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

# gandalf, the range host (ADR-0017, ADR-0116). A second node in the same tree
# and the same state, as ADR-0076 foresaw, through an alias rather than the
# environment: PROXMOX_VE_* already names Saruman. The endpoint and the token
# come from TF_VAR_gandalf_endpoint and TF_VAR_gandalf_api_token in
# phoenix.env, beside the Saruman lines, so every tofu step that sources
# phoenix.env works unchanged (build-the-playground.md §5). A variable a
# provider reads is not written to state either. TLS is verified
# against gandalf's CA, which phoenix trusts since build-the-lab-templates.md
# §5.
provider "proxmox" {
  alias     = "gandalf"
  endpoint  = var.gandalf_endpoint
  api_token = var.gandalf_api_token
  insecure  = false
}
