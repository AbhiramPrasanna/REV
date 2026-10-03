#!/usr/bin/env python3
"""Challenge 1 with 40 clients (measured) and 80 requests in flight (predicted).

Push is a closed loop: N requests in flight, each spending Z outside the memory
node (network + client) and S of memory-core CPU on one of C cores. Mean-value
analysis with Seidmann's approximation for the C-core station. Two constants per
system, both from c1_results.csv:
  S = cores / push throughput at 2 cores (the cores are 100% busy there)
  Z = fitted so the 40-client curve passes through the measured 8-core point
DEX pull is NIC-bound: one queue (the NIC, demand D) + delay, fitted to the
1-client latency (2.78 us, m_t1dex) and the 40-client throughput.
CHIME pull is limited by CHIME's own compute-side work, which this model does
not cover; at 80 it is drawn unchanged, as an assumption.

  python plot_c1_predict.py c1_results.csv   -> fig_c1_80clients.png / .pdf
"""
import csv, os, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FixedLocator, FixedFormatter

PULL, PUSH, MUTED, GRID, INK = "#2f6fdb", "#e8743b", "#6b6b6b", "#e6e6e6", "#1f1f1f"
CORES = [1, 2, 4, 8]
XS = [1, 2, 4, 8, 16]
DEX_PULL_1CLIENT_US = 2.78


def mva(N, C, S, Z):
    """closed loop, delay Z + C-server station (Seidmann). Returns throughput (Mops)."""
    dq, dd, q = S / C, Z + S * (C - 1) / C, 0.0
    for n in range(1, N + 1):
        r = dq * (1 + q)
        x = n / (dd + r)
        q = x * r
    return x


def fit(f, target, lo, hi, increasing=True):
    for _ in range(80):
        mid = (lo + hi) / 2
        if (f(mid) < target) == increasing:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2


def load(path):
    d = {}
    with open(path) as fh:
        for r in csv.DictReader(fh):
            d[(r["block"], int(float(r["memthreads"])))] = float(r["tput_mops"])
    return d


def cross(fx, level, lo=1.0, hi=16.0):
    """first core count (0.05 steps) where fx(c) >= level, else None"""
    c = lo
    while c <= hi + 1e-9:
        if fx(c) >= level:
            return c
        c += 0.05
    return None


def main():
    d = load(sys.argv[1])
    systems = [
        ("Page B+tree · DEX", "c1_dexr_model_warm", "c1_dexr_model_warm", None),
        ("Hashed-leaf B+tree · CHIME", "c1_chime_model_pull", "c1_chime_model_push", "c1_chime_model_pull_nohot"),
    ]
    fig, axes = plt.subplots(1, 2, figsize=(11.5, 4.6), sharey=True)
    notes = []
    for ax, (title, pblk, sblk, nohot) in zip(axes, systems):
        meas = {c: d[(sblk, c)] for c in CORES if (sblk, c) in d}
        S = 2 / meas[2]
        Z = fit(lambda z: mva(40, 8, S, z), meas[8], 0.0, 60.0, increasing=False)
        grid = [1 + i * 0.05 for i in range(int(15 / 0.05) + 1)]
        p40 = lambda c: mva(40, c, S, Z)
        p80 = lambda c: mva(80, c, S, Z)
        pull40 = d[(pblk, 0)]
        # pull
        ax.plot(XS, [pull40] * len(XS), color=PULL, lw=2, marker="o", ms=5,
                markeredgecolor="white", label=f"Pull, 40 clients (measured {pull40:.1f})")
        if nohot:
            pull80 = pull40
            ph = d[(nohot, 0)]
            ax.plot(XS, [ph] * len(XS), color=PULL, lw=1.5, ls="--", marker="o", ms=5, mfc="white",
                    label=f"Pull, hotspot buffer off, 40 clients (measured {ph:.1f})")
            ax.text(0.97, 0.03, "CHIME pull at 80: not predicted (limited by CHIME's own\n"
                    "compute-side work); drawn unchanged", transform=ax.transAxes,
                    ha="right", va="bottom", fontsize=7, color=MUTED)
        else:
            D = fit(lambda dd: mva(40, 1, dd, DEX_PULL_1CLIENT_US - dd), pull40, 1e-4, 0.2, increasing=False)
            pull80 = mva(80, 1, D, DEX_PULL_1CLIENT_US - D)
            ax.plot(XS, [pull80] * len(XS), color=PULL, lw=1.5, ls=(0, (1, 2)),
                    label=f"Pull, 80 in flight (predicted {pull80:.1f}: NIC-bound)")
        # push
        ax.plot(list(meas), list(meas.values()), ls="none", color=PUSH, marker="s", ms=7,
                markeredgecolor="white", label="Push, 40 clients (measured)")
        ax.plot(grid, [p40(c) for c in grid], color=PUSH, lw=1.8,
                label=f"Push, 40 clients (fit: {S:.2f} µs per request, {Z + S:.1f} µs per push)")
        ax.plot(grid, [p80(c) for c in grid], color=PUSH, lw=1.8, ls="--",
                label="Push, 80 in flight (predicted)")
        for c in (10, 16):
            ax.plot([c], [p80(c)], marker="s", ms=5, color=PUSH, mfc="white")
            ax.annotate(f"{p80(c):.1f}", (c, p80(c)), xytext=(0, 6), textcoords="offset points",
                        ha="center", fontsize=7, color=PUSH)
            ax.annotate(f"{p40(c):.1f}", (c, p40(c)), xytext=(0, -11), textcoords="offset points",
                        ha="center", fontsize=7, color=PUSH)
        # crossings
        refs = [("pull", pull80)] + ([("buffer-off pull", d[(nohot, 0)])] if nohot else [])
        for name, lvl in refs:
            c40, c80 = cross(p40, lvl), cross(p80, lvl)
            notes.append(f"{title.split('· ')[1]}: push reaches {name} ({lvl:.1f}) at "
                         + (f"{c40:.1f} cores with 40 clients" if c40 else "no core count with 40 clients")
                         + "; " + (f"{c80:.1f} cores with 80 in flight" if c80 else "never with 80 in flight"))
            if c80:
                ax.axvline(c80, color=PUSH, lw=0.8, ls=":", alpha=0.6)
        ax.set_xscale("log", base=2); ax.set_yscale("log")
        ax.set_xticks(XS, [str(c) for c in XS]); ax.set_xlim(0.85, 19)
        ax.set_ylim(1, 50)
        ax.yaxis.set_major_locator(FixedLocator([1, 2, 5, 10, 20, 50]))
        ax.yaxis.set_major_formatter(FixedFormatter(["1", "2", "5", "10", "20", "50"]))
        ax.yaxis.set_minor_formatter(FixedFormatter([]))
        ax.set_title(title, fontsize=10.5, color=INK, loc="left")
        ax.set_xlabel("Memory-node cores", fontsize=9, color=MUTED)
        ax.grid(True, which="major", color=GRID, lw=0.8); ax.set_axisbelow(True)
        for s in ("top", "right"):
            ax.spines[s].set_visible(False)
        ax.tick_params(labelsize=8.5, colors=MUTED)
        ax.legend(fontsize=7, frameon=False, loc="upper left")
        print(f"{title}: S={S:.3f} us, Z={Z:.2f} us; push 40: " +
              ", ".join(f"{c}:{p40(c):.2f}" for c in (1, 2, 4, 8, 10, 16)) + "; push 80: " +
              ", ".join(f"{c}:{p80(c):.2f}" for c in (1, 2, 4, 8, 10, 16)) + f"; pull 80 {pull80:.2f}")
    axes[0].set_ylabel("Lookup throughput (Mops)", fontsize=9, color=MUTED)
    fig.suptitle("Challenge 1 · 40 clients (measured) vs 80 requests in flight (predicted)",
                 fontsize=10.5, color=INK, x=0.01, ha="left")
    fig.tight_layout()
    fig.subplots_adjust(bottom=0.12 + 0.035 * len(notes))
    fig.text(0.01, 0.01, "\n".join(notes) +
             "\n80 in flight = 2 requests per client thread on the same 40 cores; assumes client-side work "
             "per lookup does not grow.", fontsize=7.5, color=MUTED, va="bottom")
    for n in notes:
        print(" ", n)
    base = os.path.join(os.path.dirname(os.path.abspath(sys.argv[1])), "fig_c1_80clients")
    for ext in (".png", ".pdf"):
        target = base + ext
        for i in range(2, 50):
            try:
                fig.savefig(target, dpi=150); break
            except OSError:
                target = f"{base}_v{i}{ext}"
        print("wrote", target)


if __name__ == "__main__":
    main()
