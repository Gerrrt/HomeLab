#!/bin/sh
# Purges the Ubuntu server seed's services that no guest cloned from 901 uses,
# as root over Packer's SSH session (packer/ubuntu.pkr.hcl). Every clone is a
# KVM guest on Saruman with no modem, SAN, laptop hardware or desktop, and
# nothing in this repository installs a snap. The eden audit of 2026-11-13
# found all eight running there; they were purged on eden by hand on
# 2026-11-16 (docs/changelog.md), and this carries the same purge into the
# template.
#
# Purging them also purges the ubuntu-server and ubuntu-server-minimal
# metapackages, which would leave everything those two pulled in marked
# automatic, for a later `apt autoremove` to take: sudo, apparmor,
# unattended-upgrades and the rest. So their other dependencies are marked
# manual first.
set -eu

cloud-init status --wait >/dev/null 2>&1 || true

PRUNE="open-vm-tools modemmanager snapd thermald multipath-tools open-iscsi kdump-tools udisks2"
EXCLUDE='^(open-vm-tools|modemmanager|snapd|thermald|multipath-tools|open-iscsi|kdump-tools|udisks2)$'

keep=$(apt-cache depends --installed --no-pre-depends --no-suggests \
         --no-conflicts --no-breaks --no-replaces --no-enhances \
         ubuntu-server ubuntu-server-minimal 2>/dev/null \
       | awk '/Depends:|Recommends:/ { print $2 }' | tr -d '<>' | sort -u \
       | grep -vE "$EXCLUDE" || true)
if [ -n "$keep" ]; then
  # shellcheck disable=SC2086 # one package name per word
  apt-mark manual $keep >/dev/null
fi

installed=""
for p in $PRUNE; do
  if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q '^install ok installed'; then
    installed="$installed $p"
  fi
done
if [ -n "$installed" ]; then
  # shellcheck disable=SC2086
  DEBIAN_FRONTEND=noninteractive apt-get -y purge $installed
fi

# kdump-tools reserved crash-kernel memory on the kernel line; without it the
# reservation is dead weight on every clone. The installer also copies the
# boot command's `autoinstall` (packer/ubuntu.pkr.hcl) into
# GRUB_CMDLINE_LINUX_DEFAULT, so every clone booted with it. It does nothing
# on an installed system, but it is not a choice anyone made.
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="autoinstall"$/GRUB_CMDLINE_LINUX_DEFAULT=""/' /etc/default/grub
update-grub

# Fail the build rather than ship a template that still carries one.
for p in $PRUNE; do
  if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q '^install ok installed'; then
    echo "prune.sh: $p is still installed" >&2
    exit 1
  fi
done
if grep -q crashkernel /boot/grub/grub.cfg; then
  echo "prune.sh: crashkernel= is still on the kernel line" >&2
  exit 1
fi
if grep -q autoinstall /boot/grub/grub.cfg; then
  echo "prune.sh: autoinstall is still on the kernel line" >&2
  exit 1
fi
