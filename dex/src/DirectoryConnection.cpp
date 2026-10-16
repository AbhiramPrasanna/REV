#include "DirectoryConnection.h"

#include "Connection.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>

DirectoryConnection::DirectoryConnection(uint16_t dirID, void *dsmPool,
                                         uint64_t dsmSize, uint32_t machineNR,
                                         RemoteConnection *remoteInfo)
    : dirID(dirID), remoteInfo(remoteInfo) {

  createContext(&ctx);
  cq = ibv_create_cq(ctx.ctx, RAW_RECV_CQ_COUNT, NULL, NULL, 0);
  message = new RawMessageConnection(ctx, cq, DIR_MESSAGE_NR);

  message->initRecv();
  message->initSend();

  // dsm memory
  this->dsmPool = dsmPool;
  this->dsmSize = dsmSize;
  this->dsmMR = createMemoryRegion((uint64_t)dsmPool, dsmSize, &ctx);
  this->dsmLKey = dsmMR->lkey;

  // on-chip lock memory
  // DEX_HOST_LOCKS=1 (default 0 = on-chip): this process's lock table in host
  // memory. The NIC's on-chip memory fits only two tables, so fair/multi sets it
  // for compute processes; with MN_ONLY placement no page (and no lock) lives there.
  if (dirID == 0 && getenv("DEX_HOST_LOCKS") && atoi(getenv("DEX_HOST_LOCKS"))) {
    this->lockSize = define::kLockChipMemSize;
    this->lockPool = aligned_alloc(4096, this->lockSize);
    memset(this->lockPool, 0, this->lockSize);
    this->lockMR =
        createMemoryRegion((uint64_t)this->lockPool, this->lockSize, &ctx);
    this->lockLKey = lockMR->lkey;
    printf("[MULTI] lock table in host memory (DEX_HOST_LOCKS=1)\n");
  } else if (dirID == 0) {
    this->lockPool = (void *)define::kLockStartAddr;
    this->lockSize = define::kLockChipMemSize;
    this->lockMR = createMemoryRegionOnChip((uint64_t)this->lockPool,
                                            this->lockSize, &ctx);
    this->lockLKey = lockMR->lkey;
    // this->lockPool = (void *)hugePageAlloc(define::kLockChipMemSize);
    // this->lockSize = define::kLockChipMemSize;
    // memset(lockPool, 0, this->lockSize = define::kLockChipMemSize);
    // this->lockMR =
    //     createMemoryRegion((uint64_t)this->lockPool, this->lockSize, &ctx);
    // this->lockLKey = lockMR->lkey;
  }

  // app, RC
  if (dirID == 0) {
    for (int i = 0; i < MAX_APP_THREAD; ++i) {
      data2app[i] = new ibv_qp *[machineNR];
      for (size_t k = 0; k < machineNR; ++k) {
        createQueuePair(&data2app[i][k], IBV_QPT_RC, cq, &ctx);
      }
    }
  }
}

void DirectoryConnection::sendMessage2App(RawMessage *m, uint16_t node_id,
                                          uint16_t th_id) {
  message->sendRawMessage(m, remoteInfo[node_id].appMessageQPN[th_id],
                          remoteInfo[node_id].dirToAppAh[dirID][th_id]);
  ;
}
