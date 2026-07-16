#!/usr/bin/env python3
"""
CHIME miss-gated offload: one sweep, memory-node per-node metrics.

Plots offload ON vs OFF across index-cache size for the sweep whose logs prove
that offloading now fires ONLY on an inner-node miss (the offload% row). Four
rows x two workloads:
  1 throughput (Mops)          -- higher better
  2 MEAN latency (us)          -- lower better; this is what drives throughput
  3 p99 latency (us)           -- the tail
  4 % ops offloaded            -- the MISS RATE; offload tracks it, hits go direct

Reads one sweep dir's per-cell memory.log files directly (not the CSV) so the
offload% and mean come from the same source. Single node, so throughput is that
node's own rate -- a valid off-vs-on comparison; cluster is ~2x.

Usage: python3 plot_miss_offload.py [SWEEP_DIR] [--out FILE]
Palette reused from plot_offload.py (validated: CVD dE 73.6).
"""
import argparse, glob, os, re, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

C_OFF = "#2a78d6"   # blue  -- offload OFF (pure one-sided)
C_ON  = "#1baf7a"   # aqua  -- offload ON  (miss-gated)
GRID, INK, MUTED = "#e2e2de", "#0b0b0b", "#82817c"
# Preferred column order; the script plots whichever of these the sweep contains,
# so a point-only sweep shows 2 columns and a full sweep shows all 4.
WL_ORDER = ["point-uniform", "point-zipf", "range-uniform", "range-zipf"]

_RES = re.compile(r"throughput=([0-9.]+)")
_ALL = re.compile(r"^  ALL\s")
_LAT = {k: re.compile(k + r"=\s*([0-9.]+)us") for k in ("mean", "p50", "p99")}
_OFF = re.compile(r"ops offload \(rpc\)\s*=\s*\d+\s*\(([0-9.]+)%\)")


def parse(log):
    """-> dict(tput, mean, p50, p99, offl) from one memory.log."""
    if not os.path.exists(log):
        return None
    d = {"offl": 0.0}
    with open(log, errors="replace") as f:
        in_all = False
        for ln in f:
            m = _RES.search(ln)
            if ln.startswith("[RESULT") and m:
                d["tput"] = float(m.group(1))
            if ln.startswith("[ALL OPS]"):
                in_all = True
            elif in_all and _ALL.match(ln):
                for k, rx in _LAT.items():
                    mm = rx.search(ln)
                    if mm:
                        d[k] = float(mm.group(1))
                in_all = False
            mo = _OFF.search(ln)
            if mo:
                d["offl"] = float(mo.group(1))   # last one wins (node 0/1)
    return d if "tput" in d else None


def newest_sweep(base):
    cands = []
    for d in glob.glob(os.path.join(base, "memory", "sweep_*")):
        n = len(glob.glob(os.path.join(d, "cache_*")))
        cands.append((n, d))
    if not cands:
        return None
    cands.sort()
    return cands[-1][1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sweep", nargs="?")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    sweep = a.sweep or newest_sweep(here)
    if not sweep or not os.path.isdir(sweep):
        sys.exit("no sweep dir found; pass one explicitly")
    out = a.out or os.path.join(here, "chime_miss_offload.png")
    print("sweep:", sweep)

    caches = sorted(int(re.search(r"cache_(\d+)MB", d).group(1))
                    for d in glob.glob(os.path.join(sweep, "cache_*MB")))
    if not caches:
        sys.exit("no cache_*MB dirs under " + sweep)
    print("cache points:", caches)

    # Discover which workloads this sweep actually has (a point-only sweep -> 2
    # columns; a full one -> 4). Look under the first cache dir.
    c0 = os.path.join(sweep, "cache_%dMB" % caches[0])
    present = {os.path.basename(p) for p in glob.glob(os.path.join(c0, "*"))
               if os.path.isdir(p)}
    WLS = [w for w in WL_ORDER if w in present]
    if not WLS:
        sys.exit("no workload dirs under " + c0)
    print("workloads:", WLS)

    # data[wl][mode][metric] = [per cache]
    data = {wl: {m: {k: [] for k in ("tput", "mean", "p99", "offl")}
                 for m in ("off", "on")} for wl in WLS}
    tainted = []
    for wl in WLS:
        for c in caches:
            for m in ("off", "on"):
                d = parse(os.path.join(sweep, "cache_%dMB" % c, wl, m,
                                       "memory.log")) or {}
                for k in ("tput", "mean", "p99", "offl"):
                    data[wl][m][k].append(d.get(k))
            # Pre-fix range guard: an OFF cell that still offloaded means the run
            # was made before the range A/B fix (b28460e) and its off-vs-on is
            # meaningless (both halves ran the offload path). Flag it loudly
            # instead of drawing a wrong comparison.
            off_offl = data[wl]["off"]["offl"][-1]
            if off_offl and off_offl > 1.0:
                tainted.append("%s@%dMB (OFF cell offloaded %.0f%%)"
                               % (wl, c, off_offl))
    if tainted:
        print("\n*** WARNING: OFF cells that actually ran offload (pre-fix data,\n"
              "    off-vs-on is INVALID for these) ***")
        for t in tainted:
            print("   ", t)
        print("    Re-collect with a binary built after commit b28460e.\n")

    # NB the offload% row means different things per family: for POINT lookups
    # offload is miss-gated, so % offloaded == inner-node miss rate and falls with
    # cache size. For RANGE scans offload is whole-scan pushdown (rate-gated, not
    # miss-gated: a scan reads many sibling leaves regardless of a cached start
    # leaf), so % offloaded is ~100 (ON) / 0 (OFF), flat across cache.
    rows = [("tput", "Throughput (Mops)  ↑ better", False),
            ("mean", "MEAN latency (µs)  ↓ better\n(drives throughput)", False),
            ("p99",  "p99 latency (µs)  ↓ better\n(the tail)", False),
            ("offl", "% ops offloaded\n(point: = MISS rate)", True)]

    def top(metric):
        vs = [v for wl in WLS for m in ("off", "on")
              for v in data[wl][m][metric] if v is not None]
        return (max(vs) * 1.08) if vs else 1.0
    tops = {k: (100 if k == "offl" else top(k)) for k, _, _ in rows}

    x = list(range(len(caches)))
    fig, axes = plt.subplots(len(rows), len(WLS),
                             figsize=(3.7 * len(WLS), 11.2), squeeze=False)
    fig.patch.set_facecolor("white")

    for r, (metric, ylab, offl_row) in enumerate(rows):
        for cix, wl in enumerate(WLS):
            ax = axes[r][cix]
            modes = (("on", C_ON, "Offload ON (miss-gated)"),) if offl_row else \
                    (("off", C_OFF, "Offload OFF"), ("on", C_ON, "Offload ON"))
            for m, col, lbl in modes:
                ys = data[wl][m][metric]
                xs = [xi for xi, y in zip(x, ys) if y is not None]
                yy = [y for y in ys if y is not None]
                ax.plot(xs, yy, "-o", color=col, lw=2, ms=6, mec="white",
                        mew=1.5, label=lbl, zorder=3)
                if offl_row:  # annotate the miss rate directly
                    for xi, y in zip(xs, yy):
                        ax.annotate("%.0f%%" % y, (xi, y), textcoords="offset points",
                                    xytext=(0, 8), ha="center", fontsize=8, color=MUTED)
            ax.set_ylim(0, tops[metric])
            ax.set_xticks(x); ax.set_xticklabels([str(c) for c in caches])
            ax.set_xlim(-0.25, len(caches) - 0.75)
            ax.grid(axis="y", color=GRID, lw=1, zorder=0); ax.set_axisbelow(True)
            for s in ("top", "right"): ax.spines[s].set_visible(False)
            for s in ("left", "bottom"): ax.spines[s].set_color(GRID)
            ax.tick_params(colors=MUTED, labelsize=9)
            if r == 0: ax.set_title(wl, fontsize=11, color=INK, pad=8)
            if r == len(rows) - 1: ax.set_xlabel("index cache (MB)", fontsize=9, color=MUTED)
            if cix == 0: ax.set_ylabel(ylab, fontsize=10, color=INK)
            # throughput: label the speedup
            if metric == "tput":
                off_v, on_v = data[wl]["off"]["tput"], data[wl]["on"]["tput"]
                for xi, o, n in zip(x, off_v, on_v):
                    if o and n:
                        ax.annotate("%.1fx" % (n / o), (xi, n),
                                    textcoords="offset points", xytext=(0, 8),
                                    ha="center", fontsize=8,
                                    color=(C_ON if n >= o else C_OFF))

    # legend on the OFF/ON throughput axis (row 0), inside the panel, so it never
    # collides with the header text.
    h, l = axes[0][0].get_legend_handles_labels()
    axes[0][0].legend(h, l, loc="lower right", frameon=False, fontsize=9)
    fig.suptitle("CHIME — miss-gated RPC offload vs one-sided reads",
                 fontsize=14, color=INK, x=0.008, ha="left", y=0.992)
    fig.text(0.008, 0.968,
             "2-node RDMA · 50M keys · 50M ops/cell · 4 dir threads · "
             "index ≈88MB (fits at 128, evicts below) · memory-node rate",
             fontsize=9.5, color=MUTED, ha="left")
    fig.tight_layout(rect=[0, 0, 1, 0.958])
    fig.savefig(out, dpi=160, facecolor="white")
    print("wrote", out)


if __name__ == "__main__":
    main()
