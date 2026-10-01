# Inputs shared by every source in this directory.
#
# The credential comes from ~/.config/proxmox/phoenix.env on phoenix, sourced
# with `set -a` before a build (ADR-0073 part 4). The defaults below read that
# file's own variable names, so the file written by build-the-jumpbox.md §4
# needs no second spelling of the same token. Nothing secret has a literal
# default here, and nothing here is ever a secret in git.

variable "proxmox_url" {
  type        = string
  description = "Proxmox API URL, ending /api2/json."
  default     = env("PROXMOX_URL")
}

variable "proxmox_token_id" {
  type        = string
  description = "API token ID, user@realm!name."
  default     = env("PROXMOX_TOKEN_ID")
}

variable "proxmox_token_secret" {
  type        = string
  description = "API token secret (the UUID)."
  sensitive   = true
  default     = env("PROXMOX_TOKEN_SECRET")
}

# Saruman's API presents the hypervisor's self-signed certificate. phoenix
# reaches it by address on VLAN 30, admitted by one firewall rule (ADR-0043
# part 3); the token, not the certificate, is the control on that path.
variable "proxmox_insecure_skip_tls_verify" {
  type    = bool
  default = true
}

variable "node" {
  type        = string
  description = "Node to build on. Capital S, as Proxmox spells it."
  default     = "Saruman"
}

# Guests are on the SSD pool since #527 measured the HDD mirror; the template
# is a guest's disk until it is cloned, so it lives there too.
variable "disk_storage" {
  type    = string
  default = "large_data"
}

# Where the installer ISOs already sit, and where the generated answer-file
# discs are uploaded for the length of a build.
variable "iso_storage" {
  type    = string
  default = "local"
}

# VLAN 30, untagged on the bridge. Setting a tag here breaks networking
# (build-the-lab-domain.md §1).
variable "bridge" {
  type    = string
  default = "vmbr0"
}

# phoenix's key, the one ADR-0043 says the toolchain injects into every guest
# it builds. Read at build time, never copied into this tree.
variable "ssh_public_key_file" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "ssh_private_key_file" {
  type    = string
  default = "~/.ssh/id_ed25519"
}

# The local Administrator password inside a Windows build, and the one a clone
# boots with until whatever converges it rotates it (#448). From phoenix.env as
# PKR_VAR_build_password. Empty by default so that a build without it fails at
# validation, not twenty minutes into Windows Setup. It is pasted into two
# answer files verbatim, so the five characters XML would need escaped are
# refused rather than escaped.
variable "build_password" {
  type      = string
  sensitive = true
  default   = ""
  validation {
    condition     = length(var.build_password) >= 14 && length(regexall("[<>&\"']", var.build_password)) == 0
    error_message = "Set PKR_VAR_build_password in phoenix.env: 14+ characters, Windows' complexity rules, none of < > & \" '."
  }
}

variable "ubuntu_iso_file" {
  type    = string
  default = "local:iso/ubuntu-26.04.1-live-server-amd64.iso"
}

# A placeholder name: Kali is written and not yet built (ADR-0073 part 2), and
# the first build on ifrit sets this to the ISO it actually has.
variable "kali_iso_file" {
  type    = string
  default = "local:iso/kali-linux-installer-amd64.iso"
}

variable "kali_node" {
  type        = string
  description = "ifrit, once it exists. Saruman only to prove the preseed."
  default     = "ifrit"
}

variable "win11_iso_file" {
  type    = string
  default = "local:iso/windows-11.iso"
}

variable "ws2025_iso_file" {
  type    = string
  default = "local:iso/windows-server-2025-eval.iso"
}

variable "virtio_iso_file" {
  type    = string
  default = "local:iso/virtio-win.iso"
}
