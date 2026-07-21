---
name: updating-rpi-kernels
description: Use when checking, adding, updating, or reviewing Raspberry Pi Linux kernel series, upstream rpi-X.Y.y branches, kernel flake inputs, or automated kernel update pull requests in this repository.
---

# Updating Raspberry Pi Kernels

## Overview

Treat patch updates and new series differently: CI rolls tracked series forward, while adding a series is an intentional repository change. Compare series numerically and preserve the configured default unless the maintainer asks to change it.

## Existing series update

Use `.github/scripts/update-rpi-kernels.sh <version> <summary-file>`. Accept a revision only when the script observes a successful upstream status or check run. Evaluate both boards:

```bash
nix eval ".#packages.aarch64-linux.\"linux-<version>-bcm2711\".drvPath"
nix eval ".#packages.aarch64-linux.\"linux-<version>-bcm2712\".drvPath"
```

## Adding a newer series

1. Read tracked `vX_Y` entries from `.github/scripts/update-rpi-kernels.sh` and `overlays/default.nix`.
2. List upstream branches:

   ```bash
   gh api --paginate repos/raspberrypi/linux/branches --jq '.[].name'
   ```

3. Parse only `rpi-X.Y.y`. Compare integer major, then integer minor; add only versions greater than the highest tracked version. Do not backfill older missing branches.
4. Verify the selected branch HEAD has a successful visible status or check run.
5. Add `rpi-linux-X_Y-src` in `flake.nix` using `github:raspberrypi/linux/rpi-X.Y.y` and refresh only that lock input.
6. Add the input argument and `vX_Y` entry in `overlays/default.nix` with `patches = [ ];`.
7. Add `vX_Y|rpi-X.Y.y|rpi-linux-X_Y-src` to `tracked_series` in `.github/scripts/update-rpi-kernels.sh`.
8. Run both board evaluations and ShellCheck.
9. Do not change `rpi/default.nix` or README defaults unless explicitly requested.

## Pull request contract

Use a conventional commit. Report the upstream branch, old/new revisions when applicable, compare URL, commit subject/date, upstream check signal, and exact Nix evaluations.

## Common mistakes

- Lexical ordering makes `6.9` appear newer than `6.18`; compare integers.
- Updating only `flake.nix` leaves the overlay and automation incomplete.
- A passing local evaluation does not replace upstream check validation.
