#!/bin/bash

## Copyright (C) 2026 - 2026 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## AI-Assisted

## Minimal reproduction of the Kicksecure BIOS Calamares grub-pc install step
## (live-config-dist calamares-bootloader-config.dist), without building an ISO.
##
## Builds a loop disk with the Calamares encrypted BIOS layout (msdos, plain ext4
## /boot, LUKS ext4 root), bootstraps a trixie target with grub-common (as the
## Calamares target has it), then for each scenario restores the target fresh and runs
## the same 'apt-get install grub-pc' the helper runs, recording:
##  - apt-get exit status (the helper has no errexit, so a failure there is ignored)
##  - the grub-pc postinst output
##  - dpkg-query Status after the install
##  - whether a later 'dpkg-reconfigure grub-pc' (finish-grub-setup) succeeds
##
## Scenarios: unseeded | seed-root (grub-probe /) | seed-boot (grub-probe /boot)
##
## Usage (root, throwaway machine -- creates loop devices, LUKS, mounts):
##   ./repro.sh [scenario...]        default: all three
## Output: one summary line per scenario + full logs under ${REPRO_WORK:-/var/lib/grub-pc-seed-repro}.

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
shopt -s inherit_errexit
shopt -s shift_verbose
export LC_ALL=C

## Root-only by default: everything below is created, extracted and executed as root, so
## the work dir must never be one a local user could pre-create (see secure_work_dir).
work="${REPRO_WORK:-/var/lib/grub-pc-seed-repro}"
suite="${REPRO_SUITE:-trixie}"
mirror="${REPRO_MIRROR:-http://deb.debian.org/debian}"
disk_size="${REPRO_DISK_SIZE:-3G}"
image="${work}/disk.img"
## Default mirrors the live ISO squashfs the Calamares target is unpacked from: grub-common,
## grub-pc-bin and the grub-efi binaries are already installed there; grub-pc is not.
target_include="${REPRO_INCLUDE:-grub-common,grub-pc-bin,grub-efi-amd64-bin,grub-efi-amd64-signed,linux-image-amd64}"
## Cache keyed by the package list, so a changed list never reuses a stale bootstrap.
target_tar="${work}/target-$(printf '%s' "${target_include}" | sha256sum | cut -c1-12).tar"
mnt="${work}/mnt"
keyfile="${work}/luks.key"
mapper_name='grub-pc-seed-repro-root'
loopdev=''
## Teardown undoes only what THIS run did.
mapper_opened='false'
mounted_list=()

die() {
   printf '%s\n' "repro: FATAL: $*" >&2
   exit 1
}

[ "$(id -u)" = 0 ] || die "must run as root"

## Refuse a work dir a non-root user could control: it must be a real directory (no
## symlink), owned by root, and not group/other-writable. Created 0700 if absent.
secure_work_dir() {
   local stat_out
   if [ ! -e "${work}" ] && [ ! -L "${work}" ]; then
      mkdir --mode=0700 -- "${work}"
   fi
   [ ! -L "${work}" ] || die "work dir '${work}' is a symlink"
   [ -d "${work}" ] || die "work dir '${work}' is not a directory"
   stat_out="$(stat --format='%u %a' -- "${work}")"
   case "${stat_out}" in
      "0 "?[0145][0145])
         ;;
      *)
         die "work dir '${work}' must be root-owned and not group/other-writable (got uid/mode '${stat_out}')"
         ;;
   esac
}

## Record a mount this run made, so teardown unmounts only those (innermost first).
mount_tracked() {
   mount "$@"
   mounted_list+=( "${!#}" )
}

teardown() {
   local i
   for (( i=${#mounted_list[@]}-1; i>=0; i-- )); do
      umount --lazy -- "${mounted_list[${i}]}" || true
   done
   mounted_list=()
   if [ "${mapper_opened}" = 'true' ]; then
      cryptsetup close "${mapper_name}" || true
      mapper_opened='false'
   fi
   if [ -n "${loopdev}" ]; then
      losetup --detach "${loopdev}" || true
      loopdev=''
   fi
}
trap teardown EXIT

## Calamares encrypted BIOS layout: msdos table, p1 = plain /boot, p2 = LUKS root.
make_disk() {
   safe-rm --force -- "${image}"
   truncate --size="${disk_size}" -- "${image}"
   parted --script -- "${image}" mklabel msdos \
      mkpart primary ext4 1MiB 513MiB \
      mkpart primary ext4 513MiB 100%
   loopdev="$(losetup --find --show --partscan -- "${image}")"
   udevadm settle || true
   mkfs.ext4 -q -F -- "${loopdev}p1"
   head --bytes=64 /dev/urandom > "${keyfile}"
   cryptsetup luksFormat --batch-mode --type luks2 --key-file "${keyfile}" -- "${loopdev}p2"
   cryptsetup open --key-file "${keyfile}" -- "${loopdev}p2" "${mapper_name}"
   mapper_opened='true'
   mkfs.ext4 -q -F -- "/dev/mapper/${mapper_name}"
}

mount_target() {
   mkdir --parents -- "${mnt}"
   mount_tracked -- "/dev/mapper/${mapper_name}" "${mnt}"
   mkdir --parents -- "${mnt}/boot"
   mount_tracked -- "${loopdev}p1" "${mnt}/boot"
}

bind_api() {
   local d
   for d in dev dev/pts proc sys; do
      mkdir --parents -- "${mnt}/${d}"
      mount_tracked --bind -- "/${d}" "${mnt}/${d}"
      ## Slave: events never propagate back to the host (shared propagation is the
      ## systemd default), so unmounting here cannot touch host mounts.
      mount --make-rslave -- "${mnt}/${d}"
   done
}

## Fail loud: a bind left mounted would let reset_target recurse into the host's
## /dev, /proc or /sys. Only unmounts the binds bind_api recorded.
unbind_api() {
   local d i
   local -a keep=()
   for d in dev/pts dev proc sys; do
      for i in "${!mounted_list[@]}"; do
         if [ "${mounted_list[${i}]}" = "${mnt}/${d}" ]; then
            umount -- "${mnt}/${d}"
            unset 'mounted_list[i]'
         fi
      done
   done
   keep=( "${mounted_list[@]}" )
   mounted_list=( "${keep[@]}" )
}

## Scenario names become file names: allowlist them before any path is built.
validate_scenario() {
   case "$1" in
      unseeded|seed-root|seed-boot)
         ;;
      *)
         die "unknown scenario '$1' (allowed: unseeded seed-root seed-boot)"
         ;;
   esac
}

## Bootstrapped once, restored per scenario. grub-common is in the Calamares target
## base already (grub-probe comes from it); grub-pc is NOT.
make_target_tar() {
   [ -s "${target_tar}" ] && return 0
   ## Atomic: an interrupted bootstrap must never leave a tarball a later run reuses.
   mmdebstrap --variant=minbase --include="${target_include}" \
      "${suite}" "${target_tar}.part.tar" "${mirror}"
   mv -- "${target_tar}.part.tar" "${target_tar}"
}

## Mounts below the target root other than its /boot (literal prefix match, no regex).
list_submounts() {
   local target
   while IFS= read -r target; do
      case "${target}" in
         "${mnt}/boot")
            ;;
         "${mnt}"/*)
            printf '%s\n' "${target}"
            ;;
      esac
   done < <(findmnt --list --noheadings --output TARGET)
}

reset_target() {
   local submounts
   ## Never delete while anything but /boot is mounted below the target root.
   submounts="$(list_submounts)"
   [ -z "${submounts}" ] || die "refusing to reset the target: still mounted below it: ${submounts}"
   find "${mnt}" -xdev -mindepth 1 -maxdepth 1 ! -name boot ! -name lost+found -exec safe-rm --recursive --force -- {} +
   find "${mnt}/boot" -xdev -mindepth 1 -maxdepth 1 ! -name lost+found -exec safe-rm --recursive --force -- {} +
   tar --extract --file="${target_tar}" --directory="${mnt}"
}

in_target() {
   ## TMPDIR: the host's (e.g. /tmp/user/0) does not exist in the target and breaks
   ## maintainer scripts' mktemp -- a repro artifact, not the behavior under test.
   chroot "${mnt}" /usr/bin/env DEBIAN_FRONTEND=noninteractive TMPDIR=/tmp "$@"
}

run_scenario() {
   local scenario log seed_from devices apt_rc status reconf_rc
   scenario="$1"
   validate_scenario "${scenario}"
   log="${work}/${scenario}.log"
   true >| "${log}"
   reset_target
   bind_api
   case "${scenario}" in
      unseeded)
         seed_from=''
         ;;
      seed-root)
         seed_from='/'
         ;;
      seed-boot)
         seed_from='/boot'
         ;;
      *)
         die "unknown scenario '${scenario}'"
         ;;
   esac
   devices=''
   if [ -n "${seed_from}" ]; then
      devices="$(in_target grub-probe --target=disk "${seed_from}" 2>>"${log}" || true)"
      devices="${devices//$'\n'/, }"
      printf '%s\n' "grub-pc grub-pc/install_devices multiselect ${devices}" \
         | in_target debconf-set-selections
   fi
   ## The helper runs apt-get update first too (mmdebstrap's tarball ships no lists).
   in_target apt-get update >>"${log}" 2>&1
   apt_rc=0
   in_target apt-get --yes install grub-pc >>"${log}" 2>&1 || apt_rc=$?
   ## '${Status}' is a dpkg-query format, not a shell expansion.
   # shellcheck disable=SC2016
   status="$(in_target dpkg-query --show --showformat='${Status}' grub-pc 2>&1 || true)"
   reconf_rc=0
   in_target dpkg-reconfigure --frontend=noninteractive grub-pc >>"${log}" 2>&1 || reconf_rc=$?
   unbind_api
   printf '%s\n' "RESULT ${scenario} seed='${devices}' apt_rc=${apt_rc} status='${status}' reconfigure_rc=${reconf_rc}"
}

main() {
   local -a scenarios=( "$@" )
   [ "${#scenarios[@]}" -gt 0 ] || scenarios=( unseeded seed-root seed-boot )
   local s
   for s in "${scenarios[@]}"; do
      validate_scenario "${s}"
   done
   secure_work_dir
   make_target_tar
   make_disk
   mount_target
   for s in "${scenarios[@]}"; do
      run_scenario "${s}"
   done
   printf '%s\n' "logs: ${work}/<scenario>.log"
}

main "$@"
