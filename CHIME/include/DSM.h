#ifndef __DSM_H__
#define __DSM_H__

#include <atomic>

#include "RdmaCache.h"
#include "Config.h"
#include "Connection.h"
#include "DSMKeeper.h"
#include "GlobalAddress.h"
#include "LocalAllocator.h"
#include "RdmaBuffer.h"
#include "Common.h"


class DSMKeeper;
class Directory;

class DSM {

public:
  void registerThread();
  void loadKeySpace(const std::string& load_workloads_path, bool is_str);
  void set_key_space(const uint64_t *keys, uint64_t n);  // random-key pool for cache eviction
  Key getRandomKey();
  Key getNoComflictKey(uint64_t key_hash, uint64_t global_thread_id, uint64_t global_thread_num);
  static DSM *getInstance(const DSMConfig &conf);

  uint16_t getMyNodeID() { return myNodeID; }
  uint16_t getMyThreadID() { return thread_id; }
  uint16_t getClusterSize() { return conf.machineNR; }
  uint64_t getThreadTag() { return thread_tag; }
  uint64_t getMyGlobalThreadID() { return conf.threadNR * myNodeID + (thread_id-1); }

  // RDMA operations
  // buffer is registered memory
  void read(char *buffer, GlobalAddress gaddr, size_t size, bool signal = true,
            CoroPull* sink = nullptr);
  void read_sync(char *buffer, GlobalAddress gaddr, size_t size,
                 CoroPull* sink = nullptr);
  void read_sync_without_sink(char *buffer, GlobalAddress gaddr, size_t size,
                              CoroPull* sink, CoroQueue* waiting_queue);

  void write(const char *buffer, GlobalAddress gaddr, size_t size,
             bool signal = true, CoroPull* sink = nullptr);
  void write_without_sink(const char *buffer, GlobalAddress gaddr, size_t size,
                          bool signal, CoroPull* sink, CoroQueue* waiting_queue);
  void write_sync(const char *buffer, GlobalAddress gaddr, size_t size,
                  CoroPull* sink = nullptr);
  void write_sync_without_sink(const char *buffer, GlobalAddress gaddr, size_t size,
                               CoroPull* sink, CoroQueue* waiting_queue);

  void read_batch(RdmaOpRegion *rs, int k, bool signal = true,
                  CoroPull* sink = nullptr);
  void read_batch_sync(RdmaOpRegion *rs, int k, CoroPull* sink = nullptr);
  void read_batch_sync_without_sink(RdmaOpRegion *rs, int k, CoroPull* sink, CoroQueue* waiting_queue);
  void read_batches_sync(const std::vector<RdmaOpRegion>& rs, CoroPull* sink = nullptr);

  void write_batch(RdmaOpRegion *rs, int k, bool signal = true,
                   CoroPull* sink = nullptr);
  void write_batch_without_sink(RdmaOpRegion *rs, int k, bool signal,
                                CoroPull* sink, CoroQueue* waiting_queue);
  void write_batch_sync(RdmaOpRegion *rs, int k, CoroPull* sink = nullptr);
  void write_batch_sync_without_sink(RdmaOpRegion *rs, int k, CoroPull* sink, CoroQueue* waiting_queue);
  void write_batches_sync(const std::vector<RdmaOpRegion>& rs, CoroPull* sink = nullptr);

  void write_faa(RdmaOpRegion &write_ror, RdmaOpRegion &faa_ror,
                 uint64_t add_val, bool signal = true,
                 CoroPull* sink = nullptr);
  void write_faa_sync(RdmaOpRegion &write_ror, RdmaOpRegion &faa_ror,
                      uint64_t add_val, CoroPull* sink = nullptr);

  void write_cas(RdmaOpRegion &write_ror, RdmaOpRegion &cas_ror,
                 uint64_t equal, uint64_t val, bool signal = true,
                 CoroPull* sink = nullptr);
  void write_cas_sync(RdmaOpRegion &write_ror, RdmaOpRegion &cas_ror,
                      uint64_t equal, uint64_t val, CoroPull* sink = nullptr);

  void cas(GlobalAddress gaddr, uint64_t equal, uint64_t val,
           uint64_t *rdma_buffer, bool signal = true,
           CoroPull* sink = nullptr);
  bool cas_sync(GlobalAddress gaddr, uint64_t equal, uint64_t val,
                uint64_t *rdma_buffer, CoroPull* sink = nullptr);

  void cas_read(RdmaOpRegion &cas_ror, RdmaOpRegion &read_ror, uint64_t equal,
                uint64_t val, bool signal = true, CoroPull* sink = nullptr);
  bool cas_read_sync(RdmaOpRegion &cas_ror, RdmaOpRegion &read_ror,
                     uint64_t equal, uint64_t val, CoroPull* sink = nullptr);

  void read_cas(RdmaOpRegion &read_ror, RdmaOpRegion &cas_ror, uint64_t equal,
                uint64_t val, bool signal = true, CoroPull* sink = nullptr);
  bool read_cas_sync(RdmaOpRegion &read_ror, RdmaOpRegion &cas_ror,
                     uint64_t equal, uint64_t val, CoroPull* sink = nullptr);

  void cas_write(RdmaOpRegion &cas_ror, RdmaOpRegion &write_ror, uint64_t equal,
                 uint64_t val, bool signal = true, CoroPull* sink = nullptr);
  bool cas_write_sync(RdmaOpRegion &cas_ror, RdmaOpRegion &write_ror,
                      uint64_t equal, uint64_t val, CoroPull* sink = nullptr);

  void cas_mask(GlobalAddress gaddr, uint64_t equal, uint64_t val,
                uint64_t *rdma_buffer, uint64_t compare_mask = ~(0ull), uint64_t swap_mask = ~(0ull),
                bool signal = true, CoroPull* sink = nullptr);
  bool cas_mask_sync(GlobalAddress gaddr, uint64_t equal, uint64_t val,
                     uint64_t *rdma_buffer, uint64_t compare_mask = ~(0ull), uint64_t swap_mask = ~(0ull),  // !!NOTE: the swap_mask must contains compare_mask
                     CoroPull* sink = nullptr);
  bool cas_mask_sync_without_sink(GlobalAddress gaddr, uint64_t equal, uint64_t val,
                                  uint64_t *rdma_buffer, uint64_t compare_mask, uint64_t swap_mask,  // !!NOTE: the swap_mask must contains compare_mask
                                  CoroPull* sink, CoroQueue* waiting_queue);

  void faa_boundary(GlobalAddress gaddr, uint64_t add_val,
                    uint64_t *rdma_buffer, uint64_t mask = 63,
                    bool signal = true, CoroPull* sink = nullptr);
  void faa_boundary_sync(GlobalAddress gaddr, uint64_t add_val,
                         uint64_t *rdma_buffer, uint64_t mask = 63,
                         CoroPull* sink = nullptr);

  // for on-chip device memory
  void read_dm(char *buffer, GlobalAddress gaddr, size_t size,
               bool signal = true, CoroPull* sink = nullptr);
  void read_dm_sync(char *buffer, GlobalAddress gaddr, size_t size,
                    CoroPull* sink = nullptr);

  void write_dm(const char *buffer, GlobalAddress gaddr, size_t size,
                bool signal = true, CoroPull* sink = nullptr);
  void write_dm_sync(const char *buffer, GlobalAddress gaddr, size_t size,
                     CoroPull* sink = nullptr);

  void cas_dm(GlobalAddress gaddr, uint64_t equal, uint64_t val,
              uint64_t *rdma_buffer, bool signal = true,
              CoroPull* sink = nullptr);
  bool cas_dm_sync(GlobalAddress gaddr, uint64_t equal, uint64_t val,
                   uint64_t *rdma_buffer, CoroPull* sink = nullptr);

  void cas_dm_mask(GlobalAddress gaddr, uint64_t equal, uint64_t val,
                   uint64_t *rdma_buffer, uint64_t compare_mask = ~(0ull), uint64_t swap_mask = ~(0ull),
                   bool signal = true, CoroPull* sink = nullptr);
  bool cas_dm_mask_sync(GlobalAddress gaddr, uint64_t equal, uint64_t val,
                        uint64_t *rdma_buffer, uint64_t compare_mask = ~(0ull), uint64_t swap_mask = ~(0ull),
                        CoroPull* sink = nullptr);

  void faa_dm_boundary(GlobalAddress gaddr, uint64_t add_val,
                       uint64_t *rdma_buffer, uint64_t mask = 63,
                       bool signal = true, CoroPull* sink = nullptr);
  void faa_dm_boundary_sync(GlobalAddress gaddr, uint64_t add_val,
                            uint64_t *rdma_buffer, uint64_t mask = 63,
                            CoroPull* sink = nullptr);

  uint64_t poll_rdma_cq(int count = 1);
  bool poll_rdma_cq_once(uint64_t &wr_id);
  int poll_rdma_cq_batch_once(uint64_t *wr_ids, int count);

  uint64_t sum(uint64_t value) {
    static uint64_t count = 0;
    return keeper->sum(std::string("sum-") + std::to_string(count++), value);
  }

  // Memcached operations for sync
  size_t Put(uint64_t key, const void *value, size_t count) {

    std::string k = std::string("gam-") + std::to_string(key);
    keeper->memSet(k.c_str(), k.size(), (char *)value, count);
    return count;
  }

  size_t Get(uint64_t key, void *value) {

    std::string k = std::string("gam-") + std::to_string(key);
    size_t size;
    char *ret = keeper->memGet(k.c_str(), k.size(), &size);
    memcpy(value, ret, size);

    return size;
  }

private:
  DSM(const DSMConfig &conf);
  ~DSM();

  void initRDMAConnection();
  void fill_keys_dest(RdmaOpRegion &ror, GlobalAddress addr, bool is_chip);

  DSMConfig conf;
  std::atomic_int appID;
  Cache cache;

  static thread_local int thread_id;
  static thread_local uint64_t thread_tag;
  static thread_local ThreadConnection *iCon;
  static thread_local char *rdma_buffer;
  static thread_local LocalAllocator local_allocators[MEMORY_NODE_NUM][NR_DIRECTORY];
  static thread_local RdmaBuffer rbuf[MAX_CORO_NUM];

  uint64_t baseAddr;
  uint32_t myNodeID;
  uint64_t keySpaceSize;

  RemoteConnection *remoteInfo;
  ThreadConnection *thCon[MAX_APP_THREAD];
  DirectoryConnection *dirCon[NR_DIRECTORY];
  DSMKeeper *keeper;

  Directory *dirAgent[NR_DIRECTORY];
  Key keyBuffer[MAX_KEY_SPACE_SIZE];

public:
  bool is_register() { return thread_id != -1; }
  void barrier(const std::string &ss) { keeper->barrier(ss); }

  char *get_rdma_buffer() { return rdma_buffer; }
  RdmaBuffer &get_rbuf(CoroPull* sink) { return rbuf[sink ? sink->get() : 0]; }

  GlobalAddress alloc(size_t size, uint8_t align_bit = CACHELINE_ALIGN_BIT);
  void free(const GlobalAddress& addr, int size);

  void rpc_call_dir(const RawMessage &m, uint16_t node_id,
                    uint16_t dir_id = 0) {

    auto buffer = (RawMessage *)iCon->message->getSendPool();

    memcpy(buffer, &m, sizeof(RawMessage));
    buffer->node_id = myNodeID;
    buffer->app_id = thread_id;

    iCon->sendMessage2Dir(buffer, node_id, dir_id);
  }

  RawMessage *rpc_wait() {
    ibv_wc wc;

    pollWithCQ(iCon->rpc_cq, 1, &wc);
    return (RawMessage *)iCon->message->getMessage();
  }

#ifdef ENABLE_OFFLOAD
  // --- RPC offloading (compute-side stubs; handlers in Directory.cpp) ---
  // Point-lookup pushdown from the CN's CACHE BOUNDARY: `node_addr`/`level` are
  // the deepest node the CN's cache resolved (leaf if fully cached, else an
  // internal node). The MN traverses the rest -- internals + leaf -- locally and
  // returns the value, so cache misses are served by the MN (DEX-style).
  // Returns 1 (found, `result` set) or 2 (not found).
  int rpc_lookup(const GlobalAddress &node_addr, int level, const Key &k, Value &result) {
    RawMessage m;
    m.type = RpcType::RPC_LOOKUP;
    m.addr = node_addr;
    m.level = level;                 // request: starting level (reply reuses it as status)
    memcpy(&m.k, k.data(), define::keyLen);
    // Shard over the ACTIVE dirs only -- a dir >= num_dir() has no thread polling
    // its CQ, so an RPC sent there never completes and rpc_wait() blocks forever.
    rpc_call_dir(m, node_addr.nodeID, thread_id % chime::num_dir());
    auto *mm = rpc_wait();
    if (mm->level == 1) result = mm->v;
    return mm->level;
  }

  // Range-scan pushdown over [from, to). The MN walks sibling leaves and packs
  // up to `num` pairs into its scratch slot; on return `result_addr` is that
  // slot (RDMA-read `cnt` pairs from it), `max_key` is the resume boundary, and
  // `leaves` is how many leaves the MN scanned (for offload accounting).
  // `start_level` (default 1): level of `leaf_addr` as the CN's cache reported
  // it. 1 = it is the entry leaf. >= 2 = it is an internal node; the MN walks
  // down to the leaf itself (the scan counterpart of rpc_lookup's descent).
  int rpc_scan(const GlobalAddress &leaf_addr, const Key &from, const Key &to,
               int num, GlobalAddress &result_addr, Key &max_key, int &leaves,
               int start_level = 1) {
    RawMessage m;
    m.type = RpcType::RPC_SCAN;
    m.addr = leaf_addr;
    memcpy(&m.k, from.data(), define::keyLen);
    memcpy(&m.v, to.data(), define::keyLen);
    // Same packing as chime_offload::pack_scan_level (chime_rpc.h): count in
    // bits 0-15, start level in bits 16-31. Kept inline to avoid an include cycle.
    m.level = (num & 0xFFFF) | ((start_level & 0xFFFF) << 16);
    rpc_call_dir(m, leaf_addr.nodeID, thread_id % chime::num_dir());
    auto *mm = rpc_wait();
    result_addr = mm->addr;
    memcpy(max_key.data(), &mm->k, define::keyLen);
    leaves = (int)mm->v;
    return mm->level;
  }

  // Write pushdown (CHIME_PUSH_WRITES=1, see push_write.h): ask the memory node
  // that holds `node_addr` to run this insert or update itself, starting from
  // `node_addr` (`level` as the cache saw it; `sibling` its expected sibling, or
  // Null). Returns 1 once the write is done, 0 if the memory node declined (the
  // caller then does the write itself).
  int rpc_write(uint8_t op, const GlobalAddress &node_addr, const GlobalAddress &sibling,
                int level, const Key &k, uint64_t v) {
    RawMessage m;
    m.type = RpcType::RPC_WRITE;
    m.addr = node_addr;
    m.level = (level & 0xFFFF) | ((int)op << 16);   // same packing as pushw::pack_level
    memcpy(&m.k, k.data(), define::keyLen);
    m.v = v;
    m.aux = sibling.to_uint64();
    rpc_call_dir(m, node_addr.nodeID, thread_id % chime::num_dir());
    auto *mm = rpc_wait();
    return mm->level;
  }
#endif // ENABLE_OFFLOAD

  // How many thread slots (thCon[]) registerThread has handed out on this node.
  int thread_slots_used() const { return appID.load(); }

  // ---- write pushdown mode 2 (CHIME_PUSH_WRITES=2, see push_write.h) --------
  // In mode 2 the memory node is the only writer, so its write workers may run
  // atomics on their OWN node as CPU atomics, copy a node they hold locked
  // straight out of local memory, and must wait for every write they post (so
  // no CPU step overtakes a write still in flight). Data writes stay RDMA
  // writes: compute nodes keep reading with one sided reads, and a NIC write
  // keeps each cache line whole for them. Off for every other thread.
  void set_owner_thread(bool on) { owner_thread = on; locked_len = 0; }
  bool is_owner_thread() const { return owner_thread; }
  // The node this thread has just locked: [node, node + len), lock word at `lock`.
  void note_locked(const GlobalAddress &node, uint32_t len, const GlobalAddress &lock) {
    locked_node = node; locked_lock = lock; locked_len = len;
  }
  void clear_locked() { locked_len = 0; }

private:
  static thread_local bool owner_thread;
  static thread_local GlobalAddress locked_node, locked_lock;
  static thread_local uint32_t locked_len;
  bool owner_local(const GlobalAddress &g) const { return owner_thread && g.nodeID == myNodeID; }
  bool in_locked(const GlobalAddress &g, size_t size) const {
    return locked_len && g.nodeID == locked_node.nodeID && g.offset >= locked_node.offset &&
           g.offset + size <= locked_node.offset + locked_len;
  }
  // A write that covers the lock word releases the lock: stop treating the node
  // as held (clearing early only costs the local copy, never correctness).
  void release_check(const GlobalAddress &g, size_t size) {
    if (locked_len && g.nodeID == locked_lock.nodeID && g.offset <= locked_lock.offset &&
        locked_lock.offset < g.offset + size)
      locked_len = 0;
  }
  char *local_ptr(const GlobalAddress &g) const { return (char *)baseAddr + g.offset; }
};

inline GlobalAddress DSM::alloc(size_t size, uint8_t align_bit) {
  thread_local int cur_target_node = (this->getMyThreadID() + this->getMyNodeID()) % MEMORY_NODE_NUM;
  // Cycle over ACTIVE dirs only: a chunk-alloc RPC to a dir with no thread would
  // block forever, and dirs >= num_dir() own no slice of the DSM region anyway.
  thread_local int cur_target_dir_id = (this->getMyThreadID() + this->getMyNodeID()) % chime::num_dir();
  if (++cur_target_dir_id == chime::num_dir()) {
    cur_target_node = (cur_target_node + 1) % MEMORY_NODE_NUM;
    cur_target_dir_id = 0;
  }

  auto& local_allocator = local_allocators[cur_target_node][cur_target_dir_id];

  // alloc from the target node
  bool need_chunk = true;
  GlobalAddress addr = local_allocator.malloc(size, need_chunk, align_bit);
  if (need_chunk)  {
    RawMessage m;
    m.type = RpcType::MALLOC;

    this->rpc_call_dir(m, cur_target_node, cur_target_dir_id);
    local_allocator.set_chunck(rpc_wait()->addr);

    // retry
    addr = local_allocator.malloc(size, need_chunk, align_bit);
  }
  return addr;
}

inline void DSM::free(const GlobalAddress& addr, int size) {
  local_allocators[addr.nodeID][0].free(addr, size);
}

#endif /* __DSM_H__ */
