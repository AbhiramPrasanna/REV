#include "Directory.h"
#include "Common.h"

#include "Connection.h"
#include "cache/btree_rpc.h"

#include <gperftools/profiler.h>

GlobalAddress g_root_ptr = GlobalAddress::Null();
int g_root_level = -1;
bool enable_cache;

Directory::Directory(DirectoryConnection *dCon, RemoteConnection *remoteInfo,
                     uint32_t machineNR, uint16_t dirID, uint16_t nodeID,
                     int memThreadCount)
    : dCon(dCon), remoteInfo(remoteInfo), machineNR(machineNR), dirID(dirID),
      nodeID(nodeID), dirTh(nullptr) {

  { // chunck alloctor
    GlobalAddress dsm_start;
    uint64_t per_directory_dsm_size = dCon->dsmSize / memThreadCount;
    dsm_start.nodeID = nodeID;
    dsm_start.offset = per_directory_dsm_size * dirID;
    // std::cout << "Per directory DM size (MB) = "
    //           << per_directory_dsm_size / define::MB << std::endl;
    chunckAlloc = new GlobalAllocator(dsm_start, per_directory_dsm_size);
  }

  // Reserve one chunk up front for range-scan pushdown results. The local
  // pointer is resolved lazily (remoteInfo[].dsmBase is only valid after the
  // QPs are connected, which happens after construction).
  scanScratch = chunckAlloc->alloc_chunck();
  scanScratchBase = nullptr;

  dirTh = new std::thread(&Directory::dirThread, this);
}

Directory::~Directory() { delete chunckAlloc; }

void Directory::dirThread() {
  // bindCore((19 - dirID) * 2);
  bindCore(39 - dirID);
  Debug::notifyInfo("dir %d launch!\n", dirID);

  while (true) {
    struct ibv_wc wc;
    pollWithCQ(dCon->cq, 1, &wc);
    switch (int(wc.opcode)) {
    case IBV_WC_RECV: // control message
    {
      // printf("Dir receives a mesage\n");
      auto *m = (RawMessage *)dCon->message->getMessage();

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

  case RpcType::LOOKUP: {
    auto addr = m->addr;
    Value v_result;
    GlobalAddress g_result;
    auto ret = cachepush::lookup(addr, remoteInfo[addr.nodeID].dsmBase, m->k,
                                 v_result, g_result);
    send = (RawMessage *)dCon->message->getSendPool();
    send->level = ret;
    if (ret == 1) {
      send->addr.val = v_result;
    } else if (ret == 2) {
      send->addr = g_result;
    }

    break;
  }

  case RpcType::UPDATE: {
    auto addr = m->addr;
    auto ret =
        cachepush::update(addr, remoteInfo[addr.nodeID].dsmBase, m->k, m->v);
    send = (RawMessage *)dCon->message->getSendPool();
    send->level = ret;
    send->addr = addr;
    break;
  }

  case RpcType::INSERT: {
    auto addr = m->addr;
    auto ret =
        cachepush::insert(addr, remoteInfo[addr.nodeID].dsmBase, m->k, m->v);
    send = (RawMessage *)dCon->message->getSendPool();
    send->level = ret;
    send->addr = addr;
    break;
  }

  case RpcType::DELETE: {
    auto addr = m->addr;
    auto ret = cachepush::remove(addr, remoteInfo[addr.nodeID].dsmBase, m->k);
    send = (RawMessage *)dCon->message->getSendPool();
    send->level = ret;
    send->addr = addr;
    break;
  }

  case RpcType::SCAN: {
    // m->addr = entry leaf, m->k = start key, m->v = requested count.
    auto addr = m->addr;
    uint64_t dsm_base = remoteInfo[addr.nodeID].dsmBase;

    // Resolve the scratch local pointer on first use, and pick this requester's
    // private slot (indexed by app thread id).
    if (scanScratchBase == nullptr) {
      scanScratchBase = reinterpret_cast<char *>(dsm_base + scanScratch.offset);
    }
    int slot = m->app_id % MAX_APP_THREAD;
    auto *out = reinterpret_cast<std::pair<Key, Value> *>(
        scanScratchBase + static_cast<uint64_t>(slot) * kScanSlotBytes);

    int want = static_cast<int>(m->v);
    if (want > kScanSlotCap)
      want = kScanSlotCap;

    Key max_key = 0;
    int leaves = 0;
    int cnt = cachepush::range_scan(addr, dsm_base, m->k, want, out, max_key,
                                    leaves);

    send = (RawMessage *)dCon->message->getSendPool();
    send->level = cnt;     // count packed (or -1 stale)
    send->k = max_key;     // resume boundary
    send->v = leaves;      // leaves visited (for offload tracking)
    // Slot address the compute node reads the packed KV pairs back from.
    send->addr = GlobalAddress{addr.nodeID, scanScratch.offset +
                                                static_cast<uint64_t>(slot) *
                                                    kScanSlotBytes};
    break;
  }

  case RpcType::MALLOC: {
    // printf("DIR has received a MALLOC msg\n");
    send = (RawMessage *)dCon->message->getSendPool();
    send->addr = chunckAlloc->alloc_chunck();
    break;
  }

  case RpcType::NEW_ROOT: {

    if (g_root_level < m->level) {
      g_root_ptr = m->addr;
      g_root_level = m->level;
      if (g_root_level >= 3) {
        enable_cache = true;
      }
    }

    break;
  }

  default:
    assert(false);
  }

  if (send) {
    // printf("Send back the message to node %d, app %d\n", m->node_id,
    // m->app_id);
    dCon->sendMessage2App(send, m->node_id, m->app_id);
  }
}