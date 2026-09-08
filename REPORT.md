# REV — spending memory-node CPU only where caching has already failed

**Baseline · Implementation · Results · Recommendations**

Disaggregated-memory indexes are all accelerated the same way: cache part of the
index on the compute node and leave the memory node's CPU idle, because that CPU is
scarce. The limitation is structural. **A cache changes how often an operation crosses
the network; it never changes what a crossing costs.** A miss still pays a full remote
descent, and a range scan pays one crossing per leaf it touches.

REV takes the other half of the hierarchy seriously. It lets the memory node execute
index work — but only after the compute-side cache has failed, so the scarce resource
is never spent on work a single one-sided read would have done. Built across three
systems (DEX, CHIME, DART as the untouched control), the result is that operations the
baselines could not accelerate at all — **range scans above all** — become the place
where the technique pays most.

> **On the framing.** This document is organised as "here is what the baselines could
> not do, and here is us doing it." That story is fully carried by the measured DEX
> data in §3.1 and by CHIME's offload data in §3.2. It is **not** carried by CHIME's
> leaf cache, which is a point-lookup win and a measured scan *regression*. §3.3
> reports that as it stands rather than omitting it, and §4 says what to do about it.
> A claim that survives a reviewer is worth more than a clean-looking one that does
> not.

Mechanism-level detail for everything below is in
**[IMPLEMENTATION.md](IMPLEMENTATION.md)**; this document is the argument, not the
reference.

---

## 1. Baseline — what the three systems could not do

### 1.1 The shared limitation

All three baselines treat the memory node as dumb memory. Every index operation runs
entirely on the compute node, which means every cache miss is paid at network latency,
serially, once per tree level and once per leaf.

That is defensible for point lookups: a miss costs *h* round trips, and a good cache
makes misses rare. It is indefensible for **range scans**, where even a perfect index
cache leaves one round trip per covered leaf — and a 100-key scan over 16-entry leaves
covers a dozen or more. Caching cannot help, because the leaves being scanned are
precisely the ones the workload does not revisit.

### 1.2 Where each baseline stopped

| System | Compute-side cache | Memory-node CPU | The gap |
|---|---|---|---|
| **DEX** (PVLDB 17(10)) | Path-aware, inner **and** leaf pages | Cost-aware pushdown of `LOOKUP`, `UPDATE`, `INSERT`, `DELETE` | **No range-scan pushdown.** §7 of the paper explicitly subdivides a multi-leaf scan into *multiple lookups* using fence keys, because DEX keeps no sibling links on the compute side. Scans pay the pushdown decision once per leaf and never ship a batch |
| **CHIME** | **Internal nodes only** | None. Every access is one-sided | **No pushdown of any kind, and no leaf caching.** The last hop — the leaf — is *always* a remote read |
| **DART** | ART + skip-table, per-thread | None by construction: `memory.cc` sets up queue pairs, sends `ready`, then blocks on a socket for the whole run | Control arm. Deliberately unmodified |

### 1.3 CHIME's version of the problem is the sharpest

CHIME spends a great deal of design on making the last round trip *cheap*: hopscotch
leaves confine a key to an 8-entry window; `SPECULATIVE_READ`'s hotspot buffer shrinks
the read to a single entry; `METADATA_REPLICATION` makes a segment read
self-describing.

Every one of those optimises the **bytes**. None removes the **round trip**. On this
fabric a 70-byte read and a 500-byte read cost nearly the same. That is the structural
reason CHIME stays behind DART under skew no matter how large the index cache gets:
DART's per-op cost is flat and low, and CHIME pays one full RTT per lookup *on top of
a perfect cache hit*.

**So the baselines share one blind spot, and it is not cache management. It is that
the cost of a crossing is fixed and nobody is allowed to remove crossings.**

---

## 2. Implementation — what REV adds

Three techniques, applied to both indexes. The first is what makes spending memory-node
CPU defensible; the second is where the win comes from; the third is what made porting
to CHIME expensive.

### 2.1 Execution gated on cache misses

The memory node never repeats work the compute node could have done in one read.

In CHIME this is `CHIME_OFFLOAD_MIN_LEVEL = 2`. `level == 1` *is* the leaf — internals
are level ≥ 2 — so a boundary at level 1 means the cache already resolved the entire
descent and handed back a leaf address. Offloading that would ask a directory core to
perform the single read one-sided RDMA does with **zero** memory-node CPU: strictly
worse, and it burns the core budget the genuine misses need. Gating at level 2 means
*offload only on a cache miss*.

Scans are gated on coverage rather than level: a complete cache miss pushes the whole
scan down; a partial hit serves the covered prefix locally and offloads only the
uncovered tail; a full hit never offloads.

In DEX the equivalent gate already existed as an adaptive latency model. REV adds
`-DMANUAL_PUSHDOWN`, which disables the adaptive policy so `rpc_rate` becomes the exact
fraction of eligible misses pushed down — turning the offload ratio from a policy the
system overrides into an experimental axis that can be swept. Without the flag the
build is byte-for-byte upstream.

### 2.2 Batched leaf traversal

This is the technique that closes the gap the baselines could not.

**DEX** gains a `SCAN` RPC (`RpcType::SCAN`) and a memory-node scanner,
`cachepush::range_scan`, that walks the sibling chain in local memory and packs up to
`max_num` pairs into a per-requester scratch slot in the DSM region. **One RPC covers
several leaves, and the compute node pulls the entire batch with one RDMA read** — in
place of one read per leaf. The reply carries the count, the resume boundary
(`max_limit_` of the last leaf visited), and the slot address.

**CHIME** gains the same via `chime_offload::range_scan`, plus
`chime_offload::lookup_from`, which is a *cache-boundary* pushdown: the memory node
walks every remaining internal level **and** the leaf locally, so a descent that would
have cost *k* remote reads costs one RPC. That is why offload's benefit grows as the
cache shrinks.

Both scanners follow the sibling chain only while it stays on the issuing memory node;
a pointer that leaves returns control to the compute node. This mirrors DEX's
subtree-placement condition and avoids remote pointer chasing between memory nodes.

### 2.3 Decoding nodes in the index's own format

DEX stores plain structs in DSM, so its memory node casts `dsm_base + offset` and is
done. **CHIME does not.** Its leaves are version-encoded on the wire — every 64-byte
line is 63 bytes of payload plus one version byte — and, with `METADATA_REPLICATION`,
scattered into per-group metadata copies rather than one header.

So the CHIME memory node runs the index's own decoders:

```c
memcpy(s.raw, dsm_base + addr.offset, define::transLeafSize);   // snapshot first
if (!LeafVersionManager::decode_node_versions(s.raw, s.inter))
    return false;                                               // torn -> retry
MetadataManager::decode_node_metadata(s.inter, s.dec);          // un-scatter
```

The snapshot must come first: you cannot compare version bytes in place, because a
writer could land another cacheline between the comparison and the read, leaving you
having validated bytes you did not use. This preserves CHIME's torn-read detection
under concurrent one-sided writers, and it is the reason the CHIME port cost far more
to write than the DEX one. It is also the generalisable claim — **pushdown does not
require the index to store naked structs, only that the memory node speak the index's
encoding.**

### 2.4 CHIME's leaf cache (the fourth piece, and the mixed one)

Because CHIME caches internal nodes only, REV also adds a compute-side cache of
fully decoded **leaf** images, carved *out* of the same total budget
(`CHIME_CACHE_MB`, split by `CHIME_LEAF_CACHE_PCT`, never grown — so it must earn its
share against the inner nodes it displaces, and DART is swept at the same totals).

Serving a leaf from DRAM is the one read in CHIME that is not self-validating, so it
needs a coherence protocol: an 8-byte, never-reused **stamp** per leaf, published by
the writer under the leaf lock before any data byte moves, and checked by the reader
with one 24-byte `[lock word, stamp]` probe before every hit. A fill closes the same
seqlock around the data read as a single three-request doorbell, so **a fill costs the
one round trip the uncached read would have cost anyway.** Full protocol and its
correctness argument: [IMPLEMENTATION.md §5](IMPLEMENTATION.md#5-the-leaf-cache--how-it-is-actually-done).

The two mechanisms divide the work rather than compete. At the default gate:

> **Offload serves the index misses; the leaf cache serves the index hits.**

---

## 3. Results

### 3.1 DEX — the headline, and it is the range scans

Measured sweep, `dex/build/results/summary.csv`: 2 nodes, 32 compute threads,
4 memory threads, 50 M keys, zipf θ = 0.99, scan length 100. Throughput in Mops.

**Range scans — the operation the baseline could not offload at all:**

| Cache | uniform, offload off | uniform, **on** | speedup | zipf, off | zipf, **on** | speedup |
|---:|---:|---:|---:|---:|---:|---:|
| 64 MB | 0.421 | **0.903** | 2.15× | 0.596 | **1.291** | 2.17× |
| 128 MB | 0.445 | **1.011** | 2.27× | 0.672 | **1.526** | 2.27× |
| 256 MB | 0.484 | **1.184** | 2.45× | 0.780 | **1.856** | 2.38× |
| 512 MB | 0.555 | **1.456** | 2.62× | 0.948 | **2.371** | 2.50× |

**A consistent 2.1–2.6× on scans, and the advantage widens with cache size** — because
a larger cache resolves more of the descent, leaving a higher fraction of the remaining
cost in exactly the leaf traversal the batch collapses.

Point lookups improve too, by less: 1.68–1.95× (uniform) and 1.61–1.71× (zipf).

**The mechanism is visible directly in the network counters:**

| Workload @ 512 MB | reads/op off | reads/op on | RPCs/op on | total network ops |
|---|---:|---:|---:|---|
| range / uniform | 16.88 | 4.26 | 1.375 | 16.9 → 5.6 (**3.0× fewer**) |
| range / zipf | 9.29 | 2.22 | 0.945 | 9.3 → 3.2 (**2.9× fewer**) |
| lookup / uniform | 3.34 | 0.0008 | 0.997 | 3.3 → 1.0 (**3.3× fewer**) |

`rpc_per_op ≈ 1.4` on uniform scans against ~17–22 reads/op in the baseline is the
whole argument in one number: **a 100-key scan that cost roughly twenty serial page
reads now costs about 1.4 RPCs plus a handful of reads.** And on point lookups at
512 MB, `rdma_read_per_op` collapses from 3.34 to 0.0008 — the cache holds the inner
path and the single RPC ships an 8-byte value instead of a 512 B–1 KB page. Page
shipping has become result shipping.

**Tail latency moves with it** (p99, 512 MB): range-uniform 95.0 → 58.0 µs (−39%),
range-zipf 92.5 → 53.0 µs (−43%), lookup-uniform 28.5 → 14.0 µs (−51%), lookup-zipf
26.5 → 12.5 µs (−53%).

**Against DART**, the zero-memory-CPU control (ratio of DEX-offload-on to DART):

| Cache | lookup / uniform | lookup / zipf | range / uniform | range / zipf |
|---:|---:|---:|---:|---:|
| 64 MB | 0.80× | 0.77× | 0.80× | 0.74× |
| 128 MB | **1.17×** | 1.81× | 0.91× | 0.88× |
| 256 MB | **1.83×** | **1.78×** | **1.05×** | **1.08×** |
| 512 MB | **1.94×** | **2.02×** | 0.87× | **1.37×** |

Offload-*off* DEX never catches DART on any cell. **Offloading is what makes DEX
competitive, and it is the only reason DEX passes DART at all.** Once the cache holds
the inner working set (≈256 MB), DEX-on leads on three of four workloads and reaches
2.0× on point-zipf and 1.37× on range-zipf.

Two honest qualifications on that table:

- **Range-uniform at 512 MB is the one regression in the crossover**, and it is DART
  that moves, not DEX: DART's uniform scan jumps from ~1.13 to 1.676 Mops only at
  512 MB while being flat everywhere else. Treat that single point as suspect until
  it is re-run.
- **DART's zipf lookup at 128 MB (2.655) is an outlier** against 4.29 / 4.27 / 4.28 at
  the other three cache points. The 1.81× at that cell is inflated by DART's dip, not
  by DEX.

### 3.2 CHIME offload — it rescues the regime it was built for

Sweep `leafstudy`, per-node compute throughput, 34 threads/node, 50 M keys, 16 B values.

Offload is **inert at large caches** — the index fits, so there are no misses to push
down — and that is the design working as intended. Where it pays is exactly where the
baseline breaks down:

| Cell (leaf cache on) | offload off | offload on | |
|---|---:|---:|---|
| point-zipf, 128 MB total | 1.111 | **3.157** | 2.8× |
| point-zipf, 64 MB total | 1.200 | **3.157** | 2.6× |
| range-zipf, 128 MB total | 0.120 | **0.355** | 3.0× |
| range-uniform, 128 MB total | 0.066 | **0.241** | 3.7× |

This is the composition the design intended: halving the inner cache to make room for
leaves pushes the arm across the "index no longer fits" boundary, and **offload serves
precisely the index misses that created.**

### 3.3 CHIME leaf cache — a point-lookup win and a scan regression

| Workload | Cache | Leaf hit | Baseline | + leaf cache | Δ |
|---|---:|---:|---:|---:|---:|
| point / zipf-0.99 | 512 MB | 69.9% | 2.857 | 3.999 | **+40%** |
| point / zipf-0.99 | 256 MB | 63.5% | 2.857 | 3.999 | **+40%** |
| point / uniform | 512 MB | 12.3% | 2.307 | 2.608 | +13% |
| range / uniform | 512 MB | 12.2% | 0.496 | 0.293 | **−41%** |
| range / uniform | 256 MB | 6.1% | 0.496 | 0.279 | **−44%** |
| range / zipf-0.99 | 512 MB | 59.0% | 0.496 | 0.423 | **−15%** |

p99 improves on points (21.0 → 17.0 µs at 512 MB) and degrades on scans
(82.0 → 157.5 µs).

**It loses on scans even at a 59% hit rate**, which rules out "the cache is too small"
and points at the design. The cause is the same principle that motivates the whole
project, turned against us: the first cut served each covered leaf on its own — one
guard probe per resident leaf, one bracketed read per missing leaf — which preserved
the baseline's **round-trip count** and only shrank the bytes, while adding a ~480-byte
entry allocation per miss. Under uniform, 88–94% of covered leaves are misses, so fill
overhead dominated outright.

Points win anyway because the point *baseline*'s per-leaf cost is variable and often
more than one round trip (speculative read mis-guesses and falls back to a full
hopscotch search; `read_leaf_retry` on version mismatch; `read_two_segments` when the
hop window wraps). The range baseline was already exactly one round trip per leaf, so
there was nothing to remove.

**The fix is written and committed (`15070de`) but not yet run.** `Tree::range_query`
now issues two doorbells regardless of leaf count — one batch of guard probes for every
resident leaf, one batch of bracketed reads for the rest — taking a 12-leaf scan from
12 round trips to **2**; plus per-path admission ratios so streaming scans stop paying
for entries they never revisit. Both default to no-behaviour-change on purpose, so
batching can be attributed before admission is swept.

### 3.4 What the three results say together

| | can it remove round trips? | measured outcome |
|---|---|---|
| Compute-side caching alone | No — only their frequency | DEX-off never catches DART; CHIME stays behind DART under skew at any cache size |
| Miss-gated pushdown | **Yes** | DEX +2.1–2.6× on scans, passes DART from 256 MB; CHIME +2.6–3.7× in the stressed-cache regime |
| Leaf caching without batching | No — shrinks bytes only | +40% where the baseline was >1 RTT/leaf, **−41% where it was exactly 1** |

The three rows are one finding: **the benefit is predictable from the round trips
remaining after the cache runs out.** Where the baseline already spent exactly one
crossing, removing bytes buys nothing and the bookkeeping costs real throughput. That
is why the leaf cache's failure is evidence *for* the thesis rather than against it —
and it is the cleanest demonstration in the study that round trips, not bytes, are the
currency on this fabric.

---

## 4. Recommendations

### 4.1 Before anything else — two measurements that gate the claims

1. **Run the batched scan path.** The §3.3 fix is committed and unmeasured; the whole
   CHIME scan story rests on it. Build on the cluster, then verify
   `[CORRECTNESS] lookup found %` and scan rows are **identical** to `CACHE_LEAF=0`
   with offload off and on. A difference means the cached-image path returns different
   results from the remote path — a bug, not noise. Only then sweep
   `CHIME_LEAF_ADMIT_SCAN` (DEX uses 0.1); measure batching alone first, since two
   knobs moving at once cannot be attributed.
2. **Re-run DART at matched thread counts.** This is a live methodological hole:
   - The DEX↔DART comparison (§3.1) pairs DEX at **32** compute threads against
     `cache_sweep_baseline_20260615_125117.csv`, which was actually run at **56**
     threads — despite `COMPARISON.md` describing the intent as matched at 32. DEX is
     therefore beating a *better-provisioned* DART, so the crossover is if anything
     understated, but the comparison is not clean.
   - The CHIME↔DART comparison pairs `20260622_071147.csv` (34/36 threads on one
     machine) against CHIME running the same binary on both nodes, i.e. **68** client
     threads.

   Both asymmetries run in opposite directions. Re-run DART at 32 threads for the DEX
   figures and at 17/node-equivalent for CHIME, or state the thread counts inline
   everywhere a ratio appears. Do not publish a bare "N× DART" number until one of
   those is done.

### 4.2 What to claim in the writeup

- **Lead with the scans.** They are the operation the baselines structurally could not
  accelerate, they are where the technique pays most (2.1–2.6× on DEX, widening with
  cache), and the `rpc_per_op ≈ 1.4` against ~20 reads/op is the single most legible
  number in the study.
- **Lead with the mechanism, not the throughput.** "Network operations per op fall
  ~3×, and throughput follows at ~2.5×" is a claim a reviewer can check against the
  counters. "2.5× faster" is not.
- **Report the leaf-cache scan regression explicitly**, with the mechanism from §3.3.
  It is a genuine result that supports the thesis, and omitting it invites exactly the
  question it already answers.
- **State the portability claim carefully.** `range_scan` and `lookup_from` are
  identical across both ports; only the decode differs (a cast in DEX, snapshot →
  version check → un-scatter → retry in CHIME). That is the generalisable
  contribution: pushdown needs the memory node to speak the index's encoding, not to
  have naked structs.
- **Do not claim multi-node concurrent-writer correctness.** See §4.4.

### 4.3 Experiments worth running next

| Experiment | Why | Cost |
|---|---|---|
| Sweep `CHIME_OFFLOAD_MIN_LEVEL` ∈ {1, 2, 3} | The gate is the thesis in one knob, and its break-even is empirical: at level 2 an RPC replaces only ~2 round trips and may not beat them. A curve here is the paper's cleanest ablation | 1 runtime axis, one build |
| Sweep `LEAF_CACHE_PCT` ∈ {25, 50, 75} at a pinned total | Finds the best inner/leaf **split**, not just the best total — currently untested; 50 was assumed | Runtime only |
| Scan length ∈ {10, 100, 1000} | Batching's win should scale with leaves covered. This is the strongest predicted-and-confirmed result available and it is not yet run | Runtime only |
| `memThreadCount` × offload (DEX) | Finds where added memory-side service capacity stops buying throughput — the "when does it stop mattering" answer for the resource-awareness argument | Needs `NR_DIRECTORY ≥ 8`, rebuild both nodes |
| A write-mixed workload | Every measured cell so far is read-only, so `[LEAFCACHE] stale=0` throughout: **the coherence protocol is exercised but idle.** The stamp path has never actually rejected an image in a measurement | New workload cell |

### 4.4 Engineering debt to retire, in priority order

1. **Masked-CAS emulation.** `DSM::cas_mask_sync` does a read plus a plain CAS
   serialised by a *process-local* mutex, because true masked atomics need MLNX
   experimental verbs this rdma-core cluster does not provide. The leaf cache's
   correctness argument rests on the leaf lock, so **cross-node concurrent writers are
   outside what this port guarantees.** Single-node writers (what the benchmark does)
   are fine. This is pre-existing port debt, not new — but it bounds every correctness
   claim and must be stated in the paper.
2. **Correctness checking is found/not-found only.** It would not catch a cached image
   returning a stale *value* for a key that still exists. Harmless today because
   nothing writes during the measured phase — and exactly the check that has to be
   strengthened before §4.3's write-mixed cell means anything.
3. **Synchronous RPCs.** `rpc_lookup`/`rpc_scan` block on `rpc_wait()` with no coroutine
   yield, so offloaded ops do not overlap under `kCoroCnt`. Fine for the load
   measurement, but it caps peak offload throughput — every number in §3.1 is a floor.
4. **Scan scratch slot keying** (`app_id % MAX_APP_THREAD`) can collide across compute
   *nodes*. Harmless for load numbers; key by global thread id before trusting
   multi-CN scan results.
5. **Repository hygiene.** The working tree currently carries ~284 deleted files under
   `CHIME/results/` and ~17 untracked files including `paper/paper.tex` and
   `hybrid_plots/`. Resolve before the next results run, or provenance for the figures
   will not be reconstructible.

### 4.5 One open naming decision

`notes.txt` proposes **LIFELINE** over REV, on the grounds that a lifeline is thrown
only when someone is already in trouble — which is precisely what miss-gating does. It
is a better name than REV for exactly the reason the system is interesting. If it is
adopted, the change is small: `paper/dex_vs_dart.tex:66` carries the name in the title;
the other occurrences are absolute paths in `\graphicspath` and stay.

---

## Provenance

| Claim set | Source | Status |
|---|---|---|
| §3.1 DEX | `dex/build/results/summary.csv` | Measured, 32 threads |
| §3.1 DART reference | `DART/cache_sweep_baseline_summary_20260615_125117.csv` | Measured, **56 threads** — see §4.1 |
| §3.2–3.3 CHIME | sweep `leafstudy`, 2026-08-30/31, 64 cells | Measured, 34 threads/node; **pre-dates** the §3.3 fix |
| §3.3 fix | commit `15070de` | Committed, **not compiled or run** |

Not used here: `dex/8_dex_offload_vs_dart.csv`, whose 64–256 MB rows are marked
`projected` rather than `measured`. Every figure above is measured.
