#!/usr/bin/env python3
"""
compare_chime_dart.py — overlay CHIME (offload off & on) vs DART at 16/32/64 MB.

Answers: at the SAME cache budget, SAME dataset (30M x 8B keys x 48B values) and
SAME workload, can CHIME -- especially with offloading -- catch up to DART as the
compute-side cache is stressed from "fits the index" (64 MB) down to 16 MB?

INPUTS
  CHIME : a sweep directory from run/run_cache_stress.sh, i.e.
            <dir>/summary_memory.csv, <dir>/summary_compute.csv   (throughput)
            <dir>/[cache_<MB>/]<workload>/<off|on>/compute.log    (mean latency)
          Cluster throughput per cell = memory node_tput + compute node_tput.
          Mean latency comes from the compute log's '[ALL OPS] -> ALL' row
          (DART reports MEAN latency, so we compare mean-to-mean, not p99).
  DART  : the CSV from script/cache_sweep_compare.sh
            dist,op,cache_total_mb,...,throughput_mops,latency_us
          (dist in {uniform,zipf99}, op in {lookup,scan}; latency_us = mean).

OUTPUT
  compare_chime_dart.png : 2 rows (throughput, mean latency) x 4 workload cols.
  Grouped bars: at each cache size {64,32,16}, three bars -- CHIME off, CHIME on,
  DART. Throughput higher = better; latency lower = better. Per the project
  convention every axis STARTS AT 0 and each metric row SHARES one y-scale across
  all four workloads, so panels are directly comparable.

USAGE
  python3 compare_chime_dart.py CHIME_SWEEP_DIR DART_CSV [--out compare_chime_dart.png]
  python3 compare_chime_dart.py --dart DART_CSV        # auto-find newest CHIME sweep
"""
import argparse, csv, glob, os, re, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# workload canonical order + the (dist,op) -> workload mapping for DART rows
WL_ORDER = ["point-uniform", "point-zipf", "range-uniform", "range-zipf"]
WL_TITLE = {"point-uniform": "point / uniform", "point-zipf": "point / zipf-0.99",
            "range-uniform": "range / uniform", "range-zipf": "range / zipf-0.99"}
DART_WL = {("uniform", "lookup"): "point-uniform", ("zipf99", "lookup"): "point-zipf",
           ("uniform", "scan"): "range-uniform", ("zipf99", "scan"): "range-zipf"}

# series colors: CHIME off (blue), CHIME on (green), DART (amber) -- brand-neutral
C_CHIME_OFF, C_CHIME_ON, C_DART = "#2a78d6", "#1baf7a", "#e08a1e"
INK, GRID, MUTED = "#222222", "#dddddd", "#888888"
MEAN_RX = re.compile(r"mean=\s*([0-9.]+)us")


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def find_newest_chime_sweep():
    roots = ["CHIME/build/results/cache_stress", "CHIME/build/results/offload_ab"]
    cands = []
    for r in roots:
        cands += glob.glob(os.path.join(r, "sweep_*"))
    if not cands:
        return None
    return max(cands, key=os.path.getmtime)


def load_chime(sweep_dir):
    """-> {(cache_mb:int, workload, offload): {'tput':float|None, 'mean':float|None}}"""
    out = {}
    # throughput: sum the two nodes' node_tput_mops for each cell
    for role in ("memory", "compute"):
        csv_path = os.path.join(sweep_dir, f"summary_{role}.csv")
        if not os.path.isfile(csv_path):
            continue
        with open(csv_path, newline="") as f:
            for row in csv.DictReader(f):
                c = num(row.get("cache_mb"))
                if c is None:
                    continue
                key = (int(c), row["workload"], row["offload"])
                d = out.setdefault(key, {"tput": None, "mean": None})
                t = num(row.get("node_tput_mops"))
                if t is not None:
                    d["tput"] = (d["tput"] or 0.0) + t
    # mean latency: parse the compute per-cell log
    for key in list(out.keys()):
        c, wl, off = key
        for cand in (os.path.join(sweep_dir, f"cache_{c}MB", wl, off, "compute.log"),
                     os.path.join(sweep_dir, wl, off, "compute.log")):
            if os.path.isfile(cand):
                out[key]["mean"] = parse_mean(cand)
                break
    return out


def parse_mean(path):
    """Pull mean (µs) from the '[ALL OPS]' -> '  ALL ' row of a micro_test log."""
    try:
        with open(path, errors="ignore") as f:
            in_block = False
            for line in f:
                if line.startswith("[ALL OPS]"):
                    in_block = True
                    continue
                if in_block and line.lstrip().startswith("ALL "):
                    m = MEAN_RX.search(line)
                    return float(m.group(1)) if m else None
    except OSError:
        return None
    return None


def load_dart(csv_path):
    """-> {(cache_mb:int, workload): {'tput':float|None, 'mean':float|None}}"""
    out = {}
    with open(csv_path, newline="") as f:
        for row in csv.DictReader(f):
            wl = DART_WL.get((row["dist"], row["op"]))
            if wl is None:
                continue
            c = num(row.get("cache_total_mb"))
            if c is None:
                continue
            out[(int(c), wl)] = {"tput": num(row.get("throughput_mops")),
                                 "mean": num(row.get("latency_us"))}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("chime_dir", nargs="?", help="CHIME run_cache_stress sweep dir")
    ap.add_argument("dart_csv", nargs="?", help="DART cache_sweep_compare CSV")
    ap.add_argument("--dart", help="DART CSV (alt to positional)")
    ap.add_argument("--out", default="compare_chime_dart.png")
    ap.add_argument("--caches", default="64,32,16", help="cache MB points, high->low")
    args = ap.parse_args()

    chime_dir = args.chime_dir or find_newest_chime_sweep()
    dart_csv = args.dart_csv or args.dart
    if not chime_dir or not os.path.isdir(chime_dir):
        sys.exit("CHIME sweep dir not found; pass it explicitly.")
    if not dart_csv or not os.path.isfile(dart_csv):
        sys.exit("DART CSV not found; pass it as arg 2 or --dart.")

    caches = [int(x) for x in args.caches.split(",")]
    chime = load_chime(chime_dir)
    dart = load_dart(dart_csv)

    # assemble series[metric][workload] = {'chime_off':[...],'chime_on':[...],'dart':[...]}
    series = {}
    for metric in ("tput", "mean"):
        series[metric] = {}
        for wl in WL_ORDER:
            g = {"chime_off": [], "chime_on": [], "dart": []}
            for c in caches:
                g["chime_off"].append((chime.get((c, wl, "off")) or {}).get(metric))
                g["chime_on"].append((chime.get((c, wl, "on")) or {}).get(metric))
                g["dart"].append((dart.get((c, wl)) or {}).get(metric))
            series[metric][wl] = g

    def top(metric):
        vals = [v for wl in WL_ORDER for grp in series[metric][wl].values()
                for v in grp if v is not None]
        return max(vals) * 1.15 if vals else 1.0

    tops = {m: top(m) for m in ("tput", "mean")}
    row_meta = [("tput", "throughput (Mops)  ↑ better"),
                ("mean", "mean latency (µs)  ↓ better")]

    fig, axes = plt.subplots(2, 4, figsize=(18, 8), sharex=True)
    x = range(len(caches))
    w = 0.26
    bar_defs = [("chime_off", C_CHIME_OFF, "CHIME offload off"),
                ("chime_on", C_CHIME_ON, "CHIME offload on"),
                ("dart", C_DART, "DART")]

    for r, (metric, ylab) in enumerate(row_meta):
        for col, wl in enumerate(WL_ORDER):
            ax = axes[r][col]
            g = series[metric][wl]
            for i, (k, color, _lab) in enumerate(bar_defs):
                xs = [xi + (i - 1) * w for xi in x]
                ys = [v if v is not None else 0.0 for v in g[k]]
                bars = ax.bar(xs, ys, w, color=color, edgecolor="white", linewidth=0.5)
                for xi, v in zip(xs, g[k]):
                    if v is None:
                        ax.text(xi, tops[metric] * 0.02, "×", ha="center",
                                va="bottom", color=MUTED, fontsize=9)
            ax.set_ylim(0, tops[metric])                 # axes start at 0, shared scale
            ax.set_xticks(list(x))
            ax.set_xticklabels([f"{c}MB" for c in caches])
            ax.grid(axis="y", color=GRID, linewidth=0.8)
            ax.set_axisbelow(True)
            for s in ("top", "right"):
                ax.spines[s].set_visible(False)
            if r == 0:
                ax.set_title(WL_TITLE[wl], color=INK, fontsize=12)
            if col == 0:
                ax.set_ylabel(ylab, color=INK, fontsize=11)

    handles = [plt.Rectangle((0, 0), 1, 1, color=c) for _, c, _ in bar_defs]
    fig.legend(handles, [l for _, _, l in bar_defs], loc="upper center",
               ncol=3, frameon=False, fontsize=11, bbox_to_anchor=(0.5, 1.02))
    fig.suptitle("CHIME vs DART — cache 64→32→16 MB (same dataset, same workload)",
                 y=1.06, fontsize=13, color=INK)
    fig.text(0.5, -0.01,
             "x = compute-side cache budget (stressed left→right).  "
             "× = missing/failed cell.  Latency = MEAN (both systems).",
             ha="center", color=MUTED, fontsize=9)
    fig.tight_layout()
    fig.savefig(args.out, dpi=140, bbox_inches="tight")
    print(f"wrote {args.out}")
    print(f"  CHIME sweep : {chime_dir}")
    print(f"  DART CSV    : {dart_csv}")


if __name__ == "__main__":
    main()
