#!/usr/bin/env python3
r"""
Figures for the REV paper.

    python3 paper/make_figures.py

Writes vector PDFs into paper/figures/, which is on the paper's \graphicspath.

Every number here is measured. Sources:
    CHIME/results/leafstudy2_compute.csv   CHIME lever sweep, 34 thr/node, 16 B values,
                                           50 M keys, 30 M ops, scan 100, compute node
    dex/build/results/summary.csv          DEX sweep, 32 compute / 4 memory threads,
                                           50 M keys, scan 100
    CHIME/results/RANGE_SCANS.md           CHIME leaf-cache first cut (pre-repair)

Palette is Okabe-Ito, chosen because it passes the colorblind-separation and
chroma checks in the dataviz validator and prints legibly in grayscale.
"""

import csv
import os
import collections

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
from matplotlib.patches import Patch

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(HERE, "figures")
os.makedirs(OUT, exist_ok=True)

# --- validated categorical palette (Okabe-Ito) ------------------------------
C_CACHE = "#0072B2"   # caching lever alone
C_OFF   = "#D55E00"   # + memory-side offload
C_LEAF  = "#CC79A7"   # + leaf caching
C_BOTH  = "#009E73"   # both levers
INK     = "#1a1a1a"
INK2    = "#5a5a5a"
MUTED   = "#8a8a8a"
GRID    = "#dcdcdc"

plt.rcParams.update({
    "font.family": "serif",
    "font.serif": ["Times New Roman", "DejaVu Serif"],
    "font.size": 8,
    "axes.labelsize": 8,
    "axes.titlesize": 8.5,
    "xtick.labelsize": 7.5,
    "ytick.labelsize": 7.5,
    "legend.fontsize": 7.5,
    "axes.edgecolor": INK2,
    "axes.linewidth": 0.6,
    "xtick.color": INK2,
    "ytick.color": INK2,
    "text.color": INK,
    "axes.labelcolor": INK,
    "pdf.fonttype": 42,
    "figure.dpi": 200,
})


def tidy(ax):
    """Recessive axes: no top/right spine, light horizontal grid behind marks."""
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.yaxis.grid(True, color=GRID, linewidth=0.5)
    ax.set_axisbelow(True)


WORKLOADS = ["point-uniform", "point-zipf", "range-uniform", "range-zipf"]
NICE = {"point-uniform": "Point, uniform", "point-zipf": "Point, zipf 0.99",
        "range-uniform": "Range, uniform", "range-zipf": "Range, zipf 0.99"}


# ===========================================================================
# Figure 1 -- the CHIME lever map.
# Throughput against INNER cache, which is what the caching lever actually
# spends. Re-indexing by inner (rather than total) is what makes the two leaf
# arms commensurable: a leaf-on cell at 128 MB total and a leaf-off cell at
# 64 MB total both run a 64 MB inner cache and land within 2% of each other.
# ===========================================================================
def fig_lever_map():
    rows = list(csv.DictReader(open(os.path.join(ROOT, "CHIME/results/leafstudy2_compute.csv"))))
    by = collections.defaultdict(dict)
    for r in rows:
        lever = ("leaf" if r["cache_leaf"] == "1" else "noleaf") + "/" + r["offload"]
        by[(r["workload"], int(r["inner_cache_mb"]))][lever] = float(r["node_tput_mops"])

    series = [("noleaf/off", "cache only",   C_CACHE, "o", "-"),
              ("noleaf/on",  "+ offload",    C_OFF,   "s", "-"),
              ("leaf/off",   "+ leaf cache", C_LEAF,  "^", "--"),
              ("leaf/on",    "both levers",  C_BOTH,  "D", "-")]

    fig, axes = plt.subplots(2, 2, figsize=(7.0, 4.3), sharex=True)
    for ax, w in zip(axes.flat, WORKLOADS):
        tidy(ax)
        # The fit boundary: the internal index is ~90-100 MB at this geometry,
        # so inner >= 128 MB holds it and inner <= 64 MB does not.
        ax.axvspan(80, 110, color=MUTED, alpha=0.16, lw=0, zorder=0)
        for key, label, colour, marker, ls in series:
            xs, ys = [], []
            for inner in [32, 64, 128, 256, 512]:
                d = by.get((w, inner))
                if d and key in d:
                    xs.append(inner); ys.append(d[key])
            if xs:
                ax.plot(xs, ys, ls, color=colour, marker=marker, markersize=3.4,
                        linewidth=1.4, label=label, clip_on=False, zorder=3)
        ax.set_xscale("log", base=2)
        ax.set_xticks([32, 64, 128, 256, 512])
        ax.set_xticklabels(["32", "64", "128", "256", "512"])
        ax.set_xlim(28, 580)
        ax.set_ylim(bottom=0)
        ax.set_title(NICE[w], loc="left", color=INK)

    for ax in axes[:, 0]:
        ax.set_ylabel("Throughput (Mops)")
    for ax in axes[1, :]:
        ax.set_xlabel("Inner-node cache (MB)")

    # The band is a legend entry rather than an in-plot label: at this size any
    # rotated annotation lands on top of the series it is meant to explain.
    handles = [Line2D([], [], color=c, marker=m, linestyle=ls, markersize=3.4,
                      linewidth=1.4, label=lab) for _, lab, c, m, ls in series]
    handles.append(Patch(facecolor=MUTED, alpha=0.16, label="index stops fitting"))
    fig.legend(handles=handles, loc="upper center", ncol=5, frameon=False,
               bbox_to_anchor=(0.5, 1.005))
    fig.tight_layout(rect=[0, 0, 1, 0.945])
    fig.savefig(os.path.join(OUT, "fig_lever_map.pdf"))
    plt.close(fig)
    print("wrote fig_lever_map.pdf")


# ===========================================================================
# Figure 2 -- DEX: the caching lever is dead under uniform.
# With offload on, an RPC fires exactly when the cache could not resolve the
# leaf, so rpc_per_op reads out how often the caching lever failed. The two
# uniform rows are flat across an 8x cache sweep.
# ===========================================================================
def fig_dex_rpc():
    rows = list(csv.DictReader(open(os.path.join(ROOT, "dex/build/results/summary.csv"))))
    caches = [64, 128, 256, 512]
    # dy nudges the direct label off its endpoint: "Point, uniform" ends at 1.00
    # and "Range, zipf" at 0.95, so without a nudge the two labels collide.
    spec = [("range", "uniform",  "Range, uniform",  C_OFF,   "s", "-",  0),
            ("range", "zipfian",  "Range, zipf",     C_LEAF,  "^", "--", -7),
            ("lookup", "uniform", "Point, uniform",  C_CACHE, "o", "-",  4),
            ("lookup", "zipfian", "Point, zipf",     C_BOTH,  "D", "--", 0)]

    fig, ax = plt.subplots(figsize=(3.33, 2.45))
    tidy(ax)
    for w, d, label, colour, marker, ls, dy in spec:
        ys = [float([r for r in rows if r["workload"] == w and r["dist"] == d
                     and r["offload"] == "on" and int(r["cache_mb"]) == c][0]["rpc_per_op"])
              for c in caches]
        ax.plot(caches, ys, ls, color=colour, marker=marker, markersize=3.4,
                linewidth=1.4, clip_on=False, zorder=3)
        # Direct labels rather than a legend box: four series, and the flat
        # ones are the point of the figure.
        ax.annotate(label, xy=(caches[-1], ys[-1]), xytext=(4, dy),
                    textcoords="offset points", va="center", fontsize=7,
                    color=colour)

    ax.set_xscale("log", base=2)
    ax.set_xticks(caches)
    ax.set_xticklabels(["64", "128", "256", "512"])
    ax.set_xlim(60, 560)
    ax.set_ylim(0, 1.55)
    ax.set_xlabel("Compute-side cache (MB)")
    ax.set_ylabel("RPCs per operation")
    fig.tight_layout(rect=[0, 0, 0.72, 1])
    fig.savefig(os.path.join(OUT, "fig_dex_rpc.pdf"))
    plt.close(fig)
    print("wrote fig_dex_rpc.pdf")


# ===========================================================================
# Figure 3 -- DEX: network crossings per operation, one lever versus two.
# Crossings = RDMA reads + RPCs. This is the mechanism behind Figure 2's
# throughput: the offload lever removes a roughly constant FRACTION of
# crossings at every cache size, and what differs across workloads is the
# absolute remainder the caching lever left behind.
# ===========================================================================
def fig_dex_crossings():
    rows = list(csv.DictReader(open(os.path.join(ROOT, "dex/build/results/summary.csv"))))
    caches = [64, 128, 256, 512]

    def crossings(w, d, off, c):
        r = [x for x in rows if x["workload"] == w and x["dist"] == d
             and x["offload"] == off and int(x["cache_mb"]) == c][0]
        return float(r["rdma_read_per_op"]) + float(r["rpc_per_op"])

    spec = [("lookup", "uniform"), ("lookup", "zipfian"),
            ("range", "uniform"), ("range", "zipfian")]
    titles = ["Point, uniform", "Point, zipf 0.99", "Range, uniform", "Range, zipf 0.99"]

    fig, axes = plt.subplots(1, 4, figsize=(7.0, 1.95))
    for ax, (w, d), t in zip(axes, spec, titles):
        tidy(ax)
        ax.plot(caches, [crossings(w, d, "off", c) for c in caches], "-",
                color=C_CACHE, marker="o", markersize=3.4, linewidth=1.4,
                label="cache only", clip_on=False, zorder=3)
        ax.plot(caches, [crossings(w, d, "on", c) for c in caches], "-",
                color=C_BOTH, marker="D", markersize=3.4, linewidth=1.4,
                label="both levers", clip_on=False, zorder=3)
        ax.set_xscale("log", base=2)
        ax.set_xticks(caches)
        ax.set_xticklabels(["64", "128", "256", "512"])
        ax.set_xlim(60, 545)
        ax.set_ylim(bottom=0)
        ax.set_title(t, loc="left", color=INK)
        ax.set_xlabel("Cache (MB)")
    axes[0].set_ylabel("Crossings per op")

    handles = [Line2D([], [], color=C_CACHE, marker="o", markersize=3.4,
                      linewidth=1.4, label="cache only"),
               Line2D([], [], color=C_BOTH, marker="D", markersize=3.4,
                      linewidth=1.4, label="both levers")]
    fig.legend(handles=handles, loc="upper center", ncol=2, frameon=False,
               bbox_to_anchor=(0.5, 1.02))
    fig.tight_layout(rect=[0, 0, 1, 0.88])
    fig.savefig(os.path.join(OUT, "fig_dex_crossings.pdf"))
    plt.close(fig)
    print("wrote fig_dex_crossings.pdf")


# ===========================================================================
# Figure 4 -- CHIME: the falsification test and its repair.
# The first cut of the leaf cache shrank each covered leaf's transfer roughly
# 40x while leaving the crossing COUNT unchanged, and lost throughput. Batching
# the covered set into two doorbells removes the crossings instead, and the
# zipf arm flips from a regression to a gain.
# First-cut numbers: CHIME/results/RANGE_SCANS.md (sweep leafstudy).
# Batched numbers:   leafstudy2, leaf_1 / offload off.
# ===========================================================================
def fig_scan_repair():
    # Stock and batched come from leafstudy2; the first-cut arm comes from the
    # earlier leafstudy sweep, whose own stock baseline measured 0.496/0.500,
    # within 0.8% of these. Both deltas are therefore quoted against the stock
    # bar shown, and the first-cut delta is accurate to well under a point.
    cells = [("Range, uniform\n512 MB", 0.4999, 0.293, 0.3947),
             ("Range, uniform\n256 MB", 0.4957, 0.279, 0.3845),
             ("Range, zipf\n512 MB",    0.4999, 0.423, 0.5940),
             ("Range, zipf\n256 MB",    0.4999, 0.408, 0.5713)]

    fig, ax = plt.subplots(figsize=(3.33, 2.5))
    tidy(ax)
    w = 0.26
    xs = range(len(cells))
    base = [c[1] for c in cells]
    first = [c[2] for c in cells]
    batch = [c[3] for c in cells]

    # 2px surface gap between adjacent bars comes from the width/offset choice.
    ax.bar([x - w for x in xs], base, w * 0.92, color=C_CACHE, label="stock CHIME", zorder=3)
    ax.bar(list(xs), first, w * 0.92, color=C_LEAF, label="leaf cache, first cut", zorder=3)
    ax.bar([x + w for x in xs], batch, w * 0.92, color=C_BOTH, label="leaf cache, batched", zorder=3)

    for x, b, f, t in zip(xs, base, first, batch):
        ax.annotate(f"{100*(f-b)/b:+.0f}%", xy=(x, f), xytext=(0, 2),
                    textcoords="offset points", ha="center", fontsize=6.4, color=C_LEAF)
        ax.annotate(f"{100*(t-b)/b:+.0f}%", xy=(x + w, t), xytext=(0, 2),
                    textcoords="offset points", ha="center", fontsize=6.4, color=C_BOTH)

    ax.set_xticks(list(xs))
    ax.set_xticklabels([c[0] for c in cells], fontsize=6.8)
    ax.set_ylabel("Throughput (Mops)")
    ax.set_ylim(0, 0.72)
    ax.legend(frameon=False, loc="upper left", fontsize=6.8, handlelength=1.2)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "fig_scan_repair.pdf"))
    plt.close(fig)
    print("wrote fig_scan_repair.pdf")


if __name__ == "__main__":
    fig_lever_map()
    fig_dex_rpc()
    fig_dex_crossings()
    fig_scan_repair()
    print("figures ->", OUT)
