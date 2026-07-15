#!/usr/bin/env python3
"""
Plot CHIME offload ON vs OFF across index-cache size.

Reads a sweep's summary CSVs + per-cell logs and emits a 3x4 grid:
  row 1 = cluster throughput (Mops, higher better)
  row 2 = MEAN latency      (us, lower better)  <- this is what drives throughput
  row 3 = p99 latency       (us, lower better)  <- the tail
  cols  = the four workload cells

Why MEAN matters: throughput ~= threads / MEAN latency (Little's Law), NOT
1/p99. Offload looks paradoxical if you only plot p99 (lower p99 but lower
throughput). The mean explains it -- baseline is bimodal (p50 ~8us on a cache
hit, p99 ~275us on a miss) so its mean is low; offload is uniform (every op is
one RPC, ~57us) so its mean is higher but its tail is far tighter.

Why it merges two CSVs: `cluster throughput` is only printed by node 0, so it
lands in whichever node's CSV happened to register first that round (the roles
can swap between cache points). The total is valid either way, so we take the
non-NA value from whichever file has it. Latencies are parsed from the per-cell
logs (the CSV only carries p99), taken from the compute node by default.

Usage:
  python3 plot_offload.py                       # auto-find the newest complete sweep
  python3 plot_offload.py MEM_CSV COMPUTE_CSV   # explicit
  python3 plot_offload.py ... --out chime.png --p99-from memory

Only needs matplotlib.
"""

import argparse
import csv
import glob
import os
import re
import sys
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# Validated categorical palette (CVD deltaE 73.6, both modes pass).
C_OFF = "#2a78d6"   # blue
C_ON = "#1baf7a"    # aqua
GRID = "#e2e2de"
INK = "#0b0b0b"
MUTED = "#82817c"

WL_ORDER = ["point-uniform", "point-zipf", "range-uniform", "range-zipf"]


def read_summary(path):
    """-> {(cache, workload, offload): {'tput': float|None, 'p99': float|None}}"""
    out = {}
    if not path or not os.path.exists(path):
        return out
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            try:
                cache = int(row["cache_mb"])
            except (ValueError, KeyError, TypeError):
                continue  # skip 'build'/malformed rows

            def num(v):
                try:
                    return float(v)
                except (TypeError, ValueError):
                    return None  # 'NA'

            # new format: per-node exact throughput from micro_test's [RESULT].
            # old format: cluster_tput_mops (only node 0 printed it).
            tp = num(row.get("node_tput_mops"))
            if tp is None:
                tp = num(row.get("cluster_tput_mops"))
            out[(cache, row["workload"], row["offload"])] = {
                "tput": tp,
                "p99": num(row.get("p99_us")),
                "per_node": "node_tput_mops" in row,
            }
    return out


_LAT_RE = {
    "mean": re.compile(r"mean=\s*([0-9.]+)us"),
    "p50": re.compile(r"p50=\s*([0-9.]+)us"),
    "p99": re.compile(r"p99=\s*([0-9.]+)us"),
}


def parse_log_latency(path):
    """Pull mean/p50/p99 from the '[ALL OPS]' -> '  ALL ' row of a micro_test log."""
    if not os.path.exists(path):
        return {}
    try:
        with open(path, errors="replace") as f:
            in_all = False
            for line in f:
                if line.startswith("[ALL OPS]"):
                    in_all = True
                elif in_all and line.startswith("  ALL "):
                    out = {}
                    for k, rx in _LAT_RE.items():
                        m = rx.search(line)
                        if m:
                            out[k] = float(m.group(1))
                    return out
    except OSError:
        pass
    return {}


def latencies_from_logs(sweep_dir, role, caches, wls):
    """-> {(cache, wl, offload): {'mean':..,'p50':..,'p99':..}} from per-cell logs."""
    out = {}
    for c in caches:
        for wl in wls:
            for off in ("off", "on"):
                p = os.path.join(sweep_dir, "cache_%dMB" % c, wl, off, "%s.log" % role)
                d = parse_log_latency(p)
                if d:
                    out[(c, wl, off)] = d
    return out


def autodiscover(base):
    """Newest sweep dir (per role) that has the most cache points."""
    def best(role, fname):
        cands = []
        for d in glob.glob(os.path.join(base, role, "sweep_*")):
            csvp = os.path.join(d, fname)
            if os.path.exists(csvp):
                ncache = len(glob.glob(os.path.join(d, "cache_*")))
                cands.append((ncache, os.path.basename(d), csvp))
        if not cands:
            return None
        cands.sort()  # by cache count, then timestamp
        return cands[-1][2]

    return best("memory", "summary_memory.csv"), best("compute", "summary_compute.csv")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csvs", nargs="*", help="MEMORY_CSV COMPUTE_CSV (optional)")
    ap.add_argument("--out", default="chime_offload.png")
    ap.add_argument("--p99-from", choices=["compute", "memory"], default="compute")
    ap.add_argument("--title", default="CHIME — RPC offload ON vs OFF across index-cache size")
    ap.add_argument("--subtitle", default="2-node RDMA · 50M keys · 50M ops · zipf θ=0.99 · scan range 100")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    if len(args.csvs) == 2:
        mem_csv, cmp_csv = args.csvs
    else:
        mem_csv, cmp_csv = autodiscover(here)
        if not mem_csv or not cmp_csv:
            sys.exit("Could not auto-find sweeps under %s — pass the two CSVs explicitly." % here)
    print("memory  CSV: %s" % mem_csv)
    print("compute CSV: %s" % cmp_csv)

    mem, cmpu = read_summary(mem_csv), read_summary(cmp_csv)

    caches = sorted({k[0] for k in list(mem) + list(cmpu)})
    wls = [w for w in WL_ORDER if any(k[1] == w for k in list(mem) + list(cmpu))]
    if not caches or not wls:
        sys.exit("No usable rows found in the CSVs.")
    print("cache points: %s" % caches)
    print("workloads   : %s" % wls)

    # Latencies come from the per-cell logs (the CSV only carries p99; we need
    # the MEAN, since throughput ~= threads / mean, not 1/p99).
    lat_role = args.p99_from
    lat_dir = os.path.dirname(cmp_csv if lat_role == "compute" else mem_csv)
    lat = latencies_from_logs(lat_dir, lat_role, caches, wls)
    print("latency from: %s logs (%d cells)" % (lat_role, len(lat)))

    # series[wl][metric][offload] = [v per cache]
    series = defaultdict(lambda: defaultdict(dict))
    missing = 0
    for wl in wls:
        for metric in ("tput", "mean", "p99"):
            for off in ("off", "on"):
                vals = []
                for c in caches:
                    if metric == "tput":
                        mv = mem.get((c, wl, off), {})
                        cv = cmpu.get((c, wl, off), {})
                        if mv.get("per_node") or cv.get("per_node"):
                            # new format: each node reports its OWN exact rate ->
                            # cluster total is the SUM of the two.
                            parts = [x.get("tput") for x in (mv, cv)
                                     if x.get("tput") is not None]
                            v = sum(parts) if parts else None
                        else:
                            # old format: only node 0 printed the cluster total
                            v = mv.get("tput") or cv.get("tput")
                    else:
                        v = lat.get((c, wl, off), {}).get(metric)
                        if v is None and metric == "p99":  # fall back to the CSV
                            src = cmpu if lat_role == "compute" else mem
                            v = src.get((c, wl, off), {}).get("p99")
                    if v is None:
                        missing += 1
                    vals.append(v)
                series[wl][metric][off] = vals
    if missing:
        print("note: %d data points missing (plotted as gaps)" % missing)

    # Shared y-scale per metric, starting at 0.
    def top_of(metric):
        vs = [v for wl in wls for off in ("off", "on")
              for v in series[wl][metric][off] if v is not None]
        return max(vs) * 1.08 if vs else 1.0

    tops = {m: top_of(m) for m in ("tput", "mean", "p99")}

    fig, axes = plt.subplots(3, len(wls), figsize=(3.5 * len(wls), 9.4), squeeze=False)
    fig.patch.set_facecolor("white")
    x = list(range(len(caches)))

    rows = [("tput", "Throughput (Mops)  ↑ better"),
            ("mean", "MEAN latency (µs)  ↓ better\n(this drives throughput)"),
            ("p99", "p99 latency (µs)  ↓ better\n(the tail)")]

    for r, (metric, ylab) in enumerate(rows):
        for c, wl in enumerate(wls):
            ax = axes[r][c]
            for off, color, lbl in (("off", C_OFF, "Offload OFF"), ("on", C_ON, "Offload ON")):
                ys = series[wl][metric][off]
                xs = [xi for xi, y in zip(x, ys) if y is not None]
                yy = [y for y in ys if y is not None]
                ax.plot(xs, yy, "-o", color=color, lw=2, ms=6,
                        mec="white", mew=1.5, label=lbl, zorder=3)

            ax.set_ylim(0, tops[metric])              # axes start at 0
            ax.set_xticks(x)
            ax.set_xticklabels([str(cc) for cc in caches])
            ax.set_xlim(-0.25, len(caches) - 0.75)
            ax.grid(axis="y", color=GRID, lw=1, zorder=0)
            ax.set_axisbelow(True)
            for s in ("top", "right"):
                ax.spines[s].set_visible(False)
            for s in ("left", "bottom"):
                ax.spines[s].set_color(GRID)
            ax.tick_params(colors=MUTED, labelsize=9)

            if r == 0:
                ax.set_title(wl, fontsize=11, color=INK, pad=8)
            if r == len(rows) - 1:
                ax.set_xlabel("index cache (MB)", fontsize=9, color=MUTED)
            if c == 0:
                ax.set_ylabel(ylab, fontsize=10, color=INK)

            # avg ratio annotation
            a = [v for v in series[wl][metric]["off"] if v is not None]
            b = [v for v in series[wl][metric]["on"] if v is not None]
            if a and b:
                am, bm = sum(a) / len(a), sum(b) / len(b)
                if metric == "tput":
                    txt = ("OFF %.1f× higher" % (am / bm)) if am >= bm else ("ON %.1f× higher" % (bm / am))
                else:
                    txt = ("OFF %.1f× lower" % (bm / am)) if am <= bm else ("ON %.1f× lower" % (am / bm))
                ax.text(0.03, 0.94, txt, transform=ax.transAxes, fontsize=8.5,
                        color=MUTED, va="top")

    handles, labels = axes[0][0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper right", frameon=False,
               fontsize=10, bbox_to_anchor=(0.995, 0.985))
    fig.suptitle(args.title, fontsize=14, color=INK, x=0.008, ha="left", y=0.985)
    fig.text(0.008, 0.945, args.subtitle, fontsize=9.5, color=MUTED, ha="left")
    fig.tight_layout(rect=[0, 0, 1, 0.925])
    fig.savefig(args.out, dpi=160, facecolor="white")
    print("wrote %s" % args.out)


if __name__ == "__main__":
    main()
