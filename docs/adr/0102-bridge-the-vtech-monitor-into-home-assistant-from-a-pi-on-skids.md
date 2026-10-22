# ADR-0102: Bridge the VTech monitor into Home Assistant from a Pi on Skids

**Status:** Accepted · 2026-10

## Context

The household's rule is that Home Assistant is where everything is seen and
controlled. The VTech RM7764HD baby monitor (`monitor-01`, the camera, and
`monitor-02`, its parent unit, both on Skids in `network.md`) is the one
camera in the house Home Assistant cannot show: every other camera is Ring,
and Ring's cloud integration already carries their pictures there. It is the
one device on Skids that neither a vendor cloud integration nor a local API
can reach. [#1248](https://github.com/Gerrrt/HomeLab/issues/1248) carries the
work and records what was found on 2026-10-22; this ADR records the decision.

The camera speaks ThroughTek's TUTK/Kalay peer-to-peer protocol with an
X25519 and ChaCha20-Poly1305 layer VTech added above the SDK. It serves no
RTSP and no ONVIF, and VTech has told a customer in writing that it cannot.
The official path is the *MyVTech Baby Pro* app, which reaches the camera
either on the LAN or through ThroughTek's relay servers. Home Assistant has no
integration for it, core or custom, for this app generation.

One community project reaches it anyway.
[JonGilmore/vtech-baby-pro-bridge](https://github.com/JonGilmore/vtech-baby-pro-bridge)
reimplements VTech's layer in C, loads ThroughTek's Android libraries from
the operator's own copy of the app inside a bionic chroot, and hands the
decrypted H.264 and G.711 to go2rtc, which republishes it as RTSP and WebRTC.
At runtime it talks to nothing but the camera. It was built on an RM5766,
this unit's 5-inch sibling from the same app generation; the layer it
reimplements belongs to the app, not to the model, so it should carry over.
No report of it on an RM7764HD exists. Two facts about it shape everything
below:

1. **It must share the camera's broadcast domain.** TUTK finds the camera
   with a UDP broadcast, and broadcasts do not cross `morpheus`. So the
   bridge runs on Skids, or it connects by relay through the internet, which
   is the cloud path this decision exists to avoid.
2. **Its credentials come out of a rooted phone, once.** The app's TUTK
   license key and the camera's channel password are decrypted at runtime
   under DexGuard, which defeats Frida and Xposed. The project captures them
   with a kernel uprobe on a rooted Android phone while the app runs. The
   phone is needed for an afternoon and not again.

The estate has neither an arm64 host on Skids nor a phone that may be rooted.
Both are purchases.

## Decision

**Run the bridge on a Raspberry Pi on Skids, named `heimdall`, and read its
restream from `trinity` over one host-scoped row. Control stays where it was:
nothing on Skids initiates upward, including the Pi.**

| On interface | Rule | Position | Purpose |
| --- | --- | --- | --- |
| 99 | `10.0.99.40 → 10.0.20.30:8554/tcp` | **above** *Block access to Skids*, beside ADR-0035's and ADR-0099's rows | Home Assistant reads the RTSP restream |
| 99 | `10.0.99.20 → 10.0.20.30:9100/tcp` | same | `prometheus` scrapes the Pi like any host |
| 99 | `10.0.99.40 → 10.0.20.30:22/tcp` | same | The operator maintains the Pi from `trinity` |

1. **`heimdall` is a Skids device and is treated as one.** A Raspberry Pi 4
   or 5 running Debian, Docker and the bridge, with a Kea reservation at
   `10.0.20.30`, below the pool and beside `bifrost` and the HomePods. It is
   named for the watchman at the end of `bifrost`, who sees and hears across
   the realms. It initiates to the camera on its own segment and to nothing
   above it; it needs no internet at runtime and gets none beyond what Skids
   already has. The #223 tripwire must still read zero with it running.
2. **Home Assistant reads it as a `generic` camera over RTSP, on demand.**
   Home Assistant's own go2rtc opens the source when a dashboard shows it and
   closes it after; nothing is preloaded or recorded. This is one camera on
   one row, read when looked at. It is not the continuous RTSP from every
   camera that [ADR-0032](0032-decline-frigate-while-the-cameras-are-ring.md)
   declined with Frigate, and it does not reopen that decision: the cameras
   are still Ring, there is still no accelerator, and ADR-0008's table gains
   no continuous row.
3. **The restream is not open to the segment, and the hop is not private
   from it either.** go2rtc's RTSP listener requires a username and password,
   its API port binds to the Pi's loopback, and nothing else on the Pi
   listens on Skids but SSH and node_exporter. Without that, every device on
   Skids could connect and watch the room the camera watches, which is wider
   than the camera itself allows today. What the credential does not do is
   encrypt the hop. RTSP from the Pi to `trinity` crosses Skids in the clear,
   so a Skids device that has already been compromised and can put itself in
   the path, by ARP spoofing the Pi or the gateway, can read the picture and
   the sound for as long as Home Assistant has the stream open. That is
   accepted here, as a residual and not a property: it needs an active
   attacker already inside the segment, it is bounded by point 2 to the
   minutes a dashboard is showing the camera, and it is the same interception
   the parent unit's own link is open to on the same segment. What retires
   it is an encrypted transport that verifies the peer, and #1248 tries the
   one go2rtc offers before settling for RTSP: its API served over TLS with
   a leaf from the tier's CA, read by Home Assistant's own go2rtc over
   WebRTC, whose media is DTLS-SRTP. If that path works from `trinity`, the
   `8554/tcp` row becomes the TLS port instead and this point gets a note.
   If it does not, the residual stands as written.
4. **Four secrets, each in `secrets/*.sops.yaml` and in exactly the places
   that use it.** The TUTK license key and the camera's UID and channel
   password are the camera's: they are recorded in the repository's secrets
   so the Pi can be rebuilt, rendered onto the Pi by hand, and held nowhere
   else. go2rtc's restream credential is shared by design: it is on the Pi,
   and in Home Assistant's configuration on `trinity`, rendered from the
   same secrets the way the rest of the tier's are. ThroughTek's four
   libraries are not secrets but are not redistributable; they live on the
   Pi and are extracted again from the app on a rebuild. None of the five
   touches a tracked file.
5. **A used Pixel is bought for the extraction, rooted, used, and wiped.**
   It signs into the household's VTech account for the afternoon the capture
   takes, is signed out and factory-reset after, and is not a household
   phone before or afterwards. Rooting a phone the household carries is not
   on the table.
6. **The extraction is the gate.** Nothing else in #1248 is built, and the
   Pi is not ordered, until the three values come out of the phone and the
   bridge, run once on any arm64 box or the phone's own chroot, decodes a
   frame from this camera. If this model's layer differs from the RM5766's,
   that is where it shows, and the decision stops there with one used phone
   bought.
7. **The rows are not created by this ADR.** #1248 creates them after the
   reservation, in the order the issue lists. Until then, `network.md`'s
   Winterfell and Skids notes carry them as decided.

## Alternatives considered

- **[Kasoo/vtech_baby](https://github.com/Kasoo/vtech_baby), a Home Assistant
  custom integration.** Local, no root, and richer: alerts, temperature, the
  night light. Tested only on the RM5754HD, an older app generation whose
  opcodes and secrets its README expects to differ. It also wants Home
  Assistant on the camera's broadcast domain, which is the next alternative.
  Declined for this model; noted for any VTech of that generation.
- **A leg for Home Assistant on Skids**, by a macvlan interface or host
  networking. It puts the tier's most capable container on the segment whose
  stated assumption is that everything on it may be compromised, and
  `stacks/sensitive/README.md` already argues against host networking for
  this container. Declined.
- **The bridge on `trinity`.** Not on Skids, so no broadcast discovery; the
  only alternative is TUTK's relay, which is the cloud path. The chroot is
  also built for arm64. Declined.
- **Replace the monitor with an RTSP camera.** A hardware and privacy
  decision of its own, and the one ADR-0032 names as the thing that reopens
  Frigate. The monitor works and the household likes its parent unit. Declined.
- **Nothing.** The monitor stays out of Home Assistant. Rejected because the
  household asked for it, and the cost is a Pi, a used phone and a weekend,
  with the first afternoon deciding whether the rest is spent.

## Consequences

- **A general-purpose computer joins Skids for the first time.** Every other
  device there is an appliance with a vendor's firmware. The Pi runs Debian
  and Docker and is the operator's to patch, which is why it is scraped and
  reachable by SSH from `trinity`, and why both of those are rows of their
  own rather than a wider pass. A compromised `heimdall` is a compromised
  Skids device: it can reach everything on the segment, including the camera
  whose credentials it holds, and nothing above it.
- **An unreviewed native bridge holds the camera's credentials.** The
  project is one author's reverse-engineering work, loaded with proprietary
  libraries nobody here can audit. It is accepted because it runs on the
  segment already assumed compromised, talks to nothing but the camera, and
  the credentials it holds open nothing but this camera. The commit it is
  built from is pinned in the Pi's build notes, and a rebuild is from that
  commit, not from `main`.
- **Skids stays terminal outward.** The three rows are `trinity` and
  `prometheus` initiating; replies ride on state. The #223 tripwire keeps its
  meaning.
- **The picture of one room travels to Winterfell on demand** and is shown
  by Home Assistant to whoever is signed in. Home Assistant's users are the
  household; this is the same trust the Ring cameras' snapshots already carry
  there. Nothing is recorded on `trinity`. On its way it crosses Skids
  unencrypted unless point 3's TLS path works, and a compromised Skids
  device in the path can read it while it flows. The credential keeps the
  idle stream closed to the segment; it does not keep an open one private.
- **Two purchases and one new host**, through *Everything still to buy* and
  then `hardware.md` and `network.md`, with the Pi's address kept true by its
  reservation.
- **Reopened by:** VTech or Home Assistant shipping a supported local path,
  which retires the bridge; the bridge failing to decode this model, which
  closes #1248 with the finding and a used phone; or the household replacing
  the monitor, which makes this ADR moot and reopens ADR-0032's question
  instead.
