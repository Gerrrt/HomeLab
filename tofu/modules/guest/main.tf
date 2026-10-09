# One lab guest, a full clone of a packer/ template.
#
# The flags mirror the as-run `qm create` in build-the-lab-domain.md §1 and
# build-the-jumpbox.md §1: host CPU, no balloon, virtio-scsi-single, the disk on
# large_data with discard, iothread and ssd, vmbr0 untagged, the agent on, q35
# and OVMF with an EFI disk, and for Windows a TPM. A guest built here and a
# guest built by hand should be indistinguishable in `qm config`, apart from
# the pool.
terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

resource "proxmox_virtual_environment_vm" "this" {
  name      = var.name
  vm_id     = var.vm_id
  node_name = var.node
  pool_id   = var.pool_id
  tags      = sort(var.tags)
  on_boot   = var.on_boot

  # `full` is not a variable. ADR-0074 §2 rebuilds a template in place with
  # `packer build -force`, which a linked clone would block or orphan, and
  # that rule is only as good as the one place a clone is made.
  clone {
    vm_id        = var.template
    node_name    = var.node
    datastore_id = var.datastore
    full         = true
  }

  operating_system {
    type = var.linux ? "l26" : "win11"
  }

  # Every template packer/ builds is q35 and OVMF with an EFI disk, and the
  # provider's own default is SeaBIOS: left unset, a clone could come up with
  # no bootable disk. Windows 11 also refuses to boot without TPM 2.0 and
  # Secure Boot (build-the-lab-domain.md §1). Saying so here keeps the provider
  # from "correcting" what the template already has.
  bios    = "ovmf"
  machine = "q35"

  efi_disk {
    datastore_id      = var.datastore
    file_format       = "raw"
    type              = "4m"
    pre_enrolled_keys = var.secure_boot
  }

  dynamic "tpm_state" {
    for_each = var.linux ? [] : [1]
    content {
      datastore_id = var.datastore
      version      = "v2.0"
    }
  }

  # Pinned for the bought Windows 11 Pro endpoints: the digital entitlement is
  # keyed to the hardware ID, and the SMBIOS UUID is most of what a VM has.
  dynamic "smbios" {
    for_each = var.smbios_uuid == null ? [] : [1]
    content {
      uuid = var.smbios_uuid
    }
  }

  cpu {
    type    = "host"
    cores   = var.cores
    sockets = 1
  }

  memory {
    dedicated = var.memory_mib
    floating  = 0 # --balloon 0
  }

  scsi_hardware = "virtio-scsi-single"

  disk {
    interface    = "scsi0"
    datastore_id = var.datastore
    size         = var.disk_gib
    discard      = "on"
    iothread     = true
    ssd          = true
  }

  network_device {
    bridge   = var.bridge
    model    = "virtio"
    firewall = false
    # Pinned, because morpheus's reservations are keyed by MAC and the
    # inventory's addresses are only true while they hold (ADR-0077 decision 6).
    mac_address = var.mac_address
    # No vlan_id: VLAN 30 is untagged on vmbr0, and a tag here breaks
    # networking (packer/variables.pkr.hcl says the same).
  }

  agent {
    enabled = true
  }

  # Only where a guest asks: leaving the block out keeps Proxmox's default and
  # every other guest's plan unchanged.
  dynamic "vga" {
    for_each = var.vga == null ? [] : [var.vga]
    content {
      type = vga.value
    }
  }

  # A Linux clone takes its user, key, password and address from the cloud-init
  # drive the template left empty. Windows clones take theirs from the
  # sysprep answer file, so this block is Linux-only.
  dynamic "initialization" {
    for_each = var.linux ? [1] : []
    content {
      datastore_id = var.datastore
      ip_config {
        ipv4 {
          address = "dhcp"
        }
      }
      user_account {
        username = var.username
        keys     = var.ssh_keys
        password = var.password
      }
    }
  }

  # Without the agent answering, a shutdown request is ignored and the destroy
  # waits out its timeout. A guest being destroyed has nothing to save.
  stop_on_destroy = true

  # Not set here, and never changed from here. Proxmox asks for Sys.Modify on
  # `/` to set a guest's `startup` (PVE::API2::Qemu), a host-wide privilege
  # ADR-0043 keeps from phoenix. The #448 rebuild's first apply was refused
  # with 403 on exactly this. Root on Saruman sets the order after an apply
  # (build-the-lab-domain.md, "Rebuild from the pipeline"); the guests.tf
  # output `startup_orders` says what to set.
  #
  # `started` is ignored too. The provider's default is true, so a guest is
  # started when it is created (its first boot) and then never touched again
  # from here. Without this, every plan that met a stopped on-demand guest
  # (ADR-0079: carbuncle, siren, and the dotfiles VMs of ADR-0090) proposed
  # `started = false -> true`, and an untargeted apply would boot it. Whether a
  # guest is up is the operator's, and HypervisorGuestStopped's, not tofu's.
  lifecycle {
    ignore_changes = [startup, started]
  }
}
