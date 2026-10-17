#!/usr/bin/env python3
"""fair/multi/collect_scaling.py <SCALE_ID> [<SCALE_ID> ...] [--results DIR]

Collects run_scaling.sh: every point fair/results/<SCALE_ID>_c<NCN>m<NMN>/ holds
  dex_multi/dex_multi.csv, chime_multi/chime_multi.csv           (compute side)
  dex_multi/dex_multi_mnload.csv, chime_multi/chime_multi_mnload.csv  (memory side)
The memory side's files are written on server 8: copy its point folders next to
server 6's first (same names, e.g. rsync -a server8:REV/fair/results/sc_cn_c* .),
or the memory-CPU columns stay empty.

Writes fair/results/<SCALE_ID>_scaling.csv (one row per cell, named by the paper's
configuration) and prints throughput across the points for each configuration,
the memory processes' per-thread busy %, and every cell whose answers were not
all correct.
"""
import argparse
import csv
import glob
import os
import re
import sys

POINT_RE = re.compile(r"_c(\d+)m(\d+)$")


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def block_of(r):
    if r["workload"].startswith("range"):
        return "scans"
    u, i, s = (int(float(r.get(k) or 0)) for k in ("update_pct", "insert_pct", "scan_pct"))
    if u or i:
        return "writes"
    if s:
        return "lkscan"
    return "lookups"


def label(kind, r):
    mt = int(float(r["memthreads"]))
    if kind == "dex":
        return "DEX" if mt == 0 else ("DEX+Push" if r["system"] == "dex-r" else "DEX (own push)")
    if mt == 0:
        return "CHIME"
    return "CHIME+Push+Leaf" if r.get("leaf_cache") == "1" else "CHIME+Push"


def read_csv(path):
    if not os.path.exists(path):
        return []
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def collect(sid, root):
    rows = []
    for d in sorted(glob.glob(os.path.join(root, sid + "_c*m*"))):
        m = POINT_RE.search(os.path.basename(d))
        if not m or os.path.basename(d)[: m.start()] != sid:
            continue
        for kind in ("dex", "chime"):
            sub = os.path.join(d, f"{kind}_multi")
            load = {os.path.basename(r["log_prefix"]): r
                    for r in read_csv(os.path.join(sub, f"{kind}_multi_mnload.csv"))}
            for r in read_csv(os.path.join(sub, f"{kind}_multi.csv")):
                ncn, nmn = int(r["ncn"]), int(r["nmn"])
                mt = int(float(r["memthreads"]))
                if kind == "dex":
                    rd, rp = num(r.get("rdma_read_per_op")), num(r.get("rpc_per_op"))
                    rt = None if rd is None and rp is None else (rd or 0) + (rp or 0)
                    ok = r.get("ops_ok_pct_min")
                    chained = sum(int(float(r.get(k) or 0)) for k in ("chained_lookups", "chained_scans", "chained_walks"))
                else:
                    rt = num(r.get("round_trips_per_op"))
                    ok = r.get("lookup_found_pct_min")
                    chained = sum(int(float(r.get(k) or 0)) for k in ("chained_lookups", "chained_scans", "chained_walks"))
                ld = load.get(os.path.basename(r["log_prefix"]), {})
                tput = num(r["tput_mops"])
                rows.append({
                    "scale_id": sid, "ncn": ncn, "nmn": nmn, "clients": int(r["threads"]),
                    "system": label(kind, r), "block": block_of(r), "workload": r["workload"],
                    "cache_mb": int(float(r["cache_mb"])), "workers_per_mn": mt,
                    "workers_total": mt * nmn,
                    "tput_mops": tput,
                    "tput_per_cn_mops": None if tput is None else tput / ncn,
                    "p99_us": num(r.get("p99_us")),
                    "round_trips_per_op": rt,
                    "mn_busy_pct_mean": num(ld.get("util_pct_mean")),
                    "mn_busy_pct_max": num(ld.get("util_pct_max")),
                    "mn_requests_per_s": num(ld.get("msgs_per_s")),
                    "lookups_crossed": r.get("lookups_crossed"),
                    "pushes_carried_on": chained,
                    "correct_pct_min": num(ok),
                    "log_prefix": r["log_prefix"],
                })
    return rows


def fmt(v, nd=2):
    return "-" if v is None else f"{v:.{nd}f}"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("scale_ids", nargs="+")
    ap.add_argument("--results", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "results"))
    a = ap.parse_args()
    root = os.path.abspath(a.results)
    bad = 0
    for sid in a.scale_ids:
        rows = collect(sid, root)
        if not rows:
            print(f"{sid}: no cells under {root}/{sid}_c*m*/", file=sys.stderr)
            bad = 1
            continue
        rows.sort(key=lambda r: (r["block"], r["workload"], r["cache_mb"], r["system"], r["workers_per_mn"], r["ncn"], r["nmn"]))
        out = os.path.join(root, f"{sid}_scaling.csv")
        with open(out, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0]))
            w.writeheader()
            w.writerows(rows)
        print(f"== {sid}: {len(rows)} cells -> {out}")

        axis = "nmn" if len({r["ncn"] for r in rows}) == 1 and len({r["nmn"] for r in rows}) > 1 else "ncn"
        pts = sorted({r[axis] for r in rows})
        print(f"   throughput (Mops) at {axis.upper()} = {' '.join(map(str, pts))};  "
              f"[memory per-thread busy %]")
        groups = {}
        for r in rows:
            groups.setdefault((r["block"], r["workload"], r["cache_mb"], r["system"], r["workers_per_mn"]), {})[r[axis]] = r
        for (blk, wl, c, s, mt), byp in groups.items():
            t = "  ".join(f"{fmt(byp[p]['tput_mops']):>6}" if p in byp else "     -" for p in pts)
            u = " ".join(fmt(byp[p]["mn_busy_pct_mean"], 0) if p in byp else "-" for p in pts)
            print(f"   {blk:8} {wl:14} {c:>4} MB  {s:16} {mt:>2} w/MN | {t} | [{u}]")
        # Read-only cells: every lookup/scan answered (>= 99.99%). Write mixes count an
        # insert of an existing key, or a lookup of a key not inserted yet, as not found,
        # so their share is a property of the workload: a push cell must match the
        # pull-only cell of the same system, point, keys and cache (within 0.5 points).
        def family(r):
            return r["system"].split("+")[0].split(" ")[0]
        pull = {(family(r), r["ncn"], r["nmn"], r["block"], r["workload"], r["cache_mb"]): r
                for r in rows if r["workers_per_mn"] == 0}
        wrong = []
        for r in rows:
            c = r["correct_pct_min"]
            if c is None:
                continue
            if r["block"] in ("lookups", "scans"):
                if c < 99.99:
                    wrong.append((r, "below 99.99%"))
            elif r["workers_per_mn"] > 0:
                base = pull.get((family(r), r["ncn"], r["nmn"], r["block"], r["workload"], r["cache_mb"]))
                if base and base["correct_pct_min"] is not None and abs(c - base["correct_pct_min"]) > 0.5:
                    wrong.append((r, f"pull-only found {base['correct_pct_min']}%"))
        missing = [r for r in rows if r["correct_pct_min"] is None]
        for r, why in wrong:
            print(f"   !! answers {r['correct_pct_min']}% correct ({why}): {r['log_prefix']}")
        if missing:
            print(f"   note: {len(missing)} cells printed no correctness line")
        bad |= bool(wrong)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
