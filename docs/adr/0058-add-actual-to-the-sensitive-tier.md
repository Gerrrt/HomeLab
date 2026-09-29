# ADR-0058: Add Actual to the sensitive tier, and claim it before it answers

**Status:** Accepted · 2026-09 · adds a service to the tier
[ADR-0008](0008-place-services-by-data-trust.md) created, a row to the classes
[ADR-0023](0023-keep-the-household-recovery-path-outside-the-estate.md) set and
the table [ADR-0022](0022-expire-the-sso-deferral-when-the-tier-holds-real-data.md)
keeps; decides [#142](https://github.com/Gerrrt/HomeLab/issues/142)

## Context

[#142](https://github.com/Gerrrt/HomeLab/issues/142) proposed a budgeting
service for the household. [Actual](https://actualbudget.org) is local-first
zero-sum budgeting. Every client keeps the whole budget in its own database,
and the server is the place they sync through, so the server being down stops
syncing and nothing else. The alternative the issue named is
[Firefly III](https://firefly-iii.org/): double-entry accounting with a rule
engine, in PHP on a Postgres of its own. It is a different way of keeping
accounts, not a larger version of the same one, and the issue asked for one of
the two: "running both is how neither gets used."

**Actual, not Firefly III.** The household wants a budget, which is what
Actual is and what Firefly III can be made to do. Firefly III would be the
tier's third Postgres, beside Immich's and Paperless-ngx's, for an application
that is unusable whenever the server is down. Actual is one container on
SQLite and keeps working without the server.

ADR-0008 does not name it. Its test is the trust of the data, not the
function. A household's accounts, balances and every transaction are "data
whose loss or exposure genuinely hurts", the same category as the document
archive, which already holds the statements they come from. So the placement
is not in question: VLAN 99, on `trinity`, behind Caddy. Hicks already reaches
Caddy's `443` under the 50→99 rule, and Actual answers nothing else, so no
rule is added. This is an ADR rather than a changelog line because the
roadmap requires every service beyond ADR-0008's nine to have a decision of
its own, as Miniflux had in
[ADR-0057](0057-add-miniflux-to-the-sensitive-tier-with-its-fetcher-kept-off-winterfell.md),
and because one fact about the image changes how it has to be deployed.

**Actual has no password setting.** A fresh server is *unclaimed*. The first
client to reach it is offered "set a password", and whatever it sends becomes
the password. Behind Caddy, that first client is anything on Hicks that finds
the name before the operator does. The image's own reset script cannot close
that gap from a script: it reads the password with stdin in raw mode and
needs a terminal.

Measured on `actualbudget/actual-server:26.9.0-alpine`, pinned by digest, on
2026-09-29:

- **User and filesystem.** It declares no user and would run node as root.
  It ships an `actual` user, 1001, which owns `/data`. Run as 1001, read-only,
  with every capability dropped, it came up healthy and `docker diff` showed
  nothing written outside `/data`.
- **What it keeps.** `/data/server-files/account.sqlite` holds the password
  hash and the sessions. `/data/user-files/` holds one blob per budget, written
  by the budget's first upload. `account.sqlite` is in rollback-journal mode,
  not WAL.
- **Network.** It boots and answers `/health` with `--network none`.
- **Claiming it.** `POST /account/bootstrap` sets the password once, and a
  second attempt gets `400 already-bootstrapped`.
- **Sessions.** In password mode there is one user, and every login is handed
  the same session token. By default that token never expires. **Changing the
  password does not revoke it**: the token issued before a change validated
  after it. Deleting the `sessions` rows with the service stopped does
  revoke it, and the next login is issued a new token.
- **Login methods.** It allows password, header and OpenID logins by default,
  and trusts every private range as a proxy by default. Header login is
  unreachable while the only auth row is the password's: an attempt was
  refused with 400.
- **Rate limit.** Five failed logins or claims per client per fifteen
  minutes. The sixth got 429.
- **Memory.** 279 MiB idle RSS, and 329 MiB at its high-water mark after a
  20 MiB budget upload.

## Decision

1. **Actual joins `stacks/sensitive` on `trinity`** in the tier's shape:
   `expose:` and no `ports:`, a site block at `actual.matrix.elysium` and an
   alias on Caddy, pinned by digest, `read_only`, `cap_drop: ALL`,
   `no-new-privileges`, and the image's own health script. It runs as the
   image's own user, 1001, rather than as root with capabilities dropped,
   because this image offers a user. The memory ceiling is 1 GiB, about three
   times the measured peak. CI boots it under that hardening on every change,
   as it does Home Assistant and ntfy.

2. **No new firewall rule.** Hicks reaches it through Caddy's `443` like every
   other service on the tier.

3. **The server is claimed from SOPS before it first starts.** The password is
   `ACTUAL_SERVER_PASSWORD` in `secrets/sensitive.sops.yaml`.
   `scripts/seed-actual-password.sh` runs from `make up`, before the stack
   starts. On an empty volume it boots the pinned image under the service's
   hardening with `--network none`, claims the server over the same HTTP call
   the first-run page makes, and stops it. So the live service never exists
   unclaimed. A claimed server is only checked: a login with the SOPS value,
   and a warning if it fails. The seed never changes a password that is set.
   - The value is read from SOPS by the script. It is never in the
     container's environment or in `.env`, because the service never needs it.
   - It is also kept in the password manager, because it is what each client
     logs in with.

4. **No bank sync.** Transactions come in as imported files. GoCardless and
   SimpleFIN would put a third party's credentials in `account.sqlite` and
   have the server hand the household's bank access to an aggregator on a
   schedule. That trades the estate's lack of any external dependency for a
   convenience. Turning it on
   is a decision with its own record, not a setting changed in the app.

5. **Password login only.** `ACTUAL_ALLOWED_LOGIN_METHODS=password`, and
   `ACTUAL_TRUSTED_PROXIES` names Caddy's fixed address alone. The first turns
   "header login is unreachable" from a property of the database into a
   setting. The second makes the rate limit count the phone on Hicks rather
   than the proxy.

6. **Backed up as a record, with the service stopped.** `actual-data` joins the
   nightly set, with `./server-files/account.sqlite` as its sentinel. The
   clients' copies are a real mitigation but not a backup: they survive
   losing the server, not a bad sync, which reaches every client.

7. **ADR-0023 class: Durable**, with Immich and Paperless-ngx. It may be down,
   and it may not be lost. Like them it holds no real data until the
   off-estate copy exists, which is
   [#404](https://github.com/Gerrrt/HomeLab/issues/404) step 10.

8. **ADR-0022: no second factor.** Actual has none short of OpenID, which
   would need the identity provider ADR-0022 defers. It joins Immich and
   AdGuard Home in that table's "None" rows.

## Consequences

- **The tier grows by one container, one volume and one name.** The name
  needs a host override on `morpheus` when it is deployed, like the other
  eight.
- **One password and one session for the whole household.** Anyone who has
  the password, or any signed-in device, can read and change every budget.
  A lost phone is dealt with by signing every device out: the stack README
  has the command. A changed password alone does not do it, and that is
  written beside the key in the secrets template because it is the opposite of
  what most people would expect.
- **The seed is the only thing between a fresh volume and the first client
  on Hicks.** `make up` runs it every time, and on a restore it doubles as the
  check that the volume came back: an empty volume is claimed afresh, and the
  seed says so. `--check` is in the restore runbook.
- **The budgets are readable on `trinity`** unless a budget has Actual's own
  end-to-end encryption turned on, which is a per-budget choice made in the
  client. That is the same position as the documents in Paperless-ngx, on
  disks that are encrypted at rest
  ([ADR-0054](0054-encrypt-trinitys-disks-and-seal-the-root-key-to-the-tpm.md)).
- **Nightly backups stop Actual for as long as the archive takes.** A client
  that tries to sync in that window fails, keeps its changes, and syncs on the
  next attempt.
- **Homepage links to it and reads nothing from it.** A widget would need
  the household password, and that password gets the token every device
  shares.
- **ADR-0008, ADR-0022 and ADR-0023 are not superseded.** ADR-0008's tier
  gains a service by its own test, and ADR-0022's and ADR-0023's tables each
  gain a row. ADR-0022 and ADR-0023 each gain a pointer to this record, and
  their tables are not edited.
