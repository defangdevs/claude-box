{
  description = "agent-box: reproducible multi-user coding agent hosts (bare-metal NixOS + VM images)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
    in
    {
      # The portable module. Import into any NixOS host:
      #   imports = [ inputs.agent-box.nixosModules.agent-box ];
      nixosModules.agent-box = import ./modules/agent-box.nix;
      nixosModules.default = self.nixosModules.agent-box;

      # Bootable VM config used both by the qcow2 generator (below) and by
      #   nixos-rebuild build-vm --flake .#vm
      # (build-vm injects boot/filesystem, so this stays hardware-free).
      nixosConfigurations.vm = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ self.nixosModules.agent-box ./hosts/vm.nix ];
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
              self.nixosModules.agent-box
              ./hosts/bare-metal.nix
              ({ modulesPath, ... }: { imports = [ (modulesPath + "/virtualisation/qemu-vm.nix") ]; })
            ];
          };
          services = multiUser.config.systemd.services;
          wanted = [ "agent-box-alice" "agent-box-bob" "agent-box-coder" "agent-box-ci" ];
          missing = builtins.filter (n: ! builtins.hasAttr n services) wanted;
        in
        {
          # Eval-level assertion; cheap.
          multi-user = assert missing == [ ];
            pkgs.runCommand "agent-box-multi-user-ok" { } ''
              printf 'generated services: %s\n' ${nixpkgs.lib.escapeShellArg (toString wanted)} > "$out"
            '';

          # Full closure build of the VM config — the "is it actually usable"
          # proof (compiles the system agents would run in).
          vm-closure = self.nixosConfigurations.vm.config.system.build.vm;

          # Interactive VM test: wrong-password basic-auth attempts on the web
          # terminal get the client IP banned. Needs KVM (or slow TCG); CI
          # enables /dev/kvm before building this.
          web-fail2ban = pkgs.testers.runNixOSTest
            (import ./tests/web-fail2ban.nix { agent-box = self.nixosModules.agent-box; });

          # Interactive VM test: an agent user drops a snippet into ~/sites/
          # and reloads caddy via the sudoAllowlist rule; the new vhost
          # serves without any nixos-rebuild.
          self-serve-domain = pkgs.testers.runNixOSTest
            (import ./tests/self-serve-domain.nix { agent-box = self.nixosModules.agent-box; });

          # Interactive VM test: the per-user settings page (issue #36) adds a
          # secret through the browser (behind basic auth), writes the
          # user-owned 0600 env file, lists key names only, and the agent unit
          # picks the file up as an optional EnvironmentFile — no rebuild.
          settings-page = pkgs.testers.runNixOSTest
            (import ./tests/settings-page.nix { agent-box = self.nixosModules.agent-box; });

          # Interactive VM test (issue 62): protectMemory defaults — zram
          # swap active, agent unit's OOMScoreAdjust applied, and earlyoom
          # kills a runaway memory hog while the box stays responsive
          # (instead of the swapless refault livelock that froze a deployed
          # 2 GB box for hours).
          memory-protection = pkgs.testers.runNixOSTest
            (import ./tests/memory-protection.nix { agent-box = self.nixosModules.agent-box; });

          # Interactive VM test (issue #59): sessions are runtime data — the
          # seeded "main" session starts, `agent-box-session add/rm` brings a
          # second agent up and down as the user (no sudo, no rebuild), the
          # runtime session lives inside the hardened unit's cgroup, and the
          # settings daemon serves the root session manager page plus its
          # CRUD routes, all behind the web auth gate.
          sessions = pkgs.testers.runNixOSTest
            (import ./tests/sessions.nix { agent-box = self.nixosModules.agent-box; });

          # Regression guard (issue #51): deployed boxes fetch
          # modules/agent-box.nix as a SINGLE file — the CFN user-data and
          # agent-box-update.service both fetchurl just that path — so the
          # module must never reference a ./sibling. builtins.path snapshots
          # the lone file into the store exactly like fetchurl does; forcing
          # the toplevel drvPath then proves a web-enabled system still
          # evaluates from the bare file. Eval-only, nothing is built.
          module-single-file =
            let
              moduleAlone = builtins.path {
                path = ./modules/agent-box.nix;
                name = "agent-box-module-alone.nix";
              };
              sys = nixpkgs.lib.nixosSystem {
                inherit system;
                modules = [
                  moduleAlone
                  ({ modulesPath, ... }: { imports = [ (modulesPath + "/virtualisation/qemu-vm.nix") ]; })
                  {
                    services.agent-box = {
                      enable = true;
                      agent = "claude";
                      users.agent.web.passwordHashFile = "/var/lib/agent-box-web/password-hash";
                      web = {
                        enable = true;
                        domain = "single-file.test";
                        user = "agent";
                      };
                    };
                    system.stateVersion = "25.05";
                  }
                ];
              };
            in
            pkgs.runCommand "agent-box-module-single-file-ok" {
              # Forcing drvPath instantiates the full system eval without
              # building it; the context is discarded so this check itself
              # stays a trivial build.
              evaluated = builtins.unsafeDiscardStringContext
                sys.config.system.build.toplevel.drvPath;
            } ''
              printf 'single-file eval OK: %s\n' "$evaluated" > "$out"
            '';
        };
    };
}
