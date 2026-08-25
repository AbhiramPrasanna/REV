#if !defined(_TREE_H_)
#define _TREE_H_

#include "TreeCache.h"
#include "IdxCache.h"
#include "LeafCache.h"
#include "DSM.h"
#include "Common.h"
#include "LocalLockTable.h"
#include "MetadataManager.h"
#include "LeafVersionManager.h"
#include "VersionManager.h"

#include <atomic>
#include <city.h>
#include <functional>
#include <map>
#include <algorithm>
#include <queue>
#include <set>
#include <iostream>


/* Workloads */
enum RequestType : int {
  INSERT = 0,
  UPDATE,
  SEARCH,
  SCAN
};

#ifdef ENABLE_OFFLOAD
// Fraction of point lookups (0..100) served via LOOKUP pushdown to the memory
// node instead of a one-sided leaf read. Set by the benchmark app; default 100.
extern int g_offload_rate;
extern int g_offload_min_level;  // cache-boundary level below which we DON'T offload
#endif

#ifdef CACHE_LEAF_NODE
// Compute-side LEAF-cache budget (MB), carved OUT of the same total the
// internal-node cache spends from: g_index_cache_mb + g_leaf_cache_mb always
// equals CHIME_CACHE_MB. The total is the axis the DART comparison holds equal,
// so the leaf cache has to earn its share against the inner nodes it displaces.
extern int g_leaf_cache_mb;
#endif

struct Request {
  RequestType req_type;
  Key k;
  Value v;
  int range_size;
};

class RequstGen {
public:
  RequstGen() = default;
  virtual Request next() { return Request{}; }
};


/* Tree */
using GenFunc = std::function<RequstGen *(DSM*, Request*, int, int, int)>;
#define MAX_FLAG_NUM 4
enum {
  FIRST_TRY,
  INVALID_LEAF,
  INVALID_NODE,
  FIND_NEXT
};


class RootEntry {
public:
  uint16_t level;
  PackedGAddr ptr;

  RootEntry(const uint16_t level, const GlobalAddress& ptr) : level(level), ptr(ptr) {}

  operator uint64_t() const { return ((uint64_t)ptr << 16) | level; }
  operator std::pair<uint16_t, GlobalAddress>() const { return std::make_pair(level, (GlobalAddress)ptr); }
} __attribute__((packed));

static_assert(sizeof(RootEntry) == 8);


class Tree {
public:
  Tree(DSM *dsm, uint16_t tree_id = 0, bool init_root = true);

  using WorkFunc = std::function<void (Tree *, const Request&, CoroPull *)>;
  void run_coroutine(GenFunc gen_func, WorkFunc work_func, int coro_cnt, Request* req = nullptr, int req_num = 0);

  void insert(const Key &k, Value v, CoroPull* sink = nullptr);   // NOTE: insert can also do update things if key exists
  void update(const Key &k, Value v, CoroPull* sink = nullptr);   // assert(false) if key is not found
  bool search(const Key &k, Value &v, CoroPull* sink = nullptr);  // return false if key is not found
  bool range_query(const Key &from, const Key &to, std::map<Key, Value> &ret);

#ifdef ENABLE_OFFLOAD
  // Range query served by SCAN pushdown to the memory node (see chime_rpc.h).
  // Returns the number of KV pairs collected into `ret`.
  int range_query_offload(const Key &from, const Key &to, std::map<Key, Value> &ret);
#endif

  void statistics();
  // Leaf-cache counters only. Separate from statistics() so it can be called at
  // the END of the measured phase without re-printing (and re-dating) the index
  // cache's post-bulk-load occupancy line, which the sweep scripts parse.
  void leaf_cache_statistics();
  void clear_debug_info();

private:
  // common
  void before_operation(CoroPull* sink);
  GlobalAddress get_root_ptr_ptr();
  RootEntry get_root_ptr(CoroPull* sink);

  // cache
  void record_cache_hit_ratio(bool from_cache, int level=1);
  void cache_node(InternalNode* node);

  // lock
  static uint64_t get_lock_info(bool is_leaf);
  void lock_node(const GlobalAddress &node_addr, uint64_t* lock_buffer, bool is_leaf, CoroPull* sink);
  void unlock_node(const GlobalAddress &node_addr, uint64_t* lock_buffer, bool is_leaf, CoroPull* sink, bool async = false);

  // leaf cache (see LeafCache.h for the coherence protocol)
#ifdef CACHE_LEAF_NODE
  // Publish a fresh, globally unique stamp for `leaf_addr`. Called right after a
  // leaf lock is acquired and before any data is written, so an RC queue pair
  // orders it lock -> stamp -> data -> unlock.
  void publish_leaf_stamp(const GlobalAddress& leaf_addr, CoroPull* sink);
  // One 16-byte [lock, stamp] probe. True iff the leaf is unlocked AND still
  // carries `stamp`, i.e. the cached image may be served.
  bool leaf_cache_validate(const GlobalAddress& leaf_addr, uint64_t stamp, CoroPull* sink);
  // Read + decode a WHOLE leaf with the seqlock closed around it (one doorbell
  // batch of three reads). On success `leaf_buffer` holds the decoded image; if
  // `stamp_out` comes back non-zero the seqlock closed and the image is cacheable.
  bool leaf_read_full(const GlobalAddress& leaf_addr, char *raw_leaf_buffer,
                      char *leaf_buffer, uint64_t& stamp_out, bool& cacheable,
                      CoroPull* sink);
  // Point-probe a decoded leaf image held in local memory (cached or freshly
  // read). Returns false iff the internal-node cache entry that produced
  // `node_addr` is stale and the caller must invalidate + retry -- the same
  // contract as leaf_node_search.
  bool leaf_probe_local(const LeafNode* leaf, const GlobalAddress& node_addr,
                        const GlobalAddress& sibling_addr, const Key &k, Value &v,
                        bool from_cache, CoroPull* sink);
  // Harvest [l_k, r_k) out of a decoded leaf image into a range-query result.
  static void leaf_harvest_range(const LeafNode* leaf, const Key& l_k, const Key& r_k,
                                 std::map<Key, Value>& ret);
#endif

  // search
  bool leaf_node_search(const GlobalAddress& node_addr, const GlobalAddress& sibling_addr, const Key &k, Value &v, bool from_cache, CoroPull* sink);
  bool internal_node_search(GlobalAddress& node_addr, GlobalAddress& sibling_addr, const Key &k, uint16_t& level, bool from_cache, CoroPull* sink);
#ifdef ENABLE_OFFLOAD
  // Traverse the cached internal nodes down to (but not into) the leaf covering
  // `k`, returning that leaf's address -- the entry point for a SCAN pushdown.
  GlobalAddress get_leaf_addr(const Key &k, CoroPull* sink);
#endif

  // insert
  bool leaf_node_insert(const GlobalAddress& node_addr, const GlobalAddress& sibling_addr, const Key &k, Value v, bool from_cache, CoroPull* sink);
  bool internal_node_insert(const GlobalAddress& node_addr, const Key &k, const GlobalAddress &v, bool from_cache, uint8_t level, CoroPull* sink);

  // update
  bool leaf_node_update(const GlobalAddress& node_addr, const GlobalAddress& sibling_addr, const Key &k, Value v, bool from_cache, CoroPull* sink);

  // hopscotch
#ifdef HOPSCOTCH_LEAF_NODE
  bool hopscotch_insert_and_unlock(LeafNode* leaf, const Key& k, Value v, const GlobalAddress& node_addr, uint64_t* lock_buffer, CoroPull* sink, int entry_num=define::leafSpanSize);
  void hopscotch_split_and_unlock(LeafNode* leaf, const Key& k, Value v, const GlobalAddress& node_addr, uint64_t* lock_buffer, CoroPull* sink);
  void hopscotch_search(const GlobalAddress& node_addr, int hash_idx, char *raw_leaf_buffer, char *leaf_buffer, CoroPull* sink, int entry_num=define::neighborSize, bool for_write=false);

  Key hopscotch_get_split_key(LeafEntry* records, const Key& k);
  int hopscotch_insert_locally(LeafEntry* records, const Key& k, Value v);
#endif

  // speculative read
#ifdef SPECULATIVE_READ
  bool speculative_read(const GlobalAddress& leaf_addr, std::pair<int, int> range, char *raw_leaf_buffer, char *leaf_buffer, const Key &k, Value &v, int& speculative_idx, CoroPull* sink, bool for_write=false);
#endif

  // lower-level function
  void leaf_entry_read(const GlobalAddress& leaf_addr, const int idx, char *raw_leaf_buffer, char *leaf_buffer, CoroPull* sink, bool for_write=false);
  template <class NODE, class ENTRY, class VAL>
  void entry_write_and_unlock(NODE* node, const int idx, const Key& k, VAL v, const GlobalAddress& node_addr, uint64_t* lock_buffer, CoroPull* sink, bool async=false);
  template <class NODE, class ENTRY, int TRANS_SIZE>
  void node_write_and_unlock(NODE* node, const GlobalAddress& node_addr, uint64_t* lock_buffer, CoroPull* sink, bool async=false);
  void segment_write_and_unlock(LeafNode* leaf, int l_idx, int r_idx, const std::vector<int>& hopped_idxes, const GlobalAddress& node_addr, uint64_t* lock_buffer, CoroPull* sink);

  template <class NODE, class ENTRY, class VAL, int SPAN_SIZE, int ALLOC_SIZE, int TRANS_SIZE>
  void node_split_and_unlock(NODE* node, const Key& k, VAL v, const GlobalAddress& node_addr, uint64_t* lock_buffer, uint8_t level, CoroPull* sink);
  void insert_internal(const Key &k, const GlobalAddress& ptr, const RootEntry& root_entry, uint8_t target_level, CoroPull* sink);

  void coro_worker(CoroPull &sink, RequstGen *gen, WorkFunc work_func);

private:
  DSM *dsm;
  TreeCache *tree_cache;
#ifdef SPECULATIVE_READ
  IdxCache *idx_cache;
#endif
#ifdef CACHE_LEAF_NODE
  LeafCache *leaf_cache;   // nullptr unless CHIME_CACHE_LEAF=1
#endif
  uint64_t tree_id;
  std::atomic<uint16_t> rough_height;
  GlobalAddress root_ptr_ptr;  // the address which stores root pointer;

public:
  LocalLockTable *local_lock_table;
  static thread_local std::vector<CoroPush> workers;
  static thread_local CoroQueue busy_waiting_queue;
};


#endif // _TREE_H_
