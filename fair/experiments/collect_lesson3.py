#!/usr/bin/env python3
"""Merge the Lesson 3 sweep (run_lesson3.sh, DART's configuration) into
fair/results/lesson3_all.csv.

    python3 fair/experiments/collect_lesson3.py
    L3_TAG=l3smoke python3 fair/experiments/collect_lesson3.py

One row per cell, every system in the same columns:

    system       DART | DEX | DEX (own push) | DEX+Push | CHIME | CHIME+Push |
                 CHIME+Push+Leaf
    part, ycsb   a = YCSB C (lookups) | b = YCSB A (50% updates)
    dist, cache_mb, memthreads, tput_mops, p99_us
    round_trips_per_op   network round trips per operation
    net_bytes_per_op     bytes moved over the network per operation, both ways
    value_bytes          value size the binary ran with
    read_amp             net_bytes_per_op / (8 B key + value_bytes)
    mn_busy_cores        memory server cores busy on index work (DART: 0)
    tree_height

How each system's counters become the two network columns:
    DEX    round trips = rdma reads + writes + atomics + rpcs per op; bytes =
           "rdma read size/ op" (it already includes each request) + "rdma write
           size / op" + rpcs x the RawMessage reply (33 B + value_bytes - 8)
    CHIME  round trips = [RDMA] per_op round_trips; bytes = [RDMA] per_op bytes
           (reads, writes and requests sent) + sends x the RawMessage reply
           (41 B + value_bytes - 8)
    DART   round trips = "avg rtt count" + 1; bytes = "avg bandwidth
           consumption" + 128: the shipped build skips the counters of the
           shortcut-table search, one round trip of 128 B in DART's own DYNAMIC
           path (src/prheart/art-node.cc:136-137)
Bytes the memory server reads in its own memory for a pushed operation are not
network bytes and are not in net_bytes_per_op.
"""
import csv
import glob
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(os.path.dirname(HERE), "results")
TAG = os.environ.get("L3_TAG", "l3")
VALUE_B = int(os.environ.get("L3_VALUE_B", "64"))   # used when a log does not say
KEY_B = 8
DEX_MSG_B = 33       # sizeof(RawMessage) with 8 B values, dex/include/RawMessageConnection.h
CHIME_MSG_B = 41     # sizeof(RawMessage) with 8 B values, CHIME/include/RawMessageConnection.h
DART_RACE_RTT, DART_RACE_B = 1, 128
ANSI = re.compile(r"\x1B\[[0-9;?]*[A-Za-z]")


def fnum(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def local(path, near=None):
    """A log path recorded on the server, mapped into this checkout."""
    if path and os.path.exists(path):
        return path
    p = (path or "").replace("\\", "/")
    i = p.find("fair/results/")
    if i >= 0:
        q = os.path.join(RES, p[i + len("fair/results/"):])
        if os.path.exists(q):
            return q
    if near and path:
        q = os.path.join(near, os.path.basename(p))
        if os.path.exists(q):
            return q
    return None


def text(path):
    return ANSI.sub("", open(path, errors="replace").read()) if path else ""


def last(t, pat):
    m = re.findall(pat, t)
    return float(m[-1]) if m else None


def mn_cores(mlog):
    """mean and peak memory server cores busy, from DEX/CHIME 'AGGREGATE active' lines"""
    if not mlog:
        return None, None
    agg = [(float(a), int(b)) for a, b in re.findall(
        r"AGGREGATE active = ([0-9.]+)% \(of \d+ dir-threads;[^)]*\)\s+msgs=(\d+)", text(mlog))]
    busy = [a for a, m in agg if m > 1000]
    if busy:
        return round(sum(busy) / len(busy) / 100, 3), round(max(busy) / 100, 3)
    return (0.0, round(max(a for a, _ in agg) / 100, 3)) if agg else (None, None)


def block_part(block):
    """('a'|'b', name) from '<tag>_<part>_<name>'"""
    rest = block[len(TAG) + 1:]
    return rest.split("_")[0], rest.split("_", 1)[1] if "_" in rest else ""


def row(**k):
    b, v = k.get("net_bytes_per_op"), k.get("value_bytes") or VALUE_B
    k["read_amp"] = round(b / (KEY_B + v), 2) if b is not None else None
    k["ycsb"] = "C" if k["part"] == "a" else "A"
    return k


def dex_rows():
    out = []
    for comp in sorted(glob.glob(os.path.join(RES, TAG + "_*", "dex", "dex_compute.csv"))):
        d = os.path.dirname(comp)
        block = comp.replace("\\", "/").split("/")[-3]
        part, name = block_part(block)
        for r in csv.DictReader(open(comp)):
            log = local(r["log"], d)
            t = text(log)
            mt = int(r["memthreads"])
            vb = last(t, r"\[GEOMETRY\].*?value_bytes=(\d+)")
            vb = int(vb) if vb else VALUE_B
            reads, rpcs = fnum(r["rdma_read_per_op"]), fnum(r["rpc_per_op"])
            wr = last(t, r"Avg\. rdma write / op = ([0-9.eE+-]+)") or 0.0
            cas = last(t, r"Avg\. rdma cas / op = ([0-9.eE+-]+)") or 0.0
            rsz = last(t, r"Avg\. rdma read size/ op = ([0-9.eE+-]+)")
            wsz = last(t, r"Avg\. rdma write size / op = ([0-9.eE+-]+)") or 0.0
            rt = reads + rpcs + wr + cas if reads is not None and rpcs is not None else None
            reply = DEX_MSG_B + max(0, vb - 8)
            nb = rsz + wsz + rpcs * reply if rsz is not None and rpcs is not None else None
            mlog = local(log[:-len("compute.log")] + "memory.log", d) if log and log.endswith("compute.log") else None
            mean_c, peak_c = mn_cores(mlog)
            if mt == 0:
                mean_c, peak_c = 0.0, 0.0   # one idle directory thread hands out memory only
                system = "DEX"
            else:
                system = "DEX (own push)" if name == "dexown" else "DEX+Push"
            out.append(row(system=system, part=part, dist=r["dist"],
                           cache_mb=int(r["cache_mb"]), memthreads=mt,
                           tput_mops=fnum(r["tput_mops"]), p99_us=fnum(r["p99_us"]),
                           round_trips_per_op=rt, net_bytes_per_op=nb, value_bytes=vb,
                           mn_busy_cores=mean_c, mn_busy_cores_peak=peak_c,
                           tree_height=r.get("tree_height"), block=block, log=r["log"]))
    return out


def dart_rows():
    out = []
    for f in sorted(glob.glob(os.path.join(RES, TAG + "_*", "dart", "dart.csv"))):
        d = os.path.dirname(f)
        block = f.replace("\\", "/").split("/")[-3]
        part, _ = block_part(block)
        for r in csv.DictReader(open(f)):
            clog = local(r["log"].replace(".monitor.log", ".compute.log"), d)
            t = text(clog)
            ev = rt = bw = 0.0
            for n, a, b in re.findall(r"total event count: ([0-9.eE+-]+) M; avg rtt count: ([0-9.eE+-]+); "
                                      r"avg bandwidth consumption: ([0-9.eE+-]+)", t):
                n = float(n)
                ev += n; rt += n * float(a); bw += n * float(b)
            out.append(row(system="DART", part=part, dist=r["dist"],
                           cache_mb=int(r["cache_mb"]), memthreads=0,
                           tput_mops=fnum(r["tput_mops"]), p99_us=fnum(r["p99_us"]),
                           round_trips_per_op=rt / ev + DART_RACE_RTT if ev else None,
                           net_bytes_per_op=bw / ev + DART_RACE_B if ev else None,
                           value_bytes=VALUE_B, mn_busy_cores=0.0, mn_busy_cores_peak=0.0,
                           tree_height="", block=block, log=r["log"]))
    return out


def chime_rows():
    """CHIME blocks are in Lesson 2's format: its collector parses them."""
    if not glob.glob(os.path.join(RES, TAG + "_*", "chime", "sweep_mt*", "summary_compute.csv")):
        return []
    env = dict(os.environ, L2_TAG=TAG, L2_OUT="lesson3_chime.csv", L2_LEVELS_OUT="lesson3_chime_levels.csv")
    subprocess.run([sys.executable, os.path.join(HERE, "collect_lesson2.py")], env=env, check=False)
    path = os.path.join(RES, "lesson3_chime.csv")
    out = []
    if not os.path.exists(path):
        return out
    for r in csv.DictReader(open(path)):
        block = r["block"]
        part, name = block_part(block)
        mt = int(r["memthreads"])
        if name.startswith("leaf"):
            system = "CHIME+Push+Leaf"
        else:
            system = "CHIME+Push" if mt else "CHIME"
        log = local(r.get("log", ""))
        vb = last(text(log), r"\[GEOMETRY\] leaf\s*: span=\d+ val=(\d+)B") if log else None
        vb = int(vb) if vb else VALUE_B
        rt = fnum(r.get("rdma_round_trips_per_op"))
        b, s = fnum(r.get("rdma_bytes_per_op")), fnum(r.get("rdma_requests_per_op"))
        nb = b + (s or 0.0) * (CHIME_MSG_B + max(0, vb - 8)) if b is not None else None
        out.append(row(system=system, part=part,
                       dist="uniform" if r["workload"].endswith("uniform") else "zipf",
                       cache_mb=int(float(r["cache_mb"])), memthreads=mt,
                       tput_mops=fnum(r.get("node_tput_mops")), p99_us=fnum(r.get("p99_us")),
                       round_trips_per_op=rt, net_bytes_per_op=nb, value_bytes=vb,
                       mn_busy_cores=fnum(r.get("mn_busy_cores")) if mt else 0.0,
                       mn_busy_cores_peak=fnum(r.get("mn_busy_cores_peak")) if mt else 0.0,
                       tree_height=r.get("tree_height"), block=block, log=r.get("log", "")))
    return out


def main():
    rows = dart_rows() + dex_rows() + chime_rows()
    if not rows:
        print("no %s_* results under %s" % (TAG, RES))
        return
    keys = []
    for r in rows:
        for k in r:
            if k not in keys:
                keys.append(k)
    dst = os.path.join(RES, "lesson3_all.csv")
    with open(dst, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {dst}: {len(rows)} cells")
    f = lambda v, p=2: "" if v is None else f"{v:.{p}f}"
    for part, dists in (("a", ("zipf", "uniform")), ("b", ("zipf",))):
        for dist in dists:
            sel = [r for r in rows if r["part"] == part and r["dist"] == dist]
            if not sel:
                continue
            dart = [r["tput_mops"] for r in sel if r["system"] == "DART" and r["tput_mops"]]
            ref = sum(dart) / len(dart) if dart else None
            print(f"\nYCSB {'C' if part == 'a' else 'A'}, {dist}: DART = {f(ref)} Mops")
            print(f"  {'system':16} {'cache':>5} {'thr':>3} {'Mops':>6} {'xDART':>6} {'p99':>6} "
                  f"{'trips':>6} {'bytes':>7} {'amp':>6} {'cores':>5}")
            for r in sorted(sel, key=lambda r: (r["system"], r["cache_mb"], r["memthreads"])):
                x = r["tput_mops"] / ref if ref and r["tput_mops"] else None
                print(f"  {r['system']:16} {r['cache_mb']:>5} {r['memthreads']:>3} {f(r['tput_mops']):>6} "
                      f"{f(x):>6} {f(r['p99_us'], 0):>6} {f(r['round_trips_per_op']):>6} "
                      f"{f(r['net_bytes_per_op'], 0):>7} {f(r['read_amp'], 1):>6} {f(r['mn_busy_cores'], 1):>5}")


if __name__ == "__main__":
    main()
