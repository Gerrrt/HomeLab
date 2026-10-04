# State and plan encryption (ADR-0076). This file is the reason the tree is
# OpenTofu rather than Terraform: a state file holds every value a provider
# touched, in cleartext, and this one would hold cloud-init passwords.
#
# It is self-contained on purpose. scripts/check-tofu-state-encryption.sh
# copies THIS file, unchanged, next to a canary and proves that the canary does
# not appear in the state it writes, and that it does appear without this file.
# Keep everything the encryption needs in here, or that proof stops testing the
# configuration that runs.
#
# The key is a passphrase, not an age key. OpenTofu has no age key provider,
# and phoenix holds no age key by decision (ADR-0043 part 2, ADR-0074 §4). The
# passphrase lives in ~/.config/proxmox/phoenix.env beside the token, as
# TF_VAR_state_passphrase, and its escrow copy is secrets/tofu.sops.yaml,
# encrypted to the estate's two recipients: phoenix can write that file and
# never read it.
#
# `enforced = true` on both is the guard against the quiet failure. Without it,
# a missing method would write plaintext without a word. With it, tofu refuses.
# There is deliberately no `unencrypted` method and no `fallback` anywhere.
terraform {
  encryption {
    key_provider "pbkdf2" "phoenix" {
      passphrase = var.state_passphrase
    }

    method "aes_gcm" "phoenix" {
      keys = key_provider.pbkdf2.phoenix
    }

    state {
      method   = method.aes_gcm.phoenix
      enforced = true
    }

    plan {
      method   = method.aes_gcm.phoenix
      enforced = true
    }
  }
}

variable "state_passphrase" {
  type        = string
  sensitive   = true
  description = "From TF_VAR_state_passphrase in phoenix.env. Escrowed in secrets/tofu.sops.yaml."

  validation {
    # pbkdf2 itself refuses under 16. 32 is what the runbook generates, and a
    # short value here is a mistake, not a choice.
    condition     = length(var.state_passphrase) >= 32
    error_message = "state_passphrase must be at least 32 characters (openssl rand -base64 32)."
  }
}
