{
  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages."${system}";
      customPython = (pkgs.python.withPackages (pythonPackages: with pythonPackages; [ lxml ]));
    in
    rec {
      # build an XNG OPS from a tarball release
      lib.buildXngOps = { pkgs, src, name ? "xng-ops" }: pkgs.stdenv.mkDerivation {
        inherit name src;
        nativeBuildInputs = [ pkgs.autoPatchelfHook ];
        buildInputs = with pkgs; [
          (python3.withPackages (pythonPackages: with pythonPackages; [ lxml ]))
          libxml2
        ];
        installPhase = ''
          runHook preInstall
          mkdir $out
          cp -r . $out/
          runHook postInstall
        '';

        # meta attributes
        meta = {
          target = "armv7a-vmsa-tz";
        };
      };

      # compile one XNG configuration using the vendored Makefile
      lib.buildXngConfig = { pkgs, xngOps, name, src, xngConfigurationPath }: pkgs.stdenv.mkDerivation {
        inherit name src;
        nativeBuildInputs = [ pkgs.gcc-arm-embedded xngOps ];
        XNG_ROOT_PATH = xngOps;
        postPatch = ''
          for file in $( find -name Makefile -o -name '*.mk' ); do
            sed --in-place 's|^\(\s*XNG_ROOT_PATH\s*=\s*\).*$|\1${xngOps}|' "$file"
          done
          cd '${xngConfigurationPath}'
        '';
        dontFixup = true;
        installPhase = "mkdir $out; cp *.bin *.elf $out/";
      };

      # compile one XNG configuration using a custom nix/bash based builder
      lib.buildXngSysImage =
        { pkgs
        , xngOps
        , name
        , partitions
        , xcf
        , target ? xngOps.meta.target
        , hardFp ? false
        , stdenv ? (if hardFp then
            pkgs.pkgsCross.armhf-embedded.stdenv
          else pkgs.pkgsCross.arm-embedded.stdenv)
        }:
        let
          archDefine = builtins.replaceStrings [ "-" ] [ "_" ] (pkgs.lib.toUpper target);
          fp = if hardFp then "hard" else "soft";
        in
        stdenv.mkDerivation {
          inherit name;
          dontUnpack = true;
          dontFixup = true;
          nativeBuildInputs = [ xngOps pkgs.file pkgs.xmlstarlet ];
          buildInputs = [ xngOps ];

          configurePhase = ''
            runHook preConfigure

            echo "configuring xcf for ${name}"
            set -x
            xcparser.${target} ${xcf}/module.xml xcf.c
            { set +x; } 2>/dev/null

            runHook postConfigure
          '';

          buildPhase = ''
            runHook preBuild
            set -Eeuo pipefail

            export TARGET_CFLAGS="$NIX_CFLAGS_COMPILE -ffreestanding -mabi=aapcs \
              -mlittle-endian -march=armv7-a -mtune=cortex-a9 -mfpu=neon -DNEON \
              -D${archDefine} -Wall -Wextra -pedantic -std=c99 -fno-builtin -O2 \
              -fno-short-enums -I${xngOps}/include/xre-${target} \
              -I${xngOps}/lib/include -I${xngOps}/include/xc -mfloat-abi=${fp} \
              -mthumb"

            echo "building configuration image"
            set -x
            $CC $TARGET_CFLAGS -O2 -nostdlib -Wl,--entry=0x0 \
              -Wl,-T${xngOps}/lds/xcf.lds xcf.c -o xcf.${target}.elf
            $OBJCOPY -O binary xcf.${target}.elf xcf.${target}.bin
            { set +x; } 2>/dev/null

            echo "gathering information"
            local hypervisor_xml=$(xml sel -N 'n=http://www.fentiss.com/xngModuleXml' -t -v '/n:Module/n:Hypervisor/@hRef' ${xcf}/module.xml)
            local hypervisor_entry_point=$(xml sel -N 'n=http://www.fentiss.com/xngHypervisorXml' -t -v '/n:Hypervisor/@entryPoint' ${xcf}/$hypervisor_xml)
            local xcf_entry_point=0x200000

            local args=("-e" "$hypervisor_entry_point" \
              "${xngOps}/lib/xng.${target}.bin@$hypervisor_entry_point")

            ${builtins.concatStringsSep "\n"
              (pkgs.lib.attrsets.mapAttrsToList (name: src: ''
                echo "gathering information for partition ${name}"
                local partition_xml=$(xml sel -N 'n=http://www.fentiss.com/xngPartitionXml' -t -if '/n:Partition/@name="${name}"' --inp-name $(find ${xcf} -name '*.xml'))
                [ -f "$partition_xml" ] || (echo "unable to find xml for partition ${name}"; exit 127)
                local entry_point=$(xml sel -N 'n=http://www.fentiss.com/xngPartitionXml' -t -v '/n:Partition/@entryPoint' $partition_xml)
                (( entry_point >= 0 )) || (echo "unable to extract partition entry point for partition ${name}"; exit 1)

                args+=("${name}.${target}.bin@$entry_point")

                echo "building partition ${name}"
                local extra_ld_args=
                if file --brief ${src} | grep 'C source'
                then
                  local object_code=${name}.${target}.o
                  set -x
                  $CC $TARGET_CFLAGS -c -o $object_code ${src}
                  { set +x; } 2>/dev/null
                elif file --brief ${src} | grep 'ar archive'
                then
                  local object_code=${src}
                  extra_ld_args="--require-defined PartitionMain"
                fi

                set -x
                $LD -EL $object_code -o ${name}.${target}.elf \
                  -Ttext $entry_point -T${xngOps}/lds/xre.lds \
                  --start-group -L${xngOps}/lib \
                  -lxre.${fp}fp.armv7a-vmsa-tz \
                  -lxc.${fp}fp.armv7a-vmsa-tz \
                  -lfw.${fp}fp.armv7a-vmsa-tz \
                  --end-group $extra_ld_args
                $OBJCOPY -O binary ${name}.${target}.elf ${name}.${target}.bin
                { set +x; } 2>/dev/null

              '') partitions)}

            args+=("xcf.${target}.bin@$xcf_entry_point" "sys_img.elf")

            echo "building image"
            set -x
            TARGET_CC="$CC" elfbdr.py ''${args[@]}
            { set +x; } 2>/dev/null

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            mkdir $out
            mv *.{bin,c,elf} $out/
            runHook postInstall
          '';
        };

      templates = {
        xng-build = {
          path = ./template;
          description = "Simple build script for XNG examples";
        };
      };
      templates.default = self.templates.xng-build;

      checks.x86_64-linux =
        let
          xngSrc = ./. + "/14-033.094.ops+${xngOps.meta.target}+zynq7000.r16736.tbz2";
          exampleDir = xngOps + "/xre-examples";
          xngOps = lib.buildXngOps {
            inherit pkgs;
            src = xngSrc;
          };
          genCheckFromExample = { name, partitions, hardFp ? false }: lib.buildXngSysImage {
            inherit name pkgs xngOps hardFp;
            xcf = exampleDir + "/${name}/xml";
            partitions = pkgs.lib.mapAttrs (_: v: exampleDir + "/${name}/${v}") partitions;
          };
          meta = with lib; {
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
          makeFileOnlyExamples = [
            { name = "reset_hypervisor"; }
          ];
        in
        (builtins.listToAttrs (builtins.map
          ({ name, ... } @ args: {
            name = "example_${name}";
            value = genCheckFromExample args;
          })
          examples)) //
        (builtins.listToAttrs (builtins.map
          ({ name, ... } @ args: {
            name = "makefile_example_${name}";
            value = lib.buildXngConfig rec {
              inherit name pkgs xngOps;
              src = xngSrc;
              xngConfigurationPath = "xre-examples/${name}";
            };
          })
          (examples ++ makeFileOnlyExamples)));
    };
}

