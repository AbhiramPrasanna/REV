#pragma once

// ===========================================================================
// bench_stats.h
//
// Lightweight, per-thread microbenchmark instrumentation for DEX.
//
// It adds two things on top of the existing throughput / RDMA counters:
//
//   1. 500 ns latency buckets.
//      Every executed operation is timed and dropped into a histogram whose
//      buckets are exactly 500 ns wide.  Buckets are kept per (thread, op-type,
//      class) so the hot path is lock-free and false-sharing free.
//
//   2. Remote-operation attribution.
//      DEX is a *path-aware* buffer cache: it caches leaf pages together with
//      the inner nodes on the path to them, so a hot lookup is served entirely
//      from local memory and issues *zero* remote operations.  We attribute the
//      remote work (one-sided RDMA read / write / CAS and RPC pushdown) of each
//      logical operation by snapshotting the per-thread DSM counters around the
//      operation.  An operation is classified LOCAL (a full cache hit on the
//      cached path) or REMOTE (it touched a memory node at least once), and the
//      latency histogram is split along that line so cache-hit vs cache-miss
//      tail latency can be read off directly.
//
// All of this compiles away when BENCH_LATENCY is undefined.
//
// NOTE: the remote-op snapshot relies on COUNT_RDMA being enabled in DSM.h
//       (it is, by default).  If COUNT_RDMA is off the LOCAL/REMOTE split is
//       still produced but every op is reported as LOCAL.
// ===========================================================================

#include "Common.h" // MAX_APP_THREAD

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

// Toggle the whole subsystem.  Comment out to remove every cycle of overhead.
#define BENCH_LATENCY 1

namespace bench {

// --------------------------------------------------------------------------
// 500 ns latency buckets
// --------------------------------------------------------------------------
// Bucket b covers the half-open interval [b*500ns, (b+1)*500ns).
// The final bucket is an overflow bucket that catches everything >= 1 ms.
constexpr uint64_t kBucketWidthNs = 500;
constexpr uint32_t kNumBuckets = 2000; // 2000 * 500ns = 1 ms tracked range
constexpr uint64_t kMaxTrackedNs = kBucketWidthNs * (kNumBuckets - 1);

// Operation classes recorded by the benchmark.
enum LatOp : int {
  OP_LOOKUP = 0,
  OP_INSERT,
  OP_UPDATE,
  OP_DELETE,
  OP_RANGE,
  OP_COUNT
};

// Whether an op stayed in the local path-aware cache or hit remote memory.
enum LatClass : int { CLS_LOCAL = 0, CLS_REMOTE, CLS_COUNT };

inline const char *op_name(int op) {
  static const char *n[OP_COUNT] = {"LOOKUP", "INSERT", "UPDATE", "DELETE",
                                    "RANGE"};
  return (op >= 0 && op < OP_COUNT) ? n[op] : "?";
}

inline const char *class_name(int cls) {
  static const char *n[CLS_COUNT] = {"LOCAL", "REMOTE"};
  return (cls >= 0 && cls < CLS_COUNT) ? n[cls] : "?";
}

// Per-thread statistics block, cache-line aligned to avoid false sharing on
// the benchmark hot path.
struct alignas(64) ThreadStats {
  // hist[op][class][bucket] -> number of ops landing in that 500ns bucket.
  uint64_t hist[OP_COUNT][CLS_COUNT][kNumBuckets];

  // Remote-op work attributed to this thread across the measured window.
  uint64_t remote_read;  // one-sided RDMA reads  (path / leaf cache fills)
  uint64_t remote_write; // one-sided RDMA writes (dirty flush / unswizzle)
  uint64_t remote_cas;   // RDMA compare-and-swap  (remote node locking)
  uint64_t remote_rpc;   // RPC pushdown to the memory node

  // Op classification counters.
  uint64_t ops_local;            // served fully from local cache
  uint64_t ops_remote;           // touched remote memory at least once
  uint64_t op_count[OP_COUNT];   // per-op-type executed count
  uint64_t op_remote[OP_COUNT];  // per-op-type ops that went remote
  uint64_t op_sum_ns[OP_COUNT];  // per-op-type latency sum (for mean)

  // Offloaded-task tracking (work pushed down to the memory node).
  uint64_t off_lookup;    // lookups served by RPC pushdown
  uint64_t off_scan;      // scan RPC round-trips
  uint64_t off_scan_kv;   // KV pairs returned by scan pushdown
  uint64_t off_scan_leaf; // leaves scanned remotely

  char pad[64];

  void clear() { std::memset(this, 0, sizeof(*this)); }

  inline void record(int op, int cls, uint64_t ns) {
    uint32_t b = static_cast<uint32_t>(ns / kBucketWidthNs);
    if (b >= kNumBuckets)
      b = kNumBuckets - 1;
    hist[op][cls][b]++;
    op_count[op]++;
    op_sum_ns[op] += ns;
    if (cls == CLS_REMOTE) {
      ops_remote++;
      op_remote[op]++;
    } else {
      ops_local++;
    }
  }
};

// Defined exactly once in test/newbench.cpp.
extern ThreadStats g_stats[MAX_APP_THREAD];

inline void clear_all() {
  for (int i = 0; i < MAX_APP_THREAD; ++i)
    g_stats[i].clear();
}

// --------------------------------------------------------------------------
// Aggregation / reporting
// --------------------------------------------------------------------------
struct Reporter {
  // Merge one (op, class) histogram across all threads in [0, nthreads).
  static uint64_t merge(const ThreadStats *st, int nthreads, int op, int cls,
                        std::vector<uint64_t> &out) {
    out.assign(kNumBuckets, 0);
    uint64_t total = 0;
    for (int t = 0; t < nthreads; ++t) {
      const uint64_t *h = st[t].hist[op][cls];
      for (uint32_t b = 0; b < kNumBuckets; ++b) {
        out[b] += h[b];
        total += h[b];
      }
    }
    return total;
  }

  // Merge across all op-types for a given class (or both classes if cls < 0).
  static uint64_t merge_all(const ThreadStats *st, int nthreads, int cls,
                            std::vector<uint64_t> &out) {
    out.assign(kNumBuckets, 0);
    uint64_t total = 0;
    for (int t = 0; t < nthreads; ++t) {
      for (int op = 0; op < OP_COUNT; ++op) {
        for (int c = 0; c < CLS_COUNT; ++c) {
          if (cls >= 0 && c != cls)
            continue;
          const uint64_t *h = st[t].hist[op][c];
          for (uint32_t b = 0; b < kNumBuckets; ++b) {
            out[b] += h[b];
            total += h[b];
          }
        }
      }
    }
    return total;
  }

  // Upper edge (ns) of the bucket holding the requested percentile.
  static uint64_t percentile(const std::vector<uint64_t> &b, uint64_t total,
                             double p) {
    if (total == 0)
      return 0;
    uint64_t target = static_cast<uint64_t>(p * total);
    uint64_t cum = 0;
    for (uint32_t i = 0; i < kNumBuckets; ++i) {
      cum += b[i];
      if (cum >= target)
        return static_cast<uint64_t>(i + 1) * kBucketWidthNs;
    }
    return kMaxTrackedNs;
  }

  static double mean_ns(const std::vector<uint64_t> &b, uint64_t total) {
    if (total == 0)
      return 0.0;
    // Use bucket midpoints for the histogram-based estimate.
    long double sum = 0;
    for (uint32_t i = 0; i < kNumBuckets; ++i)
      sum += static_cast<long double>(b[i]) *
             (i * kBucketWidthNs + kBucketWidthNs / 2.0L);
    return static_cast<double>(sum / total);
  }

  static void print_lat_row(const char *label, const std::vector<uint64_t> &b,
                            uint64_t total) {
    if (total == 0) {
      printf("  %-18s        (no samples)\n", label);
      return;
    }
    printf("  %-18s n=%-10lu mean=%8.2fus  p50=%7.2fus  p90=%7.2fus  "
           "p99=%7.2fus  p99.9=%7.2fus  max>=%6.2fus\n",
           label, (unsigned long)total, mean_ns(b, total) / 1000.0,
           percentile(b, total, 0.50) / 1000.0,
           percentile(b, total, 0.90) / 1000.0,
           percentile(b, total, 0.99) / 1000.0,
           percentile(b, total, 0.999) / 1000.0,
           percentile(b, total, 1.0) / 1000.0);
  }

  // Dump the raw, non-empty 500 ns buckets as a CDF (the headline artifact).
  static void print_buckets(const std::vector<uint64_t> &b, uint64_t total) {
    if (total == 0) {
      printf("  (no samples)\n");
      return;
    }
    printf("  %-22s %12s %10s %9s\n", "bucket [lo,hi) ns", "count", "pct",
           "cdf");
    uint64_t cum = 0;
    for (uint32_t i = 0; i < kNumBuckets; ++i) {
      if (b[i] == 0)
        continue;
      cum += b[i];
      uint64_t lo = static_cast<uint64_t>(i) * kBucketWidthNs;
      uint64_t hi = lo + kBucketWidthNs;
      if (i == kNumBuckets - 1)
        printf("  [%9lu, +inf)        %12lu %9.4f%% %8.4f%%\n",
               (unsigned long)lo, (unsigned long)b[i], 100.0 * b[i] / total,
               100.0 * cum / total);
      else
        printf("  [%9lu,%9lu) %12lu %9.4f%% %8.4f%%\n", (unsigned long)lo,
               (unsigned long)hi, (unsigned long)b[i], 100.0 * b[i] / total,
               100.0 * cum / total);
    }
  }

  // node_id / nthreads identify this compute node's threads in g_stats.
  // inner_miss / leaf_miss / rpc_total come from the path-aware cache so the
  // remote breakdown can show how much remote traffic is inner vs leaf.
  static void print(const ThreadStats *st, int nthreads, int node_id,
                    uint64_t inner_miss, uint64_t leaf_miss,
                    uint64_t cache_writes) {
    printf("\n==================== LATENCY BUCKETS (500 ns) "
           "[node %d] ====================\n",
           node_id);

    // Per-op-type latency summary (ALL / LOCAL / REMOTE).
    for (int op = 0; op < OP_COUNT; ++op) {
      std::vector<uint64_t> all, loc, rem;
      // ALL = LOCAL + REMOTE
      uint64_t n_loc = merge(st, nthreads, op, CLS_LOCAL, loc);
      uint64_t n_rem = merge(st, nthreads, op, CLS_REMOTE, rem);
      all.assign(kNumBuckets, 0);
      uint64_t n_all = 0;
      for (uint32_t i = 0; i < kNumBuckets; ++i) {
        all[i] = loc[i] + rem[i];
        n_all += all[i];
      }
      if (n_all == 0)
        continue;
      printf("[%s]\n", op_name(op));
      print_lat_row("ALL", all, n_all);
      print_lat_row("LOCAL (cache hit)", loc, n_loc);
      print_lat_row("REMOTE (miss/rpc)", rem, n_rem);
    }

    // Aggregate over every op type.
    std::vector<uint64_t> all, loc, rem;
    uint64_t n_loc = merge_all(st, nthreads, CLS_LOCAL, loc);
    uint64_t n_rem = merge_all(st, nthreads, CLS_REMOTE, rem);
    all.assign(kNumBuckets, 0);
    uint64_t n_all = 0;
    for (uint32_t i = 0; i < kNumBuckets; ++i) {
      all[i] = loc[i] + rem[i];
      n_all += all[i];
    }
    printf("[ALL OPS]\n");
    print_lat_row("ALL", all, n_all);
    print_lat_row("LOCAL (cache hit)", loc, n_loc);
    print_lat_row("REMOTE (miss/rpc)", rem, n_rem);

    // Headline artifact: the raw 500 ns bucket CDF over all operations.
    printf("\n----- 500 ns bucket CDF (all ops) [node %d] -----\n", node_id);
    print_buckets(all, n_all);

    // ---- Remote-operation tracking ----------------------------------------
    uint64_t rr = 0, rw = 0, rc = 0, rp = 0, ol = 0, orr = 0;
    for (int t = 0; t < nthreads; ++t) {
      rr += st[t].remote_read;
      rw += st[t].remote_write;
      rc += st[t].remote_cas;
      rp += st[t].remote_rpc;
      ol += st[t].ops_local;
      orr += st[t].ops_remote;
    }
    uint64_t total_ops = ol + orr;
    uint64_t total_remote = rr + rw + rc + rp;
    printf("\n----- REMOTE OPERATIONS [node %d] -----\n", node_id);
    printf("  ops total                = %lu\n", (unsigned long)total_ops);
    printf("  ops local  (cache hit)   = %lu (%.2f%%)\n", (unsigned long)ol,
           total_ops ? 100.0 * ol / total_ops : 0.0);
    printf("  ops remote (>=1 net op)  = %lu (%.2f%%)\n", (unsigned long)orr,
           total_ops ? 100.0 * orr / total_ops : 0.0);
    printf("  remote ops total         = %lu\n", (unsigned long)total_remote);
    printf("    rdma read              = %lu\n", (unsigned long)rr);
    printf("    rdma write             = %lu\n", (unsigned long)rw);
    printf("    rdma cas               = %lu\n", (unsigned long)rc);
    printf("    rpc pushdown           = %lu\n", (unsigned long)rp);
    printf("  remote ops / op          = %.4f\n",
           total_ops ? static_cast<double>(total_remote) / total_ops : 0.0);
    printf("  remote ops / remote op   = %.4f\n",
           orr ? static_cast<double>(total_remote) / orr : 0.0);

    // ---- Offloaded task tracking (pushed down to memory node) -------------
    // DEX can execute a lookup or a range scan *on the memory node* instead of
    // pulling the leaf page over RDMA. We track those offloaded tasks here,
    // both aggregated ("complete operations") and per worker thread.
    uint64_t t_off_lu = 0, t_off_sc = 0, t_off_kv = 0, t_off_lf = 0;
    for (int t = 0; t < nthreads; ++t) {
      t_off_lu += st[t].off_lookup;
      t_off_sc += st[t].off_scan;
      t_off_kv += st[t].off_scan_kv;
      t_off_lf += st[t].off_scan_leaf;
    }
    printf("\n----- OFFLOADED TASKS [node %d] -----\n", node_id);
    printf("  lookup pushdowns         = %lu\n", (unsigned long)t_off_lu);
    printf("  scan    pushdowns (RPC)  = %lu\n", (unsigned long)t_off_sc);
    printf("    kv pairs returned      = %lu\n", (unsigned long)t_off_kv);
    printf("    leaves scanned remotely= %lu\n", (unsigned long)t_off_lf);
    printf("    kv / scan pushdown     = %.2f\n",
           t_off_sc ? static_cast<double>(t_off_kv) / t_off_sc : 0.0);
    printf("    leaves / scan pushdown = %.2f\n",
           t_off_sc ? static_cast<double>(t_off_lf) / t_off_sc : 0.0);
    if (t_off_lu || t_off_sc) {
      printf("  per-thread breakdown (tid: lookups | scans | kv | leaves):\n");
      for (int t = 0; t < nthreads; ++t) {
        if (st[t].off_lookup == 0 && st[t].off_scan == 0)
          continue;
        printf("    t%-3d  %10lu | %10lu | %10lu | %10lu\n", t,
               (unsigned long)st[t].off_lookup, (unsigned long)st[t].off_scan,
               (unsigned long)st[t].off_scan_kv,
               (unsigned long)st[t].off_scan_leaf);
      }
    }

    // ---- Path-aware cache miss breakdown (inner vs leaf) ------------------
    // Because DEX caches inner nodes along the path, inner misses should be a
    // small fraction; leaf misses dominate the remote read traffic.
    uint64_t path_miss = inner_miss + leaf_miss;
    printf("\n----- PATH-AWARE CACHE MISSES [node %d] -----\n", node_id);
    printf("  inner-node read miss     = %lu (%.2f%%)\n",
           (unsigned long)inner_miss,
           path_miss ? 100.0 * inner_miss / path_miss : 0.0);
    printf("  leaf-node  read miss     = %lu (%.2f%%)\n",
           (unsigned long)leaf_miss,
           path_miss ? 100.0 * leaf_miss / path_miss : 0.0);
    printf("  total read miss          = %lu\n", (unsigned long)path_miss);
    printf("  cache writebacks         = %lu\n", (unsigned long)cache_writes);
    printf("============================================================="
           "============\n\n");
  }
};

} // namespace bench
