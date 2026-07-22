#!/usr/bin/env python3
"""
CHIME hybrid range scans -- offload OFF vs ON at one cache point.
INDIVIDUAL figures, one metric per file:
  chime_hybrid_range_tput.png   throughput (Mops)   -- speedup + %ops offloaded
  chime_hybrid_range_mean.png   MEAN latency (us)   -- what drives throughput
  chime_hybrid_range_p99.png    p99 latency (us)    -- the tail

Reads one run of run_span_sweep.sh (layout: span_sweep_<ts>/span_<S>/<wl>/
<off|on>/<role>.log + summary CSV). Pass the sweep dir(s); per cell the
compute.log (client-side latency) is preferred, else memory.log.

The header shows the inner-node index : cache ratio -- the quantity that decides
how much of each scan the cache can serve locally vs how much the hybrid
offloads. index_mb comes from the CSV or the logs' "consumed cache size"; if
neither recorded it, pass --index-mb (e.g. estimated ~1.8 MB per 1M keys).

  python3 plot_hybrid_range.py compute/span_sweep_X --index-mb 53
Parsing/palette reused from plot_miss_offload.py.
"""
import argparse, csv, glob, os, re, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

import plot_miss_offload as base

C_OFF, C_ON = base.C_OFF, base.C_ON
GRID, INK, MUTED = base.GRID, base.INK, base.MUTED
RANGE_WLS = ["range-uniform", "range-zipf"]


def find_cell_log(dirs, span, wl, mode):
    for d in dirs:
        for role in ("compute", "memory"):
            p = os.path.join(d, "span_%d" % span, wl, mode, "%s.log" % role)
            if os.path.exists(p):
                return p
    return None


def read_csv_meta(dirs, span):
    cache, idx = None, None
    for d in dirs:
        for p in glob.glob(os.path.join(d, "span_%d" % span, "summary_*.csv")):
            for row in csv.DictReader(open(p)):
                try:
                    cache = cache or int(row["cache_mb"])
                except (ValueError, KeyError):
                    pass
                try:
                    idx = max(idx or 0, float(row.get("index_mb", "")))
                except ValueError:
                    pass
    return cache, idx


def index_from_logs(dirs, span):
    rx = re.compile(r"consumed cache size.*?=\s*([0-9.]+)\s*MB")
    best = None
    for d in dirs:
        for p in glob.glob(os.path.join(d, "span_%d" % span, "*", "*", "*.log")):
            try:
                for ln in open(p, errors="replace"):
                    m = rx.search(ln)
                    if m:
                        best = max(best or 0, float(m.group(1)))
            except OSError:
                pass
    return best


def style(ax):
    ax.grid(axis="y", color=GRID, lw=1, zorder=0)
    ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color(GRID)
    ax.tick_params(colors=MUTED, labelsize=10)


def one_figure(metric, ylab, better, fname, wls, data, span, header, outdir,
               show_offl):
    x = list(range(len(wls)))
    width = 0.34
    offs = [data[wl]["off"].get(metric) for wl in wls]
    ons  = [data[wl]["on"].get(metric)  for wl in wls]
    top = max([v for v in offs + ons if v is not None] or [1.0]) * 1.3

    fig, ax = plt.subplots(figsize=(6.4, 4.6))
    fig.patch.set_facecolor("white")
    ax.bar([xi - width / 2 for xi in x], [v or 0 for v in offs], width,
           color=C_OFF, label="offload OFF (one-sided)", zorder=3)
    ax.bar([xi + width / 2 for xi in x], [v or 0 for v in ons], width,
           color=C_ON, label="offload ON (hybrid)", zorder=3)

    for xi, (o, n) in enumerate(zip(offs, ons)):
        if o and n:   # improvement factor on the ON bar (direction-aware)
            factor = (n / o) if metric == "tput" else (o / n)
            ax.annotate("%.1f× %s" % (factor, "faster" if metric == "tput" else "lower"),
                        (xi + width / 2, n), textcoords="offset points",
                        xytext=(0, 6), ha="center", fontsize=10,
                        fontweight="bold", color=C_ON)
        if show_offl:
            offl = data[wls[xi]]["on"].get("offl")
            if offl is not None:
                ax.annotate("%.0f%% ops\noffloaded" % offl, (xi + width / 2, 0),
                            textcoords="offset points", xytext=(0, 5),
                            ha="center", va="bottom", fontsize=8, color="white")

    ax.set_ylim(0, top)
    ax.set_xticks(x)
    ax.set_xticklabels(wls, fontsize=11)
    ax.set_ylabel("%s  %s better" % (ylab, better), fontsize=11, color=INK)
    ax.legend(loc="upper left", frameon=False, fontsize=9)
    style(ax)

    fig.suptitle("CHIME hybrid range — %s (span=%d)" % (ylab, span),
                 fontsize=13, color=INK, x=0.01, ha="left", y=0.985)
    fig.text(0.01, 0.915, header, fontsize=9, color=MUTED, ha="left", va="top")
    fig.tight_layout(rect=[0, 0, 1, 0.87])
    out = os.path.join(outdir, fname)
    fig.savefig(out, dpi=160, facecolor="white")
    plt.close(fig)
    print("wrote", out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sweeps", nargs="+", help="span_sweep_<ts> dir(s), any role")
    ap.add_argument("--span", type=int, default=None)
    ap.add_argument("--index-mb", type=float, default=None,
                    help="index size override if the logs didn't record it")
    ap.add_argument("--outdir", default=None)
    a = ap.parse_args()

    dirs = [d for d in a.sweeps if os.path.isdir(d)]
    if not dirs:
        sys.exit("no valid sweep dirs given")
    spans = sorted({int(re.search(r"span_(\d+)", p).group(1))
                    for d in dirs for p in glob.glob(os.path.join(d, "span_*"))})
    if not spans:
        sys.exit("no span_<S> dirs found")
    span = a.span or spans[0]

    wls = [w for w in RANGE_WLS
           if find_cell_log(dirs, span, w, "off") or find_cell_log(dirs, span, w, "on")]
    if not wls:
        sys.exit("no range workload logs under span_%d" % span)

    data = {}
    for wl in wls:
        for mode in ("off", "on"):
            p = find_cell_log(dirs, span, wl, mode)
            data.setdefault(wl, {})[mode] = (base.parse(p) or {}) if p else {}

    cache, idx = read_csv_meta(dirs, span)
    measured = idx or index_from_logs(dirs, span)
    idx = measured or a.index_mb
    if cache and idx:
        header = "inner-node index ≈%.0f MB%s vs cache %d MB  →  index = %.1f× the cache\n" \
                 "hybrid: covered prefix served locally, uncovered tail offloaded to the MN" \
                 % (idx, "" if measured else " (est.)", cache, idx / cache)
    else:
        header = "hybrid: covered prefix served locally, uncovered tail offloaded to the MN"

    outdir = a.outdir or os.path.dirname(os.path.abspath(__file__))
    one_figure("tput", "Throughput (Mops)", "↑", "chime_hybrid_range_tput.png",
               wls, data, span, header, outdir, show_offl=True)
    one_figure("mean", "MEAN latency (µs)", "↓", "chime_hybrid_range_mean.png",
               wls, data, span, header, outdir, show_offl=False)
    one_figure("p99", "p99 latency (µs)", "↓", "chime_hybrid_range_p99.png",
               wls, data, span, header, outdir, show_offl=False)


if __name__ == "__main__":
    main()
