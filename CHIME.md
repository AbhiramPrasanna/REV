# CHIME — the system that bet everything on one lever fitting

**Baseline → Implementation → Results → Recommendations**

CHIME commits to the caching lever alone and structures the entire index around that
commitment: it caches internal nodes only, and every remaining mechanism exists to make the
one unavoidable remote read *smaller*. The bet is that the inner index fits in the compute
cache. When it does, CHIME is flat and fast. When it does not, there is no second lever and
the system falls **3.7×** in a single cache step.

This document maps what happens when you give it the second lever.

Companion: [DEX.md](DEX.md) · cross-cutting argument: [REPORT.md](REPORT.md) ·
mechanism detail: [IMPLEMENTATION.md](IMPLEMENTATION.md)

**Configuration for every number here:** 2 nodes, 34 app threads/node, 4 dir threads,
50 M keys, 8-byte keys, **16-byte values**, 30 M measured ops, scan length 100,
zipf θ = 0.99. Compute-node throughput. Data:
[`CHIME/results/leafstudy2_compute.csv`](CHIME/results/leafstudy2_compute.csv).

---

## 1. Baseline — what CHIME does

### 1.1 The caching lever, deliberately half-used

**The compute cache holds internal nodes only.** This is a considered choice, not an
oversight: inner nodes need no coherence, because a stale one merely lands the search at
the wrong leaf and the operation retries. Excluding leaves therefore sidesteps cross-server
invalidation entirely.

The price is that **the leaf is always a remote read** — even when the cache resolved the
entire descent.

### 1.2 No offload lever at all

Every access is one-sided RDMA. The memory node's CPU is never involved in an index
operation. Like DART, and unlike DEX, CHIME has exactly one lever.

### 1.3 Everything else makes the unavoidable read smaller

- **Hopscotch leaves** confine a key to a `neighborSize = 8` window, so a reader fetches one
  hop *segment* rather than a whole leaf. The per-entry `hop_bitmap` doubles as the
  torn-read detector for those partial reads.
- **`SPECULATIVE_READ`** remembers which slot a hot key occupies, shrinking a read to a
  single entry.
- **`METADATA_REPLICATION`** puts a metadata copy in every entry group so a segment read is
  self-describing.
- **Per-cacheline version bytes** make one-sided reads self-validating without a lock.
- **Vacancy-aware lock** — a bitmap inside the lock word tells a reader how many entries it
  must fetch.

**Every one of these optimises bytes. None removes a crossing.** On this fabric a 70-byte
read and a 500-byte read cost nearly the same.

### 1.4 The bet

The design rests on the inner index fitting in the compute cache. Two decisions make the
consequences of losing that bet severe:

- `leafSpanSize = internalSpanSize = 16`, chosen so an internal node (319 B) is smaller
  than a leaf (979 B). The cost is **fanout 16**, and the logs show **the root at level 7**.
- The index working set is **~90–100 MB** at 50 M keys with 16 B values. And **nominal cache
  ≠ index cache**: `SPECULATIVE_READ` takes `kHotspotBufSize` = 30 MB off the top whenever
  nominal > 50 MB, so a "64 MB" cache gives `TreeCache` only 34 MB.

| | crossings |
|---|---:|
| cache **hit** | 1 leaf read |
| cache **miss** | ~6 internal + 1 leaf = **7** |

---

## 2. Implementation — what we investigated and what we changed

### 2.1 The experiment: map the lever space on both sides of the fit boundary

We swept **cache {512, 256, 128, 64 MB} × leaf-cache {off, on} × offload {off, on} ×
{point, range} × {uniform, zipf}** — 64 cells, ~6 h per node.

The critical methodological choice: **the leaf cache is carved *out* of the total budget**
(`LEAF_CACHE_PCT = 50`), never added to it. `g_index_cache_mb + g_leaf_cache_mb ==
CHIME_CACHE_MB`, always. Every arm therefore occupies identical compute-side memory, so
caching leaves has to earn its share against the inner nodes it displaces — and DART is
swept at the same totals. If the leaf cache were extra memory on top, a win would only say
*"CHIME was given more RAM."*

That gives **four lever configurations at every budget**, on both sides of the boundary.

### 2.2 The analysis step that made it legible

**Re-index the sweep by *inner* cache rather than total.** That is what the caching lever
actually spends, and it makes the two leaf arms line up on one axis — a `leaf_1` cell at
total 128 MB and a `leaf_0` cell at total 64 MB both run a 64 MB inner cache, and they
measure within 2% of each other (0.645 vs 0.632 on point-uniform) despite one having twice
the total memory.

That single observation says the cliff is an **inner-cache phenomenon**, not a total-memory
one, and it is what turns the sweep into the lever map in §3.

### 2.3 What we changed

**Added the offload lever, miss-gated structurally.** `CHIME_OFFLOAD_MIN_LEVEL = 2`.
`level == 1` *is* the leaf — internals are level ≥ 2 — so a level-1 boundary means the cache
resolved the whole descent and offloading would ask a directory core to perform the single
read one-sided RDMA does with **zero** memory-node CPU. Because only level-1 nodes are
cached, **a cache hit cannot pass the gate**: miss-gating is a property of the structure,
not a policy that can drift.

Scans gate on coverage instead of level: complete cache miss → push the whole scan down;
partial hit → serve the covered prefix locally and offload only the uncovered tail; full hit
→ never offload.

**`lookup_from` — the 7 → 1 collapse.** The memory node walks every remaining internal level
*and* the leaf in local memory, faithfully replaying `internal_node_search` including the
turn-right on a concurrent split. On a 7-level tree a missed descent becomes one RPC. This
is CHIME's single largest win source.

**Encoding-agnostic decode.** CHIME leaves are version-encoded and metadata-scattered, so
the memory node runs CHIME's own decoders: `memcpy` snapshot → `decode_node_versions` →
`decode_node_metadata` → retry on mismatch. The snapshot must come first — comparing version
bytes in place lets a writer land another cacheline between the comparison and the read.

Worth noting for the paper: the memory node consults **neither bitmap**. Both the hopscotch
and vacancy bitmaps exist to make *partial* reads safe; the memory node has the leaf in
local DRAM, reads all of it, and validates with the whole-node version check, which is
strictly stronger.

**Added a leaf-caching lever**, so the caching lever could reach the last crossing. Serving
a leaf from DRAM is the one read in CHIME that is not self-validating, so it needs
coherence: an 8-byte never-reused **stamp** per leaf, published by the writer under the leaf
lock before any data byte moves, checked by the reader with one 24-byte `[lock, stamp]`
probe before every hit. A fill closes the same seqlock around the data read as a single
3-request doorbell, so **a fill costs the crossing the uncached read would have cost
anyway**. Full protocol:
[IMPLEMENTATION.md §5](IMPLEMENTATION.md#5-the-leaf-cache--how-it-is-actually-done).

**The first cut of the leaf cache failed, as predicted.** It served each covered leaf on its
own — one guard probe per resident leaf, one bracketed read per missing one — which preserved
the baseline's *crossing count* and shrank only bytes:

| | crossings | bytes | extra work |
|---|---:|---|---|
| baseline | 1 | ~1 KB | decode |
| cache HIT | 1 | ~24 B | local scan |
| cache MISS | 1 | 3-WR batch | decode + ~480 B alloc/memcpy + LFU |

Result: **−41%** on range-uniform, and **−15% at a 59% hit rate** on range-zipf — losing
even at a high hit rate, which rules out "the cache was too small."

**The repair.** `Tree::range_query` now issues **two doorbells regardless of leaf count** —
one batch of guard probes for every resident leaf, one batch of seqlock-bracketed reads for
the rest — taking a 12-leaf scan from 12 crossings to **2**. Chunked at 32 leaves so a
doorbell is at most 96 work requests against a 4096-deep send queue. Plus per-path admission
ratios (point and scan separate), both defaulting to 1.0 so batching could be attributed
alone.

---

## 3. Results — the lever map

Indexed by **inner cache MB**. Fit boundary ≈ 90–100 MB, so **inner ≥ 128 fits,
inner ≤ 64 does not.**

### 3.1 point-zipf — the headline

| inner MB | cache only | + offload | + leaf cache | **both levers** |
|---:|---:|---:|---:|---:|
| 512 | 2.857 | 2.857 | — | — |
| 256 | 2.857 | 2.857 | 3.999 | 3.999 |
| 128 | 2.857 | 2.857 | 3.749 | 3.999 |
| **64** | **1.091** | **2.727** | 1.250 | **3.157** |
| **32** | — | — | 1.224 | **3.157** |

Read the columns as levers:

- **Caching raises the plateau.** The leaf cache lifts 2.857 → 3.999 (**+40%**) — but only
  where the index fits. Below the cliff it does almost nothing (1.091 → 1.250).
- **Offload removes the cliff.** At inner 64: 1.091 → 2.727 (**2.5×**). Above the cliff it is
  **exactly inert** — 2.857 → 2.857, three consecutive cache points. The gate is working.
- **Together at 32 MB inner + 32 MB leaf: 3.157 — above stock CHIME's ceiling of 2.857,
  which stock needs ≥128 MB of inner cache to reach.** Half the total cache, a quarter of
  the inner cache, **1.11× the throughput.**

### 3.2 point-uniform — same structure, weaker caching lever

| inner MB | cache only | + offload | + leaf cache | both |
|---:|---:|---:|---:|---:|
| 256 | 2.307 | 2.307 | 2.608 | 2.608 |
| 128 | 2.307 | 2.307 | 2.500 | 2.499 |
| **64** | **0.632** | **1.714** | 0.645 | **1.714** |
| 32 | — | — | 0.612 | 1.666 |

Leaf caching buys only **+13%** — hot keys are hashed through CityHash, so a Zipf *rank*
becomes a pseudorandom *key* and the hot set scatters across ~4.5 M leaves; under uniform a
256 MB leaf cache covers ~12% of them. Offload still buys **2.7×** at the cliff.

**Stated honestly:** both levers at 32 MB (1.666) do **not** beat stock's plateau (2.307).
The "beats its own ceiling" headline holds for skew, not for uniform.

### 3.3 range-zipf — caching reaches scans only once batched

| inner MB | cache only | + offload | + leaf cache | both |
|---:|---:|---:|---:|---:|
| 256 | 0.500 | 0.496 | 0.594 | **0.600** |
| 128 | 0.496 | 0.500 | 0.571 | 0.566 |
| **64** | **0.093** | **0.377** | 0.129 | **0.429** |
| 32 | — | — | 0.124 | 0.417 |

Batched leaf caching lifts the plateau **+19%** (from −15% before the repair); offload lifts
the floor **4.1×**.

### 3.4 range-uniform — the caching lever is unavailable, full stop

| inner MB | cache only | + offload | + leaf cache | both |
|---:|---:|---:|---:|---:|
| 256 | 0.496 | 0.496 | 0.395 | 0.395 |
| 128 | 0.496 | 0.496 | 0.385 | 0.385 |
| **64** | **0.047** | **0.243** | 0.066 | 0.242 |
| 32 | — | — | 0.066 | 0.236 |

**Leaf caching is a net loss at every budget** (−21%): a uniform scan streams through leaves
it never revisits, so there is nothing to cache. Offload is the only lever that works, and
only below the cliff (**5.1×**).

### 3.5 What the map says

| | caching lever | offload lever |
|---|---|---|
| **Index fits** | raises the plateau: **+40%** point-zipf, **+19%** range-zipf, +13% point-uniform, **−21% range-uniform** | **inert** — correctly, by the gate |
| **Index does not fit** | ~nothing (+2 to +13%), and **it stole the memory that caused the cliff** | **removes the cliff: 2.5–5.1×** |

**And the leaf-caching lever can backfire.** At total 128 MB the leaf arm runs a 64 MB inner
cache — below the boundary — and point-uniform drops **2.307 → 0.645, a 3.6× self-inflicted
collapse.** With offload on, the same cell recovers to 1.714. The second lever is therefore
not merely additive: **it bounds the downside of using the first one aggressively**, which
is what makes an aggressive caching policy safe to adopt at all.

**The gate is validated independently.** Measured offload fraction against predicted miss
rate `1 − effective/84 MB`: 64 MB 60%/**63.2%**, 32 MB 62%/**65.2%**, 16 MB 81%/**82.5%**.
Three for three — offload fires often because the cache misses often, not because the policy
is loose.

**Reproducibility.** The point path reproduces across two independent 6-hour sweeps to four
decimals (point-uniform 512 baseline 2.3072 / 2.307; point-zipf 2.8565 / 2.857), so
plateau-regime deltas are signal. Stressed cells run ±5–12% — do not read small differences
at inner ≤ 64.

### 3.6 Tails did not follow throughput

| cell, leaf cache on | baseline p99 | leaf-on p99 | |
|---|---:|---:|---|
| range-zipf 512 MB | 81.0 | 90.5 | **worse, despite +19% throughput** |
| range-uniform 512 MB | 81.0 | 116.5 | worse (was 157.5 before batching) |

Plausibly the phase-2 doorbell: a scan needing many full-leaf fetches now takes one large
stall instead of several small ones, which helps the mean and hurts the tail. This fits the
"trades tail predictability for throughput" framing and should be stated, not hidden.

### 3.7 Figures

| ID | Figure | Status |
|---|---|---|
| **F-CHIME-1** | **the lever map** — throughput vs *inner* cache, four lever configs, fit boundary marked. **Figure 1 candidate** | **new — data in hand** |
| **F-CHIME-3** | range cells: baseline / first-cut / batched — the falsification and its repair | **new — data in hand** |
| F-CHIME-2 | stressed-regime speedups | exists — `CHIME/results/stress_*.png` |
| F-CHIME-4 | leaf cache on/off with the inner/leaf split annotated | exists — `plot_leaf_cache.py` |
| F-CHIME-5 | CHIME arms vs DART at equal total cache | exists — `compare_chime_dart.py` |

---

## 4. Recommendations — how CHIME should have expanded its own operating point

### R1 — CHIME should never have bet the design on the index fitting

Inner-only caching gives a plateau that is flat and good **and a cliff that is 3.7× deep**,
with no second lever to catch it. The data shows the catch is cheap: offload restores
1.091 → 2.727 at inner 64 MB, and is **exactly inert above the boundary**, so it costs
nothing when it is not needed.

**A system with one lever must be provisioned for its worst case; a system with two can be
provisioned for its common case.** That is the entire provisioning argument, and CHIME gave
it up by construction.

### R2 — CHIME should have priced the "no leaf caching" decision instead of assuming it

Excluding leaves avoids coherence entirely; the price is one guaranteed crossing per
operation, forever. Our stamp protocol shows that price was **mis-estimated** — coherence for
a cached leaf costs one 24-byte probe, folded into a crossing the read needed anyway.

*Stated carefully, because our own map complicates it:* the leaf lever pays **only for point
lookups under skew (+40%) and batched zipf scans (+19%)**, and is a **−21% loss on uniform
scans**. So the recommendation is not "cache leaves." It is that **the coherence argument
alone never settled the question** — the answer is regime-dependent, and CHIME never
measured which regime it was in.

### R3 — CHIME should have batched its scan path by default, independent of any lever

The covered-leaf set is fully known before any I/O — `leaf_addrs` is complete before the read
loop begins — yet the stock path issues one `read_sync` per leaf, **serially**. The
information needed to batch was already in hand and unused.

This is the cheapest structural fix in the codebase, it requires no memory-side CPU, no
coherence protocol and no second lever — and it is what made the leaf lever viable for scans
at all (−15% → +19%). A 100-key scan over 16-entry leaves is a dozen-plus serial crossings
deep in stock CHIME for no reason.

### R4 — CHIME should have coupled its fanout choice to miss cost

Shrinking `internalSpanSize` to keep internal nodes smaller than leaves is defensible in
isolation. But fanout 16 makes the tree ~7 levels, so **a miss costs ~7 crossings instead of
~4** — the parameter was optimised on node size while multiplying the cost of the event that
dominates the regime where the design is weakest.

Note the interaction with R1: **with a second lever this coupling stops mattering**, because
the memory node walks those 7 levels in local memory. That is itself an argument for having
one — a second lever buys freedom in parameters the first lever had to be conservative about.

### R5 — CHIME should have reported performance against its fit boundary, in inner-cache terms

Throughput against *total* cache hides a 3.7× cliff and makes the two arms incomparable;
throughput against *inner* cache makes the structure legible immediately (§2.2, §3).

Worse, **nominal ≠ index cache**: `SPECULATIVE_READ` silently takes 30 MB off the top, so a
reported "64 MB" is 34 MB of index. Anyone comparing CHIME's cache axis against another
system's is comparing the wrong quantity.

### R6 — CHIME should have validated that byte-reduction was the right axis

Hopscotch neighbourhoods, `SPECULATIVE_READ` and `METADATA_REPLICATION` are three
independent mechanisms all shrinking the size of a read whose cost is nearly
size-independent. **One microbenchmark — latency versus read size on the target fabric —
would have shown that a 70 B and a 500 B read cost nearly the same** and redirected the
design budget toward removing crossings instead.

Our leaf-cache first cut is the controlled experiment CHIME never ran: it shrank a scan's
per-leaf transfer roughly 40× and **lost 41% throughput**.

---

## 5. Open items for CHIME

| Item | Why | Cost |
|---|---|---|
| **`[CORRECTNESS]` check on `leafstudy2`** | Not carried in the summary CSV, and this is the first run of a path interleaving several leaves' seqlock brackets in one doorbell. `lookup found %` and `scan rows returned` must match between `leaf_0` and `leaf_1` | Minutes |
| **`CHIME_LEAF_ADMIT_SCAN=0.1`** | Closes range-uniform's remaining −21%. At 12% hit rate ~88% of covered leaves are misses, each paying a ~480 B allocation + memcpy + LFU for a leaf never revisited. Still at default 1.0 so batching could be attributed alone — it now can be | Range cells only |
| **One sweep spanning 16 → 512 MB in a single configuration** | Extends the lever map below inner = 32 and joins it to the stress sweep, which uses different threads and value size and **must not be spliced** | One sweep |
| **Sweep `CHIME_OFFLOAD_MIN_LEVEL` {1, 2, 3}** | The gate ablation; directly answers the "memory-side CPU is scarce" objection. At level 2 an RPC replaces only ~2 crossings and may not beat them — the break-even is empirical | Runtime only |
| **Identify the 2 skipped cells** (`ran=62 skipped=2`) | Confirm they came from this binary; the previous study carried the same footnote unresolved | Minutes |
| `LEAF_CACHE_PCT` {25, 50, 75} | Finds the best split between the two caching sub-levers; 50 was assumed, never tested | Runtime only |
| **Write-mixed workload** | Every measured cell is read-only, so `[LEAFCACHE] stale=0` throughout — **the coherence protocol has never once fired.** The stamp path is exercised but idle | New cell |
| **Masked-CAS emulation** | `DSM::cas_mask_sync` = read + plain CAS under a *process-local* mutex; true masked atomics need MLNX experimental verbs this rdma-core cluster lacks. The leaf cache's correctness rests on the leaf lock, so **cross-node concurrent writers are outside what this port guarantees.** Pre-existing port debt, but it bounds every correctness claim | Blocked on verbs |
| Correctness checking is found/not-found only | Would not catch a stale *value* for a live key. Must be strengthened before the write-mixed cell means anything | Small |
