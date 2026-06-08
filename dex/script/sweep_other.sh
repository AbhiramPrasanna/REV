#!/bin/bash
# ===========================================================================
# sweep_other.sh  --  DEX cache-size sweep  (run on NODE 1 / memory node: 10.30.1.6)
#
# Mirror of sweep.sh that runs the SAME 48 configurations in the SAME order,
# but does NOT restart memcached (node 0 owns it).  For each configuration it
# waits a few seconds for node 0 to bring up a fresh memcached, then launches
# newbench, which registers as node 1 (the remote memory pool) and stays alive
# serving RDMA until node 0's run finishes at the shared "finish" barrier.
#
# The argument list MUST match sweep.sh exactly (same keyspace / sharding).
#
# HOW TO RUN:  start ./sweep.sh on node 0 first, then this on node 1.
# If you ever see node 1 failing to register, increase WAIT_FOR_MEMC below.
# ===========================================================================
set -u

# ---- must match sweep.sh ---------------------------------------------------
NODENUM=2
THREADS=36
KMAX=36
MEMTHREADS=4
BULK=50
WARMUP=10
OP=30
CORRECT=0
TIMEBASE=1
EARLY=1
INDEX=0
ADMIT=0.1
TUNE=0
ZIPF_THETA=0.99

CACHES=(32 64 128 256 512 1024)

# Seconds to wait at the start of each config for node 0 to restart memcached.
# Must exceed node 0's (run-end -> restartMemc complete) latency.
WAIT_FOR_MEMC=12

RESULTS=./results
mkdir -p "$RESULTS"

# --- preflight: same shared-library check as node 0 -------------------------
if [ ! -x ./newbench ]; then
  echo "ERROR: ./newbench not found here. Build first and run from build/." >&2
  exit 1
fi
if ldd ./newbench 2>/dev/null | grep -q "not found"; then
  echo "ERROR: newbench has unresolved shared libraries:" >&2
  ldd ./newbench | grep "not found" >&2
  echo "  echo /usr/local/lib | sudo tee /etc/ld.so.conf.d/local.conf && sudo ldconfig" >&2
  exit 1
fi

# run_one <tag> <read> <range> <uniform> <zipf> <rpc> <cache_mb>
run_one() {
  local tag=$1 r=$2 rg=$3 uni=$4 zipf=$5 rpc=$6 cache=$7
  local logf="$RESULTS/${tag}.node1.log"
  echo ">>> [$(date '+%H:%M:%S')] CONFIG: $tag  (waiting ${WAIT_FOR_MEMC}s for node-0 memcached)"
  sleep "$WAIT_FOR_MEMC"

  sudo ./newbench "$NODENUM" "$r" 0 0 0 "$rg" "$THREADS" "$MEMTHREADS" "$cache" \
       "$uni" "$zipf" "$BULK" "$WARMUP" "$OP" "$CORRECT" "$TIMEBASE" "$EARLY" \
       "$INDEX" "$rpc" "$ADMIT" "$TUNE" "$KMAX" 2>&1 | tee "$logf"

  echo "<<< [$(date '+%H:%M:%S')] DONE: $tag"
  sleep 3
}

echo "DEX cache sweep (node 1) starting at $(date)."
for dist in uniform zipf; do
  if [ "$dist" = uniform ]; then uni=1; else uni=0; fi
  for wl in lookup range; do
    if [ "$wl" = lookup ]; then r=100; rg=0; else r=0; rg=100; fi
    for off in on off; do
      if [ "$off" = on ]; then rpc=1; else rpc=0; fi
      for cache in "${CACHES[@]}"; do
        tag="dex_${wl}_${dist}_offload-${off}_cache${cache}mb"
        run_one "$tag" "$r" "$rg" "$uni" "$ZIPF_THETA" "$rpc" "$cache"
      done
    done
  done
done

echo "Sweep (node 1) COMPLETE at $(date)."
