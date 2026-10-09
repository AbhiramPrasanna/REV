// Unit test for the leaf cache's key index and owner-mode protocol
// (CHIME_LEAF_BY_KEY / CHIME_LEAF_OWNER, include/LeafCache.h). No RDMA: it builds
// leaf images in memory and drives LeafCache directly.
//
//   CHIME_LEAF_BY_KEY=1 CHIME_LEAF_OWNER=1 ./leaf_key_index_test
//
// Checks: a key is found only in the leaf that holds it, with its value; a miss is
// a miss; an invalidated or overwritten leaf is never served; a fill that races a
// write is dropped; and, under 8 threads filling and reading at once, no lookup
// ever returns a wrong value.
#include "LeafCache.h"

#include <atomic>
#include <cassert>
#include <cstdio>
#include <random>
#include <thread>
#include <vector>

static int failures = 0;
#define CHECK(c) do { if (!(c)) { ++failures; printf("FAIL line %d: %s\n", __LINE__, #c); } } while (0)

static const uint64_t kKeysPerLeaf = 8;

// leaf i holds integer keys [i*8, i*8+8), values key*10+1
static void make_leaf(uint64_t i, LeafNode *leaf) {
  memset((void *)leaf, 0, sizeof(LeafNode));
  new (leaf) LeafNode;
  leaf->metadata.valid = 1;
  for (int j = 0; j < (int)define::leafSpanSize; ++j) leaf->records[j].key = define::kkeyNull;
  for (uint64_t j = 0; j < kKeysPerLeaf; ++j) {
    leaf->records[j].key = int2key(i * kKeysPerLeaf + j + 1);   // +1: key 0 is reserved
    leaf->records[j].value = (i * kKeysPerLeaf + j + 1) * 10 + 1;
  }
}
static GlobalAddress addr_of(uint64_t i) { return GlobalAddress(0, 4096 + i * 1024); }
static uint64_t lo_of(uint64_t i) { return i * kKeysPerLeaf + 1; }
static uint64_t hi_of(uint64_t i) { return (i + 1) * kKeysPerLeaf + 1; }

int main() {
  assert(leafcache::by_key() && leafcache::owner());
  LeafCache lc(16);
  LeafNode leaf;

  // 1. found only where it lives, with the right value
  for (uint64_t i = 0; i < 100; ++i) {
    make_leaf(i, &leaf);
    lc.put(addr_of(i), &leaf, 7);
    lc.index_put(addr_of(i), lo_of(i), hi_of(i));
  }
  for (uint64_t key = 1; key <= 800; ++key) {
    Value v = 0;
    const LeafCacheEntry *e = lc.find_by_key(int2key(key), v);
    CHECK(e != nullptr);
    if (e) { CHECK(v == key * 10 + 1); CHECK(e->leaf_addr == addr_of((key - 1) / kKeysPerLeaf)); }
  }
  // 2. a key no cached leaf holds is a miss
  { Value v = 0; CHECK(lc.find_by_key(int2key(5000), v) == nullptr); }

  // 3. invalidated -> miss (the index hint may remain; the image is gone)
  lc.invalidate(addr_of(3));
  { Value v = 0; CHECK(lc.find_by_key(int2key(3 * 8 + 2), v) == nullptr); }

  // 4. a write drops the image at begin and again at end
  lc.owner_write_begin(addr_of(4));
  { Value v = 0; CHECK(lc.find_by_key(int2key(4 * 8 + 2), v) == nullptr); }
  // a fill that starts while the write is in flight must not publish
  { uint64_t e0; CHECK(lc.owner_fill_begin(addr_of(4), e0) == false); }
  lc.owner_write_end(addr_of(4));
  { uint64_t e0; CHECK(lc.owner_fill_begin(addr_of(4), e0) == true); }

  // 5. a fill that a write overtakes (begin after the fill's epoch read) is dropped
  {
    uint64_t e0;
    CHECK(lc.owner_fill_begin(addr_of(5), e0));
    lc.owner_write_begin(addr_of(5));           // write starts during the "remote read"
    make_leaf(5, &leaf);
    lc.put(addr_of(5), &leaf, 9);               // the filler publishes its old image
    lc.owner_fill_end(addr_of(5), e0);          // ... and must drop it again
    Value v = 0;
    CHECK(lc.find_by_key(int2key(5 * 8 + 1), v) == nullptr);
    lc.owner_write_end(addr_of(5));
  }

  // 6. a stale hint (wider range, wrong address) never gives a wrong answer
  lc.index_put(addr_of(6), lo_of(6), hi_of(9));   // claims keys of leaves 7..9 too
  for (uint64_t key = lo_of(7); key < hi_of(9); ++key) {
    Value v = 0;
    const LeafCacheEntry *e = lc.find_by_key(int2key(key), v);
    if (e) CHECK(v == key * 10 + 1);
  }

  // 7. concurrency: 8 threads fill, overwrite with new values and read; a reader
  //    may miss, but a hit must return a value the leaf held at some point
  //    (key*10+1 or key*10+2), never another key's value
  {
    LeafCache big(64);
    std::atomic<bool> stop{false};
    std::atomic<uint64_t> hits{0}, bad{0};
    const uint64_t nleaves = 20000;
    std::vector<std::thread> th;
    for (int t = 0; t < 8; ++t)
      th.emplace_back([&, t] {
        std::mt19937_64 rng(t * 7919 + 1);
        LeafNode l;
        for (int it = 0; it < 400000; ++it) {
          uint64_t i = rng() % nleaves;
          if (t < 4 && (it & 3) == 0) {
            make_leaf(i, &l);
            if (it & 4) for (uint64_t j = 0; j < kKeysPerLeaf; ++j) l.records[j].value += 1;
            big.put(addr_of(i), &l, it);
            big.index_put(addr_of(i), lo_of(i), hi_of(i));
          } else {
            uint64_t key = i * kKeysPerLeaf + 1 + rng() % kKeysPerLeaf;
            Value v = 0;
            if (big.find_by_key(int2key(key), v)) {
              hits++;
              if (v != key * 10 + 1 && v != key * 10 + 2) bad++;
            }
          }
        }
      });
    for (auto &x : th) x.join();
    printf("concurrent: hits=%lu wrong=%lu\n", (unsigned long)hits.load(), (unsigned long)bad.load());
    CHECK(bad.load() == 0);
    CHECK(hits.load() > 0);
  }

  if (failures) printf("leaf_key_index_test: %d FAILED\n", failures);
  else printf("leaf_key_index_test: all passed\n");
  return failures ? 1 : 0;
}
