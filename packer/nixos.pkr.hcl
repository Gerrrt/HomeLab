# tpl-nixos, VMID 909: the base for dot-nixos, the VM dotfiles-NixOS's
# bootstrap is tested on (#920 phase 4, ADR-0090).
#
# NixOS has no answer file: it is installed by evaluating a configuration.
# So the build boots the minimal ISO, which logs in at the console by
# itself, and types three things at its shell: phoenix's key for root, a
# fixed address (the ISO runs no guest agent to report its DHCP one, as in
# alpine.pkr.hcl), and sshd. Packer then runs nixos/install.sh over SSH with
# nixos/configuration.nix. Nothing listens on phoenix.
#
# Secure Boot is off: NixOS ships no Microsoft-signed shim.

locals {
  nixos_ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_file)))
}

source "proxmox-iso" "nixos" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_token_id
  token                    = var.proxmox_token_secret
  insecure_skip_tls_verify = var.proxmox_insecure_skip_tls_verify
  node                     = var.node

  vm_id                = 909
  vm_name              = "tpl-nixos"
  template_name        = "tpl-nixos"
  template_description = "NixOS 26.05, built by packer/nixos.pkr.hcl from ${var.nixos_iso_file} on ${timestamp()}. Full clones only (ADR-0074)."
  tags                 = "template;linux"

  os              = "l26"
  machine         = "q35"
  bios            = "ovmf"
  cpu_type        = "host"
  cores           = 2
  sockets         = 1
  memory          = 4096
  scsi_controller = "virtio-scsi-single"
  qemu_agent      = true

  efi_config {
    efi_storage_pool  = var.disk_storage
    efi_type          = "4m"
    pre_enrolled_keys = false
  }

  disks {
    type         = "scsi"
    storage_pool = var.disk_storage
    disk_size    = "40G"
    format       = "raw"
    io_thread    = true
    discard      = true
    ssd          = true
  }

  network_adapters {
    model    = "virtio"
    bridge   = var.bridge
    firewall = false
  }

  boot_iso {
    type     = "ide"
    index    = "2"
    iso_file = var.nixos_iso_file
    unmount  = true
  }

  cloud_init              = true
  cloud_init_storage_pool = var.disk_storage
  cloud_init_disk_type    = "ide"

  # The disk first, then the ISO, as ubuntu.pkr.hcl explains. The ISO's GRUB
  # boots its first entry after 10 s, and the installer logs in as `nixos` on
  # tty1; the wait covers both, then the commands are typed at that shell.
  boot      = "order=scsi0;ide2"
  boot_wait = "90s"
  boot_command = [
    "sudo -i<enter><wait2s>",
    "mkdir -p /root/.ssh && echo '${local.nixos_ssh_public_key}' > /root/.ssh/authorized_keys<enter><wait1s>",
    "ip addr add ${var.cloud_image_build_address}/24 dev $(ip -o link | awk -F': ' '/: en/ {print $2; exit}')<enter><wait1s>",
    "systemctl start sshd<enter>",
  ]

  communicator         = "ssh"
  ssh_username         = "root"
  ssh_host             = var.cloud_image_build_address
  ssh_private_key_file = pathexpand(var.ssh_private_key_file)
  ssh_timeout          = "20m"
}

build {
  name    = "nixos"
  sources = ["source.proxmox-iso.nixos"]

  provisioner "file" {
    source      = "${abspath(path.root)}/nixos/configuration.nix"
    destination = "/tmp/configuration.nix"
  }

  provisioner "shell" {
    script = "${abspath(path.root)}/nixos/install.sh"
  }
}
