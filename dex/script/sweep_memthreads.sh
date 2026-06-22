#!/bin/bash
# ===========================================================================
# sweep_memthreads.sh  --  DEX memory-thread sweep  (NODE 0 / compute + memcached)
#
# Question this answers:
#   "If I change the number of memory-side service threads (memThreadCount),
#    how does offloading behave? Can offloaded ops get there faster, how much
#    faster, and at what point does adding threads stop mattering?"
#
# For EACH memThreadCount in {2,4,6,8} it re-runs the COMPLETE working set,
# both WITH and WITHOUT offloading:
#       offload in {off (rpc=0), on (rpc=1)}
#       op      in {lookup, range}
#       dist    in {uniform, zipfian-0.99}
#       cache   in {64,128,256,512} MB
#   => 4 memthreads x 2 offload x 2 ops x 2 dists x 4 caches = 128 configs.
#   The offload-OFF rows are the control: the MN does no CPU work, so remote
#   load stays ~0 and throughput is flat in memThreadCount. The offload-ON rows
#   are where memThreadCount can actually buy more MN service capacity.
#
# memThreadCount is HARD-CAPPED at NR_DIRECTORY (=4 by default in
# include/Common.h); a value above NR_DIRECTORY reads uninitialized dirCon[] ->
# assert. To sweep 6/8 you MUST raise NR_DIRECTORY to >=8 and rebuild BOTH nodes.
#
# *** REQUIRES a MANUAL_PUSHDOWN build on BOTH nodes ***
#     cmake -DCMAKE_BUILD_TYPE=Release -DMANUAL_PUSHDOWN=ON .. && make -j
#
# HOW TO RUN:
#   1. node 0:  ./sweep_memthreads.sh
#   2. node 1:  ./sweep_memthreads_other.sh   (start right after)
#
# Results -> results/<tag>.log ; summary -> results/summary_memthreads.csv
# The remote CPU load (dir-thread active %) is printed on NODE 1 and summarized
# by sweep_memthreads_other.sh into results/remote_load_memthreads.csv.
# ===========================================================================
set -u

# ---- fixed parameters ------------------------------------------------------
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
# ---- swept dimensions ------------------------------------------------------
MEMTHREAD_SET=(2 4 6 8)     # each value MUST be <= NR_DIRECTORY; raise it to
                            # >=8 in include/Common.h and rebuild BOTH nodes.
OFFLOADS=(off on)           # off = rpc 0 (MN idle, control); on = rpc 1
COMBOS=(
  "lookup uniform"
  "lookup zipfian"
  "range  uniform"
  "range  zipfian"
)
CACHES=(64 128 256 512)     # complete cache working set

RESULTS=./results
mkdir -p "$RESULTS"

if [ ! -x ./newbench ]; then
  echo "ERROR: ./newbench not found here. Build first and run from build/." >&2
  exit 1
fi
FIRST_RUN=1

# run_one <tag> <read> <range> <uniform> <memthreads> <cache> <rpc>
run_one() {
  local tag=$1 r=$2 rg=$3 uni=$4 mt=$5 cache=$6 rpc=$7
  local logf="$RESULTS/${tag}.log"
  echo "===================================================================="
  echo ">>> [$(date '+%H:%M:%S')] CONFIG: $tag  (MEMTHREADS=$mt cache=${cache}MB rpc=$rpc)"
  echo "===================================================================="
  if ! ./restartMemc.sh; then
    echo "ABORT: memcached restart failed for $tag." >&2; exit 1
  fi
  sleep 2
  sudo ./newbench "$NODENUM" "$r" 0 0 0 "$rg" "$THREADS" "$mt" "$cache" \
       "$uni" "$ZIPF_THETA" "$BULK" "$WARMUP" "$OP" "$CORRECT" "$TIMEBASE" \
       "$EARLY" "$INDEX" "$rpc" "$ADMIT" "$TUNE" "$KMAX" 2>&1 | tee "$logf"
  local rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ]; then
    echo "WARNING: newbench exited with code $rc for $tag" >&2
    [ "$FIRST_RUN" = 1 ] && { echo "ABORT: first run failed." >&2; exit 1; }
  fi
  FIRST_RUN=0
  echo "<<< [$(date '+%H:%M:%S')] DONE: $tag  (log: $logf)"
  sleep 3
}

echo "DEX memthreads sweep $(date). ${#MEMTHREAD_SET[@]} memthreads x ${#OFFLOADS[@]} offload x ${#COMBOS[@]} combos x ${#CACHES[@]} caches."
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

# ---- summary ---------------------------------------------------------------
SUM="$RESULTS/summary_memthreads.csv"
echo "workload,dist,offload,memthreads,cache_mb,throughput_mops,p99_us,rdma_read_per_op,rpc_per_op" > "$SUM"
for mt in "${MEMTHREAD_SET[@]}"; do
  for off in "${OFFLOADS[@]}"; do
    for combo in "${COMBOS[@]}"; do
      set -- $combo; wl=$1; dist=$2
      for cache in "${CACHES[@]}"; do
        logf="$RESULTS/dex_${wl}_${dist}_offload-${off}_cache${cache}mb_mt${mt}.log"
        [ -f "$logf" ] || continue
        thr=$(awk '/Final throughput =/{v=$NF} END{print (v!=""?v:"NA")}' "$logf")
        p99=$(awk 'match($0,/p99=[ ]*[0-9.]+/){s=substr($0,RSTART,RLENGTH);gsub(/p99=[ ]*/,"",s);print s;exit}' "$logf")
        rr=$(awk '/Avg. rdma read \/ op =/{v=$NF} END{print (v!=""?v:"NA")}' "$logf")
        rp=$(awk '/Avg. rdma rpc \/ op =/{v=$NF} END{print (v!=""?v:"NA")}' "$logf")
        echo "${wl},${dist},${off},${mt},${cache},${thr:-NA},${p99:-NA},${rr:-NA},${rp:-NA}" >> "$SUM"
      done
    done
  done
done

echo "===================================================================="
echo "memthreads sweep COMPLETE $(date). Summary ($SUM):"
column -s, -t "$SUM" 2>/dev/null || cat "$SUM"
echo "Pair the throughput/p99 here with results/remote_load_memthreads.csv from NODE 1."
echo "===================================================================="
