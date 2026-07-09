# VM image config. Consumed by:
#   nix build .#vm                        -> qcow2 (nixos-generators)
#   nixos-rebuild build-vm --flake .#vm   -> local QEMU runner
#
# Boot loader + root filesystem are supplied by the generator / build-vm, so
# this file only declares the agent service and console conveniences.
{ pkgs, ... }:
{
  services.claude-box = {
    enable = true;
    agent = "claude";
    users.agent = { };
    sudoAllowlist = [
      "/run/current-system/sw/bin/systemctl reload caddy.service"
    ];
    extraPackages = with pkgs; [ git ripgrep jq ];
  };

  # Console convenience for a throwaway VM. Change the password on first login;
  # complete the selected agent's login with `tmux -L agent-box attach -t main`.
  users.users.agent.initialPassword = "agent";
  services.getty.autologinUser = "agent";

  # Let the agent reach the network (subscription APIs + optional remote control).
  networking.firewall.enable = true;

  system.stateVersion = "25.05";
}
