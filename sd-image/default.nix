{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/sd-card/sd-image.nix") ];

  config = {
    # Reuse maintained image initialization without generic hardware selection.
    hardware.enableAllHardware = lib.mkForce false;

    # Never collect an unregistered first-boot system if initialization fails.
    systemd.services.nix-gc = lib.mkIf config.nix.gc.automatic {
      requires = [ "register-nix-paths.service" ];
      after = [ "register-nix-paths.service" ];
    };

    boot.loader.grub.enable = false;

    boot.consoleLogLevel = lib.mkDefault 7;

    boot.kernelParams = [
      # This is ugly and fragile, but the sdImage image has an msdos
      # table, so the partition table id is a 1-indexed hex
      # number. So, we drop the hex prefix and stick on a "02" to
      # refer to the root partition.
      "root=PARTUUID=${lib.strings.removePrefix "0x" config.sdImage.firmwarePartitionID}-02"
      "rootfstype=ext4"
      "fsck.repair=yes"
      "rootwait"
    ];

    sdImage =
      let
        kernel-params = pkgs.writeTextFile {
          name = "cmdline.txt";
          text = ''
            ${lib.strings.concatStringsSep " " config.boot.kernelParams}
          '';
        };
        cfg = config.raspberry-pi-nix;
        version = cfg.kernel-version;
        board = cfg.board;
        kernel = "${config.system.build.kernel}/${config.system.boot.loader.kernelFile}";
        initrd = "${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";
        populate-kernel =
          if cfg.uboot.enable
          then ''
            cp ${cfg.uboot.package}/u-boot.bin firmware/u-boot-rpi-arm64.bin
          ''
          else ''
            cp "${kernel}" firmware/kernel.img
            cp "${initrd}" firmware/initrd
            cp "${kernel-params}" firmware/cmdline.txt
          '';
      in
      {
        firmwarePartitionName = cfg.firmware-partition-label;
        firmwareSize = lib.mkDefault 128;
        populateFirmwareCommands = ''
          ${populate-kernel}
          cp -r ${pkgs.raspberrypifw}/share/raspberrypi/boot/{start*.elf,*.dtb,bootcode.bin,fixup*.dat,overlays} firmware
          cp ${config.hardware.raspberry-pi.config-output} firmware/config.txt
        '';
        populateRootCommands =
          if cfg.uboot.enable
          then ''
            mkdir -p ./files/boot
            ${config.boot.loader.generic-extlinux-compatible.populateCmd} -c ${config.system.build.toplevel} -d ./files/boot
          ''
          else ''
            mkdir -p ./files/sbin
            content="$(
              echo "#!${pkgs.bash}/bin/bash"
              echo "exec ${config.system.build.toplevel}/init"
            )"
            echo "$content" > ./files/sbin/init
            chmod 744 ./files/sbin/init
          '';
      };
  };
}
