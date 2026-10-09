# Inputs shared by every source in this directory.
#
# The credential comes from ~/.config/proxmox/phoenix.env on phoenix, sourced
# with `set -a` before a build (ADR-0074 part 4). The defaults below read that
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

# Verified. Saruman's API certificate is signed by the cluster's own CA
# (/etc/pve/pve-root-ca.pem), which build-the-lab-templates.md §2 installs in
# phoenix's trust store. Skipping verification would hand the token to any
# guest on VLAN 30 that answered for 10.0.30.110, and the attack VM shares
# that segment. Set true only to debug, never to build.
variable "proxmox_insecure_skip_tls_verify" {
  type    = bool
  default = false
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

# Where the generated answer-file discs are uploaded for the length of a
# build. NOT smaug-iso, though the installers live there: the Windows answer
# disc carries the build password in its XML, which has no business on the
# NAS, and the daily checksum run would report every one as an unlisted file
# (scripts/collect-iso-store-state.sh). The installers are named per variable
# below.
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

# The one address the clones' OpenSSH rule admits (packer/windows/scripts/
# openssh.ps1), and the one the build's WinRM rule admits (bootstrap.ps1).
# phoenix's, from ADR-0043.
variable "phoenix_address" {
  type    = string
  default = "10.0.30.70"
}

variable "ssh_private_key_file" {
  type    = string
  default = "~/.ssh/id_ed25519"
}

# The local Administrator password inside a Windows build, and the one a clone
# boots with until ansible/'s base role rotates it (#448). From phoenix.env as
# PKR_VAR_build_password. Empty by default so that a build without it fails at
# validation, not twenty minutes into Windows Setup. All four character
# classes are required: Windows asks for three of the four, and requiring all
# of them here means Setup can never be the first thing to refuse it. It is
# pasted into two answer files verbatim, so the five characters XML would need
# escaped are refused rather than escaped.
variable "build_password" {
  type      = string
  sensitive = true
  default   = ""
  validation {
    condition = (
      length(var.build_password) >= 14
      && can(regex("[A-Z]", var.build_password))
      && can(regex("[a-z]", var.build_password))
      && can(regex("[0-9]", var.build_password))
      && can(regex("[^A-Za-z0-9]", var.build_password))
      && length(regexall("[<>&\"']", var.build_password)) == 0
    )
    error_message = "Set PKR_VAR_build_password in phoenix.env: 14+ characters, with an upper-case letter, a lower-case letter, a digit and a symbol, and none of < > & \" '."
  }
}

# The installers Saruman builds from are on smaug-iso, the ISO store
# (ADR-0072), and each is checked daily against the list in
# scripts/collect-iso-store-state.sh, because Packer does not check an ISO it
# is handed from storage. A name here and a name in that list are the same
# file, so change both together (build-the-lab-templates.md §1).
variable "ubuntu_iso_file" {
  type    = string
  default = "smaug-iso:iso/ubuntu-26.04.1-live-server-amd64.iso"
}

# The dotfiles OS layers' installers (#920, ADR-0090).
variable "debian_iso_file" {
  type    = string
  default = "smaug-iso:iso/debian-13.7.0-amd64-netinst.iso"
}

variable "fedora_iso_file" {
  type    = string
  default = "smaug-iso:iso/Fedora-Server-netinst-x86_64-44-1.7.iso"
}

variable "opensuse_iso_file" {
  type    = string
  default = "smaug-iso:iso/openSUSE-Tumbleweed-NET-x86_64-Snapshot20261007-Media.iso"
}

# The address the cloud-image builds (alpine, gentoo) give their clone for
# the length of the build. The images carry no guest agent to report one.
# Below the DHCP pool and in no table (docs/network.md).
variable "cloud_image_build_address" {
  type    = string
  default = "10.0.30.99"
}

variable "nixos_iso_file" {
  type    = string
  default = "smaug-iso:iso/nixos-minimal-26.05.11576.7c8764b7c7b0-x86_64-linux.iso"
}

variable "arch_iso_file" {
  type    = string
  default = "smaug-iso:iso/archlinux-2026.10.01-x86_64.iso"
}

# A placeholder name: Kali is written and not yet built (ADR-0074 part 2), and
# the first build on ifrit sets this to the ISO it actually has. It stays on
# local: the ISO store's export and pass admit Saruman alone (ADR-0072), so
# ifrit cannot mount it.
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
  default = "smaug-iso:iso/windows-11-26h2.iso"
}

variable "ws2025_iso_file" {
  type    = string
  default = "smaug-iso:iso/windows-server-2025-eval.iso"
}

variable "virtio_iso_file" {
  type    = string
  default = "smaug-iso:iso/virtio-win-0.1.302.iso"
}
