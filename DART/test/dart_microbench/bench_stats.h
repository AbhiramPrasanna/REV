#pragma once
//
// dart_microbench/bench_stats.h
//
// Latency + LOCAL/REMOTE instrumentation for the DART microbenchmark, modeled
// on the DEX harness described in test/microbenchmarks.md (500 ns buckets,
// per-op-type histograms, network/local split).
//
// DART analog of DEX's per-op RDMA delta: DART increments the thread-local
// counter `rtt` (declared in src/prheart/art-node.cc) once per RDMA round trip
// inside every tree operation. So:
//     before op:  r0 = rtt;
//     run op
//     after  op:  remote = (rtt - r0) > 0;
// remote==false  => the op was served from the local cache path (LOCAL).
// remote==true   => the op issued >=1 RDMA round trip (REMOTE).
//
// Everything compiles away when BENCH_LATENCY is undefined.
//
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <vector>

#define BENCH_LATENCY 1

// The tree's per-thread round-trip counter (src/prheart/art-node.cc).
extern __thread uint64_t rtt;

namespace dart_bench {

enum OpClass { OP_READ = 0, OP_INSERT, OP_UPDATE, OP_SCAN, OP_REMOVE, OP_N };
enum NetClass { NET_LOCAL = 0, NET_REMOTE, NET_N };

static const char* op_name(int o) {
    static const char* n[OP_N] = {"READ", "INSERT", "UPDATE", "SCAN", "REMOVE"};
    return n[o];
}

#ifdef BENCH_LATENCY

constexpr uint64_t kBucketWidthNs = 500;
constexpr uint64_t kNumBuckets    = 2000;  // [0, 1ms), last bucket = >=1ms overflow

// Cache-line aligned per-thread block: lock-free, false-sharing-free hot path.
struct alignas(64) ThreadStats {
    // [op][class][bucket]
    std::vector<uint64_t> h;
    uint64_t remote_rtt = 0;  // total round trips attributed to this thread
    ThreadStats() : h(OP_N * NET_N * kNumBuckets, 0) {}

    inline void record(int op, int net, uint64_t ns) {
        uint64_t b = ns / kBucketWidthNs;
        if (b >= kNumBuckets) b = kNumBuckets - 1;
        h[(op * NET_N + net) * kNumBuckets + b]++;
    }
};

struct Registry {
    std::vector<ThreadStats*> threads;
    void enroll(ThreadStats* t) { threads.push_back(t); }
};
inline Registry& registry() { static Registry r; return r; }

// RAII timer + classifier for one operation. Usage inside an op lambda:
//     { dart_bench::ScopedOp _t(ts, dart_bench::OP_READ); tree.search(key); }
struct ScopedOp {
    ThreadStats& ts;
    int op;
    uint64_t r0;
    std::chrono::high_resolution_clock::time_point start;
    ScopedOp(ThreadStats& s, int o)
        : ts(s), op(o), r0(rtt),
          start(std::chrono::high_resolution_clock::now()) {}
    ~ScopedOp() {
        auto end = std::chrono::high_resolution_clock::now();
        uint64_t ns =
            std::chrono::duration_cast<std::chrono::nanoseconds>(end - start)
                .count();
        uint64_t dr = rtt - r0;
        ts.remote_rtt += dr;
        ts.record(op, dr > 0 ? NET_REMOTE : NET_LOCAL, ns);
    }
};

// Merge every enrolled thread and print the report (call once per node).
struct Reporter {
    // Upper edge (ns) of the bucket holding percentile p (p=1.0 -> max bucket).
    static uint64_t pct(const std::vector<uint64_t>& cdf, uint64_t total,
                        double p) {
        if (!total) return 0;
        uint64_t target = (uint64_t)(total * p);
        uint64_t acc = 0;
        for (uint64_t b = 0; b < kNumBuckets; ++b) {
            acc += cdf[b];
            if (acc >= target) return (b + 1) * kBucketWidthNs;
        }
        return kNumBuckets * kBucketWidthNs;
    }

    // mean via bucket midpoints (matches DEX's histogram-based estimate).
    static double mean_ns(const std::vector<uint64_t>& v, uint64_t total) {
        if (!total) return 0.0;
        long double sum = 0;
        for (uint64_t b = 0; b < kNumBuckets; ++b)
            sum += (long double)v[b] *
                   (b * kBucketWidthNs + kBucketWidthNs / 2.0L);
        return (double)(sum / total);
    }

    static void lat_row(const char* label, const std::vector<uint64_t>& v) {
        uint64_t n = 0;
        for (uint64_t b = 0; b < kNumBuckets; ++b) n += v[b];
        if (!n) {
            std::printf("  %-18s        (no samples)\n", label);
            return;
        }
        std::printf(
            "  %-18s n=%-10llu mean=%8.2fus  p50=%7.2fus  p90=%7.2fus  "
            "p99=%7.2fus  p99.9=%7.2fus  max>=%6.2fus\n",
            label, (unsigned long long)n, mean_ns(v, n) / 1000.0,
            pct(v, n, 0.50) / 1000.0, pct(v, n, 0.90) / 1000.0,
            pct(v, n, 0.99) / 1000.0, pct(v, n, 0.999) / 1000.0,
            pct(v, n, 1.0) / 1000.0);
    }

    // Headline artifact: raw, non-empty 500 ns buckets as count / pct / CDF.
    // This is the literal "number of operations in each 500 ns bucket".
    static void print_buckets(const std::vector<uint64_t>& v) {
        uint64_t total = 0;
        for (uint64_t b = 0; b < kNumBuckets; ++b) total += v[b];
        if (!total) {
            std::printf("  (no samples)\n");
            return;
        }
        std::printf("  %-22s %12s %10s %9s\n", "bucket [lo,hi) ns", "count",
                    "pct", "cdf");
        uint64_t cum = 0;
        for (uint64_t i = 0; i < kNumBuckets; ++i) {
            if (!v[i]) continue;
            cum += v[i];
            uint64_t lo = i * kBucketWidthNs, hi = lo + kBucketWidthNs;
            if (i == kNumBuckets - 1)
                std::printf("  [%9llu, +inf)        %12llu %9.4f%% %8.4f%%\n",
                            (unsigned long long)lo, (unsigned long long)v[i],
                            100.0 * v[i] / total, 100.0 * cum / total);
            else
                std::printf("  [%9llu,%9llu) %12llu %9.4f%% %8.4f%%\n",
                            (unsigned long long)lo, (unsigned long long)hi,
                            (unsigned long long)v[i], 100.0 * v[i] / total,
                            100.0 * cum / total);
        }
    }

    static void print(int node = 0) {
        // merged[op][net][bucket]
        std::vector<uint64_t> m(OP_N * NET_N * kNumBuckets, 0);
        uint64_t remote_rtt = 0;
        for (auto* t : registry().threads) {
            for (size_t i = 0; i < m.size(); ++i) m[i] += t->h[i];
            remote_rtt += t->remote_rtt;
        }

        std::printf(
            "\n========= DART LATENCY BUCKETS (500 ns) [node %d] =========\n",
            node);
        uint64_t ops_total = 0, ops_local = 0, ops_remote = 0;

        // Extract one merged (op,net) bucket vector; net<0 => LOCAL+REMOTE.
        auto vec = [&](int op, int net) {
            std::vector<uint64_t> v(kNumBuckets, 0);
            for (int c = 0; c < NET_N; ++c) {
                if (net >= 0 && c != net) continue;
                const uint64_t* base = &m[(op * NET_N + c) * kNumBuckets];
                for (uint64_t b = 0; b < kNumBuckets; ++b) v[b] += base[b];
            }
            return v;
        };

        // Per-op-type latency summary (ALL / LOCAL / REMOTE), like DEX.
        for (int op = 0; op < OP_N; ++op) {
            std::vector<uint64_t> all = vec(op, -1);
            uint64_t any = 0;
            for (uint64_t b = 0; b < kNumBuckets; ++b) any += all[b];
            if (!any) continue;
            std::printf("[%s]\n", op_name(op));
            lat_row("ALL", all);
            lat_row("LOCAL (cache hit)", vec(op, NET_LOCAL));
            lat_row("REMOTE (>=1 rtt)", vec(op, NET_REMOTE));
        }

        // Aggregate over every op type.
        std::vector<uint64_t> agg_all(kNumBuckets, 0), agg_loc(kNumBuckets, 0),
            agg_rem(kNumBuckets, 0);
        for (int op = 0; op < OP_N; ++op) {
            std::vector<uint64_t> l = vec(op, NET_LOCAL),
                                  r = vec(op, NET_REMOTE);
            for (uint64_t b = 0; b < kNumBuckets; ++b) {
                agg_loc[b] += l[b];
                agg_rem[b] += r[b];
                agg_all[b] += l[b] + r[b];
                ops_total += l[b] + r[b];
                ops_local += l[b];
                ops_remote += r[b];
            }
        }
        std::printf("[ALL OPS]\n");
        lat_row("ALL", agg_all);
        lat_row("LOCAL (cache hit)", agg_loc);
        lat_row("REMOTE (>=1 rtt)", agg_rem);

        // Headline: the raw 500 ns bucket CDF over all operations.
        std::printf("\n----- 500 ns bucket CDF (all ops) [node %d] -----\n",
                    node);
        print_buckets(agg_all);

        std::printf("\n----- LOCAL / REMOTE [node %d] -----\n", node);
        if (ops_total) {
            std::printf("  ops total                = %llu\n",
                        (unsigned long long)ops_total);
            std::printf("  ops local  (cache hit)   = %llu (%.2f%%)\n",
                        (unsigned long long)ops_local,
                        100.0 * ops_local / ops_total);
            std::printf("  ops remote (>=1 rtt)     = %llu (%.2f%%)\n",
                        (unsigned long long)ops_remote,
                        100.0 * ops_remote / ops_total);
            std::printf("  remote round trips       = %llu\n",
                        (unsigned long long)remote_rtt);
            std::printf("  rtt / op                 = %.4f\n",
                        (double)remote_rtt / ops_total);
        }
    }
};

#else  // !BENCH_LATENCY

struct ThreadStats {};
struct ScopedOp { ScopedOp(ThreadStats&, int) {} };
inline struct { void enroll(ThreadStats*) {} } registry();
struct Reporter { static void print(int = 0) {} };

#endif  // BENCH_LATENCY

}  // namespace dart_bench
