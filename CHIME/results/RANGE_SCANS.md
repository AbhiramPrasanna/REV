# Why the leaf cache makes range scans SLOWER

Measured, 2026-08-30/31, sweep `build/results/leaf_cache/sweep_leafstudy`.
Compute-node throughput, 50 M keys, 30 M ops, scan length 100.

| workload | total cache | leaf hit | baseline | + leaf cache | Δ |
|---|---|---|---|---|---|
| range-uniform | 512 MB | 12.2% | 0.496 | 0.293 | **−41%** |
| range-uniform | 256 MB | 6.1%  | 0.496 | 0.279 | **−44%** |
| range-zipf    | 512 MB | 59.0% | 0.496 | 0.423 | **−15%** |
| range-zipf    | 256 MB | 52.0% | 0.500 | 0.408 | **−18%** |

p99 goes the same way: range-uniform 512 MB, 82.0 → 157.5 µs.

**It loses even at a 59% hit rate.** That rules out "the cache is just too small"
and points at the design.

---

## The prediction was wrong, and here is why

Going in, the claim was: *stock CHIME serves each covered leaf with its own
`read_sync`, so a 100-key scan over 16-entry leaves is a dozen-plus serial round
trips deep; caching those leaves collapses them.*

The first half is true. The second half does not follow, because of what the
**validated** design actually does per covered leaf.

`Tree::range_query`, non-legacy covered-leaf loop:

```
                          round trips   bytes moved    extra work
baseline (leaf off)            1        ~1 KB read     decode
leaf cache HIT                 1        ~24 B probe    local scan
leaf cache MISS                1        3-WR batch     decode + ~480 B
                                                       alloc/memcpy + LFU
                                                       + deferred-free
```

The probe — `leaf_cache_validate()` — is issued **per covered leaf**. So the
number of round trips per scan is **unchanged**. All the cache does is:

- **on a hit**, shrink that round trip from ~1 KB to ~24 B;
- **on a miss**, keep the round trip *and* add a `LeafCacheEntry` allocation, a
  ~480-byte `memcpy`, LFU bookkeeping and a deferred-free push.

Round trips are the cost on this fabric, not bytes. So the hits save almost
nothing and the misses cost more than the baseline did. Under uniform, 88–94% of
covered leaves are misses, and the fill overhead dominates outright — hence −41%.
Under Zipf a majority hit, but a hit still costs a full round trip, so the
remaining ~41% of misses are enough to stay net-negative.

---

## Why point lookups win and scans do not

Both paths pay one round trip on a hit, so byte savings alone cannot explain
+40% on point-zipf against −15% on range-zipf. The asymmetry is in what the
**baseline** costs per leaf:

- **Point path (baseline):** a hopscotch segment read, or a `SPECULATIVE_READ`
  single-entry read that can *miss its guess* and fall back to a full hopscotch
  search; plus `read_leaf_retry` on a version mismatch and `read_two_segments`
  when the hop window wraps. Its per-lookup cost is **variable and sometimes more
  than one round trip**. A leaf-cache hit replaces all of that with exactly one
  small probe.
- **Range path (baseline):** one `read_sync` of the whole leaf, decode, harvest,
  bounded retry. Already **exactly one round trip**, with no speculative fallback
  to eliminate.

So the leading hypothesis is: *the leaf cache wins where the baseline's per-leaf
cost is variable and greater than one round trip, and loses where the baseline is
already exactly one.*

**This is a hypothesis, not a measurement.** To confirm it, compare across arms in
the per-cell logs: `try_speculative_read` vs `correct_speculative_read`,
`read_leaf_retry`, `read_two_segments`, and `try_read_leaf`. If the point
baseline's average round trips per lookup is meaningfully above 1 and the range
baseline's is 1.0, the hypothesis holds.

---

## The fix: batch the validation

The scan path knows **all** its covered leaves up front — `leaf_addrs` is fully
populated before the read loop begins. So the probes do not have to be serial:

1. build one `RdmaOpRegion` array of `[lock, stamp]` reads, one per resident
   covered leaf, and issue it as a **single doorbell batch** — 1 round trip for
   the whole scan instead of one per leaf;
2. harvest every leaf whose stamp still matches, entirely locally;
3. batch the full-leaf reads for the ones that failed validation or were not
   resident, again as one doorbell batch.

That turns a 12-leaf scan from 12 round trips into **2**, and it is the shape the
original claim assumed. The machinery already exists: `dsm->read_batch_sync` is
used by `leaf_read_full` (3 WRs) and by the legacy batched range path.

Second, smaller fix: **do not fill the cache from the scan path when the hit rate
is low.** The per-miss `LeafCacheEntry` allocation plus ~480-byte copy is pure
cost when the leaf will not be read again, and a scan streams through leaves it
will never revisit. An admission policy — only insert a leaf the scan path has
seen more than once, or only when the observed hit rate is above some threshold —
would remove most of the −41%. DEX has an explicit admission ratio (`ADMIT`) for
exactly this reason.

Until one of those lands, **run range workloads with `CACHE_LEAF=0`.**

---

## Do not misread the high-hit-rate scan cells

`range-uniform` at 128 MB, leaf on, offload off: **86.2% leaf hit, 0.066 Mops** —
near-best hit rate, worst throughput in the sweep.

That is not the leaf cache. With a 64 MB inner cache there is no covering level-1
node for the range, so `range_query` takes its fallback path: a per-key
`search()` across the whole span — **100 point lookups per scan** instead of ~12
covered-leaf reads. Those lookups hit the leaf cache, which is where the 86%
comes from; the throughput is the fallback. The same fallback explains the 64 MB
baseline at 0.047 Mops.

On the range path, always read hit rate and throughput together.

---

## Bottom line

- Leaf caching as built is a **point-lookup optimisation**. It is a **regression**
  for scans at every cache size tested.
- The cause is structural: one validation round trip per covered leaf, plus
  per-miss fill cost, against a baseline that already spent exactly one round trip
  per leaf.
- It is fixable — batch the probes (12 RTT → 2) and add an admission policy — and
  both changes are contained to `Tree::range_query` and `LeafCache::put`.
- Reporting guidance: quote the point-lookup result as the finding, and report the
  scan regression explicitly rather than omitting it. The mechanism above is the
  explanation to give.
