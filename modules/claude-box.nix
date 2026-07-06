{ config, lib, pkgs, ... }:

let
  cfg = config.services.claude-box;

  userOpts = { name, ... }: {
    options = {
      skipPermissions = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Pass --dangerously-skip-permissions (full autonomy, no approval prompts).";
      };
      remoteControl = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Pass --remote-control so the session is drivable from the Claude apps.";
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
        description = "Extra arguments appended to the claude invocation.";
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
      sessionName =
        if u.remoteControlName != null
        then u.remoteControlName
        else "${name}@${config.networking.fqdnOrHostName}";
      claudeCmd = lib.concatStringsSep " " (
        [ (lib.getExe cfg.package) ]
        ++ lib.optional u.skipPermissions "--dangerously-skip-permissions"
        ++ lib.optionals u.remoteControl [ "--remote-control" sessionName ]
        ++ u.extraArgs
      );
    in
    pkgs.writeShellScript "claude-box-${name}-start" ''
      set -u
      # Detached tmux session so a human can `tmux -L claude-box attach -t main`.
      # `|| exec bash` gives a POST-MORTEM shell ONLY on non-zero claude exit;
      # clean exits let the session die so systemd's Restart=always brings up
      # a fresh claude. (Was `; exec bash`, which pinned the session forever.)
      ${pkgs.tmux}/bin/tmux -L claude-box new-session -d -s main \
        -c ${lib.escapeShellArg u.workingDirectory} \
        ${lib.escapeShellArg (claudeCmd + " || exec ${pkgs.bashInteractive}/bin/bash")}
      # Block ExecStart until the session actually goes away — a clean claude
      # exit, the user typing `exit` in the post-mortem bash, someone
      # `tmux kill-session`ing us, or ExecStop killing it. Type=exec + this
      # supervising tail lets Restart=always distinguish "session died on its
      # own" (restart) from "systemctl stop" (don't restart).
      while ${pkgs.tmux}/bin/tmux -L claude-box has-session -t main 2>/dev/null; do
        sleep 2
      done
    '';
in
{
  options.services.claude-box = {
    enable = lib.mkEnableOption "reproducible multi-user Claude Code agent host";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.claude-code;
      defaultText = lib.literalExpression "pkgs.claude-code";
      description = "Claude Code package to run.";
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule userOpts);
      default = { };
      example = lib.literalExpression ''{ alice = { }; bob = { remoteControlName = "bob-box"; }; }'';
      description = "Agent users to provision. Each gets an unprivileged account and its own tmux/Claude service.";
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
    }];

    # Claude Code is unfree; allow just it (host can override).
    nixpkgs.config.allowUnfreePredicate =
      lib.mkDefault (pkg: builtins.elem (lib.getName pkg) [ "claude-code" ]);

    users.users = lib.mapAttrs (name: u: {
      isNormalUser = true;
      home = "/home/${name}";
      createHome = true;
      extraGroups = u.extraGroups;
      shell = pkgs.bashInteractive;
    }) cfg.users;

    environment.systemPackages = [ cfg.package pkgs.tmux ] ++ cfg.extraPackages;

    systemd.services = lib.mapAttrs' (name: u:
      lib.nameValuePair "claude-box-${name}" {
        description = "Claude Code agent (tmux) for ${name}";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        # System services get a minimal PATH; give the agent an explicit toolset.
        path = [ cfg.package pkgs.tmux pkgs.bashInteractive pkgs.coreutils pkgs.git ] ++ cfg.extraPackages;
        environment = { HOME = "/home/${name}"; } // u.environment;
        serviceConfig = {
          User = name;
          # ExecStart's mkStart supervises the tmux session and stays live for
          # as long as the session is alive, so systemd can distinguish clean
          # session termination (Restart=always kicks in → fresh claude) from
          # explicit `systemctl stop` (which systemd never restarts through).
          Type = "exec";
          Restart = "always";
          RestartSec = "2s";
          ExecStart = mkStart name u;
          ExecStop = "${pkgs.tmux}/bin/tmux -L claude-box kill-session -t main";
          # Custom tokens (GH_TOKEN, etc.) land here. The '-' makes the per-user
          # file optional so the agent starts even before any token is dropped in.
          EnvironmentFile = cfg.environmentFiles
            ++ [ "-${cfg.tokenDir}/${name}.env" ]
            ++ u.environmentFiles;
        };
      }
    ) cfg.users;

    systemd.tmpfiles.rules =
      lib.mkIf cfg.manageTokenDir [ "d ${cfg.tokenDir} 0755 root root - -" ];

    security.sudo.extraRules = lib.mkIf (cfg.sudoAllowlist != [ ]) [{
      users = lib.attrNames cfg.users;
      commands = map (command: { inherit command; options = [ "NOPASSWD" "SETENV" ]; }) cfg.sudoAllowlist;
    }];
  };
}
