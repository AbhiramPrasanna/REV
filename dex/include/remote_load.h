#pragma once
// ===========================================================================
// remote_load.h
//
// "Remote CPU load" tracker for the DEX memory node.
//
// The memory-node directory threads BUSY-POLL the completion queue
// (Directory::dirThread: `while(true){ pollWithCQ(...); ... }`, pinned core),
// so their raw CPU utilization is pinned at ~100% whether or not there is any
// RPC work to do. Plain `top`/CPU% therefore tells you nothing about how loaded
// the memory side actually is.
//
// What is meaningful is the ACTIVE FRACTION: of the wall-clock time a directory
// thread spends in its poll loop, how much is spent INSIDE process_message
// (real index work serving an offloaded RPC) vs spinning on the NIC waiting for
// the next request. That fraction is the true "remote compute load":
//   * baseline / caching (rpc_rate=0): no RPCs arrive  -> active ~ 0%   (MN idle)
//   * offloading (rpc_rate>0):          RPCs arrive     -> active rises
//   * MN saturated:                     active -> ~100% per dir-thread, and the
//                                       aggregate caps at 100% * memThreadCount
//                                       (memThreadCount <= NR_DIRECTORY = 4).
//
// This is the metric that answers "can offloading get there faster, and at what
// point does adding memThreads stop mattering": adding dir-threads raises the
// aggregate ceiling only until the network or the compute node becomes the
// bottleneck, at which point per-thread active% falls and throughput flattens.
//
// Compiles away when REMOTE_LOAD is undefined.
// ===========================================================================

#include "Common.h" // NR_DIRECTORY

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <thread>

#define REMOTE_LOAD 1

namespace remoteload {

#ifdef REMOTE_LOAD

// Per-directory-thread active-time accumulator, cache-line isolated.
struct alignas(64) DirStat {
  std::atomic<uint64_t> active_ns{0}; // ns spent inside process_message
  std::atomic<uint64_t> msgs{0};      // RPC messages served
  char pad[64 - 2 * sizeof(std::atomic<uint64_t>)];
};

inline DirStat g_dir[NR_DIRECTORY];
inline std::atomic<bool> g_reporter_started{false};

inline uint64_t now_ns() {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

// Background reporter: every `interval_s` print each dir-thread's active% for
// that window (active_ns delta / wall delta) plus the aggregate. The memory
// node never reaches an explicit "end of run", so a periodic print is how its
// steady-state load is observed; in a per-config sweep the process is short so
// the steady value is the load for that configuration.
inline void reporter_loop(int n_dir, int interval_s) {
  uint64_t last_active[NR_DIRECTORY] = {0};
  uint64_t last_msgs[NR_DIRECTORY] = {0};
  auto last = std::chrono::steady_clock::now();
  for (;;) {
    std::this_thread::sleep_for(std::chrono::seconds(interval_s));
    auto cur = std::chrono::steady_clock::now();
    double wall_ns =
        std::chrono::duration_cast<std::chrono::nanoseconds>(cur - last)
            .count();
    last = cur;
    double tot_busy = 0;
    unsigned long long tot_msgs = 0;
    printf("\n----- REMOTE CPU LOAD (memory node dir-threads, %ds window) "
           "-----\n",
           interval_s);
    for (int d = 0; d < n_dir; ++d) {
      uint64_t a = g_dir[d].active_ns.load(std::memory_order_relaxed);
      uint64_t m = g_dir[d].msgs.load(std::memory_order_relaxed);
      double da = double(a - last_active[d]);
      unsigned long long dm = m - last_msgs[d];
      last_active[d] = a;
      last_msgs[d] = m;
      double busy = wall_ns > 0 ? 100.0 * da / wall_ns : 0.0;
      tot_busy += busy;
      tot_msgs += dm;
      printf("  dir %d: active=%6.2f%%  msgs=%-10llu  %.0f ns/msg\n", d, busy,
             dm, dm ? da / double(dm) : 0.0);
    }
    printf("  AGGREGATE active = %.2f%% (of %d dir-threads; %.2f%% per-thread "
           "avg)  msgs=%llu\n",
           tot_busy, n_dir, n_dir ? tot_busy / n_dir : 0.0, tot_msgs);
  }
}

inline void start_reporter(int n_dir, int interval_s = 2) {
  if (n_dir > NR_DIRECTORY)
    n_dir = NR_DIRECTORY;
  bool expected = false;
  if (g_reporter_started.compare_exchange_strong(expected, true))
    std::thread(reporter_loop, n_dir, interval_s).detach();
}

// RAII guard: wrap a single process_message() call to attribute its CPU time
// to directory `dir`.
struct ScopedActive {
  int dir;
  uint64_t t0;
  explicit ScopedActive(int d) : dir(d), t0(now_ns()) {}
  ~ScopedActive() {
    g_dir[dir].active_ns.fetch_add(now_ns() - t0, std::memory_order_relaxed);
    g_dir[dir].msgs.fetch_add(1, std::memory_order_relaxed);
  }
};

#else // !REMOTE_LOAD

struct ScopedActive {
  explicit ScopedActive(int) {}
};
inline void start_reporter(int, int = 2) {}

#endif // REMOTE_LOAD

} // namespace remoteload
