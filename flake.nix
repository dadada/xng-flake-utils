{
  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages."${system}";
      stdenv = pkgs.gcc49Stdenv; # TODO is this really necessary?
      customPython = (pkgs.python3.withPackages (pythonPackages: with pythonPackages; [ lxml ]));
    in
    {
      # build an SKE OPS from a tarball release
      lib.builSkeOps = { pkgs, src }: stdenv.mkDerivation {
        name = "xng-ops";
        inherit src;
        nativeBuildInputs = [ pkgs.autoPatchelfHook ];
        buildInputs = with pkgs; [ customPython libxml2 ];
        installPhase = ''
          runHook preInstall
          mkdir $out
          cp -r . $out/
          runHook postInstall
        '';
      };

      # build an XNG OPS from a tarball release
      lib.buildXngOps = { pkgs, src }: stdenv.mkDerivation {
        name = "xng-ops";
        inherit src;
        nativeBuildInputs = [ pkgs.autoPatchelfHook ];
        buildInputs = with pkgs; [ customPython libxml2 ];
        installPhase = ''
          runHook preInstall
          mkdir $out
          cp -r . $out/
          runHook postInstall
        '';
      };

      # compile one XNG configuration
      lib.buildXngConfig = { pkgs, xngOps, name, src, xngConfigurationPath }: stdenv.mkDerivation {
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
      templates = {
        xng-build = {
          path = ./template;
          description = "Simple build script for XNG examples";
        };
      };
      defaultTemplate = self.templates.xng-build;
    };
}

