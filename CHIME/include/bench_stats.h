#pragma once

// ===========================================================================
// bench_stats.h  (CHIME)
//
// Per-thread microbenchmark instrumentation, ported from dex/include/bench_stats.h
// so CHIME's offload benchmark reports latency and throughput the SAME way DEX
// does. It lives entirely in the benchmark app -- it does NOT touch CHIME's
// index logic.
//
//   1. 500 ns latency buckets.
//      Every executed op is timed and dropped into a histogram of 500 ns buckets
//      (per thread / op-type / class) so the hot path is lock-free and false-
//      sharing free. Same bucket width and percentile logic as DEX.
//
//   2. DIRECT vs OFFLOAD attribution.
//      DEX splits ops LOCAL (cache hit, zero network) vs REMOTE. CHIME's offload
//      study cares about the analogous split: DIRECT (served by one-sided RDMA)
//      vs OFFLOAD (served by an RPC pushdown to the memory node). The app
//      snapshots CHIME's offload counters around each op -- exactly the way
//      newbench snapshots DEX's num_push_* counters -- and classifies the op by
//      whether an offload happened.
//
// Compiles away when BENCH_LATENCY is undefined.
// ===========================================================================

#include "Common.h" // MAX_APP_THREAD

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#define BENCH_LATENCY 1

namespace bench {

// Bucket b covers [b*500ns, (b+1)*500ns); the last bucket catches >= 1 ms.
constexpr uint64_t kBucketWidthNs = 500;
constexpr uint32_t kNumBuckets = 2000; // 2000 * 500ns = 1 ms tracked range
constexpr uint64_t kMaxTrackedNs = kBucketWidthNs * (kNumBuckets - 1);

enum LatOp : int {
  OP_LOOKUP = 0,
  OP_INSERT,
  OP_UPDATE,
  OP_RANGE,
  OP_COUNT
};

// DIRECT = one-sided RDMA path; OFFLOAD = RPC pushdown to the memory node.
enum LatClass : int { CLS_DIRECT = 0, CLS_OFFLOAD, CLS_COUNT };

inline const char *op_name(int op) {
  static const char *n[OP_COUNT] = {"LOOKUP", "INSERT", "UPDATE", "RANGE"};
  return (op >= 0 && op < OP_COUNT) ? n[op] : "?";
}

struct alignas(64) ThreadStats {
  uint64_t hist[OP_COUNT][CLS_COUNT][kNumBuckets];

  // Offloaded-task tracking (work pushed down to the memory node).
  uint64_t off_lookup;    // lookups served by RPC pushdown
  uint64_t off_scan;      // scan RPC round-trips
  uint64_t off_scan_kv;   // KV pairs returned by scan pushdown
  uint64_t off_scan_leaf; // leaves scanned remotely

  // Op classification counters.
  uint64_t ops_direct;
  uint64_t ops_offload;

  char pad[64];

  void clear() { std::memset(this, 0, sizeof(*this)); }

  inline void record(int op, int cls, uint64_t ns) {
    uint32_t b = static_cast<uint32_t>(ns / kBucketWidthNs);
    if (b >= kNumBuckets) b = kNumBuckets - 1;
    hist[op][cls][b]++;
    if (cls == CLS_OFFLOAD) ops_offload++;
    else ops_direct++;
  }
};

// Defined exactly once in test/offload_test.cpp.
extern ThreadStats g_stats[MAX_APP_THREAD];

inline void clear_all() {
  for (int i = 0; i < MAX_APP_THREAD; ++i) g_stats[i].clear();
}

struct Reporter {
  static uint64_t merge(const ThreadStats *st, int nthreads, int op, int cls,
                        std::vector<uint64_t> &out) {
    out.assign(kNumBuckets, 0);
    uint64_t total = 0;
    for (int t = 0; t < nthreads; ++t) {
      const uint64_t *h = st[t].hist[op][cls];
      for (uint32_t b = 0; b < kNumBuckets; ++b) { out[b] += h[b]; total += h[b]; }
    }
    return total;
  }

  static uint64_t merge_all(const ThreadStats *st, int nthreads, int cls,
                            std::vector<uint64_t> &out) {
    out.assign(kNumBuckets, 0);
    uint64_t total = 0;
    for (int t = 0; t < nthreads; ++t)
      for (int op = 0; op < OP_COUNT; ++op)
        for (int c = 0; c < CLS_COUNT; ++c) {
          if (cls >= 0 && c != cls) continue;
          const uint64_t *h = st[t].hist[op][c];
          for (uint32_t b = 0; b < kNumBuckets; ++b) { out[b] += h[b]; total += h[b]; }
        }
    return total;
  }

  // Upper edge (ns) of the bucket holding percentile p.
  static uint64_t percentile(const std::vector<uint64_t> &b, uint64_t total, double p) {
    if (total == 0) return 0;
    uint64_t target = static_cast<uint64_t>(p * total);
    uint64_t cum = 0;
    for (uint32_t i = 0; i < kNumBuckets; ++i) {
      cum += b[i];
      if (cum >= target) return static_cast<uint64_t>(i + 1) * kBucketWidthNs;
    }
    return kMaxTrackedNs;
  }

  static double mean_ns(const std::vector<uint64_t> &b, uint64_t total) {
    if (total == 0) return 0.0;
    long double sum = 0;
    for (uint32_t i = 0; i < kNumBuckets; ++i)
      sum += static_cast<long double>(b[i]) * (i * kBucketWidthNs + kBucketWidthNs / 2.0L);
    return static_cast<double>(sum / total);
  }

  static void print_lat_row(const char *label, const std::vector<uint64_t> &b, uint64_t total) {
    if (total == 0) { printf("  %-18s        (no samples)\n", label); return; }
    printf("  %-18s n=%-10lu mean=%8.2fus  p50=%7.2fus  p90=%7.2fus  "
           "p99=%7.2fus  p99.9=%7.2fus  max>=%6.2fus\n",
           label, (unsigned long)total, mean_ns(b, total) / 1000.0,
           percentile(b, total, 0.50) / 1000.0, percentile(b, total, 0.90) / 1000.0,
           percentile(b, total, 0.99) / 1000.0, percentile(b, total, 0.999) / 1000.0,
           percentile(b, total, 1.0) / 1000.0);
  }

  static void print_buckets(const std::vector<uint64_t> &b, uint64_t total) {
    if (total == 0) { printf("  (no samples)\n"); return; }
    printf("  %-22s %12s %10s %9s\n", "bucket [lo,hi) ns", "count", "pct", "cdf");
    uint64_t cum = 0;
    for (uint32_t i = 0; i < kNumBuckets; ++i) {
      if (b[i] == 0) continue;
      cum += b[i];
      uint64_t lo = static_cast<uint64_t>(i) * kBucketWidthNs;
      uint64_t hi = lo + kBucketWidthNs;
      if (i == kNumBuckets - 1)
        printf("  [%9lu, +inf)        %12lu %9.4f%% %8.4f%%\n",
               (unsigned long)lo, (unsigned long)b[i], 100.0 * b[i] / total, 100.0 * cum / total);
      else
        printf("  [%9lu,%9lu) %12lu %9.4f%% %8.4f%%\n", (unsigned long)lo,
               (unsigned long)hi, (unsigned long)b[i], 100.0 * b[i] / total, 100.0 * cum / total);
    }
  }

  static void print(const ThreadStats *st, int nthreads, int node_id) {
    printf("\n==================== LATENCY BUCKETS (500 ns) "
           "[node %d] ====================\n", node_id);

    for (int op = 0; op < OP_COUNT; ++op) {
      std::vector<uint64_t> all, dir, off;
      uint64_t n_dir = merge(st, nthreads, op, CLS_DIRECT, dir);
      uint64_t n_off = merge(st, nthreads, op, CLS_OFFLOAD, off);
      all.assign(kNumBuckets, 0);
      uint64_t n_all = 0;
      for (uint32_t i = 0; i < kNumBuckets; ++i) { all[i] = dir[i] + off[i]; n_all += all[i]; }
      if (n_all == 0) continue;
      printf("[%s]\n", op_name(op));
      print_lat_row("ALL", all, n_all);
      print_lat_row("DIRECT (1-sided)", dir, n_dir);
      print_lat_row("OFFLOAD (rpc)", off, n_off);
    }

    std::vector<uint64_t> all, dir, off;
    uint64_t n_dir = merge_all(st, nthreads, CLS_DIRECT, dir);
    uint64_t n_off = merge_all(st, nthreads, CLS_OFFLOAD, off);
    all.assign(kNumBuckets, 0);
    uint64_t n_all = 0;
    for (uint32_t i = 0; i < kNumBuckets; ++i) { all[i] = dir[i] + off[i]; n_all += all[i]; }
    printf("[ALL OPS]\n");
    print_lat_row("ALL", all, n_all);
    print_lat_row("DIRECT (1-sided)", dir, n_dir);
    print_lat_row("OFFLOAD (rpc)", off, n_off);

    printf("\n----- 500 ns bucket CDF (all ops) [node %d] -----\n", node_id);
    print_buckets(all, n_all);

    // ---- Offloaded task tracking (pushed down to memory node) -------------
    uint64_t t_lu = 0, t_sc = 0, t_kv = 0, t_lf = 0, t_dir = 0, t_off = 0;
    for (int t = 0; t < nthreads; ++t) {
      t_lu += st[t].off_lookup; t_sc += st[t].off_scan;
      t_kv += st[t].off_scan_kv; t_lf += st[t].off_scan_leaf;
      t_dir += st[t].ops_direct; t_off += st[t].ops_offload;
    }
    uint64_t total_ops = t_dir + t_off;
    printf("\n----- OFFLOADED TASKS [node %d] -----\n", node_id);
    printf("  ops total                = %lu\n", (unsigned long)total_ops);
    printf("  ops direct (1-sided)     = %lu (%.2f%%)\n", (unsigned long)t_dir,
           total_ops ? 100.0 * t_dir / total_ops : 0.0);
    printf("  ops offload (rpc)        = %lu (%.2f%%)\n", (unsigned long)t_off,
           total_ops ? 100.0 * t_off / total_ops : 0.0);
    printf("  lookup pushdowns         = %lu\n", (unsigned long)t_lu);
    printf("  scan   pushdowns (RPC)   = %lu\n", (unsigned long)t_sc);
    printf("    kv pairs returned      = %lu\n", (unsigned long)t_kv);
    printf("    leaves scanned remotely= %lu\n", (unsigned long)t_lf);
    printf("    kv / scan pushdown     = %.2f\n", t_sc ? (double)t_kv / t_sc : 0.0);
    printf("    leaves / scan pushdown = %.2f\n", t_sc ? (double)t_lf / t_sc : 0.0);
    printf("=============================================================="
           "===========\n\n");
  }
};

} // namespace bench
