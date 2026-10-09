#!/usr/bin/env python3
"""Merge every Lesson 2 block (run_lesson2.sh) into fair/results/lesson2_all.csv.

    python3 fair/experiments/collect_lesson2.py

Reads fair/results/l2_manifest.csv (what each block ran) and every
fair/results/l2_*/chime/sweep_mt<k>/summary_compute.csv (one row per cell), and
adds, from each cell's compute log:
    index_hit_pct      index-cache hit rate        ([READPATH] line)
    leaf_rtt_per_lookup estimated leaf round trips per lookup ([READPATH])
    push_ops_cfg       CHIME_PUSH_OPS as the binary saw it ([CONFIG] line)
    scan_always_cfg    CHIME_SCAN_OFFLOAD_ALWAYS as the binary saw it
    remote_per_op      network operations per operation (reporter, if printed)
    lookup_pushdowns, scan_pushdowns   pushed operations (reporter, if printed)
    lookup_found_pct, scan_rows        correctness lines
    inner_hit_pct, leaf_hit_pct        inner nodes against leaves ([KIND], CHIME_LEVEL_STATS=1)
    scan_* columns                     scan leaf hits and reads ([SCANLEAF])
    lat_mean/p50/p90/p99/p999_us       latency spread over all operations
    rdma_*_per_op                      round trips, reads, writes, atomics, pushed
                                       requests, verbs and bytes ([RDMA], CHIME_RDMA_STATS=1)
    ops_offload_pct, leaves/kv_per_scan_pushdown   pushed work
    mn_busy_cores, mn_busy_cores_peak  memory server CPU spent on pushed requests,
                                       from memory.log next to compute.log (server 8)
and writes fair/results/lesson2_levels.csv: one row per cell and tree level
([LEVEL] lines; level 0 = leaf), the same counts DEX's per-level runs give.
Logs are found by their path relative to fair/results, so results copied from
the servers work as well.
"""
import csv
import glob
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(os.path.dirname(HERE), "results")


def rx(text, pat, cast=float):
    m = re.search(pat, text)
    return cast(m.group(1)) if m else ""


def local_log(path):
    """The log path recorded on the server, mapped into this checkout."""
    if os.path.exists(path):
        return path
    i = path.replace("\\", "/").find("fair/results/")
    if i >= 0:
        p = os.path.join(RES, path.replace("\\", "/")[i + len("fair/results/"):])
        if os.path.exists(p):
            return p
    return None


def main():
    man = {}
    mf = os.path.join(RES, "l2_manifest.csv")
    if os.path.exists(mf):
        # arm names may hold commas (written unquoted by the first runs): the first two
        # and the last seven fields are fixed, the arm is whatever lies between
        cols = ["leaf_pct", "push_ops", "scan_always", "theta", "workloads", "caches", "memthreads"]
        for line in open(mf).read().splitlines()[1:]:
            f = next(csv.reader([line])) if line.count('"') >= 2 else line.split(",")
            if len(f) < 10:
                continue
            r = {"block": f[0], "part": f[1], "arm": ",".join(f[2:-7]).strip().strip('"')}
            r.update(dict(zip(cols, f[-7:])))
            man[r["block"]] = r
    rows, levels = [], []
    for csvf in sorted(glob.glob(os.path.join(RES, "l2_*", "chime", "sweep_mt*", "summary_compute.csv"))):
        parts = csvf.replace("\\", "/").split("/")
        block = parts[-4]
        mt = int(re.search(r"sweep_mt(\d+)", parts[-2]).group(1))
        meta = man.get(block, {})
        for r in csv.DictReader(open(csvf)):
            out = {"block": block, "part": meta.get("part", block.split("_")[1] if "_" in block else ""),
                   "arm": meta.get("arm", ""), "leaf_pct": meta.get("leaf_pct", ""),
                   "push_ops": meta.get("push_ops", ""), "scan_always": meta.get("scan_always", ""),
                   "theta": meta.get("theta", ""), "memthreads": mt,
                   "push": "on" if mt > 0 else "off"}
            out.update(r)
            log = local_log(r.get("log", ""))
            t = open(log, errors="replace").read() if log else ""
            out["index_hit_pct"] = rx(t, r"index-cache hit=([0-9.]+)%")
            out["leaf_rtt_per_lookup"] = rx(t, r"est\. leaf round trips/lookup=([0-9.]+)")
            out["push_ops_cfg"] = rx(t, r"push ops: (\w+)", str)
            out["scan_always_cfg"] = rx(t, r"offload_always=(\d)", int)
            out["hotspot_cfg"] = rx(t, r"hotspot buffer \+ speculative read: (on|off)", str)
            out["remote_per_op"] = rx(t, r"remote ops / op\s*=\s*([0-9.]+)")
            out["lookup_pushdowns"] = rx(t, r"lookup pushdowns\s*=\s*(\d+)", int)
            out["scan_pushdowns"] = rx(t, r"scan\s+pushdowns \(RPC\)\s*=\s*(\d+)", int)
            out["lookup_found_pct"] = rx(t, r"lookup found \d+ / \d+ = ([0-9.]+)%")
            out["scan_rows"] = rx(t, r"scan rows returned = (\d+)", int)
            # CHIME_LEVEL_STATS=1: inner nodes against leaves (lookups), and scans
            out["inner_hit_pct"] = rx(t, r"\[KIND node \d+\].*?inner_hit_pct=([0-9.]+)")
            out["leaf_hit_pct"] = rx(t, r"\[KIND node \d+\].*?leaf_hit_pct=([0-9.]+)")
            out["scan_inner_complete_miss"] = rx(t, r"\[SCANLEAF node \d+\].*?inner_complete_miss=(\d+)", int)
            out["scan_inner_partial"] = rx(t, r"\[SCANLEAF node \d+\].*?inner_partial=(\d+)", int)
            out["scan_leaf_cache_hits"] = rx(t, r"\[SCANLEAF node \d+\].*?leaf_cache_hits=(\d+)", int)
            out["scan_leaf_reads"] = rx(t, r"\[SCANLEAF node \d+\].*?leaf_reads=(\d+)", int)
            out["scan_cn_leaves_per_scan"] = rx(t, r"\[SCANLEAF node \d+\].*?cn_leaves_per_scan=([0-9.]+)")
            out["scan_leaf_hit_pct"] = rx(t, r"\[SCANLEAF node \d+\].*?leaf_hit_pct=([0-9.]+)")
            # latency spread, all operations ([ALL OPS] ALL row of the reporter)
            lat = re.search(r"\[ALL OPS\][\s\S]*?\n\s+ALL\s+n=\d+\s+mean=\s*([0-9.]+)us\s+p50=\s*([0-9.]+)us\s+"
                            r"p90=\s*([0-9.]+)us\s+p99=\s*([0-9.]+)us\s+p99\.9=\s*([0-9.]+)us", t)
            for k_, i_ in (("lat_mean_us", 1), ("lat_p50_us", 2), ("lat_p90_us", 3),
                           ("lat_p99_us", 4), ("lat_p999_us", 5)):
                out[k_] = float(lat.group(i_)) if lat else ""
            # CHIME_RDMA_STATS=1: what each operation sent over the network
            for k_, pat in (("rdma_round_trips_per_op", r"per_op: round_trips=([0-9.]+)"),
                            ("rdma_reads_per_op", r"per_op:.*?reads=([0-9.]+)"),
                            ("rdma_writes_per_op", r"per_op:.*?writes=([0-9.]+)"),
                            ("rdma_atomics_per_op", r"per_op:.*?atomics=([0-9.]+)"),
                            ("rdma_requests_per_op", r"per_op:.*?sends=([0-9.]+)"),
                            ("rdma_verbs_per_op", r"per_op:.*?verbs=([0-9.]+)"),
                            ("rdma_bytes_per_op", r"per_op:.*?bytes=([0-9.]+)")):
                out[k_] = rx(t, r"\[RDMA node \d+\] " + pat)
            # pushed work (OFFLOADED TASKS block of the reporter)
            out["ops_offload_pct"] = rx(t, r"ops offload \(rpc\)\s*=\s*\d+ \(([0-9.]+)%\)")
            out["leaves_per_scan_pushdown"] = rx(t, r"leaves / scan pushdown\s*=\s*([0-9.]+)")
            out["kv_per_scan_pushdown"] = rx(t, r"kv / scan pushdown\s*=\s*([0-9.]+)")
            # memory server CPU: the push threads' busy time, from the memory log (server 8)
            mlog = log[:-len("compute.log")] + "memory.log" if log and log.endswith("compute.log") else None
            out["mn_busy_cores"], out["mn_busy_cores_peak"], out["mn_log_found"] = "", "", 0
            if mlog and os.path.exists(mlog):
                agg = [(float(a), int(b)) for a, b in re.findall(
                    r"AGGREGATE active = ([0-9.]+)% \(of \d+ dir-threads;[^)]*\)\s+msgs=(\d+)",
                    open(mlog, errors="replace").read())]
                busy = [a for a, m in agg if m > 1000]       # reports while requests were arriving
                out["mn_log_found"] = 1
                if busy:
                    out["mn_busy_cores"] = round(sum(busy) / len(busy) / 100.0, 3)
                    out["mn_busy_cores_peak"] = round(max(busy) / 100.0, 3)
                elif agg:   # push on but almost nothing was pushed (the cache answered): idle
                    out["mn_busy_cores"] = 0.0
                    out["mn_busy_cores_peak"] = round(max(a for a, _ in agg) / 100.0, 3)
            out["log_found"] = 1 if log else 0
            rows.append(out)
            for lv, h, m in re.findall(r"\[LEVEL\] level=(\d+) hits=(\d+) misses=(\d+)", t):
                h, m = int(h), int(m)
                levels.append({"block": block, "part": out["part"], "arm": out["arm"],
                               "leaf_pct": out["leaf_pct"], "push": out["push"], "memthreads": mt,
                               "theta": out["theta"], "workload": r.get("workload", ""),
                               "cache_mb": r.get("cache_mb", ""), "level": int(lv), "hits": h,
                               "misses": m, "hit_pct": round(100.0 * h / max(1, h + m), 3)})
    if not rows:
        print("no l2_* results under", RES)
        return
    keys = []
    for r in rows:
        for k in r:
            if k not in keys:
                keys.append(k)
    dst = os.path.join(RES, "lesson2_all.csv")
    with open(dst, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        w.writerows(rows)
    # quick checks: the binary must have run what the block asked for
    bad = [r for r in rows if r["log_found"] and r["push_ops_cfg"] and r["push_ops"]
           and r["push_ops_cfg"] != r["push_ops"]]
    num = lambda x: x not in (None, "", "NA")
    split = [r for r in rows if num(r.get("total_cache_mb")) and num(r.get("inner_cache_mb"))
             and int(r["inner_cache_mb"]) + int(r.get("leaf_cache_mb") or 0) != int(r["total_cache_mb"])]
    print(f"wrote {dst}: {len(rows)} cells from {len({r['block'] for r in rows})} blocks")
    if levels:
        lv = os.path.join(RES, "lesson2_levels.csv")
        with open(lv, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(levels[0].keys()))
            w.writeheader()
            w.writerows(levels)
        print(f"wrote {lv}: {len(levels)} level rows (per tree level, lookups; level 0 = leaf)")
    else:
        print("no [LEVEL] lines found (CHIME_LEVEL_STATS was off, or the build predates it)")
    if bad:
        print(f"WARNING: {len(bad)} cells ran a different CHIME_PUSH_OPS than their block asked for")
    if split:
        print(f"WARNING: {len(split)} cells where inner + leaf cache != total")


if __name__ == "__main__":
    main()
