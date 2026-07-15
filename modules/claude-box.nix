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
  tmuxSessionName = "main";
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
  # Commands granted to EVERY declarative claude-box user.
  broadSudoCommands =
    cfg.sudoAllowlist
    ++ lib.optional cfg.web.enable caddyReloadCmd
    ++ lib.optionals cfg.selfUpdate.enable [ updateStartCmd updateStartNoBlockCmd ];
  # Commands granted ONLY to the operator user (web.user) — the box's main
  # admin surface. Creating another OS user is a bigger power than the broad
  # allowlist, so it doesn't fan out to every declarative agent.
  operatorSudoCommands =
    lib.optional cfg.runtimeAgents.enable claudeBoxAgentCmd;
  # Union — used for the NoNewPrivileges gate. Any setuid entry on any
  # user's unit needs NNP off; the split above is a sudoers-scope concern.
  effectiveSudoAllowlist = broadSudoCommands ++ operatorSudoCommands;
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
  agentDisplayName = agent:
    if agent == "claude" then "Claude Code"
    else "Codex";
  agentCommand = name: u:
    let
      agent = if u.agent != null then u.agent else cfg.agent;
      package = agentPackage agent;
      sessionName =
        if u.remoteControlName != null
        then u.remoteControlName
        else "${name}@${config.networking.fqdnOrHostName}";
      autonomyArgs =
        if !u.skipPermissions then [ ]
        else if agent == "claude" then [ "--dangerously-skip-permissions" ]
        else [ "--dangerously-bypass-approvals-and-sandbox" ];
      remoteArgs =
        if agent == "claude" && u.remoteControl
        then [ "--remote-control" sessionName ]
        else [ ];
    in {
      inherit agent package;
      displayName = agentDisplayName agent;
      command = lib.concatStringsSep " " (
        [ (lib.escapeShellArg (lib.getExe package)) ]
        ++ (map lib.escapeShellArg autonomyArgs)
        ++ (map lib.escapeShellArg remoteArgs)
        ++ (map lib.escapeShellArg u.extraArgs)
      );
    };

  userOpts = { name, ... }: {
    options = {
      agent = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum supportedAgents);
        default = null;
        description = ''
          Agent CLI to run for this user. When null, uses
          services.claude-box.agent.
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

  mkStart = name: u:
    let
      agent = agentCommand name u;
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
      # Runs on every start (idempotent), which also covers upstream's
      # occasional failure to persist an interactive acceptance
      # (anthropics/claude-code issue 36403). Codex has no such dialogs.
      seedClaudeState = ''
        seed_json() {
          # seed_json FILE JQ_ARGS... — jq-edit FILE in place, creating it
          # if missing. A file jq can't parse is left untouched: the dialog
          # comes back, but the agent still starts.
          file=$1; shift
          [ -s "$file" ] || printf '{}' > "$file"
          if ${pkgs.jq}/bin/jq "$@" "$file" > "$file.seed-tmp" 2>/dev/null; then
            mv "$file.seed-tmp" "$file"
          else
            rm -f "$file.seed-tmp"
          fi
        }
        mkdir -p /home/${name}/.claude
        seed_json /home/${name}/.claude.json --arg wd ${lib.escapeShellArg u.workingDirectory} \
          '.projects[$wd] = ((.projects[$wd] // {}) + {hasTrustDialogAccepted: true, hasCompletedProjectOnboarding: true})'
        ${lib.optionalString u.skipPermissions ''
          seed_json /home/${name}/.claude/settings.json \
            '.skipDangerousModePermissionPrompt = true'
        ''}
      '';
      # AGENTS.md — cross-vendor agent-instructions file (codex, opencode
      # native; claude-code as CLAUDE.md fallback). Only seed if absent so
      # the agent's own edits or a repo checkout in workingDirectory never
      # get clobbered. Content lives in the Nix store so no in-shell
      # quoting; $CLAUDE_BOX_URL and other $refs in the content stay
      # literal for the agent to expand at read time.
      agentsMdFile =
        if u.agentsMd == null then null
        else pkgs.writeText "claude-box-${name}-agents.md" u.agentsMd;
      seedAgentsMd = lib.optionalString (agentsMdFile != null) ''
        if [ ! -e ${lib.escapeShellArg "${u.workingDirectory}/AGENTS.md"} ]; then
          mkdir -p ${lib.escapeShellArg u.workingDirectory}
          install -m 0644 ${agentsMdFile} ${lib.escapeShellArg "${u.workingDirectory}/AGENTS.md"}
        fi
      '';
      # Every user-provided arg gets individually shell-escaped so a
      # remoteControlName or extraArgs element containing whitespace or shell
      # metacharacters can't inject into the tmux new-session command below.
    in
    pkgs.writeShellScript "claude-box-${name}-start" ''
      set -u
      ${lib.optionalString (agent.agent == "claude") seedClaudeState}
      ${seedAgentsMd}
      # Detached tmux session so a human can `tmux -L agent-box attach -t main`.
      # `|| exec bash` gives a POST-MORTEM shell ONLY on non-zero agent exit;
      # clean exits let the session die so systemd's Restart=always brings up
      # a fresh agent. (Was `; exec bash`, which pinned the session forever.)
      ${pkgs.tmux}/bin/tmux -L ${tmuxSocketName} new-session -d -s main \
        -c ${lib.escapeShellArg u.workingDirectory} \
        ${lib.escapeShellArg (agent.command + " || exec ${pkgs.bashInteractive}/bin/bash")}
      # Block ExecStart until the session actually goes away — a clean agent
      # exit, the user typing `exit` in the post-mortem bash, someone
      # `tmux kill-session`ing us, or ExecStop killing it. Type=exec + this
      # supervising tail lets Restart=always distinguish "session died on its
      # own" (restart) from "systemctl stop" (don't restart).
      while ${pkgs.tmux}/bin/tmux -L ${tmuxSocketName} has-session -t main 2>/dev/null; do
        sleep 2
      done
    '';

  # ---- Runtime-agent support (services.claude-box.runtimeAgents.enable) ----
  # Parent of the per-instance ttyd socket dirs. Each claude-web-terminal@
  # instance gets RuntimeDirectory=claude-web-terminal/%i — a systemd-owned
  # subdirectory the instance USER owns, holding that terminal's tty.sock
  # (0660 <user>:caddy via ttyd -U). Kept OUTSIDE /run/agent-box-<name>
  # (the agent unit's 0700 RuntimeDirectory) so caddy — a different uid —
  # can reach it; per-instance subdirs rather than one shared writable dir
  # so no other local user can pre-squat a future agent's socket path and
  # capture its (post-auth) terminal traffic. The settings sockets have no
  # such problem: systemd binds those as root via the template socket unit.
  runtimeTermSocketDir = "/run/claude-web-terminal";
  # Picker daemon (rendered inline below): served at "/" so runtime agents
  # show up without regenerating a static index. Root:caddy 0660.
  pickerSocketPath = "/run/claude-box-picker.sock";
  # Fixed path under the system profile so sudoers can name it. `useradd` +
  # `caddy hash-password` live under the same profile at nixos-rebuild time.
  claudeBoxAgentCmd = "/run/current-system/sw/bin/claude-box-agent";

  # Runtime-agent tmux launcher. Mirrors mkStart but reads the user name
  # from $1 (systemd passes it as %i) so a single script serves all runtime
  # instances. Deliberately does NOT read a per-user config file — v1
  # runtime agents get the module's default agent CLI, skipPermissions on,
  # remoteControl on (for claude), and remoteControlName = <name>@<host>.
  # If a user needs per-agent customization, they use the declarative
  # `services.claude-box.users.<name>` path.
  runtimeAgentStart =
    let
      agent = cfg.agent;
      package = agentPackage agent;
      autonomyFlag =
        if agent == "claude" then "--dangerously-skip-permissions"
        else "--dangerously-bypass-approvals-and-sandbox";
    in
    pkgs.writeShellScript "claude-box-runtime-start" ''
      set -u
      name="$1"
      workdir="/home/$name"
      ${lib.optionalString (agent == "claude") ''
        # Same startup-dialog pre-accept as mkStart's seedClaudeState (see
        # the rationale there), with user and workdir resolved at run time
        # from $1 instead of at eval time. Runtime agents always run with
        # the autonomy flag, so the Bypass Permissions acceptance is
        # seeded unconditionally.
        seed_json() {
          file=$1; shift
          [ -s "$file" ] || printf '{}' > "$file"
          if ${pkgs.jq}/bin/jq "$@" "$file" > "$file.seed-tmp" 2>/dev/null; then
            mv "$file.seed-tmp" "$file"
          else
            rm -f "$file.seed-tmp"
          fi
        }
        mkdir -p "/home/$name/.claude"
        seed_json "/home/$name/.claude.json" --arg wd "$workdir" \
          '.projects[$wd] = ((.projects[$wd] // {}) + {hasTrustDialogAccepted: true, hasCompletedProjectOnboarding: true})'
        seed_json "/home/$name/.claude/settings.json" \
          '.skipDangerousModePermissionPrompt = true'
      ''}
      # Session name for --remote-control (claude only). Falls back to the
      # bare hostname when networking.domain is unset — same shape as the
      # declarative default.
      host="${config.networking.fqdnOrHostName}"
      session_name="$name@$host"
      ${lib.optionalString (agent == "claude") ''
        agent_cmd=${lib.escapeShellArg (lib.getExe package)}" ${autonomyFlag} --remote-control $(printf %q "$session_name")"
      ''}
      ${lib.optionalString (agent == "codex") ''
        agent_cmd=${lib.escapeShellArg (lib.getExe package)}" ${autonomyFlag}"
      ''}
      ${pkgs.tmux}/bin/tmux -L ${tmuxSocketName} new-session -d -s ${tmuxSessionName} \
        -c "$workdir" \
        "$agent_cmd || exec ${pkgs.bashInteractive}/bin/bash"
      while ${pkgs.tmux}/bin/tmux -L ${tmuxSocketName} has-session -t ${tmuxSessionName} 2>/dev/null; do
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

    runtimeAgents = {
      enable = lib.mkEnableOption ''
        run-time provisioning of additional agent users WITHOUT nixos-rebuild.
        Adds systemd template units (claude-box@, claude-web-terminal@,
        claude-box-settings@) and a root-owned helper (`claude-box-agent
        add|remove|list`) that the operator (services.claude-box.web.user) can
        invoke through a single NOPASSWD sudo entry. Requires web.enable; new
        agents get the module's default agent CLI, autonomy flag on, and a
        browser terminal + settings page just like a declarative user. Runtime
        agents' vhost snippets land in /var/lib/claude-box-vhosts/ (imported by
        the top-level Caddyfile) with the bcrypt hash inlined so a caddy
        reload picks them up without restarting the daemon
      '';

      stateDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/claude-box-agents";
        description = ''
          Directory holding per-runtime-agent state (one subdirectory per
          agent, root-owned 0700). Presence of a subdirectory here is what
          identifies a name as runtime-managed vs declarative — the helper
          refuses names that already exist as OS users but have no state dir.
        '';
      };

      vhostsDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/claude-box-vhosts";
        description = ''
          Directory the top-level Caddyfile imports at runtime-agent-enabled
          hosts. The helper writes one <name>.caddy file per runtime agent
          (0640 root:caddy, bcrypt hash and cookie secret inline).
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [{
    assertions = [{
      assertion = cfg.users != { };
      message = "services.claude-box.enable is true but no users are defined in services.claude-box.users.";
    } {
      # Runtime agents need the shared web plumbing (Caddy vhost import,
      # settings-socket dir, picker daemon slot) — turning them on without
      # web enabled would silently do nothing.
      assertion = !cfg.runtimeAgents.enable || cfg.web.enable;
      message = "services.claude-box.runtimeAgents.enable = true requires services.claude-box.web.enable = true.";
    } {
      # The operator (services.claude-box.web.user) is what carries the
      # NOPASSWD claude-box-agent sudo entry, so they have to be a real
      # declarative user for the rule to land on any account.
      assertion = !cfg.runtimeAgents.enable || (cfg.users ? ${cfg.web.user});
      message = "services.claude-box.runtimeAgents.enable requires services.claude-box.web.user to be defined in services.claude-box.users.";
    } {
      # useradd-created users live in /etc/passwd; with mutableUsers = false
      # the next activation regenerates that file from the Nix config and
      # silently deletes every runtime agent.
      assertion = !cfg.runtimeAgents.enable || config.users.mutableUsers;
      message = "services.claude-box.runtimeAgents.enable requires users.mutableUsers = true (runtime agents are created with useradd).";
    }] ++ (lib.mapAttrsToList (name: u: {
      # Cheap sanity check on the one string that lands verbatim in a shell
      # command; deeper escaping happens in mkStart via lib.escapeShellArg.
      assertion = u.remoteControlName == null || (
        u.remoteControlName != ""
        && !(lib.hasInfix "\n" u.remoteControlName)
        && !(lib.hasInfix "\r" u.remoteControlName)
      );
      message = "services.claude-box.users.${name}.remoteControlName must be non-empty and free of newlines.";
    }) cfg.users);

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
      (lib.unique ((map (u: (agentCommand "" u).package) (lib.attrValues cfg.users)) ++ [ pkgs.tmux ] ++ cfg.extraPackages));

    systemd.services = lib.mapAttrs' (name: u:
      let agent = agentCommand name u;
      in
      lib.nameValuePair "claude-box-${name}" {
        description = "${agent.displayName} agent (tmux) for ${name}";
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
        path = [ "/home/${name}/.nix-profile" agent.package pkgs.tmux pkgs.bashInteractive pkgs.coreutils pkgs.git ]
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
          # ExecStart's mkStart supervises the tmux session and stays live for
          # as long as the session is alive, so systemd can distinguish clean
          # session termination (Restart=always kicks in -> fresh agent) from
          # explicit `systemctl stop` (which systemd never restarts through).
          Type = "exec";
          Restart = "always";
          RestartSec = "2s";
          # Upstream claude-code bug: the client persists only channelsEnabled
          # to ~/.claude/remote-settings.json, losing the org's channel-plugin
          # allowlist; the next launch trusts the stale cache and silently
          # drops every channel notification ("Channel notifications skipped"
          # in the MCP debug log). Clearing the cache before each start forces
          # a full policy fetch. Harmless otherwise — it's a cache file.
          ExecStartPre = "${pkgs.coreutils}/bin/rm -f /home/${name}/.claude/remote-settings.json";
          ExecStart = mkStart name u;
          ExecStop = "${pkgs.tmux}/bin/tmux -L ${tmuxSocketName} kill-session -t main";
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

    security.sudo.extraRules =
      # NOPASSWD only — no SETENV. SETENV lets the caller alter env vars
      # visible to the sudo'd command, which broadens the surface for no
      # gain given the allowlist is meant to be tight and command-scoped.
      (lib.optional (broadSudoCommands != [ ]) {
        users = lib.attrNames cfg.users;
        commands = map (command: { inherit command; options = [ "NOPASSWD" ]; }) broadSudoCommands;
      })
      ++ (lib.optional (operatorSudoCommands != [ ] && cfg.users ? ${cfg.web.user}) {
        users = [ cfg.web.user ];
        commands = map (command: { inherit command; options = [ "NOPASSWD" ]; }) operatorSudoCommands;
      });
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
        # restarts the agent by killing its tmux session (same uid, via the
        # PrivateTmp socket under TMUX_TMPDIR); the agent unit's Restart=always
        # brings it back with the fresh environment.
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
        #   CLAUDE_BOX_TMUX_SESSION       tmux session name (e.g. main)
        #   CLAUDE_BOX_TMUX_TMPDIR        TMUX_TMPDIR the agent's socket lives under
        #   CLAUDE_BOX_TMUX_BIN           absolute path to the tmux binary

        import html
        import http.server
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
        TMUX_SESSION = os.environ.get("CLAUDE_BOX_TMUX_SESSION", "main")
        TMUX_TMPDIR = os.environ.get("CLAUDE_BOX_TMUX_TMPDIR", "")
        TMUX_BIN = os.environ.get("CLAUDE_BOX_TMUX_BIN", "tmux")
        # Full sudo command line that triggers the box update (issue 54). Empty
        # when selfUpdate is off, which hides the Update card and 404s the route.
        UPDATE_CMD = os.environ.get("CLAUDE_BOX_UPDATE_CMD", "")

        # Full sudo command line that shells out to claude-box-agent (runtime
        # agent add/remove). Set only for the OPERATOR's settings daemon; empty
        # everywhere else, which hides the Add-agent card and 404s the routes.
        ADD_AGENT_CMD = os.environ.get("CLAUDE_BOX_ADD_AGENT_CMD", "")
        ADD_AGENT_DOMAIN = os.environ.get("CLAUDE_BOX_ADD_AGENT_DOMAIN", "")

        # Env var names: POSIX-ish. Must start with a letter or underscore and
        # contain only letters, digits, underscores. This is what a shell / systemd
        # EnvironmentFile will accept as a variable name.
        KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

        # Runtime-agent user names — same shape claude-box-agent enforces
        # server-side, echoed here so we can 400 obvious garbage before
        # spawning sudo.
        AGENT_NAME_RE = re.compile(r"^[a-z][a-z0-9_-]{1,31}$")


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


        def list_agents():
            """Return the sorted list of runtime agent names.

            Shells out to `sudo -n claude-box-agent list`. Runs even for
            non-operator daemons if ADD_AGENT_CMD is set (it isn't, elsewhere);
            returns [] if the helper fails or is absent.
            """
            if not ADD_AGENT_CMD:
                return []
            try:
                proc = subprocess.run(
                    ADD_AGENT_CMD.split() + ["list"],
                    check=False,
                    capture_output=True,
                    timeout=10,
                )
            except (OSError, subprocess.TimeoutExpired) as exc:
                sys.stderr.write("list_agents: %s\n" % exc)
                return []
            if proc.returncode != 0:
                sys.stderr.write("list_agents: rc=%d\n" % proc.returncode)
                return []
            names = []
            for line in proc.stdout.decode("utf-8", "replace").splitlines():
                line = line.strip()
                if AGENT_NAME_RE.match(line):
                    names.append(line)
            return sorted(set(names))


        def add_agent(name, password):
            """Spawn `sudo -n claude-box-agent add <name>` with the password on
            stdin. Returns (ok: bool, message: str) — message is a short
            human-readable status suitable for the redirect flash, never a raw
            copy of stderr (which could echo an attempted password).
            """
            if not ADD_AGENT_CMD:
                return False, "Add-agent disabled."
            if not AGENT_NAME_RE.match(name):
                return False, "Invalid agent name."
            try:
                proc = subprocess.run(
                    ADD_AGENT_CMD.split() + ["add", name],
                    input=(password + "\n").encode("utf-8"),
                    check=False,
                    capture_output=True,
                    timeout=30,
                )
            except (OSError, subprocess.TimeoutExpired) as exc:
                sys.stderr.write("add_agent: %s\n" % exc)
                return False, "Helper failed to spawn."
            sys.stderr.write("add_agent %s: rc=%d\n" % (name, proc.returncode))
            if proc.returncode == 0:
                return True, "Added."
            # Best-effort: surface stderr's *first* line only, and only if it
            # contains no obvious secret token. The password itself is never
            # echoed by the helper, but keep the surface narrow.
            first = proc.stderr.decode("utf-8", "replace").splitlines()[:1]
            hint = first[0] if first else "add failed"
            return False, "Add failed: " + hint[:120]


        def remove_agent(name):
            """Spawn `sudo -n claude-box-agent remove <name>`."""
            if not ADD_AGENT_CMD:
                return False, "Remove disabled."
            if not AGENT_NAME_RE.match(name):
                return False, "Invalid agent name."
            try:
                proc = subprocess.run(
                    ADD_AGENT_CMD.split() + ["remove", name],
                    check=False,
                    capture_output=True,
                    timeout=30,
                )
            except (OSError, subprocess.TimeoutExpired) as exc:
                sys.stderr.write("remove_agent: %s\n" % exc)
                return False, "Helper failed to spawn."
            sys.stderr.write("remove_agent %s: rc=%d\n" % (name, proc.returncode))
            if proc.returncode == 0:
                return True, "Removed."
            first = proc.stderr.decode("utf-8", "replace").splitlines()[:1]
            hint = first[0] if first else "remove failed"
            return False, "Remove failed: " + hint[:120]


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
          {update}
          {agents}
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

        # Operator-only: create/remove additional runtime agents from the
        # settings page. Only rendered when ADD_AGENT_CMD is set (see the
        # module: only the web.user's daemon receives it). The list of
        # existing runtime agents shows a Remove button per row; the form
        # accepts a name + password and shells out to claude-box-agent add.
        ADD_AGENT_CARD = """<div class="card">
            <h2 style="font-size:16px;margin-top:0">Additional agents</h2>
            <p class="note">Extra terminals share this box's hardware and its
            operator-level trust boundary. Each agent gets its own Linux user,
            browser terminal at <code>https://{domain}/&lt;name&gt;/</code>, and
            its own settings page.</p>
            {agent_rows}
            <form method="post" action="{base}/add-agent" style="margin-top:12px">
              <div class="row">
                <input type="text" name="name" placeholder="agent name"
                       pattern="[a-z][a-z0-9_-]{{1,31}}" required
                       title="Lowercase letters, digits, - and _; 2-32 chars; starts with a letter">
                <input type="password" name="password" placeholder="terminal password"
                       autocomplete="off" required
                       pattern="[A-Za-z0-9._~-]{{16,64}}"
                       title="16-64 chars from A-Za-z0-9._~-">
                <button type="submit">Add agent</button>
              </div>
              <p class="note">Password is 16-64 chars from
              <code>[A-Za-z0-9._~-]</code>. Save it somewhere — this page
              cannot recover it later.</p>
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


        def render_agent_rows(agents):
            if not agents:
                return '<p class="note">No additional agents yet.</p>'
            items = []
            for name in agents:
                safe = html.escape(name)
                items.append(
                    f'<li><code>{safe}</code>'
                    f'<form class="inline" method="post" action="{html.escape(BASE)}/remove-agent" '
                    f'onsubmit="return confirm(\'Remove agent {safe}? The user\\\'s /home/{safe} is preserved.\');">'
                    f'<input type="hidden" name="name" value="{safe}">'
                    f'<button type="submit" class="danger">Remove</button></form></li>'
                )
            return "<ul>" + "".join(items) + "</ul>"


        def render_page(message=""):
            msg_html = f'<div class="msg">{html.escape(message)}</div>' if message else ""
            agents_html = ""
            if ADD_AGENT_CMD:
                agents_html = ADD_AGENT_CARD.format(
                    base=html.escape(BASE),
                    domain=html.escape(ADD_AGENT_DOMAIN),
                    agent_rows=render_agent_rows(list_agents()),
                )
            return PAGE.format(
                user=html.escape(USER),
                base=html.escape(BASE),
                keys=render_keys(read_keys()),
                message=msg_html,
                update=UPDATE_CARD.format(base=html.escape(BASE)) if UPDATE_CMD else "",
                agents=agents_html,
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
                        "update": "Box update started — the system rebuilds in the "
                                  "background and this page may briefly go away.",
                        "agent-added": "Agent added.",
                        "agent-removed": "Agent removed.",
                    }.get(params["ok"][0], "")
                if "err" in params:
                    message = params["err"][0][:200]
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
                elif path == BASE + "/update" and UPDATE_CMD:
                    update_box()
                    self._redirect("ok=update")
                elif path == BASE + "/add-agent" and ADD_AGENT_CMD:
                    name = (form.get("name", [""])[0]).strip()
                    password = form.get("password", [""])[0]
                    ok, msg = add_agent(name, password)
                    if ok:
                        self._redirect("ok=agent-added")
                    else:
                        self._redirect("err=" + urllib.parse.quote(msg))
                elif path == BASE + "/remove-agent" and ADD_AGENT_CMD:
                    name = (form.get("name", [""])[0]).strip()
                    ok, msg = remove_agent(name)
                    if ok:
                        self._redirect("ok=agent-removed")
                    else:
                        self._redirect("err=" + urllib.parse.quote(msg))
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

      # Static picker: unauthenticated /: HTML listing terminals. Used when
      # runtimeAgents is off — the set of users is fixed at eval time so a
      # baked-in respond block is cheapest. When runtimeAgents is on, the
      # picker becomes a reverse_proxy to a small daemon (below) that
      # enumerates the runtime state dir at request time so freshly-added
      # agents show up without a caddy reload.
      pickerBlockStatic = ''
        # Anything else, including /: unauthenticated picker listing this
        # box's terminals. User names are not secrets; the passwords are.
        handle {
          header Content-Type "text/html; charset=utf-8"
          respond <<PICKER_HTML
            <!doctype html>
            <html lang="en">
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="robots" content="noindex">
            <title>Terminals — ${cfg.web.domain}</title>
            <style>
              body { margin: 0; min-height: 100vh; display: grid; place-items: center;
                     background: #0d1117; color: #e6edf3; font: 16px/1.6 system-ui, sans-serif; }
              main { text-align: center; }
              main .row { display: flex; gap: 8px; margin: 10px 0; align-items: stretch; }
              main a { display: flex; align-items: center; justify-content: center;
                       padding: 12px 36px;
                       border: 1px solid #30363d; border-radius: 10px; background: #161b22;
                       color: #e8a087; font-size: 20px; text-decoration: none; }
              main a.term { flex: 1; }
              main a.gear { padding: 12px 18px; text-decoration: none; }
              main a:hover { border-color: #e8a087; }
            </style>
            <main>
              <h1>Terminals</h1>
              ${/* No ${n}@ userinfo in these hrefs: Chrome answers the basic-auth
                    challenge with URL userinfo + an EMPTY password, and credentials
                    typed into the prompt cannot override the URL-embedded identity
                    (issue 56). */
                lib.concatMapStringsSep "\n      " (n: ''<div class="row"><a class="term" href="https://${cfg.web.domain}/${n}/">${n}</a><a class="gear" href="https://${cfg.web.domain}/${n}/settings/" title="${n} settings" aria-label="${n} settings">&#9881;</a></div>'') terminalUsers}
            </main>
            PICKER_HTML 200
        }
      '';
      pickerBlockDaemon = ''
        # Runtime-agents mode: picker is a small daemon (root:caddy 0660
        # unix socket) that lists declarative + runtime terminals at
        # request time. No caddy reload needed when a runtime agent is
        # added.
        handle {
          reverse_proxy unix/${pickerSocketPath}
        }
      '';
      pickerBlock = if cfg.runtimeAgents.enable then pickerBlockDaemon else pickerBlockStatic;

      # Runtime-agent vhost snippets — one <name>.caddy per agent, written
      # by claude-box-agent with the bcrypt hash and cookie secret inline
      # (0640 root:caddy, so the world-readable /nix/store never holds the
      # hash). Empty when runtimeAgents is off.
      runtimeVhostImport = lib.optionalString cfg.runtimeAgents.enable ''

        # Runtime-agent vhosts. Written/removed by claude-box-agent; a
        # caddy reload picks new agents up without a nixos-rebuild.
        import ${cfg.runtimeAgents.vhostsDir}/*.caddy
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
      + indent "  " runtimeVhostImport
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

      # -----------------------------------------------------------------
      # Runtime-agent helpers. Only wired into config below when
      # cfg.runtimeAgents.enable, but defined here so both share the web
      # block's `settingsDaemon` binding (settings socket path, module
      # constants) without a second let scope.
      # -----------------------------------------------------------------

      # Root helper for adding/removing OS-level agent users at runtime,
      # invoked by the operator (services.claude-box.web.user) through a
      # single NOPASSWD sudo entry. Everything else about a new agent —
      # tmux service, ttyd, settings daemon, Caddy vhost — is derived
      # from state files this helper writes; no nixos-rebuild involved.
      #
      # Trust model: sudoers grants the OPERATOR the ability to invoke
      # this binary with any arguments; input validation (name shape,
      # password shape, reserved-name checks, collision checks) lives
      # entirely inside the helper. Password is read from stdin, never
      # from argv, so it never lands in /proc/*/cmdline.
      helperScript = pkgs.writeShellApplication {
        name = "claude-box-agent";
        runtimeInputs = with pkgs; [
          shadow caddy openssl coreutils gnugrep gnused systemd util-linux findutils
        ];
        # The Nix-generated `declarative_user` case body confuses
        # shellcheck when cfg.users is empty; and the rm -rf line only
        # ever removes paths under a Nix-baked, non-empty state dir with
        # a name that passed name_ok — SC2115's warning about expanding
        # to `/` is not reachable here.
        excludeShellChecks = [ "SC2317" "SC2115" ];
        text = ''
          # Runtime-agent add/remove helper (claude-box).
          if [ "$(id -u)" -ne 0 ]; then
            echo "claude-box-agent: must run as root (via sudo)" >&2
            exit 2
          fi

          STATE_DIR=${lib.escapeShellArg cfg.runtimeAgents.stateDir}
          VHOSTS_DIR=${lib.escapeShellArg cfg.runtimeAgents.vhostsDir}
          DOMAIN=${lib.escapeShellArg cfg.web.domain}
          OPERATOR=${lib.escapeShellArg cfg.web.user}

          name_ok() {
            [[ "$1" =~ ^[a-z][a-z0-9_-]{1,31}$ ]]
          }

          # Same shape as the CFN WebPassword parameter — punctuation
          # limited to the URL-safe subset so the value survives every
          # transport (env file, curl -u, cookie) without escaping.
          password_ok() {
            [[ "$1" =~ ^[A-Za-z0-9._~-]{16,64}$ ]]
          }

          reserved_name() {
            case "$1" in
              root|caddy|nobody|nogroup|systemd-*|nixbld*|"$OPERATOR") return 0 ;;
            esac
            return 1
          }

          # Any name defined in services.claude-box.users at eval time —
          # baked in so runtime add cannot shadow a declarative agent.
          declarative_user() {
            case "$1" in
          ${lib.concatMapStrings (n: "    ${lib.escapeShellArg n}) return 0 ;;\n") (lib.attrNames cfg.users)}
              *) return 1 ;;
            esac
          }

          cmd_add() {
            local name="''${1:-}" password
            if ! name_ok "$name"; then
              echo "invalid name: must match [a-z][a-z0-9_-]{1,31}" >&2
              exit 2
            fi
            if reserved_name "$name"; then
              echo "refusing reserved name: $name" >&2
              exit 2
            fi
            if declarative_user "$name"; then
              echo "refusing: $name is a declarative claude-box user" >&2
              exit 2
            fi
            if [ -d "$STATE_DIR/$name" ]; then
              echo "already exists: $name" >&2
              exit 2
            fi
            if id -u "$name" >/dev/null 2>&1; then
              echo "OS user $name already exists outside claude-box control" >&2
              exit 2
            fi

            # Password from stdin (single line) so it never lands in argv
            # or process env. `read` returns 1 on EOF without newline —
            # that's the common shell case, ignore it and validate the
            # value we got.
            IFS= read -r password || true
            if ! password_ok "$password"; then
              echo "invalid password: 16-64 chars from [A-Za-z0-9._~-]" >&2
              exit 2
            fi

            # Everything sensitive (bcrypt hash, cookie secret) lands in
            # the vhost snippet, mode 0640 root:caddy — no separate
            # state file, no env-var indirection, so a caddy reload picks
            # the new user up without restarting the daemon.
            cookie_secret="$(openssl rand -hex 32)"
            # Not --plaintext: that would put the password in the caddy
            # subprocess's argv, world-readable via /proc for its (brief)
            # lifetime. On a non-tty stdin caddy reads password +
            # confirmation lines instead.
            password_hash="$(printf '%s\n%s\n' "$password" "$password" | caddy hash-password)"

            # OS user. `caddy` supplementary group lets the per-user
            # settings daemon chown its unix socket 0660 <name>:caddy.
            useradd -m -s ${pkgs.bashInteractive}/bin/bash -G caddy "$name"
            # cmd_remove preserves /home/$name, so a recycled name may find
            # an old home owned by a now-recycled uid — re-own it so the new
            # incarnation can use it. No-op on a fresh home. "$name:" =
            # the user's login group (useradd here creates no per-user
            # group). Does not dereference symlinks (GNU chown -R default),
            # and fs.protected_hardlinks (NixOS default) blocks the
            # hardlink-to-root-file trick, so this can't be steered at
            # files outside the home.
            chown -R "$name:" "/home/$name"

            install -d -m 0700 -o root -g root "$STATE_DIR/$name"

            umask 037
            tmp="$(mktemp "$VHOSTS_DIR/.$name.caddy.XXXXXX")"
            cat >"$tmp" <<CADDY
          # Runtime agent: $name (managed by claude-box-agent — do not edit).
          redir /$name /$name/
          handle /$name/settings* {
            @cookie_settings_$name header_regexp Cookie "(^|; )__Host-agent_box_auth_$name=$cookie_secret(;|$)"
            handle @cookie_settings_$name {
              reverse_proxy unix/${settingsSocketDir}/$name.sock
            }
            handle {
              route {
                basic_auth bcrypt $name {
                  $name $password_hash
                }
                header >Set-Cookie "__Host-agent_box_auth_$name=$cookie_secret; Path=/; Max-Age=2592000; HttpOnly; Secure; SameSite=Strict"
                reverse_proxy unix/${settingsSocketDir}/$name.sock
              }
            }
          }
          handle /$name/* {
            @cookie_$name header_regexp Cookie "(^|; )__Host-agent_box_auth_$name=$cookie_secret(;|$)"
            handle @cookie_$name {
              reverse_proxy unix/${runtimeTermSocketDir}/$name/tty.sock
            }
            handle {
              route {
                basic_auth bcrypt $name {
                  $name $password_hash
                }
                header >Set-Cookie "__Host-agent_box_auth_$name=$cookie_secret; Path=/; Max-Age=2592000; HttpOnly; Secure; SameSite=Strict"
                reverse_proxy unix/${runtimeTermSocketDir}/$name/tty.sock
              }
            }
          }
          CADDY
            chown root:caddy "$tmp"
            chmod 0640 "$tmp"
            mv "$tmp" "$VHOSTS_DIR/$name.caddy"

            # Reload first so the new vhost is live before services come
            # up (avoids a brief 502 window on the first hit).
            systemctl reload caddy.service

            systemctl start "claude-box-settings@$name.socket"
            systemctl start "claude-box@$name.service"
            systemctl start "claude-web-terminal@$name.service"

            echo "added: $name (https://$DOMAIN/$name/)"
          }

          cmd_remove() {
            local name="''${1:-}"
            if ! name_ok "$name"; then
              echo "invalid name" >&2
              exit 2
            fi
            if [ ! -d "$STATE_DIR/$name" ]; then
              echo "not a runtime agent: $name" >&2
              exit 2
            fi
            # Best-effort — template units may already be inactive.
            systemctl stop "claude-web-terminal@$name.service" 2>/dev/null || true
            systemctl stop "claude-box@$name.service" 2>/dev/null || true
            systemctl stop "claude-box-settings@$name.service" 2>/dev/null || true
            systemctl stop "claude-box-settings@$name.socket" 2>/dev/null || true
            rm -f "$VHOSTS_DIR/$name.caddy"
            systemctl reload caddy.service 2>/dev/null || true
            rm -rf "$STATE_DIR/$name"
            # Leave /home/$name intact — matches the module's stance that
            # each agent home is untrusted state to back up or wipe with
            # intent. Operator can rm -rf later.
            userdel "$name" 2>/dev/null || true
            echo "removed: $name (home /home/$name preserved)"
          }

          cmd_list() {
            [ -d "$STATE_DIR" ] || return 0
            find "$STATE_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
          }

          case "''${1:-}" in
            add)    shift; cmd_add "$@" ;;
            remove) shift; cmd_remove "$@" ;;
            list)   shift; cmd_list "$@" ;;
            *) echo "usage: claude-box-agent {add|remove|list} [name]" >&2; exit 2 ;;
          esac
        '';
      };

      # Picker daemon (issue: dynamic terminal listing under runtime
      # agents). Serves the same HTML as the static picker but enumerates
      # the runtime state dir at request time, so a freshly-added agent
      # shows up without regenerating any file. Root:caddy 0660 unix
      # socket; adopted through socket activation (LISTEN_FDS).
      # Same Python-3-stdlib-only rule as the settings daemon so the
      # module stays audit-friendly.
      pickerDaemon = pkgs.writers.writePython3Bin "claude-box-picker" {
        flakeIgnore = [ "E501" "E302" "E305" "W503" "E226" ];
      } ''
        import html
        import http.server
        import os
        import re
        import socket
        import sys

        DOMAIN = os.environ.get("CLAUDE_BOX_PICKER_DOMAIN", "")
        DECLARATIVE = [
            u for u in os.environ.get("CLAUDE_BOX_PICKER_DECLARATIVE_USERS", "").split(",") if u
        ]
        RUNTIME_DIR = os.environ.get("CLAUDE_BOX_PICKER_RUNTIME_DIR", "/var/lib/claude-box-agents")

        NAME_RE = re.compile(r"^[a-z][a-z0-9_-]{1,31}$")


        def runtime_users():
            try:
                names = os.listdir(RUNTIME_DIR)
            except OSError:
                return []
            out = []
            for name in sorted(names):
                if not NAME_RE.match(name):
                    continue
                if os.path.isdir(os.path.join(RUNTIME_DIR, name)):
                    out.append(name)
            return out


        PAGE = """<!doctype html>
        <html lang="en">
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="robots" content="noindex">
        <title>Terminals — {domain}</title>
        <style>
          body {{ margin: 0; min-height: 100vh; display: grid; place-items: center;
                 background: #0d1117; color: #e6edf3; font: 16px/1.6 system-ui, sans-serif; }}
          main {{ text-align: center; }}
          main .row {{ display: flex; gap: 8px; margin: 10px 0; align-items: stretch; }}
          main a {{ display: flex; align-items: center; justify-content: center;
                   padding: 12px 36px;
                   border: 1px solid #30363d; border-radius: 10px; background: #161b22;
                   color: #e8a087; font-size: 20px; text-decoration: none; }}
          main a.term {{ flex: 1; }}
          main a.gear {{ padding: 12px 18px; text-decoration: none; }}
          main a:hover {{ border-color: #e8a087; }}
        </style>
        <main>
          <h1>Terminals</h1>
        {rows}
        </main>
        </html>
        """


        def render_row(user):
            safe = html.escape(user)
            return (
                f'    <div class="row"><a class="term" href="/{safe}/">{safe}</a>'
                f'<a class="gear" href="/{safe}/settings/" title="{safe} settings" '
                f'aria-label="{safe} settings">&#9881;</a></div>'
            )


        def render():
            # dict.fromkeys keeps first-occurrence order and dedups if a
            # runtime name accidentally shadows a declarative one (the
            # helper refuses that at add-time, but harmless as a belt).
            seen = list(dict.fromkeys(DECLARATIVE + runtime_users()))
            rows = "\n".join(render_row(u) for u in seen)
            return PAGE.format(domain=html.escape(DOMAIN), rows=rows)


        class Handler(http.server.BaseHTTPRequestHandler):
            server_version = "claude-box-picker/1"

            def do_GET(self):
                body = render().encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.send_header("X-Content-Type-Options", "nosniff")
                self.end_headers()
                self.wfile.write(body)

            def address_string(self):
                if isinstance(self.client_address, tuple) and self.client_address:
                    return super().address_string()
                return "unix"

            def log_message(self, fmt, *args):
                sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


        SD_LISTEN_FDS_START = 3


        class UnixHTTPServer(http.server.ThreadingHTTPServer):
            # AF_UNIX so __init__'s placeholder socket() call stays within the
            # unit's RestrictAddressFamilies=AF_UNIX (an AF_INET placeholder
            # dies with EAFNOSUPPORT before the activation fd is adopted).
            address_family = socket.AF_UNIX


        def make_server():
            if int(os.environ.get("LISTEN_FDS", "0") or "0") >= 1:
                server = UnixHTTPServer(
                    ("127.0.0.1", 0), Handler, bind_and_activate=False
                )
                # Swap the never-bound placeholder for the systemd-bound fd.
                server.socket.close()
                server.socket = socket.socket(fileno=SD_LISTEN_FDS_START)
                server.server_name = "claude-box-picker"
                server.server_port = 0
                return server
            # Dev fallback — not used by the module (always socket-activated).
            return http.server.ThreadingHTTPServer(("127.0.0.1", 8079), Handler)


        if __name__ == "__main__":
            make_server().serve_forever()
      '';
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
      ) terminalUsers
      # Runtime-agent state. stateDir is 0700 root-only (holds nothing
      # sensitive right now, but that's the trust boundary); vhostsDir is
      # 0755 root:caddy so caddy can traverse to read individual snippet
      # files (which themselves are 0640 root:caddy — the bcrypt hash and
      # cookie secret live inside each snippet, no separate secrets file).
      # runtimeTermSocketDir only holds the per-instance RuntimeDirectory
      # subdirs (see its definition for the squatting rationale) — root-owned
      # 0755, explicit here even though systemd would create it on demand.
      ++ lib.optionals cfg.runtimeAgents.enable [
        "d ${cfg.runtimeAgents.stateDir} 0700 root root - -"
        "d ${cfg.runtimeAgents.vhostsDir} 0755 root caddy - -"
        "d ${runtimeTermSocketDir} 0755 root root - -"
      ];

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
            "-p" (toString portOf.${name})
            "-i" "127.0.0.1"
            "-b" "/${name}"
            "-t" "titleFixed=${name}@${cfg.web.domain}"
            "${pkgs.tmux}/bin/tmux" "-L" tmuxSocketName "attach" "-t" "main"
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
          CLAUDE_BOX_TMUX_SESSION = tmuxSessionName;
          CLAUDE_BOX_TMUX_TMPDIR = "/run/${runtimeDirectory name}";
          CLAUDE_BOX_TMUX_BIN = "${pkgs.tmux}/bin/tmux";
        } // lib.optionalAttrs cfg.selfUpdate.enable {
          # --no-block so the daemon's HTTP response goes out before the
          # rebuild (possibly) restarts the daemon itself.
          CLAUDE_BOX_UPDATE_CMD = "/run/wrappers/bin/sudo -n ${updateStartNoBlockCmd}";
        } // lib.optionalAttrs (cfg.runtimeAgents.enable && name == webUser) {
          # Runtime-agent management from the settings page — visible only
          # on the operator's own settings daemon. Sudo entry is
          # operator-only (see operatorSudoCommands); the daemon shells
          # out here with the password on stdin.
          CLAUDE_BOX_ADD_AGENT_CMD = "/run/wrappers/bin/sudo -n ${claudeBoxAgentCmd}";
          CLAUDE_BOX_ADD_AGENT_DOMAIN = cfg.web.domain;
        };
        serviceConfig = {
          User = name;
          Restart = "always";
          RestartSec = "5s";
          ExecStart = "${settingsDaemon}/bin/claude-box-settings";
          # Hardening: the daemon needs to write ~/.config/claude-box and run
          # tmux against the /run socket dir, nothing else — EXCEPT the
          # operator's daemon under runtimeAgents: its sudo'd claude-box-agent
          # child runs inside THIS unit's mount namespace, and
          # ProtectSystem=strict is a namespace property, not a uid check —
          # it vetoes even root's useradd writing /etc, creating /home/<n>,
          # or managing the state/vhost dirs. Drop it just there; plain DAC
          # still keeps the daemon's own (non-root) uid out of those paths.
          ProtectSystem =
            if cfg.runtimeAgents.enable && name == webUser then false else "strict";
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
          # argument-free update trigger, and — on the operator's daemon —
          # the runtime-agent helper), so relax NNP only for those cases.
          NoNewPrivileges =
            !(cfg.selfUpdate.enable || (cfg.runtimeAgents.enable && name == webUser));
        };
      }) terminalUsers)
      // lib.optionalAttrs cfg.runtimeAgents.enable {
        # ---- Runtime-agent template units ----
        # One tmux-backed agent per runtime user. Systemd substitutes %i
        # (the instance name) at start time, so a single template serves
        # every runtime agent. Mirrors the declarative claude-box-<name>
        # service, minus the per-user customization surface — runtime
        # agents get the module's default agent CLI and its default
        # flags. For customization, add the user declaratively.
        "claude-box@" = {
          description = "Runtime coding-agent (tmux) for %I";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          # Deliberately no wantedBy — instances come up via
          # `systemctl start` from the claude-box-agent helper.
          # %i in a path list is preserved through makeBinPath and
          # expanded by systemd in the resulting PATH env var.
          path = [ "/home/%i/.nix-profile" (agentPackage cfg.agent) pkgs.tmux pkgs.bashInteractive pkgs.coreutils pkgs.git ]
            ++ cfg.extraPackages;
          environment = {
            HOME = "/home/%i";
            TMUX_TMPDIR = "/run/agent-box-%i";
            TERM = "xterm-256color";
            # Unconditional (unlike the declarative unit's optionalAttrs):
            # every runtime agent has a browser terminal by construction.
            CLAUDE_BOX_URL = "https://${cfg.web.domain}/%i/";
          };
          serviceConfig = {
            User = "%i";
            Type = "exec";
            Restart = "always";
            RestartSec = "2s";
            # Same channel-plugin-cache reset the declarative unit does.
            ExecStartPre = "${pkgs.coreutils}/bin/rm -f /home/%i/.claude/remote-settings.json";
            ExecStart = "${runtimeAgentStart} %i";
            ExecStop = "${pkgs.tmux}/bin/tmux -L ${tmuxSocketName} kill-session -t ${tmuxSessionName}";
            EnvironmentFile = [ "-/home/%i/.config/claude-box/env" ];
            RuntimeDirectory = "agent-box-%i";
            RuntimeDirectoryMode = "0700";
            RuntimeDirectoryPreserve = "yes";
            PrivateTmp = true;
            PrivateDevices = true;
            ProtectSystem = "strict";
            ReadWritePaths = [ "/home/%i" ];
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectControlGroups = true;
            ProtectClock = true;
            RestrictSUIDSGID = true;
            RestrictRealtime = true;
            LockPersonality = true;
            # Runtime users are not in cfg.users, so effectiveSudoAllowlist
            # never applied to them anyway — NNP=true is unconditionally
            # safe here.
            NoNewPrivileges = true;
          } // lib.optionalAttrs cfg.protectMemory {
            # Same memory-pressure stance as the declarative agent units:
            # sacrifice agent work before sshd/caddy/SSM.
            OOMScoreAdjust = lib.mkDefault 500;
          };
        };
        # Browser terminal on a unix socket rather than a localhost port.
        # ttyd's -U <user>:<group> sets the socket owner directly, so no
        # chmod dance in a wrapper is needed.
        "claude-web-terminal@" = {
          description = "Browser terminal (ttyd) for %I";
          after = [ "claude-box@%i.service" "network-online.target" ];
          wants = [ "network-online.target" ];
          environment.TMUX_TMPDIR = "/run/agent-box-%i";
          serviceConfig = {
            User = "%i";
            Restart = "always";
            RestartSec = "5s";
            # Per-instance socket dir owned by the instance user — ttyd
            # (running as %i) can bind there, and no other local user can
            # squat the path (see runtimeTermSocketDir).
            RuntimeDirectory = "claude-web-terminal/%i";
            RuntimeDirectoryMode = "0755";
            ExecStart = lib.concatStringsSep " " [
              "${pkgs.ttyd}/bin/ttyd"
              "--writable"
              "-i" "${runtimeTermSocketDir}/%i/tty.sock"
              "-U" "%i:caddy"
              "-b" "/%i"
              "-t" "titleFixed=%i@${cfg.web.domain}"
              "${pkgs.tmux}/bin/tmux" "-L" tmuxSocketName "attach" "-t" tmuxSessionName
            ];
            ProtectSystem = "strict";
            ProtectHome = "read-only";
            PrivateDevices = true;
            NoNewPrivileges = true;
          };
        };
        # Per-runtime-agent settings daemon. Same binary as the
        # declarative one (reads the same env-var contract), just
        # activated through the template socket unit above.
        "claude-box-settings@" = {
          description = "Per-user secrets settings page for %I";
          requires = [ "claude-box-settings@%i.socket" ];
          after = [ "network-online.target" "claude-box-settings@%i.socket" ];
          wants = [ "network-online.target" ];
          environment = {
            TMUX_TMPDIR = "/run/agent-box-%i";
            CLAUDE_BOX_SETTINGS_USER = "%i";
            CLAUDE_BOX_SETTINGS_ENV_FILE = "/home/%i/.config/claude-box/env";
            CLAUDE_BOX_SETTINGS_BASE = "/%i/settings";
            CLAUDE_BOX_TMUX_SOCKET = tmuxSocketName;
            CLAUDE_BOX_TMUX_SESSION = tmuxSessionName;
            CLAUDE_BOX_TMUX_TMPDIR = "/run/agent-box-%i";
            CLAUDE_BOX_TMUX_BIN = "${pkgs.tmux}/bin/tmux";
          };
          serviceConfig = {
            User = "%i";
            Restart = "always";
            RestartSec = "5s";
            ExecStart = "${settingsDaemon}/bin/claude-box-settings";
            ProtectSystem = "strict";
            ReadWritePaths = [ "/home/%i" "/run/agent-box-%i" ];
            ProtectHome = false;
            PrivateDevices = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectControlGroups = true;
            RestrictSUIDSGID = true;
            RestrictRealtime = true;
            LockPersonality = true;
            NoNewPrivileges = true;
          };
        };
        # Boot-time reconcile. The helper starts template instances
        # imperatively and they have no wantedBy, so nothing would bring
        # runtime agents back after a reboot (or an EC2 spot restart).
        # This oneshot walks the state dir — the single source of truth
        # for "is <name> a runtime agent" — and starts the trio for each
        # entry. A oneshot loop rather than `systemctl enable` symlinks:
        # NixOS regenerates /etc/systemd/system on every switch, so
        # runtime enablement links there are not durable.
        claude-box-runtime-reconcile = {
          description = "Start runtime agents recorded in ${cfg.runtimeAgents.stateDir}";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          path = [ pkgs.coreutils pkgs.systemd ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            shopt -s nullglob
            for state in ${cfg.runtimeAgents.stateDir}/*/; do
              name=$(basename "$state")
              systemctl start --no-block "claude-box-settings@$name.socket"
              systemctl start --no-block "claude-box@$name.service"
              systemctl start --no-block "claude-web-terminal@$name.service"
            done
          '';
        };
        # Picker daemon. stateDir is 0700 root:root, so a non-root
        # DynamicUser could not list it. Run as root (the daemon holds no
        # user credentials anyway — it serves an unauthenticated picker)
        # with tight hardening below.
        claude-box-picker = {
          description = "Terminal picker daemon";
          requires = [ "claude-box-picker.socket" ];
          after = [ "claude-box-picker.socket" ];
          wantedBy = [ "multi-user.target" ];
          environment = {
            CLAUDE_BOX_PICKER_DOMAIN = cfg.web.domain;
            CLAUDE_BOX_PICKER_DECLARATIVE_USERS = lib.concatStringsSep "," terminalUsers;
            CLAUDE_BOX_PICKER_RUNTIME_DIR = cfg.runtimeAgents.stateDir;
          };
          serviceConfig = {
            User = "root";
            Restart = "always";
            RestartSec = "5s";
            ExecStart = "${pickerDaemon}/bin/claude-box-picker";
            # Runs as root but touches almost nothing — just read the
            # state dir at request time. Hardening bounds the blast
            # radius so a listing bug can't wander further.
            ProtectSystem = "strict";
            ProtectHome = true;
            ReadOnlyPaths = [ cfg.runtimeAgents.stateDir ];
            PrivateDevices = true;
            PrivateTmp = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectControlGroups = true;
            ProtectClock = true;
            RestrictSUIDSGID = true;
            RestrictRealtime = true;
            RestrictAddressFamilies = [ "AF_UNIX" ];
            LockPersonality = true;
            NoNewPrivileges = true;
          };
        };
      };

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
      }) terminalUsers)
      // lib.optionalAttrs cfg.runtimeAgents.enable {
        # Picker daemon socket. Root:caddy 0660 — root owns because the
        # daemon doesn't run as a real user (see the service below); caddy
        # is the only client that talks to it via reverse_proxy.
        claude-box-picker = {
          description = "Picker socket";
          wantedBy = [ "sockets.target" ];
          socketConfig = {
            ListenStream = pickerSocketPath;
            SocketUser = "root";
            SocketGroup = "caddy";
            SocketMode = "0660";
          };
        };
        # Settings-daemon template socket. `%i` in ListenStream and
        # SocketUser is expanded by systemd at instance activation, so
        # `systemctl start claude-box-settings@alice.socket` binds
        # /run/claude-box-settings/alice.sock 0660 alice:caddy — the
        # same story as the declarative sockets above, generalized.
        "claude-box-settings@" = {
          description = "Settings page socket for %I";
          socketConfig = {
            ListenStream = "${settingsSocketDir}/%i.sock";
            SocketUser = "%i";
            SocketGroup = "caddy";
            SocketMode = "0660";
          };
        };
      };

      # Runtime-agent helper is on every user's PATH — most invocations
      # go via sudo -n, but stashing it here keeps `claude-box-agent list`
      # working under any interactive root shell. mkIf (rather than
      # `// optionalAttrs cfg.…` at the top of the return attrset) keeps
      # the module system's shape-determination step from recursing
      # through cfg on its own definition.
      environment.systemPackages = lib.mkIf cfg.runtimeAgents.enable [ helperScript ];
    }
  ))]);
}
