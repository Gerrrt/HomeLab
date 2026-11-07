#!/bin/sh
# Installs NixOS onto /dev/sda from the minimal ISO, as root over Packer's SSH
# session (packer/nixos.pkr.hcl, #920 phase 4, ADR-0090). NixOS is installed
# by evaluating a configuration, not by answering questions, so this is the
# manual's partitioning and nixos-install, scripted.
set -eu

disk=/dev/sda

parted -s "$disk" -- mklabel gpt \
  mkpart ESP fat32 1MiB 513MiB set 1 esp on \
  mkpart root ext4 513MiB 100%
udevadm settle
mkfs.fat -F 32 -n BOOT "${disk}1"
mkfs.ext4 -q -F -L nixos "${disk}2"
# By device, not /dev/disk/by-label: udev had not made the label's link yet
# when the first build mounted it (2026-10-09). hardware-configuration.nix
# still names the filesystems by UUID.
# With the type said: the minimal ISO had not loaded ext4 yet, and mount's
# own detection then tried the partition as FAT and gave up (2026-10-09).
udevadm settle
mount -t ext4 "${disk}2" /mnt
# 0077, so the random seed systemd-boot writes is not world-readable.
mkdir -p /mnt/boot
mount -t vfat -o fmask=0077,dmask=0077 "${disk}1" /mnt/boot

nixos-generate-config --root /mnt
install -m 0644 /tmp/configuration.nix /mnt/etc/nixos/configuration.nix
# The ISO's nixos channel is copied in: dotfiles-NixOS's README runs
# nixos-rebuild switch from channels, not a flake.
nixos-install --no-root-passwd

sync
umount -R /mnt
