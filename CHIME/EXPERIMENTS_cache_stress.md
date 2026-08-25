# Cache-stress + offload study — and CHIME vs DART

Two experiments driven from this repo. Both ask the same underlying question from
different angles: **when the compute-side cache is too small to hold the index,
does offloading rescue throughput and tail latency?**

The internal-node index for the default build is **~55 MB** (measure it — see
*Calibrate* below). The cache points **64 / 32 / 16 MB** therefore span
*fits-the-index → stressed → badly stressed*.

---

## Experiment A — CHIME: stressed cache, offload OFF vs ON

**Hypothesis:** with offload ON, a stressed 32 MB / 16 MB cache delivers
throughput and p99 ≥ the comfortable 64 MB cache, because cache-missed descents
are pushed to the memory node instead of costing extra one-sided round trips.

**Matrix** (per node, 50M ops/cell): cache `{64,32,16}` × offload `{off,on}` ×
workload `{point,range} × {uniform,zipf-0.99}` = 24 cells. Cache size is a
**runtime** knob (`CHIME_CACHE_MB`) — one build, no rebuilds.

**Build** (offload must be compiled in):
```bash
cd CHIME && mkdir -p build && cd build && cmake -DENABLE_OFFLOAD=ON .. && make -j
```

**Run** — memory node first, then compute, identical args:
```bash
# on the memory node (10.30.1.8)
CHIME/run/run_cache_stress.sh memory
# on the compute node (10.30.1.6)
CHIME/run/run_cache_stress.sh compute
```
Quick logic check on small data: prefix with `PROFILE=quick` (10M keys/ops).

**Plot** (throughput + MEAN + p99 across cache × offload, per workload):
```bash
python3 CHIME/results/plot_offload.py     # auto-finds the newest sweep
```
Read MEAN, not just p99: throughput ≈ threads / mean (Little's Law). Baseline is
bimodal (fast on a cache hit, slow on a miss) so its mean is low but its tail is
huge; offload is uniform (every miss = one RPC) so its mean is higher but the
tail collapses. The two rows together explain any throughput crossover.

---

## Experiment B — CHIME vs DART at 16 / 32 / 64 MB

**Question:** at the same cache budget and same dataset, can CHIME (off and on)
catch up to DART as the cache is stressed?

### Comparability contract — what is held equal, and what cannot be

| Axis | Held equal | How |
|---|---|---|
| Dataset (memory-node tree) | **yes (logical)** | 30M keys, 8-byte u64 keys, **48-byte values** on both. CHIME: `BULK=30`, `keyLen=8`, `simulatedValLen=48`. DART: `--mb_key_count=30000000`, `--payload_byte=48`. |
| Cache budget (compute side) | **yes** | 16/32/64 MB total. DART cache is per-thread → `--th_b = total/threads`; CHIME is one total via `CHIME_CACHE_MB`. |
| Workloads | **yes** | point(lookup) & range(scan) × uniform & zipf-0.99, `scan_len=100`. |
| Threads | **yes** | both set to 24 (`THREADS`). |
| **Inner-node size** | **NO — not equalizable** | DART is a **radix tree (ART/prheart)** with adaptive Node4/16/48/256; CHIME is a **B+-tree** with a fixed `internalSpanSize`. There is no single span that equals an ART node. We pin CHIME at its default `internalSpanSize=16` and let the structure differ — **that difference is the comparison.** |
| Memory-node byte footprint | **reported, not forced** | A B+-tree and an ART store the same dataset with different overhead, so the byte counts can't be made identical. Each system's *actual* footprint is read from its own logs (CHIME: `consumed cache size`; DART: memory log) so the writeup states how close they really are. |

Because the index *structures* differ, the same "55 MB" statement does **not**
transfer to DART — DART's directory-cache working set is its own number. The
experiment compares them **at equal cache budget**, which is the fair axis.

### Run

CHIME side — the same Experiment A sweep already produces the CHIME half. If you
want the 30M-key / 48B contract exactly, run it with matching op counts:
```bash
BULK=30 WARMUP=5 POINT_OP=30 RANGE_OP=30 CHIME/run/run_cache_stress.sh memory
BULK=30 WARMUP=5 POINT_OP=30 RANGE_OP=30 CHIME/run/run_cache_stress.sh compute
```

DART side (matched sweep; edit the cluster block at the top first):
```bash
# on the DART monitor+memory host
DART/script/cache_sweep_compare.sh          # -> DART/cache_compare_<ts>.csv
```

### Overlay plot
```bash
python3 compare_chime_dart.py CHIME/build/results/cache_stress/sweep_<ts> \
                              DART/cache_compare_<ts>.csv \
                              --out compare_chime_dart.png
```
2 rows (throughput, **mean** latency) × 4 workload columns. At each cache size,
three bars: CHIME-off, CHIME-on, DART. Latency is **mean on both** (DART reports
mean, so CHIME's mean is parsed from its logs — not p99 — for a like-for-like
axis). Every axis starts at 0 and each metric row shares one y-scale.

---

## Calibrate the index once (do this first)

Confirm where 64/32/16 sit relative to the true index working set:
```bash
CACHE_MB=1024 POINT_OP=1 WORKLOADS=point-uniform SEQUENCE=off \
    CHIME/run/run_cache_stress.sh memory
grep "consumed cache size" CHIME/build/results/cache_stress/sweep_*/**/memory.log
```
That number is the real index MB (recorded per-cell in the `index_mb` CSV column
too). If it isn't ~55 MB in your build, re-pick the cache points so one sits
above the index and the rest below it.

---

## Experiment C — does caching LEAF nodes let CHIME pass DART?

Experiments A and B both hit the same wall: CHIME's cache holds **internal nodes
only**, so even a perfect index-cache hit ends in one remote read of the leaf.
Experiment C lets the compute node cache **both** node types and asks whether that
is a better use of the same memory.

**The budget is split, not grown.** `CHIME_CACHE_MB` is the TOTAL, and at each
point the baseline arm is *all inner* while the leaf arm is *half inner / half
leaf* — so both CHIME arms and DART occupy identical compute-side memory. The
sweep runs at **64 / 128 / 256 / 512 / 1024 MB**, the same points
`DART/script/cache_sweep_compare.sh` now defaults to.

```bash
CHIME/run/run_leaf_cache.sh memory      # then: ... compute
DART/script/cache_sweep_compare.sh      # same totals, on the DART host
python3 CHIME/results/plot_leaf_cache.py
```

`plot_leaf_cache.py` prints the inner/leaf split it read out of every cell and
flags any row where `inner + leaf` is not the sweep point — if it flags anything,
the arms were not on equal memory and the overlay means nothing.

Design, coherence protocol, knobs and what to expect: **[LEAFCACHE.md](LEAFCACHE.md)**.
`compare_chime_dart.py` picks the leaf arm up automatically from the sweep's
`cache_leaf` column.

## Files
- `CHIME/run/run_cache_stress.sh` — Experiment A runner (wraps `bench_common.sh`).
- `CHIME/run/run_leaf_cache.sh` — Experiment C runner (leaf-cache axis).
- `CHIME/results/plot_leaf_cache.py` — Experiment C plot.
- `CHIME/results/plot_offload.py` — Experiment A plot (existing).
- `DART/script/cache_sweep_compare.sh` — DART sweep matched to the contract above.
- `compare_chime_dart.py` — Experiment B overlay plot.
