# ADR-0117: Close the firewall's own addresses to every segment, and take passwords off its SSH

**Status:** Accepted · 2026-11

## Context

A read-only audit of `morpheus` from `prometheus` on 2026-11-13 found two
things the documents said were closed.

**Every segment reached the admin UI and `sshd` on the firewall's WAN
address.** Each interface carries *Block SSH to pfSense*, *Block HTTPS to
pfSense* and *Block HTTP to pfSense* (Winterfell carries only the last two).
Each block names that interface's own address and nothing else. The firewall
holds an address on every segment and one on the WAN, and the interface's
catch-all `pass ... to any` carried a packet to any of those not already
blocked. From `prometheus`, `https://` on the WAN address answered 200 and
port 22 there gave an OpenSSH banner. [`network.md`](../network.md) said
"Winterfell itself is blocked from it". That held for `10.0.99.1` and for no
other address. Hicks had a second way in: *Allow Hicks access to
ImaginationLAN* passes TCP to the whole of `10.0.30.0/24`
([ADR-0031](0031-narrow-hicks-to-a-named-list-on-winterfell-and-leave-the-lab-open.md)),
and the lab's gateway, `10.0.30.1`, is in it.

`make check-firewall` could not see this, and that is a gap in its question,
not a defect in its code. It asks which *segments* a catch-all reaches, and the
WAN address is in no segment.

**`sshd` accepted passwords, keyboard-interactive and root.** `auth.log`, read
on 2026-11-14, has `admin` logging in by password from a Hicks desktop on
2026-11-10, from the Hicks MacBook on 2026-11-13, and six times from `oracle`
on 2026-11-10. All of
Hicks reaches port 22 on the firewall by *Allow SSH to Winterfell*, and every
segment reached it on the WAN address. That includes the two corporate laptops
on Hicks, which [`network.md`](../network.md) says are to be treated as
untrusted. Two keys are authorised. One is `prometheus`'s, and it is how every
collector, the nightly export and `make check-firewall` log in, as `root`.

## Decision

**Every interface blocks ssh, http and https to `This Firewall (self)`, not to
its own address.** Each block's source is `any` and its family is IPv4+IPv6,
and the three rows sit above every other rule on the interface except the named
exceptions below. pfSense expands `(self)` to every address the firewall holds,
the WAN's included. The three rows keep their names. Hicks' three move up, above
*Allow Hicks access to ImaginationLAN*.

**The exceptions are named passes above those blocks, and there are three:**

| Segment | Pass | Why |
| --- | --- | --- |
| Hicks | *Allow SSH to Winterfell*, already there, 22 to `10.0.99.0/24` | administration from a workstation, key-only below |
| Hicks | *Allow HTTPS to pfSense on its management address*, already there, 443 to `10.0.99.1` | the admin UI |
| Winterfell | *Allow SSH to pfSense from prometheus*, new, `10.0.99.20` → `10.0.99.1:22` | the collectors, the export and the claims check |

The switch LAN keeps pfSense's generated anti-lockout rule, which sits above
every user rule and passes 22, 80 and 443 to the LAN's own address. It is the
way back in if a rule change locks Hicks out, and the only thing on that
segment is `neo`. The rest of the switch LAN is closed by the same three blocks.

So the admin UI answers at `10.0.99.1` to Hicks and nowhere else, and `sshd`
answers at `10.0.99.1` to Hicks and to `prometheus`. `oracle` and `trinity` lose
port 22 on the firewall. Nothing scheduled on either uses it. The 2026-11-10
logins from `oracle` were a person at a shell there, and that person now uses
`prometheus` or Hicks.

**`sshd` is key-only.** *System → Advanced → Admin Access → SSHd Key Only* is
set to *Public Key Only*, which turns off password and keyboard-interactive
authentication. Root login stays allowed, because `prometheus`'s jobs log in as
`root` (`FW_USER`'s default since `backup-firewall.sh`), and with passwords off
that is a key login too. Every machine that administers the firewall over SSH
has its key on `admin` under *System → User Manager* before the switch. The
password path that remains is the console, at the rack.

**The claims file asks the second question, and the timer answers it nightly.**
`docs/firewall-claims.yaml` gains a `firewall` entry per interface: which of the
firewall's own addresses a host on that segment reaches on ssh, http and https.
`check_firewall_claims.py` derives it by evaluating the ruleset the way pf
does, one firewall address at a time, first `quick` match wins. It names each
address by the segment it sits on, or `WAN`, or `link-local`, and never prints
the number. A host-scoped pass like `prometheus`'s is not counted, because the
question is what the segment reaches. The fixtures run in CI under
`scripts/self-tests.sh`. The live run stays on `prometheus`, for
[ADR-0026](0026-check-the-documents-where-the-truth-is.md)'s reason.

## Alternatives considered

- **Bind the admin UI and `sshd` to `10.0.99.1` only.** pfSense offers no
  listen address for either in its UI, and a change made under it is lost to the
  next upgrade or restore. Rules are the lever pfSense supports.
- **One floating rule set instead of rows per interface.** Floating rules are
  evaluated before every interface's own, so Hicks' two passes would have to
  move there too. [`network.md`](../network.md) lists what each segment reaches
  interface by interface, and so does `pfctl`. Three rows per interface keeps
  those two agreeing.
- **Disable the anti-lockout rule.** That removes the one recovery path that
  needs no console. Its cost is that a device on an untagged switch port reaches
  the UI's login page, and it has been accepted since the switch LAN was closed
  ([ADR-0025](0025-close-the-switch-lan-to-winterfell.md)).
- **Narrow Hicks' SSH to named workstations.** Hicks is a `/24` with no
  per-host source by decision
  ([ADR-0031](0031-narrow-hicks-to-a-named-list-on-winterfell-and-leave-the-lab-open.md)).
  Key-only `sshd` is what stops a corporate laptop logging in. A per-host list
  can follow when Hicks gets one.

## Consequences

- A rule that names one firewall address where it meant all of them now fails
  the nightly check, by name, rather than waiting for the next audit.
- An `ssh admin@10.0.99.1` with no key on the MacBook, the desktops or `oracle`
  fails after the switch. [`close-the-firewall-to-its-segments.md`](../runbooks/close-the-firewall-to-its-segments.md)
  §1 proves every key that is meant to work before the setting changes.
- A mistake in the Hicks rows can lock the UI out from Hicks. Recovery is the
  console's *Restore recent configuration*, or a cable into an untagged port on
  `neo` and the anti-lockout rule.
- The GUI's default self-signed certificate, the undeclared Hicks pass into
  `smaug` and the other audit findings are not decided here.
