# tpl-gentoo, VMID 908: the base for dot-gentoo, the VM dotfiles-Gentoo's
# bootstrap is tested on (#920 phase 3, ADR-0090).
#
# Not an ISO install. Gentoo has no installer: a stage3 is unpacked and the
# system compiled by hand, hours a build. The build starts from Gentoo's own
# signed weekly cloud-init image instead, which
# scripts/import-cloud-template.sh puts on Saruman as staging template 918,
# and this clones it, adds what the dotfiles layer and the lab need, and
# converts the result. Its profile is 23.0/no-multilib/systemd, the only one
# the project publishes as a cloud image; dotfiles-Gentoo defaults to OpenRC,
# so the VM tests the layer on systemd.
#
# As alpine.pkr.hcl: no guest agent in the image, so a fixed build address
# and a key Packer puts on the cloud-init drive, for the image's default user
# `gentoo` (passwordless sudo), deleted at the end.

source "proxmox-clone" "gentoo" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_token_id
  token                    = var.proxmox_token_secret
  insecure_skip_tls_verify = var.proxmox_insecure_skip_tls_verify
  node                     = var.node

  clone_vm_id = 918
  full_clone  = true

  vm_id                = 908
  vm_name              = "tpl-gentoo"
  template_name        = "tpl-gentoo"
  template_description = "Gentoo Linux (23.0 systemd), built by packer/gentoo.pkr.hcl from staging template 918 on ${timestamp()}. Full clones only (ADR-0074)."
  tags                 = "template;linux"

  cores      = 4
  memory     = 8192
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
  ssh_username = "gentoo"
  ssh_host     = var.cloud_image_build_address
  ssh_timeout  = "15m"
}

build {
  name    = "gentoo"
  sources = ["source.proxmox-clone.gentoo"]

  provisioner "shell" {
    execute_command = "sudo -E sh -eu '{{ .Path }}'"
    inline = [
      "cloud-init status --wait || true",
      # The image ships no ebuild repository; dotfiles-Gentoo's bootstrap
      # emerges, so the template carries one.
      "emerge-webrsync --quiet",
      # From Gentoo's binary host, which the image already trusts (FEATURES
      # binpkg-request-signature): git for the dotfiles' clone, the agent for
      # Packer, tofu and the smoke test.
      "emerge --quiet --getbinpkg --noreplace dev-vcs/git app-emulation/qemu-guest-agent",
      "systemctl enable qemu-guest-agent",
      "rm -rf /var/cache/distfiles/* /var/cache/binpkgs/*",
      "rm -f /etc/ssh/ssh_host_*",
      "cloud-init clean --logs --machine-id",
    ]
  }

  provisioner "shell" {
    execute_command = "sudo -E sh -eu '{{ .Path }}'"
    skip_clean      = true
    inline = [
      "userdel -f -r gentoo || true",
    ]
  }
}
