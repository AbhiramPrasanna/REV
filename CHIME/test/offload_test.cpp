// ===========================================================================
// offload_test.cpp
//
// CHIME RPC-OFFLOADING benchmark application.
//
// Same YCSB driver as ycsb_test, but point lookups and range scans are pushed
// down to the memory node (see chime_rpc.h / Directory.cpp / Tree.cpp), so the
// memory node does real per-op index work instead of only serving one-sided
// RDMA. Latency and throughput are measured EXACTLY like the DEX benchmark
// (newbench.cpp / bench_stats.h): 500 ns latency buckets with mean/p50/p90/
// p99/p99.9/max and a CDF, plus live per-epoch cluster throughput.
//
//   * throughput prints here, on the compute nodes;
//   * the memory node prints its dir-thread ACTIVE% every 2s (remote_load.h).
//
// This file and bench_stats.h are the ONLY instrumentation; CHIME's index logic
// is unchanged (the offload path itself is behind -DENABLE_OFFLOAD). Without
// that flag this still compiles and runs one-sided (baseline A/B).
//
// Usage:
//   ./offload_test kNodeCount kThreadCount kCoroCnt randint <a|b|c|d|e> \
//                  [offload_rate 0..100] [fix_range_size]
// ===========================================================================

#include "Tree.h"
#include "Timer.h"
#include "bench_stats.h"
#include <city.h>

#include <stdlib.h>
#include <thread>
#include <time.h>
#include <chrono>
#include <vector>
#include <iostream>
#include <string>
#include <fstream>
#include <random>

#ifdef SHORT_TEST_EPOCH
  #define TEST_EPOCH 5
  #define TIME_INTERVAL 0.2
#else
  #define TEST_EPOCH 10
  #define TIME_INTERVAL 0.5
#endif

#define MAX_THREAD_REQUEST 10000000
#define LOAD_HEARTBEAT 100000
#define LOADER_NUM 8

extern volatile bool need_stop;
extern volatile bool need_clear[MAX_APP_THREAD];

#ifdef ENABLE_OFFLOAD
extern uint64_t offload_lookup_cnt[MAX_APP_THREAD];
extern uint64_t offload_scan_cnt[MAX_APP_THREAD];
extern uint64_t offload_scan_kv[MAX_APP_THREAD];
extern uint64_t offload_scan_leaf[MAX_APP_THREAD];
#endif

// bench_stats histogram storage (defined exactly once here).
namespace bench { ThreadStats g_stats[MAX_APP_THREAD]; }

int kThreadCount;
int kNodeCount;
int kCoroCnt = 8;
bool kIsScan;
int kOffloadRate = 100;  // percent of point lookups pushed down
int fix_range_size = -1;

std::string ycsb_load_path;
std::string ycsb_trans_path;

std::thread th[MAX_APP_THREAD];
uint64_t tp[MAX_APP_THREAD][MAX_CORO_NUM];

std::default_random_engine e;
std::uniform_int_distribution<Value> randval(define::kValueMin, define::kValueMax);

Tree *tree;
DSM *dsm;

inline uint64_t key_hash(const Key &k) { return CityHash64((char *)&k, sizeof(k)); }


void work_func(Tree *tree, const Request &r, CoroPull *sink) {
  if (r.req_type == SEARCH) {
    Value v;
    tree->search(r.k, v, sink);  // offloads internally when ENABLE_OFFLOAD
  } else if (r.req_type == INSERT) {
    tree->insert(r.k, r.v, sink);
  } else if (r.req_type == UPDATE) {
    tree->update(r.k, r.v, sink);
  } else {  // SCAN
    std::map<Key, Value> ret;
#ifdef ENABLE_OFFLOAD
    tree->range_query_offload(r.k, r.k + r.range_size, ret);
#else
    tree->range_query(r.k, r.k + r.range_size, ret);
#endif
  }
}


Timer bench_timer;
std::atomic<int64_t> warmup_cnt{0};
std::atomic_bool ready{false};


void thread_load(int id) {
  uint64_t loader_id = std::min(kThreadCount, LOADER_NUM) * dsm->getMyNodeID() + id;
  printf("I am loader %lu\n", loader_id);

  std::string op;
  std::ifstream load_in(ycsb_load_path + std::to_string(loader_id));
  if (!load_in.is_open()) { printf("Error opening load file\n"); assert(false); }
  Key k;
  int cnt = 0;
  uint64_t int_k;
  while (load_in >> op >> int_k) {
    k = int2key(int_k);
    assert(op == "INSERT");
    tree->insert(k, randval(e));
    if (++cnt % LOAD_HEARTBEAT == 0) printf("loader %lu: %d loaded\n", loader_id, cnt);
  }
  printf("loader %lu load finish\n", loader_id);
}


void thread_run(int id) {
  bindCore(id * 2 + 1);
  dsm->registerThread();
  uint64_t my_id = kThreadCount * dsm->getMyNodeID() + id;
  printf("I am %lu\n", my_id);

  if (id == 0) bench_timer.begin();
  if (id < std::min(kThreadCount, LOADER_NUM)) thread_load(id);

  // load transaction requests
  Request *req = new Request[MAX_THREAD_REQUEST];
  int req_num = 0;
  std::ifstream trans_in(ycsb_trans_path + std::to_string(my_id));
  if (!trans_in.is_open()) { printf("Error opening trans file\n"); assert(false); }
  std::string op;
  int range_size = 0;
  uint64_t int_k;
  while (trans_in >> op >> int_k) {
    if (op == "SCAN") trans_in >> range_size; else range_size = 0;
    Request r;
    r.req_type = (op == "READ"   ? SEARCH : (
                  op == "INSERT" ? INSERT : (
                  op == "UPDATE" ? UPDATE : SCAN)));
    r.range_size = fix_range_size >= 0 ? fix_range_size : range_size;
    r.k = int2key(int_k);
    r.v = randval(e);
    req[req_num++] = r;
  }

  warmup_cnt.fetch_add(1);
  if (id == 0) {
    while (warmup_cnt.load() != kThreadCount) ;
    printf("node %d finish\n", dsm->getMyNodeID());
    dsm->barrier("warm_finish");
    printf("warmup time %lds\n", bench_timer.end() / 1000 / 1000 / 1000);
    ready = true;
    warmup_cnt.store(-1);
  }
  while (warmup_cnt.load() != -1) ;

  // run: time every op into 500 ns buckets, classify DIRECT vs OFFLOAD by
  // snapshotting CHIME's offload counters around the op (same technique as
  // newbench snapshotting DEX's num_push_* counters).
  auto thread_id = dsm->getMyThreadID();
  bench::ThreadStats &my_stats = bench::g_stats[thread_id];
  int cur = 0;
  while (!need_stop) {
    auto &r = req[cur];
    cur = (cur + 1) % req_num;

    int lat_op = (r.req_type == SEARCH ? bench::OP_LOOKUP : (
                  r.req_type == INSERT ? bench::OP_INSERT : (
                  r.req_type == UPDATE ? bench::OP_UPDATE : bench::OP_RANGE)));
#ifdef ENABLE_OFFLOAD
    uint64_t lu0 = offload_lookup_cnt[thread_id];
    uint64_t sc0 = offload_scan_cnt[thread_id];
    uint64_t kv0 = offload_scan_kv[thread_id];
    uint64_t lf0 = offload_scan_leaf[thread_id];
#endif
    auto t0 = std::chrono::high_resolution_clock::now();
    work_func(tree, r, nullptr);
    auto t1 = std::chrono::high_resolution_clock::now();
    uint64_t ns = std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count();

    int cls = bench::CLS_DIRECT;
#ifdef ENABLE_OFFLOAD
    uint64_t dlu = offload_lookup_cnt[thread_id] - lu0;
    uint64_t dsc = offload_scan_cnt[thread_id] - sc0;
    if (dlu > 0 || dsc > 0) cls = bench::CLS_OFFLOAD;
    my_stats.off_lookup    += dlu;
    my_stats.off_scan      += dsc;
    my_stats.off_scan_kv   += offload_scan_kv[thread_id] - kv0;
    my_stats.off_scan_leaf += offload_scan_leaf[thread_id] - lf0;
#endif
    my_stats.record(lat_op, cls, ns);
    tp[thread_id][0]++;
  }
}


void parse_args(int argc, char *argv[]) {
  if (argc < 6) {
    printf("Usage: ./offload_test kNodeCount kThreadCount kCoroCnt randint <a/b/c/d/e> "
           "[offload_rate 0..100] [fix_range_size]\n");
    exit(-1);
  }
  kNodeCount = atoi(argv[1]);
  kThreadCount = atoi(argv[2]);
  kCoroCnt = atoi(argv[3]);
  assert(std::string(argv[4]) == "randint");
  kIsScan = (std::string(argv[5]) == "e");
  if (argc >= 7) kOffloadRate = atoi(argv[6]);
  if (argc >= 8) fix_range_size = atoi(argv[7]);

  std::string workload_dir;
  std::ifstream workloads_dir_in("../workloads.conf");
  if (!workloads_dir_in.is_open()) { printf("Error opening workloads.conf\n"); assert(false); }
  workloads_dir_in >> workload_dir;
  ycsb_load_path  = workload_dir + "/load_" + std::string(argv[4]) + "_workload" + std::string(argv[5]);
  ycsb_trans_path = workload_dir + "/txn_"  + std::string(argv[4]) + "_workload" + std::string(argv[5]);

  printf("kNodeCount %d, kThreadCount %d, kCoroCnt %d, offload_rate %d%%\n",
         kNodeCount, kThreadCount, kCoroCnt, kOffloadRate);
#ifndef ENABLE_OFFLOAD
  printf("[WARN] built WITHOUT -DENABLE_OFFLOAD: running one-sided (baseline)\n");
#endif
}


int main(int argc, char *argv[]) {
  parse_args(argc, argv);

  DSMConfig config;
  assert(kNodeCount >= MEMORY_NODE_NUM);
  config.machineNR = kNodeCount;
  config.threadNR = kThreadCount;
  dsm = DSM::getInstance(config);
  bindCore(kThreadCount * 2 + 1);
  dsm->registerThread();
  tree = new Tree(dsm);
#ifdef ENABLE_OFFLOAD
  g_offload_rate = kOffloadRate;
#endif
  bench::clear_all();
  dsm->barrier("benchmark");

  for (int i = 0; i < kThreadCount; i++) th[i] = std::thread(thread_run, i);

  while (!ready.load()) ;
  timespec s, e2;
  uint64_t pre_tp = 0;
  int count = 0;
  clock_gettime(CLOCK_REALTIME, &s);
  while (!need_stop) {
    sleep(TIME_INTERVAL);
    clock_gettime(CLOCK_REALTIME, &e2);
    int us = (e2.tv_sec - s.tv_sec) * 1000000 + (double)(e2.tv_nsec - s.tv_nsec) / 1000;
    uint64_t all_tp = 0;
    for (int i = 0; i < MAX_APP_THREAD; ++i)
      for (int j = 0; j < kCoroCnt; ++j) all_tp += tp[i][j];
    clock_gettime(CLOCK_REALTIME, &s);

    uint64_t cap = all_tp - pre_tp;
    pre_tp = all_tp;
    double per_node_tp = cap * 1.0 / us;                         // Mops
    uint64_t cluster_tp = dsm->sum((uint64_t)(per_node_tp * 1000));

    printf("%d, throughput %.4f Mops\n", dsm->getMyNodeID(), per_node_tp);
    if (dsm->getMyNodeID() == 0)
      printf("epoch %d: cluster throughput %.3f Mops\n", ++count, cluster_tp / 1000.0);
    else
      ++count;
    if (count >= TEST_EPOCH) need_stop = true;
  }

  for (int i = 0; i < kThreadCount; i++) th[i].join();

  // DEX-style latency report (500 ns buckets + CDF + offload tasks).
  bench::Reporter::print(bench::g_stats, kThreadCount, dsm->getMyNodeID());

  printf("[END]\n");
  dsm->barrier("fin");
  return 0;
}
