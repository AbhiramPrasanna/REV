#!/usr/bin/env python3
"""
plot_miss_rate.py -- DEX path-aware cache MISS RATE analysis
                     (reads build/results/qload/summary_qload.csv)

Produces (into build/results/qload/plots/):
  1. miss_rate_vs_cache.png       total miss rate vs cache size, offload on/off (2x2)
  2. miss_breakdown_stacked.png   inner-vs-leaf miss stacked bars per cache (2x2)
  3. miss_vs_reads_per_op.png     miss RATE vs absolute remote traffic (the caveat)

Miss rate here is DEX's PROPER path-aware, per-node-access rate:
    miss_rate = (inner_miss + leaf_miss) / (node_hit + inner_miss + leaf_miss)
so inner_miss_rate + leaf_miss_rate == total miss_rate (they stack cleanly).

SCALING CONTRACT (per user request):
  * every y-axis starts at 0
  * all miss-rate figures share ONE common y-max (YMAX below), so every subplot
    and every bar is on the exact same scale and is directly comparable.

Miss rate is a COMPUTE-side cache property, so it is invariant to the number of
memory-node service threads: mt=2 and mt=6 rows are identical to within noise.
We therefore plot mt=2 and assert the mt=6 rows match (printed as a check).

Run from repo root or build/:  python script/plot_miss_rate.py
"""
import csv, os, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

# ---- locate summary_qload.csv ---------------------------------------------
HERE = os.path.dirname(os.path.abspath(__file__))
CANDS = [
    os.path.join(HERE, "..", "build", "results", "qload", "summary_qload.csv"),
    os.path.join(os.getcwd(), "results", "qload", "summary_qload.csv"),
    os.path.join(os.getcwd(), "build", "results", "qload", "summary_qload.csv"),
    os.path.join(os.getcwd(), "summary_qload.csv"),
]
csv_path = next((p for p in CANDS if os.path.isfile(p)), None)
if not csv_path:
    sys.exit("summary_qload.csv not found in:\n  " +
             "\n  ".join(os.path.abspath(p) for p in CANDS))
OUT = os.path.join(os.path.dirname(os.path.abspath(csv_path)), "plots")
os.makedirs(OUT, exist_ok=True)
print("reading", os.path.abspath(csv_path))
print("writing", os.path.abspath(OUT))

# ---- load ------------------------------------------------------------------
def fnum(x):
    try: return float(x)
    except (TypeError, ValueError): return float("nan")

rows = []
with open(csv_path) as f:
    for r in csv.DictReader(f):
        rows.append(dict(
            workload=r["workload"].strip(), dist=r["dist"].strip(),
            offload=r["offload"].strip(), mt=int(r["memthreads"]),
            cache=int(r["cache_mb"]),
            thr=fnum(r["throughput_mops"]), p99=fnum(r["p99_us"]),
            miss=fnum(r["miss_rate_pct"]),
            leaf=fnum(r["leaf_miss_rate_pct"]),
            inner=fnum(r["inner_miss_rate_pct"]),
            reads=fnum(r["direct_read_per_op"]),
            rpc=fnum(r["offload_rpc_per_op"]),
            remote_ops=fnum(r["total_remote_ops_per_op"])))

QUADS = [("lookup", "uniform"), ("lookup", "zipfian"),
         ("range", "uniform"), ("range", "zipfian")]
CACHES = sorted({r["cache"] for r in rows})
MT = 2  # miss rate is compute-side => memthreads-invariant; plot mt=2

# --- validate memthreads-invariance of the miss rate ------------------------
def get(wl, dist, off, cache, mt, field):
    for r in rows:
        if (r["workload"] == wl and r["dist"] == dist and r["offload"] == off
                and r["cache"] == cache and r["mt"] == mt):
            return r[field]
    return float("nan")

maxdiff = 0.0
for wl, dist in QUADS:
    for off in ("off", "on"):
        for c in CACHES:
            a, b = get(wl, dist, off, c, 2, "miss"), get(wl, dist, off, c, 6, "miss")
            if a == a and b == b:
                maxdiff = max(maxdiff, abs(a - b))
print(f"miss-rate mt2-vs-mt6 max abs diff = {maxdiff:.4f} pp "
      f"(confirms miss rate is memthreads-invariant)")

# --- ONE common y-scale for every miss-rate figure --------------------------
allmiss = [r["miss"] for r in rows if r["mt"] == MT and r["miss"] == r["miss"]]
YMAX = 5 * np.ceil(max(allmiss) / 5.0)   # round up to a clean multiple of 5
print(f"shared miss-rate y-scale = [0, {YMAX:.0f}] %")

C_OFF, C_ON = "#9aa0a6", "#1f77b4"        # no-offload grey, offload blue
C_INNER, C_LEAF = "#1f77b4", "#f2a900"    # inner blue, leaf amber

def series(wl, dist, off, field, mt=MT):
    pts = sorted((r["cache"], r[field]) for r in rows
                 if r["workload"] == wl and r["dist"] == dist
                 and r["offload"] == off and r["mt"] == mt)
    return [c for c, _ in pts], [v for _, v in pts]

# ===========================================================================
# 1. MISS RATE vs CACHE  (line, shared 0..YMAX)
# ===========================================================================
fig, axes = plt.subplots(2, 2, figsize=(12, 8.5), sharex=True, sharey=True)
for ax, (wl, dist) in zip(axes.flat, QUADS):
    for off, color, lbl, ls in [("off", C_OFF, "no offload", "--"),
                                ("on",  C_ON,  "offload",    "-")]:
        x, y = series(wl, dist, off, "miss")
        if x:
            ax.plot(x, y, ls, color=color, marker="o", ms=7, lw=2.4, label=lbl)
            for c, v in zip(x, y):
                ax.annotate(f"{v:.1f}", (c, v), textcoords="offset points",
                            xytext=(0, 7), ha="center", fontsize=7.5, color=color)
    ax.set_title(f"{wl} / {dist}", fontsize=12, fontweight="bold")
    ax.set_xscale("log", base=2); ax.set_xticks(CACHES)
    ax.set_xticklabels([str(c) for c in CACHES])
    ax.set_ylim(0, YMAX)                      # <-- starts at 0, shared scale
    ax.grid(True, alpha=0.3)
    ax.legend(fontsize=9)
for ax in axes[-1]:
    ax.set_xlabel("compute-node cache (MB)")
for ax in axes[:, 0]:
    ax.set_ylabel("path-aware miss rate (%)")
fig.suptitle("DEX path-aware cache MISS RATE vs cache size  "
             "(per-node-access; mt=2, shared 0-%.0f%% scale)" % YMAX,
             fontsize=14, fontweight="bold")
fig.tight_layout(rect=[0, 0, 1, 0.96])
fig.savefig(os.path.join(OUT, "miss_rate_vs_cache.png"), dpi=130); plt.close(fig)
print("  wrote miss_rate_vs_cache.png")

# ===========================================================================
# 2. INNER-vs-LEAF MISS  (stacked bars, off|on per cache, shared 0..YMAX)
# ===========================================================================
fig, axes = plt.subplots(2, 2, figsize=(12, 8.5), sharex=True, sharey=True)
xidx = np.arange(len(CACHES))
bw = 0.38
for ax, (wl, dist) in zip(axes.flat, QUADS):
    for k, (off, xoff) in enumerate([("off", -bw/2 - 0.02), ("on", bw/2 + 0.02)]):
        inner = [get(wl, dist, off, c, MT, "inner") for c in CACHES]
        leaf  = [get(wl, dist, off, c, MT, "leaf")  for c in CACHES]
        pos = xidx + xoff
        b1 = ax.bar(pos, inner, bw, color=C_INNER,
                    label="inner miss" if k == 0 else None,
                    edgecolor="white", linewidth=0.5)
        b2 = ax.bar(pos, leaf, bw, bottom=inner, color=C_LEAF,
                    label="leaf miss" if k == 0 else None,
                    edgecolor="white", linewidth=0.5)
        for xp, iv, lv in zip(pos, inner, leaf):
            tot = iv + lv
            if tot == tot:
                ax.annotate(f"{tot:.1f}", (xp, tot), textcoords="offset points",
                            xytext=(0, 3), ha="center", fontsize=7)
                ax.annotate(off, (xp, 0), textcoords="offset points",
                            xytext=(0, -12), ha="center", fontsize=7,
                            color="#555")
    ax.set_title(f"{wl} / {dist}", fontsize=12, fontweight="bold")
    ax.set_xticks(xidx); ax.set_xticklabels([str(c) for c in CACHES])
    ax.set_ylim(0, YMAX)                      # <-- starts at 0, shared scale
    ax.grid(True, axis="y", alpha=0.3)
    ax.legend(fontsize=9, loc="upper right")
for ax in axes[-1]:
    ax.set_xlabel("compute-node cache (MB)   [each bar-pair = no-offload | offload]")
for ax in axes[:, 0]:
    ax.set_ylabel("miss rate (%)  (inner + leaf = total)")
fig.suptitle("DEX miss-rate breakdown: inner-node vs leaf-node misses  "
             "(stacked; mt=2, shared 0-%.0f%% scale)" % YMAX,
             fontsize=14, fontweight="bold")
fig.tight_layout(rect=[0, 0, 1, 0.96])
fig.savefig(os.path.join(OUT, "miss_breakdown_stacked.png"), dpi=130); plt.close(fig)
print("  wrote miss_breakdown_stacked.png")

# ===========================================================================
# 3. MISS RATE vs ABSOLUTE REMOTE TRAFFIC  (the interpretation caveat)
#    higher miss RATE under offload can still mean far LESS remote work/op.
# ===========================================================================
fig, axes = plt.subplots(2, 2, figsize=(12, 8.5), sharex=True, sharey=True)
# shared x-scale for remote-ops/op too (start at 0)
XMAX = 5 * np.ceil(max(r["remote_ops"] for r in rows
                       if r["mt"] == MT and r["remote_ops"] == r["remote_ops"]) / 5.0)
for ax, (wl, dist) in zip(axes.flat, QUADS):
    for off, color, lbl in [("off", C_OFF, "no offload"), ("on", C_ON, "offload")]:
        pts = sorted((r["cache"], r["remote_ops"], r["miss"]) for r in rows
                     if r["workload"] == wl and r["dist"] == dist
                     and r["offload"] == off and r["mt"] == MT)
        if not pts:
            continue
        xs = [x for _, x, _ in pts]; ys = [y for _, _, y in pts]
        cs = [c for c, _, _ in pts]
        ax.plot(xs, ys, "-", color=color, alpha=0.5, lw=1.6)
        ax.scatter(xs, ys, c=color, s=80, zorder=3, label=lbl,
                   edgecolor="k", linewidth=0.4)
        for c, x, y in zip(cs, xs, ys):
            ax.annotate(f"{c}MB", (x, y), textcoords="offset points",
                        xytext=(5, 4), fontsize=7, color=color)
    ax.set_title(f"{wl} / {dist}", fontsize=12, fontweight="bold")
    ax.set_xlim(0, XMAX); ax.set_ylim(0, YMAX)     # both axes start at 0
    ax.set_xlabel("remote ops / op  (absolute traffic)")
    ax.set_ylabel("miss rate (%)")
    ax.grid(True, alpha=0.3); ax.legend(fontsize=9)
fig.suptitle("Miss RATE vs absolute remote traffic  "
             "(offload can raise the RATE while cutting ops/op; mt=2, shared scales)",
             fontsize=14, fontweight="bold")
fig.tight_layout(rect=[0, 0, 1, 0.96])
fig.savefig(os.path.join(OUT, "miss_vs_reads_per_op.png"), dpi=130); plt.close(fig)
print("  wrote miss_vs_reads_per_op.png")

print("done.")
