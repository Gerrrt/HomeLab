# The one plugin this tree needs, pinned to an exact release. `packer init`
# fetches it on phoenix; a bump is a deliberate edit here, not a side effect of
# whatever was newest on the day of a rebuild (ADR-0073).
#
# 1.2 is the floor regardless: it is where `boot_iso`, `efi_config` and
# `tpm_config` replaced the deprecated flat keys this tree does not use.
packer {
  required_version = ">= 1.11.0"
  required_plugins {
    proxmox = {
      source  = "github.com/hashicorp/proxmox"
      version = "= 1.2.4"
    }
  }
}
