#include "Directory.h"
#include "Common.h"

#include "Connection.h"

#include <unistd.h>   // sysconf(_SC_NPROCESSORS_ONLN) for dir-thread core pinning

#ifdef ENABLE_OFFLOAD
#include "chime_rpc.h"   // memory-node lookup/scan pushdown handlers
#include "remote_load.h" // memory-node "remote CPU load" (dir-thread active %)
#endif

// #include <gperftools/profiler.h>

GlobalAddress g_root_ptr = GlobalAddress::Null();
int g_root_level = -1;
bool enable_cache;

Directory::Directory(DirectoryConnection *dCon, RemoteConnection *remoteInfo,
                     uint32_t machineNR, uint16_t dirID, uint16_t nodeID)
    : dCon(dCon), remoteInfo(remoteInfo), machineNR(machineNR), dirID(dirID),
      nodeID(nodeID), dirTh(nullptr) {

  { // chunck alloctor
    // Slice by the ACTIVE dir count, not NR_DIRECTORY: the running dirs must
    // between them cover the whole DSM region. Slicing by the max (8) while only
    // running 4 dirs would strand half the region and give each dir an
    // unnecessarily small pool to run out of.
    GlobalAddress dsm_start;
    uint64_t per_directory_dsm_size = dCon->dsmSize / chime::num_dir();
    dsm_start.nodeID = nodeID;
    dsm_start.offset = per_directory_dsm_size * dirID;
    chunckAlloc = new GlobalAllocator(dsm_start, per_directory_dsm_size);
  }

#ifdef ENABLE_OFFLOAD
  // Reserve one chunk up front for range-scan pushdown results.
  scanScratch = chunckAlloc->alloc_chunck();
  scanScratchBase = (char *)dCon->dsmPool + scanScratch.offset;
#endif

  dirTh = new std::thread(&Directory::dirThread, this);
}

Directory::~Directory() { delete chunckAlloc; }

void Directory::dirThread() {

  // Pin to the TOP of the machine's real core range, counting down, away from the
  // app threads at the bottom.
  //
  // This used to be (CPU_PHYSICAL_CORE_NUM - 1 - dirID) * 2 + 1, which on a box
  // whose real core count differs from the macro (72 in Common.h) produces core
  // ids past the end; bindCore then wraps them modulo nproc and lands them ON TOP
  // of app threads. On an 80-logical machine that is 143/141/139/137 -> 63/61/59/57
  // -- exactly where app threads 31/30/29/28 sit (bindCore(id*2+1)). Those app
  // threads then share a core with a thread that BUSY-POLLS a CQ, so they crawl;
  // and because the measured phase is op-bounded, the whole node cannot finish
  // until they do. The symptom is a memory node stuck at ~1/10th the compute
  // node's throughput for a long tail, which drifts the two nodes out of lockstep
  // and eventually breaks the inter-cell handshake ("transport retry counter
  // exceeded"). It stayed hidden while THREADS was small enough (<=28) that the
  // app range never reached the wrapped dir cores.
  //
  // Deriving from _SC_NPROCESSORS_ONLN instead makes it correct on any machine
  // without a per-box macro edit. App threads occupy odd cores 1..2T-1 (main
  // thread at 2T+1); dir threads take nproc-1, nproc-3, ... so they only ever
  // collide if the app range genuinely runs out of cores -- which is warned below.
  long ncpu = sysconf(_SC_NPROCESSORS_ONLN);
  if (ncpu <= 0) ncpu = CPU_PHYSICAL_CORE_NUM * 2;
  int dir_core = (int)(ncpu - 1 - 2 * (long)dirID);
  if (dir_core < 0) dir_core = (int)(ncpu - 1);
  bindCore((uint16_t)dir_core);
  Debug::notifyInfo("dir %d launch! (core %d of %ld)\n", dirID, dir_core, ncpu);

#ifdef ENABLE_OFFLOAD
  // The memory node has no explicit run boundary, so a periodic report is how
  // its steady-state remote CPU load is observed.
  // dir 0 only: this runs in EVERY dir thread, so without the guard N dir threads
  // each spawn their own reporter and N copies of the aggregate interleave.
  // Report over the ACTIVE dir count so "active %" is a fraction of the dirs that
  // really exist -- that ratio is what says whether the MN is the bottleneck.
  if (dirID == 0) remoteload::start_reporter(chime::num_dir());
#endif

  while (true) {
    struct ibv_wc wc;
    pollWithCQ(dCon->cq, 1, &wc);

    switch (int(wc.opcode)) {
    case IBV_WC_RECV: // control message
    {

      auto *m = (RawMessage *)dCon->message->getMessage();

#ifdef ENABLE_OFFLOAD
      // Attribute the time spent serving this RPC to this dir-thread: this is
      // the "remote compute load" (vs spinning in pollWithCQ above).
      remoteload::ScopedActive _active(dirID);
#endif
      process_message(m);

      break;
    }
    case IBV_WC_RDMA_WRITE: {
      break;
    }
    case IBV_WC_RECV_RDMA_WITH_IMM: {

      break;
    }
    default:
      assert(false);
    }
  }
}

void Directory::process_message(const RawMessage *m) {

  RawMessage *send = nullptr;
  switch (m->type) {

#ifdef ENABLE_OFFLOAD
  case RpcType::RPC_LOOKUP: {
    // m->addr / m->level = the CN's cache-boundary node + its level; m->k = key.
    // Traverse the remaining internals + leaf locally and reply with the value.
    Key k;
    memcpy(k.data(), &m->k, define::keyLen);
    Value v_result = define::kValueNull;
    int ret = chime_offload::lookup_from((char *)dCon->dsmPool, m->addr, m->level, k, v_result);
    send = (RawMessage *)dCon->message->getSendPool();
    send->level = ret;                 // 1 = found, 2 = not found
    if (ret == 1) send->v = v_result;  // inline value back to the CN
    break;
  }

  case RpcType::RPC_SCAN: {
    // m->addr = entry leaf, m->k = `from`, m->v = `to`, m->level = requested count.
    Key from, to;
    memcpy(from.data(), &m->k, define::keyLen);
    memcpy(to.data(), &m->v, define::keyLen);

    int slot = m->app_id % MAX_APP_THREAD;
    auto *out = reinterpret_cast<std::pair<Key, Value> *>(
        scanScratchBase + (uint64_t)slot * chime_offload::kScanSlotBytes);

    int want = m->level;
    if (want > chime_offload::kScanSlotCap) want = chime_offload::kScanSlotCap;

    Key max_key{};
    int leaves = 0;
    int cnt = chime_offload::range_scan((char *)dCon->dsmPool, m->addr, from, to,
                                        want, out, max_key, leaves);

    send = (RawMessage *)dCon->message->getSendPool();
    send->level = cnt;                    // pairs packed
    send->v = (uint64_t)leaves;           // leaves scanned remotely (for offload tracking)
    memcpy(&send->k, max_key.data(), define::keyLen); // resume boundary
    // Slot address the compute node RDMA-reads the packed pairs back from.
    send->addr = GlobalAddress{nodeID, scanScratch.offset +
                                           (uint64_t)slot *
                                               chime_offload::kScanSlotBytes};
    break;
  }
#endif // ENABLE_OFFLOAD

  case RpcType::MALLOC: {

    send = (RawMessage *)dCon->message->getSendPool();

    send->addr = chunckAlloc->alloc_chunck();
    break;
  }

  case RpcType::NEW_ROOT: {

    if (g_root_level < m->level) {
      g_root_ptr = m->addr;
      g_root_level = m->level;
      // if (g_root_level >= 3) {
      //   enable_cache = true;
      // }
    }

    break;
  }

  default:
    assert(false);
  }

  if (send) {
    dCon->sendMessage2App(send, m->node_id, m->app_id);
  }
}
