#!/bin/bash
# ===========================================================================
# cache_sweep_qload_other.sh  --  NODE 1 (memory node) mirror of the qload sweep.
#                                  This is where the QUEUE LOAD is measured.
#
# Runs the SAME memthreads x offload x combos x caches in the SAME order as
# cache_sweep_qload.sh. MEMTHREAD_SET / OFFLOADS / COMBOS / CACHES / OP MUST
# match or the two nodes desync.
#
# QUEUE LOAD = how loaded the memory-node service threads are. The dir-threads
# busy-poll the NIC, so raw CPU% is useless; remote_load.h instead reports the
# ACTIVE FRACTION = time inside process_message / wall time. We record, per
# config, the PEAK steady-state:
#   queue_load_aggregate_pct  = peak "AGGREGATE active = X%"  (sum over threads,
#                               caps near 100% * memthreads -> total capacity used)
#   queue_load_per_thread_pct = matching per-thread avg       (per-thread saturation;
#                               ->100% means that thread is the bottleneck / backed up)
#   peak_msgs                 = RPC msgs served in the peak window
#
# Reading it for your question (2 vs 6 remote threads):
#   * offload OFF rows  -> ~0% (MN does no CPU work; nothing is queued).
#   * offload ON, mt=2  -> per-thread active% saturates first (queue builds with
#                          only 2 servers); aggregate ceiling ~200%.
#   * offload ON, mt=6  -> more service capacity; per-thread active% lower at the
#                          same offered load; aggregate ceiling ~600%.
#   Compare per-thread% (saturation) between mt=2 and mt=6 across cache sizes:
#   smaller cache -> more misses -> more pushdowns -> higher queue load.
#
# HOW TO RUN: start ./cache_sweep_qload.sh on node 0 first, then this on node 1.
# ===========================================================================
set -u

# ---- must match cache_sweep_qload.sh ---------------------------------------
NODENUM=2
THREADS=32
KMAX=32
BULK=50
WARMUP=10
OP=50
CORRECT=0
TIMEBASE=1
EARLY=1
INDEX=0
ADMIT=0.1
TUNE=0
ZIPF_THETA=0.99

MEMTHREAD_SET=(2 6)
OFFLOADS=(off on)
COMBOS=(
  "lookup uniform"
  "lookup zipfian"
  "range  uniform"
  "range  zipfian"
)
CACHES=(64 128 256 512)

WAIT_FOR_MEMC=12
RESULTS=./results
OUTDIR="$RESULTS/qload"
mkdir -p "$OUTDIR"

if [ ! -x ./newbench ]; then
  echo "ERROR: ./newbench not found here. Build first and run from build/." >&2
  exit 1
fi

# run_one <tag> <read> <range> <uniform> <memthreads> <cache> <rpc>
run_one() {
  local tag=$1 r=$2 rg=$3 uni=$4 mt=$5 cache=$6 rpc=$7
  local logf="$OUTDIR/${tag}.node1.log"
  echo ">>> [$(date '+%H:%M:%S')] CONFIG: $tag (MEMTHREADS=$mt cache=${cache}MB rpc=$rpc; waiting ${WAIT_FOR_MEMC}s for node-0 memcached)"
  sleep "$WAIT_FOR_MEMC"
  sudo ./newbench "$NODENUM" "$r" 0 0 0 "$rg" "$THREADS" "$mt" "$cache" \
       "$uni" "$ZIPF_THETA" "$BULK" "$WARMUP" "$OP" "$CORRECT" "$TIMEBASE" \
       "$EARLY" "$INDEX" "$rpc" "$ADMIT" "$TUNE" "$KMAX" 2>&1 | tee "$logf"
  echo "<<< [$(date '+%H:%M:%S')] DONE: $tag"
  sleep 3
}

echo "DEX qload cache sweep (node 1 / memory) $(date)."
for mt in "${MEMTHREAD_SET[@]}"; do
  for off in "${OFFLOADS[@]}"; do
    if [ "$off" = on ]; then rpc=1; else rpc=0; fi
    for combo in "${COMBOS[@]}"; do
      set -- $combo; wl=$1; dist=$2
      if [ "$wl" = lookup ]; then r=100; rg=0; else r=0; rg=100; fi
      if [ "$dist" = uniform ]; then uni=1; else uni=0; fi
      for cache in "${CACHES[@]}"; do
        tag="dex_${wl}_${dist}_offload-${off}_cache${cache}mb_mt${mt}"
        run_one "$tag" "$r" "$rg" "$uni" "$mt" "$cache" "$rpc"
      done
    done
  done
done

# ---- queue-load summary (parse the AGGREGATE active% windows) --------------
# remote_load.h line:
#   AGGREGATE active = 312.40% (of 6 dir-threads; 52.07% per-thread avg)  msgs=NNN
# Record the PEAK aggregate window and its per-thread avg + msgs.
SUM="$OUTDIR/queue_load_qload.csv"
echo "workload,dist,offload,memthreads,cache_mb,queue_load_aggregate_pct,queue_load_per_thread_pct,peak_msgs" > "$SUM"
for mt in "${MEMTHREAD_SET[@]}"; do
  for off in "${OFFLOADS[@]}"; do
    for combo in "${COMBOS[@]}"; do
      set -- $combo; wl=$1; dist=$2
      for cache in "${CACHES[@]}"; do
        logf="$OUTDIR/dex_${wl}_${dist}_offload-${off}_cache${cache}mb_mt${mt}.node1.log"
        [ -f "$logf" ] || continue
        read agg per msgs <<<"$(awk '
          /AGGREGATE active = / {
            a=$0; sub(/.*AGGREGATE active = /,"",a); sub(/%.*/,"",a)
            p=$0; sub(/.*; /,"",p); sub(/% per-thread.*/,"",p)
            m=$0; if (match(m,/msgs=[0-9]+/)) { m=substr(m,RSTART,RLENGTH); sub(/msgs=/,"",m) } else { m=0 }
            if (a+0 > maxa) { maxa=a+0; maxp=p+0; maxm=m+0 }
          }
          END{ printf "%.2f %.2f %d", maxa, maxp, maxm }' "$logf")"
        echo "${wl},${dist},${off},${mt},${cache},${agg:-NA},${per:-NA},${msgs:-NA}" >> "$SUM"
      done
    done
  done
done

echo "DEX qload cache sweep (node 1) COMPLETE $(date). Queue load ($SUM):"
column -s, -t "$SUM" 2>/dev/null || cat "$SUM"
echo "Pair with results/qload/summary_qload.csv (miss rate + traffic split) from NODE 0."
