# ADR-0054: Encrypt `trinity`'s disks and seal the root key to the TPM

**Status:** Accepted · 2026-09 · makes the build-time choice
[ADR-0022](0022-expire-the-sso-deferral-when-the-tier-holds-real-data.md)
required and did not make

## Context

ADR-0022 said the sensitive tier's host would have its disk encryption
**decided at build time** and not inherited from `prometheus` by default. That
host is `trinity`
([ADR-0034](0034-run-the-sensitive-tier-on-the-prodesk-and-make-it-the-spare-hardware.md)).
It came back from #92's firewall rehearsal wiped on 2026-09-27, and it is built
under [#404](https://github.com/Gerrrt/HomeLab/issues/404). The build is the
sitting where this choice is cheap.

`docs/security.md` accepts plaintext at rest on `prometheus` and gives a reason
that is still right for that host. Full-disk encryption on a headless box
leaves two choices. One is a passphrase that nobody is there to type after a
power cut. The other is a key stored on the same machine, *"which is most of
the way back to where this started"*. What `trinity` will hold changes the
weight of both:

- The vault.
- Home Assistant's `.storage`, where every vendor token a config flow produces
  lives, outside SOPS by
  [ADR-0035](0035-scope-the-99-to-20-rule-to-the-hue-bridge.md).
- The photos, on a 2 TB USB drive that is the easiest thing in the house to
  carry off.
- The scanned documents.

The machine has what `prometheus` lacks: a TPM 2.0, and firmware with Secure
Boot. A key sealed to the TPM is not "stored on the same machine" in the sense
the security note means. It is not on the disk, so a disk read elsewhere yields
nothing.

The three answers weighed:

| Answer | For | Against |
| --- | --- | --- |
| No encryption | Nothing to build or lose | The vault, the tokens and the photos are readable from any pulled disk or unplugged drive |
| LUKS, passphrase at every boot | The strongest at rest: nothing on the machine unlocks it | Every power cut and every patch reboot leaves the tier down until someone reaches the console. ADR-0023 allows the downtime. Nobody would choose it twice |
| **LUKS, key sealed to the TPM, passphrase kept for recovery** | Unlocks unattended; a pulled disk or drive is ciphertext | Whoever takes the whole box takes the TPM with it |

## Decision

**LUKS2 on both disks. The root's key is sealed to the TPM against PCR 7. The
photo disk unlocks from a keyfile on the encrypted root. Each disk also has a
recovery passphrase, held in the operator's password manager.**

- **The root.** Ubuntu Server 26.04's installer does LVM on LUKS, with a
  passphrase. After the first boot, `systemd-cryptenroll` adds a `tpm2`
  keyslot bound to PCR 7, and `crypttab`'s `tpm2-device=auto` has the
  initramfs unlock with it. The installer's passphrase stays in its keyslot
  as the recovery key. This works because 26.04 builds its initramfs with
  dracut, which carries `systemd-cryptsetup`. 24.04's initramfs-tools ignores
  `tpm2-device=`, and on 24.04 this would have had to be Clevis. The runbook proves it
  with a reboot nobody types at, before anything else is built on the host.
- **PCR 7 alone.** PCR 7 measures the Secure Boot state and its keys. So the key
  unseals only while Secure Boot is on, with the same databases. Adding the
  kernel or initramfs PCRs would break the unlock on every kernel update, and a
  box that needs the console after each patch is the passphrase option again.
- **Secure Boot on, a BIOS administrator password, and no boot from USB.**
  PCR 7 alone has a known weakness: any image signed with the same keys, such as
  an Ubuntu live stick, measures the same PCR 7 and could ask the TPM for the
  key. The firmware settings are what close that. Booting anything but the NVMe
  needs the BIOS password, and turning Secure Boot off changes PCR 7, which
  makes the TPM refuse.
- **The photo disk.** LUKS2 with a random keyfile at
  `/etc/cryptsetup-keys.d/immich.key`, mode `0400`, on the encrypted root.
  `crypttab` opens it with `nofail`. A second keyslot holds a passphrase, so
  the drive can be read on another machine if `trinity`'s SSD dies. The
  photographs outlive the host that way, not only through the off-estate copy.
- **The recovery material lives in the operator's password manager.** That means
  the root passphrase, the photo disk's passphrase and the BIOS password. The
  second recipient's offline copy is not the right home: that copy exists to
  open *secrets*, and a disk passphrase has to be at hand the day the TPM says
  no.

## Consequences

- **A pulled SSD or unplugged photo drive is ciphertext.** That is the threat
  this ADR answers, and the one ADR-0022 was worried about.
- **The whole box stolen is not covered.** Neither is someone at the console
  with the BIOS password. The threat model in `docs/security.md` already
  excludes physical access to the rack, and this narrows that exclusion rather
  than removing it.
- **A firmware update, a Secure Boot key change or a TPM clear stops the
  unattended boot.** The box then waits at the passphrase prompt. That is the
  designed failure, and it is the passphrase option's normal state, which
  ADR-0023 accepts. After typing it, re-enrolling the `tpm2` slot seals to the new
  PCR 7.
- **Swapping the box for the firewall wipes all of this**
  ([ADR-0034](0034-run-the-sensitive-tier-on-the-prodesk-and-make-it-the-spare-hardware.md)).
  The tier's data comes back from its backups onto a rebuilt host, as it would
  anyway.
- **`prometheus` is unchanged.** Its disk stays plaintext, for the reasons
  `docs/security.md` gives. This decides `trinity` and says nothing about the
  estate's other hosts.
- **The procedure is
  [`build-the-sensitive-tier-host.md`](../runbooks/build-the-sensitive-tier-host.md)**
  §§2–5.
