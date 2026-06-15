#!/usr/bin/env python3
"""
plot_offload_vs_dart.py

Plot DEX latency (no-offload vs offload) against the DART reference across cache
sizes, and mark the "cliff": the cache size at which DEX *with offloading*
catches up to (drops below) DART. Lower latency is better.

The input CSV is normalized; this script rescales it to APPROXIMATE REAL
latencies (us) using per-operation factors calibrated to actually-measured
anchors from the local runs:
    point lookup @ 64 MB  ~ 2.9 us   (measured)
    range scan   @ 64 MB  ~ 14.1 us  (measured)
Scaling is uniform within each operation type, so DEX and DART are scaled by the
same factor -> the cliff (crossover cache size) is preserved exactly; only the
y-axis becomes realistic us instead of normalized units.

Input CSV columns:
  workload, cache_label, cache_MB,
  DEX_nooffload_us, DEX_offload_4mt_us, DART_ref_us,
  offload_le_DART, DEX_nooffload_source(projected|measured)

Usage:
  python3 plot_offload_vs_dart.py [csv_path] [out_png]
Defaults: csv next to this script (8_dex_offload_vs_dart.csv),
          out = dex_offload_vs_dart.png  (4 PNGs: one per workload)
"""
import csv
import math
import os
import sys
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")  # headless: write a PNG, no display needed
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))

# ---- approximate-real calibration -----------------------------------------
# Factor that maps normalized units -> microseconds, per operation type.
# Calibrated so the 64 MB point matches the measured local runs (see header).
POINT_SCALE = 2.50   # 2.9 us / 1.158 (point @64MB)
RANGE_SCALE = 13.20  # 14.1 us / 1.068 (range @64MB)


def scale_for(workload):
    return RANGE_SCALE if "Range" in workload else POINT_SCALE


def find_csv(arg):
    if arg:
        return arg
    for cand in (os.path.join(HERE, "8_dex_offload_vs_dart.csv"),
                 "8_dex_offload_vs_dart.csv"):
        if os.path.exists(cand):
            return cand
    sys.exit("CSV not found; pass its path as the first argument.")


csv_path = find_csv(sys.argv[1] if len(sys.argv) > 1 else None)
out_png = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "dex_offload_vs_dart.png")

# ---- load, group by workload, rescale to approximate real us ---------------
rows = defaultdict(list)
with open(csv_path, newline="") as f:
    for r in csv.DictReader(f):
        w = r["workload"]
        s = scale_for(w)
        rows[w].append({
            "cache": float(r["cache_MB"]),
            "noff": float(r["DEX_nooffload_us"]) * s,
            "off": float(r["DEX_offload_4mt_us"]) * s,
            "dart": float(r["DART_ref_us"]) * s,
            "src": r.get("DEX_nooffload_source", "").strip(),
        })
for w in rows:
    rows[w].sort(key=lambda d: d["cache"])


def cliff_cache(data, key="off"):
    """Interpolate the cache size (MB) where DEX[key] latency crosses DART."""
    for a, b in zip(data, data[1:]):
        if a[key] > a["dart"] >= b[key]:              # crossing above -> below
            x1, x2 = math.log2(a["cache"]), math.log2(b["cache"])
            y1, y2 = a[key], b[key]
            d = a["dart"]
            t = (y1 - d) / (y1 - y2) if y1 != y2 else 0.0
            return 2 ** (x1 + t * (x2 - x1))
    return None


def mb_label(mb):
    return f"{int(mb)}MB" if mb < 1024 else f"{mb / 1024:.0f}GB"


preferred = ["BTree-Point-Zipf", "BTree-Point-Uniform",
             "BTree-Range-Zipf", "BTree-Range-Uniform"]
order = [w for w in preferred if w in rows] or list(rows)

out_dir = os.path.dirname(out_png) or "."
out_base = os.path.splitext(os.path.basename(out_png))[0]

# ---- one PNG per workload --------------------------------------------------
print(f"{'workload':22s} {'no-offload cliff':>16s} {'offload cliff':>14s} {'cache saved':>12s}")
saved_files = []
for w in order:
    fig, ax = plt.subplots(figsize=(7, 5))
    d = rows[w]
    x = [r["cache"] for r in d]
    ax.plot(x, [r["noff"] for r in d], "-o", color="#1f77b4", label="DEX no-offload")
    ax.plot(x, [r["off"] for r in d], "-s", color="#2ca02c", label="DEX offload")
    dart = d[0]["dart"]
    ax.axhline(dart, ls="--", color="#d62728", label=f"DART ref ({dart:.2f} us)")

    # hollow markers on projected points (vs measured)
    for r in d:
        if r["src"] and r["src"] != "measured":
            ax.plot(r["cache"], r["noff"], "o", mfc="white", mec="#1f77b4", zorder=5)
            ax.plot(r["cache"], r["off"], "s", mfc="white", mec="#2ca02c", zorder=5)

    c = cliff_cache(d, "off")
    c0 = cliff_cache(d, "noff")
    if c:
        ax.axvline(c, ls=":", color="#2ca02c", alpha=0.8)
        ax.annotate(f"offload cliff\n~ {mb_label(c)}", xy=(c, dart),
                    xytext=(c * 1.05, dart * 1.04), fontsize=9, color="#2ca02c",
                    arrowprops=dict(arrowstyle="->", lw=0.8, color="#2ca02c"))
    if c0:
        ax.axvline(c0, ls=":", color="#1f77b4", alpha=0.5)
    saved = f"{c0 / c:.2f}x less" if (c and c0) else "-"
    print(f"{w:22s} {mb_label(c0) if c0 else '-':>16s} {mb_label(c) if c else '-':>14s} {saved:>12s}")

    ax.set_xscale("log", base=2)
    ax.set_xticks(x)
    ax.set_xticklabels([mb_label(v) for v in x], rotation=45)
    ax.set_title(f"{w}\nlatency vs cache (lower is better); cliff = DEX-offload catches DART",
                 fontsize=10)
    ax.set_xlabel("Cache size")
    ax.set_ylabel("Latency (us, approx. real)")
    ax.grid(True, which="both", ls=":", alpha=0.4)
    ax.legend(fontsize=8)

    fig.tight_layout()
    fname = os.path.join(out_dir, f"{out_base}__{w}.png")
    fig.savefig(fname, dpi=150)
    plt.close(fig)
    saved_files.append(fname)

# ---- write the approximate-real numbers back out as a CSV ------------------
real_csv = os.path.join(out_dir, f"{out_base}_real_us.csv")
with open(real_csv, "w", newline="") as f:
    wtr = csv.writer(f)
    wtr.writerow(["workload", "cache_MB", "DEX_nooffload_us", "DEX_offload_us",
                  "DART_ref_us", "offload_le_DART"])
    for w in order:
        for r in rows[w]:
            wtr.writerow([w, int(r["cache"]), f"{r['noff']:.2f}",
                          f"{r['off']:.2f}", f"{r['dart']:.2f}",
                          1 if r["off"] <= r["dart"] else 0])

print("\nSaved plots:")
for fpath in saved_files:
    print(f"  {fpath}")
print(f"Saved real-number CSV: {real_csv}")
