# DART microbenchmark (in-memory working set)

A YCSB-free microbenchmark for DART, modeled on the DEX harness documented in
[../microbenchmarks.md](../microbenchmarks.md). Instead of downloading YCSB,
running its generator, and parsing `*_load` / `*_run` text files through
`YCSB::FileLoader`, this generates the **working set in memory** at startup using
the same distribution generators DEX uses (`../zipf.h`, `../uniform.h`).

See [../skills.md](../skills.md) for the full design and rationale.

## Files

| File              | Purpose |
|-------------------|---------|
| `workload_gen.h`  | header-only generator → `YCSB::FileLoader::records` (drop-in) |
| `bench_stats.h`   | 500 ns latency buckets + LOCAL/REMOTE split via the tree's `rtt` |
| `integration.md`  | exact edits to wire it into `compute.cc` |
| `README.md`       | this file |

## Quick mental model

```
WorkloadSpec ──► WorkloadGenerator ──► load_records()  (pure inserts = the working set)
                                  └──► run_records()   (read/insert/update/scan/remove mix)
                                          │
                                          ▼
                                  YCSB::Benchmark  ──► PrheartTree.{search,insert,update,scan,remove}
```

- **Working set** = `key_count` distinct keys, each `scramble(i) = i * golden64`
  stored big-endian (byte-wise tree order == numeric order), scattered like DEX's
  CityHash keys.
- **Load phase** inserts the whole working set (mirrors DART's existing
  load-then-run two-phase flow and the `*_load` file).
- **Run phase** is the measured `op_count` mix; key selection is **uniform** or
  **zipfian(theta)**. Inserts use fresh keys past the working set.

## Configure

Edit a `WorkloadSpec` (or map it from gflags — see `integration.md`):

```cpp
dart_bench::WorkloadSpec s;
s.key_count = 10'000'000;   // working set
s.op_count  = 6'000'000;    // measured ops (≈ --run_max_request)
s.read_pct = 95; s.update_pct = 5;
s.uniform = false; s.theta = 0.99;
s.value_len = 16;           // ≈ --payload_byte
dart_bench::WorkloadGenerator gen(s);
```

Mix presets (parallels DART's YCSB a–e):

| name | read | insert | update | scan | remove |
|------|-----:|-------:|-------:|-----:|-------:|
| A (update-heavy) | 50 | 0 | 50 | 0 | 0 |
| B (read-mostly)  | 95 | 0 |  5 | 0 | 0 |
| C (read-only)    |100 | 0 |  0 | 0 | 0 |
| D (read-latest)  | 95 | 5 |  0 | 0 | 0 |
| E (scan-heavy)   |  0 | 5 |  0 | 95| 0 |
| load (insert)    |  0 |100 |  0 | 0 | 0 |

## Build & run

The headers need no build-system change (header-only). After applying
`integration.md` to `compute.cc`:

```shell
cmake --build build
sudo sysctl -w vm.nr_hugepages=16384
bin/monitor  --test_func=0 --memory_num=1 --compute_num=1 \
             --load_thread_num=56 --run_thread_num=56 --coro_num=1 \
             --mem_mb=8192 --th_mb=10 --bucket=256 --run_max_request=6000000
bin/memory   --monitor_addr=127.0.0.1:9898
bin/compute  --monitor_addr=127.0.0.1:9898
```

Throughput/latency print exactly as today (monitor aggregates per-compute-node
`thp`/`lat`). With `bench_stats.h` enabled you additionally get the per-op
500 ns histogram and the LOCAL/REMOTE breakdown per node.
