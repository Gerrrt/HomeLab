# Zeek's site policy for fenrir (#437, ADR-0068).
#
# `local` on the command line loads Zeek's own site/local.zeek first — the
# stock protocol analysers and their default logs — and this file after it.
# What is here is only what differs.

# One JSON object per line, so Alloy ships them without a parser and Loki's
# `| json` reads every field.
redef LogAscii::use_json = T;
redef LogAscii::json_timestamps = JSON::TS_ISO8601;

# Hourly rotation into archive/ beside the current logs. Alloy tails only the
# current *.log; the archive is the local copy for the days the lab's Loki does
# not keep, pruned by build-the-sensor-guest.md's timer.
redef Log::default_rotation_interval = 1 hr;
redef Log::default_rotation_dir = "archive";

# The mirror delivers the guests' frames as their kernels built them, which
# with segmentation offload can be one 64 KiB super-frame rather than forty
# wire-sized ones. The default snaplen would truncate them and every analyser
# past the first segment would see a gap.
redef Pcap::snaplen = 65535;

# The domain: these are Zeek's names for the address space the lab uses, so
# conn.log's local_orig/local_resp mean "ImaginationLAN".
redef Site::local_nets += { 10.0.30.0/24 };

# TLS metadata without decryption — the ground Suricata's "plaintext only"
# limit gives up. SNI, and the certificate subjects and issuers, are in ssl.log
# and x509.log with no help. This adds whether each chain validates against
# the Mozilla roots Zeek ships: a self-signed or unverifiable certificate on a
# lab host's outbound TLS is the shape of a C2 channel.
@load protocols/ssl/validate-certs

# JA4+ fingerprints (ADR-0069, #776): FoxIO's scripts package, vendored at a
# commit into ./ja4 by scripts/vendor-ja4.sh and mounted read-only beside this
# file. It adds ja4 and ja4s to ssl.log, ja4h to http.log, ja4l, ja4ls, ja4t and
# ja4ts to conn.log, and writes ja4ssh.log and ja4d.log. Which methods run is
# set by `@if` in the vendored config.zeek at load time, so a redef here cannot
# change it: everything but JA4X, upstream's default. JA4 is BSD; the rest is
# the FoxIO License 1.1, which ./ja4/NOTICE spells out.
@load ./ja4

# Kerberos tickets per request, so a Kerberoast — many TGS requests for
# service tickets from one client — is a query rather than a hunch.
@load protocols/krb/ticket-logging

# Hashes for every file Zeek reassembles, SMB transfers included.
@load frameworks/files/hash-all-files
