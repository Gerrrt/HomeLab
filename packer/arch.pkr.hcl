# tpl-arch, VMID 906: the base for dot-arch, the VM dotfiles-Arch's bootstrap
# is tested on (#920 phase 2, ADR-0090).
#
# Arch has no installer to drive with an answer file, so the build drives the
# live ISO instead. Its own cloud-init reads a disc labelled `cidata` and lets
# Packer in as root with phoenix's key (arch/user-data.pkrtpl); Packer then
# runs arch/install.sh over SSH, which partitions, pacstraps and configures
# /dev/sda the way the installation guide does. Nothing listens on phoenix.
#
# Secure Boot is off: Arch ships no Microsoft-signed shim (ADR-0090), and the
# clone is made with `secure_boot = false` to match.

source "proxmox-iso" "arch" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_token_id
  token                    = var.proxmox_token_secret
  insecure_skip_tls_verify = var.proxmox_insecure_skip_tls_verify
  node                     = var.node

  vm_id                = 906
  vm_name              = "tpl-arch"
  template_name        = "tpl-arch"
  template_description = "Arch Linux, built by packer/arch.pkr.hcl from ${var.arch_iso_file} on ${timestamp()}. Full clones only (ADR-0074)."
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
    disk_size    = "32G"
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
    iso_file = var.arch_iso_file
    unmount  = true
  }

  # The live system's seed. `cidata` is the label NoCloud looks for.
  additional_iso_files {
    type             = "ide"
    index            = "0"
    iso_storage_pool = var.iso_storage
    cd_label         = "cidata"
    cd_content = {
      "meta-data" = ""
      "user-data" = templatefile("${abspath(path.root)}/arch/user-data.pkrtpl", {
        ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_file)))
      })
    }
    unmount = true
  }

  cloud_init              = true
  cloud_init_storage_pool = var.disk_storage
  cloud_init_disk_type    = "ide"

  # The disk first, then the ISO, as ubuntu.pkr.hcl explains. The ISO's
  # systemd-boot starts its default entry after 15 s, so no boot command.
  boot      = "order=scsi0;ide2"
  boot_wait = "5s"

  communicator         = "ssh"
  ssh_username         = "root"
  ssh_private_key_file = pathexpand(var.ssh_private_key_file)
  ssh_timeout          = "20m"
}

build {
  name    = "arch"
  sources = ["source.proxmox-iso.arch"]

  provisioner "shell" {
    script = "${abspath(path.root)}/arch/install.sh"
  }
}
