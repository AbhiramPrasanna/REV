#!/usr/bin/env python3
"""
collect_dxt_sweep.py -- merge the run_dxt_sweep.sh blocks into one CSV.

    python3 fair/experiments/collect_dxt_sweep.py

Reads fair/results/dxt_*/ and dxtr_*/dex/dex_compute.csv (and dex_memory.csv when the
memory server's results have been copied or pushed next to them), plus each
cell's compute log for mean latency and, in the 50/50 mix, the lookup and scan
latencies separately. Writes fair/results/dxt_sweep_all.csv, one row per cell:

    rule           stock (DEX's bottom-four-level rule) or deepest (DEX-R)
    variant        Base (0 memory threads), PLk / PSc (push on a miss), Mix
                   (the 50/50 workload with push on a miss); PAll means push
                   everything and is not a block of this sweep
    inner_share    share of the inner nodes the cache can hold
                   (3,846,104 inner nodes x 512 B = 1,878 MiB; capped at 1)
"""
import csv
import glob
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(os.path.dirname(HERE), "results")
OUT = os.path.join(RES, "dxt_sweep_all.csv")
INNER_MIB = 1878.0
TREE_MIB = 3756.0


def variant(wl, mt):
    # PAll means push everything (every operation to the memory node); the
    # 50/50 mix with push on a miss is not PAll, it is "Mix".
    if int(mt) == 0:
        return "Base"
    return {"point": "PLk", "range": "PSc", "mixed": "Mix"}[wl.split("-")[0]]


SEC = re.compile(r"^\[(LOOKUP|RANGE|ALL OPS)\]")
ALL = re.compile(r"^\s*ALL\s+n=\s*(\d+)\s+mean=\s*([0-9.]+)us.*p99=\s*([0-9.]+)us")


def log_latency(path):
    """{'LOOKUP': (n, mean, p99), 'RANGE': ..., 'ALL OPS': ...} from the last report."""
    out, cur = {}, None
    try:
        with open(path, errors="replace") as f:
            for line in f:
                m = SEC.match(line)
                if m:
                    cur = m.group(1)
                    continue
                m = ALL.match(line)
                if m and cur:
                    out[cur] = (int(m.group(1)), float(m.group(2)), float(m.group(3)))
                    cur = None
    except OSError:
        pass
    return out


def main():
    rows = []
    for comp in sorted(glob.glob(os.path.join(RES, "dxt*_*", "dex", "dex_compute.csv"))):
        block = comp.split(os.sep)[-3]
        rule = "deepest" if block.startswith("dxtr_") else "stock"
        mem = {}
        mpath = os.path.join(os.path.dirname(comp), "dex_memory.csv")
        if os.path.exists(mpath):
            for r in csv.DictReader(open(mpath)):
                mem[(r["workload"], r["cache_mb"], r["memthreads"])] = r
        for r in csv.DictReader(open(comp)):
            wl, c, mt = r["workload"], r["cache_mb"], r["memthreads"]
            lat = log_latency(r["log"])
            m = mem.get((wl, c, mt), {})
            cache = float(c)
            row = {
                "block": block, "workload": wl, "op": wl.split("-")[0], "dist": r["dist"],
                "cache_mb": c, "memthreads": mt, "rule": rule, "variant": variant(wl, mt),
                "inner_share": round(min(1.0, cache / INNER_MIB), 4),
                "whole_tree_fits": "yes" if cache >= 1.3 * TREE_MIB else "no",
                "tput_mops": r["tput_mops"], "p99_us": r["p99_us"],
                "mean_us": lat.get("ALL OPS", (0, "NA", "NA"))[1],
                "reads_per_op": r["rdma_read_per_op"], "requests_per_op": r["rpc_per_op"],
                "lookup_mean_us": lat.get("LOOKUP", (0, "NA", "NA"))[1],
                "lookup_p99_us": lat.get("LOOKUP", (0, "NA", "NA"))[2],
                "scan_mean_us": lat.get("RANGE", (0, "NA", "NA"))[1],
                "scan_p99_us": lat.get("RANGE", (0, "NA", "NA"))[2],
                "mn_peak_busy_pct": m.get("mn_peak_active_pct", "NA"),
                "cache_full_before_measure": r.get("cache_full_before_measure", "NA"),
                "tree_height": r["tree_height"], "inner_nodes": r.get("inner_nodes", "NA"),
                "cache_slots": r.get("cache_slots", "NA"), "log": r["log"],
            }
            rows.append(row)
    if not rows:
        print("no fair/results/dxt_*/dex/dex_compute.csv found")
        return
    with open(OUT, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {OUT}: {len(rows)} cells")
    # quick look: Base against push, uniform lookups and scans
    for op in ("point", "range", "mixed"):
        sel = [x for x in rows if x["op"] == op and x["dist"] == "uniform" and x["rule"] == "stock"]
        if not sel:
            continue
        print(f"\n{op}-uniform  Mops by cache (MB) and memory threads")
        caches = sorted({int(x["cache_mb"]) for x in sel})
        mts = sorted({int(x["memthreads"]) for x in sel})
        print("cache " + " ".join(f"{m:>6}" for m in mts))
        for c in caches:
            cell = {int(x["memthreads"]): x["tput_mops"] for x in sel if int(x["cache_mb"]) == c}
            print(f"{c:>5} " + " ".join(f"{cell.get(m, ''):>6}"[:6] for m in mts))


if __name__ == "__main__":
    main()
