#include "Directory.h"
#include "Common.h"

#include "Connection.h"

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
    GlobalAddress dsm_start;
    uint64_t per_directory_dsm_size = dCon->dsmSize / NR_DIRECTORY;
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

  bindCore((CPU_PHYSICAL_CORE_NUM - 1 - dirID) * 2 + 1);  // bind to the last CPU core
  Debug::notifyInfo("dir %d launch!\n", dirID);

#ifdef ENABLE_OFFLOAD
  // The memory node has no explicit run boundary, so a periodic report is how
  // its steady-state remote CPU load is observed.
  remoteload::start_reporter(NR_DIRECTORY);
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
