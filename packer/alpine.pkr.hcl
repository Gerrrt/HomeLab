# tpl-alpine, VMID 907: the base for dot-alpine, the VM dotfiles-Alpine's
# bootstrap is tested on (#920 phase 3, ADR-0090).
#
# Not an ISO install. Alpine's installer is typed at a console, so the build
# starts from Alpine's own signed cloud image, which
# scripts/import-cloud-template.sh puts on Saruman as staging template 917.
# This clones it, adds what the dotfiles layer and the lab need, and converts
# the result.
#
# The image has no guest agent, so Packer cannot learn the clone's address
# from it: the build gives the clone a fixed one, .99, which is otherwise
# unused, through the cloud-init drive, and connects there. Packer generates
# a key for the session and puts it on the same drive, for the image's own
# default user, `alpine`, which can doas without a password. That user is
# deleted at the end, with its key.
#
# Secure Boot is off, as the staging template's EFI disk is.

source "proxmox-clone" "alpine" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_token_id
  token                    = var.proxmox_token_secret
  insecure_skip_tls_verify = var.proxmox_insecure_skip_tls_verify
  node                     = var.node

  clone_vm_id = 917
  full_clone  = true

  vm_id                = 907
  vm_name              = "tpl-alpine"
  template_name        = "tpl-alpine"
  template_description = "Alpine Linux 3.24, built by packer/alpine.pkr.hcl from staging template 917 on ${timestamp()}. Full clones only (ADR-0074)."
  tags                 = "template;linux"

  cores      = 1
  memory     = 1024
  qemu_agent = true
  # Said, not inherited: the clone builder sets its own default, lsi, which
  # OVMF has no driver for, and the clone then finds no disk to boot
  # (2026-10-09).
  scsi_controller = "virtio-scsi-single"

  # net0 as every template has it. The clone builder pairs each ipconfig with
  # an adapter declared here, not with the one the staging template carries.
  network_adapters {
    model    = "virtio"
    bridge   = var.bridge
    firewall = false
  }

  cloud_init              = true
  cloud_init_storage_pool = var.disk_storage
  # Proxmox's user-data asks for a package upgrade on first boot, which then
  # holds the package database while the provisioner wants it. The
  # provisioner upgrades, after waiting for cloud-init to finish.
  cloud_init_disable_upgrade_packages = true
  ipconfig {
    ip      = "${var.cloud_image_build_address}/24"
    gateway = "10.0.30.1"
  }
  nameserver = "10.0.30.1"

  communicator = "ssh"
  ssh_username = "alpine"
  ssh_host     = var.cloud_image_build_address
  ssh_timeout  = "15m"
}

build {
  name    = "alpine"
  sources = ["source.proxmox-clone.alpine"]

  provisioner "shell" {
    execute_command = "doas sh -eu '{{ .Path }}'"
    inline = [
      "cloud-init status --wait || true",
      # With a static address from cloud-init, Alpine's ifupdown does not
      # write the nameserver to resolv.conf (udhcpc does, on a DHCP clone), and
      # apk fails on "DNS: transient error". The clone's own boot rewrites it.
      "printf 'nameserver 10.0.30.1\\n' > /etc/resolv.conf",
      "apk update",
      "apk upgrade --no-interactive",
      # What dotfiles-Alpine's README asks for first (bash, git; the
      # community repository is already enabled), curl for the dotfiles'
      # preflights, and the guest agent for Packer, tofu and the smoke test.
      # Not sudo: the layer runs under doas, and a sudo with no rule for the
      # clone's user would be chosen first and fail.
      "apk add --no-interactive bash git curl qemu-guest-agent",
      "rc-update add qemu-guest-agent default",
      # cloud-init creates a clone's user with a locked password, and
      # OpenSSH without PAM refuses a locked account even a key login. The
      # image ships openssh-server-pam with PAM off; on is what lets
      # `tester` in.
      "printf 'UsePAM yes\\n' > /etc/ssh/sshd_config.d/10-pam.conf",
      "rm -f /etc/ssh/ssh_host_*",
      "cloud-init clean --logs",
    ]
  }

  # Last: remove the image's default user, which cloud-init made on this
  # clone's first boot with Packer's key. skip_clean for the reason
  # ubuntu.pkr.hcl gives.
  provisioner "shell" {
    execute_command = "doas sh -eu '{{ .Path }}'"
    skip_clean      = true
    inline = [
      "deluser --remove-home alpine || true",
    ]
  }
}
