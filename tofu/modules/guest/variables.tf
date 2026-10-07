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
  description = "Template VMID: 901 Ubuntu, 902 Kali, 911 Windows 11, 912 Server 2025 (ADR-0074 §2)."

  validation {
    condition     = contains([901, 902, 911, 912], var.template)
    error_message = "template must be one of packer/'s VMIDs: 901, 902, 911, 912."
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

variable "startup_order" {
  type        = number
  default     = null
  description = "Boot order after a host reboot. Null for a guest that is on demand."
}

variable "cores" {
  type = number
}

variable "memory_mib" {
  type = number
}

variable "disk_gib" {
  type        = number
  description = "At least the template's own disk: 32 for Linux, 64 for Windows."
}

variable "linux" {
  type = bool
}

variable "on_boot" {
  type    = bool
  default = false
}

variable "tags" {
  type    = list(string)
  default = []
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
