# ADR-0118: Give the Wazuh indexer three GiB of heap

**Status:** Accepted · 2026-11 · amends [ADR-0030](0030-give-the-security-tooling-its-own-guest-and-its-own-stack.md)

## Context

[ADR-0030](0030-give-the-security-tooling-its-own-guest-and-its-own-stack.md)
bounded the indexer's retention by heap, not disk. At OpenSearch's 25 shards
per GiB, its 2 GiB of heap buys about 50 shards. It estimated that the non-alert
index families take roughly 15 of them, and so set thirty days of daily alert
indices. The lab's `WazuhIndexerShardBudgetNearlySpent` fires above 45. ADR-0030
named the heap as a reason to reopen it: "the indexer needing more than 2 GiB
of heap once six agents are real". It declined more heap because the guest had
8 GiB, and the spinning disks needed the page cache.

An audit of `odin` on 2026-11-13 re-derived the numbers, and they do not fit:

- The non-alert families take about 30 shards, not 15: fourteen
  `wazuh-states-*` indices (one per inventory type, plus vulnerabilities),
  about ten weekly `wazuh-monitoring-*` and `wazuh-statistics-*` indices under
  the 30-day policy #1507 gave them, and about six system indices.
- That leaves about 20 shards for alert indices at a line of 45, which is
  about two-thirds of the thirty days ADR-0030 set.
- The steady state, with thirty days of alerts, is about 60 shards.

When it was read, the cluster held 59–61 shards and both indexer alerts had
fired. After #1507 the cluster is green at 40, but only because `odin` was off
for eighteen days during the rack move and holds twelve alert indices. It
crosses 45 again as the days fill in.

Two of ADR-0030's reasons for declining more heap no longer hold.
`build-the-soc-guest.md` §0 gave the guest 16 GiB after the 2026-09-27
build, for the vulnerability feed's import bursts. And ADR-0030's own note of 2026-09-22 moved
`odin` onto the SSD pool, so there is no spinning pair to starve of page cache.

## Decision

**The indexer's heap goes from 2 GiB to 3 GiB** (`-Xms3g -Xmx3g`, still equal,
by Wazuh's tuning guidance). At 25 per GiB that is about 75 shards.

**Its container limit goes from 3.5 GiB to 4.5 GiB.** The off-heap share is
unchanged: on 2026-11-16 the container used 2.74 GiB with a 2 GiB heap.

**`WazuhIndexerShardBudgetNearlySpent` fires above 68**, which is nine-tenths
of the new budget, the same proportion as 45 was of 50. The steady state of
about 60 sits under it.

Thirty days of alerts, the `wazuh-weekly-30d` policy and everything else in
ADR-0030 are unchanged. Only the heap, the limit and the alert line move.

## Alternatives considered

- **Rollover indices.** ADR-0030 names them as the correct long-term fix,
  because they decouple the shard count from the day count. They are still
  that, and they are still a divergence from Wazuh's shipped index template,
  which ADR-0030 chose not to make. With the heap raised, the arithmetic does
  not need them yet.
- **Fifteen days of alerts.** That fits a 2 GiB heap, but halves the record
  the stack exists to keep, to save 1 GiB on a guest that has it.
- **Half of system RAM, 8 GiB.** That buys about 200 shards for an estate of
  seven agents, and takes from the import bursts' headroom what §0 sized the
  guest for.

## Consequences

- The SOC's memory limits add up to about 9.7 GiB on a 16 GiB guest. The rest
  is the import bursts' headroom and page cache.
- Applying it recreates the indexer container, which is a restart of a minute
  or two. The cluster comes back at the same shard count.
- The budget is still a bound, not a measurement, re-derived as ADR-0030
  says. If the steady state passes 68, rollover is the next step, not a
  fourth GiB.
- `stacks/scratch` keeps 2 GiB. Its investigations are meant to finish before
  the shard ceiling matters ([ADR-0071](0071-run-disposable-investigations-on-a-guest-that-is-destroyed.md)).
