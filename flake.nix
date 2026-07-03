{
  description = "claude-box: reproducible multi-user Claude Code agent hosts (bare-metal NixOS + VM images)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators, ... }:
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

      # Standalone qcow2 image: nix build .#vm  ->  result/nixos.qcow2
      packages.${system} =
        let
          image = nixos-generators.nixosGenerate {
            inherit system;
            format = "qcow";
            modules = [ self.nixosModules.claude-box ./hosts/vm.nix ];
          };
        in
        {
          vm = image;
          default = image;
        };
    };
}
