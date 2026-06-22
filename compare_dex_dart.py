#!/usr/bin/env python3
"""
compare_dex_dart.py -- 1-to-1 head-to-head of DEX vs DART from their sweep CSVs.

Reads (paths auto-detected, or pass with flags):
  * DEX   : dex/build/results/summary.csv
            cols: workload,dist,offload,cache_mb,throughput_mops,p99_us,
                  rdma_read_per_op,rpc_per_op
  * DART  : DART/cache_sweep_baseline_summary_*.csv  (latest)
            cols: dist,op,cache_mb,throughput_mops,latency_us[,p99_us],bandwidth_gbps
  * (opt) DEX memthreads: dex/build/results/summary_memthreads.csv
  * (opt) DEX remote load: dex/build/results/remote_load_memthreads.csv

Writes PNGs into ./compare_plots/:
  1. throughput_vs_cache.png   DART vs DEX(off) vs DEX(on), 2x2 (op x dist)
  2. latency_vs_cache.png      p99 (or avg) latency, same panels
  3. dex_catches_dart.png      DEX/DART latency ratio vs cache (crossover at 1.0)
  4. memthreads.png            throughput + remote CPU load vs memThreadCount
  5. radar_<op>_<dist>.png     normalized radar: the "story" plot

Naming bridge: DEX workload {lookup,range} == DART op {lookup,scan}; DEX dist
{uniform,zipfian} == DART dist {uniform,zipf99}.

Run:  python compare_dex_dart.py
"""
import argparse, csv, glob, os, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))

# ---- canonical keys --------------------------------------------------------
def norm_op(s):    # lookup|range|scan -> lookup|scan(=range)
    s = s.strip().lower()
    return "scan" if s in ("range", "scan") else "lookup"

def norm_dist(s):  # uniform|zipfian|zipf99 -> uniform|zipf
    return "zipf" if "zip" in s.strip().lower() else "uniform"

def fnum(x):
    try: return float(x)
    except: return None

# ---- loaders ---------------------------------------------------------------
def load_dex(path):
    """-> {(op,dist,offload): {cache: row}}"""
    d = {}
    if not path or not os.path.isfile(path):
        return d
    with open(path) as f:
        for r in csv.DictReader(f):
            op, dist = norm_op(r["workload"]), norm_dist(r["dist"])
            off = r["offload"].strip().lower()
            c = fnum(r["cache_mb"])
            if c is None: continue
            d.setdefault((op, dist, off), {})[c] = {
                "thr": fnum(r.get("throughput_mops")),
                "p99": fnum(r.get("p99_us")),
                "rd_op": fnum(r.get("rdma_read_per_op")),
                "rpc_op": fnum(r.get("rpc_per_op")),
            }
    return d

def load_dart(path):
    """-> {(op,dist): {cache: row}}"""
    d = {}
    if not path or not os.path.isfile(path):
        return d
    with open(path) as f:
        for r in csv.DictReader(f):
            op, dist = norm_op(r["op"]), norm_dist(r["dist"])
            c = fnum(r["cache_mb"])
            if c is None: continue
            d.setdefault((op, dist), {})[c] = {
                "thr": fnum(r.get("throughput_mops")),
                "lat": fnum(r.get("latency_us")),
                "p99": fnum(r.get("p99_us")),   # NA in older CSVs
            }
    return d

def latest(pat):
    g = sorted(glob.glob(pat))
    return g[-1] if g else None

# ---- helpers ---------------------------------------------------------------
def caches_of(*maps):
    cs = set()
    for m in maps:
        for c in m: cs.add(c)
    return sorted(cs)

def series(m, caches, field):
    return [m.get(c, {}).get(field) for c in caches]

OPS = ["lookup", "scan"]
DISTS = ["uniform", "zipf"]
TITLE = {("lookup","uniform"):"Point lookup / Uniform",
         ("lookup","zipf"):"Point lookup / Zipf-0.99",
         ("scan","uniform"):"Range scan / Uniform",
         ("scan","zipf"):"Range scan / Zipf-0.99"}

def plot_grid(dex, dart, field_dex, field_dart, ylabel, title, fname, outdir,
              dart_field2=None):
    fig, axes = plt.subplots(2, 2, figsize=(12, 9))
    for ax, op in zip(axes, OPS):
        for a, dist in zip(ax, DISTS):
            md_off = dex.get((op, dist, "off"), {})
            md_on  = dex.get((op, dist, "on"), {})
            mt     = dart.get((op, dist), {})
            cs = caches_of(md_off, md_on, mt)
            if not cs:
                a.set_title(TITLE[(op,dist)] + " (no data)"); continue
            x = np.array(cs)
            yd_off = series(md_off, cs, field_dex)
            yd_on  = series(md_on,  cs, field_dex)
            yt     = series(mt, cs, field_dart)
            if all(v is None for v in yt) and dart_field2:
                yt = series(mt, cs, dart_field2)
            a.plot(x, yd_off, "o-", color="#1f77b4", label="DEX offload-off")
            a.plot(x, yd_on,  "s-", color="#d62728", label="DEX offload-on")
            a.plot(x, yt,     "^-", color="#2ca02c", label="DART (baseline)")
            a.set_xscale("log", base=2); a.set_xticks(x)
            a.get_xaxis().set_major_formatter(matplotlib.ticker.ScalarFormatter())
            a.set_title(TITLE[(op,dist)]); a.set_xlabel("cache (MB)")
            a.set_ylabel(ylabel); a.grid(True, alpha=.3); a.legend(fontsize=8)
    fig.suptitle(title, fontsize=14); fig.tight_layout()
    p = os.path.join(outdir, fname); fig.savefig(p, dpi=130); plt.close(fig)
    print("wrote", p)

def plot_catches(dex, dart, outdir):
    """DEX-on / DART latency ratio vs cache; <1 means DEX is faster (catches)."""
    fig, axes = plt.subplots(2, 2, figsize=(12, 9))
    for ax, op in zip(axes, OPS):
        for a, dist in zip(ax, DISTS):
            md_on = dex.get((op, dist, "on"), {})
            md_off = dex.get((op, dist, "off"), {})
            mt = dart.get((op, dist), {})
            cs = caches_of(md_on, mt)
            if not cs:
                a.set_title(TITLE[(op,dist)] + " (no data)"); continue
            x = np.array(cs)
            def ratio(md):
                out = []
                for c in cs:
                    dexl = md.get(c, {}).get("p99")
                    dl = mt.get(c, {}).get("p99") or mt.get(c, {}).get("lat")
                    out.append(dexl/dl if (dexl and dl) else None)
                return out
            a.plot(x, ratio(md_on),  "s-", color="#d62728", label="DEX-on / DART")
            a.plot(x, ratio(md_off), "o-", color="#1f77b4", label="DEX-off / DART")
            a.axhline(1.0, color="k", ls="--", lw=1)
            a.fill_between(x, 0, 1, color="#2ca02c", alpha=.07)
            a.set_xscale("log", base=2); a.set_xticks(x)
            a.get_xaxis().set_major_formatter(matplotlib.ticker.ScalarFormatter())
            a.set_title(TITLE[(op,dist)]); a.set_xlabel("cache (MB)")
            a.set_ylabel("latency ratio (DEX / DART)\n<1 = DEX faster")
            a.grid(True, alpha=.3); a.legend(fontsize=8)
    fig.suptitle("Where DEX catches DART (latency ratio; below dashed line = DEX wins)",
                 fontsize=14)
    fig.tight_layout()
    p = os.path.join(outdir, "dex_catches_dart.png"); fig.savefig(p, dpi=130)
    plt.close(fig); print("wrote", p)

def plot_memthreads(mt_csv, rl_csv, outdir):
    if not (mt_csv and os.path.isfile(mt_csv)):
        print("skip memthreads (no summary_memthreads.csv)"); return
    rows = list(csv.DictReader(open(mt_csv)))
    rl = {}
    if rl_csv and os.path.isfile(rl_csv):
        for r in csv.DictReader(open(rl_csv)):
            rl[(norm_op(r["workload"]), norm_dist(r["dist"]),
                r.get("offload","on"), int(float(r["memthreads"])),
                int(float(r["cache_mb"])))] = fnum(r["peak_aggregate_active_pct"])
    # pick offload-on rows; group by (op,dist) at the largest cache
    by = {}
    for r in rows:
        if r.get("offload","on").strip() != "on":
            continue
        k = (norm_op(r["workload"]), norm_dist(r["dist"]), int(float(r["cache_mb"])))
        by.setdefault(k, []).append((int(float(r["memthreads"])),
                                     fnum(r["throughput_mops"]), fnum(r["p99_us"])))
    if not by:
        print("skip memthreads (no offload-on rows)"); return
    maxcache = max(k[2] for k in by)
    panels = [(op,dist) for op in OPS for dist in DISTS
              if (op,dist,maxcache) in by]
    fig, axes = plt.subplots(1, len(panels), figsize=(5*len(panels), 4.5),
                             squeeze=False)
    for a,(op,dist) in zip(axes[0], panels):
        pts = sorted(by[(op,dist,maxcache)])
        mts = [p[0] for p in pts]; thr = [p[1] for p in pts]
        a.plot(mts, thr, "s-", color="#d62728", label="throughput (Mops)")
        a.set_xlabel("memThreadCount"); a.set_ylabel("throughput (Mops)")
        a.set_title(f"{TITLE[(op,dist)]}\ncache={maxcache}MB, offload-on")
        a.set_xticks(mts); a.grid(True, alpha=.3)
        load = [rl.get((op,dist,"on",m,maxcache)) for m in mts]
        if any(v is not None for v in load):
            a2 = a.twinx()
            a2.plot(mts, load, "^--", color="#7f7f7f", label="remote CPU load %")
            a2.set_ylabel("peak remote CPU load (%)"); a2.set_ylim(0, None)
        a.legend(fontsize=8, loc="lower right")
    fig.suptitle("memThreadCount: more MN service threads -> faster offload, until it saturates",
                 fontsize=13)
    fig.tight_layout()
    p = os.path.join(outdir, "memthreads.png"); fig.savefig(p, dpi=130)
    plt.close(fig); print("wrote", p)

def plot_radar(dex, dart, outdir, cache=512):
    """The 'story' plot: normalized radar per (op,dist).

    Axes (outward = better), one polygon per system:
      Throughput, Median speed (1/p50~p99), Tail speed (1/p99),
      Locality (low rdma/op), Offload capability (MN CPU usable).
    All normalized to the best system on that axis = 1.0.
    """
    metrics = ["Throughput", "Tail speed\n(1/p99)", "Locality\n(low RDMA/op)",
               "Offload\ncapability", "Cache\nrobustness"]
    N = len(metrics)
    ang = np.linspace(0, 2*np.pi, N, endpoint=False).tolist(); ang += ang[:1]
    for op in OPS:
        for dist in DISTS:
            mon = dex.get((op,dist,"on"), {}); moff = dex.get((op,dist,"off"), {})
            mt  = dart.get((op,dist), {})
            if not (mon or moff or mt): continue
            def at(m, c, f): return (m.get(c, {}) or {}).get(f)
            # raw values per system
            def thr(m):  return at(m, cache, "thr")
            def p99(m):  return at(m, cache, "p99")
            sysraw = {}
            sysraw["DART"] = dict(thr=thr(mt), p99=p99(mt) or at(mt,cache,"lat"),
                                  rdma=None, offload=0.0)
            sysraw["DEX-off"] = dict(thr=thr(moff), p99=p99(moff),
                                     rdma=at(moff,cache,"rd_op"), offload=0.0)
            sysraw["DEX-on"]  = dict(thr=thr(mon), p99=p99(mon),
                                     rdma=at(mon,cache,"rd_op"),
                                     offload=at(mon,cache,"rpc_op") or 1.0)
            # cache robustness = thr(maxcache)/thr(mincache); flat (>=1) is robust
            def robust(m):
                cs = sorted(m)
                if len(cs) < 2 or not m[cs[0]].get("thr") or not m[cs[-1]].get("thr"):
                    return None
                lo, hi = m[cs[0]]["thr"], m[cs[-1]]["thr"]
                return lo/hi if hi else None   # ~1 robust, <1 cache-hungry
            rob = {"DART": robust(mt), "DEX-off": robust(moff), "DEX-on": robust(mon)}
            # build per-axis arrays, normalize (bigger=better)
            axis_vals = {s: [] for s in sysraw}
            def push(getter, invert=False):
                vals = {s: getter(s) for s in sysraw}
                nums = [v for v in vals.values() if v]
                if not nums:
                    for s in sysraw: axis_vals[s].append(0.0); return
                if invert:
                    vals = {s: (1.0/v if v else None) for s,v in vals.items()}
                    nums = [v for v in vals.values() if v]
                mx = max(nums)
                for s in sysraw:
                    axis_vals[s].append((vals[s]/mx) if (vals[s] and mx) else 0.0)
            push(lambda s: sysraw[s]["thr"])                 # throughput
            push(lambda s: sysraw[s]["p99"], invert=True)    # tail speed
            push(lambda s: sysraw[s]["rdma"], invert=True)   # locality
            push(lambda s: sysraw[s]["offload"])             # offload capability
            push(lambda s: rob[s])                           # cache robustness
            fig = plt.figure(figsize=(6.5, 6.5))
            a = fig.add_subplot(111, polar=True)
            colors = {"DART":"#2ca02c","DEX-off":"#1f77b4","DEX-on":"#d62728"}
            for s in ["DART","DEX-off","DEX-on"]:
                v = axis_vals[s] + axis_vals[s][:1]
                a.plot(ang, v, "o-", lw=2, color=colors[s], label=s)
                a.fill(ang, v, color=colors[s], alpha=.10)
            a.set_xticks(ang[:-1]); a.set_xticklabels(metrics, fontsize=9)
            a.set_ylim(0, 1.05); a.set_yticks([.25,.5,.75,1.0])
            a.set_title(f"{TITLE[(op,dist)]}  @ {cache}MB cache\n"
                        "(outward = better; normalized per axis)", fontsize=11)
            a.legend(loc="upper right", bbox_to_anchor=(1.25,1.1), fontsize=9)
            fig.tight_layout()
            p = os.path.join(outdir, f"radar_{op}_{dist}.png")
            fig.savefig(p, dpi=130); plt.close(fig); print("wrote", p)

# ---- main ------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dex", default=os.path.join(HERE,"dex","build","results","summary.csv"))
    ap.add_argument("--dart", default=latest(os.path.join(HERE,"DART","cache_sweep_baseline_summary_*.csv")))
    ap.add_argument("--memthreads", default=os.path.join(HERE,"dex","build","results","summary_memthreads.csv"))
    ap.add_argument("--remoteload", default=os.path.join(HERE,"dex","build","results","remote_load_memthreads.csv"))
    ap.add_argument("--radar-cache", type=float, default=512)
    ap.add_argument("--out", default=os.path.join(HERE,"compare_plots"))
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    import matplotlib.ticker  # noqa

    dex = load_dex(args.dex)
    dart = load_dart(args.dart)
    print(f"DEX rows: {sum(len(v) for v in dex.values())} from {args.dex}")
    print(f"DART rows: {sum(len(v) for v in dart.values())} from {args.dart}")
    if not dex and not dart:
        sys.exit("No data found. Run the sweeps first, or pass --dex/--dart.")

    plot_grid(dex, dart, "thr", "thr", "throughput (Mops)",
              "Throughput vs cache (higher = better)",
              "throughput_vs_cache.png", args.out)
    plot_grid(dex, dart, "p99", "p99", "p99 latency (us)",
              "p99 latency vs cache (lower = better)",
              "latency_vs_cache.png", args.out, dart_field2="lat")
    plot_catches(dex, dart, args.out)
    plot_memthreads(args.memthreads, args.remoteload, args.out)
    plot_radar(dex, dart, args.out, cache=args.radar_cache)
    print("done ->", args.out)

if __name__ == "__main__":
    import matplotlib.ticker
    main()
