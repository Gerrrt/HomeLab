# YYYY-MM-DD: Short name of the exercise

**Date:** YYYY-MM-DD · **Operator:** you · **Issue:** #N, if one exists ·
**Re-run of:** link to an earlier exercise, or *none*

## Objective

One or two sentences: what this exercise tests, and which detection it is
meant to prove or disprove.

## Scope

- **Attacker:** the host or VM the activity came from.
- **Targets:** the lab hosts it touched. Lab domain or range only.
- **Window:** start and end time, with the time zone, so the logs can be
  pulled for exactly this period.
- **Lab state:** anything switched on for this run, such as which deliberate
  weakness tags were enabled
  ([ADR-0083](../adr/0083-give-the-lab-domains-deliberate-weaknesses-as-switchable-tags.md)).

## Techniques

One row per step, in the order run. Describe the activity, not the payload.

| # | Time | ATT&CK ID | Technique | Tool | What was done |
| --- | --- | --- | --- | --- | --- |
| 1 | hh:mm | T0000 | Name | Tool | One line |

## Expected detections

Written before the run, so the result cannot shape the expectation.

| # | Source | Expected rule or signal |
| --- | --- | --- |
| 1 | Wazuh / Zeek / Suricata / Velociraptor / Loki | Rule ID or query, and what it should show |

## Observed

| # | Detected? | Where, and how long after the step | Notes |
| --- | --- | --- | --- |
| 1 | Yes / Partly / No | Source and delay | Alert text summarised, not pasted with secrets |

## Gaps and fixes

For every *No* or *Partly* above: why it was missed, and what changes.
Each fix links the issue or PR that makes it.

## Lessons

What this exercise taught, in a few lines.
