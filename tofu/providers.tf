# The endpoint and the token come from the environment, from phoenix.env:
# PROXMOX_VE_ENDPOINT and PROXMOX_VE_API_TOKEN ("phoenix@pve!builder=<secret>").
# Provider configuration is never written to state, so the token stays where
# ADR-0074 §4 put it and nowhere else.
#
# TLS is verified. phoenix already trusts Saruman's PVE root CA for Packer
# (build-the-lab-templates.md §2), and this reads the same trust store.
provider "proxmox" {
  insecure = false
}
