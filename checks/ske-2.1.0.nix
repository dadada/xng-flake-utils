{ pkgs, xng-flake-utils }:
let
  ske-version = "ske-2.1.0";
  srcs = {
    ske = pkgs.requireFile {
      name = "14-034.010.ops.r711.tbz2";
      url = "http://fentiss.com";
      sha256 = "15pdl94502kk0kis8fdni886lybsm7204blra2cnnkidjrdmd4kk";
    };
  };
in
{
  "${ske-version}-ske-ops" = xng-flake-utils.lib.buildSkeOps { inherit pkgs; src = srcs.ske; };
} 
