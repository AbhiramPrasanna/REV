#ifndef __DIRECTORY_H__
#define __DIRECTORY_H__

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
#endif

  void dirThread();

  void sendData2App(const RawMessage *m);

  void process_message(const RawMessage *m);

};

#endif /* __DIRECTORY_H__ */
