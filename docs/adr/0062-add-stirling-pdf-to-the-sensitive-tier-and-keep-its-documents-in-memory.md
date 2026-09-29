# ADR-0062: Add Stirling-PDF to the sensitive tier and keep its documents in memory

**Status:** Accepted · 2026-09 · adds a service to the tier
[ADR-0008](0008-place-services-by-data-trust.md) created, the fifth beyond its
nine after Miniflux
([ADR-0057](0057-add-miniflux-to-the-sensitive-tier-with-its-fetcher-kept-off-winterfell.md))
Memos
([ADR-0059](0059-add-memos-to-the-sensitive-tier-for-notes-and-keep-documentation-in-docs.md)),
Mealie
([ADR-0060](0060-add-mealie-to-the-sensitive-tier-as-recipes.md)) and linkding
([ADR-0061](0061-add-linkding-to-the-sensitive-tier-behind-one-factor.md));
decides [#143](https://github.com/Gerrrt/HomeLab/issues/143)

## Context

[#143](https://github.com/Gerrrt/HomeLab/issues/143) proposed
[Stirling-PDF](https://github.com/Stirling-Tools/Stirling-PDF), a self-hosted
PDF toolkit: merge, split, rotate, convert, OCR, sign, compress. Its argument
is not a feature. The household already does these things, by uploading the
document to whichever free PDF website ranks first that week. This estate
segments its network by trust and encrypts its secrets at rest, and none of
that protects a P60 or a passport scan that goes through an anonymous web
converter on the way to an email.

Paperless-ngx ([#133](https://github.com/Gerrrt/HomeLab/issues/133)) is the
archive and deliberately not an editor. Stirling is the editor and
deliberately not an archive. Neither covers the other's job.

ADR-0008 does not name it, and
[`roadmap.md`](../roadmap.md#tier-extras) requires a decision for any service
beyond ADR-0008's nine before it is authored. That rule is why this is an ADR.
The placement is not in question: ADR-0008's test is the trust of the data,
and this service handles exactly the documents Paperless holds. The issue's
dependency on #102 is stale, since the host is `trinity`
([#404](https://github.com/Gerrrt/HomeLab/issues/404)).

What does need deciding is where the documents live while Stirling works on
them. The issue named this directly: *"a stack of half-processed financial
documents in a container volume is its own small problem."* Measured on the
pinned image (`3.0.0`) on 2026-09-29, booted under the hardening below with no
route off the host:

- **Every file a job touches goes under `/tmp/stirling-pdf`.** That covers
  the upload, every intermediate and the result. The entrypoint pins
  `java.io.tmpdir` there on the java command line. Stirling deletes a job's
  files when the job ends. After OCR, conversion, merge, rotate, split and
  compress, no document file was left, only the PDF engine's unpacked shared
  libraries.
- **The image enables a heap dump on OOM, written to `/configs`,** which is a
  volume. A heap dump of this JVM contains whatever document it ran out of
  memory on.
- **The entrypoint starts as root and drops to `stirlingpdfuser` (1001) with
  `setpriv`.** That needs CAP_SETUID and CAP_SETGID. It also has a non-root
  branch, which works as written.
- **LibreOffice runs inside a Landlock and seccomp sandbox that needs no
  root.** On the test boot it reported *"landlock ABI 8, seccomp active"*.
  Without root it loses only the separate uid it would otherwise run as.
- **Memory:** 790 MiB idle. The peak was 1342–1454 MiB across a 20-page and a
  40-page 300 dpi OCR, an RTF conversion, merge, rotate, split and compress,
  with no `oom_kill`.
- **Analytics.** PostHog, Scarf and the analytics master switch default to
  *ask the admin*, and the update check is on.
- **CORS.** An empty `corsAllowedOrigins` means *every origin, with
  credentials*.

## Decision

1. **Stirling-PDF joins `stacks/sensitive` on `trinity`** at
   `pdf.matrix.elysium`, in the tier's usual shape: `expose:` only, a site
   block in the `Caddyfile` and an alias on Caddy, pinned by digest,
   `cap_drop: ALL`, `no-new-privileges`, a read-only root, the image's own
   healthcheck, and a memory ceiling set over a measured number. It is reached
   from Hicks under the existing 50→99 rule. **There is no new firewall rule
   and no new published port.**

2. **Login is on, and the admin comes from SOPS.** `STIRLING_ADMIN_PASSWORD`
   is read once, on a first start against an empty volume, in the
   `PAPERLESS_ADMIN_*` shape. TOTP is enrolled on that account at first login,
   which is [ADR-0022](0022-expire-the-sso-deferral-when-the-tier-holds-real-data.md)'s
   floor. The issue called network position alone not enough, and it is right:
   every device on Hicks can reach this page.

3. **Documents are held in memory, never on a disk.** `/tmp` is a 1 GiB
   tmpfs charged to the container's 3 GiB limit. This is the trade that
   Paperless's DIFFERENCE 11 refused, taken the other way, because the
   workload is the other way. Paperless OCRs a backlog unattended, and an OOM
   kill halfway through one is lost work nobody sees. Here, one person OCRs
   one document while watching, and the worst case is an error they can
   retry. A restart erases whatever a failed job left behind. Stirling's own
   sweep of orphaned files runs every ten minutes and removes anything older
   than an hour (the defaults are thirty minutes and a day). Caddy refuses an
   upload over 256 MB, so a single file cannot fill the tmpfs before the job
   starts.

   **That tmpfs is `exec`,** which Docker's default is not, and this is not
   by choice. The PDF engine unpacks its shared libraries into
   `java.io.tmpdir`, nothing can move that directory, and under `noexec`
   every pdfium-backed tool fails while the healthcheck stays green. The root
   stays read-only, so the added exposure is a place where a compromised
   process with no capabilities could write and run a binary for as long as
   the container lives.

4. **Nothing leaves the house.** Analytics, PostHog, Scarf, the update check,
   URL-to-PDF, the AI engine and the phone-upload QR codes are all off. The
   running app confirmed each setting on the test boot, and that boot had no
   route out. The heap dump is off (`-XX:-HeapDumpOnOutOfMemoryError`,
   appended after the image's flags). CORS is pinned to
   `https://pdf.matrix.elysium`.

5. **It runs as uid 1001 from the start, not as root dropping to it.**
   `user:` takes the entrypoint's non-root branch. LibreOffice then shares
   that uid, and the Landlock and seccomp sandbox stays. With
   `STIRLING_LO_SANDBOX=required`, a kernel that cannot provide the sandbox
   refuses conversions rather than running LibreOffice unconfined.

6. **Its volume is not backed up.** `stirling-pdf-configs` holds the account
   database, the settings Stirling generates and its own nightly SQL dump. It
   holds no document, by decision 3. Everything in it comes back on an empty
   volume: the admin from SOPS and the settings from the environment. A
   rebuild costs a TOTP re-enrolment. It sits in `backup-volumes.sh`'s
   `DISPOSABLE` table with that reason, which also means a backup never stops
   the service.

7. **[ADR-0023](0023-keep-the-household-recovery-path-outside-the-estate.md)
   classes it as Unclassed.** It holds nothing a household would need back.
   A household that cannot reach it on a bad day is back to the free PDF
   websites, which is the problem, not a recovery path.

## Consequences

- **The tier's memory ceilings rise by 3 GiB, from 17.8 to 20.8 GiB of
  `trinity`'s 32.** The heap is capped at 40% of the limit where
  the entrypoint would choose 70%, so the heap, the JVM's off-heap memory,
  LibreOffice, tesseract and a full `/tmp` fit together. `cpus: 2` keeps an
  OCR here from taking the cores Paperless's ceiling of four counts on.
  Re-derive both from `container_memory_rss` after a month, as for the rest
  of the tier.
- **Twenty containers in the stack, where there were nineteen.** One more
  image for Dependabot to bump monthly. The CI boot step checks the hardening
  on each bump, and then runs `stacks/sensitive/stirling-pdf/smoke.sh`. That
  script logs in as the seeded admin and merges two pages through pdfium, so
  the failure decision 3 was measured against fails CI rather than a
  household member. With `/tmp` put back to `noexec`, the boot went healthy
  and the smoke test failed on the merge's 500.
- **One more login on Hicks's reach.** Every Stirling tool requires a session
  (an unauthenticated call answered 401), except the status endpoint the
  healthcheck reads.
- **Stirling's own data-at-rest features stay off.** Server-side storage,
  sharing, group signing, watched folders and pipelines would each put
  documents in the volume that decision 6 does not back up, and would make
  this an archive. **Any of them reopens this ADR.** The answer then is
  probably Paperless, not Stirling.
- **ADR-0008 is not superseded.** Its tier gains a service of the kind it
  already holds, under the rule
  [`roadmap.md`](../roadmap.md#tier-extras) set for extras.
