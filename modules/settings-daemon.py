# Per-user settings daemon for claude-box (issue #36).
# (Run via pkgs.writers.writePython3Bin, which supplies the interpreter
# shebang; no #! line here so it stays lint-clean.)
#
# Runs AS THE AGENT USER (no root) — it only ever touches files the user
# already owns and only kills the user's own tmux session, so it crosses no
# privilege boundary. One instance per web-terminal user, bound to
# 127.0.0.1:<port>; Caddy reverse-proxies https://<domain>/<user>/settings*
# to it INSIDE that user's existing basic-auth block, so there is no new
# auth surface (see modules/claude-box.nix).
#
# Purpose: let the end user add/remove agent secrets (GH_TOKEN,
# ANTHROPIC_API_KEY, ...) WITHOUT a nixos-rebuild and WITHOUT ever typing the
# secret into the agent chat/terminal (which would leak into the transcript,
# tmux scrollback, and model context). The secret path is
# browser -> TLS (Caddy) -> this daemon -> ~/.config/claude-box/env (0600).
#
# The UI lists key NAMES only; it never renders a stored value. "Apply"
# restarts the agent by killing its tmux session (same uid, via the
# PrivateTmp socket under TMUX_TMPDIR); the agent unit's Restart=always
# brings it back with the fresh environment.
#
# Deliberately Python-3-stdlib only: no third-party imports, so it stays
# tiny and auditable and needs nothing beyond pkgs.python3.
#
# Configuration comes from the environment (set by the systemd unit):
#   CLAUDE_BOX_SETTINGS_USER      the linux user name (display only)
#   CLAUDE_BOX_SETTINGS_ENV_FILE  path to the env file to manage
#   CLAUDE_BOX_SETTINGS_BASE      URL base path, e.g. /alice/settings
#   CLAUDE_BOX_SETTINGS_PORT      TCP port to bind on 127.0.0.1
#   CLAUDE_BOX_TMUX_SOCKET        tmux -L socket name (e.g. agent-box)
#   CLAUDE_BOX_TMUX_SESSION       tmux session name (e.g. main)
#   CLAUDE_BOX_TMUX_TMPDIR        TMUX_TMPDIR the agent's socket lives under
#   CLAUDE_BOX_TMUX_BIN           absolute path to the tmux binary

import html
import http.server
import os
import re
import subprocess
import sys
import tempfile
import urllib.parse

USER = os.environ.get("CLAUDE_BOX_SETTINGS_USER", "agent")
ENV_FILE = os.environ["CLAUDE_BOX_SETTINGS_ENV_FILE"]
BASE = os.environ.get("CLAUDE_BOX_SETTINGS_BASE", "/settings").rstrip("/")
PORT = int(os.environ.get("CLAUDE_BOX_SETTINGS_PORT", "8080"))
TMUX_SOCKET = os.environ.get("CLAUDE_BOX_TMUX_SOCKET", "agent-box")
TMUX_SESSION = os.environ.get("CLAUDE_BOX_TMUX_SESSION", "main")
TMUX_TMPDIR = os.environ.get("CLAUDE_BOX_TMUX_TMPDIR", "")
TMUX_BIN = os.environ.get("CLAUDE_BOX_TMUX_BIN", "tmux")

# Env var names: POSIX-ish. Must start with a letter or underscore and
# contain only letters, digits, underscores. This is what a shell / systemd
# EnvironmentFile will accept as a variable name.
KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def read_keys():
    """Return the sorted list of KEY names currently in the env file.

    Values are intentionally never returned — the UI must not be able to
    surface a stored secret.
    """
    keys = []
    try:
        with open(ENV_FILE, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key = line.split("=", 1)[0].strip()
                if KEY_RE.match(key):
                    keys.append(key)
    except FileNotFoundError:
        pass
    # De-dup preserving the last occurrence's position is unnecessary; names
    # are what matter, so sort for a stable UI.
    return sorted(set(keys))


def load_pairs():
    """Return an ordered dict-ish list of (key, rawvalue) for rewriting.

    Used only internally when mutating the file; values never leave the
    process.
    """
    pairs = []
    try:
        with open(ENV_FILE, "r", encoding="utf-8") as fh:
            for line in fh:
                stripped = line.strip()
                if not stripped or stripped.startswith("#") or "=" not in stripped:
                    continue
                key, val = stripped.split("=", 1)
                key = key.strip()
                if KEY_RE.match(key):
                    pairs.append((key, val))
    except FileNotFoundError:
        pass
    return pairs


def write_pairs(pairs):
    """Atomically write pairs to ENV_FILE at mode 0600.

    Writes to a temp file in the same directory (so os.replace is atomic on
    the same filesystem) then renames over the target.
    """
    directory = os.path.dirname(ENV_FILE) or "."
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".env.")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write("# Managed by claude-box settings page. KEY=value, one per line.\n")
            fh.write("# Do not add secrets by hand here unless you know what you are doing.\n")
            for key, val in pairs:
                fh.write(f"{key}={val}\n")
        os.replace(tmp, ENV_FILE)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def set_key(key, value):
    pairs = [(k, v) for (k, v) in load_pairs() if k != key]
    pairs.append((key, value))
    write_pairs(pairs)


def delete_key(key):
    pairs = [(k, v) for (k, v) in load_pairs() if k != key]
    write_pairs(pairs)


def restart_agent():
    """Kill the agent's tmux session so systemd's Restart=always reloads it
    with fresh env. Runs as the same uid; the socket lives under the agent
    unit's PrivateTmp TMUX_TMPDIR (a /run path both processes share).
    """
    env = dict(os.environ)
    if TMUX_TMPDIR:
        env["TMUX_TMPDIR"] = TMUX_TMPDIR
    try:
        subprocess.run(
            [TMUX_BIN, "-L", TMUX_SOCKET, "kill-session", "-t", TMUX_SESSION],
            env=env,
            check=False,
            capture_output=True,
        )
    except OSError as exc:
        # Missing/unrunnable tmux binary must not 500 the request.
        sys.stderr.write("restart_agent: %s\n" % exc)


PAGE = """<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Settings — {user}</title>
<style>
  body {{ margin: 0; min-height: 100vh; background: #0d1117; color: #e6edf3;
         font: 16px/1.6 system-ui, sans-serif; }}
  main {{ max-width: 640px; margin: 0 auto; padding: 32px 20px; }}
  h1 {{ font-size: 24px; }}
  a.back {{ color: #8b949e; text-decoration: none; font-size: 14px; }}
  a.back:hover {{ color: #e6edf3; }}
  .card {{ border: 1px solid #30363d; border-radius: 10px; background: #161b22;
          padding: 18px; margin: 18px 0; }}
  .note {{ color: #8b949e; font-size: 13px; }}
  ul {{ list-style: none; padding: 0; margin: 0; }}
  li {{ display: flex; align-items: center; justify-content: space-between;
       padding: 8px 0; border-bottom: 1px solid #21262d; }}
  li:last-child {{ border-bottom: 0; }}
  code {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
         color: #e8a087; }}
  input {{ font: inherit; padding: 8px 10px; border-radius: 6px;
          border: 1px solid #30363d; background: #0d1117; color: #e6edf3; }}
  input[type=text] {{ width: 160px; }}
  input[type=password] {{ width: 260px; }}
  button {{ font: inherit; padding: 8px 16px; border-radius: 6px;
           border: 1px solid #30363d; background: #21262d; color: #e6edf3;
           cursor: pointer; }}
  button:hover {{ border-color: #e8a087; }}
  button.danger {{ color: #f0a1a1; }}
  form.inline {{ display: inline; }}
  .row {{ display: flex; gap: 8px; flex-wrap: wrap; align-items: center;
         margin-top: 10px; }}
  .msg {{ padding: 10px 14px; border-radius: 8px; margin: 12px 0;
         border: 1px solid #30363d; background: #10251a; color: #7ee787; }}
</style>
<main>
  <a class="back" href="/">← all terminals</a>
  <h1>Settings for {user}</h1>
  <p class="note">
    Add API keys and tokens for your agent (e.g. <code>GH_TOKEN</code>,
    <code>ANTHROPIC_API_KEY</code>). They are written to a private file only
    your agent can read — never shown here, never typed into the chat.
    Values take effect after you restart the agent.
  </p>
  {message}
  <div class="card">
    <h2 style="font-size:16px;margin-top:0">Current keys</h2>
    {keys}
  </div>
  <div class="card">
    <h2 style="font-size:16px;margin-top:0">Add or update a key</h2>
    <form method="post" action="{base}/set">
      <div class="row">
        <input type="text" name="key" placeholder="KEY_NAME"
               pattern="[A-Za-z_][A-Za-z0-9_]*" required
               title="Letters, digits and underscores; must not start with a digit">
        <input type="password" name="value" placeholder="value" autocomplete="off" required>
        <button type="submit">Save</button>
      </div>
      <p class="note">The value is write-only — saving replaces any existing
      value for that key. This page never displays stored values.</p>
    </form>
  </div>
  <div class="card">
    <h2 style="font-size:16px;margin-top:0">Apply changes (restart agent)</h2>
    <p class="note">Restarting reloads the agent with the current keys.
    <strong>This kills the live agent session</strong> — any in-flight work
    in the terminal that the agent has not persisted is lost.</p>
    <form method="post" action="{base}/restart"
          onsubmit="return confirm('Restart the agent now? The live session will be killed and any unsaved in-flight work is lost.');">
      <button type="submit" class="danger">Restart agent</button>
    </form>
  </div>
</main>
</html>
"""


def render_keys(keys):
    if not keys:
        return '<p class="note">No keys set yet.</p>'
    items = []
    for key in keys:
        safe = html.escape(key)
        items.append(
            f'<li><code>{safe}</code>'
            f'<form class="inline" method="post" action="{html.escape(BASE)}/delete" '
            f'onsubmit="return confirm(\'Delete {safe}?\');">'
            f'<input type="hidden" name="key" value="{safe}">'
            f'<button type="submit" class="danger">Delete</button></form></li>'
        )
    return "<ul>" + "".join(items) + "</ul>"


def render_page(message=""):
    msg_html = f'<div class="msg">{html.escape(message)}</div>' if message else ""
    return PAGE.format(
        user=html.escape(USER),
        base=html.escape(BASE),
        keys=render_keys(read_keys()),
        message=msg_html,
    )


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "claude-box-settings/1"

    def _under_base(self, path):
        """True if request path is BASE or under BASE. Caddy strips nothing,
        so we match the full public path."""
        return path == BASE or path == BASE + "/" or path.startswith(BASE + "/")

    def _send_html(self, body, status=200):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def _redirect(self, query=""):
        target = BASE + "/" + (("?" + query) if query else "")
        self.send_response(303)
        self.send_header("Location", target)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if not self._under_base(parsed.path):
            self._send_html("<h1>404</h1>", status=404)
            return
        params = urllib.parse.parse_qs(parsed.query)
        message = ""
        if "ok" in params:
            message = {
                "saved": "Key saved. Restart the agent to apply.",
                "deleted": "Key deleted. Restart the agent to apply.",
                "restarted": "Agent restart requested.",
            }.get(params["ok"][0], "")
        self._send_html(render_page(message))

    def _read_form(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length).decode("utf-8") if length else ""
        return urllib.parse.parse_qs(raw)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/")
        form = self._read_form()
        if path == BASE + "/set":
            key = (form.get("key", [""])[0]).strip()
            value = form.get("value", [""])[0]
            if not KEY_RE.match(key):
                self._send_html(
                    render_page("Invalid key name. Use letters, digits and "
                                "underscores; do not start with a digit."),
                    status=400,
                )
                return
            set_key(key, value)
            self._redirect("ok=saved")
        elif path == BASE + "/delete":
            key = (form.get("key", [""])[0]).strip()
            if KEY_RE.match(key):
                delete_key(key)
            self._redirect("ok=deleted")
        elif path == BASE + "/restart":
            restart_agent()
            self._redirect("ok=restarted")
        else:
            self._send_html("<h1>404</h1>", status=404)

    def log_message(self, fmt, *args):
        # Keep the journal quiet-ish; never log form bodies (would leak
        # secrets). Only method + path + status, which BaseHTTPRequestHandler
        # already restricts to.
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
