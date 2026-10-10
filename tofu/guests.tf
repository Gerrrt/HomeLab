# Every guest this tree manages, and the pools that group them.
#
# ADR-0029's six domain guests (150-155), cloned from 911 and 912 and then
# configured by ansible/ (ADR-0077). They were built by hand first, for #414.
# #448 brings them here: they are imported once, so that `tofu destroy` can
# remove them, and are then rebuilt from the templates (build-the-lab-domain.md,
# "Rebuild from the pipeline").
#
# #920's on-demand dotfiles VMs (191-198), one per dotfiles OS layer, in the
# `dotfiles` pool (ADR-0090).
#
# #921's garuda (162), Defense's always-on analyst workstation, in the
# `analyst` pool (ADR-0091).
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
      username = "operator"
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
      # `backup` because golem holds all six (ADR-0053), and
      # GuestNotInBackupJob reads the tag.
      tags     = concat(["lab-domain", "backup"], g.startup == null ? ["on-demand"] : [])
      password = null
      username = "operator" # unused: a Windows clone takes no cloud-init user
    })
  }

  # #920's on-demand VMs, one per dotfiles OS layer (ADR-0090). Standalone,
  # not domain members: they test the dotfiles, not the domain. Each is booted
  # from its `clean` snapshot for a run and shut down after it, so `on-demand`
  # keeps HypervisorGuestStopped quiet (ADR-0079), and none boots with the
  # host. The MACs are fixed for morpheus's reservations, .91-.98, as the
  # domain's are. No SMBIOS UUID: dot-windows is an unactivated Windows 11, so
  # there is no activation to carry. Arch's Secure Boot is off, as its
  # template's is: Arch ships no Microsoft-signed shim, and Alpine's and
  # Gentoo's cloud images and NixOS boot without one too.
  dotfiles = {
    for name, g in {
      dot-debian   = { vm_id = 191, template = 903, cores = 2, memory_mib = 4096, disk_gib = 32, linux = true, mac_address = "BC:24:11:D0:51:9D" }
      dot-fedora   = { vm_id = 192, template = 904, cores = 2, memory_mib = 4096, disk_gib = 32, linux = true, mac_address = "BC:24:11:81:DB:CC" }
      dot-opensuse = { vm_id = 193, template = 905, cores = 2, memory_mib = 4096, disk_gib = 32, linux = true, mac_address = "BC:24:11:E9:5A:7B" }
      dot-arch     = { vm_id = 194, template = 906, cores = 2, memory_mib = 4096, disk_gib = 32, linux = true, mac_address = "BC:24:11:9A:27:EC", secure_boot = false }
      dot-alpine   = { vm_id = 195, template = 907, cores = 1, memory_mib = 1024, disk_gib = 8, linux = true, mac_address = "BC:24:11:B9:94:6A", secure_boot = false }
      dot-gentoo   = { vm_id = 196, template = 908, cores = 4, memory_mib = 8192, disk_gib = 60, linux = true, mac_address = "BC:24:11:CB:16:C3", secure_boot = false }
      dot-nixos    = { vm_id = 197, template = 909, cores = 2, memory_mib = 4096, disk_gib = 40, linux = true, mac_address = "BC:24:11:69:5A:40", secure_boot = false }
      dot-windows  = { vm_id = 198, template = 911, cores = 4, memory_mib = 8192, disk_gib = 64, linux = false, mac_address = "BC:24:11:E0:A4:9A", vga = "virtio" }
    } :
    name => merge(g, {
      pool        = "dotfiles"
      smbios_uuid = null
      startup     = null
      on_boot     = false
      tags        = ["dotfiles", "on-demand"]
      password    = null
      # Not the module's `operator`: Debian ships a system group of that name
      # and Fedora a system user, so cloud-init's useradd failed on the first
      # apply (2026-10-08) and the guest had no login. `tester` is also the
      # Windows guest's bootstrap user (test-the-dotfiles-layers.md §3).
      username = "tester"
    })
  }

  # #921's analyst workstation (ADR-0091): Kali Purple without its SOC, and
  # the home of the dotfiles-Defense layer. Always on, so not `on-demand`:
  # HypervisorGuestStopped is meant to find it stopped (ADR-0079). Standalone,
  # not a domain member, so that whoever takes the domain does not also take
  # the case notes. No startup order: nothing waits for it, as it waits for
  # nothing. Secure Boot is off, as its template's is. `analyst`, not the
  # module's `operator`, for the reason the dotfiles VMs give below.
  analyst = {
    for name, g in {
      garuda = { vm_id = 162, template = 910, cores = 4, memory_mib = 8192, disk_gib = 80, mac_address = "BC:24:11:ED:98:3F" }
    } :
    name => merge(g, {
      pool        = "analyst"
      smbios_uuid = null
      startup     = null
      linux       = true
      on_boot     = true
      secure_boot = false
      tags        = ["analyst", "backup"] # golem holds it: the case notes are in no repository
      password    = null
      username    = "analyst"
    })
  }

  guests = merge(local.lab_domain, local.dotfiles, local.analyst, local.proof_guests)

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
  username   = each.value.username
  # Absent means on: only a guest whose template has no Microsoft-signed shim
  # sets it.
  secure_boot = lookup(each.value, "secure_boot", true)
  # Absent means Proxmox's default. dot-windows runs VirtIO GPU (#1108).
  vga      = lookup(each.value, "vga", null)
  ssh_keys = each.value.linux ? [trimspace(file(pathexpand(var.ssh_public_key_file)))] : []

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
