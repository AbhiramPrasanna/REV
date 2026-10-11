#!/usr/bin/env python3
"""Merge the Lesson 3 sweep (run_lesson3.sh) into fair/results/lesson3_all.csv.

    python3 fair/experiments/collect_lesson3.py
    L3_TAG=l3 L2_CSV=fair/results/lesson2_all.csv python3 fair/experiments/collect_lesson3.py

One row per cell, every system in the same columns:

    system       DEX | DEX+Push | CHIME | CHIME+Push | CHIME+Push+Leaf | DART
    part         a (Lesson 2 tree, 10 levels) | b (DART) | c (node size as shipped)
    op           point (lookups; the sweep runs only lookups)
    nodes        16 (16-entry nodes, the Lesson 2 tree) | shipped (DEX 1 KB, CHIME 64)
    dist, cache_mb, memthreads, tput_mops, p99_us
    round_trips_per_op   network round trips per lookup
    net_bytes_per_op     bytes moved over the network per lookup, both ways
    read_amp             net_bytes_per_op / 16 (one 8 B key + 8 B value)
    mn_busy_cores        memory server cores busy on index work (DART: 0)
    tree_height

How each system's counters become the two network columns:
    DEX    round trips = rdma reads + rpcs per op (+ writes and atomics, 0 for
           lookups); bytes = "rdma read size/ op" (it already includes each
           request) + "rdma write size / op" + rpcs x 33 B, the RawMessage reply
    CHIME  round trips = [RDMA] per_op round_trips; bytes = [RDMA] per_op bytes
           (reads, writes and requests sent) + sends x 41 B, the RawMessage reply
           (CHIME's part a rows come from Lesson 2: L2_CSV, lesson2_all.csv)
    DART   round trips = "avg rtt count" + 1; bytes = "avg bandwidth
           consumption" + 128: the shipped build skips the counters of the
           shortcut-table search, one round trip of 128 B in DART's own DYNAMIC
           path (src/prheart/art-node.cc:136-137)
Bytes the memory server reads in its own memory for a pushed lookup are not
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
L2_CSV = os.environ.get("L2_CSV", os.path.join(RES, "lesson2_all.csv"))
USEFUL_B = 16.0
DEX_REPLY_B = 33     # sizeof(RawMessage), dex/include/RawMessageConnection.h
CHIME_REPLY_B = 41   # sizeof(RawMessage), CHIME/include/RawMessageConnection.h
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


def row(**k):
    b = k.get("net_bytes_per_op")
    k["read_amp"] = round(b / USEFUL_B, 2) if b is not None else None
    return k


def dex_rows():
    out = []
    for comp in sorted(glob.glob(os.path.join(RES, TAG + "_*", "dex", "dex_compute.csv"))):
        d = os.path.dirname(comp)
        block = comp.replace("\\", "/").split("/")[-3]
        part = block[len(TAG) + 1:].split("_")[0]
        mem = {}
        mp = os.path.join(d, "dex_memory.csv")
        if os.path.exists(mp):
            for r in csv.DictReader(open(mp)):
                mem[(r["workload"], r["cache_mb"], r["memthreads"])] = r
        for r in csv.DictReader(open(comp)):
            log = local(r["log"], d)
            t = text(log)
            mt = int(r["memthreads"])
            reads, rpcs = fnum(r["rdma_read_per_op"]), fnum(r["rpc_per_op"])
            wr = last(t, r"Avg\. rdma write / op = ([0-9.eE+-]+)") or 0.0
            cas = last(t, r"Avg\. rdma cas / op = ([0-9.eE+-]+)") or 0.0
            rsz = last(t, r"Avg\. rdma read size/ op = ([0-9.eE+-]+)")
            wsz = last(t, r"Avg\. rdma write size / op = ([0-9.eE+-]+)") or 0.0
            rt = reads + rpcs + wr + cas if reads is not None and rpcs is not None else None
            nb = rsz + wsz + rpcs * DEX_REPLY_B if rsz is not None and rpcs is not None else None
            mlog = local(log[:-len("compute.log")] + "memory.log", d) if log and log.endswith("compute.log") else None
            mean_c, peak_c = mn_cores(mlog)
            if peak_c is None:
                pk = fnum(mem.get((r["workload"], r["cache_mb"], r["memthreads"]), {}).get("mn_peak_active_pct"))
                peak_c = round(pk / 100, 3) if pk is not None else None
            if mt == 0:
                mean_c, peak_c = 0.0, 0.0   # one idle directory thread hands out memory only
            out.append(row(system="DEX+Push" if mt else "DEX", part=part, op=r["workload"].split("-")[0],
                           nodes="shipped" if part == "c" else "16", dist=r["dist"],
                           cache_mb=int(r["cache_mb"]), memthreads=mt,
                           tput_mops=fnum(r["tput_mops"]), p99_us=fnum(r["p99_us"]),
                           round_trips_per_op=rt, net_bytes_per_op=nb,
                           mn_busy_cores=mean_c, mn_busy_cores_peak=peak_c,
                           tree_height=r.get("tree_height"), block=block, log=r["log"]))
    return out


def dart_rows():
    out = []
    for f in sorted(glob.glob(os.path.join(RES, TAG + "_*", "dart", "dart.csv"))):
        d = os.path.dirname(f)
        block = f.replace("\\", "/").split("/")[-3]
        for r in csv.DictReader(open(f)):
            mlog = local(r["log"], d)
            clog = local(r["log"].replace(".monitor.log", ".compute.log"), d)
            t = text(clog)
            ev = rt = bw = 0.0
            for n, a, b in re.findall(r"total event count: ([0-9.eE+-]+) M; avg rtt count: ([0-9.eE+-]+); "
                                      r"avg bandwidth consumption: ([0-9.eE+-]+)", t):
                n = float(n)
                ev += n; rt += n * float(a); bw += n * float(b)
            rtt = rt / ev + DART_RACE_RTT if ev else None
            nb = bw / ev + DART_RACE_B if ev else None
            out.append(row(system="DART", part="b", op=r["workload"].split("-")[0], nodes="DART", dist=r["dist"],
                           cache_mb=int(r["cache_mb"]), memthreads=0,
                           tput_mops=fnum(r["tput_mops"]), p99_us=fnum(r["p99_us"]),
                           round_trips_per_op=rtt, net_bytes_per_op=nb,
                           mn_busy_cores=0.0, mn_busy_cores_peak=0.0, tree_height="",
                           block=block, log=r["log"] if mlog else r["log"]))
    return out


def chime_rows(path, part, nodes):
    out = []
    if not os.path.exists(path):
        print(f"note: {path} not found, no CHIME rows for part {part}")
        return out
    for r in csv.DictReader(open(path)):
        if r.get("workload", "").split("-")[0] != "point":
            continue
        block = r["block"]
        if part == "a":
            if "_a_stock" in block:
                arm = "stock"
            elif "_a_2p" in block:
                arm = "2p"
            else:
                continue           # shipped (hotspot on) is not a Lesson 3 arm
        else:
            arm = "stock"
        mt = int(r["memthreads"])
        system = "CHIME+Push+Leaf" if arm == "2p" else ("CHIME+Push" if mt else "CHIME")
        rt = fnum(r.get("rdma_round_trips_per_op"))
        b, s = fnum(r.get("rdma_bytes_per_op")), fnum(r.get("rdma_requests_per_op"))
        nb = b + (s or 0.0) * CHIME_REPLY_B if b is not None else None
        out.append(row(system=system, part=part, op="point", nodes=nodes,
                       dist="uniform" if r["workload"].endswith("uniform") else "zipf",
                       cache_mb=int(float(r["cache_mb"])), memthreads=mt,
                       tput_mops=fnum(r.get("node_tput_mops")), p99_us=fnum(r.get("p99_us")),
                       round_trips_per_op=rt, net_bytes_per_op=nb,
                       mn_busy_cores=fnum(r.get("mn_busy_cores")) if mt else 0.0,
                       mn_busy_cores_peak=fnum(r.get("mn_busy_cores_peak")) if mt else 0.0,
                       tree_height=r.get("tree_height"), block=block, log=r.get("log", "")))
    return out


def main():
    rows = dex_rows() + dart_rows() + chime_rows(L2_CSV, "a", "16")
    # part c CHIME blocks are in Lesson 2's format: let its collector parse them
    if glob.glob(os.path.join(RES, TAG + "_c_chime", "chime", "sweep_mt*", "summary_compute.csv")):
        env = dict(os.environ, L2_TAG=TAG, L2_OUT="lesson3_chime.csv", L2_LEVELS_OUT="lesson3_chime_levels.csv")
        subprocess.run([sys.executable, os.path.join(HERE, "collect_lesson2.py")], env=env, check=False)
        rows += chime_rows(os.path.join(RES, "lesson3_chime.csv"), "c", "shipped")
    if not rows:
        print("no Lesson 3 results under", RES)
        return
    keys = list(rows[0].keys())
    dst = os.path.join(RES, "lesson3_all.csv")
    with open(dst, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {dst}: {len(rows)} cells")
    # quick look: lookups per system at the smallest and largest cache, against DART
    dart = {}
    for r in rows:
        if r["system"] == "DART" and r["op"] == "point" and r["tput_mops"] is not None:
            dart.setdefault(r["dist"], []).append(r["tput_mops"])
    for dist in ("uniform", "zipf"):
        ref = sum(dart[dist]) / len(dart[dist]) if dart.get(dist) else None
        print(f"\n{dist} lookups, Lesson 2 tree (16-entry nodes); DART = {ref and round(ref, 2)} Mops")
        print(f"  {'system':16} {'cache':>5} {'thr':>3} {'Mops':>6} {'xDART':>6} {'p99':>6} {'trips':>6} {'bytes':>7} {'amp':>6} {'cores':>5}")
        for r in sorted((r for r in rows if r["dist"] == dist and r["op"] == "point" and r["part"] in ("a", "b")),
                        key=lambda r: (r["system"], r["cache_mb"], r["memthreads"])):
            if r["system"] != "DART" and r["cache_mb"] not in (8, 128, 1024):
                continue
            if r["system"] in ("DEX+Push", "CHIME+Push", "CHIME+Push+Leaf") and r["memthreads"] not in (8, 16):
                continue
            x = r["tput_mops"] / ref if ref and r["tput_mops"] else None
            f = lambda v, p=2: "" if v is None else f"{v:.{p}f}"
            print(f"  {r['system']:16} {r['cache_mb']:>5} {r['memthreads']:>3} {f(r['tput_mops']):>6} {f(x):>6} "
                  f"{f(r['p99_us'], 0):>6} {f(r['round_trips_per_op']):>6} {f(r['net_bytes_per_op'], 0):>7} "
                  f"{f(r['read_amp'], 1):>6} {f(r['mn_busy_cores'], 1):>5}")


if __name__ == "__main__":
    main()
