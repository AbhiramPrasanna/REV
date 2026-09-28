# REV — architecture of DEX, CHIME and DART, what we changed, and how the fair comparison works

This document explains the three disaggregated-memory indexes in this repository,
how each one reads and caches the tree, what our versions (DEX+ and CHIME+) add, why,
and how the fair sweep in `fair/` compares them. It is written against the code on
branch `chime-leaf-cache`. File and line references point at that code.

Contents

1. [The setting: one compute node, one memory node](#1-the-setting-one-compute-node-one-memory-node)
2. [Three ideas every section uses](#2-three-ideas-every-section-uses)
3. [DART](#3-dart)
4. [DEX, and what DEX+ adds](#4-dex-and-what-dex-adds)
5. [CHIME, and what CHIME+ adds](#5-chime-and-what-chime-adds)
6. [Side by side: DEX, CHIME, DART](#6-side-by-side-dex-chime-dart)
7. [The fair comparison: what is matched and why](#7-the-fair-comparison-what-is-matched-and-why)
8. [Running the fair sweep](#8-running-the-fair-sweep)
9. [Reading the results](#9-reading-the-results)
10. [Every switch, in one place](#10-every-switch-in-one-place)
11. [File map](#11-file-map)
12. [Known limits](#12-known-limits)

---

## 1. The setting: one compute node, one memory node

Two servers joined by RDMA:

| Server | Address | Role |
|---|---|---|
| 8 | `10.30.1.8` | **Memory node.** Holds the whole index in its DRAM. Its CPU is idle unless a system asks it to do index work. |
| 6 | `10.30.1.6` | **Compute node.** Runs the client threads and the compute-side cache. |

The compute node reaches the index in two ways:

- **One-sided RDMA read.** The compute node reads bytes straight out of the memory
  node's DRAM. The memory node's CPU does nothing. One read is one network round trip.
- **A request to the memory node.** The compute node sends a message; a thread on the
  memory node (a "directory thread" or "memory thread") does some index work locally
  and replies. One request is also one round trip, but it can replace many reads.

All three systems are one binary per server, coordinated by memcached (DEX and CHIME)
or by a monitor process (DART).

## 2. Three ideas every section uses

1. **A round trip costs roughly the same whatever it carries.** On this network a
   70-byte read and a 500-byte read take about the same time. So what matters is how
   many round trips an operation makes, not how many bytes it moves. Making a read
   smaller does not help if the number of reads stays the same.
2. **A cache removes round trips only for data that fits and gets reused.** Inner
   nodes are few and every lookup passes through them, so they cache well. Leaves are
   many — their number grows with the data — and under uniform access any one leaf is
   rarely read twice, so they cache badly. A scan reads each leaf about once.
3. **A memory-node request removes round trips the cache could not.** When a lookup
   misses the cache several levels up, the memory node can finish the walk in its own
   DRAM and answer in one round trip. When a scan covers many leaves, the memory node
   can walk them and return them in one reply. It costs memory-node CPU, so it should
   happen only when the cache has actually missed.

## 3. DART

**What it is.** A radix tree (an adaptive radix tree, ART) on disaggregated memory.
Its depth depends on key length, not on how many keys are loaded, so with 8-byte keys
it never goes more than about eight levels deep.

**How a lookup works.** After the load, the compute node builds a hashed shortcut
table on the memory node (the RACE hash table, `src/race/`). A lookup reads the
shortcut table to jump close to its key, then reads one or two tree nodes to reach it.
About two to three round trips, whatever the cache holds.

**What the compute node caches.** Nothing, in this code. Each client thread has one
scratch buffer (`--th_b`/`--th_kb`/`--th_mb`) into which every read lands
(`art-node.cc:539`); its end pointer is never read. The only compute-side copy is the
shortcut table's directory. So the cache size passed to DART has no effect, and DART
gives the same result at every cache size.

**What the memory node does.** Nothing during an operation: `memory.cc` registers
memory, starts the shortcut-table server and waits on a socket.

**What this DART code covers.**

| Operation | Behaviour in this code |
|---|---|
| Point lookup | Complete. This is what DART is compared on. |
| Range scan | Follows a single path from the root and returns at most one key (`art-node.cc:1812-1865`). Its rate is an upper bound on a real 100-key DART scan. |
| Insert / update | One compare-and-swap; a failed one is not retried and not reported (`art-node.cc:351-355, 382-384`). |
| Delete | Not implemented; returns false with no RDMA but is still counted (`art-node.cc:1871-1886`). |

**In the fair sweep DART is run unchanged**, built with its own `build.sh`, with its
own launch sequence (monitor, memory, compute). Only the run settings match the
others: 50 M keys, 8-byte values, 36 client threads, 30 M operations. The one required
edit is configuration: `src/main/compute.cc:41` `ips[0]` must be the memory server's
address, because DART dials it for the shortcut table.

## 4. DEX, and what DEX+ adds

### 4.1 DEX as designed (PVLDB 17)

**Tree.** A B+tree. Nodes are plain C++ structs in the memory node's DRAM
(`include/cache/btree_node.h`): a 64-byte header (`NodeBase`), then sorted keys and
children (inner) or sorted key/value pairs (leaf). Leaves carry fence keys
(`min_limit_`, `max_limit_`) and a `next_leaf` link on the memory side.

**Cache.** A path-aware compute-side cache of **both inner nodes and leaves**
(`include/cache/leanstore_cache.h`). A child is admitted only if its parent is cached,
and a cached path is followed by local pointers (pointer swizzling). Inner nodes are
always admitted; leaves are admitted one time in ten (`admission_rate = 0.1`), because
caching leaves usually does not pay. Eviction uses a cooling map rather than one
shared list.

**Memory-node execution.** DEX can already send `LOOKUP`, `UPDATE`, `INSERT` and
`DELETE` to the memory node when a runtime cost model says a request is cheaper than
finishing locally. Upstream, this fires for subtree-level misses (levels up to
`megaLevel = 4`); a miss at the leaf's parent goes through the cache's admission path
instead, i.e. the leaf is copied to the compute node.

**Scans.** DEX keeps no leaf links on the compute side, so `range_scan(k, N)` reads one
leaf and then starts again from the root for the next one. A 100-key scan is a series
of lookups.

**Placement.** DEX treats every machine as a memory server (Sherman-style). Tree
nodes are spread over all machines: `DSM::get_random_id` picks another node for each
new inner node, so with two machines levels alternate between the compute node and the
memory node, and the compute node's own directory threads serve part of the requests.

### 4.2 Geometry in this fork

Upstream DEX used 1 KB nodes (about 60 entries per inner node, 4-5 levels at 50 M
keys, an inner-node set of roughly 40 MB). This fork decoupled inner and leaf
geometry (commit `f10be4a`) and set an inner fanout of 5 and 25-entry leaves, which
makes the tree **22 levels tall**. **Every DEX result so far used that geometry.**
The geometry is now a build flag (`DEX_INNER_PAGE`, `DEX_LEAF_PAGE`); the defaults
(160 / 512) reproduce the old results exactly. The fair sweep uses 336 / 352 bytes,
which with the 64-byte header gives **16-entry inner nodes and 16-entry leaves** —
the same shape as CHIME (§7).

### 4.3 What DEX+ adds

| Change | Where | What it does |
|---|---|---|
| Leaf-miss requests | `cold_to_hot_with_rpc_for_lookup` in `leanstore_cache.h`, called at the leaf parent in `leanstore_tree.h` | On a leaf miss, send a request: the memory node searches the leaf and returns the 8-byte value, instead of the compute node copying the whole leaf. |
| Scan requests | new `RpcType::SCAN`; `cachepush::range_scan` in `include/cache/btree_rpc.h`; handler in `src/Directory.cpp`; hook `cold_to_hot_with_rpc_for_scan` | On a scan's leaf miss, the memory node walks `next_leaf` in its own DRAM, packs up to the requested number of pairs into a per-requester slot, and the compute node fetches them with one read. It stops when the chain leaves this memory node and returns a resume key. |
| Manual rate | `-DMANUAL_PUSHDOWN=ON`, `rpc_rate` argument | Turns off the adaptive cost model so `rpc_rate` is the exact fraction of eligible misses sent (0 = off, 1 = always). |
| Memory-node load | `include/remote_load.h` | Prints each directory thread's busy fraction every 2 s (`AGGREGATE active = …%`). Raw CPU% is useless because the threads busy-poll. |
| Memory-node-only placement | `-DMN_ONLY_PLACEMENT=ON`; `dsm_placement_node` in `include/DSM.h` | Every allocation goes to a memory node (IDs `computeNR`..`machineNR-1`), never the compute node. The root pointer store stays on node 0. Used by the fair sweep so DEX's tree lives where DART's and CHIME's do. |
| Geometry line | `test/newbench.cpp` | Prints `[GEOMETRY] inner_page= leaf_page= inner_entries= leaf_entries= slot= placement=` at start. |

**The logic:** keep the cache for inner nodes, which are few and always reused, and
serve leaves at the memory node, because their number grows with the data and a cache
cannot hold the ones that will be needed under uniform access. A scan that would have
been a series of lookups becomes one request.

## 5. CHIME, and what CHIME+ adds

### 5.1 CHIME as designed (SOSP'24)

**Tree.** A B+tree built on Sherman's code base. Inner nodes are sorted; **leaves are
hopscotch hash tables** — a key lives within a small neighbourhood (`neighborSize = 8`)
of its hashed slot, so leaves are unsorted inside.

**Node format.** Encoded so a one-sided reader can check a read without a lock:

- **Version bytes in every 64-byte cache line.** A writer's RDMA write can land one
  cache line at a time; a reader copies the node and checks that every line carries
  the same version. A mismatch means the read overlapped a write, so it retries.
- **Replicated metadata.** Fence keys, sibling pointer and level are copied into every
  group of entries, so reading part of a leaf is self-describing.
- **Hop bitmap per entry.** Says which nearby slots hash to this one; the reader
  recomputes it to detect a torn partial read.
- **Vacancy-aware lock word.** The leaf's 8-byte lock also holds a bitmap of occupied
  slots, so a reader knows how much to fetch. Writers take the lock with a masked
  compare-and-swap (emulated on this cluster's rdma-core, `DSM.cpp:642-675`).

**Cache.** **Inner nodes only.** A cached inner node never needs to be kept in sync —
a stale one just leads to the wrong leaf and the operation retries — so CHIME avoids
cache coherence entirely. The price: every lookup reads its leaf remotely, even on a
full cache hit. Everything else in CHIME (hopscotch windows, a hotspot buffer that
remembers where popular keys sit, replicated metadata) makes that one leaf read
*smaller*; none removes it.

**Memory node.** Never does index work.

**Tree shape in this fork.** `internalSpanSize = leafSpanSize = 16` (upstream 64),
chosen so an inner node is smaller than a leaf. How full the nodes end up depends
on the load order. CHIME's stock load inserts the keys shuffled, which leaves nodes
about two-thirds full: about 7 levels at 50 M keys, with roughly 90-100 MB of inner
nodes. The fair sweep loads the keys sorted instead (`CHIME_SORTED_LOAD=1`), the
same way DEX's `bulk_load` does. Each split then leaves the left node half full, so
the tree has the same shape as DEX's (see §7). A cache miss costs one dependent read
per inner level.

**Scans.** A scan of N keys becomes the key range `[k, k+N)`. With the level-1 inner
nodes cached, upstream CHIME knows every target leaf and reads them together in one
round trip. On this cluster that batched read was unstable (commits `4a32148`,
`f3ee90e`), so **this port reads covered leaves one at a time** by default. Without
the cached level-1 nodes, it runs one full lookup per key.

### 5.2 What CHIME+ adds

| Change | Where | What it does |
|---|---|---|
| Lookup requests on a miss | `RPC_LOOKUP`; `chime_offload::lookup_from` (`include/chime_rpc.h`); hook in `Tree::search` | The compute node sends the deepest inner node its cache found and that node's level; the memory node walks the remaining inner levels and the leaf in its DRAM and returns the value. ~7 reads become 1 request. Gated by `CHIME_OFFLOAD_MIN_LEVEL` (default 2): only when inner levels remain, i.e. on a cache miss. |
| Scan requests | `RPC_SCAN`; `chime_offload::range_scan`; `Tree::range_query_offload` | The memory node walks sibling leaves, gathers keys in range, sorts them (leaves are unsorted), and the compute node fetches them in one read. Originally sent only when the inner-node cache misses. |
| Reading the encoded format | `read_leaf_local`, `read_internal_local` in `chime_rpc.h` | The memory node copies the node, checks the version bytes, reassembles the metadata, retrying on mismatch. The copy comes first: checking in place would let a writer change a line between check and read. It ignores both bitmaps — they exist to make *partial* reads safe; the memory node reads the whole node and the version check is stronger. |
| Leaf cache | `include/LeafCache.h`; `-DCACHE_LEAF_NODE`, `CHIME_CACHE_LEAF` | A second compute-side cache of decoded leaves, carved out of the same total budget (`CHIME_LEAF_CACHE_PCT`, default 50%): inner + leaf = total, always. 8-way set associative, LFU with ageing, immutable entries, deferred free. |
| Leaf-cache correctness | 8-byte **stamp** per leaf, at `leafStampOffset`; `Tree::lock_node` | A writer, right after taking the leaf lock and before changing data, writes a new never-reused stamp (thread id << 48 \| counter). A reader may use a cached leaf only if one 24-byte read of `[lock word, stamp]` shows the leaf unlocked with the stamp it cached. A fill brackets the data read with two such reads in one doorbell, so it costs no extra round trip. Every node must run with the same `CHIME_CACHE_LEAF` value. |
| Scan leaves read together | `Tree::range_query`, leaf-cache branch | With the leaf cache on: one batch of `[lock, stamp]` checks for cached leaves, one batch of bracketed reads for the rest — two round trips per scan instead of one per leaf. Per-path admission `CHIME_LEAF_ADMIT_POINT` / `CHIME_LEAF_ADMIT_SCAN`. |
| **Clients on the compute node only** | `CHIME_MN_CLIENTS=0` (`test/micro_test.cpp`) | CHIME runs the same benchmark on both servers, so by default the memory node also runs 34-36 client threads that share its NIC and CPU with request handling. With 0, the memory node's threads join every barrier but run no operations — the same placement as DEX and DART. |
| **No lost cache budget** | `Tree::Tree` (`src/Tree.cpp`) | The 30 MB hotspot buffer is now subtracted from the inner-node cache only when the buffer exists. It is disabled when the leaf cache is on, and before this fix its 30 MB went unused. |
| **Scan requests start from the cache** | `CHIME_SCAN_FROM_CACHE=1`; `Tree::range_query_offload`; `chime_offload::descend_to_leaf`; `RPC_SCAN` handler in `src/Directory.cpp` | Before, a scan request first walked down to its start leaf with one-sided reads (`get_leaf_addr`, ~6-7 round trips on a miss) and only then asked the memory node. Now it sends the deepest cached node and its level, and the memory node walks down — exactly what point lookups do. The start level travels in the upper 16 bits of `RawMessage.level` (count in the lower 16), so the message size is unchanged; old requests (level 1) behave as before. If the memory node cannot walk down, the compute node retries the old way. |
| **DEX-shaped bulk build** | `CHIME_BULK_BUILD=1` (`CHIME_BUILD_LEAF_KEYS` 8, `CHIME_BUILD_INNER_FANOUT` 7); `Tree::bulk_build` in `src/Tree.cpp`, called from `thread_bulk_load` | One thread writes every node bottom-up from the sorted keys, in the same on-wire format the split paths produce (hopscotch placement, replicated metadata, cacheline versions, unlocked vacancy-aware lock word), then swings the root pointer. Leaves get 8 keys and inner nodes 7 children, DEX's measured fill, so both trees are 9 levels with the same node counts. The compute node's cache starts empty and is filled by the warmup. |
| **DEX-style load order (superseded)** | `CHIME_SORTED_LOAD=1`; `generate_workload` and `thread_bulk_load` in `test/micro_test.cpp` | The bulk-load keys are sorted, and each of the 8 loader threads inserts its own contiguous block in ascending order. This follows DEX's `bulk_load`, so both trees get half-full nodes and the same height. Contiguous blocks keep the 8 loaders apart; one global sorted stream would make them all compete for the rightmost leaf. Only the load order changes; the workload keys are drawn the same way as before. After the load, the loader node prints `[TREE] height= leaves= inner_nodes= … inner_MB=`. |
| **Every scan to the memory node** | `CHIME_SCAN_OFFLOAD_ALWAYS=1`; top of `Tree::range_query` | While offloading is on, every scan goes to the memory node, even when the inner nodes fit — the path DEX+ uses. With offloading off it never fires. |
| Geometry and config lines | `micro_test.cpp` | `[GEOMETRY]`, `[CACHE node N] total= index= leaf=`, `[CONFIG node N] clients on this node:`, `[CONFIG node N] scan path: from_cache= offload_always=`. |

The last four rows (bold) were added for the fair comparison; all default to the old
behaviour, so every earlier CHIME result can still be reproduced.

**The logic:** CHIME already had caching, so its gains come from the memory node.
When the inner nodes do not fit, one request replaces a ~7-read walk. When they do
fit, the remaining cost is the leaf read, which the leaf cache removes for popular
leaves. Scans are a different case: a scan reads most leaves once, so a leaf cache
mostly adds the cost of filling it, and what helps is handing the whole scan to the
memory node — which is why the scan path now matches DEX+'s.

## 6. Side by side: DEX, CHIME, DART

| | DEX | CHIME | DART |
|---|---|---|---|
| Tree | B+tree, sorted nodes | B+tree, hopscotch (unsorted) leaves | Radix tree (ART) |
| Depth grows with | number of keys | number of keys | key length only |
| Node format | plain structs | per-cache-line versions, replicated metadata, bitmaps | ART node types |
| Compute-side cache | inner nodes and leaves (leaves 1 in 10) | inner nodes only | none |
| Lookup, cache hit | 0 round trips (leaf cached) or 1 | 1 (the leaf) | ~2-3 (shortcut table + 1-2 nodes) |
| Lookup, cache miss | 1 per missing level | ~7 | ~2-3 |
| Memory node CPU | optional requests (cost model) | never | never |
| Range scan | one lookup per leaf, from the root | reads covered leaves together (one at a time in this port) | one path, one key in this code |
| Keeping cached copies correct | its own protocol for cached leaves | not needed (inner only) | nothing cached |
| **+ version** | DEX+: memory node answers leaf misses and walks scans | CHIME+: memory node answers misses and walks scans; leaf cache with stamps | unchanged |
| **+ memory-node work per request** | cheap: reads plain structs (~0.6 µs per scan request measured) | more: copy, check, reassemble each leaf | — |

## 7. The fair comparison: what is matched and why

| Property | Setting | Why |
|---|---|---|
| Data | 50 M keys, 8 B keys, 8 B values in all three | DEX stores 8 B values; CHIME is built with `-DCHIME_VALUE_LEN=8`; DART runs `--payload_byte=8`. |
| Tree shape | DEX and CHIME: **16-entry inner nodes, 16-entry leaves** | DEX `-DDEX_INNER_PAGE=336 -DDEX_LEAF_PAGE=352` gives (336-8-64)/16 = 16 inner entries and (352-32-64)/16 = 16 leaf entries; CHIME's spans are 16. Node size alone does not fix the tree: the load order sets how full nodes are. DEX loads sorted, which leaves nodes half full, so its tree is taller and has more inner nodes than CHIME's stock shuffled load (about 7 levels, roughly 100 MB). Measured in run fair3, DEX's tree is 9 levels with 6,249,999 leaves (2,098 MB) and 1,041,652 inner nodes (350 MB, about 7 children each). CHIME inserting the same sorted keys was not enough: it measured 8 levels and 772,006 inner nodes, because its inner split keeps about 9 children, and the load took 43 minutes against 2.5 minutes shuffled. The fair sweep therefore builds CHIME's tree bottom-up from the sorted keys with DEX's measured fill (`CHIME_BULK_BUILD=1`: 8 keys per leaf, 7 children per inner node). That gives 9 levels, 6,250,000 leaves and about 1,041,667 inner nodes (about 333 MB at 335 B per node) in seconds. The workloads are read-only, so the way the tree was built does not change what is measured. Compare DEX's `Tree height` / `#leaf nodes` / `#inner nodes` lines with CHIME's `[TREE]` line in the compute logs. DART's radix shape cannot be matched, and that difference is what the comparison measures. |
| Cache range | 32, 64, 128, 256, 512, 1024 MB total | Runs from "inner nodes do not fit" (32-128) through the boundary (256-512, near DEX's measured 350 MB inner set) to "fit" (1024). With upstream geometry (64-entry nodes) the inner set would be ~30-45 MB and there would be almost no "do not fit" region. |
| Memory threads | 0-8; **0 = no offloading** | DEX: `rpc_rate 0` with one idle directory thread (needed to hand out memory chunks). CHIME: offload off, one directory thread. k ≥ 1: offloading on with k threads. DART: not applicable. |
| Clients | 36 threads, compute node only | DEX and DART already do this; CHIME uses `CHIME_MN_CLIENTS=0`. |
| Where the tree lives | memory node only | DART and CHIME already; DEX built with `-DMN_ONLY_PLACEMENT=ON`. |
| Run | 10 M warmup + 30 M measured ops (DART: no warmup phase exists) | DEX runs op-bounded (`time_based = 0`) to match. |
| Latency | p99 from 0.5 µs histograms | All three report the same way; DART's other latency column is a mean and is not used. |
| DART | unchanged code, own build and launch | By request: DART is the reference as shipped. |

**Differences that remain, by design or by limit:** DART has no warmup phase; DART's
scan returns one key (so scan ratios understate the B+trees); DART is built by its own
`build.sh` (no optimisation flags set there, while DEX and CHIME build with -O3); CHIME
still pins client thread i to core 2i+1 (needs ≥ 74 logical CPUs at 36 threads, the
scripts warn otherwise); DEX's root pointer store stays on node 0.

## 8. Running the fair sweep

**Once per server** (both 6 and 8): hugepages, `ulimit -l unlimited`, memcached
installed (DEX uses it on server 6, CHIME on server 8), the same commit checked out at
the same path, and for CHIME the NIC macros set (`CHIME/run/configure_nic.sh`). Set
DART's `ips[0]` to `10.30.1.8`.

**Build** (both servers, same commit):

```bash
RUN_ID=fair1 bash fair/build.sh          # dex/build_fair, CHIME/build_fair, DART/bin
```

**Run** (one command per server, same `RUN_ID`, start in either order):

```bash
# server 8 (memory)
RUN_ID=fair1 bash fair/run_all.sh memory
# server 6 (compute)
RUN_ID=fair1 bash fair/run_all.sh compute
```

`run_all.sh` runs DART, then DEX, then CHIME, and on server 6 finishes with
`fair/collect.py`. Each system can also be run alone: `fair/run_dart.sh`,
`fair/run_dex.sh`, `fair/run_chime.sh`, each with `compute` or `memory`.

**Size and time with the defaults** (9 memory-thread counts × 6 caches × 4 workloads):
DART 24 cells (~1 h), DEX 216 cells (~11 h), CHIME 432 cells with both leaf-cache
arms (~40 h). A first pass that still spans every regime:

```bash
RUN_ID=fair0 MEMTHREADS="0 1 2 4 8" CACHES="32 128 512 1024" bash fair/run_all.sh <role>
```

Every setting in `fair/params.sh` can be overridden from the environment, as long as
both servers get the same values.

**How the two servers stay in step.**

- DEX: server 6 is DEX node 0; it restarts memcached (resetting `serverNum` to 0) and
  starts each cell. Server 8 polls memcached until `serverNum` is 1 (server 6 has
  registered) and then starts the same cell.
- CHIME: server 8 is CHIME node 0 and hosts memcached; `CHIME/run/bench_common.sh`
  handles the handshake per cell, as in every earlier CHIME sweep.
- DART: server 6 starts the monitor then the compute process; server 8 retries
  `bin/memory` until the monitor is listening, once per cell.

## 9. Reading the results

`fair/results/<RUN_ID>/` holds per-system logs and CSVs, and after `collect.py`:

| File | What it is |
|---|---|
| `fair_all.csv` | Every cell in one schema: system, workload, cache, memory threads, leaf arm, throughput, p99, **ratio to DART**, peak memory-node busy %. |
| `fair_summary.md` | For DEX and CHIME+, a table per workload of ratio to DART (rows: memory threads, columns: cache), and the smallest cache and thread count at which each first reaches DART. |
| `fig_dex_vs_dart.png`, `fig_chime_vs_dart.png` | Throughput against cache, one line per memory-thread count (grey dashed = no offloading), DART as the dotted reference. Same y-scale on every panel, starting at 0. |
| `fig_ratio_vs_dart.png` | Heatmaps of ratio to DART (memory threads × cache) for DEX and CHIME+; red below 1, grey at 1, blue above. |

**Ratio to DART** = the system's throughput ÷ DART's throughput for the same workload
and cache size. Above 1.00 is faster than DART by that factor. **CHIME+** is the better
of the two leaf-cache arms at each cell. For scans, DART's rate comes from a one-key
scan, so a real 100-key DART scan would be slower and the ratios shown are the least
the B+trees are ahead by.

**What to check first in the logs:** DEX `[GEOMETRY] inner_entries=16 leaf_entries=16
placement=mn_only` and `Tree height`; CHIME `[CONFIG node 0] clients on this node: no`,
`scan path: from_cache=1 offload_always=1`, and `[CACHE node 1] total= index= leaf=`
adding up; DART `Total throughput` in the monitor log.

## 10. Every switch, in one place

**DEX (CMake)**

| Flag | Default | Effect |
|---|---|---|
| `CMAKE_BUILD_TYPE` | required | `Release` = -O3 |
| `MANUAL_PUSHDOWN` | OFF | ON: `rpc_rate` controls offloading exactly (adaptive model off) |
| `MN_ONLY_PLACEMENT` | OFF | ON: tree nodes on memory nodes only |
| `DEX_INNER_PAGE` / `DEX_LEAF_PAGE` | 160 / 512 | node geometry in bytes (fair: 336 / 352) |

DEX `newbench` arguments (22): nodes, read%, insert%, update%, delete%, range%,
total threads, memory threads, cache MB, uniform (1/0), zipf θ, bulk M, warmup M,
ops M, check, time_based, early_stop, index (0 DEX, 1 Sherman, 2 SMART), rpc_rate,
admission rate, auto_tune, threads per compute node.

**CHIME (CMake)**: `ENABLE_OFFLOAD` (OFF), `CACHE_LEAF_NODE` (ON), `CHIME_VALUE_LEN`
(48; fair 8), `CHIME_INTERNAL_SPAN` (16). Layout-changing flags must match on both
servers.

**CHIME (environment)**

| Variable | Default | Effect |
|---|---|---|
| `CHIME_CACHE_MB` | 100 | total compute-side cache |
| `CHIME_CACHE_LEAF` | 0 | leaf cache on/off (same on both servers) |
| `CHIME_LEAF_CACHE_PCT` / `_MB` | 50 / — | leaf share of the total |
| `CHIME_DIR_THREADS` | 4 | memory-node threads (same on both servers) |
| `CHIME_OFFLOAD_MIN_LEVEL` | 2 | lookups offload only when this many levels remain |
| `CHIME_LEAF_ADMIT_POINT` / `_SCAN` | 1.0 / 1.0 | leaf-cache admission per path |
| `CHIME_MN_CLIENTS` | 1 | 0: no client operations on the memory node |
| `CHIME_SCAN_FROM_CACHE` | 0 | 1: scan requests start from the deepest cached node |
| `CHIME_SCAN_OFFLOAD_ALWAYS` | 0 | 1: every scan to the memory node while offloading is on |
| `CHIME_BULK_BUILD` | 0 (fair sweep: 1) | 1: build the tree bottom-up with `CHIME_BUILD_LEAF_KEYS` (8) keys per leaf and `CHIME_BUILD_INNER_FANOUT` (7) children per inner node |
| `CHIME_SORTED_LOAD` | 0 | 1: bulk load in sorted order, contiguous block per loader (DEX-like tree shape) |
| `CHIME_RANGE_BATCHED` | unset | any value: upstream's batched covered-leaf read (unstable here) |
| `CHIME_NODE_ID` | — | set by the scripts: 0 memory, 1 compute |

**DART (flags, unchanged)**: `--th_b` (per-thread buffer), `--payload_byte`,
`--mb_key_count`, `--run_max_request`, `--mb_read_pct` / `--mb_scan_pct`,
`--mb_uniform`, `--mb_theta_x100`, `--mb_scan_len`, thread and NIC flags.

**Fair sweep (`fair/params.sh`, all overridable)**: `RUN_ID` (required), `MEM_IP`,
`CMP_IP`, `THREADS` 36, `KEYS_M` 50, `VALUE_B` 8, `WARMUP_M` 10, `OPS_M` 30,
`SCAN_LEN` 100, `ZIPF_THETA` 0.99, `CACHES`, `MEMTHREADS`, `WORKLOADS`,
`CHIME_LEAF_SET`; `SYSTEMS` for `run_all.sh`.

## 11. File map

| Path | What |
|---|---|
| `fair/` | fair sweep: `params.sh`, `build.sh`, `run_{all,dart,dex,chime}.sh`, `collect.py` |
| `dex/include/cache/btree_node.h` | DEX node layout and geometry flags |
| `dex/include/cache/leanstore_cache.h` | DEX cache, admission, request hooks |
| `dex/include/tree/leanstore_tree.h` | DEX tree: lookup, scan, splits, placement calls |
| `dex/include/cache/btree_rpc.h` | DEX memory-node lookup and scan handlers |
| `dex/include/DSM.h` | DEX allocation and placement (`dsm_placement_node`) |
| `dex/test/newbench.cpp` | DEX benchmark (also runs Sherman and SMART) |
| `CHIME/src/Tree.cpp` | CHIME tree: search, offload hooks, range query, leaf cache use |
| `CHIME/include/chime_rpc.h` | CHIME memory-node decode, `lookup_from`, `descend_to_leaf`, `range_scan` |
| `CHIME/src/Directory.cpp` | CHIME memory-node request handlers |
| `CHIME/include/LeafCache.h` | CHIME+ leaf cache |
| `CHIME/test/micro_test.cpp` | CHIME benchmark |
| `CHIME/run/` | CHIME sweep harness (`bench_common.sh`, `run_leaf_cache.sh`, …) |
| `DART/src/prheart/art-node.cc` | DART tree operations |
| `DART/src/main/{monitor,memory,compute}.cc` | DART processes |
| `RUNBOOK.md` | build/run audit and every known issue with file:line |

## 12. Known limits

- **None of the new code has been compiled yet**; both DEX and CHIME build only on
  the Linux cluster. Check the `[GEOMETRY]` and `[CONFIG]` lines on the first cell.
- **CHIME masked compare-and-swap is emulated** (read + CAS under a process-local
  mutex). Fine for the read-only sweep and a single loader; not a guarantee for
  concurrent writers on two nodes.
- **CHIME scan scratch slots** are keyed by thread number within a process
  (`Directory.cpp`, `app_id % MAX_APP_THREAD`). With `CHIME_MN_CLIENTS=0` only one
  node sends scans, so slots no longer collide.
- **Requests are synchronous** in both systems (a thread blocks on its reply), so
  memory-node execution numbers are a floor.
- **Correctness checks are found/not-found only**; they would not catch a wrong value.
- **DART** limits in §3 (one-key scans, no delete, unretried writes) bound what can be
  compared; the fair sweep is read-only (point lookups and 100-key range scans).
- **Earlier results** (DEX `summary.csv`, CHIME `leafstudy2`) used different trees
  (DEX 22 levels) and settings, and must not be mixed with the fair sweep.
