#!/bin/bash
# ===========================================================================
# cache_sweep_qload.sh  --  DEX focused cache sweep, NODE 0 (compute + memcached)
#
# Answers, for remote-thread counts {2, 6}:
#   (1) DEX path-aware cache MISS RATE
#   (2) REMOTE TRAFFIC, split into:
#         - NON-offloaded  : direct RDMA reads the compute node still issues
#         - offloaded      : RPC pushdowns served on the memory node
#       (the split is the whole point of the offload-ON case)
#   (3) memory-node QUEUE LOAD with 2 vs 6 remote service threads
#       -> printed on NODE 1; captured by cache_sweep_qload_other.sh.
#
# Sweep grid (re-runs the FULL working set for each remote-thread count):
#   memthreads (remote svc threads) in {2, 6}
#   offload                          in {off (rpc=0), on (rpc=1)}
#   workload                         in {lookup, range}
#   distribution                     in {uniform, zipfian(0.99)}
#   cache                            in {64,128,256,512} MB
#   => 2 x 2 x 2 x 2 x 4 = 64 configs, OP=50M each (time_based caps ~<=60s).
#
# memthreads MUST be <= NR_DIRECTORY. include/Common.h already has
# NR_DIRECTORY=8, so {2,6} need NO rebuild. The current ./newbench already has
# BENCH_LATENCY=1 (miss rate + traffic split) and REMOTE_LOAD=1 (queue load)
# compiled in, so NO rebuild is required at all -- just run it on both nodes.
# (If you DO rebuild: cmake -DCMAKE_BUILD_TYPE=Release -DMANUAL_PUSHDOWN=ON .. && make -j)
#
# HOW TO RUN:
#   1. node 0:  ./cache_sweep_qload.sh
#   2. node 1:  ./cache_sweep_qload_other.sh     (start right after)
#
# Node-0 metrics  -> results/qload/summary_qload.csv
# Node-1 queue    -> results/qload/queue_load_qload.csv  (from the _other script)
# ===========================================================================
set -u

# ---- fixed parameters (match the _other script EXACTLY) --------------------
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
MEMTHREAD_SET=(2 6)          # remote service threads; both <= NR_DIRECTORY(=8)
OFFLOADS=(off on)            # off = rpc 0 (MN idle control); on = rpc 1
COMBOS=(
  "lookup uniform"
  "lookup zipfian"
  "range  uniform"
  "range  zipfian"
)
CACHES=(64 128 256 512)

RESULTS=./results
OUTDIR="$RESULTS/qload"
mkdir -p "$OUTDIR"

if [ ! -x ./newbench ]; then
  echo "ERROR: ./newbench not found here. Build first and run from build/." >&2
  exit 1
fi
FIRST_RUN=1

# run_one <tag> <read> <range> <uniform> <memthreads> <cache> <rpc>
run_one() {
  local tag=$1 r=$2 rg=$3 uni=$4 mt=$5 cache=$6 rpc=$7
  local logf="$OUTDIR/${tag}.log"
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

echo "DEX qload cache sweep $(date). ${#MEMTHREAD_SET[@]} memthreads x ${#OFFLOADS[@]} offload x ${#COMBOS[@]} combos x ${#CACHES[@]} caches."
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

# ---- summary: miss rate + remote-traffic split -----------------------------
# miss_rate_pct           = "MISS RATE = P%"            (PROPER path-aware miss
#                           rate, per node access: miss/(hit+miss). Falls as the
#                           cache grows. This is the headline number.)
# leaf_miss_rate_pct      = "leaf-node miss ... P% rate"  (leaf node-access miss rate)
# inner_miss_rate_pct     = "inner-node miss ... P% rate" (inner node-access miss rate)
# ops_remote_pct          = "ops remote (>=1 net op) P%"  (op-level, ~100% always)
# direct_read_per_op      = "Avg. rdma read / op"      (NON-offloaded traffic, count)
# direct_read_bytes_per_op= "Avg. rdma read size/ op"  (NON-offloaded traffic, bytes)
# offload_rpc_per_op      = "Avg. rdma rpc / op"       (OFFLOADED traffic, count)
# total_remote_ops_per_op = "remote ops / op"          (all remote ops/op)
# offload_traffic_frac    = rpc / (read + rpc)         (share of remote ops offloaded)
SUM="$OUTDIR/summary_qload.csv"
echo "workload,dist,offload,memthreads,cache_mb,throughput_mops,p99_us,miss_rate_pct,leaf_miss_rate_pct,inner_miss_rate_pct,ops_remote_pct,direct_read_per_op,direct_read_bytes_per_op,offload_rpc_per_op,total_remote_ops_per_op,offload_traffic_frac" > "$SUM"
for mt in "${MEMTHREAD_SET[@]}"; do
  for off in "${OFFLOADS[@]}"; do
    for combo in "${COMBOS[@]}"; do
      set -- $combo; wl=$1; dist=$2
      for cache in "${CACHES[@]}"; do
        logf="$OUTDIR/dex_${wl}_${dist}_offload-${off}_cache${cache}mb_mt${mt}.log"
        [ -f "$logf" ] || continue
        thr=$(awk '/Final throughput =/{v=$NF} END{print (v!=""?v:"NA")}' "$logf")
        p99=$(awk '/^[[:space:]]*ALL[[:space:]]/{ if(match($0,/p99=[ ]*[0-9.]+/)){s=substr($0,RSTART,RLENGTH);gsub(/p99=[ ]*/,"",s);v=s} } END{print (v!=""?v:"NA")}' "$logf")
        miss=$(awk 'match($0,/MISS RATE[ ]*=[ ]*[0-9.]+%/){s=substr($0,RSTART,RLENGTH);gsub(/[^0-9.]/,"",s);v=s} END{print (v!=""?v:"NA")}' "$logf")
        leafr=$(awk 'match($0,/leaf-node  miss .*[0-9.]+% rate/){s=$0; sub(/.*, /,"",s); sub(/% rate.*/,"",s); v=s} END{print (v!=""?v:"NA")}' "$logf")
        innerr=$(awk 'match($0,/inner-node miss .*[0-9.]+% rate/){s=$0; sub(/.*, /,"",s); sub(/% rate.*/,"",s); v=s} END{print (v!=""?v:"NA")}' "$logf")
        remp=$(awk 'match($0,/ops remote \(>=1 net op\)[ ]*=[ ]*[0-9]+[ ]*\([0-9.]+%\)/){s=$0; sub(/.*\(/,"",s); sub(/%.*/,"",s); v=s} END{print (v!=""?v:"NA")}' "$logf")
        rr=$(awk '/Avg. rdma read \/ op =/{v=$NF} END{print (v!=""?v:"NA")}' "$logf")
        rrb=$(awk '/Avg. rdma read size\/ op =/{v=$NF} END{print (v!=""?v:"NA")}' "$logf")
        rp=$(awk '/Avg. rdma rpc \/ op =/{v=$NF} END{print (v!=""?v:"NA")}' "$logf")
        rop=$(awk '/remote ops \/ op/{v=$NF} END{print (v!=""?v:"NA")}' "$logf")
        frac=$(awk -v rr="$rr" -v rp="$rp" 'BEGIN{ if(rr=="NA"||rp=="NA"){print "NA"} else { d=rr+rp; printf "%.4f", (d>0? rp/d : 0) } }')
        echo "${wl},${dist},${off},${mt},${cache},${thr:-NA},${p99:-NA},${miss:-NA},${leafr:-NA},${innerr:-NA},${remp:-NA},${rr:-NA},${rrb:-NA},${rp:-NA},${rop:-NA},${frac:-NA}" >> "$SUM"
      done
    done
  done
done

echo "===================================================================="
echo "qload cache sweep COMPLETE $(date). Node-0 summary ($SUM):"
column -s, -t "$SUM" 2>/dev/null || cat "$SUM"
echo "Pair with results/qload/queue_load_qload.csv (queue load) from NODE 1."
echo "===================================================================="
