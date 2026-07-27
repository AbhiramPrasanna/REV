#!/usr/bin/env python3
"""
plot_cache_stress.py -- the CHIME cache-stress "what fits in the node, and when".

Reads a run_cache_stress sweep's summary_compute.csv (client-side throughput +
p99) and draws a 2 x 4 grid: rows = [throughput Mops, p99 us], cols = the four
workloads. Each panel has two lines vs cache size {16,32,64} MB: offload OFF and
offload ON.

The point of the figure is the CACHE-FIT boundary. The whole CHIME index is
~34 MB (the consumed 'index_mb' column saturates at 34 at the 64 MB cap and is
clipped to the cap at 32/16). So:
    * 64 MB  -> the ENTIRE index fits in the compute node's cache.
    * 32 MB, 16 MB -> the index no longer fits; the cache is stressed.
A dashed marker at 34 MB and a shaded "index does not fit" band make that
explicit, so the reader sees exactly when the node stops holding the index and
what that does to throughput/latency with and without offload.

Project convention: every axis STARTS AT 0 and each metric row SHARES one y-scale
across all four workloads, so panels are directly comparable.

Usage:
  python3 plot_cache_stress.py [SUMMARY_COMPUTE_CSV] [--out cache_stress.png]
  (defaults to the newest results/compute/sweep_*/summary_compute.csv)
"""
import argparse, csv, glob, os, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
from matplotlib.patches import Patch

WL_ORDER = ["point-uniform", "point-zipf", "range-uniform", "range-zipf"]
WL_TITLE = {"point-uniform": "point / uniform", "point-zipf": "point / zipf-0.99",
            "range-uniform": "range / uniform", "range-zipf": "range / zipf-0.99"}

# match compare_chime_dart.py: brand-neutral, CVD-aware
C_OFF, C_ON = "#2a78d6", "#1baf7a"          # offload off (blue), on (green)
INK, GRID, MUTED, BAND = "#222222", "#dddddd", "#888888", "#f0a24a"
INDEX_MB = 34.0                              # measured full-index footprint


def newest_default():
    cands = glob.glob(os.path.join(os.path.dirname(__file__),
                                   "compute", "sweep_*", "summary_compute.csv"))
    if not cands:
        sys.exit("no summary_compute.csv found; pass one explicitly")
    return max(cands, key=os.path.getmtime)


def load(csv_path):
    # data[workload][offload] = list of (cache_mb, tput, p99)
    data = {w: {"off": [], "on": []} for w in WL_ORDER}
    with open(csv_path) as f:
        for r in csv.DictReader(f):
            w = r["workload"]
            if w not in data:
                continue
            data[w][r["offload"]].append(
                (float(r["cache_mb"]), float(r["node_tput_mops"]), float(r["p99_us"])))
    for w in data:
        for o in data[w]:
            data[w][o].sort()
    return data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv", nargs="?", default=None)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__),
                                                  "cache_stress.png"))
    args = ap.parse_args()
    csv_path = args.csv or newest_default()
    data = load(csv_path)

    fig, axes = plt.subplots(2, 4, figsize=(15, 7.2), sharex=True)
    fig.suptitle("CHIME under cache stress: throughput & tail latency as the index "
                 "stops fitting in the compute node", fontsize=14, y=0.99)

    # shared per-row limits (start at 0)
    tmax = max(t for w in WL_ORDER for o in ("off", "on") for _, t, _ in data[w][o])
    pmax = max(p for w in WL_ORDER for o in ("off", "on") for _, _, p in data[w][o])

    for col, w in enumerate(WL_ORDER):
        for row, (metric, ymax, ylab) in enumerate(
                [(1, tmax, "throughput (Mops)"), (2, pmax, "p99 latency (us)")]):
            ax = axes[row][col]
            # cache-fit band: left of the index footprint = "does not fit"
            ax.axvspan(0, INDEX_MB, color=BAND, alpha=0.10, zorder=0)
            ax.axvline(INDEX_MB, color=BAND, ls="--", lw=1.3, zorder=1)
            for off, color, lab in [("off", C_OFF, "offload off"),
                                    ("on", C_ON, "offload on")]:
                pts = data[w][off]
                xs = [c for c, _, _ in pts]
                ys = [(t if metric == 1 else p) for c, t, p in pts]
                ax.plot(xs, ys, "-o", color=color, lw=2, ms=7, label=lab, zorder=3)
            ax.set_ylim(0, ymax * 1.12)
            ax.set_xlim(0, 72)
            ax.set_xticks([16, 32, 64])
            ax.grid(True, color=GRID, lw=0.6, zorder=0)
            ax.set_axisbelow(True)
            for s in ("top", "right"):
                ax.spines[s].set_visible(False)
            if row == 0:
                ax.set_title(WL_TITLE[w], fontsize=11, color=INK)
            if col == 0:
                ax.set_ylabel(ylab, fontsize=10)
            if row == 1:
                ax.set_xlabel("compute-node cache (MB)", fontsize=9)

    # one legend for the whole figure
    handles = [Line2D([0], [0], color=C_OFF, lw=2, marker="o", label="offload OFF"),
               Line2D([0], [0], color=C_ON, lw=2, marker="o", label="offload ON"),
               Patch(facecolor=BAND, alpha=0.25,
                     label="index does not fit (< ~34 MB)"),
               Line2D([0], [0], color=BAND, ls="--", lw=1.3,
                      label="full index ~34 MB")]
    fig.legend(handles=handles, loc="lower center", ncol=4, frameon=False,
               fontsize=10, bbox_to_anchor=(0.5, -0.01))
    fig.tight_layout(rect=[0, 0.04, 1, 0.96])
    fig.savefig(args.out, dpi=140, bbox_inches="tight")
    print("wrote", args.out, "from", csv_path)


if __name__ == "__main__":
    main()
