# CHIME RPC Offloading

This adds a **compute-offload path** to CHIME so the memory node (MN) can execute
point lookups and range scans on behalf of the compute node (CN), mirroring how
**DEX** offloads (see `dex/include/cache/btree_rpc.h`, `dex/src/Directory.cpp`).
It exists so CHIME can be compared head-to-head with DEX on **remote CPU load**:
stock CHIME, like DART, keeps the MN idle (only one-sided RDMA); with offloading
the MN does real per-op index work.

## What it does

- **LOOKUP pushdown.** The CN traverses its cached internal nodes as normal; at
  the leaf's parent (`level == 1` in `Tree::search`) it sends the resolved leaf
  address + key to the MN instead of doing a one-sided leaf read. The MN decodes
  the leaf in local memory and probes it (`chime_offload::lookup`).
- **SCAN pushdown.** The MN walks the sibling-leaf chain locally, packs up to
  `kScanSlotCap` KV pairs into a per-requester scratch slot in its DSM region,
  and returns the slot address + count. The CN reads the whole batch with **one**
  RDMA read (`Tree::range_query_offload` + `chime_offload::range_scan`).
- **Remote-load metric.** The MN dir-thread prints its **active %** every 2 s
  (`remote_load.h`) — time inside `process_message` (real RPC work) vs spinning
  on the NIC. This is the exact metric used on the DEX side.

Unlike DEX (plain structs in DSM), CHIME leaves are version-**encoded** and, with
`METADATA_REPLICATION`, **scattered**, so the MN reuses CHIME's own decoders
(`LeafVersionManager` / `MetadataManager` / `VersionManager`) and retries on a
version mismatch — preserving CHIME's torn-read detection under concurrent
one-sided writers.

## Files

| File | Change |
|---|---|
| `include/RawMessageConnection.h` | `RpcType::{LOOKUP,SCAN}` + `k`/`v` message fields |
| `include/chime_rpc.h` | **new** — MN-side `lookup()` / `range_scan()` |
| `include/remote_load.h` | **new** — MN dir-thread active-% tracker |
| `src/Directory.cpp`, `include/Directory.h` | RPC handlers + scan scratch + load tracking |
| `include/DSM.h` | CN-side `rpc_lookup()` / `rpc_scan()` |
| `src/Tree.cpp`, `include/Tree.h` | offload hook in `search`, `get_leaf_addr`, `range_query_offload` |
| `test/offload_test.cpp` | **new** — benchmark app |
| `CMakeLists.txt` | `ENABLE_OFFLOAD` option (default **OFF**) |

Everything data-plane is behind `#ifdef ENABLE_OFFLOAD`; with the flag off the
build is functionally identical to stock CHIME (only the RawMessage struct grows,
still well under `MESSAGE_SIZE`).

## Build & run (on the CloudLab / Linux RDMA cluster)

```shell
# on ALL nodes
mkdir build; cd build
cmake .. -DENABLE_OFFLOAD=ON
make -j
```

Baseline (one-sided, for A/B) is the same tree with `-DENABLE_OFFLOAD=OFF`.

```shell
# one node: memcached
/bin/bash ../script/restartMemc.sh
# all nodes: split workloads (as for ycsb_test)
python3 ../ycsb/split_workload.py c randint 10 24
# all nodes: run — 6th arg = % of lookups offloaded (0..100), 7th = fixed scan range
./offload_test 10 24 2 randint c 100
./offload_test 10 24 2 randint e 100 100     # scan workload, range 100
```

Throughput prints on the CNs; the **memory node** prints `REMOTE CPU LOAD ... dir N:
active=..%` every 2 s — that is the number to compare against DEX.

## Microbenchmark (DEX-style, no YCSB files)

`test/micro_test.cpp` runs the way DEX's `newbench` runs: the workload is
**generated in code** from a synthetic key distribution (uniform or Zipfian, the
same `mehcached_zipf` as DEX) with a configurable op mix, executed in the DEX
phase structure **bulk-load → warmup (untimed) → measured run**, and reported
with the same `bench_stats` output (500 ns buckets, p50/p90/p99/p99.9/max, CDF,
offloaded-task tracking). No `split_workload.py`, no YCSB files.

```
./micro_test kNodeCount kThreadCount readRatio insertRatio updateRatio rangeRatio \
             uniform(1|0) zipf_theta bulkLoadM warmupM opM offload_rate [scan_range]
```

The four DEX microbenchmark cells (Point/Range × Uniform/Zipf), 2 nodes / 24 thr / 50M keys:

```shell
# Point-Uniform            R  I U S  uni theta bulk warm op  off
./micro_test 2 24 100 0 0   0  1  0     50   10  50 100
# Point-Zipf
./micro_test 2 24 100 0 0   0  0  0.99  50   10  50 100
# Range-Uniform  (scan span 100)
./micro_test 2 24 0   0 0 100  1  0     50   10  10 100 100
# Range-Zipf
./micro_test 2 24 0   0 0 100  0  0.99  50   10  10 100 100
```

Set `offload_rate 0` for the one-sided baseline in the same binary (A/B). The
memory node prints its dir-thread `active %` throughout. `ycsb_test` (unchanged)
and `offload_test` (YCSB-driven) remain available; `micro_test` is the
self-generating, DEX-style path.

## Known limitations / caveats

- **Not yet compiled or run** — the REV repos build only on the Linux RDMA
  cluster (MLNX_OFED/libibverbs), not the Windows dev box. The code is written
  against CHIME's structures but needs a cluster build + a correctness pass
  (a `c`/`e` workload with offload on vs off should return identical results).
- **Synchronous RPCs.** `rpc_lookup`/`rpc_scan` block on `rpc_wait()` (no
  coroutine yield), so offloaded ops don't overlap under `kCoroCnt`. Fine for
  the load measurement; make them coro-aware for peak throughput.
- **Scan scratch slot = `app_id % MAX_APP_THREAD`** (same scheme as DEX). Across
  multiple CN *nodes* two threads can share a slot; harmless for load numbers but
  key by global thread id if exact multi-CN scan results are needed.
- `ENABLE_VAR_LEN_KV` is not offloaded (would need a second hop for the DataBlock).
