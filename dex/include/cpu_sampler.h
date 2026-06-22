#pragma once
// ===========================================================================
// cpu_sampler.h  --  per-node CPU utilization sampler (memory node vs compute
//                    node), via /proc. A detached background thread prints, every
//                    `interval` seconds:
//
//   [CPU <label>] process=<P>% of <N> cores  system=<S>%   (window <w>s)
//
//   * process% = (utime+stime delta) / (wall delta * online_cores) * 100
//                -> 100% means "all cores fully busy in THIS process".
//   * system%  = busy / (busy+idle) from /proc/stat over the window
//                -> whole-machine busy, including NIC softirq, other procs.
//
// WHY BOTH THIS *AND* the active-fraction trackers (remote_load.h):
//   DEX/DART busy-POLL the NIC, so on a working node process% pins near
//   100*cores even when the CPU is only spinning on the completion queue -- the
//   cores are "utilized" but no useful work is done. cpu_sampler shows that gross
//   utilization; remote_load.h's dir-thread "active %" shows the USEFUL fraction.
//   Read together:
//     - DART memory node: blocks on a socket -> process% ~ 0  (truly idle: all
//       data access is one-sided RDMA served by the NIC, zero MN CPU work).
//     - DEX  memory node, offload OFF: process% ~ 100*memThreads (dir-threads
//       spin) but USEFUL active% ~ 0   -> cores pegged, no work.
//     - DEX  memory node, offload ON : process% ~ 100*memThreads AND active% > 0
//       -> cores pegged AND doing real RPC work (the "remote load").
//     - compute node (both): process% ~ 100*threads (workers run index logic and
//       spin-wait on RDMA) -> this is the "compute load".
//   That is exactly the "NIC at 100% but work-done differs between memory and
//   compute" picture.
//
// Compiles away when CPU_SAMPLE is undefined.
// ===========================================================================
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <unistd.h>

#define CPU_SAMPLE 1

namespace cpusample {

#ifdef CPU_SAMPLE

inline long online_cpu() {
  long n = sysconf(_SC_NPROCESSORS_ONLN);
  return n > 0 ? n : 1;
}

// Process CPU seconds = (utime + stime) from /proc/self/stat.
inline double proc_cpu_sec() {
  FILE *f = fopen("/proc/self/stat", "r");
  if (!f) return 0.0;
  char buf[4096];
  if (!fgets(buf, sizeof(buf), f)) { fclose(f); return 0.0; }
  fclose(f);
  char *rp = strrchr(buf, ')'); // end of the (comm) field, which may have spaces
  if (!rp) return 0.0;
  unsigned long utime = 0, stime = 0;
  // After ')': state ppid pgrp session tty tpgid flags minflt cminflt majflt
  //            cmajflt utime stime ...   (utime is field 14, stime field 15)
  if (sscanf(rp + 2,
             "%*c %*d %*d %*d %*d %*d %*u %*lu %*lu %*lu %*lu %lu %lu",
             &utime, &stime) != 2)
    return 0.0;
  long hz = sysconf(_SC_CLK_TCK);
  if (hz <= 0) hz = 100;
  return double(utime + stime) / double(hz);
}

// Whole-machine busy / total jiffies from /proc/stat first line.
inline void system_jiffies(unsigned long long &busy, unsigned long long &total) {
  busy = total = 0;
  FILE *f = fopen("/proc/stat", "r");
  if (!f) return;
  char buf[512];
  if (fgets(buf, sizeof(buf), f) && !strncmp(buf, "cpu ", 4)) {
    unsigned long long v[10] = {0};
    int n = sscanf(buf + 4, "%llu %llu %llu %llu %llu %llu %llu %llu %llu %llu",
                   &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7], &v[8],
                   &v[9]);
    unsigned long long idle = (n > 3) ? v[3] + v[4] : 0; // idle + iowait
    for (int i = 0; i < n; ++i) total += v[i];
    busy = total - idle;
  }
  fclose(f);
}

inline std::atomic<bool> g_started{false};

inline void loop(std::string label, int interval_s) {
  long ncpu = online_cpu();
  double last_cpu = proc_cpu_sec();
  unsigned long long sb, st;
  system_jiffies(sb, st);
  struct timespec t0; clock_gettime(CLOCK_MONOTONIC, &t0);
  for (;;) {
    sleep(interval_s);
    struct timespec t1; clock_gettime(CLOCK_MONOTONIC, &t1);
    double wall = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    t0 = t1;
    double cpu = proc_cpu_sec();
    double dcpu = cpu - last_cpu; last_cpu = cpu;
    unsigned long long sb2, st2; system_jiffies(sb2, st2);
    double sysp = (st2 > st) ? 100.0 * double(sb2 - sb) / double(st2 - st) : 0.0;
    sb = sb2; st = st2;
    double procp = (wall > 0) ? 100.0 * dcpu / (wall * ncpu) : 0.0;
    printf("[CPU %-8s] process=%6.2f%% of %ld cores   system=%6.2f%%   (window %ds)\n",
           label.c_str(), procp, ncpu, sysp, interval_s);
    fflush(stdout);
  }
}

inline void start(const std::string &label, int interval_s = 2) {
  bool expected = false;
  if (g_started.compare_exchange_strong(expected, true))
    std::thread(loop, label, interval_s).detach();
}

#else // !CPU_SAMPLE
inline void start(const std::string &, int = 2) {}
#endif

} // namespace cpusample
