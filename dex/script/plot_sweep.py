#!/usr/bin/env python3
"""
plot_sweep.py -- visualize the DEX offloading sweep (build/results/summary.csv).

Produces (into build/results/plots/):
  1. throughput_vs_cache.png   throughput vs cache size, offload on vs off (2x2)
  2. latency_vs_cache.png      p99 latency vs cache size, on vs off (2x2)  <-- "operating point" vs caching
  3. reads_per_op_vs_cache.png the mechanism: RDMA reads/op collapsing under offload (2x2)
  4. operating_points.png      throughput-vs-p99 scatter (down-right = better)
  5. dex_config_and_offload.png  the tree config (node sizes) + how offload works

Run from the repo root or build/:  python script/plot_sweep.py
"""
import csv, os, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

# ---- locate summary.csv ----------------------------------------------------
HERE = os.path.dirname(os.path.abspath(__file__))
CANDS = [
    os.path.join(HERE, "..", "build", "results", "summary.csv"),
    os.path.join(os.getcwd(), "results", "summary.csv"),
    os.path.join(os.getcwd(), "build", "results", "summary.csv"),
    os.path.join(os.getcwd(), "summary.csv"),
]
csv_path = next((p for p in CANDS if os.path.isfile(p)), None)
if not csv_path:
    sys.exit("summary.csv not found in: " + " ; ".join(os.path.abspath(p) for p in CANDS))
OUT = os.path.join(os.path.dirname(os.path.abspath(csv_path)), "plots")
os.makedirs(OUT, exist_ok=True)
print("reading", os.path.abspath(csv_path))
print("writing", os.path.abspath(OUT))

# ---- load ------------------------------------------------------------------
rows = []
with open(csv_path) as f:
    for r in csv.DictReader(f):
        try:
            rows.append(dict(
                workload=r["workload"].strip(), dist=r["dist"].strip(),
                offload=r["offload"].strip(), cache=int(r["cache_mb"]),
                thr=float(r["throughput_mops"]), p99=float(r["p99_us"]),
                rr=float(r["rdma_read_per_op"]), rpc=float(r["rpc_per_op"])))
        except (ValueError, KeyError):
            pass  # skip NA / malformed rows

QUADS = [("lookup", "uniform"), ("lookup", "zipfian"),
         ("range", "uniform"), ("range", "zipfian")]
CACHES = sorted({r["cache"] for r in rows})
C_OFF, C_ON = "#888888", "#1f77b4"

def series(wl, dist, off, field):
    pts = sorted((r["cache"], r[field]) for r in rows
                 if r["workload"] == wl and r["dist"] == dist and r["offload"] == off)
    return [c for c, _ in pts], [v for _, v in pts]

def grid(field, ylabel, title, fname, logy=False, annotate_speedup=False):
    fig, axes = plt.subplots(2, 2, figsize=(12, 8.5), sharex=True)
    for ax, (wl, dist) in zip(axes.flat, QUADS):
        for off, color, lbl, ls in [("off", C_OFF, "no offload", "--"),
                                     ("on", C_ON, "offload", "-")]:
            x, y = series(wl, dist, off, field)
            if x:
                ax.plot(x, y, ls, color=color, marker="o", ms=7, lw=2.2, label=lbl)
        if annotate_speedup:
            xo, yo = series(wl, dist, "off", "thr")
            xn, yn = series(wl, dist, "on", "thr")
            for c in set(xo) & set(xn):
                a = yo[xo.index(c)]; b = yn[xn.index(c)]
                yy = series(wl, dist, "on", field)[1][series(wl, dist, "on", field)[0].index(c)]
                ax.annotate(f"{b/a:.1f}x", (c, yy), textcoords="offset points",
                            xytext=(0, 8), ha="center", fontsize=8, color=C_ON)
        ax.set_title(f"{wl} / {dist}", fontsize=12, fontweight="bold")
        ax.set_xscale("log", base=2); ax.set_xticks(CACHES)
        ax.set_xticklabels([str(c) for c in CACHES])
        if logy: ax.set_yscale("log")
        ax.grid(True, alpha=0.3); ax.set_ylim(bottom=0 if not logy else None)
        ax.legend(fontsize=9)
    for ax in axes[-1]:
        ax.set_xlabel("compute-node cache (MB)")
    for ax in axes[:, 0]:
        ax.set_ylabel(ylabel)
    fig.suptitle(title, fontsize=15, fontweight="bold")
    fig.tight_layout(rect=[0, 0, 1, 0.97])
    p = os.path.join(OUT, fname); fig.savefig(p, dpi=130); plt.close(fig)
    print("  wrote", fname)

# 1. throughput vs cache
grid("thr", "throughput (Mops/s)",
     "DEX range/lookup throughput vs cache  (offload vs no-offload, height-22 tree)",
     "throughput_vs_cache.png", annotate_speedup=True)
# 2. p99 latency vs cache  (the requested operating-point-vs-caching view)
grid("p99", "p99 latency (us)",
     "DEX p99 latency vs cache  (offload vs no-offload, height-22 tree)",
     "latency_vs_cache.png")
# 3. mechanism: rdma reads/op vs cache
grid("rr", "RDMA reads / op",
     "Mechanism: RDMA reads per op  (offload collapses the deep walk + avoids leaf pollution)",
     "reads_per_op_vs_cache.png")

# 4. operating-point scatter: throughput (x) vs p99 (y); down-right = better
fig, axes = plt.subplots(2, 2, figsize=(12, 8.5))
for ax, (wl, dist) in zip(axes.flat, QUADS):
    for off, color, lbl in [("off", C_OFF, "no offload"), ("on", C_ON, "offload")]:
        pts = sorted((r["cache"], r["thr"], r["p99"]) for r in rows
                     if r["workload"] == wl and r["dist"] == dist and r["offload"] == off)
        if not pts:
            continue
        xs = [t for _, t, _ in pts]; ys = [p for _, _, p in pts]; cs = [c for c, _, _ in pts]
        ax.plot(xs, ys, "-", color=color, alpha=0.5, lw=1.5)
        ax.scatter(xs, ys, c=color, s=90, zorder=3, label=lbl, edgecolor="k", linewidth=0.4)
        for c, x, y in pts:
            ax.annotate(f"{c}", (x, y), textcoords="offset points", xytext=(5, 4),
                        fontsize=7, color=color)
    ax.set_title(f"{wl} / {dist}", fontsize=12, fontweight="bold")
    ax.set_xlabel("throughput (Mops/s)"); ax.set_ylabel("p99 latency (us)")
    ax.grid(True, alpha=0.3); ax.legend(fontsize=9)
    ax.annotate("better", xy=(0.93, 0.07), xycoords="axes fraction", ha="right",
                fontsize=9, style="italic",
                arrowprops=dict(arrowstyle="->"), xytext=(0.55, 0.4),
                textcoords="axes fraction")
fig.suptitle("Operating points: throughput vs p99 latency  (label = cache MB; down-right = better)",
             fontsize=14, fontweight="bold")
fig.tight_layout(rect=[0, 0, 1, 0.97])
fig.savefig(os.path.join(OUT, "operating_points.png"), dpi=130); plt.close(fig)
print("  wrote operating_points.png")

# 5. config + how-offload-works panel
fig = plt.figure(figsize=(12, 7))
fig.suptitle("DEX tree configuration & how offloading works", fontsize=15, fontweight="bold")

# left: tree-shape / node sizes
axl = fig.add_axes([0.04, 0.05, 0.44, 0.85]); axl.axis("off")
cfg = (
"TREE CONFIGURATION (height-22 build)\n"
"------------------------------------\n"
"pageSize        = 512 B   (physical node / cache slot / IO)\n"
"leafPageSize    = 512 B  -> leaf fanout  = 26 entries\n"
"innerPageSize   = 160 B  -> inner fanout = 5  (geometry only)\n"
"\n"
"Keys            = 50 M  (8B key / 8B value)\n"
"Leaves          ~ 3.85 M  (~1.9 GB)\n"
"Inner nodes     ~ 3.85 M  (~1.9 GB)   <-- the INDEX\n"
"Tree height     = 22\n"
"\n"
"Why this shape: sorted bulk-load fills nodes ~50%, so a\n"
"small inner fanout (5) -> a very TALL tree. The 1.9 GB\n"
"index does NOT fit the 64-512 MB cache.\n"
"\n"
"Decoupling note: inner/leaf fanout is set independently\n"
"(innerPageSize vs leafPageSize); the physical page and the\n"
"cache slot stay uniform = leafPageSize.")
axl.text(0, 1, cfg, va="top", ha="left", family="monospace", fontsize=9.5)

# right: mechanism diagram
axr = fig.add_axes([0.52, 0.05, 0.44, 0.85]); axr.axis("off")
axr.set_xlim(0, 10); axr.set_ylim(0, 10)
# upper tree (cached) vs bottom subtree (offloaded)
axr.add_patch(plt.Rectangle((0.5, 7.2), 9, 2.4, fc="#dbeafe", ec="k"))
axr.text(5, 8.4, "UPPER TREE  (small, stays CACHED on compute)",
         ha="center", va="center", fontsize=9, fontweight="bold")
axr.add_patch(plt.Rectangle((0.5, 3.8), 9, 2.8, fc="#fde68a", ec="k"))
axr.text(5, 5.2, "BOTTOM SUBTREE (levels <= megaLevel=4) + LEAF\n"
                 "lives in MEMORY-NODE DRAM",
         ha="center", va="center", fontsize=9, fontweight="bold")
axr.annotate("", xy=(5, 6.6), xytext=(5, 7.2),
             arrowprops=dict(arrowstyle="-"))
mech = (
"NO OFFLOAD: compute pulls every page it walks over RDMA,\n"
"and caches leaves -> leaves evict index pages -> the 1.9 GB\n"
"index THRASHES (16-22 RDMA reads / range op).\n"
"\n"
"OFFLOAD: at the first bottom-subtree miss the compute sends\n"
"ONE RPC; the memory node walks the bottom subtree + leaf\n"
"locally and returns only the result (8 B for a lookup, a\n"
"packed batch for a scan). Leaves never enter the cache, so\n"
"the index stays resident.\n"
"  => lookups: ~1 RPC, ~0 index reads at >=256 MB\n"
"  => 1.6-2.6x throughput, ~2x lower p99 across the sweep")
axr.text(0.3, 3.3, mech, va="top", ha="left", fontsize=8.7, family="monospace")
fig.savefig(os.path.join(OUT, "dex_config_and_offload.png"), dpi=130); plt.close(fig)
print("  wrote dex_config_and_offload.png")
print("done.")
