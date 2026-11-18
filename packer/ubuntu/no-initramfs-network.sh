#!/bin/sh
# Leaves networking out of every initramfs in the template, as root over
# Packer's SSH session (packer/ubuntu.pkr.hcl). Runs after the upgrade, so the
# kernel a clone boots is one of the images rebuilt here.
#
# Ubuntu 26.04's initramfs is dracut's, and it carries systemd-networkd with a
# catch-all, zzzz-dracut-default.network, that runs DHCP on every interface.
# Every clone of 901 therefore took a lease from the lab pool while it booted,
# before cloud-init's static address applied: eden leased .106 and .101 on its
# boots of 2026-11-16 and 2026-11-18 (docs/changelog.md). The root disk is
# local, so the initramfs needs no network at all. This is the drop-in the
# hand-installed guests carry (build-the-sensor-guest.md §3).
#
# update-initramfs prints a dracut[E] line for dyn-netconf, from
# cloud-initramfs-dyn-netconf, which depends on systemd-networkd. That is the
# omit working; the lsinitrd check below is what decides.
set -eu

cat > /etc/dracut.conf.d/10-homelab-no-network.conf <<'CONF'
# No networking in the initramfs (packer/ubuntu/no-initramfs-network.sh).
# The root disk is local. With systemd-networkd in the image, its catch-all
# DHCPs every interface before cloud-init's static address applies.
# Same line as dracut's own dracut.conf.d/no-network profile.
omit_dracutmodules+=" net-lib systemd-networkd "
CONF
chmod 644 /etc/dracut.conf.d/10-homelab-no-network.conf

built=0
for v in /boot/vmlinuz-*; do
  [ -e "$v" ] || continue
  k="${v#/boot/vmlinuz-}"
  update-initramfs -u -k "$k"
  built=$((built + 1))
done
if [ "$built" -eq 0 ]; then
  echo "no-initramfs-network.sh: no kernel found under /boot" >&2
  exit 1
fi

# Fail the build rather than ship a template whose clones still DHCP at boot.
# The module list is read first, on its own: in `lsinitrd | grep` inside an
# `if`, the status is grep's and `set -e` does not apply, so an lsinitrd that
# failed would read as an image with no networking.
for img in /boot/initrd.img-*; do
  [ -e "$img" ] || continue
  if ! mods="$(lsinitrd -m "$img")" || [ -z "$mods" ]; then
    echo "no-initramfs-network.sh: lsinitrd could not list the modules in $img" >&2
    exit 1
  fi
  if printf '%s\n' "$mods" | grep -qE 'net-lib|systemd-networkd'; then
    echo "no-initramfs-network.sh: $img still carries networking" >&2
    exit 1
  fi
done
echo "no-initramfs-network.sh: $built initramfs image(s) rebuilt without networking"
