#!/usr/bin/env python3
"""
Plot the CHIME LEAF-CACHE study (run/run_leaf_cache.sh).

The question the sweep asks: stock CHIME caches internal nodes only, so even a
perfect index-cache hit ends in one remote read of the leaf. Is spending part of
the SAME cache budget on leaves better than spending all of it on inner nodes?

The x axis is the TOTAL compute-side cache -- the same 64/128/256/512/1024 MB
points DART is given. It is split, never grown: at 256 MB the baseline arm is
256 inner / 0 leaf and the leaf arm is 128 / 128. This script prints the split it
read out of every cell and flags any row where inner + leaf does not equal the
point, because that equality is the whole comparability claim.

Layout produced by run_leaf_cache.sh:
    <sweep>/cache_<MB>/leaf_<0|1>/<workload>/<off|on>/{memory,compute}.log
    <sweep>/summary_{memory,compute}.csv
        (cache_leaf, total/inner/leaf_cache_mb, leaf_hit_pct)

Output: a 3 x 4 grid
    row 1  cluster throughput (Mops, higher better)
    row 2  MEAN latency (us, lower better)   <- throughput ~= threads / mean
    row 3  leaf-cache hit rate (%)           <- the explanation for rows 1-2
    cols   the four workload cells
Four curves: leaf cache off/on x offload off/on. Every axis starts at 0 and each
metric row shares one y-scale, so panels compare directly.

Read row 3 first. A leaf is only worth caching when its keys are re-read, so the
hit rate is near zero under a uniform distribution (hot keys are spread over
millions of leaves) and high under zipf. Rows 1 and 2 should move only where row
3 does -- if they move where it does not, something else changed. And remember
the leaf arm runs a HALF-SIZE inner-node cache, so a flat curve is already the
leaf cache paying for the inner nodes it displaced.

Usage:
  python3 plot_leaf_cache.py                     # auto-find the newest sweep
  python3 plot_leaf_cache.py SWEEP_DIR
  python3 plot_leaf_cache.py ... --out leaf.png
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

C_LEAF0_OFF = "#2a78d6"   # blue   -- stock CHIME
C_LEAF0_ON = "#1baf7a"    # aqua   -- stock CHIME + offload
C_LEAF1_OFF = "#7c5cd6"   # violet -- leaf cache
C_LEAF1_ON = "#c0439a"    # magenta-- leaf cache + offload
GRID = "#e2e2de"
INK = "#0b0b0b"
MUTED = "#82817c"

WL_ORDER = ["point-uniform", "point-zipf", "range-uniform", "range-zipf"]
SERIES = [("0", "off", C_LEAF0_OFF, "-", "stock CHIME"),
          ("0", "on", C_LEAF0_ON, "-", "stock + offload"),
          ("1", "off", C_LEAF1_OFF, "--", "leaf cache"),
          ("1", "on", C_LEAF1_ON, "--", "leaf cache + offload")]

_LAT_RE = re.compile(r"mean=\s*([0-9.]+)us")


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def read_summary(sweep_dir):
    """-> {(cache, wl, offload, leaf): {'tput':.., 'leaf_hit':.., 'inner':.., 'leafmb':..}}

    Throughput is the CLUSTER total, i.e. the sum of the two nodes' own
    [RESULT] rates -- each node reports only its own, by design. `inner`/`leafmb`
    are the split micro_test actually ran; they must sum to the cache point.
    """
    out = {}
    for role in ("memory", "compute"):
        path = os.path.join(sweep_dir, "summary_%s.csv" % role)
        if not os.path.isfile(path):
            continue
        with open(path, newline="") as f:
            for row in csv.DictReader(f):
                c = num(row.get("cache_mb"))
                if c is None:
                    continue
                leaf = str(row.get("cache_leaf") or "0").strip() or "0"
                key = (int(c), row["workload"], row["offload"], leaf)
                d = out.setdefault(key, {"tput": None, "leaf_hit": None,
                                         "inner": None, "leafmb": None})
                t = num(row.get("node_tput_mops"))
                if t is not None:
                    d["tput"] = (d["tput"] or 0.0) + t
                if role == "compute":
                    h = num(row.get("leaf_hit_pct"))
                    if h is not None:
                        d["leaf_hit"] = h
                    d["inner"] = d["inner"] if d["inner"] is not None else num(row.get("inner_cache_mb"))
                    d["leafmb"] = d["leafmb"] if d["leafmb"] is not None else num(row.get("leaf_cache_mb"))
    return out


def parse_mean(path):
    """MEAN latency (us) from the '[ALL OPS]' -> '  ALL ' row of a micro_test log."""
    if not os.path.isfile(path):
        return None
    try:
        with open(path, errors="replace") as f:
            in_all = False
            for line in f:
                if line.startswith("[ALL OPS]"):
                    in_all = True
                elif in_all and line.lstrip().startswith("ALL "):
                    m = _LAT_RE.search(line)
                    return float(m.group(1)) if m else None
    except OSError:
        return None
    return None


def cell_log(sweep_dir, cache, leaf, wl, off, role="compute"):
    """Tolerate both layouts: with and without the leaf_<v>/ level."""
    for p in (os.path.join(sweep_dir, "cache_%dMB" % cache, "leaf_%s" % leaf, wl, off, "%s.log" % role),
              os.path.join(sweep_dir, "cache_%dMB" % cache, wl, off, "%s.log" % role),
              os.path.join(sweep_dir, "leaf_%s" % leaf, wl, off, "%s.log" % role),
              os.path.join(sweep_dir, wl, off, "%s.log" % role)):
        if os.path.isfile(p):
            return p
    return None


def autodiscover(here):
    roots = [os.path.join(here, "..", "build", "results", "leaf_cache"),
             os.path.join(here, "..", "build", "results", "cache_stress"),
             os.path.join(here, "leaf_cache")]
    cands = []
    for r in roots:
        for role in ("", "memory", "compute"):
            cands += glob.glob(os.path.join(r, role, "sweep_*"))
    cands = [d for d in cands if os.path.isdir(d) and
             (os.path.isfile(os.path.join(d, "summary_memory.csv")) or
              os.path.isfile(os.path.join(d, "summary_compute.csv")))]
    return max(cands, key=os.path.getmtime) if cands else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sweep", nargs="?", help="run_leaf_cache.sh sweep directory")
    ap.add_argument("--out", default="chime_leaf_cache.png")
    ap.add_argument("--title", default="CHIME — compute-side LEAF cache, on vs off")
    ap.add_argument("--subtitle", default=None)
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    sweep = args.sweep or autodiscover(here)
    if not sweep or not os.path.isdir(sweep):
        sys.exit("No sweep found — pass the run_leaf_cache.sh sweep directory.")
    print("sweep: %s" % sweep)

    data = read_summary(sweep)
    if not data:
        sys.exit("No usable rows in %s/summary_*.csv" % sweep)

    caches = sorted({k[0] for k in data}, reverse=True)   # biggest cache left
    wls = [w for w in WL_ORDER if any(k[1] == w for k in data)]
    leaves = sorted({k[3] for k in data})
    print("cache points (TOTAL, MB): %s   leaf arms: %s" % (caches, leaves))
    if "1" not in leaves:
        print("warning: this sweep has no CACHE_LEAF=1 cells — run run_leaf_cache.sh")

    # The split is the whole comparability claim: at every cache point BOTH arms
    # must occupy the same total compute-side memory. Check it rather than trust it.
    split_note = []
    for c in caches:
        got = [(k[3], v["inner"], v["leafmb"]) for k, v in data.items()
               if k[0] == c and v["inner"] is not None]
        for arm, inner, lmb in sorted(set(got)):
            tot = (inner or 0) + (lmb or 0)
            flag = "" if abs(tot - c) < 1e-6 else "   <-- MISMATCH, expected %g" % c
            print("  %5d MB total, leaf=%s -> inner %g + leaf %g = %g%s"
                  % (c, arm, inner or 0, lmb or 0, tot, flag))
        if got:
            arm1 = [(i, l) for a, i, l in got if a == "1"]
            if arm1:
                split_note.append("%dMB=%g/%g" % (c, arm1[0][0] or 0, arm1[0][1] or 0))

    # series[wl][metric][(leaf, off)] = [v per cache]
    series = defaultdict(lambda: defaultdict(dict))
    for wl in wls:
        for leaf, off, _c, _ls, _lab in SERIES:
            tputs, means, hits = [], [], []
            for c in caches:
                d = data.get((c, wl, off, leaf)) or {}
                tputs.append(d.get("tput"))
                hits.append(d.get("leaf_hit") if leaf == "1" else None)
                p = cell_log(sweep, c, leaf, wl, off)
                means.append(parse_mean(p) if p else None)
            series[wl]["tput"][(leaf, off)] = tputs
            series[wl]["mean"][(leaf, off)] = means
            series[wl]["hit"][(leaf, off)] = hits

    def top_of(metric):
        vs = [v for wl in wls for g in series[wl][metric].values()
              for v in g if v is not None]
        return max(vs) * 1.08 if vs else 1.0

    tops = {m: top_of(m) for m in ("tput", "mean", "hit")}
    tops["hit"] = max(tops["hit"], 100.0)   # a hit rate is a percentage

    rows = [("tput", "Throughput (Mops)  ↑ better"),
            ("mean", "MEAN latency (µs)  ↓ better\n(this drives throughput)"),
            ("hit", "Leaf-cache hit rate (%)\n(why rows 1–2 move, or don't)")]

    # Floor the width so the title and legend still fit when a sweep was narrowed
    # to one or two workloads (WORKLOADS=point-zipf, say).
    fig, axes = plt.subplots(3, len(wls), figsize=(max(10.0, 3.6 * len(wls)), 9.8),
                             squeeze=False)
    fig.patch.set_facecolor("white")
    x = list(range(len(caches)))

    for r, (metric, ylab) in enumerate(rows):
        for col, wl in enumerate(wls):
            ax = axes[r][col]
            for leaf, off, color, ls, lab in SERIES:
                if metric == "hit" and leaf == "0":
                    continue                      # no leaf cache, nothing to plot
                ys = series[wl][metric][(leaf, off)]
                xs = [xi for xi, y in zip(x, ys) if y is not None]
                yy = [y for y in ys if y is not None]
                if not xs:
                    continue
                ax.plot(xs, yy, ls, marker="o", color=color, lw=2, ms=6,
                        mec="white", mew=1.5, label=lab, zorder=3)

            ax.set_ylim(0, tops[metric])          # every axis starts at 0
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
                ax.set_xlabel("TOTAL cache: inner + leaf (MB)", fontsize=9, color=MUTED)
            if col == 0:
                ax.set_ylabel(ylab, fontsize=10, color=INK)

            # "what did the leaf cache buy" annotation, offload held fixed at off
            if metric in ("tput", "mean"):
                a = [v for v in series[wl][metric][("0", "off")] if v is not None]
                b = [v for v in series[wl][metric][("1", "off")] if v is not None]
                if a and b:
                    am, bm = sum(a) / len(a), sum(b) / len(b)
                    if metric == "tput":
                        txt = ("leaf %.2f× tput" % (bm / am)) if am else ""
                    else:
                        txt = ("leaf %.2f× latency" % (bm / am)) if am else ""
                    ax.text(0.03, 0.94, txt, transform=ax.transAxes, fontsize=8.5,
                            color=MUTED, va="top")

    handles, labels = axes[0][0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper right", frameon=False,
               fontsize=10, bbox_to_anchor=(0.995, 0.985))
    fig.suptitle(args.title, fontsize=14, color=INK, x=0.008, ha="left", y=0.985)
    sub = args.subtitle or (
        "x = TOTAL compute-side cache (inner + leaf), the same points DART is given · "
        "leaf arm inner/leaf split: " + (", ".join(split_note) if split_note else "n/a"))
    fig.text(0.008, 0.945, sub, fontsize=9.5, color=MUTED, ha="left")
    fig.tight_layout(rect=[0, 0, 1, 0.925])
    fig.savefig(args.out, dpi=160, facecolor="white")
    print("wrote %s" % args.out)


if __name__ == "__main__":
    main()
