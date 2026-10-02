# tpl-win11-pro (911) and tpl-ws2025-eval (912): the bases for ADR-0029's six.
#
# Three discs per build, inside q35's two IDE slots plus one SATA:
#   ide2   the installer                  (on smaug-iso:iso/, checked daily)
#   ide0   virtio-win                     (on smaug-iso:iso/, checked daily) — Windows
#          ships no driver for virtio-scsi or virtio-net, and the guest agent
#          that tells Packer the address comes from this disc too
#   sata0  the answer disc, generated     (Autounattend.xml, bootstrap.ps1)
# ide3 does not exist on q35 (build-the-lab-domain.md §1), hence SATA.
#
# The last provisioner runs sysprep /generalize, so every clone takes a new
# machine SID at first boot. That, not rebuilding, is what lets a member join a
# domain whose two DCs were cloned from the same template (ADR-0074 part 3).

locals {
  # Microsoft's published generic installation key for Windows 11 Pro. It
  # selects the edition and activates nothing; the bought key is entered on
  # the guest. The evaluation image needs none. gitleaks reads it as a generic
  # API key; it is public by design, hence the inline allow.
  win11_generic_key = "VK7JG-NPHTM-C97JM-9MPGT-3V66T" # gitleaks:allow

  windows_answer_disc = {
    win11 = {
      "Autounattend.xml" = templatefile("${abspath(path.root)}/windows/autounattend.xml.pkrtpl", {
        image_name     = "Windows 11 Pro"
        product_key    = local.win11_generic_key
        driver_dir     = "w11"
        computer_name  = "TPL-WIN11"
        build_password = var.build_password
      })
      "bootstrap.ps1" = file("${abspath(path.root)}/windows/scripts/bootstrap.ps1")
    }
    ws2025 = {
      "Autounattend.xml" = templatefile("${abspath(path.root)}/windows/autounattend.xml.pkrtpl", {
        # Desktop Experience, not Core (ADR-0029).
        image_name     = "Windows Server 2025 Standard Evaluation (Desktop Experience)"
        product_key    = ""
        driver_dir     = "2k25"
        computer_name  = "TPL-WS2025"
        build_password = var.build_password
      })
      "bootstrap.ps1" = file("${abspath(path.root)}/windows/scripts/bootstrap.ps1")
    }
  }

  unattend_oobe = templatefile("${abspath(path.root)}/windows/unattend-oobe.xml.pkrtpl", {
    build_password = var.build_password
  })
}

source "proxmox-iso" "win11-pro" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_token_id
  token                    = var.proxmox_token_secret
  insecure_skip_tls_verify = var.proxmox_insecure_skip_tls_verify
  node                     = var.node

  vm_id                = 911
  vm_name              = "tpl-win11-pro"
  template_name        = "tpl-win11-pro"
  template_description = "Windows 11 Pro, sysprep-generalised, built by packer/windows.pkr.hcl on ${timestamp()}. Full clones only (ADR-0074)."
  tags                 = "template;windows"

  # build-the-lab-domain.md §1's shape, which is ADR-0029's.
  os              = "win11"
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

  tpm_config {
    tpm_storage_pool = var.disk_storage
    tpm_version      = "v2.0"
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

  network_adapters {
    model    = "virtio"
    bridge   = var.bridge
    firewall = false
  }

  boot_iso {
    type     = "ide"
    index    = "2"
    iso_file = var.win11_iso_file
    unmount  = true
  }

  additional_iso_files {
    type     = "ide"
    index    = "0"
    iso_file = var.virtio_iso_file
    unmount  = true
  }

  additional_iso_files {
    type             = "sata"
    index            = "0"
    iso_storage_pool = var.iso_storage
    cd_label         = "ANSWERS"
    cd_content       = local.windows_answer_disc.win11
    unmount          = true
  }

  # OVMF shows "Press any key to boot from CD or DVD" for a few seconds.
  # The system disk, then the installer: the VirtIO and answer discs are not
  # bootable, and OVMF trying them first is what made the Ubuntu build miss
  # its boot prompt (packer/ubuntu.pkr.hcl). "Press any key to boot from CD"
  # lasts about five seconds, so the margin here is thinner than Ubuntu's.
  boot         = "order=scsi0;ide2"
  boot_wait    = "3s"
  boot_command = ["<spacebar><wait1s><spacebar><wait1s><spacebar>"]

  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = var.build_password
  winrm_insecure = true
  winrm_use_ssl  = false
  winrm_timeout  = "2h"
}

source "proxmox-iso" "ws2025-eval" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_token_id
  token                    = var.proxmox_token_secret
  insecure_skip_tls_verify = var.proxmox_insecure_skip_tls_verify
  node                     = var.node

  vm_id                = 912
  vm_name              = "tpl-ws2025-eval"
  template_name        = "tpl-ws2025-eval"
  template_description = "Windows Server 2025 Standard evaluation (Desktop Experience), sysprep-generalised, built by packer/windows.pkr.hcl on ${timestamp()}. Full clones only (ADR-0074)."
  tags                 = "template;windows"

  os              = "win11"
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

  tpm_config {
    tpm_storage_pool = var.disk_storage
    tpm_version      = "v2.0"
  }

  # 60G is the smallest of ADR-0029's server disks; titan and ramuh grow
  # theirs to 80G on the clone.
  disks {
    type         = "scsi"
    storage_pool = var.disk_storage
    disk_size    = "60G"
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
    iso_file = var.ws2025_iso_file
    unmount  = true
  }

  additional_iso_files {
    type     = "ide"
    index    = "0"
    iso_file = var.virtio_iso_file
    unmount  = true
  }

  additional_iso_files {
    type             = "sata"
    index            = "0"
    iso_storage_pool = var.iso_storage
    cd_label         = "ANSWERS"
    cd_content       = local.windows_answer_disc.ws2025
    unmount          = true
  }

  # The system disk, then the installer: the VirtIO and answer discs are not
  # bootable, and OVMF trying them first is what made the Ubuntu build miss
  # its boot prompt (packer/ubuntu.pkr.hcl). "Press any key to boot from CD"
  # lasts about five seconds, so the margin here is thinner than Ubuntu's.
  boot         = "order=scsi0;ide2"
  boot_wait    = "3s"
  boot_command = ["<spacebar><wait1s><spacebar><wait1s><spacebar>"]

  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = var.build_password
  winrm_insecure = true
  winrm_use_ssl  = false
  winrm_timeout  = "2h"
}

build {
  name = "windows"
  sources = [
    "source.proxmox-iso.win11-pro",
    "source.proxmox-iso.ws2025-eval",
  ]

  # The answer file for the clone's OOBE, and the script that closes WinRM on
  # the clone once that OOBE is done. Neither is needed during the build, so
  # they are uploaded here rather than carried on the answer disc.
  provisioner "file" {
    content     = local.unattend_oobe
    destination = "C:/Windows/Panther/unattend-oobe.xml"
  }

  provisioner "file" {
    source      = "${abspath(path.root)}/windows/scripts/SetupComplete.cmd"
    destination = "C:/Windows/Setup/Scripts/SetupComplete.cmd"
  }

  # Last. /quit rather than /shutdown: the builder shuts the guest down through
  # the agent and converts it, and a sysprep that powered off first would race
  # that. A generalised image must not boot again before it is a template, and
  # nothing here boots it.
  provisioner "powershell" {
    script = "${abspath(path.root)}/windows/scripts/sysprep.ps1"
  }
}
