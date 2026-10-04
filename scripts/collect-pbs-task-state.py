#!/usr/bin/env python3
"""What golem's Proxmox Backup Server last did, as metrics the lab can see (#485, ADR-0053).

THE GAP. ADR-0053 and ADR-0027 both say a verify job's outcome has to reach
where the lab already looks, because a verify nobody watches is a green check
with nothing behind it. PBS keeps that outcome to itself: its task log and its
web UI on golem, which nobody opens unless something is already wrong. golem's
Alloy agent ships host metrics and logs, and neither says whether last
Sunday's verify passed. This is where it is answered.

WHAT IT READS. PBS's own job-state API, through `proxmox-backup-debug api get`
as root on golem, so no token or password is involved:

    /admin/verify, /admin/prune, /admin/gc   each job's last run: its state
                                             (`OK`, `WARNINGS: n`, or the
                                             error) and when it ended
    /admin/datastore                         the datastores
    /admin/datastore/<store>/snapshots       every snapshot: its verify state
                                             and its encryption key's
                                             fingerprint

WHAT IT WRITES, to pbs-task-state.prom in the textfile directory:

    homelab_pbs_job_last_run_ok{store, kind, pbs_job}                1 when the last
        run ended `OK`, 0 otherwise. `WARNINGS: n` is 0 on purpose: a verify
        or prune that warned is one to read. Absent for a job that has never
        run, because never having run is not having failed.
    homelab_pbs_job_last_run_end_timestamp_seconds{store, kind, pbs_job}
        When the last run ended; 0 when it never has, so a verify job that
        has never run reads as overdue rather than as absent.
    homelab_pbs_snapshots{store, verify}                         snapshots by
        verify state: `ok`, `failed`, or `none` for never verified. All
        three always, at 0 when empty, so a failure appearing is a value
        changing and not a series being born.
    homelab_pbs_snapshots_unencrypted{store}                     snapshots with
        no key fingerprint. ADR-0053 encrypts every backup on Saruman
        before it leaves, so this is 0 or the job was set up wrong.
    homelab_pbs_snapshot_newest_timestamp_seconds{store}         the newest
        backup's time; 0 for an empty store, which is not one being
        backed up.

`kind` is verify, prune or gc, and `pbs_job` is the job's ID; a garbage
collection's is its store. Not `job`, which Prometheus already uses for the
scrape job and would rename this one away from.

A READING THAT FAILS WRITES NOTHING. Any API call that errors, or answers with
something this cannot parse, leaves the last file in place and exits non-zero,
so the journal says why and PbsTaskStateStale says that the answer stopped.
Writing zeros instead would make "PBS is down" read as "PBS has nothing to
verify".

NO BACKUP CONTENT. Job states, snapshot times, verify states and key
fingerprints. Nothing reads what is inside a backup, and the fingerprint
identifies a key without being one.

Usage: scripts/collect-pbs-task-state.py [--print]
       scripts/collect-pbs-task-state.py --self-test
"""

import json
import os
import socket
import subprocess
import sys

TEXTFILE_DIR = os.environ.get("TEXTFILE_DIR", "/var/lib/node_exporter/textfile_collector")
PROM = os.path.join(TEXTFILE_DIR, "pbs-task-state.prom")
DEBUG = os.environ.get("PBS_DEBUG", "/usr/sbin/proxmox-backup-debug")

KINDS = (("verify", "/admin/verify"), ("prune", "/admin/prune"), ("gc", "/admin/gc"))
VERIFY_STATES = ("ok", "failed", "none")


class ReadError(Exception):
    pass


def api_get(path):
    try:
        out = subprocess.run(
            [DEBUG, "api", "get", path, "--output-format", "json"],
            capture_output=True, text=True, timeout=300, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        raise ReadError(f"{path}: {e}") from e
    if out.returncode != 0:
        raise ReadError(f"{path}: {(out.stderr or out.stdout).strip() or f'exit {out.returncode}'}")
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError as e:
        raise ReadError(f"{path}: not JSON ({e})") from e


def esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def labels(**kv):
    return "{" + ",".join(f'{k}="{esc(v)}"' for k, v in kv.items()) + "}"


def job_rows(kind, entries):
    """One row per job: (store, kind, job, ok-or-None, end).

    A GC's status has no `id`; its job is its store. `ok` is None for a job
    that has never run, which has no `last-run-state` at all.
    """
    if not isinstance(entries, list):
        raise ReadError(f"/admin/{kind}: expected a list")
    rows = []
    for e in entries:
        store = e.get("store")
        if not store:
            raise ReadError(f"/admin/{kind}: an entry with no store")
        job = e.get("id") or store
        state = e.get("last-run-state")
        ok = None if state is None else int(state == "OK")
        end = int(e.get("last-run-endtime") or 0)
        rows.append((store, kind, job, ok, end))
    return rows


def snapshot_summary(snapshots):
    """(counts by verify state, unencrypted count, newest backup time)."""
    if not isinstance(snapshots, list):
        raise ReadError("snapshots: expected a list")
    counts = dict.fromkeys(VERIFY_STATES, 0)
    unencrypted = 0
    newest = 0
    for s in snapshots:
        state = (s.get("verification") or {}).get("state") or "none"
        # Anything PBS adds later counts as not verified OK, which is what it is.
        counts[state if state in counts else "failed"] += 1
        if not s.get("fingerprint"):
            unencrypted += 1
        newest = max(newest, int(s.get("backup-time") or 0))
    return counts, unencrypted, newest


def render(host, jobs, stores):
    """jobs: job_rows output. stores: {store: snapshot_summary output}."""
    out = []

    def metric(name, help_, type_, samples):
        out.append(f"# HELP {name} {help_}")
        out.append(f"# TYPE {name} {type_}")
        out.extend(f"{name}{labels(host=host, **lab)} {val}" for lab, val in samples)

    metric("homelab_pbs_job_last_run_ok",
           "1 when the job's last run ended OK; absent if it has never run.", "gauge",
           [(dict(store=s, kind=k, pbs_job=j), ok) for s, k, j, ok, _ in jobs if ok is not None])
    metric("homelab_pbs_job_last_run_end_timestamp_seconds",
           "When the job's last run ended; 0 if it never has.", "gauge",
           [(dict(store=s, kind=k, pbs_job=j), end) for s, k, j, _, end in jobs])
    metric("homelab_pbs_snapshots",
           "Snapshots in the datastore, by verify state (none is never verified).", "gauge",
           [(dict(store=st, verify=v), c[v]) for st, (c, _, _) in sorted(stores.items()) for v in VERIFY_STATES])
    metric("homelab_pbs_snapshots_unencrypted",
           "Snapshots with no encryption key fingerprint.", "gauge",
           [(dict(store=st), u) for st, (_, u, _) in sorted(stores.items())])
    metric("homelab_pbs_snapshot_newest_timestamp_seconds",
           "The newest snapshot's backup time; 0 for an empty datastore.", "gauge",
           [(dict(store=st), n) for st, (_, _, n) in sorted(stores.items())])
    return "\n".join(out) + "\n"


def collect():
    jobs = []
    for kind, path in KINDS:
        jobs.extend(job_rows(kind, api_get(path)))
    datastores = api_get("/admin/datastore")
    if not isinstance(datastores, list):
        raise ReadError("/admin/datastore: expected a list")
    stores = {}
    for d in datastores:
        store = d.get("store")
        if not store:
            raise ReadError("/admin/datastore: an entry with no store")
        stores[store] = snapshot_summary(api_get(f"/admin/datastore/{store}/snapshots"))
    return jobs, stores


def self_test():
    failed = 0

    def check(name, expect, got):
        nonlocal failed
        if got == expect:
            print(f"\033[0;32m  PASS\033[0m {name}")
        else:
            print(f"\033[0;31m  FAIL\033[0m {name}\n       got      {got!r}\n       expected {expect!r}")
            failed = 1

    # golem's own answers on 2026-10-04, the morning after its first nightly
    # run: the weekly verify had passed all seven snapshots.
    verify = json.loads(
        '[{"id":"weekly","ignore-verified":true,"last-run-endtime":1791110495,"last-run-state":"OK",'
        '"last-run-upid":"UPID:golem:000030B1:000082AF:0000000F:6AC223A0:verificationjob:erebor\\\\x3aweekly:root@pam:",'
        '"next-run":1791712800,"outdated-after":30,"schedule":"sun 03:00","store":"erebor"}]')
    prune = json.loads(
        '[{"id":"daily","keep-daily":7,"keep-monthly":3,"keep-weekly":4,"last-run-endtime":1791097200,'
        '"last-run-state":"OK","last-run-upid":"UPID:golem:000030B1:000082AF:0000000D:6AC1F970:prunejob:erebor:root@pam:",'
        '"next-run":1791183600,"schedule":"daily","store":"erebor"}]')
    # A garbage collection that has never run: no last-run fields, upid null.
    gc_never = json.loads(
        '[{"disk-bytes":0,"disk-chunks":0,"index-data-bytes":0,"index-file-count":0,"next-run":1791626400,'
        '"pending-bytes":0,"pending-chunks":0,"removed-bad":0,"removed-bytes":0,"removed-chunks":0,'
        '"schedule":"sat 03:00","still-bad":0,"store":"erebor","upid":null}]')
    # golem's first garbage collection, run by hand that morning so this
    # fixture is a real answer: it removed nothing, as a first run must not.
    gc_ran = json.loads(
        '[{"cache-stats":{"hits":84482,"misses":52746},"disk-bytes":115363386675,"disk-chunks":52747,'
        '"duration":684,"index-data-bytes":575554027520,"index-file-count":20,"last-run-endtime":1791118715,'
        '"last-run-state":"OK","next-run":1791626400,"pending-bytes":4732488637,"pending-chunks":3180,'
        '"removed-bad":0,"removed-bytes":0,"removed-chunks":0,"schedule":"sat 03:00","still-bad":0,'
        '"store":"erebor","upid":"UPID:golem:000030B1:000082AF:00000010:6AC24ACF:garbage_collection:erebor:root@pam:"}]')
    snap_ok = json.loads(
        '{"backup-id":"152","backup-time":1791087763,"backup-type":"vm","comment":"titan",'
        '"fingerprint":"8d:80:00:ab:90:fc:ea:9a:d6:1a:52:5b:eb:71:d0:e9:d5:dd:d1:85:0e:41:85:51:27:a7:3f:a0:61:b1:a9:50",'
        '"owner":"pve@pbs!saruman","protected":false,"size":85904082241,'
        '"verification":{"state":"ok","upid":"UPID:golem:000030B1:000082AF:0000000F:6AC223A0:verificationjob:erebor\\\\x3aweekly:root@pam:"}}')
    # The same snapshot before Sunday's verify: PBS omits the key entirely.
    snap_new = {k: v for k, v in snap_ok.items() if k != "verification"} | {"backup-time": 1791093000}
    snap_bad = snap_ok | {"verification": {"state": "failed", "upid": "UPID:x"}}
    snap_plain = {k: v for k, v in snap_ok.items() if k != "fingerprint"}

    check("verify job that ran OK", [("erebor", "verify", "weekly", 1, 1791110495)], job_rows("verify", verify))
    check("prune job that ran OK", [("erebor", "prune", "daily", 1, 1791097200)], job_rows("prune", prune))
    check("gc never run: no verdict, end 0, job is the store",
          [("erebor", "gc", "erebor", None, 0)], job_rows("gc", gc_never))
    check("gc that ran OK", [("erebor", "gc", "erebor", 1, 1791118715)], job_rows("gc", gc_ran))
    failed_verify = [verify[0] | {"last-run-state": "verification failed - please check the log for details"}]
    check("verify job that failed", 0, job_rows("verify", failed_verify)[0][3])
    check("a job that warned is not OK", 0, job_rows("prune", [prune[0] | {"last-run-state": "WARNINGS: 1"}])[0][3])
    check("no jobs configured is no rows", [], job_rows("verify", []))
    try:
        job_rows("verify", {"data": []})
        check("an answer that is not a list is refused", "ReadError", "accepted")
    except ReadError:
        check("an answer that is not a list is refused", "ReadError", "ReadError")

    check("verified, encrypted",
          ({"ok": 1, "failed": 0, "none": 0}, 0, 1791087763), snapshot_summary([snap_ok]))
    check("one of each verify state, newest wins",
          ({"ok": 1, "failed": 1, "none": 1}, 0, 1791093000), snapshot_summary([snap_ok, snap_bad, snap_new]))
    check("a snapshot with no fingerprint is unencrypted",
          ({"ok": 1, "failed": 0, "none": 0}, 1, 1791087763), snapshot_summary([snap_plain]))
    check("an unknown verify state counts as not ok",
          ({"ok": 0, "failed": 1, "none": 0}, 0, 1791087763),
          snapshot_summary([snap_ok | {"verification": {"state": "something-new"}}]))
    check("an empty datastore", ({"ok": 0, "failed": 0, "none": 0}, 0, 0), snapshot_summary([]))

    text = render("golem", job_rows("verify", verify) + job_rows("gc", gc_never),
                  {"erebor": snapshot_summary([snap_ok, snap_new])})
    check("a never-run gc has an end time and no ok series",
          (True, False),
          ('homelab_pbs_job_last_run_end_timestamp_seconds{host="golem",store="erebor",kind="gc",pbs_job="erebor"} 0' in text,
           'kind="gc"' in "".join(l for l in text.splitlines() if l.startswith("homelab_pbs_job_last_run_ok"))))
    check("all three verify states are written",
          ['homelab_pbs_snapshots{host="golem",store="erebor",verify="ok"} 1',
           'homelab_pbs_snapshots{host="golem",store="erebor",verify="failed"} 0',
           'homelab_pbs_snapshots{host="golem",store="erebor",verify="none"} 1'],
          [l for l in text.splitlines() if l.startswith("homelab_pbs_snapshots{")])
    check("a label value is escaped", '{host="a\\"b"}', labels(host='a"b'))
    return failed


def main():
    if "--self-test" in sys.argv[1:]:
        sys.exit(self_test())
    print_only = "--print" in sys.argv[1:]
    if [a for a in sys.argv[1:] if a != "--print"]:
        sys.exit(__doc__.split("Usage:")[1].strip())

    host = socket.gethostname().split(".")[0]
    try:
        jobs, stores = collect()
    except ReadError as e:
        sys.exit(f"pbs-task-state: nothing written: {e}")
    text = render(host, jobs, stores)
    if print_only:
        sys.stdout.write(text)
        return

    if not os.path.isdir(TEXTFILE_DIR):
        sys.exit(f"pbs-task-state: no {TEXTFILE_DIR}")
    tmp = f"{PROM}.{os.getpid()}"
    with open(tmp, "w") as f:
        f.write(text)
    os.chmod(tmp, 0o644)
    os.replace(tmp, PROM)

    summary = " ".join(f"{k}:{j}={'never' if ok is None else ('ok' if ok else 'FAILED')}" for _, k, j, ok, _ in jobs)
    snaps = " ".join(f"{st}=ok:{c['ok']}/failed:{c['failed']}/none:{c['none']}/unencrypted:{u}"
                     for st, (c, u, _) in sorted(stores.items()))
    print(f"pbs-task-state host={host} {summary} {snaps}")


if __name__ == "__main__":
    main()
