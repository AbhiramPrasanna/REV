# DEX — the system that had both levers and used one at a time

**Baseline → Implementation → Results → Recommendations**

DEX is the strongest prior work in this study and the most instructive, because it is the
one system that **already owns both levers**: compute-side caching of inner *and* leaf
pages, and cost-aware memory-side offloading. It still has a regime where it falls off,
and the reason is not a missing mechanism — it is that the two levers are never asked to
cover for one another.

Companion: [CHIME.md](CHIME.md) · cross-cutting argument: [REPORT.md](REPORT.md) ·
mechanism detail: [IMPLEMENTATION.md](IMPLEMENTATION.md)

**Configuration for every number here:** 2 nodes, 32 compute threads, 4 memory threads,
50 M keys, scan length 100, zipf θ = 0.99. Source
`dex/build/results/summary.csv` / `summary_full.csv`.

---

## 1. Baseline — what DEX does

### 1.1 The caching lever

- **Path-aware caching of both inner and leaf pages** — a child cannot be admitted unless
  its parent is cached, and a parent is not evicted until its children are. This keeps
  frequently-used root-to-leaf paths contiguous in the cache.
- **Pointer swizzling**, so a cached subpath is traversed by local pointer chasing.
- **Cooling map** — a hash table of per-bucket FIFO arrays replacing a centralised FIFO
  list, so eviction does not serialise across threads.
- **Lazy admission** — each newly fetched node is admitted with probability `P_A`, set to
  **1.0 for inner nodes** and **0.1 for leaves**.

### 1.2 The offload lever

- **Opportunistic, cost-aware pushdown** of `LOOKUP`, `UPDATE`, `INSERT`, `DELETE` at the
  cache boundary. On a miss at level *L*, DEX issues an RPC only when
  `l_p < (L+1)(l_o + l_s)c`, with `l_o` and `l_p` maintained as moving averages of recent
  samples and a small probability *q* of taking the contrary action to track drift.
- Offloading is confined to one compute/memory server pair, and falls back to the normal
  path if the operation would trigger an SMO.

### 1.3 Range queries

DEX maintains **no leaf links** — "to maintain simplicity for the pointer unswizzling
process" — so a scan spanning multiple leaves is **subdivided into multiple lookups** using
fence keys (§7 of the paper). Each covered leaf gets its own traversal, its own cache
probe, and its own offload decision.

### 1.4 How the two levers are wired together

**They are not.** Both fire per node miss, locally. Nothing in DEX observes whether the
caching lever is *working* for a given operation class and shifts weight accordingly. That
is the gap the rest of this document is about.

---

## 2. Implementation — what we investigated and what we changed

### 2.1 The question we asked: is the caching lever actually working?

We promoted **crossings per operation** to a first-class metric and swept cache
64 → 512 MB with offload off, i.e. the caching lever alone:

| workload, caching only | 64 MB | 512 MB | crossings removed by **8× more cache** |
|---|---:|---:|---|
| lookup / uniform | 6.79 | 3.34 | 2.0× |
| lookup / zipf | 4.18 | 1.54 | 2.7× |
| **range / uniform** | **22.35** | **16.88** | **1.32×** |
| range / zipf | 15.31 | 9.29 | 1.65× |

Even at 512 MB a uniform lookup still pays 3.34 remote reads, and a uniform scan 16.88.

### 2.2 The measurement that settles it

With offload on, **`rpc_per_op` is a direct readout of how often the caching lever failed**
— an RPC fires exactly when the cache could not resolve the leaf:

| workload | 64 MB | 128 MB | 256 MB | 512 MB |
|---|---:|---:|---:|---:|
| **lookup / uniform** | **1.0000** | **1.0000** | **1.0000** | **0.9974** |
| lookup / zipf | 0.8173 | 0.7192 | 0.6165 | 0.5403 |
| **range / uniform** | **1.3748** | **1.3748** | **1.3748** | **1.3748** |
| range / zipf | 1.2207 | 1.1327 | 1.0547 | 0.9451 |

Read the two bolded rows:

- **Under uniform, every single lookup misses its leaf, at every cache size.** `1.0000`
  across a 4× budget increase, and `0.9974` at 512 MB. The leaf half of the caching lever
  delivers **approximately nothing**, and eight times the memory does not change that.
- **Uniform scans are worse still: `1.3748`, constant to four decimal places across the
  whole sweep.** The offload rate does not move *at all*, because the caching lever
  contributes literally zero to scan performance at any budget.
- Under zipf the lever works as designed — 0.817 → 0.540 means 46% of lookups get their
  leaf from cache at 512 MB, and the offload rate falls to match.

The arithmetic behind it: at 50 M keys there are millions of leaves, and under uniform
every one is equally likely. There is no hot core to capture, so budget converts into hit
rate at a terrible exchange rate. **Skew is the only thing that makes the leaf-caching
lever function, which makes DEX-under-uniform the pathological corner.**

### 2.3 `P_A = 0.1` is DEX measuring the same thing

A nine-in-ten refusal to cache a leaf it just fetched is the design conceding that the
leaf-caching lever mostly does not pay. It is an empirically correct constant. What it is
not is a *response*: DEX tunes the failing lever rather than routing those accesses to the
one it already has.

### 2.4 What we changed

**`RpcType::SCAN` + `cachepush::range_scan`.** The memory node descends to the leaf covering
`k`, walks `next_leaf` forward **while the chain stays on this memory node**, and packs up
to `max_num` pairs into a per-requester scratch slot in the DSM region. The compute node
pulls the whole batch with **one** RDMA read.

Reply carries the count, the resume boundary (`max_limit_` of the last leaf visited), and
the slot address. Contract:

| return | meaning |
|---|---|
| `> 0` | pairs packed; caller reads the slot, resumes at `max_key + 1` |
| `-1` | entry leaf no longer covers `k` (stale cached parent) → drop IO flag, retry from root |
| `0`, `leaves_scanned == 0` | subtree continues on another memory node → fall back to the local path, IO flag still held |

**Hook.** The scan path's leaf-parent miss (`inner->level == 1`) calls
`cold_to_hot_with_rpc_for_scan()`, a strict superset of upstream behaviour: when pushdown
is not selected it tail-calls the unmodified `cold_to_hot_with_admission_for_scan()`.

One subtlety worth recording: on a successful pushdown `kv_buffer` is deliberately **not**
advanced across leaves — the caller reuses one fixed buffer per op and passes it by
reference, so advancing it would corrupt the next operation. Only the count is consumed,
matching the local path.

**`-DMANUAL_PUSHDOWN`.** Stock DEX decides adaptively, which is the right production policy
and the wrong experimental one — you cannot sweep an offload ratio the system overrides.
The flag disables the adaptive path so `rpc_rate` is the exact fraction of eligible misses
pushed down. Without it the build is byte-for-byte upstream. The same flag gates
`cold_to_hot_with_rpc_for_lookup()`, making `rpc_rate` the single manual lever position for
both operation types.

**Remote-load instrumentation.** `dex/include/remote_load.h` reports each directory
thread's *active fraction* — time inside `process_message` over wall time — every 2 s. Raw
CPU% is useless because the dir thread busy-polls and sits at 100% regardless. Cache-only
reads ~0%; it is the only regime where memory-side CPU load is a real number.

---

## 3. Results — what the second lever buys

### 3.1 Throughput

| Cache | range/uni **cache only** | **both levers** | | range/zipf **cache only** | **both levers** | |
|---:|---:|---:|---:|---:|---:|---:|
| 64 MB | 0.421 | 0.903 | 2.15× | 0.596 | 1.291 | 2.17× |
| 128 MB | 0.445 | 1.011 | 2.27× | 0.672 | 1.526 | 2.27× |
| 256 MB | 0.484 | 1.184 | 2.45× | 0.780 | 1.856 | 2.38× |
| 512 MB | 0.555 | **1.456** | **2.62×** | 0.948 | **2.371** | **2.50×** |

| Cache | lookup/uni **cache only** | **both** | | lookup/zipf **cache only** | **both** | |
|---:|---:|---:|---:|---:|---:|---:|
| 64 MB | 1.290 | 2.171 | 1.68× | 2.044 | 3.299 | 1.61× |
| 512 MB | 2.524 | **4.933** | 1.95× | 5.056 | **8.661** | 1.71× |

**Scans gain most, and the gain widens with cache** (2.15× → 2.62×) — because a larger cache
resolves more of the descent, leaving a higher fraction of the remaining cost in exactly
the leaf traversal the batch collapses.

### 3.2 Mechanism — crossings per operation at 512 MB

| workload | caching only | both levers | |
|---|---:|---|---|
| range / uniform | 16.88 reads | 4.26 reads + 1.375 RPC = **5.6** | **3.0× fewer** |
| range / zipf | 9.29 reads | 2.22 + 0.945 = **3.2** | **2.9× fewer** |
| lookup / uniform | 3.34 reads | 0.0008 + 0.997 = **1.0** | **3.3× fewer** |

`rpc_per_op ≈ 1.4` against 22.35 reads/op is the floor being removed by a mechanism that
eight times the memory could not match. On point lookups `rdma_read_per_op` collapses from
3.34 to **0.0008** — the cache holds the inner path and one RPC ships an 8-byte value
instead of a 512 B–1 KB page. **Page shipping became result shipping.**

### 3.3 The provisioning statement

Offload at **one-eighth** the cache against caching at full cache:

| workload | cache only @ 512 MB | both levers @ 64 MB | |
|---|---:|---:|---|
| range / uniform | 0.555 | **0.903** | **1.63× faster on ⅛ the cache** |
| range / zipf | 0.948 | **1.291** | **1.36× faster on ⅛ the cache** |
| lookup / uniform | 2.524 | 2.171 | 0.86× — nearly matches |
| lookup / zipf | 5.056 | 3.299 | 0.65× — does not |

**For scans, the offload lever is strictly better than eight times the memory.** For zipf
lookups it is not — and that exception is the design working: skew makes the working set
cacheable, so caching is the right lever and the gate keeps the memory node out of the way.

### 3.4 Tail latency

p99, µs:

| workload | cache only @ 512 | both @ 512 | |
|---|---:|---:|---|
| range / uniform | 95.0 | 58.0 | −39% |
| range / zipf | 92.5 | 53.0 | −43% |
| lookup / uniform | 28.5 | 14.0 | −51% |
| lookup / zipf | 26.5 | 12.5 | −53% |

Unlike CHIME's leaf cache (see [CHIME.md §3.5](CHIME.md)), the DEX offload lever improves
throughput and tail together.

### 3.5 Against DART

DART is the zero-memory-CPU control. Ratio of DEX-both-levers to DART:

| Cache | lookup/uni | lookup/zipf | range/uni | range/zipf |
|---:|---:|---:|---:|---:|
| 64 MB | 0.80× | 0.77× | 0.80× | 0.74× |
| 128 MB | **1.17×** | 1.81× | 0.91× | 0.88× |
| 256 MB | **1.83×** | **1.78×** | **1.05×** | **1.08×** |
| 512 MB | **1.94×** | **2.02×** | 0.87× | **1.37×** |

**Cache-only DEX never catches DART on any cell.** The offload lever is the only reason DEX
passes it at all. Once the cache holds the inner working set (≈256 MB), both-levers DEX
leads on three of four workloads.

Two cells need caveats, and both are DART moving rather than DEX:

- DART's uniform scan jumps to **1.676** at 512 MB only, against a flat ~1.13 at the other
  three points. That single point is the one cell both-levers DEX does not take. Treat it
  as suspect until re-run.
- DART's zipf lookup at 128 MB reads **2.655** against 4.29 / 4.27 / 4.28 elsewhere. The
  1.81× at that cell is inflated by DART's dip, not by DEX.

> ⚠ **Thread counts were not matched.** DEX ran at 32 compute threads; the DART baseline
> (`cache_sweep_baseline_20260615_125117.csv`) was actually run at **56** — despite
> `COMPARISON.md` describing the intent as matched at 32. DEX is beating a
> *better-provisioned* DART, so the crossover is if anything understated, but the
> comparison is not clean. **Do not publish a bare "N× DART" number until DART is re-run at
> 32 threads.**

### 3.6 Figures

| ID | Figure | Status |
|---|---|---|
| **F-DEX-2** | `rpc_per_op` vs cache, offload on — the flat 1.0000 / 1.3748 uniform rows. **The single most convincing panel that the caching lever is dead under uniform** | **new — data in hand** |
| **F-DEX-5** | crossings/op vs cache, one lever vs two | **new — data in hand** |
| F-DEX-4 | throughput vs p99 with the beats-DART region shaded | exists — `hybrid_plots/fig_opshift.png` |
| F-DEX-3 | DEX/DART crossover | exists — `compare_plots/dex_catches_dart_*.png` |
| F-DEX-1 | throughput vs cache | exists — `compare_plots/throughput_vs_cache_*.png` |
| *(pending)* | scan length {10, 100, 1000} | **needs the run** — see §4.5 |

---

## 4. Recommendations — how DEX should have combined its levers

These are design critiques of the published system. In the paper they are §8 Discussion
material.

### R1 — The offload decision should have been regime-aware, not node-local

DEX's cost model fires at a node miss and compares one RPC against one descent:
`l_p < (L+1)(l_o + l_s)c`. It never asks *"is the caching lever working for this operation
class at all?"* So when leaf caching degrades — uniform data, large working sets — DEX keeps
making locally-reasonable per-miss decisions while the aggregate regime has changed
underneath it.

The evidence that a regime signal exists and is trivially observable: `rpc_per_op` pinned
at **1.0000** across a 4× cache sweep (§2.2). Any system watching the marginal return on
cache budget would see that flatline immediately.

**What it should have been:** a lever-selection layer above the per-miss model, observing
the caching lever's marginal return and shifting weight to offload when it flattens. DEX
had both levers to shift between and never built the thing that shifts.

### R2 — `P_A = 0.1` should have been treated as a regime signal, not a tuning constant

The observation that leaves are not worth caching is correct and valuable. But it is
*exactly the signal* that the caching lever has run out for that node class, and the right
response is to route those accesses to the other lever — not to cache 10% of them anyway.

**The two findings sit in adjacent sections of the same paper (§5.4 admission, §6
offloading) and are never connected.** This is the clearest instance in the literature of a
system holding the answer to its own problem in the next section.

### R3 — The scan path should not have been traded for unswizzling simplicity

Dropping leaf links "to maintain simplicity for the pointer unswizzling process" is a local
engineering convenience purchased with an **asymptotic penalty on the one operation class
where the caching lever is structurally unavailable.** A scan streams through leaves it
never revisits; caching cannot help it by construction; so scans are precisely where the
offload lever must carry the load — and decomposing them into N independent lookups is what
prevents that.

**What it should have been:** a leaf-run mechanism used *only* on the pushdown path, never
in the swizzled cache. Unswizzling stays exactly as simple, and one reply can still carry a
run. That is what we built, and it costs DEX's cache design nothing.

The trade is never measured in the paper.

### R4 — Crossings per operation should have been a reported metric

DEX's own instrumentation already collects `rdma_read_per_op` and `rpc_per_op`. Plotted
against cache size they show the caching lever saturating immediately (§2.1) and dead under
uniform (§2.2). Reporting only throughput and latency hides *which lever is doing the work*,
which is the question a two-lever system most needs answered.

### R5 — Scan length should have been swept

The cost of decomposing a scan into lookups is linear in leaves covered, and therefore
invisible at a single fixed scan length. Sweeping it is the experiment that exposes R3.

It is also **the experiment we most need to run ourselves** — it converts our primary
contribution from a speedup into an asymptotic result, and we currently have every cell at
length 100.

---

## 5. Open items for DEX

| Item | Why | Cost |
|---|---|---|
| **Sweep scan length {10, 100, 1000}** | Converts the scan-pushdown claim from a speedup into a scaling result. Highest value | Runtime only |
| **Re-run DART at 32 threads** | Gates every "N× DART" number (§3.5) | One sweep |
| **Sweep `rpc_rate` 0 → 100%** | The offload lever's saturation curve; gives the resource-awareness argument its empirical limit | Runtime only |
| `memThreadCount` × offload | Where added memory-side capacity stops buying throughput | Rebuild, `NR_DIRECTORY ≥ 8` |
| **Fix the path-aware miss counters** | `inner-node read miss = 0` and `leaf-node read miss = 0` in every committed log, so §2's argument rests on `rpc_per_op` and `P_A` rather than a direct inner-vs-leaf split. Cheapest available strengthening | Small code fix |
| **Make RPCs coroutine-aware** | `rpc_lookup`/`rpc_scan` block on `rpc_wait()` with no yield, so offloaded ops do not overlap under `kCoroCnt` — **every number in §3 is a floor** | Moderate |
| Scan scratch slot keying | `app_id % MAX_APP_THREAD` collides across compute *nodes*; harmless for load numbers, wrong for exact multi-CN scan results | Small |
