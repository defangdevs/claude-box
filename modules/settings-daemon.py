# Per-user settings daemon for agent-box (issue #36).
# (Run via pkgs.writers.writePython3Bin, which supplies the interpreter
# shebang; no #! line here so it stays lint-clean.)
#
# Runs AS THE AGENT USER (no root) — it only ever touches files the user
# already owns and only kills the user's own tmux session, so it crosses no
# privilege boundary. One instance per web-terminal user, bound to
# 127.0.0.1:<port>; Caddy reverse-proxies https://<domain>/<user>/settings*
# to it INSIDE that user's existing basic-auth block, so there is no new
# auth surface (see modules/agent-box.nix).
#
# Purpose: let the end user add/remove agent secrets (GH_TOKEN,
# ANTHROPIC_API_KEY, ...) WITHOUT a nixos-rebuild and WITHOUT ever typing the
# secret into the agent chat/terminal (which would leak into the transcript,
# tmux scrollback, and model context). The secret path is
# browser -> TLS (Caddy) -> this daemon -> ~/.config/agent-box/env (0600).
#
# The UI lists key NAMES only; it never renders a stored value. "Apply"
# kills the user's tmux sessions (same uid, via the PrivateTmp socket
# under TMUX_TMPDIR); the supervisor in the agent unit brings them
# back with the fresh environment.
#
# Sessions (issue 59): the daemon is also the web CRUD surface for the
# user-owned sessions.json — add/delete/restart sessions. For the
# primary web user (AGENT_BOX_HOME=1) that session manager is served
# at the vhost root (/), replacing the old unauthenticated picker;
# other users keep it on their settings page. The reconcile/respawn
# logic deliberately does NOT live here (a daemon crash or restart
# must never take the agent sessions down): the daemon only writes the
# file and kills the user's own tmux sessions; the supervisor in the
# hardened agent unit does the starting.
#
# Deliberately Python-3-stdlib only: no third-party imports, so it stays
# tiny and auditable and needs nothing beyond pkgs.python3.
#
# Listening (issue #49): under the module, systemd socket-activates the
# daemon on a pre-bound unix socket (0660 <user>:caddy — only the user and
# the caddy reverse-proxy can connect; localhost TCP was reachable by every
# local user). Without LISTEN_FDS (dev rigs, e2e runs) it falls back to
# binding 127.0.0.1:$AGENT_BOX_SETTINGS_PORT itself.
#
# Configuration comes from the environment (set by the systemd unit):
#   AGENT_BOX_SETTINGS_USER      the linux user name (display only)
#   AGENT_BOX_SETTINGS_ENV_FILE  path to the env file to manage
#   AGENT_BOX_SETTINGS_BASE      URL base path, e.g. /alice/settings
#   AGENT_BOX_SETTINGS_PORT      dev fallback TCP port on 127.0.0.1
#                                 (ignored when socket-activated)
#   AGENT_BOX_TMUX_SOCKET        tmux -L socket name (e.g. agent-box)
#   AGENT_BOX_TMUX_TMPDIR        TMUX_TMPDIR the agent's socket lives under
#   AGENT_BOX_TMUX_BIN           absolute path to the tmux binary
#   AGENT_BOX_SESSIONS_FILE      path to the user's sessions.json
#   AGENT_BOX_HOME               "1" = also serve the session manager
#                                 at / (the primary web user's daemon)
#   AGENT_BOX_AGENTS             comma-separated installed agent CLIs
#   AGENT_BOX_DEFAULT_AGENT      agent preselected in the add form

import html
import http.server
import json
import os
import re
import signal
import socket
import subprocess
import sys
import tempfile
import urllib.parse

USER = os.environ.get("AGENT_BOX_SETTINGS_USER", "agent")
ENV_FILE = os.environ["AGENT_BOX_SETTINGS_ENV_FILE"]
BASE = os.environ.get("AGENT_BOX_SETTINGS_BASE", "/settings").rstrip("/")
PORT = int(os.environ.get("AGENT_BOX_SETTINGS_PORT", "8080"))
TMUX_SOCKET = os.environ.get("AGENT_BOX_TMUX_SOCKET", "agent-box")
TMUX_TMPDIR = os.environ.get("AGENT_BOX_TMUX_TMPDIR", "")
TMUX_BIN = os.environ.get("AGENT_BOX_TMUX_BIN", "tmux")
# Sessions (issue 59): the daemon is the web CRUD surface for the
# user-owned sessions.json; the supervisor inside the agent unit
# reconciles tmux against it (starts within ~2s). The daemon only
# ever writes the file and kills the user's own tmux sessions.
SESSIONS_FILE = os.environ.get("AGENT_BOX_SESSIONS_FILE", "")
# Primary web user's daemon (Caddy proxies the vhost root here, behind
# the same cookie-or-basic auth as the terminal): GET / renders the
# session manager and session CRUD moves to /sessions/*. The settings
# page then keeps only secrets + danger zone.
HOME = os.environ.get("AGENT_BOX_HOME", "") == "1"
# Where session CRUD routes live, and the page they redirect back to.
SESS_BASE = "" if HOME else BASE
SESS_PAGE = "/" if HOME else BASE + "/"
AGENTS = [a for a in os.environ.get("AGENT_BOX_AGENTS", "claude").split(",") if a]
DEFAULT_AGENT = os.environ.get("AGENT_BOX_DEFAULT_AGENT", "claude")
# Full sudo command line that triggers the box update (issue 54). Empty
# when selfUpdate is off, which hides the Update card and 404s the route.
UPDATE_CMD = os.environ.get("AGENT_BOX_UPDATE_CMD", "")
# Running agent-box git rev + GitHub owner/repo (set alongside
# UPDATE_CMD when selfUpdate is on) — shown on the Update card.
REPO = os.environ.get("AGENT_BOX_REPO", "")
REV = os.environ.get("AGENT_BOX_REV", "")

# Env var names: POSIX-ish. Must start with a letter or underscore and
# contain only letters, digits, underscores. This is what a shell / systemd
# EnvironmentFile will accept as a variable name.
KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
# Session names: same charset the supervisor and CLI enforce (they
# land in tmux -t targets and URLs).
SESSION_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")


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
            fh.write("# Managed by agent-box settings page. KEY=value, one per line.\n")
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


def read_sessions():
    """Return the raw sessions dict from SESSIONS_FILE ({} on any problem).

    Values are kept as-is for read-modify-write; callers that render or
    publish names filter through SESSION_RE themselves.
    """
    try:
        with open(SESSIONS_FILE, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    sessions = data.get("sessions") if isinstance(data, dict) else None
    if not isinstance(sessions, dict):
        return {}
    result = {}
    for k, v in sessions.items():
        if isinstance(k, str) and isinstance(v, dict):
            result[k] = v
    return result


def write_sessions(sessions):
    """Atomically rewrite SESSIONS_FILE (0600) with the given dict.

    Same tempfile-in-directory + os.replace dance as write_pairs. The
    supervisor in the agent unit picks the change up within ~2s.
    """
    directory = os.path.dirname(SESSIONS_FILE) or "."
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".sessions.")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump({"version": 1, "sessions": sessions}, fh, indent=2)
            fh.write("\n")
        os.replace(tmp, SESSIONS_FILE)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def tmux(*args):
    """Run a tmux command against the user's own server; None on OSError."""
    env = dict(os.environ)
    if TMUX_TMPDIR:
        env["TMUX_TMPDIR"] = TMUX_TMPDIR
    try:
        return subprocess.run(
            [TMUX_BIN, "-L", TMUX_SOCKET] + list(args),
            env=env,
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as exc:
        # Missing/unrunnable tmux binary must not 500 the request.
        sys.stderr.write("tmux: %s\n" % exc)
        return None


def live_sessions():
    proc = tmux("list-sessions", "-F", "#S")
    if proc is None or proc.returncode != 0:
        return set()
    return {line for line in proc.stdout.splitlines() if line}


def kill_session(name):
    """Kill one tmux session. The supervisor recreates it if it is still
    listed in sessions.json (= restart); delisting first makes it stay
    gone (= destroy)."""
    tmux("kill-session", "-t", "=" + name)


def find_supervisor_pids():
    """PIDs of this user's session supervisor — the agent unit's main
    process (the mkStart store script). Matched by an argv element
    ending in "agent-box-<user>-start", restricted to our own uid."""
    marker = "agent-box-%s-start" % USER
    uid = os.getuid()
    pids = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            if os.stat("/proc/" + entry).st_uid != uid:
                continue
            with open("/proc/%s/cmdline" % entry, "rb") as fh:
                argv = fh.read().split(b"\0")
        except OSError:
            continue  # process raced away
        if any(a.decode("utf-8", "replace").endswith(marker) for a in argv):
            pids.append(int(entry))
    return pids


def restart_all():
    """Bounce the WHOLE agent unit, no sudo needed: SIGTERM the
    supervisor (the unit's main process, our own uid). systemd then
    tears the session tree down and Restart=always brings the unit
    back with freshly read EnvironmentFiles — unit env is a
    start-time snapshot, so this is the only lever that applies
    root-dropped tokenDir changes (issue 89). Per-session restarts
    stay cheap: the spawn wrapper re-reads the user env file anyway.
    Dev rigs without the unit fall back to bouncing the sessions."""
    pids = find_supervisor_pids()
    if not pids:
        for name in read_sessions():
            if SESSION_RE.match(name):
                kill_session(name)
        return
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError as exc:
            sys.stderr.write("restart_all: pid %d: %s\n" % (pid, exc))


def update_box():
    """Trigger the box update oneshot via the allowlisted sudo command.
    --no-block (baked into UPDATE_CMD) means this returns immediately;
    the rebuild may later restart this very daemon.
    """
    try:
        proc = subprocess.run(
            UPDATE_CMD.split(),
            check=False,
            capture_output=True,
        )
        # rc only — never log request bodies or command output wholesale.
        sys.stderr.write("update_box: trigger rc=%d\n" % proc.returncode)
    except OSError as exc:
        sys.stderr.write("update_box: %s\n" % exc)


# Page skeleton. HEAD_TPL and BODY go through str.format (hence no
# literal braces in them); STYLE and SCRIPT are plain strings so CSS/JS
# braces need no doubling. The layout mirrors GitHub's environment-
# secrets settings: section header with an action button on the right,
# then a bordered table (header row + one row per item) with icon
# buttons per row. SCRIPT is progressive enhancement only — without JS
# the plain form POST + 303 redirect flow still works, the add/edit
# forms just render expanded.
HEAD_TPL = """<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>{title}</title>
"""

STYLE = """<style>
  body { margin: 0; min-height: 100vh; background: #0d1117; color: #e6edf3;
         font: 14px/1.5 -apple-system, BlinkMacSystemFont, system-ui, sans-serif; }
  main { max-width: 720px; margin: 0 auto; padding: 32px 20px 48px; }
  h1 { font-size: 24px; font-weight: 600; margin: 8px 0 4px; }
  h2 { font-size: 16px; font-weight: 600; margin: 0; }
  section { margin: 28px 0; }
  .sec-head { display: flex; align-items: center; justify-content: space-between;
              gap: 12px; }
  a.back { color: #8b949e; text-decoration: none; font-size: 13px; }
  a.back:hover { color: #e6edf3; }
  .note { color: #8b949e; font-size: 13px; margin: 6px 0 0; }
  .note a { color: #58a6ff; text-decoration: none; }
  .note a:hover { text-decoration: underline; }
  code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
         font-size: 13px; }
  .tbl { list-style: none; margin: 12px 0 0; padding: 0;
         border: 1px solid #30363d; border-radius: 8px; overflow: hidden; }
  .tbl li { display: flex; align-items: center; justify-content: space-between;
            gap: 12px; padding: 10px 16px; border-top: 1px solid #30363d; }
  .tbl li:first-child { border-top: 0; }
  .tbl-head { background: #161b22; color: #8b949e; font-size: 13px;
              font-weight: 600; }
  li.empty { color: #8b949e; font-size: 13px; }
  .nm { display: flex; align-items: center; gap: 8px; min-width: 0; }
  .nm svg { color: #8b949e; flex: none; }
  a.sess { color: #58a6ff; text-decoration: none; }
  a.sess:hover { text-decoration: underline; }
  .acts { display: flex; align-items: center; gap: 4px; flex: none; }
  .meta { color: #8b949e; font-size: 12px; }
  .state { font-size: 12px; color: #8b949e; }
  .state::before { content: ""; display: inline-block; width: 8px; height: 8px;
                   border-radius: 50%; background: currentColor; margin-right: 5px; }
  .state[data-state=live] { color: #3fb950; }
  .state[data-state=starting] { color: #d29922; }
  .btn { font: inherit; font-size: 13px; font-weight: 500; padding: 5px 14px;
         border-radius: 6px; border: 1px solid #30363d; background: #21262d;
         color: #e6edf3; cursor: pointer; white-space: nowrap; }
  .btn:hover { background: #30363d; }
  .btn.small { padding: 3px 10px; font-size: 12px; }
  button.icon { display: inline-flex; padding: 5px 8px; background: transparent;
                border: 0; border-radius: 6px; color: #8b949e; cursor: pointer; }
  button.icon:hover { background: #21262d; color: #e6edf3; }
  button.icon.idanger:hover { color: #f85149; background: rgba(248,81,73,.1); }
  .danger-btn { color: #f85149; }
  .danger-btn:hover { background: #da3633; border-color: #f85149; color: #fff; }
  .tbl.danger { border-color: rgba(248,81,73,.4); }
  .dz { display: flex; flex-direction: column; min-width: 0; }
  .dz strong { font-size: 14px; }
  .dz .note { margin: 2px 0 0; }
  .editor { border: 1px solid #30363d; border-radius: 8px; background: #161b22;
            padding: 14px 16px; margin: 12px 0 0; }
  input, select { font: inherit; font-size: 13px; padding: 6px 10px;
                  border-radius: 6px; border: 1px solid #30363d;
                  background: #0d1117; color: #e6edf3; }
  input[type=text] { width: 200px; max-width: 100%; }
  input[type=password] { width: 280px; max-width: 100%; }
  .row { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
  form.inline { display: inline; }
  .msg { padding: 10px 14px; border-radius: 8px; margin: 12px 0;
         border: 1px solid rgba(63,185,80,.4); background: #10251a;
         color: #7ee787; font-size: 13px; }
</style>
"""

# The session manager, one <section> shared by the two pages that can
# host it: the root page (primary user, HOME) and the settings page
# (everyone else). {action_base} is SESS_BASE, so the forms post to
# wherever the session routes actually live.
SESSIONS_SECTION_TPL = """<section>
    <div class="sec-head">
      <h2>Sessions</h2>
      <button type="button" class="btn" data-toggle="session-editor">Add session</button>
    </div>
    <p class="note">Each session is one agent CLI in its own terminal.
    New sessions start within a few seconds &mdash; no rebuild, no sudo.
    Click a session to open its terminal.</p>
    <div id="session-editor" class="editor">
      <form method="post" action="{action_base}/sessions/add">
        <div class="row">
          <input type="text" name="name" placeholder="session-name"
                 pattern="[A-Za-z0-9_-]+" required
                 title="Letters, digits, dash and underscore">
          <select name="agent">{agents}</select>
          <button type="submit" class="btn">Add session</button>
        </div>
      </form>
    </div>
    <div id="sessions-list">{sessions}</div>
  </section>"""

# Root page (HOME mode): the session manager IS the front page; the
# settings page holds everything else.
HOME_BODY = """<main>
  <a class="back" href="{base}/">&#9881; Settings</a>
  <h1>Sessions</h1>
  <div id="msg-slot">{message}</div>
  {sessions_section}
</main>
</html>
"""

BODY = """<main>
  <a class="back" href="/">&larr; sessions</a>
  <h1>Settings for {user}</h1>
  <div id="msg-slot">{message}</div>
  {sessions_section}
  <section>
    <div class="sec-head">
      <h2>Environment secrets</h2>
      <button type="button" class="btn" data-toggle="secret-editor">Add secret</button>
    </div>
    <p class="note">Secrets are passed to your agent sessions as environment
    variables (e.g. <code>GH_TOKEN</code>, <code>ANTHROPIC_API_KEY</code>).
    They are written to a private file only your agent can read &mdash;
    never shown here, never typed into the chat. Restart sessions to
    apply changes.</p>
    <div id="secret-editor" class="editor">
      <form id="secret-form" method="post" action="{base}/set">
        <div class="row">
          <input type="text" name="key" placeholder="KEY_NAME"
                 pattern="[A-Za-z_][A-Za-z0-9_]*" required
                 title="Letters, digits and underscores; must not start with a digit">
          <input type="password" name="value" placeholder="value" autocomplete="off" required>
          <button type="submit" class="btn">Save</button>
        </div>
        <p class="note">The value is write-only &mdash; saving replaces any
        existing value for that key. This page never displays stored values.</p>
      </form>
    </div>
    <div id="secrets-list">{keys}</div>
  </section>
  <section>
    <h2>Danger zone</h2>
    <ul class="tbl danger">
      <li>
        <span class="dz"><strong>Restart all sessions</strong>
        <span class="note">Restarts the whole agent service: every
        session comes back with the current secrets and token files.
        Live sessions are killed &mdash; unsaved in-flight work is lost.</span></span>
        <form method="post" action="{base}/restart"
              onsubmit="return confirm('Restart all sessions now? Live sessions will be killed and any unsaved in-flight work is lost.');">
          <button type="submit" class="btn danger-btn">Restart all</button>
        </form>
      </li>
      {update_row}
    </ul>
  </section>
</main>
</html>
"""

UPDATE_ROW = """<li>
        <span class="dz"><strong>Update box</strong>
        <span class="note">Fetches the latest agent-box release and agent
        CLI versions, then rebuilds the system. Takes a few minutes; sessions
        restart if their software changed.{rev_line}</span></span>
        <form method="post" action="{base}/update"
              onsubmit="return confirm('Update the box now? This rebuilds the system and may restart the agent sessions.');">
          <button type="submit" class="btn danger-btn">Update box</button>
        </form>
      </li>"""

# Octicons (MIT) inlined so the page stays a single self-contained
# response.
ICON_LOCK = (
    '<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">'
    '<path d="M4 4a4 4 0 0 1 8 0v2h.25c.966 0 1.75.784 1.75 1.75v5.5A1.75 1.75 0 0 1 12.25 15'
    'h-8.5A1.75 1.75 0 0 1 2 13.25v-5.5C2 6.784 2.784 6 3.75 6H4Zm8.25 3.5h-8.5a.25.25 0 0 0'
    '-.25.25v5.5c0 .138.112.25.25.25h8.5a.25.25 0 0 0 .25-.25v-5.5a.25.25 0 0 0-.25-.25Z'
    'M10.5 6V4a2.5 2.5 0 1 0-5 0v2Z"/></svg>'
)
ICON_PENCIL = (
    '<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">'
    '<path d="M11.013 1.427a1.75 1.75 0 0 1 2.474 0l1.086 1.086a1.75 1.75 0 0 1 0 2.474l-8.61 '
    '8.61c-.21.21-.47.364-.756.445l-3.251.93a.75.75 0 0 1-.927-.928l.929-3.25c.081-.286.235'
    '-.547.445-.758l8.61-8.61Zm.176 4.823L9.75 4.81l-6.286 6.287a.253.253 0 0 0-.064.108l'
    '-.558 1.953 1.953-.558a.253.253 0 0 0 .108-.064Zm1.238-3.763a.25.25 0 0 0-.354 0L10.811 '
    '3.75l1.439 1.44 1.263-1.263a.25.25 0 0 0 0-.354Z"/></svg>'
)
ICON_TRASH = (
    '<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">'
    '<path d="M11 1.75V3h2.25a.75.75 0 0 1 0 1.5H2.75a.75.75 0 0 1 0-1.5H5V1.75C5 .784 5.784 '
    '0 6.75 0h2.5C10.216 0 11 .784 11 1.75ZM4.496 6.675l.66 6.6a.25.25 0 0 0 .249.225h5.19'
    'a.25.25 0 0 0 .249-.225l.66-6.6a.75.75 0 0 1 1.492.149l-.66 6.6A1.748 1.748 0 0 1 '
    '10.595 15h-5.19a1.75 1.75 0 0 1-1.741-1.575l-.66-6.6a.75.75 0 1 1 1.492-.15ZM6.5 1.75'
    'V3h3V1.75a.25.25 0 0 0-.25-.25h-2.5a.25.25 0 0 0-.25.25Z"/></svg>'
)

# Progressive enhancement: submit forms via fetch and patch the three
# swap regions (message, secrets list, sessions list) in place, so
# changes show up without a page reload; poll briefly while a session
# is still "starting" so the state flips to "live" on its own. The
# inline confirm() guards run before the submit event reaches us — a
# dismissed dialog cancels the event, so we only see accepted ones.
SCRIPT = """<script>
(function () {
  "use strict";
  function applyDoc(doc, ids) {
    ids.forEach(function (id) {
      var from = doc.getElementById(id);
      var to = document.getElementById(id);
      if (from && to) { to.replaceWith(document.importNode(from, true)); }
    });
  }
  function parseHTML(text) {
    return new DOMParser().parseFromString(text, "text/html");
  }

  var pollLeft = 0;
  var pollTimer = null;
  function schedulePoll() {
    if (pollTimer || pollLeft <= 0) { return; }
    if (!document.querySelector("#sessions-list [data-state=starting]")) { return; }
    pollLeft -= 1;
    pollTimer = window.setTimeout(function () {
      pollTimer = null;
      fetch(window.location.pathname)
        .then(function (r) { return r.text(); })
        .then(function (t) {
          applyDoc(parseHTML(t), ["sessions-list"]);
          schedulePoll();
        });
    }, 2500);
  }
  function startPolling(n) { pollLeft = n; schedulePoll(); }

  // The editors render expanded (no-JS fallback); collapse them once
  // JS is live so the page opens in list-only, GitHub-style form.
  ["secret-editor", "session-editor"].forEach(function (id) {
    var el = document.getElementById(id);
    if (el) { el.hidden = true; }
  });

  document.addEventListener("click", function (e) {
    var t = e.target && e.target.closest ? e.target.closest("[data-toggle],[data-edit]") : null;
    if (!t) { return; }
    var form = document.getElementById("secret-form");
    if (t.hasAttribute("data-edit")) {
      document.getElementById("secret-editor").hidden = false;
      form.reset();
      var key = form.querySelector("input[name=key]");
      key.value = t.getAttribute("data-edit");
      key.readOnly = true;
      form.querySelector("input[name=value]").focus();
      return;
    }
    var el = document.getElementById(t.getAttribute("data-toggle"));
    if (!el) { return; }
    el.hidden = !el.hidden;
    if (!el.hidden && el.id === "secret-editor") {
      form.reset();
      var ki = form.querySelector("input[name=key]");
      ki.readOnly = false;
      ki.focus();
    }
  });

  document.addEventListener("submit", function (e) {
    var f = e.target;
    if (e.defaultPrevented || !f || (f.method || "").toLowerCase() !== "post") { return; }
    e.preventDefault();
    var body = new URLSearchParams();
    new FormData(f).forEach(function (v, k) { body.append(k, v); });
    fetch(f.getAttribute("action"), { method: "POST", body: body })
      .then(function (r) { return r.text(); })
      .then(function (t) {
        applyDoc(parseHTML(t), ["msg-slot", "secrets-list", "sessions-list"]);
        var ed = f.closest(".editor");
        if (ed) { f.reset(); ed.hidden = true; }
        startPolling(8);
      });
  });

  startPolling(8);
})();
</script>
"""


def render_keys(keys):
    base = html.escape(BASE)
    rows = []
    for key in keys:
        safe = html.escape(key)
        rows.append(
            f'<li><span class="nm">{ICON_LOCK}<code>{safe}</code></span>'
            f'<span class="acts">'
            f'<button type="button" class="icon" data-edit="{safe}" '
            f'aria-label="Edit" title="Update {safe}">{ICON_PENCIL}</button>'
            f'<form class="inline" method="post" action="{base}/delete" '
            f'onsubmit="return confirm(\'Delete {safe}?\');">'
            f'<input type="hidden" name="key" value="{safe}">'
            f'<button type="submit" class="icon idanger" aria-label="Delete" '
            f'title="Delete {safe}">{ICON_TRASH}</button></form>'
            f'</span></li>'
        )
    body = "".join(rows) if rows else '<li class="empty">No secrets yet.</li>'
    return '<ul class="tbl"><li class="tbl-head">Name</li>' + body + "</ul>"


def render_sessions():
    entries = {n: v for n, v in read_sessions().items() if SESSION_RE.match(n)}
    base = html.escape(SESS_BASE)
    user = urllib.parse.quote(USER, safe="")
    if not entries:
        body = '<li class="empty">No sessions defined.</li>'
    else:
        live = live_sessions()
        items = []
        for name in sorted(entries):
            safe = html.escape(name)
            agent = html.escape(str(entries[name].get("agent") or "?"))
            state = "live" if name in live else "starting"
            items.append(
                # The name deep-links into the terminal via ttyd's
                # ?arg= session selector. No userinfo in the href
                # (issue 56). SESSION_RE names are URL-safe as-is.
                f'<li><span class="nm">'
                f'<a class="sess" href="/{user}/?arg={safe}"><code>{safe}</code></a>'
                f'<span class="meta">{agent}</span>'
                f'<span class="state" data-state="{state}">{state}</span></span>'
                f'<span class="acts">'
                f'<form class="inline" method="post" action="{base}/sessions/restart" '
                f'onsubmit="return confirm(\'Restart {safe}? Unsaved in-flight work is lost.\');">'
                f'<input type="hidden" name="name" value="{safe}">'
                f'<button type="submit" class="btn small">Restart</button></form>'
                f'<form class="inline" method="post" action="{base}/sessions/delete" '
                f'onsubmit="return confirm(\'Delete session {safe}? Its live agent is killed.\');">'
                f'<input type="hidden" name="name" value="{safe}">'
                f'<button type="submit" class="icon idanger" aria-label="Delete" '
                f'title="Delete {safe}">{ICON_TRASH}</button></form>'
                f'</span></li>'
            )
        body = "".join(items)
    return '<ul class="tbl"><li class="tbl-head">Session</li>' + body + "</ul>"


def render_agent_options():
    items = []
    for agent in AGENTS:
        sel = " selected" if agent == DEFAULT_AGENT else ""
        safe = html.escape(agent)
        items.append(f'<option value="{safe}"{sel}>{safe}</option>')
    return "".join(items)


def render_rev_line():
    """The running agent-box rev as a GitHub commit link (Update card).

    REV is a full git sha; the label shows the usual short form. Empty
    when the module didn't pass a rev (selfUpdate off — but then the
    whole Update card is hidden anyway).
    """
    if not REV:
        return ""
    label = f"<code>{html.escape(REV[:12])}</code>"
    if REPO:
        url = html.escape(f"https://github.com/{REPO}/commit/{REV}")
        label = f'<a href="{url}">{label}</a>'
    return " Currently at " + label + "."


def render_sessions_section():
    return SESSIONS_SECTION_TPL.format(
        action_base=html.escape(SESS_BASE),
        agents=render_agent_options(),
        sessions=render_sessions(),
    )


def render_page(message=""):
    msg_html = f'<div class="msg">{html.escape(message)}</div>' if message else ""
    return (
        HEAD_TPL.format(title="Settings &mdash; " + html.escape(USER))
        + STYLE
        + BODY.format(
            user=html.escape(USER),
            base=html.escape(BASE),
            keys=render_keys(read_keys()),
            # HOME moves the session manager to the root page; keep it
            # here for every other user.
            sessions_section="" if HOME else render_sessions_section(),
            message=msg_html,
            update_row=(
                UPDATE_ROW.format(base=html.escape(BASE), rev_line=render_rev_line())
                if UPDATE_CMD else ""
            ),
        )
        + SCRIPT
    )


def render_home(message=""):
    msg_html = f'<div class="msg">{html.escape(message)}</div>' if message else ""
    return (
        HEAD_TPL.format(title="Sessions &mdash; " + html.escape(USER))
        + STYLE
        + HOME_BODY.format(
            base=html.escape(BASE),
            sessions_section=render_sessions_section(),
            message=msg_html,
        )
        + SCRIPT
    )


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "agent-box-settings/1"

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

    def _redirect(self, query="", page=None):
        target = (page or BASE + "/") + (("?" + query) if query else "")
        self.send_response(303)
        self.send_header("Location", target)
        self.send_header("Content-Length", "0")
        self.end_headers()

    OK_MESSAGES = {
        "saved": "Key saved. Restart the sessions to apply.",
        "deleted": "Key deleted. Restart the sessions to apply.",
        "restarted": "Restart of all sessions requested.",
        "session_added": "Session added — it starts within a few seconds.",
        "session_deleted": "Session deleted.",
        "session_restarted": "Session restart requested.",
        "update": "Box update started — the system rebuilds in the "
                  "background and this page may briefly go away.",
    }

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        message = ""
        if "ok" in params:
            message = self.OK_MESSAGES.get(params["ok"][0], "")
        if HOME and parsed.path == "/":
            self._send_html(render_home(message))
            return
        if not self._under_base(parsed.path):
            self._send_html("<h1>404</h1>", status=404)
            return
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
        elif path == SESS_BASE + "/sessions/add":
            render = render_home if HOME else render_page
            name = (form.get("name", [""])[0]).strip()
            agent = (form.get("agent", [""])[0]).strip() or DEFAULT_AGENT
            if not SESSION_RE.match(name):
                self._send_html(
                    render("Invalid session name. Use letters, digits, "
                           "dash and underscore (max 32 chars)."),
                    status=400,
                )
                return
            if agent not in AGENTS:
                self._send_html(
                    render("Unknown agent. Installed: " + ", ".join(AGENTS)),
                    status=400,
                )
                return
            sessions = read_sessions()
            sessions[name] = {
                "agent": agent,
                "skipPermissions": True,
                "remoteControl": True,
                "remoteControlName": None,
                "workingDirectory": None,
                "extraArgs": [],
            }
            write_sessions(sessions)
            self._redirect("ok=session_added", SESS_PAGE)
        elif path == SESS_BASE + "/sessions/delete":
            name = (form.get("name", [""])[0]).strip()
            if SESSION_RE.match(name):
                sessions = read_sessions()
                sessions.pop(name, None)
                write_sessions(sessions)
                kill_session(name)
            self._redirect("ok=session_deleted", SESS_PAGE)
        elif path == SESS_BASE + "/sessions/restart":
            name = (form.get("name", [""])[0]).strip()
            if SESSION_RE.match(name):
                kill_session(name)
            self._redirect("ok=session_restarted", SESS_PAGE)
        elif path == BASE + "/restart":
            # Full unit bounce (see restart_all): re-reads unit-level
            # EnvironmentFiles, which per-session restarts can't.
            restart_all()
            self._redirect("ok=restarted")
        elif path == BASE + "/update" and UPDATE_CMD:
            update_box()
            self._redirect("ok=update")
        else:
            self._send_html("<h1>404</h1>", status=404)

    def address_string(self):
        # AF_UNIX peers have no (host, port) client_address — the base class
        # would IndexError on the empty string it gets instead.
        if isinstance(self.client_address, tuple) and self.client_address:
            return super().address_string()
        return "unix"

    def log_message(self, fmt, *args):
        # Keep the journal quiet-ish; never log form bodies (would leak
        # secrets). Only method + path + status, which BaseHTTPRequestHandler
        # already restricts to.
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


# Per the systemd socket-activation protocol, inherited listening sockets
# start at fd 3 (after stdin/stdout/stderr).
SD_LISTEN_FDS_START = 3


def make_server():
    if int(os.environ.get("LISTEN_FDS", "0") or "0") >= 1:
        # Socket-activated (the module's only mode, issue #49): adopt the
        # unix socket systemd pre-bound with 0660 <user>:caddy permissions.
        # bind_and_activate=False skips bind/listen; the placeholder address
        # is never bound.
        server = http.server.ThreadingHTTPServer(
            ("127.0.0.1", 0), Handler, bind_and_activate=False
        )
        server.socket = socket.socket(fileno=SD_LISTEN_FDS_START)
        # server_bind() never ran; set the attributes it would have set.
        server.server_name = "agent-box-settings"
        server.server_port = 0
        return server
    # Dev fallback for LAN rigs / e2e runs outside the module.
    return http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)


def main():
    make_server().serve_forever()


if __name__ == "__main__":
    main()
