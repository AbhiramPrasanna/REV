#!/usr/bin/env python3
"""
CHIME inner-node-size sweep -- how far offloading widens the range of inner-node
geometries the system still runs well at.

Consumes a sweep produced by run/run_span_sweep.sh:
    span_sweep_<ts>/span_<S>/<workload>/<off|on>/<role>.log
where S = internalSpanSize (inner-node fanout). Cache is held fixed across the
sweep, so inner-node size is the only variable.

The story (Figure A, chime_span_operating_point.png): one-sided caching (offload
off) has a sweet spot near the proposed geometry (S=16) and falls off at both
ends -- small S makes the tree deep (many hops per miss), large S makes each
inner node big and read-amplified. Offload on collapses the whole walk into ONE
RPC regardless of S, so it stays flat and high. Reading off the *proposed
operating rate* (offload-off at the proposed S) as a horizontal reference, the
span of inner-node sizes that still meets that rate is narrow for one-sided but
wide for offload -- offloading covers a much larger base of geometries than the
single proposed one.

Figure B (chime_span_p99.png) is the p99 companion.

Parsing/palette are reused from plot_miss_offload so all CHIME figures agree.

Usage:
  python3 plot_span_sweep.py [SPAN_SWEEP_DIR] [--role memory|compute]
                             [--ref-span 16] [--outdir DIR]
If SPAN_SWEEP_DIR is omitted, the newest span_sweep_* under results/<role>/ or
results/memory/ is used.
"""
import argparse, glob, os, re, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

import plot_miss_offload as base   # parse(), palette

C_OFF, C_ON = base.C_OFF, base.C_ON
GRID, INK, MUTED = base.GRID, base.INK, base.MUTED
BAND = "#1baf7a"
WL_ORDER = base.WL_ORDER
PROPOSED_DEFAULT = 16


def internal_node_bytes(s):
    """Transferred inner-node size in bytes: 43 + 17*S (Common.h geometry)."""
    return 43 + 17 * s


def find_sweep(here, role):
    for sub in (role, "memory", "compute", "."):
        cands = sorted(glob.glob(os.path.join(here, sub, "span_sweep_*")))
        if cands:
            return cands[-1]
    cands = sorted(glob.glob(os.path.join(here, "**", "span_sweep_*"),
                             recursive=True))
    return cands[-1] if cands else None


def load(sweep, role):
    """-> spans(list[int]), WLS(list), data[wl][mode][metric]=[per span]."""
    spans = sorted(int(re.search(r"span_(\d+)", d).group(1))
                   for d in glob.glob(os.path.join(sweep, "span_*")))
    if not spans:
        sys.exit("no span_<S> dirs under " + sweep)
    s0 = os.path.join(sweep, "span_%d" % spans[0])
    present = {os.path.basename(p) for p in glob.glob(os.path.join(s0, "*"))
               if os.path.isdir(p)}
    WLS = [w for w in WL_ORDER if w in present]
    if not WLS:
        sys.exit("no workload dirs under " + s0)
    data = {wl: {m: {k: [] for k in ("tput", "mean", "p99", "offl")}
                 for m in ("off", "on")} for wl in WLS}
    for wl in WLS:
        for s in spans:
            for m in ("off", "on"):
                d = base.parse(os.path.join(sweep, "span_%d" % s, wl, m,
                                            "%s.log" % role)) or {}
                for k in ("tput", "mean", "p99", "offl"):
                    data[wl][m][k].append(d.get(k))
    return spans, WLS, data


def style(ax):
    ax.grid(axis="y", color=GRID, lw=1, zorder=0)
    ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color(GRID)
    ax.tick_params(colors=MUTED, labelsize=9)


def span_ticklabels(spans):
    return ["S=%d\n%dB" % (s, internal_node_bytes(s)) for s in spans]


def contiguous_band(xs, ok):
    """Extent [lo,hi] of the contiguous True run in `ok` around/adjacent to the
    proposed point, in categorical x; None if nothing qualifies."""
    idxs = [i for i, v in enumerate(ok) if v]
    if not idxs:
        return None
    # widest contiguous run
    best = (idxs[0], idxs[0])
    run = (idxs[0], idxs[0])
    for i in idxs[1:]:
        if i == run[1] + 1:
            run = (run[0], i)
        else:
            run = (i, i)
        if run[1] - run[0] > best[1] - best[0]:
            best = run
    lo, hi = best
    return (xs[lo] - (0.5 if lo > 0 else 0.35),
            xs[hi] + (0.5 if hi < len(xs) - 1 else 0.35))


def fig_throughput(spans, WLS, data, ref_span, outdir):
    x = list(range(len(spans)))
    ref_ix = spans.index(ref_span) if ref_span in spans else None

    top = max((v for wl in WLS for m in ("off", "on")
               for v in data[wl][m]["tput"] if v is not None), default=1.0) * 1.15

    fig, axes = plt.subplots(1, len(WLS), figsize=(3.9 * len(WLS), 4.4),
                             squeeze=False, sharey=False)
    fig.patch.set_facecolor("white")

    for cix, wl in enumerate(WLS):
        ax = axes[0][cix]
        yo, yn = data[wl]["off"]["tput"], data[wl]["on"]["tput"]

        # proposed operating rate = one-sided throughput at the proposed span
        ref = yo[ref_ix] if (ref_ix is not None and yo[ref_ix] is not None) \
            else max((v for v in yo if v is not None), default=None)

        # reclaimed area between the curves
        ax.fill_between(x, yo, yn,
                        where=[o is not None and n is not None and n > o
                               for o, n in zip(yo, yn)],
                        interpolate=True, color=BAND, alpha=0.15, zorder=1)

        if ref:
            ax.axhline(ref, color=MUTED, lw=1.1, ls=(0, (4, 3)), zorder=2)
            # qualifying spans: throughput >= the proposed operating rate
            b_on = contiguous_band(x, [v is not None and v >= ref for v in yn])
            b_off = contiguous_band(x, [v is not None and v >= ref for v in yo])
            if b_on:
                ax.axvspan(b_on[0], b_on[1], ymin=0, ymax=1, color=BAND,
                           alpha=0.07, zorder=0)

        ax.plot(x, yo, "-o", color=C_OFF, lw=2.2, ms=7, mec="white", mew=1.5,
                label="one-sided (cache only)", zorder=3)
        ax.plot(x, yn, "-o", color=C_ON, lw=2.2, ms=7, mec="white", mew=1.5,
                label="offload (miss → RPC)", zorder=3)

        if ref_ix is not None:
            ax.axvline(ref_ix, color=INK, lw=1.0, ls=":", zorder=2)
            ax.annotate("proposed\nS=%d" % ref_span, (ref_ix, top),
                        textcoords="offset points", xytext=(4, -4),
                        ha="left", va="top", fontsize=8.5, color=INK)

        ax.set_ylim(0, top)
        ax.set_xlim(-0.35, len(spans) - 0.65)
        ax.set_xticks(x)
        ax.set_xticklabels(span_ticklabels(spans), fontsize=8.5)
        ax.set_title(wl, fontsize=11.5, color=INK, pad=6)
        ax.set_xlabel("inner-node size  →  (internalSpanSize, node bytes)",
                      fontsize=9.5, color=MUTED)
        if cix == 0:
            ax.set_ylabel("Throughput (Mops)   ↑ better", fontsize=11, color=INK)
        style(ax)

    h, l = axes[0][0].get_legend_handles_labels()
    if any(data[wl]["off"]["tput"][spans.index(ref_span)] is not None
           for wl in WLS if ref_span in spans):
        h.append(plt.Line2D([0], [0], color=MUTED, lw=1.1, ls=(0, (4, 3))))
        l.append("proposed operating rate")
    axes[0][0].legend(h, l, loc="lower center", frameon=False, fontsize=8.5)

    fig.suptitle("CHIME — offloading widens the inner-node operating range",
                 fontsize=14, color=INK, x=0.008, ha="left", y=0.985)
    fig.text(0.008, 0.9,
             "Cache fixed; inner-node size (internalSpanSize) swept.\nOne-sided "
             "caching meets the proposed rate only near S=%d; offloading holds "
             "it across a\nmuch wider range of geometries — a larger base than "
             "the single proposed configuration." % ref_span,
             fontsize=9.5, color=MUTED, ha="left", va="top")
    fig.tight_layout(rect=[0, 0, 1, 0.8])
    out = os.path.join(outdir, "chime_span_operating_point.png")
    fig.savefig(out, dpi=160, facecolor="white")
    plt.close(fig)
    print("wrote", out)


def fig_p99(spans, WLS, data, ref_span, outdir):
    x = list(range(len(spans)))
    ref_ix = spans.index(ref_span) if ref_span in spans else None
    top = max((v for wl in WLS for m in ("off", "on")
               for v in data[wl][m]["p99"] if v is not None), default=1.0) * 1.12

    fig, axes = plt.subplots(1, len(WLS), figsize=(3.9 * len(WLS), 4.2),
                             squeeze=False)
    fig.patch.set_facecolor("white")
    for cix, wl in enumerate(WLS):
        ax = axes[0][cix]
        for m, col, lbl in (("off", C_OFF, "one-sided"),
                            ("on", C_ON, "offload")):
            ys = data[wl][m]["p99"]
            xs = [xi for xi, y in zip(x, ys) if y is not None]
            yy = [y for y in ys if y is not None]
            ax.plot(xs, yy, "-o", color=col, lw=2.2, ms=7, mec="white",
                    mew=1.5, label=lbl, zorder=3)
        if ref_ix is not None:
            ax.axvline(ref_ix, color=INK, lw=1.0, ls=":", zorder=2)
        ax.set_ylim(0, top)
        ax.set_xlim(-0.35, len(spans) - 0.65)
        ax.set_xticks(x)
        ax.set_xticklabels(span_ticklabels(spans), fontsize=8.5)
        ax.set_title(wl, fontsize=11.5, color=INK, pad=6)
        ax.set_xlabel("inner-node size (internalSpanSize)", fontsize=9.5, color=MUTED)
        if cix == 0:
            ax.set_ylabel("p99 latency (µs)   ↓ better", fontsize=11, color=INK)
        style(ax)
    axes[0][0].legend(loc="upper center", frameon=False, fontsize=9)
    fig.suptitle("CHIME — p99 vs inner-node size", fontsize=13, color=INK,
                 x=0.01, ha="left", y=0.99)
    fig.tight_layout(rect=[0, 0, 1, 0.92])
    out = os.path.join(outdir, "chime_span_p99.png")
    fig.savefig(out, dpi=160, facecolor="white")
    plt.close(fig)
    print("wrote", out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sweep", nargs="?")
    ap.add_argument("--role", default="memory", choices=("memory", "compute"))
    ap.add_argument("--ref-span", type=int, default=PROPOSED_DEFAULT)
    ap.add_argument("--outdir", default=None)
    a = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    sweep = a.sweep or find_sweep(here, a.role)
    if not sweep or not os.path.isdir(sweep):
        sys.exit("no span_sweep dir found; pass one explicitly")
    outdir = a.outdir or here
    os.makedirs(outdir, exist_ok=True)
    print("sweep:", sweep, "| role:", a.role)

    spans, WLS, data = load(sweep, a.role)
    print("spans:", spans, "| workloads:", WLS)
    fig_throughput(spans, WLS, data, a.ref_span, outdir)
    fig_p99(spans, WLS, data, a.ref_span, outdir)


if __name__ == "__main__":
    main()
