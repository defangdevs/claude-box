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
  effectiveSudoAllowlist =
    cfg.sudoAllowlist
    ++ lib.optional cfg.web.enable caddyReloadCmd
    ++ lib.optional cfg.selfUpdate.enable updateStartCmd;
  agentPackage = agent:
    if cfg.package != null then cfg.package
    else if agent == "claude" then pkgs.claude-code
    else pkgs.codex;
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
      # Every user-provided arg gets individually shell-escaped so a
      # remoteControlName or extraArgs element containing whitespace or shell
      # metacharacters can't inject into the tmux new-session command below.
    in
    pkgs.writeShellScript "claude-box-${name}-start" ''
      set -u
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
        `systemctl start claude-box-update.service` — a root oneshot that
        fast-forwards the box to the upstream repo's latest default-branch
        commit by rewriting `pinFile` and running `nixos-rebuild switch`.
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
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [{
    assertions = [{
      assertion = cfg.users != { };
      message = "services.claude-box.enable is true but no users are defined in services.claude-box.users.";
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
        environment = { HOME = "/home/${name}"; TMUX_TMPDIR = "/run/${runtimeDirectory name}"; } // u.environment;
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
  } (lib.mkIf cfg.selfUpdate.enable {
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
      path = [ pkgs.curl pkgs.jq pkgs.openssl pkgs.coreutils pkgs.util-linux ];
      environment = {
        REPO = cfg.selfUpdate.repo;
        CURRENT_REV = cfg.selfUpdate.rev;
        PIN_FILE = cfg.selfUpdate.pinFile;
        # nixos-rebuild resolves <nixpkgs> via NIX_PATH, which systemd units
        # don't inherit; point it at root's channel (the NixOS AMI default).
        NIX_PATH = "nixpkgs=/nix/var/nix/profiles/per-user/root/channels/nixos:nixos-config=/etc/nixos/configuration.nix";
      };
      serviceConfig.Type = "oneshot";
      script = ''
        set -euo pipefail
        api() { curl -fsSL -H 'Accept: application/vnd.github+json' "$1"; }

        target="$(api "https://api.github.com/repos/$REPO/commits/HEAD" | jq -r .sha)"
        if [ "$target" = "$CURRENT_REV" ]; then
          echo "already at upstream HEAD ($target)"
          exit 0
        fi

        # Fast-forward only: a target that isn't strictly ahead of the
        # running rev means upstream history was rewritten or an older
        # (possibly vulnerable) rev is being replayed — refuse both.
        status="$(api "https://api.github.com/repos/$REPO/compare/$CURRENT_REV...$target" | jq -r .status)"
        if [ "$status" != "ahead" ]; then
          echo "refusing update: $target is '$status' of running rev $CURRENT_REV (need fast-forward)" >&2
          exit 1
        fi

        module="$(mktemp)"
        trap 'rm -f "$module"' EXIT
        curl -fsSL "https://raw.githubusercontent.com/$REPO/$target/modules/claude-box.nix" -o "$module"
        sha="sha256-$(openssl dgst -sha256 -binary "$module" | base64)"

        if [ -e "$PIN_FILE" ]; then
          cp "$PIN_FILE" "$PIN_FILE.prev"
        fi
        printf '{ rev = "%s"; sha256 = "%s"; }\n' "$target" "$sha" > "$PIN_FILE.tmp"
        mv "$PIN_FILE.tmp" "$PIN_FILE"

        wall "claude-box: updating to $REPO@$target — agent sessions will restart if their services changed." || true
        if /run/current-system/sw/bin/nixos-rebuild switch; then
          wall "claude-box: update to $target applied." || true
        else
          # Roll the pin back so the next trigger retries cleanly instead of
          # believing the failed rev is current.
          if [ -e "$PIN_FILE.prev" ]; then
            mv "$PIN_FILE.prev" "$PIN_FILE"
          else
            rm -f "$PIN_FILE"
          fi
          wall "claude-box: update to $target FAILED — pin rolled back, system unchanged. See: journalctl -u claude-box-update" || true
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

      pickerBlock = ''
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
              ${lib.concatMapStringsSep "\n      " (n: ''<div class="row"><a class="term" href="https://${n}@${cfg.web.domain}/${n}/">${n}</a><a class="gear" href="https://${n}@${cfg.web.domain}/${n}/settings/" title="${n} settings" aria-label="${n} settings">&#9881;</a></div>'') terminalUsers}
            </main>
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
          NoNewPrivileges = true;
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
