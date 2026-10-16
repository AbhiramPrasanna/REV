#pragma once

#include "../GlobalAddress.h"
#include "btree_node.h"

namespace cachepush {

// -1 means lookup failure, 0 means next global_address_ptr, 1 means find value
// result, 2 means find nothing
int lookup(GlobalAddress root, uint64_t dsm_base, Key k, Value &v_result,
           GlobalAddress &g_result) {
  auto node_id = root.nodeID;
  auto node = root;
  NodeBase *mem_node = reinterpret_cast<NodeBase *>(dsm_base + root.offset);
  while (mem_node->type == PageType::BTreeInner) {
    auto inner = static_cast<BTreeInner<Key> *>(mem_node);
    node = inner->children[inner->lowerBound(k)];
    if (node.nodeID != node_id) {
      g_result = node;
      return 0;
    } else {
      mem_node = reinterpret_cast<NodeBase *>(dsm_base + node.offset);
    }
  }

  BTreeLeaf<Key, Value> *leaf = static_cast<BTreeLeaf<Key, Value> *>(mem_node);
  if (!leaf->rangeValid(k)) {
    return -1;
  }

  unsigned pos = leaf->lowerBound(k);
  int ret = 2;
  if ((pos < leaf->count) && (leaf->data[pos].first == k)) {
    ret = 1;
    v_result = leaf->data[pos].second;
  }

  return ret;
}

// -1 means update failure because enterring wrong leaf node, 0 means failure
// because not enter into a leaf node, 1 means update value succeeds, 2 means
// update nothing
int update(GlobalAddress &root, uint64_t dsm_base, Key k, Value v_result) {
  auto node_id = root.nodeID;
  auto node = root;
  NodeBase *mem_node = reinterpret_cast<NodeBase *>(dsm_base + root.offset);
  while (mem_node->type == PageType::BTreeInner) {
    auto inner = static_cast<BTreeInner<Key> *>(mem_node);
    node = inner->children[inner->lowerBound(k)];
    if (node.nodeID != node_id) {
      return 0;
    } else {
      mem_node = reinterpret_cast<NodeBase *>(dsm_base + node.offset);
    }
  }

  BTreeLeaf<Key, Value> *leaf = static_cast<BTreeLeaf<Key, Value> *>(mem_node);
  if (!leaf->rangeValid(k)) {
    return -1;
  }

  unsigned pos = leaf->lowerBound(k);
  int ret = 2;
  if ((pos < leaf->count) && (leaf->data[pos].first == k)) {
    ret = 1;
    leaf->data[pos].second = v_result;
    root = leaf->remote_address;
  }

  return ret;
}

// -1 means insert failure because enterring wrong leaf node (-1 also means it
// needs to SMO), 0 means failure because not enter into a leaf node, 1 means
// insert value succeeds, 2 means update a existing value;
int insert(GlobalAddress &root, uint64_t dsm_base, Key k, Value v_result) {
  auto node_id = root.nodeID;
  auto node = root;
  NodeBase *mem_node = reinterpret_cast<NodeBase *>(dsm_base + root.offset);
  while (mem_node->type == PageType::BTreeInner) {
    auto inner = static_cast<BTreeInner<Key> *>(mem_node);
    node = inner->children[inner->lowerBound(k)];
    if (node.nodeID != node_id) {
      return 0;
    } else {
      mem_node = reinterpret_cast<NodeBase *>(dsm_base + node.offset);
    }
  }

  BTreeLeaf<Key, Value> *leaf = static_cast<BTreeLeaf<Key, Value> *>(mem_node);
  if (!leaf->rangeValid(k) || (leaf->count == leaf->maxEntries)) {
    return -1;
  }

  root = leaf->remote_address;
  bool insert_success = leaf->insert(k, v_result);
  if (insert_success) {
    return 1;
  }

  return 2;
}

// -1 means remove failure because enterring wrong leaf node, 0 means failure
// because not enter into a leaf node, 1 means remove value succeeds, 2 means
// remove nothing
int remove(GlobalAddress &root, uint64_t dsm_base, Key k) {
  auto node_id = root.nodeID;
  auto node = root;
  NodeBase *mem_node = reinterpret_cast<NodeBase *>(dsm_base + root.offset);
  while (mem_node->type == PageType::BTreeInner) {
    auto inner = static_cast<BTreeInner<Key> *>(mem_node);
    node = inner->children[inner->lowerBound(k)];
    if (node.nodeID != node_id) {
      return 0;
    } else {
      mem_node = reinterpret_cast<NodeBase *>(dsm_base + node.offset);
    }
  }

  BTreeLeaf<Key, Value> *leaf = static_cast<BTreeLeaf<Key, Value> *>(mem_node);
  if (!leaf->rangeValid(k)) {
    return -1;
  }

  auto flag = leaf->remove(k);
  int ret = flag ? 1 : 2;
  root = leaf->remote_address;
  return ret;
}

// Range-scan pushdown executed entirely on the memory node.
//
// `start` is the leaf (or subtree root) the compute node missed on. We walk it
// down to the leaf covering `k`, then scan forward across sibling leaves that
// live on THIS memory node, packing up to `max_num` KV pairs contiguously into
// `out`. This is the offload win: a single RPC can cover several leaves, so the
// compute node fetches the whole batch with ONE follow-up RDMA read of `out`
// instead of one read per leaf.
//
// Returns the number of KV pairs packed (>= 0). Sets `max_key` to the upper
// bound (max_limit_) of the last leaf visited so the caller knows where to
// resume, and `leaves_scanned` to how many leaves were touched here.
// Returns -1 if the entry leaf no longer covers `k` (stale -> caller retries),
// and 0 (with leaves_scanned == 0) if the data lives on another memory node.
// `cross` (optional): when the walk down reaches a child on another memory node,
// that child, so the compute node can carry the scan on there (DEX_PUSH_CHAIN).
int range_scan(GlobalAddress start, uint64_t dsm_base, Key k, int max_num,
               std::pair<Key, Value> *out, Key &max_key, int &leaves_scanned,
               GlobalAddress *cross = nullptr) {
  auto node_id = start.nodeID;
  leaves_scanned = 0;
  NodeBase *mem_node = reinterpret_cast<NodeBase *>(dsm_base + start.offset);

  // Walk down to the covering leaf (no-op if `start` is already a leaf).
  while (mem_node->type == PageType::BTreeInner) {
    auto inner = static_cast<BTreeInner<Key> *>(mem_node);
    auto child = inner->children[inner->lowerBound(k)];
    if (child.nodeID != node_id) {
      // Subtree continues on a different memory node; nothing to serve here.
      if (cross)
        *cross = child;
      return 0;
    }
    mem_node = reinterpret_cast<NodeBase *>(dsm_base + child.offset);
  }

  BTreeLeaf<Key, Value> *leaf = static_cast<BTreeLeaf<Key, Value> *>(mem_node);
  if (!leaf->rangeValid(k)) {
    return -1;
  }

  int cur = 0;
  Key start_key = k;
  std::pair<Key, Value> *cursor = out;
  while (true) {
    uint32_t got = leaf->range_scan(start_key, max_num - cur, cursor);
    cur += got;
    cursor += got;
    ++leaves_scanned;
    max_key = leaf->max_limit_;

    if (cur >= max_num)
      break;
    if (max_key == std::numeric_limits<Key>::max())
      break;

    // Follow the sibling chain only while it stays on this memory node.
    GlobalAddress nxt = leaf->next_leaf;
    if (nxt == GlobalAddress::Null() || nxt.nodeID != node_id)
      break;

    leaf = reinterpret_cast<BTreeLeaf<Key, Value> *>(
        reinterpret_cast<NodeBase *>(dsm_base + nxt.offset));
    start_key = max_key + 1;
  }

  return cur;
}

// DEX-C (DEX_PUSH_WRITES_LOCATE): walk from `start` down to the leaf covering `k`
// and return that leaf's address; the compute node then writes the leaf itself.
// Reads only. 1 = g_result is the leaf; 0 = the walk reached an inner node on
// another memory node (g_result = that node, where the walk can go on). A leaf
// on another memory node is returned as is: it is never read here.
int locate(GlobalAddress start, uint64_t dsm_base, Key k,
           GlobalAddress &g_result) {
  auto node_id = start.nodeID;
  GlobalAddress node = start;
  NodeBase *mem_node = reinterpret_cast<NodeBase *>(dsm_base + start.offset);
  while (mem_node->type == PageType::BTreeInner) {
    auto inner = static_cast<BTreeInner<Key> *>(mem_node);
    auto child = inner->children[inner->lowerBound(k)];
    if (inner->level == 1) { // children are leaves
      g_result = child;
      return 1;
    }
    if (child.nodeID != node_id) {
      g_result = child;
      return 0;
    }
    node = child;
    mem_node = reinterpret_cast<NodeBase *>(dsm_base + child.offset);
  }
  g_result = node; // `start` was the leaf
  return 1;
}

} // namespace cachepush