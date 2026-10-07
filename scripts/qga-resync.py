#!/usr/bin/env python3
"""Resynchronise a guest agent that has stopped answering, without touching the guest.

THE FAILURE. On 2026-10-07 `qm agent 140 ping` and `qm agent 190 ping` both
answered "QEMU guest agent is not running", seven seconds apart, while the
other six guests' agents answered. Inside fenrir `qemu-ga` was active and
asleep, and its journal showed why nothing came back. It logged the last
request that worked, and then nothing at all: not the `guest-exec` that timed
out, and not one of the pings after it. It had not hung. It had stopped
recognising requests. Both failures began during the ISO-store verify on
Saruman (19.5 GB, nearly three minutes of CPU). The likely cause is a request
that arrived half-written, which left qemu-ga's JSON parser inside an object
that never closes. Every request after it then reads as more of that object.

THE FIX. qemu-ga's protocol has a way out. A 0xFF byte is invalid JSON, so it
resets the parser. `guest-sync-delimited` then gets an answer with its own
0xFF in front, after any stale reply still in the channel. That is all this
does, and both agents answered `qm agent ping` straight after it. Proxmox's own
sync evidently does not send the byte, so `qm` never recovers by itself. The
alternatives are restarting `qemu-guest-agent` inside the guest, which needs
root there and a way in that is not the agent, or rebooting.

WHAT IT DOES NOT DO. Restart anything, reconnect anything, or run a command in
the guest. After the sync it sends one `guest-ping` on the same connection to
prove the channel carries a fresh request both ways. If either step goes
unanswered within the timeout, it says so and exits non-zero. A guest whose
`qemu-ga` has really died needs what the sync cannot give.

RUN IT ON THE HYPERVISOR, AS ROOT. The sockets are QEMU's, under
/var/run/qemu-server/, and owned by root. One client at a time is served, so a
`qm guest exec` in flight on the same guest holds the socket until it finishes
or times out. Run this after it, not over it.

Usage: scripts/qga-resync.py [--timeout SECONDS] <vmid>...
       scripts/qga-resync.py --self-test
"""

import json
import math
import os
import secrets
import socket
import sys
import time

QGA_DIR = os.environ.get("QGA_DIR", "/var/run/qemu-server")
DEFAULT_TIMEOUT = 10.0
# What the agent sends is the guest's to choose (ADR-0070), and this runs as
# root on the hypervisor. A reply that grows past this without ending is
# refused rather than buffered: collect-guest-disk-state.sh's cap, for its
# reason.
MAX_REPLY = 1024 * 1024


class NoAnswer(Exception):
    pass


def _replies(sock, deadline):
    """Yield each JSON reply from the socket, skipping 0xFF delimiters and anything unparseable."""
    buf = b""
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise NoAnswer("timed out")
        sock.settimeout(remaining)
        try:
            data = sock.recv(65536)
        except TimeoutError:
            raise NoAnswer("timed out") from None
        except OSError as e:
            raise NoAnswer(f"the socket failed: {e}") from None
        if not data:
            raise NoAnswer("the socket closed")
        buf += data.replace(b"\xff", b"")
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            try:
                reply = json.loads(line)
            except ValueError:
                continue
            if isinstance(reply, dict):
                yield reply
        if len(buf) > MAX_REPLY:
            raise NoAnswer(f"a reply passed {MAX_REPLY} bytes without ending, and was refused")


def _await(sock, deadline, want):
    for reply in _replies(sock, deadline):
        if want(reply):
            return reply
    raise NoAnswer("the socket closed")


def _send(sock, request, prefix=b""):
    try:
        sock.sendall(prefix + json.dumps(request).encode() + b"\n")
    except OSError as e:
        raise NoAnswer(f"the socket failed: {e}") from None


def resync(vmid, timeout=DEFAULT_TIMEOUT):
    """Return None when the agent resynchronised and answered a ping, else why not."""
    path = os.path.join(QGA_DIR, f"{vmid}.qga")
    if not os.path.exists(path):
        return f"no {path}: the guest is not running, or has no agent configured"
    sync_id = secrets.randbelow(2**31 - 1) + 1
    deadline = time.monotonic() + timeout
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(timeout)
        try:
            sock.connect(path)
        except OSError as e:
            return f"could not connect to {path}: {e}"
        try:
            _send(sock, {"execute": "guest-sync-delimited", "arguments": {"id": sync_id}}, prefix=b"\xff")
            # A stale reply from before the reset may come first; only ours counts.
            _await(sock, deadline, lambda r: r.get("return") == sync_id)
        except NoAnswer as e:
            return f"no answer to guest-sync-delimited: {e}"
        try:
            _send(sock, {"execute": "guest-ping"})
            reply = _await(sock, deadline, lambda r: "return" in r or "error" in r)
        except NoAnswer as e:
            return f"resynchronised, but no answer to guest-ping: {e}"
        if "error" in reply:
            # The guest's words, so quoted and cut short rather than printed raw.
            return f"resynchronised, but guest-ping failed: {json.dumps(reply['error'])[:200]}"
        return None
    finally:
        sock.close()


def self_test():
    import tempfile
    import threading

    failed = 0

    def check(name, expect, got):
        nonlocal failed
        if got == expect:
            print(f"\033[0;32m  PASS\033[0m {name}")
        else:
            print(f"\033[0;31m  FAIL\033[0m {name}\n       got      {got!r}\n       expected {expect!r}")
            failed = 1

    def fake_agent(path, mode):
        """One connection's worth of qemu-ga, in the state `mode` names."""
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(path)
        srv.listen(1)

        def serve():
            conn, _ = srv.accept()
            conn.settimeout(3)
            buf = b""
            # "wedged": the state found on 2026-10-07, inside an object that
            # never closes, so nothing parses until a 0xFF resets it.
            reset = mode != "wedged"
            try:
                if mode == "flood":
                    # A compromised guest: bytes that never end in a newline.
                    chunk = b"x" * 65536
                    for _ in range(MAX_REPLY // len(chunk) + 2):
                        conn.sendall(chunk)
                if mode == "hangup":
                    # The peer goes away mid-conversation, with a reset.
                    conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, b"\x01\x00\x00\x00\x00\x00\x00\x00")
                    conn.close()
                    return
                if mode == "stale":
                    # A reply to an earlier sync, still in the channel.
                    conn.sendall(b'\xff{"return": 7}\n')
                while True:
                    data = conn.recv(4096)
                    if not data:
                        break
                    if mode == "dead":
                        continue
                    if b"\xff" in data:
                        reset = True
                        conn.sendall(
                            b'{"error": {"class": "GenericError", "desc": "JSON parse error, stray \'\\uFFFD\'"}}\n'
                        )
                        data = data.split(b"\xff")[-1]
                    if not reset:
                        continue
                    buf += data
                    while b"\n" in buf:
                        line, buf = buf.split(b"\n", 1)
                        req = json.loads(line)
                        if req["execute"] == "guest-sync-delimited":
                            conn.sendall(b"\xff" + json.dumps({"return": req["arguments"]["id"]}).encode() + b"\n")
                        elif req["execute"] == "guest-ping" and mode != "no-ping":
                            conn.sendall(b'{"return": {}}\n')
            except OSError:
                pass
            finally:
                conn.close()
                srv.close()

        t = threading.Thread(target=serve, daemon=True)
        t.start()
        return t

    global QGA_DIR
    saved = QGA_DIR
    with tempfile.TemporaryDirectory() as d:
        QGA_DIR = d
        for vmid, mode in ((1, "wedged"), (2, "stale"), (3, "dead"), (4, "no-ping"), (6, "flood"), (7, "hangup")):
            fake_agent(os.path.join(d, f"{vmid}.qga"), mode)
        check("a wedged agent answers after the 0xFF reset", None, resync(1, timeout=2))
        check("a stale reply to an earlier sync is not taken for ours", None, resync(2, timeout=2))
        check(
            "an agent that never answers is reported, not passed",
            "no answer to guest-sync-delimited: timed out",
            resync(3, timeout=0.5),
        )
        check(
            "a sync without a ping is not called recovered",
            "resynchronised, but no answer to guest-ping: timed out",
            resync(4, timeout=0.5),
        )
        check(
            "a guest with no socket says so",
            f"no {os.path.join(d, '5.qga')}: the guest is not running, or has no agent configured",
            resync(5, timeout=0.5),
        )
        check(
            "a reply that never ends is refused at the cap, not buffered",
            f"no answer to guest-sync-delimited: a reply passed {MAX_REPLY} bytes without ending, and was refused",
            resync(6, timeout=5),
        )
        hangup = resync(7, timeout=2)
        check(
            "a peer that hangs up is a reason, not a traceback",
            True,
            hangup is not None and hangup.startswith("no answer to guest-sync-delimited: "),
        )
        for bad in ("0", "-1", "nan", "inf", "x"):
            check(f"--timeout {bad} is refused", None, parse_timeout(bad))
        check("--timeout 2.5 is taken", 2.5, parse_timeout("2.5"))
    QGA_DIR = saved
    return failed


def parse_timeout(text):
    """A finite, positive number of seconds, or None."""
    try:
        value = float(text)
    except ValueError:
        return None
    return value if math.isfinite(value) and value > 0 else None


def main():
    args = sys.argv[1:]
    if "--self-test" in args:
        sys.exit(self_test())
    timeout = DEFAULT_TIMEOUT
    if args[:1] == ["--timeout"] and len(args) >= 2:
        timeout = parse_timeout(args[1])
        if timeout is None:
            sys.exit(__doc__.split("Usage:")[1].strip())
        args = args[2:]
    if not args or not all(a.isdigit() for a in args):
        sys.exit(__doc__.split("Usage:")[1].strip())

    failures = 0
    for vmid in args:
        why = resync(vmid, timeout)
        if why is None:
            print(f"qga-resync vmid={vmid} ok: resynchronised and answered guest-ping")
        else:
            print(f"qga-resync vmid={vmid} FAILED: {why}", file=sys.stderr)
            failures += 1
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
