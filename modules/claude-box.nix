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
        type = lib.types.str;
        default = name;
        description = "Remote Control session name. Keep it shell-safe (no spaces/quotes).";
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
    };
  };

  mkStart = name: u:
    let
      claudeCmd = lib.concatStringsSep " " (
        [ (lib.getExe cfg.package) ]
        ++ lib.optional u.skipPermissions "--dangerously-skip-permissions"
        ++ lib.optionals u.remoteControl [ "--remote-control" u.remoteControlName ]
        ++ u.extraArgs
      );
    in
    pkgs.writeShellScript "claude-box-${name}-start" ''
      set -eu
      # Detached tmux session so a human can `tmux -L claude-box attach -t main`.
      # `; exec bash` keeps the pane alive (login/OAuth prompt, or restart) if
      # claude exits, instead of tearing the session down.
      exec ${pkgs.tmux}/bin/tmux -L claude-box new-session -d -s main \
        -c ${lib.escapeShellArg u.workingDirectory} \
        ${lib.escapeShellArg (claudeCmd + "; exec ${pkgs.bashInteractive}/bin/bash")}
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
        environment.HOME = "/home/${name}";
        serviceConfig = {
          User = name;
          # tmux daemonizes and returns; keep the unit "active" and let ExecStop
          # tear the session down. Auto-login/OAuth happens on first `tmux attach`.
          Type = "oneshot";
          RemainAfterExit = true;
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
