# DEX: Scalable Range Indexing on Disaggregated Memory

## What's included

- DEX - Proposed distributed B+-Tree on disaggregated memory
- Benchmark framework

## Building

### Dependencies
1. We tested our build with Linux Kernel 6.3.2 and GCC 13.1.1.
2. Mellanox ConnectX-5 NICs
3. RDMA Driver: MLNX_OFED_LINUX-5**
4. memcached (to exchange QP information)
5. cityhash

### Compiling
Assuming to compile under a `build` directory:
```bash
git clone https://github.com/baotonglu/dex.git
cd dex
./script/hugepage.sh
mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=Release .. 
make -j
cp ../script/restartMemc.sh .
cp ../script/run*.sh .
cp ../script/sweep*.sh .
```

## Running benchmark

### Cluster layout (this setup)

| Server IP   | Node ID | Role                                   | What it runs            |
|-------------|---------|----------------------------------------|-------------------------|
| `10.30.1.9` | node 0  | memcached host **+** compute node      | `./run.sh`              |
| `10.30.1.6` | node 1  | memory node (serves pages over RDMA)   | `./run_other.sh`        |

Node IDs are handed out by memcached in **registration order**, so always start
node 0 (`10.30.1.9`) first. With the default config (`nodenum=2`,
`threads=2`, `kMaxThread=36`) the cluster has **one compute node and one memory
node**; raise the thread count past 36 to turn `10.30.1.6` into a second compute
node too.

### Step 0 — memcached config (already done)

`memcached.conf` (repo root) is read by both the benchmark and `restartMemc.sh`
as `../memcached.conf` from the `build/` directory. It must be identical on both
servers and point at the memcached host:

```
10.30.1.9      # line 1: memcached IP  (node 0)
11211          # line 2: memcached port
```

memcached is the out-of-band channel the nodes use to exchange RDMA queue-pair
info (LIDs/GIDs/rkeys) and to act as a cross-node barrier. It carries **no data**
traffic — that all goes over RDMA.

### Step 1 — build on *both* servers

Run these on `10.30.1.9` **and** `10.30.1.6` (each needs its own build):

```bash
git clone https://github.com/baotonglu/dex.git
cd dex
./script/hugepage.sh                       # reserve hugepages for RDMA buffers
mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=Release ..        # configure the build
make -j                                    # compile -> produces ./newbench
cp ../script/restartMemc.sh .              # memcached (re)starter
cp ../script/run*.sh .                     # run.sh + run_other.sh launchers
```

- `./script/hugepage.sh` runs `sysctl -w vm.nr_hugepages=62768` — DEX's RDMA
  buffers and DSM backing store are hugepage-backed; without this `mmap` fails.
- `make -j` builds every file in `test/` into an executable; the benchmark is
  `newbench`.

### Step 2 — make sure memcached can start (one-time check on node 0)

`restartMemc.sh` reaches the memcached host over SSH **on port 22** to (re)launch
memcached and zero the `serverNum`/`clientNum` counters:

```bash
ssh -p 22 10.30.1.9 "memcached -u root -l 10.30.1.9 -p 11211 -c 10000 -d -P /tmp/memcached.pid"
```

This requires passwordless SSH to `10.30.1.9` (port 22). If that isn't set up,
skip the script and start memcached manually on `10.30.1.9` once:

```bash
# on 10.30.1.9, start memcached bound to its own IP:
memcached -u root -l 10.30.1.9 -p 11211 -c 10000 -d -P /tmp/memcached.pid
# initialize the two registration counters the keeper expects:
printf 'set serverNum 0 0 1\r\n0\r\nquit\r\n' | nc 10.30.1.9 11211
printf 'set clientNum 0 0 1\r\n0\r\nquit\r\n' | nc 10.30.1.9 11211
```

### Step 3 — launch the run

**On node 0 (`10.30.1.9`) — start this first:**

```bash
cd dex/build
./run.sh
```

`run.sh` calls `./restartMemc.sh` (fresh memcached + cleared counters) and then
launches `newbench` as node 0. It blocks, prints live throughput every 2 s, and
at the end prints the latency/remote-op report.

**On node 1 (`10.30.1.6`) — start within a few seconds:**

```bash
cd dex/build
./run_other.sh
```

`run_other.sh` does **not** touch memcached (node 0 owns it); it just launches
`newbench` with the same arguments and registers as node 1. It sleeps ~10 s first
so node 0 wins the node-0 slot.

Both processes rendezvous through memcached, set up RDMA queue pairs, bulk-load
the tree, run warmup, then the measured phase. The run self-terminates (time- or
op-bounded) and joins at a final barrier.

### What the `newbench` command means

Both scripts invoke (default `op=0` = 100% lookup preset):

```bash
sudo ./newbench  2 100 0 0 0 0  2 4 256  0 0.99  50 10 50  0 1 1  0 1 0.1 0  36
#                 │  └ op mix ┘  │ │  │   │  │     │  │  │   │ │ │  │ │  │  │   └ kMaxThread (threads/compute node)
#                 │              │ │  │   │  │     │  │  │   │ │ │  │ │  │  └ auto_tune (0=off)
#                 │              │ │  │   │  │     │  │  │   │ │ │  │ │  └ admission_rate (DEX leaf-cache admission)
#                 │              │ │  │   │  │     │  │  │   │ │ │  │ └ rpc_rate (DEX pushdown ratio)
#                 │              │ │  │   │  │     │  │  │   │ │ │  └ index (0=DEX, 1=Sherman, 2=SMART)
#                 │              │ │  │   │  │     │  │  │   │ │ └ early_stop (1=first finisher stops the rest)
#                 │              │ │  │   │  │     │  │  │   │ └ time_based (1=cap phases by wall-clock)
#                 │              │ │  │   │  │     │  │  │   └ check_correctness (0=off)
#                 │              │ │  │   │  │     │  │  └ op_num  in millions (measured ops)
#                 │              │ │  │   │  │     │  └ warmup_num in millions
#                 │              │ │  │   │  │     └ bulk_load_num in millions (keys preloaded)
#                 │              │ │  │   │  └ zipfian_theta (skew; ignored if uniform=1)
#                 │              │ │  │   └ uniform_workload (0=Zipfian, 1=uniform)
#                 │              │ │  └ cache_size MB (per compute-node buffer cache)
#                 │              │ └ memThreadCount (directory/memory-side threads)
#                 │              └ totalThreadCount (worker threads across ALL compute nodes)
#                 └ kNodeCount (total machines = 2)
# op mix = kReadRatio kInsertRatio kUpdateRatio kDeleteRatio kRangeRatio  (must sum to 100)
```

So the default line means: 2 machines, **100% lookups**, 36 worker threads, 4
memory-side threads, 256 MB cache, Zipf 0.99 skew, bulk-load 50 M keys, 10 M
warmup ops, 50 M measured ops, DEX index, full RPC pushdown, 0.1 admission,
36 threads/compute-node. To change the workload, edit the clearly-named
variables at the top of `run.sh`/`run_other.sh` (`READ/INSERT/UPDATE/DELETE/
RANGE`, `CACHE_MB`, `RPC` for offloading, etc.) — **keep both scripts identical**.

### Cache-size sweep (`sweep.sh` / `sweep_other.sh`)

To sweep the compute-node cache across **32, 64, 128, 256, 512, 1024 MB** for
every combination of workload (100% lookup, 100% range), distribution (uniform,
zipfian 0.99) and offloading (RPC pushdown on/off) at **30 M ops each** — 48
configurations — use the sweep scripts. memcached is restarted before every
configuration so each run is a fresh distributed registration.

```bash
# node 0 (10.30.1.9) — start first:
./sweep.sh
# node 1 (10.30.1.6) — start right after:
./sweep_other.sh
```

`sweep.sh` restarts memcached and runs `newbench` for each config; `sweep_other.sh`
mirrors the same 48 configs (identical args, no memcached restart) and waits
`WAIT_FOR_MEMC` seconds per config for node 0's fresh memcached. Per-config logs
land in `build/results/dex_<workload>_<dist>_offload-<on|off>_cache<NN>mb.log`,
each ending with the latency-bucket / remote-op / path-aware-miss report. Edit
the parameter block at the top of `sweep.sh` (and mirror it in `sweep_other.sh`)
to change op count, thread count, bulk size, etc. If node 1 ever fails to
register, increase `WAIT_FOR_MEMC` in `sweep_other.sh`.

### Reading the results

When the measured phase ends, node 0 prints throughput plus the instrumentation
report (see `microbenchmarks.md` for full detail):

- `LATENCY BUCKETS (500 ns)` — per-op p50/p90/p99/p99.9/max, split into **LOCAL**
  (served from the path-aware cache, no network) vs **REMOTE** (≥1 RDMA/RPC), and
  the raw 500 ns bucket CDF.
- `REMOTE OPERATIONS` — local vs remote op fraction and the RDMA read/write/CAS/RPC
  breakdown.
- `PATH-AWARE CACHE MISSES` — inner-node vs leaf-node read misses.
- `Final throughput` (Mops/s).

### Quick troubleshooting

| Symptom | Fix |
|---------|-----|
| `can't open memcached.conf` | run `newbench` from `build/` (it reads `../memcached.conf`) |
| Hangs at `Build the DSMKeeper` / a barrier | memcached unreachable, wrong IP/port, or node 1 never started — both must register |
| `ssh` refused in `restartMemc.sh` | set up passwordless SSH to the memcached host (port 22), or start memcached manually (Step 2) |
| `ib device wasn't found` | NIC not named `mlx5_0`; adjust the device match in `src/rdma/Resource.cpp` |
| `mmap failed` | rerun `./script/hugepage.sh` (need enough hugepages) |
| Stale state across runs | `run.sh` re-runs `restartMemc.sh`; ensure it succeeds before node 1 starts |
