#!/usr/bin/env python3
"""
fair/plot_dex_fair.py -- paper figures for the DEX fair sweep.

    python3 fair/plot_dex_fair.py fair/results/fair3            # reads dex/dex_compute.csv
    python3 fair/plot_dex_fair.py path/to/dex_compute.csv --out figs
    python3 fair/plot_dex_fair.py fair/results/fair3 --one-scale

Writes (PDF for the paper, PNG at 300 dpi for slides and notes):
    dex_point.{pdf,png}    point lookups: throughput vs memory threads, one line per cache size
    dex_range.{pdf,png}    range scans:   same layout
    dex_speedup.{pdf,png}  best offloaded throughput / throughput with offloading off, vs cache size

Every y axis starts at 0. The uniform and Zipfian panels of a figure share one
scale; --one-scale also puts the point and range figures on the same scale.
Only the standard library and matplotlib are needed.
"""
import argparse
import csv
import math
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import MultipleLocator, NullLocator

CACHES = [32, 64, 128, 256, 512, 1024]
MEMTHREADS = list(range(9))
DISTS = [("uniform", "Uniform"), ("zipf", "Zipfian")]
MARKERS = ["o", "s", "^", "v", "D", "P"]

plt.rcParams.update({
    "font.family": "serif",
    "font.serif": ["Times New Roman", "Times", "Nimbus Roman", "Liberation Serif", "DejaVu Serif"],
    "mathtext.fontset": "stix",
    "font.size": 8,
    "axes.labelsize": 8,
    "xtick.labelsize": 7,
    "ytick.labelsize": 7,
    "legend.fontsize": 7,
    "axes.linewidth": 0.6,
    "xtick.direction": "in",
    "ytick.direction": "in",
    "xtick.top": True,
    "ytick.right": True,
    "xtick.major.width": 0.6,
    "ytick.major.width": 0.6,
    "xtick.major.size": 3,
    "ytick.major.size": 3,
    "lines.linewidth": 1.0,
    "lines.markersize": 3.5,
    "savefig.dpi": 300,
    "pdf.fonttype": 42,          # embed TrueType, so the PDF passes conference checks
    "ps.fonttype": 42,
})


def load(path):
    """{(workload, cache_mb, memthreads): Mops}; a later row for the same cell wins."""
    if os.path.isdir(path):
        path = os.path.join(path, "dex", "dex_compute.csv")
    if not os.path.exists(path):
        sys.exit(f"no such file: {path}")
    data = {}
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            try:
                cell = (r["workload"], int(r["cache_mb"]), int(r["memthreads"]))
            except (KeyError, ValueError):
                continue          # malformed row
            try:
                data[cell] = float(r["tput_mops"])
            except ValueError:
                # The latest run of this cell failed (NA): drop any older value
                # rather than plot a result the rerun did not reproduce (same
                # rule as collect.py: the last row for a cell wins).
                data.pop(cell, None)
    if not data:
        sys.exit(f"no usable rows in {path}")
    return data


def nice_ceiling(v):
    """Round up to a round number (1, 1.5, 2, 2.5, 3, 4, 5, 6, 8 x 10^k) for the top tick."""
    if v <= 0:
        return 1.0
    e = 10 ** math.floor(math.log10(v))
    for m in (1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10):
        if v <= m * e:
            return m * e
    return 10 * e


def tick_step(ymax):
    for step in (0.5, 1, 2, 2.5, 5, 10, 20, 25, 50):
        if ymax / step <= 6 and abs(ymax / step - round(ymax / step)) < 1e-9:
            return step
    return ymax / 5


def cache_colors():
    # One hue, light to dark: a bigger cache is a darker line.
    cmap = plt.get_cmap("Greys")
    return [cmap(0.35 + 0.65 * i / (len(CACHES) - 1)) for i in range(len(CACHES))]


def series(data, workload, cache):
    xs, ys = [], []
    for t in MEMTHREADS:
        v = data.get((workload, cache, t))
        if v is not None:
            xs.append(t)
            ys.append(v)
    return xs, ys


def panel_max(data, op):
    return max((v for (wl, _, _), v in data.items() if wl.startswith(op + "-")), default=0)


def plot_threads(data, op, ymax, out):
    fig, axes = plt.subplots(1, 2, figsize=(3.4, 1.95), sharey=True)
    colors = cache_colors()
    for ax, (dist, name), letter in zip(axes, DISTS, "ab"):
        wl = f"{op}-{dist}"
        for cache, color, marker in zip(CACHES, colors, MARKERS):
            xs, ys = series(data, wl, cache)
            if xs:
                ax.plot(xs, ys, color=color, marker=marker, markerfacecolor="white",
                        markeredgewidth=0.8, label=f"{cache} MB", clip_on=False, zorder=3)
        # 0 memory threads = offloading off; keep it visually apart from 1..8.
        ax.axvline(0.5, color="0.6", linewidth=0.5, linestyle=(0, (2, 2)), zorder=1)
        ax.set_xlim(-0.3, 8.3)
        ax.set_xticks(MEMTHREADS)
        ax.set_xticklabels(["off"] + [str(t) for t in MEMTHREADS[1:]])
        ax.set_ylim(0, ymax)
        ax.yaxis.set_major_locator(MultipleLocator(tick_step(ymax)))
        ax.yaxis.set_minor_locator(NullLocator())
        ax.grid(axis="y", color="0.88", linewidth=0.4, zorder=0)
        ax.set_xlabel("Memory-node threads")
        ax.set_title(f"({letter}) {name}", y=-0.52, fontsize=8)
    axes[0].set_ylabel("Throughput (Mops)")
    handles, labels = axes[0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper center", ncol=3, frameon=False,
               handlelength=2.0, columnspacing=1.4, handletextpad=0.4,
               bbox_to_anchor=(0.55, 1.01))
    fig.subplots_adjust(left=0.13, right=0.98, top=0.80, bottom=0.30, wspace=0.08)
    save(fig, out)


def plot_speedup(data, out):
    fig, ax = plt.subplots(figsize=(3.4, 2.1))
    lines = [("point-uniform", "Point, uniform", "0.0", "-", "o"),
             ("point-zipf", "Point, Zipfian", "0.0", (0, (4, 2)), "s"),
             ("range-uniform", "Range, uniform", "0.45", "-", "^"),
             ("range-zipf", "Range, Zipfian", "0.45", (0, (4, 2)), "D")]
    top = 0
    for wl, label, color, style, marker in lines:
        xs, ys = [], []
        for i, cache in enumerate(CACHES):
            off = data.get((wl, cache, 0))
            on = [data[(wl, cache, t)] for t in MEMTHREADS[1:] if (wl, cache, t) in data]
            if off and on:
                xs.append(i)
                ys.append(max(on) / off)
        if xs:
            top = max(top, max(ys))
            ax.plot(xs, ys, color=color, linestyle=style, marker=marker,
                    markerfacecolor="white", markeredgewidth=0.8, label=label,
                    clip_on=False, zorder=3)
    ax.axhline(1.0, color="0.5", linewidth=0.6, linestyle=(0, (1, 1.5)), zorder=1)
    ax.text(-0.15, 0.93, "break-even", va="top", ha="left", fontsize=6.5, color="0.35")
    ymax = nice_ceiling(top * 1.05)
    ax.set_ylim(0, ymax)
    ax.yaxis.set_major_locator(MultipleLocator(tick_step(ymax)))
    ax.set_xlim(-0.25, len(CACHES) - 1 + 0.25)
    ax.set_xticks(range(len(CACHES)))
    ax.set_xticklabels([str(c) for c in CACHES])
    ax.grid(axis="y", color="0.88", linewidth=0.4, zorder=0)
    ax.set_xlabel("Compute-side cache (MB)")
    ax.set_ylabel("Best offload / no offload")
    ax.legend(loc="lower center", bbox_to_anchor=(0.5, 1.0), ncol=2, frameon=False,
              handlelength=2.2, columnspacing=1.4, handletextpad=0.5)
    fig.subplots_adjust(left=0.13, right=0.97, top=0.80, bottom=0.21)
    save(fig, out)


def save(fig, stem):
    for ext in ("pdf", "png"):
        fig.savefig(f"{stem}.{ext}")
    plt.close(fig)
    print(f"wrote {stem}.pdf / .png")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", help="results dir (e.g. fair/results/fair3) or a dex_compute.csv")
    ap.add_argument("--out", help="output dir (default: <results dir>/figs)")
    ap.add_argument("--one-scale", action="store_true",
                    help="one y scale for the point and range figures together")
    args = ap.parse_args()

    data = load(args.input)
    base = args.input if os.path.isdir(args.input) else os.path.dirname(os.path.abspath(args.input))
    out = args.out or os.path.join(base, "figs")
    os.makedirs(out, exist_ok=True)

    pmax, rmax = panel_max(data, "point"), panel_max(data, "range")
    if args.one_scale:
        pmax = rmax = max(pmax, rmax)
    plot_threads(data, "point", nice_ceiling(pmax * 1.03), os.path.join(out, "dex_point"))
    plot_threads(data, "range", nice_ceiling(rmax * 1.03), os.path.join(out, "dex_range"))
    plot_speedup(data, os.path.join(out, "dex_speedup"))


if __name__ == "__main__":
    main()
