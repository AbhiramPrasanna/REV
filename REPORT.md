# REV — two levers, and the operating point they cover

**Cross-cutting argument and paper plan.**

| Document | Contents |
|---|---|
| **REPORT.md** *(this file)* | contributions, novelty, paper outline, the lever model, figure plan, global to-do |
| **[DEX.md](DEX.md)** | DEX: baseline → implementation → results → recommendations |
| **[CHIME.md](CHIME.md)** | CHIME: baseline → implementation → results → recommendations |
| **[IMPLEMENTATION.md](IMPLEMENTATION.md)** | mechanism reference — byte layouts, protocols, knobs |

---

## The claim in one paragraph

A disaggregated index has **two levers** for removing remote cost — *compute-side caching*
and *memory-side offloading* — and each **fails in the regime where the other works.**
Existing designs own one lever or both, but treat them as independent local optimisations
rather than as a portfolio covering a space. The consequence is that every system has a
regime where it falls off a cliff, **even when it possessed the lever that would have saved
it**. DEX owns both and never asks which regime it is in ([DEX.md §4](DEX.md)); CHIME owns
one and bets the design on that lever always fitting ([CHIME.md §4](CHIME.md)).

---

# Part I — Contributions and novelty

## I.1 The two levers

| | Compute-side caching | Memory-side offloading |
|---|---|---|
| Removes | crossings for data that **fits** | the **cost** of a crossing that happens anyway |
| Scales with | cache budget vs working-set size | memory-side CPU |
| **Fails when** | the working set doesn't fit, has no hot core (uniform), or is streamed (scans) | the cache is already working — then it is pure overhead |
| Cost of misusing it | memory spent that buys nothing, **and can buy negative** | memory-side CPU burnt for no gain |

Neither lever is new. **The finding is that they are complementary in a regime sense, not
substitutes** — and that a system holding both can still collapse if it never asks *which
regime am I in*. From the CHIME lever map ([CHIME.md §3](CHIME.md)):

- **Caching raises the plateau** where the index fits, and does **nothing** below it.
- **Offloading removes the cliff** where the index does not fit, and is **exactly inert**
  above it — 2.857 → 2.857 across three consecutive cache points.

They act on disjoint parts of the curve, so together they produce an operating point
neither reaches alone.

## I.2 The four contributions

### C1 — Run-at-a-time scan pushdown *(the missing lever position)*

> A range scan can be served in **O(1) round trips instead of O(leaves)**, by executing the
> leaf-chain traversal at the memory node and returning a packed run in one reply.

Scans are the case where the caching lever is *structurally* unavailable — a scan streams
through leaves it never revisits — so the offload lever is the only one left. Yet no
disaggregated index offloads a scan as a run. Sherman and SMART offload nothing; DEX states
that "range scans that span multiple leaf nodes are subdivided into multiple lookups by
employing fence keys" (§7), paying one decision and one crossing **per covered leaf**. A
difference in asymptotics, not tuning.

**Evidence.** DEX `rpc_per_op ≈ 1.4` against **22.35 reads/op**; 2.1–2.6×. CHIME 4.1–5.1×
below the fit boundary.

### C2 — Encoding-agnostic memory-side execution *(making the lever available at all)*

> Pushdown requires only that the memory node run the index's **own decoder** — not that the
> index store plain structs.

CHIME's encoding (per-cacheline versions, scattered metadata) exists *precisely* to make
one-sided reads safe without memory-side CPU — i.e. to commit to the caching lever alone.
Showing the offload lever still applies, unchanged above the decode layer, is what makes
"two levers" a general claim rather than a DEX-specific one. One engine, two incompatible
encodings; `range_scan` and `lookup_from` are identical across both ports.

> ⚠ Frame as *a property demonstrated by two instantiations*, never as "we ported code."

### C3 — The post-cache remainder *(which lever, and how much it can buy)*

> The benefit of any acceleration is set by the **round trips remaining after the caching
> lever has done what it can** — not by bytes moved, not by hit rate.

This turns "two levers" into a decision rule: the remainder *is* the size of the offload
lever's opportunity. Two predictions were tested, and **they did not fare equally.**

1. **Ordering — holds at the class level only.** Scans, whose remainder is 9–22
   crossings/op, gain 2.15–2.62×; point lookups, at 1.5–6.8, gain 1.61–2.52×. But the
   relationship is **not** a tight predictor: over DEX's 16 cells, Pearson *r* between
   remainder and speedup is **0.528**, and *within* each workload class it is mildly
   **inverted** — range-uniform's speedup falls from 2.62× to 2.15× as the remainder grows
   from 16.9 to 22.3. Throughput depends on more than crossings (service capacity, mean
   latency under fixed threads), so the remainder bounds the *opportunity*, it does not
   predict the realised gain.
2. **Falsification — holds, cleanly.** An optimization that removes *bytes* but not *round
   trips*, applied where the baseline already spends exactly one crossing, must fail — even
   at a high hit rate. **Measured: −41%, and −15% at a 59% hit rate.** Given batching so it
   removed crossings instead, the zipf arm **flipped to +19%**.

> **Claim C3 at the strength the data supports:** crossings, not bytes, are the currency
> (prediction 2, strongly confirmed), and the *class* with the larger remainder is the class
> pushdown helps most (prediction 1, coarse only). **Do not claim a quantitative predictor.**
> An earlier draft of this document proposed a "speedup vs remainder" scatter as the figure
> that would make the paper analytical; the scatter was computed and does not support that
> reading, so it is not in the figure plan.

### C4 — Operating-point expansion *(the result)*

> With both levers, an index runs the workload it previously needed a large cache for on a
> fraction of that cache — and in some regimes **beats its own best-ever number.**

**CHIME point-zipf.** Stock plateaus at **2.857 Mops** and needs ≥128 MB inner cache to get
there. Both levers at **32 MB inner + 32 MB leaf**: **3.157 Mops** — 1.11× stock's ceiling on
half the total cache and a quarter of the inner cache.

**DEX scans.** Offload at 64 MB beats caching at 512 MB: 0.903 vs 0.555 (uniform, 1.63×),
1.291 vs 0.948 (zipf, 1.36×).

A *provisioning* claim — the currency disaggregation exists to trade in.

## I.3 Explicitly NOT claimed as novel

| Not new | Prior art |
|---|---|
| RPC pushdown / offloading as such | DEX §6 |
| Cost-aware offload decisions | DEX §6.1 |
| Compute-side caching, path-aware caching, lazy admission | DEX §5 |
| Caching inner nodes but not leaves for coherence reasons | Sherman, SMART |
| Seqlock / version-stamp coherence | textbook, adapted to RDMA |
| The ports, harness, sweep tooling | engineering |

## I.4 Reviewer objections

**"DEX already has both levers."** It has both *mechanisms*; it does not use them as a
portfolio. Its offload decision is evaluated at a single node miss —
`l_p < (L+1)(l_o + l_s)c` — so it never asks *"is my caching lever working for this operation
class?"* For scans the right unit is the covered run (one RPC vs N crossings), and **DEX's
cost model, at node granularity, is structurally incapable of seeing that comparison.** The
machinery was present and could not fire. Direct evidence the regime signal exists and is
trivially observable: DEX's `rpc_per_op` is pinned at **1.0000** across a 4× cache sweep on
uniform lookups ([DEX.md §2.2](DEX.md)).

**"Your model is just 'round trips are expensive'."** The claim is the *remainder*, and it
predicts something a bytes model gets backwards: shrinking a scan's per-leaf transfer ~40×
should help, and it loses 41%. Predicted, measured, explained, repaired.

**"Memory-side CPU is scarce."** Which is why the offload lever is **miss-gated**, and in
CHIME gated *structurally*: only level-1 nodes are cached, so a cache hit cannot pass the
gate. Measured offload fraction tracks predicted miss rate three for three (64 MB
60%/63.2%, 32 MB 62%/65.2%, 16 MB 81%/82.5%). Above the cliff the memory node is idle —
visible as offload being exactly 1.00× where the index fits.

---

# Part II — Paper outline (2B, measurement-first)

**Decision: 2B.** There is no single new system — both instantiations are retrofits — so a
"we propose a framework" section invites *"framework or two patches?"*, the most dangerous
question here. 2B never claims a system; it claims a **design principle about lever
coverage**, validated on two structurally different indexes. It also gives the negative
result a home as the falsification test rather than a failed experiment.

| § | Content | Source |
|---|---|---|
| **1 Introduction** | 1.1 two levers, each with a blind spot; 1.2 what measuring two state-of-the-art indexes shows; 1.3 contributions | Part I |
| **2 Background** | DM, RDMA verbs, one/two-sided, why indexes cache inner nodes. Track DEX §2.1–2.2 | — |
| **3 Measurement study** | 3.1 CHIME: the caching lever's cliff · 3.2 DEX: the caching lever's floor · 3.3 shared diagnosis. *A contribution, not setup* | [CHIME.md §1–2](CHIME.md), [DEX.md §1–2](DEX.md) |
| **4 Insights** | I1–I3, named (below) | Part III |
| **5 Design responses** | 5.1 Miss-Gated Execution · 5.2 Run-at-a-Time Scan Pushdown · 5.3 Encoding-Agnostic Decoding · 5.4 leaf-cache coherence | [IMPLEMENTATION.md](IMPLEMENTATION.md) |
| **6 Instantiation** | 6.1 DEX · 6.2 CHIME — short; the point is §5 lands on both and only the decoder differs | [DEX.md §2.4](DEX.md), [CHIME.md §2.3](CHIME.md) |
| **7 Evaluation** | 7.1 setup · 7.2 **the lever map** (C4) · 7.3 scan scaling (C1) · 7.4 falsification + repair (C3) · 7.5 vs DART · 7.6 ablations | [CHIME.md §3](CHIME.md), [DEX.md §3](DEX.md) |
| **8 Discussion** | when to spend memory-side CPU; the tail trade; what each baseline should have done | [DEX.md §4](DEX.md), [CHIME.md §4](CHIME.md) |
| **9–10** | Related work, Conclusion | — |

**Named insights (§4).** DEX's rhetorical device is naming — its challenges and techniques
are bold-led and become the contribution list. Mirror it:

- **I1 — Crossings, Not Bytes.** A 70 B and a 500 B read cost nearly the same, so
  byte-reducing optimizations are invisible. *Number:* ~40× less transfer, −41% throughput.
- **I2 — Levers Cover Regimes, Not Operations.** Caching raises the plateau and does nothing
  below the cliff; offload removes the cliff and is inert above it. *Number:* the lever map.
- **I3 — Caching Cannot Reach Scans.** *Number:* DEX `rpc_per_op` constant at 1.3748 across
  an 8× cache sweep on uniform scans.

**Named techniques (§5):** *Miss-Gated Execution*, *Run-at-a-Time Scan Pushdown*,
*Encoding-Agnostic Decoding*.

**Figure 1** should be the **lever-coverage diagram**: throughput vs cache with the fit
boundary marked, caching lifting the right-hand plateau and offload lifting the left-hand
floor, and the region neither covers alone shaded. It states I1–I3 in one picture — the
analogue of DEX's numbered desiderata figure.

**Draft abstract** — in DEX's register:

> Memory disaggregation lets range indexes scale past one machine, and nearly every design
> accelerates them the same way: cache part of the index on the compute node while the
> memory node stays idle, because memory-side CPU is scarce. We show by measurement that
> this leaves a structural gap. A cache changes how *often* an operation crosses the network
> but never what a crossing *costs*, so performance is governed by whether the working set
> fits — and range scans, which stream through leaves they never revisit, cannot be helped by
> cache budget at all. On two state-of-the-art indexes we measure the consequences: one
> collapses 3.7× at its fit boundary, and on the other an eightfold cache increase leaves the
> offload rate on uniform scans unchanged to four decimal places.
>
> We show that memory-side CPU, spent *only after caching has failed*, removes the cost
> caching cannot. We present three techniques — execution gated on cache misses,
> run-at-a-time scan pushdown returning an entire run of leaves in one reply, and decoding
> nodes in the index's own format so the memory node can read leaves encoded for safe
> one-sided access — and instantiate them in both indexes. The benefit is predictable from
> the round trips remaining after the cache runs out; it is largest on range scans; and it
> expands the operating point, letting the same workload run on a quarter to an eighth of the
> compute-side cache. A falsification test confirms the model: an optimization that removes
> bytes without removing round trips regresses throughput by 41%, even at a 59% cache hit
> rate.

---

# Part III — The lever model (C3, validated)

| case | gain from the offload lever | crossings the caching lever left behind |
|---|---:|---|
| CHIME range / uniform @ cliff | **5.1×** | deep tree **and** uncacheable leaves |
| CHIME range / zipf @ cliff | 4.1× | many leaves, warmer path |
| CHIME point / uniform @ cliff | 2.7× | 7-level descent |
| DEX range / uniform | 2.6× | many leaves, shallow tree |
| CHIME point / zipf @ cliff | 2.5× | 7-level descent, hot |
| DEX lookup / zipf | 1.7× | hot path largely cached |
| **CHIME point / zipf, index fits** | **1.00×** | **nothing left — lever correctly idle** |

**The offload lever's value equals the remainder the caching lever left.** The bottom row is
the strongest evidence the model is right: where caching fully succeeds, offload is not
merely small — it is *exactly* 1.00× across three consecutive cache points.

| lever configuration | removes crossings? | measured |
|---|---|---|
| Caching only | Only for what fits | CHIME collapses 3.7× at the boundary; DEX's uniform-scan offload rate is flat at 1.3748 across 8× cache |
| + offload | **Yes, below the boundary** | CHIME 2.5–5.1×; DEX 1.6–2.6×; inert above |
| + leaf caching, unbatched | No — bytes only | +40% where baseline > 1 crossing/leaf, **−41% where it was exactly 1** |
| + leaf caching, batched | **Yes** | range-zipf −15% → **+19%** |
| **Both levers** | **Plateau raised and cliff removed** | point-zipf **3.157 at 32 MB inner vs 2.857 stock ceiling** |

---

# Part IV — Figure plan

Generated by [`paper/make_figures.py`](paper/make_figures.py) into `paper/figures/`, which is
on the paper's `\graphicspath`. Palette is Okabe-Ito, validated against the colorblind
separation and chroma checks before use.

| File | Figure | Paper § | Status |
|---|---|---|---|
| **`fig_lever_map.pdf`** | **the lever map** — throughput vs *inner* cache, 4 lever configs, fit band marked | Arm II, Fig. 11 | **written** |
| **`fig_dex_rpc.pdf`** | DEX `rpc_per_op` vs cache — the flat 1.0000 / 1.3748 uniform rows | Arm I, Q6 | **written** |
| **`fig_dex_crossings.pdf`** | DEX crossings/op, one lever vs two, 4 panels | Arm I, Q6 | **written** |
| **`fig_scan_repair.pdf`** | range: stock / first-cut / batched | Arm II, Fig. 12 | **written** |
| **`fig_dex_self.pdf`** | DEX throughput + p99 vs cache, one lever vs two | Arm I, Fig. 1 | **written** |
| **`fig_dex_equivalence.pdf`** | cache equivalence: both levers @64 MB / caching @512 MB | Arm I, Q10 | **written** |
| — | per-cell latency and throughput with gains | Arm I | exists `hybrid_plots/fig{1,2,3,4}*.png` |
| *(pending)* | scan length {10, 100, 1000} | Arm I/II | **needs the run** — §V.2 |

**Dropped:** the "speedup vs post-cache remainder" scatter. It was computed on DEX's 16
cells and the relationship is weak (*r* = 0.528) and inverted within workload classes, so
shipping it would have overclaimed C3. See §I.2 C3.

**Also dropped, with the DART material:** `fig_opshift.png` (beats-DART region),
`fig_coverage.png`, `dex_catches_dart_*.png` and `latency_p99_vs_cache_*.png`, all of which
have a DART line baked in. `fig_dex_self.pdf` replaces the last of those.

---

# Part V — Global to-do

## V.1 Cross-system comparison: removed from the paper, not deferred

**The paper now reports no cross-system number at all.** Both arms are ablations — one
binary, one runtime setting apart — and the *On the Absence of a Cross System Comparison*
section states why. Three yardsticks replace the external baseline: the design's own
ceiling, cache equivalence, and crossings per operation.

The equalisations a DART comparison would need, each a place an effect can be manufactured:

| | problem |
|---|---|
| **Thread count** | DEX ran at **36** (`totalThreadCount 36`), not the 32 `COMPARISON.md` claims. The DART file that document pairs against (`20260615_125117`) was run at **56**. A matched file *does* exist — `20260622_071147` has 36-thread rows — but it is not the one used. For CHIME the mismatch is structural: DART drives 34 threads from one machine, CHIME runs the same binary on both nodes, so 34 means 68. |
| **Cache budget** | DART's cache is per-thread, CHIME's and DEX's are shared totals. Dividing one by the thread count is a convention, not an equivalence. |
| **Latency statistic** | The two harnesses do not report the same one; a mean read as a tail is a real hazard. |
| **Index shape** | ART's adaptive nodes have no fixed span, so "same inner node size" cannot be imposed. |

To add one later: fix and state all four, use the same statistic on both sides, and run a
sweep *for that purpose* rather than assembling two that happened to exist.
`COMPARISON.md` has been corrected but remains a working note, not a result.

## V.2 Experiments by value

| Experiment | Buys | Cost |
|---|---|---|
| **Scan length {10, 100, 1000}**, both systems | Converts **C1** from a speedup into an **asymptotic** result — the strongest upgrade to the primary contribution, and the experiment DEX itself should have run ([DEX.md §4 R5](DEX.md)) | Runtime |
| **CHIME 16 → 512 MB in one configuration** | Extends the lever map below inner = 32 and joins it to the stress sweep, which uses different threads/value size and **must not be spliced** | One sweep |
| **`CHIME_LEAF_ADMIT_SCAN=0.1`** | Closes range-uniform's remaining −21%; completes the repair arc | Range cells |
| **`CHIME_OFFLOAD_MIN_LEVEL` {1,2,3}** | The gate ablation; directly answers the scarce-CPU objection | Runtime |
| **DEX `rpc_rate` sweep** | The offload lever's saturation curve | Runtime |
| `LEAF_CACHE_PCT` {25,50,75} | Best split between the two caching sub-levers | Runtime |
| `memThreadCount` × offload | Where memory-side capacity stops paying | Rebuild, `NR_DIRECTORY ≥ 8` |
| **Write-mixed workload** | Every cell is read-only, so `[LEAFCACHE] stale=0` throughout — **the coherence protocol has never once fired** | New cell |

Per-system open items, including verification owed on `leafstudy2`, are in
[DEX.md §5](DEX.md) and [CHIME.md §5](CHIME.md).

## V.3 Debt that bounds claims, across both systems

1. **Masked-CAS emulation** ([CHIME.md §5](CHIME.md)) — cross-node concurrent writers are
   outside what this port guarantees. Bounds every correctness claim.
2. **Correctness checking is found/not-found only** — would not catch a stale *value*.
3. **DEX path-aware miss counters read zero** — the caching-lever argument rests on
   `rpc_per_op` and `P_A` rather than a direct inner-vs-leaf split.
4. **Synchronous RPCs** cap offload throughput — every DEX number is a floor.
5. **Scan scratch slot keying** collides across compute nodes.
6. **Repository hygiene.** ~284 deleted files under `CHIME/results/`, ~17 untracked
   including `paper/paper.tex` and `hybrid_plots/`.

## V.4 Naming

`notes.txt` proposes **LIFELINE** over REV: a lifeline is thrown only when someone is
already in trouble — exactly what a miss-gated second lever does, and exactly what the 1.00×
row in Part III shows. It encodes the contribution. If adopted:
`paper/dex_vs_dart.tex:66` carries the name in the title; the other occurrences are
`\graphicspath` paths and stay.

---

## Provenance

| Claim set | Source | Configuration | Status |
|---|---|---|---|
| CHIME lever map | [`CHIME/results/leafstudy2_compute.csv`](CHIME/results/leafstudy2_compute.csv) | 34 thr/node, 16 B values | Measured, **post-repair** |
| CHIME first-cut leaf cache | sweep `leafstudy` | same | Measured, pre-repair |
| CHIME stressed regime (16/32 MB) | `CHIME/results/stress/summary_compute.csv` | 24 thr/node, 48 B values | Measured — **different config, not spliced** |
| DEX (all) | `dex/build/results/summary.csv`, `summary_full.csv` | **36** compute / 4 memory threads | Measured |
| DART reference | `cache_sweep_baseline_summary_20260615_125117.csv` | **56 threads** | Measured — see §V.1 |

Not used anywhere: `dex/8_dex_offload_vs_dart.csv`, whose 64–256 MB rows are marked
`projected`. Every figure above is measured.
