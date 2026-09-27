#!/usr/bin/env python3
"""
fair/collect.py <results_dir> -- merge the fair DEX / CHIME / DART sweep and
compare DEX and CHIME with DART.

Reads  <results_dir>/dart/dart.csv
       <results_dir>/dex/dex_compute.csv   (+ dex_memory.csv)
       <results_dir>/chime/sweep_mt<k>/summary_compute.csv (+ summary_memory.csv)
Writes <results_dir>/fair_all.csv       every cell, one schema, with ratio to DART
       <results_dir>/fair_summary.md    ratio tables and where each system first
                                        reaches DART
       <results_dir>/fig_dex_vs_dart.png, fig_chime_vs_dart.png,
       <results_dir>/fig_ratio_vs_dart.png

Ratio to DART = system throughput / DART throughput for the same workload and
cache size (DART has no memory threads). CHIME+ = the better of the two leaf
cache arms at each cell. For scans, DART's code returns one key per scan, so its
scan rate bounds a real 100-key DART scan from above and scan ratios understate
the B+trees.
"""
import csv, glob, os, re, sys
from collections import defaultdict

WORKLOADS = ["point-uniform", "point-zipf", "range-uniform", "range-zipf"]


def fnum(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def read_csv(path):
    if not os.path.exists(path):
        return []
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def peak_mn_active(log_path):
    """Peak 'AGGREGATE active = X%' in a memory-node log (DEX or CHIME tracker)."""
    best = None
    try:
        with open(log_path, errors="replace") as f:
            for line in f:
                m = re.search(r"AGGREGATE active = ([0-9.]+)%", line)
                if m:
                    v = float(m.group(1))
                    best = v if best is None or v > best else best
    except OSError:
        pass
    return best


def load(results):
    rows = []
    # ---- DART ---------------------------------------------------------------
    for r in read_csv(os.path.join(results, "dart", "dart.csv")):
        rows.append(dict(system="DART", workload=r["workload"], cache_mb=int(r["cache_mb"]),
                         memthreads=None, leaf=None, tput=fnum(r["tput_mops"]),
                         p99=fnum(r["p99_us"]), mn_active=0.0, log=r["log"]))
    # ---- DEX ----------------------------------------------------------------
    mn = {}
    for r in read_csv(os.path.join(results, "dex", "dex_memory.csv")):
        mn[(r["workload"], int(r["cache_mb"]), int(r["memthreads"]))] = fnum(r["mn_peak_active_pct"])
    for r in read_csv(os.path.join(results, "dex", "dex_compute.csv")):
        k = (r["workload"], int(r["cache_mb"]), int(r["memthreads"]))
        rows.append(dict(system="DEX", workload=r["workload"], cache_mb=k[1], memthreads=k[2],
                         leaf=None, tput=fnum(r["tput_mops"]), p99=fnum(r["p99_us"]),
                         mn_active=mn.get(k), log=r["log"],
                         height=r.get("tree_height"), inner=r.get("inner_entries"),
                         leafent=r.get("leaf_entries")))
    # ---- CHIME --------------------------------------------------------------
    for d in sorted(glob.glob(os.path.join(results, "chime", "sweep_mt*"))):
        mt = int(re.search(r"sweep_mt(\d+)$", d).group(1))
        mem_logs = {}
        for r in read_csv(os.path.join(d, "summary_memory.csv")):
            mem_logs[(r["workload"], r["cache_mb"], r["cache_leaf"])] = r.get("log")
        for r in read_csv(os.path.join(d, "summary_compute.csv")):
            key = (r["workload"], r["cache_mb"], r["cache_leaf"])
            ml = mem_logs.get(key)
            rows.append(dict(system="CHIME", workload=r["workload"], cache_mb=int(r["cache_mb"]),
                             memthreads=mt, leaf=int(r["cache_leaf"]),
                             tput=fnum(r["node_tput_mops"]), p99=fnum(r["p99_us"]),
                             mn_active=peak_mn_active(ml) if ml else None, log=r.get("log"),
                             inner_mb=r.get("inner_cache_mb"), leaf_mb=r.get("leaf_cache_mb"),
                             leaf_hit=r.get("leaf_hit_pct")))
    return rows


def best_chime(rows):
    """CHIME+ = the better leaf-cache arm per (workload, cache, memthreads)."""
    best = {}
    for r in rows:
        if r["system"] != "CHIME" or r["tput"] is None:
            continue
        k = (r["workload"], r["cache_mb"], r["memthreads"])
        if k not in best or r["tput"] > best[k]["tput"]:
            best[k] = r
    return best


def main():
    results = sys.argv[1] if len(sys.argv) > 1 else "."
    rows = load(results)
    if not rows:
        sys.exit(f"no results under {results}")

    dart = {(r["workload"], r["cache_mb"]): r for r in rows if r["system"] == "DART"}

    def ratio(r):
        d = dart.get((r["workload"], r["cache_mb"]))
        if d and d["tput"] and r["tput"] is not None:
            return r["tput"] / d["tput"]
        return None

    # ---- fair_all.csv -------------------------------------------------------
    out_csv = os.path.join(results, "fair_all.csv")
    cols = ["system", "workload", "cache_mb", "memthreads", "leaf", "tput", "p99",
            "ratio_vs_dart", "mn_active", "log"]
    with open(out_csv, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(cols)
        for r in sorted(rows, key=lambda r: (r["system"], r["workload"], r["cache_mb"],
                                              r["memthreads"] if r["memthreads"] is not None else -1,
                                              r["leaf"] if r["leaf"] is not None else -1)):
            rv = ratio(r)
            w.writerow([r["system"], r["workload"], r["cache_mb"], r["memthreads"], r["leaf"],
                        r["tput"], r["p99"], f"{rv:.3f}" if rv else "", r["mn_active"], r["log"]])

    dex = {(r["workload"], r["cache_mb"], r["memthreads"]): r for r in rows if r["system"] == "DEX"}
    chime = best_chime(rows)
    caches = sorted({r["cache_mb"] for r in rows})
    mts = sorted({r["memthreads"] for r in rows if r["memthreads"] is not None})

    # ---- fair_summary.md ----------------------------------------------------
    lines = ["# Fair sweep: DEX and CHIME against DART", "",
             f"Results: `{results}`. Each cell is throughput / DART's throughput at the same",
             "workload and cache size. Above 1.00 = faster than DART. Memory threads 0 = no",
             "offloading. CHIME+ = the better leaf-cache arm. DART scans return one key, so",
             "scan ratios understate the B+trees.", ""]
    for sysname, table in (("DEX", dex), ("CHIME+", chime)):
        lines += [f"## {sysname}", ""]
        for wl in WORKLOADS:
            lines += [f"### {wl}", "",
                      "| memory threads | " + " | ".join(f"{c} MB" for c in caches) + " |",
                      "|---|" + "---:|" * len(caches)]
            for mt in mts:
                cells = []
                for c in caches:
                    r = table.get((wl, c, mt))
                    rv = ratio(r) if r else None
                    cells.append(f"**{rv:.2f}**" if rv and rv >= 1 else (f"{rv:.2f}" if rv else "-"))
                lines.append(f"| {mt} | " + " | ".join(cells) + " |")
            # first point reaching DART
            first = None
            for mt in mts:
                for c in caches:
                    r = table.get((wl, c, mt))
                    rv = ratio(r) if r else None
                    if rv and rv >= 1 and (first is None or (c, mt) < (first[0], first[1])):
                        first = (c, mt)
            lines += ["", f"Reaches DART first at: {f'{first[0]} MB with {first[1]} memory threads' if first else 'not reached'}", ""]
    with open(os.path.join(results, "fair_summary.md"), "w") as f:
        f.write("\n".join(lines) + "\n")

    # ---- figures -------------------------------------------------------------
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        from matplotlib.colors import LinearSegmentedColormap, TwoSlopeNorm
    except ImportError:
        print("matplotlib not installed; wrote CSV and summary only")
        return

    INK, INK2, MUTED, GRID = "#0b0b0b", "#52514e", "#898781", "#e1e0d9"
    # Memory threads are a magnitude: one hue, light -> dark (reference blue ramp).
    BLUES = ["#86b6ef", "#6da7ec", "#5598e7", "#3987e5", "#2a78d6", "#256abf", "#184f95", "#0d366b"]
    plt.rcParams.update({"font.size": 9, "axes.edgecolor": "#c3c2b7", "axes.labelcolor": INK2,
                         "xtick.color": INK2, "ytick.color": INK2, "axes.grid": True,
                         "grid.color": GRID, "grid.linewidth": 0.6})

    def series_color(mt, nonzero):
        if mt == 0:
            return MUTED
        return BLUES[min(len(BLUES) - 1, nonzero.index(mt) * len(BLUES) // max(1, len(nonzero)))]

    def line_fig(table, name, fname):
        nonzero = [m for m in mts if m != 0]
        ymax = 0
        for wl in WORKLOADS:
            for c in caches:
                for mt in mts:
                    r = table.get((wl, c, mt))
                    if r and r["tput"]:
                        ymax = max(ymax, r["tput"])
                d = dart.get((wl, c))
                if d and d["tput"]:
                    ymax = max(ymax, d["tput"])
        fig, axes = plt.subplots(1, 4, figsize=(15, 3.8), sharey=True)
        for ax, wl in zip(axes, WORKLOADS):
            for mt in mts:
                xs, ys = [], []
                for c in caches:
                    r = table.get((wl, c, mt))
                    if r and r["tput"] is not None:
                        xs.append(c); ys.append(r["tput"])
                if xs:
                    ax.plot(xs, ys, color=series_color(mt, nonzero), lw=2,
                            ls="--" if mt == 0 else "-", marker="o", ms=4,
                            label="no offloading" if mt == 0 else
                            f"{mt} memory thread" + ("" if mt == 1 else "s"))
            dx = [c for c in caches if (wl, c) in dart and dart[(wl, c)]["tput"]]
            if dx:
                ax.plot(dx, [dart[(wl, c)]["tput"] for c in dx], color=INK, lw=2, ls=":",
                        label="DART" + (" (1-key scan)" if wl.startswith("range") else ""))
            ax.set_xscale("log", base=2)
            ax.set_xticks(caches); ax.set_xticklabels([str(c) for c in caches])
            ax.set_ylim(0, ymax * 1.08 if ymax else 1)
            ax.set_title(wl, color=INK, fontsize=10)
            ax.set_xlabel("total compute-side cache (MB)")
        axes[0].set_ylabel("throughput (Mops)")
        h, l = axes[0].get_legend_handles_labels()
        fig.legend(h, l, loc="upper center", ncol=min(len(l), 6), frameon=False,
                   bbox_to_anchor=(0.5, 1.06))
        fig.suptitle(f"{name} against DART (same data, same tree shape, same threads)",
                     y=1.13, color=INK, fontsize=11)
        fig.savefig(os.path.join(results, fname), dpi=150, bbox_inches="tight")
        plt.close(fig)

    line_fig(dex, "DEX", "fig_dex_vs_dart.png")
    line_fig(chime, "CHIME+", "fig_chime_vs_dart.png")

    # Ratio heatmaps: diverging red (< 1, slower than DART) <-> blue (> 1), gray at 1.
    cmap = LinearSegmentedColormap.from_list("ratio", ["#e34948", "#f0efec", "#2a78d6"])
    fig, axes = plt.subplots(2, 4, figsize=(15, 6.5))
    vals = []
    for table in (dex, chime):
        for wl in WORKLOADS:
            for mt in mts:
                for c in caches:
                    r = table.get((wl, c, mt))
                    rv = ratio(r) if r else None
                    if rv:
                        vals.append(rv)
    lo = min(vals + [0.5]); hi = max(vals + [2.0])
    norm = TwoSlopeNorm(vmin=min(lo, 0.99), vcenter=1.0, vmax=max(hi, 1.01))
    im = None
    for row, (sysname, table) in enumerate((("DEX", dex), ("CHIME+", chime))):
        for col, wl in enumerate(WORKLOADS):
            ax = axes[row][col]
            grid = [[(ratio(table[(wl, c, mt)]) if (wl, c, mt) in table else None) or float("nan")
                     for c in caches] for mt in mts]
            im = ax.imshow(grid, cmap=cmap, norm=norm, aspect="auto", origin="lower")
            for i, mt in enumerate(mts):
                for j, c in enumerate(caches):
                    v = grid[i][j]
                    if v == v:
                        ax.text(j, i, f"{v:.2f}", ha="center", va="center", fontsize=7, color=INK)
            ax.set_xticks(range(len(caches))); ax.set_xticklabels([str(c) for c in caches])
            ax.set_yticks(range(len(mts))); ax.set_yticklabels([str(m) for m in mts])
            ax.grid(False)
            ax.set_title(f"{sysname}: {wl}", color=INK, fontsize=10)
            if row == 1: ax.set_xlabel("cache (MB)")
            if col == 0: ax.set_ylabel("memory threads (0 = off)")
    cb = fig.colorbar(im, ax=axes, shrink=0.8)
    cb.set_label("throughput / DART  (1.0 = level with DART)")
    fig.savefig(os.path.join(results, "fig_ratio_vs_dart.png"), dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"wrote {out_csv}, fair_summary.md and 3 figures under {results}")


if __name__ == "__main__":
    main()
