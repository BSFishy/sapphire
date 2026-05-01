{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    bsfishy.url = "github:BSFishy/nix";
  };

  outputs =
    { nixpkgs, flake-utils, bsfishy, ... }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells = {

          default =
          let
            limine = pkgs.limine-full;
          in
            pkgs.mkShell {
              buildInputs = [
                # language tools
                pkgs.zig
                pkgs.zls
                pkgs.lldb
                pkgs.llvmPackages.lldbPlugins.llef
                pkgs.wabt

                # development tools
                limine
                pkgs.libisoburn # for xorriso
                pkgs.qemu
                bsfishy.packages.${system}.zig-mcp
              ];

              shellHook = ''
                export LIMINE_SHARE_PATH="${limine}/share/limine"
              '';
            };
        };
      }
    );
}
