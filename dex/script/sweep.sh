#!/bin/bash
# ===========================================================================
# sweep.sh  --  DEX OFFLOADING cache sweep  (run on NODE 0 / memcached host)
#
# Range-scan, uniform workload. For each cache size, runs DEX WITHOUT offloading
# (rpc_rate=0) and WITH offloading (rpc_rate=1) so you can see the throughput /
# tail-latency gap as the cache grows.
#     cache size : 64, 128, 256, 512 MB
#     offloading : OFF (rpc_rate=0)  vs  ON (rpc_rate=1)
# => 4 x 2 = 8 configurations.
#
# *** REQUIRES a MANUAL_PUSHDOWN build ***
#   cmake -DCMAKE_BUILD_TYPE=Release -DMANUAL_PUSHDOWN=ON .. && make -j
# Without it, rpc_rate is ignored (adaptive) and offload on/off are identical.
#
# Results: each config -> results/<tag>.log  (OVERWRITES any previous run).
# A summary table is written to results/summary.csv at the end.
#
# HOW TO RUN:
#   1. node 0:  ./sweep.sh
#   2. node 1:  ./sweep_other.sh   (start right after)
# ===========================================================================
set -u

# ---- fixed parameters ------------------------------------------------------
NODENUM=2          # total machines
THREADS=36         # worker threads (matches the validated single-run setup)
KMAX=36            # threads/node -> CNodeCount = 1
MEMTHREADS=4       # MN directory threads -- MUST be <= NR_DIRECTORY (4)
BULK=50            # bulk-load keys, millions
WARMUP=10          # warmup ops, millions (populate the cache)
OP=300             # measured ops, millions -- intentionally high so every
                   # config runs the full time_based window (max operations)
CORRECT=0
TIMEBASE=1         # cap phases by wall-clock (so OP just needs to be "large")
EARLY=1
INDEX=0            # 0 = DEX
ADMIT=0.1
TUNE=0
ZIPF_THETA=0.99    # unused (uniform), kept for the arg slot

# ---- workload / distribution (the config that shows the gap) ---------------
WL=range           # range  (set to: lookup  for point lookups)
DIST=uniform       # uniform

# ---- sweep dimensions ------------------------------------------------------
CACHES=(64 128 256 512)

RESULTS=./results
mkdir -p "$RESULTS"

# --- preflight --------------------------------------------------------------
if [ ! -x ./newbench ]; then
  echo "ERROR: ./newbench not found here. Build first and run from build/." >&2
  exit 1
fi
if ldd ./newbench 2>/dev/null | grep -q "not found"; then
  echo "ERROR: newbench has unresolved shared libraries:" >&2
  ldd ./newbench | grep "not found" >&2
  exit 1
fi
FIRST_RUN=1

# run_one <tag> <read> <range> <uniform> <rpc> <cache_mb>
run_one() {
  local tag=$1 r=$2 rg=$3 uni=$4 rpc=$5 cache=$6
  local logf="$RESULTS/${tag}.log"          # tee OVERWRITES (truncates) this file
  echo "===================================================================="
  echo ">>> [$(date '+%H:%M:%S')] CONFIG: $tag"
  echo "===================================================================="

  if ! ./restartMemc.sh; then
    echo "ABORT: memcached restart failed for $tag." >&2
    exit 1
  fi
  sleep 2

  sudo ./newbench "$NODENUM" "$r" 0 0 0 "$rg" "$THREADS" "$MEMTHREADS" "$cache" \
       "$uni" "$ZIPF_THETA" "$BULK" "$WARMUP" "$OP" "$CORRECT" "$TIMEBASE" \
       "$EARLY" "$INDEX" "$rpc" "$ADMIT" "$TUNE" "$KMAX" 2>&1 | tee "$logf"
  local rc=${PIPESTATUS[0]}

  if [ "$rc" -ne 0 ]; then
    echo "WARNING: newbench exited with code $rc for $tag" >&2
    if [ "$FIRST_RUN" = 1 ]; then
      echo "ABORT: first run failed -> environment not ready." >&2
      exit 1
    fi
  fi
  FIRST_RUN=0
  echo "<<< [$(date '+%H:%M:%S')] DONE: $tag  (log: $logf)"
  sleep 3
}

if [ "$WL" = lookup ]; then R=100; RG=0; else R=0; RG=100; fi
if [ "$DIST" = uniform ]; then UNI=1; else UNI=0; fi

echo "DEX cache sweep starting $(date). 8 configs ($WL/$DIST), ${OP}M op cap each."
for off in off on; do
  if [ "$off" = on ]; then rpc=1; else rpc=0; fi
  for cache in "${CACHES[@]}"; do
    tag="dex_${WL}_${DIST}_offload-${off}_cache${cache}mb"
    run_one "$tag" "$R" "$RG" "$UNI" "$rpc" "$cache"
  done
done

# ---- summary: extract the headline numbers into results/summary.csv ---------
SUM="$RESULTS/summary.csv"
echo "workload,dist,offload,cache_mb,throughput_mops,p99_us,rdma_read_per_op,rpc_per_op" > "$SUM"
for off in off on; do
  for cache in "${CACHES[@]}"; do
    logf="$RESULTS/dex_${WL}_${DIST}_offload-${off}_cache${cache}mb.log"
    [ -f "$logf" ] || continue
    thr=$(awk '/Final throughput =/{v=$NF} END{if(v!="")print v; else print "NA"}' "$logf")
    p99=$(awk 'match($0,/p99=[ ]*[0-9.]+/){s=substr($0,RSTART,RLENGTH);gsub(/p99=[ ]*/,"",s);print s;exit}' "$logf")
    rr=$(awk '/Avg. rdma read \/ op =/{v=$NF} END{if(v!="")print v; else print "NA"}' "$logf")
    rp=$(awk '/Avg. rdma rpc \/ op =/{v=$NF} END{if(v!="")print v; else print "NA"}' "$logf")
    echo "${WL},${DIST},${off},${cache},${thr:-NA},${p99:-NA},${rr:-NA},${rp:-NA}" >> "$SUM"
  done
done

echo "===================================================================="
echo "Sweep COMPLETE $(date). Per-config logs in $RESULTS/"
echo "Summary table:"
column -s, -t "$SUM" 2>/dev/null || cat "$SUM"
echo "===================================================================="
