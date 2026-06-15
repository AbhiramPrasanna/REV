#!/bin/bash
# ===========================================================================
# sweep_other.sh  --  DEX cache sweep  (run on NODE 1 / memory node)
#
# Mirror of sweep.sh: SAME 8 configurations in the SAME order, no memcached
# restart (node 0 owns it). For each config it waits WAIT_FOR_MEMC seconds for
# node 0's fresh memcached, then launches newbench as node 1 (the memory pool).
#
# The argument list MUST match sweep.sh exactly.
#
# HOW TO RUN: start ./sweep.sh on node 0 first, then this on node 1.
# If node 1 fails to register, increase WAIT_FOR_MEMC.
# ===========================================================================
set -u

# ---- must match sweep.sh ---------------------------------------------------
NODENUM=2
THREADS=36
KMAX=36
MEMTHREADS=4       # MUST be <= NR_DIRECTORY (4)
BULK=50
WARMUP=10
OP=300
CORRECT=0
TIMEBASE=1
EARLY=1
INDEX=0
ADMIT=0.1
TUNE=0
ZIPF_THETA=0.99

WL=range           # MUST match sweep.sh
DIST=uniform       # MUST match sweep.sh

CACHES=(64 128 256 512)

# Seconds to wait per config for node 0 to restart memcached.
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
  local logf="$RESULTS/${tag}.node1.log"     # OVERWRITES previous
  echo ">>> [$(date '+%H:%M:%S')] CONFIG: $tag (waiting ${WAIT_FOR_MEMC}s for node-0 memcached)"
  sleep "$WAIT_FOR_MEMC"

  sudo ./newbench "$NODENUM" "$r" 0 0 0 "$rg" "$THREADS" "$MEMTHREADS" "$cache" \
       "$uni" "$ZIPF_THETA" "$BULK" "$WARMUP" "$OP" "$CORRECT" "$TIMEBASE" \
       "$EARLY" "$INDEX" "$rpc" "$ADMIT" "$TUNE" "$KMAX" 2>&1 | tee "$logf"

  echo "<<< [$(date '+%H:%M:%S')] DONE: $tag"
  sleep 3
}

if [ "$WL" = lookup ]; then R=100; RG=0; else R=0; RG=100; fi
if [ "$DIST" = uniform ]; then UNI=1; else UNI=0; fi

echo "DEX cache sweep (node 1) starting $(date)."
for off in off on; do
  if [ "$off" = on ]; then rpc=1; else rpc=0; fi
  for cache in "${CACHES[@]}"; do
    tag="dex_${WL}_${DIST}_offload-${off}_cache${cache}mb"
    run_one "$tag" "$R" "$RG" "$UNI" "$rpc" "$cache"
  done
done

echo "Sweep (node 1) COMPLETE $(date)."
