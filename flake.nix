{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells = {
          default = pkgs.mkShell {
            buildInputs = [
              pkgs.zig
              pkgs.zls
              pkgs.lldb
              pkgs.llvmPackages.lldbPlugins.llef
              pkgs.limine-full
              pkgs.just
              pkgs.libisoburn
              pkgs.qemu
            ];

            shellHook = ''
              export LIMINE_SHARE="${pkgs.limine-full}/share/limine"
            '';
          };
        };
      }
    );
}
