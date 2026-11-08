# nix eval --impure --json --file tests/binary-kernel.nix --apply 'builtins.mapAttrs (_: v: v.checks)'
let
  flake = builtins.getFlake (toString ./..);
  lib = flake.inputs.nixpkgs.lib;
  seriesNames = [
    "v6_12"
    "v6_18"
  ];
  boards = [
    "bcm2711"
    "bcm2712"
  ];
  rejects = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  bundleFor = series: flake.inputs.${"rpi-linux-${lib.removePrefix "v" series}-bin"};
  mkSystem =
    board: backend: series: extra:
    lib.nixosSystem {
      modules = [
        flake.nixosModules.raspberry-pi
        {
          nixpkgs.hostPlatform = "aarch64-linux";
          raspberry-pi-nix = {
            inherit board;
            kernel-backend = backend;
            uboot.enable = true;
          }
          // lib.optionalAttrs (series != null) {
            kernel-version = series;
          };
          system.stateVersion = "24.11";
          fileSystems."/" = {
            device = "/dev/disk/by-label/NIXOS_SD";
            fsType = "ext4";
          };
        }
        extra
      ];
    };
  initrdDefaults =
    system: with system.config.boot.initrd; {
      inherit includeDefaultModules availableKernelModules kernelModules;
      tpm2 = systemd.tpm2.enable or null;
    };
  firmwareSource = system: toString system.pkgs.raspberrypifw.src;
  forKernel =
    { board, series }:
    let
      system = mkSystem board "binary" series { };
      kernel = system.config.boot.kernelPackages.kernel;
      defaults = backend: mkSystem board backend null { };
      source = mkSystem board "source" series { };
      patched = mkSystem board "binary" series {
        boot.kernelPatches = [
          {
            name = "unsupported";
            patch = null;
          }
        ];
      };
      external = mkSystem board "binary" series (
        { pkgs, ... }: {
          boot.extraModulePackages = [ pkgs.hello ];
        }
      );
      forPin =
        pin:
        let
          extra.raspberry-pi-nix.pin-inputs.enable = pin;
          binary = mkSystem board "binary" series extra;
          otherSeries = if series == "v6_12" then "v6_18" else "v6_12";
          other = mkSystem board "binary" otherSeries extra;
          explicitSource = mkSystem board "source" series extra;
          fallback = mkSystem board "binary" "v7_1" extra;
          fallbackSource = mkSystem board "source" "v7_1" extra;
          binarySource = toString binary.config.boot.kernelPackages.kernel.firmwareSource;
          otherSource = toString other.config.boot.kernelPackages.kernel.firmwareSource;
        in
        assert firmwareSource binary == binarySource;
        assert firmwareSource binary == toString (bundleFor series);
        assert firmwareSource other == otherSource;
        assert firmwareSource other == toString (bundleFor otherSeries);
        assert firmwareSource binary != firmwareSource other;
        assert firmwareSource explicitSource == toString flake.inputs.rpi-firmware-src;
        assert firmwareSource fallback == firmwareSource fallbackSource;
        assert firmwareSource fallback == toString flake.inputs.rpi-firmware-src;
        assert
          fallback.config.boot.kernelPackages.kernel.drvPath
          == fallbackSource.config.boot.kernelPackages.kernel.drvPath;
        assert !(fallback.config.boot.kernelPackages.kernel.isRaspberryPiBinary or false);
        assert fallback.config.boot.initrd.includeDefaultModules;
        assert initrdDefaults fallback == initrdDefaults fallbackSource;
        assert lib.any (lib.hasInfix "v7_1") fallback.config.warnings;
        assert !lib.any (lib.hasInfix "falling back to a source build") binary.config.warnings;
        true;
    in
    {
      checks =
        assert kernel.isRaspberryPiBinary;
        assert kernel.isLTS && !kernel.isHardened && !kernel.isZen && !kernel.isLibre;
        assert
          lib.versions.majorMinor kernel.version
          == lib.replaceStrings [ "_" ] [ "." ] (lib.removePrefix "v" series);
        assert kernel.kernelAtLeast kernel.version && !kernel.kernelOlder kernel.version;
        assert kernel.config.isSet "MODULES" && kernel.config.isYes "MODULES";
        assert kernel.config.getValue "MODULES" == "y";
        assert kernel.config.isModule "CFG80211" && kernel.config.isEnabled "CFG80211";
        assert kernel.config.isYes (if board == "bcm2711" then "ARM64_4K_PAGES" else "ARM64_16K_PAGES");
        assert !system.config.boot.initrd.includeDefaultModules;
        assert builtins.elem "dm_mod" system.config.boot.initrd.kernelModules;
        assert rejects patched.config.boot.kernelPackages.kernel.drvPath;
        assert rejects (kernel.override { features.efiBootStub = true; }).drvPath;
        assert rejects (kernel.override { randstructSeed = "unsupported"; }).drvPath;
        assert rejects (kernel.override { expectedSeries = "99.99"; }).drvPath;
        assert rejects kernel.dev;
        assert rejects external.config.system.build.toplevel.drvPath;
        assert lib.all (backend: (defaults backend).config.raspberry-pi-nix.kernel-version == "v6_12") [
          "source"
          "binary"
        ];
        assert (defaults "binary").config.boot.kernelPackages.kernel.isRaspberryPiBinary;
        assert !(source.config.boot.kernelPackages.kernel.isRaspberryPiBinary or false);
        assert source.config.boot.initrd.includeDefaultModules;
        assert lib.all forPin [
          true
          false
        ];
        assert lib.all
          (backend: rejects (mkSystem board backend "v99_99" { }).config.boot.kernelPackages.kernel.drvPath)
          [
            "source"
            "binary"
          ];
        true;
      inherit kernel;
      initrd = system.config.system.build.initialRamdisk;
    };
in
lib.listToAttrs (
  map
    (case: {
      name = "${case.series}-${case.board}";
      value = forKernel case;
    })
    (
      lib.cartesianProduct {
        series = seriesNames;
        board = boards;
      }
    )
)
