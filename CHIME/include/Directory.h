#ifndef __DIRECTORY_H__
#define __DIRECTORY_H__

#include <mutex>
#include <thread>

#include <unordered_map>

#include "Common.h"

#include "Connection.h"
#include "GlobalAllocator.h"


class Directory {
public:
  Directory(DirectoryConnection *dCon, RemoteConnection *remoteInfo,
            uint32_t machineNR, uint16_t dirID, uint16_t nodeID);

  ~Directory();

#ifdef ENABLE_OFFLOAD
  // CHIME_PUSH_WRITES: a worker thread answers a pushed write through the
  // directory thread that received it (see push_write.h).
  void send_write_reply(uint16_t node_id, uint16_t app_id, int status);
#endif

private:
  DirectoryConnection *dCon;
  RemoteConnection *remoteInfo;

  uint32_t machineNR;
  uint16_t dirID;
  uint16_t nodeID;

  std::thread *dirTh;

  GlobalAllocator *chunckAlloc;

#ifdef ENABLE_OFFLOAD
  // Scratch chunk (inside the registered DSM region) where SCAN pushdown packs
  // its per-requester result batch for the compute node to RDMA-read back. The
  // local pointer is resolved lazily (dsmPool is valid at construction, but we
  // keep the resolution next to first use for clarity).
  GlobalAddress scanScratch;
  char *scanScratchBase;
  // Guards this directory's send pool when worker threads also send through it.
  // Taken only with CHIME_PUSH_WRITES=1; otherwise the directory thread is the
  // only sender, as before.
  std::mutex send_mtx;
#endif

  void dirThread();

  void sendData2App(const RawMessage *m);

  void process_message(const RawMessage *m);

};

#endif /* __DIRECTORY_H__ */
