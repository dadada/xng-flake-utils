{
  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
    in
    rec {
      # build an XNG OPS from a tarball release
      lib.buildXngOps = { pkgs, src ? null, srcs ? null, name ? "xng-ops", target ? "armv7a-vmsa-tz" }:
        let
          archDefine = builtins.replaceStrings [ "-" ] [ "_" ] (pkgs.lib.toUpper target);
        in
        pkgs.stdenv.mkDerivation {
          inherit name src srcs;

          nativeBuildInputs = [ pkgs.autoPatchelfHook ];
          buildInputs = with pkgs; [
            (python3.withPackages (pythonPackages: with pythonPackages; [ lxml ]))
            libxml2
          ];

          outputs = [ "bin" "dev" "out" ];

          setupHook = pkgs.writeTextFile {
            name = "xngSetupHook";
            text = ''
              addXngFlags () {
                # make XNG headers discoverable
                for dir in "$1/lib/include" "$1/include/xc" "$1/include/xre-${target}"; do
                    if [ -d "$dir" ]; then
                        export NIX_CFLAGS_COMPILE+=" -isystem $dir"
                    fi
                done

                # export flags relevant to XNG
                export XNG_TARGET_CFLAGS="-ffreestanding -mabi=aapcs -mlittle-endian -march=armv7-a \
                    -mtune=cortex-a9 -mfpu=neon -DNEON -D${archDefine} -Wall -Wextra -pedantic -std=c99 \
                    -fno-builtin -O2 -fno-short-enums -mthumb"
              }
              addEnvHooks "$hostOffset" addXngFlags
            '';
          };


          installPhase = ''
            runHook preInstall

            mkdir $bin $dev $out
            cp -r bin xsd.${target} $bin/
            cp -r cfg lds lib xre-examples $dev/
            cp -r * $out/

            runHook postInstall
          '';

          # meta attributes
          meta = {
            inherit target;
          };
        };

      # build an SKE OPS from a tarball release
      lib.buildSkeOps = { pkgs, src ? null, srcs ? null, name ? "ske-ops", target ? "skelinux" }:
        let
          archDefine = builtins.replaceStrings [ "-" ] [ "_" ] (pkgs.lib.toUpper target);
        in
        pkgs.stdenv.mkDerivation {
          inherit name src srcs;

          nativeBuildInputs = [ pkgs.autoPatchelfHook ];
          buildInputs = with pkgs; [
            (python2.withPackages (pythonPackages: with pythonPackages; [ lxml ]))
            libxml2
          ];

          outputs = [ "bin" "dev" "out" ];

          setupHook = pkgs.writeTextFile {
            name = "skeSetupHook";
            text = ''
              addSKEFlags () {
                # export flags relevant to SKE
                export SKE_TARGET_CFLAGS+=" -finstrument-functions -std=c99"
              }
              addEnvHooks "$hostOffset" addSKEFlags
            '';
          };

          installPhase = ''
            runHook preInstall

            mkdir $bin $dev $out
            cp -r bin $bin/
            cp -r lib examples $dev/
            cp -r * $out/

            runHook postInstall
          '';

          # meta attributes
          meta = {
            inherit target;
          };
        };

      # build a LithOS OPS
      lib.buildLithOsOps = { pkgs, src, name ? "lithos-ops" }: pkgs.stdenvNoCC.mkDerivation {
        inherit name src;
        dontStrip = true;
        dontPatchELF = true;
        installPhase = ''
          runHook preInstall
          mkdir $out
          mv * $out
          runHook postInstall
        '';
      };

      # compile one XNG configuration using the vendored Makefile
      lib.buildXngConfig = { pkgs, xngOps, name, src, xngConfigurationPath }:
        let
          combinedXngOps = pkgs.symlinkJoin {
            name = "xngOpsFull";
            paths = [ xngOps.bin xngOps.dev ];
          };
        in
        pkgs.stdenv.mkDerivation {
          inherit name src;
          nativeBuildInputs = [ pkgs.gcc-arm-embedded xngOps.bin ];
          preBuild = ''
            cd '${xngConfigurationPath}'
          '';
          makeFlags = [ "XNG_ROOT_PATH=${combinedXngOps}" ];
          dontFixup = true;
          installPhase = "mkdir $out; cp *.bin *.elf $out/";
        };

      lib.buildPartitionC =
        { pkgs
        , xns-ops
        , name
        , src ? null
        , srcs ? null
        , hardFp ? false
        , stdenv ? (if hardFp then
            pkgs.pkgsCross.armhf-embedded.stdenv
          else pkgs.pkgsCross.arm-embedded.stdenv)
        }: { };


      lib.load-xml = { pkgs, file }: builtins.fromJSON (builtins.readFile (pkgs.runCommandNoCC "convert-xml-to-json" { }
        "${pkgs.dasel}/bin/dasel --file ${file} --write json > $out"));

      lib.parse-xcf = { pkgs, src }:
        let
          parsed-xml = self.lib.load-xml { inherit pkgs; file = src + "/module.xml"; };
          replace-hRef = attrset: pkgs.lib.mapAttrsRecursive
            (path: value:
              if pkgs.lib.last path == "-hRef" && builtins.isString value then
                self.lib.load-xml { inherit pkgs; file = src + "/${value}"; }
              else value)
            attrset;
          expanded-xml = replace-hRef (replace-hRef parsed-xml);
        in
        expanded-xml;
      # lib.build-xcf = { pkgs, xng-ops, xng-config, src }: { };
      # lib.build-partition = { pkgs, xng-ops, xng-config, src, name }: { };
      # lib.build-sys-image = { pkgs, xng-ops, xng-config, partitions }: { };


      # compile one XNG configuration using a custom nix/bash based builder
      # partitions is a map of a partition name to an attrset containing the src
      lib.buildXngSysImage =
        { pkgs
        , xngOps
        , name
        , partitions
        , xcf
        , lithOsOps ? null
        , hardFp ? false
        , stdenv ? (if hardFp then
            pkgs.pkgsCross.armhf-embedded.stdenv
          else pkgs.pkgsCross.arm-embedded.stdenv)
        }:
        let
          target = xngOps.meta.target;
          fp = if hardFp then "hard" else "soft";
          baseUrl = "http://www.fentiss.com/";
        in
        # either an lithOsOps is available, or no partition requires one.
        assert lithOsOps != null || pkgs.lib.lists.all ({ enableLithOs ? false, ... }: !enableLithOs) (pkgs.lib.attrValues partitions);
        stdenv.mkDerivation {
          inherit name;
          dontUnpack = true;
          dontFixup = true;
          nativeBuildInputs = [ pkgs.file pkgs.xmlstarlet xngOps.bin ];
          buildInputs = [ xngOps.dev ];

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

            # fail on everything
            set -Eeuo pipefail

            export TARGET_CFLAGS="$NIX_CFLAGS_COMPILE $XNG_TARGET_CFLAGS -mfloat-abi=${fp}"

            echo "building configuration image"
            set -x
            $CC $TARGET_CFLAGS -O2 -nostdlib -Wl,--entry=0x0 -Wl,-T${xngOps.dev}/lds/xcf.lds xcf.c \
                -o xcf.${target}.elf
            $OBJCOPY -O binary xcf.${target}.elf xcf.${target}.bin
            { set +x; } 2>/dev/null

            echo "gathering information"
            local hypervisor_xml=$(xml sel -N 'n=${baseUrl}xngModuleXml' -t \
                -v '/n:Module/n:Hypervisor/@hRef' ${xcf}/module.xml)
            local hypervisor_entry_point=$(xml sel -N 'n=${baseUrl}xngHypervisorXml' -t \
                -v '/n:Hypervisor/@entryPoint' ${xcf}/$hypervisor_xml)
            local xcf_entry_point=0x200000

            local args=("-e" "$hypervisor_entry_point" \
                "${xngOps.dev}/lib/xng.${target}.bin@$hypervisor_entry_point")

            ${builtins.concatStringsSep "\n"
              (pkgs.lib.attrsets.mapAttrsToList (name: { src, enableLithOs ? false, ltcf ? null }: ''
                echo "gathering information for partition ${name}"
                local partition_xml=$(xml sel -N 'n=${baseUrl}xngPartitionXml' -t \
                    -if '/n:Partition/@name="${name}"' --inp-name $(find ${xcf} -name '*.xml'))

                # check partition xml file exits
                [ -f "$partition_xml" ] || {
                    echo "unable to find xml for partition ${name}"
                    exit 127
                }

                local entry_point=$(xml sel -N 'n=${baseUrl}xngPartitionXml' -t \
                    -v '/n:Partition/@entryPoint' $partition_xml)

                # check entry point is a positive number
                (( entry_point >= 0 )) || {
                    echo "unable to extract partition entry point for partition ${name}"
                    exit 1
                }

                args+=("${name}.${target}.bin@$entry_point")

                echo "building partition ${name}"
                local object_code=()
                local extra_ld_args=("-Ttext $entry_point")

                if file --brief ${src} | grep 'C source'
                then
                    local object_code+=("${name}.${target}.o")
                    set -x
                    $CC $TARGET_CFLAGS -c -o ''${object_code[-1]} ${src}
                    { set +x; } 2>/dev/null
                elif file --brief ${src} | grep 'ar archive'
                then
                    local object_code+=("${src}")
                    extra_ld_args+=("--require-defined PartitionMain")
                fi

                ${ if enableLithOs then ''
                    if [ -z "${ltcf}" ] || {
                        echo "unable to find '${ltcf}'"
                        exit 127
                    }
                    set -x
                    $CC $TARGET_CFLAGS --include ${ltcf} -c -o ${ltcf}.o ${lithOsOps}/lib/ltcf.c
                    { set +x; } 2>/dev/null

                    object_code+=("${lithOsOps}/lib/lte_kernel.o" "${ltcf}.o")
                    extra_ld_args+=("-T${lithOsOps}/lds/lithos-${target}.lds")
                '' else ''
                    extra_ld_args+=(
                        "-T${xngOps.dev}/lds/xre.lds"
                        "--start-group"
                        "-lxre.${fp}fp.armv7a-vmsa-tz"
                        "-lxc.${fp}fp.armv7a-vmsa-tz"
                        "-lfw.${fp}fp.armv7a-vmsa-tz"
                        "--end-group"
                    )
                '' }

                set -x
                $LD -EL ''${object_code[@]} -o ${name}.${target}.elf ''${extra_ld_args[@]}
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
          pkgs = nixpkgs.legacyPackages."${system}";
          target = "armv7a-vmsa-tz";
          fentISS-srcs = {
            xng = pkgs.requireFile {
              name = "14-033.094.ops+${target}+zynq7000.r14040.tbz2";
              url = "http://fentiss.com";
              sha256 = "01wrisyqhhi6v4pp4cxy60a13a5w3h5a3jnbyzmssk4q6gkkrd9i";
            };
            xng-smp = pkgs.requireFile {
              name = "14-033.094.ops+${target}+zynq7000.r16736.tbz2";
              url = "http://fentiss.com";
              sha256 = "1gb0cq3mmmr2fqj49p4svx07h5ccs8v564awlsc56mfjhm6jg3n4";
            };
            lithos = pkgs.requireFile {
              name = "020.080.ops.r7048.XNG-r13982.tbz2";
              url = "https://fentiss.com";
              sha256 = "080pxsmwj8hh0dirb8x3225gvpmk48lb54lf97bggp98jgss6kls";
            };
            ske = pkgs.requireFile {
              name = "14-034.010.ops.r711.tbz2";
              url = "http://fentiss.com";
              sha256 = "15pdl94502kk0kis8fdni886lybsm7204blra2cnnkidjrdmd4kk";
            };
          };
          skeOps = lib.buildSkeOps { inherit pkgs; src = fentISS-srcs.ske; };
          xng-smp = rec {
            ops = lib.buildXngOps { inherit pkgs; src = fentISS-srcs.xng-smp; };
            exampleDir = ops.dev + "/xre-examples";
            genCheckFromExample = { name, partitions, hardFp ? false }: lib.buildXngSysImage {
              inherit name pkgs hardFp;
              xngOps = ops;
              xcf = exampleDir + "/${name}/xml";
              partitions = pkgs.lib.mapAttrs (_: v: { src = exampleDir + "/${name}/${v}"; }) partitions;
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
            normalChecks = (builtins.listToAttrs (builtins.map
              ({ name, ... } @ args: {
                name = "example_${name}";
                value = xng-smp.genCheckFromExample args;
              })
              examples));
            makefileChecks = (builtins.listToAttrs (builtins.map
              ({ name, ... } @ args: {
                name = "makefile_example_${name}";
                value = lib.buildXngConfig rec {
                  inherit name pkgs;
                  xngOps = xng-smp.ops;
                  src = fentISS-srcs.xng-smp;
                  xngConfigurationPath = "xre-examples/${name}";
                };
              })
              (examples ++ makeFileOnlyExamples)));
          };
          # xng-lithos = {
          #   ops = lib.buildXngOps {
          #     inherit pkgs; srcs = [
          #     fentISS-srcs.xng
          #     fentISS-srcs.lithos
          #   ];
          #   };
          # };
        in
        {
          inherit skeOps;
          xng-smp-ops = xng-smp.ops;
          # xng-lithos-ops = xng-lithos.ops;
        }
        // xng-smp.normalChecks
        // xng-smp.makefileChecks;
    };
}

