#!/bin/sh
# Installs Arch onto /dev/sda from the live ISO, as root over Packer's SSH
# session (packer/arch.pkr.hcl, #920 phase 2, ADR-0090). Arch has no
# unattended installer worth the name; archinstall's JSON changes between
# releases, so this is the wiki's installation guide, scripted.
#
# The result is a template, not a guest: no user, root locked, and cloud-init
# to give a clone its user, key, hostname and address from the Proxmox drive.
set -eu

disk=/dev/sda

# Packages come from the mirrors reflector picked at boot. Wait for the live
# system's own keyring and mirror list before pacstrap needs them.
systemctl start pacman-init.service
for _ in $(seq 60); do
  systemctl is-active --quiet reflector.service || break
  sleep 5
done

# GPT: a 1 GiB ESP and the rest as root.
sgdisk --zap-all "$disk"
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:ESP -n 2:0:0 -t 2:8304 -c 2:root "$disk"
partprobe "$disk"
udevadm settle
mkfs.fat -F 32 -n ESP "${disk}1"
mkfs.ext4 -q -F -L root "${disk}2"
mount "${disk}2" /mnt
# 0077 so the random seed bootctl writes is not world-readable; genfstab
# carries the options into the installed fstab.
mount --mkdir -o fmask=0077,dmask=0077 "${disk}1" /mnt/boot

# What dotfiles-Arch's bootstrap expects to find (its README): sudo, git and
# a UTF-8 locale. curl for the dotfiles' other preflights.
pacstrap -K /mnt base linux openssh sudo git curl cloud-init qemu-guest-agent \
  cloud-guest-utils gptfdisk
genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot /mnt sh -eu <<'CHROOT'
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
echo tpl-arch > /etc/hostname

# systemd-boot. Secure Boot is off for this template (ADR-0090): Arch ships
# no Microsoft-signed shim. bootctl also writes EFI/BOOT/BOOTX64.EFI, the
# fallback a clone's fresh EFI vars boot from.
bootctl install
cat > /boot/loader/loader.conf <<'L'
default arch.conf
timeout 0
L
root_uuid=$(blkid -s UUID -o value /dev/sda2)
cat > /boot/loader/entries/arch.conf <<L
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=UUID=$root_uuid rw
L

# Networking by systemd-networkd, which cloud-init's network stage writes
# for (it renders the Proxmox drive's ipconfig0 as a .network file).
# qemu-guest-agent has no [Install]: udev starts it when the virtio port appears.
systemctl enable systemd-networkd systemd-resolved sshd
# Every cloud-init stage that this release ships. Since 24.3 the unit names
# changed (cloud-init-main, cloud-init-network), and Fedora 44's presets left
# one out (#920 phase 1), so each is named rather than trusted to a preset.
for u in cloud-init-local cloud-init-main cloud-init-network cloud-init cloud-config cloud-final; do
  if systemctl list-unit-files "$u.service" | grep -q "^$u.service"; then
    systemctl enable "$u.service"
  fi
done

# Root is locked; a clone's only login is cloud-init's user with phoenix's key.
# cloud-init writes the clone user's own sudo rule (90-cloud-init-users).
passwd -l root

# Per-machine state: nothing has run yet, but be explicit.
rm -f /etc/ssh/ssh_host_*
: > /etc/machine-id
cloud-init clean --logs || true
CHROOT

# From outside the chroot: arch-chroot bind-mounts the live system's
# resolv.conf over the target's, so `ln` inside it fails with "same file".
ln -sf ../run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf

sync
umount -R /mnt
