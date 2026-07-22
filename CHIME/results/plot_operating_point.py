#!/usr/bin/env python3
"""
CHIME operating point -- how far offload EXPANDS the region where CHIME still
runs at a good rate.

The x-axis is cache pressure: how big the index is relative to the cache. CHIME
caches internal (inner) nodes and does one-sided leaf reads. Grow the inner-node
footprint (equivalently: shrink the cache) and eventually the index no longer
fits. To the LEFT of that boundary the index fits and *caching is the right
call* -- pure one-sided reads are as fast or faster than offload. To the RIGHT
the index spills, every lookup misses in cache, and each miss is a multi-hop
one-sided walk -- the one-sided line collapses. Offload turns every miss into a
single MN-side RPC, so it stays flat and high across the whole range.

The shaded band between the two lines is the operating region offload reclaims:
the range of index/cache where caching alone has failed but CHIME still serves a
good rate because it offloads the miss.

x is ordered by INCREASING pressure (index fits -> index spills). Index footprint
is ~88MB (from the sweep geometry); the fits/spills boundary is index/cache = 1.

Usage: python3 plot_operating_point.py [SWEEP_DIR] [--out FILE] [--index-mb MB]
Palette + axes-from-0 convention shared with plot_miss_offload.py.
"""
import argparse, glob, os, re, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

import plot_miss_offload as base

C_OFF, C_ON = base.C_OFF, base.C_ON
GRID, INK, MUTED = base.GRID, base.INK, base.MUTED
BAND = "#1baf7a"          # reclaimed-region fill (offload hue, low alpha)
INDEX_MB_DEFAULT = 88.0   # inner-node index footprint (sweep geometry)
WL_ORDER = base.WL_ORDER


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sweep", nargs="?")
    ap.add_argument("--out", default=None)
    ap.add_argument("--index-mb", type=float, default=INDEX_MB_DEFAULT)
    a = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    sweep = a.sweep or base.newest_sweep(here)
    if not sweep or not os.path.isdir(sweep):
        sys.exit("no sweep dir found; pass one explicitly")
    out = a.out or os.path.join(here, "chime_operating_point.png")
    idx = a.index_mb

    # DESC cache order == increasing pressure left->right (index fits -> spills)
    caches = sorted((int(re.search(r"cache_(\d+)MB", d).group(1))
                     for d in glob.glob(os.path.join(sweep, "cache_*MB"))),
                    reverse=True)
    if not caches:
        sys.exit("no cache_*MB dirs under " + sweep)
    c0 = os.path.join(sweep, "cache_%dMB" % caches[0])
    present = {os.path.basename(p) for p in glob.glob(os.path.join(c0, "*"))
               if os.path.isdir(p)}
    WLS = [w for w in WL_ORDER if w in present]
    if not WLS:
        sys.exit("no workload dirs under " + c0)
    print("sweep:", sweep, "| pressure order (MB):", caches, "| workloads:", WLS)

    def tput(wl, c, m):
        d = base.parse(os.path.join(sweep, "cache_%dMB" % c, wl, m,
                                    "memory.log")) or {}
        return d.get("tput")

    off = {wl: [tput(wl, c, "off") for c in caches] for wl in WLS}
    on  = {wl: [tput(wl, c, "on")  for c in caches] for wl in WLS}

    top = max(v for wl in WLS for v in off[wl] + on[wl] if v is not None) * 1.15
    x = list(range(len(caches)))
    ratios = [idx / c for c in caches]                 # index/cache per tick

    # fits/spills boundary (ratio == 1) in categorical x. Interpolate between the
    # two ticks whose ratio straddles 1; clamp to the panel if all fit / all spill.
    def boundary_x():
        for i in range(len(ratios) - 1):
            r0, r1 = ratios[i], ratios[i + 1]
            if (r0 - 1.0) * (r1 - 1.0) <= 0 and r1 != r0:
                # linear in log(ratio) between adjacent categorical positions
                import math
                f = (math.log(1.0) - math.log(r0)) / (math.log(r1) - math.log(r0))
                return i + f
        return -1.0 if ratios[0] > 1 else len(caches)
    bx = boundary_x()

    fig, axes = plt.subplots(1, len(WLS), figsize=(5.4 * len(WLS), 4.9),
                             squeeze=False, sharey=True)
    fig.patch.set_facecolor("white")

    for cix, wl in enumerate(WLS):
        ax = axes[0][cix]
        yo, yn = off[wl], on[wl]

        # "index spills" zone shading (right of the boundary)
        if -0.25 < bx < len(caches):
            ax.axvspan(bx, len(caches) - 0.6, color=GRID, alpha=0.45, zorder=0)
            ax.axvline(bx, color=MUTED, lw=1.3, ls=(0, (4, 3)), zorder=1)

        # reclaimed operating region: gap between offload and one-sided
        ax.fill_between(x, yo, yn, where=[n is not None and o is not None and n > o
                                          for o, n in zip(yo, yn)],
                        interpolate=True, color=BAND, alpha=0.16, zorder=1,
                        label="operating region\nreclaimed by offload")

        ax.plot(x, yo, "-o", color=C_OFF, lw=2.2, ms=7, mec="white", mew=1.5,
                label="one-sided (cache only)", zorder=3)
        ax.plot(x, yn, "-o", color=C_ON, lw=2.2, ms=7, mec="white", mew=1.5,
                label="offload (miss → RPC)", zorder=3)

        # speedup label at the highest-pressure (right-most) point
        o_r, n_r = yo[-1], yn[-1]
        if o_r and n_r:
            ax.annotate("%.1f× the\none-sided rate" % (n_r / o_r),
                        (x[-1], n_r), textcoords="offset points",
                        xytext=(-6, 6), ha="right", va="bottom", fontsize=9.5,
                        color=C_ON, fontweight="bold")

        ax.set_ylim(0, top)
        ax.set_xlim(-0.35, len(caches) - 0.6)
        ax.set_xticks(x)
        ax.set_xticklabels(["%d MB\nindex %.1f×" % (c, r)
                            for c, r in zip(caches, ratios)], fontsize=9)
        ax.set_title(wl, fontsize=12, color=INK, pad=6)
        ax.set_xlabel("cache pressure  →  (inner-node index relative to cache)",
                      fontsize=10, color=MUTED)
        if cix == 0:
            ax.set_ylabel("Throughput (Mops)   ↑ better", fontsize=11, color=INK)
        ax.grid(axis="y", color=GRID, lw=1, zorder=0)
        ax.set_axisbelow(True)
        for s in ("top", "right"):
            ax.spines[s].set_visible(False)
        for s in ("left", "bottom"):
            ax.spines[s].set_color(GRID)
        ax.tick_params(colors=MUTED, labelsize=9)

        # single-line zone captions along the top of the first panel only
        if cix == 0:
            if bx > 0:
                ax.text(max(bx / 2 - 0.35, -0.3), top * 0.9, "◄ index fits",
                        ha="left", va="center", fontsize=9, color=MUTED)
            ax.text(bx + 0.12, top * 0.9,
                    "index spills  →  one-sided collapses, offload holds",
                    ha="left", va="center", fontsize=9, color=INK)

    # shared legend on the left panel, tucked into the empty lower-left wedge so
    # it never lands on the zipf line or the speedup labels on the right panel.
    h, l = axes[0][0].get_legend_handles_labels()
    axes[0][0].legend(h, l, loc="lower left", frameon=False, fontsize=9,
                      bbox_to_anchor=(0.0, 0.02))

    fig.suptitle("CHIME — offload expands the operating point",
                 fontsize=14, color=INK, x=0.008, ha="left", y=0.985)
    fig.text(0.008, 0.905,
             "Once the inner-node index outgrows the cache, one-sided caching "
             "collapses;\noffloading each miss keeps CHIME at a good rate — "
             "expanding the region where it still operates.",
             fontsize=9.5, color=MUTED, ha="left", va="top")
    fig.tight_layout(rect=[0, 0, 1, 0.86])
    fig.savefig(out, dpi=160, facecolor="white")
    print("wrote", out)


if __name__ == "__main__":
    main()
