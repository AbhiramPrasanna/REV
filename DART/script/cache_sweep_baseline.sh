#!/usr/bin/env bash
#
# cache_sweep_baseline.sh — BASELINE DART directory-cache sweep (no offloading).
#                           >>> RUN THIS ON THE COMPUTE HOST: 10.30.1.8 <<<
#
# Pure DART, in-memory microbench (test_func=1). There is NO offloading/pushdown
# knob in DART — that concept belongs to DEX (separate repo). This is the plain
# baseline: every inner/leaf miss is an RDMA round trip; the only lever is the
# compute-side directory cache.
#
# This is the COMPUTE side of a TWO-SCRIPT pair (DEX-style, no SSH needed):
#     10.30.1.8  ->  monitor + compute   ::  ./script/cache_sweep_baseline.sh        (THIS)
#     10.30.1.6  ->  memory              ::  ./script/cache_sweep_baseline_other.sh  (pair)
#
# The monitor (here) owns ALL workload/sizing flags and drives the matrix. For
# each configuration it relaunches monitor+compute locally; the memory node is
# supplied by the _other script over on 10.30.1.6, which loops in lockstep.
# The monitor blocks until BOTH memory and compute have connected, so start
# order across the two hosts does not matter — whichever waits, waits.
#
# Sweeps the compute-side directory cache over {64,128,256,512} MiB (TOTAL across
# all worker threads, so --th_b = size*1MiB / threads), for each combination of:
#     distribution : uniform, zipf-0.99
#     op mix       : 100% point lookup, 100% range scan
# 30M measured ops per configuration. 2 x 2 x 4 = 16 runs.
#
# HOW TO RUN (either order works; the monitor barrier syncs them):
#   1. on 10.30.1.6:  ./script/cache_sweep_baseline_other.sh
#   2. on 10.30.1.8:  ./script/cache_sweep_baseline.sh
#
# PREREQS:
#   * Build on BOTH hosts (same path): ./build.sh   (binaries in ./bin)
#   * Hugepages on both: sudo sysctl -w vm.nr_hugepages=16384
#   * Set CMP_NIC to this host's RDMA device index (see `ibv_devices`).
#   * ips[] in src/main/compute.cc must list the memory-node IP as ips[0]
#     (already "10.30.1.6" — no rebuild needed for this topology).
#
#   *** IMPORTANT: keep CACHE_TOTAL_MB / DISTS / OPS IDENTICAL in both scripts ***
#   so the run count matches and the two loops stay in lockstep.
#
set -u

# ----------------------------- cluster config ------------------------------
MONITOR_BIND="0.0.0.0:9898"     # monitor binds here (THIS host = 10.30.1.8)

CMP_NIC=0                       # compute-host (10.30.1.8) RDMA device index
IB_PORT=1

# Repo dir (this script lives in <repo>/script/).
DART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --------------------------- experiment config -----------------------------
MEMORY_NUM=1
COMPUTE_NUM=1
# Compute worker threads (load_thread_num == run_thread_num). Matched to DEX's
# 32 compute threads. This is now a SWEPT dimension, the DART analog of varying
# THREADS in the DEX scripts: add values to study thread scaling, e.g.
# THREADS_SET=(8 16 24 32). --th_b is recomputed per thread count so the TOTAL
# cache stays at the sweep value. (DART has no memory-side service threads to
# match DEX's MEMTHREADS=4 -- the MN does no CPU work; see COMPARISON.md sec 3.)
# *** KEEP THREADS_SET IDENTICAL in cache_sweep_baseline_other.sh ***
THREADS_SET=(34 36)
CORO=1
MEM_MB=8192                     # memory-node RDMA region (the disaggregated heap)
BUCKET=256
KEY_COUNT=50000000              # distinct keys = working set (matches DEX BULK=50M)
OP_COUNT=30000000               # 30M measured ops per run
VALUE_LEN=16
SCAN_LEN=100
TEST_FUNC=1                     # 1 = in-memory microbench

# The "directory cache" sweep: 64/128/256/512 MB total compute-side cache.
# KEEP THESE THREE ARRAYS IDENTICAL IN cache_sweep_baseline_other.sh.
CACHE_TOTAL_MB=(64 128 256 512)
DISTS=(uniform zipf99)
OPS=(lookup scan)

STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="$DART_DIR/cache_sweep_baseline_${STAMP}.csv"
LOGDIR="$DART_DIR/sweep_logs_baseline_${STAMP}"
mkdir -p "$LOGDIR"
echo "dist,op,cache_total_mb,th_bytes_per_thread,threads,key_count,op_count,throughput_mops,latency_us,p99_us,bandwidth_gbps" > "$OUT"

# ------------------------------ helpers ------------------------------------
strip_ansi() { sed -r 's/\x1B\[[0-9;?]*[A-Za-z]//g'; }

teardown() { sudo killall -9 monitor compute 2>/dev/null; }   # local only (no SSH)

run_one() {
    local dist="$1" op="$2" cache="$3" THREADS="$4"
    local tag="${dist}_${op}_${cache}MB_t${THREADS}"
    local mlog="$LOGDIR/monitor_${tag}.log"

    # The cache is per-thread; the sweep value is TOTAL. Use --th_b (exact bytes)
    # rather than --th_mb so small totals don't truncate to 0/1 MiB across threads.
    local th_b=$(( cache * 1048576 / THREADS ))

    local uniform theta read scan
    if [ "$dist" = "uniform" ]; then uniform=1; else uniform=0; fi
    theta=99
    if [ "$op" = "lookup" ]; then read=100; scan=0; else read=0; scan=100; fi

    echo "================================================================"
    echo ">>> $tag  (th_b=${th_b}/thread x ${THREADS} = ~${cache}MB total)"
    echo "================================================================"

    teardown                       # clear local stragglers from a prior failed run
    sleep 1

    # 1) monitor (background, THIS host) — owns all workload/sizing flags
    sudo "$DART_DIR/bin/monitor" \
        --monitor_addr="$MONITOR_BIND" \
        --memory_num=$MEMORY_NUM --compute_num=$COMPUTE_NUM \
        --load_thread_num=$THREADS --run_thread_num=$THREADS --coro_num=$CORO \
        --mem_mb=$MEM_MB --th_b=$th_b \
        --test_func=$TEST_FUNC --bucket=$BUCKET \
        --run_max_request=$OP_COUNT --payload_byte=$VALUE_LEN \
        --mb_read_pct=$read --mb_scan_pct=$scan \
        --mb_insert_pct=0 --mb_update_pct=0 --mb_remove_pct=0 \
        --mb_uniform=$uniform --mb_theta_x100=$theta \
        --mb_key_count=$KEY_COUNT --mb_scan_len=$SCAN_LEN \
        > "$mlog" 2>&1 &
    local mon_pid=$!
    sleep 2                        # let the monitor bind before nodes dial in

    # 2) compute node (THIS host, blocks until the run finishes). The memory node
    #    is launched by cache_sweep_baseline_other.sh on 10.30.1.6; the monitor
    #    barrier waits for both before the run begins.
    sudo "$DART_DIR/bin/compute" \
        --monitor_addr="$MONITOR_BIND" --nic_index=$CMP_NIC --ib_port=$IB_PORT \
        --numa_node_total_num=2 --numa_node_group=0 \
        > "$LOGDIR/compute_${tag}.log" 2>&1

    # 3) wait for the monitor to print the aggregate and exit
    wait "$mon_pid" 2>/dev/null

    # 4) parse results (strip ANSI color codes first)
    local thp lat ban p99 clog
    clog="$LOGDIR/compute_${tag}.log"
    thp=$(strip_ansi < "$mlog" | grep -oE 'Total throughput = [0-9.eE+-]+' | tail -1 | grep -oE '[0-9.eE+-]+$')
    lat=$(strip_ansi < "$mlog" | grep -oE 'Average latency = [0-9.eE+-]+'  | tail -1 | grep -oE '[0-9.eE+-]+$')
    ban=$(strip_ansi < "$mlog" | grep -oE 'Total bandwidth = [0-9.eE+-]+'  | tail -1 | grep -oE '[0-9.eE+-]+$')
    # p99 of ALL ops, from the [ALL OPS] block of the DART LATENCY BUCKETS report
    # (bench_stats.h; the "ALL" row right after the [ALL OPS] header).
    p99=$(strip_ansi < "$clog" 2>/dev/null | awk '
      /\[ALL OPS\]/{f=1; next}
      f && match($0,/p99=[ ]*[0-9.]+/){s=substr($0,RSTART,RLENGTH);gsub(/p99=[ ]*/,"",s);print s; exit}')
    echo "$dist,$op,$cache,$th_b,$THREADS,$KEY_COUNT,$OP_COUNT,${thp:-NA},${lat:-NA},${p99:-NA},${ban:-NA}" >> "$OUT"
    echo "    -> throughput=${thp:-NA} MOps  latency=${lat:-NA} us  p99=${p99:-NA} us  bw=${ban:-NA} Gbps  (log: $mlog)"

    teardown                       # clean slate for the next config
    sleep 2                        # let RDMA QPs / port 9898 release
}

# ------------------------------- the sweep ---------------------------------
echo "BASELINE DART cache sweep (COMPUTE side, 10.30.1.8) -> $OUT  (logs in $LOGDIR)"
echo ">>> Make sure cache_sweep_baseline_other.sh is running on 10.30.1.6 <<<"
for threads in "${THREADS_SET[@]}"; do
  for dist in "${DISTS[@]}"; do
    for op in "${OPS[@]}"; do
      for cache in "${CACHE_TOTAL_MB[@]}"; do
        run_one "$dist" "$op" "$cache" "$threads"
      done
    done
  done
done

# ---- summary over EVERY monitor log present (robust to partial / rerun) -----
# Re-parses whatever monitor_<dist>_<op>_<cache>MB_t<threads>.log files exist in
# LOGDIR, so you get one complete table even if interrupted or rerun in pieces.
SUM="$DART_DIR/cache_sweep_baseline_summary_${STAMP}.csv"
echo "dist,op,cache_mb,threads,throughput_mops,latency_us,p99_us,bandwidth_gbps" > "$SUM"
for threads in "${THREADS_SET[@]}"; do
 for dist in "${DISTS[@]}"; do
  for op in "${OPS[@]}"; do
    for cache in "${CACHE_TOTAL_MB[@]}"; do
      mlog="$LOGDIR/monitor_${dist}_${op}_${cache}MB_t${threads}.log"
      clog="$LOGDIR/compute_${dist}_${op}_${cache}MB_t${threads}.log"
      [ -f "$mlog" ] || continue
      thp=$(strip_ansi < "$mlog" | grep -oE 'Total throughput = [0-9.eE+-]+' | tail -1 | grep -oE '[0-9.eE+-]+$')
      lat=$(strip_ansi < "$mlog" | grep -oE 'Average latency = [0-9.eE+-]+'  | tail -1 | grep -oE '[0-9.eE+-]+$')
      ban=$(strip_ansi < "$mlog" | grep -oE 'Total bandwidth = [0-9.eE+-]+'  | tail -1 | grep -oE '[0-9.eE+-]+$')
      p99=$(strip_ansi < "$clog" 2>/dev/null | awk '
        /\[ALL OPS\]/{f=1; next}
        f && match($0,/p99=[ ]*[0-9.]+/){s=substr($0,RSTART,RLENGTH);gsub(/p99=[ ]*/,"",s);print s; exit}')
      echo "${dist},${op},${cache},${threads},${thp:-NA},${lat:-NA},${p99:-NA},${ban:-NA}" >> "$SUM"
    done
  done
 done
done

echo
echo "Sweep complete."
echo "Per-config CSV : $OUT"
echo "Summary table  : $SUM"
echo
column -t -s, "$SUM" 2>/dev/null || cat "$SUM"
