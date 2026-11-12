variable "proof" {
  type        = bool
  default     = false
  description = "Declare the proof guest, 998. On for the runbook's §4 proof, then off again, which destroys it and its pool."
}

variable "ssh_public_key_file" {
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
  description = "phoenix's key, the one ADR-0043 says the toolchain puts on every guest it builds. Same default as packer/."
}

variable "eden_operator_key_file" {
  type        = string
  default     = "~/.config/proxmox/eden-garnet.pub"
  description = "garnet's public key from alexander, which eden's operator logs in with beside phoenix's own (build-the-bloodhound-guest.md §1). A public key, but kept beside the credentials so the checkout stays the same on every host."
}

# Each guest's MAC and, for the six domain guests, the SMBIOS UUID the
# hand-built one had. They are not in this repository: docs/security.md's
# "What this repository deliberately does not publish" withholds full MACs,
# and a UUID is the same kind of hardware fingerprint. The working copy is
# tofu/identities.auto.tfvars on phoenix, gitignored and loaded automatically.
# The escrow copy is TOFU_GUEST_IDENTITIES in secrets/tofu.sops.yaml, written by
# phoenix as the state passphrase's is (provision-lab-guests.md §3).
# identities.auto.tfvars.example shows the shape. No default: a plan without
# the file fails, rather than inventing a MAC that orphans a reservation.
variable "guest_identities" {
  type = map(object({
    mac_address = string
    smbios_uuid = optional(string)
  }))

  nullable    = false
  description = "Every guest's MAC and optional SMBIOS UUID, keyed by guest name. From tofu/identities.auto.tfvars; escrowed in secrets/tofu.sops.yaml."

  # A domain guest missing its UUID would plan a change to one that exists,
  # and a plan that changes a guest is a stop (provision-lab-guests.md §5).
  # Refuse it here instead.
  validation {
    condition = alltrue([
      for name in ["bahamut", "leviathan", "titan", "ramuh", "carbuncle", "siren"] :
      try(var.guest_identities[name].smbios_uuid != null, false)
    ])

    error_message = "Each of the six domain guests needs its smbios_uuid in guest_identities, as tofu/identities.auto.tfvars.example shows."
  }
}
