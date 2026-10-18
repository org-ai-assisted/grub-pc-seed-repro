#!/bin/bash

## Copyright (C) 2026 - 2026 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## AI-Assisted

## Unit tests for repro.sh's pure logic -- no root, no loop devices, no mmdebstrap.
## repro.sh is sourced (its main() guard keeps it inert on source), then cache_key and
## resolve_seed are exercised directly. Regression guard for:
##  - cache_key must fold suite + mirror + include (a stale suite/mirror must not reuse a cache)
##  - resolve_seed must fail nonzero on a grub-probe failure OR an empty result (never report
##    an empty 'seed=' as a valid seeded RESULT).
## Lint with 'shellcheck -x --source-path=SCRIPTDIR' so the sourced repro.sh is followed.

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
shopt -s inherit_errexit
shopt -s shift_verbose
export LC_ALL=C

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../repro.sh
source "${here}/../repro.sh"

fail_count=0

check_eq() {
   ## check_eq <description> <expected> <actual>  -- pass if equal
   if [ "$2" = "$3" ]; then
      printf '%s\n' "ok   $1"
   else
      printf '%s\n' "FAIL $1 (expected '$2', got '$3')"
      fail_count=$(( fail_count + 1 ))
   fi
}

check_ne() {
   ## check_ne <description> <value-a> <value-b>  -- pass if they differ
   if [ "$2" != "$3" ]; then
      printf '%s\n' "ok   $1"
   else
      printf '%s\n' "FAIL $1 (both '$2')"
      fail_count=$(( fail_count + 1 ))
   fi
}

## --- cache_key (finding #3) ------------------------------------------------

suite='trixie'; mirror='http://deb.debian.org/debian'; target_include='grub-common'
base_key="$(cache_key)"
check_eq 'cache_key stable for identical inputs' "${base_key}" "$(cache_key)"

suite='bookworm'
check_ne 'cache_key changes with suite' "${base_key}" "$(cache_key)"

suite='trixie'; mirror='http://example.invalid/debian'
check_ne 'cache_key changes with mirror' "${base_key}" "$(cache_key)"

mirror='http://deb.debian.org/debian'; target_include='grub-common,grub-pc-bin'
check_ne 'cache_key changes with include' "${base_key}" "$(cache_key)"

## --- resolve_seed (finding #5) ---------------------------------------------

## grub-probe failure must propagate, not be swallowed.
in_target() { return 1; }
rc=0; out="$(resolve_seed / /dev/null)" || rc="$?"
check_eq 'resolve_seed nonzero on probe failure' 1 "${rc}"
check_eq 'resolve_seed empty on probe failure' '' "${out}"

## A probe that succeeds but resolves nothing is still a failed seed.
in_target() { return 0; }
rc=0; out="$(resolve_seed / /dev/null)" || rc="$?"
check_eq 'resolve_seed nonzero on empty result' 1 "${rc}"

## A real multi-line probe result is comma-joined and succeeds.
in_target() { printf '%s\n' '/dev/loop0' '/dev/loop1'; }
rc=0; out="$(resolve_seed / /dev/null)" || rc="$?"
check_eq 'resolve_seed zero on real result' 0 "${rc}"
check_eq 'resolve_seed joins multi-line result' '/dev/loop0, /dev/loop1' "${out}"

## --- summary ---------------------------------------------------------------

if [ "${fail_count}" -eq 0 ]; then
   printf '%s\n' 'PASS: all unit tests passed'
   exit 0
fi
printf '%s\n' "FAIL: ${fail_count} unit test(s) failed"
exit 1
