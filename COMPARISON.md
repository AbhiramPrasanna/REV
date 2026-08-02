# DEX vs DART — head-to-head methodology, results, and the radial story

This document ties together the 1-to-1 comparison harness: what was added, how to
run both systems so they compete fairly, what the current data already says about
**where and how DEX catches DART**, the new **remote-load vs compute-load**
tracker, the **memThreadCount** experiment, and the **radial-plot** design.

It pairs with:
- [dex/skills.md](dex/skills.md) — DEX internals (path-aware cache, offloading, §7 tree geometry).
- [DART/test/skills.md](DART/test/skills.md) — DART microbench + `bench_stats.h`.
- [compare_dex_dart.py](compare_dex_dart.py) — the head-to-head + radar plotter.

---

## 0. What changed (so the two systems are measured the same way)

| change | file | why |
|---|---|---|
| DART now prints the **raw 500 ns bucket histogram (count/pct/CDF)** + per-op `ALL` row + `p90`/`max` | [DART/test/dart_microbench/bench_stats.h](DART/test/dart_microbench/bench_stats.h) | identical latency artifact to DEX's `print_buckets`; "number of ops per 500 ns bucket" |
| DART baseline sweep now also captures **p99** (from the `[ALL OPS]` block) | [DART/script/cache_sweep_baseline.sh](DART/script/cache_sweep_baseline.sh) | so latency competes p99-to-p99 with DEX (DEX CSV already had p99) |
| DEX **remote-CPU-load tracker** (dir-thread active fraction) | [dex/include/remote_load.h](dex/include/remote_load.h), [dex/src/Directory.cpp](dex/src/Directory.cpp) | the true "remote load" signal under busy-poll (see §3) |
| **Per-node CPU sampler** (process + system %), both systems | [dex/include/cpu_sampler.h](dex/include/cpu_sampler.h), [DART/test/dart_microbench/cpu_sampler.h](DART/test/dart_microbench/cpu_sampler.h) | see memory-node vs compute-node CPU directly (§3.1) — wired into all 4 mains |
| **Threads matched 32 compute / 4 memory**, and made a swept dimension on both | DEX `sweep*.sh`/`run*.sh` (`THREADS=KMAX=32`, `MEMTHREADS=4`); DART `cache_sweep_baseline*.sh` (`THREADS_SET=(32)`) | 1-to-1 thread budget; sweep `THREADS_SET`/`THREADS` to study scaling |
| `NR_DIRECTORY` 4 → 8 | [dex/include/Common.h](dex/include/Common.h) | allow the memThreadCount sweep up to 8 (**rebuild BOTH nodes**) |
| **memThreadCount sweep** (full matrix, offload off+on) | [dex/script/sweep_memthreads.sh](dex/script/sweep_memthreads.sh) + `_other.sh` | answer "do more MN threads make offload faster, and when does it stop mattering" |
| **head-to-head + radar plotter** | [compare_dex_dart.py](compare_dex_dart.py) | overlays DART vs DEX(off/on), crossover, memthreads, radar |

> All latency instrumentation compiles away when `BENCH_LATENCY` / `REMOTE_LOAD`
> are undefined; overhead is one clock pair (+ counter reads) per op, negligible
> vs an RDMA round trip.

---

## 1. Making them compete 1-to-1

Both sweeps already share the **working set and matrix**:

```
50 M keys (16 B/entry)   ·   30–50 M measured ops
op   ∈ {point-lookup, range-scan(100 keys)}
dist ∈ {uniform, zipf-0.99}
cache ∈ {64, 128, 256, 512} MB  (compute-side directory cache)
```

Two things to equalize for a *fair* comparison, both now wired into the harness:

1. **Thread count — matched at 32 compute + 4 memory.** Both DEX sweep scripts
   now use `THREADS=32`/`KMAX=32` with `MEMTHREADS=4`; DART uses `THREADS_SET=(32)`
   compute threads. (DART has **no** memory-side service threads to match DEX's
   `MEMTHREADS=4` — its MN does no CPU work, §3 — so "4 mem threads" is a
   DEX-only knob.) Thread count is now a **swept dimension on both sides**: edit
   `MEMTHREAD_SET` / `THREADS` in DEX and `THREADS_SET` in DART
   (e.g. `THREADS_SET=(8 16 24 32)`) to study scaling. In DART, `--th_b` is
   recomputed per thread count so the *total* cache stays fixed, and the memory
   script counts the same iterations (the monitor pushes thread counts to it).
   Keep `DEX THREADS ≤ KMAX` (=32) so the topology stays 1-compute/1-memory.
2. **Latency percentile.** Compare **p99-to-p99** (now available on both) rather
   than DEX-p99 vs DART-avg.

DART has **no offload axis** by design (no pushdown). DEX is therefore run in two
modes — **offload-off** (pure caching, the apples-to-apples baseline vs DART) and
**offload-on** (`-DMANUAL_PUSHDOWN`, `RPC=1`) — so the plots carry three curves:
`DART`, `DEX offload-off`, `DEX offload-on`.

---

## 2. Where & how DEX catches DART (from the current `summary.csv`)

Numbers below are the committed DEX sweep ([dex/build/results/summary.csv](dex/build/results/summary.csv))
and the DART baseline ([DART/cache_sweep_baseline_summary_20260615_125117.csv](DART/cache_sweep_baseline_summary_20260615_125117.csv)).
Throughput in Mops (absolute; mind the thread-count caveat §1).

**Point lookup — throughput vs cache (64→512 MB)**

| system | uniform | zipf-0.99 |
|---|---|---|
| DART (baseline) | ~2.5 – 2.6 (flat) | ~4.3 (flat) |
| DEX offload-off | 1.29 → 2.52 | 2.04 → 5.06 |
| DEX offload-on  | 2.17 → **4.93** | 3.30 → **8.66** |

**Range scan — throughput vs cache**

| system | uniform | zipf-0.99 |
|---|---|---|
| DART (baseline) | ~1.1 → 1.68 | ~1.73 (flat) |
| DEX offload-off | 0.42 → 0.56 | 0.60 → 0.95 |
| DEX offload-on  | 0.90 → **1.46** | 1.29 → **2.37** |

**Reading it:**

- **DEX-offload-off never catches DART.** Pure caching pays a full page READ on
  every miss; `rdma_read/op` only falls slowly with cache (lookup-uniform
  6.8→3.3). DART's lean ART + skip-table baseline is simply faster per miss.
- **Offloading is how DEX catches and passes DART.** With `RPC=1` the dominant
  leaf miss becomes an RPC that ships an **8 B value** instead of a 512 B–1 KB
  page: `rdma_read/op` collapses to ~0 (lookup-uniform `2.33 → 0.0008` across the
  cache sweep), so DEX-on **overtakes DART**:
  - point-lookup **uniform**: crosses DART at ≈128 MB, ≈1.9× DART by 512 MB;
  - point-lookup **zipf**: crosses at ≈256 MB, ≈2× DART by 512 MB;
  - range **uniform**: catches DART only near 512 MB (offload collapses ~N leaf
    reads into 1 RPC + 1 scratch read; `rpc/op > 1` confirms multi-leaf);
  - range **zipf**: passes DART by ≈256 MB (2.37 vs 1.73 at 512 MB).
- **Latency.** DEX-on p99 falls to **14 µs (lookup-uniform) / 12.5 µs
  (lookup-zipf)** at 512 MB — into DART's operating range. The crossover panel
  ([compare_plots/dex_catches_dart.png](compare_plots/)) plots `DEX/DART` latency
  ratio; below the dashed 1.0 line is where DEX is faster.

**The "how" in one line:** DEX catches DART by **converting page-shipping into
result-shipping** (offload) and by keeping the **inner path resident** (needs
cache ≥ the ~256 MB inner working set, skills §7.2). It catches *earlier under
zipf* (free hot-set hits) and *needs more cache for scans* (more leaves per op).
DART wins when you cannot/should not spend memory-node CPU: it stays flat-fast
with zero MN load, especially under skew.

---

## 3. Remote-load vs compute-load tracker (node CPU utilization)

**Goal:** for each system, how much work sits on the **memory node CPU** ("remote
load") vs the **compute node CPU** ("compute load") — the saturation view that
tells you when adding memory-side service threads stops helping.

**Key subtlety (why raw CPU% is the wrong number):** both systems **busy-poll**
the NIC. DEX directory threads run `while(true){ pollWithCQ(); process_message();}`
on pinned cores ([dex/src/Directory.cpp](dex/src/Directory.cpp)); compute workers
spin on completion queues. So `top`/CPU% is pinned at ~100% whether or not there
is real work. The meaningful metric is the **active-work fraction**:

```
remote load  =  time inside process_message  /  dir-thread wall-time
```

[dex/include/remote_load.h](dex/include/remote_load.h) accumulates this per
dir-thread and a background reporter prints, every 2 s:

```
----- REMOTE CPU LOAD (memory node dir-threads, 2s window) -----
  dir 0: active= 73.4%  msgs=...   ... ns/msg
  ...
  AGGREGATE active = 251.0% (of 4 dir-threads; 62.8% per-thread avg)  msgs=...
```

**What the two systems show:**

- **DART memory node = 0% remote CPU load, by construction.** `memory.cc` sets up
  QPs, sends `ready`, then **blocks on a socket** until the run ends
  ([DART/src/main/memory.cc:173](DART/src/main/memory.cc#L173)). Every access is
  one-sided RDMA served by the NIC; the CPU never touches an op. *All* of DART's
  work is compute-side. (DART's "remote cost" is purely network — captured by
  `rtt/op` in its `bench_stats.h`, not CPU.)
- **DEX offload-off ≈ 0% remote load** too (caching is one-sided; the MN CPU is
  idle). **DEX offload-on > 0%**: each RPC runs index work on the MN CPU. This is
  the *only* regime where memory-node CPU load — and `memThreadCount` — matters.

So "remote vs compute load" is really a story about **where the cycles live**:
DART and DEX-caching put 100% of compute on the CN and use the MN as dumb memory;
DEX-offload deliberately moves some compute onto the MN to save network bytes —
which is exactly what §4 stress-tests.

> Compute-side split (compute vs RDMA-wait) on DEX can be read from the existing
> `LOCAL` vs `REMOTE` latency rows and `remote ops/op`; for an exact time split
> enable `COUNT_TIME` in [dex/include/DSM.h](dex/include/DSM.h) and divide
> `rdma_read_time/op` by total op time.

### 3.1 Seeing it directly: the per-node CPU sampler

[dex/include/cpu_sampler.h](dex/include/cpu_sampler.h) /
[DART/test/dart_microbench/cpu_sampler.h](DART/test/dart_microbench/cpu_sampler.h)
(both already wired into the binaries' `main`) print, every 2 s, on **each
node**:

```
[CPU compute ] process=  92.31% of 64 cores   system=  48.10%   (window 2s)
[CPU memory  ] process=   0.04% of 64 cores   system=   3.20%   (window 2s)   <- DART
```

`process%` is `(utime+stime)/(wall·cores)` — gross CPU the binary burns;
`system%` is whole-machine busy. Read **alongside** the dir-thread active% so you
separate *cores pegged* from *work done* — this is exactly your point that "even
if the NIC is at 100%, the work being done in compute must differ from memory":

| node / mode | `cpu_sampler` process% | useful-work % | meaning |
|---|---|---|---|
| **DART memory** | **~0%** (blocked on a socket) | 0 | MN is pure passive RDMA target; *all* work is on the CN |
| **DART compute** | high (workers + RDMA spin-wait) | the index logic | the compute load |
| **DEX memory, offload-off** | ~100%×memThreads (dir-threads **spin**) | **~0%** active | cores pegged by busy-poll, **no useful work** |
| **DEX memory, offload-on** | ~100%×memThreads (spin) | **>0%** active (rises w/ rpc) | cores pegged **and** doing real RPC work — the *remote load* |
| **DEX compute** | high (workers + RDMA spin-wait) | index logic + RPC issue | the compute load |

So the two systems put the cycles in different places: **DART and DEX-caching =
100% of useful work on the compute node, memory node idle/spinning**; **DEX-offload
deliberately migrates a measured slice of useful work onto the memory-node CPU**
(visible as dir-thread active% > 0 even though the gross CPU% was already pinned
by the poll). The memThreads study (§4) is precisely about how far you can push
that migrated slice before the MN service threads saturate.

---

## 4. memThreadCount experiment — does offload "get there faster"?

**Run:** [dex/script/sweep_memthreads.sh](dex/script/sweep_memthreads.sh) (node 0)
+ `sweep_memthreads_other.sh` (node 1). Full working set
(`op × dist × cache{64..512}`) × **offload {off,on}** × **memThreadCount {2,4,6,8}**.
Requires `NR_DIRECTORY ≥ 8` (now 8) and a **rebuild on both nodes**.

**Hypothesis / what to expect:**

- **Offload-off rows = control:** MN does no CPU work, so remote load stays ~0%
  and throughput/p99 are **flat in memThreadCount**. (If they move, something
  else changed — a guardrail.)
- **Offload-on rows:** each dir-thread serves RPCs serially while it busy-polls.
  Adding threads adds **parallel MN service capacity**, so offloaded ops queue
  less and "get there faster":
  - throughput **rises** and p99 **falls** with memThreadCount **while the MN is
    the bottleneck** (per-thread active% high, aggregate climbing);
  - the gain **flattens** once the bottleneck moves to the **network** (NIC
    message rate) or the **compute node** (it can't issue RPCs faster) — at that
    point per-thread active% **drops** even as you add threads, and throughput is
    flat. That inflection is the answer to *"at what point does it stop
    mattering."*
- **How much faster:** read it off `summary_memthreads.csv` (throughput/p99) ×
  `remote_load_memthreads.csv` (peak aggregate active%). The
  [compare_plots/memthreads.png](compare_plots/) panel overlays throughput (left
  axis) and remote CPU load (right axis) vs memThreadCount; the knee where the
  load curve stops rising is where extra threads stop buying throughput.
- **Where it matters most:** **uniform + scans** (highest offload volume / MN
  work per op) should benefit most from more threads; **zipf lookups** least
  (many ops are free local hits, so the MN is lightly loaded and saturates late).

---

## 5. Radial (radar) plot — metrics and the story

The radar ([compare_plots/radar_<op>_<dist>.png](compare_plots/)) puts the three
systems (DART, DEX-off, DEX-on) on one normalized polygon per workload. **Axes,
all oriented "outward = better," normalized to the best system per axis = 1.0:**

| axis | raw metric | why it's in the story |
|---|---|---|
| **Throughput** | Mops | headline capacity |
| **Tail speed** | 1 / p99 | tail latency, the SLO-relevant number |
| **Locality** | 1 / (RDMA reads-per-op) | how little it touches the network per op — DART's and DEX-offload's structural advantage from different mechanisms |
| **Offload capability** | rpc/op (DART = 0) | the *capability* axis: only DEX-on can move work to the MN; this is the dimension DART structurally lacks |
| **Cache robustness** | thr(min-cache)/thr(max-cache) | how flat performance is as cache shrinks — high = degrades gracefully under memory pressure |

**The story the radar should tell:**

- **DART** is a *spiky specialist*: large on **Locality** and **Cache
  robustness** (flat, skip-table keeps hot paths local with little cache) and
  decent **Tail speed**, but **collapsed to zero on Offload capability** and
  middling on **Throughput** at large cache — it cannot trade MN CPU for network
  bytes.
- **DEX offload-off** is a *smaller version of the same shape* — it shares DART's
  "no MN CPU" profile but with **worse Locality** (pays full page reads), so its
  polygon sits inside DART's on most axes.
- **DEX offload-on** is the *balanced, larger polygon*: it lights up **Offload
  capability**, pushes **Locality** to the max (reads/op → ~0), and takes the
  **Throughput**/**Tail speed** lead at adequate cache — visibly *enclosing* the
  other two under uniform/large-cache, while under zipf-small-cache DART's
  robustness corner still pokes out.

So across the four workload radars the narrative is: **DART = lean, robust, MN-free
baseline; DEX = pays for an extra capability (offload) that, once the cache holds
the inner path, expands its polygon past DART — most under uniform/large cache,
least under zipf where DART's free locality already wins.**

---

## 6. Run order (cluster)

```bash
# DEX (node 0 / node 1), MANUAL_PUSHDOWN build, NR_DIRECTORY=8 on BOTH:
cd dex/build && cmake -DCMAKE_BUILD_TYPE=Release -DMANUAL_PUSHDOWN=ON .. && make -j
cp ../script/{restartMemc.sh,run*.sh,sweep*.sh} .
./sweep.sh            # node 0   (offload off/on baseline)   ./sweep_other.sh on node 1
./sweep_memthreads.sh # node 0   (memThreadCount study)      ./sweep_memthreads_other.sh on node 1

# DART (compute host / memory host):
./build.sh
./script/cache_sweep_baseline.sh         # 10.30.1.7   (+ _other.sh on 10.30.1.6)

# Plot everything (needs matplotlib; run where the CSVs are):
python compare_dex_dart.py
```
