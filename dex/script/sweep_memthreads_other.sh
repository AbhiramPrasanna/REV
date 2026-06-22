#!/bin/bash
# ===========================================================================
# sweep_memthreads_other.sh  --  NODE 1 (memory node) mirror of the memthreads
#                                sweep. This is where the REMOTE CPU LOAD prints.
#
# Runs the SAME memthreads x offload x combos x caches in the SAME order as
# sweep_memthreads.sh. MEMTHREAD_SET / OFFLOADS / COMBOS / CACHES / OP MUST
# match or the nodes desync.
#
# Parses each memory-node log's periodic "AGGREGATE active = X%" lines (from
# include/remote_load.h) and records the PEAK steady-state load per config into
# results/remote_load_memthreads.csv -- pair it with summary_memthreads.csv on
# node 0 to see remote CPU load vs throughput as memThreadCount grows. The
# offload-OFF rows should read ~0% (the MN does no CPU work); offload-ON rows
# rise with the offloaded fraction and cap near 100% * memThreadCount.
#
# HOW TO RUN: start ./sweep_memthreads.sh on node 0 first, then this on node 1.
# ===========================================================================
set -u

# ---- must match sweep_memthreads.sh ----------------------------------------
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

MEMTHREAD_SET=(2 4 6 8)     # MUST be <= NR_DIRECTORY (raise it + rebuild for 6/8)
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
mkdir -p "$RESULTS"

if [ ! -x ./newbench ]; then
  echo "ERROR: ./newbench not found here. Build first and run from build/." >&2
  exit 1
fi

# run_one <tag> <read> <range> <uniform> <memthreads> <cache> <rpc>
run_one() {
  local tag=$1 r=$2 rg=$3 uni=$4 mt=$5 cache=$6 rpc=$7
  local logf="$RESULTS/${tag}.node1.log"
  echo ">>> [$(date '+%H:%M:%S')] CONFIG: $tag (MEMTHREADS=$mt cache=${cache}MB rpc=$rpc; waiting ${WAIT_FOR_MEMC}s for node-0 memcached)"
  sleep "$WAIT_FOR_MEMC"
  sudo ./newbench "$NODENUM" "$r" 0 0 0 "$rg" "$THREADS" "$mt" "$cache" \
       "$uni" "$ZIPF_THETA" "$BULK" "$WARMUP" "$OP" "$CORRECT" "$TIMEBASE" \
       "$EARLY" "$INDEX" "$rpc" "$ADMIT" "$TUNE" "$KMAX" 2>&1 | tee "$logf"
  echo "<<< [$(date '+%H:%M:%S')] DONE: $tag"
  sleep 3
}

echo "DEX memthreads sweep (node 1 / memory) $(date)."
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

# ---- remote-load summary (parse the AGGREGATE active% lines) ---------------
# Line format from remote_load.h:
#   AGGREGATE active = 73.21% (of 4 dir-threads; 18.30% per-thread avg)  msgs=...
# We report the PEAK aggregate and the corresponding per-thread average; peak is
# the cleanest saturation signal (steady run window, warmup excluded by EARLY).
SUM="$RESULTS/remote_load_memthreads.csv"
echo "workload,dist,offload,memthreads,cache_mb,peak_aggregate_active_pct,peak_per_thread_active_pct" > "$SUM"
for mt in "${MEMTHREAD_SET[@]}"; do
  for off in "${OFFLOADS[@]}"; do
    for combo in "${COMBOS[@]}"; do
      set -- $combo; wl=$1; dist=$2
      for cache in "${CACHES[@]}"; do
        logf="$RESULTS/dex_${wl}_${dist}_offload-${off}_cache${cache}mb_mt${mt}.node1.log"
        [ -f "$logf" ] || continue
        read agg per <<<"$(awk '
          match($0,/AGGREGATE active = [0-9.]+%/){
            a=substr($0,RSTART,RLENGTH); gsub(/[^0-9.]/,"",a)
          }
          match($0,/; [0-9.]+% per-thread/){
            p=substr($0,RSTART,RLENGTH); gsub(/[^0-9.]/,"",p)
          }
          a!=""{ if(a+0>maxa){maxa=a+0; maxp=p+0} }
          END{ printf "%.2f %.2f", maxa, maxp }' "$logf")"
        echo "${wl},${dist},${off},${mt},${cache},${agg:-NA},${per:-NA}" >> "$SUM"
      done
    done
  done
done

echo "DEX memthreads sweep (node 1) COMPLETE $(date). Remote load ($SUM):"
column -s, -t "$SUM" 2>/dev/null || cat "$SUM"
