#!/bin/bash
# ===========================================================================
# sweep_other.sh  --  NODE 1 (memory node) mirror of the FULL sweep.
#
# Runs the SAME 32 configs in the SAME order, no memcached restart.
# COMBOS / CACHES / OP MUST match sweep.sh exactly or the nodes desync.
#
# HOW TO RUN: start ./sweep.sh on node 0 first, then this on node 1.
# ===========================================================================
set -u

# ---- must match sweep.sh ---------------------------------------------------
NODENUM=2
THREADS=32
KMAX=32
MEMTHREADS=4
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
if ldd ./newbench 2>/dev/null | grep -q "not found"; then
  echo "ERROR: newbench has unresolved shared libraries:" >&2
  ldd ./newbench | grep "not found" >&2
  exit 1
fi

# run_one <tag> <read> <range> <uniform> <rpc> <cache_mb>
run_one() {
  local tag=$1 r=$2 rg=$3 uni=$4 rpc=$5 cache=$6
  local logf="$RESULTS/${tag}.node1.log"
  echo ">>> [$(date '+%H:%M:%S')] CONFIG: $tag (waiting ${WAIT_FOR_MEMC}s for node-0 memcached)"
  sleep "$WAIT_FOR_MEMC"
  sudo ./newbench "$NODENUM" "$r" 0 0 0 "$rg" "$THREADS" "$MEMTHREADS" "$cache" \
       "$uni" "$ZIPF_THETA" "$BULK" "$WARMUP" "$OP" "$CORRECT" "$TIMEBASE" \
       "$EARLY" "$INDEX" "$rpc" "$ADMIT" "$TUNE" "$KMAX" 2>&1 | tee "$logf"
  echo "<<< [$(date '+%H:%M:%S')] DONE: $tag"
  sleep 3
}

echo "DEX full sweep (node 1) $(date)."
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

echo "DEX full sweep (node 1) COMPLETE $(date)."
