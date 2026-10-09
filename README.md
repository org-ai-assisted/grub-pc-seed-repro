# grub-pc-seed-repro

Minimal reproduction of the Kicksecure BIOS Calamares grub-pc install step
(`live-config-dist` `usr/share/calamares/helpers/calamares-bootloader-config.dist`)
without building an ISO. Iterates in minutes instead of a full ISO build + install.

## What it does

`repro.sh` (root, throwaway machine -- loop devices, LUKS, mounts):

1. builds a loop disk with the Calamares encrypted BIOS layout: msdos table, plain ext4
   `/boot`, LUKS2 ext4 root;
2. bootstraps a Debian trixie target with `grub-common` (as the Calamares target has it;
   `grub-pc` is not installed yet);
3. per scenario, restores the target fresh and runs what the helper runs
   (`apt-get update`, optional debconf seed, `apt-get install grub-pc`), then the
   `dpkg-reconfigure grub-pc` that `finish-grub-setup` runs later.

Scenarios: `unseeded`, `seed-root` (`grub-probe --target=disk /`), `seed-boot`
(`grub-probe --target=disk /boot`).

    ./repro.sh                 # all scenarios
    ./repro.sh seed-boot       # one scenario
    REPRO_WORK=/var/tmp/x ./repro.sh

One `RESULT` line per scenario; full logs under `${REPRO_WORK:-/var/tmp/grub-pc-seed-repro}`.

## Results (tested 2026-10-09, trixie, grub-pc 2.12-9+deb13u2, sandbox qube)

    RESULT unseeded   seed=''                                     apt_rc=0 status='install ok installed' reconfigure_rc=0
    RESULT seed-root  seed='/dev/mapper/grub-pc-seed-repro-root'  apt_rc=0 status='install ok installed' reconfigure_rc=0
    RESULT seed-boot  seed='/dev/loop0'                           apt_rc=0 status='install ok installed' reconfigure_rc=0

Findings:

- In a plain chroot, an UNSEEDED `apt-get install grub-pc` does NOT leave grub-pc
  half-configured, and a later `dpkg-reconfigure grub-pc` succeeds. The real BIOS
  Calamares failure therefore depends on something this plain chroot does not reproduce
  (Calamares / live-session environment) -- under investigation with debug logs in the
  live-config-dist helpers.
- `grub-probe --target=disk /boot` resolves the BASE disk before GRUB is installed
  (needs only `grub-common`); `/` resolves to the LUKS mapper device.
- When grub-pc's postinst DOES fail, `apt-get` exits non-zero (100) and the package stays
  `install ok half-configured` -- so a helper without `errexit` silently carries on with a
  half-configured grub-pc. (Observed here only via a repro artifact: a host `TMPDIR` that
  does not exist inside the chroot broke the postinst's `mktemp`; `repro.sh` now pins
  `TMPDIR=/tmp` in the target.)

Not covered: the Calamares job environment, debconf frontends other than noninteractive,
the live ISO's apt sources, and grub-install onto a real BIOS boot disk (results are from
loop devices).

AI-Assisted
