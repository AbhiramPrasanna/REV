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
  LOOKUP,
  INSERT,
  UPDATE,
  DELETE,
  SCAN, // range-scan pushdown: memory node scans across sibling leaves
  SMO,
  LOCATE // DEX-C: a write's walk pushed, the leaf written by the compute node
};

struct RawMessage {
  RpcType type; // operation type

  uint16_t node_id; // source node ID
  uint16_t app_id; // source thread ID, so the receiver can send the message for
                   // reply

  GlobalAddress addr; // for malloc and for root_address of B+-Tree RPC
  int level;          // the return value of pushdown op
  uint64_t k;         // key for B+-Tree RPC
  uint64_t v;         // value for B+-Tree RPC
  // Updated node
#if DEX_VALUE_PAD > 0
  uint8_t value_pad[DEX_VALUE_PAD]; // the rest of a simulated DEX_VALUE_LEN value
#endif
} __attribute__((packed));
static_assert(sizeof(RawMessage) + 40 <= MESSAGE_SIZE, "RawMessage outgrew its message slot");

class RawMessageConnection : public AbstractMessageConnection {

public:
  RawMessageConnection(RdmaContext &ctx, ibv_cq *cq, uint32_t messageNR);

  void initSend();
  void sendRawMessage(RawMessage *m, uint32_t remoteQPN, ibv_ah *ah);
};

#endif /* __RAWMESSAGECONNECTION_H__ */
