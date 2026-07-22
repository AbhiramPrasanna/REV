#ifndef __COMMON_H__
#define __COMMON_H__

#include <cassert>
#include <cstdint>
#include <cstdlib>
#include <cstring>

#include <atomic>
#include <queue>
#include <bitset>
#include <limits>

#include "Debug.h"
#include "HugePageAlloc.h"
#include "Rdma.h"

#include "WRLock.h"

// DEBUG
// #define HOPSCOTCH_LEAF_NODE
// #define VACANCY_AWARE_LOCK
// #define METADATA_REPLICATION
// #define SIBLING_BASED_VALIDATION
// #define SPECULATIVE_POINT_QUERY
// #define ENABLE_VAR_LEN_KV

// Environment Config
#define MAX_MACHINE 20
#define MEMORY_NODE_NUM 1
#define CPU_PHYSICAL_CORE_NUM 72  // [CONFIG]  72
#define MAX_CORO_NUM 8

#define LATENCY_WINDOWS 100000
#define PACKED_ADDR_ALIGN_BIT 8
#define CACHELINE_ALIGN_BIT 6
#define MAX_KEY_SPACE_SIZE 60000000
// #define KEY_SPACE_LIMIT
#define MESSAGE_SIZE 96 // byte
#define RAW_RECV_CQ_COUNT 4096 // 128
#define MAX_TREE_HEIGHT 20

// Auxiliary function
#define STRUCT_OFFSET(type, field)  ((char *)&((type *)(0))->field - (char *)((type *)(0)))
#define UNUSED(x) (void)(x)
#define ADD_ROUND(x, n) ((x) = ((x) + 1) % (n))
#define ROUND_UP(x, n) (((x) + (1<<(n)) - 1) & ~((1<<(n)) - 1))
#define ROUND_DOWN(x, n) ((x) & ~((1<<(n)) - 1))
#define ADD_CACHELINE_VERSION_SIZE(x, cvs) ((x) + ((x)/(64-(cvs)) + ((x)%(64-(cvs))?1:0))*(cvs))


// app thread
#define MAX_APP_THREAD 65   // one additional thread for data statistics(main thread)  [CONFIG] 65
#define APP_MESSAGE_NR 96
#define POLL_CQ_MAX_CNT_ONCE 8

// dir thread -- RPC-serving threads on the memory node.
// [CONFIG] 4 (stock CHIME: 1). Stock CHIME never needs these: its data path is
// pure one-sided RDMA, served by the NIC with ZERO memory-node CPU, so 1 dir
// thread (which only handles malloc/free/root RPCs) is plenty. But the offload
// path turns every lookup into an RPC that a dir thread must execute, so with
// NR_DIRECTORY=1 all client threads serialize through ONE core (~700K RPC/s
// ceiling) and offload loses to one-sided reads no matter how many round trips
// it saves. DEX runs its offload with 4 memory threads (its results are labelled
// "offload_4mt"), so 4 is the apples-to-apples setting.
// RPCs shard automatically: rpc_call_dir(..., thread_id % chime::num_dir()).
//
// NR_DIRECTORY is the compile-time MAXIMUM: it sizes arrays (dirCon[],
// dsmRKey[], local_allocators[][], dirMessageQPN[], ...) and drives the QP
// exchange in DSMKeeper. Those stay at the max on every node so the two nodes'
// connection exchange is symmetric no matter how many dir threads actually run.
#define NR_DIRECTORY 8
#define DIR_MESSAGE_NR 128

namespace chime {
// How many dir threads ACTUALLY run -- the DEX-style runtime knob (DEX exposes
// its memory-thread count the same way; its offload results are labelled
// "offload_4mt" = 4 memory threads). Set with CHIME_DIR_THREADS; default 4.
//
// Runtime, not compile-time, so the dir count can be swept (1/2/4/8) with NO
// rebuild -- which is what makes an offload-vs-one-sided comparison fair instead
// of hostage to a single hard-coded value.
//
// !! BOTH NODES MUST SET THE SAME VALUE !!  The memory node uses it to decide how
// many dir threads to spawn; the compute node uses it to shard RPCs
// (thread_id % num_dir()). If the compute node shards over more dirs than the
// memory node spawned, those RPCs target a dir with no thread polling its CQ and
// the caller blocks forever in rpc_wait() -- which surfaces as a lock-held-forever
// "Deadlock" report, not as an obvious config error.
//
// Static-local init is thread-safe (C++11) and runs on first use, so there is no
// static-init-order hazard with DSM's thread_local allocators.
inline int num_dir() {
  static const int n = [] {
    const char *e = getenv("CHIME_DIR_THREADS");
    int v = e ? atoi(e) : 4;
    if (v < 1) v = 1;
    if (v > NR_DIRECTORY) v = NR_DIRECTORY;  // never exceed the array bound
    return v;
  }();
  return n;
}
}  // namespace chime


void bindCore(uint16_t core);
char *getIP();
char *getMac();

inline int bits_in(std::uint64_t u) {
  auto bs = std::bitset<64>(u);
  return bs.count();
}

#include <boost/coroutine2/all.hpp>
#include <boost/crc.hpp>

using CoroPush = boost::coroutines2::coroutine<int>::push_type;
using CoroPull = boost::coroutines2::coroutine<int>::pull_type;

using CoroQueue = std::queue<uint16_t>;

namespace define {
// KV size
constexpr uint32_t keyLen = 8;
// [CACHE-SWEEP GEOMETRY] 48 (was 8, stock CHIME). The value size inflates ONLY
// the leaf (decodedLeafSize = 196 + 16*V at leafSpanSize=16 with the build's
// SIBLING_BASED_VALIDATION on); it does not touch the internal node or the cached
// index. Two things at once:
//   (1) leaf 979B vs internal 319B (transferred) -> a 3.1x "internal < leaf"
//       margin. This is NOT cosmetic: at V=8 the leaf is 329B against a 319B
//       internal, a 3% margin that flips outright depending on whether
//       SIBLING_BASED_VALIDATION is on (it shrinks scatterMetadataSize 26 -> 10).
//       V=48 puts the inequality beyond the reach of any validation macro.
//   (2) tree = ~3.1M leaves * 979B ~= 3.0GB, i.e. DEX-scale, while the index stays
//       ~65-95MB so the cache sweep still straddles it.
constexpr uint32_t simulatedValLen = 48;
#ifndef ENABLE_VAR_LEN_KV
constexpr uint32_t inlineValLen = simulatedValLen;
#else
constexpr uint32_t inlineValLen = 8;
constexpr uint32_t indirectValLen = simulatedValLen;
constexpr uint32_t dataBlockLen = sizeof(uint64_t) * 2 + 0 + simulatedValLen;
#endif
}

using Key = std::array<uint8_t, define::keyLen>;
using Value = uint64_t;

namespace define {   // namespace define

constexpr uint64_t MB = 1024ull * 1024;
constexpr uint64_t GB = 1024ull * MB;
constexpr uint16_t kCacheLineSize = 64;

// Remote Allocation
constexpr uint64_t dsmSize           = 64;        // GB  [CONFIG] 64
constexpr uint64_t kChunkSize        = 16 * MB;   // B

// Local Allocation
constexpr uint64_t rdmaBufferSize     = 4;         // GB  [CONFIG] 4

// Cache (MB)
constexpr int kIndexCacheSize  = 100;  // MB including kHotspotBufSize 
constexpr int kHotspotBufSize  = 30;

// KV
constexpr uint64_t kKeyMin = 1;
constexpr uint64_t kLoadedKeyNum = 60000000;  // [CONFIG] 60000000
#ifdef KEY_SPACE_LIMIT
constexpr uint64_t kKeyMax = kLoadedKeyNum;  // only for int workloads
#endif
constexpr Key   kkeyNull   = Key{};
constexpr Value kValueNull = std::numeric_limits<Value>::min();
constexpr Value kValueMin = 1;
constexpr Value kValueMax = std::numeric_limits<Value>::max();

// Tree
constexpr uint64_t kRootPointerStoreOffest = kChunkSize / 2;
static_assert(kRootPointerStoreOffest % sizeof(uint64_t) == 0);

// Packed GlobalAddress
constexpr uint32_t mnIdBit         = 8;
constexpr uint32_t offsetBit       = 48 - PACKED_ADDR_ALIGN_BIT;
constexpr uint32_t packedGaddrBit  = mnIdBit + offsetBit;
constexpr uint32_t packedGAddrSize = ROUND_UP(mnIdBit + offsetBit, 3) / 8;

// Version
constexpr uint32_t entryVersionBit = 4;
constexpr uint32_t nodeVersionBit  = 4;
constexpr uint32_t versionSize     = ROUND_UP(entryVersionBit + nodeVersionBit, 3) / 8;
constexpr uint32_t cachelineSize   = 64;
constexpr uint32_t blockSize       = cachelineSize - versionSize;

// Leaf Node
// [CACHE-SWEEP GEOMETRY] 16 (was 64). Smaller leaves => more leaves => the
// compute-side INDEX cache (kIndexCacheSize, internals only) working set grows
// from ~20MB to ~84MB for 50M keys, so a 32-512MB cache sweep is meaningful and
// comparable to DEX. Must be a multiple of neighborSize (8) and >= neighborSize.
// (Increasing internalSpanSize does NOT help: level-1 internal bytes are ~=
// num_leaves*16 regardless of fanout.) Set back to 64 for stock CHIME.
constexpr uint32_t leafSpanSize    = 16;
#ifdef SIBLING_BASED_VALIDATION
constexpr uint32_t scatterMetadataSize = versionSize + sizeof(uint8_t) + sizeof(uint64_t);
#else
constexpr uint32_t scatterMetadataSize = versionSize + sizeof(uint8_t) + sizeof(uint64_t) + keyLen * 2;
#endif
constexpr uint32_t leafMetadataSize    = versionSize + sizeof(uint8_t) * 2 + sizeof(uint64_t) + keyLen * 2;
#ifdef HOPSCOTCH_LEAF_NODE
constexpr uint32_t leafEntrySize = versionSize + sizeof(uint16_t) + keyLen + inlineValLen;
#else
constexpr uint32_t leafEntrySize = versionSize + keyLen + inlineValLen;
#endif

// Internal Node
// [CACHE-SWEEP GEOMETRY] 16 (was 64, stock CHIME).
//
// Rationale: the cached INDEX working set is ~= num_leaves * (internalMetadataSize
// + internalEntrySize*S)/(S-1), which is nearly INVARIANT in the fanout S
// (18B/leaf at S=64 vs 21B/leaf at S=16) -- the entries-per-node and the
// nodes-per-level cancel. But the internal NODE size, 43 + 17*S, is linear in S.
// So shrinking S is the one knob that makes an internal node SMALLER than a leaf
// WITHOUT shrinking the index we want to overflow the cache:
// (transferred sizes, with the build's SIBLING_BASED_VALIDATION + HOPSCOTCH +
//  METADATA_REPLICATION all ON, and simulatedValLen=48):
//   S=64 -> internal 1148B  >  leaf 979B   (internal BIGGER -- unwanted)
//   S=16 -> internal  319B  <  leaf 979B   (internal 3.1x smaller -- wanted)
// Cost: fanout 16 makes the tree ~6 levels deep instead of ~4, so a cache MISS
// costs more RDMA round-trips -- which is exactly the regime where offloading the
// walk to one MN RPC is supposed to pay off.
// Set back to 64 for stock CHIME.
//
// [NODE-SIZE SWEEP] Overridable at build time so run/run_span_sweep.sh can
// rebuild one binary per inner-node size without editing this file:
//     cmake -DCHIME_INTERNAL_SPAN=<S> ..
// The default (16) reproduces the committed cache-sweep geometry exactly.
#ifndef CHIME_INTERNAL_SPAN
#define CHIME_INTERNAL_SPAN 16
#endif
constexpr uint32_t internalSpanSize = CHIME_INTERNAL_SPAN;
constexpr uint32_t internalMetadataSize = versionSize + sizeof(uint8_t) * 2 + sizeof(uint64_t) * 3 + keyLen * 2;
constexpr uint32_t internalEntrySize    = versionSize + keyLen + sizeof(uint64_t);

// Hopscotch Hashing
constexpr uint32_t neighborSize  = 8;
constexpr uint32_t entryGroupNum = leafSpanSize / neighborSize + ((leafSpanSize % neighborSize) ? 1 : 0);
constexpr uint32_t groupSize     = leafEntrySize * neighborSize;
constexpr uint32_t overflowNum   = entryGroupNum * neighborSize - leafSpanSize;

#ifdef VACANCY_AWARE_LOCK
constexpr int log2_ceil(unsigned int n, int p = 0) {
    return (n <= 1) ? p : log2_ceil((n + 1) / 2, p + 1);
}
constexpr uint32_t paddingBit  = log2_ceil(std::max(leafSpanSize, internalSpanSize));
constexpr uint32_t vacancyMapBit = std::min((uint32_t)(63 - paddingBit), std::min(leafSpanSize, internalSpanSize));
constexpr uint32_t maxKeyIdxBit  = 63 - vacancyMapBit;
#endif

// Rdma Read/Write Size
#ifdef METADATA_REPLICATION
constexpr uint32_t decodedLeafSize        = (scatterMetadataSize + leafEntrySize * neighborSize) * entryGroupNum - leafEntrySize * overflowNum;
#ifdef SIBLING_BASED_VALIDATION
constexpr uint32_t logicalLeafSize        = std::max(decodedLeafSize, leafMetadataSize + leafEntrySize * leafSpanSize);
#endif
#else
constexpr uint32_t decodedLeafSize        = leafMetadataSize + leafEntrySize * leafSpanSize;
#endif
constexpr uint32_t decodedInternalSize    = internalMetadataSize + internalEntrySize * internalSpanSize;
constexpr uint32_t transLeafSize     = (decodedLeafSize <= cachelineSize) ? decodedLeafSize : (cachelineSize + ADD_CACHELINE_VERSION_SIZE(decodedLeafSize - cachelineSize, versionSize));
constexpr uint32_t transInternalSize = decodedInternalSize <= cachelineSize ? decodedInternalSize : (cachelineSize + ADD_CACHELINE_VERSION_SIZE(decodedInternalSize - cachelineSize, versionSize));

// Allocation Size
constexpr uint32_t allocationLockSize = 16UL;  // round up lock_addr
constexpr uint32_t allocationLeafSize = transLeafSize + allocationLockSize;  // remain space for the lock
constexpr uint32_t allocationInternalSize = transInternalSize + allocationLockSize;
#ifdef SIBLING_BASED_VALIDATION
constexpr uint32_t logicalTransLeafSize = (logicalLeafSize <= cachelineSize) ? logicalLeafSize : (cachelineSize + ADD_CACHELINE_VERSION_SIZE(logicalLeafSize - cachelineSize, versionSize));
constexpr uint32_t rdmaBufLeafSize = logicalTransLeafSize + allocationLockSize;
#else
constexpr uint32_t rdmaBufLeafSize = allocationLeafSize;
#endif

// Rdma Buffer
constexpr int64_t  kPerThreadRdmaBuf  = rdmaBufferSize * GB / MAX_APP_THREAD;
constexpr int64_t  kPerCoroRdmaBuf    = kPerThreadRdmaBuf / MAX_CORO_NUM;
constexpr uint32_t bufferEntrySize    = ADD_CACHELINE_VERSION_SIZE(scatterMetadataSize + std::max(leafEntrySize, internalEntrySize), versionSize);
constexpr uint32_t bufferMetadataSize = ADD_CACHELINE_VERSION_SIZE(std::max(leafMetadataSize, internalMetadataSize), versionSize);
#ifdef ENABLE_VAR_LEN_KV
constexpr uint32_t bufferBlockSize    = dataBlockLen;
#else
constexpr uint32_t bufferBlockSize    = 0;
#endif

// On-chip Memory
constexpr uint64_t kLockStartAddr   = 0;
constexpr uint64_t kLockChipMemSize = ON_CHIP_SIZE * 1024;
constexpr uint64_t kLocalLockNum    = 4 * MB;  // tune to an appropriate value (as small as possible without affect the performance)
constexpr uint64_t kOnChipLockNum   = kLockChipMemSize * 8;  // 1bit-lock

// Greedy
constexpr uint64_t greedySizePerIO       = transLeafSize / 2;  // [TUNE]
constexpr uint32_t maxLeafEntryPerIO     = greedySizePerIO / leafEntrySize;
}


static inline unsigned long long asm_rdtsc(void) {
  unsigned hi, lo;
  __asm__ __volatile__("rdtsc" : "=a"(lo), "=d"(hi));
  return ((unsigned long long)lo) | (((unsigned long long)hi) << 32);
}

__inline__ unsigned long long rdtsc(void) {
  unsigned hi, lo;
  __asm__ __volatile__("rdtsc" : "=a"(lo), "=d"(hi));
  return ((unsigned long long)lo) | (((unsigned long long)hi) << 32);
}

inline void mfence() { asm volatile("mfence" ::: "memory"); }

inline void compiler_barrier() { asm volatile("" ::: "memory"); }

#endif /* __COMMON_H__ */
