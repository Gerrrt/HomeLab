# ADR-0083: Give the lab domain its deliberate weaknesses as individually switchable tags

**Status:** Accepted · 2026-10 · adds to
[ADR-0077](0077-configure-the-lab-domain-with-ansible-from-phoenix.md) (a sixth
secret in `phoenix.env`) and
[ADR-0078](0078-populate-the-lab-domain-from-a-committed-file-and-a-seed.md)
(the weaknesses it said would come)

## Context

[ADR-0029](0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md)
sized the lab domain and named two attack-surface assets — `ramuh`'s SPN
service account (the Kerberoasting target) and `titan` (the relay target) —
and stopped there, because that is architecture. ADR-0078 added the ordinary
population and fixed the rule the weaknesses must keep: the population is
ordinary, no account in it is weak, and turning a weakness off must leave the
population as it was.

[#449](https://github.com/Gerrrt/HomeLab/issues/449) asks for the weaknesses
themselves: `kerberoast`, `asreproast`, `dcsync`, `ucd`, `cd`, `rbcd`. The
deliverable it insists on is not the compromise but the **purple-team loop**:
enable one weakness, watch what Wazuh
([#266](https://github.com/Gerrrt/HomeLab/issues/266)), Velociraptor
([#267](https://github.com/Gerrrt/HomeLab/issues/267)) and Zeek
([#437](https://github.com/Gerrrt/HomeLab/issues/437)) see, then disable it and
confirm the signal goes away. And the **negative test** worth insisting on: with
every weakness off, the path to Domain Admin is *not* there. Both halves are
impossible in an all-or-nothing lab, which is why each weakness has to be
switchable on its own.

Three facts shape the design.

- **A tag selects a stage; it cannot undo one.** `lab-domain.yml` already runs
  one role per tag (ADR-0077 decision 5), and running without a tag changes
  nothing — it does not reverse. So "disable" needs a direction, not just the
  absence of a tag.
- **Two of the weaknesses are offline-crack exercises.** Kerberoasting and
  AS-REP roasting only teach anything if the account's password is actually
  crackable. That is a deliberately weak credential, which the strong
  seed-derived population passwords (ADR-0078) are the opposite of.
- **`verify.yml` already fails when a shipped weakness is tidied away.** It is
  the natural place to assert the deliberate weaknesses too — but what it should
  assert depends on whether a given weakness is meant to be on or off right now.

## Decision

Decided on #449, 2026-10-06.

1. **Each weakness is one role, one tag, with its own `present`/`absent`
   toggle.** `roles/weakness_<name>` carries `weakness_<name>_state`, default
   `absent`. The tag picks the role; the variable picks the direction. Every
   role is idempotent in **both** directions: `present` creates or sets the
   primitive, `absent` removes or clears it. So the loop is
   `--tags kerberoast -e weakness_kerberoast_state=present` to enable, observe
   in the SOC, then `--tags kerberoast` (the default) to disable. A plain
   `ansible-playbook lab-domain.yml` leaves all six absent, and
   `ansible-playbook verify.yml` then asserts none of them exists — the negative
   test, standing and re-runnable.

2. **Dedicated accounts for the account weaknesses; the real computers for the
   delegation weaknesses.** `kerberoast`, `asreproast` and `dcsync` each own a
   dedicated account (`svc-sql`, `svc-backup`, `svc-sync`) that `absent`
   deletes, so the ordinary population and the tier skeleton are never touched,
   per ADR-0078. `cd` and `rbcd` own a dedicated *controlled* principal
   (`svc-web`, `svc-rbcd`) as well. But the delegation *subject* and *resource*
   are the ADR-0029 assets themselves — `ucd` sets the flag on `ramuh`, `rbcd`
   writes the trust on `titan` — because those are the real servers the
   technique targets. The computer object is never created or deleted: `present`
   sets the attribute, `absent` clears it, returning the server to ordinary.

3. **One deliberately weak password, from `phoenix.env`.** `LAB_WEAK_PASSWORD`
   is a sixth entry in `phoenix.env`, shared by every dedicated weakness
   account. It is both the offline-crack target for `kerberoast`/`asreproast`
   and the login the `dcsync`/`cd`/`rbcd` exercises authenticate with. A role
   refuses to *enable* a weakness while it is unset. It lives in `phoenix.env`
   and not the tree because every secret does (ADR-0077 decision 3), not because
   it is secret — in a lab the weakness is the point.

4. **`verify.yml` proves each weakness is in the state its toggle names.** It
   reads the same toggles (defaulting to `absent`) and the same identifiers the
   roles use, from `group_vars/all.yaml`, so the proof cannot drift from the
   thing it proves. A plain run asserts all six absent; to prove one that is
   deliberately on, pass its state to `verify.yml` as well. It does not touch
   §0's "do not harden" assertions, which stay exactly as they were.

`ucd` uses `ramuh`, a member server, on purpose: a domain controller is trusted
for unconstrained delegation by default, so only a member server is an exercise.
`cd` ships Kerberos-only — protocol transition
(`TRUSTED_TO_AUTH_FOR_DELEGATION`, the S4U2Self variant) is deliberately not
set; it is a one-line addition if a future exercise wants it.

Rejected:

- **All six in one tag, or a single teardown tag.** Either makes "disable" all
  or nothing, which kills the per-weakness half of the loop that teaches.
- **Flipping the weakness onto an existing population or tier account.** Fewer
  objects, but disabling would then mutate a shared account back to "normal",
  and ADR-0078 is explicit that turning a weakness off leaves the population as
  it was. Dedicated accounts keep that promise by construction.
- **A committed weak password.** Fully reproducible, but it would be the only
  credential in the tree, against ADR-0077. `phoenix.env` costs nothing here and
  keeps the one rule whole.

## Consequences

- **Nothing is exploitable on merge.** Every toggle defaults to `absent`, so
  landing all six roles changes nothing on the live domain. The purple-team
  rollout stays one weakness at a time, by hand, which is #449's "add weaknesses
  one at a time, the observation is the deliverable".
- **`verify.yml` proves the primitive-level negative test, not the graph-level
  one.** With no weakness enabled it asserts all six primitives are absent, and
  if one is left on by accident a plain `verify.yml` goes red and names it. What
  it does not do is walk the authorization graph, so it is not on its own a
  proof that no path to Domain Admin exists — the collector #449 names for that
  ("run the collector with the tags off") is BloodHound, #451. The two are
  complementary: this asserts the specific primitives this lab adds are gone;
  the collector confirms the graph has no path left.
- **`LAB_WEAK_PASSWORD` is a crackable credential on the deployment host.** It
  is meant to be. It is `no_log` in every task like the other secrets, and the
  accounts that carry it exist only while a weakness is enabled.
- **The identifiers are fixed in `group_vars`.** Account names, SPNs and the
  delegation target/resource are one list, shared by the roles and the proof.
  Changing one — a different SPN, a new controlled principal — is an edit in one
  place.
- **Reopened by:** a weakness ADR-0029's table does not already allow (a
  technique needing a seventh guest, or a shipped default turned off to enable
  it) is a change to ADR-0029 first, not a new tag here.
