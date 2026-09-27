# REV runbook — what to build and run, per experiment

Covers DEX, CHIME and DART as they stand on branch `chime-leaf-cache` (HEAD `bded65a`
plus the uncommitted edits listed in §0.6). Every claim below was read from the code;
file:line references are to this checkout. Nothing here has been run yet — the cluster
is the only place any of it builds.

Legend for experiment status:

| Tag | Meaning |
|---|---|
| **READY** | Runs with the current code; at most a script variable to set |
| **EDIT** | Needs a script edit (no C++ change) |
| **FIX** | Needs a C++ change first (listed in §5) |
| **BLOCKED** | The system cannot do this today; results would be meaningless |

---

## 0. Do these before running anything

### 0.1 Revoke the GitHub token in `dex/note`
`dex/note:30` holds a `ghp_…` personal access token, and the file is tracked in git
(last touched by commit `5c14068`). Revoke it on GitHub now; removing it from the file
does not remove it from history.

### 0.2 Settle the topology — the three systems disagree

| System | What the repo assumes | Where |
|---|---|---|
| CHIME | memory node **10.30.1.8** (node 0, runs memcached), compute **10.30.1.6** | `CHIME/run/bench_common.sh:29-30`, `CHIME/memcached.conf` |
| DEX | node 0 = compute + memcached = **10.30.1.7**, node 1 = memory = **10.30.1.6** | `dex/memcached.conf`, `dex/README.md` |
| DART | monitor + compute on **10.30.1.7**, memory on **10.30.1.6**; `ips[0]` = `10.30.1.6` | `DART/script/cache_sweep_baseline*.sh:35,44`, `DART/src/main/compute.cc:41` |

Pick one pair of live hosts and use it for all three. Below, `$MEM` is the memory host
and `$CMP` the compute host. What each system needs set:

- **CHIME**: `MEM_IP=$MEM CMP_IP=$CMP` in the environment (scripts rewrite `memcached.conf` per cell).
- **DEX**: `dex/memcached.conf` = the host that runs `sweep.sh` (node 0). In DEX, node 0 is
  whichever process registers first, and with `THREADS == KMAX` node 0 is the **compute**
  node. So put `$CMP` in `dex/memcached.conf` and run `sweep.sh` on `$CMP`, `sweep_other.sh` on `$MEM`.
- **DART**: `ips[0]` in `DART/src/main/compute.cc:41` = `$MEM` (rebuild `compute`);
  `MONITOR_DIAL` in `DART/script/cache_sweep_baseline_other.sh:35` = `$CMP:9898`.

### 0.3 Know what "DEX memory-node execution" actually is
With 2 machines, `DSM::get_random_id` (`dex/include/DSM.h:132-143`) always picks the
*other* node, so tree levels alternate between the compute node and the memory node
(`leanstore_tree.h:194,640`; logs show roots at `[0,…]` then `[1,…]`). The compute node
also runs directory threads and serves RPCs: in
`dex/build/results/qload/dex_lookup_uniform_offload-on_cache64mb_mt6.log` the compute node's
dir threads reach **112% aggregate active**.

Consequences: part of the "remote" traffic is RDMA loopback, roughly half the pushdowns
run on compute-node cores, and `remote_load_memthreads.csv` (memory node only) undercounts
memory-side work. **Decide before re-running DEX:**

- **Keep and disclose** — reuse all existing DEX data; say in the paper that DEX spreads
  nodes over both machines and report dir-thread load from both.
- **Fix and re-run** — restrict allocation to the memory node (F-D4 in §5). Every DEX
  number in the paper changes, and DEX-vs-DART becomes fair.

### 0.4 Thread counts
- DEX paper data (`dex/build/results/summary.csv`) ran at **36** compute threads.
  Every current DEX sweep script says **32** (`dex/build/sweep.sh:26-27` and siblings);
  `paper/make_figures.py:12` also says 32. Use **36** to stay comparable.
- CHIME runs the same binary on both nodes, each with `THREADS` client threads, so
  `THREADS=34` = **68** clients (`micro_test.cpp:602`, no node-0 guard).
- DART: compute script `THREADS_SET=(34 36)` (`cache_sweep_baseline.sh:62`) but memory
  script `(32)` (`cache_sweep_baseline_other.sh:53`). As committed they desync and hang.

### 0.5 Do not overwrite the paper's data
`dex/build/sweep.sh:51,108` writes `./results/*.log` with `tee` and truncates
`./results/summary.csv`, which is the exact file `paper/make_figures.py:144,188,286,339`
reads. Every DEX command below uses a new `RESULTS` directory. CHIME and DART write
timestamped/`SEQ_TS` directories and are safe, but CHIME's resume key ignores
`MIN_LEVEL`, `ADMIT`, `PCT` and `SCAN_RANGE` (`run_leaf_study.sh:133-138`), so give every
variant its own `SEQ_TS`.

### 0.6 Uncommitted changes — commit or stash, then deploy identically to both nodes

| File | Change | Needed for |
|---|---|---|
| `dex/include/Common.h` | `NR_DIRECTORY` 8 → 16 | memThreads sweep above 8 only |
| `dex/src/Directory.cpp` | dir-thread pinning `39-dirID` → `ncpu-1-dirID` | machines with < 40 cores; changes cores vs all existing DEX logs |
| `dex/build/sweep*.sh` | `CACHES`/`MEMTHREADS`/`MEMTHREAD_SET` env, 32–1024 default, preflight, `SKIP_EXISTING` | convenience; **defaults changed to 32–1024** |
| `CHIME/include/Common.h` | `NR_DIRECTORY` 8 → 16 | dir sweep above 8 only |
| `CHIME/src/Directory.cpp` | dir-thread pinning odd → even cores | perf only; breaks `micro_test`'s `[CORES] OVERLAP` check; leafstudy2 used odd |
| `CHIME/run/run_leaf_study.sh` | `PROFILE`, `DIR_SET`, preflight `2*THREADS+2*DIR <= nproc` | preflight needs ≥ 76 CPUs at T=34 or `FORCE_CORES=1` |
| `CHIME/run/bench_common.sh` | `DIR_SUBDIR=1` log layout | dir sweep only |

For **exact reproductions**, stash these on the cluster. For **new experiments**, commit
them and push the same commit to both nodes. Both nodes must build from the same source:
`NR_DIRECTORY`, `MAX_APP_THREAD`, page/leaf geometry and the offload flags are all baked
into the QP exchange or on-wire layout.

---

## 1. One-time node setup (both nodes, all systems)

```bash
ulimit -l unlimited                         # or run as root; DART's RACE server pins 10 GiB
sudo sysctl -w vm.nr_hugepages=62768        # ~122 GB. DEX needs 64 GB DSM + 2 GB buf + cache;
                                            # CHIME needs 64 GB DSM + 4 GB buf on EVERY node
grep Huge /proc/meminfo
nproc; lscpu -e | head                      # needed for the pinning checks below
```

Libraries: DEX and CHIME need cityhash, boost_coroutine/context, ibverbs, libmemcached,
tbb, numa (CHIME: `script/installLibs.sh`); DEX also needs gperftools headers
(`dex/src/Directory.cpp:8`). DART needs rdma-core, `libboost-context-dev`,
`libboost-coroutine-dev`, g++ with C++20. `memcached` must be installed on the node-0 host
for DEX and on `$MEM` for CHIME. DART uses no memcached.

Use a Linux `git clone`, not files copied from Windows: the scripts are CRLF in this
checkout.

---

## 2. Builds

### 2.1 DEX (both nodes, separately — `-march=native`)
```bash
cd ~/REV/dex/build
rm -rf CMakeCache.txt CMakeFiles           # committed cache hard-codes /home/apa222 paths
cmake -DCMAKE_BUILD_TYPE=Release -DMANUAL_PUSHDOWN=ON ..
make clean && make -j                      # -> ./newbench
grep -q MANUAL_PUSHDOWN CMakeFiles/newbench.dir/flags.make && echo OK-manual
```
- Do **not** `rm -rf build`: the newest scripts (`sweep*.sh`, `cache_sweep_qload*.sh`) live only there.
- `CMAKE_BUILD_TYPE` must be given (`dex/CMakeLists.txt:20` fails otherwise). Asserts stay on (`-UNDEBUG`, line 7).
- Without `-DMANUAL_PUSHDOWN=ON`, `LATENCY_COLLECT` overrides `rpc_rate`
  (`leanstore_cache.h:51-53,809-884`) and "offload off/on" is not what you think. The log
  does not print the build mode — check `flags.make`.

### 2.2 CHIME (both nodes, identical flags)
```bash
cd ~/REV/CHIME/run && ./configure_nic.sh    # patches include/Rdma.h NIC macros per node
cd .. && rm -rf build && mkdir build && cd build
cmake -DENABLE_OFFLOAD=ON -DCACHE_LEAF_NODE=ON -DCHIME_VALUE_LEN=16 ..
make -j micro_test
```
- `CACHE_LEAF_NODE`, `CHIME_VALUE_LEN`, `CHIME_INTERNAL_SPAN`, `NR_DIRECTORY`,
  `ENABLE_OFFLOAD` must match on both nodes (they change `allocationLeafSize`,
  `Common.h:322-323`, or the RPC handlers).
- No build type → asserts are live. That matters for writes (F-C4).
- No MLNX experimental verbs needed; masked CAS is emulated (`DSM.cpp:642-675`).
- The `build_span_*` directories in the repo are stale July builds (48 B values, no leaf
  cache, pre-warmup-fix). Never reuse them with `REBUILD=0`.

### 2.3 DART (both nodes)
```bash
cd ~/REV/DART
# submodules are broken in the REV checkout (no root .gitmodules; SSH URLs):
rmdir gflags magic_enum 2>/dev/null
git clone https://github.com/gflags/gflags.git gflags && git -C gflags checkout 5319350323577cff4c42ab59118531d04f13edf4
git clone https://github.com/Neargye/magic_enum.git magic_enum && git -C magic_enum checkout b233b96e49d371bad00300f59b5ba581100b8745
# set ips[0] = $MEM in src/main/compute.cc:41 first
cmake -B build -DCMAKE_CXX_FLAGS=-O3 && cmake --build build -j   # -> bin/{monitor,compute,memory}
```
- `build.sh` builds with **no optimisation** (`CMakeLists.txt:57` only adds `-g`); DEX and
  CHIME use -O3. Unknown which the committed DART CSVs used. Use `-O3`.
- Don't use `-DCMAKE_BUILD_TYPE=Release`: `-DNDEBUG` removes the op-mix-sums-to-100 check
  and any shortfall silently becomes deletes (`workload_gen.h:84-86,112-155`).
- `DART/test/newbench.cpp` is DEX's harness copied over; it is not built and not DART's benchmark.

---

## 3. Experiments

### Index

| ID | Experiment | Status | Cells | Time |
|---|---|---|---:|---|
| **C0** | CHIME leafstudy2 correctness check from existing logs | **READY** (no run) | 0 | minutes |
| **D1** | DEX: reproduce `summary.csv` at 36 threads | **EDIT** | 32 | ~1.6 h |
| **D2** | DEX: `rpc_rate` sweep | **EDIT** | 28–56 | 1.5–3 h |
| **D3** | DEX: memThreadCount × offload | **EDIT** | 96+ | ~5 h |
| **D4** | DEX: scan length {10,100,1000} | **FIX** F-D1..3 | 24 | ~1.2 h |
| **D5** | DEX: write mixes | **EDIT**, caveats | 16+ | ~1 h |
| **D6** | DEX harness: Sherman / SMART | **READY**, untested | — | — |
| **C1** | CHIME: reproduce leafstudy2 | **READY** | 64 | ~6.5 h |
| **C2** | CHIME: `LEAF_ADMIT_SCAN=0.1` | **READY** | 16 | ~1.6 h |
| **C3** | CHIME: 16–512 MB in one configuration | **READY**, slow | +32 | 5 h+ |
| **C4** | CHIME: `CHIME_OFFLOAD_MIN_LEVEL` {1,3} | **READY** | 32 | ~3 h |
| **C5** | CHIME: `LEAF_CACHE_PCT` {25,75} | **FIX** F-C3 (or pick MB) | 32 | ~3 h |
| **C6** | CHIME: scan length {10,1000} | **FIX** F-C1 | 16–32 | 2 h+ |
| **C7** | CHIME: batching without the leaf cache | **FIX** F-C5 | 8–16 | ~1.5 h |
| **C8** | CHIME: write mixes | **FIX** F-C4, F-C6..8 | — | — |
| **C9** | CHIME: scan path fixes (DEX+-style scans) × memory-node threads {4,8,16} | **FIX** F-C10..13 | 12 | ~1.5 h |
| **R1** | DART: point lookups, matched | **EDIT** | 8 | short |
| **R2** | DART: range scans | **BLOCKED** (F-R1) | — | — |
| **R3** | DART: write mixes / deletes | **BLOCKED** (F-R2..4) | — | — |

Time estimates: DEX ~3 min/cell (time-based; `qload_node0.out` shows 64 cells in 3 h 04 m);
CHIME ~6 min/cell, much longer for stressed range cells with offload off (0.047 Mops →
~11 min of measurement alone). DART per-cell time is not recorded anywhere; measure it on R1.

---

### C0 — CHIME: correctness check owed on leafstudy2 (no run)

`[CORRECTNESS]` lines are only in the per-node logs (`micro_test.cpp:679-682`), never in a
CSV, and leafstudy2's committed CSV has lost the log path. On **each** node:

```bash
cd ~/REV/CHIME/build/results/leaf_cache/sweep_<leafstudy2 SEQ_TS>
for f in cache_*MB/leaf_*/*/*/*.log; do
  echo "$f $(grep -h '^\[CORRECTNESS' "$f" | tr '\n' ' ') \
$(grep -h '^\[LEAFCACHE\] hit=' "$f" | tail -1 | grep -o 'stale=[0-9]*\|admit_pct=[0-9.]*')"
done
```

Pass if: lookup found ≈ **99.998%** (1000 of 50,001,000 keys are never loaded;
`LEAF_CACHE_RESULTS.md` says 0.0100%, which is an arithmetic slip); leaf_0 vs leaf_1 agree
to ~4 significant figures (not exactly: key streams are `rdtsc`-seeded,
`micro_test.cpp:129,132`); scan rows ≈ ops × 100; `stale=0`. `admit_pct=` present proves
the row came from the post-batching binary (`15070de`).

This check cannot catch a wrong value or wrong key, only found/not-found (see F-C2, F-C7).

---

### D1 — DEX: reproduce `summary.csv` (36 threads, 4 mem threads, 64–512 MB)

On both nodes, in `dex/build`, edit the copies (don't touch the originals):
```bash
cp sweep.sh sweep36.sh; cp sweep_other.sh sweep36_other.sh
sed -i 's/^THREADS=32/THREADS=36/; s/^KMAX=32/KMAX=36/; s#^RESULTS=./results#RESULTS=./results_repro36#' sweep36.sh sweep36_other.sh
```
Run (node 0 = `$CMP`, the host in `dex/memcached.conf`, first):
```bash
# $CMP
MEMTHREADS=4 CACHES="64 128 256 512" ./sweep36.sh
# $MEM, immediately after
MEMTHREADS=4 CACHES="64 128 256 512" ./sweep36_other.sh
```
- Output: `results_repro36/dex_<lookup|range>_<uniform|zipfian>_offload-<off|on>_cache<N>mb.log`
  and `results_repro36/summary.csv` (`workload,dist,offload,cache_mb,throughput_mops,p99_us,rdma_read_per_op,rpc_per_op`).
- Check each log: `kMaxThread = 36`, `I am servers 0` on `$CMP`, and `entering dynamic phase`
  appears (offload only starts once the cache is full: `leanstore_cache.h:561,712,775`).
- Byte-faithful to the June 15 binary would also need `NR_DIRECTORY=4` and the old pinning;
  HEAD only adds instrumentation (miss counters, remote load, CPU sampler), not algorithm changes.
- The miss counters now work (commit `dbb5001`), so these logs will show non-zero
  `PATH-AWARE CACHE MISS RATE`. They are **not comparable between offload off and on**:
  with offload on, traversal stops at the first missed level.
- If you chose "fix and re-run" in §0.3, apply F-D4 first; this is then the new baseline.

### D2 — DEX: `rpc_rate` sweep

No script sweeps it; `sweep.sh` hard-codes rpc 0/1. Make `sweep_rpc36.sh` /
`sweep_rpc36_other.sh` from the `sweep36*` copies and, in **both** files, change the offload
loop in the run section (and, in `sweep_rpc36.sh`, the one in the summary section) from
```bash
for off in off on; do
  if [ "$off" = on ]; then rpc=1; else rpc=0; fi
```
to
```bash
for rpc in ${RPC_SET:-0 0.1 0.25 0.5 0.75 1}; do
  off="rpc${rpc}"
```
The tag becomes `dex_<wl>_<dist>_offload-rpc<r>_cache<N>mb`. Then:
```bash
sed -i 's#^RESULTS=.*#RESULTS=./results_rpc36#' sweep_rpc36.sh sweep_rpc36_other.sh
RPC_SET="0 0.1 0.25 0.5 0.75 1" MEMTHREADS=4 CACHES="64 512" ./sweep_rpc36.sh        # $CMP
RPC_SET="0 0.1 0.25 0.5 0.75 1" MEMTHREADS=4 CACHES="64 512" ./sweep_rpc36_other.sh  # $MEM
```
- 4 combos × 6 rates × 2 caches = 48 cells, ~2.4 h.
- **`rpc_rate` is not the fraction of operations offloaded.** The coin is flipped once per
  missed eligible level (level 1: `leanstore_cache.h:712,775`; levels 2–4, non-shared:
  `:885-893`), so P(op offloaded) = 1−(1−r)^k. Scans only offload at level 1
  (`leanstore_tree.h:2038-2068`). Plot against measured `rpc_per_op`, not `r`.
- Don't use `auto_tune=1` for this: its final `Avg. rdma …/op` divides the last round's
  counters by every round's ops (`newbench.cpp:234,398` vs `1151-1181`).

### D3 — DEX: memThreadCount × offload

1. Set `NR_DIRECTORY` ≥ max(`MEMTHREAD_SET`) in `dex/include/Common.h` on **both** nodes and
   rebuild both (the uncommitted 16 covers up to 16).
2. In `build/sweep_memthreads.sh:56-57` and `build/sweep_memthreads_other.sh:23-24` set
   `THREADS=36 KMAX=36`; set a new `RESULTS` directory in both. The committed
   `summary_memthreads.csv` is 32 threads and partial (mt=6 range/zipf/on at 128–512 MB and
   every mt=8 cell died right after `KeySpace`).
3. Run:
```bash
MEMTHREAD_SET="2 4 8 16" CACHES="64 256 512" ./sweep_memthreads.sh         # $CMP
MEMTHREAD_SET="2 4 8 16" CACHES="64 256 512" ./sweep_memthreads_other.sh   # $MEM
```
- Output: `$CMP` writes `summary_memthreads.csv`; `$MEM` writes `remote_load_memthreads.csv`
  (peak aggregate / per-thread active %). **Because of §0.3, also grep
  `AGGREGATE active` from the `$CMP` logs** — the compute node serves part of the RPCs and
  nothing summarizes it.
- `SKIP_EXISTING` uses different tests on the two nodes (`sweep_memthreads.sh:142` vs
  `_other.sh:65`); after a crash, clear the half-finished cell's logs on both before resuming.
- Needs `THREADS + memThreads ≤ cores` on `$CMP`; check `lscpu -e`.

### D4 — DEX: scan length {10, 100, 1000}  (FIX first)

Apply F-D1, F-D2, F-D3 (§5), rebuild both nodes. Then copy `sweep36*.sh` to
`sweep_scan*.sh`, keep only the two `range` combos, add an outer `for SL in 10 100 1000`
that passes the length (argv or env — note `sudo` drops env, so use `sudo SCAN_LEN=$SL ./newbench …`
or an argv slot), and put `_scan${SL}` in the tag. Use `RESULTS=./results_scan36`,
`CACHES="64 512"`. 2 combos × 2 offload × 2 caches × 3 lengths = 24 cells.

### D5 — DEX: write mixes

`newbench` supports insert/update/delete; the sweep scripts hard-code
`"$r" 0 0 0 "$rg"` (`build/sweep.sh:77`). In a copy, replace the combo list with explicit
tuples for args 2–6 (read insert update delete range):

| Mix | args 2–6 |
|---|---|
| read/update 50/50 | `50 0 50 0 0` |
| read/insert 50/50 | `50 50 0 0 0` |
| reads + deletes | `90 0 0 10 0` (pick the ratio; none is specified anywhere) |
| scan-heavy + 5% inserts | `0 5 0 0 95` |

and replace the p99 awk (`sweep.sh:116` takes the first `p99=`, i.e. the LOOKUP row) with
the `[ALL OPS]` row, as `cache_sweep_qload.sh:135` does.

**Read the results with these limits:**
- Insert keys are drawn from the whole keyspace, not fresh (`newbench.cpp:832-833`); at 50%
  inserts ~37.5% of lookups initially hit absent keys and many inserts are upserts.
- Writes are pushed down only at levels 2–4; a level-1 write is a one-sided
  read-modify-write of the leaf (`leanstore_tree.h:1690-1699,2174-2183,2377-2387`). So
  "offload on" barely changes the write path. The MN handlers take no locks (`btree_rpc.h:44-131`).
- Scan pushdown can read sibling leaves that are dirty in the compute node's write-back
  cache (`btree_rpc.h:185-191`, `leanstore_cache.h:262-264`) — stale scan results in
  scan+insert mixes. `BTreeLeaf::range_scan` needs an exact start-key match
  (`btree_node.h:273-282`), which distorts scans once keys are missing.
- No correctness check unless you uncomment `CHECK_CORRECTNESS` (`newbench.cpp:33`); it then
  looks up every key single-threaded after the run and runs `tree->validate()`.

### D6 — Sherman / SMART in the DEX harness
Same binary; argument 18 = 1 (Sherman) or 2 (SMART); args 19–20 ignored; no offload.
Never run in this harness (no logs). Sherman's `range_scan(num)` is a key-range width, not a
count. SMART's `remove()` is a no-op that returns true (`smart_wrapper.h`), so delete mixes
are invalid. Both also allocate across both nodes.

---

### C1 — CHIME: reproduce leafstudy2

leafstudy2 came from `run_leaf_study.sh` with an explicit 4-point cache list at the
`15070de` code (HEAD's CHIME code is identical to `15070de`). Stash the uncommitted CHIME
edits (§0.6) for an exact reproduction.

```bash
# $MEM first, then $CMP; identical env on both
cd ~/REV/CHIME/run
MEM_IP=$MEM CMP_IP=$CMP SEQ_TS=leafstudy2_repro CACHE_MB="512 256 128 64" THREADS=34 ./run_leaf_study.sh memory
MEM_IP=$MEM CMP_IP=$CMP SEQ_TS=leafstudy2_repro CACHE_MB="512 256 128 64" THREADS=34 ./run_leaf_study.sh compute
```
(With the uncommitted script: add `DIR_SET=4`, and `FORCE_CORES=1` if `nproc < 76`.)

- Defaults: `BULK=50 WARMUP=10 POINT_OP=30 RANGE_OP=30 SCAN_RANGE=100 LEAF_PCT=50 DIR_THREADS=4`.
  Resumable; stops at the first failed cell. No per-cell timeout.
- Output: `CHIME/build/results/leaf_cache/sweep_leafstudy2_repro/summary_{memory,compute}.csv`
  (`cache_mb,dir_threads,workload,offload,role,node_tput_mops,ops,p99_us,index_mb,cache_leaf,total_cache_mb,inner_cache_mb,leaf_cache_mb,leaf_hit_pct,log`).
  Throughput and p99 are **per node**. Keep the `log` column this time.
- Plot: copy the memory CSV next to the compute one, then
  `python3 results/plot_leaf_cache.py <sweep dir>` (sums nodes). `paper/make_figures.py:86`
  reads `CHIME/results/leafstudy2_compute.csv` (compute node only).
- Then run C0 on the new logs.

### C2 — CHIME: `LEAF_ADMIT_SCAN=0.1` on range cells
Use the **script** variable `LEAF_ADMIT_SCAN`; `bench_common.sh:284` overrides any exported
`CHIME_LEAF_ADMIT_SCAN`. `THREADS=34` is mandatory — `run_leaf_cache.sh` inherits a default
of 24 (`bench_common.sh:39`).
```bash
MEM_IP=$MEM CMP_IP=$CMP SEQ_TS=admit01 THREADS=34 CACHE_MB="512 256 128 64" \
  WORKLOADS="range-uniform range-zipf" SEQUENCE="off on" LEAF_SET=1 LEAF_ADMIT_SCAN=0.1 \
  BULK=50 WARMUP=10 POINT_OP=30 RANGE_OP=30 ./run_leaf_cache.sh memory     # then: compute
```
Check `admit_pct≈10` in `[LEAFCACHE]`. Compare against leafstudy2's `leaf_1` range rows.

### C3 — CHIME: 16–512 MB in one configuration
Resume the C1 sweep with more points (same `SEQ_TS` → the 64 existing rows are skipped):
```bash
MEM_IP=$MEM CMP_IP=$CMP SEQ_TS=leafstudy2_repro CACHE_MB="512 256 128 64 32 16" THREADS=34 ./run_leaf_study.sh <role>
```
- Range cells with offload off at 32/16 MB can take tens of minutes each.
- Report the **real** inner cache: with the leaf cache off, TreeCache = nominal − 30 MB when
  nominal > 50 (`Tree.cpp:125`), so total 64 → 34 MB; total 32 → 32 MB. Those two points are
  nearly the same inner cache.
- Extend `paper/make_figures.py:103`'s hard-coded x list to plot them.
- **Do not splice** with `CHIME/results/stress/summary_compute.csv` (24 threads, 48 B values,
  50 M ops, before the warmup fix `6aef59b`).

### C4 — CHIME: `CHIME_OFFLOAD_MIN_LEVEL` {1, 3}
Level 2 is leafstudy2. The variable passes through `env`:
```bash
export CHIME_OFFLOAD_MIN_LEVEL=3          # on BOTH nodes; then 1 with a new SEQ_TS
MEM_IP=$MEM CMP_IP=$CMP SEQ_TS=minlvl3 THREADS=34 CACHE_MB="512 256 128 64" \
  WORKLOADS="point-uniform point-zipf" SEQUENCE=on LEAF_SET="0 1" \
  BULK=50 WARMUP=10 POINT_OP=30 RANGE_OP=30 ./run_leaf_cache.sh <role>
```
- Verify on `$MEM`: `[CONFIG] offload rate = 100%, min cache-boundary level = N`
  (`micro_test.cpp:545-550`). The level is not in the CSV — the `SEQ_TS` is the only record.
- Point path only; range offload gates on coverage (`Tree.cpp:2403-2408,2464-2465`).
- At level 1 every lookup is offloaded and the leaf cache is never used (`micro_test.cpp:558-560`).
- `CACHE_MORE_INTERNAL_NODE` is **ON** (`CMakeLists.txt:168`), so the cache holds inner
  nodes of every level, not only level 1. A partial hit can return a level-2+ node and pass
  the level-2 gate. CHIME.md §2.3's "a cache hit cannot pass the gate" is not true of this build.

### C5 — CHIME: `LEAF_CACHE_PCT` {25, 75}  (FIX F-C3, or choose sizes by hand)
`LeafCache` rounds its set count **down** to a power of two (`LeafCache.h:254-259`): the 50%
arm keeps ~94% of its nominal budget, the 75% arm only 62.5% — e.g. 192 MB nominal leaf =
120 MB effective, the same as the 50% arm. Either apply F-C3, or run with
`LEAF_CACHE_MB` values that land on power-of-two capacities and read the effective size from
the `[LeafCache]: budget=… sets x … ways` line. Then:
```bash
MEM_IP=$MEM CMP_IP=$CMP SEQ_TS=pct25 THREADS=34 CACHE_MB="512 256 128 64" LEAF_SET=1 \
  LEAF_CACHE_PCT=25 BULK=50 WARMUP=10 POINT_OP=30 RANGE_OP=30 ./run_leaf_cache.sh <role>
```
(In `run_leaf_study.sh` the variable is `LEAF_PCT`; it overwrites `LEAF_CACHE_PCT`.)
Note an exported `CHIME_LEAF_CACHE_MB` silently wins over the percentage (`micro_test.cpp:435`).

### C6 — CHIME: scan length {10, 1000}  (FIX F-C1 for 1000)
`micro_test.cpp:216` does `k + (uint8_t)scan_range`: 1000 becomes 232, 256 becomes 0.
After F-C1:
```bash
MEM_IP=$MEM CMP_IP=$CMP SEQ_TS=scan1000 SCAN_RANGE=1000 RANGE_OP=5 THREADS=34 \
  CACHE_MB="512 64" WORKLOADS="range-uniform range-zipf" SEQUENCE="off on" LEAF_SET="0 1" \
  BULK=50 WARMUP=10 ./run_leaf_cache.sh <role>
```
Keep `RANGE_OP` the same across every length you compare. Offloaded scans handle 1000
(512-pair cap per RPC with a resume loop, `Tree.cpp:1921-1941`).

### C7 — CHIME: batching without the leaf cache  (FIX F-C5)
The two-batch covered-leaf path only runs inside `if (leaf_cache)` (`Tree.cpp:2520`); with
the leaf cache off, leaves are read one at a time (`Tree.cpp:2663-2714`). This is the
experiment that separates "batching" from "leaf caching" in the +19% / −21% result. After
F-C5:
```bash
export CHIME_RANGE_BATCH_NOCACHE=1        # both nodes
MEM_IP=$MEM CMP_IP=$CMP SEQ_TS=batch_nocache THREADS=34 CACHE_MB="512 256" \
  WORKLOADS="range-uniform range-zipf" SEQUENCE=off LEAF_SET=0 \
  BULK=50 WARMUP=10 RANGE_OP=30 ./run_leaf_cache.sh <role>
```
Zero-code approximation (range cells only): `LEAF_SET=1 LEAF_CACHE_MB=1 LEAF_ADMIT_SCAN=0
LEAF_ADMIT_POINT=0` — nothing is admitted, so every covered leaf goes through phase 2. But
it disables the hotspot buffer and costs 1 MB of inner cache.

Upstream CHIME's own batched range path (`CHIME_RANGE_BATCHED`, any value including `0`
turns it on, `Tree.cpp:2372`) is the one that crashed on rdma-core (unbounded
`goto re_read`, heap corruption). Only try it in an `ENABLE_ASAN` build.

### C8 — CHIME: write mixes  (FIX first)
Not runnable today:
- `bench_common.sh:104-112` only knows the four read-only workloads; add cases for the mixes.
- An update of a missing key aborts: `assert(j != neighborSize)` at `Tree.cpp:1704` is live
  and ~1000 keys are never loaded (F-C4).
- "Inserts" are mostly upserts (random draws over the enlarged keyspace, `micro_test.cpp:172`).
- No delete op anywhere (`micro_test.cpp:88`, `Tree.h`/`Tree.cpp`) (F-C8).
- No value verification: values come from a shared unsynchronized RNG (`micro_test.cpp:115,207-208`) (F-C7).
- Scans trust cached level-1 fences and never re-search on a split (`Tree.cpp:2520-2714`) — rows can go missing.
The stamp path **does** fire on writes (`Tree.cpp:323-332`), so `stale=` becomes meaningful —
the first time the coherence protocol is exercised.

---

### R1 — DART: point lookups, matched to DEX/CHIME

**What DART in this repo is:** no compute-side cache (the per-thread `th_b` buffer is a
scratch buffer; every read lands at its start, `art-node.cc:539`; `local_end_ptr` is never
read). The "cache sweep" is four repeats of the same run — the committed 34/36-thread
curves are flat within ~3%. Treat DART as **one flat line** with error bars, not a curve.

Edits:
1. `DART/src/main/compute.cc:41`: `ips[0] = "$MEM"`; rebuild `compute`.
2. `DART/script/cache_sweep_baseline.sh:62` **and** `cache_sweep_baseline_other.sh:53`:
   the same `THREADS_SET`, e.g. `(36)` to match DEX. (Mismatched sets hang the sweep at
   config 17.)
3. `cache_sweep_baseline.sh:76` and `_other.sh:49`: `OPS=(lookup)` (scans are not valid, R2).
4. `_other.sh:35` `MONITOR_DIAL=$CMP:9898`; set `CMP_NIC` (`baseline.sh:46`) and `MEM_NIC` (`_other.sh:37`).
5. Value size: DEX values are 8 B (`dex/include/Common.h:165`); CHIME's 16 B slot holds an
   8 B real value (`LeafNode.h:40-44`). Set `VALUE_LEN=8` (`baseline.sh:68`) to match both.
   (8+8 is safe from the leaf over-write bug at `art-node.cc:1259-1270`.)
6. Passwordless `sudo` on `$CMP` (monitor and compute run under sudo in the background).

Run (either order):
```bash
# $CMP
cd ~/REV/DART && ./script/cache_sweep_baseline.sh
# $MEM
cd ~/REV/DART && ./script/cache_sweep_baseline_other.sh
```
- Output on `$CMP`: `cache_sweep_baseline_<stamp>.csv` and `cache_sweep_baseline_summary_<stamp>.csv`
  (`dist,op,cache_mb,threads,throughput_mops,latency_us,p99_us,bandwidth_gbps`).
- `latency_us` is a **mean** (= threads ÷ throughput); `p99_us` is a 500 ns histogram edge.
  Compare p99 with p99 only.
- `rtt / op` in `compute.log` excludes the skip-table (RACE) round trip; apply F-R5 or add 1.
- Memory-node CPU: `[CPU memory ] process=…%` in `memory.log`, near 0 but not exactly 0.
- 30M ops, **no warmup**, fixed seed; DEX runs 50M ops time-capped after a 10M warmup.
- `compare_dex_dart.py` picks the newest summary by name and ignores the `threads` column
  (`:68-83`, `:452`) — pass files explicitly.
- Matching CHIME's 68 clients from one host needs ≥ 135 logical CPUs at stride 2
  (`compute.cc:124,344`, return code unchecked) or `--numa_node_total_num=1`.
  `--compute_num=2` is not supported: both nodes would load all 50M keys and run all ops
  (`compute.cc:419-423,741-762`).

### R2 — DART: range scans  (BLOCKED)
`scan_local` returns on the first matching child in every branch (`art-node.cc:1812-1865`),
so a scan returns at most one key. `--mb_scan_len` only widens the end key. Every DART scan
number so far measures one root-to-leaf descent. A real in-order scan (sorted child order —
slots are stored by hash bucket, `art-node.cc:1409-1410` — plus backtracking until N keys)
has to be written first (F-R1).

### R3 — DART: write mixes and deletes  (BLOCKED)
- `remove` issues no RDMA and returns false (`art-node.cc:1871-1886`) but still counts as an
  op (`ycsb-timecounter.cc:51-55`) → inflated throughput.
- Run-phase insert/update CAS failures are not retried and the return value is ignored
  (`art-node.cc:351-355,382-384`; `compute.cc:390-409`).
- An insert starting from a skip-table node passes parent pointer 0; on node growth it treats
  the root's slot 0 as the parent (`art-node.cc:352,1331-1344`) — silent failure or corruption.
- The skip table is built once after load and never updated (`art-node.cc:2202,2259`).
- No correctness output at all (`wrong`/`fail`/`duplicate` counters never printed, `art-node.cc:74-78`).
Only a read/update 50/50 mix runs, and lost updates are silent.

---

## 4. Case study 3 — what can actually be run today

| | DEX | CHIME | DART |
|---|---|---|---|
| Exp 1 point lookups | D1 | C1 | R1 (flat line, no cache axis) |
| Exp 1 range scans (100) | D1 | C1 | **blocked** (R2) |
| Exp 2 read/update 50/50 | D5 (writes not pushed at level 1) | **fix** (F-C4) | runs, lost updates silent |
| Exp 2 read/insert 50/50 | D5 (upserts) | **fix** (upserts; F-C6) | **blocked** (R3) |
| Exp 2 deletes | D5 | **blocked** (no delete, F-C8) | **blocked** (no-op) |
| Exp 2 scan + 5% insert | D5 (stale-scan risk) | **fix** | **blocked** |
| Exp 3 gain vs round trips left | `rdma_read_per_op` + `rpc_per_op` | not in CSV; add | `rtt / op` (+1 for RACE) |
| Memory-node CPU | both nodes' `AGGREGATE active` (§0.3) | `REMOTE CPU LOAD` on `$MEM` | `[CPU memory ]` |

Also mismatched until fixed: thread counts (36 / 34×2 / 36), measured ops (50M time-capped /
30M per node / 30M), warmup (10M / 10M / none), DEX data on both nodes vs DART on one.

---

## 5. Code fixes, by priority

**Correctness of numbers already in the paper**
- **F-C2** CHIME scan scratch slot collides across nodes. The slot is `app_id % MAX_APP_THREAD`
  (`CHIME/src/Directory.cpp:150`) and `app_id` is the per-process thread id (`DSM.cpp:81`), so
  thread *i* on both nodes shares a slot; the dir can overwrite it before the first requester
  reads it (`Tree.cpp:1930`). Wrong rows, unchanged counts. Key by
  `node_id * MAX_APP_THREAD + app_id` (the 16 MB chunk has room). DEX uses the same keying
  but only one node runs clients there, so it only matters for DEX with 2+ compute nodes.
- **F-C9** CHIME leaf arm is not on equal memory. With the leaf cache on, the hotspot IdxCache
  is disabled (`Tree.cpp:142`) but TreeCache still subtracts its 30 MB (`Tree.cpp:125`), so the
  leaf arm really uses 466/218/94/62 MB against 512/256/128/64. Either give TreeCache the full
  `g_index_cache_mb` when `leafcache::enabled()` and re-run C1, or state the real sizes.
- **F-D4** (optional, §0.3) DEX placement: make allocation pick only memory-node IDs
  (`DSM.h:132-143` callers in `leanstore_tree.h:192-197,640,1088-1091,1632-1635`).

**Needed for planned experiments**
- **F-C1** `micro_test.cpp:216`: `tree->range_query(k, int2key((item & kOpMask) + scan_range), ret);`
- **F-C3** `LeafCache.h:254-259`: use a non-power-of-two set count with `% nsets`, or report
  the effective size.
- **F-C5** `Tree.cpp:2520`: `if (leaf_cache || batch_nocache)` with
  `static const bool batch_nocache = getenv("CHIME_RANGE_BATCH_NOCACHE") != nullptr;`;
  `ce = leaf_cache ? leaf_cache->get(a) : nullptr` at 2544; guard the `put`s at 2628-2629 and
  2652-2655 with `leaf_cache &&`.
- **F-D1** `newbench.cpp:167`: make `scan_num` an argument; put it in the log tag.
- **F-D2** `dex/include/Directory.h:39-41`: raise the scan slot to ≥ 16384 B (256 pairs today).
- **F-D3** `bench_stats.h:53` (DEX): raise `kNumBuckets` (~20000) — the histogram caps at 1 ms.

**CHIME scan path — to give CHIME+ the scan path DEX+ uses (Case Study 3)**

Why: DEX+ passes DART on scans because nearly every scan is handed to the memory
node, which walks linked leaves and returns them in one reply. CHIME+ does not,
for two reasons found in the code:
(1) `Tree::range_query` sends a scan to the memory node only on an inner-cache
miss (`Tree.cpp:2403-2408, 2464-2465`), so from 128 MB up scans never go there;
(2) when it does, `range_query_offload` first calls `get_leaf_addr`
(`Tree.cpp:1880-1909`), which walks down to the starting leaf with one-sided
reads (~6-7 round trips on a miss) before sending `RPC_SCAN`. Point lookups do
not have this problem: `lookup_from` hands the remaining walk to the memory node.
The 0.24 / 0.42 Mops "offloaded scan" numbers at 64 MB therefore measure that
one-sided walk, not the memory node scan path.

- **F-C10 Scan request from the deepest cached node.** In `range_query_offload`,
  replace `get_leaf_addr(cur)` with the cache lookup only
  (`tree_cache->search_from_cache(cur, p, sibling_p, level)`, or the root pointer
  on a full miss) and send `(p, level)` in the request. In the `RPC_SCAN` handler
  (`Directory.cpp:144+`), when `level > 1`, descend to the leaf with the same
  local walk `chime_offload::lookup_from` uses (`chime_rpc.h`), then call
  `chime_offload::range_scan` as today. Reuse `RawMessage.level`, which today
  carries the requested count: add a field or pack both.
- **F-C11 Offload scans even when the inner nodes fit.** Runtime switch
  `CHIME_SCAN_OFFLOAD_ALWAYS=1`: at the top of `Tree::range_query`, if set and
  offload is on, call `range_query_offload(from, to, ret)` and return. Default
  off, so every existing result stays reproducible. Only worth enabling when the
  memory node has spare threads (see the projection below).
- **F-C12 Memory-node threads for scans.** Run `CHIME_DIR_THREADS` 8 and 16. The
  uncommitted `NR_DIRECTORY 16` (`include/Common.h`) already allows it; build
  both nodes with it. `run_leaf_study.sh` `DIR_SET="4 8 16"` (uncommitted
  version) sweeps it.
- **F-C13 Clients on the compute node only** (matches DART and DEX). Guard in
  `micro_test.cpp` `thread_run` (`:261-362`): on node 0, take part in the
  `bulk`/`warmup`/`done` barriers but skip the op loops. Then the memory node's
  threads serve one node's clients, and CHIME's rate is directly comparable with
  DART's at the same thread count.
- **F-C14 (optional) Flat result buffer.** `micro_test.cpp:210` builds a fresh
  `std::map` of ~100 entries per scan; a reused vector removes ~100 allocations
  per scan on the compute node.
- F-C5 (batching without the leaf cache) is the other half: it is the best
  path when the memory node has no spare threads.

**Test cells (C9).** Build with F-C10..C13 on both nodes (`NR_DIRECTORY 16`).
Range workloads only, 512 and 128 MB, leaf cache off:
```bash
export CHIME_SCAN_OFFLOAD_ALWAYS=1          # both nodes
for D in 4 8 16; do
  MEM_IP=$MEM CMP_IP=$CMP SEQ_TS=scanfix_dir$D THREADS=34 DIR_THREADS=$D \
    CACHE_MB="512 128" WORKLOADS="range-uniform range-zipf" SEQUENCE=on LEAF_SET=0 \
    BULK=50 WARMUP=10 RANGE_OP=30 ./run_leaf_cache.sh <role>
done
```
Record `REMOTE CPU LOAD ... ns/msg` from `memory.log`: that per-request cost is
the one number the projection below assumes (~5 us per scan).

**Projection these fixes are expected to give** (not measured; written into
`RevSigmod_2027/sections/09-case-study-3-notes.tex`). Anchor: DEX memory-node
threads spend 0.55-0.6 us per scan request (`qload/dex_range_*_offload-on_cache512mb_mt2.log`),
walking ~2-3 leaves, i.e. ~0.25 us per plain-struct leaf. CHIME leaves must be
copied, version-checked and reassembled, and a scan covers ~11 of them, plus a
sort: assume ~5 us of memory-node time per CHIME scan. Per-node scan rate =
memory-node threads / (nodes running clients x 5 us), capped by the compute
node at ~34 / 11 us ~ 3.0 Mops. DART's scan bound at 34 threads is 1.27 Mops.

Zipf costs ~0.88x uniform per request on the memory node (DEX: 0.55 vs 0.62 us,
same logs), so CHIME Zipf c ~ 4.4 us. At 64 MB the memory node also walks the
missing inner levels: ~7 us uniform, ~6.1 us Zipf (1.14 / 1.31 Mops at 8 threads).

| Setup (128-512 MB) | Access | 4 MN threads | 8 | 16 |
|---|---|---:|---:|---:|
| Clients on both nodes (as run today) | uniform | 0.40 (0.32x) | 0.80 (0.64x) | 1.60 (1.27x) |
| | Zipf | 0.45 (0.35x) | 0.91 (0.72x) | 1.81 (1.43x) |
| Clients on compute node only (F-C13) | uniform | 0.80 (0.64x) | **1.60 (1.27x)** | **~3.0 (2.4x)** |
| | Zipf | 0.91 (0.72x) | **1.81 (1.43x)** | **~3.1 (2.4x)** |

With 4 memory-node threads the local batched path (F-C5, ~0.76-0.89 Mops) is
better, so F-C11 should only be on when the memory node has spare threads.

**Needed for Exp 2 (writes)**
- **F-C4** `Tree.cpp:1704`: turn the assert into unlock-and-return false, or draw update keys
  from `bulk_array`.
- **F-C6** `micro_test.cpp:172`: fresh-key inserts (counter above the loaded range).
- **F-C7** encode the key in the value (`v = key<<16 | ctr`) and check on every lookup and scan row.
- **F-C8** implement delete under `lock_node` (so the stamp is published).
- **F-R1..4** DART: real range scan; CAS retry; parent-slot pointer from the skip table or
  restart from root; skip-table maintenance; implement `remove`; print found/not-found.
- **F-R5** DART `art-node.cc:220`: `rtt++; access_size += …;` in `get_root(key)` so `rtt / op`
  includes the RACE round trip.

**Measurement hygiene**
- CHIME CSV: add `[CORRECTNESS]`, `stale=`, mean latency, `MIN_LEVEL`, `ADMIT`, `PCT`,
  `SCAN_RANGE` columns, and add them to the resume key (`run_leaf_study.sh:133-138`).
- DEX sweeps: take p99 from `[ALL OPS]`, not the first `p99=`.
- DART: add a warmup and match op counts.

---

## 6. Paper statements that the audit contradicts

| Statement | Where | What the code does |
|---|---|---|
| "CHIME's scans read one leaf at a time" | `05-chime.tex` §scope | Upstream batches all covered leaves in one doorbell; the **port** reads one at a time because upstream's path crashed on rdma-core (`4a32148`, `f3ee90e`) |
| Leaf cache "has to earn its share" on equal memory | CHIME.md §2.1, IMPLEMENTATION §5.2 | Leaf arm loses 30 MB (F-C9) and more to power-of-two rounding |
| "Only level-1 nodes are cached, so a hit cannot pass the gate" | CHIME.md §2.3, `05-chime.tex` | `CACHE_MORE_INTERNAL_NODE` is ON; higher levels are cached too |
| DEX cost = "four memory node threads" | `04-dex.tex` §cost | The compute node also runs dir threads and serves ~half the RPCs (§0.3) |
| DEX runs at 32 threads | `paper/make_figures.py:12`, COMPARISON.md | 36 (`totalThreadCount 36` in every summary.csv log) |
| DEX path-aware miss counters read zero | DEX.md:331, REPORT.md:313 | Fixed in `dbb5001`; only the June logs predate it |
| §7 fixes "not yet compiled or run" | IMPLEMENTATION.md:669,881; OFFLOAD.md:105 | leafstudy2 ran on them |
| "DART keeps a separate cache for each thread"; DART scans ≈ half its lookups | notes.txt:177,199 | DART has no compute cache and its scans return one key |
| "DEX and DART support all of these" (deletes) | notes.txt:189 | DART delete is a no-op; SMART's too |
