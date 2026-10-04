#pragma once
// ===========================================================================
// push_write.h -- optional write pushdown for CHIME (CHIME_PUSH_WRITES=1).
//
// Stock CHIME pushes nothing, and our offload path pushes reads only
// (chime_rpc.h). A pushed write cannot simply edit the leaf in local memory the
// way DEX's memory node does (dex/include/cache/btree_rpc.h): DEX can, because
// each of its subtrees belongs to one compute node, but any CHIME compute node
// may lock and write any leaf with one sided verbs at the same time.
//
// So a pushed write here is DELEGATION: the memory node that holds the target
// node runs CHIME's own, unchanged write protocol (lock with the vacancy bitmap,
// hopscotch insert, version encoding, leaf stamp, split, parent insert) on the
// compute node's behalf, through its own RDMA connections (loopback for its own
// memory, the network for any other node). Every interaction with other
// writers -- on any compute node or any memory node -- is therefore exactly the
// one CHIME already has, and the result is the same as if the compute node had
// done the write itself; only the round trips move from the network to the
// memory node's PCIe. What it saves is the compute node's round trips: lock,
// read, write, unlock (and any split) become one request.
//
// Who does what:
//   compute node  Tree::insert / Tree::update: resolve the deepest cached node
//                 as usual; if the switch is on, that node lives on another
//                 machine and the offload rule says push, send RPC_WRITE to the
//                 node's memory node and wait. A reply of 0 means "declined":
//                 the compute node then does the write itself, unchanged.
//   directory     Directory::process_message: never runs a write itself. It
//   thread        queues the request (pushw::queue) and goes back to polling.
//                 A write can wait on a lock held by a compute node that is
//                 itself waiting for this directory thread (a chunk allocation
//                 during a split); keeping directory threads non-blocking rules
//                 that deadlock out.
//   worker        Tree::push_write_worker: a registered DSM thread on the memory
//   threads       node. Runs Tree::insert_from / update_from from the node the
//                 compute node sent, then replies through the directory thread
//                 that received the request (Directory::send_write_reply, under
//                 that directory's send lock).
//
// Off by default: with CHIME_PUSH_WRITES unset nothing below runs, no worker
// starts, and the only change on the hot path is one cached flag test.
// Requirements: every node runs the same binary and the same CHIME_PUSH_WRITES
// value (a node with the switch off answers 0 and the sender falls back).
// Not covered: ENABLE_VAR_LEN_KV (values live in a separate data block).
//
// Knobs (memory node):
//   CHIME_PUSH_WRITES=1            turn it on (all nodes)
//   CHIME_PUSH_WRITE_WORKERS=<n>   worker threads per memory node
//                                  (default: the number of directory threads)
//   CHIME_PUSH_WRITE_CPUS=<list>   pin worker i to CPU list[i % len]; unset = no pinning
// ===========================================================================

#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <functional>
#include <mutex>

#include "GlobalAddress.h"

class Directory;

namespace pushw {

inline bool enabled() {
  static const bool v = [] {
    const char *e = getenv("CHIME_PUSH_WRITES");
    return e && atoi(e) != 0;
  }();
  return v;
}

enum : uint8_t { OP_INSERT = 1, OP_UPDATE = 2 };

// RPC_WRITE packs the operation next to the start level in RawMessage.level.
inline int pack_level(int level, uint8_t op) { return (level & 0xFFFF) | ((int)op << 16); }
inline void unpack_level(int packed, int &level, uint8_t &op) {
  level = packed & 0xFFFF;
  op = (uint8_t)((packed >> 16) & 0xFF);
}

struct Req {
  uint8_t op;
  int level;               // level of `addr` as the compute node's cache saw it
  GlobalAddress addr;      // deepest node the compute node's cache resolved
  GlobalAddress sibling;   // its expected sibling (Null if unknown)
  uint64_t k, v;
  uint16_t node_id, app_id;  // who to answer
  Directory *dir;            // which directory thread received it (answers it)
};

// Many directory threads push, many workers pop. Writes take microseconds, so a
// mutex around a deque is far below the cost of the work it hands over.
class Queue {
public:
  void push(const Req &r) {
    std::lock_guard<std::mutex> g(m_);
    q_.push_back(r);
  }
  bool pop(Req &r) {
    std::lock_guard<std::mutex> g(m_);
    if (q_.empty()) return false;
    r = q_.front();
    q_.pop_front();
    return true;
  }
private:
  std::mutex m_;
  std::deque<Req> q_;
};

inline Queue &queue() {
  static Queue q;
  return q;
}

// Workers start on the first pushed write, not at construction: by then every
// application thread on the node has registered with the DSM, so worker thread
// ids never collide with them. The Tree registers how to start them; the
// starter returns how many workers it started.
inline std::function<int()> &starter() {
  static std::function<int()> f;
  return f;
}
inline std::atomic<int> &running() {
  static std::atomic<int> n{0};
  return n;
}
// True once at least one worker runs. False (the request is then declined) if no
// Tree has registered a starter on this node or no worker could be started.
inline bool ensure_started() {
  static std::once_flag once;
  std::call_once(once, [] {
    if (starter()) running().store(starter()());
  });
  return running().load() > 0;
}

}  // namespace pushw
