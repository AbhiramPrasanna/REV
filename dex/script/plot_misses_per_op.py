#!/usr/bin/env python3
"""
plot_misses_per_op.py -- DEX cache misses normalized PER OPERATION.

Why this instead of miss RATE:
  miss rate = misses / (node accesses the compute node performs).  Offload
  changes that denominator (it hands the bottom-subtree/leaf walk to the memory
  node, so those accesses leave the count), which makes the RATE incomparable
  across offload on/off -- offload can look "worse" while doing less work.

  misses PER OP uses a FIXED denominator: the number of logical operations,
  which is identical for offload and no-offload.  So it is directly comparable
  and behaves monotonically -- offload is always <= no-offload.

Unit note: this is a COUNT (average misses per op), not a percentage.  One range
op causes many leaf fetches, so range values are several per op; lookups are ~<=1.

Reads the RAW counts straight from the per-config logs (not the summary CSV,
which only stored rates):
    total miss               = N
    inner-node miss          = N
    leaf-node  miss          = N
    ops total                = N        (from the REMOTE OPERATIONS section)

Outputs (into build/results/qload/plots/):
  1. misses_per_op_vs_cache.png      total misses/op vs cache, offload on/off (2x2)
  2. misses_per_op_stacked.png       inner/op + leaf/op stacked bars (2x2)
Also writes build/results/qload/misses_per_op.csv (the derived table).

SCALING: every y-axis starts at 0 and all panels share ONE common y-max.

Run from repo root or build/:  python script/plot_misses_per_op.py
"""
import os, re, sys, glob, csv
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

# ---- locate the qload log directory ---------------------------------------
HERE = os.path.dirname(os.path.abspath(__file__))
CANDS = [
    os.path.join(HERE, "..", "build", "results", "qload"),
    os.path.join(os.getcwd(), "results", "qload"),
    os.path.join(os.getcwd(), "build", "results", "qload"),
    os.getcwd(),
]
QDIR = next((p for p in CANDS if os.path.isdir(p) and
             glob.glob(os.path.join(p, "dex_*_mt*.log"))), None)
if not QDIR:
    sys.exit("qload log dir with dex_*_mt*.log not found in:\n  " +
             "\n  ".join(os.path.abspath(p) for p in CANDS))
QDIR = os.path.abspath(QDIR)
OUT = os.path.join(QDIR, "plots")
os.makedirs(OUT, exist_ok=True)
print("reading logs from", QDIR)

# ---- parse each log --------------------------------------------------------
# take the LAST occurrence of each field (final measured run in the file)
FNAME = re.compile(
    r"dex_(?P<wl>lookup|range)_(?P<dist>uniform|zipfian)_"
    r"offload-(?P<off>on|off)_cache(?P<cache>\d+)mb_mt(?P<mt>\d+)\.log$")
PATS = {
    # anchor to line start so "ops total" does NOT also match "remote ops total"
    # (that later line ~= total_miss and would force every ratio to 1.0).
    "ops":   re.compile(r"^\s*ops total\s*=\s*(\d+)", re.M),
    "miss":  re.compile(r"^\s*total miss\s*=\s*(\d+)", re.M),
    "inner": re.compile(r"^\s*inner-node miss\s*=\s*(\d+)", re.M),
    "leaf":  re.compile(r"^\s*leaf-node\s+miss\s*=\s*(\d+)", re.M),
}

def last(pat, text):
    m = pat.findall(text)
    return int(m[-1]) if m else None

rows = []
for path in sorted(glob.glob(os.path.join(QDIR, "dex_*_mt*.log"))):
    fm = FNAME.search(os.path.basename(path))
    if not fm:
        continue
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    ops = last(PATS["ops"], text)
    miss = last(PATS["miss"], text)
    inner = last(PATS["inner"], text)
    leaf = last(PATS["leaf"], text)
    if not ops or miss is None:
        print("  WARN: missing counts in", os.path.basename(path))
        continue
    rows.append(dict(
        workload=fm["wl"], dist=fm["dist"], offload=fm["off"],
        cache=int(fm["cache"]), mt=int(fm["mt"]),
        ops=ops, miss=miss, inner=inner or 0, leaf=leaf or 0,
        miss_per_op=miss / ops,
        inner_per_op=(inner or 0) / ops,
        leaf_per_op=(leaf or 0) / ops))

if not rows:
    sys.exit("no logs parsed")
print(f"parsed {len(rows)} configs")

# ---- derived CSV -----------------------------------------------------------
csv_out = os.path.join(QDIR, "misses_per_op.csv")
with open(csv_out, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["workload", "dist", "offload", "memthreads", "cache_mb",
                "ops_total", "total_miss", "inner_miss", "leaf_miss",
                "misses_per_op", "inner_per_op", "leaf_per_op"])
    for r in sorted(rows, key=lambda r: (r["workload"], r["dist"],
                                         r["offload"], r["mt"], r["cache"])):
        w.writerow([r["workload"], r["dist"], r["offload"], r["mt"], r["cache"],
                    r["ops"], r["miss"], r["inner"], r["leaf"],
                    f"{r['miss_per_op']:.4f}", f"{r['inner_per_op']:.4f}",
                    f"{r['leaf_per_op']:.4f}"])
print("  wrote", os.path.basename(csv_out))

# ---- plotting setup --------------------------------------------------------
QUADS = [("lookup", "uniform"), ("lookup", "zipfian"),
         ("range", "uniform"), ("range", "zipfian")]
CACHES = sorted({r["cache"] for r in rows})
MT = 2  # compute-side metric => memthreads-invariant

def get(wl, dist, off, cache, field, mt=MT):
    for r in rows:
        if (r["workload"] == wl and r["dist"] == dist and r["offload"] == off
                and r["cache"] == cache and r["mt"] == mt):
            return r[field]
    return float("nan")

# ONE shared y-scale (misses/op is a count; round up to a clean number)
YMAX = float(np.ceil(max(r["miss_per_op"] for r in rows if r["mt"] == MT)))
YMAX = float(np.ceil(YMAX / 5.0) * 5)
print(f"shared misses/op y-scale = [0, {YMAX:.0f}]")

C_OFF, C_ON = "#9aa0a6", "#1f77b4"
C_INNER, C_LEAF = "#1f77b4", "#f2a900"

def series(wl, dist, off, field):
    pts = sorted((c, get(wl, dist, off, c, field)) for c in CACHES)
    return [c for c, _ in pts], [v for _, v in pts]

# ===========================================================================
# 1. MISSES / OP vs CACHE  (line, fixed denominator, shared 0..YMAX)
# ===========================================================================
fig, axes = plt.subplots(2, 2, figsize=(12, 8.5), sharex=True, sharey=True)
for ax, (wl, dist) in zip(axes.flat, QUADS):
    for off, color, lbl, ls in [("off", C_OFF, "no offload", "--"),
                                ("on",  C_ON,  "offload",    "-")]:
        x, y = series(wl, dist, off, "miss_per_op")
        ax.plot(x, y, ls, color=color, marker="o", ms=7, lw=2.4, label=lbl)
        for c, v in zip(x, y):
            ax.annotate(f"{v:.2f}", (c, v), textcoords="offset points",
                        xytext=(0, 7), ha="center", fontsize=7.5, color=color)
    ax.set_title(f"{wl} / {dist}", fontsize=12, fontweight="bold")
    ax.set_xscale("log", base=2); ax.set_xticks(CACHES)
    ax.set_xticklabels([str(c) for c in CACHES])
    ax.set_ylim(0, YMAX)
    ax.grid(True, alpha=0.3); ax.legend(fontsize=9)
for ax in axes[-1]:
    ax.set_xlabel("compute-node cache (MB)")
for ax in axes[:, 0]:
    ax.set_ylabel("cache misses per operation")
fig.suptitle("DEX cache MISSES PER OPERATION vs cache size  "
             "(fixed denominator = #ops; mt=2, shared 0-%.0f scale)" % YMAX,
             fontsize=14, fontweight="bold")
fig.tight_layout(rect=[0, 0, 1, 0.96])
fig.savefig(os.path.join(OUT, "misses_per_op_vs_cache.png"), dpi=130); plt.close(fig)
print("  wrote misses_per_op_vs_cache.png")

# ===========================================================================
# 2. INNER vs LEAF misses/op  (stacked bars, off|on per cache, shared 0..YMAX)
# ===========================================================================
fig, axes = plt.subplots(2, 2, figsize=(12, 8.5), sharex=True, sharey=True)
xidx = np.arange(len(CACHES)); bw = 0.38
for ax, (wl, dist) in zip(axes.flat, QUADS):
    for k, (off, xo) in enumerate([("off", -bw/2 - 0.02), ("on", bw/2 + 0.02)]):
        inner = [get(wl, dist, off, c, "inner_per_op") for c in CACHES]
        leaf  = [get(wl, dist, off, c, "leaf_per_op")  for c in CACHES]
        pos = xidx + xo
        ax.bar(pos, inner, bw, color=C_INNER,
               label="inner miss/op" if k == 0 else None,
               edgecolor="white", linewidth=0.5)
        ax.bar(pos, leaf, bw, bottom=inner, color=C_LEAF,
               label="leaf miss/op" if k == 0 else None,
               edgecolor="white", linewidth=0.5)
        for xp, iv, lv in zip(pos, inner, leaf):
            tot = iv + lv
            ax.annotate(f"{tot:.2f}", (xp, tot), textcoords="offset points",
                        xytext=(0, 3), ha="center", fontsize=7)
            ax.annotate(off, (xp, 0), textcoords="offset points",
                        xytext=(0, -12), ha="center", fontsize=7, color="#555")
    ax.set_title(f"{wl} / {dist}", fontsize=12, fontweight="bold")
    ax.set_xticks(xidx); ax.set_xticklabels([str(c) for c in CACHES])
    ax.set_ylim(0, YMAX)
    ax.grid(True, axis="y", alpha=0.3); ax.legend(fontsize=9, loc="upper right")
for ax in axes[-1]:
    ax.set_xlabel("compute-node cache (MB)   [each bar-pair = no-offload | offload]")
for ax in axes[:, 0]:
    ax.set_ylabel("misses per op  (inner + leaf)")
fig.suptitle("DEX misses/op breakdown: inner vs leaf  "
             "(stacked, fixed denominator; mt=2, shared 0-%.0f scale)" % YMAX,
             fontsize=14, fontweight="bold")
fig.tight_layout(rect=[0, 0, 1, 0.96])
fig.savefig(os.path.join(OUT, "misses_per_op_stacked.png"), dpi=130); plt.close(fig)
print("  wrote misses_per_op_stacked.png")

# ===========================================================================
# PER-PANEL versions: one separate image per (workload, dist), same shared
# 0..YMAX scale so they stay directly comparable across the four files.
# ===========================================================================
for wl, dist in QUADS:
    fig, ax = plt.subplots(figsize=(5.0, 4.0))
    for off, color, lbl, ls in [("off", C_OFF, "no offload", "--"),
                                ("on",  C_ON,  "offload",    "-")]:
        x, y = series(wl, dist, off, "miss_per_op")
        ax.plot(x, y, ls, color=color, marker="o", ms=6.5, lw=2.2, label=lbl)
        for c, v in zip(x, y):
            ax.annotate(f"{v:.2f}", (c, v), textcoords="offset points",
                        xytext=(0, 6), ha="center", fontsize=7.5, color=color)
    ax.set_title(f"{wl} / {dist}", fontsize=12, fontweight="bold")
    ax.set_xscale("log", base=2); ax.set_xticks(CACHES)
    ax.set_xticklabels([str(c) for c in CACHES])
    ax.set_ylim(0, YMAX)
    ax.grid(True, alpha=0.3); ax.legend(fontsize=9)
    ax.set_xlabel("compute-node cache (MB)")
    ax.set_ylabel("cache misses per operation")
    fig.tight_layout()
    fn = f"misses_per_op_vs_cache_{wl}_{dist}.png"
    fig.savefig(os.path.join(OUT, fn), dpi=130); plt.close(fig)
    print("  wrote", fn)

for wl, dist in QUADS:
    fig, ax = plt.subplots(figsize=(5.0, 4.0))
    xi = np.arange(len(CACHES)); bw = 0.38
    for k, (off, xo) in enumerate([("off", -bw/2 - 0.02), ("on", bw/2 + 0.02)]):
        inner = [get(wl, dist, off, c, "inner_per_op") for c in CACHES]
        leaf  = [get(wl, dist, off, c, "leaf_per_op")  for c in CACHES]
        pos = xi + xo
        ax.bar(pos, inner, bw, color=C_INNER,
               label="inner miss/op" if k == 0 else None,
               edgecolor="white", linewidth=0.5)
        ax.bar(pos, leaf, bw, bottom=inner, color=C_LEAF,
               label="leaf miss/op" if k == 0 else None,
               edgecolor="white", linewidth=0.5)
        for xp, iv, lv in zip(pos, inner, leaf):
            ax.annotate(f"{iv+lv:.2f}", (xp, iv + lv),
                        textcoords="offset points", xytext=(0, 3),
                        ha="center", fontsize=7)
            ax.annotate(off, (xp, 0), textcoords="offset points",
                        xytext=(0, -12), ha="center", fontsize=7, color="#555")
    ax.set_title(f"{wl} / {dist}", fontsize=12, fontweight="bold")
    ax.set_xticks(xi); ax.set_xticklabels([str(c) for c in CACHES])
    ax.set_ylim(0, YMAX)
    ax.grid(True, axis="y", alpha=0.3); ax.legend(fontsize=9, loc="upper right")
    ax.set_xlabel("compute-node cache (MB)  [pair = off | on]")
    ax.set_ylabel("misses per op  (inner + leaf)")
    fig.tight_layout()
    fn = f"misses_per_op_stacked_{wl}_{dist}.png"
    fig.savefig(os.path.join(OUT, fn), dpi=130); plt.close(fig)
    print("  wrote", fn)

print("done.")
