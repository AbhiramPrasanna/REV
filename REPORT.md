# REV — expanding the operating point of a disaggregated index

**Baseline · Implementation · Results · Recommendations**

Every disaggregated-memory index in this study has an **operating point**: a region of
cache budget and workload skew inside which it performs well, and outside which it
collapses. The region is defined by one question — *does the working set fit?* — and
both baselines answer it badly in different ways.

The collapse is not a tuning failure. It is structural, and it follows from one fact:
**a cache changes how often an operation crosses the network; it never changes what a
crossing costs.** When the cache stops fitting, the crossings come back at full price,
all of them, serially.

REV attacks the price rather than the frequency. It lets the memory node execute index
work — but only after the compute-side cache has already failed, so scarce memory-side
CPU is never spent on work a single one-sided read would have done. The result is not
mainly that the peak gets higher. **It is that the cliff goes away**: performance stops
depending on fit, and the systems become usable in the regimes where they previously
were not.

> **On honesty in the framing.** The operating-point expansion is carried by measured
> data for CHIME (§3.1) and DEX (§3.2). It is **not** carried by CHIME's leaf cache,
> which is a point-lookup win and a measured scan *regression* — §3.4 reports that as
> it stands, because it turns out to be evidence *for* the thesis rather than against
> it. §4 says what to run before any of this reaches a draft.

Mechanism-level detail for everything below is in
**[IMPLEMENTATION.md](IMPLEMENTATION.md)**; this document is the argument.

---

## 1. Baseline — two different fragilities, one shared cause

### 1.1 The shared cause

All three baselines treat the memory node as dumb memory: every index operation runs
entirely on the compute node, so every cache miss is paid at network latency, serially,
once per tree level and once per leaf.

Caching is the only lever, and caching has a hard ceiling — **it can only remove
crossings for data it can hold.** The moment the working set exceeds the budget, the
lever stops working, and it stops working *abruptly*, because a miss costs the full
descent rather than a fraction of one.

Each baseline hits that ceiling in its own way.

### 1.2 CHIME's fragility is a data-structure problem

CHIME's compute cache holds **internal nodes only**. This is a deliberate choice —
inner nodes need no coherence, since a stale one lands you at the wrong leaf and you
retry — but it means the system's entire fate rests on the inner index fitting.

Two design decisions compound it at the sweep geometry:

- `leafSpanSize = internalSpanSize = 16`, chosen so that an internal node (319 B) is
  smaller than a leaf (979 B). The cost is **fanout 16**, which makes the tree ~6–7
  levels deep instead of ~4. The measured logs show **the root at level 7.**
- The index working set is **~84 MB** at 50 M keys, and the nominal cache is not all
  index: `SPECULATIVE_READ` takes `kHotspotBufSize` = 30 MB off the top whenever the
  nominal budget exceeds 50 MB, so a "64 MB" cache gives `TreeCache` only **34 MB**.

So a miss is not slightly worse than a hit — it is catastrophically worse:

| | round trips |
|---|---:|
| cache **hit** | 1 leaf read |
| cache **miss** | ~6 internal reads + 1 leaf read ≈ **7** |

**That 7× cliff is CHIME's operating point.** Above ~84 MB of *effective* index cache
it is fine; below it, every missed op pays seven crossings. And the cliff is sharp —
measured in the `leafstudy` sweep, baseline point-uniform:

| cache | 512 MB | 256 MB | 128 MB | **64 MB** |
|---|---:|---:|---:|---:|
| Mops | 2.307 | 2.307 | 2.307 | **0.566** |

Flat, flat, flat, then a **4.1× collapse in one step.** A separate, independently
configured stress sweep (24 threads, 48 B values, 16/32/64 MB) measures the floor below
that cliff at 0.538–0.585 Mops — i.e. once you are off the edge, spending 4× less cache
costs nothing more, because you were already paying full price for everything.

The stress sweep also confirms the gate is doing exactly what it should: measured
offload fraction tracks predicted miss rate `1 − effective/84 MB` three times out of
three (64 MB: 60% predicted / 63.2% measured; 32 MB: 62% / 65.2%; 16 MB: 81% / 82.5%).
Nothing anomalous is happening — **offload fires often because the cache misses often.**

### 1.3 DEX's fragility is that leaf caching cannot be bought

DEX does cache leaves, which is precisely why it is the more interesting case: it shows
that **adding leaves to the cache does not fix the problem, because leaf caching is the
expensive kind and its working set is unbounded.**

DEX's own design concedes this. Its lazy-admission policy sets the admission probability
`P_A = 1.0` for inner nodes but **`P_A = 0.1` for leaves** — a nine-in-ten refusal to
cache a leaf it just fetched, on the grounds that admitting it would evict something
hotter and that provisioning the frame may trigger a writeback. That is DEX telling you,
in its own parameters, that leaf caching mostly does not pay.

The reason is arithmetic. At 50 M keys there are millions of leaves, and **under a
uniform workload every one of them is equally likely.** There is no hot set to capture,
so cache budget converts into hit rate at a terrible exchange rate. The measured network
counters show it directly — `rdma_read_per_op`, offload off, across an **8× cache
increase** (64 → 512 MB):

| workload | 64 MB | 512 MB | reads removed by 8× more cache |
|---|---:|---:|---|
| lookup / uniform | 6.79 | 3.34 | 2.0× |
| lookup / zipf | 4.18 | 1.54 | 2.7× |
| **range / uniform** | **22.35** | **16.88** | **1.32×** |
| range / zipf | 15.31 | 9.29 | 1.65× |

**Eight times the memory buys a 32% reduction in crossings on uniform scans.** Even at
512 MB a uniform lookup still pays 3.34 remote reads. The cache never converges, because
it is chasing a working set that does not have a hot core.

Skew is the only thing that rescues it — zipf gives a hot set worth holding — which is
why DEX-under-uniform is the pathological corner and DEX-under-zipf is not.

### 1.4 The two fragilities are the same shape

| | CHIME | DEX |
|---|---|---|
| What it caches | inner nodes only | inner **and** leaf pages |
| Failure mode | inner index doesn't fit → **7 crossings per miss** | leaf set is unbounded → **crossings never fall below ~3–17 per op** |
| Shape | a **cliff** at the fit boundary | a **floor** the cache cannot get under |
| Rescued by skew? | partly (hot inner path) | yes for points, barely for scans |
| Range scans | worst case: one crossing per covered leaf, uncacheable | worst case: same, and `P_A = 0.1` means they are barely cached at all |

Both reduce to: *you must fit, or you pay full price.* **The operating point is defined
by fit, and neither system has any lever other than buying more memory** — which is
exactly the resource disaggregation was supposed to let you stop over-provisioning.

DART, the untouched control, is the reference for what "no memory-node CPU" costs: flat
and moderate everywhere, never collapsing and never excelling.

---

## 2. Implementation — decoupling performance from fit

Three techniques. The first makes spending memory-node CPU defensible; the second is
where the win comes from; the third is what made the CHIME port expensive.

### 2.1 Execution gated on cache misses

The memory node never repeats work the compute node could have done in one read. This
is what makes the whole approach compatible with the premise that memory-side CPU is
scarce: **the MN is idle exactly when the cache is working, and busy exactly when it is
not.**

In CHIME the gate is `CHIME_OFFLOAD_MIN_LEVEL = 2`. `level == 1` *is* the leaf —
internals are level ≥ 2 — so a boundary at level 1 means the cache resolved the whole
descent and handed back a leaf address. Offloading that would ask a directory core to
perform the single read one-sided RDMA does with **zero** memory-node CPU: strictly
worse, and it burns the core budget genuine misses need. Since only level-1 nodes are
cached, a cache hit *cannot* pass the gate — miss-gating is enforced structurally, not
by policy.

Scans gate on coverage instead of level: a complete cache miss pushes the whole scan
down; a partial hit serves the covered prefix locally and offloads only the uncovered
tail; a full hit never offloads.

In DEX the gate already existed as an adaptive latency model. REV adds
`-DMANUAL_PUSHDOWN`, which disables it so `rpc_rate` becomes the exact fraction of
eligible misses pushed down — turning the offload ratio from a policy the system
overrides into an axis that can be swept. Without the flag the build is byte-for-byte
upstream.

### 2.2 Batched leaf traversal

This is what collapses the crossings the baselines could not remove.

**DEX** gains a `SCAN` RPC and `cachepush::range_scan`, which walks the sibling chain in
local memory and packs up to `max_num` pairs into a per-requester scratch slot in the
DSM region. **One RPC covers several leaves; the compute node pulls the whole batch with
one RDMA read** — in place of one read per leaf. The reply carries the count, the resume
boundary, and the slot address.

**CHIME** gains the same, plus `chime_offload::lookup_from` — a *cache-boundary*
pushdown where the MN walks every remaining internal level **and** the leaf locally. On
CHIME's 7-level tree that is the 7 → 1 collapse in §1.2, and it is the single largest
source of the win.

Both scanners follow the sibling chain only while it stays on the issuing memory node;
a pointer that leaves returns control to the compute node, mirroring DEX's
subtree-placement condition and avoiding remote pointer chasing between MNs.

### 2.3 Decoding nodes in the index's own format

DEX stores plain structs in DSM, so its memory node casts `dsm_base + offset`. **CHIME
does not.** Its leaves are version-encoded on the wire — every 64-byte line is 63 bytes
of payload plus one version byte — and, with `METADATA_REPLICATION`, scattered into
per-group metadata copies rather than one header.

So the CHIME memory node runs the index's own decoders: snapshot → version check →
un-scatter → retry on mismatch. The snapshot must come first, because comparing version
bytes in place lets a writer land another cacheline between the comparison and the read.
This preserves CHIME's torn-read detection under concurrent one-sided writers.

It is also the generalisable claim: **pushdown does not require the index to store naked
structs, only that the memory node speak the index's encoding.**

### 2.4 CHIME's leaf cache

Because CHIME caches internal nodes only, REV also adds a compute-side cache of decoded
**leaf** images, carved *out* of the same total budget — never grown, so it must earn its
share against the inner nodes it displaces, and DART is swept at identical totals.

Serving a leaf from DRAM is the one read in CHIME that is not self-validating, so it
needs coherence: an 8-byte never-reused **stamp** per leaf, published by the writer under
the leaf lock before any data byte moves, checked by the reader with one 24-byte
`[lock, stamp]` probe before every hit. A fill closes the same seqlock around the data
read as a single three-request doorbell, so **a fill costs the one round trip the
uncached read would have cost anyway.**
([IMPLEMENTATION.md §5](IMPLEMENTATION.md#5-the-leaf-cache--how-it-is-actually-done).)

At the default gate the two mechanisms partition the work:

> **Offload serves the index misses; the leaf cache serves the index hits.**

---

## 3. Results — the operating point expands

### 3.1 CHIME: the cliff flattens

Cache-stress sweep, cluster throughput, 50 M keys, 50 M ops, 24 threads/node,
`scan_range 100`. The three cache points (64/32/16 MB) all sit **below** the ~84 MB
fit boundary — i.e. entirely inside the collapsed regime of §1.2.

| workload @ 64 MB | offload off | offload on | gain |
|---|---:|---:|---:|
| point / uniform | 1.19 | 2.50 | **2.1×** |
| point / zipf | 2.11 | 2.84 | 1.3× |
| range / uniform | 0.069 | 0.437 | **6.3×** |
| range / zipf | 0.133 | 0.580 | **4.4×** |

p99: point 92 → 31 µs. Range-off p99 reads `1000.00` — **censored**, the histogram caps
at 1 ms — against 181 µs with offload, so that improvement is a *lower bound*.

The operating-point result is not in that table, though. It is this:

**Offload makes CHIME nearly cache-size-insensitive.** Going from 64 MB to 16 MB — a 4×
cut — costs only **8%** on point/uniform and **17%** on range/uniform once offload is on.
And the direct comparison that matters for provisioning:

| workload | 64 MB, **no** offload | 16 MB, **with** offload | |
|---|---:|---:|---|
| point / uniform | 0.568 | 1.136 | **2.0× faster on ¼ the cache** |
| range / uniform | 0.035 | 0.179 | **5.2× faster on ¼ the cache** |

*(compute-node figures, so both columns are measured the same way)*

That is the expansion stated plainly: **a stressed 16 MB cache with offload beats a
comfortable 64 MB cache without it, in every workload.** The system stopped depending on
fit.

### 3.2 DEX: the floor drops

Measured sweep, 32 compute threads / 4 memory threads, 50 M keys, scan length 100.

Offload off → on, throughput in Mops:

| Cache | uniform, off | uniform, **on** | | zipf, off | zipf, **on** | |
|---:|---:|---:|---:|---:|---:|---:|
| **range** 64 MB | 0.421 | 0.903 | 2.15× | 0.596 | 1.291 | 2.17× |
| **range** 512 MB | 0.555 | 1.456 | **2.62×** | 0.948 | 2.371 | **2.50×** |
| **lookup** 64 MB | 1.290 | 2.171 | 1.68× | 2.044 | 3.299 | 1.61× |
| **lookup** 512 MB | 2.524 | 4.933 | 1.95× | 5.056 | 8.661 | 1.71× |

The mechanism is the crossing count, and it is unambiguous (512 MB):

| workload | reads/op off | reads/op on | RPCs/op | total crossings |
|---|---:|---:|---:|---|
| range / uniform | 16.88 | 4.26 | 1.375 | 16.9 → 5.6 (**3.0× fewer**) |
| range / zipf | 9.29 | 2.22 | 0.945 | 9.3 → 3.2 (**2.9× fewer**) |
| lookup / uniform | 3.34 | 0.0008 | 0.997 | 3.3 → 1.0 (**3.3× fewer**) |

`rpc_per_op ≈ 1.4` on uniform scans against **22.35 reads/op** in the baseline is §1.3's
floor being removed: the thing 8× more cache could not fix, one RPC does. And on point
lookups at 512 MB `rdma_read_per_op` collapses from 3.34 to **0.0008** — the cache holds
the inner path and a single RPC ships an 8-byte value instead of a 512 B–1 KB page. Page
shipping became result shipping.

**The provisioning statement, as in §3.1** — offload at one-eighth the cache against
caching at full cache:

| workload | off @ 512 MB | **on @ 64 MB** | |
|---|---:|---:|---|
| range / uniform | 0.555 | 0.903 | **1.63× faster on ⅛ the cache** |
| range / zipf | 0.948 | 1.291 | **1.36× faster on ⅛ the cache** |
| lookup / uniform | 2.524 | 2.171 | 0.86× — nearly matches |
| lookup / zipf | 5.056 | 3.299 | 0.65× — does not |

**For scans, offloading is strictly better than eight times the memory.** For uniform
point lookups it very nearly is. For zipf point lookups it is not — and that exception
is the thesis working, not failing: see §3.3.

Tail latency moves with throughput (p99, 512 MB): range-uniform 95.0 → 58.0 µs (−39%),
range-zipf 92.5 → 53.0 µs (−43%), lookup-uniform 28.5 → 14.0 µs (−51%), lookup-zipf
26.5 → 12.5 µs (−53%).

**Against DART** (ratio of DEX-offload-on to DART): offload-*off* DEX never catches DART
on any cell. With offload, DEX leads from 256 MB on three of four workloads — 1.83× and
1.78× on point lookups, 1.05× and 1.08× on scans, reaching **2.02×** (point-zipf) and
**1.37×** (range-zipf) at 512 MB. Two caveats: DART's uniform scan jumps anomalously to
1.676 at 512 MB only (flat ~1.13 elsewhere), which is the one cell DEX-on does not take;
and DART's zipf lookup at 128 MB (2.655 against 4.29/4.27/4.28 elsewhere) is an outlier
that inflates that one ratio. **And see §4.1 — the DART baseline was not run at matched
thread counts.**

### 3.3 Where the operating point does *not* expand, and why that is the point

The gains are not uniform, and their ordering is predictable:

| case | gain | crossings the cache left behind |
|---|---:|---|
| CHIME range / uniform @ 64 MB | **6.3×** | deep tree **and** many leaves — the most |
| CHIME range / zipf | 4.4× | many leaves, warmer path |
| DEX range / uniform | 2.6× | many leaves, shallow tree |
| CHIME point / uniform | 2.1× | 7-level descent |
| DEX lookup / zipf | 1.7× | hot path largely cached already |
| **CHIME point / zipf** | **1.3×** | cache already works — **little left to remove** |

**The size of the win is set by the round trips remaining after the cache runs out.**
Where caching already succeeds — CHIME point/zipf, DEX lookup/zipf — there is little
left to take, and offload correctly does almost nothing. Where caching structurally
cannot succeed — any uniform scan — the win is largest.

This is why the exception in §3.2 (zipf point lookups, where 8× cache beats offload) is
*confirmation*: skew makes the working set cacheable, caching is the right tool, and the
gate keeps the memory node out of the way.

### 3.4 The leaf cache — the same principle, turned against us

| Workload | Cache | Leaf hit | Baseline | + leaf cache | Δ |
|---|---:|---:|---:|---:|---:|
| point / zipf-0.99 | 512 MB | 69.9% | 2.857 | 3.999 | **+40%** |
| point / uniform | 512 MB | 12.3% | 2.307 | 2.608 | +13% |
| range / uniform | 512 MB | 12.2% | 0.496 | 0.293 | **−41%** |
| range / zipf-0.99 | 512 MB | 59.0% | 0.496 | 0.423 | **−15%** |

**It loses on scans even at a 59% hit rate**, which rules out "too small" and points at
the design. The first cut served each covered leaf on its own — one guard probe per
resident leaf, one bracketed read per missing leaf — which **preserved the baseline's
crossing count** and only shrank the bytes, while adding a ~480-byte entry allocation per
miss. Under uniform, 88–94% of covered leaves are misses, so fill overhead dominated.

Points won anyway because the point *baseline*'s per-leaf cost is variable and often more
than one crossing (speculative-read mis-guesses falling back to a full hopscotch search,
`read_leaf_retry`, `read_two_segments`). The range baseline was already exactly one
crossing per leaf, so there was nothing to remove.

**That is the thesis stated as a negative result.** Removing bytes without removing
crossings buys nothing and costs bookkeeping. The fix — batching all covered leaves into
two doorbells, 12 crossings → **2** — is committed (`15070de`) but **not yet run**.

### 3.5 What the three results say together

| | can it remove crossings? | measured outcome |
|---|---|---|
| Caching alone | No — only their frequency, and only for what fits | CHIME collapses 4.1× at its fit boundary; DEX's uniform-scan crossings fall just 1.32× for 8× cache |
| Miss-gated pushdown | **Yes** | CHIME 2.1–6.3× and near cache-insensitive; DEX 1.6–2.6×, and on scans better than 8× the memory |
| Leaf caching without batching | No — shrinks bytes only | +40% where the baseline exceeded one crossing per leaf, **−41% where it was exactly one** |

**One finding: performance on this fabric is governed by crossings, and the value of any
technique is the number of crossings it removes from the post-cache remainder.** Caching
is a frequency lever with a hard ceiling at the fit boundary; pushdown is a cost lever
with no such ceiling. That is why pushdown expands the operating point and more cache
merely moves along it.

---

## 4. Recommendations

### 4.1 Two measurements that gate every claim above

1. **Run the batched scan path.** The §3.4 fix is committed and unmeasured, and the CHIME
   scan story rests on it. Build on the cluster, then verify `[CORRECTNESS] lookup found %`
   and scan rows are **identical** to `CACHE_LEAF=0`, offload off and on — a difference
   means the cached-image path returns different results from the remote path, which is a
   bug, not noise. Only then sweep `CHIME_LEAF_ADMIT_SCAN`; measure batching alone first,
   since two knobs moving at once cannot be attributed.

2. **Re-run DART at matched thread counts.** This is a live methodological hole:
   - The DEX↔DART comparison pairs DEX at **32** compute threads against
     `cache_sweep_baseline_20260615_125117.csv`, which was actually run at **56** threads
     — despite `COMPARISON.md` describing the intent as matched at 32. DEX is beating a
     *better-provisioned* DART, so the crossover is if anything understated, but it is
     not clean.
   - The CHIME↔DART comparison pairs `20260622_071147.csv` (34/36 threads on one machine)
     against CHIME running the same binary on both nodes, i.e. **68** client threads.

   The asymmetries run in opposite directions. Re-run DART at 32 threads for the DEX
   figures and at 17/node-equivalent for CHIME, or state thread counts inline everywhere
   a ratio appears. **Do not publish a bare "N× DART" number until one is done.**
   `COMPARISON.md` currently asserts the matched-at-32 version and should be corrected.

### 4.2 The measurement that would make the argument complete

**Sweep CHIME across the fit boundary with offload on and off.** Everything in §3.1 is
measured *below* the cliff (16/32/64 MB) and everything in §1.2's cliff table is measured
*at and above* it (64–512 MB) — in two sweeps with different thread counts and value
sizes. Nobody has yet run one sweep spanning 16 → 512 MB in a single configuration.

That single figure — throughput vs cache, offload off vs on, with the ~84 MB fit boundary
marked — **is the paper's central plot.** It shows the baseline's cliff and the offload
curve flattening straight through it. Right now it has to be argued across two studies
instead of read off one.

### 4.3 What to claim

- **Lead with the operating point, not the speedup.** "A stressed 16 MB cache with
  offload beats a comfortable 64 MB cache without it" and "on scans, offloading beats
  eight times the memory" are the claims that matter, because they are about
  provisioning — which is the thing disaggregation exists to fix.
- **Lead with crossings, not throughput.** "Network operations per op fall ~3×, and
  throughput follows at ~2.5×" is checkable against the counters. "2.5× faster" is not.
- **Use the gain ordering in §3.3 as a prediction, not a table.** That the win is largest
  where the cache leaves the most crossings, and smallest where caching already works, is
  the strongest evidence the mechanism is understood rather than merely observed.
- **Report the leaf-cache regression explicitly**, with the §3.4 mechanism. It supports
  the thesis, and omitting it invites exactly the question it already answers.
- **State the portability claim carefully.** `range_scan` and `lookup_from` are identical
  across both ports; only the decode differs. Pushdown needs the memory node to speak the
  index's encoding, not to have naked structs.
- **Do not claim multi-node concurrent-writer correctness** — see §4.5.

### 4.4 Experiments worth running next

| Experiment | Why | Cost |
|---|---|---|
| **CHIME 16 → 512 MB in one configuration** | §4.2 — the central figure | One sweep, runtime axis |
| Sweep `CHIME_OFFLOAD_MIN_LEVEL` ∈ {1, 2, 3} | The gate *is* the thesis in one knob, and its break-even is empirical: at level 2 an RPC replaces only ~2 crossings and may not beat them. The cleanest available ablation | Runtime only |
| Scan length ∈ {10, 100, 1000} | Batching's win should scale with leaves covered — the strongest predicted-and-unconfirmed result available | Runtime only |
| Sweep `LEAF_CACHE_PCT` ∈ {25, 50, 75} at pinned total | Finds the best inner/leaf **split**; 50 was assumed, never tested | Runtime only |
| `memThreadCount` × offload (DEX) | Where added memory-side capacity stops buying throughput — the resource-awareness argument's own limit | Needs `NR_DIRECTORY ≥ 8`, rebuild |
| A write-mixed workload | Every measured cell is read-only, so `[LEAFCACHE] stale=0` throughout: **the coherence protocol has never once fired.** | New workload cell |

### 4.5 Engineering debt, in priority order

1. **Masked-CAS emulation.** `DSM::cas_mask_sync` does a read plus a plain CAS serialised
   by a *process-local* mutex, because true masked atomics need MLNX experimental verbs
   this rdma-core cluster lacks. The leaf cache's correctness rests on the leaf lock, so
   **cross-node concurrent writers are outside what this port guarantees.** Pre-existing
   port debt, not new — but it bounds every correctness claim and belongs in the paper.
2. **Correctness checking is found/not-found only** — it would not catch a stale *value*
   for a key that still exists. Harmless while nothing writes, and exactly the check that
   must be strengthened before §4.4's write-mixed cell means anything.
3. **The path-aware miss counters read zero.** `PATH-AWARE CACHE MISSES` reports
   `inner-node read miss = 0` and `leaf-node read miss = 0` in the committed DEX logs, so
   §1.3's "leaf caching cannot be bought" argument currently rests on `rdma_read_per_op`
   and DEX's own `P_A = 0.1` rather than a direct measurement. **Fixing this counter would
   quantify the inner-vs-leaf caching cost directly** — it is the cheapest way to
   strengthen the baseline analysis.
4. **Synchronous RPCs.** `rpc_lookup`/`rpc_scan` block on `rpc_wait()` with no coroutine
   yield, so offloaded ops do not overlap under `kCoroCnt`. Every number in §3.2 is a
   floor.
5. **Scan scratch slot keying** (`app_id % MAX_APP_THREAD`) can collide across compute
   *nodes*. Harmless for load numbers; key by global thread id before trusting multi-CN
   scan results.
6. **Repository hygiene.** ~284 deleted files under `CHIME/results/` and ~17 untracked
   files including `paper/paper.tex` and `hybrid_plots/`. Resolve before the next results
   run or figure provenance will not be reconstructible.

### 4.6 One open naming decision

`notes.txt` proposes **LIFELINE** over REV: a lifeline is thrown only when someone is
already in trouble, which is exactly what miss-gating does. Given that §3.3's whole point
is that the mechanism does nothing when caching is working, it is the better name. If
adopted, the change is small — `paper/dex_vs_dart.tex:66` carries it in the title; the
other occurrences are `\graphicspath` paths and stay.

---

## Provenance

| Claim set | Source | Configuration | Status |
|---|---|---|---|
| §1.2 cliff (64–512 MB) | sweep `leafstudy` | 34 thr/node, 16 B values, compute-node | Measured |
| §1.2 floor, §3.1 | `CHIME/results/stress/summary_compute.csv` (`sweep_20260724_112339`) | 24 thr/node, 48 B values | Measured; cluster figures from `stress/CONCLUSIONS.md` |
| §1.3, §3.2 DEX | `dex/build/results/summary_full.csv` | 32 compute / 4 memory threads | Measured |
| §3.2 DART reference | `DART/cache_sweep_baseline_summary_20260615_125117.csv` | **56 threads** | Measured — see §4.1 |
| §3.4 leaf cache | sweep `leafstudy` | 34 thr/node, 16 B values | Measured; **pre-dates** the fix |
| §3.4 fix | commit `15070de` | — | Committed, **not compiled or run** |

**§1.2 and §3.1 come from two differently configured sweeps and are not spliced into one
curve** — that is precisely what §4.2 asks for. Not used anywhere:
`dex/8_dex_offload_vs_dart.csv`, whose 64–256 MB rows are marked `projected` rather than
`measured`. Every figure above is measured.
