# Exercises

One file per purple-team exercise against the lab domain: what was run,
what the estate was expected to see, what it actually saw, and what changed
because of it. The point is the gap between *expected* and *observed*. An
exercise that finds no gap is still worth a file, because it proves a
detection works on a date.

## The rules

- **One exercise, one file**, named `YYYY-MM-DD-short-name.md`, copied from
  [`TEMPLATE.md`](TEMPLATE.md).
- **An exercise file is a record.** Like [`changelog.md`](../changelog.md), it
  is never rewritten after the day. A re-run is a new file that links the
  earlier one, so the history shows a detection being fixed, not just the end
  state.
- **Every technique carries its MITRE ATT&CK ID**, so exercises can be searched
  by technique and coverage can be counted.
- **Only inside the lab.** Every target is on the lab domain or the range
  ([ADR-0007](../adr/0007-defensive-estate-and-offensive-range.md),
  [ADR-0014](../adr/0014-put-ifrit-on-imaginationlan-and-give-the-targets-no-route.md)).
  Nothing here is run against the household tiers or anything outside the
  house.
- **Describe the activity, not the payload.** Name the technique and the tool
  and say what was done. No working exploit code, no captured credentials or
  hashes, no tokens. This repository is public, and
  [`security.md`](../security.md#what-this-repository-deliberately-does-not-publish)
  applies here as everywhere.
- **A missed or weak detection opens an issue.** The issue is the follow-up;
  the exercise file links it.

## Where the evidence comes from

| Source | Lives on | What it sees |
| --- | --- | --- |
| Wazuh | `odin` ([`stacks/soc`](../../stacks/soc)) | Agent alerts from the domain's hosts, Sysmon included |
| Velociraptor | `odin` ([`stacks/soc`](../../stacks/soc)) | Endpoint state, collected on demand |
| Zeek | `fenrir` ([`stacks/sensor`](../../stacks/sensor)) | Network metadata from the mirrored lab bridge |
| Suricata | `morpheus` | Alerts at the firewall, the chokepoint ([ADR-0006](../adr/0006-detect-at-the-chokepoint.md)) |
| Loki and Grafana | `alexander` ([`stacks/lab`](../../stacks/lab)) | The lab's logs, searchable by time window |

## Index

Newest first. Add a row with each new file.

| Date | Exercise | Techniques | Result |
| --- | --- | --- | --- |
