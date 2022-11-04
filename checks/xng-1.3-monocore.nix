{ pkgs, xng-flake-utils }:
let
  xng-version = "xng-1.3-monocore";
  srcs = {
    xng = pkgs.requireFile {
      name = "14-033.094.ops+armv7a-vmsa-tz+zynq7000.r14040.tbz2";
      url = "http://fentiss.com";
      sha256 = "01wrisyqhhi6v4pp4cxy60a13a5w3h5a3jnbyzmssk4q6gkkrd9i";
    };
    lithos = pkgs.requireFile {
      name = "020.080.ops.r7048.XNG-r13982.tbz2";
      url = "https://fentiss.com";
      sha256 = "080pxsmwj8hh0dirb8x3225gvpmk48lb54lf97bggp98jgss6kls";
    };
  };
  xng-ops = xng-flake-utils.lib.buildXngOps { inherit pkgs; src = srcs.xng; };
  lithos-ops = xng-flake-utils.lib.buildLithOsOps { inherit pkgs; src = srcs.lithos; };
  exampleDir = xng-ops.dev + "/xre-examples";
  genCheckFromExample = { name, partitions, hardFp ? false }: xng-flake-utils.lib.buildXngSysImage {
    inherit name pkgs hardFp;
    xngOps = xng-ops;
    xcf = exampleDir + "/${name}/xml.armv7a-vmsa-tz";
    partitions = pkgs.lib.mapAttrs (_: v: { src = exampleDir + "/${name}/${v}"; }) partitions;
  };
  meta = with pkgs.lib; {
    homepage = "https://fentiss.com/";
    license = licenses.unfree;
  };
  examples = [
    {
      name = "hello_world";
      partitions.Partition0 = "hello_world.c";
    }
    {
      name = "queuing_port";
      partitions.src_partition = "src0.c";
      partitions.dst_partition = "dst0.c";
    }
    {
      name = "sampling_port";
      partitions.src_partition = "src0.c";
      partitions.dst_partition0 = "dst0.c";
      partitions.dst_partition1 = "dst1.c";
    }
    {
      name = "system_timer";
      partitions.Partition0 = "system_timer.c";
    }
    {
      name = "vfp";
      partitions.Partition0 = "vfp0.c";
      partitions.Partition1 = "vfp1.c";
      hardFp = true;
    }
  ];
  checkDrvs =
    # the XNG examples
    (builtins.listToAttrs (builtins.map
      ({ name, ... } @ args: {
        name = "example-" + name;
        value = genCheckFromExample args;
      })
      examples))
    // {
      inherit xng-ops lithos-ops;

      # lithos example
      "lithos-example-00-hello" = xng-flake-utils.lib.buildXngSysImage rec {
        inherit pkgs;
        name = "00-hello";
        xngOps = xng-ops;
        lithOsOps = lithos-ops;
        partitions.Partition0 = {
          enableLithOs = true;
          src = lithos-ops + "/examples/${name}/main.c";
          ltcf = lithos-ops + "/examples/${name}/system.ltcf";
        };
        xcf = "${lithos-ops}/examples/${name}/xml.xng-armv7a-vmsa-tz";
      };
    };
in
with pkgs.lib; mapAttrs' (name: value: nameValuePair "${xng-version}-${name}" value) checkDrvs
