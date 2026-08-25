# CHIME leaf-node caching (`CACHE_LEAF`)

Compute-side caching of **leaf nodes**, on top of CHIME's existing internal-node
cache — plus the coherence protocol that makes it safe, and the sweep that
measures whether it lets CHIME pass DART.

---

## 1. Why CHIME needs this to beat DART

Stock CHIME's compute cache (`TreeCache`) holds **internal nodes only**. Give it
enough memory and the whole descent becomes local — but the descent is not the
whole operation. The last hop, the leaf, is **always** a remote one-sided read.

CHIME already spends a lot of design on making that read *cheap*:

- **hopscotch leaves** confine a key to a `neighborSize` window, so the reader
  fetches one hop **segment** rather than the whole leaf — no read amplification;
- **`SPECULATIVE_READ`**'s hotspot buffer remembers which slot a hot key sits in
  and shrinks the read to a **single entry**;
- **`METADATA_REPLICATION`** puts a metadata copy in every entry group so a
  segment read is self-describing.

Every one of those optimises the **bytes** of the last round trip. None of them
removes the **round trip**. And on an RDMA fabric a 70-byte read and a 500-byte
read cost nearly the same — the cost is the round trip. That is the structural
reason CHIME stays behind DART under skew no matter how big the index cache gets:
DART's per-op cost is flat and low, and CHIME pays one RTT per lookup on top of a
perfect cache hit.

A leaf cache attacks it directly. A cached leaf is a fully decoded `LeafNode` in
compute-node DRAM, so the compute node caches **both** node types — inner nodes in
`TreeCache`, leaves here — and the experiment is whether that beats inner-only:

| | inner nodes only | inner nodes **and** leaves |
|---|---|---|
| point lookup, index hit | 1 RTT, one hop segment (~500 B) | 1 RTT, **16 bytes** |
| range scan, N covered leaves | **N serial RTTs**, a full leaf each | N × 16-byte probe |
| point lookup, index miss | k RTTs down the tree | unchanged (offload's job) |

Scans are where it pays most: CHIME's default covered-leaf path issues **one
`read_sync` per leaf, serially**, so a 100-key scan over 16-entry leaves is a
dozen-plus round trips deep. Point lookups keep their round trip — it just gets
small — so the honest expectation there is a modest gain, not a step change.

## 1a. The budget is one number, split — never grown

`CHIME_CACHE_MB` is the **total** compute-side cache, and the leaf cache is carved
**out** of it. At every sweep point:

| total | `CACHE_LEAF=0` | `CACHE_LEAF=1` (`LEAF_CACHE_PCT=50`) |
|---|---|---|
| 1024 MB | 1024 inner / 0 leaf | 512 inner / 512 leaf |
| 512 MB | 512 / 0 | 256 / 256 |
| 256 MB | 256 / 0 | 128 / 128 |
| 128 MB | 128 / 0 | 64 / 64 |
| 64 MB | 64 / 0 | 32 / 32 |

This is not a detail, it is the comparison. DART is swept at the same totals, so
both CHIME arms and DART occupy identical compute-side memory at every point — if
the leaf cache were extra memory on top, a win would only say *"CHIME was given
more RAM"*. Caching leaves has to **earn its share against the inner nodes it
displaces**, which also means a *flat* curve is a real result: the leaf cache paid
for a halved index cache and broke even.

Every cell records the split it actually ran (`total_cache_mb`, `inner_cache_mb`,
`leaf_cache_mb` in the summary CSV, from micro_test's `[CACHE node N]` line), and
`plot_leaf_cache.py` prints it and flags any row where inner + leaf ≠ the point.
To find the best *split* rather than the best total, pin the total and sweep
`LEAF_CACHE_PCT` (25 / 50 / 75).

---

## 2. Coherence — the actual hard part

Every other read in CHIME is self-validating: it fetches the real bytes, and the
version machinery certifies them. **A leaf served out of DRAM is not.** Leaves are
mutated by any node with one-sided writes under the leaf's own lock, so a cached
image can go stale three ways: an entry **update**, an **insert** (which also
re-hops neighbours), and a **split** (which moves keys out and rewrites the fence
keys and sibling pointer).

### The protocol: a seqlock over RDMA, anchored on the leaf lock

Every leaf allocation carries an 8-byte **stamp** (`define::leafStampOffset`).

```
writer                                   reader (cached image, stamp S)
------                                   -----------------------------
CAS lock word  -> busy                   read 16B [lock word, stamp]
write stamp    -> S'  (fresh, unique)    serve the image iff
write data                                   lock is UNLOCKED and stamp == S
write lock     -> free
```

All four writer ops go down the **same RC queue pair**, so the memory node applies
them in that order. A stamp is `(global_thread_id << 48) | per-thread counter`:
globally unique and **never reused**, so a stamp a reader cached can never be
re-produced by a later write.

**Why the probe is conclusive.** Suppose a write *completed* (the writer returned)
before the reader issued its probe: all four ops had landed, so the probe reads
`S' ≠ S` and the image is refused. Suppose the write is still *in flight*: either
its stamp write has landed — stamp differs, refused — or it has not, in which case
its CAS may or may not have landed. If it has, the probe reads **busy** and the
image is refused. If it has not, then no byte of data has been written yet either,
so serving the cached image returns the pre-write value of a write that has not
completed — exactly what a concurrent one-sided reader in stock CHIME may return.
**The cache is never weaker than the system it sits in.**

### Filling costs no extra round trip

A fill closes the same seqlock around the data read, posted as **one doorbell batch
of three RDMA reads** — `[lock,stamp]`, leaf bytes, `[lock,stamp]` — which an RC
responder executes in order. The image is published only if both guard samples read
UNLOCKED with an equal stamp. So a fill costs the single round trip the uncached
read would have cost anyway, and the published image is a provably quiescent
snapshot. (That bracket is strictly stronger than the hopscotch-bitmap
cross-check the stock range path does, which is why the fill path does not repeat
it.)

### Where the stamp lives, and why not next to the lock

The stamp is the **last 8 bytes of the leaf allocation**, past the 16-byte lock
area — not adjacent to the lock word, which would have been the obvious place.
Every "write the node (or its last segment) **and** release the lock in one RDMA
op" in `Tree.cpp` writes exactly up to `transLeafSize + allocationLockSize`. A
stamp inside that window would be silently overwritten by whatever the writer's
local buffer happened to hold there — and a stale leftover could *coincidentally
match* a stamp some reader had cached. Outside the window it is only ever written
deliberately.

### One mode, always on

There is no "trust the cache" setting. The probe runs before **every** hit, so a
cached leaf can never be served past a write and the cache is correct under
arbitrary concurrent writers from any node — no read-only assumption, and no
configuration that can silently produce wrong numbers. The price is that a point
lookup still costs a round trip; what changes is that it carries 16 bytes instead
of a hop segment.

### Known limits (state these when you write the results up)

- The correctness argument rests on the **leaf lock**. On this rdma-core port
  masked compare-and-swap is *emulated* (`DSM::cas_mask_sync`: read + plain CAS,
  serialised by a **process-local** mutex), so cross-node concurrent writers are
  already outside what this port guarantees — a pre-existing property of the port,
  not of the leaf cache. Single-node writers (what the benchmark does) are fine.
- `ENABLE_VAR_LEN_KV` is untested with leaf caching: the cached image holds the
  `DataPointer`, and the point path resolves it with the same second hop it always
  did, but the range harvest would return pointers. Same limitation the existing
  range path has.
- Coroutines: the probe uses `read_sync`, so a hit yields exactly like every other
  CHIME read. Nothing special to account for.

---

## 3. Architecture and where it plugs in

| File | Change |
|---|---|
| `include/LeafCache.h` | **new** — the cache: fixed-capacity, 8-way set-associative, LFU-with-aging, deferred-free retirement. Capacity is sized from the byte budget at construction, so it **cannot** exceed its budget and there is no eviction livelock to tune. |
| `include/Common.h` | leaf stamp geometry: `leafStampSize / leafLockOffset / leafStampOffset / leafGuardSize`, `allocationLeafSize` grows by 8 B |
| `src/Tree.cpp` | `publish_leaf_stamp` (in `lock_node`), `leaf_cache_validate`, `leaf_read_full`, `leaf_probe_local`, `leaf_harvest_range`; hooks in `leaf_node_search` and `range_query` |
| `include/Tree.h` | `LeafCache *leaf_cache`, `g_leaf_cache_mb` |
| `test/micro_test.cpp` | budget split, `[CACHE node N]` split line, `[LEAFCACHE]` report |
| `CMakeLists.txt` | `CACHE_LEAF_NODE` option (default **ON**) |
| `run/bench_common.sh` | `CACHE_LEAF` / `LEAF_CACHE_PCT` / `LEAF_SET`, new CSV columns |
| `run/run_leaf_cache.sh` | **new** — the sweep |
| `results/plot_leaf_cache.py` | **new** — the plot |
| `compare_chime_dart.py` | leaf-aware: adds CHIME+leaf-cache bars to the DART overlay |

**Compile-time vs runtime.** `CACHE_LEAF_NODE` (cmake, default ON) compiles in the
stamp and the cache; it is compile-time because it changes the **allocation
layout**, and every node must agree. Whether a *run* uses the cache is the runtime
knob `CHIME_CACHE_LEAF=0|1`, so **one binary serves both arms of the A/B** —
exactly like the offload rate and `CHIME_CACHE_MB`. Build with
`-DCACHE_LEAF_NODE=OFF` to get the exact pre-leaf-cache geometry back.

**Budget.** See §1a — `CHIME_CACHE_MB` is the total and is split, never grown.

**Interaction with `SPECULATIVE_READ`.** With leaf caching on, the hotspot buffer
is disabled and its budget goes to the leaf cache. The two answer the same question
(where does this key live) at different granularities, and because a speculative
hit never fetches a whole leaf, running both would keep the leaf cache permanently
cold. `CHIME_LEAF_KEEP_SPECULATIVE=1` stacks them (speculative first) if you want
to measure that.

**Interaction with offload.** They are complementary and compose at the default
`CHIME_OFFLOAD_MIN_LEVEL=2`: **offload serves the index misses** (the memory node
walks the remaining internals in local memory), the **leaf cache serves the index
hits** (level 1, where the only work left was the leaf read). At min level 1
offload takes every lookup and the leaf cache is never consulted on the point
path — `micro_test` prints a warning if you do that.

---

## 4. Build and run

### 4.0 Match the DART sweep you are comparing against

Read the DART CSV's own header row — it records the contract. The committed
baseline (`DART/cache_sweep_baseline_20260622_071147.csv`) was run at:

| | DART | CHIME setting |
|---|---|---|
| keys | 50,000,000 | `BULK=50` |
| measured ops | 30,000,000 | `POINT_OP=30 RANGE_OP=30` |
| value size | **16 B** (`--payload_byte`) | `cmake -DCHIME_VALUE_LEN=16` ← **compile-time** |
| scan length | 100 | `SCAN_RANGE=100` (default) |
| distributions | uniform, zipf-0.99 | default |
| cache totals | 64 / 128 / 256 / 512 MB | `CACHE_MB="512 256 128 64"` (default) |
| threads | 34 **and** 36 | `THREADS=34` — pick one, and pass `--dart-threads 34` to the plotter |
| coroutines | 1 | `micro_test` runs no coroutines |

Two of these bite:

- **Value size is compile-time in CHIME.** The source default is 48 B; the DART
  data is 16 B. Build with `-DCHIME_VALUE_LEN=16` or the two systems are not
  storing the same dataset — and at 16 B a leaf is ~459 B instead of ~979 B, so
  roughly twice as many leaves fit the leaf cache. It changes the headline number.
  After changing it, check the `[GEOMETRY] internal/leaf` line says
  **`OK: internal < leaf`** (at 16 B it is 319 B vs 459 B — still fine, but the
  margin is 1.4× rather than 3.1×).
- **Thread accounting differs by construction.** DART drives its 34 client threads
  from **one** machine; CHIME runs the same binary on both nodes, so `THREADS=34`
  means **68** client threads. `THREADS=34` keeps the "per-node thread count"
  contract the earlier experiments used — keep it, but say so in the writeup.
  `THREADS=17` is the setting that matches *total* client parallelism instead.

### 4.1 Build (both nodes, identical flags)

```bash
# The stamp changes the allocation layout, so a mismatched pair will corrupt reads.
cd CHIME && rm -rf build && mkdir build && cd build
cmake -DENABLE_OFFLOAD=ON -DCACHE_LEAF_NODE=ON -DCHIME_VALUE_LEN=16 ..
make -j
```

### 4.2 Smoke test first (~minutes, one cell)

```bash
export SEQ_TS=smoke                     # SAME on both nodes -- see 4.4
PROFILE=quick THREADS=34 CACHE_MB=256 WORKLOADS=point-zipf \
  CHIME/run/run_leaf_cache.sh memory    # 10.30.1.8, START FIRST
# ... then the identical line with `compute` on 10.30.1.6
```

Four things to confirm in the logs before spending hours:

1. `[GEOMETRY] internal/leaf = 0.70x  (OK: internal < leaf)`
2. `[CACHE node N] total=256 MB index=128 MB leaf=128 MB` on the `leaf_1` cells,
   and `index=256 MB leaf=0 MB` on `leaf_0` — they must sum to 256 either way
3. `[LEAFCACHE] hit=… hit_pct=…` non-zero on the `leaf_1` cells
4. **`[CORRECTNESS node N] lookup found …%` identical between `leaf_0` and
   `leaf_1`.** This is the gate: a difference means the cached-image path returns
   different results from the remote path. Stop and fix, do not sweep.

### 4.3 Full run

```bash
export SEQ_TS=$(date +%Y%m%d_%H%M%S)    # copy this exact value to the other node
THREADS=34 BULK=50 WARMUP=10 POINT_OP=30 RANGE_OP=30 SCAN_RANGE=100 \
  CHIME/run/run_leaf_cache.sh memory    # memory node FIRST
# ... identical line with `compute`
```

64 cells per node (4 caches × 2 leaf × 2 offload × 4 workloads), each rebuilding a
50 M-key tree. Run it in pieces if that is too long — `WORKLOADS=point-zipf` etc.
splits cleanly, since every cell is independent.

### 4.4 Collect both nodes' results onto one machine

Each node writes only its **own** summary, and the two get different sweep
timestamps unless you pin `SEQ_TS`. The plotters want both CSVs in one directory,
because cluster throughput is the **sum** of the two nodes' `[RESULT]` rates:

```bash
# on the compute node, after both finish
scp 10.30.1.8:CHIME/build/results/leaf_cache/sweep_$SEQ_TS/summary_memory.csv \
    CHIME/build/results/leaf_cache/sweep_$SEQ_TS/
```

Sweep: `cache {1024,512,256,128,64} × leaf {0,1} × offload {off,on} × 4 workloads`
= 80 cells per node, all runtime — one build. `PROFILE=quick` for a 10M smoke run
first. The DART half must be swept at the **same totals**:

```bash
DART/script/cache_sweep_compare.sh     # CACHE_TOTAL_MB defaults to the same points
```

To find the best inner/leaf **split** rather than the best total, pin the total:

```bash
CACHE_MB=256 LEAF_SET=1 LEAF_CACHE_PCT=25 CHIME/run/run_leaf_cache.sh memory
#                                     50 / 75 ...
```

### 4.5 Plot

```bash
S=CHIME/build/results/leaf_cache/sweep_$SEQ_TS

# leaf cache on vs off, per workload (prints + checks the inner/leaf split)
python3 CHIME/results/plot_leaf_cache.py $S

# vs DART, at equal total cache. --dart-threads picks one of the thread counts
# the DART baseline CSV swept (34 or 36) -- without it the lowest is used.
python3 compare_chime_dart.py $S \
    DART/cache_sweep_baseline_20260622_071147.csv \
    --dart-threads 34 --caches 512,256,128,64 \
    --out compare_chime_dart_leaf.png
```

The overlay grows two bars per group when the sweep has a leaf arm: CHIME
offload-off, CHIME offload-on, **CHIME+leaf off**, **CHIME+leaf on**, DART.

### Knobs

| env | default | meaning |
|---|---|---|
| `CACHE_MB` | `1024 512 256 128 64` | **total** compute-side cache points (= DART's) |
| `CACHE_LEAF` | `0` | leaf cache off/on for a single run |
| `LEAF_SET` | `0 1` (in `run_leaf_cache.sh`) | sweep the leaf axis; adds a `leaf_<v>/` results level |
| `LEAF_CACHE_PCT` | `50` | leaf share of the total, in percent (rest → inner nodes) |
| `LEAF_CACHE_MB` | — | absolute leaf budget, overrides the % |
| `CHIME_LEAF_KEEP_SPECULATIVE` | `0` | keep the hotspot buffer stacked on top |

New CSV columns: `cache_leaf, total_cache_mb, inner_cache_mb, leaf_cache_mb,
leaf_hit_pct` — check `inner + leaf == total` on every row. New log lines, parsed
by the scripts:

```
[CACHE node N] total=… MB index=… MB leaf=… MB
[LEAFCACHE] hit=… miss=… stale=… hit_pct=… resident=… capacity=… budget_mb=…
```

---

## 5. What to expect, and how to read it

**Read the hit-rate row of the plot first.** A leaf is only worth caching when its
keys are re-read, and this benchmark maps every workload key through
`CityHash64`, so a Zipf *rank* becomes a pseudorandom *key*. Hot keys are therefore
scattered across millions of leaves, and each cached leaf earns its ~1 KB mostly
for a single hot key.

- **uniform**: ~3 M leaves at 50 M keys; a 128 MB leaf cache holds ~130 K of them,
  so the hit rate is a few percent at best. Expect **no win, possibly a loss** —
  the halved inner-node cache costs something and the leaf cache returns nothing.
  That is a result, not a bug: it is the honest statement that leaf caching is a
  *skew* optimisation, and it is exactly why the split has to be charged for.
- **zipf-0.99**: cumulative Zipf mass over the hottest `R` of `N` ranks goes roughly
  as `ln R / ln N`, so ~130 K resident leaves ≈ **60–70% hit rate**. This is where
  a win can exist.
- **point**: modest at best. The round trip is still there, it just got small.
- **range**: the largest win, because one 16-byte probe replaces a whole serial
  leaf read, a dozen-plus times per scan.
- **big totals help the leaf arm**: at 64 MB the inner cache is halved to 32 MB,
  well under the ~55 MB index, so the leaf arm pays for extra descent misses. At
  512–1024 MB both halves are comfortable and the leaf cache is close to free.
  If there is a crossover, expect it in the middle of the range.

Two sanity checks before believing any of it:

- `plot_leaf_cache.py` prints the inner/leaf split per cell and flags
  `inner + leaf != total`. If it flags anything, the arms were not on equal memory
  and the comparison is void.
- If throughput moves where the hit rate does **not**, the leaf cache is not what
  changed — look at the inner cache it displaced.

**Correctness check across arms.** `micro_test` prints
`[CORRECTNESS node N] lookup found …%` and `scan rows returned = …`. On a static
tree these **must be identical** for `CACHE_LEAF=0` and `CACHE_LEAF=1`, with
offload off and on. A mismatch means the cached-image path returned different
results from the remote path — treat it as a bug, not as noise.
