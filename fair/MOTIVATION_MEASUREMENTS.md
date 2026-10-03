# Measurements for intro and motivation

**What this is.** These experiments produce, from our own DEX, CHIME and DART runs, the plots that `RevSigmod2027/measurement-summary-with-plots.pdf` shows from the analytical model:
- one experiment (M0) for the introduction
- one experiment per challenge, M1–M6, for challenges 1–6

Each section uses the PDF's layout:
- the question
- what to run, with the exact command
- what to plot, with the same axes as the PDF
- what we expect
- the result that would mean we are wrong
- what we already have

Nothing here changes the paper. The plots go into a separate PDF in the same style once the data is in.

**Servers.** server 6 (10.30.1.6) is the compute node; server 8 (10.30.1.8) is the memory node.

**How every command runs.** Each command starts the same way on both servers, with the memory side first or in either order. The handshake is the one `fair/run_all.sh` already uses.

**Three policies, named the same way everywhere**

| Policy | DEX | CHIME | DART |
|---|---|---|---|
| **Pull only** | memory threads 0 (`rpc_rate 0`) | memory threads 0 (offload off) | always (DART has no push) |
| **Push only** | every operation sent from the root: **needs code change P2** | `CHIME_OFFLOAD_MIN_LEVEL=1` (every lookup, cache hits included) + `CHIME_SCAN_OFFLOAD_ALWAYS=1` (every scan): **no code change** | — |
| **Both** (push only on a miss) | memory threads ≥ 1, `rpc_rate 1` (today's default) | memory threads ≥ 1, default min level 2, scans on miss | — |

**Two trees, so each experiment shows both regimes**

| Tree | DEX | CHIME |
|---|---|---|
| `TREE_SETUP=stress` (inner nodes never fit) | 22 levels, inner 1,878 MB, total 3,756 MB | stock shuffled load, inner ≈ 84–100 MB |
| `TREE_SETUP=fair` (inner nodes fit from ~512 MB) | 9 levels, inner 350 MB | bulk-built, the same shape as DEX |

---

## Before any new run: prerequisites

### P0. Builds

Both trees need their own binaries on both servers. The DEX fair tree is `dex/build_336_352_mn_only`; fair3 built it, so check that it still exists.

```
RUN_ID=build TREE_SETUP=stress ./fair/build.sh dex
RUN_ID=build TREE_SETUP=fair   ./fair/build.sh dex
RUN_ID=build ./fair/build.sh chime
RUN_ID=build ./fair/build.sh dart
```

### P1. Give the memory node 8 physical cores

**Needs a one-line edit in `fair/params.sh`. Not applied yet.**

**The problem.** In stress1, memory-node threads 5–8 ran on the hyperthread siblings of threads 1–4 (memory log: CPUs 79–76, then 39–36). `dir_cpu_list` reserves the cores of CPUs 0–35 for client threads, but the memory node runs no clients.

**The fix.** Change line 196 from

```
REV_DIR_CPUS="$(dir_cpu_list)"
```

to

```
: "${REV_DIR_CPUS:=$(dir_cpu_list)}"
```

Then on server 8 pass 8 distinct physical cores on the NIC's socket. First find the socket:

```
cat /sys/class/infiniband/*/device/numa_node      # NIC socket, e.g. 0
lscpu -p=CPU,CORE,SOCKET | grep -v '^#' | awk -F, '$3==0 && $1<40' | head -8   # pick 8 CPUs, one per core
```

Then pass them, for example:

```
export REV_DIR_CPUS=0,2,4,6,8,10,12,14
```

The values are an example: use the CPUs the check prints. Check every memory log's `dir N launch! (core …)` lines: all 8 must sit on different physical cores.

### P2. DEX push-only mode

**Needs a code change. Not applied yet.**

Add a runtime switch `DEX_PUSH_ALL=1`:
- **Lookup:** send one request at the root. The memory node walks the whole tree; the compute cache is not read.
- **Scan:** one request at the root. The memory node descends, then walks the leaf chain (as `rpc_scan` does today from a leaf).

DEX's code today can only push inside the bottom 4 levels (`megaLevel`), so there is no way to run push-only without this change.

`run_dex.sh` starts DEX with `sudo env REV_DIR_CPUS=…`, and sudo drops every other variable. So P2 must also add `DEX_PUSH_ALL="${DEX_PUSH_ALL:-0}"` to that `env` list.

CHIME needs no such change: `CHIME/run/bench_common.sh` launches with plain `env`, so an exported `CHIME_OFFLOAD_MIN_LEVEL` reaches the binary.

**Without P2:** M0 and M1 show DEX's push-only from the calibrated model (`fair/results/stress1/model/`), clearly labelled as a model, and CHIME's push-only measured.

### P3. A write-fraction knob in the harness

Only needed for M4(c).

- **The change.** `run_dex.sh`, `run_chime.sh` and `run_dart.sh` pass 0% updates today. Add `UPDATE_PCT` (DEX's argument 4, CHIME's update mix, DART's `--mb_update_pct`) with the remainder as lookups.
- **What it costs.** A small harness change, with no system code touched.

### P4. CHIME reads per operation

**Optional.** It is needed only for the "round trips per operation" panels of CHIME.

- **The gap.** DEX prints `Avg. rdma read / op` and `Avg. rdma rpc / op`; CHIME prints neither.
- **The fix.** Count one-sided reads per operation in CHIME's `bench_stats.h` and print one line at the end.

**Memory-node CPU for CHIME.** No change is needed: its directory threads already print `REMOTE CPU LOAD … AGGREGATE active` (`CHIME/src/Directory.cpp`, `include/remote_load.h`). The CSV does not carry it yet, but the logs do.

---

## G. The main grid: one sweep for the introduction and challenges 1, 2, 3, 5 and 7

M0, M1, M2, M3 and M5 all come from **one grid per system**, so that every plot reads the same cells.

| Axis | Values |
|---|---|
| Compute-side cache | 8, 16, 32, 64, 128, 256, 512, 1024, 2048 MB (9) |
| Memory-node cores | 2, 4, 6, 8, each a separate physical core (P1) |
| Policy | pull only (0 cores); push only at 2, 4, 6, 8; both at 2, 4, 6, 8 (9 settings) |
| Workloads | lookups and 100-key scans, uniform and Zipfian (4) |
| Trees | stress (inner nodes never fit) and fair (inner nodes fit from ~512 MB) (2) |
| Client threads | 36, as in every run so far |

That is 9 caches × 9 settings × 4 workloads × 2 trees = **648 cells each for DEX and CHIME**, plus 36 DART cells (9 caches × 4 workloads, one tree, pull only).

```
# server 8: ROLE=memory, with REV_DIR_CPUS exported (P1). server 6: ROLE=compute.
export CACHES="8 16 32 64 128 256 512 1024 2048"
export WORKLOADS="point-uniform point-zipf range-uniform range-zipf"
for T in stress fair; do
  # pull only and both
  RUN_ID=g_dex_$T   TREE_SETUP=$T SYSTEMS=dex   MEMTHREADS="0 2 4 6 8" bash fair/run_all.sh $ROLE
  RUN_ID=g_chime_$T TREE_SETUP=$T SYSTEMS=chime MEMTHREADS="0 2 4 6 8" CHIME_LEAF_SET=0 bash fair/run_all.sh $ROLE
  # push only
  RUN_ID=g_dexpush_$T   TREE_SETUP=$T SYSTEMS=dex   MEMTHREADS="2 4 6 8" DEX_PUSH_ALL=1 bash fair/run_all.sh $ROLE   # needs P2
  RUN_ID=g_chimepush_$T TREE_SETUP=$T SYSTEMS=chime MEMTHREADS="2 4 6 8" CHIME_LEAF_SET=0 \
    CHIME_OFFLOAD_MIN_LEVEL=1 CHIME_SCAN_OFFLOAD_ALWAYS=1 bash fair/run_all.sh $ROLE
done
RUN_ID=g_dart SYSTEMS=dart bash fair/run_all.sh $ROLE
```

### How long it runs

**DEX** (measured on stress1). The memory node prints a CPU report every 2 s, which gives each cell's wall time:
- 96–174 s per cell, 110 s on average.
- About 85 s of that is fixed: loading 50 M keys and the handshake. The rest is the 40 M operations.
- With the scripts' pauses, plan on **≈ 2.3 min per cell**.
- 8 and 16 MB cells and push only on 2 cores run slower (≈ 3 min); 1024–2048 MB cells run faster.

**CHIME:**
- **Fair tree:** 145 s per cell, measured on fair3 (bulk build).
- **Stress tree:** slower, for two reasons:
  - The tree is loaded by shuffled inserts.
  - Pulled scans are very slow at small caches. 40 M operations at 0.063 M scans/s (measured at 32 MB) is about 11 min per cell, and 13 MB ran at 0.039 (≈ 17 min).
- Plan on **≈ 6 min per stress cell** on average, and **≈ 2.5 min per fair cell**.

**DART:** ≈ 2 min per cell.

| Block | Cells | Per cell | Time |
|---|---|---|---|
| DEX, stress tree | 324 | ≈ 2.3 min | ≈ 12.5 h |
| DEX, fair tree | 324 | ≈ 2.3 min | ≈ 12.5 h |
| CHIME, stress tree | 324 | ≈ 6 min | ≈ 32 h |
| CHIME, fair tree | 324 | ≈ 2.5 min | ≈ 13.5 h |
| DART | 36 | ≈ 2 min | ≈ 1.2 h |
| **Grid total** | **1,332** | | **≈ 72 h (3 days)** |
| Already measured and reusable: DEX stress tree at 32–1024 MB, pull only and both at 2 and 4 cores (stress1); CHIME stress tree, pull and offload at 2 and 4 cores, leaf off (stress1, once fetched) | ≈ −144 | | ≈ −10 h |
| **To run** | | | **≈ 62 h** |

The systems share the two servers, so they run one after another, not in parallel. Each block is independent: plots for one system can be drawn while the next runs.

**Ways to cut it, if needed:**
- **Run push only at 2 and 8 cores only,** dropping 4 and 6: −288 cells, ≈ −14 h. The core curves keep both ends.
- **Run CHIME's stress tree only up to 512 MB:** its inner nodes (~84–100 MB) already fit by 128 MB, so 1024 and 2048 MB repeat 512. That saves 72 cells, ≈ −7 h.
- **Run scan cells with `OPS_M=10 WARMUP_M=5`:** 10 M measured scans is still a stable average and a well-filled p99. That cuts CHIME's slow small-cache cells by ~60%, ≈ −10 h. Mark them in the figure caption.

### Which figure each part of the grid makes

Each figure has the model PDF's axes:

| Model figure (PDF) | Our measured version, from grid G |
|---|---|
| **Intro** (new) | At 8, 32 and 2048 MB: throughput bars for pull only / push only / both, per system and tree, with memory-node cores busy marked on each bar. A second row has the same for p99. |
| **Fig. 1:** throughput vs memory-node cores | x = 2, 4, 6, 8 cores. Pull only is flat; push only and both rise. One panel per system × tree, at a warm cache (fair tree, 2048 MB) and a cold cache (stress tree, 32 MB). |
| **Fig. 1b:** cores push needs to match pull | the fewest cores at which push only, and both, reach pull only, against cache (8–2048 MB). "Never" is drawn at the top. |
| **Fig. 2:** throughput vs cache budget | x = cache ÷ inner footprint (log, MB labels). Curves: pull, push only at 2 cores, both at 2 and 8 cores, oracle. DART is a flat line. |
| **Fig. 2b:** pull latency vs cache budget | mean and p99 of pull only against cache, with the 1-read floor marked |
| **Fig. 3:** latency vs miss depth, winner vs load | (a) mean latency against uncached inner levels (from DEX's read counters), pull vs push at 2, 4, 6, 8 cores, each labelled with measured ρ. (b) Heatmap of m against ρ, coloured by the winner. |
| **Fig. 5:** push ÷ pull by structure and operation | bars for DEX and CHIME in both trees, lookup and scan, at 1 GB with 2 cores (the model's point) and at 32 MB. DART's pull ÷ DEX's pull is a separate marker. |
| **Fig. 7:** effect of tree depth | the two trees *are* the depth experiment: DEX's 22 levels vs 9. (a) latency of a cold miss (8 MB) for pull vs push. (b) cores push only needs to match pull, in each tree. (c) the measured inner footprint of each tree. |
| **Fig. 8:** CHIME key-space sweep | M2b below (a separate run) |

---

## M2b. CHIME at its shipped 70 MB cache, sweeping keys (the PDF's Fig. 8)

```
for K in 10 25 50 100 200; do
  RUN_ID=m2b_chime_k$K KEYS_M=$K SYSTEMS=chime CACHES=70 MEMTHREADS="0 2" CHIME_LEAF_SET=0 \
    WORKLOADS="point-uniform range-uniform" bash fair/run_all.sh $ROLE
done
```

- **Size:** 5 key counts × 2 settings × 2 workloads = 20 cells, ≈ 2–3 h. Load time grows with keys.
- **Memory:** 200 M keys needs about 12 GB on the memory node; check free memory first.
- **Plot:** (a) lookup throughput, (b) scan latency, (c) inner footprint vs the 70 MB line, each against keys on a log axis.

---

## M0. Introduction: at a small cache, neither pull alone nor push alone is enough

**Question.** With little compute-side memory, is it enough to pull everything, or to push everything? Or does a system need both, decided per operation?

**Run.** From grid G.

**Plot** (the introduction's figure).
- **(a)** Throughput against cache, 8–2048 MB (log): pull only, push only, both, at 2 cores. A light band shows 2–8 cores.
- **(b)** Bars at three caches, 8 MB (small), 32 MB and 2048 MB (large), in rows; columns are lookups and scans, uniform. Each panel has:
- **Bars:** throughput per policy, grouped by system (DEX stress tree, DEX fair tree, CHIME stress, CHIME fair, DART).
- **A marker above each bar:** memory-node cores busy (pull only 0; push only near all; both in between).
- **A thin line:** p99 for each bar.

**Expect.**
- **At 8–32 MB:** pull only is the slowest everywhere. Push only beats pull only but uses every memory-node core, and with 2 threads it saturates. Both is at least as fast as push only, with fewer busy cores.
- **At 1024–2048 MB in the fair tree** (inner nodes fit): pull only beats push only for lookups. Both matches pull only, because it barely pushes.
- **Scans:** push wins in DEX at every size, because DEX pulls a scan one leaf at a time.

**We are wrong if** one fixed policy is within 5% of both at every cache, tree and workload. Then a fixed choice is enough.

**What we have now.**
- DEX stress tree, pull only and both at 32–1024 MB with 2 and 4 cores (stress1). Its 6- and 8-thread cells ran on hyperthreads and are rerun in G.
- CHIME at 16–64 MB, off/on (`CHIME/results/stress/`).
- DART at 64–512 MB.
- Missing: push only (DEX needs P2), the fair tree, and 8, 16 and 2048 MB everywhere.

---

## M1. Challenge 1: push needs memory-node CPU

**Question.** Can push only match pull with the few cores a memory node has (2, 4, 6, 8)?

**Run.** From grid G.

**Plot** (the PDF's Fig. 1 and 1b). Shared x-axis: memory-node cores, 2, 4, 6, 8.
- **(a) Throughput:** pull only (flat), push only, both.
- **(b) Memory-node CPU %**, from `dex_memory.csv`; for CHIME, parse `AGGREGATE active` from the memory logs.
- **(c) Instead of "compute nodes"** (we have one): client threads 1–36 at 2 memory cores. M6 makes this plot.

**Expect.**
- **Push only:** throughput rises roughly in step with cores. It reaches warm pull only beyond 8 cores, or never.
- **Both:** at least pull's throughput at 2 cores.

**Model prediction.** Original model: about 9 cores to reach a warm pull. Our calibrated model: push only cannot reach a warm pull at any core count here, because one request (7.4 µs) costs more than one read (5.0 µs) with 36 clients waiting.

**We are wrong if** push only reaches warm pull with 2 cores.

**What we have now.** DEX "both" at 2 and 4 threads in the stress tree (stress1). Everything else comes from G.

---

## M2. Challenge 2: the cache budget flips the winner

**Question.** As the cache shrinks, does pull lose to push, and at what budget? Does that budget differ between structures?

**Run.** From grid G.

**Plot** (the PDF's Fig. 2).
- **x-axis:** cache ÷ inner footprint (log), labelled with MB as well.
- **(a) Throughput, (b) round trips per operation.** Round trips come from DEX's counters; for CHIME they need P4.
- **Curves:**
  - pull only
  - push only (2 cores)
  - both (2, 4, 6, 8 cores, as a light-to-dark ramp)
  - the oracle: the better of pull and push per point, drawn dotted
- **Panels:** one per system and tree. DART is a flat line in each lookup and scan panel.

**Expect.**
- Pull only falls as the cache shrinks; push only stays flat until the memory node saturates.
- The curves cross. They cross at a much smaller fraction of the footprint for the fair tree than for the stress tree.
- Both follows the upper envelope.
- In stress1 the crossover with 2 threads is between 64 and 128 MB (3.4–6.8% of the inner footprint). The model expected about 1%.

**We are wrong if** the curves never cross in the swept range.

---

## M3. Challenge 3: the depth of the miss, and load

**Question.** Is there a miss depth m\* above which push beats pull, and does it move with memory-node load?

**Run.** From grid G; no extra runs.
- **The cache size sets the miss depth.** Uncached inner levels = (reads per pulled lookup) − 1, read straight from DEX's counters at each cache. The 9 caches give m from about 9 down to 0.
- **The memory-node core count sets the load.** ρ = busy cores ÷ cores, from `dex_memory.csv`.

**Plot** (the PDF's Fig. 3).
- **(a)** Mean latency (36 ÷ throughput) against uncached inner levels, m = 0 to 7. Curves: pull, and push at 2, 4, 6, 8 cores, each labelled with its measured ρ.
- **(b)** The winner map: m against ρ, coloured by which path is faster. This is our existing `figs/lookup_7_push_vs_pull` heatmap, redrawn on (m, ρ) axes.

**Expect.**
- Pull rises by about one round trip (≈ 3.5 µs) per uncached level.
- Push is nearly flat at low load and steepens near saturation.
- m\* grows as threads are removed. Measured so far: push needs 6.8 / 4.5 / 2.1 pulled round trips to win at 2 / 3 / 4+ threads.

**We are wrong if** the crossover sits at the same depth at every load. Then DEX's fixed `megaLevel` would be enough.

**What we have now.** Panel (a) can be drawn today from stress1, at 2 and 4 cores.

---

## M4. Challenge 4: lookups, scans and writes want different paths

**Question.** Does the best path depend on the operation?

**Run.**
- **(a, b)** Scan length 1, 10, 100, 1000 keys:
  - DEX: pull only, both, push only
  - CHIME: pull only, both, push only
  - DART: pull only. Its one-key leaves are our radix tree, the stand-in for the PDF's SMART.
  - Cache 128 MB in the stress tree and 1024 MB in the fair tree; 2 and 8 memory threads.
- **(c)** Write fraction 0, 25, 50, 75, 100% updates (needs P3), DEX and DART.

```
for L in 1 10 100 1000; do
  RUN_ID=m4_<sys>_<tree>_L$L SCAN_LEN=$L TREE_SETUP=<tree> SYSTEMS=<dex|chime|dart> \
    CACHES=<128|1024> MEMTHREADS="0 2 8" WORKLOADS=range-uniform CHIME_LEAF_SET=0 \
    bash fair/run_all.sh <role>
done
```

**Size.** About 48 cells for DEX, 48 for CHIME and 8 for DART, roughly 8 h in total. Writes add about 30 cells.

**Plot** (the PDF's Fig. 4).
- **(a)** Reads per scan against scan length (log). DEX from its counters; CHIME needs P4; DART from `rtt_per_op`.
- **(b)** Mean latency against scan length.
- **(c)** Throughput against write fraction.
- **Curves:** pull and push for each structure, as in the PDF:
  - page B+tree: DEX
  - hashed-leaf B+tree: CHIME
  - one-key-leaf radix: DART

**Expect.**
- **DEX:** push wins scans at every length above 1, because DEX pulls one leaf at a time. In the fair tree, pull wins short scans and lookups.
- **DART:** pulled scan latency grows with every key (one leaf per key).
- **Writes:** push wins latency once lock round trips dominate, until the memory node saturates.

**We are wrong if** the same path wins for every operation in every tree.

**What we have now.**
- 100-key scans and lookups for DEX (stress1) and CHIME (`stress/`, leafstudy2).
- DART lookups and scans at 64–512 MB.

---

## M5. Challenge 5: the same policy helps one structure and hurts another

**Question.** Is the push ÷ pull ratio a property of the structure as well as the workload?

**Run.** None. Every bar comes from M0 and M2 cells, at matched settings:
- the model's own point: 1 GB cache, 2 memory threads
- plus 32 MB with 2 threads

**Plot** (the PDF's Fig. 5). Grouped bars, structures on the x-axis, with lookup and 100-key scan in each group. A log y-axis with a line at 1.
- **(a)** Latency gain of push: pull latency ÷ push latency.
- **(b)** Push throughput ÷ pull throughput.
- **Bars:**
  - DEX stress tree
  - DEX fair tree
  - CHIME stress
  - CHIME fair
- **DART** has no push, so it gets a separate marker: DART pull ÷ DEX pull at the same cache. That isolates the structure, not the policy.

**Expect.** Bars on both sides of 1:
- above 1 for DEX in the stress tree and for scans
- below 1 for lookups in the fair trees at 1 GB

stress1 already gives DEX lookups at 1 GB with 2 threads: 0.54 (uniform) and 0.61 (Zipfian), inside the model's 0.10–0.90.

**We are wrong if** every bar falls on the same side of 1.

---

## M6. Challenge 6: load and skew move the crossover

**Question.** Is the path that wins at low load still the winner at high load, and under skew?

**Run.**
- **(a) Load.** Our runs are closed loop, so client threads set the offered load: 1, 2, 4, 8, 16, 24, 36.
  - DEX: pull only, and both at 2, 4, 6, 8 memory cores.
  - Cache where one inner level is uncached: stress tree at 1024 MB (2.14 reads per lookup); fair tree at 256 MB.
  - Lookups, uniform.
- **(b) Skew.** Zipf θ 0, 0.5, 0.8, 0.99, 1.2 at 128 MB.
  - DEX, CHIME and DART.
  - Pull only, both, push only; 2 memory threads.

```
# (a)
for C in 1 2 4 8 16 24 36; do
  RUN_ID=m6a_dex_t$C THREADS=$C SYSTEMS=dex CACHES=1024 MEMTHREADS="0 2 4 6 8" \
    WORKLOADS=point-uniform bash fair/run_all.sh <role>
done
# (b)
for Z in 0 0.5 0.8 0.99 1.2; do
  RUN_ID=m6b_<sys>_z$Z ZIPF_THETA=$Z SYSTEMS=<dex|chime|dart> CACHES=128 MEMTHREADS="0 2" \
    WORKLOADS="point-zipf range-zipf" CHIME_LEAF_SET=0 bash fair/run_all.sh <role>
done
```

θ = 0 runs the Zipf generator with no skew. Check that DEX's and CHIME's generators accept θ = 0 and 1.2 in a one-cell test first.

**Size.**
- (a): 7 client counts × 5 settings = 35 cells, ≈ 1.5 h.
- (b): 5 θ × 2 workloads × 3 settings (pull, both, push only at 2 cores) = 30 cells per system: DEX ≈ 1.2 h, CHIME ≈ 2.5 h, DART (10 cells) ≈ 0.3 h.
- DEX's node ordering assumes `THREADS == kMaxThread` (`run_dex.sh` passes both). Run one small-THREADS cell first to check that the compute node still registers as node 0.

**Plot** (the PDF's Fig. 6).
- **(a)** p50 and p99 latency (log) against measured throughput, one point per client count. Curves: pull only, and both at 2, 4, 6, 8 memory cores.
- **(b)** Throughput against Zipf θ for pull only, both, push only.

**Expect.**
- Push has the lower latency at low load, and its curve turns upward first with 2 memory cores.
- Skew helps pull (popular paths stay cached) and narrows push's gain. stress1 already shows this: the lookup gain peaks at 1.98× under Zipfian against 2.38× under uniform.

**We are wrong if** the better static policy changes at no load and no skew.

---

## Order and total

| Step | What | Time |
|---|---|---|
| 1 | Fetch CHIME stress1 and fair3 (commands below); make P1 and P2 | — |
| 2 | **Grid G**: DEX, both trees (the introduction and challenges 1, 2, 3, 5 and 7 for DEX) | ≈ 22 h (25 h minus reused stress1 cells) |
| 3 | **Grid G**: CHIME, both trees | ≈ 39 h (46 h minus reused cells) |
| 4 | **Grid G**: DART | ≈ 1.2 h |
| 5 | **M2b**: CHIME key sweep | ≈ 3 h |
| 6 | **M4**: scan length and writes. Run 1000-key scans with `OPS_M=2 WARMUP_M=1`: a pulled 1000-key CHIME scan at a small cache would otherwise take ~3 h per cell. | ≈ 11 h |
| 7 | **M6**: client threads and skew | ≈ 5.5 h |
| | **Total** | **≈ 82 h, about 3.5 days** |
| | With the three cuts under grid G (push only at 2 and 8 cores; CHIME stress tree up to 512 MB; 10 M ops for scan cells) | **≈ 51 h, about 2 days** |

Steps 2–7 are independent. Do step 2 first, because it alone gives the introduction figure and five of the challenge figures for DEX. M3 and M5 need no runs of their own.

## Fetching what is already on the servers

CHIME stress1 (both sides) and the fair3 DEX run. Run the same steps on each server, changing only the branch name.

```
# on server 6 (compute), in bash:
cd ~/REV
pgrep -a micro_test || echo "CHIME not running"          # must say not running before you copy
for f in fair/results/stress1/chime/sweep_mt*/summary_compute.csv; do echo "$f $(( $(wc -l < "$f") - 1 )) rows"; done
ls fair/results/fair3/dex/dex_compute.csv
git checkout -b results-chime-stress1-compute
git add -f fair/results/stress1/chime fair/results/fair3
git commit -m "stress1 CHIME and fair3 results (compute, server 6)"
git push origin results-chime-stress1-compute
git checkout -                                            # back to the branch you were on

# on server 8 (memory): the same, with
#   summary_memory.csv in the row count, and branch results-chime-stress1-memory
```

The full CHIME stress1 grid is 9 memory-thread settings × 6 caches × 4 workloads × 2 leaf settings = 432 cells, so expect 48 rows per `sweep_mt*` file.
