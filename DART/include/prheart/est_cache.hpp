#pragma once
// ===========================================================================
// est_cache: a compute-side cache of Express Skip Table (EST) entries, the
// "metadata of hot express nodes" that DART's paper caches when the cache space
// is larger than the EST's hash directory (DART, SIGMOD'26, Section 5.1). The
// released code caches only the directory (race.cc, sync_dir).
//
// OFF BY DEFAULT. With DART_EST_CACHE_MB unset or 0 nothing here runs and DART
// behaves exactly as released. With DART_EST_CACHE_MB=<MB>:
//   - get_root() looks the key's prefix up here before searching the EST over
//     RDMA; a hit returns the express node's 8-byte metadata (type, pos, fptr)
//     with no network access, a miss searches the EST as before and stores the
//     8-byte result.
//   - The table holds <MB> MiB of entries (16 B each: prefix tag + metadata),
//     shared by every thread of the compute process, 4-way set associative; a
//     new entry replaces one of its set (hot prefixes come back on their next miss).
//   - It starts empty when the measured phase begins (begin_run), after the
//     load and the skip-table build, and only for runs without inserts or
//     removes: those can move or retype an express node, and nothing here would
//     notice. Updates rewrite leaves, not express nodes.
//   - Every EST search that does cross the network is counted in rtt (1 round
//     trip) and access_size (128 B), the way DART's DYNAMIC path counts it, and
//     report() prints [ESTCACHE] ... counted_in_rtt=1 so the collector does not
//     add the uncounted search a second time.
// ===========================================================================
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <vector>

namespace est_cache {

struct Slot {
    std::atomic<uint64_t> tag{0};    // 0 = empty
    std::atomic<uint64_t> meta{0};
};
constexpr uint64_t kWays = 4;

struct Counters { uint64_t hits = 0, misses = 0, stores = 0; char pad[40]; };

struct State {
    std::atomic<bool> active{false};
    Slot* slots = nullptr;
    uint64_t sets = 0;
    uint64_t mb = 0;
    std::mutex mu;
    std::vector<Counters*> counters;
};
inline State& state() { static State s; return s; }

inline uint64_t configured_mb() {
    const char* e = std::getenv("DART_EST_CACHE_MB");
    return e ? std::strtoull(e, nullptr, 10) : 0;
}

inline Counters& my_counters() {
    thread_local Counters* c = nullptr;
    if (!c) {
        c = new Counters();                       // kept for report(), never freed
        std::lock_guard<std::mutex> g(state().mu);
        state().counters.push_back(c);
    }
    return *c;
}

inline bool enabled() { return state().active.load(std::memory_order_acquire); }

// After a warmup: this thread's hit/miss counts start again from zero.
inline void reset_my_counters() {
    Counters& c = my_counters();
    c.hits = c.misses = c.stores = 0;
}

// A prefix of 1..7 bytes packed with its length; 0 means "cannot cache".
inline uint64_t tag_of(const uint8_t* data, size_t len) {
    if (len == 0 || len > 7) return 0;
    uint64_t t = 0;
    std::memcpy(&t, data, len);
    return t | (uint64_t(len) << 56);
}

inline uint64_t mix(uint64_t x) {           // splitmix64 finaliser
    x += 0x9e3779b97f4a7c15ULL;
    x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
    x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
    return x ^ (x >> 31);
}

inline bool lookup(uint64_t tag, uint64_t& meta) {
    State& s = state();
    uint64_t h = mix(tag);
    Slot* set = s.slots + (h % s.sets) * kWays;
    for (uint64_t w = 0; w < kWays; ++w) {
        uint64_t t1 = set[w].tag.load(std::memory_order_acquire);
        if (t1 != tag) continue;
        uint64_t m = set[w].meta.load(std::memory_order_acquire);
        if (set[w].tag.load(std::memory_order_acquire) != tag) continue;   // replaced meanwhile
        meta = m;
        ++my_counters().hits;
        return true;
    }
    ++my_counters().misses;
    return false;
}

inline void store(uint64_t tag, uint64_t meta) {
    State& s = state();
    uint64_t h = mix(tag);
    Slot* set = s.slots + (h % s.sets) * kWays;
    uint64_t victim = (h >> 40) % kWays;
    for (uint64_t w = 0; w < kWays; ++w) {
        uint64_t t = set[w].tag.load(std::memory_order_relaxed);
        if (t == tag) return;                       // already cached (metadata does not change)
        if (t == 0) { victim = w; break; }
    }
    Slot& v = set[victim];
    v.tag.store(0, std::memory_order_release);      // readers of the old entry now miss
    v.meta.store(meta, std::memory_order_release);
    v.tag.store(tag, std::memory_order_release);
    ++my_counters().stores;
}

// Called once, before the measured-phase threads start.
inline void begin_run(bool microbench, uint64_t insert_pct, uint64_t remove_pct) {
    State& s = state();
    uint64_t mb = configured_mb();
    s.mb = mb;
    if (mb == 0) return;
    if (!microbench || insert_pct || remove_pct) {
        std::printf("[ESTCACHE] off: DART_EST_CACHE_MB=%lu needs a microbench run without inserts "
                    "or removes (insert%%=%lu remove%%=%lu)\n", (unsigned long)mb,
                    (unsigned long)insert_pct, (unsigned long)remove_pct);
        s.mb = 0;
        return;
    }
    uint64_t entries = mb * 1024ULL * 1024ULL / sizeof(Slot);
    s.sets = entries / kWays;
    if (s.sets == 0) { s.mb = 0; return; }
    s.slots = new Slot[s.sets * kWays];             // zero tags: empty
    s.active.store(true, std::memory_order_release);
    std::printf("[ESTCACHE] on: %lu MiB, %lu entries (%lu sets x %lu ways), empty at run start\n",
                (unsigned long)mb, (unsigned long)(s.sets * kWays), (unsigned long)s.sets,
                (unsigned long)kWays);
    std::fflush(stdout);
}

inline void report() {
    State& s = state();
    if (s.mb == 0) return;
    uint64_t hits = 0, misses = 0, stores = 0;
    {
        std::lock_guard<std::mutex> g(s.mu);
        for (auto* c : s.counters) { hits += c->hits; misses += c->misses; stores += c->stores; }
    }
    uint64_t n = hits + misses;
    std::printf("[ESTCACHE] mb=%lu entries=%lu lookups=%lu hits=%lu hit_pct=%.2f stores=%lu counted_in_rtt=1\n",
                (unsigned long)s.mb, (unsigned long)(s.sets * kWays), (unsigned long)n,
                (unsigned long)hits, n ? 100.0 * hits / n : 0.0, (unsigned long)stores);
    std::fflush(stdout);
}

}  // namespace est_cache
