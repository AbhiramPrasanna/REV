#!/usr/bin/env bash
#
# cache_sweep_compare.sh — DART cache sweep, MATCHED to CHIME for a fair overlay
#
# This is script/cache_sweep.sh pinned to the SAME comparison contract CHIME's
# run_cache_stress.sh uses, so the two CSVs can be overlaid by compare_chime_dart.py:
#
#   held equal to CHIME:
#     cache budget   64, 128, 256, 512 MB  (TOTAL across threads;
#                    --th_b = total/threads). These are the points CHIME's
#                    run_leaf_cache.sh sweeps, and on the CHIME side the total is
#                    SPLIT between its inner-node cache and its leaf cache rather
#                    than grown -- so at every point both systems occupy the same
#                    compute-side memory. Override with CACHE_TOTAL_MB="64 32 16"
#                    to reproduce the older cache-STRESS overlay instead.
#     dataset        30M distinct u64 keys, 48-byte values
#                    -> same LOGICAL tree/data on the memory node as CHIME
#                       (BULK=30, keyLen=8, simulatedValLen=48)
#     workloads      point(lookup) & range(scan) x uniform & zipf-0.99, scan_len=100
#     threads        matched to CHIME's app-thread count (THREADS)
#
#   NOT equalizable (structural, documented -- this is what we are measuring):
#     DART is a radix tree (ART/prheart); CHIME is a B+-tree. There is no single
#     "inner node size" that equals a B+-tree span, so we do NOT try to match it.
#     We hold the DATASET + CACHE BUDGET + WORKLOAD equal and let the index
#     structure differ -- that difference is the comparison. Each system's ACTUAL
#     memory-node footprint is read from its own logs (DART: memory log; CHIME:
#     "consumed cache size") so the writeup can state how close the two really are.
#
# Output CSV matches cache_sweep.sh so the same parsers work:
#   dist,op,cache_total_mb,th_bytes_per_thread,threads,key_count,op_count,
#   throughput_mops,latency_us
#
# TOPOLOGY / PREREQS: identical to cache_sweep.sh (monitor+memory here, compute
# over SSH; build on both; hugepages; passwordless SSH). Edit the cluster block.
#
set -u

# ----------------------------- cluster config ------------------------------
MONITOR_BIND="${MONITOR_BIND:-0.0.0.0:9898}"
MONITOR_DIAL="${MONITOR_DIAL:-10.30.1.6:9898}"
COMPUTE_HOST="${COMPUTE_HOST:-10.30.1.7}"      # "" => run compute locally
SSH="${SSH:-ssh}"
MEM_NIC="${MEM_NIC:-0}"
CMP_NIC="${CMP_NIC:-0}"
IB_PORT="${IB_PORT:-1}"

DART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --------------------------- comparison contract ---------------------------
MEMORY_NUM="${MEMORY_NUM:-1}"
COMPUTE_NUM="${COMPUTE_NUM:-1}"
THREADS="${THREADS:-24}"            # MATCH CHIME app threads (bench_common THREADS=24)
CORO="${CORO:-1}"
MEM_MB="${MEM_MB:-8192}"            # memory-node RDMA region (disaggregated heap)
BUCKET="${BUCKET:-256}"
KEY_COUNT="${KEY_COUNT:-30000000}"  # 30M keys  == CHIME BULK=30
OP_COUNT="${OP_COUNT:-30000000}"    # 30M measured ops
VALUE_LEN="${VALUE_LEN:-48}"        # 48B       == CHIME simulatedValLen
SCAN_LEN="${SCAN_LEN:-100}"         # == CHIME SCAN_RANGE
TEST_FUNC="${TEST_FUNC:-1}"         # in-memory microbench

# 64 (fits index) -> 32 -> 16 (stressed), same points as CHIME run_cache_stress.
CACHE_TOTAL_MB=(${CACHE_TOTAL_MB:-512 256 128 64})
DISTS=(${DISTS:-uniform zipf99})
OPS=(${OPS:-lookup scan})

STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="${OUT:-$DART_DIR/cache_compare_${STAMP}.csv}"
LOGDIR="${LOGDIR:-$DART_DIR/compare_logs_${STAMP}}"
mkdir -p "$LOGDIR"
echo "dist,op,cache_total_mb,th_bytes_per_thread,threads,key_count,op_count,throughput_mops,latency_us" > "$OUT"

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
    local th_b=$(( cache * 1048576 / THREADS ))

    local uniform theta read scan
    if [ "$dist" = "uniform" ]; then uniform=1; else uniform=0; fi
    theta=99
    if [ "$op" = "lookup" ]; then read=100; scan=0; else read=0; scan=100; fi

    echo "================================================================"
    echo ">>> $tag  (th_b=${th_b}/thread x ${THREADS} = ~${cache}MB total)"
    echo "================================================================"

    teardown; sleep 1

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
    sleep 2

    "$DART_DIR/bin/memory" \
        --monitor_addr="$MONITOR_DIAL" --nic_index=$MEM_NIC --ib_port=$IB_PORT \
        > "$LOGDIR/memory_${tag}.log" 2>&1 &

    local cmp_cmd="cd '$DART_DIR' && ./bin/compute --monitor_addr=$MONITOR_DIAL --nic_index=$CMP_NIC --ib_port=$IB_PORT --numa_node_total_num=2 --numa_node_group=0"
    if [ -n "$COMPUTE_HOST" ]; then
        $SSH "$COMPUTE_HOST" "$cmp_cmd" > "$LOGDIR/compute_${tag}.log" 2>&1
    else
        bash -c "$cmp_cmd" > "$LOGDIR/compute_${tag}.log" 2>&1
    fi

    wait "$mon_pid" 2>/dev/null

    local thp lat
    thp=$(strip_ansi < "$mlog" | grep -oE 'Total throughput = [0-9.eE+-]+' | tail -1 | grep -oE '[0-9.eE+-]+$')
    lat=$(strip_ansi < "$mlog" | grep -oE 'Average latency = [0-9.eE+-]+'  | tail -1 | grep -oE '[0-9.eE+-]+$')
    echo "$dist,$op,$cache,$th_b,$THREADS,$KEY_COUNT,$OP_COUNT,${thp:-NA},${lat:-NA}" >> "$OUT"
    echo "    -> throughput=${thp:-NA} MOps  latency=${lat:-NA} us   (log: $mlog)"

    teardown; sleep 2
}

echo "DART matched cache sweep -> $OUT  (logs in $LOGDIR)"
echo "  contract: ${KEY_COUNT} keys, ${VALUE_LEN}B values, ${THREADS} threads, scan_len=${SCAN_LEN}"
echo "  caches=[${CACHE_TOTAL_MB[*]}]MB  dists=[${DISTS[*]}]  ops=[${OPS[*]}]"
for dist in "${DISTS[@]}"; do
  for op in "${OPS[@]}"; do
    for cache in "${CACHE_TOTAL_MB[@]}"; do
      run_one "$dist" "$op" "$cache"
    done
  done
done

echo; echo "Sweep complete. Results:"
column -t -s, "$OUT" 2>/dev/null || cat "$OUT"
