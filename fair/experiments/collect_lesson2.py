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
        for r in csv.DictReader(open(mf)):
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
    split = [r for r in rows if r.get("total_cache_mb") not in ("", "NA") and r.get("inner_cache_mb") not in ("", "NA")
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
