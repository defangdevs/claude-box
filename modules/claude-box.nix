# CONTRACT: this module must remain a SINGLE self-contained file. Deployed
# boxes fetch exactly this one file and import it from a bare store path —
# aws/template.yaml's user-data and claude-box-update.service both
# `builtins.fetchurl` .../modules/claude-box.nix and pin one sha256. Any
# `./sibling` reference (readFile, import, path interpolation) evaluates
# against the lone store file, fails first-boot amazon-init *silently*
# (journal-only), and bricks self-update on every already-deployed box
# (issue #51). The `module-single-file` flake check enforces this in CI.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.claude-box;
  supportedAgents = [ "claude" "codex" ];
  tmuxSocketName = "agent-box";
  runtimeDirectory = name: "agent-box-${name}";
  # ttyd port base; ports are assigned in sorted user-name order (see
  # terminalUsers below).
  ttydPortBase = 7681;
  # The settings daemon listens on a per-user UNIX socket, not localhost TCP:
  # a 127.0.0.1 port is reachable by EVERY local user (issue #49 — on a
  # multi-agent box, codex could rewrite claude's keys and restart claude's
  # agent). systemd creates each socket 0660 <user>:caddy, so only that user
  # and the caddy reverse-proxy can connect.
  settingsSocketDir = "/run/claude-box-settings";
  settingsSocketOf = name: "${settingsSocketDir}/${name}.sock";
  # The per-user secrets file the settings page (issue #36) manages. User-
  # owned, 0600, loaded (optionally) by the agent unit's EnvironmentFile.
  userEnvFile = name: "/home/${name}/.config/claude-box/env";

  # Reload command is granted when web is enabled so the agent can add a
  # virtual host and reload without root — pooled with the user-supplied
  # sudoAllowlist so NoNewPrivileges + sudo rules see the same list.
  caddyReloadCmd = "/run/current-system/sw/bin/systemctl reload caddy.service";
  updateStartCmd = "/run/current-system/sw/bin/systemctl start claude-box-update.service";
  # --no-block variant for the settings page's Update button: the daemon must
  # answer the HTTP request before the rebuild (possibly) restarts the daemon
  # itself. A separate literal because sudoers matches argv exactly.
  updateStartNoBlockCmd = "/run/current-system/sw/bin/systemctl start --no-block claude-box-update.service";
  effectiveSudoAllowlist =
    cfg.sudoAllowlist
    ++ lib.optional cfg.web.enable caddyReloadCmd
    ++ lib.optionals cfg.selfUpdate.enable [ updateStartCmd updateStartNoBlockCmd ];
  # Agent CLIs (claude-code, codex) move much faster than any host channel.
  # When the host wires selfUpdate.agentNixpkgs (from the pin file the update
  # service maintains — see that option), resolve just the agent packages from
  # that pinned nixos-unstable snapshot; the rest of the system stays on the
  # host nixpkgs. Hydra builds unstable, so this is a binary substitution, not
  # a local compile. Null (fresh box, or wiring absent) falls back to host
  # pkgs, so eval never breaks.
  agentPkgs =
    if cfg.selfUpdate.agentNixpkgs != null then
      import (builtins.fetchTarball {
        url = cfg.selfUpdate.agentNixpkgs.url;
        sha256 = cfg.selfUpdate.agentNixpkgs.sha256;
      }) {
        system = pkgs.stdenv.hostPlatform.system;
        # The host's allowUnfreePredicate does not reach a second nixpkgs
        # import; allow exactly the bundled agent packages (mirrors the
        # host-side default set below).
        config.allowUnfreePredicate = pkg:
          builtins.elem (lib.getName pkg) [ "claude-code" "codex" ];
      }
    else pkgs;
  agentPackage = agent:
    if cfg.package != null then cfg.package
    else if agent == "claude" then agentPkgs.claude-code
    else agentPkgs.codex;
  installedAgentPackages = map agentPackage cfg.installAgents;
  # Sessions are RUNTIME data (issue #59): the Nix-declared
  # users.<name>.sessions (or the legacy per-user agent/… options, which
  # stand in for a single session named "main") only SEED
  # ~/.config/claude-box/sessions.json on first boot. Afterwards the file is
  # authoritative and sessions are created/destroyed WITHOUT a rebuild —
  # via the claude-box-session CLI or the settings page. The supervisor
  # (mkStart) reconciles tmux sessions against the file and builds each
  # agent command at runtime, so per-agent flag logic lives in that script.
  seedSessions = name: u:
    if u.sessions != { } then u.sessions
    else {
      main = {
        inherit (u) agent skipPermissions remoteControl remoteControlName extraArgs;
        inherit (u) workingDirectory;
      };
    };
  sessionsSeedFile = name: u:
    pkgs.writeText "claude-box-${name}-sessions.json" (builtins.toJSON {
      version = 1;
      sessions = lib.mapAttrs (sname: s: {
        agent = if s.agent != null then s.agent else cfg.agent;
        inherit (s) skipPermissions remoteControl extraArgs;
        # null → the supervisor derives "<user>@<fqdn>" (main) or
        # "<user>-<session>@<fqdn>" at start time.
        remoteControlName = s.remoteControlName;
        workingDirectory =
          if s.workingDirectory != null then s.workingDirectory
          else "/home/${name}";
      }) (seedSessions name u);
    });
  userSessionsFile = name: "/home/${name}/.config/claude-box/sessions.json";

  # Runtime session CRUD, shipped on every PATH. Runs as the calling agent
  # user: edits the user-owned sessions.json (the supervisor reconciles
  # within ~2s) and talks only to the user's own tmux server. No sudo, no
  # rebuild — the whole point of issue #59.
  sessionCli = pkgs.writeShellScriptBin "claude-box-session" ''
    set -eu
    JQ=${pkgs.jq}/bin/jq
    FILE="$HOME/.config/claude-box/sessions.json"
    AGENTS=${lib.escapeShellArg (lib.concatStringsSep " " cfg.installAgents)}
    DEFAULT_AGENT=${lib.escapeShellArg cfg.agent}
    export TMUX_TMPDIR="''${TMUX_TMPDIR:-/run/agent-box-$USER}"

    t() { ${pkgs.tmux}/bin/tmux -L ${tmuxSocketName} "$@"; }
    usage() {
      echo "usage: claude-box-session ls"
      echo "       claude-box-session add NAME [--agent AGENT] [--cwd DIR] [-- EXTRA_ARGS...]"
      echo "       claude-box-session rm NAME"
      echo "       claude-box-session restart NAME"
      echo "agents: $AGENTS (default: $DEFAULT_AGENT)"
      echo "Listed sessions are (re)started by the per-user supervisor within ~2s."
      echo "Attach: tmux -L ${tmuxSocketName} attach -t NAME, or the browser terminal /<user>/?arg=NAME"
    }
    valid_name() {
      case "$1" in (*[!A-Za-z0-9_-]*|"") return 1 ;; esac
    }
    ensure_file() {
      mkdir -p "$(dirname "$FILE")"
      [ -s "$FILE" ] || printf '{"version":1,"sessions":{}}\n' > "$FILE"
    }
    jq_edit() {
      # jq_edit JQ_ARGS... — atomically rewrite FILE through jq.
      tmp="$(mktemp "$FILE.XXXXXX")"
      if "$JQ" "$@" < "$FILE" > "$tmp"; then
        mv "$tmp" "$FILE"
      else
        rm -f "$tmp"
        exit 1
      fi
    }

    cmd="''${1:-}"; shift || true
    case "$cmd" in
      ls)
        live="$(t list-sessions -F '#S' 2>/dev/null || true)"
        printf '%-24s %-8s %s\n' NAME AGENT STATE
        if [ -s "$FILE" ]; then
          "$JQ" -r '.sessions | to_entries[] | [.key, (.value.agent // "?")] | @tsv' "$FILE" \
          | while IFS="$(printf '\t')" read -r n a; do
            state=starting
            printf '%s\n' "$live" | grep -qxF "$n" && state=live
            printf '%-24s %-8s %s\n' "$n" "$a" "$state"
          done
        fi
        # Live tmux sessions nobody listed (started by hand): show, don't hide.
        printf '%s\n' "$live" | while IFS= read -r n; do
          [ -n "$n" ] || continue
          if [ ! -s "$FILE" ] || ! "$JQ" -e --arg n "$n" '.sessions | has($n)' "$FILE" >/dev/null; then
            printf '%-24s %-8s %s\n' "$n" '-' 'unmanaged'
          fi
        done
        ;;
      add)
        name="''${1:-}"; shift || true
        valid_name "$name" || { usage >&2; exit 2; }
        agent="$DEFAULT_AGENT"; cwd=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --agent) agent="''${2:?--agent needs a value}"; shift 2 ;;
            --cwd) cwd="''${2:?--cwd needs a value}"; shift 2 ;;
            --) shift; break ;;
            *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
          esac
        done
        case " $AGENTS " in
          (*" $agent "*) ;;
          (*) echo "agent '$agent' is not installed (installed: $AGENTS)" >&2; exit 2 ;;
        esac
        ensure_file
        jq_edit --arg n "$name" --arg a "$agent" --arg c "$cwd" \
          '.sessions[$n] = {agent: $a, skipPermissions: true, remoteControl: true,
                            remoteControlName: null,
                            workingDirectory: (if $c == "" then null else $c end),
                            extraArgs: $ARGS.positional}' \
          --args "$@"
        echo "session '$name' ($agent) added — the supervisor starts it within ~2s"
        ;;
      rm)
        name="''${1:-}"
        valid_name "$name" || { usage >&2; exit 2; }
        ensure_file
        jq_edit --arg n "$name" 'del(.sessions[$n])'
        t kill-session -t "=$name" 2>/dev/null || true
        echo "session '$name' removed"
        ;;
      restart)
        name="''${1:-}"
        valid_name "$name" || { usage >&2; exit 2; }
        t kill-session -t "=$name"
        echo "session '$name' killed — the supervisor restarts it within ~2s if still listed"
        ;;
      *)
        usage >&2
        exit 2
        ;;
    esac
  '';

  # One session = one agent CLI in one tmux session. These options are the
  # FIRST-BOOT SEED only (see users.<name>.sessions); at runtime the same
  # fields live as JSON in ~/.config/claude-box/sessions.json.
  sessionOpts = {
    options = {
      agent = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum supportedAgents);
        default = null;
        description = ''
          Agent CLI this session runs. When null, uses
          services.claude-box.agent. Must be listed in
          services.claude-box.installAgents.
        '';
      };
      skipPermissions = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Pass the agent's autonomy flag (see users.<name>.skipPermissions).";
      };
      remoteControl = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Pass --remote-control (claude sessions only; see users.<name>.remoteControl).";
      };
      remoteControlName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Remote Control session name. When null, defaults to
          "<user>@<fqdnOrHostName>" for the session named "main" and
          "<user>-<session>@<fqdnOrHostName>" otherwise.
        '';
      };
      workingDirectory = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Directory the session's agent starts in. Null means the user's home.";
      };
      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra arguments appended to this session's agent invocation.";
      };
    };
  };

  userOpts = { name, ... }: {
    options = {
      sessions = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule sessionOpts);
        default = { };
        example = lib.literalExpression ''{ main = { }; review = { agent = "codex"; }; }'';
        description = ''
          Seed sessions for this user — each is an agent CLI running in its
          own tmux session under the user's single supervised service.
          Session names must match [A-Za-z0-9_-]+.

          Sessions are RUNTIME data: this option is written to
          ~/.config/claude-box/sessions.json ONLY when that file does not
          exist yet (first boot). Afterwards the file is authoritative, and
          sessions are added/removed/restarted without a rebuild via the
          claude-box-session CLI or the settings page. A later rebuild never
          clobbers runtime changes.

          When empty (the default), the per-user agent / skipPermissions /
          remoteControl* / workingDirectory / extraArgs options below seed a
          single session named "main" — the pre-sessions behaviour.
        '';
      };
      agent = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum supportedAgents);
        default = null;
        description = ''
          Agent CLI to run for this user's default "main" session. When
          null, uses services.claude-box.agent. Ignored when
          users.<name>.sessions is set (set the agent per session there).
        '';
      };
      skipPermissions = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Pass the selected agent's autonomy flag, i.e. the agent has full
          autonomy inside its shell with no in-tool approval prompts.
          Default is `true` because claude-box is designed to be a HEADLESS
          agent runner — no human sits at the prompt to answer questions.

          This is autonomy INSIDE the agent CLI, not an OS sandbox. The OS
          sandbox is the unprivileged user, the systemd hardening this
          module applies, and the tight sudoAllowlist. Set false if you
          want each tool invocation to block for approval (only sensible
          on a box with a human attached).
        '';
      };
      remoteControl = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Pass --remote-control so the session is drivable from the Claude
          desktop and mobile apps. Default `true` because "drive it from
          your phone" is one of the module's headline features.

          Set false to disable remote-app control for this user — then the
          agent is only reachable through the local tmux session (or the
          ttyd browser terminal in the AWS variant).

          Applies only to the claude agent. Codex remote/app-server wiring is
          separate future work; use extraArgs for explicit Codex flags.
        '';
      };
      remoteControlName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Remote Control session name, used to correlate the session to this box
          from the Claude apps. Keep it shell-safe (no spaces/quotes). When null,
          defaults to "<user>@<fqdnOrHostName>" (falls back to the bare hostname
          when networking.domain is unset).
        '';
      };
      workingDirectory = lib.mkOption {
        type = lib.types.str;
        default = "/home/${name}";
        description = "Directory the agent starts in.";
      };
      extraGroups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra groups for this agent user.";
      };
      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra arguments appended to the selected agent invocation.";
      };
      environmentFiles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = lib.literalExpression ''[ "/run/secrets/alice-tokens.env" ]'';
        description = ''
          Extra systemd EnvironmentFile paths for this agent (KEY=value lines,
          one per line). Read by systemd as root, so keep them outside the Nix
          store (mode 600, root-owned). Prefix a path with '-' to make it
          optional. These load in addition to the auto per-user token file.
        '';
      };
      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = lib.literalExpression ''{ TERM = "xterm-256color"; }'';
        description = "Extra (non-secret) environment variables for this agent's service. Merged over the default HOME.";
      };
      agentsMd = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = lib.literalExpression ''
          '''
            # claude-box
            Your terminal is at $CLAUDE_BOX_URL — `echo` it to print.
          '''
        '';
        description = ''
          Content seeded to <workingDirectory>/AGENTS.md on agent start,
          IFF that file does not already exist — so the agent's own
          edits or a repo checkout in workingDirectory never get
          clobbered. Null (default) writes nothing.

          AGENTS.md is the cross-vendor agent-instructions convention
          read natively by codex and opencode, and by claude-code as a
          fallback when CLAUDE.md is absent. The agent's systemd env
          exports CLAUDE_BOX_URL whenever this user has a browser
          terminal (see web.passwordHashFile), so an AGENTS.md that
          references that variable lets the agent answer "where am I
          reachable?" without hard-coding the URL.
        '';
      };
      web.passwordHashFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        example = "/var/lib/claude-box-web/password-hash-${name}";
        description = ''
          Give this user a browser terminal (requires
          services.claude-box.web.enable). Path to a file containing a bcrypt
          hash produced by `caddy hash-password`; the terminal is served at
          https://<web.domain>/${name}/ behind basic auth whose username is
          this linux user name and whose password is the one behind this
          hash. Root-owned, 0600, outside the Nix store so the plaintext
          never lands in a world-readable path. Null (the default) means no
          browser terminal for this user.

          Each terminal's ttyd gets a localhost port assigned in sorted
          user-name order starting at 7681. The top-level Caddyfile is
          module-managed, so adding/removing terminal users is a
          nixos-rebuild away — check the assigned ports with
          `systemctl cat claude-web-terminal-<user>`.
        '';
      };
    };
  };

  # The per-user SUPERVISOR (issue #59). One hardened unit per user; the tmux
  # server and every session — including ones added at runtime — are children
  # of this script, so they all inherit the unit's systemd sandboxing. The
  # loop is ensure-only: missing listed sessions are (re)created, but the
  # supervisor never kills. Destroy goes through the CRUD paths
  # (claude-box-session rm / settings page), which delist AND kill — so a
  # removed entry stays gone, and an ad-hoc `tmux new` session is left alone.
  mkStart = name: u:
    let
      home = "/home/${name}";
      fqdn = config.networking.fqdnOrHostName;
      agentBinCases = lib.concatMapStrings (a:
        "          ${a}) printf '%s\\n' ${lib.escapeShellArg (lib.getExe (agentPackage a))} ;;\n"
      ) cfg.installAgents;
      # AGENTS.md — cross-vendor agent-instructions file (codex, opencode
      # native; claude-code as CLAUDE.md fallback). Content lives in the Nix
      # store so no in-shell quoting; $CLAUDE_BOX_URL and other $refs in the
      # content stay literal for the agent to expand at read time. Seeded
      # per session in start_session below.
      agentsMdFile =
        if u.agentsMd == null then null
        else pkgs.writeText "claude-box-${name}-agents.md" u.agentsMd;
    in
    pkgs.writeShellScript "claude-box-${name}-start" ''
      set -u
      JQ=${pkgs.jq}/bin/jq
      TMUX="${pkgs.tmux}/bin/tmux -L ${tmuxSocketName}"
      SESSIONS_FILE=${lib.escapeShellArg (userSessionsFile name)}

      # First boot only: seed the Nix-declared sessions. The file is RUNTIME
      # data afterwards — a rebuild must never clobber sessions the user
      # added or removed while the box was live.
      mkdir -p ${home}/.config/claude-box
      if [ ! -s "$SESSIONS_FILE" ]; then
        install -m 0600 ${sessionsSeedFile name u} "$SESSIONS_FILE"
      fi

      seed_json() {
        # seed_json FILE JQ_ARGS... — jq-edit FILE in place, creating it
        # if missing. A file jq can't parse is left untouched: the dialog
        # comes back, but the agent still starts.
        file=$1; shift
        [ -s "$file" ] || printf '{}' > "$file"
        if $JQ "$@" "$file" > "$file.seed-tmp" 2>/dev/null; then
          mv "$file.seed-tmp" "$file"
        else
          rm -f "$file.seed-tmp"
        fi
      }

      # Pre-accept claude-code's one-time startup dialogs. A fresh home
      # otherwise parks the session on interactive prompts — the folder-trust
      # dialog ("Is this a project you trust?") and, when running with
      # --dangerously-skip-permissions, the Bypass Permissions warning (whose
      # default answer is "No, exit"). On a headless box nobody is at the
      # terminal to answer them, and Remote Control can't drive a session
      # that is stuck on a dialog, so the ONLY interactive step left should
      # be the one-time OAuth login. claude persists both acceptances in
      # per-user state files, which it round-trips (read-modify-write), so
      # values seeded before first launch survive login/onboarding:
      #   ~/.claude.json          projects.<workdir>.hasTrustDialogAccepted
      #   ~/.claude/settings.json skipDangerousModePermissionPrompt
      # Runs before every claude session start (idempotent), which also
      # covers upstream's occasional failure to persist an interactive
      # acceptance (anthropics/claude-code issue 36403). Codex has no such
      # dialogs. $1 = working directory, $2 = skipPermissions (true/false).
      seed_claude_state() {
        mkdir -p ${home}/.claude
        seed_json ${home}/.claude.json --arg wd "$1" \
          '.projects[$wd] = ((.projects[$wd] // {}) + {hasTrustDialogAccepted: true, hasCompletedProjectOnboarding: true})'
        if [ "$2" = true ]; then
          seed_json ${home}/.claude/settings.json \
            '.skipDangerousModePermissionPrompt = true'
        fi
      }

      agent_bin() {
        case "$1" in
${agentBinCases}          *) return 1 ;;
        esac
      }

      start_session() {
        sname=$1
        sjson="$($JQ -c --arg s "$sname" '.sessions[$s] // empty' "$SESSIONS_FILE")" || return 0
        [ -n "$sjson" ] || return 0
        agent="$($JQ -r '.agent // empty' <<<"$sjson")"
        if ! bin="$(agent_bin "$agent")"; then
          echo "session '$sname': agent '$agent' is not installed (see installAgents) — skipping" >&2
          return 0
        fi
        wd="$($JQ -r '.workingDirectory // empty' <<<"$sjson")"
        [ -n "$wd" ] || wd=${home}
        skip="$($JQ -r 'if .skipPermissions == false then "false" else "true" end' <<<"$sjson")"
        rc="$($JQ -r 'if .remoteControl == false then "false" else "true" end' <<<"$sjson")"
        rcname="$($JQ -r '.remoteControlName // empty' <<<"$sjson")"
        # Build the command with printf %q so runtime-provided fields
        # (extraArgs, remoteControlName, cwd) can't inject into the tmux
        # command line — the runtime equivalent of lib.escapeShellArg.
        cmd="$(printf '%q' "$bin")"
        if [ "$skip" = true ]; then
          case "$agent" in
            claude) cmd="$cmd --dangerously-skip-permissions" ;;
            codex) cmd="$cmd --dangerously-bypass-approvals-and-sandbox" ;;
          esac
        fi
        if [ "$agent" = claude ] && [ "$rc" = true ]; then
          if [ -z "$rcname" ]; then
            rcname="${name}@${fqdn}"
            [ "$sname" = main ] || rcname="${name}-$sname@${fqdn}"
          fi
          cmd="$cmd --remote-control $(printf '%q' "$rcname")"
        fi
        while IFS= read -r xarg; do
          cmd="$cmd $(printf '%q' "$xarg")"
        done < <($JQ -r '.extraArgs // [] | .[]' <<<"$sjson")
        if [ "$agent" = claude ]; then
          # Upstream claude-code bug: the client persists only
          # channelsEnabled to ~/.claude/remote-settings.json, losing the
          # org's channel-plugin allowlist; the next launch trusts the stale
          # cache and silently drops every channel notification. Clearing
          # the cache before each claude launch forces a full policy fetch.
          rm -f ${home}/.claude/remote-settings.json
          seed_claude_state "$wd" "$skip"
        fi
${lib.optionalString (agentsMdFile != null) ''
        # Seed AGENTS.md into the session's working directory IFF absent, so
        # the agent's own edits or a repo checkout there never get clobbered.
        if [ ! -e "$wd/AGENTS.md" ]; then
          mkdir -p "$wd"
          install -m 0644 ${agentsMdFile} "$wd/AGENTS.md"
        fi
''}        # `|| exec bash` gives a POST-MORTEM shell ONLY on non-zero agent
        # exit — the dead session stays attachable for inspection and is NOT
        # respawned over. A clean exit lets the session die; the reconcile
        # loop below then starts a fresh agent within ~2s.
        $TMUX new-session -d -s "$sname" -c "$wd" \
          "$cmd || exec ${pkgs.bashInteractive}/bin/bash"
      }

      # Reconcile forever; systemd stop tears the whole tree down (ExecStop
      # kill-server + cgroup kill), Restart=always revives a crashed loop.
      while true; do
        while IFS= read -r sname; do
          case "$sname" in
            (*[!A-Za-z0-9_-]*|"") continue ;;
          esac
          $TMUX has-session -t "=$sname" 2>/dev/null || start_session "$sname"
        done < <($JQ -r '.sessions | keys[]' "$SESSIONS_FILE" 2>/dev/null)
        sleep 2
      done
    '';
in
{
  options.services.claude-box = {
    enable = lib.mkEnableOption "reproducible multi-user coding agent host";

    agent = lib.mkOption {
      type = lib.types.enum supportedAgents;
      default = "claude";
      description = "Default agent CLI to run. Supported values: claude, codex.";
    };

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      defaultText = lib.literalExpression ''null (pkgs.claude-code for agent = "claude"; pkgs.codex for agent = "codex")'';
      description = "Package to run for every agent user. Leave null to use the selected agent's default package.";
    };

    installAgents = lib.mkOption {
      type = lib.types.listOf (lib.types.enum supportedAgents);
      default = supportedAgents;
      description = ''
        Agent CLIs installed on the box — system PATH and every agent unit's
        PATH — independently of what any session currently runs, so a
        runtime `claude-box-session add --agent codex` needs no rebuild.
        Sessions may only use agents listed here. Default: all supported
        agents.
      '';
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule userOpts);
      default = { };
      example = lib.literalExpression ''{ alice = { }; bob = { remoteControlName = "bob-box"; }; }'';
      description = "Agent users to provision. Each gets an unprivileged account and its own tmux-backed agent service.";
    };

    sudoAllowlist = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = lib.literalExpression ''[ "/run/current-system/sw/bin/systemctl reload caddy.service" ]'';
      description = ''
        Passwordless sudo commands granted to every agent user. This is the ONLY
        elevated power the agents get — keep it a tight, explicit allowlist rather
        than blanket root.
      '';
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "with pkgs; [ git ripgrep jq ]";
      description = "Extra packages placed on each agent's PATH.";
    };

    environmentFiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra systemd EnvironmentFile paths applied to every agent (see per-user environmentFiles).";
    };

    tokenDir = lib.mkOption {
      type = lib.types.str;
      default = "/etc/claude-box";
      description = ''
        Directory holding optional per-agent token files. Each agent
        auto-loads <tokenDir>/<user>.env if it exists — so adding a token like
        GH_TOKEN is just: drop a KEY=value line into that file (mode 600), no
        rebuild required.
      '';
    };

    manageTokenDir = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Create tokenDir (root-owned) via tmpfiles so token files can be dropped in.";
    };

    protectMemory = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Guard the box against agent-driven memory exhaustion: compressed
        zram swap, earlyoom as an OOM backstop, and a raised OOMScoreAdjust
        on the agent units so the kernel and earlyoom sacrifice agent work
        before sshd/caddy/the SSM agent. A small swapless box under memory
        pressure never OOM-kills — reclaim keeps "succeeding" by evicting
        clean page-cache pages (including running programs' own code),
        which immediately refault from disk, and the whole userspace
        livelocks (issue 62). Every knob below is set with mkDefault, so
        hosts can tune individual pieces — e.g. add disk swap on top via
        the standard swapDevices option.
      '';
    };

    web = {
      enable = lib.mkEnableOption ''
        browser terminals (one ttyd per user with web.passwordHashFile set)
        fronted by Caddy with basic-auth-to-cookie web auth — the basic-auth
        username is the linux user name, so logging in picks the terminal.
        An unauthenticated picker page at / lists them. The top-level
        Caddyfile is module-managed (regenerated every rebuild); each agent
        user's own virtual hosts live in ~/sites/*.caddy (a symlink to
        /var/lib/claude-box-sites/<user>/, which caddy can read) and land
        with `sudo systemctl reload caddy.service`
      '';

      domain = lib.mkOption {
        type = lib.types.str;
        example = "1-2-3-4.sslip.io";
        description = ''
          Public hostname for the browser terminal. Used to seed
          /var/lib/caddy/Caddyfile the first time only — subsequent edits are
          preserved. Set this to whatever DNS name resolves to the host
          (sslip.io on AWS, a custom domain on bare metal, etc).
        '';
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "agent";
        description = ''
          Which services.claude-box.users entry administers Caddy: it is
          added to the caddy group (so it can edit /var/lib/caddy/Caddyfile)
          and granted passwordless sudo for `systemctl reload caddy.service`.
          Which users get a browser terminal is separate — set
          users.<name>.web.passwordHashFile per user.
        '';
      };

      fail2ban = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Ban IPs that repeatedly fail the browser terminal's basic auth
          (fail2ban jail watching Caddy's access log in the journal). Only
          counts requests that actually carried credentials, so the 401 a
          browser gets before showing the login prompt doesn't score against
          visitors. The module-managed Caddyfile includes the `log` directive
          the jail needs; per-user snippet files under ~/sites/ share the
          same journal stream if they include `log` too. Whitelist trusted
          networks with services.fail2ban.ignoreIP. Also brings fail2ban's
          default sshd jail along.
        '';
      };
    };

    selfUpdate = {
      enable = lib.mkEnableOption ''
        an agent-triggerable self-update service. When enabled, every agent
        user's sudo allowlist gains exactly
        `systemctl start claude-box-update.service` (plus its --no-block
        variant, used by the settings page's Update button) — a root oneshot
        that fast-forwards the box to the upstream repo's latest
        default-branch commit by rewriting `pinFile` (and, when agentNixpkgs
        is wired, advances `agentPinFile` to the latest nixos-unstable
        channel release so agent CLIs stay fresh) and running
        `nixos-rebuild switch`.
        The privilege boundary is trigger-only: no arguments, environment or
        paths cross sudo; the update source and logic are fixed in the unit.
        NOTE: the rebuild restarts agent services, so running sessions die —
        agents should save their working context before triggering it.
        Release signature verification is future work (tracked upstream);
        until then the updater trusts the pinned GitHub repo as published,
        hash-pinning only what it fetched
      '';

      repo = lib.mkOption {
        type = lib.types.str;
        default = "defangdevs/claude-box";
        description = "GitHub owner/repo the update service pulls from.";
      };

      rev = lib.mkOption {
        type = lib.types.str;
        example = "0f96eebfda54d9e7cc90cdda9a5b30f04b95c1df";
        description = ''
          Git rev of `repo` this configuration was built from — wire it to
          the same value that pins the module fetch (see pinFile). Used as
          the ancestry baseline: the updater refuses any target that is not
          strictly ahead of this rev, so history rewrites and replays of
          older (possibly vulnerable) revisions don't apply.
        '';
      };

      pinFile = lib.mkOption {
        type = lib.types.str;
        default = "/etc/nixos/claude-box-pin.nix";
        description = ''
          File the updater atomically rewrites with
          `{ rev = "..."; sha256 = "..."; }`. The host configuration must
          import the module at exactly this pin when the file exists (see
          aws/template.yaml for the reference wiring); otherwise the update
          rebuilds against a stale module and silently no-ops.
        '';
      };

      agentNixpkgs = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            url = lib.mkOption {
              type = lib.types.str;
              example = "https://releases.nixos.org/nixos/unstable/nixos-25.11pre850000.abcdef123456/nixexprs.tar.xz";
              description = "Channel-release tarball of the nixpkgs snapshot to resolve agent CLIs from.";
            };
            sha256 = lib.mkOption {
              type = lib.types.str;
              description = "nix-prefetch-url --unpack hash of `url`.";
            };
          };
        });
        default = null;
        description = ''
          A second, faster-moving nixpkgs snapshot (a nixos-unstable
          channel-release tarball) that only the agent CLI packages
          (claude-code, codex) are resolved from — the rest of the system
          stays on the host's own nixpkgs. When null, agent packages come
          from the module's regular `pkgs`. The update service advances this
          pin by rewriting `agentPinFile`; the host configuration must import
          that file when it exists and wire it back into this option (same
          pathExists dance as pinFile — see aws/template.yaml). Kept as an
          option rather than a file read inside the module so the module
          stays pure for flake evaluation.
        '';
      };

      agentPinFile = lib.mkOption {
        type = lib.types.str;
        default = "/etc/nixos/claude-box-agent-pin.nix";
        description = ''
          File the updater atomically rewrites with
          `{ url = "..."; sha256 = "..."; }` — the latest nixos-unstable
          channel release, feeding agentNixpkgs on the next eval.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [{
    assertions = [{
      assertion = cfg.users != { };
      message = "services.claude-box.enable is true but no users are defined in services.claude-box.users.";
    } {
      assertion = cfg.installAgents != [ ];
      message = "services.claude-box.installAgents must not be empty.";
    }] ++ lib.concatLists (lib.mapAttrsToList (name: u:
      lib.concatLists (lib.mapAttrsToList (sname: s: [
        {
          # Session names land in tmux -t targets, URLs and env-ish contexts;
          # the same regex is enforced at runtime by the supervisor, the CLI
          # and the settings daemon.
          assertion = builtins.match "[A-Za-z0-9_-]+" sname != null;
          message = "services.claude-box.users.${name}: session name \"${sname}\" must match [A-Za-z0-9_-]+.";
        }
        {
          assertion = builtins.elem (if s.agent != null then s.agent else cfg.agent) cfg.installAgents;
          message = "services.claude-box.users.${name}: session \"${sname}\" uses agent \"${if s.agent != null then s.agent else cfg.agent}\", which is not in services.claude-box.installAgents.";
        }
        {
          # Cheap sanity check on a string that lands in a shell command;
          # deeper escaping happens at runtime via printf %q in mkStart.
          assertion = s.remoteControlName == null || (
            s.remoteControlName != ""
            && !(lib.hasInfix "\n" s.remoteControlName)
            && !(lib.hasInfix "\r" s.remoteControlName)
          );
          message = "services.claude-box.users.${name}: session \"${sname}\"'s remoteControlName must be non-empty and free of newlines.";
        }
      ]) (seedSessions name u))) cfg.users);

    # Claude Code is unfree; allow just the bundled supported agent packages
    # (host can override).
    nixpkgs.config.allowUnfreePredicate =
      lib.mkDefault (pkg: builtins.elem (lib.getName pkg) [ "claude-code" "codex" ]);

    users.users = lib.mapAttrs (name: u: {
      isNormalUser = true;
      home = "/home/${name}";
      createHome = true;
      extraGroups = u.extraGroups;
      shell = pkgs.bashInteractive;
    }) cfg.users;

    environment.systemPackages =
      (lib.unique (installedAgentPackages ++ [ pkgs.tmux sessionCli ] ++ cfg.extraPackages));

    systemd.services = lib.mapAttrs' (name: u:
      lib.nameValuePair "claude-box-${name}" {
        description = "Coding agent sessions (tmux) for ${name}";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        # System services get a minimal PATH; give the agent an explicit toolset.
        # The user's nix-profile bin goes first so `nix profile add` tools are
        # visible without a rebuild. It must be in the unit's PATH (not just a
        # BASH_ENV hook): agent CLIs commonly snapshot their startup PATH and re-export
        # it in every tool shell, clobbering anything BASH_ENV prepended.
        # NOTE: `path` entries go through makeBinPath, which appends /bin —
        # so list the profile ROOT, not its bin dir ('.../bin' became the
        # nonexistent '.../bin/bin' and silently dropped nix-profile tools).
        # /run/wrappers is added when the agent has any sudo allowlist entries,
        # so the setuid `sudo` wrapper (which lives at /run/wrappers/bin/sudo,
        # NOT on the default systemd unit PATH) resolves in agent tool shells.
        path = [ "/home/${name}/.nix-profile" ]
          ++ installedAgentPackages
          ++ [ sessionCli pkgs.tmux pkgs.bashInteractive pkgs.coreutils pkgs.git ]
          ++ cfg.extraPackages
          ++ lib.optional (effectiveSudoAllowlist != [ ]) "/run/wrappers";
        # TMUX_TMPDIR puts the control socket under the /run RuntimeDirectory
        # below instead of /tmp. PrivateTmp (in serviceConfig) gives this unit a
        # PRIVATE /tmp, so a socket there would be invisible to the separate
        # process that attaches (the AWS ttyd service, or `sudo -u <name> tmux`).
        # /run/agent-box-<name> is a normal host path both sides can reach.
        # Attach with: env TMUX_TMPDIR=/run/agent-box-<name> tmux -L agent-box attach -t main
        #
        # CLAUDE_BOX_URL: the user's browser-terminal URL, exported only when
        # this user actually has a terminal (web.enable + web.passwordHashFile).
        # An AGENTS.md (see users.<name>.agentsMd) can reference it so any
        # agent — claude-code, codex, opencode — can answer "where am I
        # reachable?" without hard-coding the URL, which is useful because
        # the hostname is a spot-restart away from changing.
        environment =
          { HOME = "/home/${name}"; TMUX_TMPDIR = "/run/${runtimeDirectory name}"; }
          // (lib.optionalAttrs (cfg.web.enable && u.web.passwordHashFile != null) {
            CLAUDE_BOX_URL = "https://${cfg.web.domain}/${name}/";
          })
          // u.environment;
        serviceConfig = {
          User = name;
          # ExecStart's mkStart is the session supervisor (issue #59): it
          # reconciles tmux sessions against the user-owned sessions.json
          # forever. Individual session restarts happen inside the loop;
          # Restart=always only backstops a crashed supervisor.
          Type = "exec";
          Restart = "always";
          RestartSec = "2s";
          ExecStart = mkStart name u;
          # Stopping the unit stops every session: kill the whole per-user
          # tmux server (the supervisor loop dies with the cgroup).
          ExecStop = "${pkgs.tmux}/bin/tmux -L ${tmuxSocketName} kill-server";
          # Holds the tmux control socket (see TMUX_TMPDIR above). 0700 so only
          # the agent user can reach its own socket; ExecStop/attachers run as
          # the same user. Persist across restarts so an in-flight attach isn't
          # racing the dir's teardown when Restart=always cycles the agent.
          RuntimeDirectory = runtimeDirectory name;
          RuntimeDirectoryMode = "0700";
          RuntimeDirectoryPreserve = true;
          # Custom tokens (GH_TOKEN, etc.) land here. The '-' makes the per-user
          # file optional so the agent starts even before any token is dropped in.
          # The self-serve settings page (issue #36) writes the user-owned
          # ~/.config/claude-box/env; it's listed here (also '-'-optional) so an
          # end user can add secrets through the browser without a rebuild and
          # without typing them into the agent chat/terminal. Restarting the
          # agent (settings-page "Apply") reloads this env.
          EnvironmentFile = cfg.environmentFiles
            ++ [ "-${cfg.tokenDir}/${name}.env" ]
            ++ [ "-/home/${name}/.config/claude-box/env" ]
            ++ u.environmentFiles;

          # Systemd hardening. The OS boundary has to stay meaningful even
          # though the agent runs with its in-tool approval prompts disabled.
          # This is the containment the agent CLI deliberately opts out of.
          PrivateTmp = true;
          PrivateDevices = true;              # keeps pty subsystem; blocks /dev/mem etc.
          ProtectSystem = "strict";           # entire fs read-only except explicit RW paths
          ReadWritePaths = [ "/home/${name}" ];
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          ProtectClock = true;
          RestrictSUIDSGID = true;
          RestrictRealtime = true;
          LockPersonality = true;
          # NoNewPrivileges would break the sudoAllowlist escape hatch (sudo
          # is setuid root; NNP blocks the euid transition). Enable it only
          # when the effective allowlist is empty — with a non-empty allowlist
          # (from cfg.sudoAllowlist or the web-implied caddy reload) we've
          # traded some containment for scoped elevation as a host choice.
          NoNewPrivileges = effectiveSudoAllowlist == [ ];
        } // lib.optionalAttrs cfg.protectMemory {
          # Sacrifice agent work first under memory pressure: the kernel OOM
          # killer and earlyoom both weigh oom_score_adj, so a runaway agent
          # process dies before sshd/caddy/SSM — and Restart=always brings
          # the session back fresh instead of leaving a frozen box.
          OOMScoreAdjust = lib.mkDefault 500;
        };
      }
    ) cfg.users;

    systemd.tmpfiles.rules = lib.mkIf cfg.manageTokenDir [
      # The dir itself is only ever traversed by root (systemd reads
      # EnvironmentFile= as root, before the service process starts as the
      # agent user), so 0700 is enough. Was 0755, which leaked filenames
      # (= usernames) to anyone on the box.
      "d ${cfg.tokenDir} 0700 root root - -"
      # Also enforce 0600 on any existing *.env files so a hand-created file
      # with lax perms gets corrected on next tmpfiles run.
      "Z ${cfg.tokenDir}/*.env 0600 root root - -"
    ];

    security.sudo.extraRules = lib.mkIf (effectiveSudoAllowlist != [ ]) [{
      users = lib.attrNames cfg.users;
      # NOPASSWD only — no SETENV. SETENV lets the caller alter env vars
      # visible to the sudo'd command, which broadens the surface for no
      # gain given the allowlist is meant to be tight and command-scoped.
      commands = map (command: { inherit command; options = [ "NOPASSWD" ]; }) effectiveSudoAllowlist;
    }];
  } (lib.mkIf cfg.protectMemory {
    # Memory protection (issue 62). The incident that motivated this: a
    # swapless 2 GB box under agent memory pressure never OOM-killed —
    # reclaim kept "succeeding" by evicting clean page-cache pages
    # (including running programs' own code), which immediately refaulted
    # from disk (~80 GB/h of reads), and every userspace process froze for
    # hours while EC2 status checks stayed green. Swap gives reclaim
    # somewhere cheap to go; earlyoom kills the largest offender BEFORE
    # the livelock; the agent units' OOMScoreAdjust (above) points both
    # killers at agent work first. All mkDefault — hosts can tune.
    zramSwap = {
      enable = lib.mkDefault true;
      algorithm = lib.mkDefault "zstd";
      # Cap on UNCOMPRESSED bytes stored; at zstd's typical ~3:1 a full
      # device costs ~1/3 of RAM, so 100% is safe and doubles headroom.
      memoryPercent = lib.mkDefault 100;
    };
    # Canonical zram tuning: swap early and eagerly (compressed swap is
    # far cheaper than dropping hot page cache), and no readahead on swap
    # faults (meaningless on a RAM-backed device).
    boot.kernel.sysctl = {
      "vm.swappiness" = lib.mkDefault 180;
      "vm.page-cluster" = lib.mkDefault 0;
    };
    services.earlyoom = {
      enable = lib.mkDefault true;
      # Kill the biggest process when free RAM and free swap both dip
      # under the (default 10%) thresholds — i.e. act where the kernel
      # OOM killer wouldn't, which is exactly the livelock window.
      # Patterns match comm names, truncated by the kernel to 15 chars —
      # hence "amazon-ssm-agen". Never pick the management plane or the
      # tmux server (that would take every session down, not just the
      # offender); prefer the agent CLI processes, which their unit's
      # Restart=always respawns.
      extraArgs = lib.mkDefault [
        "--avoid" "^(sshd|systemd|systemd-.*|caddy|ttyd|tmux.*|amazon-ssm-agen|ssm-.*|nix-daemon)$"
        "--prefer" "^(node|claude|codex)$"
      ];
    };
    # systemd-oomd overlaps earlyoom (two daemons racing to kill under
    # pressure); keep exactly one, explicitly.
    systemd.oomd.enable = lib.mkDefault false;
  }) (lib.mkIf cfg.selfUpdate.enable {
    # Agent-triggerable box update. The agents' only power here is the
    # allowlisted `sudo systemctl start claude-box-update.service` (see
    # updateStartCmd) — a trigger with no arguments, so everything below
    # (source repo, pin file, rebuild) is fixed at build time and immutable
    # in the store. Verifying releases against an offline signing key is
    # tracked upstream (defangdevs/claude-box issue 46); until then this
    # trusts the pinned repo as GitHub serves it.
    systemd.services.claude-box-update = {
      description = "Fast-forward claude-box to upstream HEAD and rebuild";
      # No wantedBy — on-demand only, via the agents' sudo rule (or root).
      path = [ pkgs.curl pkgs.jq pkgs.openssl pkgs.coreutils pkgs.util-linux pkgs.nix ];
      environment = {
        REPO = cfg.selfUpdate.repo;
        CURRENT_REV = cfg.selfUpdate.rev;
        PIN_FILE = cfg.selfUpdate.pinFile;
        AGENT_PIN_FILE = cfg.selfUpdate.agentPinFile;
        # nixos-rebuild resolves <nixpkgs> via NIX_PATH, which systemd units
        # don't inherit; point it at root's channel (the NixOS AMI default).
        NIX_PATH = "nixpkgs=/nix/var/nix/profiles/per-user/root/channels/nixos:nixos-config=/etc/nixos/configuration.nix";
      };
      serviceConfig.Type = "oneshot";
      script = ''
        set -euo pipefail
        api() { curl -fsSL -H 'Accept: application/vnd.github+json' "$1"; }

        # --- what would change? -----------------------------------------
        target="$(api "https://api.github.com/repos/$REPO/commits/HEAD" | jq -r .sha)"
        update_module=1
        if [ "$target" = "$CURRENT_REV" ]; then
          update_module=0
        else
          # Fast-forward only: a target that isn't strictly ahead of the
          # running rev means upstream history was rewritten or an older
          # (possibly vulnerable) rev is being replayed — refuse both.
          status="$(api "https://api.github.com/repos/$REPO/compare/$CURRENT_REV...$target" | jq -r .status)"
          if [ "$status" != "ahead" ]; then
            echo "refusing update: $target is '$status' of running rev $CURRENT_REV (need fast-forward)" >&2
            exit 1
          fi
        fi

        # Agent CLI pin: latest nixos-unstable channel release.
        # channels.nixos.org redirects to the immutable releases.nixos.org
        # URL — pin that, so the pin file stays reproducible.
        release="$(curl -fsSLo /dev/null -w '%{url_effective}' https://channels.nixos.org/nixos-unstable)"
        tarball="''${release%/}/nixexprs.tar.xz"
        update_agent=1
        if [ -e "$AGENT_PIN_FILE" ] && grep -qF "$tarball" "$AGENT_PIN_FILE"; then
          update_agent=0
        fi

        if [ "$update_module" = 0 ] && [ "$update_agent" = 0 ]; then
          echo "already current: module at $target, agent nixpkgs at $release"
          exit 0
        fi

        # --- write the pins (with backups, so failure rolls back exactly
        # what this run changed) ------------------------------------------
        if [ "$update_module" = 1 ]; then
          module="$(mktemp)"
          trap 'rm -f "$module"' EXIT
          curl -fsSL "https://raw.githubusercontent.com/$REPO/$target/modules/claude-box.nix" -o "$module"
          sha="sha256-$(openssl dgst -sha256 -binary "$module" | base64)"
          if [ -e "$PIN_FILE" ]; then
            cp "$PIN_FILE" "$PIN_FILE.prev"
          fi
          printf '{ rev = "%s"; sha256 = "%s"; }\n' "$target" "$sha" > "$PIN_FILE.tmp"
          mv "$PIN_FILE.tmp" "$PIN_FILE"
        fi

        if [ "$update_agent" = 1 ]; then
          # nix-prefetch-url --unpack both hashes the tarball and pre-warms
          # the store path fetchTarball wants, so the rebuild that follows
          # doesn't download it a second time.
          agent_sha="$(nix-prefetch-url --unpack "$tarball")"
          if [ -e "$AGENT_PIN_FILE" ]; then
            cp "$AGENT_PIN_FILE" "$AGENT_PIN_FILE.prev"
          fi
          printf '{ url = "%s"; sha256 = "%s"; }\n' "$tarball" "$agent_sha" > "$AGENT_PIN_FILE.tmp"
          mv "$AGENT_PIN_FILE.tmp" "$AGENT_PIN_FILE"
        fi

        wall "claude-box: updating (module: $REPO@$target, agent nixpkgs: $release) — agent sessions will restart if their services changed." || true
        if /run/current-system/sw/bin/nixos-rebuild switch; then
          wall "claude-box: update to $target applied." || true
        else
          # Roll back exactly the pins this run touched so the next trigger
          # retries cleanly instead of believing the failed state is current.
          if [ "$update_module" = 1 ]; then
            if [ -e "$PIN_FILE.prev" ]; then
              mv "$PIN_FILE.prev" "$PIN_FILE"
            else
              rm -f "$PIN_FILE"
            fi
          fi
          if [ "$update_agent" = 1 ]; then
            if [ -e "$AGENT_PIN_FILE.prev" ]; then
              mv "$AGENT_PIN_FILE.prev" "$AGENT_PIN_FILE"
            else
              rm -f "$AGENT_PIN_FILE"
            fi
          fi
          wall "claude-box: update to $target FAILED — pins rolled back, system unchanged. See: journalctl -u claude-box-update" || true
          exit 1
        fi
      '';
    };
  }) (lib.mkIf (cfg.enable && cfg.web.enable) (
    let
      webUser = cfg.web.user;
      # Users that get a browser terminal, in sorted order (attrNames sorts) —
      # port assignment below depends on that order being deterministic.
      terminalUsers = lib.filter (n: cfg.users.${n}.web.passwordHashFile != null) (lib.attrNames cfg.users);
      portOf = lib.listToAttrs (lib.imap0 (i: n: lib.nameValuePair n (ttydPortBase + i)) terminalUsers);
      # Public URL base path for a user's settings page (Caddy does not strip
      # a prefix, so the daemon matches this full path).
      settingsBaseOf = n: "/${n}/settings";
      hashFileOf = n: toString cfg.users.${n}.web.passwordHashFile;
      # The settings daemon script (issue #36). Python-3-stdlib only — no
      # third-party deps — so it stays tiny and auditable. Runs as the agent
      # user; writes ~/.config/claude-box/env (0600) and restarts the agent by
      # killing its tmux session. Full rationale in the script header below.
      #
      # INLINE ON PURPOSE (issue #51): deployed boxes fetch this module as a
      # SINGLE file (see the contract at the top of this file), so the script
      # cannot live in a ./sibling. If you edit it, keep it free of the two
      # Nix indented-string specials (two consecutive single-quotes, and
      # dollar-brace) or escape them per the Nix manual.
      settingsDaemon = pkgs.writers.writePython3Bin "claude-box-settings" {
        # No external libraries; skip flake8 style gate (the script is
        # formatted for readability, not lint-perfection) but keep syntax
        # checking that writePython3Bin does by compiling.
        flakeIgnore = [ "E501" "E302" "E305" "W503" "E226" ];
      } ''
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
        # kills the user's tmux sessions (same uid, via the PrivateTmp socket
        # under TMUX_TMPDIR); the supervisor in the agent unit brings them
        # back with the fresh environment.
        #
        # Sessions (issue 59): the daemon is also the web CRUD surface for the
        # user-owned sessions.json — add/delete/restart sessions and a public
        # names-only listing that feeds the flat picker. The reconcile/respawn
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
        # binding 127.0.0.1:$CLAUDE_BOX_SETTINGS_PORT itself.
        #
        # Configuration comes from the environment (set by the systemd unit):
        #   CLAUDE_BOX_SETTINGS_USER      the linux user name (display only)
        #   CLAUDE_BOX_SETTINGS_ENV_FILE  path to the env file to manage
        #   CLAUDE_BOX_SETTINGS_BASE      URL base path, e.g. /alice/settings
        #   CLAUDE_BOX_SETTINGS_PORT      dev fallback TCP port on 127.0.0.1
        #                                 (ignored when socket-activated)
        #   CLAUDE_BOX_TMUX_SOCKET        tmux -L socket name (e.g. agent-box)
        #   CLAUDE_BOX_TMUX_TMPDIR        TMUX_TMPDIR the agent's socket lives under
        #   CLAUDE_BOX_TMUX_BIN           absolute path to the tmux binary
        #   CLAUDE_BOX_SESSIONS_FILE      path to the user's sessions.json
        #   CLAUDE_BOX_SESSIONS_PUBLIC    unauthenticated names-only list path
        #   CLAUDE_BOX_AGENTS             comma-separated installed agent CLIs
        #   CLAUDE_BOX_DEFAULT_AGENT      agent preselected in the add form

        import html
        import http.server
        import json
        import os
        import re
        import socket
        import subprocess
        import sys
        import tempfile
        import urllib.parse

        USER = os.environ.get("CLAUDE_BOX_SETTINGS_USER", "agent")
        ENV_FILE = os.environ["CLAUDE_BOX_SETTINGS_ENV_FILE"]
        BASE = os.environ.get("CLAUDE_BOX_SETTINGS_BASE", "/settings").rstrip("/")
        PORT = int(os.environ.get("CLAUDE_BOX_SETTINGS_PORT", "8080"))
        TMUX_SOCKET = os.environ.get("CLAUDE_BOX_TMUX_SOCKET", "agent-box")
        TMUX_TMPDIR = os.environ.get("CLAUDE_BOX_TMUX_TMPDIR", "")
        TMUX_BIN = os.environ.get("CLAUDE_BOX_TMUX_BIN", "tmux")
        # Sessions (issue 59): the daemon is the web CRUD surface for the
        # user-owned sessions.json; the supervisor inside the agent unit
        # reconciles tmux against it (starts within ~2s). The daemon only
        # ever writes the file and kills the user's own tmux sessions.
        SESSIONS_FILE = os.environ.get("CLAUDE_BOX_SESSIONS_FILE", "")
        # Unauthenticated names-only listing path (feeds the flat picker).
        SESSIONS_PUBLIC = os.environ.get("CLAUDE_BOX_SESSIONS_PUBLIC", "")
        AGENTS = [a for a in os.environ.get("CLAUDE_BOX_AGENTS", "claude").split(",") if a]
        DEFAULT_AGENT = os.environ.get("CLAUDE_BOX_DEFAULT_AGENT", "claude")
        # Full sudo command line that triggers the box update (issue 54). Empty
        # when selfUpdate is off, which hides the Update card and 404s the route.
        UPDATE_CMD = os.environ.get("CLAUDE_BOX_UPDATE_CMD", "")

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
          input, select {{ font: inherit; padding: 8px 10px; border-radius: 6px;
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
            <h2 style="font-size:16px;margin-top:0">Sessions</h2>
            <p class="note">Each session is one agent CLI in its own terminal.
            New sessions start within a few seconds — no rebuild, no sudo.
            Open a session from the front page or at
            <code>/{user}/?arg=&lt;session&gt;</code>.</p>
            {sessions}
            <form method="post" action="{base}/sessions/add">
              <div class="row">
                <input type="text" name="name" placeholder="session-name"
                       pattern="[A-Za-z0-9_-]+" required
                       title="Letters, digits, dash and underscore">
                <select name="agent">{agents}</select>
                <button type="submit">Add session</button>
              </div>
            </form>
          </div>
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
            <h2 style="font-size:16px;margin-top:0">Apply changes (restart all sessions)</h2>
            <p class="note">Restarting reloads every session's agent with the
            current keys. <strong>This kills all live agent sessions</strong> —
            any in-flight work an agent has not persisted is lost. Individual
            sessions can be restarted from the Sessions card above.</p>
            <form method="post" action="{base}/restart"
                  onsubmit="return confirm('Restart all sessions now? Live sessions will be killed and any unsaved in-flight work is lost.');">
              <button type="submit" class="danger">Restart all</button>
            </form>
          </div>
          {update}
        </main>
        </html>
        """

        UPDATE_CARD = """<div class="card">
            <h2 style="font-size:16px;margin-top:0">Update box</h2>
            <p class="note">Fetches the latest claude-box release and the newest
            agent CLI versions, then rebuilds the system. Takes a few minutes.
            <strong>The agent session restarts if its software changed</strong> —
            unsaved in-flight work is lost.</p>
            <form method="post" action="{base}/update"
                  onsubmit="return confirm('Update the box now? This rebuilds the system and may restart the agent session.');">
              <button type="submit" class="danger">Update box</button>
            </form>
          </div>"""


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


        def render_sessions():
            entries = {n: v for n, v in read_sessions().items() if SESSION_RE.match(n)}
            if not entries:
                return '<p class="note">No sessions defined.</p>'
            live = live_sessions()
            base = html.escape(BASE)
            items = []
            for name in sorted(entries):
                safe = html.escape(name)
                agent = html.escape(str(entries[name].get("agent") or "?"))
                state = "live" if name in live else "starting"
                items.append(
                    f'<li><span><code>{safe}</code> '
                    f'<span class="note">{agent} · {state}</span></span><span>'
                    f'<form class="inline" method="post" action="{base}/sessions/restart" '
                    f'onsubmit="return confirm(\'Restart {safe}? Unsaved in-flight work is lost.\');">'
                    f'<input type="hidden" name="name" value="{safe}">'
                    f'<button type="submit">Restart</button></form> '
                    f'<form class="inline" method="post" action="{base}/sessions/delete" '
                    f'onsubmit="return confirm(\'Delete session {safe}? Its live agent is killed.\');">'
                    f'<input type="hidden" name="name" value="{safe}">'
                    f'<button type="submit" class="danger">Delete</button></form>'
                    f'</span></li>'
                )
            return "<ul>" + "".join(items) + "</ul>"


        def render_agent_options():
            items = []
            for agent in AGENTS:
                sel = " selected" if agent == DEFAULT_AGENT else ""
                safe = html.escape(agent)
                items.append(f'<option value="{safe}"{sel}>{safe}</option>')
            return "".join(items)


        def render_page(message=""):
            msg_html = f'<div class="msg">{html.escape(message)}</div>' if message else ""
            return PAGE.format(
                user=html.escape(USER),
                base=html.escape(BASE),
                keys=render_keys(read_keys()),
                sessions=render_sessions(),
                agents=render_agent_options(),
                message=msg_html,
                update=UPDATE_CARD.format(base=html.escape(BASE)) if UPDATE_CMD else "",
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

            def _send_json(self, obj):
                data = (json.dumps(obj) + "\n").encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Cache-Control", "no-store")
                self.send_header("X-Content-Type-Options", "nosniff")
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                parsed = urllib.parse.urlparse(self.path)
                if SESSIONS_PUBLIC and parsed.path == SESSIONS_PUBLIC:
                    # Names+agents only — deliberately unauthenticated (Caddy
                    # routes it outside the auth block): it feeds the flat
                    # session picker, same public stance as user names there.
                    # Never include argv/cwd/env — those may hold secrets.
                    self._send_json([
                        {"name": n, "agent": str(v.get("agent") or "")}
                        for n, v in sorted(read_sessions().items())
                        if SESSION_RE.match(n)
                    ])
                    return
                if not self._under_base(parsed.path):
                    self._send_html("<h1>404</h1>", status=404)
                    return
                params = urllib.parse.parse_qs(parsed.query)
                message = ""
                if "ok" in params:
                    message = {
                        "saved": "Key saved. Restart the sessions to apply.",
                        "deleted": "Key deleted. Restart the sessions to apply.",
                        "restarted": "Restart of all sessions requested.",
                        "session_added": "Session added — it starts within a few seconds.",
                        "session_deleted": "Session deleted.",
                        "session_restarted": "Session restart requested.",
                        "update": "Box update started — the system rebuilds in the "
                                  "background and this page may briefly go away.",
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
                elif path == BASE + "/sessions/add":
                    name = (form.get("name", [""])[0]).strip()
                    agent = (form.get("agent", [""])[0]).strip() or DEFAULT_AGENT
                    if not SESSION_RE.match(name):
                        self._send_html(
                            render_page("Invalid session name. Use letters, digits, "
                                        "dash and underscore (max 32 chars)."),
                            status=400,
                        )
                        return
                    if agent not in AGENTS:
                        self._send_html(
                            render_page("Unknown agent. Installed: " + ", ".join(AGENTS)),
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
                    self._redirect("ok=session_added")
                elif path == BASE + "/sessions/delete":
                    name = (form.get("name", [""])[0]).strip()
                    if SESSION_RE.match(name):
                        sessions = read_sessions()
                        sessions.pop(name, None)
                        write_sessions(sessions)
                        kill_session(name)
                    self._redirect("ok=session_deleted")
                elif path == BASE + "/sessions/restart":
                    name = (form.get("name", [""])[0]).strip()
                    if SESSION_RE.match(name):
                        kill_session(name)
                    self._redirect("ok=session_restarted")
                elif path == BASE + "/restart":
                    # Bounce every listed session so all agents reload the env
                    # file; the supervisor brings them back within ~2s.
                    for name in read_sessions():
                        if SESSION_RE.match(name):
                            kill_session(name)
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
                server.server_name = "claude-box-settings"
                server.server_port = 0
                return server
            # Dev fallback for LAN rigs / e2e runs outside the module.
            return http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)


        def main():
            make_server().serve_forever()


        if __name__ == "__main__":
            main()
      '';
      # Per-connection tmux attach for ttyd (issue #59). ttyd runs with
      # --url-arg, so /<user>/?arg=<session> passes <session> as $1 — ONE
      # ttyd per user serves every session, including runtime-created ones.
      # Strict allowlist on the client-supplied argument: session-name
      # charset AND an existing tmux session; anything else prints the live
      # list and exits (ttyd spawns a fresh instance per connection).
      attachScript = name: pkgs.writeShellScript "claude-box-${name}-attach" ''
        set -u
        T="${pkgs.tmux}/bin/tmux -L ${tmuxSocketName}"
        want="''${1:-}"
        case "$want" in (*[!A-Za-z0-9_-]*) want="" ;; esac
        if [ -n "$want" ]; then
          if $T has-session -t "=$want" 2>/dev/null; then
            exec $T attach -t "=$want"
          fi
          echo "no session named '$want'. Live sessions:"
          $T list-sessions -F '  #S' 2>/dev/null || echo "  (none)"
          echo "create it with: claude-box-session add $want"
          sleep 5
          exit 1
        fi
        # No session requested: prefer "main", else the first live session.
        if $T has-session -t "=main" 2>/dev/null; then
          exec $T attach -t "=main"
        fi
        first="$($T list-sessions -F '#S' 2>/dev/null | ${pkgs.coreutils}/bin/head -n 1)"
        if [ -n "$first" ]; then
          exec $T attach -t "=$first"
        fi
        echo "no live sessions yet — the supervisor may still be starting them."
        sleep 5
        exit 1
      '';
      # Per-user env var suffix for the Caddyfile placeholders; linux user
      # names may contain chars that are invalid in env var names.
      envName = n: lib.toUpper (lib.stringAsChars (c: if builtins.match "[a-zA-Z0-9]" c != null then c else "_") n);

      # Prefix every non-blank line — Nix indented strings strip the common
      # leading whitespace, so composed fragments need explicit re-indenting.
      indent = prefix: text: lib.concatMapStrings
        (line: if line == "" then "\n" else prefix + line + "\n")
        (lib.init (lib.splitString "\n" text));

      terminalCaddyBlock = name: ''
        # ${name}'s terminal. Cookie first — browsers refuse to attach basic
        # auth credentials to WebSocket upgrades — then basic auth with the
        # linux user name as the login name.
        redir /${name} /${name}/
        # ${name}'s session list (issue #59): session names + agent kinds
        # only, no secrets — same public stance as the user names on the
        # picker, which this feeds. Served by the settings daemon over its
        # unix socket, deliberately OUTSIDE the auth block.
        handle /${name}/sessions.json {
          reverse_proxy unix/${settingsSocketOf name}
        }
        # ${name}'s settings page (issue #36). Same auth surface as the
        # terminal (cookie-or-basic-auth, same user name), just a different
        # upstream — the settings daemon over its user+caddy-only unix socket
        # (issue #49). More specific than /${name}/* below, so Caddy routes
        # it here first.
        handle /${name}/settings* {
          @cookie_settings_${name} header_regexp Cookie "(^|; )__Host-agent_box_auth_${name}={$WEB_COOKIE_SECRET_${envName name}}(;|$)"
          handle @cookie_settings_${name} {
            reverse_proxy unix/${settingsSocketOf name}
          }
          handle {
            route {
              basic_auth bcrypt ${name} {
                ${name} {$WEB_PASSWORD_HASH_${envName name}}
              }
              header >Set-Cookie "__Host-agent_box_auth_${name}={$WEB_COOKIE_SECRET_${envName name}}; Path=/; Max-Age=2592000; HttpOnly; Secure; SameSite=Strict"
              reverse_proxy unix/${settingsSocketOf name}
            }
          }
        }
        handle /${name}/* {
          @cookie_${name} header_regexp Cookie "(^|; )__Host-agent_box_auth_${name}={$WEB_COOKIE_SECRET_${envName name}}(;|$)"
          handle @cookie_${name} {
            reverse_proxy 127.0.0.1:${toString portOf.${name}}
          }
          handle {
            route {
              basic_auth bcrypt ${name} {
                ${name} {$WEB_PASSWORD_HASH_${envName name}}
              }
              header >Set-Cookie "__Host-agent_box_auth_${name}={$WEB_COOKIE_SECRET_${envName name}}; Path=/; Max-Age=2592000; HttpOnly; Secure; SameSite=Strict"
              reverse_proxy 127.0.0.1:${toString portOf.${name}}
            }
          }
        }
      '';

      pickerBlock = ''
        # Anything else, including /: unauthenticated picker listing this
        # box's agent SESSIONS (issue #59), flat — the users->sessions
        # hierarchy survives only in the URL and the auth realm. Fetched
        # client-side from each user's public names-only sessions.json;
        # session and user names are not secrets, the passwords are. The
        # <noscript> fallback keeps per-user links. No userinfo in any href
        # (issue 56): Chrome answers the basic-auth challenge with URL
        # userinfo + an EMPTY password, and credentials typed into the
        # prompt cannot override the URL-embedded identity.
        handle {
          header Content-Type "text/html; charset=utf-8"
          respond <<PICKER_HTML
            <!doctype html>
            <html lang="en">
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="robots" content="noindex">
            <title>Sessions — ${cfg.web.domain}</title>
            <style>
              body { margin: 0; min-height: 100vh; display: grid; place-items: center;
                     background: #0d1117; color: #e6edf3; font: 16px/1.6 system-ui, sans-serif; }
              main { text-align: center; }
              main .row { display: flex; gap: 8px; margin: 10px 0; align-items: stretch; }
              main a { display: flex; align-items: center; justify-content: center;
                       padding: 12px 36px;
                       border: 1px solid #30363d; border-radius: 10px; background: #161b22;
                       color: #e8a087; font-size: 20px; text-decoration: none; }
              main a.term { flex: 1; flex-direction: column; }
              main a.gear { padding: 12px 18px; text-decoration: none; }
              main a:hover { border-color: #e8a087; }
              main .sub { display: block; font-size: 13px; color: #8b949e; }
            </style>
            <main>
              <h1>Sessions</h1>
              <div id="list"><noscript>
              ${lib.concatMapStringsSep "\n      " (n: ''<div class="row"><a class="term" href="https://${cfg.web.domain}/${n}/">${n}</a><a class="gear" href="https://${cfg.web.domain}/${n}/settings/" title="${n} settings" aria-label="${n} settings">&#9881;</a></div>'') terminalUsers}
              </noscript></div>
            </main>
            <script>
              var users = [${lib.concatMapStringsSep ", " (n: "\"${n}\"") terminalUsers}];
              var list = document.getElementById("list");
              function card(user, session, agent) {
                var row = document.createElement("div");
                row.className = "row";
                var a = document.createElement("a");
                a.className = "term";
                if (session === null) {
                  a.href = "/" + user + "/";
                  a.textContent = user;
                } else {
                  a.href = "/" + user + "/?arg=" + encodeURIComponent(session);
                  a.textContent = session;
                  var sub = document.createElement("span");
                  sub.className = "sub";
                  sub.textContent = agent + (users.length > 1 ? " · " + user : "");
                  a.appendChild(sub);
                }
                var gear = document.createElement("a");
                gear.className = "gear";
                gear.href = "/" + user + "/settings/";
                gear.title = user + " settings";
                gear.setAttribute("aria-label", user + " settings");
                gear.innerHTML = "&#9881;";
                row.appendChild(a);
                row.appendChild(gear);
                list.appendChild(row);
              }
              users.forEach(function (u) {
                fetch("/" + u + "/sessions.json").then(function (r) {
                  if (!r.ok) { throw new Error("http " + r.status); }
                  return r.json();
                }).then(function (sessions) {
                  if (!sessions.length) { card(u, null, null); return; }
                  sessions.forEach(function (s) { card(u, s.name, s.agent); });
                }).catch(function () { card(u, null, null); });
              });
            </script>
            PICKER_HTML 200
        }
      '';

      # Rendered Caddyfile. Module-managed (regenerated every rebuild) — safe
      # to keep in the world-readable Nix store because it only holds
      # {$ENV} placeholders, never secrets.
      #
      # Self-serve extension point: the trailing per-user `import` lines
      # (one per agent user, since the Caddyfile `import` directive rejects
      # multi-wildcard globs like `*/*.caddy`) pick up snippet files. Each
      # agent user has a caddy-readable directory at
      # /var/lib/claude-box-sites/<user>/ symlinked from ~/sites, so the agent
      # can add a virtual host by writing ~/sites/<something>.caddy and
      # running `sudo systemctl reload caddy.service`. No nixos-rebuild
      # needed. Snippets should REVERSE-PROXY to a localhost port rather than
      # serve files from $HOME — caddy.service runs with ProtectHome=true and
      # can't read /home. See the comment block at the top of the rendered
      # file below (agents will read that from the running box).
      managedCaddyfile = pkgs.writeText "claude-box-caddyfile" (''
        # This file is module-managed by services.claude-box — edits here get
        # OVERWRITTEN on the next nixos-rebuild. To add your own virtual host,
        # drop a *.caddy snippet into ~/sites/ (which is a symlink into
        # /var/lib/claude-box-sites/<you>/, a caddy-readable location) and
        # reload with: sudo systemctl reload caddy.service
        #
        # Recommended snippet shape — reverse-proxy to a localhost port your
        # agent runs, NOT `file_server /home/<you>/...`. caddy.service has
        # ProtectHome=true, so it cannot read files under /home; use file_server
        # only against a path outside /home (e.g. /var/lib/claude-box-sites/<you>/public):
        #
        #     foo.example.com {
        #       import acme_alpn_only    # Let's Encrypt via TLS-ALPN-01
        #       reverse_proxy 127.0.0.1:3000
        #     }
        #
        # New hosts get a Let's Encrypt cert on first request as long as DNS
        # for that hostname points at this box.

        (acme_alpn_only) {
          tls {
            issuer acme {
              disable_http_challenge
            }
          }
        }

        ${cfg.web.domain} {
          # Access log to the journal — the fail2ban jail counts 401s here.
          log
          import acme_alpn_only
          header {
            Cache-Control "no-store"
            X-Content-Type-Options "nosniff"
          }

      ''
      + lib.concatMapStringsSep "\n" (name: indent "  " (terminalCaddyBlock name)) terminalUsers
      + "\n"
      + indent "  " pickerBlock
      + "}\n\n"
      + ''
        # Per-user snippet directories. Each agent user's ~/sites/ symlinks
        # here. Adding a file below and running `sudo systemctl reload
        # caddy.service` is the whole workflow — no nixos-rebuild required.
        # One import per user: Caddyfile's `import` directive only accepts a
        # single `*` per pattern, so we can't collapse this to `*/*.caddy`.
      ''
      + lib.concatMapStringsSep "" (name: "import /var/lib/claude-box-sites/${name}/*.caddy\n") (lib.attrNames cfg.users));

      # Reads each terminal user's (already-hashed) password from their
      # passwordHashFile, mints a persistent per-user cookie secret if
      # absent, and writes everything into /run/claude-box-web/env for Caddy
      # to consume as environment variables (WEB_PASSWORD_HASH_<USER> /
      # WEB_COOKIE_SECRET_<USER>). Runs BEFORE caddy every boot.
      webAuthSecretsService = {
        description = "Prepare browser terminal auth env for Caddy";
        before = [ "caddy.service" ];
        requiredBy = [ "caddy.service" ];
        path = [ pkgs.coreutils pkgs.openssl ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -euo pipefail
          umask 077
          tmp="$(mktemp /run/claude-box-web/env.XXXXXX)"
        '' + lib.concatMapStrings (name: ''
          if [ ! -s /var/lib/claude-box-web/cookie-secret-${name} ]; then
            openssl rand -hex 32 > /var/lib/claude-box-web/cookie-secret-${name}
          fi
          {
            printf 'WEB_COOKIE_SECRET_${envName name}=%s\n' "$(cat /var/lib/claude-box-web/cookie-secret-${name})"
            printf 'WEB_PASSWORD_HASH_${envName name}=%s\n' "$(cat ${lib.escapeShellArg (hashFileOf name)})"
          } >> "$tmp"
        '') terminalUsers + ''
          chmod 0600 "$tmp"
          mv "$tmp" /run/claude-box-web/env
        '';
      };
    in
    {
      assertions = [
        {
          assertion = cfg.users ? ${webUser};
          message =
            "services.claude-box.web.user = \"${webUser}\" but that user "
            + "isn't defined in services.claude-box.users.";
        }
        {
          assertion = terminalUsers != [ ];
          message =
            "services.claude-box.web.enable is true but no user has "
            + "web.passwordHashFile set, so no terminal would be served.";
        }
        {
          assertion = lib.length (lib.unique (map envName terminalUsers)) == lib.length terminalUsers;
          message =
            "services.claude-box: web-terminal user names must stay distinct "
            + "after sanitizing to env-var form ([A-Z0-9_]).";
        }
      ];

      # The top-level Caddyfile is module-managed (see managedCaddyfile above);
      # each agent user's own virtual hosts live in per-user snippet files at
      # /var/lib/claude-box-sites/<user>/*.caddy, symlinked into their $HOME
      # as ~/sites/. Reload via the sudo rule added to effectiveSudoAllowlist.

      networking.firewall.allowedTCPPorts = [ 443 ];

      systemd.tmpfiles.rules = [
        "d /var/lib/claude-box-web 0700 root root - -"
        "d /run/claude-box-web 0700 root root - -"
        # Snippet dirs: parent is world-traversable so caddy (primary group
        # `caddy`) can reach the per-user subdirectories, which are 0750
        # <user>:caddy — the user writes, caddy reads, other agent users on
        # the box can't peek. Kept OUTSIDE /var/lib/claude-box-web (0700) so
        # caddy's `import` can traverse without loosening the secrets dir.
        "d /var/lib/claude-box-sites 0755 root root - -"
        # Settings daemon sockets live here (issue #49). World-traversable is
        # fine: the per-user socket files themselves are 0660 <user>:caddy
        # (created by systemd, see systemd.sockets below), and connecting
        # requires write permission on the socket file.
        "d ${settingsSocketDir} 0755 root root - -"
      ] ++ lib.concatMap (name: [
        "d /var/lib/claude-box-sites/${name} 0750 ${name} caddy - -"
        # ~/sites -> the caddy-readable snippet dir. L+ replaces a stale
        # symlink/file if the target differs from ours (idempotent across
        # renames). Users edit through this link and never touch /var/lib.
        "L+ /home/${name}/sites - - - - /var/lib/claude-box-sites/${name}"
      ]) (lib.attrNames cfg.users)
      # The settings page's env dir, per terminal user. User-owned 0700 so
      # only the agent user (and root) can read it; the settings daemon runs
      # as that user and writes env (0600) inside. Created here so the daemon
      # and the agent unit's optional EnvironmentFile both have a stable path
      # even before the user saves any key.
      ++ lib.map (name:
        "d /home/${name}/.config/claude-box 0700 ${name} ${name} - -"
      ) terminalUsers;

      services.caddy = {
        enable = true;
        # Module-managed. Store path is world-readable but holds only ENV
        # placeholders, no secrets. Per-user extensions land via the trailing
        # `import /var/lib/claude-box-sites/*/*.caddy`.
        configFile = managedCaddyfile;
      };

      # Brute-force protection: count 401s on the terminal vhost that carried
      # an Authorization header (Caddy logs it as ["REDACTED"] when present),
      # i.e. actual wrong-password attempts — a browser's credential-less
      # first request also 401s but is not counted.
      services.fail2ban = lib.mkIf cfg.web.fail2ban {
        enable = true;
        jails.claude-web-auth = {
          filter.Definition = {
            failregex = ''^.*"logger":"http\.log\.access".*"client_ip":"<HOST>".*"Authorization":\["REDACTED"\].*"status":401'';
            journalmatch = "_SYSTEMD_UNIT=caddy.service";
          };
          settings = {
            backend = "systemd";
            port = "http,https";
            maxretry = 5;
            findtime = "10m";
            bantime = "1h";
          };
        };
      };

      # ttyd per terminal user — attaches to that user's tmux session over an
      # internal port; --base-path keeps each terminal (and its /ws endpoint)
      # under /<user>/ so one vhost can serve them all.
      # TMUX_TMPDIR must match the agent unit's RuntimeDirectory (the agent
      # runs with PrivateTmp, so the socket lives in /run, not /tmp).
      systemd.services = {
        claude-web-auth-secrets = webAuthSecretsService;
        caddy.serviceConfig.EnvironmentFile = "/run/claude-box-web/env";
      } // lib.listToAttrs (map (name: lib.nameValuePair "claude-web-terminal-${name}" {
        description = "Browser terminal (ttyd) attached to ${name}'s tmux";
        after = [ "claude-box-${name}.service" "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        environment.TMUX_TMPDIR = "/run/${runtimeDirectory name}";
        serviceConfig = {
          User = name;
          Restart = "always";
          RestartSec = "5s";
          ExecStart = lib.concatStringsSep " " [
            "${pkgs.ttyd}/bin/ttyd"
            "--writable"
            # ?arg=<session> in the URL becomes $1 of the attach wrapper —
            # session-level deep links from the picker (issue #59).
            "--url-arg"
            "-p" (toString portOf.${name})
            "-i" "127.0.0.1"
            "-b" "/${name}"
            "-t" "titleFixed=${name}@${cfg.web.domain}"
            (toString (attachScript name))
          ];
        };
      }) terminalUsers)
      # Settings daemon (issue #36), one per terminal user. Runs AS the agent
      # user (no root, no privilege boundary): it only writes that user's own
      # ~/.config/claude-box/env and kills that user's own tmux session. The
      # agent unit's Restart=always then reloads it with the fresh env.
      # Listens via socket activation on the systemd-owned unix socket
      # (issue #49) — the same-named .socket unit below; requires/after kept
      # explicit per this repo's explicit-over-implied-config convention.
      // lib.listToAttrs (map (name: lib.nameValuePair "claude-box-settings-${name}" {
        description = "Per-user secrets settings page for ${name}";
        after = [ "network-online.target" "claude-box-settings-${name}.socket" ];
        requires = [ "claude-box-settings-${name}.socket" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        # TMUX_TMPDIR must match the agent unit's RuntimeDirectory so the
        # daemon can reach the (PrivateTmp) tmux socket to restart the agent.
        environment = {
          TMUX_TMPDIR = "/run/${runtimeDirectory name}";
          CLAUDE_BOX_SETTINGS_USER = name;
          CLAUDE_BOX_SETTINGS_ENV_FILE = userEnvFile name;
          CLAUDE_BOX_SETTINGS_BASE = settingsBaseOf name;
          CLAUDE_BOX_TMUX_SOCKET = tmuxSocketName;
          CLAUDE_BOX_TMUX_TMPDIR = "/run/${runtimeDirectory name}";
          CLAUDE_BOX_TMUX_BIN = "${pkgs.tmux}/bin/tmux";
          CLAUDE_BOX_SESSIONS_FILE = userSessionsFile name;
          CLAUDE_BOX_SESSIONS_PUBLIC = "/${name}/sessions.json";
          CLAUDE_BOX_AGENTS = lib.concatStringsSep "," cfg.installAgents;
          CLAUDE_BOX_DEFAULT_AGENT = cfg.agent;
        } // lib.optionalAttrs cfg.selfUpdate.enable {
          # --no-block so the daemon's HTTP response goes out before the
          # rebuild (possibly) restarts the daemon itself.
          CLAUDE_BOX_UPDATE_CMD = "/run/wrappers/bin/sudo -n ${updateStartNoBlockCmd}";
        };
        serviceConfig = {
          User = name;
          Restart = "always";
          RestartSec = "5s";
          ExecStart = "${settingsDaemon}/bin/claude-box-settings";
          # Hardening: the daemon needs to write ~/.config/claude-box and run
          # tmux against the /run socket dir, nothing else.
          ProtectSystem = "strict";
          ReadWritePaths = [ "/home/${name}" "/run/${runtimeDirectory name}" ];
          ProtectHome = false;
          PrivateDevices = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictSUIDSGID = true;
          RestrictRealtime = true;
          LockPersonality = true;
          # Setuid sudo needs privilege escalation, which NNP vetoes — same
          # tradeoff the agent unit makes for its sudoAllowlist. The only
          # extra power gained is the daemon user's own allowlist (the
          # argument-free update trigger), so relax NNP only when selfUpdate
          # is on.
          NoNewPrivileges = !cfg.selfUpdate.enable;
        };
      }) terminalUsers);

      # The settings daemon's listening sockets (issue #49). systemd (root)
      # binds each unix socket with exact ownership BEFORE the daemon starts:
      # 0660 <user>:caddy means only that user and the caddy reverse-proxy
      # can connect — unlike the previous 127.0.0.1:<port> listener, which
      # every local user could reach. The daemon adopts the socket through
      # socket activation (LISTEN_FDS, fd 3).
      systemd.sockets = lib.listToAttrs (map (name: lib.nameValuePair "claude-box-settings-${name}" {
        description = "Settings page socket for ${name}";
        wantedBy = [ "sockets.target" ];
        socketConfig = {
          ListenStream = settingsSocketOf name;
          SocketUser = name;
          SocketGroup = "caddy";
          SocketMode = "0660";
        };
      }) terminalUsers);
    }
  ))]);
}
