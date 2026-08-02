## What changed

<!-- One or two sentences. What does this change do to the running lab? -->

## Why

<!-- The problem this solves. Link an issue or a line in docs/roadmap.md. -->

## Blast radius

<!-- Which hosts, VLANs or services are affected if this is wrong? -->

- [ ] No change to network segmentation or firewall rules
- [ ] No new port published to a VLAN that could not already reach the service
- [ ] No credential added outside `secrets/*.sops.yaml`

## Verification

<!-- What you actually ran, and what it printed. -->

- [ ] `make validate` passes
- [ ] Deployed to the lab and confirmed working
- [ ] Docs updated (`docs/`, service README, or `docs/roadmap.md`)
