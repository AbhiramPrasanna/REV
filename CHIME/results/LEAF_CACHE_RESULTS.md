# Leaf-cache study — measured results

Sweep `build/results/leaf_cache/sweep_leafstudy`, 2026-08-30/31.
64 cells, ~6 h wall time.

**Configuration.** 2 nodes (mem 10.30.1.8 / cmp 10.30.1.6), 34 app threads per
node, 4 dir threads, 50 M keys, 8-byte keys, **16-byte values**
(`-DCHIME_VALUE_LEN=16`, to match the DART baseline's `--payload_byte`), 30 M
measured ops, scan length 100, zipf θ=0.99. Build:
`-DENABLE_OFFLOAD=ON -DCACHE_LEAF_NODE=ON -DCHIME_VALUE_LEN=16`.

**Cache budget is a TOTAL and is split, never grown.** At each point the baseline
arm is all inner nodes; the leaf arm is half inner / half leaf. Both arms occupy
the same compute-side memory, which is what makes the comparison — and the DART
comparison — mean anything.

> All throughput figures below are the **compute node's own rate**, as recorded in
> `summary_compute.csv`. Cluster throughput is the sum of both nodes; see
> *Comparing to DART* at the end before quoting any ratio.

---

## 1. Point lookups — the leaf cache works

### zipf-0.99 (the headline)

| total cache | inner/leaf | leaf hit | offload | baseline | + leaf cache | Δ |
|---|---|---|---|---|---|---|
| 512 MB | 256/256 | 69.9% | off | 2.857 | **3.999** | **+40%** |
| 512 MB | 256/256 | 70.1% | on  | 2.857 | **3.997** | **+40%** |
| 256 MB | 128/128 | 63.5% | off | 2.857 | **3.999** | **+40%** |
| 256 MB | 128/128 | 63.6% | on  | 2.856 | 3.749 | +31% |
| 128 MB | 64/64   | 59.7% | off | 2.857 | 1.111 | **−61%** |
| 128 MB | 64/64   | 78.3% | on  | 2.856 | 3.157 | +11% |
| 64 MB  | 32/32   | 54.9% | off | 1.154 | 1.200 | +4% |
| 64 MB  | 32/32   | 75.2% | on  | 2.727 | 3.157 | +16% |

p99 improves alongside throughput at 512 MB: **21.0 → 17.0 µs**.

### uniform

| total cache | leaf hit | offload | baseline | + leaf cache | Δ |
|---|---|---|---|---|---|
| 512 MB | 12.3% | off | 2.307 | 2.608 | +13% |
| 512 MB | 12.2% | on  | 2.307 | 2.608 | +13% |
| 256 MB | 6.0%  | off | 2.307 | 2.500 | +8% |
| 256 MB | 6.0%  | on  | 2.307 | 2.500 | +8% |
| 128 MB | 3.1%  | off | 2.307 | 0.625 | **−73%** |
| 128 MB | 4.3%  | on  | 2.307 | 1.666 | −28% |
| 64 MB  | 1.6%  | off | 0.566 | 0.577 | +2% |
| 64 MB  | 2.2%  | on  | 1.714 | 1.666 | −3% |

Exactly the skew dependence predicted: keys are hashed (`to_key` runs the Zipf
rank through CityHash), so hot keys scatter across ~4.5 M leaves. Under uniform a
256 MB leaf cache covers ~12% of them and the win is small; under Zipf the same
cache captures the hot set and the win is large.

---

## 2. Range scans — the leaf cache LOSES. Read [RANGE_SCANS.md](RANGE_SCANS.md)

| workload | total cache | leaf hit | offload | baseline | + leaf cache | Δ |
|---|---|---|---|---|---|---|
| range-uniform | 512 MB | 12.2% | off | 0.496 | 0.293 | **−41%** |
| range-uniform | 256 MB | 6.1%  | off | 0.496 | 0.279 | **−44%** |
| range-zipf    | 512 MB | 59.0% | off | 0.496 | 0.423 | **−15%** |
| range-zipf    | 256 MB | 52.0% | off | 0.500 | 0.408 | **−18%** |

It loses even at a 59% hit rate. The cause is structural, not tuning — the
validated design removes *bytes* from the scan path but not *round trips*, and
adds a per-miss fill cost. Full analysis and the fix in
**[RANGE_SCANS.md](RANGE_SCANS.md)**.

---

## 3. The 128 MB cliff — the leaf cache has to pay for what it displaces

At 128 MB the leaf arm runs a **64 MB inner cache**, below the index working set,
and the descent thrashes: point-uniform 2.307 → 0.625, point-zipf 2.857 → 1.111.
The baseline's 128 MB inner cache still fits.

This is the trade-off the split budget was designed to expose, and it lands one
cache point earlier for the leaf arm than for the baseline — as predicted. At
64 MB both arms are stressed and they converge (1.154 vs 1.200).

**Action:** confirm the true index size from `index_mb` in `summary_memory.csv`
(the `[TreeCache] consumed cache size` line, printed on node 0 only). The 10 M-key
calibration measured 18.3 MB, which scales to roughly 90–100 MB at 50 M.

---

## 4. Offload and leaf caching compose — where it matters

At large caches offload is inert (the index fits, so there are no misses to push
down — correct behaviour after the warmup fix). At small caches it rescues the
leaf arm by serving the inner-cache misses that halving the inner cache created:

| cell | leaf, offload **off** | leaf, offload **on** |
|---|---|---|
| point-zipf 128 MB | 1.111 | **3.157** |
| point-zipf 64 MB  | 1.200 | **3.157** |
| range-zipf 128 MB | 0.120 | 0.355 |
| range-uniform 128 MB | 0.066 | 0.241 |

The two features split the work by construction at `CHIME_OFFLOAD_MIN_LEVEL=2`:
offload serves the index **misses**, the leaf cache serves the index **hits**.

---

## 5. Artifact to be aware of: the per-key range fallback

`range-uniform` at 128 MB, leaf on, offload off shows **86.2% leaf hit but
0.066 Mops** — the worst cell in the sweep alongside a near-best hit rate.

That is not the leaf cache. When the internal cache holds no covering level-1
node for the range, `range_query` falls back to a **per-key `search()`** over the
whole span — 100 individual lookups per scan instead of ~12 covered-leaf reads.
Those lookups hit the leaf cache (hence 86%), but there are eight times as many
of them. The same fallback explains `range-uniform` 64 MB baseline at 0.047 Mops.

Read the hit rate and the throughput together; a high hit rate on the range path
can mean the scan degenerated into point lookups.

---

## 6. Correctness

Every cell reported `lookup found ≈ 99.99%`, matching between `CACHE_LEAF=0` and
`CACHE_LEAF=1`. That value is structural, not coincidental: bulk load inserts 50 M
keys into a 50,001,000-key space, so ~0.0100% of lookups target keys that were
never inserted, and `100 − 99.99 = 0.01`.

`[LEAFCACHE] stale=0` throughout — the seqlock probe never rejected an image,
which is what a read-only measured phase should produce. The coherence path is
exercised but idle.

**Limit of this check:** it verifies found/not-found only, never the value. A
cache returning a stale *value* for a key that still exists would not be caught.
Nothing writes during these cells, so there is no stale value to return — but do
not lean on this check if an insert/update mix is added.

---

## 7. Comparing to DART

DART baseline at 34 threads
(`DART/cache_sweep_baseline_20260622_071147.csv`), flat across 64–512 MB:

| workload | DART (Mops) |
|---|---|
| point-uniform | 2.82 |
| point-zipf | 2.86 |
| range-uniform | 1.26 |
| range-zipf | 1.27 |

**Do not quote a ratio without stating the thread asymmetry.** DART drives 34
client threads from **one** machine; CHIME runs the same binary on both nodes, so
`THREADS=34` means **68** client threads, and cluster throughput is the sum of the
two nodes. Either report per-node figures against DART's, or state the thread
counts alongside any ratio. `THREADS=17` would match total client parallelism if
you want a like-for-like number.

Note also that CHIME's range numbers (0.28–0.50 Mops per node) are far below
DART's 1.26 even in the baseline arm — the scan path is where CHIME is weakest,
and the leaf cache as built makes it worse rather than better.

Plots:

```bash
S=CHIME/build/results/leaf_cache/sweep_leafstudy
scp 10.30.1.8:$S/summary_memory.csv $S/          # cluster tput needs BOTH nodes
python3 CHIME/results/plot_leaf_cache.py $S --out chime_leaf_cache.png
python3 compare_chime_dart.py $S \
    DART/cache_sweep_baseline_20260622_071147.csv \
    --dart-threads 34 --out compare_chime_dart_leaf.png
```

---

## 8. Provenance caveats

- The study reported `ran=62 skipped=2`: two cells were resumed from an earlier
  partial run. Confirm they were produced by the current binary (post
  warmup-offload fix) or delete those rows and re-run them.
- The offload-on arms measure something different from sweeps taken **before**
  the warmup fix (`6aef59b`), where a node that did not bulk-load ran with a
  permanently empty index cache and offloaded 100% of lookups. Do not mix
  pre- and post-fix data in one figure.
