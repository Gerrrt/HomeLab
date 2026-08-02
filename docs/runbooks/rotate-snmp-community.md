# Runbook: Rotate the SNMP communities

**Why this is not optional.** A single SNMP community string was committed to
this public repository in plaintext and shared across pfSense, the MokerLink
switch, the APC UPS and the ProLiant's iLO. It is still in git history. Anyone
who cloned the repository at any point has it.

These are read-only communities, which sounds mild. On a firewall, read-only
means the complete state table, every interface and the full pf configuration
surface. Treat them as credentials.

**Order matters:** change the device first, then the repository. Doing it the
other way round means the exporter starts failing before the device is ready.

---

## 1. Generate four distinct communities

```bash
for d in pfsense apc mokerlink ilo; do
  printf '%-10s %s\n' "$d" "$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
done
```

One per device. The whole reason the old arrangement was dangerous is that a
single string unlocked everything.

Note that SNMPv2c sends these in cleartext on every poll. Distinct communities
limit the blast radius of a captured packet; they do not make the protocol
secure. Moving to SNMPv3 authPriv is tracked in [`roadmap.md`](../roadmap.md) —
the MokerLink switch not supporting it is the blocker.

## 2. Change each device

### pfSense (`morpheus`, 10.0.99.1)

**Services → SNMP.** Replace the read community string. Confirm the daemon binds
only to the VLAN 99 interface — not WAN, not all interfaces.

### APC Smart-UPS (`mjolnir`, 10.0.99.10)

Network Management Card web UI, **Configuration → Network → SNMPv1 → Access
Control**. Replace the community for the `prometheus` host entry. Set access to
**Read** and restrict the NMS address to `10.0.99.20` if the card supports it.

### MokerLink switch (`neo`, 10.7.7.2)

Web UI at `http://10.7.7.2`, **SNMP → Community**. Replace the read-only
community. Delete any default `public`/`private` entries while you are in there.

### HPE iLO (`shiva`, 10.0.30.10)

**Administration → Management → SNMP Settings.** Replace the read community.

## 3. Verify each device before touching the repo

```bash
snmpwalk -v2c -c '<new-community>' 10.0.99.1  1.3.6.1.2.1.1.1.0   # pfSense
snmpwalk -v2c -c '<new-community>' 10.0.99.10 1.3.6.1.2.1.1.1.0   # APC
snmpwalk -v2c -c '<new-community>' 10.7.7.2   1.3.6.1.2.1.1.1.0   # switch
snmpwalk -v2c -c '<new-community>' 10.0.30.10 1.3.6.1.2.1.1.1.0   # iLO
```

Each must return a sysDescr string. Also confirm the **old** community now
fails — some devices append rather than replace:

```bash
snmpwalk -v2c -c '<old-community>' 10.0.99.1 1.3.6.1.2.1.1.1.0    # must time out
```

## 4. Update the repository

```bash
make secrets-edit
```

Replace all four values:

```yaml
SNMP_COMMUNITY_PFSENSE: <new>
SNMP_COMMUNITY_APC: <new>
SNMP_COMMUNITY_MOKERLINK: <new>
SNMP_COMMUNITY_ILO: <new>
```

Then re-render and restart:

```bash
make render
make up
```

`make render` fails loudly if any placeholder is left unsubstituted, so a typo in
a key name is caught before the container starts.

## 5. Confirm monitoring recovered

**Prometheus → Status → Targets**, job `snmp`. All four instances `UP` within
60 seconds. Or:

```promql
up{job="snmp"}
```

The `SnmpTargetUnreachable` alert fires after 10 minutes, so a mistake here
announces itself.

## 6. Commit

```bash
git add secrets/observability.sops.yaml
git commit -m "chore(secrets): rotate SNMP communities"
```

The diff shows *which* keys changed and nothing about their values — SOPS
encrypts values and leaves keys in plaintext.

---

## Also required

Rotating the live credential does not remove the old one from git history.
Follow [`purge-git-history.md`](purge-git-history.md) as well — one without the
other leaves the job half done.
