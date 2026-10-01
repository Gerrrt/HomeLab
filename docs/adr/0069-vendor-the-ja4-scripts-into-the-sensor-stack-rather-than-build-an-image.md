# ADR-0069: Vendor the JA4 scripts into the sensor stack rather than build an image

**Status:** Accepted · 2026-10

## Context

[#437](https://github.com/Gerrrt/HomeLab/issues/437) asked Zeek on `fenrir` for
TLS metadata without decryption, and named JA3. It closed on 2026-10-01 with SNI,
certificate subjects and issuers, and chain validation in `ssl.log` and
`x509.log`. It did not get fingerprints, because the stock `zeek/zeek` image
`stacks/sensor` pins ships none.
[#776](https://github.com/Gerrrt/HomeLab/issues/776) is the gap.

**JA4, not JA3.** JA3 hashes the ClientHello's extensions in the order they
arrive. Browsers have randomised that order since 2023, so one client now
produces many JA3 hashes. JA4 sorts the extensions before hashing.

**How the package would arrive is the decision, because of what the repository
already enforces.** Every image here is pulled and pinned by digest from a
`compose.yaml`, and nothing is built. Three things rest on that:

- `scripts/check_image_pins.py` requires every service image to carry a digest
  and every `docker run` to resolve through `scripts/image-for.sh`.
- `check_compose_health.py --probe` execs healthchecks inside the pinned image.
- Dependabot bumps the digests.

A `build:` stanza is outside all three: an image built on `fenrir` is pinned by
nothing, probed by nothing, and bumped by nothing.

The issue offered three ways in: a derived image built here, `zkg install` at
container start, or a third-party image. Reading FoxIO's repositories on
2026-10-01 added a fourth, and it changed the comparison.

- **`zeek/foxio/ja4` is now a compiled C++ plugin.** Building it needs a C++20
  compiler, CMake 3.15+ and Zeek's development headers. A derived image is
  therefore a multi-stage toolchain build, not one `RUN zkg install` line.
- **FoxIO also publishes
  [`ja4-zeek-scripts`](https://github.com/FoxIO-LLC/ja4-zeek-scripts), "Zeek
  scripts only"**, for Zeek 5+. Its README says it can be installed by copying
  its `zeek/` directory into the site path and adding `@load`. That is exactly
  how `stacks/sensor/zeek/local.zeek` already reaches the container: a
  read-only bind mount of a file in this repository.

**Licensing**, from FoxIO's
[License FAQ](https://github.com/FoxIO-LLC/ja4/blob/main/License%20FAQ.md):

- JA4, the TLS client fingerprint, is BSD 3-Clause.
- Everything else in JA4+ is under the FoxIO License 1.1. The FAQ names JA4S,
  JA4L, JA4LS, JA4H, JA4X, JA4SSH, JA4T, JA4TS, JA4TScan, JA4Scan, JA4D, JA4D6
  "and all future additions", so the list is open-ended by design. It is permissive for internal, academic and
  personal use, and not for monetisation. It allows combination with
  permissive-licensed code provided the FoxIO licence is included and noted.
- This repository is public, MIT-licensed, and earns nothing.

## Decision

**Vendor `ja4-zeek-scripts` at a pinned commit into
`stacks/sensor/zeek/ja4/`, and load it from `local.zeek`. Build no image.**

- **What is vendored.** The package's `zeek/` directory, taken whole at one
  commit of `FoxIO-LLC/ja4-zeek-scripts`, recorded beside it with the date and
  the upstream URL. The package's `LICENSE`, `LICENSE-JA4` and `zkg.meta` come
  with it.
  - A `NOTICE` at the top of that directory says which parts are BSD (JA4) and
    which are under the FoxIO License 1.1 (every other JA4+ method, named by
    reference to FoxIO's FAQ rather than copied, since that list grows). That is the
    inclusion and notice the licence asks of a permissive-licensed repository.
  - The repository's own MIT licence does not extend to that directory, and the
    NOTICE says so.
- **How it reaches Zeek.** `compose.yaml` bind-mounts `./zeek/ja4` read-only
  beside `local.zeek`, and `local.zeek` loads it. The `zeek/zeek` image, its
  digest and every check above are untouched.
- **Which methods run.** FoxIO's defaults: everything `config.zeek` enables,
  which is all but JA4X. Upstream marks JA4X as awaiting Zeek support. JA4D6 is
  listed but awaits Zeek's DHCPv6 support, so it produces nothing yet. JA4LS
  and JA4TS come with JA4L and JA4T. They are switched by `@if` at load time in
  the package's own `config.zeek`, so they cannot be changed with a `redef` in
  `local.zeek`. A change to the set is an edit to the vendored `config.zeek`,
  and goes in the same PR as the NOTICE entry for it.
- **How it is updated.** A deliberate PR that re-vendors at a newer commit.
  `scripts/vendor-ja4.sh <commit>` fetches that commit's tree from GitHub,
  replaces the directory, and rewrites the recorded commit. The diff is the
  review. Dependabot does not track it. That is the cost, and the same one
  every pinned-by-hand thing here carries.
- **How it is proved.** A JA4 appears in `ssl.log` for a guest's outbound TLS,
  and `{job="zeek", log_type="ssl"} | json | ja4 != ""` returns lines in the
  lab's Loki. `capture_loss.log`'s `percent_lost` and `stats.log`'s
  `pkts_dropped` are compared across the week before and the week after. Scripts are slower than the
  plugin, and the lab's traffic is a trickle; that comparison is how the
  trickle stays an assumption checked rather than one made.
  - **The baseline is not zero.** On 2026-10-01, before any JA4, the sensor
    already read 8.1% `percent_lost` (1,624 gaps in 19,940 acks) with
    `pkts_dropped` at 0. So segments are missing upstream of Zeek, not being
    dropped by it. What reopens this decision is a rise over that baseline,
    not the baseline itself. The baseline needs its own explanation.

**Also, in the same change:** `stacks/sensor` gets its Dependabot entry. #437's
stack was added without one, so its `zeek/zeek` and `grafana/alloy` digests
would never have been bumped. That has nothing to do with JA4, except that the
one image this decision leans on is the one that was not being kept current.

### Rejected

- **A derived image building the compiled plugin.** It would be the estate's
  first locally built image. It would need a toolchain stage, and it would sit
  outside the digest pin, the healthcheck probe and Dependabot. Each of those
  would have to learn about `build:`, or the image would drift from its base
  the first time Dependabot bumped `zeek/zeek` and nobody rebuilt it. That is a
  repository-wide policy change, made for a speed-up the lab does not need. It
  is reopened by the measurement above (below).
- **`zkg install` at container start.** What runs would be whatever the
  package index served that morning: unpinned, unreviewed, and needing the
  internet before Zeek can start. That is the state `check_image_pins.py`
  exists to make impossible, reached around it instead of through it.
- **A third-party Zeek image with JA4 built in.** There is no maintained one to
  pin, and trusting it would move the estate's sensor onto someone else's
  build pipeline for one feature.
- **JA4 alone, to stay BSD-only.** It is possible: set every other method off in
  the vendored `config.zeek`. But JA4S (the server's answer to the client's
  hello) is half of what makes a C2 channel recognisable. JA4H and JA4SSH cover
  the protocols an attacker on this segment uses next. The FoxIO License
  permits this use outright; avoiding it would buy nothing but a smaller
  NOTICE.

## Consequences

- **No new tooling, and no change to what CI enforces.** The checks, the image
  and the deploy procedure stay as they are. The stack gains a directory and
  one `@load` line.
- **A licence that is not MIT lives in this repository**, in one directory, and
  says so. A reuse of this repository that monetises the sensor would need
  FoxIO's OEM licence. The NOTICE is where that reader finds out.
- **Upstream fixes arrive only when someone re-vendors.** Nothing alerts on a
  new upstream release.
  - **What the scripts do.** They do not parse packets; Zeek's analysers do. But
    every value they read and hash comes from the wire and is attacker-controlled:
    a ClientHello's extensions, an HTTP request's headers, TCP options, DHCP
    options.
  - **What a bug costs.** A defect in them is a script error or a crash. A crash
    takes the sensor down and Docker restarts it. A script error is an empty
    field.
  - **What would catch it.** `homelab_zeek_mirror_active` would not, since it
    proves the mirror and not Zeek (ADR-0068). A flat stream of Zeek logs in
    the lab's Grafana would.
  - **Why that is acceptable.** For a sensor in a lab, it is. A security fix
    upstream is the case where re-vendoring is urgent rather than routine.
- **Fields land in existing logs** (`ssl.log`, `http.log`, `conn.log`), plus
  `ja4ssh.log` and `ja4d.log`. The Alloy pipeline ships every `*.log` already,
  so the two new streams need no change there.
- **Reopened by:**
  - `capture_loss.log` showing loss the plugin would avoid, after which the
    derived image is worth its policy change;
  - FoxIO archiving `ja4-zeek-scripts`, or its README withdrawing the
    copy-into-site install;
  - this repository, or a fork of it, being used for anything that earns money;
  - a second stack needing a package Zeek's image lacks, after which building
    images is a pattern rather than an exception, and deserves the tooling.
