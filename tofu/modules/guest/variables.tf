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
  description = "At least the template's own disk: 32 for Ubuntu (901), 64 for Kali (902) and Windows (911, 912)."

  # A clone cannot be smaller than its template. Without this, a disk that is
  # too small fails only at apply, against Proxmox, with the guest half made.
  # By template, not by var.linux: Kali is Linux and its disk is 64G
  # (packer/kali.pkr.hcl).
  validation {
    condition     = var.disk_gib >= (var.template == 901 ? 32 : 64) && floor(var.disk_gib) == var.disk_gib
    error_message = "disk_gib must be a whole number, at least the template's own disk: 32 for Ubuntu (901), 64 for Kali (902) and Windows (911, 912)."
  }
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
