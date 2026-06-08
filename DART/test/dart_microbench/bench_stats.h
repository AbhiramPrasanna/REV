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
    static uint64_t pct(const std::vector<uint64_t>& cdf, uint64_t total,
                        double p) {
        uint64_t target = (uint64_t)(total * p);
        uint64_t acc = 0;
        for (uint64_t b = 0; b < kNumBuckets; ++b) {
            acc += cdf[b];
            if (acc >= target) return (b + 1) * kBucketWidthNs;
        }
        return kNumBuckets * kBucketWidthNs;
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

        auto dump = [&](int op, int net, const char* label) {
            const uint64_t* base = &m[(op * NET_N + net) * kNumBuckets];
            std::vector<uint64_t> v(base, base + kNumBuckets);
            uint64_t n = 0, sum_ns = 0;
            for (uint64_t b = 0; b < kNumBuckets; ++b) {
                n += v[b];
                sum_ns += v[b] * ((b + 1) * kBucketWidthNs);
            }
            if (!n) return;
            std::printf(
                "  %-18s n=%-10llu mean=%7.2fus p50=%6.2fus p99=%6.2fus "
                "p99.9=%6.2fus\n",
                label, (unsigned long long)n, sum_ns / 1000.0 / n,
                pct(v, n, 0.50) / 1000.0, pct(v, n, 0.99) / 1000.0,
                pct(v, n, 0.999) / 1000.0);
        };

        for (int op = 0; op < OP_N; ++op) {
            // skip op-types with no ops
            uint64_t any = 0;
            for (int net = 0; net < NET_N; ++net)
                for (uint64_t b = 0; b < kNumBuckets; ++b)
                    any += m[(op * NET_N + net) * kNumBuckets + b];
            if (!any) continue;
            std::printf("[%s]\n", op_name(op));
            dump(op, NET_LOCAL, "LOCAL (cache hit)");
            dump(op, NET_REMOTE, "REMOTE (>=1 rtt)");
        }

        for (int op = 0; op < OP_N; ++op) {
            for (uint64_t b = 0; b < kNumBuckets; ++b) {
                uint64_t l = m[(op * NET_N + NET_LOCAL) * kNumBuckets + b];
                uint64_t r = m[(op * NET_N + NET_REMOTE) * kNumBuckets + b];
                ops_total += l + r;
                ops_local += l;
                ops_remote += r;
            }
        }

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
