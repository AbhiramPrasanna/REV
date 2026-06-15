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

---

## 6. Offloading (pushdown) for lookups & range scans

This section documents the offloading subsystem end to end: what it is, how a
task is shipped to the memory node, how lookups and range scans differ, how the
tasks are tracked, and how to reason about the results under uniform vs Zipfian
workloads.

### 6.1 What "offloading" is

DEX has two ways to serve an operation that misses the path-aware cache at the
bottom of the tree (a leaf, or a small subtree near the leaves):

1. **Caching (one-sided RDMA).** Pull the leaf page into the CN cache with a
   one-sided RDMA **READ**, then run the operation on the CPU of the **compute
   node**. The MN CPU is never involved. Future hits on that leaf are local.
2. **Offloading (RPC pushdown).** Send a small two-sided **RPC** to the **memory
   node**; the MN CPU runs the operation directly on its own copy of the page(s)
   and ships back only the *result*. The page is never cached on the CN.

Offloading wins when caching would be wasteful: cold/one-shot keys (you'd evict
the page before reusing it), and when the result is far smaller than the page(s)
touched. It costs MN CPU and adds it to the critical path.

The decision lives in `include/cache/leanstore_cache.h`:

- **Adaptive (default build).** `LATENCY_COLLECT` is on; `decision.caching_or_push()`
  (a `LatencyCollector`) measures recent caching-latency vs pushdown-latency and
  picks the cheaper one per op. The manual `rpc_rate` knob is **ignored**. In this
  build behavior is exactly upstream DEX: lookups offload only on subtree-internal
  inner misses (levels 2..`megaLevel`), the leaf-parent miss uses admission
  control, and scans use admission control (one-sided read). The scan-RPC and the
  manual leaf-parent lookup-RPC added by this work are **compiled out**.
- **Manual (`-DMANUAL_PUSHDOWN`).** `LATENCY_COLLECT` is off; offloading is a
  per-op coin flip with probability `rpc_rate` (the `RPC` variable in
  `run.sh`/`run_other.sh`, parsed by `newbench` as a **double**, passed straight
  to `CacheManager`). This is the build for the offloading study — a clean knob:
  `rpc_rate=0` ⇒ pure caching, `rpc_rate=0.3` ⇒ ~30% of eligible ops offloaded,
  `rpc_rate=1` ⇒ offload every eligible op.

> **Controlling the knob (this is the fix).** Previously the `RPC` parameter did
> not give manual control of *lookups*: (a) the default build ignores it
> (adaptive), and (b) even with `-DMANUAL_PUSHDOWN` it only affected the rare
> level 2..`megaLevel` inner-miss path — the **dominant** leaf-parent lookup miss
> went through admission control, which is governed by `ADMIT`, not `RPC`, so
> lookups looked "always on / not manual". Two changes make `RPC` the real
> lookup knob:
>   1. The leaf-parent lookup miss now first consults the `rpc_rate` coin
>      (`cold_to_hot_with_rpc_for_lookup`): with probability `rpc_rate` it does a
>      true `rpc_lookup` pushdown; the remaining `1-rpc_rate` fall through to the
>      original admission policy (which then caches a fraction `ADMIT` of those
>      and one-sided-reads the rest). Scans use the identical gate
>      (`cold_to_hot_with_rpc_for_scan`).
>   2. The `rpc_rate_` clamp was relaxed from `[0,0.99]` to `[0,1]`, so `RPC=1`
>      really means 100%.
>
> Both new gates are wrapped in `#ifdef MANUAL_PUSHDOWN`, so the **default build
> is unchanged**. Net effect in the manual build: `RPC` linearly controls the
> offloaded fraction of *both* lookups and range scans; `ADMIT` then controls how
> much of the *non-offloaded* remainder gets cached vs streamed.

### 6.1.1 Worked example: how many ops get offloaded

With `READ=100`, `RPC=0.3`, `ADMIT=0.1`, a measured window of `N` lookups, and a
steady-state leaf-miss probability `m` (misses that reach the leaf parent; hot
keys that hit the cached path never get here):

```
offloaded lookups   ≈ N · m · RPC               (true MN pushdown, rpc_lookup)
of the rest (1-RPC):
  cached leaves     ≈ N · m · (1-RPC) · ADMIT    (one-sided read, then resident)
  streamed leaves   ≈ N · m · (1-RPC) · (1-ADMIT)(one-sided read, not cached)
local cache hits    ≈ N · (1-m)                  (zero RDMA, fastest)
```

The report's `OFFLOADED TASKS` block prints the measured `N·m·RPC` term
(`lookup pushdowns`) and the per-thread split; cross-check it against
`RPC × (leaf-node read miss share)` from the `PATH-AWARE CACHE MISSES` /
`REMOTE OPERATIONS` blocks.

### 6.2 How a lookup is offloaded

There are two lookup miss sites, and `rpc_rate` gates both in the manual build:

- **Leaf-parent miss** (`inner->level == 1`, the common case) →
  `cold_to_hot_with_rpc_for_lookup` (added by this work). With probability
  `rpc_rate` it pushes; otherwise it falls back to admission control.
- **Subtree-internal inner miss** (`level` 2..`megaLevel`, rare because inner
  nodes are path-cached) → `cold_to_hot_with_rpc` (pre-existing). Gated by
  `rpc_rate` in the manual build, by the adaptive `decision` otherwise. Here the
  MN walks several inner levels before reaching the leaf.

Both end in the same RPC round-trip:

```
CN  leanstore_tree.h::lookup()                   miss (leaf-parent or inner)
  └ cold_to_hot_with_rpc_for_lookup / cold_to_hot_with_rpc   coin: rpc_rate
      └ DSM::rpc_lookup(node_ga, k, &result)     RawMessage{LOOKUP,k,addr}
          └ RDMA SEND to MN directory thread, then block on rpc_wait
          └ num_push_lookup[tid]++               (offload-task tracking)
MN  Directory::process_message()  case LOOKUP
      └ cachepush::lookup(addr, dsmBase, k, v, g)  walk to leaf -> value (or -1)
      └ reply RawMessage{level=ret, addr=value}
CN  value returned; IO flag dropped. ret<=0 (stale) -> drop flag, retry.
```

The whole point: the leaf page (1 KB) never crosses the wire — only the 8-byte
value does, inside a 96-byte `RawMessage`. The non-pushed remainder goes to
admission control: a fraction `ADMIT` is cached (one-sided read, then resident
for future hits), the rest is read-and-discarded.

### 6.3 How a range scan is offloaded (added by this work)

A scan returns up to `scan_num` (default **100**) KV pairs = ~1600 B, which does
**not** fit in a 96-byte `RawMessage` reply. So the scan RPC uses a
**scratch-buffer + one-RDMA-read** transport, and the MN walks **multiple
sibling leaves per RPC** — that cross-leaf traversal on the MN is the offload
win (one RPC + one read instead of one page read per leaf).

Control is the same manual gate as lookups: `cold_to_hot_with_rpc_for_scan`
pushes only under `-DMANUAL_PUSHDOWN` and only when the `rpc_rate` coin says so;
otherwise (and always in the default build) it falls back to
`cold_to_hot_with_admission_for_scan` — the original one-sided-read scan.

```
CN  leanstore_tree.h::range_scan()        miss at leaf-parent (inner->level==1)
  └ leanstore_cache.h::cold_to_hot_with_rpc_for_scan(...)   coin: rpc_rate
      └ DSM::rpc_scan(leaf_ga, k, num, &slot, &max_key, &leaves)
          └ RawMessage{SCAN, k=startkey, v=num, addr=leaf_ga}  -> MN, block
MN  Directory::process_message()  case SCAN
      └ cachepush::range_scan(leaf_ga, dsmBase, k, want, out, max_key, leaves)
          • walk to covering leaf
          • scan entries >= k into `out`, then follow next_leaf siblings that
            live on THIS MN until `want` reached or range/boundary hit
          • `out` = this requester's private slot in the per-directory scratch
            chunk (slot index = m->app_id)
      └ reply RawMessage{level=count, addr=slot_ga, k=max_key, v=leaves}
CN  cold_to_hot_with_rpc_for_scan:
      • ONE raw_remote_read(slot_ga, count*16) pulls the whole batch
      • memcpy into the caller's kv_buffer
      • returns count; tree loop continues from max_key+1 if more is needed
```

Key design points:

- **Scratch region.** Each `Directory` reserves one 32 MB chunk
  (`scanScratch`) at construction (`src/Directory.cpp`). It is split into
  `MAX_APP_THREAD` slots of `kScanSlotBytes = 4096` (256 KV pairs each).
- **Race-free slots.** A slot is indexed by the requesting app-thread id. A
  worker has at most one outstanding RPC (it blocks in `rpc_wait`), and no two
  workers share a slot, so a result is never overwritten before it is read.
  The reply carries the exact slot `GlobalAddress`, so even with `dir_id`
  rotation across directories the CN always reads the right scratch.
- **Multi-leaf, capped.** The MN packs up to `min(num, 256)` pairs across
  siblings; if `num` exceeds that or siblings live on another MN, the CN's
  existing `range_scan` loop resumes from `max_key+1` and issues another RPC.
- **Fallback.** If pushdown is not chosen, or the MN cannot serve the leaf
  (subtree on a different MN, `count==0 && leaves==0`), it falls back to
  `cold_to_hot_with_admission_for_scan` (one-sided read + local scan) — the
  pre-existing behavior — so progress is always guaranteed.
- **`kv_buffer` is not advanced across leaves.** The benchmark reuses one fixed
  buffer per op and passes it by reference; only the returned *count* is
  consumed. Advancing it would corrupt the next op. (This matches the original
  local scan path.)

Stale handling: if the entry leaf no longer covers `k` (`rangeValid` fails on
the MN), the RPC returns `-1`; the CN drops the IO flag and retries from the
root via `new_refresh_from_root`.

### 6.4 Tracking offloaded tasks

Two layers, mirroring the existing RDMA instrumentation:

- **Per-thread DSM counters** (`include/DSM.h`, under `COUNT_RDMA`), incremented
  inside the RPC calls themselves:
  `num_push_lookup`, `num_push_scan`, `num_push_scan_kv`, `num_push_scan_leaf`.
  Reset in `clear_rdma_statistic` at the warmup→measure boundary; aggregate
  getters: `get_push_lookup_num()` etc.
- **Per-worker bench stats** (`include/bench_stats.h` `ThreadStats`):
  `off_lookup`, `off_scan`, `off_scan_kv`, `off_scan_leaf`. Filled in
  `test/newbench.cpp` by snapshotting the DSM counter deltas around each op
  (same pattern as `remote_rpc`), so every offloaded task is attributed to the
  exact operation and thread that caused it.

The final report (`bench::Reporter::print`) gains an **`OFFLOADED TASKS`**
block: aggregated totals ("complete operations") plus a per-thread breakdown
(`tid: lookups | scans | kv | leaves`), and the derived `kv / scan pushdown`
and `leaves / scan pushdown` ratios. Generic RPC pushdowns also still show up as
`rpc pushdown` under `REMOTE OPERATIONS` (every `rpc_*` bumps `num_rdma_rpc`).

### 6.5 Build & run

```bash
# Manual knob build (clean offloading x-axis) — used for the study:
cmake -DCMAKE_BUILD_TYPE=Release -DMANUAL_PUSHDOWN=ON ..
make -j
# In run.sh / run_other.sh keep both files identical; set:
#   RANGE=100  (100% range scans)   or   READ=100 (100% lookups)
#   RPC=0      -> caching only       RPC=1 -> offloading only
# Then on node 0: ./run.sh ; on node 1: ./run_other.sh
```

Read the `OFFLOADED TASKS` and `REMOTE OPERATIONS` sections of node 0's report
to confirm the offload actually fired (`scan pushdowns > 0`, `leaves / scan
pushdown > 1` proves multi-leaf offload), and compare `Final throughput` and the
`REMOTE (miss/rpc)` latency row across `RPC=0` vs `RPC=1`.

### 6.6 Why offloading helps — uniform vs Zipfian

The trade-off is always **MN-CPU result-shipping** vs **CN-cache page-shipping**,
and the workload distribution decides which side wins.

**Point lookups**

- *Uniform.* Accesses spread across all ~1.7 M leaves, so the leaf working set
  dwarfs any practical CN cache → almost every lookup is a **leaf miss**.
  Caching pays a full 1 KB page READ and then **evicts it before reuse** (no
  locality), so the cache churns for nothing. Offloading ships an 8-byte value
  instead of a 1 KB page and skips the eviction churn → **offloading wins**, and
  the win grows as the cache shrinks. (DEX inner nodes are still cached, so the
  pushdown starts near the leaf, not the root.)
- *Zipfian (θ≈0.99).* A few hot leaves serve most lookups and **stay resident**;
  those hits are local, zero-RDMA, and faster than any RPC. Offloading them
  would only add MN CPU to the critical path. The right policy is **cache the
  hot tail, (optionally) offload the cold body** — exactly what the adaptive
  `decision` does. Forcing `rpc_rate=1` under Zipf is usually *worse* than
  caching because it throws away the free hot-set hits and can bottleneck the MN
  CPU on the hot leaves.

**Range scans** (amplify everything above, because a scan touches several leaves
and returns many KV pairs)

- *Uniform.* Each scan start lands on a cold leaf and walks ~2 leaves for 100
  keys. Caching ⇒ ~2 separate 1 KB page READs that won't be reused. Offloading ⇒
  the MN walks both sibling leaves and returns one packed ~1600 B batch in **one
  RPC + one RDMA read**, regardless of how many leaves it spanned → **offloading
  wins clearly**, more decisively than for point lookups (it collapses N page
  reads into 1).
- *Zipfian.* Hot ranges' leaves stay cached and scan locally and fast; cold
  ranges benefit from offloading. Again adaptive (or a moderate `rpc_rate`) beats
  both extremes. A subtlety: a long scan over a hot region that *is* fully cached
  is fastest served locally — offloading it wastes the resident pages and adds
  MN work.

**Rules of thumb**

| Workload | Distribution | Best policy |
|---|---|---|
| Point lookup | Uniform | Offload (more so as cache shrinks) |
| Point lookup | Zipfian | Cache hot set; offload cold tail (adaptive) |
| Range scan | Uniform | Offload (collapses N leaf reads → 1 RPC+read) |
| Range scan | Zipfian | Cache hot ranges; offload cold ranges (adaptive) |

Two MN-side limits to watch in the report: offloading moves work onto MN CPUs,
so under high pushdown ratios the **MN directory threads** (`memThreadCount`) can
saturate — visible as a rising `REMOTE (miss/rpc)` p99 with throughput flat;
and the scan scratch caps a single RPC at 256 KV pairs, so very large scans make
several round trips (visible as `scans` ≫ number of range ops).

---

## 7. Tree-shape tuning: inner/leaf geometry decoupling

To create a regime where offloading clearly beats caching for **both** lookups
and range scans, the inner and leaf B-tree fanouts are **decoupled**
([btree_node.h](include/cache/btree_node.h)):

```cpp
static const uint64_t innerPageSize = 160;          // INNER fanout -> tree HEIGHT
static const uint64_t leafPageSize  = 512;          // LEAF fanout/size -> fetch cost
static const uint64_t pageSize      = leafPageSize; // physical / cache-slot / IO size
```
- `BTreeInner::maxEntries` is computed from `innerPageSize` → inner fanout **5**.
- `BTreeLeaf::maxEntries` is computed from `leafPageSize` → leaf fanout **25**.
- At 50 M keys this gives **height ~10**, ~2 M leaves, ~500 K inner nodes.

### 7.1 Why this is a *geometry-only* change (and why that's the right call)

Everything physical — the DSM node size, the RDMA transfer size, and the
**compute-node cache slot** — stays uniform at `pageSize` (= `leafPageSize`).
Only the *fanout* (array bound `maxEntries`) shrinks for inner nodes. So:

- It's **one file**. No change to the concurrency-sensitive split path, the
  RDMA read/write sizes, or the eviction/cooling/swizzling machinery. (`bulk_load`
  builds the tree via `insert_single`→splits, so a *physical* size change there
  would be risky and untestable.)
- **Key consequence:** with a *single* cache pool the slot size is the max node
  size (`leafPageSize`), so a cached **inner** node still occupies a full
  leaf-sized slot. Shrinking the inner's physical bytes would need per-type
  allocation **and two cache pools** — and it would save **DSM only, not cache**.
  Since the cache is what matters here, the physical shrink buys nothing; we skip
  it. The inner working set in cache is therefore `~500K × 512B ≈ 256 MB`.

### 7.2 Sizing the cache (important)

The path-aware cache only wins when the **inner path stays resident** so misses
are leaf-only. A tall tree has *many* inner nodes, so **`CACHE_MB` must exceed
the ~256 MB inner working set** (the run scripts default to `512`). If the cache
is too small the inner nodes churn too, every lookup pays an inner-walk of RDMA
reads, and that **swamps the offload-vs-cache signal**. Leaves (~1 GB) still
overflow a 512 MB cache, so they churn — which is exactly what makes offloading
win. (This is the trade-off discussed at length: tall-and-narrow trees are
inner-node-heavy; budget cache for the inner set, let leaves churn.)

### 7.3 Why this shape makes offload win for *both* ops

Recall the round-trip arithmetic (§6.3): lookup offload = **1 RTT** (8 B reply),
scan offload = **2 RTT** (RPC + one scratch read), no-offload scan = **N RTT**
(one read per leaf). With leaf fanout 25:

- **Lookup:** offload returns 8 B vs reading a 512 B leaf at equal round-trips,
  and skips caching the leaf → **offload wins** (bytes + no pollution).
- **Scan (100 keys):** spans ~4 leaves → offload 2 RTT vs no-offload ~4 RTT →
  **offload wins**.

Big leaves (e.g. `leafPageSize=4096`) maximize the *lookup* win but make a
100-key scan fit in ~1 leaf, where offload's 2nd round-trip makes it **lose** for
scans. `leafPageSize≈512` (fanout 25, scan spans >2 leaves) is the sweet spot
where both win.

### 7.4 Tuning knobs

| Want | Change | Watch out |
|---|---|---|
| Taller tree | lower `innerPageSize` (fanout↓) | more inner nodes → larger `CACHE_MB` |
| More expensive leaf (lookup win↑) | raise `leafPageSize` | keep fanout < ~50 or scans stop winning; keep ≤ 1024 or also raise `kLeafPageSize`/`kInternalPageSize` in [Common.h](include/Common.h) (the RDMA buffer slot) |
| Bigger scan collapse (scan win↑) | lower `leafPageSize` (more leaves/scan) | leaves get cheaper to fetch → smaller lookup win |

Invariant to preserve: `sizeof(BTreeInner)` and `sizeof(BTreeLeaf)` must both be
`≤ pageSize` (they are: 168 B and 504 B ≤ 512), and `pageSize ≤` the RDMA buffer
slot `max(kLeafPageSize,kInternalPageSize)`.
