#!/usr/bin/env python3
"""
CHIME miss-gated offload -- the same sweep as plot_miss_offload.py, but emitted
as ONE FILE PER METRIC instead of a single 4x2 wall. Each file shows both
workloads (point-uniform | point-zipf) side by side so a metric can be dropped
into a doc on its own.

Outputs (into --outdir, default this dir):
  chime_tput.png     throughput (Mops)        higher better
  chime_mean.png     MEAN latency (us)        lower better -- drives throughput
  chime_p99.png      p99 latency (us)         lower better -- the tail
  chime_offloadrate.png  % ops offloaded      = inner-node MISS rate (ON only)

Parsing is reused verbatim from plot_miss_offload.parse so the two scripts can
never disagree about a number.

Usage: python3 plot_split.py [SWEEP_DIR] [--outdir DIR]
Palette + axes-from-0 convention shared with plot_miss_offload.py.
"""
import argparse, glob, os, re, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

import plot_miss_offload as base  # reuse parse(), newest_sweep(), palette

C_OFF, C_ON = base.C_OFF, base.C_ON
GRID, INK, MUTED = base.GRID, base.INK, base.MUTED
WL_ORDER = base.WL_ORDER

# metric key -> (filename, y-label, offload-only?)
METRICS = [
    ("tput", "chime_tput.png",    "Throughput (Mops)   ↑ better",          False),
    ("mean", "chime_mean.png",    "MEAN latency (µs)   ↓ better",       False),
    ("p99",  "chime_p99.png",     "p99 latency (µs)   ↓ better",        False),
    ("offl", "chime_offloadrate.png", "% ops offloaded  (= inner-node MISS rate)", True),
]


def style(ax):
    ax.grid(axis="y", color=GRID, lw=1, zorder=0)
    ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color(GRID)
    ax.tick_params(colors=MUTED, labelsize=10)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sweep", nargs="?")
    ap.add_argument("--outdir", default=None)
    a = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    sweep = a.sweep or base.newest_sweep(here)
    if not sweep or not os.path.isdir(sweep):
        sys.exit("no sweep dir found; pass one explicitly")
    outdir = a.outdir or here
    os.makedirs(outdir, exist_ok=True)
    print("sweep:", sweep)

    caches = sorted(int(re.search(r"cache_(\d+)MB", d).group(1))
                    for d in glob.glob(os.path.join(sweep, "cache_*MB")))
    if not caches:
        sys.exit("no cache_*MB dirs under " + sweep)
    c0 = os.path.join(sweep, "cache_%dMB" % caches[0])
    present = {os.path.basename(p) for p in glob.glob(os.path.join(c0, "*"))
               if os.path.isdir(p)}
    WLS = [w for w in WL_ORDER if w in present]
    if not WLS:
        sys.exit("no workload dirs under " + c0)
    print("cache points:", caches, "| workloads:", WLS)

    # data[wl][mode][metric] = [per cache]
    data = {wl: {m: {k: [] for k in ("tput", "mean", "p99", "offl")}
                 for m in ("off", "on")} for wl in WLS}
    for wl in WLS:
        for c in caches:
            for m in ("off", "on"):
                d = base.parse(os.path.join(sweep, "cache_%dMB" % c, wl, m,
                                            "memory.log")) or {}
                for k in ("tput", "mean", "p99", "offl"):
                    data[wl][m][k].append(d.get(k))

    x = list(range(len(caches)))

    for metric, fname, ylab, offl_only in METRICS:
        # one shared y-top across BOTH workloads for this metric (axes from 0)
        vs = [v for wl in WLS
              for m in (("on",) if offl_only else ("off", "on"))
              for v in data[wl][m][metric] if v is not None]
        top = 100 if metric == "offl" else (max(vs) * 1.12 if vs else 1.0)

        fig, axes = plt.subplots(1, len(WLS), figsize=(4.1 * len(WLS), 4.0),
                                 squeeze=False)
        fig.patch.set_facecolor("white")
        for cix, wl in enumerate(WLS):
            ax = axes[0][cix]
            modes = (("on", C_ON, "Offload ON (miss-gated)"),) if offl_only else \
                    (("off", C_OFF, "One-sided (offload OFF)"),
                     ("on",  C_ON,  "Offload ON"))
            for m, col, lbl in modes:
                ys = data[wl][m][metric]
                xs = [xi for xi, y in zip(x, ys) if y is not None]
                yy = [y for y in ys if y is not None]
                ax.plot(xs, yy, "-o", color=col, lw=2, ms=7, mec="white",
                        mew=1.5, label=lbl, zorder=3)
                if offl_only:
                    for xi, y in zip(xs, yy):
                        ax.annotate("%.0f%%" % y, (xi, y),
                                    textcoords="offset points", xytext=(0, 9),
                                    ha="center", fontsize=9, color=MUTED)
            # throughput: annotate the ON/OFF speedup at each cache point
            if metric == "tput":
                for xi, o, n in zip(x, data[wl]["off"]["tput"],
                                    data[wl]["on"]["tput"]):
                    if o and n:
                        ax.annotate("%.1f×" % (n / o), (xi, max(o, n)),
                                    textcoords="offset points", xytext=(0, 9),
                                    ha="center", fontsize=9,
                                    color=(C_ON if n >= o else C_OFF))
            ax.set_ylim(0, top)
            ax.set_xticks(x)
            ax.set_xticklabels([str(c) for c in caches])
            ax.set_xlim(-0.25, len(caches) - 0.75)
            ax.set_title(wl, fontsize=12, color=INK, pad=6)
            ax.set_xlabel("index cache (MB)", fontsize=10, color=MUTED)
            if cix == 0:
                ax.set_ylabel(ylab, fontsize=11, color=INK)
            style(ax)

        h, l = axes[0][0].get_legend_handles_labels()
        loc = "upper right" if metric in ("mean", "p99") else "lower right"
        axes[0][0].legend(h, l, loc=loc, frameon=False, fontsize=9)
        fig.suptitle("CHIME — " + ylab.split("  ")[0].strip(),
                     fontsize=13, color=INK, x=0.01, ha="left", y=0.99)
        fig.text(0.01, 0.9,
                 "2-node RDMA · 50M keys · 50M ops/cell · 4 dir "
                 "threads · index ≈88MB (fits at 128, evicts below)",
                 fontsize=9, color=MUTED, ha="left", va="top")
        fig.tight_layout(rect=[0, 0, 1, 0.865])
        out = os.path.join(outdir, fname)
        fig.savefig(out, dpi=160, facecolor="white")
        plt.close(fig)
        print("wrote", out)


if __name__ == "__main__":
    main()
