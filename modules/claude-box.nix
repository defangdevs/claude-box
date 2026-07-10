{ config, lib, pkgs, ... }:

let
  cfg = config.services.claude-box;
  supportedAgents = [ "claude" "codex" ];
  tmuxSocketName = "agent-box";
  runtimeDirectory = name: "agent-box-${name}";

  # Reload command is granted when web is enabled so the agent can add a
  # virtual host and reload without root — pooled with the user-supplied
  # sudoAllowlist so NoNewPrivileges + sudo rules see the same list.
  caddyReloadCmd = "/run/current-system/sw/bin/systemctl reload caddy.service";
  effectiveSudoAllowlist =
    cfg.sudoAllowlist ++ lib.optional cfg.web.enable caddyReloadCmd;
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
          EnvironmentFile = cfg.environmentFiles
            ++ [ "-${cfg.tokenDir}/${name}.env" ]
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
  } (lib.mkIf (cfg.enable && cfg.web.enable) (
    let
      webUser = cfg.web.user;
      # Users that get a browser terminal, in sorted order (attrNames sorts) —
      # port assignment below depends on that order being deterministic.
      terminalUsers = lib.filter (n: cfg.users.${n}.web.passwordHashFile != null) (lib.attrNames cfg.users);
      portOf = lib.listToAttrs (lib.imap0 (i: n: lib.nameValuePair n (7681 + i)) terminalUsers);
      hashFileOf = n: toString cfg.users.${n}.web.passwordHashFile;
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
              main a { display: block; margin: 10px 0; padding: 12px 36px;
                       border: 1px solid #30363d; border-radius: 10px; background: #161b22;
                       color: #e8a087; font-size: 20px; text-decoration: none; }
              main a:hover { border-color: #e8a087; }
            </style>
            <main>
              <h1>Terminals</h1>
              ${lib.concatMapStringsSep "\n      " (n: ''<a href="https://${n}@${cfg.web.domain}/${n}/">${n}</a>'') terminalUsers}
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
      ] ++ lib.concatMap (name: [
        "d /var/lib/claude-box-sites/${name} 0750 ${name} caddy - -"
        # ~/sites -> the caddy-readable snippet dir. L+ replaces a stale
        # symlink/file if the target differs from ours (idempotent across
        # renames). Users edit through this link and never touch /var/lib.
        "L+ /home/${name}/sites - - - - /var/lib/claude-box-sites/${name}"
      ]) (lib.attrNames cfg.users);

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
      }) terminalUsers);
    }
  ))]);
}
