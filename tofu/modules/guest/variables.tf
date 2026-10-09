variable "name" {
  type = string
}

variable "vm_id" {
  type        = number
  description = "The last octet of the guest's address, where it has one (build-the-lab-domain.md §1)."

  validation {
    condition     = var.vm_id >= 100 && var.vm_id < 1000 && !(var.vm_id >= 900 && var.vm_id < 990)
    error_message = "vm_id must be 100-999 and outside 900-989, which holds the templates (ADR-0074 §2)."
  }
}

variable "template" {
  type        = number
  description = "Template VMID: 901 Ubuntu, 902 Kali, 903 Debian, 904 Fedora, 905 openSUSE Tumbleweed, 906 Arch, 907 Alpine, 908 Gentoo, 909 NixOS, 911 Windows 11, 912 Server 2025 (ADR-0074 §2, ADR-0090)."

  validation {
    condition     = contains([901, 902, 903, 904, 905, 906, 907, 908, 909, 911, 912], var.template)
    error_message = "template must be one of the packer/ template VMIDs: 901, 902, 903, 904, 905, 906, 907, 908, 909, 911, 912."
  }
}

variable "node" {
  type        = string
  default     = "Saruman"
  description = "Capital S, as Proxmox spells it. A template belongs to one node, so this is also where the clone is made."
}

variable "pool_id" {
  type = string
}

variable "datastore" {
  type    = string
  default = "large_data"
}

variable "bridge" {
  type    = string
  default = "vmbr0"
}

variable "mac_address" {
  type        = string
  description = "Pinned, so the guest keeps its reservation on morpheus across a rebuild (ADR-0077 decision 6)."

  validation {
    condition     = can(regex("^BC:24:11(:[0-9A-F]{2}){3}$", var.mac_address))
    error_message = "mac_address must be upper-case and in Proxmox's BC:24:11 prefix, as `qm config` prints it."
  }
}

variable "smbios_uuid" {
  type        = string
  default     = null
  description = "The guest's smbios1 uuid. Pinned where an activation is keyed to it."
}

variable "cores" {
  type        = number
  description = "vCPUs. host CPU type, so each is a real thread on Saruman."

  validation {
    condition     = var.cores >= 1 && floor(var.cores) == var.cores
    error_message = "cores must be a whole number, at least 1."
  }
}

variable "memory_mib" {
  type        = number
  description = "Dedicated memory, no balloon. At least 1024 for Linux, 2048 for Windows (Server 2025's floor)."

  validation {
    condition     = var.memory_mib >= (var.linux ? 1024 : 2048) && floor(var.memory_mib) == var.memory_mib
    error_message = "memory_mib must be a whole number, at least 1024 for Linux and 2048 for Windows."
  }
}

variable "disk_gib" {
  type        = number
  description = "At least the template's own disk: 32 for Ubuntu (901), Debian (903), Fedora (904), openSUSE (905) and Arch (906), 8 for Alpine (907), 20 for Gentoo (908), 40 for NixOS (909), 64 for Kali (902) and Windows 11 (911), 60 for Server 2025 (912)."

  # A clone cannot be smaller than its template. Without this, a disk that is
  # too small fails only at apply, against Proxmox, with the guest half made.
  # By template, not by var.linux: Kali is Linux and its disk is 64G, and
  # Server 2025's is 60G, not 64 (packer/*.pkr.hcl, disk_size).
  validation {
    condition     = var.disk_gib >= lookup({ 901 = 32, 902 = 64, 903 = 32, 904 = 32, 905 = 32, 906 = 32, 907 = 8, 908 = 20, 909 = 40, 911 = 64, 912 = 60 }, var.template, 64) && floor(var.disk_gib) == var.disk_gib
    error_message = "disk_gib must be a whole number, at least the template's own disk: 32 for Ubuntu (901), Debian (903), Fedora (904), openSUSE (905) and Arch (906), 8 for Alpine (907), 20 for Gentoo (908), 40 for NixOS (909), 64 for Kali (902) and Windows 11 (911), 60 for Server 2025 (912)."
  }
}

variable "linux" {
  type = bool
}

variable "secure_boot" {
  type        = bool
  default     = true
  description = "Pre-enrol the Microsoft Secure Boot keys in the EFI disk, as every template so far has. False for a template whose OS ships no Microsoft-signed shim (Arch, ADR-0090), or its clone will not boot."
}

variable "vga" {
  type        = string
  default     = null
  description = "The display adapter. Null leaves Proxmox's default, which every guest had before dot-windows. \"virtio\" is VirtIO GPU: Windows has no driver for the default VGA and draws it on the CPU as the Basic Display Adapter, which made dot-windows' console slow (#1108). The guest needs virtio-win's viogpudo driver for it."
  validation {
    condition     = var.vga == null || contains(["std", "virtio", "qxl"], var.vga)
    error_message = "vga is null, \"std\", \"virtio\" or \"qxl\"."
  }
}

variable "on_boot" {
  type    = bool
  default = false
}

variable "tags" {
  type        = list(string)
  description = "At least one. The clone otherwise keeps its template's `template;<os>` tags."

  # The provider sends nothing for an empty list, so a clone given no tags
  # keeps the template's. The #448 rebuild's four servers came up tagged
  # `template;windows` that way.
  validation {
    condition     = length(var.tags) > 0
    error_message = "tags must name at least one tag; with none, the clone keeps its template's `template;<os>` tags."
  }
}

variable "username" {
  type    = string
  default = "operator"
}

variable "ssh_keys" {
  type    = list(string)
  default = []
}

variable "password" {
  type      = string
  default   = null
  sensitive = true
}
