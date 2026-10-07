# The one plugin this tree needs, pinned to an exact release. `packer init`
# fetches it on phoenix; a bump is a deliberate edit here, not a side effect of
# whatever was newest on the day of a rebuild (ADR-0074). Dependabot has no
# Packer ecosystem, so scripts/check_tool_versions.py, weekly in digests.yml,
# is what says a newer plugin exists (#848).
#
# 1.2 is the floor regardless: it is where `boot_iso`, `efi_config` and
# `tpm_config` replaced the deprecated flat keys this tree does not use.
#
# Packer itself is pinned to the minor release CI lints with, the `packer`
# image in stacks/observability/compose.yaml. phoenix installs that exact
# release (build-the-lab-templates.md §1). A bump moves the image, this line and
# the runbook's V= together; until they do, `packer init` refuses to run.
packer {
  required_version = "~> 1.16.0"
  required_plugins {
    proxmox = {
      source  = "github.com/hashicorp/proxmox"
      version = "= 1.2.4"
    }
  }
}
