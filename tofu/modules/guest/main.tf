# One lab guest, a full clone of a packer/ template.
#
# The flags mirror the as-run `qm create` in build-the-lab-domain.md §1 and
# build-the-jumpbox.md §1: host CPU, no balloon, virtio-scsi-single, the disk on
# large_data with discard, iothread and ssd, vmbr0 untagged, the agent on. A
# guest built here and a guest built by hand should be indistinguishable in
# `qm config`, apart from the pool.
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
    # No vlan_id: VLAN 30 is untagged on vmbr0, and a tag here breaks
    # networking (packer/variables.pkr.hcl says the same).
  }

  agent {
    enabled = true
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
}
