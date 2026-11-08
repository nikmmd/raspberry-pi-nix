# linuxPackagesFor needs an overridable kernel, not just an Image store path.
# Keep the accepted arguments explicit: makeOverridable rejects unknown overrides.
{
  lib,
  stdenvNoCC,
  buildPackages,
  firmware,
  board,
  expectedSeries,
  isLTS,
  kernelPatches ? [ ],
  features ? {
    efiBootStub = false;
  },
  randstructSeed ? "",
}:
let
  variants = {
    bcm2711 = {
      image = "kernel8.img";
      releaseSuffix = "-v8+";
      suffix = "8";
    };
    bcm2712 = {
      image = "kernel_2712.img";
      releaseSuffix = "-v8-16k+";
      suffix = "_2712";
    };
  };
  variant = variants.${board};
  uname = builtins.head (
    lib.splitString "\n" (builtins.readFile "${firmware}/extra/uname_string${variant.suffix}")
  );
  unameMatch = builtins.match "Linux version ([^ ]+) .*" uname;
  release =
    if unameMatch == null then
      throw "Raspberry Pi binary kernel: invalid uname metadata for ${board}."
    else
      builtins.head unameMatch;
  version = lib.removeSuffix variant.releaseSuffix release;
  moduleInventory = builtins.readDir "${firmware}/modules";
  vendorFeatures = {
    efiBootStub = false;
  };
  # Native extraction keeps evaluation independent of the target architecture.
  vendorConfig =
    buildPackages.runCommand "rpi-vendor-config-${board}"
      {
        nativeBuildInputs = with buildPackages; [
          xz
          gzip
        ];
      }
      ''
        xz -dc "${firmware}/modules/${release}/kernel/kernel/configs.ko.xz" > configs.ko
        start=$(LC_ALL=C grep -aobF IKCFG_ST configs.ko | cut -d: -f1)
        end=$(LC_ALL=C grep -aobF IKCFG_ED configs.ko | cut -d: -f1)
        test -n "$start" && test -n "$end" && test "$end" -gt "$start"
        mkdir -p "$out"
        dd if=configs.ko bs=1 skip=$((start + 8)) count=$((end - start - 8)) status=none |
          gzip -dc > "$out/config"
      '';
  # Match Nixpkgs' kernel.config predicates using the actual vendor tristates.
  configValues = lib.listToAttrs (
    lib.concatMap (
      line:
      let
        match = builtins.match "(CONFIG_[^=]+)=([ym])" line;
      in
      lib.optional (match != null) {
        name = builtins.elemAt match 0;
        value = builtins.elemAt match 1;
      }
    ) (lib.splitString "\n" (builtins.readFile "${vendorConfig}/config"))
  );
  config = {
    isSet = key: builtins.hasAttr "CONFIG_${key}" configValues;
    getValue = key: configValues."CONFIG_${key}" or null;
    isYes = key: config.getValue key == "y";
    isNo = key: config.getValue key == "n";
    isModule = key: config.getValue key == "m";
    isEnabled = key: config.isYes key || config.isModule key;
    isDisabled = key: !config.isSet key || config.isNo key;
  }
  // configValues;
  unsupported =
    what: throw "Raspberry Pi binary kernel: ${what} is unsupported; use kernel-backend = \"source\".";
in
assert lib.assertMsg (
  lib.hasSuffix variant.releaseSuffix release
  && builtins.match "${lib.escapeRegex expectedSeries}\\.[0-9]+" version != null
) "Raspberry Pi binary kernel: expected ${expectedSeries} ${board} release, got ${release}.";
assert lib.assertMsg (
  (moduleInventory.${release} or null) == "directory"
) "Raspberry Pi binary kernel: missing module directory for ${release}.";
assert lib.assertMsg (kernelPatches == [ ]) (unsupported "kernel patches/configuration");
assert lib.assertMsg (features == vendorFeatures) (unsupported "kernel feature overrides");
assert lib.assertMsg (randstructSeed == "") (unsupported "randstructSeed");
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "linux-rpi-binary-${board}";
  inherit version;
  src = firmware;
  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  dontFixup = true; # Never strip/rewrite vendor modules or their signatures.
  nativeBuildInputs = [
    buildPackages.kmod
    buildPackages.gzip
    buildPackages.xz
  ];
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib/modules" "$out/dtbs/overlays" "$out/share/raspberrypi-kernel"
    gzip -dc "$src/boot/${variant.image}" > "$out/Image"
    cp -r "$src/modules/${release}" "$out/lib/modules/"
    chmod -R u+w "$out/lib/modules"
    # No dangling build/source links to the vendor build host.
    rm -f "$out/lib/modules/${release}/build" "$out/lib/modules/${release}/source"
    cp "$src"/boot/*.dtb "$out/dtbs/"
    cp "$src"/boot/overlays/*.dtbo "$out/dtbs/overlays/"
    cp "$src/extra/System${variant.suffix}.map" "$out/System.map"
    cp "$src/extra/Module${variant.suffix}.symvers" "$out/share/raspberrypi-kernel/Module.symvers"
    cp "$src/extra/uname_string${variant.suffix}" "$out/share/raspberrypi-kernel/uname_string"
    cp "${vendorConfig}/config" "$out/config"
    grep -F "Linux version ${release} " "$out/share/raspberrypi-kernel/uname_string"
    test "$(modinfo -F vermagic -b "$out" -k ${release} cfg80211 | cut -d ' ' -f 1)" = ${release}
    depmod -b "$out" -F "$out/System.map" ${release}
    test -s "$out/lib/modules/${release}/modules.dep.bin"
    test -s "$out/lib/modules/${release}/modules.builtin.modinfo"
    runHook postInstall
  '';
  passthru = {
    inherit board config isLTS;
    modDirVersion = release;
    kernelOlder = lib.versionOlder version;
    kernelAtLeast = lib.versionAtLeast version;
    features = vendorFeatures;
    isZen = false;
    isHardened = false;
    isLibre = false;
    isRaspberryPiBinary = true;
    # No pretend development output: external modules must fail explicitly.
    dev = unsupported "kernel headers/external modules";
    configfile = "${vendorConfig}/config";
    commonMakeFlags = unsupported "building external modules";
    firmwareSource = firmware;
  };
  meta = {
    description = "Official Raspberry Pi precompiled ${board} kernel and matching modules/DTBs";
    license = lib.licenses.gpl2Only;
    platforms = [ "aarch64-linux" ];
  };
})
