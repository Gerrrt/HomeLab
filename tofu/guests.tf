# Every guest this tree manages, and the pools that group them.
#
# ADR-0029's six domain guests (150-155), cloned from 911 and 912 and then
# configured by ansible/ (ADR-0077). They were built by hand first, for #414.
# #448 brings them here: they are imported once, so that `tofu destroy` can
# remove them, and are then rebuilt from the templates (build-the-lab-domain.md,
# "Rebuild from the pipeline").
#
# Beside them is the proof guest, declared only under -var proof=true. It
# exists to put a real secret, a cloud-init password, into real state, so the
# runbook can grep for it and find nothing.

resource "random_password" "proof" {
  count   = var.proof ? 1 : 0
  length  = 32
  special = false
}

locals {
  proof_guests = var.proof ? {
    tofu-proof = {
      vm_id       = 998 # beside packer-smoke.sh's 999, outside every range in use
      template    = 901 # tpl-ubuntu-2604
      pool        = "proof"
      mac_address = "BC:24:11:00:09:98" # fixed only so the module's input is total
      smbios_uuid = null
      startup     = null
      cores       = 1
      memory_mib  = 2048
      disk_gib    = 32
      linux       = true
      on_boot     = false
      # `disposable` is what DisposableGuestOutlived reads (ADR-0071). A proof
      # guest left behind is exactly what that alert is for.
      tags     = ["disposable", "tofu"]
      password = random_password.proof[0].result
    }
  } : {}

  # ADR-0029's sizes and build-the-lab-domain.md §1's flags. Every value
  # below the template was read from the hand-built six's `qm config` on
  # 2026-10-06, so a rebuilt guest keeps what other things key on:
  #
  #   - the MAC, which morpheus's reservations are keyed by. That holds for
  #     the two DCs too, which first boot on DHCP before `base` makes the same
  #     address static (ADR-0077 decision 6);
  #   - the SMBIOS UUID, which the endpoints' bought Windows 11 Pro
  #     activation is tied to. The servers keep theirs only for symmetry: an
  #     evaluation licence has nothing to carry;
  #   - the startup order: DCs before members, and none for the endpoints,
  #     which are on demand (ADR-0029's duty cycle). It is recorded here but
  #     set by root on Saruman, not by this tree: Proxmox wants Sys.Modify on
  #     `/` for it (modules/guest/main.tf). See `startup_orders` below.
  #
  # No password here. A Windows clone's comes from the template's build
  # password, which `base` rotates to LAB_ADMIN_PASSWORD on its first run.
  lab_domain = {
    for name, g in {
      bahamut   = { vm_id = 150, template = 912, memory_mib = 4096, disk_gib = 60, startup = 1, mac_address = "BC:24:11:06:2D:3A", smbios_uuid = "aeec15bb-f21b-448c-b120-167e54900039" }
      leviathan = { vm_id = 151, template = 912, memory_mib = 4096, disk_gib = 60, startup = 2, mac_address = "BC:24:11:DB:1F:85", smbios_uuid = "dd9abbda-e839-40db-b183-e8b356961401" }
      titan     = { vm_id = 152, template = 912, memory_mib = 6144, disk_gib = 80, startup = 3, mac_address = "BC:24:11:B4:4C:CF", smbios_uuid = "ab85583e-ab7c-45c2-886f-0bbee7e1a2b2" }
      ramuh     = { vm_id = 153, template = 912, memory_mib = 6144, disk_gib = 80, startup = 4, mac_address = "BC:24:11:99:74:9D", smbios_uuid = "b0af306f-f641-4184-8dfb-88279a5dbf5f" }
      carbuncle = { vm_id = 154, template = 911, memory_mib = 4096, disk_gib = 64, startup = null, mac_address = "BC:24:11:29:0B:91", smbios_uuid = "6c44c33b-9383-41df-8c9a-1ea62ac94388" }
      siren     = { vm_id = 155, template = 911, memory_mib = 4096, disk_gib = 64, startup = null, mac_address = "BC:24:11:E3:4C:9D", smbios_uuid = "dfb1eb59-2a5b-490c-b96a-ea31465c5208" }
    } :
    name => merge(g, {
      pool    = "lab-domain"
      cores   = 2
      linux   = false
      on_boot = g.startup != null
      # `lab-domain` on all six, so no clone keeps its template's
      # `template;windows` (modules/guest/variables.tf). `on-demand` is what
      # the hand-built endpoints carry, and what an endpoint left running is
      # found by.
      tags     = concat(["lab-domain"], g.startup == null ? ["on-demand"] : [])
      password = null
    })
  }

  guests = merge(local.lab_domain, local.proof_guests)

  # A pool exists exactly while it groups a guest: it is derived from the
  # guests, not listed beside them, so the last guest leaving a pool takes the
  # pool with it, and a new pool name in a guest creates it.
  #
  # Proxmox deletes a pool's ACL when it deletes the pool. phoenix's
  # Pool.Allocate on /pool/<name> goes with it, and must be granted again on
  # Saruman before that pool can be recreated (provision-lab-guests.md §2).
  pools = toset([for g in values(local.guests) : g.pool])
}

resource "proxmox_virtual_environment_pool" "this" {
  for_each = local.pools

  pool_id = each.key
  comment = "Managed by tofu/ (ADR-0076). Destroyed with the last guest in it."
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

  mac_address = each.value.mac_address
  smbios_uuid = each.value.smbios_uuid
}

output "startup_orders" {
  description = "What root on Saruman sets after an apply, one `qm set` per guest that boots with the host."
  value = {
    for name, g in local.guests : name => "qm set ${g.vm_id} --startup order=${g.startup},up=120"
    if g.startup != null
  }
}

output "proof_password" {
  description = "The secret the runbook greps the state for. Printed with -raw only."
  value       = var.proof ? random_password.proof[0].result : null
  sensitive   = true
}
