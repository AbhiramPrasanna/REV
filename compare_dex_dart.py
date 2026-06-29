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
                "mean": fnum(r.get("mean_us")),     # present in summary_full.csv
                "p50": fnum(r.get("p50_us")),       # present in summary_full.csv
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

def _slug(op, dist):
    return f"{op}_{dist}"

def plot_grid(dex, dart, field_dex, field_dart, ylabel, title, fname, outdir,
              dart_field2=None):
    """One PNG per (op,dist): <fname-stem>_<op>_<dist>.png."""
    stem = fname[:-4] if fname.endswith(".png") else fname
    for op in OPS:
        for dist in DISTS:
            md_off = dex.get((op, dist, "off"), {})
            md_on  = dex.get((op, dist, "on"), {})
            mt     = dart.get((op, dist), {})
            cs = caches_of(md_off, md_on, mt)
            if not cs:
                continue
            x = np.array(cs)
            yd_off = series(md_off, cs, field_dex)
            yd_on  = series(md_on,  cs, field_dex)
            yt     = series(mt, cs, field_dart)
            if all(v is None for v in yt) and dart_field2:
                yt = series(mt, cs, dart_field2)
            fig, a = plt.subplots(figsize=(7, 5))
            a.plot(x, yd_off, "o-", color="#1f77b4", label="DEX offload-off")
            a.plot(x, yd_on,  "s-", color="#d62728", label="DEX offload-on")
            a.plot(x, yt,     "^-", color="#2ca02c", label="DART (baseline)")
            a.set_xscale("log", base=2); a.set_xticks(x)
            a.get_xaxis().set_major_formatter(matplotlib.ticker.ScalarFormatter())
            a.set_title(f"{title}\n{TITLE[(op,dist)]}", fontsize=11)
            a.set_xlabel("cache (MB)")
            a.set_ylabel(ylabel); a.grid(True, alpha=.3); a.legend(fontsize=9)
            fig.tight_layout()
            p = os.path.join(outdir, f"{stem}_{_slug(op,dist)}.png")
            fig.savefig(p, dpi=130); plt.close(fig); print("wrote", p)

def plot_catches(dex, dart, outdir):
    """One PNG per (op,dist): DEX/DART p99 ratio vs cache; <1 means DEX faster."""
    for op in OPS:
        for dist in DISTS:
            md_on = dex.get((op, dist, "on"), {})
            md_off = dex.get((op, dist, "off"), {})
            mt = dart.get((op, dist), {})
            cs = caches_of(md_on, mt)
            if not cs:
                continue
            x = np.array(cs)
            def ratio(md):
                out = []
                for c in cs:
                    dexl = md.get(c, {}).get("p99")
                    dl = mt.get(c, {}).get("p99") or mt.get(c, {}).get("lat")
                    out.append(dexl/dl if (dexl and dl) else None)
                return out
            fig, a = plt.subplots(figsize=(7, 5))
            a.plot(x, ratio(md_on),  "s-", color="#d62728", label="DEX-on / DART")
            a.plot(x, ratio(md_off), "o-", color="#1f77b4", label="DEX-off / DART")
            a.axhline(1.0, color="k", ls="--", lw=1)
            a.fill_between(x, 0, 1, color="#2ca02c", alpha=.07)
            a.set_xscale("log", base=2); a.set_xticks(x)
            a.get_xaxis().set_major_formatter(matplotlib.ticker.ScalarFormatter())
            a.set_title(f"Where DEX catches DART (p99 ratio)\n{TITLE[(op,dist)]}",
                        fontsize=11)
            a.set_xlabel("cache (MB)")
            a.set_ylabel("p99 ratio (DEX / DART)\n<1 = DEX faster")
            a.grid(True, alpha=.3); a.legend(fontsize=9)
            fig.tight_layout()
            p = os.path.join(outdir, f"dex_catches_dart_{_slug(op,dist)}.png")
            fig.savefig(p, dpi=130); plt.close(fig); print("wrote", p)

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
    MT_KEEP = {2, 4}   # ignore mt6/mt8 (sweep incomplete)
    # pick offload-on rows; group by (op,dist) at the largest cache
    by = {}
    for r in rows:
        if r.get("offload","on").strip() != "on":
            continue
        m = int(float(r["memthreads"]))
        if m not in MT_KEEP:
            continue
        k = (norm_op(r["workload"]), norm_dist(r["dist"]), int(float(r["cache_mb"])))
        by.setdefault(k, []).append((m, fnum(r["throughput_mops"]),
                                     fnum(r["p99_us"])))
    if not by:
        print("skip memthreads (no offload-on rows)"); return
    maxcache = max(k[2] for k in by)
    # One PNG per (op,dist): throughput (+ remote CPU load) vs memThreadCount.
    for op in OPS:
        for dist in DISTS:
            if (op, dist, maxcache) not in by:
                continue
            pts = sorted(by[(op, dist, maxcache)])
            mts = [p[0] for p in pts]; thr = [p[1] for p in pts]
            fig, a = plt.subplots(figsize=(6.5, 5))
            a.plot(mts, thr, "s-", color="#d62728", label="throughput (Mops)")
            a.set_xlabel("memThreadCount"); a.set_ylabel("throughput (Mops)")
            a.set_title(f"memThreadCount scaling — {TITLE[(op,dist)]}\n"
                        f"cache={maxcache:.0f}MB, offload-on", fontsize=11)
            a.set_xticks(mts); a.grid(True, alpha=.3)
            load = [rl.get((op,dist,"on",m,maxcache)) for m in mts]
            if any(v is not None for v in load):
                a2 = a.twinx()
                a2.plot(mts, load, "^--", color="#7f7f7f",
                        label="remote CPU load %")
                a2.set_ylabel("peak remote CPU load (%)"); a2.set_ylim(0, None)
            a.legend(fontsize=9, loc="lower right")
            fig.tight_layout()
            p = os.path.join(outdir, f"memthreads_{_slug(op,dist)}.png")
            fig.savefig(p, dpi=130); plt.close(fig); print("wrote", p)

def plot_memthreads_cache(mt_csv, dex, dart, outdir):
    """One PNG per (op,dist): throughput vs CACHE, a separate line per
       memThreadCount (offload-on) — the joint memThreads x cache effect — with
       DEX-off and the DART flat baseline for reference."""
    if not (mt_csv and os.path.isfile(mt_csv)):
        print("skip memthreads_cache (no summary_memthreads.csv)"); return
    MT_KEEP = {2, 4}     # ignore mt6/mt8 (sweep incomplete)
    fam = {}             # (op,dist,mt) -> {cache: throughput}
    for r in csv.DictReader(open(mt_csv)):
        if r.get("offload", "on").strip() != "on":
            continue
        m = int(float(r["memthreads"]))
        if m not in MT_KEEP:
            continue
        t = fnum(r["throughput_mops"])
        if t is None:
            continue
        fam.setdefault((norm_op(r["workload"]), norm_dist(r["dist"]), m),
                       {})[fnum(r["cache_mb"])] = t
    reds = {2: "#fca5a5", 4: "#d62728", 6: "#991b1b", 8: "#450a0a"}
    for op in OPS:
        for dist in DISTS:
            mts = sorted({m for (o, d, m) in fam if (o, d) == (op, dist)})
            if not mts:
                continue
            moff = dex.get((op, dist, "off"), {})
            dt = dart.get((op, dist), {})
            cs = caches_of(moff, dt, *[fam[(op, dist, m)] for m in mts])
            x = np.array(cs)
            fig, a = plt.subplots(figsize=(7.5, 5.5))
            dnum = [v for v in ((dt.get(c, {}) or {}).get("thr") for c in cs) if v]
            if dnum:
                dl = float(np.median(dnum))
                a.axhline(dl, color="#2ca02c", ls="--", lw=2,
                          label=f"DART ~{dl:.2f} Mops (flat)")
            a.plot(x, series(moff, cs, "thr"), "o:", color="#1f77b4", lw=1.5,
                   label="DEX offload-off")
            for m in mts:
                fm = fam[(op, dist, m)]
                a.plot(x, [fm.get(c) for c in cs], "s-",
                       color=reds.get(m, "#d62728"), lw=2, label=f"DEX on, mt{m}")
            a.set_xscale("log", base=2); a.set_xticks(x)
            a.get_xaxis().set_major_formatter(matplotlib.ticker.ScalarFormatter())
            a.set_title(f"memThreads x cache -> throughput — {TITLE[(op,dist)]}\n"
                        "(offload-on; higher = better)", fontsize=10)
            a.set_xlabel("cache (MB)"); a.set_ylabel("throughput (Mops)")
            a.grid(True, alpha=.3); a.legend(fontsize=8)
            fig.tight_layout()
            p = os.path.join(outdir, f"memthreads_cache_{_slug(op,dist)}.png")
            fig.savefig(p, dpi=130); plt.close(fig); print("wrote", p)

def plot_radar(dex, dart, outdir, cache=512):
    """The 'story' plot: normalized radar per (op,dist).

    Axes (outward = better), one polygon per system:
      Throughput, Median speed (1/p50~p99), Tail speed (1/p99),
      Locality (low rdma/op), Offload capability (MN CPU usable).
    All normalized to the best system on that axis = 1.0.
    """
    metrics = ["Throughput", "Tail speed\n(1/p99)", "Network thrift\n(low RDMA/op)",
               "Cache\nrobustness", "Disaggregation\npurity (idle MN)"]
    N = len(metrics)
    ang = np.linspace(0, 2*np.pi, N, endpoint=False).tolist(); ang += ang[:1]
    for op in OPS:
        for dist in DISTS:
            mon = dex.get((op,dist,"on"), {}); moff = dex.get((op,dist,"off"), {})
            mt  = dart.get((op,dist), {})
            if not (mon or moff or mt): continue
            def at(m, c, f): return (m.get(c, {}) or {}).get(f)
            # raw values per system. purity = 1/(1+rpc/op): 1.0 when the MN does
            # no CPU work (DART, DEX-off), lower when offload burns remote cores.
            def thr(m):  return at(m, cache, "thr")
            def p99(m):  return at(m, cache, "p99")
            def p50(m):  return at(m, cache, "p50") or at(m, cache, "mean")
            sysraw = {}
            sysraw["DART"] = dict(thr=thr(mt),
                                  p50=p50(mt) or at(mt,cache,"lat"),
                                  p99=p99(mt) or at(mt,cache,"lat"),
                                  rdma=None, purity=1.0)
            sysraw["DEX-off"] = dict(thr=thr(moff), p50=p50(moff), p99=p99(moff),
                                     rdma=at(moff,cache,"rd_op"), purity=1.0)
            _rpc = at(mon,cache,"rpc_op")
            sysraw["DEX-on"]  = dict(thr=thr(mon), p50=p50(mon), p99=p99(mon),
                                     rdma=at(mon,cache,"rd_op"),
                                     purity=(1.0/(1.0+_rpc) if _rpc is not None else 0.5))
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
            push(lambda s: sysraw[s]["p99"], invert=True)    # tail speed (1/p99)
            push(lambda s: sysraw[s]["rdma"], invert=True)   # network thrift
            push(lambda s: rob[s])                           # cache robustness
            push(lambda s: sysraw[s]["purity"])              # disaggregation purity
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

def plot_tail_latency(dex, dart, mt_csv, outdir):
    """Tail latency (p99) vs cache, the focused view:
       - DART p99  = flat dashed baseline (it is cache-insensitive),
       - DEX off / DEX on (main sweep) p99 curves,
       - the DEX offload-ON mem-thread family (mt2/mt4/mt6) p99 curves,
       so you can see at WHICH cache DEX's tail dips below DART's, and how
       adding memThreads pulls that crossover in. Shaded green = DEX tail wins.
    """
    MT_KEEP = {2, 4}   # ignore mt6/mt8 (sweep incomplete)
    fam = {}   # offload-on p99 by (op,dist,memthreads) -> {cache: p99}
    if mt_csv and os.path.isfile(mt_csv):
        for r in csv.DictReader(open(mt_csv)):
            if r.get("offload", "on").strip() != "on":
                continue
            p = fnum(r.get("p99_us"))
            if p is None:
                continue
            m = int(float(r["memthreads"]))
            if m not in MT_KEEP:
                continue
            k = (norm_op(r["workload"]), norm_dist(r["dist"]), m)
            fam.setdefault(k, {})[fnum(r["cache_mb"])] = p
    reds = {2: "#fca5a5", 4: "#ef4444", 6: "#991b1b", 8: "#450a0a"}

    for op in OPS:
        for dist in DISTS:
            md_off = dex.get((op, dist, "off"), {})
            md_on  = dex.get((op, dist, "on"), {})
            mt     = dart.get((op, dist), {})
            mts = sorted({m for (o, d, m) in fam if (o, d) == (op, dist)})
            cs = caches_of(md_off, md_on, mt,
                           *[fam[(op, dist, m)] for m in mts])
            if not cs:
                continue
            fig, a = plt.subplots(figsize=(7.5, 5.5))
            x = np.array(cs)
            dart_p99 = [(mt.get(c, {}) or {}).get("p99") or
                        (mt.get(c, {}) or {}).get("lat") for c in cs]
            dvals = [v for v in dart_p99 if v]
            dline = float(np.median(dvals)) if dvals else None
            if dline is not None:
                a.axhline(dline, color="#2ca02c", ls="--", lw=2,
                          label=f"DART p99 ~{dline:.0f}us (flat)")
                a.fill_between(x, 0, dline, color="#2ca02c", alpha=.07)
            a.plot(x, series(md_off, cs, "p99"), "o-", color="#1f77b4",
                   lw=1.8, label="DEX off")
            if md_on:
                a.plot(x, series(md_on, cs, "p99"), "s--", color="#6b7280",
                       lw=1.3, label="DEX on (main)")
            for m in mts:
                fm = fam[(op, dist, m)]
                a.plot(x, [fm.get(c) for c in cs], "s-",
                       color=reds.get(m, "#d62728"), lw=2,
                       label=f"DEX on, mt{m}")
            # PREDICT the crossover: fit DEX-on p99 vs log2(cache) and extrapolate
            # to the cache where it meets DART's flat tail (p99 keeps falling with
            # cache, DART is flat, so they cross at a larger cache).
            xt = list(x)
            best = mts[-1] if mts else None        # use the best (most) memthreads
            yon = ([fam[(op, dist, best)].get(c) for c in cs] if best
                   else series(md_on, cs, "p99"))
            pts = [(np.log2(c), v) for c, v in zip(cs, yon) if v]
            if len(pts) >= 2 and dline:
                la = np.array([p[0] for p in pts]); ly = np.array([p[1] for p in pts])
                slope, b = np.polyfit(la, ly, 1)
                if slope < 0:
                    lcross = (dline - b) / slope
                    ccross = float(2 ** lcross)
                    if max(cs) < ccross <= 16384:     # crosses beyond swept range
                        xx = np.array([max(cs), ccross])
                        a.plot(xx, slope * np.log2(xx) + b, ":", lw=1.8,
                               color="#b91c1c",
                               label=f"extrapolated -> {ccross:.0f}MB")
                        a.plot([ccross], [dline], "*", ms=14, color="#b91c1c")
                        a.annotate(f"p99 catches DART\n~{ccross:.0f} MB",
                                   xy=(ccross, dline), xytext=(0, 8),
                                   textcoords="offset points", fontsize=8,
                                   color="#b91c1c", ha="center", fontweight="bold")
                        xt = sorted(set(xt + [ccross]))
                        a.set_xlim(min(cs) * 0.9, ccross * 1.25)
                        print(f"  predicted p99 crossover {op}/{dist}: ~{ccross:.0f} MB")
                    elif ccross <= max(cs):
                        print(f"  p99 already crosses {op}/{dist} within swept range")
            a.set_xscale("log", base=2); a.set_xticks(xt)
            a.get_xaxis().set_major_formatter(matplotlib.ticker.ScalarFormatter())
            a.set_title(f"Tail latency p99 vs cache — {TITLE[(op, dist)]}\n"
                        "DEX falls toward DART's flat tail (dotted = predicted "
                        "crossover; green = DEX wins)", fontsize=10)
            a.set_xlabel("cache (MB)")
            a.set_ylabel("p99 tail latency (us)"); a.grid(True, alpha=.3)
            a.set_ylim(0, None); a.legend(fontsize=8, ncol=2)
            fig.tight_layout()
            p = os.path.join(outdir, f"tail_latency_{_slug(op,dist)}.png")
            fig.savefig(p, dpi=130); plt.close(fig); print("wrote", p)

# ---- main ------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    _dexdir = os.path.join(HERE,"dex","build","results")
    _dexfull = os.path.join(_dexdir,"summary_full.csv")   # has mean_us/p50_us
    ap.add_argument("--dex", default=_dexfull if os.path.isfile(_dexfull)
                                     else os.path.join(_dexdir,"summary.csv"))
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
    plot_grid(dex, dart, "p99", "p99", "p99 tail latency (us)",
              "TAIL latency p99 vs cache (lower = better)",
              "latency_p99_vs_cache.png", args.out, dart_field2="lat")
    plot_catches(dex, dart, args.out)
    plot_tail_latency(dex, dart, args.memthreads, args.out)
    plot_memthreads(args.memthreads, args.remoteload, args.out)
    plot_memthreads_cache(args.memthreads, dex, dart, args.out)
    plot_radar(dex, dart, args.out, cache=args.radar_cache)
    print("done ->", args.out)

if __name__ == "__main__":
    import matplotlib.ticker
    main()
