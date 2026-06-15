# DART Microbenchmarks — building an in-memory working set (YCSB-free)

This document is the DART counterpart of [microbenchmarks.md](microbenchmarks.md)
(which describes the **DEX** harness `newbench.cpp`). It (1) explains DART end to
end as it exists in this repo, (2) explains the current YCSB workload pipeline and
why we replace it, and (3) specifies a microbenchmark that generates the
**working set in memory** — reusing the same distribution generators DEX uses
(`test/zipf.h`, `test/uniform.h`) — and plugs into DART's existing benchmark
engine with minimal edits.

The runnable scaffold lives in [dart_microbench/](dart_microbench/):
`workload_gen.h`, `bench_stats.h`, `integration.md`, `README.md`.

---

## 1. What DART is

DART (SIGMOD'26): *A Lock-free Two-layer Hashed ART Index for Disaggregated
Memory*. Like DEX it runs on **disaggregated memory**: compute nodes (CNs) hold
no persistent data and reach memory nodes (MNs) over **RDMA**. Unlike DEX (a
B+-tree), DART's index is an **adaptive radix tree (ART)** whose nodes are hashed
into a two-layer structure, plus a **skip table** (shortcuts) built after load.

### 1.1 Process model (3 binaries, coordinated over TCP)

DART is **not** a single benchmark executable. Three roles connect through a
`monitor`:

| binary  | source                | role |
|---------|-----------------------|------|
| `monitor` | `src/main/monitor.cc` | rendezvous + barrier; collects results |
| `memory`  | `src/main/memory.cc`  | a memory node (MN): registers RDMA region |
| `compute` | `src/main/compute.cc` | a compute node (CN): runs the workload |

The monitor exchanges RDMA queue-pair / memory-region metadata between every
(memory, compute, thread) triple, then drives a phased handshake using integer
signals (`200` start, `600` load done, `700` go-prepare, `800` prepare done,
`900` go-run, `999` end — see `monitor.cc`). At the end each CN sends back
`(throughput MOps, latency us, bandwidth)`; the monitor sums throughput and
averages latency. **This is the headline number.**

### 1.2 The index API (`prheart::PrheartTree`)

The tree (`include/prheart/art-node.hpp`) exposes byte-span operations — keys and
values are `span` = `std::span<uint8_t>`:

```cpp
bool search(span key);
bool insert(span key, span value);
bool update(span key, span value);
bool scan(span start_key, span end_key, vec<str>& result_vec);
bool remove(span key);
uint64_t create_skip_table();      // build shortcuts after load (CN 0 only)
```

The RACE hashing layer (`include/race/`, `src/race/`) provides the hashed buckets
the ART rides on (`--bucket` sizes it). `#define SKIP_TABLE` in `compute.cc`
turns on the shortcut layer.

### 1.3 The per-op cost signal: `rtt`

`src/prheart/art-node.cc` declares `__thread uint64_t rtt` and increments it once
per RDMA round trip taken inside a tree op. It is reset to 0 at the top of each
worker (`test_ycsb_load`). **`rtt` is DART's analog of DEX's `num_rdma_*`
counters**: the delta of `rtt` across a single op tells you whether that op was
served locally (delta 0) or hit the network (delta > 0). The microbench
instrumentation in §5 uses exactly this.

---

## 2. The current workload pipeline (and why we replace it)

Today a DART run is driven by **YCSB text files**:

```
script/workload_download.py     # pulls the YCSB release tarball
script/workload_gen.sh          # runs `ycsb load/run basic -P spec/{a..g}` -> data/{x}_{load,run}
script/split_and_send_workload.py --inputs a_load a_run --ips 70 72 74   # shard to CNs
```

At run time:

- The **monitor** forwards `workload_prefix + workload_load` and
  `... + workload_run` filenames to each CN (`monitor.cc` lines ~136–142).
- The **CN** (`compute.cc`) calls
  `YCSB::FileLoader::load_from_file(...)` for both, which parses the YCSB record
  format —
  `INSERT/READ/UPDATE/SCAN/DELETE usertable <key> [ field0=... ]` —
  into `records = vec<tup<operat, key, value, end_key>>` (spans into a
  `BufferBlock`). Keys named `user<digits>` are parsed to a `u64` and stored
  big-endian; `m...`-prefixed files are treated as **string** keys (email mode).
- `YCSB::Benchmark` (`include/ycsb/ycsb-timecounter.hpp`) registers five lambdas
  (`register_read/insert/update/scan/remove`) that call the tree, then
  `start_benchmark()` walks the record slice for this thread and dispatches by
  `operat`. `TimeCounter` wraps each call to accumulate time.

### Why replace it

- **External dependency + disk**: needs the YCSB Java/Python toolchain, a
  download, multi-GB text files, a binary-cache step, and a separate sharding
  script before a single number comes out.
- **No knobs at run time**: skew, working-set size, and op-mix are baked into the
  files; sweeping them means regenerating files.
- **We only need the *working set*** — distinct keys + an op stream over them —
  which DEX generates directly in `newbench.cpp` from `zipf.h` / `uniform.h`.
  DART should do the same: generate the working set in memory at startup, feed the
  identical `records` structure to `YCSB::Benchmark`, and keep everything else
  (the RDMA cluster, the tree, the timers, the monitor aggregation) untouched.

---

## 3. Design of the in-memory working set

Implemented in [dart_microbench/workload_gen.h](dart_microbench/workload_gen.h)
as `dart_bench::WorkloadGenerator`. It produces two `records` vectors —
`load_records()` (the working set as pure inserts) and `run_records()` (the
measured mix) — that are **type-identical** to what `FileLoader` produces, so the
benchmark engine cannot tell the difference.

### 3.1 Spec (run-time knobs, no files)

```cpp
struct WorkloadSpec {
    uint64_t key_count;   // distinct keys = the working set
    uint64_t op_count;    // measured operations
    uint32_t read_pct, insert_pct, update_pct, scan_pct, remove_pct; // sum==100
    bool     uniform;     // true=uniform, false=zipfian
    double   theta;       // zipf skew (e.g. 0.99)
    uint32_t value_len;   // payload bytes for insert/update
    uint32_t scan_len;    // approx keys per range scan
    uint64_t seed;
};
```

### 3.2 Key construction (matches DART's int64-key format exactly)

- Key *i* of the working set = `scramble(i) = i * 0x9E3779B97F4A7C15` (an odd
  multiplier ⇒ a bijection on 2⁶⁴ ⇒ distinct, well-scattered keys — the role
  CityHash plays for DEX).
- Stored as an **8-byte big-endian** `u64` via `BufferBlock::add_u64` — byte
  order identical to `FileLoader::make_saving_from_strviw` for `user<n>` keys, so
  the tree's byte-wise comparisons give numeric ordering (range scans work).

### 3.3 Op encoding & distributions

- Op type chosen by cumulative percentage thresholds (`read → insert → update →
  scan → remove`).
- Key selection for read/update/scan/remove: **uniform** via
  `UniformRandom::next_uint64() % key_count` (`uniform.h`), or **zipfian** via
  `mehcached_zipf_next` over `[0, key_count)` (`zipf.h`, init with `theta`).
- **Inserts** use fresh keys `scramble(key_count + cursor++)` so they never
  collide with the loaded set (mirrors DEX reserving headroom in `kKeySpace`).
- **Scan**: `start = scramble(idx)`, `end = start + scan_width`, where
  `scan_width = (2⁶⁴ / key_count) * scan_len` so a range holds ~`scan_len` keys
  given the uniform scatter. `end` is stored as its own big-endian u64.
- **Value**: a single shared `value_len`-byte blob (content is irrelevant to
  index cost; sharing it keeps the buffer small). Inserts/updates point at it.

### 3.4 Record materialization (span-safety)

`BufferBlock` is a `vector<u8>` that reallocates on `push_back`, so — exactly like
`FileLoader` — the generator **appends all bytes first** (recording `key::save_t`
{offset,size}), then builds the `records` spans from the now-stable buffer. The
generator owns the buffer for its lifetime; build it on the main thread so spans
outlive every worker.

### 3.5 Load vs run = DART's two phases

DART already loads then runs (`compute.cc`: spawns `load_thread_num` workers over
`file_loader_load`, builds the skip table on CN 0, then spawns `run_thread_num`
workers over `file_loader_run`). The generator maps cleanly:
`load_records()` ↔ `*_load`, `run_records()` ↔ `*_run`. Per-thread sharding is the
same contiguous slicing `FileLoader::get_part_*` does.

---

## 4. Integration (minimal, surgical)

Full diffs in [dart_microbench/integration.md](dart_microbench/integration.md).
Two options:

- **Option A (recommended):** add one generic overload
  `Benchmark::prepare_workload(records::iterator begin, records::iterator end)`
  next to `prepare_workload_file`, build the generator once in `compute.cc::main`,
  and feed per-thread slices of `gen.load_records()` / `gen.run_records()`. Drop
  the `FileLoader::load_from_file` calls for the microbench path. Everything else
  (RDMA setup, skip table, timers, monitor handshake/aggregation) is unchanged.
- **Option B:** add a new `test_func` so YCSB and the microbench coexist; select
  with `--test_func`, and map `WorkloadSpec` onto existing monitor gflags
  (`--run_max_request`→`op_count`, `--payload_byte`→`value_len`,
  `--percent`→`read_pct`, `--epoch`→`theta*100`); add one `--key_count` flag.

No `CMakeLists.txt` change is needed — both new files are header-only. Add `test/`
to the include path (or use relative includes) so `dart_microbench/*.h` and
`../zipf.h` resolve.

---

## 5. Instrumentation (`bench_stats.h`) — the DEX-style report

[dart_microbench/bench_stats.h](dart_microbench/bench_stats.h) mirrors the DEX
harness's three artifacts, adapted to DART:

- **500 ns latency buckets**, per `(thread, op-type, class)`, cache-line aligned
  and lock-free; merged at report time into per-op `mean/p50/p99/p99.9`.
- **LOCAL vs REMOTE split** using the tree's thread-local `rtt`: snapshot `rtt`
  before an op and after; delta 0 ⇒ LOCAL (served from the cached/shortcut path,
  no network), delta > 0 ⇒ REMOTE. This is the direct DART equivalent of DEX
  snapshotting `num_rdma_*`.
- **rtt / op** (network amplification) and ops-local% (the effective cache/skip
  hit rate seen by real operations).

Usage is an RAII guard inside each registered lambda:

```cpp
auto search_it = [&](span key, str& r) {
    dart_bench::ScopedOp _t(ts, dart_bench::OP_READ);   // times + classifies
    prheart_tree.search(key);
};
...
dart_bench::Reporter::print(com_ind);   // once per node after the run joins
```

Everything compiles out when `BENCH_LATENCY` is undefined. Overhead is one
high-resolution clock pair + one `rtt` read per op — negligible against an RDMA
round trip, same caveat DEX notes.

> Note: this finer histogram is *additional* to DART's existing
> `counter::TimeCounter`, which already reports per-thread throughput/latency in
> microseconds and is what the monitor aggregates. The microbench leaves that
> path intact; `bench_stats.h` only adds the tail-latency + LOCAL/REMOTE detail.

---

## 6. Recipes

After applying Option A and (optionally) the instrumentation:

```shell
sudo sysctl -w vm.nr_hugepages=16384

# 1 MN, 1 CN, 56 threads, 6M ops. Set the WorkloadSpec in compute.cc (or map flags).
bin/monitor --test_func=0 --memory_num=1 --compute_num=1 \
            --load_thread_num=56 --run_thread_num=56 --coro_num=1 \
            --mem_mb=8192 --th_mb=10 --bucket=256 --run_max_request=6000000
bin/memory  --monitor_addr=127.0.0.1:9898
bin/compute --monitor_addr=127.0.0.1:9898
```

Mix presets to set in `WorkloadSpec` (parallels YCSB a–e and DEX's run.sh
presets):

| preset | read | insert | update | scan | remove | uniform/zipf |
|--------|-----:|-------:|-------:|-----:|-------:|--------------|
| read-only      | 100 | 0 | 0  | 0  | 0 | either |
| read-mostly    | 95  | 0 | 5  | 0  | 0 | zipf 0.99 |
| update-heavy   | 50  | 0 | 50 | 0  | 0 | zipf 0.99 |
| read-latest    | 95  | 5 | 0  | 0  | 0 | zipf 0.99 |
| scan-heavy     | 0   | 5 | 0  | 95 | 0 | uniform |
| insert-only    | 0   |100| 0  | 0  | 0 | uniform |

To sweep skew or working-set size, change the spec and re-run — no file
regeneration. (For a multi-spec sweep, drive it from a shell loop around the three
binaries, the way `script/` does for the file workloads.)

---

## 6A. Baseline directory-cache sweep (two-host, two-script)

The pre-wired sweep for **baseline DART** (no offloading — that concept is
DEX-only) lives in two companion scripts, one per host. Topology:

| host        | role                | script |
|-------------|---------------------|--------|
| `10.30.1.8` | monitor + compute   | [`script/cache_sweep_baseline.sh`](../script/cache_sweep_baseline.sh) |
| `10.30.1.6` | memory (node 0)     | [`script/cache_sweep_baseline_other.sh`](../script/cache_sweep_baseline_other.sh) |

The matrix is **directory cache ∈ {64,128,256,512} MiB** (total compute-side
cache; `--th_b = size·1MiB / threads`) × **dist ∈ {uniform, zipf-0.99}** ×
**op ∈ {100% lookup, 100% scan}** = **16 runs**, 30M measured ops each, over a
**50M-key working set** (`KEY_COUNT=50000000`, matched to DEX's `BULK=50`).

**Why two scripts, no SSH:** the monitor (on `.8`) owns *all* workload/sizing
flags and pushes them to both nodes at connect time, so the memory side carries
no config — it just relaunches the one-shot `bin/memory` 16 times. The monitor's
connect barrier blocks until *both* nodes dial in, so start order is irrelevant;
between configs the `.8` script restarts the monitor and the `.6` loop retries
`bin/memory` (detecting a real run via `ready.` in its log) until it reconnects.

### Steps

1. **Build on both hosts** at the same absolute path: `./build.sh` → `bin/{monitor,memory,compute}`.
2. **Hugepages on both:** `sudo sysctl -w vm.nr_hugepages=16384`.
3. **Set the NIC index** per host (from `ibv_devices`): `CMP_NIC` in the `.8`
   script, `MEM_NIC` in the `.6` script (both default `0`). Non-`1` IB port or
   RoCE GID needs the source edits in [RUNNING.md](../RUNNING.md) §5.
4. **Confirm** `ips[]` in [`src/main/compute.cc`](../src/main/compute.cc) lists
   the memory IP as `ips[0]` (already `10.30.1.6` — no rebuild for this topology).
5. **Keep the three sweep arrays identical** in both scripts
   (`CACHE_TOTAL_MB`/`DISTS`/`OPS`) so the iteration counts stay in lockstep.
6. **Launch** (either order works — whichever waits, waits):
   ```bash
   # on 10.30.1.6
   ./script/cache_sweep_baseline_other.sh
   # on 10.30.1.8
   ./script/cache_sweep_baseline.sh
   ```

### Output

Lands on **`10.30.1.8`** next to the repo root:
- `cache_sweep_baseline_<stamp>.csv` — full per-config row
  (`dist,op,cache_total_mb,th_bytes_per_thread,threads,key_count,op_count,throughput_mops,latency_us,bandwidth_gbps`).
- `cache_sweep_baseline_summary_<stamp>.csv` — condensed table
  (`dist,op,cache_mb,throughput_mops,latency_us,bandwidth_gbps`), re-parsed from
  every `monitor_*.log` at the end so partial/rerun sweeps still aggregate cleanly.
- `sweep_logs_baseline_<stamp>/` — per-run `monitor_*.log` / `compute_*.log`.

> The DART monitor reports `throughput`, `Average latency`, and `bandwidth` (these
> land in the CSV). DEX-style **per-op tail latency** is now wired in: the microbench
> RUN phase is instrumented with `dart_microbench/bench_stats.h` (`ScopedOp` around
> every op, `Reporter::print` after join), so each `compute_*.log` prints a
> `DART LATENCY BUCKETS` block with per-op **p50/p99/p99.9**, a **LOCAL/REMOTE**
> split, and **rtt/op** (the DART analog of DEX's `rdma_read/op`). It's always on
> for `test_func=1` (negligible overhead vs an RDMA round trip). There is no
> `offload`/`rpc` dimension: DART has no pushdown, so the DEX off/on split does not apply.

The `.6` side keeps its own `sweep_logs_baseline_memory_<stamp>/` with per-attempt
memory logs. Expected shape: throughput rises with cache size, more steeply under
zipfian (hot keys fit a small cache) than uniform.

---

## 7. Reading a run

- **Headline**: monitor prints `Total throughput = X MOps` and
  `Average latency = Y us` (sum/avg over CNs). Unchanged from today.
- **With `bench_stats.h`**, per node you also get:
  - `[OP] LOCAL … / REMOTE …` with `p50/p99/p99.9` — LOCAL p50 is the
    cached/shortcut path cost; REMOTE p50 is the RDMA round-trip cost; the ALL
    tail is driven by REMOTE.
  - `ops local (%)` — the effective hit rate of the cache + skip table; a high
    value under zipfian skew is the evidence the shortcut layer is keeping hot
    paths local.
  - `rtt / op` — network amplification; ~ the remote fraction for read-only,
    rising under write/SMO-heavy mixes.

---

## 8. File manifest

| path | role |
|------|------|
| `test/microbenchmarks.md`            | the DEX harness (reference) |
| `test/zipf.h`, `test/uniform.h`      | distribution generators (reused as-is) |
| `test/skills.md`                     | this document |
| `test/dart_microbench/workload_gen.h`| in-memory working-set generator |
| `test/dart_microbench/bench_stats.h` | 500 ns buckets + LOCAL/REMOTE via `rtt` |
| `test/dart_microbench/integration.md`| exact `compute.cc` / engine edits |
| `test/dart_microbench/README.md`     | quickstart |
| `script/cache_sweep_baseline.sh`     | baseline cache sweep — COMPUTE side (10.30.1.8) |
| `script/cache_sweep_baseline_other.sh`| baseline cache sweep — MEMORY side (10.30.1.6) |

Source touch-points (only if you apply integration):
`include/ycsb/ycsb-timecounter.hpp`, `src/ycsb/ycsb-timecounter.cc`,
`src/main/compute.cc` (and `src/main/monitor.cc` only for Option B's extra flag).
