#!/bin/bash
# ===========================================================================
# sweep2.sh  --  DEX offloading sweep for the REMAINING workload/dist combos
#                (run on NODE 0 / memcached host)
#
# range/uniform was already swept (sweep.sh). This runs the other three:
#     lookup/uniform, lookup/zipfian, range/zipfian
# each x {offload off (rpc=0), on (rpc=1)} x {64,128,256,512 MB}  = 24 configs.
#
# Edit COMBOS below to change which (workload distribution) pairs run.
# Results -> results/<tag>.log  (tee OVERWRITES). Summary -> results/summary.csv
# (the summary reads ALL FOUR combos, including the range/uniform you already
#  ran, so you get one complete table).
#
# *** REQUIRES a MANUAL_PUSHDOWN build on BOTH nodes ***
#   cmake -DCMAKE_BUILD_TYPE=Release -DMANUAL_PUSHDOWN=ON .. && make -j
#
# HOW TO RUN:
#   1. node 0:  ./sweep2.sh
#   2. node 1:  ./sweep2_other.sh   (start right after)
# ===========================================================================
set -u

# ---- fixed parameters ------------------------------------------------------
NODENUM=2
THREADS=36
KMAX=36
MEMTHREADS=4       # MUST be <= NR_DIRECTORY (4)
BULK=50
WARMUP=10
OP=300             # high so every config runs the full time_based window
CORRECT=0
TIMEBASE=1
EARLY=1
INDEX=0
ADMIT=0.1
TUNE=0
ZIPF_THETA=0.99    # skew used for the zipfian runs

# ---- what to run (workload distribution) pairs -----------------------------
# range/uniform is intentionally omitted (already swept). Add it back if you
# want to re-run it: "range uniform".
COMBOS=(
  "lookup uniform"
  "lookup zipfian"
  "range  zipfian"
)
CACHES=(64 128 256 512)

# combos to AGGREGATE into summary.csv (all four, so the table is complete)
ALL_COMBOS=("lookup uniform" "lookup zipfian" "range uniform" "range zipfian")

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
  local logf="$RESULTS/${tag}.log"
  echo "===================================================================="
  echo ">>> [$(date '+%H:%M:%S')] CONFIG: $tag"
  echo "===================================================================="
  if ! ./restartMemc.sh; then
    echo "ABORT: memcached restart failed for $tag." >&2; exit 1
  fi
  sleep 2
  sudo ./newbench "$NODENUM" "$r" 0 0 0 "$rg" "$THREADS" "$MEMTHREADS" "$cache" \
       "$uni" "$ZIPF_THETA" "$BULK" "$WARMUP" "$OP" "$CORRECT" "$TIMEBASE" \
       "$EARLY" "$INDEX" "$rpc" "$ADMIT" "$TUNE" "$KMAX" 2>&1 | tee "$logf"
  local rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ]; then
    echo "WARNING: newbench exited with code $rc for $tag" >&2
    if [ "$FIRST_RUN" = 1 ]; then
      echo "ABORT: first run failed -> environment not ready." >&2; exit 1
    fi
  fi
  FIRST_RUN=0
  echo "<<< [$(date '+%H:%M:%S')] DONE: $tag  (log: $logf)"
  sleep 3
}

echo "DEX sweep2 starting $(date). ${#COMBOS[@]} combos x 2 offload x ${#CACHES[@]} caches."
for combo in "${COMBOS[@]}"; do
  set -- $combo; wl=$1; dist=$2
  if [ "$wl" = lookup ]; then r=100; rg=0; else r=0; rg=100; fi
  if [ "$dist" = uniform ]; then uni=1; else uni=0; fi
  for off in off on; do
    if [ "$off" = on ]; then rpc=1; else rpc=0; fi
    for cache in "${CACHES[@]}"; do
      tag="dex_${wl}_${dist}_offload-${off}_cache${cache}mb"
      run_one "$tag" "$r" "$rg" "$uni" "$rpc" "$cache"
    done
  done
done

# ---- summary over ALL four combos (reads whatever logs exist) ---------------
SUM="$RESULTS/summary.csv"
echo "workload,dist,offload,cache_mb,throughput_mops,p99_us,rdma_read_per_op,rpc_per_op" > "$SUM"
for combo in "${ALL_COMBOS[@]}"; do
  set -- $combo; wl=$1; dist=$2
  for off in off on; do
    for cache in "${CACHES[@]}"; do
      logf="$RESULTS/dex_${wl}_${dist}_offload-${off}_cache${cache}mb.log"
      [ -f "$logf" ] || continue
      thr=$(awk '/Final throughput =/{v=$NF} END{if(v!="")print v; else print "NA"}' "$logf")
      p99=$(awk 'match($0,/p99=[ ]*[0-9.]+/){s=substr($0,RSTART,RLENGTH);gsub(/p99=[ ]*/,"",s);print s;exit}' "$logf")
      rr=$(awk '/Avg. rdma read \/ op =/{v=$NF} END{if(v!="")print v; else print "NA"}' "$logf")
      rp=$(awk '/Avg. rdma rpc \/ op =/{v=$NF} END{if(v!="")print v; else print "NA"}' "$logf")
      echo "${wl},${dist},${off},${cache},${thr:-NA},${p99:-NA},${rr:-NA},${rp:-NA}" >> "$SUM"
    done
  done
done

echo "===================================================================="
echo "sweep2 COMPLETE $(date). Logs in $RESULTS/. Summary:"
column -s, -t "$SUM" 2>/dev/null || cat "$SUM"
echo "===================================================================="
