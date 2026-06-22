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
            uint32_t machineNR, uint16_t dirID, uint16_t nodeID,
            int memThreadCount);

  ~Directory();

private:
  DirectoryConnection *dCon;
  RemoteConnection *remoteInfo;

  uint32_t machineNR;
  uint16_t dirID;
  uint16_t nodeID;
  int memThreadCount; // # of dir-threads on this MN (for the remote-load report)

  std::thread *dirTh;

  GlobalAllocator *chunckAlloc;

  // Scratch region (one 32 MB chunk) for range-scan pushdown results. Each
  // requesting app thread gets its own slot, so a thread's result is never
  // overwritten before it reads it back (a thread has <=1 outstanding RPC).
  GlobalAddress scanScratch;   // global address of the scratch chunk
  char *scanScratchBase;       // lazily-resolved local pointer (dsmBase+offset)
  static constexpr uint64_t kScanSlotBytes = 4096; // 256 KV pairs / thread
  static constexpr int kScanSlotCap =
      kScanSlotBytes / sizeof(std::pair<Key, Value>);

  void dirThread();

  // No sepecific implementation, "process_message" below has the
  // funcitonability to handle the message and reply
  void sendData2App(const RawMessage *m);

  void process_message(const RawMessage *m);
};

#endif /* __DIRECTORY_H__ */
