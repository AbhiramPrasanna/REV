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
# The PDF's Fig. 1: warm pull = one leaf read; push-only = the memory node walks
# the whole tree (inner levels + leaf). Our push is one request per lookup that
# starts at the deepest cached node (here the leaf's parent).
C1_SYSTEMS = [
    # name, title, pull block, push block, levels walked by push-only, leaf bytes pulled, extra pull block
    ("dex", "DEX (page B+tree)", "c1_dexr_model_warm", "c1_dexr_model_warm", 6, PAGE, None),
    ("chime", "CHIME (hashed-leaf B+tree)", "c1_chime_model_pull", "c1_chime_model_push", 5, 180,
     "c1_chime_model_pull_nohot"),
]
C1_CORES = [1, 2, 4, 8]
C1_MC = [0, 1, 2, 4, 8, 16]


def c1_data(rows, spec):
    _, _, pblk, sblk, walk, leaf_b, extra = spec
    pull = pick(rows, pblk, mt=0)
    push = [pick(rows, sblk, mt=c) for c in C1_CORES]
    nohot = pick(rows, extra, mt=0) if extra else None
    return pull, push, nohot


def c1_panel(ax, rows, spec, ymax):
    name, title, _, _, walk, leaf_b, _ = spec
    pull, push, nohot = c1_data(rows, spec)
    _, xp = model_pull(1, leaf_b)
    cap = []
    if pull:
        ax.axhline(pull["tput_mops"], color=PULL, lw=2, label=f"pull, warm cache (measured: {pull['tput_mops']:.1f})")
    if nohot:
        ax.axhline(nohot["tput_mops"], color=PULL, lw=1.4, ls=(0, (6, 2)), alpha=0.9,
                   label=f"pull without hotspot buffer (measured: {nohot['tput_mops']:.1f})")
    if xp <= ymax:
        ax.axhline(xp, color=PULL, lw=1.5, ls="--", alpha=0.6, label=f"pull, warm (model: {xp:.1f})")
    else:
        ax.annotate(f"↑ pull, warm (model): {xp:.0f} Mops, above this chart",
                    (16.3, ymax), xytext=(0, -12), textcoords="offset points",
                    ha="right", fontsize=7.5, color=PULL)
    line(ax, C1_CORES, [p["tput_mops"] if p else None for p in push], PUSH2, "push, every lookup (measured)")
    line(ax, C1_MC, [model_push(walk, c)[1] for c in C1_MC], PUSH2,
         f"push-only from the root (model: {model_push(walk, 1)[1]:.2f}/core)", model=True)
    per_core = [p["tput_mops"] / c for p, c in zip(push, C1_CORES) if p and c <= 2]
    pc = sum(per_core) / len(per_core) if per_core else None
    if pc:
        ax.plot(C1_MC, [pc * c for c in C1_MC], color=PUSH8, lw=1.3, ls="-.",
                label=f"memory cores' capacity (cores ÷ {1 / pc:.2f} µs per request)")
        top = max((p["tput_mops"], c, p["mean_us"]) for p, c in zip(push, C1_CORES) if p)
        if top[2] == top[2] and top[2] > 0:
            ceil_ = CLIENTS / top[2]
            ax.axhline(ceil_, color=PUSH8, lw=1, ls=":")
            ax.annotate(f"{CLIENTS} clients ÷ {top[2]:.1f} µs per push = {ceil_:.1f} Mops",
                        (16.3, ceil_), xytext=(0, 3), textcoords="offset points",
                        ha="right", fontsize=7, color=PUSH8)
        ref = pull["tput_mops"] if pull else None
        cap.append(f"{name.upper()}: push {pc:.2f} Mops per core up to 2 cores" +
                   (f" -> would match pull at {ref / pc:.1f} cores" if ref else "") +
                   (f"; at {top[1]} cores {top[0]:.2f} Mops ({top[0] / ref:.0%} of pull)" if ref else ""))
        note("1", f"C1 {name}", "push per core, vs PDF push-only (Mops)", model_push(walk, 1)[1], pc)
        if ref:
            note("1", f"C1 {name}", "cores for push to match pull", xp / model_push(walk, 1)[1], ref / pc)
        note("1", f"C1 {name}", "push at 8 cores (Mops)", model_push(walk, 8)[1], top[0])
    if pull:
        note("1", f"C1 {name}", "warm pull (Mops)", xp, pull["tput_mops"])
    par = xp / model_push(walk, 1)[1]
    if xp > I_NIC / 2:
        ax.text(16.3, ymax * 0.55, "model: push never reaches pull\n(NIC message cap 40 Mops)",
                ha="right", fontsize=7, color=MUTED)
    elif par <= 16:
        ax.axvline(par, color=MODEL, lw=0.8, ls="--", alpha=0.5)
        ax.annotate(f"model parity\n{par:.1f} cores", (par, ymax * 0.6), xytext=(4, 0),
                    textcoords="offset points", fontsize=7, color=MUTED)
    ax.set_ylim(0, ymax); ax.set_xlim(0, 16.5); ax.set_xticks(C1_MC)
    style(ax, f"Challenge 1 · {title}", "memory-node cores", "Mops (40 clients)")
    ax.legend(fontsize=6.8, frameon=False, loc="upper left")
    return cap


def fig_c1(rows, mem):
    def has(s):
        pull, push, nohot = c1_data(rows, s)
        return any(r for r in [pull, nohot] + push)
    specs = [s for s in C1_SYSTEMS if has(s)]
    if not specs:
        return None
    # one shared scale: everything measured, the model's push lines up to 16 cores,
    # and model pull where it fits (CHIME's 51 Mops model pull is annotated instead)
    vals = [model_push(s[4], 16)[1] for s in specs] + [model_pull(1, PAGE)[1]]
    for s in specs:
        pull, push, nohot = c1_data(rows, s)
        vals += [r["tput_mops"] for r in [pull, nohot] + push if r]
    ymax = nice_max(max(vals) * 1.05)
    dex_mem = mem and "dex" in [s[0] for s in specs]
    n = len(specs) + (1 if dex_mem else 0)
    fig, axes = plt.subplots(1, n, figsize=(6.2 * n, 4.4))
    axes = [axes] if n == 1 else list(axes)
    caption = []
    for ax, s in zip(axes, specs):
        caption += c1_panel(ax, rows, s, ymax)
    if dex_mem:
        ax2 = axes[-1]
        spec = next(s for s in specs if s[0] == "dex")
        _, push, _ = c1_data(rows, spec)
        cpu = [pick(mem, spec[3], mt=c) for c in C1_CORES]
        line(ax2, C1_CORES, [c["mn_peak_per_thread_pct"] if c else None for c in cpu], PUSH2,
             "counted by DEX (request handling only)")
        per_core = [p["tput_mops"] / c for p, c in zip(push, C1_CORES) if p and c <= 2]
        if per_core:
            sreq = 1 / (sum(per_core) / len(per_core))
            line(ax2, C1_CORES, [min(100, p["tput_mops"] * sreq / c * 100) if p else None
                                 for p, c in zip(push, C1_CORES)], PUSH8,
                 f"real: throughput × {sreq:.2f} µs ÷ cores (incl. receiving)", marker="s")
        ax2.set_ylim(0, 110); ax2.set_xlim(0, 8.4); ax2.set_xticks([0] + C1_CORES)
        style(ax2, "DEX memory-node CPU per thread while pushing", "memory-node cores", "busy % per thread")
        ax2.legend(fontsize=7.5, frameon=False, loc="lower left")
    fig.tight_layout()
    if caption:
        fig.subplots_adjust(bottom=0.12 + 0.05 * len(caption))
        fig.text(0.01, 0.015, "\n".join(caption), fontsize=8, color=MUTED, ha="left", va="bottom")
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
    # any number of CSVs: result rows (DEX and/or CHIME, same columns) and the
    # memory-node CPU CSV (recognised by its mn_peak_* columns)
    rows, mem = [], None
    for path in sys.argv[1:]:
        with open(path) as f:
            head = f.readline()
        if "mn_peak" in head:
            mem = (mem or []) + load(path)
        else:
            rows += load(path)
    out = os.path.dirname(os.path.abspath(sys.argv[1]))
    figs = [("fig_c1", fig_c1(rows, mem)), ("fig_c2", fig_c2(rows)),
            ("fig_c3", fig_c3(rows)), ("fig_c4", fig_c4(rows))]
    def free(path):   # a file held open by a viewer (Windows) -> write next to it
        base, ext = os.path.splitext(path)
        for i in range(0, 50):
            cand = path if i == 0 else f"{base}_v{i + 1}{ext}"
            try:
                with open(cand, "ab"):
                    pass
                if i:
                    print(f"{os.path.basename(path)} is open in another program; writing {os.path.basename(cand)}")
                return cand
            except OSError:
                continue
        return path
    with PdfPages(free(os.path.join(out, "dex_c1c4.pdf"))) as pdf:
        for name, f in figs:
            if f is None:
                print(f"{name}: no data yet")
                continue
            target = os.path.join(out, name + ".png")
            for i in range(1, 50):
                try:
                    f.savefig(target, dpi=150)
                    break
                except OSError:   # open in an image viewer -> next free name
                    target = os.path.join(out, f"{name}_v{i + 1}.png")
                    print(f"{name}.png is open in another program; writing {os.path.basename(target)}")
            pdf.savefig(f)
            plt.close(f)
    print(f"\n{'challenge':<10}{'quantity':<46}{'model':>10}{'measured':>10}{'meas/model':>12}")
    for _, ch, what, m, v in TABLE:
        r = v / m if m else float("nan")
        print(f"{ch:<10}{what:<46}{m:>10.2f}{v:>10.2f}{r:>12.2f}")
    print(f"\nwrote {out}/dex_c1c4.pdf and fig_c1..fig_c4.png")


if __name__ == "__main__":
    main()
