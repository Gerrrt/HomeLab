# tpl-opensuse-tw, VMID 905: the base for dot-opensuse, the VM
# dotfiles-openSUSE's bootstrap is tested on (#920 phase 2, ADR-0090).
#
# The Tumbleweed NET installer is still linuxrc and YaST, so AutoYaST drives
# it. The profile is served over Packer's HTTP server on phoenix's port 8800,
# as Debian's preseed is (debian.pkr.hcl): ADR-0074's one exception to
# "answer files on a disc", for installers that cannot read one. YaST can't,
# in practice. linuxrc reads a profile from a second CD, but YaST then fetches
# it again from a by-id path it builds itself and mangles
# (device://disk/by-id/... becomes /dev//by-id/...), whether the kernel line
# said label://OEMDRV or device://sr0, and it does not know cd: at all. All
# three were tried on 2026-10-09. NET, not the DVD: it installs today's packages from the
# mirror, which is what a fresh Tumbleweed box gets, and it is a tenth of
# the size on the ISO store.

source "proxmox-iso" "opensuse" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_token_id
  token                    = var.proxmox_token_secret
  insecure_skip_tls_verify = var.proxmox_insecure_skip_tls_verify
  node                     = var.node

  vm_id                = 905
  vm_name              = "tpl-opensuse-tw"
  template_name        = "tpl-opensuse-tw"
  template_description = "openSUSE Tumbleweed, built by packer/opensuse.pkr.hcl from ${var.opensuse_iso_file} on ${timestamp()}. Full clones only (ADR-0074)."
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
    pre_enrolled_keys = true
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
    iso_file = var.opensuse_iso_file
    unmount  = true
  }

  http_content = {
    "/autoinst.xml" = templatefile("${abspath(path.root)}/opensuse/autoinst.xml.pkrtpl", {
      ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_file)))
    })
  }
  http_port_min = 8800
  http_port_max = 8800

  cloud_init              = true
  cloud_init_storage_pool = var.disk_storage
  cloud_init_disk_type    = "ide"

  # The disk first, then the installer, as ubuntu.pkr.hcl explains.
  boot = "order=scsi0;ide2"

  # The installer's GRUB finds its own files by searching for them, so the
  # prompt can boot the kernel directly with the profile's location, as
  # Debian's does, rather than drive the graphical menu.

  boot_wait = "20s"
  boot_command = [
    "c<wait3s>",
    "linux /boot/x86_64/loader/linux autoyast=http://{{ .HTTPIP }}:{{ .HTTPPort }}/autoinst.xml textmode=1<enter><wait3s>",
    "initrd /boot/x86_64/loader/initrd<enter><wait3s>",
    "boot<enter>",
  ]

  communicator         = "ssh"
  ssh_username         = "packer"
  ssh_private_key_file = pathexpand(var.ssh_private_key_file)
  ssh_timeout          = "60m"
}

build {
  name    = "opensuse"
  sources = ["source.proxmox-iso.opensuse"]

  provisioner "shell" {
    execute_command = "sudo -E sh -eu '{{ .Path }}'"
    inline = [
      "zypper --non-interactive --gpg-auto-import-keys refresh",
      "zypper --non-interactive dist-upgrade --no-recommends",
      "zypper --non-interactive clean --all",
      # Every cloud-init stage this release ships, named rather than left to
      # a preset (#920 phase 1: Fedora 44's left one out).
      "for u in cloud-init-local cloud-init-main cloud-init-network cloud-init cloud-config cloud-final; do if systemctl list-unit-files \"$u.service\" | grep -q \"^$u.service\"; then systemctl enable \"$u.service\"; fi; done",
      "rm -f /etc/ssh/ssh_host_*",
      "cloud-init clean --logs --machine-id",
    ]
  }

  # Last: remove the build user, as ubuntu.pkr.hcl does and for its reasons.
  provisioner "shell" {
    execute_command = "sudo -E sh -eu '{{ .Path }}'"
    skip_clean      = true
    inline = [
      "rm -f /etc/sudoers.d/90-packer",
      "userdel -f -r packer || true",
    ]
  }
}
