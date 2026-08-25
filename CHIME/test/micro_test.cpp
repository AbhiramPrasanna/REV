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
// threads). Overridable via CHIME_LOADERS. The RANGE-specific flood was NOT the
// loader count -- point workloads build fine at 8 loaders -- it was warmup scans
// running on a half-built tree (fixed by the bulk_finish barrier in thread_run).
// Shuffled inserts (see generate_workload) scatter splits across the tree, so 8
// loaders stay low-contention -- point always built fine at 8. Lower this for the
// LEANEST spans (small fanout -> deep tree -> many splits) if you still see an
// intermittent insert-side masked-CAS wedge on the rdma-core port. Does not
// affect measured numbers.
int LOADER_NUM = 8;

extern volatile bool need_stop;
extern volatile bool need_clear[MAX_APP_THREAD];
extern int g_index_cache_mb;   // runtime index-cache size (MB); see Tree.cpp
#ifdef CACHE_LEAF_NODE
extern int g_leaf_cache_mb;    // runtime leaf-cache size (MB); see LeafCache.h
#endif

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
  // KEEP THE SHUFFLED ORDER. A global std::sort here backfires: CHIME's split is
  // not sequential-insert-aware, so sorted keys build an underfull "staircase"
  // tree taller than optimal (level 11 vs 9 at fanout 8) -> many more splits ->
  // many more concurrent (emulated) masked-CAS ops -> the RDMA flood at high
  // loader counts. Shuffled inserts fill nodes ~50%, give the optimal height, and
  // scatter splits across the tree, so 8 loaders stay low-contention (point always
  // built fine). The range-scan flood was the missing bulk->warmup barrier
  // (thread_run), not the insertion order.

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
    // Miss-gated range (mirrors the lookup path): always enter range_query, which
    // decides PER SCAN — on a COMPLETE cache miss and offload enabled it pushes
    // the whole scan down (range_query_offload); on a partial/full cache hit it
    // stays one-sided; with offload off (rate 0) it never offloads. The rate is
    // honoured inside range_query via should_offload, so the OFF/ON A/B is real.
    tree->range_query(k, k + (uint8_t)scan_range, ret);
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
std::atomic<int64_t> bulk_cnt{0};      // bulk-load completion barrier (see thread_run)
std::atomic<int64_t> warmup_cnt{0};
std::atomic_bool ready{false};
std::atomic<int> done_cnt{0};   // threads that finished their op quota
// 0 = op-bounded: run exactly opM*1e6 ops per node (DEX's time_based=0).
// 1 = time-bounded: cycle the array for TEST_EPOCH*TIME_INTERVAL seconds.
int g_time_based = 0;


void thread_bulk_load(int id) {
  // DEX-style SINGLE-NODE construction: exactly one node (the last one -- a
  // compute node, since node 0 is the memory node) builds the ENTIRE tree; every
  // other node loads nothing and waits at the bulk_finish barrier. This removes
  // ALL cross-node concurrency. On this one node we still run LOADER_NUM loader
  // threads in parallel (traversal + leaf writes overlap); the per-word lock in
  // DSM::cas_mask_sync serialises only same-word emulated masked-CAS, so the
  // split/lock protocol never races even without hardware masked atomics -- fast
  // AND correct. Keys stay SHUFFLED (CHIME's split is not sequential-insert-aware,
  // so a sorted load builds a taller, under-filled tree).
  if (dsm->getMyNodeID() != kNodeCount - 1) return;   // only the loader node builds
  int loaders = std::min(kThreadCount, LOADER_NUM);
  uint64_t total = (bulk_load_num + loaders - 1) / loaders, step = total / 10 + 1, done = 0;
  for (uint64_t i = id; i < bulk_load_num; i += loaders) {   // strided over the whole key set
    tree->insert(int2key(bulk_array[i]), randval(e));
    if (id == 0 && ++done % step == 0)
      printf("[bulk] loader node: %lu%% (%lu/%lu keys)\n", done * 100 / total, done, total);
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

  // 1b. BULK-LOAD BARRIER -- the tree must be FULLY built before ANY warmup/query.
  //     Without it the non-loader threads start warmup immediately on a half-built
  //     tree. For POINT that only misses (harmless); for RANGE the scan follows
  //     sibling-leaf pointers that concurrent splits are still mutating -> it
  //     chases a half-updated pointer to a garbage address -> the "Failed status"
  //     RDMA flood. That is the entire point-vs-range asymmetry. Mirror the warmup
  //     barrier: every thread checks in, node 0 does a cluster barrier, then all
  //     proceed together (both nodes' loads are now complete).
  bulk_cnt.fetch_add(1);
  if (id == 0) {
    while (bulk_cnt.load() != kThreadCount) ;
    dsm->barrier("bulk_finish");
    bulk_cnt.store(-1);
  }
  while (bulk_cnt.load() != -1) ;

  // 2. warmup (untimed) -- fills the CN cache. Now runs against a COMPLETE tree.
  uint64_t *my_warm = warmup_array + id * thread_warmup_num;
  for (uint64_t c = 0; c < thread_warmup_num; ++c) run_item(my_warm[c], nullptr);

  warmup_cnt.fetch_add(1);
  if (id == 0) {
    while (warmup_cnt.load() != kThreadCount) ;
    dsm->barrier("warm_finish");
    printf("node %d warmup done in %lds\n", dsm->getMyNodeID(),
           bench_timer.end() / 1000 / 1000 / 1000);
    // Reset boundary: exclude warmup from the measured numbers. (Warmup now runs
    // AFTER the bulk_finish barrier, i.e. against the fully-built tree, but it is
    // still untimed cache-fill.) Reset here so [CORRECTNESS]/latency reflect only
    // the measured phase.
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
  //    OP-BOUNDED by default (like DEX's time_based=0): each thread executes
  //    exactly thread_op_num items, so the run performs the requested opM ops
  //    per node rather than "whatever fits in TEST_EPOCH seconds". Set
  //    CHIME_TIME_BASED=1 to restore the old time-bounded behaviour (cycles the
  //    array until the epoch budget runs out).
  bench::ThreadStats &my_stats = bench::g_stats[tid];
  uint64_t *my_work = workload_array + id * thread_op_num;
  uint64_t cur = 0;
  for (uint64_t done = 0; !need_stop && (g_time_based || done < thread_op_num); ++done) {
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
  done_cnt.fetch_add(1);   // op-bounded: tell main this thread finished its quota
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
  if (const char *tb = getenv("CHIME_TIME_BASED")) g_time_based = atoi(tb);

  // CHIME_CACHE_MB is the TOTAL compute-side cache budget. Without leaf caching it
  // is all internal nodes; with it, part goes to leaves. The total is the axis the
  // DART comparison holds equal, so it must NOT grow when leaf caching turns on.
  const int total_cache_mb = g_index_cache_mb;

#ifdef CACHE_LEAF_NODE
  // ---- split the total between inner nodes and leaves ----------------------
  //   CHIME_LEAF_CACHE_MB   absolute leaf budget (wins if set)
  //   CHIME_LEAF_CACHE_PCT  else, percent of the total (default 50)
  // index + leaf == total, always. Sweeping the percentage at a fixed total is
  // how you find where the memory is best spent.
  if (leafcache::enabled()) {
    int leaf_mb;
    if (const char *lm = getenv("CHIME_LEAF_CACHE_MB")) leaf_mb = atoi(lm);
    else {
      int pct = 50;
      if (const char *lp = getenv("CHIME_LEAF_CACHE_PCT")) pct = atoi(lp);
      if (pct < 0) pct = 0;
      if (pct > 90) pct = 90;   // the descent still has to resolve locally
      leaf_mb = total_cache_mb * pct / 100;
    }
    if (leaf_mb < 0) leaf_mb = 0;
    if (leaf_mb > total_cache_mb - 1) leaf_mb = total_cache_mb - 1;
    g_leaf_cache_mb = leaf_mb;
    g_index_cache_mb = total_cache_mb - leaf_mb;
  }
#endif

  // One machine-readable line, on EVERY node (the index-cache line below is node-0
  // only). The sweep parses this into the summary CSV, so a cell always records the
  // split it actually ran -- a mis-set env var shows up as a number, not as an
  // unexplained result. index + leaf MUST equal total.
#ifdef CACHE_LEAF_NODE
  const int leaf_mb_report = g_leaf_cache_mb;
#else
  const int leaf_mb_report = 0;
#endif
  printf("[CACHE node %d] total=%d MB index=%d MB leaf=%d MB\n",
         dsm->getMyNodeID(), total_cache_mb, g_index_cache_mb, leaf_mb_report);
  if (dsm->getMyNodeID() == 0)
    printf("index cache = %d MB (CHIME_CACHE_MB)\n", g_index_cache_mb);
#ifdef CACHE_LEAF_NODE
  if (dsm->getMyNodeID() == 0)
    printf("[CONFIG] leaf cache = %s%s  (CHIME_CACHE_LEAF / CHIME_LEAF_CACHE_PCT)\n",
           leafcache::enabled() ? "ON" : "OFF",
           (leafcache::enabled() && leafcache::keep_speculative())
               ? ", stacked on the hotspot buffer" : "");
#endif

  // Printed on BOTH nodes on purpose: the memory node spawns this many dir
  // threads and the compute node shards RPCs over this many, so a mismatch makes
  // the compute node address a dir that nobody polls -- which shows up as a lock
  // "Deadlock" report rather than as a config error. Two lines to eyeball beats
  // debugging a phantom deadlock.
  printf("[CONFIG node %d] dir threads = %d (CHIME_DIR_THREADS, max %d)"
         " -- MUST match the other node\n",
         dsm->getMyNodeID(), chime::num_dir(), NR_DIRECTORY);

  // ---- [GEOMETRY] ---------------------------------------------------------
  // The cache-eviction experiment only means anything if (a) an internal node is
  // SMALLER than a leaf and (b) the index working set straddles the cache sweep.
  // Both are pure functions of the compile-time span/value knobs, so print them
  // rather than re-deriving them by hand. The index estimate below is a LOWER
  // bound: it assumes leaves are 100% full. Real bulk load leaves them partly
  // empty, so the true index is larger -- see the [TreeCache] "consumed cache
  // size" line printed after bulk load, which is the ground truth.
  if (dsm->getMyNodeID() == 0) {
    const double idx_per_leaf =
        (double)define::transInternalSize / (define::internalSpanSize - 1);
    const double leaves_full = (double)bulk_load_num / define::leafSpanSize;
    const double idx_mb_full = leaves_full * idx_per_leaf / define::MB;
    printf("[GEOMETRY] leaf    : span=%u val=%uB trans=%uB alloc=%uB\n"
           "[GEOMETRY] internal: span=%u        trans=%uB alloc=%uB\n"
           "[GEOMETRY] internal/leaf = %.2fx  (%s)\n"
           "[GEOMETRY] tree ~= %.2fM leaves * %uB = %.2f GB\n"
           "[GEOMETRY] index ~= %.1f MB (leaves 100%% full; TRUE value is HIGHER --\n"
           "[GEOMETRY]          read '[TreeCache] consumed cache size' below)\n",
           define::leafSpanSize, define::simulatedValLen,
           define::transLeafSize, define::allocationLeafSize,
           define::internalSpanSize,
           define::transInternalSize, define::allocationInternalSize,
           (double)define::transInternalSize / define::transLeafSize,
           define::transInternalSize < define::transLeafSize
               ? "OK: internal < leaf"
               : "WARNING: internal >= leaf",
           leaves_full / 1e6, define::transLeafSize,
           leaves_full * define::transLeafSize / define::GB,
           idx_mb_full);
  }

  tree = new Tree(dsm);
#ifdef ENABLE_OFFLOAD
  g_offload_rate = kOffloadRate;
  // Offload only lookups the cache could NOT fully resolve (level==1 means the
  // cache already produced the leaf address, and a one-sided read fetches it
  // with zero memory-node CPU). 1 restores the old offload-everything behaviour.
  if (const char *ml = getenv("CHIME_OFFLOAD_MIN_LEVEL"))
    g_offload_min_level = atoi(ml);
  if (dsm->getMyNodeID() == 0)
    printf("[CONFIG] offload rate = %d%%, min cache-boundary level = %d"
           " (%s)\n",
           g_offload_rate, g_offload_min_level,
           g_offload_min_level <= 1 ? "offload EVERY lookup, incl. cache hits"
                                    : "offload cache MISSES only");
#ifdef CACHE_LEAF_NODE
  // The two features are complementary and compose by construction at the default
  // min level: offload serves the index MISSES (the memory node walks the
  // remaining internals), the leaf cache serves the index HITS (level==1, where
  // the only remaining work was the leaf read). At min level 1 offload takes every
  // lookup and the leaf cache is never consulted -- say so rather than letting a
  // flat leaf hit-rate look like a broken cache.
  if (leafcache::enabled() && g_offload_min_level <= 1 && dsm->getMyNodeID() == 0)
    printf("[WARN] CHIME_OFFLOAD_MIN_LEVEL=1 offloads every lookup, so the leaf"
           " cache will never be consulted on the point path.\n");
#endif
#endif

  generate_workload();
  // Give the tree cache a random-key pool (bulk keys) for eviction victim
  // selection; without it getRandomKey() divides by zero once the cache fills.
  dsm->set_key_space(bulk_array, bulk_load_num);
  bench::clear_all();
  dsm->barrier("benchmark");

  for (int i = 0; i < kThreadCount; i++) th[i] = std::thread(thread_run, i);

  while (!ready.load()) ;

  // ---- ground truth for the cache sweep -----------------------------------
  // `ready` implies bulk load AND warmup are done, so the index cache is now as
  // populated as this workload will ever make it. TreeCache prints
  //   consumed cache size = cache_size - free_size
  // Run this ONCE with a cache far larger than the index (CHIME_CACHE_MB=1024)
  // and that number IS the true index working set -- no fill-factor guesswork.
  // Then pick the sweep so the index falls INSIDE it: points below evict, points
  // above fit. If free_size is ~0 / negative here, the cache is overflowing and
  // eviction IS running (which is the regime we want at 16/32/64MB).
  if (dsm->getMyNodeID() == 0) {
    printf("[INDEX] --- post-bulk-load cache occupancy (cache = %d MB) ---\n",
           g_index_cache_mb);
    tree->statistics();
  }

  timespec s, e2, t0_meas;
  uint64_t pre_tp = 0;
  int count = 0;
  clock_gettime(CLOCK_REALTIME, &t0_meas);
  clock_gettime(CLOCK_REALTIME, &s);
  while (!need_stop) {
    // NOTE: must be usleep, not sleep(). POSIX sleep() takes an unsigned int, so
    // sleep(TIME_INTERVAL) with TIME_INTERVAL=0.5 truncates to sleep(0) -- the
    // epochs then complete in microseconds, need_stop fires immediately, and the
    // measured phase records only a few hundred ops (garbage throughput and
    // percentiles). Stock ycsb_test gets away with sleep() only because its
    // TIME_INTERVAL is the integer 1.
    usleep((useconds_t)(TIME_INTERVAL * 1000000));
    clock_gettime(CLOCK_REALTIME, &e2);
    int us = (e2.tv_sec - s.tv_sec) * 1000000 + (double)(e2.tv_nsec - s.tv_nsec) / 1000;
    uint64_t all_tp = 0;
    for (int i = 0; i < MAX_APP_THREAD; ++i) all_tp += tp[i][0];
    clock_gettime(CLOCK_REALTIME, &s);

    uint64_t cap = all_tp - pre_tp;
    pre_tp = all_tp;
    double per_node_tp = cap * 1.0 / us;                          // Mops
    // NOTE: no dsm->sum() here. It is a collective that only returns a real
    // value on node 0 and reads each node's memcached key -- so once the nodes
    // run different epoch counts (which op-bounded mode guarantees) it silently
    // reads stale values. Each node now reports only its OWN rate, and the
    // cluster total is summed in post-processing from the [RESULT] lines.
    printf("%d, throughput %.4f Mops\n", dsm->getMyNodeID(), per_node_tp);
    ++count;

    if (g_time_based) {
      if (count >= TEST_EPOCH) need_stop = true;
    } else if (done_cnt.load() >= kThreadCount) {
      need_stop = true;              // every thread finished its op quota
    }
  }

  for (int i = 0; i < kThreadCount; i++) th[i].join();

  // Exact per-node result over the WHOLE measured phase (total ops / wall time),
  // rather than a noisy per-epoch sample. Cluster throughput = sum of the nodes'
  // [RESULT] lines (done in post-processing; see results/plot_offload.py).
  clock_gettime(CLOCK_REALTIME, &e2);
  double meas_s = (e2.tv_sec - t0_meas.tv_sec) +
                  (double)(e2.tv_nsec - t0_meas.tv_nsec) / 1e9;
  uint64_t total_ops = 0;
  for (int i = 0; i < MAX_APP_THREAD; ++i) total_ops += tp[i][0];
  printf("[RESULT node %d] ops=%lu elapsed=%.3fs throughput=%.4f Mops mode=%s\n",
         dsm->getMyNodeID(), (unsigned long)total_ops, meas_s,
         meas_s > 0 ? total_ops / meas_s / 1e6 : 0.0,
         g_time_based ? "time-bounded" : "op-bounded");

  bench::Reporter::print(bench::g_stats, kThreadCount, dsm->getMyNodeID());

  // Correctness signal (compare across OFFLOAD off vs on -- must be identical on
  // a static tree). Lookup found-ratio and scan rows/op.
  uint64_t lf = 0, lt = 0, sr = 0;
  for (int i = 0; i < kThreadCount; ++i) { lf += g_lk_found[i]; lt += g_lk_total[i]; sr += g_scan_rows[i]; }
  if (lt) printf("[CORRECTNESS node %d] lookup found %lu / %lu = %.4f%%\n",
                 dsm->getMyNodeID(), (unsigned long)lf, (unsigned long)lt, 100.0 * lf / lt);
  if (sr) printf("[CORRECTNESS node %d] scan rows returned = %lu\n",
                 dsm->getMyNodeID(), (unsigned long)sr);

  // Leaf-cache counters for the MEASURED phase only (the tree->statistics() call
  // above ran right after warmup, so its numbers describe the cache fill, not the
  // run). This is the [LEAFCACHE] line the sweep scripts parse.
  tree->leaf_cache_statistics();

  printf("[END]\n");
  dsm->barrier("fin");
  return 0;
}
