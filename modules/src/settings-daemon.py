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
# user-owned sessions.json — add/delete/restart sessions, managed on
# every user's settings page. For the primary web user
# (AGENT_BOX_HOME=1) the vhost root (/) additionally serves a tabbed
# terminal workspace (issue 119): one tab per session, each pane an
# iframe onto the per-session ttyd URL. The reconcile/respawn
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
#   AGENT_BOX_HOME               "1" = also serve the tabbed terminal
#                                 workspace at / (primary web user)
#   AGENT_BOX_AGENTS             comma-separated installed agent CLIs
#   AGENT_BOX_DEFAULT_AGENT      agent preselected in the add form
#   AGENT_BOX_PASSWORD_CMD       no-argument sudo command that verifies
#                                 and replaces this user's web password

import html
import http.server
import json
import os
import re
import secrets
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
# tabbed terminal workspace and session CRUD lives at /sessions/*.
# The settings page keeps the session manager list plus secrets +
# danger zone.
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
# UPDATE_CMD when selfUpdate is on) — shown on the Update card and
# used by its non-blocking GitHub update check.
REPO = os.environ.get("AGENT_BOX_REPO", "")
REV = os.environ.get("AGENT_BOX_REV", "")
# Read-only handles for the {BASE}/status progress endpoint the page
# polls after triggering an update: the update oneshot's unit name and
# a systemctl binary to `show` its state with. Both empty unless
# selfUpdate is on (no unit to watch) or on dev rigs without systemd;
# the endpoint then simply omits the update block. Querying unit state
# is unprivileged — no sudo, unlike the trigger in UPDATE_CMD.
UPDATE_UNIT = os.environ.get("AGENT_BOX_UPDATE_UNIT", "")
SYSTEMCTL = os.environ.get("AGENT_BOX_SYSTEMCTL", "")
# Per-user, no-argument privileged helper (issue 91). Passwords are sent
# as JSON on stdin, never argv or environment, and helper output is never
# reflected into HTTP responses.
PASSWORD_CMD = os.environ.get("AGENT_BOX_PASSWORD_CMD", "")

# Env var names: POSIX-ish. Must start with a letter or underscore and
# contain only letters, digits, underscores. This is what a shell / systemd
# EnvironmentFile will accept as a variable name.
KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
# Session names: same charset the supervisor and CLI enforce (they
# land in tmux -t targets and URLs).
SESSION_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")

# The agent user's home. A session's working directory defaults to it
# and the working-directory picker (below) browses within it: the
# daemon runs AS the user with ProtectHome=false, so it could read the
# whole tree, but a session only ever runs somewhere the user owns and
# confining the picker to $HOME keeps the web surface from doubling as
# a filesystem browser. systemd sets $HOME for User=; fall back to the
# passwd entry so a bare dev invocation still resolves it.
HOME_DIR = os.path.realpath(
    os.environ.get("HOME") or os.path.expanduser("~" + USER)
)


def resolve_browse_dir(raw):
    """Map a user-typed directory prefix to an absolute path CONFINED
    to HOME_DIR, or None if it escapes. "", "~" and "~/" mean HOME;
    "~/x" and absolute paths are honoured; anything else is relative to
    HOME. Only the directory portion is resolved — the caller lists its
    immediate children. realpath collapses .. and symlinks BEFORE the
    containment check, so neither can climb out of HOME."""
    raw = (raw or "").strip()
    if raw in ("", "~", "~/"):
        return HOME_DIR
    if raw.startswith("~/"):
        candidate = os.path.join(HOME_DIR, raw[2:])
    elif raw.startswith("/"):
        candidate = raw
    else:
        candidate = os.path.join(HOME_DIR, raw)
    candidate = os.path.realpath(candidate)
    if candidate == HOME_DIR or candidate.startswith(HOME_DIR + os.sep):
        return candidate
    return None


def list_subdirs(abs_dir):
    """Immediate subdirectory names of abs_dir, sorted case-folded and
    capped. is_dir() follows symlinks (a symlinked checkout is a valid
    cwd); an unreadable or non-directory path yields []."""
    try:
        entries = list(os.scandir(abs_dir))
    except OSError:
        return []
    names = []
    for entry in entries:
        try:
            if entry.is_dir():
                names.append(entry.name)
        except OSError:
            continue
    names.sort(key=str.lower)
    return names[:500]


def resolve_session_cwd(raw):
    """Turn the add form's working-directory field into the value
    stored in sessions.json, or raise ValueError with a user-facing
    message. HOME (the "~" default) is stored as None so the supervisor
    keeps its default-to-home behaviour and the file stays portable;
    any other directory is stored as an absolute path. The path must
    already exist — tmux new-session -c fails on a missing cwd."""
    abs_dir = resolve_browse_dir(raw)
    if abs_dir is None:
        raise ValueError("Working directory must be inside your home directory.")
    if not os.path.isdir(abs_dir):
        raise ValueError("Working directory does not exist: %s" % raw.strip())
    return None if abs_dir == HOME_DIR else abs_dir


def valid_password(password):
    """Accept password-manager symbols; form fields cannot contain LF/CR."""
    return 16 <= len(password) <= 64 and not any(
        char in password for char in "\r\n"
    )


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


def gen_session_name(agent, sessions):
    """Auto-generate a unique session name from the agent CLI name.

    The first session for an agent gets the bare name ("claude"); a
    later one that would collide gets a short random suffix
    ("claude-a3f9") to stay unique yet readable. Users rarely care what
    a session is called (rename at runtime via /rename), so this spares
    them inventing one. `agent` is always one of AGENTS (or "shell"),
    so it already matches SESSION_RE.
    """
    if agent not in sessions:
        return agent
    for _ in range(1000):
        candidate = "%s-%s" % (agent, secrets.token_hex(2))
        if candidate not in sessions:
            return candidate
    # Astronomically unlikely fallback: a longer token can't be taken.
    return ("%s-%s" % (agent, secrets.token_hex(8)))[:32]


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


def update_service_state():
    """Read-only state of the box update oneshot, for the UI progress
    line. Returns None when self-update is off (no unit wired) or
    systemctl is unavailable (dev rigs) — the caller then omits the
    update block. `since` is the run's monotonic start time (usec since
    boot, 0 if it never ran): the page captures it before triggering
    and waits for a strictly newer value, which is stable even though
    the rebuild may restart this daemon (same boot). No privilege
    needed — `systemctl show` is a world-readable query."""
    if not UPDATE_UNIT or not SYSTEMCTL:
        return None
    try:
        proc = subprocess.run(
            [SYSTEMCTL, "show", UPDATE_UNIT, "--property",
             "ActiveState,Result,ExecMainStartTimestampMonotonic"],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    props = {}
    for line in proc.stdout.splitlines():
        key, _, value = line.partition("=")
        props[key] = value
    try:
        since = int(props.get("ExecMainStartTimestampMonotonic", "0") or "0")
    except ValueError:
        since = 0
    return {
        "active": props.get("ActiveState", ""),
        "result": props.get("Result", ""),
        "since": since,
    }


def session_counts():
    """How many configured sessions are currently live — the signal the
    page watches to confirm a 'Restart all' has bounced and recovered."""
    configured = [n for n in read_sessions() if SESSION_RE.match(n)]
    live = live_sessions()
    return {
        "configured": len(configured),
        "live": sum(1 for n in configured if n in live),
    }


def status_payload():
    """Compact JSON the settings page long-polls for restart/update
    progress. Never includes secret values or command output."""
    payload = {"rev": REV, "sessions": session_counts()}
    update = update_service_state()
    if update is not None:
        payload["update"] = update
    return payload


def change_password(previous, new):
    """Ask the root helper to verify and rotate the web credentials.

    Return 0 on success, 2 for a wrong current password, and another
    nonzero value for an operational failure. Passwords cross sudo on
    stdin only; neither argv, the environment nor the journal sees them.
    """
    try:
        proc = subprocess.run(
            PASSWORD_CMD.split(),
            input=json.dumps({"previous": previous, "new": new}),
            text=True,
            check=False,
            capture_output=True,
        )
        sys.stderr.write("change_password: helper rc=%d\n" % proc.returncode)
        return proc.returncode
    except OSError as exc:
        sys.stderr.write("change_password: %s\n" % exc)
        return 5


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
  @@include:settings.css@@
</style>
"""

# The session manager <section> on the settings page (every user,
# including the primary one — the HOME root page is the tabbed
# terminal workspace, not a manager). {action_base} is SESS_BASE, so
# the forms post to wherever the session routes actually live; the
# hidden back=settings field makes their redirects land back here
# rather than on SESS_PAGE (issue #119).
SESSIONS_SECTION_TPL = """<section>
    <div class="sec-head">
      <h2>Sessions</h2>
      <button type="button" class="btn" data-toggle="session-editor">Add session</button>
    </div>
    <p class="note">Each session is one agent CLI in its own terminal
    tab. New sessions start within a few seconds &mdash; no rebuild,
    no sudo. Click a session to open its terminal.</p>
    <div id="session-editor" class="editor">
      <form method="post" action="{action_base}/sessions/add">
        <input type="hidden" name="back" value="settings">
        <div class="row">
          <input type="text" name="name" placeholder="name (optional — auto from agent)"
                 pattern="[A-Za-z0-9_-]+"
                 title="Optional. Letters, digits, dash and underscore; blank auto-names from the agent">
          <select name="agent">{agents}</select>
          <span class="combo">
            <input type="text" name="cwd" value="~" class="cwd"
                   placeholder="~" autocomplete="off" autocapitalize="off"
                   autocorrect="off" spellcheck="false"
                   data-dir-input data-dir-base="{action_base}"
                   aria-label="Working directory" aria-autocomplete="list"
                   title="Working directory (starts in your home directory)">
            <ul class="ac" hidden></ul>
          </span>
          <button type="submit" class="btn">Add session</button>
        </div>
        <p class="note">Working directory &mdash; where the agent
        starts. Defaults to your home directory (<code>~</code>); type
        to browse folders one level at a time.</p>
      </form>
    </div>
    <div id="sessions-list">{sessions}</div>
  </section>"""

# Root page (HOME mode): a tabbed terminal workspace (issue #119) —
# one tab per session, the active one shown in an iframe onto the
# existing per-session ttyd URL (/<user>/?arg=<session>; same origin,
# so the auth cookie and its WebSocket upgrade work unchanged). Tabs
# are plain ?tab= links so the page works without JS (each click
# re-renders with the other terminal); SCRIPT upgrades that to
# client-side switching with background tabs kept attached. Session
# CRUD beyond "add" lives on the settings page.
HOME_BODY = """<body class="ws">
<nav class="tabs" id="tab-bar" aria-label="Sessions" data-term-base="{term_base}">
  {tabs}
  <button type="button" class="btn add" data-toggle="session-editor"
          title="New session" aria-label="New session">+</button>
  <span class="spacer"></span>
  <a class="gear" href="{base}/" title="Settings" aria-label="Settings">&#9881;</a>
</nav>
<div id="session-editor" class="editor">
  <form method="post" action="{action_base}/sessions/add">
    <div class="row">
      <input type="text" name="name" placeholder="name (optional — auto from agent)"
             pattern="[A-Za-z0-9_-]+"
             title="Optional. Letters, digits, dash and underscore; blank auto-names from the agent">
      <select name="agent">{agents}</select>
      <span class="combo">
        <input type="text" name="cwd" value="~" class="cwd"
               placeholder="~" autocomplete="off" autocapitalize="off"
               autocorrect="off" spellcheck="false"
               data-dir-input data-dir-base="{action_base}"
               aria-label="Working directory" aria-autocomplete="list"
               title="Working directory (starts in your home directory)">
        <ul class="ac" hidden></ul>
      </span>
      <button type="submit" class="btn">Add session</button>
    </div>
    <p class="note">Working directory &mdash; where the agent starts.
    Defaults to your home directory (<code>~</code>); type to browse
    folders one level at a time.</p>
  </form>
</div>
<div id="msg-slot">{message}</div>
<div class="panes" id="panes">{pane}</div>
</body>
</html>
"""

BODY = """<main>
  <a class="repo" href="https://github.com/defangdevs/agent-box" title="agent-box on GitHub" aria-label="agent-box on GitHub">
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38
      0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52
      -.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2
      -3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21
      2.2.82A7.65 7.65 0 0 1 8 3.86c.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82
      2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75
      -3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01
      8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z"/>
    </svg>
    GitHub
  </a>
  <a class="back" href="/">&larr; terminal</a>
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
  {password_section}
  <section>
    <h2>Danger zone</h2>
    <ul class="tbl danger">
      <li>
        <span class="dz"><strong>Restart all sessions</strong>
        <span class="note">Restarts the whole agent service: every
        session comes back with the current secrets and token files.
        Live sessions are killed &mdash; unsaved in-flight work is lost.
        <span id="restart-status" class="update-state" aria-live="polite"></span></span></span>
        <form method="post" action="{base}/restart" data-poll="restart"
              data-status="{base}/status"
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

PASSWORD_SECTION = """<section>
    <div class="sec-head">
      <h2>Account</h2>
      <button type="button" class="btn" data-toggle="password-editor">Change password</button>
    </div>
    <p class="note">Change the password used to sign in to this browser
    terminal. All signed-in browsers will be logged out.</p>
    <div id="password-editor" class="editor">
      <form method="post" action="{base}/password" data-native>
        <div class="fields">
          <label class="field">Current password
            <input type="password" name="previous_password"
                   autocomplete="current-password" required>
          </label>
          <label class="field">New password
            <input type="password" name="new_password"
                   autocomplete="new-password" minlength="16" maxlength="64" required>
          </label>
          <label class="field">Confirm new password
            <input type="password" name="confirm_password"
                   autocomplete="new-password" minlength="16" maxlength="64" required>
          </label>
          <p class="note">Use 16&ndash;64 characters. Symbols generated
          by password managers are supported.</p>
          <div><button type="submit" class="btn">Update password</button></div>
        </div>
      </form>
    </div>
  </section>"""

UPDATE_ROW = """<li>
        <span class="dz"><strong>Update box</strong>
        <span class="note">Fetches the latest agent-box release and agent
        CLI versions, then rebuilds the system. Takes a few minutes; sessions
        restart if their software changed.{update_line}</span></span>
        <form method="post" action="{base}/update" data-poll="update"
              data-status="{base}/status"
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
@@include:settings.js@@
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


def display_cwd(value):
    """Compact working-directory label for a session row: "~" for the
    default (stored None), and an absolute path is shown home-relative
    (~/foo) when it sits under HOME."""
    if not value:
        return "~"
    if value == HOME_DIR:
        return "~"
    if value.startswith(HOME_DIR + os.sep):
        return "~/" + value[len(HOME_DIR) + 1:]
    return value


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
            cwd = html.escape(display_cwd(entries[name].get("workingDirectory")))
            state = "live" if name in live else "starting"
            items.append(
                # The name deep-links into the terminal via ttyd's
                # ?arg= session selector. No userinfo in the href
                # (issue 56). SESSION_RE names are URL-safe as-is.
                f'<li><span class="nm">'
                f'<a class="sess" href="/{user}/?arg={safe}"><code>{safe}</code></a>'
                f'<span class="meta">{agent}</span>'
                f'<span class="meta" title="Working directory"><code>{cwd}</code></span>'
                f'<span class="state" data-state="{state}">{state}</span></span>'
                f'<span class="acts">'
                f'<form class="inline" method="post" action="{base}/sessions/restart" '
                f'onsubmit="return confirm(\'Restart {safe}? Unsaved in-flight work is lost.\');">'
                f'<input type="hidden" name="name" value="{safe}">'
                f'<input type="hidden" name="back" value="settings">'
                f'<button type="submit" class="btn small">Restart</button></form>'
                f'<form class="inline" method="post" action="{base}/sessions/delete" '
                f'onsubmit="return confirm(\'Delete session {safe}? Its live agent is killed.\');">'
                f'<input type="hidden" name="name" value="{safe}">'
                f'<input type="hidden" name="back" value="settings">'
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


def render_update_line():
    """Running rev plus a progressively enhanced GitHub update status.

    REV is a full git sha; the label shows the usual short form. Empty
    when the module didn't pass a rev (selfUpdate off — but then the
    whole Update card is hidden anyway). Without JavaScript, the user
    still gets a direct GitHub comparison link.
    """
    if not REV:
        return ""
    label = f"<code>{html.escape(REV[:12])}</code>"
    if REPO:
        url = html.escape(f"https://github.com/{REPO}/commit/{REV}")
        label = f'<a href="{url}">{label}</a>'
    line = " Currently at " + label + "."
    if not REPO:
        return line
    repo = html.escape(REPO)
    rev = html.escape(REV)
    compare_url = html.escape(f"https://github.com/{REPO}/compare/{REV}...HEAD")
    return (
        line
        + f' <span id="update-status" class="update-state" aria-live="polite" '
          f'data-repo="{repo}" data-rev="{rev}" data-compare-url="{compare_url}">'
          f'<a href="{compare_url}">Check GitHub for changes</a>.</span>'
    )


def render_sessions_section():
    return SESSIONS_SECTION_TPL.format(
        action_base=html.escape(SESS_BASE),
        agents=render_agent_options(),
        sessions=render_sessions(),
    )


def render_tabs(names, live, selected):
    """The workspace tab bar. File order, not sorted: sessions.json
    preserves insertion order, so a new session appears as the
    rightmost tab, like any terminal app. The dot-only .state span
    reuses the list styling (its ::before is the dot)."""
    items = []
    for name in names:
        safe = html.escape(name)
        cur = ' aria-current="page"' if name == selected else ""
        state = "live" if name in live else "starting"
        items.append(
            f'<a class="tab" data-tab="{safe}" href="/?tab={safe}"{cur}>'
            f'<span class="state" data-state="{state}"></span>{safe}</a>'
        )
    if not items:
        items.append('<span class="tab-empty">No sessions yet.</span>')
    return "".join(items)


def render_pane(selected, live):
    """The server-rendered pane: only the SELECTED session, and only
    when its tmux session is already live — the ttyd attach wrapper
    greets a not-yet-started session with an error and exits, so a
    starting session gets a placeholder instead (SCRIPT swaps in the
    iframe once the state flips; without JS, reloading does)."""
    if selected is None:
        return '<div class="pane placeholder active">No session selected.</div>'
    safe = html.escape(selected)
    if selected not in live:
        return (f'<div class="pane placeholder active" data-pane="{safe}">'
                f'{safe} is starting&hellip; reload in a few seconds.</div>')
    user = urllib.parse.quote(USER, safe="")
    # SESSION_RE names are URL-safe as-is.
    return (f'<iframe class="pane active" data-pane="{safe}" '
            f'src="/{user}/?arg={safe}" title="{safe} terminal" '
            f'allow="clipboard-read; clipboard-write"></iframe>')


def render_page(message=""):
    msg_html = f'<div class="msg">{html.escape(message)}</div>' if message else ""
    return (
        HEAD_TPL.format(title="Settings &mdash; " + html.escape(USER))
        + STYLE
        + BODY.format(
            user=html.escape(USER),
            base=html.escape(BASE),
            keys=render_keys(read_keys()),
            # Every user, primary included: the HOME root page is the
            # terminal workspace, so session CRUD lives here.
            sessions_section=render_sessions_section(),
            message=msg_html,
            password_section=(
                PASSWORD_SECTION.format(base=html.escape(BASE))
                if PASSWORD_CMD else ""
            ),
            update_row=(
                UPDATE_ROW.format(base=html.escape(BASE), update_line=render_update_line())
                if UPDATE_CMD else ""
            ),
        )
        + SCRIPT
    )


def render_home(message="", selected=None):
    entries = {n: v for n, v in read_sessions().items() if SESSION_RE.match(n)}
    names = list(entries)
    if selected not in entries:
        selected = "main" if "main" in entries else (names[0] if names else None)
    live = live_sessions()
    msg_html = f'<div class="msg">{html.escape(message)}</div>' if message else ""
    return (
        HEAD_TPL.format(title="Agent Box &mdash; " + html.escape(USER))
        + STYLE
        + HOME_BODY.format(
            base=html.escape(BASE),
            action_base=html.escape(SESS_BASE),
            term_base="/%s/" % urllib.parse.quote(USER, safe=""),
            tabs=render_tabs(names, live, selected),
            pane=render_pane(selected, live),
            agents=render_agent_options(),
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

    def _send_json(self, obj, status=200):
        data = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
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
        "password_changed": "Password changed. Sign in with your new password.",
    }

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        # Working-directory autocomplete (issue #131): the add-session
        # form asks the daemon to list one directory level at a time,
        # so the browser never sees the filesystem — only the confined
        # child names for the level being typed. GET-only, read-only,
        # no state change (so no CSRF concern); auth is Caddy's job for
        # the whole vhost. Handled before the BASE routing below since
        # in HOME mode SESS_BASE is "" and this path is not under BASE.
        if parsed.path.rstrip("/") == SESS_BASE + "/sessions/dirs":
            abs_dir = resolve_browse_dir(params.get("path", [""])[0])
            if abs_dir is None:
                self._send_json({"ok": False, "dirs": []})
            else:
                self._send_json({"ok": True, "dirs": list_subdirs(abs_dir)})
            return
        message = ""
        if "ok" in params:
            message = self.OK_MESSAGES.get(params["ok"][0], "")
        if HOME and parsed.path == "/":
            # ?tab=<session> selects the rendered tab (also the no-JS
            # switching mechanism); anything invalid falls back to the
            # default selection inside render_home.
            tab = (params.get("tab", [""])[0]).strip()
            self._send_html(render_home(message, tab if SESSION_RE.match(tab) else None))
            return
        if not self._under_base(parsed.path):
            self._send_html("<h1>404</h1>", status=404)
            return
        # Progress feed the page long-polls after a restart/update
        # (read-only, same auth block as the page it lives under).
        if parsed.path.rstrip("/") == BASE + "/status":
            self._send_json(status_payload())
            return
        self._send_html(render_page(message))

    def _read_form(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length).decode("utf-8") if length else ""
        return urllib.parse.parse_qs(raw)

    def _same_origin(self):
        """Reject cross-site state-changing POSTs (issue #117).

        Every POST route here mutates state (secrets, sessions, the
        box update). Auth alone does not stop CSRF: the __Host- cookie
        is SameSite=Strict, but the basic-auth fallback has no SameSite
        equivalent, and browsers reattach cached basic credentials to
        cross-site requests — so a lured, basic-authenticated operator
        could be forced to e.g. inject a GH_TOKEN via /set.

        Browsers always send Sec-Fetch-Site; a genuine form post from
        our own page is "same-origin". Anything a browser labels
        cross-site or same-site (sibling *.sslip.io hosts are
        same-site but different owners) is refused. Older browsers
        that omit Sec-Fetch-Site still send Origin, which we compare
        against the target Host (Caddy forwards both unchanged). A
        request with neither header is not a browser navigation and
        carries no ambient victim credentials (curl, the e2e harness),
        so it is allowed."""
        site = self.headers.get("Sec-Fetch-Site")
        if site is not None:
            return site == "same-origin"
        origin = self.headers.get("Origin")
        if origin:
            host = self.headers.get("Host", "")
            return origin in ("https://" + host, "http://" + host)
        return True

    def _sess_page(self, form):
        """Where a /sessions/* POST redirects back to: the settings
        page when the form carried back=settings (the session manager
        section lives there for every user now), else SESS_PAGE (the
        HOME workspace's own add form)."""
        back = form.get("back", [""])[0]
        return BASE + "/" if back == "settings" else SESS_PAGE

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/")
        if not self._same_origin():
            self._send_html(
                "<h1>403</h1><p>Cross-site request blocked.</p>",
                status=403,
            )
            return
        form = self._read_form()
        if path == BASE + "/password" and PASSWORD_CMD:
            previous = form.get("previous_password", [""])[0]
            new = form.get("new_password", [""])[0]
            confirm = form.get("confirm_password", [""])[0]
            if new != confirm:
                self._send_html(
                    render_page("New password and confirmation do not match."),
                    status=400,
                )
                return
            if not valid_password(new):
                self._send_html(
                    render_page("New password must be 16–64 characters and "
                                "cannot contain a line break."),
                    status=400,
                )
                return
            if new == previous:
                self._send_html(
                    render_page("New password must differ from the current password."),
                    status=400,
                )
                return
            result = change_password(previous, new)
            if result == 2:
                self._send_html(
                    render_page("Current password is incorrect."), status=403
                )
                return
            if result != 0:
                self._send_html(
                    render_page("Could not update the password. Try again or "
                                "check the settings service journal."),
                    status=500,
                )
                return
            self._redirect("ok=password_changed")
        elif path == BASE + "/set":
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
            back_page = self._sess_page(form)
            # Error pages re-render the page the form came from.
            render = render_home if (HOME and back_page == SESS_PAGE) else render_page
            name = (form.get("name", [""])[0]).strip()
            agent = (form.get("agent", [""])[0]).strip() or DEFAULT_AGENT
            if agent not in AGENTS:
                self._send_html(
                    render("Unknown agent. Available: " + ", ".join(AGENTS)),
                    status=400,
                )
                return
            if name and not SESSION_RE.match(name):
                self._send_html(
                    render("Invalid session name. Use letters, digits, "
                           "dash and underscore (max 32 chars)."),
                    status=400,
                )
                return
            # Working directory (issue #131): the field defaults to
            # "~" (home); resolve_session_cwd stores that as None (the
            # supervisor's default) and any other path as an absolute
            # directory it has confirmed exists inside HOME.
            try:
                cwd = resolve_session_cwd(form.get("cwd", [""])[0])
            except ValueError as exc:
                self._send_html(render(str(exc)), status=400)
                return
            sessions = read_sessions()
            # Blank name → derive one from the agent (issue: autogen names).
            if not name:
                name = gen_session_name(agent, sessions)
            if name in sessions:
                # Silently overwriting would reset the stored config
                # (agent, cwd, extraArgs) to defaults — issue 100.
                self._send_html(
                    render("Session '%s' already exists. Delete it "
                           "first, or use Restart to bounce it." % name),
                    status=409,
                )
                return
            sessions[name] = {
                "agent": agent,
                "skipPermissions": True,
                "remoteControl": True,
                "remoteControlName": None,
                "workingDirectory": cwd,
                "extraArgs": [],
            }
            write_sessions(sessions)
            # On the workspace, land on the new session's tab (name is
            # SESSION_RE-validated, so URL-safe as-is).
            query = "ok=session_added"
            if HOME and back_page == SESS_PAGE:
                query += "&tab=" + name
            self._redirect(query, back_page)
        elif path == SESS_BASE + "/sessions/delete":
            name = (form.get("name", [""])[0]).strip()
            if SESSION_RE.match(name):
                sessions = read_sessions()
                sessions.pop(name, None)
                write_sessions(sessions)
                kill_session(name)
            self._redirect("ok=session_deleted", self._sess_page(form))
        elif path == SESS_BASE + "/sessions/restart":
            name = (form.get("name", [""])[0]).strip()
            if SESSION_RE.match(name):
                kill_session(name)
            self._redirect("ok=session_restarted", self._sess_page(form))
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
