# tpl-kali, VMID 902: the base for #421's attack VM.
#
# WRITTEN, NOT BUILT (ADR-0071 part 2, #790). The attack VM lives on ifrit, which is
# not bought, and a template belongs to the node it was built on. CI proves
# this file parses; the first build on ifrit proves the preseed.
#
# The one source here that uses Packer's HTTP server. Debian's installer reads
# a preseed from the install medium or from a URL, not from a second disc, so
# the seed is served from phoenix for the few seconds the installer fetches it.
# That needs phoenix's own firewall to admit the guest's DHCP address on the
# port below — build-the-lab-templates.md §5 says how, for the day ifrit exists.

source "proxmox-iso" "kali" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_token_id
  token                    = var.proxmox_token_secret
  insecure_skip_tls_verify = var.proxmox_insecure_skip_tls_verify
  node                     = var.kali_node

  vm_id                = 902
  vm_name              = "tpl-kali"
  template_name        = "tpl-kali"
  template_description = "Kali Linux, built by packer/kali.pkr.hcl on ${timestamp()}. Full clones only (ADR-0071)."
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
    efi_storage_pool = var.disk_storage
    efi_type         = "4m"
    # Off: Kali does not ship a Microsoft-signed shim for every kernel it
    # rolls, and a Secure Boot refusal on ifrit is a failure nobody watches.
    pre_enrolled_keys = false
  }

  disks {
    type         = "scsi"
    storage_pool = var.disk_storage
    disk_size    = "64G"
    format       = "raw"
    io_thread    = true
    discard      = true
    ssd          = true
  }

  # net0 only. The range NIC on vmbr1 (build-the-playground.md) is the clone's,
  # added when the attack VM is made from this template, not baked in here.
  network_adapters {
    model    = "virtio"
    bridge   = var.bridge
    firewall = false
  }

  boot_iso {
    type     = "ide"
    index    = "2"
    iso_file = var.kali_iso_file
    unmount  = true
  }

  http_content = {
    "/preseed.cfg" = templatefile("${abspath(path.root)}/kali/preseed.cfg.pkrtpl", {
      ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_file)))
    })
  }
  http_port_min = 8800
  http_port_max = 8800

  cloud_init              = true
  cloud_init_storage_pool = var.disk_storage
  cloud_init_disk_type    = "ide"

  # Kali's EFI GRUB: drop to the prompt and boot the text installer's kernel
  # with the preseed URL, rather than drive the graphical menu.
  boot_wait = "10s"
  boot_command = [
    "c<wait3s>",
    "linux /install.amd/vmlinuz auto=true priority=critical ",
    "preseed/url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg ",
    "debian-installer/locale=en_US.UTF-8 keyboard-configuration/xkb-keymap=us ",
    "netcfg/get_hostname=tpl-kali netcfg/get_domain= ",
    "--- quiet<enter><wait3s>",
    "initrd /install.amd/initrd.gz<enter><wait3s>",
    "boot<enter>",
  ]

  communicator         = "ssh"
  ssh_username         = "packer"
  ssh_private_key_file = pathexpand(var.ssh_private_key_file)
  ssh_timeout          = "60m"
}

build {
  name    = "kali"
  sources = ["source.proxmox-iso.kali"]

  provisioner "shell" {
    execute_command = "sudo -E sh -eu '{{ .Path }}'"
    inline = [
      "apt-get update",
      "DEBIAN_FRONTEND=noninteractive apt-get -y install cloud-init qemu-guest-agent",
      "systemctl enable qemu-guest-agent",
      "apt-get clean",
      "rm -f /etc/ssh/ssh_host_*",
      "cloud-init clean --logs --machine-id",
    ]
  }

  provisioner "shell" {
    execute_command = "sudo -E sh -eu '{{ .Path }}'"
    skip_clean      = true
    inline = [
      "rm -f /etc/sudoers.d/90-packer",
      "userdel -f -r packer || true",
    ]
  }
}
