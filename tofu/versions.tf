# The lab's guests, cloned from packer/'s templates through Saruman's API, run
# from phoenix (ADR-0076). How to run it is docs/runbooks/provision-lab-guests.md.
#
# Both pins are exact or patch-level on purpose: a bump is a deliberate edit
# here, not a side effect of whatever was newest on the day of an apply. That is
# ADR-0074's rule for the Packer plugin, applied to the next tool along.
terraform {
  required_version = "~> 1.13.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "= 0.114.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "= 3.9.1"
    }
  }

  # Local, on phoenix, inside a directory .gitignore names and
  # scripts/check-tracked-artefacts.sh asserts is never tracked. Encrypted
  # before it is written: see encryption.tf, which is the reason this tool was
  # chosen over Terraform at all.
  backend "local" {
    path = "state/lab.tfstate"
  }
}
