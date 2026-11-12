#!/bin/sh
# Run only in the official Nix container, with a DISPOSABLE image root mounted
# at /target and DISPOSABLE_IMAGE=1. Arguments: system store path, SSH helper.
# This intentionally deletes the disposable store after testing its GC root.
set -eu

test -f /.dockerenv
test "${DISPOSABLE_IMAGE:-}" = 1
test -f /target/nix-path-registration
case "$1:$2" in /nix/store/*:/nix/store/*) ;; *) exit 2 ;; esac
store='local?root=/target'

nix-store --store "$store" --load-db < /target/nix-path-registration
nix-env --store "$store" -p /target/nix/var/nix/profiles/system --set "$1"
nix-store --store "$store" --gc
test -x "/target$2"
printf 'PASS: registered system profile protects SSH across GC\n'

find /target/nix/var/nix/profiles -maxdepth 1 -type l -name 'system*' -delete
nix-store --store "$store" --gc
test ! -e "/target$2"
printf 'PASS: missing system profile reproduces deleted SSH helper\n'
