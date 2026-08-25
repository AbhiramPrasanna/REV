#if !defined(_LEAF_CACHE_H_)
#define _LEAF_CACHE_H_
// ===========================================================================
// LeafCache.h -- compute-side cache of LEAF nodes.
//
// WHY THIS EXISTS
//   Stock CHIME caches INTERNAL nodes only (TreeCache). The descent is
//   therefore local, but the last hop -- the leaf -- is ALWAYS a remote
//   one-sided read. CHIME makes that last hop cheap rather than free: hopscotch
//   hashing confines a key to a `neighborSize` window so the reader fetches one
//   hop SEGMENT instead of the whole leaf (no read amplification), and
//   SPECULATIVE_READ's hotspot buffer shrinks it further to a single entry. Both
//   optimise the BYTES of the last round trip; neither removes the round trip.
//
//   This cache shrinks it to almost nothing. A cached leaf is a fully decoded
//   `LeafNode` image in compute-node DRAM, so a point lookup that hits it costs
//   one 16-byte validation read instead of a segment read, and a range scan
//   validates every covered leaf it holds instead of reading each one in full.
//
//   The compute node then caches BOTH node types -- inner nodes in TreeCache,
//   leaves here -- and the question the sweep asks is whether that beats caching
//   inner nodes alone.
//
// THE BUDGET IS ONE NUMBER, SPLIT
//   CHIME_CACHE_MB is the TOTAL compute-side cache, and the leaf cache is carved
//   OUT of it (CHIME_LEAF_CACHE_PCT, default 50): index + leaf always sums to the
//   sweep point. That is deliberate and it is the only honest setting -- DART is
//   compared at a fixed total compute-side budget (64/128/256/512/1024 MB), so if
//   the leaf cache were extra memory on top, a win would only say "CHIME was given
//   more RAM". Caching leaves has to EARN its share against the inner nodes it
//   displaces, and that trade-off is exactly what the sweep measures.
//
// THE HARD PART IS NOT THE CACHE, IT IS COHERENCE
//   Every other CHIME read is self-validating: it fetches the real bytes and
//   CHIME's version machinery certifies them. A leaf served from DRAM is not.
//   Leaves are mutated by ANY node with one-sided RDMA writes under the leaf's
//   own lock word, so a cached image can go stale three ways: an entry update,
//   an insert (which also re-hops neighbours), and a split (which moves keys out
//   and rewrites fence keys / sibling pointer).
//
//   The protocol here is a SEQLOCK OVER RDMA anchored on the leaf's own lock:
//
//     * Every leaf allocation carries an 8-byte STAMP right after its lock word
//       (define::leafStampOffset). A stamp value is globally unique and never
//       reused: (global_thread_id << 48) | per-thread counter.
//     * A writer publishes a fresh stamp IMMEDIATELY AFTER acquiring the leaf
//       lock and BEFORE touching data (Tree::lock_node). Both go down the same
//       RC queue pair, so the responder applies them in order: lock -> stamp ->
//       data -> unlock.
//     * A reader validates a cached image with ONE 16-byte read of
//       [lock word, stamp] and serves it only if the leaf is UNLOCKED and the
//       stamp still equals the one recorded at fill time.
//
//   Why that is correct. Suppose a write COMPLETED (the writer returned) before
//   the reader issued its 16-byte probe. Then its CAS, its stamp write, its data
//   write and its unlock had all landed, so the probe reads the new stamp and the
//   entry is refused. Suppose instead the write is still IN FLIGHT. Either its
//   stamp write has landed -- the stamp differs, refused -- or it has not, in
//   which case its CAS (ordered before it) may or may not have landed; if it has,
//   the lock reads BUSY and the entry is refused, and if it has not, no byte of
//   data has been written yet either, so serving the cached image returns the
//   pre-write value of a write that has not completed. That is exactly what a
//   concurrent one-sided reader in stock CHIME may return, so the cache is no
//   weaker than the system it sits in.
//
//   A FILL is the same seqlock closed around the data read, issued as ONE
//   doorbell batch of three RDMA reads -- [lock,stamp], leaf bytes, [lock,stamp]
//   -- which an RC responder executes in order. The image is cached only if both
//   probes read UNLOCKED and the two stamps are equal, so a fill costs the same
//   single round trip the uncached read would have cost anyway.
//
//   There is ONE coherence mode and it is always on. The probe runs before every
//   hit, so the cache is correct under arbitrary concurrent writers from any node
//   -- no read-only assumption, no configuration that can silently produce wrong
//   numbers. What it buys: a point lookup still costs one round trip, but a
//   16-byte one instead of a segment; a range scan validates all its covered
//   leaves instead of reading each one in full. So expect a LARGE win on scans and
//   a modest one on point lookups.
//
// STRUCTURE
//   Fixed-capacity, set-associative (8-way), LFU-with-aging replacement. Capacity
//   is sized from the byte budget at construction, so the cache cannot exceed its
//   budget by construction -- no free_size chasing, no eviction livelock. Entries
//   are immutable once published; replacement CASes a new pointer into the slot
//   and retires the old one through the same deferred-free queue TreeCache and
//   IdxCache use.
// ===========================================================================

#include "Common.h"
#include "GlobalAddress.h"
#include "Key.h"
#include "LeafNode.h"

#include <tbb/concurrent_queue.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace leafcache {

// ---- runtime knobs (env), resolved once on first use ----------------------
// Runtime rather than compile-time on purpose: CACHE_LEAF is an A/B axis of the
// sweep, exactly like the offload rate and CHIME_CACHE_MB, so both arms must come
// out of ONE binary. The on-wire geometry (the 8-byte stamp) is compiled in
// unconditionally under CACHE_LEAF_NODE so the two arms address identical memory.
inline bool enabled() {
  static const bool v = [] {
    const char *e = getenv("CHIME_CACHE_LEAF");
    return e && atoi(e) != 0;
  }();
  return v;
}

// Keep SPECULATIVE_READ's hotspot buffer alive alongside the leaf cache?
// Off by default: the two caches answer the SAME question (where does this key
// live) at different granularities, and running both means a leaf-cache miss is
// resolved by a single-entry speculative read that never fetches enough of the
// leaf to fill the cache -- the leaf cache would then stay permanently cold. With
// leaf caching on, a miss reads the WHOLE leaf and fills. Set
// CHIME_LEAF_KEEP_SPECULATIVE=1 to run them stacked (speculative first) instead.
inline bool keep_speculative() {
  static const bool v = [] {
    const char *e = getenv("CHIME_LEAF_KEEP_SPECULATIVE");
    return e && atoi(e) != 0;
  }();
  return v;
}

}  // namespace leafcache


// One cached leaf: the decoded logical image plus the stamp it was valid at.
// Immutable after publication except for `freq` (a replacement hint only).
struct LeafCacheEntry {
  GlobalAddress leaf_addr;
  uint64_t stamp;              // define::leafStampOffset value observed at fill
  mutable int32_t freq;        // LFU counter, bumped on hit
  LeafNode leaf;               // decoded metadata + records

  LeafCacheEntry(const GlobalAddress &addr, uint64_t stamp, const LeafNode *src)
      : leaf_addr(addr), stamp(stamp), freq(1) {
    memcpy(&leaf, src, sizeof(LeafNode));
  }
};


class LeafCache {
public:
  LeafCache(int cache_size_mb);
  ~LeafCache();

  // Returns the cached image for `leaf_addr`, or nullptr. Does NOT validate --
  // the caller decides (Tree::leaf_cache_validate) because validation needs RDMA.
  const LeafCacheEntry *get(const GlobalAddress &leaf_addr);

  // Publish a decoded image. `stamp` must have been observed with the seqlock
  // protocol described at the top of this file; callers that could not close the
  // seqlock must simply not call this.
  void put(const GlobalAddress &leaf_addr, const LeafNode *leaf, uint64_t stamp);

  // Drop the entry for `leaf_addr` (stale image, or this node is about to write
  // the leaf itself).
  void invalidate(const GlobalAddress &leaf_addr);

  void statistics(uint64_t hit, uint64_t miss, uint64_t stale) const;

  uint64_t capacity_entries() const { return (uint64_t)nsets * kWays; }
  uint64_t budget_bytes() const { return capacity_entries() * sizeof(LeafCacheEntry); }
  int size_mb() const { return cache_size_mb; }

private:
  static constexpr int kWays = 8;

  uint64_t set_of(const GlobalAddress &addr) const {
    // Leaf addresses are allocation-size-strided within a chunk, so hashing the
    // raw offset would leave the low bits nearly constant and collapse the sets.
    // Mix first (splitmix64 finaliser), then mask.
    uint64_t x = addr.to_uint64();
    x ^= x >> 30; x *= 0xbf58476d1ce4e5b9ULL;
    x ^= x >> 27; x *= 0x94d049bb133111ebULL;
    x ^= x >> 31;
    return x & (nsets - 1);
  }

  void retire(LeafCacheEntry *e);

  int cache_size_mb;
  uint64_t nsets;               // power of two
  LeafCacheEntry **table;       // nsets * kWays slots

  tbb::concurrent_queue<LeafCacheEntry *> gc;
  static constexpr int safely_free_epoch = 20 * MAX_APP_THREAD * MAX_CORO_NUM;
};


inline LeafCache::LeafCache(int cache_size_mb) : cache_size_mb(cache_size_mb) {
  uint64_t want = (uint64_t)cache_size_mb * define::MB / sizeof(LeafCacheEntry);
  uint64_t sets = want / kWays;
  uint64_t p = 1;
  while (p * 2 <= sets) p *= 2;   // largest power of two that fits the budget
  if (p < 64) p = 64;             // floor so a tiny budget still works
  nsets = p;
  table = (LeafCacheEntry **)calloc(nsets * kWays, sizeof(LeafCacheEntry *));
  assert(table);
  printf(" ----- [LeafCache]: budget=%d MB -> %lu sets x %d ways = %lu leaves"
         " (%lu B/leaf, %.1f MB) -----\n",
         cache_size_mb, (unsigned long)nsets, kWays,
         (unsigned long)capacity_entries(), (unsigned long)sizeof(LeafCacheEntry),
         (double)budget_bytes() / define::MB);
}

inline LeafCache::~LeafCache() { free(table); }


inline const LeafCacheEntry *LeafCache::get(const GlobalAddress &leaf_addr) {
  auto *set = table + set_of(leaf_addr) * kWays;
  for (int i = 0; i < kWays; ++i) {
    auto *e = set[i];   // single load; entries are immutable once published
    if (e && e->leaf_addr == leaf_addr) {
      __sync_fetch_and_add(&(e->freq), 1);
      return e;
    }
  }
  return nullptr;
}


inline void LeafCache::put(const GlobalAddress &leaf_addr, const LeafNode *leaf,
                           uint64_t stamp) {
  auto *set = table + set_of(leaf_addr) * kWays;

  // Refresh in place if this leaf is already resident: publish a NEW entry and
  // retire the old one, never mutate a live image out from under a reader.
  for (int i = 0; i < kWays; ++i) {
    auto *e = set[i];
    if (e && e->leaf_addr == leaf_addr) {
      if (e->stamp == stamp) return;   // already current
      auto *fresh = new LeafCacheEntry(leaf_addr, stamp, leaf);
      fresh->freq = e->freq;           // keep the hotness we learned
      if (__sync_bool_compare_and_swap(&set[i], e, fresh)) retire(e);
      else delete fresh;               // lost the race; the winner is as good
      return;
    }
  }

  auto *fresh = new LeafCacheEntry(leaf_addr, stamp, leaf);
  // Empty way first.
  for (int i = 0; i < kWays; ++i) {
    if (!set[i] && __sync_bool_compare_and_swap(&set[i], (LeafCacheEntry *)0, fresh))
      return;
  }
  // Otherwise evict the coldest way. Age the survivors so a leaf that was hot
  // long ago cannot hold a way forever (plain LFU never forgets).
  int victim = 0;
  int32_t min_freq = INT32_MAX;
  for (int i = 0; i < kWays; ++i) {
    auto *e = set[i];
    int32_t f = e ? e->freq : 0;
    if (f < min_freq) min_freq = f, victim = i;
  }
  auto *old = set[victim];
  if (__sync_bool_compare_and_swap(&set[victim], old, fresh)) {
    for (int i = 0; i < kWays; ++i) {
      auto *e = set[i];
      if (e && i != victim) e->freq = (e->freq >> 1) + 1;
    }
    if (old) retire(old);
  } else {
    delete fresh;
  }
}


inline void LeafCache::invalidate(const GlobalAddress &leaf_addr) {
  // Sweep the WHOLE set, not just the first match. Two threads that miss on the
  // same leaf can both fill it into different ways (each one's residency scan ran
  // before the other's publish), and a duplicate left behind here would survive
  // this node's own write -- harmless in `validated` mode, where the stamp still
  // catches it, but this is the one place that has to be unconditional.
  auto *set = table + set_of(leaf_addr) * kWays;
  for (int i = 0; i < kWays; ++i) {
    auto *e = set[i];
    if (e && e->leaf_addr == leaf_addr &&
        __sync_bool_compare_and_swap(&set[i], e, (LeafCacheEntry *)0)) {
      retire(e);
    }
  }
}


inline void LeafCache::retire(LeafCacheEntry *e) {
  // Same deferred-free epoch TreeCache/IdxCache use: a reader may still hold the
  // pointer it loaded a moment ago, so a retired image is freed only after enough
  // other retirements have gone by that no in-flight operation can still see it.
  gc.push(e);
  while (gc.unsafe_size() > safely_free_epoch) {
    LeafCacheEntry *next;
    if (gc.try_pop(next)) delete next;
    else break;
  }
}


inline void LeafCache::statistics(uint64_t hit, uint64_t miss, uint64_t stale) const {
  uint64_t resident = 0;
  for (uint64_t i = 0; i < nsets * kWays; ++i) if (table[i]) ++resident;
  uint64_t total = hit + miss;
  printf(" ----- [LeafCache]: capacity=%lu leaves resident=%lu (%.1f%% full,"
         " %.1f MB) -----\n",
         (unsigned long)capacity_entries(), (unsigned long)resident,
         capacity_entries() ? 100.0 * resident / capacity_entries() : 0.0,
         (double)resident * sizeof(LeafCacheEntry) / define::MB);
  // Machine-readable line: the sweep scripts grep this into the summary CSV.
  printf("[LEAFCACHE] hit=%lu miss=%lu stale=%lu hit_pct=%.3f resident=%lu"
         " capacity=%lu budget_mb=%d\n",
         (unsigned long)hit, (unsigned long)miss, (unsigned long)stale,
         total ? 100.0 * hit / total : 0.0, (unsigned long)resident,
         (unsigned long)capacity_entries(), cache_size_mb);
}

#endif  // _LEAF_CACHE_H_
