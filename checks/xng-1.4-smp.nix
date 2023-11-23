{ pkgs, xng-flake-utils }:
let
  xng-version = "xng-1.4-smp";
  srcs = {
    xng = pkgs.requireFile {
      name = "14-033.094.ops+armv7a-vmsa-tz+zynq7000.r16736.tbz2";
      url = "http://fentiss.com";
      sha256 = "1gb0cq3mmmr2fqj49p4svx07h5ccs8v564awlsc56mfjhm6jg3n4";
    };
    lithos = pkgs.requireFile {
      name = "020.080.ops.r7919+xngsmp.tbz2";
      url = "https://fentiss.com";
      sha256 = "1b73d6x3galw3bhj5nac7ifgp15zrsyipn4imwknr24gp1l14sc8";
    };
  };
  xng-ops = xng-flake-utils.lib.buildXngOps { inherit pkgs; src = srcs.xng; };
  lithos-ops = xng-flake-utils.lib.buildLithOsOps { inherit pkgs; src = srcs.lithos; };
  exampleDir = xng-ops.dev + "/xre-examples";
  genCheckFromExample = { name, partitions, hardFp ? false, extraBinaryBlobs ? {} }: xng-flake-utils.lib.buildXngSysImage {
    inherit extraBinaryBlobs name pkgs hardFp;
    xngOps = xng-ops;
    xcf = pkgs.runCommandNoCC "patch-src" { } ''
      cp -r ${exampleDir + "/${name}/xml"} $out/
      for file in $(find $out -name hypervisor.xml)
      do
        substituteInPlace "$file" --replace 'baseAddr="0xE0001000"' 'baseAddr="0xE0000000"'
      done
    '';
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
      extraBinaryBlobs = { "0x00050000" = ./testblob; };
    }
    {
      name = "queuing_port";
      partitions.src_partition = "src0.c";
      partitions.dst_partition = "dst0.c";
    }
    # this example doesn't work, since it is actually two independent hypervisor images
    # reset_hypervisor = genCheckFromExample {
    #   name = "reset_hypervisor";
    #   xcf = exampleDir + "/reset_hypervisor/xml";
    # };
    {
      name = "sampling_port";
      partitions.src_partition = "src0.c";
      partitions.dst_partition0 = "dst0.c";
      partitions.dst_partition1 = "dst1.c";
    }
    {
      name = "sampling_port_smp";
      partitions.Partition0 = "partition0.c";
      partitions.Partition1 = "partition1.c";
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
      examples)) //
    {
      inherit xng-ops lithos-ops;
    };
in
with pkgs.lib; mapAttrs'
  (name: value: nameValuePair
    (
      xng-flake-utils.lib.replaceDots "${xng-version}-${name}"
    )
    value)
  checkDrvs
