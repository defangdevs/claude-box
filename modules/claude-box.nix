{ config, lib, pkgs, ... }:

let
  cfg = config.services.claude-box;
  supportedAgents = [ "claude" "codex" ];
  tmuxSocketName = "agent-box";
  runtimeDirectory = name: "agent-box-${name}";
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
  };

  config = lib.mkIf cfg.enable {
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
        path = [ "/home/${name}/.nix-profile/bin" agent.package pkgs.tmux pkgs.bashInteractive pkgs.coreutils pkgs.git ] ++ cfg.extraPackages;
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
          # when the allowlist is empty — with a non-empty allowlist we've
          # traded some containment for scoped elevation as a host choice.
          NoNewPrivileges = cfg.sudoAllowlist == [ ];
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

    security.sudo.extraRules = lib.mkIf (cfg.sudoAllowlist != [ ]) [{
      users = lib.attrNames cfg.users;
      # NOPASSWD only — no SETENV. SETENV lets the caller alter env vars
      # visible to the sudo'd command, which broadens the surface for no
      # gain given the allowlist is meant to be tight and command-scoped.
      commands = map (command: { inherit command; options = [ "NOPASSWD" ]; }) cfg.sudoAllowlist;
    }];
  };
}
