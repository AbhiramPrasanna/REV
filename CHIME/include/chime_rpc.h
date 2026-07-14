#pragma once
// ===========================================================================
// chime_rpc.h
//
// Memory-node (MN) side of CHIME's RPC OFFLOADING path. This is the CHIME
// analogue of dex/include/cache/btree_rpc.h: the compute node (CN) traverses
// the cached internal nodes as usual, and instead of RDMA-reading the leaf it
// pushes an RPC down to the MN. The MN, which has DIRECT LOCAL access to the
// DSM region, decodes the leaf in local memory, probes it, and returns the
// value (LOOKUP) or a packed batch of KV pairs across sibling leaves (SCAN).
//
// The offload win is identical to DEX's: for SCAN, a single RPC can cover
// several leaves and the CN fetches the whole batch with ONE follow-up RDMA
// read, instead of one read per leaf.
//
// WHY THIS IS MORE THAN A reinterpret_cast (unlike DEX):
//   DEX stores plain structs in DSM, so its MN just casts `dsm_base + offset`.
//   CHIME stores leaves version-ENCODED on the wire (interleaved per-cacheline
//   versions) and, with METADATA_REPLICATION, in a SCATTERED group layout. So
//   the MN must run CHIME's own decoders -- LeafVersionManager /
//   MetadataManager / VersionManager -- exactly as the CN does on an RDMA read
//   (Tree.cpp leaf_node_search / the !hopping_read fallback). Reusing those
//   headers keeps the MN byte-for-byte consistent with the CN and preserves
//   CHIME's version-based torn-read detection: a decode that returns false is a
//   concurrent one-sided writer, so we re-copy and retry (the MN equivalent of
//   the CN's `goto re_read`).
//
// Scope: point LOOKUP and range SCAN over the default full-CHIME build
// (HOPSCOTCH_LEAF_NODE + METADATA_REPLICATION + SIBLING_BASED_VALIDATION +
// SPECULATIVE_READ, inline fixed-length values). ENABLE_VAR_LEN_KV is not
// offloaded (the CN would need a second hop to resolve the DataBlock).
// ===========================================================================

#include "Common.h"
#include "GlobalAddress.h"
#include "Key.h"
#include "LeafNode.h"
#include "InternalNode.h"
#include "Metadata.h"
#include "VersionManager.h"
#include "LeafVersionManager.h"
#include "MetadataManager.h"

#include <algorithm>
#include <cstring>
#include <utility>

namespace chime_offload {

// A SCAN RPC packs its result into a per-requester scratch slot inside the MN's
// DSM region; the CN reads that slot back with one RDMA read. kScanSlotCap caps
// the KV pairs a single SCAN RPC returns; keep it small enough that the CN's
// range_buffer (kPerCoroRdmaBuf tail) and the MN scratch chunk both hold it.
static constexpr int kScanSlotCap = 512;
static constexpr uint64_t kScanSlotBytes =
    kScanSlotCap * sizeof(std::pair<Key, Value>);

// Give the version decoders the largest node footprint as scratch. On the MN
// there is no partial-read optimization to make -- memory is local -- so we
// always read+decode the WHOLE leaf, which is the exact code path the CN takes
// in its non-hopping fallback (Tree.cpp:447-454).
struct alignas(64) LeafScratch {
  char raw[define::allocationLeafSize];   // encoded, as it sits in DSM
  char inter[define::allocationLeafSize]; // decoded-but-scattered (metadata repl)
  char dec[define::allocationLeafSize];   // logical LeafNode
};

// Copy one leaf out of local DSM and decode it into a logical LeafNode.
// Returns false on a version mismatch (concurrent one-sided writer) -> retry.
inline bool read_leaf_local(char *dsm_base, GlobalAddress addr, LeafScratch &s,
                            LeafNode *&leaf) {
  std::memcpy(s.raw, dsm_base + addr.offset, define::transLeafSize);
#ifdef METADATA_REPLICATION
  if (!LeafVersionManager::decode_node_versions(s.raw, s.inter)) return false;
  MetadataManager::decode_node_metadata(s.inter, s.dec);
#else
  if (!VersionManager<LeafNode, LeafEntry>::decode_node_versions(s.raw, s.dec))
    return false;
#endif
  leaf = (LeafNode *)s.dec;
  return true;
}

inline bool sibling_on_this_node(const GlobalAddress &sib, uint16_t node_id) {
  return sib != GlobalAddress::Null() && sib != GlobalAddress::Widest() &&
         sib.nodeID == node_id;
}

// Scratch for decoding one internal node out of local DSM.
struct alignas(64) InternalScratch {
  char raw[define::allocationLeafSize];   // encoded internal, as it sits in DSM
  char dec[define::allocationLeafSize];   // logical InternalNode
};

// Copy one internal node out of local DSM and decode it into a logical
// InternalNode. false on a version mismatch (concurrent one-sided writer) -> retry.
inline bool read_internal_local(char *dsm_base, GlobalAddress addr,
                                InternalScratch &s, InternalNode *&node) {
  std::memcpy(s.raw, dsm_base + addr.offset, define::transInternalSize);
  if (!VersionManager<InternalNode, InternalEntry>::decode_node_versions(s.raw, s.dec))
    return false;
  node = (InternalNode *)s.dec;
  return true;
}

// Point lookup. `leaf_addr` is the leaf the CN resolved via its cached internal
// traversal. We probe it; if the key sorts past this leaf (a concurrent split
// pushed it right), follow the sibling chain -- CHIME keys only ever migrate
// rightward on split, so forward walking suffices. Mirrors leaf_node_search's
// full-record scan (Tree.cpp:1893) + turn-right (Tree.cpp:1861/1906).
//
// Returns 1 and sets `v_out` if found; 2 if not found.
inline int lookup(char *dsm_base, GlobalAddress leaf_addr, const Key &k,
                  Value &v_out) {
  static thread_local LeafScratch s;
  GlobalAddress addr = leaf_addr;
  for (int hops = 0; hops < 8; ++hops) {
    LeafNode *leaf = nullptr;
    for (int spin = 0; !read_leaf_local(dsm_base, addr, s, leaf); ++spin)
      if (spin > (1 << 22)) return 2; // give up on a pathological writer

    Key max_key = define::kkeyNull;
    for (int i = 0; i < (int)define::leafSpanSize; ++i) {
      const auto &e = leaf->records[i];
      if (e.key == define::kkeyNull) continue;
      if (e.key == k) {
        v_out = e.value;
        return 1;
      }
      if (max_key < e.key) max_key = e.key;
    }
    GlobalAddress sib = leaf->metadata.sibling_ptr;
    if (max_key < k && sibling_on_this_node(sib, addr.nodeID)) {
      addr = sib;
      continue; // turn right
    }
    return 2;
  }
  return 2;
}

// DEX-style lookup pushdown from the CN's CACHE BOUNDARY (not just the leaf).
// `node_addr`/`level` are the deepest node the CN's cache resolved; the MN walks
// the remaining internal nodes AND the leaf entirely in local DSM, collapsing
// what would have been (level-1) remote internal reads + the leaf read into ONE
// RPC. This is what makes offload beat one-sided as the cache shrinks -- the
// misses are served by the MN, mirroring DEX. Faithfully replays
// Tree::internal_node_search (Tree.cpp:387) then probes the leaf via lookup().
// Returns 1 (found, v_out set) or 2 (not found).
inline int lookup_from(char *dsm_base, GlobalAddress node_addr, int level,
                       const Key &k, Value &v_out) {
  static thread_local InternalScratch is;
  for (int hops = 0; hops < 64; ++hops) {   // bounded descent (height + turn-rights)
    if (level <= 1) return lookup(dsm_base, node_addr, k, v_out);  // leaf probe

    InternalNode *node = nullptr;
    for (int spin = 0; !read_internal_local(dsm_base, node_addr, is, node); ++spin)
      if (spin > (1 << 22)) return 2;       // pathological concurrent writer

    const auto &fk = node->metadata.fence_keys;
    if (k >= fk.highest) {                   // key migrated right (concurrent split)
      GlobalAddress sib = node->metadata.sibling_ptr;
      if (!sibling_on_this_node(sib, node_addr.nodeID)) return 2;
      node_addr = sib;
      continue;                              // re-read the sibling at the same level
    }

    level = node->metadata.level;            // same update as internal_node_search
    auto &records = node->records;
#ifdef UNORDERED_INTERNAL_NODE
    std::sort(records, records + define::internalSpanSize,
              [](const InternalEntry &a, const InternalEntry &b) {
                if (a.key == define::kkeyNull) return false;
                if (b.key == define::kkeyNull) return true;
                return a.key < b.key;
              });
#endif
    if (k < records[0].key) {
      node_addr = node->metadata.leftmost_ptr;
    } else {
      GlobalAddress child = records[define::internalSpanSize - 1].ptr;
      for (int i = 1; i < (int)define::internalSpanSize; ++i) {
        if (k < records[i].key || records[i].key == define::kkeyNull) {
          child = records[i - 1].ptr;
          break;
        }
      }
      node_addr = child;
    }
  }
  return 2;
}

// Range scan pushdown, executed entirely on the MN. Starting at `leaf_addr`
// (the leaf covering `from`), collect keys in [from, to) and walk the sibling
// chain that stays on THIS node, packing up to `max_num` pairs into `out`.
// CHIME leaves are hopscotch-hashed (unsorted within a leaf), so we gather then
// sort. Mirrors dex/btree_rpc.h::range_scan.
//
// Returns the number of pairs packed. Sets `max_key` to the largest key seen in
// the last leaf visited (the CN's resume boundary) and `leaves` to how many
// leaves were touched here.
inline int range_scan(char *dsm_base, GlobalAddress leaf_addr, const Key &from,
                      const Key &to, int max_num, std::pair<Key, Value> *out,
                      Key &max_key, int &leaves) {
  static thread_local LeafScratch s;
  if (max_num > kScanSlotCap) max_num = kScanSlotCap;
  leaves = 0;
  int cnt = 0;
  max_key = define::kkeyNull;
  GlobalAddress addr = leaf_addr;

  while (cnt < max_num) {
    LeafNode *leaf = nullptr;
    for (int spin = 0; !read_leaf_local(dsm_base, addr, s, leaf); ++spin)
      if (spin > (1 << 22)) break;
    if (leaf == nullptr) break;
    ++leaves;

    Key leaf_max = define::kkeyNull;
    for (int i = 0; i < (int)define::leafSpanSize; ++i) {
      const auto &e = leaf->records[i];
      if (e.key == define::kkeyNull) continue;
      if (leaf_max < e.key) leaf_max = e.key;
      if (!(e.key < from) && e.key < to && cnt < max_num)
        out[cnt++] = std::make_pair(e.key, e.value);
    }
    max_key = leaf_max;

    GlobalAddress sib = leaf->metadata.sibling_ptr;
    if (!(leaf_max < to)) break;                    // range fully covered
    if (!sibling_on_this_node(sib, addr.nodeID)) break;
    addr = sib;
  }

  std::sort(out, out + cnt,
            [](const std::pair<Key, Value> &a, const std::pair<Key, Value> &b) {
              return a.first < b.first;
            });
  return cnt;
}

} // namespace chime_offload
