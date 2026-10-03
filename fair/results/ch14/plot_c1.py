#!/usr/bin/env python3
"""Challenge 1, measured only, laid out like measurement-summary-with-plots.pdf Fig. 1:
one panel per structure, lookup throughput vs memory-node cores, pull (warm cache)
vs push (every lookup one request to the memory node). No model lines.

  python plot_c1.py c1_results.csv        -> fig_c1_measured.png / .pdf next to it
"""
import csv, os, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FixedLocator, FixedFormatter

PULL, PUSH, MUTED, GRID, INK = "#2f6fdb", "#e8743b", "#6b6b6b", "#e6e6e6", "#1f1f1f"
CORES = [1, 2, 4, 8]
PANELS = [  # title, pull block, push block, extra pull block (label)
    ("Page B+tree · DEX", "c1_dexr_model_warm", "c1_dexr_model_warm", None),
    ("Hashed-leaf B+tree · CHIME", "c1_chime_model_pull", "c1_chime_model_push",
     ("c1_chime_model_pull_nohot", "Pull, warm cache, hotspot buffer off")),
]


def load(path):
    out = {}
    with open(path) as f:
        for r in csv.DictReader(f):
            out[(r["block"], int(float(r["memthreads"])))] = float(r["tput_mops"])
    return out


def crossing(pull, pts):
    """cores where the push line reaches `pull` (linear between measured points), or None."""
    for (c0, v0), (c1, v1) in zip(pts, pts[1:]):
        if v0 < pull <= v1:
            return c0 + (pull - v0) / (v1 - v0) * (c1 - c0)
    return None


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    d = load(sys.argv[1])
    fig, axes = plt.subplots(1, 2, figsize=(10.5, 4.2), sharey=True)
    for ax, (title, pblk, sblk, extra) in zip(axes, PANELS):
        pull = d.get((pblk, 0))
        push = [(c, d[(sblk, c)]) for c in CORES if (sblk, c) in d]
        if pull is not None:
            ax.plot(CORES, [pull] * len(CORES), color=PULL, lw=2, marker="o", ms=6,
                    markeredgecolor="white", label="Pull, warm cache")
        if extra and (extra[0], 0) in d:
            ax.plot(CORES, [d[(extra[0], 0)]] * len(CORES), color=PULL, lw=1.6, ls="--",
                    marker="o", ms=5, mfc="white", label=extra[1])
        if push:
            ax.plot(*zip(*push), color=PUSH, lw=2, marker="s", ms=6,
                    markeredgecolor="white", label="Push, every lookup")
        # the summary line in the corner, as in the PDF
        lines = []
        if pull is not None and push:
            x = crossing(pull, push)
            top = push[-1]
            lines.append(f"push matches pull at {x:.1f} cores" if x else
                         f"push stays below pull:\n{top[1] / pull:.0%} of it at {top[0]} cores")
            if extra and (extra[0], 0) in d:
                p2 = d[(extra[0], 0)]
                x2 = crossing(p2, push)
                lines.append(f"buffer off: push matches pull at {x2:.1f} cores" if x2 else
                             f"buffer off: push reaches {top[1] / p2:.0%} of pull at {top[0]} cores")
        ax.text(0.97, 0.05, "\n".join(lines), transform=ax.transAxes, ha="right", va="bottom",
                fontsize=8, color=MUTED)
        ax.set_xscale("log", base=2)
        ax.set_yscale("log")
        ax.set_xticks(CORES, [str(c) for c in CORES])
        ax.set_xlim(0.85, 9.5)
        ax.set_ylim(1, 20)
        ax.yaxis.set_major_locator(FixedLocator([1, 2, 5, 10, 20]))
        ax.yaxis.set_major_formatter(FixedFormatter(["1", "2", "5", "10", "20"]))
        ax.yaxis.set_minor_formatter(FixedFormatter([]))
        ax.set_title(title, fontsize=10.5, color=INK, loc="left")
        ax.set_xlabel("Memory-node cores", fontsize=9, color=MUTED)
        ax.grid(True, which="major", color=GRID, lw=0.8)
        ax.set_axisbelow(True)
        for s in ("top", "right"):
            ax.spines[s].set_visible(False)
        ax.tick_params(labelsize=8.5, colors=MUTED)
        ax.legend(fontsize=7.8, frameon=False, loc="upper left")
    axes[0].set_ylabel("Lookup throughput (Mops)", fontsize=9, color=MUTED)
    fig.suptitle("Challenge 1 · push needs memory-node CPU (measured, 40 clients, warm cache, uniform keys)",
                 fontsize=10.5, color=INK, x=0.01, ha="left")
    fig.tight_layout()
    base = os.path.join(os.path.dirname(os.path.abspath(sys.argv[1])), "fig_c1_measured")
    for ext in (".png", ".pdf"):
        target = base + ext
        for i in range(2, 50):
            try:
                fig.savefig(target, dpi=150)
                break
            except OSError:
                target = f"{base}_v{i}{ext}"
        print("wrote", target)


if __name__ == "__main__":
    main()
