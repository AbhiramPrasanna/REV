# DEX Skills Guide

A practical reference of the concepts and skills needed to understand, run, and
extend the DEX codebase and its microbenchmark suite. Pair this with
[microbenchmarks.md](microbenchmarks.md), which covers the benchmark mechanics
and metrics in depth.

> Focus: **DEX** (`tree_index = 0`). The Sherman and SMART wrappers in the tree
> are comparison baselines and are intentionally out of scope here.

---

## 1. Core concepts (the mental model)

### 1.1 Disaggregated memory
Compute nodes (CNs) have CPUs but no persistent data; memory nodes (MNs) hold the
B+-tree pages. CNs reach pages over **RDMA**:
- **one-sided READ** — pull a page into the CN cache without MN CPU involvement,
- **one-sided WRITE** — push a dirty/updated page back,
- **one-sided CAS** — remote lock (atomic compare-and-swap on a lock word),
- **RPC** — two-sided message that runs the operation on the MN CPU (pushdown).

`include/DSM.h` / `src/DSM.cpp` is the abstraction over all of this
(`read_sync`, `write_sync`, `cas_sync`, `rpc_lookup/update/insert/remove`).

### 1.2 Path-aware caching (the central idea)
DEX caches each leaf page **together with the inner nodes on the path** to it.
Inner nodes are small and cover wide key ranges, so they stay resident and a hot
lookup walks the cached path entirely in local memory — **zero RDMA**. Misses
occur at the bottom of the path, so **leaf misses dominate** and **inner misses
are rare**. Consequences you will see in the metrics:
- a high LOCAL (cache-hit) fraction of operations,
- inner-miss count ≪ leaf-miss count,
- REMOTE latency ≈ RDMA round trip; LOCAL latency ≈ in-memory B+-tree search.

Code: `include/cache/leanstore_cache.h` (`CacheManager`), tree walk in
`include/tree/leanstore_tree.h` (`lookup`, `insert`, `new_get_mem_node`).

### 1.3 Pointer swizzling
A child pointer is either a **GlobalAddress** (remote) or, if the page is cached,
a tagged in-memory pointer (`swizzle_tag` / `swizzle_hide`). `search_in_cache`,
`get_memory_address`, and `new_swizzling` convert between the two. Swizzling is
what makes a cached path walk pointer-chase-fast.

### 1.4 Optimistic lock coupling + shared/private nodes
Reads use version-based optimistic locks (`readLockOrRestart` / `checkOrRestart`)
and restart on conflict — no reader latches. Writes upgrade to write locks.
Nodes fully inside one CN's key range are **private** (local locking only); nodes
above the per-CN subtree are **shared** and additionally take a **remote** lock +
version check (`full_lock_with_check`, `check_global_conflict`). Sharding is set
up in `generate_index()` / `set_shared()` (`test/newbench.cpp`,
`leanstore_tree.h`).

### 1.5 Caching vs RPC pushdown, and admission control
On a miss DEX decides between **caching** the page (`cold_to_hot`) and **RPC
pushdown** (`cold_to_hot_with_rpc` → `dsm->rpc_*`). `rpc_rate` biases this; the
`LatencyCollector` (`include/cache/latency_collector.h`) can adaptively compare
pushdown vs caching latency. **Admission control** (`admission_rate`,
`cold_to_hot_with_admission`) decides whether a fetched leaf is worth keeping in
the cache. These two knobs are what `auto_tune` sweeps.

---

## 2. Code map (where things live)

| Area | Files |
|------|-------|
| Benchmark driver | `test/newbench.cpp` |
| Workload gen | `test/zipf.h`, `test/uniform.h`, `test/uniform_generator.h` |
| Tree (DEX) | `include/tree/leanstore_tree.h`, `include/tree/*.h` |
| Path-aware cache | `include/cache/leanstore_cache.h`, `include/cache/latency_collector.h` |
| RDMA / DSM layer | `include/DSM.h`, `src/DSM.cpp`, `include/Rdma.h`, `src/rdma/` |
| Common constants | `include/Common.h` (`MAX_APP_THREAD`, page sizes, `define::*`) |
| Coordination (memcached) | `include/Keeper.h`, `include/DSMKeeper.h`, `src/*Keeper.cpp` |
| **Instrumentation (new)** | `include/bench_stats.h` |
| Tree interface | `include/tree_api.h` |
| Scripts | `script/run.sh`, `script/run_other.sh`, `script/correlation.sh`, `script/restartMemc.sh`, `script/hugepage.sh` |
| Build | `CMakeLists.txt` |

Key compile switches:
- `COUNT_RDMA` (`include/DSM.h`, **on**) — per-thread RDMA counters; required for
  the LOCAL/REMOTE split.
- `COUNT_TIME` (`include/DSM.h`, off) — accumulate RDMA wait time.
- `BENCH_LATENCY` (`include/bench_stats.h`, **on**) — 500 ns buckets + remote-op
  tracking.
- `GLOBAL_WORKLOAD` (`test/newbench.cpp`, on) — global vs per-partition key draw.

---

## 3. Operational skills

### 3.1 Build
```bash
./script/hugepage.sh
mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=Release .. && make -j
cp ../script/{restartMemc.sh,run*.sh} .
```
Requires Linux + MLNX_OFED + ibverbs + memcached + cityhash + boost + tbb + numa.
There is **no Windows/macOS build**.

### 3.2 Run a cluster
1. Put memcached IP/port in `memcached.conf` (line 1 IP, line 2 port) on all nodes.
2. On one server: `./run.sh`. On the others: `./run_other.sh`.
3. `./restartMemc.sh` between runs to clear stale QP info.

See [microbenchmarks.md §3.1](microbenchmarks.md) for the full 22-argument CLI and
[§7](microbenchmarks.md) for ready-made command recipes.

### 3.3 Read the output
- **Throughput**: live cluster ticks every 2 s; final "All-CN throughput (Max)"
  and "(Straggler)".
- **500 ns latency buckets**: per-op and ALL-ops percentiles split LOCAL/REMOTE,
  plus the raw bucket CDF.
- **Remote operations**: local vs remote op fraction; read/write/CAS/RPC
  breakdown; remote-ops-per-op.
- **Path-aware misses**: inner vs leaf read-miss split.
- **Legacy global RDMA averages** at the end for cross-checking.

---

## 4. Extension skills (how to modify safely)

### 4.1 Add a new metric to the report
1. Add a counter to `bench::ThreadStats` in `include/bench_stats.h` (keep the
   struct cache-line aligned; clear it in `clear()`).
2. Update it on the hot path in `thread_run` (`test/newbench.cpp`) under
   `#ifdef BENCH_LATENCY`.
3. Aggregate + print it in `bench::Reporter::print`.
4. It is cleared automatically at the warmup→measure boundary via
   `bench::clear_all()`.

### 4.2 Change latency bucket resolution / range
Edit `kBucketWidthNs` (granularity) and `kNumBuckets` (range) in
`include/bench_stats.h`. Tracked range = `kBucketWidthNs * (kNumBuckets-1)`;
anything larger lands in the overflow bucket. Memory cost is
`MAX_APP_THREAD * OP_COUNT * 2 * kNumBuckets * 8 B`.

### 4.3 Surface a new cache statistic (path-aware)
Counters live in `CacheManager` (`include/cache/leanstore_cache.h`). Expose them
via a virtual in `include/tree_api.h` (default `return 0;`), override in
`BTree` (`include/tree/leanstore_tree.h`), reset them in
`BTree::clear_statistic()`, then read them in the report. This is exactly how
`get_inner_miss / get_leaf_miss / get_cache_writeback` were added.

### 4.4 Add a new operation type
1. Extend `op_type` in `test/newbench.cpp` and the dispatch switches (warmup +
   measured).
2. Add a matching `tree_api` method.
3. Add a `bench::LatOp` enum value + name in `include/bench_stats.h` and set
   `lat_op` in the new switch case.

### 4.5 Attribute remote ops correctly
The LOCAL/REMOTE split is a **delta of `dsm->num_rdma_{read,write,cas,rpc}`**
around each op. If you add a new remote primitive to `DSM`, increment a
`COUNT_RDMA` counter inside it so it shows up in the attribution automatically.

---

## 5. Gotchas

- **Warmup pollutes stats** unless reset. Resets happen once, by thread 0, at the
  warmup→measure boundary (`clear_rdma_statistic`, `clear_statistic`,
  `bench::clear_all`). Put any new reset there.
- **Per-thread indexing**: DSM RDMA counters are indexed by
  `dsm->getMyThreadID()` (the registered id); `bench::g_stats` is indexed by the
  worker's local `id`. Don't mix them.
- **`early_stop`** truncates slow threads' work; lifetime per-thread throughput is
  still valid, but a thread that stops early contributes fewer latency samples.
- **Ratios must sum to 100** (asserted in `parse_args`).
- **Overhead**: instrumentation adds two clock reads + four counter reads per op.
  For an absolute-peak throughput number, comment out `#define BENCH_LATENCY 1`.
- **`COUNT_RDMA` off** ⇒ every op is reported LOCAL (the delta is always 0).
