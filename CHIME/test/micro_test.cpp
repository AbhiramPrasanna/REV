// ===========================================================================
// micro_test.cpp
//
// CHIME MICROBENCHMARK -- run the way DEX's newbench runs, NOT via YCSB files.
//
// The workload is generated IN CODE from a synthetic key distribution
// (uniform or Zipfian, same mehcached_zipf as DEX) with a configurable op mix,
// and executed in the DEX phase structure:
//
//     bulk-load  ->  warmup (untimed, fills the CN cache)  ->  measured run
//
// Latency + throughput are reported exactly like DEX (bench_stats.h: 500 ns
// buckets, p50/p90/p99/p99.9/max, CDF, offloaded-task tracking). Point lookups
// and range scans go through the RPC-offload path when built -DENABLE_OFFLOAD.
//
// This mirrors the four DEX microbenchmark cells:
//   Point/Range  x  Uniform/Zipf   (choose via ratios + uniform flag + theta).
//
// CHIME's index logic is untouched; this file + bench_stats.h are the only
// instrumentation.
//
// Usage:
//   ./micro_test kNodeCount kThreadCount \
//                readRatio insertRatio updateRatio rangeRatio \
//                uniform(1|0) zipf_theta bulkLoadM warmupM opM \
//                offload_rate [scan_range]
//
// Examples (2 nodes, 24 threads, 50M keys, 256MB cache configured at build):
//   Point-Uniform : ./micro_test 2 24 100 0 0 0   1 0     50 10 50 100
//   Point-Zipf    : ./micro_test 2 24 100 0 0 0   0 0.99  50 10 50 100
//   Range-Uniform : ./micro_test 2 24 0   0 0 100 1 0     50 10 10 100 100
//   Range-Zipf    : ./micro_test 2 24 0   0 0 100 0 0.99  50 10 10 100 100
// ===========================================================================

#include "Tree.h"
#include "Timer.h"
#include "bench_stats.h"
#include "zipf.h"
#include <city.h>

#include <stdlib.h>
#include <thread>
#include <time.h>
#include <chrono>
#include <vector>
#include <random>
#include <algorithm>
#include <iostream>
#include <string>

#ifdef SHORT_TEST_EPOCH
  #define TEST_EPOCH 5
  #define TIME_INTERVAL 0.2
#else
  #define TEST_EPOCH 10
  #define TIME_INTERVAL 0.5
#endif

// Bulk-load parallelism (setup only; the measured phase always uses kThreadCount
// threads). Overridable via CHIME_LOADERS -- lowering it reduces lock contention
// during bulk load, which sidesteps the intermittent masked-CAS-emulation wedge
// on the rdma-core port without affecting the measured numbers.
int LOADER_NUM = 8;

extern volatile bool need_stop;
extern volatile bool need_clear[MAX_APP_THREAD];
extern int g_index_cache_mb;   // runtime index-cache size (MB); see Tree.cpp

#ifdef ENABLE_OFFLOAD
extern uint64_t offload_lookup_cnt[MAX_APP_THREAD];
extern uint64_t offload_scan_cnt[MAX_APP_THREAD];
extern uint64_t offload_scan_kv[MAX_APP_THREAD];
extern uint64_t offload_scan_leaf[MAX_APP_THREAD];
#endif

namespace bench { ThreadStats g_stats[MAX_APP_THREAD]; }

// --- op encoding: op type packed in the top 8 bits of a 64-bit item ---------
enum MicroOp : uint8_t { M_LOOKUP = 0, M_INSERT, M_UPDATE, M_RANGE };
static const uint64_t kOpMask = (1ULL << 56) - 1;

int kNodeCount, kThreadCount;
int kReadRatio, kInsertRatio, kUpdateRatio, kRangeRatio;
int uniform_workload = 1;
double zipfian = 0.0;
uint64_t bulkLoadM, warmupM, opM;
int kOffloadRate = 100;
int scan_range = 100;               // key-span of a range scan (like fix_range_size)

uint64_t kKeySpace = 0;
uint64_t bulk_load_num = 0;
uint64_t thread_op_num = 0, thread_warmup_num = 0;
uint64_t node_op_num = 0, node_warmup_num = 0;

uint64_t *bulk_array = nullptr;
uint64_t *warmup_array = nullptr;   // node-local warmup items (op<<56 | key)
uint64_t *workload_array = nullptr; // node-local measured items

std::thread th[MAX_APP_THREAD];
uint64_t tp[MAX_APP_THREAD][MAX_CORO_NUM];

std::default_random_engine e;
std::uniform_int_distribution<Value> randval(define::kValueMin, define::kValueMax);

Tree *tree;
DSM *dsm;

inline uint64_t to_key(uint64_t x) { return (CityHash64((char *)&x, sizeof(x)) + 1) % kKeySpace; }


// ---- key generator (uniform or zipf), same as DEX's generate_range_key -----
struct zipf_gen_state zstate;
static std::mt19937_64 uni_gen(0x9e3779b97f4a7c15ull);  // workload gen is single-threaded
static void init_key_generator() {
  if (uniform_workload)
    uni_gen.seed(0x9e3779b97f4a7c15ull ^ ((uint64_t)dsm->getMyNodeID() << 32) ^ rdtsc());
  else
    mehcached_zipf_init(&zstate, kKeySpace, zipfian,
                        (rdtsc() & 0x0000ffffffffffffull) ^ dsm->getMyNodeID());
}
static uint64_t next_dist_key() {
  if (uniform_workload) return to_key(uni_gen());
  return to_key(mehcached_zipf_next(&zstate));
}


// Build the per-node warmup + measured item arrays with the requested op mix.
void generate_workload() {
  node_warmup_num = thread_warmup_num * kThreadCount;
  node_op_num     = thread_op_num * kThreadCount;

  // Shuffled key universe (fixed seed => identical on every node) -> bulk set.
  uint64_t *space = new uint64_t[kKeySpace];
  for (uint64_t i = 0; i < kKeySpace; ++i) space[i] = i;
  std::mt19937 gen(0xc70f6907UL);
  std::shuffle(&space[0], &space[kKeySpace - 1], gen);
  bulk_array = new uint64_t[bulk_load_num];
  memcpy(bulk_array, space, sizeof(uint64_t) * bulk_load_num);
  delete[] space;

  init_key_generator();

  auto insertmark = kReadRatio + kInsertRatio;
  auto updatemark = insertmark + kUpdateRatio;
  auto rangemark  = updatemark + kRangeRatio;
  assert(rangemark == 100);

  auto fill = [&](uint64_t *arr, uint64_t n) {
    std::mt19937 rng(0xB5297A4Du ^ (dsm->getMyNodeID() * 2654435761u));
    for (uint64_t i = 0; i < n; ++i) {
      uint64_t key = next_dist_key();
      uint32_t r = rng() % 100;
      uint64_t op = (r < (uint32_t)kReadRatio)   ? M_LOOKUP :
                    (r < (uint32_t)insertmark)   ? M_INSERT :
                    (r < (uint32_t)updatemark)   ? M_UPDATE : M_RANGE;
      arr[i] = (op << 56) | (key & kOpMask);
    }
  };

  warmup_array   = new uint64_t[node_warmup_num];
  workload_array = new uint64_t[node_op_num];
  fill(warmup_array, node_warmup_num);
  fill(workload_array, node_op_num);
  printf("workload generated: keyspace=%lu bulk=%lu warmup=%lu op=%lu\n",
         kKeySpace, bulk_load_num, node_warmup_num, node_op_num);
}


// Correctness signal: lookups found and scan rows returned, per thread. On a
// static (read-only) tree these MUST match between OFFLOAD off and on -- a
// mismatch means the offload traversal returned wrong results.
uint64_t g_lk_found[MAX_APP_THREAD] = {0};
uint64_t g_lk_total[MAX_APP_THREAD] = {0};
uint64_t g_scan_rows[MAX_APP_THREAD] = {0};

// Execute one packed item.
inline void run_item(uint64_t item, CoroPull *sink) {
  MicroOp op = static_cast<MicroOp>(item >> 56);
  Key k = int2key(item & kOpMask);
  if (op == M_LOOKUP) {
    Value v;
    bool f = tree->search(k, v, sink);
    int t = dsm->getMyThreadID();
    g_lk_total[t]++; if (f) g_lk_found[t]++;
  }
  else if (op == M_INSERT) { tree->insert(k, randval(e), sink); }
  else if (op == M_UPDATE) { tree->update(k, randval(e), sink); }
  else {
    std::map<Key, Value> ret;
#ifdef ENABLE_OFFLOAD
    tree->range_query_offload(k, k + (uint8_t)scan_range, ret);
#else
    tree->range_query(k, k + (uint8_t)scan_range, ret);
#endif
    g_scan_rows[dsm->getMyThreadID()] += ret.size();
  }
}
inline int item_lat_op(uint64_t item) {
  switch (static_cast<MicroOp>(item >> 56)) {
    case M_LOOKUP: return bench::OP_LOOKUP;
    case M_INSERT: return bench::OP_INSERT;
    case M_UPDATE: return bench::OP_UPDATE;
    default:       return bench::OP_RANGE;
  }
}


Timer bench_timer;
std::atomic<int64_t> warmup_cnt{0};
std::atomic_bool ready{false};


void thread_bulk_load(int id) {
  // Split this node's slice of the shuffled universe across loader threads.
  int loaders = std::min(kThreadCount, LOADER_NUM);
  uint64_t per_node = bulk_load_num / kNodeCount;
  uint64_t node_lo = per_node * dsm->getMyNodeID();
  uint64_t node_hi = (dsm->getMyNodeID() == kNodeCount - 1) ? bulk_load_num : node_lo + per_node;
  for (uint64_t i = node_lo + id; i < node_hi; i += loaders) {
    tree->insert(int2key(bulk_array[i]), randval(e));
  }
}


void thread_run(int id) {
  bindCore(id * 2 + 1);
  dsm->registerThread();
  auto tid = dsm->getMyThreadID();
  printf("I am %lu\n", (uint64_t)(kThreadCount * dsm->getMyNodeID() + id));

  if (id == 0) bench_timer.begin();

  // 1. bulk load
  if (id < std::min(kThreadCount, LOADER_NUM)) thread_bulk_load(id);

  // 2. warmup (untimed) -- fills the CN cache
  uint64_t *my_warm = warmup_array + id * thread_warmup_num;
  for (uint64_t c = 0; c < thread_warmup_num; ++c) run_item(my_warm[c], nullptr);

  warmup_cnt.fetch_add(1);
  if (id == 0) {
    while (warmup_cnt.load() != kThreadCount) ;
    dsm->barrier("warm_finish");
    printf("node %d warmup done in %lds\n", dsm->getMyNodeID(),
           bench_timer.end() / 1000 / 1000 / 1000);
    // Reset boundary: exclude warmup from the measured numbers. Warmup runs
    // while the tree is still bulk-loading (the 16 non-loader threads start it
    // immediately), so warmup lookups legitimately miss on an incomplete tree --
    // counting them tanks the found-ratio. Reset here so [CORRECTNESS] reflects
    // only the measured phase, against the fully-loaded tree.
    bench::clear_all();
    std::fill(g_lk_found, g_lk_found + MAX_APP_THREAD, 0);
    std::fill(g_lk_total, g_lk_total + MAX_APP_THREAD, 0);
    std::fill(g_scan_rows, g_scan_rows + MAX_APP_THREAD, 0);
    std::fill(need_clear, need_clear + MAX_APP_THREAD, true);
    ready = true;
    warmup_cnt.store(-1);
  }
  while (warmup_cnt.load() != -1) ;

  // 3. measured run -- time every op into 500 ns buckets, classify DIRECT vs
  //    OFFLOAD by snapshotting the offload counters (same as DEX/newbench).
  bench::ThreadStats &my_stats = bench::g_stats[tid];
  uint64_t *my_work = workload_array + id * thread_op_num;
  uint64_t cur = 0;
  while (!need_stop) {
    uint64_t item = my_work[cur];
    cur = (cur + 1) % thread_op_num;

    int lat_op = item_lat_op(item);
#ifdef ENABLE_OFFLOAD
    uint64_t lu0 = offload_lookup_cnt[tid], sc0 = offload_scan_cnt[tid];
    uint64_t kv0 = offload_scan_kv[tid], lf0 = offload_scan_leaf[tid];
#endif
    auto t0 = std::chrono::high_resolution_clock::now();
    run_item(item, nullptr);
    auto t1 = std::chrono::high_resolution_clock::now();
    uint64_t ns = std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count();

    int cls = bench::CLS_DIRECT;
#ifdef ENABLE_OFFLOAD
    uint64_t dlu = offload_lookup_cnt[tid] - lu0, dsc = offload_scan_cnt[tid] - sc0;
    if (dlu > 0 || dsc > 0) cls = bench::CLS_OFFLOAD;
    my_stats.off_lookup    += dlu;
    my_stats.off_scan      += dsc;
    my_stats.off_scan_kv   += offload_scan_kv[tid] - kv0;
    my_stats.off_scan_leaf += offload_scan_leaf[tid] - lf0;
#endif
    my_stats.record(lat_op, cls, ns);
    tp[tid][0]++;
  }
}


void parse_args(int argc, char *argv[]) {
  if (argc < 13) {
    printf("Usage: ./micro_test kNodeCount kThreadCount readRatio insertRatio "
           "updateRatio rangeRatio uniform(1|0) zipf_theta bulkLoadM warmupM "
           "opM offload_rate [scan_range]\n");
    exit(-1);
  }
  kNodeCount   = atoi(argv[1]);
  kThreadCount = atoi(argv[2]);
  kReadRatio   = atoi(argv[3]);
  kInsertRatio = atoi(argv[4]);
  kUpdateRatio = atoi(argv[5]);
  kRangeRatio  = atoi(argv[6]);
  uniform_workload = atoi(argv[7]);
  zipfian      = atof(argv[8]);
  bulkLoadM    = strtoull(argv[9], nullptr, 10);
  warmupM      = strtoull(argv[10], nullptr, 10);
  opM          = strtoull(argv[11], nullptr, 10);
  kOffloadRate = atoi(argv[12]);
  if (argc >= 14) scan_range = atoi(argv[13]);

  assert(kReadRatio + kInsertRatio + kUpdateRatio + kRangeRatio == 100);

  bulk_load_num = bulkLoadM * 1000000ull;
  thread_warmup_num = warmupM * 1000000ull / kThreadCount;
  thread_op_num     = opM * 1000000ull / kThreadCount;
  // headroom so inserts never exhaust fresh keys
  kKeySpace = bulk_load_num +
              (uint64_t)((opM + warmupM) * 1000000ull * (kInsertRatio / 100.0)) + 1000;
  assert(kKeySpace < (1ull << 56));

  printf("nodes %d, threads %d, mix R/I/U/S=%d/%d/%d/%d, %s%s, bulk %luM warmup %luM op %luM, offload %d%%, scan_range %d\n",
         kNodeCount, kThreadCount, kReadRatio, kInsertRatio, kUpdateRatio, kRangeRatio,
         uniform_workload ? "uniform" : "zipf-", uniform_workload ? "" : argv[8],
         (unsigned long)bulkLoadM, (unsigned long)warmupM, (unsigned long)opM,
         kOffloadRate, scan_range);
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
  // Runtime index-cache size (MB) for a rebuild-free cache sweep (DEX-style).
  if (const char *cm = getenv("CHIME_CACHE_MB")) g_index_cache_mb = atoi(cm);
  if (const char *ld = getenv("CHIME_LOADERS")) LOADER_NUM = atoi(ld);  // bulk-load threads
  if (dsm->getMyNodeID() == 0)
    printf("index cache = %d MB (CHIME_CACHE_MB)\n", g_index_cache_mb);
  tree = new Tree(dsm);
#ifdef ENABLE_OFFLOAD
  g_offload_rate = kOffloadRate;
#endif

  generate_workload();
  // Give the tree cache a random-key pool (bulk keys) for eviction victim
  // selection; without it getRandomKey() divides by zero once the cache fills.
  dsm->set_key_space(bulk_array, bulk_load_num);
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
    for (int i = 0; i < MAX_APP_THREAD; ++i) all_tp += tp[i][0];
    clock_gettime(CLOCK_REALTIME, &s);

    uint64_t cap = all_tp - pre_tp;
    pre_tp = all_tp;
    double per_node_tp = cap * 1.0 / us;                          // Mops
    uint64_t cluster_tp = dsm->sum((uint64_t)(per_node_tp * 1000));

    printf("%d, throughput %.4f Mops\n", dsm->getMyNodeID(), per_node_tp);
    if (dsm->getMyNodeID() == 0)
      printf("epoch %d: cluster throughput %.3f Mops\n", ++count, cluster_tp / 1000.0);
    else
      ++count;
    if (count >= TEST_EPOCH) need_stop = true;
  }

  for (int i = 0; i < kThreadCount; i++) th[i].join();
  bench::Reporter::print(bench::g_stats, kThreadCount, dsm->getMyNodeID());

  // Correctness signal (compare across OFFLOAD off vs on -- must be identical on
  // a static tree). Lookup found-ratio and scan rows/op.
  uint64_t lf = 0, lt = 0, sr = 0;
  for (int i = 0; i < kThreadCount; ++i) { lf += g_lk_found[i]; lt += g_lk_total[i]; sr += g_scan_rows[i]; }
  if (lt) printf("[CORRECTNESS node %d] lookup found %lu / %lu = %.4f%%\n",
                 dsm->getMyNodeID(), (unsigned long)lf, (unsigned long)lt, 100.0 * lf / lt);
  if (sr) printf("[CORRECTNESS node %d] scan rows returned = %lu\n",
                 dsm->getMyNodeID(), (unsigned long)sr);

  printf("[END]\n");
  dsm->barrier("fin");
  return 0;
}
