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
mount /dev/disk/by-label/nixos /mnt
# 0077, so the random seed systemd-boot writes is not world-readable.
mkdir -p /mnt/boot
mount -o fmask=0077,dmask=0077 /dev/disk/by-label/BOOT /mnt/boot

nixos-generate-config --root /mnt
install -m 0644 /tmp/configuration.nix /mnt/etc/nixos/configuration.nix
# The ISO's nixos channel is copied in: dotfiles-NixOS's README runs
# nixos-rebuild switch from channels, not a flake.
nixos-install --no-root-passwd

sync
umount -R /mnt
