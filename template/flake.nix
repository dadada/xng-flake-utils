{
  inputs.xng-utils.url = "github:aeronautical-informatics/xng-flake-utils?ref=main";
  outputs = { self, nixpkgs, xng-utils }:
    with xng-utils.lib;
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages."${system}";
      mkShell = pkgs.mkShell.override { stdenv = pkgs.gccMultiStdenv; };
    in
    {
      packages."${system}" = rec {
        xng = buildXngOps { inherit pkgs; src = ./14-033.094.ops+armv7a-vmsa-tz+zynq7000.r14040.tbz2; };
        xng-config = buildXngConfig {
          inherit pkgs;
          xngOps = xng;
          name = "hello_world";
          src = ./14-033.094.ops+armv7a-vmsa-tz+zynq7000.r14040.tbz2;
          xngConfigurationPath = "xre-examples/hello_world";
        };
      };
      defaultPackage."${system}" = self.packages."${system}".xng-config;

      devShell."${system}" = with self.packages."${system}"; mkShell {
        C_INCLUDE_PATH = "${xng}/include";
        inputsFrom = [ xng-config ];
      };
    };
}

