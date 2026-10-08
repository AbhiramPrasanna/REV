#include "Rdma.h"
#include <atomic>
#include <cstdio>

// CHIME_RDMA_STATS=1 (off by default): every verb this process posts is counted, per
// thread, in the function that posts it. A "post" is one ibv_post_send, so a batch
// of k reads is one post (one round trip) and k reads. Pushed requests go out as
// sends. rdma_stats_reset() zeroes the counts at the start of the measured phase;
// rdma_stats_print() prints them, per operation when ops > 0.
namespace rdmastats {
struct alignas(64) Slot {
  uint64_t posts, read_wr, read_bytes, write_wr, write_bytes, atomic_wr, send_wr, send_bytes;
};
constexpr int kSlots = 256;
static Slot slots[kSlots];
static std::atomic<int> next_slot{0};
static thread_local int my_slot = -1;
static inline bool on() {
  static const bool v = [] { const char *e = getenv("CHIME_RDMA_STATS"); return e != nullptr && e[0] == '1'; }();
  return v;
}
static inline void add(uint64_t rd, uint64_t rdb, uint64_t wr, uint64_t wrb, uint64_t at,
                       uint64_t snd, uint64_t sndb) {
  if (!on()) return;
  if (my_slot < 0) my_slot = next_slot.fetch_add(1) % kSlots;
  Slot &s = slots[my_slot];
  s.posts++; s.read_wr += rd; s.read_bytes += rdb; s.write_wr += wr; s.write_bytes += wrb;
  s.atomic_wr += at; s.send_wr += snd; s.send_bytes += sndb;
}
static inline uint64_t batch_bytes(const RdmaOpRegion *ror, int k) {
  uint64_t b = 0;
  for (int i = 0; i < k; ++i) b += ror[i].size;
  return b;
}
}  // namespace rdmastats

void rdma_stats_reset() {
  if (!rdmastats::on()) return;
  for (auto &s : rdmastats::slots) s = rdmastats::Slot{};
}

void rdma_stats_print(int node_id, uint64_t ops) {
  if (!rdmastats::on()) return;
  rdmastats::Slot t{};
  for (const auto &s : rdmastats::slots) {
    t.posts += s.posts; t.read_wr += s.read_wr; t.read_bytes += s.read_bytes;
    t.write_wr += s.write_wr; t.write_bytes += s.write_bytes; t.atomic_wr += s.atomic_wr;
    t.send_wr += s.send_wr; t.send_bytes += s.send_bytes;
  }
  printf("[RDMA node %d] ops=%lu posts=%lu read_wr=%lu read_bytes=%lu write_wr=%lu "
         "write_bytes=%lu atomic_wr=%lu send_wr=%lu send_bytes=%lu\n", node_id,
         (unsigned long)ops, (unsigned long)t.posts, (unsigned long)t.read_wr,
         (unsigned long)t.read_bytes, (unsigned long)t.write_wr, (unsigned long)t.write_bytes,
         (unsigned long)t.atomic_wr, (unsigned long)t.send_wr, (unsigned long)t.send_bytes);
  if (ops == 0) return;
  const double o = (double)ops;
  printf("[RDMA node %d] per_op: round_trips=%.4f reads=%.4f writes=%.4f atomics=%.4f "
         "sends=%.4f verbs=%.4f bytes=%.1f\n", node_id, t.posts / o, t.read_wr / o,
         t.write_wr / o, t.atomic_wr / o, t.send_wr / o,
         (t.read_wr + t.write_wr + t.atomic_wr + t.send_wr) / o,
         (t.read_bytes + t.write_bytes + t.send_bytes) / o);
}

#include<vector>

int pollWithCQ(ibv_cq *cq, int pollNumber, struct ibv_wc *wc) {
  int count = 0;

  do {

    int new_count = ibv_poll_cq(cq, 1, wc);
    count += new_count;

  } while (count < pollNumber);

  if (count < 0) {
    Debug::notifyError("Poll Completion failed.");
    sleep(5);
    return -1;
  }

  if (wc->status != IBV_WC_SUCCESS) {
    Debug::notifyError("Failed status %s (%d) for wr_id %d",
                       ibv_wc_status_str(wc->status), wc->status,
                       (int)wc->wr_id);
    sleep(5);
    return -1;
  }

  return count;
}

int pollOnce(ibv_cq *cq, int pollNumber, struct ibv_wc *wc) {
  int count = ibv_poll_cq(cq, pollNumber, wc);
  if (count <= 0) {
    return 0;
  }
  if (wc->status != IBV_WC_SUCCESS) {
    Debug::notifyError("Failed status %s (%d) for wr_id %d",
                       ibv_wc_status_str(wc->status), wc->status,
                       (int)wc->wr_id);
    return -1;
  } else {
    return count;
  }
}

static inline void fillSgeWr(ibv_sge &sg, ibv_send_wr &wr, uint64_t source,
                             uint64_t size, uint32_t lkey) {
  memset(&sg, 0, sizeof(sg));
  sg.addr = (uintptr_t)source;
  sg.length = size;
  sg.lkey = lkey;

  memset(&wr, 0, sizeof(wr));
  wr.wr_id = 0;
  wr.sg_list = &sg;
  wr.num_sge = 1;
}

static inline void fillSgeWr(ibv_sge &sg, ibv_recv_wr &wr, uint64_t source,
                             uint64_t size, uint32_t lkey) {
  memset(&sg, 0, sizeof(sg));
  sg.addr = (uintptr_t)source;
  sg.length = size;
  sg.lkey = lkey;

  memset(&wr, 0, sizeof(wr));
  wr.wr_id = 0;
  wr.sg_list = &sg;
  wr.num_sge = 1;
}

// for UD and DC
bool rdmaSend(ibv_qp *qp, uint64_t source, uint64_t size, uint32_t lkey,
              ibv_ah *ah, uint32_t remoteQPN /* remote dct_number */,
              bool isSignaled) {
  rdmastats::add(0, 0, 0, 0, 0, 1, size);

  struct ibv_sge sg;
  struct ibv_send_wr wr;
  struct ibv_send_wr *wrBad;

  fillSgeWr(sg, wr, source, size, lkey);

  wr.opcode = IBV_WR_SEND;

  wr.wr.ud.ah = ah;
  wr.wr.ud.remote_qpn = remoteQPN;
  wr.wr.ud.remote_qkey = UD_PKEY;

  if (isSignaled)
    wr.send_flags = IBV_SEND_SIGNALED;
  if (ibv_post_send(qp, &wr, &wrBad)) {
    Debug::notifyError("Send with RDMA_SEND failed.");
    return false;
  }
  return true;
}

// for RC & UC
bool rdmaSend(ibv_qp *qp, uint64_t source, uint64_t size, uint32_t lkey,
              int32_t imm) {
  rdmastats::add(0, 0, 0, 0, 0, 1, size);

  struct ibv_sge sg;
  struct ibv_send_wr wr;
  struct ibv_send_wr *wrBad;

  fillSgeWr(sg, wr, source, size, lkey);

  if (imm != -1) {
    wr.imm_data = imm;
    wr.opcode = IBV_WR_SEND_WITH_IMM;
  } else {
    wr.opcode = IBV_WR_SEND;
  }

  wr.send_flags = IBV_SEND_SIGNALED;

  if (ibv_post_send(qp, &wr, &wrBad)) {
    Debug::notifyError("Send with RDMA_SEND failed.");
    return false;
  }
  return true;
}

bool rdmaReceive(ibv_qp *qp, uint64_t source, uint64_t size, uint32_t lkey,
                 uint64_t wr_id) {
  struct ibv_sge sg;
  struct ibv_recv_wr wr;
  struct ibv_recv_wr *wrBad;

  fillSgeWr(sg, wr, source, size, lkey);

  wr.wr_id = wr_id;

  if (ibv_post_recv(qp, &wr, &wrBad)) {
    Debug::notifyError("Receive with RDMA_RECV failed.");
    return false;
  }
  return true;
}

bool rdmaReceive(ibv_srq *srq, uint64_t source, uint64_t size, uint32_t lkey) {

  struct ibv_sge sg;
  struct ibv_recv_wr wr;
  struct ibv_recv_wr *wrBad;

  fillSgeWr(sg, wr, source, size, lkey);

  if (ibv_post_srq_recv(srq, &wr, &wrBad)) {
    Debug::notifyError("Receive with RDMA_RECV failed.");
    return false;
  }
  return true;
}



// for RC & UC
bool rdmaRead(ibv_qp *qp, uint64_t source, uint64_t dest, uint64_t size,
              uint32_t lkey, uint32_t remoteRKey, bool signal, uint64_t wrID) {
  rdmastats::add(1, size, 0, 0, 0, 0, 0);
  struct ibv_sge sg;
  struct ibv_send_wr wr;
  struct ibv_send_wr *wrBad;

  fillSgeWr(sg, wr, source, size, lkey);

  wr.opcode = IBV_WR_RDMA_READ;

  if (signal) {
    wr.send_flags = IBV_SEND_SIGNALED;
  }

  wr.wr.rdma.remote_addr = dest;
  wr.wr.rdma.rkey = remoteRKey;
  wr.wr_id = wrID;

  if (ibv_post_send(qp, &wr, &wrBad)) {
    Debug::notifyError("Send with RDMA_READ failed.");
    return false;
  }
  return true;
}


// for RC & UC
bool rdmaWrite(ibv_qp *qp, uint64_t source, uint64_t dest, uint64_t size,
               uint32_t lkey, uint32_t remoteRKey, int32_t imm, bool isSignaled,
               uint64_t wrID) {
  rdmastats::add(0, 0, 1, size, 0, 0, 0);

  struct ibv_sge sg;
  struct ibv_send_wr wr;
  struct ibv_send_wr *wrBad;

  fillSgeWr(sg, wr, source, size, lkey);

  if (imm == -1) {
    wr.opcode = IBV_WR_RDMA_WRITE;
  } else {
    wr.imm_data = imm;
    wr.opcode = IBV_WR_RDMA_WRITE_WITH_IMM;
  }

  if (isSignaled) {
    wr.send_flags = IBV_SEND_SIGNALED;
  }
  if (size <= kInlineDataMax) {  // Optimization: write inline for small node/leaf
    wr.send_flags |= IBV_SEND_INLINE;
  }

  wr.wr.rdma.remote_addr = dest;
  wr.wr.rdma.rkey = remoteRKey;
  wr.wr_id = wrID;

  if (ibv_post_send(qp, &wr, &wrBad) != 0) {
    Debug::notifyError("Send with RDMA_WRITE(WITH_IMM) failed.");
    sleep(10);
    return false;
  }
  return true;
}

// RC & UC
bool rdmaFetchAndAdd(ibv_qp *qp, uint64_t source, uint64_t dest, uint64_t add,
                     uint32_t lkey, uint32_t remoteRKey) {
  rdmastats::add(0, 0, 0, 0, 1, 0, 0);
  struct ibv_sge sg;
  struct ibv_send_wr wr;
  struct ibv_send_wr *wrBad;

  fillSgeWr(sg, wr, source, 8, lkey);

  wr.opcode = IBV_WR_ATOMIC_FETCH_AND_ADD;
  wr.send_flags = IBV_SEND_SIGNALED;

  wr.wr.atomic.remote_addr = dest;
  wr.wr.atomic.rkey = remoteRKey;
  wr.wr.atomic.compare_add = add;

  if (ibv_post_send(qp, &wr, &wrBad)) {
    Debug::notifyError("Send with ATOMIC_FETCH_AND_ADD failed.");
    return false;
  }
  return true;
}

// rdma-core has no masked/bounded atomics (was ibv_exp EXT_MASKED_ATOMIC).
// Fall back to a plain 64-bit fetch-and-add. `boundary` (carry-boundary bit) is
// ignored; this path is unused by the default CHIME config (only the masked CAS
// lock at Tree.cpp is exercised, emulated in DSM::cas_mask_sync).
bool rdmaFetchAndAddBoundary(ibv_qp *qp, uint64_t source, uint64_t dest,
                             uint64_t add, uint32_t lkey, uint32_t remoteRKey,
                             uint64_t boundary, bool singal, uint64_t wr_id) {
  rdmastats::add(0, 0, 0, 0, 1, 0, 0);
  (void)boundary;
  struct ibv_sge sg;
  struct ibv_send_wr wr;
  struct ibv_send_wr *wrBad;

  fillSgeWr(sg, wr, source, 8, lkey);

  wr.opcode = IBV_WR_ATOMIC_FETCH_AND_ADD;
  wr.wr_id = wr_id;
  if (singal) {
    wr.send_flags = IBV_SEND_SIGNALED;
  }

  wr.wr.atomic.remote_addr = dest;
  wr.wr.atomic.rkey = remoteRKey;
  wr.wr.atomic.compare_add = add;

  if (ibv_post_send(qp, &wr, &wrBad)) {
    Debug::notifyError("Send with FETCH_AND_ADD failed.");
    return false;
  }
  return true;
}


// for RC & UC
bool rdmaCompareAndSwap(ibv_qp *qp, uint64_t source, uint64_t dest,
                        uint64_t compare, uint64_t swap, uint32_t lkey,
                        uint32_t remoteRKey, bool signal, uint64_t wrID) {
  rdmastats::add(0, 0, 0, 0, 1, 0, 0);
  struct ibv_sge sg;
  struct ibv_send_wr wr;
  struct ibv_send_wr *wrBad;

  fillSgeWr(sg, wr, source, 8, lkey);

  wr.opcode = IBV_WR_ATOMIC_CMP_AND_SWP;

  if (signal) {
    wr.send_flags = IBV_SEND_SIGNALED;
  }

  wr.wr.atomic.remote_addr = dest;
  wr.wr.atomic.rkey = remoteRKey;
  wr.wr.atomic.compare_add = compare;
  wr.wr.atomic.swap = swap;
  wr.wr_id = wrID;

  if (ibv_post_send(qp, &wr, &wrBad)) {
    Debug::notifyError("Send with ATOMIC_CMP_AND_SWP failed.");
    sleep(5);
    return false;
  }
  return true;
}

// rdma-core has no masked compare-and-swap (was ibv_exp EXT_MASKED_ATOMIC).
// Fall back to a plain 64-bit CAS; the mask arguments are ignored. The one masked
// CAS CHIME actually relies on (the vacancy-aware lock) is emulated correctly at
// the DSM layer (DSM::cas_mask_sync = read + this plain CAS), so this low-level
// helper only needs to compile for the other (unused) masked wrappers.
bool rdmaCompareAndSwapMask(ibv_qp *qp, uint64_t source, uint64_t dest,
                            uint64_t compare, uint64_t swap, uint32_t lkey,
                            uint32_t remoteRKey, uint64_t compare_mask, uint64_t swap_mask, bool singal, uint64_t wrID) {
  rdmastats::add(0, 0, 0, 0, 1, 0, 0);
  (void)compare_mask;
  (void)swap_mask;
  struct ibv_sge sg;
  struct ibv_send_wr wr;
  struct ibv_send_wr *wrBad;

  fillSgeWr(sg, wr, source, 8, lkey);

  wr.opcode = IBV_WR_ATOMIC_CMP_AND_SWP;
  if (singal) {
    wr.send_flags = IBV_SEND_SIGNALED;
  }

  wr.wr.atomic.remote_addr = dest;
  wr.wr.atomic.rkey = remoteRKey;
  wr.wr.atomic.compare_add = compare;
  wr.wr.atomic.swap = swap;
  wr.wr_id = wrID;

  if (ibv_post_send(qp, &wr, &wrBad)) {
    Debug::notifyError("Send with ATOMIC_CMP_AND_SWP failed.");
    return false;
  }
  return true;
}


bool rdmaReadBatch(ibv_qp *qp, RdmaOpRegion *ror, int k, bool isSignaled,
                   uint64_t wrID) {
  rdmastats::add(k, rdmastats::batch_bytes(ror, k), 0, 0, 0, 0, 0);
  std::vector<ibv_sge> sg(k);
  std::vector<ibv_send_wr> wr(k);
  struct ibv_send_wr *wrBad;

  for (int i = 0; i < k; ++i) {
    fillSgeWr(sg[i], wr[i], ror[i].source, ror[i].size, ror[i].lkey);

    wr[i].next = (i == k - 1) ? NULL : &wr[i + 1];

    wr[i].opcode = IBV_WR_RDMA_READ;

    if (i == k - 1 && isSignaled) {
      wr[i].send_flags = IBV_SEND_SIGNALED;
    }

    wr[i].wr.rdma.remote_addr = ror[i].dest;
    wr[i].wr.rdma.rkey = ror[i].remoteRKey;
    wr[i].wr_id = wrID;
  }

  if (ibv_post_send(qp, &wr[0], &wrBad) != 0) {
    Debug::notifyError("Send with RDMA_READ(WITH_IMM) failed.");
    sleep(10);
    return false;
  }
  return true;
}


bool rdmaWriteBatch(ibv_qp *qp, RdmaOpRegion *ror, int k, bool isSignaled,
                    uint64_t wrID) {
  rdmastats::add(0, 0, k, rdmastats::batch_bytes(ror, k), 0, 0, 0);
  std::vector<ibv_sge> sg(k);
  std::vector<ibv_send_wr> wr(k);
  struct ibv_send_wr *wrBad;

  for (int i = 0; i < k; ++i) {
    fillSgeWr(sg[i], wr[i], ror[i].source, ror[i].size, ror[i].lkey);

    wr[i].next = (i == k - 1) ? NULL : &wr[i + 1];

    wr[i].opcode = IBV_WR_RDMA_WRITE;

    if (i == k - 1 && isSignaled) {
      wr[i].send_flags = IBV_SEND_SIGNALED;
    }
    if (ror[i].size <= kInlineDataMax) {  // Optimization
      wr[i].send_flags |= IBV_SEND_INLINE;
    }

    wr[i].wr.rdma.remote_addr = ror[i].dest;
    wr[i].wr.rdma.rkey = ror[i].remoteRKey;
    wr[i].wr_id = wrID;
  }

  if (ibv_post_send(qp, &wr[0], &wrBad) != 0) {
    Debug::notifyError("Send with RDMA_WRITE(WITH_IMM) failed.");
    sleep(10);
    return false;
  }
  return true;
}

bool rdmaCasRead(ibv_qp *qp, const RdmaOpRegion &cas_ror,
                 const RdmaOpRegion &read_ror, uint64_t compare, uint64_t swap,
                 bool isSignaled, uint64_t wrID) {
  rdmastats::add(1, read_ror.size, 0, 0, 1, 0, 0);

  struct ibv_sge sg[2];
  struct ibv_send_wr wr[2];
  struct ibv_send_wr *wrBad;

  fillSgeWr(sg[0], wr[0], cas_ror.source, 8, cas_ror.lkey);
  wr[0].opcode = IBV_WR_ATOMIC_CMP_AND_SWP;
  wr[0].wr.atomic.remote_addr = cas_ror.dest;
  wr[0].wr.atomic.rkey = cas_ror.remoteRKey;
  wr[0].wr.atomic.compare_add = compare;
  wr[0].wr.atomic.swap = swap;
  wr[0].next = &wr[1];

  fillSgeWr(sg[1], wr[1], read_ror.source, read_ror.size, read_ror.lkey);
  wr[1].opcode = IBV_WR_RDMA_READ;
  wr[1].wr.rdma.remote_addr = read_ror.dest;
  wr[1].wr.rdma.rkey = read_ror.remoteRKey;
  wr[1].wr_id = wrID;
  // wr[1].send_flags |= IBV_SEND_FENCE;
  if (isSignaled) {
    wr[1].send_flags |= IBV_SEND_SIGNALED;
  }

  if (ibv_post_send(qp, &wr[0], &wrBad)) {
    Debug::notifyError("Send with CAS_READs failed.");
    sleep(10);
    return false;
  }
  return true;
}

bool rdmaReadCas(ibv_qp *qp, const RdmaOpRegion &read_ror,
                 const RdmaOpRegion &cas_ror, uint64_t compare, uint64_t swap,
                 bool isSignaled, uint64_t wrID) {
  rdmastats::add(1, read_ror.size, 0, 0, 1, 0, 0);

  struct ibv_sge sg[2];
  struct ibv_send_wr wr[2];
  struct ibv_send_wr *wrBad;

  fillSgeWr(sg[0], wr[0], read_ror.source, read_ror.size, read_ror.lkey);
  wr[0].opcode = IBV_WR_RDMA_READ;
  wr[0].wr.rdma.remote_addr = cas_ror.dest;
  wr[0].wr.rdma.rkey = cas_ror.remoteRKey;
  wr[0].next = &wr[1];

  fillSgeWr(sg[1], wr[1], cas_ror.source, 8, cas_ror.lkey);
  wr[1].opcode = IBV_WR_ATOMIC_CMP_AND_SWP;
  wr[1].wr.atomic.remote_addr = read_ror.dest;
  wr[1].wr.atomic.rkey = read_ror.remoteRKey;
  wr[1].wr.atomic.compare_add = compare;
  wr[1].wr.atomic.swap = swap;
  wr[1].wr_id = wrID;
  // wr[1].send_flags |= IBV_SEND_FENCE;
  if (isSignaled) {
    wr[1].send_flags |= IBV_SEND_SIGNALED;
  }

  if (ibv_post_send(qp, &wr[0], &wrBad)) {
    Debug::notifyError("Send with CAS_READs failed.");
    sleep(10);
    return false;
  }
  return true;
}

bool rdmaCasWrite(ibv_qp *qp, const RdmaOpRegion &cas_ror,
                  const RdmaOpRegion &write_ror, uint64_t compare, uint64_t swap,
                  bool isSignaled, uint64_t wrID) {
  rdmastats::add(0, 0, 1, write_ror.size, 1, 0, 0);

  struct ibv_sge sg[2];
  struct ibv_send_wr wr[2];
  struct ibv_send_wr *wrBad;

  fillSgeWr(sg[0], wr[0], cas_ror.source, 8, cas_ror.lkey);
  wr[0].opcode = IBV_WR_ATOMIC_CMP_AND_SWP;
  wr[0].wr.atomic.remote_addr = cas_ror.dest;
  wr[0].wr.atomic.rkey = cas_ror.remoteRKey;
  wr[0].wr.atomic.compare_add = compare;
  wr[0].wr.atomic.swap = swap;
  wr[0].next = &wr[1];

  fillSgeWr(sg[1], wr[1], write_ror.source, write_ror.size, write_ror.lkey);
  wr[1].opcode = IBV_WR_RDMA_WRITE;
  wr[1].wr.rdma.remote_addr = write_ror.dest;
  wr[1].wr.rdma.rkey = write_ror.remoteRKey;
  wr[1].wr_id = wrID;
  // wr[1].send_flags |= IBV_SEND_FENCE;
  if (isSignaled) {
    wr[1].send_flags |= IBV_SEND_SIGNALED;
  }

  if (ibv_post_send(qp, &wr[0], &wrBad)) {
    Debug::notifyError("Send with CAS_WRITEs failed.");
    sleep(10);
    return false;
  }
  return true;
}

bool rdmaWriteFaa(ibv_qp *qp, const RdmaOpRegion &write_ror,
                  const RdmaOpRegion &faa_ror, uint64_t add_val,
                  bool isSignaled, uint64_t wrID) {
  rdmastats::add(0, 0, 1, write_ror.size, 1, 0, 0);

  struct ibv_sge sg[2];
  struct ibv_send_wr wr[2];
  struct ibv_send_wr *wrBad;

  fillSgeWr(sg[0], wr[0], write_ror.source, write_ror.size, write_ror.lkey);
  wr[0].opcode = IBV_WR_RDMA_WRITE;
  wr[0].wr.rdma.remote_addr = write_ror.dest;
  wr[0].wr.rdma.rkey = write_ror.remoteRKey;
  wr[0].next = &wr[1];

  fillSgeWr(sg[1], wr[1], faa_ror.source, 8, faa_ror.lkey);
  wr[1].opcode = IBV_WR_ATOMIC_FETCH_AND_ADD;
  wr[1].wr.atomic.remote_addr = faa_ror.dest;
  wr[1].wr.atomic.rkey = faa_ror.remoteRKey;
  wr[1].wr.atomic.compare_add = add_val;
  wr[1].wr_id = wrID;

  if (isSignaled) {
    wr[1].send_flags |= IBV_SEND_SIGNALED;
  }

  if (ibv_post_send(qp, &wr[0], &wrBad)) {
    Debug::notifyError("Send with Write Faa failed.");
    sleep(10);
    return false;
  }
  return true;
}

bool rdmaWriteCas(ibv_qp *qp, const RdmaOpRegion &write_ror,
                  const RdmaOpRegion &cas_ror, uint64_t compare, uint64_t swap,
                  bool isSignaled, uint64_t wrID) {
  rdmastats::add(0, 0, 1, write_ror.size, 1, 0, 0);

  struct ibv_sge sg[2];
  struct ibv_send_wr wr[2];
  struct ibv_send_wr *wrBad;

  fillSgeWr(sg[0], wr[0], write_ror.source, write_ror.size, write_ror.lkey);
  wr[0].opcode = IBV_WR_RDMA_WRITE;
  wr[0].wr.rdma.remote_addr = write_ror.dest;
  wr[0].wr.rdma.rkey = write_ror.remoteRKey;
  wr[0].next = &wr[1];

  fillSgeWr(sg[1], wr[1], cas_ror.source, 8, cas_ror.lkey);
  wr[1].opcode = IBV_WR_ATOMIC_CMP_AND_SWP;
  wr[1].wr.atomic.remote_addr = cas_ror.dest;
  wr[1].wr.atomic.rkey = cas_ror.remoteRKey;
  wr[1].wr.atomic.compare_add = compare;
  wr[1].wr.atomic.swap = swap;
  // wr[1].send_flags |= IBV_SEND_FENCE;
  wr[1].wr_id = wrID;

  if (isSignaled) {
    wr[1].send_flags |= IBV_SEND_SIGNALED;
  }

  if (ibv_post_send(qp, &wr[0], &wrBad)) {
    Debug::notifyError("Send with Write Cas failed.");
    sleep(10);
    return false;
  }
  return true;
}
