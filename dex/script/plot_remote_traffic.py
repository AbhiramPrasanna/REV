#!/usr/bin/env python3
"""
plot_remote_traffic.py -- DEX remote traffic vs cache size,
                          no-offload vs offload, for BOTH mt=2 and mt=6 cores.

Reads build/results/qload/summary_qload.csv. Relevant columns:
    direct_read_per_op        RDMA reads / op   (NON-offloaded remote traffic)
    offload_rpc_per_op        RPC pushdowns / op (OFFLOADED remote traffic)
    total_remote_ops_per_op   all remote ops / op  (= reads + rpc for read/scan)
    throughput_mops           for the aggregate-rate view

Three figures (into build/results/qload/plots/):
  1. remote_traffic_per_op.png     total remote ops/op vs cache; 4 series
                                   (off/on x 2c/6c).  PER-OP => compute-side, so
                                   2c and 6c overlap: the lever is offload.
  2. remote_traffic_split_per_op.png  stacked direct-read vs RPC per op (mt=2);
                                   shows offload CONVERTING reads into one RPC
                                   and cutting the total.
  3. remote_traffic_rate.png       aggregate remote ops/SEC = thr x ops/op;
                                   here 2c vs 6c DIVERGE (6c reaches higher
                                   throughput => delivers more load to the MN).

Cores are memory-node service threads (memthreads). Encoding across figures:
    colour  = offload   (grey = no offload, blue = offload)
    style   = cores     (2c = solid/circle, 6c = dashed/square)

SCALING: every y-axis starts at 0; all panels of a figure share one y-max.

Run from repo root or build/:  python script/plot_remote_traffic.py
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
            thr=fnum(r["throughput_mops"]),
            read=fnum(r["direct_read_per_op"]),
            rpc=fnum(r["offload_rpc_per_op"]),
            total=fnum(r["total_remote_ops_per_op"])))

QUADS = [("lookup", "uniform"), ("lookup", "zipfian"),
         ("range", "uniform"), ("range", "zipfian")]
CACHES = sorted({r["cache"] for r in rows})

def get(wl, dist, off, mt, cache, field):
    for r in rows:
        if (r["workload"] == wl and r["dist"] == dist and r["offload"] == off
                and r["mt"] == mt and r["cache"] == cache):
            return r[field]
    return float("nan")

def series(wl, dist, off, mt, field):
    pts = sorted((c, get(wl, dist, off, mt, c, field)) for c in CACHES)
    return [c for c, _ in pts], [v for _, v in pts]

C_OFF, C_ON = "#9aa0a6", "#1f77b4"
C_READ, C_RPC = "#1f77b4", "#f2a900"   # direct reads blue, rpc offload amber
# (offload, cores) -> style
STYLES = [
    ("off", 2, C_OFF, "-",  "o", "no offload, 2 cores"),
    ("off", 6, C_OFF, "--", "s", "no offload, 6 cores"),
    ("on",  2, C_ON,  "-",  "o", "offload, 2 cores"),
    ("on",  6, C_ON,  "--", "s", "offload, 6 cores"),
]

def line_grid(field, ylabel, title, fname):
    if field == "rate":
        ymax = max(r["thr"] * r["total"] for r in rows)
    else:
        ymax = max(r[field] for r in rows if r[field] == r[field])
    YMAX = float(np.ceil(ymax / 2.0) * 2)
    fig, axes = plt.subplots(2, 2, figsize=(12, 8.5), sharex=True, sharey=True)
    for ax, (wl, dist) in zip(axes.flat, QUADS):
        for off, mt, color, ls, mk, lbl in STYLES:
            if field == "rate":
                x, t = series(wl, dist, off, mt, "total")
                _, th = series(wl, dist, off, mt, "thr")
                y = [a * b for a, b in zip(th, t)]
            else:
                x, y = series(wl, dist, off, mt, field)
            ax.plot(x, y, ls, color=color, marker=mk, ms=6.5, lw=2.2,
                    markerfacecolor=(color if mt == 2 else "white"),
                    markeredgecolor=color, label=lbl)
        ax.set_title(f"{wl} / {dist}", fontsize=12, fontweight="bold")
        ax.set_xscale("log", base=2); ax.set_xticks(CACHES)
        ax.set_xticklabels([str(c) for c in CACHES])
        ax.set_ylim(0, YMAX)
        ax.grid(True, alpha=0.3); ax.legend(fontsize=8.5)
    for ax in axes[-1]:
        ax.set_xlabel("compute-node cache (MB)")
    for ax in axes[:, 0]:
        ax.set_ylabel(ylabel)
    fig.suptitle(title, fontsize=14, fontweight="bold")
    fig.tight_layout(rect=[0, 0, 1, 0.96])
    fig.savefig(os.path.join(OUT, fname), dpi=130); plt.close(fig)
    print("  wrote", fname)

# ===========================================================================
# 1. TOTAL remote ops / op  (4 series: off/on x 2c/6c)
# ===========================================================================
line_grid("total", "remote ops / operation",
          "DEX remote traffic PER OP vs cache  (offload vs no-offload, 2 vs 6 "
          "cores; 2c/6c overlap => traffic/op is compute-side)",
          "remote_traffic_per_op.png")

# ===========================================================================
# 3. AGGREGATE remote ops / SEC  = throughput x remote-ops/op
#    (here 2 vs 6 cores diverge: 6c reaches higher throughput)
# ===========================================================================
line_grid("rate", "remote ops / second  (Mops/s)",
          "DEX aggregate remote traffic RATE vs cache  (= throughput x ops/op; "
          "2 vs 6 cores diverge => load delivered to the memory node)",
          "remote_traffic_rate.png")

# ===========================================================================
# 2. SPLIT: direct RDMA read vs RPC pushdown, per op (mt=2; mt=6 identical)
# ===========================================================================
MT = 2
YMAX = float(np.ceil(max(r["total"] for r in rows if r["mt"] == MT) / 2.0) * 2)
fig, axes = plt.subplots(2, 2, figsize=(12, 8.5), sharex=True, sharey=True)
xidx = np.arange(len(CACHES)); bw = 0.38
for ax, (wl, dist) in zip(axes.flat, QUADS):
    for k, (off, xo) in enumerate([("off", -bw/2 - 0.02), ("on", bw/2 + 0.02)]):
        rd = [get(wl, dist, off, MT, c, "read") for c in CACHES]
        rp = [get(wl, dist, off, MT, c, "rpc")  for c in CACHES]
        pos = xidx + xo
        ax.bar(pos, rd, bw, color=C_READ,
               label="direct RDMA read (non-offloaded)" if k == 0 else None,
               edgecolor="white", linewidth=0.5)
        ax.bar(pos, rp, bw, bottom=rd, color=C_RPC,
               label="RPC pushdown (offloaded)" if k == 0 else None,
               edgecolor="white", linewidth=0.5)
        for xp, a, b in zip(pos, rd, rp):
            tot = a + b
            ax.annotate(f"{tot:.1f}", (xp, tot), textcoords="offset points",
                        xytext=(0, 3), ha="center", fontsize=7)
            ax.annotate(off, (xp, 0), textcoords="offset points",
                        xytext=(0, -12), ha="center", fontsize=7, color="#555")
    ax.set_title(f"{wl} / {dist}", fontsize=12, fontweight="bold")
    ax.set_xticks(xidx); ax.set_xticklabels([str(c) for c in CACHES])
    ax.set_ylim(0, YMAX)
    ax.grid(True, axis="y", alpha=0.3); ax.legend(fontsize=8.5, loc="upper right")
for ax in axes[-1]:
    ax.set_xlabel("compute-node cache (MB)   [each bar-pair = no-offload | offload]")
for ax in axes[:, 0]:
    ax.set_ylabel("remote ops / op  (read + rpc)")
fig.suptitle("DEX remote-traffic COMPOSITION per op: direct read vs RPC pushdown  "
             "(mt=2; 6 cores identical per op)",
             fontsize=13.5, fontweight="bold")
fig.tight_layout(rect=[0, 0, 1, 0.96])
fig.savefig(os.path.join(OUT, "remote_traffic_split_per_op.png"), dpi=130)
plt.close(fig)
print("  wrote remote_traffic_split_per_op.png")

# ===========================================================================
# PER-PANEL versions: one separate image per (workload, dist). Shared 0..YMAX
# per metric so the four files stay directly comparable.
# ===========================================================================
def line_panels(field, ylabel, prefix):
    if field == "rate":
        ymax = max(r["thr"] * r["total"] for r in rows)
    else:
        ymax = max(r[field] for r in rows if r[field] == r[field])
    YM = float(np.ceil(ymax / 2.0) * 2)
    for wl, dist in QUADS:
        fig, ax = plt.subplots(figsize=(5.0, 4.0))
        for off, mt, color, ls, mk, lbl in STYLES:
            if field == "rate":
                x, t = series(wl, dist, off, mt, "total")
                _, th = series(wl, dist, off, mt, "thr")
                y = [a * b for a, b in zip(th, t)]
            else:
                x, y = series(wl, dist, off, mt, field)
            ax.plot(x, y, ls, color=color, marker=mk, ms=6, lw=2.0,
                    markerfacecolor=(color if mt == 2 else "white"),
                    markeredgecolor=color, label=lbl)
        ax.set_title(f"{wl} / {dist}", fontsize=12, fontweight="bold")
        ax.set_xscale("log", base=2); ax.set_xticks(CACHES)
        ax.set_xticklabels([str(c) for c in CACHES])
        ax.set_ylim(0, YM)
        ax.grid(True, alpha=0.3); ax.legend(fontsize=8)
        ax.set_xlabel("compute-node cache (MB)"); ax.set_ylabel(ylabel)
        fig.tight_layout()
        fn = f"{prefix}_{wl}_{dist}.png"
        fig.savefig(os.path.join(OUT, fn), dpi=130); plt.close(fig)
        print("  wrote", fn)

line_panels("total", "remote ops / operation", "remote_traffic_per_op")
line_panels("rate", "remote ops / second  (Mops/s)", "remote_traffic_rate")

MTp = 2
YMs = float(np.ceil(max(r["total"] for r in rows if r["mt"] == MTp) / 2.0) * 2)
for wl, dist in QUADS:
    fig, ax = plt.subplots(figsize=(5.0, 4.0))
    xi = np.arange(len(CACHES)); bw2 = 0.38
    for k, (off, xo) in enumerate([("off", -bw2/2 - 0.02), ("on", bw2/2 + 0.02)]):
        rd = [get(wl, dist, off, MTp, c, "read") for c in CACHES]
        rp = [get(wl, dist, off, MTp, c, "rpc")  for c in CACHES]
        pos = xi + xo
        ax.bar(pos, rd, bw2, color=C_READ,
               label="direct RDMA read" if k == 0 else None,
               edgecolor="white", linewidth=0.5)
        ax.bar(pos, rp, bw2, bottom=rd, color=C_RPC,
               label="RPC pushdown" if k == 0 else None,
               edgecolor="white", linewidth=0.5)
        for xp, a, b in zip(pos, rd, rp):
            ax.annotate(f"{a+b:.1f}", (xp, a + b), textcoords="offset points",
                        xytext=(0, 3), ha="center", fontsize=7)
            ax.annotate(off, (xp, 0), textcoords="offset points",
                        xytext=(0, -12), ha="center", fontsize=7, color="#555")
    ax.set_title(f"{wl} / {dist}", fontsize=12, fontweight="bold")
    ax.set_xticks(xi); ax.set_xticklabels([str(c) for c in CACHES])
    ax.set_ylim(0, YMs)
    ax.grid(True, axis="y", alpha=0.3); ax.legend(fontsize=8, loc="upper right")
    ax.set_xlabel("compute-node cache (MB)  [pair = off | on]")
    ax.set_ylabel("remote ops / op  (read + rpc)")
    fig.tight_layout()
    fn = f"remote_traffic_split_{wl}_{dist}.png"
    fig.savefig(os.path.join(OUT, fn), dpi=130); plt.close(fig)
    print("  wrote", fn)

print("done.")
