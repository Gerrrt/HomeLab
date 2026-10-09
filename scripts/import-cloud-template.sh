#!/usr/bin/env bash
#
# Import a distribution's own cloud image as a staging template, for Packer's
# proxmox-clone builder to finish into a lab template (#920 phase 3,
# ADR-0090 decision 2).
#
# WHY NOT AN ISO. Alpine and Gentoo have no installer that takes an answer
# file: Alpine's is typed at a console, and Gentoo's is a stage3 unpacked and
# compiled by hand. Both projects publish signed cloud-init images instead,
# so the image is the install. This script puts it on Saruman unchanged.
# packer/alpine.pkr.hcl and packer/gentoo.pkr.hcl then clone it, add what
# each dotfiles layer needs, and convert the result to 907 or 908.
#
# WHY HERE, AS ROOT. Importing a disk image into a guest (`import-from`) is a
# root operation on Proxmox; phoenix's token cannot do it (ADR-0043). So this
# runs on Saruman, like the ISO store's placement (build-the-lab-templates.md
# §2b), and the rest of the build stays on phoenix.
#
# THE PINS. Each image is named by its exact file and pinned by SHA-256 below.
# The hash was taken on 2026-10-09 from a file whose publisher's signature
# verified, against a key found off the image:
#   alpine  alpine-3.24.2-x86_64-cloudinit-r2.qcow2: the .asc from
#           F26A DFAD BAE7 02EF 7AF6 3745 9DA7 EF23 BFFC DF22, the key
#           alpinelinux.org/cloud names; the .sha512 beside it matched too.
#   gentoo  di-amd64-cloudinit-20261004T164559Z.qcow2: the .asc from
#           Gentoo's Automated Weekly Release Key 13EB BDBE DE7A 1277 5DFD
#           B1BA BB57 2E0E 2D18 2910, which gentoo.org/downloads/signatures
#           lists, refreshed by WKD (the keyserver copy showed it expired).
# A download whose hash differs is refused. A newer image is a new pin, a new
# name, and the same check by hand first. scripts/check_tool_versions.py
# reads the two url= lines below weekly and says when upstream has moved on.
#
# Usage (as root on Saruman):
#   scripts/import-cloud-template.sh alpine|gentoo [--force]
#
#   --force  destroy the staging template first if it exists. The finished
#            templates are full clones of it (ADR-0074), so nothing depends
#            on it once Packer has run.
set -euo pipefail

usage() { sed -n '/^# Usage/,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2; }

[[ $# -ge 1 ]] || usage
distro=$1
shift
force=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --force) force=1 ;;
    *) echo "error: unknown argument: $1" >&2; usage ;;
  esac
  shift
done

case $distro in
  alpine)
    vmid=917
    name=stage-alpine
    url=https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/cloud/alpine-3.24.2-x86_64-cloudinit-r2.qcow2
    sha256=53a02ce7466524a83f8b07b6fe4ef212f6019752c0e563db9538d9b54d468a8e
    # The image is under half a gigabyte; 8 GiB is ADR-0090's size for the
    # guest, and the template is grown to it here so the module's disk floor
    # for 907 is the guest's.
    disk_gib=8
    memory=1024
    ;;
  gentoo)
    vmid=918
    name=stage-gentoo
    url=https://distfiles.gentoo.org/releases/amd64/autobuilds/20261004T164559Z/di-amd64-cloudinit-20261004T164559Z.qcow2
    sha256=bd4e146d45d1fbe56f00835f82a57eb1c4e978c1d0cc399314b42e769d20768d
    # Already 20 GiB as published; left as it is.
    disk_gib=
    memory=4096
    ;;
  *) usage ;;
esac

storage=large_data
bridge=vmbr0

# Root, and on Saruman: --force destroys a VMID, and 917 and 918 mean
# something else on any other node.
[[ $(id -u) -eq 0 ]] || { echo "error: run as root on Saruman" >&2; exit 1; }
[[ $(hostname -s) == Saruman ]] || { echo "error: run on Saruman, not $(hostname -s)" >&2; exit 1; }

if qm status "$vmid" >/dev/null 2>&1; then
  if ((force)); then
    qm destroy "$vmid" --purge
  else
    echo "error: VMID $vmid exists; pass --force to replace it" >&2
    exit 1
  fi
fi

# A private directory made now, not a fixed path under /var/tmp: a root
# download into a name another account could create first is a symlink away
# from overwriting any file on the host.
work=$(mktemp -d /var/tmp/import-cloud-template.XXXXXX)
trap 'rm -rf "$work"' EXIT
file="$work/${url##*/}"
curl -fsSL --retry 3 -o "$file" "$url"
echo "$sha256  $file" | sha256sum -c --quiet - || {
  echo "error: $file does not match its pin; refusing to import it" >&2
  exit 1
}

# The shape of every other Linux template (packer/ubuntu.pkr.hcl), on OVMF
# with Secure Boot off: neither project ships a Microsoft-signed shim. No
# ciuser: the image's own default user (alpine, gentoo) is the one Packer
# logs in as, with the key it generates and puts on the cloud-init drive.
qm create "$vmid" \
  --name "$name" \
  --tags "template;linux;staging" \
  --description "The $distro project's cloud image, imported unchanged by scripts/import-cloud-template.sh from ${url##*/} (sha256 $sha256) on $(date -u +%FT%TZ). Packer clones it into the lab template (#920)." \
  --ostype l26 --machine q35 --bios ovmf \
  --efidisk0 "$storage:1,efitype=4m,pre-enrolled-keys=0" \
  --cpu host --cores 2 --memory "$memory" --balloon 0 \
  --scsihw virtio-scsi-single \
  --scsi0 "$storage:0,import-from=$file,discard=on,ssd=1,iothread=1" \
  --net0 "virtio,bridge=$bridge" \
  --agent enabled=1 \
  --ide2 "$storage:cloudinit" \
  --serial0 socket \
  --boot order=scsi0
if [[ -n $disk_gib ]]; then
  qm disk resize "$vmid" scsi0 "${disk_gib}G"
fi
qm template "$vmid"
echo "$name ($vmid) imported and converted; now build it with packer/$distro.pkr.hcl from phoenix"
