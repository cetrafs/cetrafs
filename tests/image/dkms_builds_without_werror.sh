#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a DKMS build of the module does not treat warnings as errors
#
# The module builds with -Werror so a developer sees every warning. A DKMS
# build runs on a machine that did not write the code, against whatever
# kernel and compiler the update brought, and a new warning there stops the
# build: the node is left with no module for the kernel it just booted
# (audit 2026-11-14 O7). The packaged and the hand-install DKMS configs must
# both pass CETRAFS_NO_WERROR=1 to the module's make.
#
# The suite evaluates each config's MAKE command the way DKMS does (kernelver
# set, the file sourced) and requires the switch in the command it would run.
#
# DISCRIMINATION (measured on the unfixed code): neither command carries the
# switch.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root

for conf in dkms.conf debian/cetrafs-dkms.dkms; do
    cmd="$(cd "$ROOT" && kernelver=6.1.0-test && . "./$conf" && printf '%s' "${MAKE[0]}")" ||
        { fail "$conf: does not evaluate"; continue; }
    log "$conf: $cmd"
    case "$cmd" in *CETRAFS_NO_WERROR=1*) pass "$conf: its DKMS build passes CETRAFS_NO_WERROR=1" ;;
        *) fail "$conf: its DKMS build keeps -Werror: $cmd" ;; esac
done
ct_exit
