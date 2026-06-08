# DEX Microbenchmarks

This document explains the DEX microbenchmark suite end to end: what DEX is, how
the benchmark driver is built and configured, how workloads are generated and
executed, and how to read every number the harness prints — including the new
**500 ns latency buckets**, **remote-operation tracking**, and **path-aware
cache-miss breakdown**.

> Scope: this document describes the **DEX** index only (`tree_index = 0`). The
> repository also contains Sherman (`1`) and SMART (`2`) wrappers for comparison,
> but they are out of scope here and the new instrumentation is meaningful only
> for DEX.

---

## 1. What DEX is (and why the metrics are shaped this way)

DEX is a distributed B+-tree on **disaggregated memory**: compute nodes (CNs)
hold no persistent data, memory nodes (MNs) hold the tree pages, and CNs reach
pages over **RDMA** (one-sided read/write/CAS) plus an **RPC pushdown** path.

The thing that makes DEX fast is its **path-aware buffer cache**:

- The CN caches **leaf pages together with the inner nodes on the path** down to
  them. Inner nodes are tiny and shared by huge key ranges, so they stay
  resident; a hot lookup walks the cached inner path and finds the leaf locally,
  issuing **zero remote operations**.
- A miss happens at the bottom of the path. Because inner nodes are almost always
  cached, **leaf misses dominate** remote read traffic and **inner misses are
  rare** — the instrumentation makes this split explicit.
- On a miss DEX chooses between **caching** (one-sided read the page into the CN
  cache, "cold→hot") and **RPC pushdown** (ship the operation to the MN). This is
  governed by `rpc_rate` and `admission_rate`.

This is exactly why the benchmark reports latency split into **LOCAL (cache hit,
no network)** vs **REMOTE (≥1 network op)**, and why it tracks remote ops broken
down into read / write / CAS / RPC and into inner vs leaf misses.

---

## 2. Building

Dependencies (from the README): Linux ≥ 6.x, GCC 13, Mellanox ConnectX-5 NICs,
MLNX_OFED, `memcached` (used to exchange RDMA queue-pair info and to act as a
cross-node barrier/reduction), and `cityhash`.

```bash
git clone https://github.com/baotonglu/dex.git
cd dex
./script/hugepage.sh            # reserve hugepages (RDMA buffers)
mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=Release ..
make -j
cp ../script/restartMemc.sh .
cp ../script/run*.sh .
```

`CMakeLists.txt` globs every `*.cpp` in `src/` into a static lib `DEX`, then
builds one executable per file in `test/`. The benchmark binary is **`newbench`**
(from `test/newbench.cpp`). Link flags: cityhash, boost (system + coroutine),
pthread, ibverbs, memcached, tbb, numa.

Build is `-O3 -march=native`. There is no Windows build — RDMA/ibverbs/numa are
Linux only.

---

## 3. The benchmark driver: `test/newbench.cpp`

### 3.1 Command line (22 positional args; `argc` must be 23)

```
./newbench \
  kNodeCount kReadRatio kInsertRatio kUpdateRatio kDeleteRatio kRangeRatio \
  totalThreadCount memThreadCount cacheSizeMB uniform_workload zipfian_theta \
  bulkLoadM warmupM opM check_correctness time_based early_stop \
  index rpc_rate admission_rate auto_tune kMaxThread
```

| # | Arg | Meaning |
|---|-----|---------|
| 1 | `kNodeCount` | total machines participating (CN + MN roles) |
| 2 | `kReadRatio` | % point lookups |
| 3 | `kInsertRatio` | % inserts |
| 4 | `kUpdateRatio` | % updates |
| 5 | `kDeleteRatio` | % deletes |
| 6 | `kRangeRatio` | % range scans (`scan_num = 100` keys) |
| 7 | `totalThreadCount` | worker threads across **all** compute nodes |
| 8 | `memThreadCount` | directory (memory-side) threads per node |
| 9 | `cacheSizeMB` | CN buffer-cache size in MB |
| 10 | `uniform_workload` | `1` = uniform keys, `0` = Zipfian |
| 11 | `zipfian_theta` | skew (e.g. `0.99`); ignored if uniform |
| 12 | `bulkLoadM` | keys to bulk-load, in **millions** |
| 13 | `warmupM` | warmup ops, in **millions** |
| 14 | `opM` | measured ops, in **millions** |
| 15 | `check_correctness` | `1` validates the tree after the run |
| 16 | `time_based` | `1` caps phases by wall-clock instead of op count |
| 17 | `early_stop` | `1` = first thread to finish stops the others (kills straggler bias) |
| 18 | `index` | `0`=DEX, `1`=Sherman, `2`=SMART |
| 19 | `rpc_rate` | DEX pushdown ratio (0..0.99) |
| 20 | `admission_rate` | DEX cache admission ratio for leaf fills |
| 21 | `auto_tune` | `1` = sweep `admission_rate × rpc_rate` grids automatically |
| 22 | `kMaxThread` | worker threads per compute node (sharding granularity) |

The read+insert+update+delete+range ratios must sum to **100** (asserted).

`CNodeCount = ceil(totalThreadCount / kMaxThread)` — i.e. the number of compute
nodes is derived from how many worker threads you asked for vs the per-node cap.

The total key space is computed so inserts never run out of fresh keys:
`kKeySpace = bulkLoadM*1e6 + ceil((opM+warmupM)*1e6 * insertRatio/100) + 1000`.

### 3.2 Operation encoding

Each generated 64-bit work item packs the **op type in the top 8 bits** and the
key in the low 56 bits (`op_mask = (1<<56)-1`). The worker decodes
`op = key >> 56`, masks the key, and dispatches to
`lookup / insert / update / remove / range_scan`. Op enum order in code is
`{Insert, Update, Lookup, Delete, Range}`.

### 3.3 Key generation & skew

- Keys pass through `to_key(x) = (CityHash64(x)+1) % kKeySpace` to scatter them.
- Zipfian via `mehcached_zipf_*` (`test/zipf.h`); uniform via
  `uniform_key_generator_t` (`test/uniform.h`).
- `GLOBAL_WORKLOAD` (default on) means every CN draws from the **whole** key
  space and rejects keys outside its shard; with it off, each CN draws from its
  partition directly.

### 3.4 Sharding / partitioning (DEX)

DEX is range-partitioned across compute nodes. `generate_index()` builds a
`sharding` vector of range bounds, one contiguous range per CN
(`threadKSpace * kMaxThread` wide). Bulk-load is split proportionally per shard;
each CN inserts/operates within `[left_bound, right_bound)`. `set_shared()` marks
the inner nodes above the per-CN subtree as **shared** (globally synchronized);
nodes fully inside a CN's range become **private** (no global locking) — this is
the mechanism behind DEX's low coordination cost.

### 3.5 Execution phases (`thread_run`)

1. **Bind & register.** Each worker pins to a core (`bindCore`) and registers an
   RDMA thread context.
2. **Warmup.** Run `warmupM/totalThreadCount` ops per thread (untimed). Purpose:
   populate the path-aware cache. Bounded by 30 s when `time_based`.
3. **Reset point (thread 0 only).** When all threads finish warmup, thread 0:
   sets the real `rpc_rate`, calls `dsm->clear_rdma_statistic()`,
   `tree->clear_statistic()` (resets inner/leaf miss counters), and
   `bench::clear_all()` (resets the 500 ns histograms), then crosses a memcached
   barrier and flips `ready`. **This is the boundary that excludes warmup traffic
   from the measured numbers.**
4. **Measured loop.** Each thread runs its workload slice, timing every op and
   attributing its remote work (see §4). `tp[id][0]` counts ops for the live
   throughput sampler.
5. **Early stop.** With `early_stop`, the first thread to finish sets
   `thread_op_num = 0` so the rest exit promptly, so reported throughput reflects
   steady state rather than the slowest straggler.

### 3.6 Throughput collection (main thread)

While workers run, the main thread samples every 2 s: it sums `tp[i][0]`,
computes per-node ops/µs for the interval, and reduces across CNs using a
memcached-backed prefix-sum (`dsm->sum_with_prefix`). It prints per-node and
cluster throughput each tick. End-of-run it reports:

- **All-CN throughput (Max)** = sum of each thread's lifetime throughput.
- **All-CN throughput (Straggler)** = min per-thread throughput × total threads
  (a fairness-aware number; this is the headline "Final throughput").

### 3.7 Auto-tune mode

With `auto_tune=1`, the run loop sweeps `admission_rate_vec × rpc_rate_vec`
(defaults: admission ∈ {1,0.8,0.4,0.2,0.1,0.05,0.01,0}, rpc ∈ {1}) and prints the
throughput-maximizing `(admission_rate, rpc_rate)` for both the Max and Straggler
metrics.

---

## 4. Instrumentation added by this work

All of the following live in **`include/bench_stats.h`** (header-only) and are
wired into `test/newbench.cpp`. Everything compiles away when `BENCH_LATENCY`
is undefined (it is defined by default at the top of `bench_stats.h`).

### 4.1 500 ns latency buckets

Every measured op is timed with `std::chrono::high_resolution_clock` and dropped
into a histogram whose buckets are **exactly 500 ns wide**:

- `kBucketWidthNs = 500`, `kNumBuckets = 2000` → tracked range `[0, 1 ms)`, with
  the final bucket acting as a `>= 1 ms` overflow bucket.
- Buckets are kept **per (thread, op-type, class)** in a cache-line-aligned
  `ThreadStats` block, so the hot path is lock-free and false-sharing-free.
- `op-type ∈ {LOOKUP, INSERT, UPDATE, DELETE, RANGE}`.
- `class ∈ {LOCAL, REMOTE}` — see §4.2.

At report time (`bench::Reporter::print`, once per run per node) the per-thread
histograms are merged and the suite prints, for each op type and for ALL ops:

- count, mean, **p50, p90, p99, p99.9, max** — separately for ALL / LOCAL /
  REMOTE.
- the **raw 500 ns bucket CDF** for all ops (`[lo,hi) ns | count | pct | cdf`),
  printing only non-empty buckets. This is the literal "latency buckets at
  500 ns" artifact.

### 4.2 Remote-operation tracking

DEX already maintains per-thread RDMA counters in `DSM`
(`num_rdma_read/write/cas/rpc`, gated by `COUNT_RDMA`, which is on by default).
The benchmark **snapshots these counters around each op** and takes the delta:

```
before op:  r0,w0,c0,p0 = dsm->num_rdma_{read,write,cas,rpc}[tid][0]
run op
after op:   delta = (current - before) for each counter
```

- If the total delta is `0`, the op was a pure **LOCAL** cache hit (served from
  the cached path with no network). Otherwise it is **REMOTE**.
- The per-op deltas accumulate into per-thread totals: `remote_read`,
  `remote_write`, `remote_cas`, `remote_rpc`.

The report prints, per node:

- ops total / ops local (%) / ops remote (%) — i.e. the **cache hit rate** seen
  by actual operations.
- remote ops total and the **read / write / CAS / RPC breakdown**.
- **remote ops per op** and **remote ops per remote op** (network amplification).

### 4.3 Path-aware cache-miss breakdown

From the DEX cache (`CacheManager.inner_miss_`, `leaf_miss_`, `rdma_write`),
exposed through new `tree_api` virtuals
(`get_inner_miss / get_leaf_miss / get_cache_writeback`), the report prints:

- **inner-node read miss** (count and % of total read misses),
- **leaf-node read miss** (count and %),
- total read miss, and cache writebacks.

Because DEX caches the inner path, you should expect inner misses to be a small
fraction and leaf misses to dominate — this line is the direct evidence that the
path-aware caching is working.

### 4.4 Where it hooks in (summary of edits)

| File | Change |
|------|--------|
| `include/bench_stats.h` | **new** — histogram, remote-op tracker, reporter |
| `include/tree_api.h` | virtual `get_inner_miss / get_leaf_miss / get_cache_writeback` |
| `include/tree/leanstore_tree.h` | `clear_statistic()` now resets miss counters; added `get_cache_writeback()` |
| `test/newbench.cpp` | define `bench::g_stats`; clear at warmup boundary; time + attribute each measured op; print per-run report |

No build-system changes are required — `bench_stats.h` is header-only and pulled
in by `newbench.cpp`.

### 4.5 Overhead & caveats

- Two `clock_gettime`-class reads and four counter reads per op. Negligible vs an
  RDMA round trip, but it is real CPU work; for the absolute-peak throughput
  number you can disable it by commenting out `#define BENCH_LATENCY 1`.
- Timing covers the full operation including any RDMA wait, so REMOTE latencies
  reflect end-to-end network cost.
- The LOCAL/REMOTE split requires `COUNT_RDMA` (default on). If it is off, every
  op is reported LOCAL.
- Latencies above 1 ms collapse into the overflow bucket; widen `kNumBuckets` if
  you need finer tail resolution.

---

## 5. Driver scripts

### 5.1 `script/run.sh`

A single-config launcher. It defines op-mix presets as parallel arrays indexed by
`op` and a thread schedule, then calls `newbench`. Presets (`read/insert/update/
delete/range`):

| index | mix |
|-------|-----|
| 0 | 100% read |
| 1 | 50% read / 50% update |
| 2 | 95% read / 5% update |
| 3 | 100% insert |
| 4 | 5% insert / 95% range |

Defaults in the script: `nodenum=2`, `mem_threads=4`, `cache=256MB`, `bulk=50M`,
`warmup=10M`, `op=50M`, `zipf=0.99`, `rpc=1`, `admit=0.1`, `kMaxThread=36`. The
`for` loops are stubbed to a single point (`uni=0, op=0, idx=0, t=1`); widen them
to sweep. On every server: run `./run.sh` on one, `./run_other.sh` on the rest.

### 5.2 `script/correlation.sh`

A parameter-sweep harness over skew, cache size, thread count, memory threads,
pushdown rate (`push`), and admission rate, writing one results file per
configuration. Useful for producing the admission-rate / pushdown-rate
sensitivity curves.

### 5.3 Cluster setup

`memcached.conf` (line 1 = memcached IP, line 2 = port) tells every node where the
coordination memcached lives. `restartMemc.sh` clears it between runs.
`hugepage.sh` / `clear_hugepage.sh` manage the hugepages backing RDMA buffers.

---

## 6. Reading a run (example)

```
... live ticks ...
2, throughput 4.1234
cluster throughput 8.9012

==================== LATENCY BUCKETS (500 ns) [node 0] ====================
[LOOKUP]
  ALL                n=49981234  mean=   1.83us  p50=   1.00us  p90=   2.50us  p99=   7.50us  p99.9=  18.00us  max>= 64.00us
  LOCAL (cache hit)  n=46120000  mean=   0.62us  p50=   0.50us  p90=   1.00us  p99=   1.50us  p99.9=   3.00us  max>= 12.00us
  REMOTE (miss/rpc)  n= 3861234  mean=  11.40us  p50=   9.50us  p90=  16.00us  p99=  28.00us  p99.9=  41.00us  max>= 64.00us
[ALL OPS]
  ALL                n=49981234  ...

----- 500 ns bucket CDF (all ops) [node 0] -----
  bucket [lo,hi) ns          count        pct       cdf
  [        0,      500)    9120000   18.2467%  18.2467%
  [      500,     1000)   27310000   54.6...%  72.8...%
  ...

----- REMOTE OPERATIONS [node 0] -----
  ops total                = 49981234
  ops local  (cache hit)   = 46120000 (92.27%)
  ops remote (>=1 net op)  = 3861234 (7.73%)
  remote ops total         = 4203998
  ...
  remote ops / op          = 0.0841

----- PATH-AWARE CACHE MISSES [node 0] -----
  inner-node read miss     = 41233 (1.07%)
  leaf-node  read miss     = 3820765 (98.93%)
  ...
```

How to read it:

- **LOCAL p50 ≈ 0.5 µs** is the cached-path cost; **REMOTE p50 ≈ 9.5 µs** is the
  RDMA round-trip cost. The ALL-ops tail is driven entirely by the REMOTE class.
- **92% local** ops + **inner misses ≈ 1%** of misses confirms the path-aware
  cache is keeping the inner nodes hot and only paying network cost on leaves.
- **remote ops / op = 0.084** ≈ the remote fraction (7.7%) because most remote
  ops are a single leaf read; values >1 indicate write/CAS amplification (SMO,
  locking) under write-heavy mixes.

At the very end the harness also prints the legacy global RDMA averages
(`Avg. rdma read/write/cas/rpc per op`, sizes, times) for cross-checking against
the per-op attribution above.

---

## 7. Quick recipes

```bash
# 100% lookup, Zipf 0.99, 256MB cache, DEX, full pushdown, 2 nodes, 36 thr/node
./newbench 2 100 0 0 0 0 36 4 256 0 0.99 50 10 50 0 1 1 0 1 0.1 0 36

# Read/update 50-50 to exercise writes, CAS, and RPC pushdown attribution
./newbench 2 0 0 50 50 0 36 4 256 0 0.99 50 10 50 0 1 1 0 1 0.1 0 36
#                 ^read=0 ^insert=0 ^update=50 ^delete=50

# Range-scan heavy
./newbench 2 5 5 0 0 90 36 4 256 0 0.99 50 10 50 0 1 1 0 1 0.1 0 36

# Auto-tune admission × pushdown
./newbench 2 100 0 0 0 0 36 4 256 0 0.99 50 10 50 0 1 1 0 1 0.1 1 36
```
