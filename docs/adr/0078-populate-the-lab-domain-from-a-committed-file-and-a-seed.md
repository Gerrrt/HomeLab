# ADR-0078: Populate the lab domain from a committed file and a seed

**Status:** Accepted · 2026-10 · adds to
[ADR-0077](0077-configure-the-lab-domain-with-ansible-from-phoenix.md) (a
third secret in `phoenix.env`)

## Context

[ADR-0029](0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md)
sized the lab domain and stopped at its architecture.
[#449](https://github.com/Gerrrt/HomeLab/issues/449) asks for its contents,
starting with a user population: drawn from name lists, of configurable size,
with randomised group membership, and written to a file that both the
playbooks and later analysis
([#451](https://github.com/Gerrrt/HomeLab/issues/451)'s BloodHound) can read.

Three facts constrain where the population and its passwords live.

- **`phoenix` holds no age key**
  ([ADR-0043](0043-keep-the-ca-on-prometheus-and-build-phoenix-as-the-deployment-host.md)).
  `ansible/` reads its secrets from `~/.config/proxmox/phoenix.env`
  (ADR-0077 decision 3). It cannot read anything in `secrets/*.sops.yaml`.
- **A second run must change nothing** (ADR-0077). Passwords that are
  regenerated on each run would rewrite every account every time.
- **One account already exists.** `authgen` was made by hand on 2026-10-02 to
  run [`build-the-lab-domain.md`](../runbooks/build-the-lab-domain.md) §6's
  authentication generator. Two scheduled tasks run as it, and #449 said to
  fold it in rather than delete it.

## Decision

Decided on #449, 2026-10-03.

1. **The population is a committed file, without passwords.**
   `scripts/gen_population.py` draws it from two name lists into
   [`ansible/population/population.yaml`](../../ansible/population/population.yaml).
   For each account, the file records its name, department, title and groups.
   The draw is deterministic: the same `--count` and `--seed` give the same
   file, and the file's header records both. Its `--self-test`, which CI runs,
   fails if the committed file is not what that header regenerates. So the
   file is reviewed in pull requests like code and never edited by hand. The
   domain's intended shape is in git, where analysis can diff the domain
   against it.
2. **Each password is derived from a seed and the account name.** The
   derivation is the first 20 hex characters of `sha256(LAB_POPULATION_SEED
   ":" sAMAccountName)`, plus a fixed suffix for the complexity rule.
   `LAB_POPULATION_SEED` is a third entry in `phoenix.env`, generated once and
   never typed. A rerun derives the same password, and `update_password:
   when_changed` makes setting it a no-op. `population-credentials.yml` prints
   them again on demand, which is how #449's "record the starter credentials"
   is met without storing them.
3. **`authgen` is a fixed entry in the population.** It is drawn into `OU=IT`
   like anyone else, but with a fixed name and no random groups. Its password
   becomes the derived one, and `roles/authgen` stores the new one in the
   endpoints' task when the population play changed the account.
4. **The population is ordinary.** No account in it is given a weakness, and
   no group in it is delegated anything. #449's deliberate weaknesses are its
   own tags, each applied on top of this population separately. So turning
   one off leaves the population as it was.

Rejected:

- **Random passwords, printed once and kept nowhere.** That is the `authgen`
  precedent, and simpler. But a rerun could never confirm a password was
  still right. Losing the printout would mean resetting accounts that
  scheduled tasks and exercises depend on.
- **Generating the population on `phoenix` at run time, uncommitted.** The
  domain's intended shape would then be in nobody's review, and nothing the
  analysis could diff against.

## Consequences

- **The seed is a master key to the population.** Anyone with
  `phoenix.env` can derive every population password. That adds nothing to
  what `phoenix.env` already gives: `LAB_ADMIN_PASSWORD` is Domain Admin. The
  file stays mode 600 on the deployment host, as ADR-0077 has it.
- **Changing the seed changes every password at once.** That is a rotation in
  one step, and it means running `--tags population,authgen` together, so the
  endpoints' task gets the password `authgen` now has.
- **`when_changed` costs one logon per account per run.** About forty 4624s
  land on the DCs whenever the population play runs. They are noise in the
  SOC's baseline that has a known source.
- **Removing someone is a decision, not a side effect.** The role reports
  accounts in `OU=People` that the file no longer names, and removes none.
  `verify.yml` fails until someone deletes them, or puts them back in the
  file.
