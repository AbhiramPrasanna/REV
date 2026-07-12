#ifndef __RAWMESSAGECONNECTION_H__
#define __RAWMESSAGECONNECTION_H__

#include "AbstractMessageConnection.h"
#include "GlobalAddress.h"

#include <thread>

enum RpcType : uint8_t {
  MALLOC,
  FREE,
  NEW_ROOT,
  NOP,
  // --- RPC offloading (see chime_rpc.h / Directory::process_message) ---
  // Prefixed to avoid clashing with RequestType::SCAN (unscoped enum in Tree.h).
  RPC_LOOKUP, // point lookup pushdown: probe leaf on the memory node
  RPC_SCAN,   // range-scan pushdown: memory node scans across sibling leaves
};

struct RawMessage {
  RpcType type;

  uint16_t node_id;
  uint16_t app_id;

  GlobalAddress addr; // for malloc; also entry-leaf addr / reply value / scan-result addr
  int level;          // reply status / requested count (offloading)
  uint64_t k;         // key (offloading): LOOKUP key, SCAN `from`, or reply max_key
  uint64_t v;         // value (offloading): SCAN `to`
} __attribute__((packed));

class RawMessageConnection : public AbstractMessageConnection {

public:
  RawMessageConnection(RdmaContext &ctx, ibv_cq *cq, uint32_t messageNR);

  void initSend();
  void sendRawMessage(RawMessage *m, uint32_t remoteQPN, ibv_ah *ah);
};

#endif /* __RAWMESSAGECONNECTION_H__ */
