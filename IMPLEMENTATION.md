# Pushdown and Leaf Caching in REV — implementation reference

What has actually been built on top of the DEX and CHIME baselines: memory-node
pushdown for range scans, a compute-side leaf cache with an RDMA seqlock, and the
round-trip accounting that decides whether either one pays. Written against the code
as it stands on branch `chime-leaf-cache`, with the measured results and the parts
that lost.

Companion documents:

- [CHIME/LEAFCACHE.md](CHIME/LEAFCACHE.md) — leaf cache, build + sweep instructions
- [CHIME/OFFLOAD.md](CHIME/OFFLOAD.md) — CHIME RPC offloading, file map
- [CHIME/results/LEAF_CACHE_RESULTS.md](CHIME/results/LEAF_CACHE_RESULTS.md) — the 64-cell sweep
- [CHIME/results/RANGE_SCANS.md](CHIME/results/RANGE_SCANS.md) — why scans regressed
- [COMPARISON.md](COMPARISON.md) — DEX vs DART methodology

---

## Contents

1. [Where each baseline stopped](#1-where-each-baseline-stopped)
2. [DEX: range-scan pushdown](#2-dex-range-scan-pushdown)
3. [CHIME: pushdown from nothing](#3-chime-pushdown-from-nothing)
4. [The two bitmaps, and what each new path does to them](#4-the-two-bitmaps-and-what-each-new-path-does-to-them)
5. [The leaf cache — how it is actually done](#5-the-leaf-cache--how-it-is-actually-done)
6. [Offload or leaf cache? Both — and they divide the work](#6-offload-or-leaf-cache-both--and-they-divide-the-work)
7. [Scans: the regression, its cause, and the fix](#7-scans-the-regression-its-cause-and-the-fix)
8. [Measured results](#8-measured-results)
9. [Build and run matrix](#9-build-and-run-matrix)
10. [Known limits](#10-known-limits)

---

## 1. Where each baseline stopped

Three indexes on one RDMA cluster (memory node `10.30.1.8`, compute node
`10.30.1.6`). They differ in exactly one axis that matters here: **how much of an
index operation the memory node's CPU is allowed to execute.**

| System | What it is | Where it stopped |
|---|---|---|
| **DEX** | B+-tree, PVLDB 17(10). Path-aware compute cache (inner **and** leaf pages) + cost-aware pushdown of `LOOKUP`, `UPDATE`, `INSERT`, `DELETE` at the cache boundary | **No range-scan pushdown** |
| **CHIME** | Hopscotch-leaf B+-tree. Compute cache holds **internal nodes only**; every leaf access is a one-sided RDMA read, made cheap by hopscotch segments, speculative reads and replicated metadata | **No pushdown at all, no leaf caching** |
| **DART** | ART/radix comparison arm. MN sets up QPs, sends `ready`, blocks on a socket. Every access one-sided; the MN CPU never touches an op | Unmodified — the zero-MN-CPU reference |

The DEX paper's own framing is that offloading must be **resource-aware**, because
memory-side compute is scarce. Its §6 makes the decision per lookup using a latency
model, and §7 explicitly subdivides a multi-leaf range scan into *multiple lookups*
using fence keys, because DEX does not maintain leaf links on the compute side. So
scans in the baseline pay the pushdown decision once per covered leaf and never ship
a batch.

Everything below closes those two gaps — a scan pushdown for DEX, and a complete
pushdown plus leaf-cache path for CHIME — under one constant:

> **The memory node may only spend CPU on work the compute-side cache has already
> failed to do.**

---

## 2. DEX: range-scan pushdown

A new `SCAN` RPC type, a memory-node scanner that walks the sibling chain locally,
and a knob that makes the offload ratio an experimental variable rather than an
adaptive policy.

### 2.1 The RPC

`RpcType::SCAN` was added to the existing enum (`dex/include/RawMessageConnection.h`).
The handler in `dex/src/Directory.cpp` reserves one DSM chunk at construction as
**scan scratch**, sliced into per-requester slots keyed by `app_id % MAX_APP_THREAD`.

`cachepush::range_scan()` (`dex/include/cache/btree_rpc.h`) runs entirely on the MN.
Because DEX stores plain structs in DSM, the handler is a cast: `dsm_base + offset`.
It descends to the leaf covering `k`, then walks `next_leaf` forward, packing up to
`max_num` pairs contiguously into the slot. It follows the sibling chain **only while
it stays on this memory node** — a pointer that leaves returns control to the compute
node rather than chasing across MNs.

The reply carries three things the CN needs: the count, the `max_limit_` of the last
leaf visited (the resume boundary), and the global address of the slot. The CN then
pulls the whole batch with **one** RDMA read.

**Return contract:**

| Value | Meaning |
|---|---|
| `> 0` | Pairs packed; caller reads the slot and resumes at `max_key + 1` |
| `-1` | Entry leaf no longer covers `k` (stale cached parent); caller drops its IO flag and retries from the root |
| `0` with `leaves_scanned == 0` | Subtree continues on a different memory node; caller silently falls back to the local read path, still holding its IO flag |

### 2.2 Where it hooks into the tree

In `dex/include/tree/leanstore_tree.h`, the scan path's leaf-parent miss
(`inner->level == 1`, the dominant scan miss) now calls
`cold_to_hot_with_rpc_for_scan()` instead of going straight to admission control.
That function is a strict superset of the old behaviour: when pushdown is not
selected it tail-calls `cold_to_hot_with_admission_for_scan()` — the unmodified
upstream policy.

One subtlety worth recording: on a successful pushdown, `kv_buffer` is deliberately
**not** advanced across leaves. The caller reuses one fixed buffer per op and passes
it by reference, so advancing it would corrupt the next operation; only the returned
count is consumed, matching the local path.

### 2.3 `MANUAL_PUSHDOWN` — making the rate an experimental axis

Stock DEX decides adaptively (`LatencyCollector::caching_or_push`), which is the
right production policy and the wrong experimental one: you cannot sweep an offload
ratio whose value the system overrides. A new cmake option `-DMANUAL_PUSHDOWN=ON`
disables the adaptive path so that `rpc_rate` is the exact fraction of eligible
misses pushed down, sampled per-thread by `manual_push_sample()`. **Without the flag
the build is byte-for-byte upstream policy.**

The same flag also gates `cold_to_hot_with_rpc_for_lookup()`, which pushes a *point*
lookup down at the leaf's parent — the level-1 miss the upstream code handled only
through read-vs-cache admission. Together these make `rpc_rate` the single manual
offload knob for both operation types.

### 2.4 Instrumentation: remote CPU load

`dex/include/remote_load.h` reports each directory thread's **active fraction** —
time inside `process_message` divided by wall time — every 2 s. Raw CPU% is useless
here because the dir thread busy-polls the completion queue and sits at ~100% whether
or not there is work.

```
----- REMOTE CPU LOAD (memory node dir-threads, 2s window) -----
  dir 0: active= 73.4%  msgs=...   ... ns/msg
  AGGREGATE active = 251.0% (of 4 dir-threads; 62.8% per-thread avg)
```

Offload-off reads ~0%; offload-on is the only regime where memory-node CPU load is a
real number. CHIME's `remote_load.h` is the same tracker, so the two systems are
comparable on this axis. DART is structurally 0% — its `memory.cc` blocks on a socket
for the whole run.

---

## 3. CHIME: pushdown from nothing

CHIME had no RPC path at all. Adding one is **not** a cast, because CHIME does not
store plain structs in remote memory — it stores *encoded* ones.

### 3.1 What the memory node has to undo before it can read a leaf

CHIME's on-wire leaf is transformed twice so that a one-sided reader can detect torn
reads without a lock:

1. **Per-cacheline versions.** Every 64-byte line is 63 bytes of payload plus one
   version byte. All version bytes agreeing is the proof that the payload came from a
   single writer's generation.
2. **Metadata replication.** With `METADATA_REPLICATION`, the fence keys, sibling
   pointer and level are *scattered* into every entry group rather than living in one
   header, so a partial segment read is self-describing.

```
leaf at 0x1000, all consistent at version 7

  line0            line1            line2            line3
[ data.....|v=7 ][ data.....|v=7 ][ data.....|v=7 ][ data.....|v=7 ]
   63B     1B       63B     1B       63B     1B       63B     1B

mid-write, RDMA WRITE has landed on line0 only:
[ NEW.......|v=8 ][ data.....|v=7 ][ data.....|v=7 ][ data.....|v=7 ]
                    ^-- half old, half new: 8 != 7, the decoder returns false
```

The MN-side decode that DEX gets for free (`chime_rpc.h::read_leaf_local`):

```c
memcpy(s.raw, dsm_base + addr.offset, define::transLeafSize);   // 1 snapshot
if (!LeafVersionManager::decode_node_versions(s.raw, s.inter))
    return false;                                               // 2 validate -> retry
MetadataManager::decode_node_metadata(s.inter, s.dec);          // 3 un-scatter
leaf = (LeafNode *)s.dec;                                       // 4 a real LeafNode
```

**The snapshot must come first.** You cannot compare version bytes in place: a writer
could land another cacheline between the comparison and the read, and you would have
validated bytes you did not end up using. Copy, then ask whether the copy is
internally consistent. A `false` means a concurrent one-sided writer — the caller
spins, bounded at 2²² attempts.

This is the portability claim in one line:

| | decode step |
|---|---|
| DEX | `(LeafNode *)(dsm_base + offset)` |
| CHIME | `memcpy` → version check → un-scatter → retry on mismatch |

`range_scan` and `lookup_from` are otherwise identical in both ports. Same engine,
different decoder — and the reason the CHIME port cost far more to write.

### 3.2 Two pushdown entry points

**`chime_offload::lookup_from(dsm_base, node_addr, level, k, v)`** is the DEX-style
*cache-boundary* pushdown. `node_addr`/`level` are the deepest node the compute cache
resolved; the MN walks **every remaining internal level and the leaf** in local
memory, faithfully replaying `Tree::internal_node_search` including the turn-right on
a concurrent split. So a descent that would have cost *k* remote reads costs one RPC.
That is what makes offload's benefit grow as the cache shrinks.

**`chime_offload::range_scan(...)`** is the scan analogue: gather keys in
`[from, to)` from the entry leaf, follow `sibling_ptr` while it stays on this node,
pack into the per-requester scratch slot, sort (CHIME leaves are hopscotch-hashed,
therefore unsorted within a leaf), and return the count plus the resume boundary.

### 3.3 Gating: `CHIME_OFFLOAD_MIN_LEVEL`

The offload hook sits in `Tree::search` immediately after the cache lookup, and is
gated on the cache boundary, not just on the rate:

```c
if ((int)level >= g_offload_min_level && should_offload(dsm->getMyThreadID())) { ... }
```

`level == 1` **is** the leaf — internals are level ≥ 2 — so `level == 1` means the
cache already resolved the whole descent and handed back a leaf address. Offloading
that would ask a directory core to perform the single read a one-sided RDMA does with
**zero** memory-node CPU: strictly worse, and it burns the core budget the genuine
misses need. The default `g_offload_min_level = 2` therefore means **offload only on
a cache miss**. Setting it to 1 restores always-offload for comparison.

Range scans are gated the same way but on **coverage** rather than level, in
`Tree::range_query`:

| Cache state for `[from, to)` | Behaviour |
|---|---|
| **Complete miss** — no covering level-1 node | Push the whole scan down (`range_query_offload`) |
| **Partial hit** | Serve the covered prefix locally; offload only the uncovered tail `[covered, to)` |
| **Full hit** | Never offload |

> **Scope.** CHIME pushdown is **read-only**: `RPC_LOOKUP` and `RPC_SCAN` only. There
> is no insert, update, delete or SMO pushdown, so the memory node never mutates a
> node. This matters for §4.

---

## 4. The two bitmaps, and what each new path does to them

CHIME has two distinct bitmaps in a leaf, and they are frequently confused. Neither
is a free-space map. **Both exist to make a *partial, unlocked, one-sided* read
safe** — which is precisely the read that pushdown and leaf caching replace.

### 4.1 Bitmap A — the hopscotch bitmap, one per leaf entry

`LeafEntry::hop_bitmap` is a `uint16_t` using `neighborSize = 8` bits, stored in
*every* entry. Bit *j* of entry *i*'s bitmap means: **the key at slot `i+j` hashes
home to slot `i`**. It is what lets a reader fetch only an 8-entry window instead of
the whole leaf.

Its second job is the interesting one. In `hopscotch_search`, after the segment is
decoded, the reader **recomputes** the bitmap from the eight entries it actually
fetched and compares it against the stored one (`Tree.cpp:2316`):

```c
uint16_t hop_bitmap = 0;
for (int i = 0; i < neighborSize; ++i) {
  const auto& e = records[(hash_idx + i) % leafSpanSize];
  if (e.key != kkeyNull && get_hashed_leaf_entry_index(e.key) == hash_idx)
    hop_bitmap |= 1ULL << (neighborSize - i - 1);
}
if (hop_bitmap != records[hash_idx].hop_bitmap) { read_leaf_retry++; goto re_read; }
```

So the hop bitmap is CHIME's **torn-read detector for partial reads**. A writer that
re-hops a neighbour mid-read leaves the reconstructed and stored bitmaps disagreeing,
and the reader retries. The identical check appears in the stock covered-leaf range
loop (`Tree.cpp:2681`), run over all 16 slots.

### 4.2 Bitmap B — the vacancy bitmap, inside the lock word

With `VACANCY_AWARE_LOCK`, the leaf's 8-byte "lock word" is not a lock word at all —
it is a `VALOCK`:

```
bit  0                15 16                              62   63
    +-------------------+---------------------------------+----+
    |  vacancy_bitmap   |          max_key_idx            |lock|
    |   16 bits         |            47 bits              | 1  |
    +-------------------+---------------------------------+----+
      which buckets        slot of the leaf's max key       bit
      hold entries
```

At `leafLockOffset = ROUND_UP(transLeafSize, 3)`. At the sweep geometry
(`leafSpanSize = internalSpanSize = 16`) the vacancy map is 16 bits. Writers take the
lock with a **masked** CAS over `1ULL << 63` only, so the bitmap in the same word
survives lock acquisition untouched.

`get_read_entry_num_from_bitmap(start_idx, is_leaf)` converts the vacancy map into a
**read length**: how many entries a reader must fetch from `start_idx` before it is
guaranteed to hit an empty bucket. That is the second read-amplification defence —
the bitmap decides how big the one-sided read is.

### 4.3 Does pushdown change the bitmaps on the memory node?

**No. It does not read them, write them, or maintain them.**

The MN handler (`read_leaf_local`) memcpys the whole leaf out of local DSM and
validates it with the *per-cacheline version bytes*. It never touches
`leafLockOffset`, so it never sees the vacancy bitmap or the lock bit; and
`chime_offload::lookup` does a flat linear scan of all `leafSpanSize` records rather
than a hop-window search, so the hop bitmap is read as data and never consulted as an
index.

That is deliberate and it is correct. Both bitmaps exist to make a *partial* read
safe. The memory node has the leaf in local DRAM, so there is no read amplification to
avoid — reading all of it is free — and the whole-node version check is a **strictly
stronger** consistency statement than "the hop bitmaps agree", because it covers every
cacheline rather than one window. The MN skipping the bitmaps is the MN having a
better instrument, not a missing one.

Because pushdown is read-only (no `INSERT`/`UPDATE`/SMO RPC), the memory node never
has cause to *update* a bitmap either. **Both bitmaps are still maintained exclusively
by compute-side writers, exactly as in stock CHIME:** the writer takes the leaf lock
by masked CAS, edits `hop_bitmap` through `set_hop_bit`/`unset_hop_bit` in its local
copy, calls `update_vacancy` on the VALOCK, and writes both back over RDMA.

### 4.4 What each path uses instead

| Path | Hopscotch bitmap | Vacancy bitmap / lock word | Consistency instrument used |
|---|---|---|---|
| Stock point read (`hopscotch_search`) | Used, both as index **and** as the torn-read check | Used to size the read (insert path) | the bitmaps themselves |
| Stock covered-leaf scan | Full 16-slot cross-check, `ok = false` on mismatch | Not read | bitmap cross-check + versions |
| **Leaf-cache hit** | Present in the cached image but **never consulted** — `leaf_probe_local` scans all slots linearly | **Read, but only bit 63.** The 24-byte guard probe spans the lock word; the vacancy bits ride along and are discarded | stamp equality + lock bit |
| **Leaf-cache fill** | Deliberately skipped | Read twice, before and after the data | seqlock bracket |
| **MN pushdown** | Not consulted | Not read at all | whole-node version bytes |

The fill path's omission is explicit in the source (`Tree.cpp:2130`), and worth
quoting because it is the load-bearing argument:

```c
// No hopscotch-bitmap cross-check here on purpose: the bracket already
// proves no writer held this leaf's lock across the data read, which is a
// strictly stronger statement than "the hop bitmaps agree".
```

**The one thing the leaf cache never caches is the lock word.** `LeafCacheEntry` holds
the decoded `LeafNode` — metadata and records — and the stamp. The VALOCK, and
therefore the vacancy bitmap, is re-read from remote memory on every single hit. There
is no path by which a stale vacancy bitmap can be served.

Finally, a consequence for the hop bitmap: a cached leaf's `hop_bitmap` fields **can**
be stale relative to remote memory, because CHIME leaves are mutated by one-sided
writes the cache never sees. This is harmless precisely because nothing reads them.
The stamp catches the staleness one level up, and the linear scan does not depend on
the hop structure being current. Had `leaf_probe_local` reused `hopscotch_search`'s
window logic, a mid-flight rehop would have produced a wrong answer.

---

## 5. The leaf cache — how it is actually done

CHIME's compute cache holds internal nodes only, so the last hop is always remote.
This adds a second cache holding fully decoded leaf images, plus the coherence
protocol that makes serving one safe.

### 5.1 Why the last hop is the whole problem

Give stock CHIME enough cache and the entire descent becomes local — but the descent
is not the operation. The leaf is *always* a remote one-sided read. CHIME spends a lot
of design on making that read cheap:

- **hopscotch leaves** confine a key to a `neighborSize` window, so the reader fetches
  one hop *segment* rather than the whole leaf;
- **`SPECULATIVE_READ`**'s hotspot buffer remembers which slot a hot key sits in and
  shrinks the read to a single entry;
- **`METADATA_REPLICATION`** puts a metadata copy in every entry group so a segment
  read is self-describing.

Every one of those optimises the **bytes** of the last round trip. None removes the
**round trip**. And on an RDMA fabric a 70-byte read and a 500-byte read cost nearly
the same.

| | inner nodes only | inner nodes **and** leaves |
|---|---|---|
| point lookup, index hit | 1 RTT, one hop segment (~500 B) | 1 RTT, **24-byte probe** |
| point lookup, index miss | k RTTs down the tree | unchanged (offload's job) |

### 5.2 The budget is one number, split — never grown

`CHIME_CACHE_MB` is the **total** compute-side cache, and the leaf cache is carved
*out* of it (`CHIME_LEAF_CACHE_PCT`, default 50). Invariant:
`g_index_cache_mb + g_leaf_cache_mb == CHIME_CACHE_MB`, always.

| Total | `CACHE_LEAF=0` (inner/leaf) | `CACHE_LEAF=1` at `PCT=50` |
|---|---|---|
| 1024 MB | 1024 / 0 | 512 / 512 |
| 512 MB | 512 / 0 | 256 / 256 |
| 256 MB | 256 / 0 | 128 / 128 |
| 128 MB | 128 / 0 | 64 / 64 |
| 64 MB | 64 / 0 | 32 / 32 |

This is not a detail, it **is** the comparison. DART is swept at the same totals, so
all arms occupy identical compute-side memory at every point. If the leaf cache were
extra memory on top, a win would only say *"CHIME was given more RAM."* Caching leaves
has to **earn its share against the inner nodes it displaces** — which also means a
*flat* curve is a real result. Every cell records the split it actually ran
(`total_cache_mb`, `inner_cache_mb`, `leaf_cache_mb`), and `plot_leaf_cache.py` flags
any row where inner + leaf ≠ the point.

### 5.3 Coherence: a seqlock over RDMA, anchored on the leaf lock

Every other read in CHIME is self-validating — it fetches the real bytes and the
version machinery certifies them. **A leaf served out of DRAM is not.** Leaves are
mutated by one-sided writes from any node under the leaf's own lock, so a cached image
can go stale three ways: an entry **update**, an **insert** (which also re-hops
neighbours), and a **split** (which moves keys out and rewrites the fence keys and
sibling pointer).

The mechanism is an 8-byte **stamp** per leaf allocation, published by the writer
under the lock and checked by the reader before every hit:

```
writer (Tree::lock_node)                 reader (cached image, stamp S)
------------------------                 ------------------------------
1. masked CAS lock word -> busy          read 24 B [lock word .. stamp]
2. write stamp -> S'  (fresh, unique)
3. write data                            serve the image IFF
4. write lock -> free                        lock is UNLOCKED and stamp == S
```

All four writer ops go down the **same RC queue pair**, so the memory node applies
them in that order. The stamp is `(global_thread_id << 48) | per-thread counter`:
globally unique and **never reused**, so a stamp a reader cached can never be
re-produced by a later write. The counter starts at 1, so a live stamp is never 0 —
0 means "never written", which is itself a perfectly cacheable state (a fresh split
sibling).

**Why the probe is conclusive, not heuristic:**

- If a write *completed* before the probe was issued, all four ops had landed, so the
  probe reads `S' != S` → refused.
- If a write is still *in flight*, either its stamp write has landed — stamp differs,
  refused — or it has not, in which case its CAS may or may not have landed. If it
  has, the probe reads **busy** → refused.
- If neither has landed, then no data byte has been written yet, so serving the cached
  image returns the pre-write value of a write that has not completed — exactly what a
  concurrent one-sided reader in stock CHIME may return.

**The cache is never weaker than the system it sits in.** There is no "trust the
cache" mode; the probe runs before every hit.

### 5.4 Where the stamp lives, and why not next to the lock

```
 0                              transLeafSize        +16       +8
+--------------------------------+-------------------+---------+
|  encoded leaf                  |  VALOCK           |  stamp  |
|  (versioned + scattered)       |  16 B lock area   |   8 B   |
+--------------------------------+-------------------+---------+
                                 ^                   ^         ^
                                 leafLockOffset      leafStampOffset
                                 |<--- leafGuardSize = 24 B --->|
                                        ONE read
```

`allocationLeafSize = transLeafSize + 16 + 8`. The stamp is the **last 8 bytes** of
the allocation, deliberately past the lock area rather than adjacent to the lock word.

Every "write the node (or its last segment) **and** release the lock in one RDMA op"
in `Tree.cpp` writes exactly up to `transLeafSize + allocationLockSize` — so a stamp
inside that window would be silently overwritten by whatever the writer's local buffer
happened to hold there, and a stale leftover could **coincidentally match** a stamp
some reader had cached. Outside the window it is only ever written deliberately.

The guard probe is one read spanning `[lock word .. stamp]` inclusive — 24 bytes at
this geometry — so the lock check and the stamp check cost one round trip between
them, not two.

### 5.5 Filling costs no extra round trip

A fill closes the same seqlock *around* the data read, posted as one doorbell batch of
three RDMA reads:

```c
rs[0]  [lock, stamp]   24 B          @ leaf + leafLockOffset
rs[1]  leaf bytes      transLeafSize @ leaf
rs[2]  [lock, stamp]   24 B          @ leaf + leafLockOffset
dsm->read_batch_sync(&rs[0], 3, sink);          // ONE round trip
```

An RC responder executes a queue pair's requests in order, so the two guard samples
really do bracket the data read. The image is published only if both samples read
UNLOCKED with an equal stamp (`cacheable = true`). So **a fill costs the single round
trip the uncached read would have cost anyway**, and the published image is a provably
quiescent snapshot. If the decode fails — a genuine torn read — the loop retries,
bounded at 8 attempts, then falls through to the stock path.

### 5.6 Structure of the cache

| Property | Choice | Reason |
|---|---|---|
| Organisation | fixed-capacity, 8-way set-associative | Capacity computed from the byte budget at construction, so it *cannot* exceed budget and there is no eviction livelock to tune |
| Set index | splitmix64 finaliser, then mask | Leaf addresses are allocation-size-strided within a chunk; hashing the raw offset would leave low bits near-constant and collapse the sets |
| Replacement | LFU with aging | On eviction the survivors are aged `(freq >> 1) + 1`, so a leaf that was hot long ago cannot hold a way forever |
| Entry lifetime | immutable after publish | A refresh publishes a *new* entry and CASes it in; a live image is never mutated under a reader |
| Reclamation | deferred free, epoch = `20 * MAX_APP_THREAD * MAX_CORO_NUM` | Same scheme `TreeCache`/`IdxCache` use — a reader may still hold a pointer it loaded a moment ago |
| Invalidate | sweeps the **whole** set | Two threads missing on the same leaf can each fill a different way; a duplicate left behind would survive this node's own write |

### 5.7 Self-invalidation on write

The hook sits in `Tree::lock_node` — the single choke point every leaf mutation passes
through, since insert, update and both split paths take the leaf lock first.
Immediately after the CAS succeeds and **before any data byte moves**:

1. `publish_leaf_stamp()` — so every *other* node's cached image of this leaf fails
   validation from now on. The write is unsignaled and not waited on: correctness needs
   it *ordered* before this thread's subsequent data writes, which the queue pair
   guarantees, not *completed* before them.
2. `leaf_cache->invalidate()` — drop our own image immediately, saving this node a
   guaranteed-stale probe on a leaf it is itself rewriting.

> **Cluster constraint this creates.** Both steps are gated on the *runtime* switch
> `CHIME_CACHE_LEAF`, not just the compile-time one — with the cache off nobody reads
> stamps, so publishing them would be pure overhead and would make the baseline arm of
> the A/B not-quite-stock CHIME (an extra RDMA write on every leaf lock, i.e. on all
> 50 M bulk-load inserts). The consequence: **every node in the cluster must run with
> the same `CHIME_CACHE_LEAF` value.** If one node cached leaves while another wrote
> with stamps disabled, the writer would never invalidate the reader's images. The
> sweep sets it identically on both nodes and `micro_test` prints it per node, so a
> mismatch is visible in the logs.

### 5.8 Interaction with `SPECULATIVE_READ`

With leaf caching on, the hotspot buffer is disabled and its budget goes to the leaf
cache. The two answer the same question — *where does this key live* — at different
granularities, and because a speculative hit never fetches a whole leaf, running both
would keep the leaf cache permanently cold. `CHIME_LEAF_KEEP_SPECULATIVE=1` stacks
them (speculative first) if you want to measure that.

---

## 6. Offload or leaf cache? Both — and they divide the work

They are not alternatives and they are not redundant. At the default gate they
partition the operation space cleanly, and each covers the case the other cannot.

**Which one serves a given operation is decided by where the compute-side index cache
ran out.** At `CHIME_OFFLOAD_MIN_LEVEL = 2` they are disjoint by construction:

```
cache boundary  |
   level >= 2   |  ---> OFFLOAD serves it
                |       Internal levels still to walk. The MN walks the remaining
                |       internals AND the leaf in local memory: k round trips -> 1 RPC.
                |       Leaf cache is never consulted.
----------------+--------------------------------------------------------------
   level == 1   |  ---> LEAF CACHE serves it
                |       The cache resolved the whole descent and handed back a leaf
                |       address. The only work left was the leaf read; a cached image
                |       turns it into a 24-byte probe. Offloading here would burn MN
                |       CPU to do what one-sided RDMA does for free.
```

> **Offload serves the index misses; the leaf cache serves the index hits.**

At `CHIME_OFFLOAD_MIN_LEVEL = 1` offload takes every lookup and the leaf cache is
never consulted on the point path — `micro_test` prints a warning if you configure
that.

This is why they compose rather than compete, and the sweep shows it directly. The
split budget halves the inner cache, which pushes the leaf arm across the "index no
longer fits" boundary one cache point earlier than the baseline. Offload rescues
exactly that:

| Cell (leaf cache on) | offload off | offload on |
|---|---:|---:|
| point-zipf, 128 MB total | 1.111 | **3.157** |
| point-zipf, 64 MB total | 1.200 | **3.157** |
| range-zipf, 128 MB total | 0.120 | **0.355** |
| range-uniform, 128 MB total | 0.066 | **0.241** |

At large caches offload is inert — the index fits, so there are no misses to push
down. That is the correct behaviour, and it is the whole design intent: **the memory
node spends CPU only after caching has failed.**

---

## 7. Scans: the regression, its cause, and the fix

The first cut of the leaf cache made range scans measurably worse — by 41% under
uniform, and by 15% *even at a 59% hit rate*. The cause was structural, and it is
worth writing up because it is the cleanest demonstration in the study that **round
trips are the cost on this fabric, not bytes.**

### 7.1 What the first cut did

It served each covered leaf on its own: one guard probe per resident leaf, one
seqlock-bracketed read per missing leaf. Per covered leaf:

| Case | round trips | bytes moved | extra work |
|---|---:|---|---|
| baseline (leaf cache off) | 1 | ~1 KB read | decode |
| leaf cache HIT | 1 | ~24 B probe | local scan |
| leaf cache MISS | 1 | 3-WR batch | decode + ~480 B alloc/memcpy + LFU + deferred-free push |

**The round-trip count per scan was unchanged.** Hits saved almost nothing; misses
kept the round trip *and* added the fill cost. Under uniform, 88–94% of covered leaves
are misses, so the fill overhead dominated outright.

Point lookups won anyway (+40% on zipf) because the point *baseline*'s per-leaf cost
is variable and often more than one round trip: a speculative read can mis-guess and
fall back to a full hopscotch search, `read_leaf_retry` fires on a version mismatch,
`read_two_segments` when the hop window wraps. A cache hit replaces all of that with
exactly one small probe. The range baseline was already exactly one round trip per
leaf, so there was nothing to remove.

### 7.2 Fix 1 — batch the covered-leaf path

The covered set is fully known before any I/O: `leaf_addrs` is complete before the
read loop begins. So `Tree::range_query` now issues two doorbells regardless of leaf
count:

- **Phase 0** — partition the covered set into resident / not-resident by probing the
  cache locally.
- **Phase 1** — *one* doorbell of `[lock, stamp]` guard reads for every resident leaf.
  Leaves whose stamp still matches are harvested entirely locally; the rest are
  invalidated and demoted into the fetch batch.
- **Phase 2** — *one* doorbell of 3-WR seqlock-bracketed reads for every leaf not
  resident or whose probe failed.

```
                       round trips for a ~12-leaf scan
stock CHIME            ############                     12
leaf cache, v1         ############                     12   (bytes shrank, RTTs didn't)
leaf cache, batched    ##                                2
```

**The per-leaf seqlock still holds with several leaves interleaved in one doorbell:**
each leaf contributes its three work requests consecutively, and RC processes a queue
pair's requests in order, so leaf *i*'s bracket still encloses leaf *i*'s data read.

> **Risk this reintroduces, stated because it has bitten this file before.** The
> comment above this block in `Tree.cpp` blames "one doorbell list with an entry per
> leaf-segment (dozens)" for a historical completion-status storm. Mitigations:
> chunked at **32 leaves**, so a doorbell is at most 96 work requests against a
> 4096-deep send queue (the legacy path posted more, unchunked); every read is still
> version-decoded before it is trusted; and a leaf that will not decode falls back to
> the per-leaf read and then to per-key `search()` — never a re-issue of the whole
> batch.

### 7.3 Fix 2 — per-path admission

A scan streams through leaves it never revisits, and each insert costs a ~480-byte
`LeafCacheEntry` allocation, a memcpy and LFU bookkeeping — pure loss. Point-path
fills are the opposite: they are what produced the +40% on point-zipf. So the rates
are **separate**, and throttling scans cannot damage the thing that works. This
mirrors DEX's `ADMIT` knob (`cold_to_hot_with_admission[_for_scan]`), which DEX sets
to 0.1.

```
CHIME_LEAF_ADMIT_POINT   default 1.0   // leaf_node_search fill
CHIME_LEAF_ADMIT_SCAN    default 1.0   // range_query fill
```

Both default to 1.0 — admit everything, i.e. no behaviour change — **on purpose**: the
batching change landed in the same commit, and two knobs moving at once cannot be
attributed. Measure batching alone first, then sweep `CHIME_LEAF_ADMIT_SCAN`.

Admission uses a deterministic per-thread counter rather than an RNG, so a rate of *r*
admits ~*r* of every 100 candidates on each thread and the run is reproducible (DEX
uses a real `mt19937`, which makes its results depend on thread scheduling). The
`[LEAFCACHE]` line now reports `fill=` and `admit_pct=` so the ratio actually achieved
is visible per cell.

> **Status.** Both fixes are committed (`15070de`) but **not yet compiled or run** —
> the Linux RDMA cluster is the only place this builds. The first cluster run must
> re-check `[CORRECTNESS] lookup found %` and scan rows against `CACHE_LEAF=0` before
> any of the numbers in §8 are updated.

---

## 8. Measured results

Sweep `leafstudy`, 64 cells, ~6 h wall time. 2 nodes, 34 app threads per node, 4 dir
threads, 50 M keys, 8-byte keys, **16-byte values**, 30 M measured ops, scan length
100, zipf θ = 0.99. Build:
`-DENABLE_OFFLOAD=ON -DCACHE_LEAF_NODE=ON -DCHIME_VALUE_LEN=16`.

All figures are the **compute node's own rate**. **These pre-date the batching and
admission fixes of §7.**

### 8.1 Point lookups — the leaf cache works

| Workload | Total cache | Leaf hit | Baseline | + leaf cache | Δ |
|---|---:|---:|---:|---:|---:|
| point / zipf-0.99 | 512 MB | 69.9% | 2.857 | 3.999 | **+40%** |
| point / zipf-0.99 | 256 MB | 63.5% | 2.857 | 3.999 | **+40%** |
| point / uniform | 512 MB | 12.3% | 2.307 | 2.608 | +13% |
| point / uniform | 256 MB | 6.0% | 2.307 | 2.500 | +8% |

p99 improves alongside throughput at 512 MB: **21.0 → 17.0 µs**.

The skew dependence is exactly as predicted, and it is a benchmark artifact worth
stating: `to_key` runs the Zipf *rank* through CityHash, so a hot rank becomes a
pseudorandom *key* and hot keys scatter across ~4.5 M leaves. Under uniform a 256 MB
leaf cache covers ~12% of them; under Zipf the same cache captures the hot set.

### 8.2 Range scans — the leaf cache loses

| Workload | Total cache | Leaf hit | Baseline | + leaf cache | Δ |
|---|---:|---:|---:|---:|---:|
| range / uniform | 512 MB | 12.2% | 0.496 | 0.293 | **−41%** |
| range / uniform | 256 MB | 6.1% | 0.496 | 0.279 | **−44%** |
| range / zipf-0.99 | 512 MB | 59.0% | 0.496 | 0.423 | **−15%** |
| range / zipf-0.99 | 256 MB | 52.0% | 0.500 | 0.408 | **−18%** |

p99 goes the same way: range-uniform at 512 MB, 82.0 → 157.5 µs. Mechanism in §7.

### 8.3 The 128 MB cliff

At 128 MB total the leaf arm runs a **64 MB inner cache**, below the index working
set, and the descent thrashes: point-uniform 2.307 → 0.625, point-zipf 2.857 → 1.111.
The baseline's 128 MB inner cache still fits. This is the trade-off the split budget
was designed to expose, and it lands one cache point earlier for the leaf arm — as
predicted. At 64 MB both arms are stressed and converge (1.154 vs 1.200).

### 8.4 Trap — read hit rate and throughput together

`range-uniform` at 128 MB, leaf on, offload off: **86.2% leaf hit, 0.066 Mops** —
near-best hit rate, worst throughput in the sweep.

That is not the leaf cache. With a 64 MB inner cache there is no covering level-1 node,
so `range_query` takes its fallback: a per-key `search()` across the whole span — **100
point lookups per scan** instead of ~12 covered-leaf reads. Those lookups hit the leaf
cache, which is where the 86% comes from. **A high hit rate on the range path can mean
the scan degenerated.**

### 8.5 Correctness

Every cell reported `lookup found ≈ 99.99%`, matching between `CACHE_LEAF=0` and
`CACHE_LEAF=1`. That value is structural, not coincidental: bulk load inserts 50 M keys
into a 50,001,000-key space, so ~0.0100% of lookups target keys that were never
inserted.

`[LEAFCACHE] stale=0` throughout — the seqlock probe never rejected an image, which is
what a read-only measured phase should produce. The coherence path is exercised but
idle.

> **Limit of that check.** It verifies found/not-found only, never the *value*. A cache
> returning a stale value for a key that still exists would not be caught. Nothing
> writes during these cells, so there is no stale value to return — but do not lean on
> this check if an insert/update mix is added.

### 8.6 Against DART

DART baseline at 34 threads (`DART/cache_sweep_baseline_20260622_071147.csv`), flat
across 64–512 MB:

| Workload | DART (Mops) | CHIME baseline, per node |
|---|---:|---:|
| point / uniform | 2.82 | 2.31 |
| point / zipf | 2.86 | 2.86 |
| range / uniform | 1.26 | 0.50 |
| range / zipf | 1.27 | 0.50 |

> **Do not quote a ratio without the thread asymmetry.** DART drives 34 client threads
> from **one** machine; CHIME runs the same binary on both nodes, so `THREADS=34` means
> **68** client threads, and cluster throughput is the sum of the two nodes. Either
> report per-node figures against DART's, or state the thread counts alongside any
> ratio. `THREADS=17` matches total client parallelism.

CHIME's scan path is where it is structurally weakest — 0.28–0.50 Mops per node against
DART's 1.26 even in the baseline arm — and the leaf cache as first built made it worse
rather than better. That is the gap §7's batching is aimed at.

---

## 9. Build and run matrix

The design rule throughout: **anything that changes the on-wire allocation layout is
compile-time and must match on every node; anything that only changes behaviour is
runtime**, so one binary serves both arms of an A/B.

### 9.1 Compile-time (must be identical on all nodes)

| Flag | Default | Effect |
|---|---|---|
| `-DENABLE_OFFLOAD` | `OFF` | Compiles in `RPC_LOOKUP`/`RPC_SCAN`, the MN handlers and the remote-load tracker. Off = functionally stock CHIME (only `RawMessage` grows, still under `MESSAGE_SIZE`) |
| `-DCACHE_LEAF_NODE` | `ON` | Compiles in the 8-byte stamp and the cache. Compile-time because it changes `allocationLeafSize` — a mismatched pair corrupts reads. `OFF` restores the exact pre-leaf-cache geometry |
| `-DCHIME_VALUE_LEN` | `48` | **Set to 16 to match the DART baseline's `--payload_byte`.** At 16 B a leaf is ~459 B instead of ~979 B, so roughly twice as many leaves fit the leaf cache — it changes the headline number |
| `-DCHIME_INTERNAL_SPAN` | `16` | Inner-node fanout. 16 makes an internal node (319 B) smaller than a leaf without shrinking the index we want to overflow the cache |
| `-DMANUAL_PUSHDOWN` | `OFF` | *DEX only.* Disables the adaptive policy so `rpc_rate` controls offloading exactly |

After changing the value length, check the `[GEOMETRY] internal/leaf` line says
**`OK: internal < leaf`** — at 16 B it is 319 B vs 459 B, still fine, but the margin is
1.4× rather than 3.1×.

```bash
# both nodes, identical flags
cd CHIME && rm -rf build && mkdir build && cd build
cmake -DENABLE_OFFLOAD=ON -DCACHE_LEAF_NODE=ON -DCHIME_VALUE_LEN=16 ..
make -j
```

### 9.2 Runtime

| Env / knob | Default | Meaning |
|---|---|---|
| `CHIME_CACHE_MB` | — | **Total** compute-side cache; split, never grown |
| `CHIME_CACHE_LEAF` | `0` | Leaf cache off/on. Must match across nodes (§5.7) |
| `CHIME_LEAF_CACHE_PCT` | `50` | Leaf share of the total, percent; rest goes to inner nodes |
| `CHIME_LEAF_CACHE_MB` | — | Absolute leaf budget, overrides the percentage |
| `CHIME_OFFLOAD_MIN_LEVEL` | `2` | Cache-boundary level at which a lookup is worth offloading. 1 = always-offload |
| `CHIME_LEAF_ADMIT_SCAN` / `_POINT` | `1.0` / `1.0` | Per-path admission ratios (§7.3) |
| `CHIME_LEAF_KEEP_SPECULATIVE` | `0` | Keep the hotspot buffer stacked on top of the leaf cache |
| `CHIME_RANGE_BATCHED` | unset | Restore the legacy fine-grained batched range path |

### 9.3 Log lines the sweep scripts parse

```
[GEOMETRY] internal/leaf = 0.70x  (OK: internal < leaf)
[CACHE node N] total=256 MB index=128 MB leaf=128 MB
[LEAFCACHE] hit=… miss=… stale=… fill=… hit_pct=… admit_pct=… resident=… capacity=… budget_mb=…
[CORRECTNESS node N] lookup found … %
----- REMOTE CPU LOAD (memory node dir-threads, 2s window) -----
  dir 0: active= 73.4%  msgs=…   … ns/msg
```

**Two gates before spending hours on a sweep.** `inner + leaf` must equal the cache
point on every row — the plotter flags violations, and if it flags anything the arms
were not on equal memory and the comparison is void. And `[CORRECTNESS]` must be
identical between `CACHE_LEAF=0` and `CACHE_LEAF=1`, offload off and on. A difference
means the cached-image path returns different results from the remote path — stop and
fix, do not sweep.

---

## 10. Known limits

Stated here rather than discovered later. Several are properties of the port, not of
the new code, but they bound what the results can claim.

### 10.1 The masked-CAS emulation

The leaf cache's correctness argument rests on the leaf lock. On this rdma-core port
masked compare-and-swap is **emulated** — `DSM::cas_mask_sync` does a read plus a plain
CAS, serialised by a **process-local** mutex. So cross-node concurrent writers are
already outside what this port guarantees. That is a pre-existing property of the port,
not of the leaf cache; single-node writers (what the benchmark does) are fine. The
upstream cause is that CHIME needs MLNX experimental verbs for true masked atomics,
which this cluster's rdma-core stack does not provide.

### 10.2 Other bounds

- **`ENABLE_VAR_LEN_KV` is untested with leaf caching.** The cached image holds the
  `DataPointer`, and the point path resolves it with the same second hop it always did,
  but the range harvest would return pointers — the same limitation the existing range
  path has. It is also not offloaded, on either system.
- **Synchronous RPCs.** `rpc_lookup`/`rpc_scan` block on `rpc_wait()` with no coroutine
  yield, so offloaded ops do not overlap under `kCoroCnt`. Fine for the load
  measurement; they need to be coro-aware for peak throughput. The leaf-cache probe, by
  contrast, uses `read_sync` and yields like every other CHIME read.
- **Scan scratch slot keying.** Both systems key the slot by `app_id % MAX_APP_THREAD`.
  Across multiple compute *nodes*, two threads can share a slot — harmless for load
  numbers, but key by global thread id if exact multi-CN scan results are needed.
- **Single-memory-node confinement.** Both scan handlers follow the sibling chain only
  while it stays on the issuing memory node, and CHIME's `lookup_from` does the same for
  internal descent. A pointer that leaves returns control to the compute node. This
  mirrors DEX's subtree-placement condition and avoids remote pointer chasing across
  MNs.
- **Provenance.** Offload-on arms measured *before* commit `6aef59b` are not comparable
  with later ones: a node that did not bulk-load ran with a permanently empty index
  cache and therefore offloaded 100% of lookups. Do not mix pre- and post-fix data in
  one figure.

---

## Sources

`CHIME/src/Tree.cpp` · `CHIME/src/Directory.cpp` ·
`CHIME/include/{LeafCache,chime_rpc,remote_load,Common,LeafNode,Metadata}.h` ·
`CHIME/test/micro_test.cpp` · `dex/include/cache/{btree_rpc,leanstore_cache}.h` ·
`dex/include/tree/leanstore_tree.h` · `dex/include/RawMessageConnection.h` ·
`CHIME/results/{LEAF_CACHE_RESULTS,RANGE_SCANS}.md`.

Measured figures from sweep `leafstudy`, 2026-08-30/31. The §7 fixes (commit
`15070de`) are committed but not yet run.
