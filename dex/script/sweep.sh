#!/bin/bash
# ===========================================================================
# sweep.sh  --  DEX cache-size sweep  (run on NODE 0 / memcached host: 10.30.1.9)
#
# Sweeps the compute-node buffer cache across:
#     32, 64, 128, 256, 512, 1024 MB
# for every combination of:
#     workload     : 100% point-lookup,  100% range-scan
#     distribution : uniform,            zipfian (theta = 0.99)
#     offloading   : ON  (rpc_rate=1, RPC pushdown to memory node)
#                    OFF (rpc_rate=0, pure one-sided RDMA + caching)
# => 2 x 2 x 2 x 6 = 48 configurations, 30 M operations each.
#
# memcached is restarted BEFORE every configuration so each run is a fresh
# distributed registration (node ids / barriers reset).
#
# Topology: NODENUM=2 with THREADS<=KMAX so CNodeCount=1 -> node 0 is the single
# compute node (the one whose cache we sweep) and node 1 is the remote memory
# pool.  The ~1 GB bulk-loaded tree spans the 32 MB..1024 MB sweep nicely
# (32 MB = almost no caching, 1024 MB = nearly the whole tree resident).
#
# HOW TO RUN:
#   1. start this script on node 0 (10.30.1.9):   ./sweep.sh
#   2. then start ./sweep_other.sh on node 1 (10.30.1.6)
#   Each per-config run blocks until both nodes finish (final barrier), so the
#   two scripts stay in lockstep.
# ===========================================================================
set -u

# ---- fixed parameters (edit here) -----------------------------------------
NODENUM=2          # total machines
THREADS=36         # worker threads on the compute node
KMAX=36            # threads/node  -> CNodeCount = ceil(THREADS/KMAX) = 1
MEMTHREADS=4       # directory (memory-side) threads
BULK=50            # bulk-load keys, millions  (~1 GB tree)
WARMUP=10          # warmup ops, millions      (populate the cache)
OP=30              # measured ops, millions    (<-- 30 M as requested)
CORRECT=0          # no post-run validation
TIMEBASE=1         # cap phases by wall-clock
EARLY=1            # first finisher stops the rest
INDEX=0            # 0 = DEX
ADMIT=0.1          # admission ratio
TUNE=0             # no auto-tune
ZIPF_THETA=0.99    # skew for the zipfian runs

# ---- sweep dimensions ------------------------------------------------------
CACHES=(32 64 128 256 512 1024)

RESULTS=./results
mkdir -p "$RESULTS"

# run_one <tag> <read> <range> <uniform> <zipf> <rpc> <cache_mb>
run_one() {
  local tag=$1 r=$2 rg=$3 uni=$4 zipf=$5 rpc=$6 cache=$7
  local logf="$RESULTS/${tag}.log"
  echo "===================================================================="
  echo ">>> [$(date '+%H:%M:%S')] CONFIG: $tag"
  echo "===================================================================="

  # Fresh memcached for this configuration (resets serverNum/clientNum).
  ./restartMemc.sh
  sleep 2

  # read insert update delete range = r 0 0 0 rg   (must sum to 100)
  sudo ./newbench "$NODENUM" "$r" 0 0 0 "$rg" "$THREADS" "$MEMTHREADS" "$cache" \
       "$uni" "$zipf" "$BULK" "$WARMUP" "$OP" "$CORRECT" "$TIMEBASE" "$EARLY" \
       "$INDEX" "$rpc" "$ADMIT" "$TUNE" "$KMAX" 2>&1 | tee "$logf"

  echo "<<< [$(date '+%H:%M:%S')] DONE: $tag  (log: $logf)"
  sleep 3
}

echo "DEX cache sweep starting at $(date).  48 configs, ${OP}M ops each."
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

echo "===================================================================="
echo "Sweep COMPLETE at $(date).  Per-config logs in $RESULTS/"
echo "Each log ends with: LATENCY BUCKETS (500 ns) / REMOTE OPERATIONS /"
echo "PATH-AWARE CACHE MISSES / Final throughput."
echo "===================================================================="
