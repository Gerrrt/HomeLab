# Every guest this tree manages, and the pools that group them.
#
# The six domain guests (150-155) are NOT here. They were built by hand before
# this tree existed, and they stay hand-managed until #448 or an evaluation
# rebuild replaces them from 911/912 (ADR-0075). Importing a domain controller
# into a tool whose next plan might replace it is the wrong first apply.
#
# What is here today is the proof guest, declared only under -var proof=true.
# It exists to put a real secret, a cloud-init password, into real state, so
# the runbook can grep for it and find nothing.

resource "random_password" "proof" {
  count   = var.proof ? 1 : 0
  length  = 32
  special = false
}

locals {
  proof_guests = var.proof ? {
    tofu-proof = {
      vm_id      = 998 # beside packer-smoke.sh's 999, outside every range in use
      template   = 901 # tpl-ubuntu-2604
      pool       = "proof"
      cores      = 1
      memory_mib = 2048
      disk_gib   = 32
      linux      = true
      on_boot    = false
      # `disposable` is what DisposableGuestOutlived reads (ADR-0071). A proof
      # guest left behind is exactly what that alert is for.
      tags     = ["disposable", "tofu"]
      password = random_password.proof[0].result
    }
  } : {}

  guests = merge(local.proof_guests)

  # A pool exists exactly while it groups a guest: it is derived from the
  # guests, not listed beside them, so the last guest leaving a pool takes the
  # pool with it, and a new pool name in a guest creates it.
  pools = toset([for g in values(local.guests) : g.pool])
}

resource "proxmox_virtual_environment_pool" "this" {
  for_each = local.pools

  pool_id = each.key
  comment = "Managed by tofu/ (ADR-0075). Destroyed with the last guest in it."
}

module "guest" {
  source   = "./modules/guest"
  for_each = local.guests

  name       = each.key
  vm_id      = each.value.vm_id
  template   = each.value.template
  pool_id    = proxmox_virtual_environment_pool.this[each.value.pool].pool_id
  cores      = each.value.cores
  memory_mib = each.value.memory_mib
  disk_gib   = each.value.disk_gib
  linux      = each.value.linux
  on_boot    = each.value.on_boot
  tags       = each.value.tags
  password   = each.value.password
  ssh_keys   = each.value.linux ? [trimspace(file(pathexpand(var.ssh_public_key_file)))] : []
}

output "proof_password" {
  description = "The secret the runbook greps the state for. Printed with -raw only."
  value       = var.proof ? random_password.proof[0].result : null
  sensitive   = true
}
