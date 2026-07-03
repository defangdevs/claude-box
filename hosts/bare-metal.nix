# Example: run >1 Claude Code agent on an existing bare-metal NixOS host.
#
# This is an importable fragment, NOT a standalone system — your host still
# provides its own boot loader, filesystems, and hardware config. Import it
# (and the module) from your configuration.nix / flake:
#
#   imports = [
#     inputs.claude-box.nixosModules.claude-box
#     ./claude-box/hosts/bare-metal.nix    # or just copy the block below
#   ];
#
# First boot per user: `tmux -L claude-box attach -t main` as that user (or
# `sudo -u alice ...`) and complete the one-time Claude login. Credentials live
# in ~/.claude and are per-user runtime state — never baked into this config.
{ pkgs, ... }:
{
  services.claude-box = {
    enable = true;

    users = {
      alice = { };
      bob = {
        remoteControlName = "bob-box";
      };
      # A locked-down worker: no autonomy flag, keeps approval prompts on.
      ci = {
        skipPermissions = false;
      };
    };

    # The ONLY elevated powers the agents get. Keep this tight and explicit.
    sudoAllowlist = [
      "/run/current-system/sw/bin/systemctl reload caddy.service"
    ];

    extraPackages = with pkgs; [ git ripgrep jq ];
  };

  # Custom tokens in the agent's env (like GH_TOKEN in this sandbox) — no rebuild:
  #   sudo install -m600 /dev/stdin /etc/claude-box/alice.env <<'EOF'
  #   GH_TOKEN=ghp_xxx
  #   ANTHROPIC_LOG=info
  #   EOF
  #   sudo systemctl restart claude-box-alice
  # For Nix-managed secret paths instead, set (per user or globally):
  #   services.claude-box.users.alice.environmentFiles = [ "/run/secrets/alice.env" ];
}
