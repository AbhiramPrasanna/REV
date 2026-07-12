#!/usr/bin/env python3
"""
plot_bandwidth.py -- DEX NETWORK BANDWIDTH / TRAFFIC (bytes on the wire),
                     not just remote-op counts.

Remote-op *count* misses the point of offloading: a one-sided page read moves a
whole 0.5--1 KB node, while a lookup RPC ships back an 8 B value. To see that we
track BYTES, using the per-op read-size counter the sweep records.

Source: summary_qload.csv
  direct_read_bytes_per_op  = "Avg. rdma read size/ op"  (bytes pulled per op)
  throughput_mops           = ops/s (for the aggregate wire-bandwidth view)

Two metrics, each emitted as a combined 2x2 AND four per-panel images:
  1. net_bytes_per_op[_wl_dist].png   RDMA read bytes per operation vs cache.
     Page-shipping (KBs/op) collapses under offload for lookups; scans keep the
     packed-batch bytes (the batch is pulled back with one RDMA read, so it IS
     counted here).
  2. net_bandwidth[_wl_dist].png      aggregate read bandwidth = bytes/op x
     throughput (GB/s) -- the actual traffic on the link. Cores matter here
     (via throughput), unlike the per-op view.

Series per panel: offload off/on x memory-node cores 2/6.
Scaling: y starts at 0; all panels of a metric share one y-max.

CAVEAT: this is the RDMA read byte stream (pages + offloaded scan batches). The
small RPC *message* payloads for point lookups (an 8 B value + request header)
are not in this counter; they are negligible next to a page, so the lookup curves
understate offload's byte cost by only a few bytes/op.

Run from repo root or build/:  python script/plot_bandwidth.py
"""
import csv, os, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
CANDS = [
    os.path.join(HERE, "..", "build", "results", "qload", "summary_qload.csv"),
    os.path.join(os.getcwd(), "results", "qload", "summary_qload.csv"),
    os.path.join(os.getcwd(), "build", "results", "qload", "summary_qload.csv"),
    os.path.join(os.getcwd(), "summary_qload.csv"),
]
csv_path = next((p for p in CANDS if os.path.isfile(p)), None)
if not csv_path:
    sys.exit("summary_qload.csv not found")
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
            bytes=fnum(r["direct_read_bytes_per_op"])))

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
STYLES = [
    ("off", 2, C_OFF, "-",  "o", "no offload, 2 cores"),
    ("off", 6, C_OFF, "--", "s", "no offload, 6 cores"),
    ("on",  2, C_ON,  "-",  "o", "offload, 2 cores"),
    ("on",  6, C_ON,  "--", "s", "offload, 6 cores"),
]

# value() maps a (wl,dist,off,mt) series onto the plotted quantity.
def yvals(wl, dist, off, mt, metric):
    x, b = series(wl, dist, off, mt, "bytes")
    if metric == "bytes":                       # bytes per op
        return x, b
    _, th = series(wl, dist, off, mt, "thr")     # aggregate GB/s
    return x, [(t * 1e6) * by / 1e9 for t, by in zip(th, b)]

def ymax_for(metric):
    m = 0.0
    for wl, dist in QUADS:
        for off, mt, *_ in STYLES:
            _, y = yvals(wl, dist, off, mt, metric)
            m = max([m] + [v for v in y if v == v])
    if metric == "bytes":
        return float(np.ceil(m / 1000.0) * 1000)
    return float(np.ceil(m))

def draw_panel(ax, wl, dist, metric, YMAX, ylabel):
    for off, mt, color, ls, mk, lbl in STYLES:
        x, y = yvals(wl, dist, off, mt, metric)
        ax.plot(x, y, ls, color=color, marker=mk, ms=6, lw=2.0,
                markerfacecolor=(color if mt == 2 else "white"),
                markeredgecolor=color, label=lbl)
    ax.set_title(f"{wl} / {dist}", fontsize=12, fontweight="bold")
    ax.set_xscale("log", base=2); ax.set_xticks(CACHES)
    ax.set_xticklabels([str(c) for c in CACHES])
    ax.set_ylim(0, YMAX); ax.grid(True, alpha=0.3); ax.legend(fontsize=8)
    ax.set_xlabel("compute-node cache (MB)"); ax.set_ylabel(ylabel)

def make(metric, ylabel, title, base):
    YMAX = ymax_for(metric)
    # combined 2x2
    fig, axes = plt.subplots(2, 2, figsize=(12, 8.5), sharex=True, sharey=True)
    for ax, (wl, dist) in zip(axes.flat, QUADS):
        draw_panel(ax, wl, dist, metric, YMAX, ylabel)
    fig.suptitle(title, fontsize=14, fontweight="bold")
    fig.tight_layout(rect=[0, 0, 1, 0.96])
    fig.savefig(os.path.join(OUT, f"{base}.png"), dpi=130); plt.close(fig)
    print("  wrote", f"{base}.png")
    # per-panel
    for wl, dist in QUADS:
        fig, ax = plt.subplots(figsize=(5.0, 4.0))
        draw_panel(ax, wl, dist, metric, YMAX, ylabel)
        fig.tight_layout()
        fn = f"{base}_{wl}_{dist}.png"
        fig.savefig(os.path.join(OUT, fn), dpi=130); plt.close(fig)
        print("  wrote", fn)

make("bytes", "RDMA read bytes / operation",
     "DEX network traffic PER OP: bytes pulled per operation vs cache  "
     "(offloading ships results, not pages)",
     "net_bytes_per_op")

make("bw", "read bandwidth (GB/s)",
     "DEX aggregate network bandwidth vs cache  (= bytes/op x throughput; "
     "the actual traffic on the link)",
     "net_bandwidth")

print("done.")
