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

                # development tools
                limine
                pkgs.libisoburn # for xorriso
                pkgs.qemu
              ];

              shellHook = ''
                export LIMINE_SHARE_PATH="${limine}/share/limine"
              '';
            };
        };
      }
    );
}
