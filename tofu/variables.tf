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
