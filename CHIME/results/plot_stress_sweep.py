#!/usr/bin/env python3
"""
CHIME inner-node STRESS test analysis.

Consumes the summary CSV from run/run_stress_sweep.sh:
  span,cache_mb,dir_threads,workload,offload,role,status,node_tput_mops,p99_us,
  index_mb,elapsed_s,failed_lines,log

and answers: as the memory-node inner nodes get fatter/leaner (internalSpanSize),
at different cache sizes (i.e. different inner-node-index / cache %), for point vs
range and uniform vs zipf -- how does throughput move WITH vs WITHOUT offloading,
where does no-offload break, and how much does offloading help / rescue it.

Two figures:
  chime_stress_throughput.png  rows = cache (the index/cache % regime),
                               cols = workload; each panel = throughput vs inner-
                               node size, one-sided (blue) vs offload (green).
                               Failed cells get a red x at the baseline.
  chime_stress_speedup.png     offload/one-sided throughput ratio vs inner-node
                               size (one line per cache), per workload. >1 = better;
                               a * marks where one-sided BROKE and offload survived.

Palette + axes-from-0 shared with plot_miss_offload.py.
Usage: python3 plot_stress_sweep.py [STRESS_DIR|CSV] [--role memory|compute] [--outdir DIR]
"""
import argparse, csv, glob, os, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

import plot_miss_offload as base

C_OFF, C_ON = base.C_OFF, base.C_ON
GRID, INK, MUTED = base.GRID, base.INK, base.MUTED
BAD = "#d1495b"                     # failure marker
CACHE_COLORS = ["#2a78d6", "#e08a1e", "#7a4fbf", "#1baf7a"]  # per-cache (speedup fig)
WL_ORDER = base.WL_ORDER
OK = "ok"


def node_bytes(s):
    return 43 + 17 * s              # transferred inner-node size (Common.h geometry)


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def find_csv(path, role):
    if path and os.path.isfile(path):
        return path
    base_dir = path if path and os.path.isdir(path) else None
    if base_dir is None:
        here = os.path.dirname(os.path.abspath(__file__))
        cands = sorted(glob.glob(os.path.join(here, "**", "stress_*"), recursive=True))
        base_dir = cands[-1] if cands else None
    if not base_dir:
        return None
    c = os.path.join(base_dir, "summary_%s.csv" % role)
    if os.path.isfile(c):
        return c
    cs = glob.glob(os.path.join(base_dir, "summary_*.csv"))
    return cs[0] if cs else None


def load(csv_path):
    """-> spans, caches, WLS, D[wl][cache][span][mode] = row-dict."""
    rows = list(csv.DictReader(open(csv_path)))
    D = {}
    spans, caches, wls = set(), set(), set()
    for r in rows:
        wl, mode = r["workload"], r["offload"]
        s, c = int(r["span"]), int(r["cache_mb"])
        spans.add(s); caches.add(c); wls.add(wl)
        D.setdefault(wl, {}).setdefault(c, {}).setdefault(s, {})[mode] = {
            "status": r["status"], "tput": num(r["node_tput_mops"]),
            "p99": num(r["p99_us"]), "index": num(r["index_mb"])}
    WLS = [w for w in WL_ORDER if w in wls] or sorted(wls)
    return sorted(spans), sorted(caches), WLS, D


def cell(D, wl, c, s, mode):
    return D.get(wl, {}).get(c, {}).get(s, {}).get(mode)


def rep_index(D, wl, c):
    """representative index size (MB) for a workload+cache: median of ok cells."""
    vs = sorted(v["index"] for s in D.get(wl, {}).get(c, {})
                for m, v in D[wl][c][s].items()
                if v["status"] == OK and v["index"] is not None)
    return vs[len(vs) // 2] if vs else None


def style(ax):
    ax.grid(axis="y", color=GRID, lw=1, zorder=0); ax.set_axisbelow(True)
    for sp in ("top", "right"): ax.spines[sp].set_visible(False)
    for sp in ("left", "bottom"): ax.spines[sp].set_color(GRID)
    ax.tick_params(colors=MUTED, labelsize=8.5)


def xticklabels(spans):
    return ["S=%d\n%dB" % (s, node_bytes(s)) for s in spans]


def fig_throughput(spans, caches, WLS, D, outdir):
    x = list(range(len(spans)))
    nrow, ncol = len(caches), len(WLS)
    fig, axes = plt.subplots(nrow, ncol, figsize=(3.5 * ncol, 3.3 * nrow),
                             squeeze=False)
    fig.patch.set_facecolor("white")

    # shared y PER COLUMN (workload): range must not be crushed by point's scale.
    col_top = []
    for wl in WLS:
        vs = [cell(D, wl, c, s, m)["tput"]
              for c in caches for s in spans for m in ("off", "on")
              if cell(D, wl, c, s, m) and cell(D, wl, c, s, m)["tput"] is not None]
        col_top.append((max(vs) * 1.15) if vs else 1.0)

    for ri, c in enumerate(caches):
        for ci, wl in enumerate(WLS):
            ax = axes[ri][ci]
            top = col_top[ci]
            for mode, col, lbl in (("off", C_OFF, "one-sided"), ("on", C_ON, "offload")):
                xs, ys = [], []
                for xi, s in zip(x, spans):
                    cc = cell(D, wl, c, s, mode)
                    if cc and cc["status"] == OK and cc["tput"] is not None:
                        xs.append(xi); ys.append(cc["tput"])
                    elif cc and cc["status"] != OK:
                        ax.scatter([xi], [top * 0.03], marker="x", s=42,
                                   color=(C_OFF if mode == "off" else C_ON),
                                   zorder=4, linewidths=1.8)
                ax.plot(xs, ys, "-o", color=col, lw=2, ms=6, mec="white",
                        mew=1.3, label=lbl, zorder=3)
            # offload speedup label where both ran
            for xi, s in zip(x, spans):
                o = cell(D, wl, c, s, "off"); n = cell(D, wl, c, s, "on")
                if o and n and o["status"] == OK and n["status"] == OK \
                        and o["tput"] and n["tput"]:
                    ax.annotate("%.1f×" % (n["tput"] / o["tput"]),
                                (xi, n["tput"]), textcoords="offset points",
                                xytext=(0, 7), ha="center", fontsize=7.5,
                                color=(C_ON if n["tput"] >= o["tput"] else C_OFF))
            ax.set_ylim(0, top)
            ax.set_xlim(-0.4, len(spans) - 0.6)
            ax.set_xticks(x); ax.set_xticklabels(xticklabels(spans), fontsize=8)
            style(ax)
            if ri == 0:
                ax.set_title(wl, fontsize=11, color=INK, pad=6)
            if ri == nrow - 1:
                ax.set_xlabel("inner-node size", fontsize=9, color=MUTED)
            if ci == 0:
                idx = rep_index(D, WLS[0], c)  # representative across workloads
                idx = idx or next((rep_index(D, w, c) for w in WLS
                                   if rep_index(D, w, c)), None)
                lab = "cache %d MB" % c
                if idx:
                    lab += "\nindex ≈%.0fMB (%.1f×)" % (idx, idx / c)
                ax.set_ylabel(lab + "\nThroughput (Mops)", fontsize=9, color=INK)

    axes[0][0].legend(loc="upper right", frameon=False, fontsize=8.5)
    fig.suptitle("CHIME stress — throughput vs inner-node size "
                 "(one-sided vs offload)", fontsize=13.5, color=INK, x=0.008,
                 ha="left", y=0.99)
    fig.text(0.008, 0.94,
             "rows = cache (≈ index/cache %); cols = workload. × at the "
             "baseline = that config FAILED (broke or timed out). Label = offload/"
             "one-sided speedup.",
             fontsize=8.5, color=MUTED, ha="left", va="top")
    fig.tight_layout(rect=[0, 0, 1, 0.925])
    out = os.path.join(outdir, "chime_stress_throughput.png")
    fig.savefig(out, dpi=155, facecolor="white"); plt.close(fig)
    print("wrote", out)


def fig_speedup(spans, caches, WLS, D, outdir):
    x = list(range(len(spans)))
    fig, axes = plt.subplots(1, len(WLS), figsize=(3.6 * len(WLS), 3.9),
                             squeeze=False, sharey=True)
    fig.patch.set_facecolor("white")
    tops = []
    for wl in WLS:
        for ci_c, c in enumerate(caches):
            r = []
            for s in spans:
                o = cell(D, wl, c, s, "off"); n = cell(D, wl, c, s, "on")
                if o and n and o["status"] == OK and n["status"] == OK and o["tput"] and n["tput"]:
                    r.append(n["tput"] / o["tput"])
            if r: tops.append(max(r))
    top = (max(tops) * 1.2) if tops else 3.0

    for ci, wl in enumerate(WLS):
        ax = axes[0][ci]
        ax.axhline(1.0, color=MUTED, lw=1, ls=(0, (4, 3)), zorder=1)
        for k, c in enumerate(caches):
            col = CACHE_COLORS[k % len(CACHE_COLORS)]
            xs, ys = [], []
            for xi, s in zip(x, spans):
                o = cell(D, wl, c, s, "off"); n = cell(D, wl, c, s, "on")
                if o and n and o["status"] == OK and n["status"] == OK and o["tput"] and n["tput"]:
                    xs.append(xi); ys.append(n["tput"] / o["tput"])
                elif n and n["status"] == OK and o and o["status"] != OK:
                    # one-sided broke, offload survived -> pure rescue
                    ax.scatter([xi], [top * 0.94], marker="*", s=90, color=col,
                               zorder=4, edgecolors="white", linewidths=0.6)
            ax.plot(xs, ys, "-o", color=col, lw=2, ms=6, mec="white", mew=1.3,
                    label="cache %dMB" % c, zorder=3)
        ax.set_ylim(0, top)
        ax.set_xlim(-0.4, len(spans) - 0.6)
        ax.set_xticks(x); ax.set_xticklabels(xticklabels(spans), fontsize=8)
        ax.set_title(wl, fontsize=11, color=INK, pad=6)
        ax.set_xlabel("inner-node size", fontsize=9, color=MUTED)
        if ci == 0:
            ax.set_ylabel("offload speedup  (offload ÷ one-sided)",
                          fontsize=10, color=INK)
        style(ax)
    axes[0][0].legend(loc="upper left", frameon=False, fontsize=8.5)
    fig.suptitle("CHIME stress — how much offloading helps (★ = one-sided "
                 "broke, offload survived)", fontsize=13, color=INK, x=0.008,
                 ha="left", y=0.99)
    fig.tight_layout(rect=[0, 0, 1, 0.93])
    out = os.path.join(outdir, "chime_stress_speedup.png")
    fig.savefig(out, dpi=155, facecolor="white"); plt.close(fig)
    print("wrote", out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src", nargs="?", help="stress_<ts> dir or a summary CSV")
    ap.add_argument("--role", default="memory", choices=("memory", "compute"))
    ap.add_argument("--outdir", default=None)
    a = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    csv_path = find_csv(a.src, a.role)
    if not csv_path:
        sys.exit("no stress summary CSV found; pass the stress_<ts> dir or the CSV")
    outdir = a.outdir or here
    os.makedirs(outdir, exist_ok=True)
    print("csv:", csv_path)

    spans, caches, WLS, D = load(csv_path)
    print("spans:", spans, "| caches:", caches, "| workloads:", WLS)
    fig_throughput(spans, caches, WLS, D, outdir)
    fig_speedup(spans, caches, WLS, D, outdir)


if __name__ == "__main__":
    main()
