{
  description = "claude-box: reproducible multi-user coding agent hosts (bare-metal NixOS + VM images)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
    in
    {
      # The portable module. Import into any NixOS host:
      #   imports = [ inputs.claude-box.nixosModules.claude-box ];
      nixosModules.claude-box = import ./modules/claude-box.nix;
      nixosModules.default = self.nixosModules.claude-box;

      # Bootable VM config used both by the qcow2 generator (below) and by
      #   nixos-rebuild build-vm --flake .#vm
      # (build-vm injects boot/filesystem, so this stays hardware-free).
      nixosConfigurations.vm = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ self.nixosModules.claude-box ./hosts/vm.nix ];
      };

      # Standalone qcow2 image (BIOS boot), built via the image API upstreamed
      # into nixpkgs (NixOS 25.05+): nix build .#vm  ->  result/*.qcow2
      # The `qemu` variant extends the fs/bootloader-free vm config with its own
      # partition table + GRUB, so the base config stays usable for build-vm.
      packages.${system} =
        let
          image = self.nixosConfigurations.vm.config.system.build.images.qemu;
        in
        {
          vm = image;
          default = image;
        };

      # CI validation entrypoints (`nix build .#checks.x86_64-linux.<name>`).
      # NOTE: prefer these over `nix flake check` — the VM nixosConfiguration is
      # intentionally bootloader/filesystem-free (the generator supplies them),
      # so its `toplevel` (which flake check builds) does not evaluate.
      checks.${system} =
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # A full, bootable multi-user system (qemu-vm supplies boot/fs) built
          # from the published bare-metal example — proves the module evaluates
          # and generates a per-user service for every configured agent.
          multiUser = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.claude-box
              ./hosts/bare-metal.nix
              ({ modulesPath, ... }: { imports = [ (modulesPath + "/virtualisation/qemu-vm.nix") ]; })
            ];
          };
          services = multiUser.config.systemd.services;
          wanted = [ "claude-box-alice" "claude-box-bob" "claude-box-coder" "claude-box-ci" ];
          missing = builtins.filter (n: ! builtins.hasAttr n services) wanted;
        in
        {
          # Eval-level assertion; cheap.
          multi-user = assert missing == [ ];
            pkgs.runCommand "claude-box-multi-user-ok" { } ''
              printf 'generated services: %s\n' ${nixpkgs.lib.escapeShellArg (toString wanted)} > "$out"
            '';

          # Full closure build of the VM config — the "is it actually usable"
          # proof (compiles the system agents would run in).
          vm-closure = self.nixosConfigurations.vm.config.system.build.vm;

          # Interactive VM test: wrong-password basic-auth attempts on the web
          # terminal get the client IP banned. Needs KVM (or slow TCG); CI
          # enables /dev/kvm before building this.
          web-fail2ban = pkgs.testers.runNixOSTest
            (import ./tests/web-fail2ban.nix { claude-box = self.nixosModules.claude-box; });

          # Interactive VM test: an agent user drops a snippet into ~/sites/
          # and reloads caddy via the sudoAllowlist rule; the new vhost
          # serves without any nixos-rebuild.
          self-serve-domain = pkgs.testers.runNixOSTest
            (import ./tests/self-serve-domain.nix { claude-box = self.nixosModules.claude-box; });
        };
    };
}
