#!/usr/bin/env python3
"""DEX (page B+tree) results for challenges 1-4, next to analytical-model.pdf.

Input: the CSV printed on server 6 by the "DEX results" command
  block,cache_mb,memthreads,tput_mops,p99_us,reads_per_op,req_per_op,mean_us,threads
and optionally the memory-node CSV from server 8
  block,cache_mb,memthreads,mn_peak_active_pct,mn_peak_per_thread_pct

  python plot_dex_c1c4.py dex_c1c4.csv [dex_memcpu.csv]

Writes fig_c1..fig_c4 (.png) and dex_c1c4.pdf next to the CSV, and prints a
model-vs-measured table. The model is analytical-model.pdf §4-5 with its own
default constants (Table "Platform constants") and the model tree's measured
shape (1 KB pages, 5 inner levels, 29 keys per leaf). Every axis starts at 0;
the panels of one figure share one scale.
"""
import csv, math, os, sys
from collections import defaultdict
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages

# ---- analytical-model.pdf, platform constants (defaults) -------------------
R, R_RPC, T_MSG, T_LVL, T_PAR, T_COPY = 2.0, 2.3, 0.2, 0.1, 0.025, 0.005   # us
I_NIC, B, H = 80.0, 12.5e3, 64          # Mops; bytes/us (12.5 GB/s); header bytes
S_REQ, S_RESP = 64, 16
# ---- the model tree, measured (m_check): DEX 1 KB pages --------------------
PAGE, KEYS_PER_LEAF, CLIENTS = 1024, 29, 40

PULL, PUSH2, PUSH8, MODEL = "#2f6fdb", "#e8743b", "#19a979", "#7a7a7a"
INK, MUTED, GRID = "#1f1f1f", "#6b6b6b", "#e6e6e6"


def model_pull(reads, nbytes=None):
    """Lookup pull: (m+1) dependent reads of one page each. Returns (T us, X Mops)."""
    nbytes = reads * PAGE if nbytes is None else nbytes
    t = reads * R + nbytes / B
    nu = max(reads / I_NIC, (nbytes + reads * H) / B)
    return t, 1.0 / nu


def model_push(levels, cores, extra_s=0.0, resp=S_RESP):
    """Push from the deepest cached node walking `levels` nodes on the memory node."""
    s = T_MSG + levels * T_LVL + extra_s
    t = R_RPC + s + (S_REQ + resp) / B
    x = min(cores / s, I_NIC / 2, B / (S_REQ + resp + 2 * H))
    return t, x, s


def scan_leaves(k):
    return math.ceil(k / KEYS_PER_LEAF) + 1


def model_scan_pull(k, batched=True):
    n = scan_leaves(k)
    rts = math.ceil(n / 32) if batched else n          # Sherman batches 32 reads; DEX: 1 per RT
    t = rts * R + n * PAGE / B
    nu = max(n / I_NIC, n * (PAGE + H) / B)
    return t, 1.0 / nu


def model_scan_push(k, cores):
    n = scan_leaves(k)
    return model_push(1, cores, extra_s=n * T_PAR + k * T_COPY, resp=64 + 16 * k)


# ---- data ------------------------------------------------------------------
def load(path):
    rows = []
    with open(path) as f:
        for r in csv.DictReader(f):
            for k in list(r):
                if k != "block":
                    try:
                        r[k] = float(r[k])
                    except (TypeError, ValueError):
                        r[k] = float("nan")
            rows.append(r)
    return rows


def pick(rows, block, mt=None, cache=None):
    out = [r for r in rows if r["block"] == block
           and (mt is None or r["memthreads"] == mt)
           and (cache is None or r["cache_mb"] == cache)]
    return out[0] if out else None


def style(ax, title, xlabel, ylabel):
    ax.set_title(title, fontsize=10, color=INK, loc="left")
    ax.set_xlabel(xlabel, fontsize=9, color=MUTED)
    ax.set_ylabel(ylabel, fontsize=9, color=MUTED)
    ax.grid(True, color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    ax.tick_params(labelsize=8, colors=MUTED)


def nice_max(v):
    if v <= 0 or math.isnan(v):
        return 1
    e = 10 ** math.floor(math.log10(v))
    for m in (1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10):
        if v <= m * e:
            return m * e
    return 10 * e


def line(ax, xs, ys, color, label, model=False, marker="o"):
    pts = [(x, y) for x, y in zip(xs, ys) if y is not None and not math.isnan(y)]
    if not pts:
        return
    a, b = zip(*pts)
    if model:
        ax.plot(a, b, color=color, lw=1.5, ls="--", alpha=0.75, label=label)
    else:
        ax.plot(a, b, color=color, lw=2, marker=marker, ms=6, label=label,
                markeredgecolor="white", markeredgewidth=1.2)


TABLE = []


def note(fig, ch, what, model, meas):
    TABLE.append((fig, ch, what, model, meas))


# ---- figures -----------------------------------------------------------------
def fig_c1(rows, mem):
    blk = "c1_dexr_model_warm"
    pull = pick(rows, blk, mt=0)
    cores = [1, 2, 4, 8]
    push = [pick(rows, blk, mt=c) for c in cores]
    if not pull:
        return None
    fig, axes = plt.subplots(1, 2 if mem else 1, figsize=(11 if mem else 6.2, 4))
    ax = axes[0] if mem else axes
    xs = [0] + cores
    ax.axhline(pull["tput_mops"], color=PULL, lw=2, label="pull, warm cache (measured)")
    tp, xp = model_pull(pull["reads_per_op"])
    ax.axhline(xp, color=PULL, lw=1.5, ls="--", alpha=0.75, label="pull (model)")
    line(ax, cores, [p["tput_mops"] if p else None for p in push], PUSH2, "push (measured)")
    line(ax, xs, [model_push(1, c)[1] for c in xs], PUSH2, "push from leaf parent (model)", model=True)
    ymax = nice_max(max(pull["tput_mops"], xp, *[model_push(1, c)[1] for c in cores],
                        *[p["tput_mops"] for p in push if p]))
    ax.set_ylim(0, ymax); ax.set_xlim(0, 8.4); ax.set_xticks(xs)
    style(ax, "Challenge 1 · DEX: lookup throughput vs memory cores",
          "memory-node cores", "Mops (40 clients)")
    ax.legend(fontsize=7.5, frameon=False, loc="upper left")
    per_core = [p["tput_mops"] / c for p, c in zip(push, cores) if p]
    if per_core:
        pc = sum(per_core) / len(per_core)
        ax.text(8.3, ymax * 0.04, f"cores to match pull: {pull['tput_mops'] / pc:.1f} measured, "
                f"{pull['tput_mops'] / model_push(1, 1)[1]:.1f} model", ha="right", fontsize=8, color=MUTED)
        note("1", "C1", "push per core (Mops)", model_push(1, 1)[1], pc)
        note("1", "C1", "cores for push to match pull", xp / model_push(1, 1)[1], pull["tput_mops"] / pc)
    note("1", "C1", "warm pull (Mops)", xp, pull["tput_mops"])
    if mem:
        ax2 = axes[1]
        cpu = [pick(mem, blk, mt=c) for c in cores]
        line(ax2, cores, [c["mn_peak_active_pct"] if c else None for c in cpu], PUSH2, "memory-node CPU, all threads")
        ax2.set_ylim(0, 100); ax2.set_xlim(0, 8.4); ax2.set_xticks(xs)
        style(ax2, "memory-node CPU while pushing", "memory-node cores", "busy %")
        ax2.legend(fontsize=7.5, frameon=False)
    fig.tight_layout()
    return fig


def fig_c2(rows):
    blk = "c2_dexr_model"
    caches = sorted({r["cache_mb"] for r in rows if r["block"] == blk})
    if not caches:
        return None
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(11, 4))
    xi = list(range(len(caches)))
    labels = [f"{int(c)} MB" for c in caches]
    pull = [pick(rows, blk, 0, c) for c in caches]
    p2 = [pick(rows, blk, 2, c) for c in caches]
    p8 = [pick(rows, blk, 8, c) for c in caches]
    line(a1, xi, [p["tput_mops"] if p else None for p in pull], PULL, "pull")
    line(a1, xi, [p["tput_mops"] if p else None for p in p2], PUSH2, "push, 2 cores")
    line(a1, xi, [p["tput_mops"] if p else None for p in p8], PUSH8, "push, 8 cores")
    mp = [model_pull(p["reads_per_op"])[1] if p else None for p in pull]
    m2 = [model_push(p["reads_per_op"], 2)[1] if p else None for p in pull]
    m8 = [model_push(p["reads_per_op"], 8)[1] if p else None for p in pull]
    line(a1, xi, mp, PULL, "pull (model)", model=True)
    line(a1, xi, m2, PUSH2, "push 2 (model)", model=True)
    line(a1, xi, m8, PUSH8, "push 8 (model)", model=True)
    vals = [v for s in (mp, m2, m8) for v in s if v] + \
           [p["tput_mops"] for s in (pull, p2, p8) for p in s if p]
    a1.set_ylim(0, nice_max(max(vals)))
    a1.set_xticks(xi, labels)
    style(a1, "Challenge 2 · DEX: lookup throughput vs cache", "compute-side cache (inner nodes: 60 MB)", "Mops (40 clients)")
    a1.legend(fontsize=7.5, frameon=False, ncol=2)
    line(a2, xi, [p["reads_per_op"] if p else None for p in pull], PULL, "pull: reads per lookup")
    line(a2, xi, [p["req_per_op"] if p else None for p in p2], PUSH2, "push: requests per lookup")
    a2.set_ylim(0, nice_max(max([p["reads_per_op"] for p in pull if p] + [1.2])))
    a2.set_xticks(xi, labels)
    style(a2, "round trips per lookup", "compute-side cache", "per lookup")
    a2.legend(fontsize=7.5, frameon=False)
    for c, p, a, b, m in zip(caches, pull, p2, mp, m2):
        if p:
            note("2", "C2", f"pull @ {int(c)} MB (Mops)", b, p["tput_mops"])
        if a:
            note("2", "C2", f"push 2 @ {int(c)} MB (Mops)", m, a["tput_mops"])
    fig.tight_layout()
    return fig


def fig_c3(rows):
    blk = "c3_dexr_model_idle"
    caches = sorted({r["cache_mb"] for r in rows if r["block"] == blk}, reverse=True)
    if not caches:
        return None
    fig, ax = plt.subplots(figsize=(6.2, 4))
    pull = [pick(rows, blk, 0, c) for c in caches]
    push = [pick(rows, blk, 1, c) for c in caches]
    ms = [max(p["reads_per_op"] - 1, 0) if p else None for p in pull]
    line(ax, ms, [p["mean_us"] if p else None for p in pull], PULL, "pull (measured)")
    line(ax, ms, [p["mean_us"] if p else None for p in push], PUSH2, "push (measured)")
    grid = [i / 10 for i in range(0, int(max(m for m in ms if m is not None) * 10) + 6)]
    line(ax, grid, [model_pull(m + 1)[0] for m in grid], PULL, "pull (model)", model=True)
    line(ax, grid, [model_push(m + 1, 1)[0] for m in grid], PUSH2, "push, idle (model)", model=True)
    for m, c in zip(ms, caches):
        if m is not None:
            ax.annotate(f"{int(c)} MB", (m, 0), textcoords="offset points", xytext=(0, 4),
                        ha="center", fontsize=7, color=MUTED)
    vals = [p["mean_us"] for s in (pull, push) for p in s if p] + [model_pull(grid[-1] + 1)[0]]
    ax.set_ylim(0, nice_max(max(vals))); ax.set_xlim(0, grid[-1])
    style(ax, "Challenge 3 · DEX: 1-client latency vs depth of the miss",
          "uncached inner levels m (measured reads per lookup − 1)", "mean latency (µs)")
    ax.legend(fontsize=7.5, frameon=False, loc="upper left")
    for m, p, q in zip(ms, pull, push):
        if p:
            note("3", "C3", f"pull latency, m={m:.2f} (us)", model_pull(m + 1)[0], p["mean_us"])
        if q:
            note("3", "C3", f"push latency, m={m:.2f} (us)", model_push(m + 1, 1)[0], q["mean_us"])
    fig.tight_layout()
    return fig


def fig_c4(rows):
    lens = sorted({int(b.split("_L")[1].split("_")[0]) for b in {r["block"] for r in rows}
                   if b.startswith("c4_dexr_model_L")})
    if not lens:
        return None
    fig, axes = plt.subplots(1, 3, figsize=(15, 4))
    a1, a2, a3 = axes
    xi = list(range(len(lens)))
    labels = [str(k) for k in lens]
    lat_pull = [pick(rows, f"c4_dexr_model_L{k}_c1", 0) for k in lens]
    lat_push = [pick(rows, f"c4_dexr_model_L{k}_c1", 1) for k in lens]
    line(a1, xi, [p["mean_us"] if p else None for p in lat_pull], PULL, "pull (measured)")
    line(a1, xi, [p["mean_us"] if p else None for p in lat_push], PUSH2, "push (measured)")
    line(a1, xi, [model_scan_pull(k)[0] for k in lens], PULL, "pull, batched leaves (model)", model=True)
    line(a1, xi, [model_scan_pull(k, batched=False)[0] for k in lens], MODEL,
         "pull, one leaf per round trip (DEX's path)", model=True)
    line(a1, xi, [model_scan_push(k, 1)[0] for k in lens], PUSH2, "push (model)", model=True)
    v1 = [p["mean_us"] for s in (lat_pull, lat_push) for p in s if p] + \
         [model_scan_pull(k, False)[0] for k in lens]
    a1.set_ylim(0, nice_max(max(v1))); a1.set_xticks(xi, labels)
    style(a1, "Challenge 4 · DEX: scan latency, 1 client", "keys per scan", "mean latency (µs)")
    a1.legend(fontsize=7, frameon=False, loc="upper left")

    tp_pull = [pick(rows, f"c4_dexr_model_L{k}", 0) for k in lens]
    tp_push = [pick(rows, f"c4_dexr_model_L{k}", 2) for k in lens]
    line(a2, xi, [p["tput_mops"] if p else None for p in tp_pull], PULL, "pull (measured)")
    line(a2, xi, [p["tput_mops"] if p else None for p in tp_push], PUSH2, "push, 2 cores (measured)")
    line(a2, xi, [model_scan_pull(k)[1] for k in lens], PULL, "pull (model)", model=True)
    line(a2, xi, [model_scan_push(k, 2)[1] for k in lens], PUSH2, "push 2 (model)", model=True)
    v2 = [p["tput_mops"] for s in (tp_pull, tp_push) for p in s if p] + \
         [model_scan_pull(k)[1] for k in lens] + [model_scan_push(k, 2)[1] for k in lens]
    a2.set_ylim(0, nice_max(max(v2))); a2.set_xticks(xi, labels)
    style(a2, "scan throughput, 40 clients", "keys per scan", "M scans/s")
    a2.legend(fontsize=7, frameon=False)

    ups = [0, 50, 100]
    def upd(u, mt):
        return pick(rows, "c1_dexr_model_warm", mt) if u == 0 else pick(rows, f"c4_dexr_model_upd{u}", mt)
    wp = [upd(u, 0) for u in ups]
    w2 = [upd(u, 2) for u in ups]
    line(a3, ups, [p["tput_mops"] if p else None for p in wp], PULL, "pull")
    line(a3, ups, [p["tput_mops"] if p else None for p in w2], PUSH2, "push, 2 cores")
    v3 = [p["tput_mops"] for s in (wp, w2) for p in s if p]
    a3.set_ylim(0, nice_max(max(v3 or [1]))); a3.set_xlim(0, 105); a3.set_xticks(ups)
    style(a3, "writes: update fraction", "% updates (rest lookups)", "Mops (40 clients)")
    a3.legend(fontsize=7.5, frameon=False)
    for k, p, q in zip(lens, lat_pull, lat_push):
        if p:
            note("4", "C4", f"{k}-key scan, pull latency (us) [model batched]", model_scan_pull(k)[0], p["mean_us"])
        if q:
            note("4", "C4", f"{k}-key scan, push latency (us)", model_scan_push(k, 1)[0], q["mean_us"])
    fig.tight_layout()
    return fig


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    rows = load(sys.argv[1])
    mem = load(sys.argv[2]) if len(sys.argv) > 2 else None
    out = os.path.dirname(os.path.abspath(sys.argv[1]))
    figs = [("fig_c1", fig_c1(rows, mem)), ("fig_c2", fig_c2(rows)),
            ("fig_c3", fig_c3(rows)), ("fig_c4", fig_c4(rows))]
    with PdfPages(os.path.join(out, "dex_c1c4.pdf")) as pdf:
        for name, f in figs:
            if f is None:
                print(f"{name}: no data yet")
                continue
            f.savefig(os.path.join(out, name + ".png"), dpi=150)
            pdf.savefig(f)
            plt.close(f)
    print(f"\n{'challenge':<10}{'quantity':<46}{'model':>10}{'measured':>10}{'meas/model':>12}")
    for _, ch, what, m, v in TABLE:
        r = v / m if m else float("nan")
        print(f"{ch:<10}{what:<46}{m:>10.2f}{v:>10.2f}{r:>12.2f}")
    print(f"\nwrote {out}/dex_c1c4.pdf and fig_c1..fig_c4.png")


if __name__ == "__main__":
    main()
