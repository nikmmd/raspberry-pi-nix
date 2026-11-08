# Official vendor binary kernels

In an existing Raspberry Pi NixOS configuration:

```nix
raspberry-pi-nix = {
  board = "bcm2711"; # bcm2712 for Pi 5
  kernel-backend = "binary";
  kernel-version = "v6_18";
  uboot.enable = true; # existing extlinux generation support
};
```

`kernel-backend` defaults to `"source"`. `kernel-version` defaults to `"v6_12"`
for **both** backends, so selecting `"binary"` alone selects the registered 6.12
bundle. A binary request prefers the registered series/board when available and
otherwise emits a NixOS warning and builds the same source kernel as an explicit
source request. In particular, `v7_1` currently falls back to source, retaining
source initrd defaults. The source series are `v6_12`, `v6_18`, and `v7_1`;
unknown series fail. There is no `"firmware"` series selector.

## Bundles and availability

Each binary series has its own `flake = false` firmware-repository input:

| Series | Input | Initial vendor tag | Available boards |
| --- | --- | --- | --- |
| v6_12 | rpi-linux-6_12-bin | 1.20260408 | bcm2711, bcm2712 |
| v6_18 | rpi-linux-6_18-bin | 1.20260915 | bcm2711, bcm2712 |

The 6.12 input contains the **6.12.75 legacy vendor baseline**, not a guarantee of
latest upstream security patches. It has not been hardware-boot verified here.
For both bundles, Pi 4 uses `boot/kernel8.img` with 4 KiB pages and Pi 5 uses
`boot/kernel_2712.img` with 16 KiB pages:

| Series / board | Module release |
| --- | --- |
| v6_12 / bcm2711 | 6.12.75-v8+ |
| v6_12 / bcm2712 | 6.12.75-v8-16k+ |
| v6_18 / bcm2711 | 6.18.50-v8+ |
| v6_18 / bcm2712 | 6.18.50-v8-16k+ |

Availability is not boot verification; see [boot verification](#boot-verification)
for the evidence and its limits.

These tables record the initial integration baselines. `flake.nix` and
`flake.lock` are authoritative for the current pins and may advance independently
through reviewed patch-update PRs.

The core overlay exposes `pkgs.rpi-binary-kernels.<series>.<board>`; for example,
`pkgs.rpi-binary-kernels.v6_12.bcm2711`. Flake packages are
`packages.aarch64-linux.linux-binary-<series>-<board>`, for example
`linux-binary-v6_18-bcm2712`. Use `kernel-backend = "source"` to explicitly build
from source even when that series has binaries.

The `binarySeries` registry supplies each series' `bundle` and `isLTS` metadata.
The shared package validates the requested series against the extracted vendor
release; a new input cannot silently relabel a different kernel series.
Missing registry/board entries permit warned source fallback. Corrupt bundles,
wrong release series, and missing or mismatched module inventories are errors,
**not** reasons to silently use source.

For an effective binary selection, the kernel, modules, DTBs, overlays, and
`raspberrypifw` boot firmware come from that series' bundle, through the selected
kernel's `firmwareSource`. Hosts selecting different binary series therefore use
independent matching firmware. Source and source-fallback hosts retain the
existing, separate `rpi-firmware-src` default; updating a binary input does not
update that source-backend firmware pin. Wireless/Bluetooth firmware inputs
remain separate. Do not independently override `raspberrypifw` or run `rpi-update`
with a binary kernel.

Release and numeric version metadata come from vendor `extra/uname_string8` or
`extra/uname_string_2712`, retaining hardware-specific suffixes and filenames.
`kernelOlder` and `kernelAtLeast` describe that numeric version; LTS status comes
from registry metadata. Patch releases are not hardcoded in the package.
Packaging decompresses the vendor image to `Image`, preserves module bytes, and
regenerates dependency indices with native `depmod`. DTBs/overlays retain vendor
filenames under `dtbs/`; `System.map` and informational `Module.symvers` are
included. The actual embedded vendor configuration supplies `kernel.configfile`
and Nixpkgs-compatible `kernel.config` predicates. Config extraction uses a small
native import-from-derivation build during evaluation, not kernel compilation.

## Upgrading a kernel

### Patch update within a registered series

1. Select a [vendor firmware tag or commit](https://github.com/raspberrypi/firmware)
   for the series being upgraded. Inspect its actual `extra/uname_string8` and
   `extra/uname_string_2712`, then confirm the packaged releases/configuration for
   both boards. The firmware release date is not the kernel version, and a newer
   tag need not contain the newest upstream LTS patch. Both board releases must
   remain in the registered series. Moving channels such as `master` can change
   series and must not be assumed to track one permanently.
2. In this repository's `flake.nix`, change **only the relevant series input URL**.
   For a 6.18 patch update, replace
   `inputs.rpi-linux-6_18-bin.url = "github:raspberrypi/firmware/1.20260915"`
   with the selected tag/commit, then run:

   ```sh
   nix flake update rpi-linux-6_18-bin
   ```

   For 6.12, change `inputs.rpi-linux-6_12-bin.url` instead and run
   `nix flake update rpi-linux-6_12-bin`. **A fixed tag does not advance:** running
   `nix flake update` without changing that URL does not select a newer release.
   Leave the other series input, `rpi-firmware-src`, the host's `kernel-version`,
   and registry LTS metadata unchanged for an ordinary patch update. Package
   versions and module releases are derived automatically; do not hardcode them
   or re-pin test assertions.
3. Run the checks below and build both board packages for the updated series.
   With an ARM64 builder, also build the relevant actual consumer initrd and
   system/image. Verify the extracted module release against the vendor uname
   metadata and requested series, and inspect the effective binary selection.
   Review vendor configuration/security changes and firmware compatibility.
   Repeat isolated boot testing and the applicable hardware checks; a lock change
   or successful build alone is not evidence of bootability.
4. Update this guide with the version and evidence actually established, then
   commit and publish the reviewed input/lock changes before consumers upgrade.

### Automated patch proposals

The separate `update-rpi-binary-kernels` workflow runs weekly or on manual
dispatch. It discovers registered binary series, inspects immutable revisions of
the vendor firmware branch heads, and proposes only a numerically newer patch in
the same series with matching Pi 4/Pi 5 releases. It does not assume that a vendor
branch name permanently identifies a kernel series.

The workflow checks out the repository's default branch, so merge it there before
using scheduled/manual runs. Repository settings must permit Actions to create
pull requests. Validation uses read-only permissions; only the separate publishing
job receives repository/PR write permissions and consumes validated update artifacts.

Each series has its own rolling PR. The updater changes that binary input's URL
to the selected commit and updates its lock; other binary and source pins remain
unchanged. CI runs candidate-selection tests, evaluates the binary behavior checks
and packages both board binaries using native x86 build tools, without compiling
a kernel. This is packaging validation, not hardware or full-system boot verification.

If no vendor branch head offers a newer matching binary, the updater leaves the
pin unchanged. In particular, registering a legacy series does not guarantee
continued vendor patch releases. Malformed candidate metadata or a broken bundle
fails validation instead of triggering a source-build fallback.

The workflow neither merges nor deploys updates. Review the PR and complete the
consumer build, firmware/recovery and reboot gates below before activation.

### Adding a new binary series

This is separate from a patch update. Add a dedicated `flake = false` input
`rpi-linux-<series>-bin` pinned to a reviewed vendor tag/commit, and register the
series in `binarySeries` with that input as `bundle` and the correct `isLTS`.
The shared package validates the requested series; do not weaken that check or
repurpose another series' input. Ensure the host's source-series selector
supports the new series, cover available boards and fallback behavior in the
existing checks, and validate packaging, matching firmware, initrds, and boot
before documenting support. The registry drives the binary package exports.

Changing a host from `v6_12` to `v6_18` selects the other registered binary bundle
and matching boot firmware; it does not change either input pin. Selecting
`v7_1` with the binary backend currently warns and builds from source. It does
not discover or download a binary series automatically.

### Consumer upgrade and pre-reboot gate

1. In the consuming flake, ensure the `raspberry-pi-nix` URL targets the published
   branch/revision containing the reviewed change, then update its lock:

   ```sh
   nix flake update raspberry-pi-nix
   ```

   A consumer's old lock continues to use the old kernel even after this
   repository publishes an update. Check the effective result and build it;
   replace `HOST` with the consumer configuration name:

   ```sh
   nix eval --json .#nixosConfigurations.HOST.config.boot.kernelPackages.kernel \
     --apply 'k: { release = k.modDirVersion; binary = k.isRaspberryPiBinary or false; }'
   nixos-rebuild build --flake .#HOST
   ```

   Require `binary = true` and the expected series, patch release, and board
   suffix when a binary deployment is intended; do not mistake source fallback
   for a successful binary upgrade. Build the actual image/initrd as applicable.
2. **Before any reboot, establish firmware compatibility and physical recovery.**
   Retain the previous generation, a recoverable FAT-partition backup, a
   known-good boot medium, and serial/recovery access. Check that the FAT boot
   firmware, DTBs, overlays, `config.txt`, and U-Boot (when used) are compatible
   with the new kernel and the generations you need for recovery. In particular,
   switching between the independently pinned series may require a firmware
   change as well as a kernel change.
3. Use a deployment procedure that explicitly handles the FAT partition.
   `nixos-rebuild boot` only installs the generation for the next boot: **it does
   not activate `raspberry-pi-firmware-migrate.service`**, and enabling U-Boot does
   not make that migration happen before the reboot. Do not reboot on the
   assumption that a newly installed service can repair firmware needed to reach
   that service. Either establish that the existing FAT contents are already
   compatible, or arrange a controlled activation/migration of the intended new
   generation (or prepare and validate a replacement boot medium) before relying
   on it. A service from the old running generation is not proof that the new
   generation's firmware was installed. Inspect migration results and actual FAT
   contents before passing this gate; if compatibility/recovery is uncertain,
   stop rather than reboot.
4. Only after that gate passes, complete the consumer's deployment/reboot
   procedure. Check `uname -r`, failed units, kernel/module/firmware logs, and
   required peripherals. An extlinux rollback changes kernel/initrd/module paths
   but **does not roll back shared FAT firmware, DTBs, overlays, or U-Boot**.

## Customization, security, and boot limits

- Effective binary selections reject kernel patches, feature/configuration/seed
  overrides, and `boot.extraModulePackages`. There are no development headers or
  usable `kernel.dev`/`commonMakeFlags`; use the source backend for external
  modules, ZFS, custom signing, or kernel configuration changes. Unsupported
  customizations fail rather than choosing source behind the operator's back.
- Binary initrds use Pi-specific module defaults and, where available, default
  systemd TPM2 support off because generic PC TPM drivers are absent. Missing
  module checks stay strict. Board-specific SPI/I2C TPM setups need explicit
  configuration. These changes do not apply to source or source fallback.
- The previously verified 6.18.50 vendor configuration lacks Landlock, Yama, BPF
  LSM, hardened usercopy, and kernel BTF/debug information. Recheck the actual
  configuration for each bundle; a requested `lsm=` list cannot add missing
  features. Successful boot is **not security equivalence** with a source-built
  NixOS kernel; use source when these protections or BTF-dependent workflows are
  required. This does not mean all eBPF or Tailscale is unavailable.
- This is ARM64 only. Pi 5's 16 KiB pages require compatible userspace. U-Boot and
  uncached userspace may still compile; only kernel/module compilation is removed.
- Existing U-Boot/extlinux generations retain separate kernel/initrd/module
  paths and use the firmware-provided device tree. Direct firmware boot remains
  available but does not provide an extlinux generation menu. The existing
  migration service updates shared FAT files in place, not per generation.

## Checks and hardware validation

Run the small consumer-behavior check on a Nix host with flakes enabled:

```sh
nix eval --impure --json --file tests/binary-kernel.nix --apply 'builtins.mapAttrs (_: v: v.checks)'
nix build .#linux-binary-v6_12-bcm2711 .#linux-binary-v6_12-bcm2712 --no-link
nix build .#linux-binary-v6_18-bcm2711 .#linux-binary-v6_18-bcm2712 --no-link
# With an aarch64-linux builder, build the consumer's actual initrd:
nix build .#nixosConfigurations.HOST.config.system.build.initialRamdisk --no-link
```

The behavior check exercises series/board selection, metadata/config predicates,
rejected patches and external modules, warned unavailable-series fallback with
unchanged source initrd defaults, explicit source selection, the default series,
and unknown-series rejection. An unqualified `nix flake check` also includes
source-kernel builds.

Before activation, build the actual consumer image/initrd and retain a known-good
boot medium plus serial recovery. On physical Pi 4/Pi 5 hardware, verify
`uname -r`, page size, matching module tree, root storage, and the peripherals you
use. Review failed units and kernel module/firmware errors. Separately exercise
U-Boot selection of a previous generation and a source-kernel generation while
keeping compatible firmware. Remote builds and direct-kernel QEMU boot do not
validate physical firmware, U-Boot rollback, networking, display, camera, or NVMe.

## Boot verification

The 6.18.50 bundle at tag `1.20260915` previously passed packaging and
module/config/DTB checks for both boards. A consumer NixOS 26.05 systemd initrd
and complete SD image built on native ARM64 without compiling the kernel. QEMU
11.1.2 `raspi4b`, using direct kernel launch, the matching DTB and an isolated
disposable SD snapshot, mounted the root and firmware partitions, completed
activation, and reached **Multi-User System**.

This establishes root/userspace boot, not a clean service-health pass or verified
interactive login. Some application and hardware-dependent services failed in
the isolated emulator; their individual failure causes were not fully diagnosed.
U-Boot selection, rollback and physical peripherals remain unverified.

After the multi-series refactor, all four series/board cases passed the behavior
checks and binary packaging builds. Checks cover host-specific matching firmware
with input pinning enabled and disabled, source selection and warned source
fallback. Consumer NixOS 26.05 initrds built on native ARM64 for both series.

A separate minimal QEMU `raspi4b` smoke booted the 6.12.75 kernel into ARM64
initramfs userspace, loaded a matching vendor module and powered off cleanly.
This is **not** a full 6.12.75 NixOS image boot. The full 6.18.50 boot above
predates the multi-series refactor; physical hardware and U-Boot validation
remain deployment gates for both series.
