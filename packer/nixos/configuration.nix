# The NixOS template's system (tpl-nixos, 909; #920 phase 4, ADR-0090),
# installed by packer/nixos/install.sh beside the hardware-configuration.nix
# that nixos-generate-config writes.
#
# A template, not a guest: no user, no hostname, no address. A clone gets
# those from the Proxmox cloud-init drive, as every other Linux template's
# clone does. dotfiles-NixOS's own nixos.nix is the test's to import, after
# the clean snapshot (test-the-dotfiles-layers.md), not this file's.
{ pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  # systemd-boot, without Secure Boot: NixOS ships no Microsoft-signed shim.
  # No EFI variables written from the installer; bootctl's fallback copy,
  # EFI/BOOT/BOOTX64.EFI, is what a clone boots.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;

  # A clone's disk is larger than the template's (40G -> the guest's size).
  boot.growPartition = true;
  fileSystems."/".autoResize = true;

  # cloud-init names the host and writes the network, for networkd.
  networking.hostName = "";
  networking.useDHCP = false;
  networking.useNetworkd = true;
  services.cloud-init = {
    enable = true;
    network.enable = true;
  };

  # The clone's cloud-init user, with the sudo rule cloud-init writes for it.
  # NixOS's sudoers does not read sudoers.d unless told to.
  users.mutableUsers = true;
  security.sudo.extraConfig = "@includedir /etc/sudoers.d";
  environment.etc."cloud/cloud.cfg.d/90-default-user.cfg".text = ''
    system_info:
      default_user:
        lock_passwd: true
        groups: [wheel]
        sudo: ["ALL=(ALL) NOPASSWD:ALL"]
        shell: /run/current-system/sw/bin/bash
  '';

  services.qemuGuest.enable = true;
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # git for the dotfiles' clone, curl for their preflights. Flakes on, which
  # dotfiles-NixOS's home-manager step may use.
  environment.systemPackages = with pkgs; [ git curl ];
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  time.timeZone = "UTC";
  system.stateVersion = "26.05";
}
