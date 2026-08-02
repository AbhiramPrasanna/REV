#!/usr/bin/env bash
#
# cache_sweep.sh — DART directory-cache sweep (in-memory microbench, test_func=1)
#
# Sweeps the compute-side cache over {32,64,128,256,512,1024} MiB (TOTAL across
# all worker threads, so --th_mb = size / threads), for each combination of:
#     distribution : uniform, zipf-0.99
#     op mix       : 100% point lookup, 100% range scan
# running 30M measured ops per configuration. That's 2 x 2 x 6 = 24 runs.
#
# DART has NO memcached. Each "configuration restart" = relaunch the one-shot
# monitor/memory/compute processes (they connect, run once, report, and exit).
#
# TOPOLOGY (edit below): monitor+memory on this host; compute over SSH.
#   10.30.1.6  ->  monitor + memory (memory node 0)   <- run this script here
#   10.30.1.7  ->  compute (compute node 0)           <- launched via SSH
#
# PREREQS:
#   * Build on BOTH hosts (same path): ./build.sh   (binaries in ./bin)
#   * Hugepages on both: sudo sysctl -w vm.nr_hugepages=16384
#   * Passwordless SSH from this host to $COMPUTE_HOST, identical repo path.
#   * Set MEM_NIC / CMP_NIC to your RDMA device index (see `ibv_devices`).
#   * ips[] in src/main/compute.cc must list the memory-node IP (already 10.30.1.6).
#
set -u

# ----------------------------- cluster config ------------------------------
MONITOR_BIND="0.0.0.0:9898"     # monitor binds here (this host)
MONITOR_DIAL="10.30.1.6:9898"   # memory/compute dial this
COMPUTE_HOST="10.30.1.7"        # SSH target for the compute node ("" = run local)
SSH="ssh"                       # ssh command ("" with COMPUTE_HOST="" => local)

MEM_NIC=0                       # memory-host RDMA device index (ibv_devices)
CMP_NIC=0                       # compute-host RDMA device index
IB_PORT=1

# Repo dir on BOTH hosts (this script lives in <repo>/script/).
DART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --------------------------- experiment config -----------------------------
MEMORY_NUM=1
COMPUTE_NUM=1
THREADS=56                      # load_thread_num == run_thread_num
CORO=1
MEM_MB=8192                     # memory-node RDMA region (the disaggregated heap)
BUCKET=256
KEY_COUNT=30000000              # distinct keys = working set
OP_COUNT=30000000               # 30M measured ops per run
VALUE_LEN=16
SCAN_LEN=100
TEST_FUNC=1                     # 1 = in-memory microbench

CACHE_TOTAL_MB=(32 64 128 256 512 1024)
DISTS=(uniform zipf99)
OPS=(lookup scan)

STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="$DART_DIR/cache_sweep_${STAMP}.csv"
LOGDIR="$DART_DIR/sweep_logs_${STAMP}"
mkdir -p "$LOGDIR"
echo "dist,op,cache_total_mb,th_bytes_per_thread,threads,key_count,op_count,throughput_mops,latency_us" > "$OUT"

# ------------------------------ helpers ------------------------------------
strip_ansi() { sed -r 's/\x1B\[[0-9;?]*[A-Za-z]//g'; }

teardown() {
    killall -9 monitor memory 2>/dev/null
    if [ -n "$COMPUTE_HOST" ]; then
        $SSH "$COMPUTE_HOST" 'killall -9 compute 2>/dev/null' 2>/dev/null
    else
        killall -9 compute 2>/dev/null
    fi
}

run_one() {
    local dist="$1" op="$2" cache="$3"
    local tag="${dist}_${op}_${cache}MB"
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

    teardown                       # clear stragglers from a prior failed run
    sleep 1

    # 1) monitor (background) — owns all workload/sizing flags, relays to compute
    "$DART_DIR/bin/monitor" \
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

    # 2) memory node (background, this host)
    "$DART_DIR/bin/memory" \
        --monitor_addr="$MONITOR_DIAL" --nic_index=$MEM_NIC --ib_port=$IB_PORT \
        > "$LOGDIR/memory_${tag}.log" 2>&1 &

    # 3) compute node (blocks until the run finishes)
    local cmp_cmd="cd '$DART_DIR' && ./bin/compute --monitor_addr=$MONITOR_DIAL --nic_index=$CMP_NIC --ib_port=$IB_PORT --numa_node_total_num=2 --numa_node_group=0"
    if [ -n "$COMPUTE_HOST" ]; then
        $SSH "$COMPUTE_HOST" "$cmp_cmd" > "$LOGDIR/compute_${tag}.log" 2>&1
    else
        bash -c "$cmp_cmd" > "$LOGDIR/compute_${tag}.log" 2>&1
    fi

    # 4) wait for the monitor to print the aggregate and exit
    wait "$mon_pid" 2>/dev/null

    # 5) parse results (strip ANSI color codes first)
    local thp lat
    thp=$(strip_ansi < "$mlog" | grep -oE 'Total throughput = [0-9.eE+-]+' | tail -1 | grep -oE '[0-9.eE+-]+$')
    lat=$(strip_ansi < "$mlog" | grep -oE 'Average latency = [0-9.eE+-]+'  | tail -1 | grep -oE '[0-9.eE+-]+$')
    echo "$dist,$op,$cache,$th_b,$THREADS,$KEY_COUNT,$OP_COUNT,${thp:-NA},${lat:-NA}" >> "$OUT"
    echo "    -> throughput=${thp:-NA} MOps  latency=${lat:-NA} us   (log: $mlog)"

    teardown                       # ensure a clean slate for the next config
    sleep 2                        # let RDMA QPs / port 9898 release
}

# ------------------------------- the sweep ---------------------------------
echo "DART cache sweep -> $OUT  (logs in $LOGDIR)"
for dist in "${DISTS[@]}"; do
  for op in "${OPS[@]}"; do
    for cache in "${CACHE_TOTAL_MB[@]}"; do
      run_one "$dist" "$op" "$cache"
    done
  done
done

echo
echo "Sweep complete. Results:"
column -t -s, "$OUT" 2>/dev/null || cat "$OUT"
