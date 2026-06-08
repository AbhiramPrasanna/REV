#!/bin/bash
# ===========================================================================
# sweep.sh  --  DEX OFFLOADING study  (run on NODE 0 / memcached host: 10.30.1.9)
#
# Compares DEX WITHOUT offloading vs WITH offloading across:
#     workload     : 100% point-lookup,  100% range-scan
#     distribution : uniform,            zipfian (theta = 0.99)
#     offloading   : OFF (rpc_rate=0, pure caching)
#                    ON  (rpc_rate=1, RPC pushdown of inner-subtree misses)
#     cache size   : 16, 32, 48, 64, 128, 256 MB
# => 2 x 2 x 2 x 6 = 48 configurations, 30 M operations each.
#
# *** REQUIRES a MANUAL_PUSHDOWN build ***
#   cmake -DCMAKE_BUILD_TYPE=Release -DMANUAL_PUSHDOWN=ON .. && make -j
# Without it, DEX's adaptive policy IGNORES rpc_rate and offload on/off are
# identical (see leanstore_cache.h LATENCY_COLLECT).
#
# IMPORTANT, by DEX's design:
#  - RANGE scans have NO pushdown path -> offload on/off are identical for range
#    (kept here as a control; the difference, if any, lives in point-lookups).
#  - Pushdown only engages on INNER-subtree misses, which require the cache to be
#    smaller than the ~60 MB inner-node footprint. Hence small caches below;
#    at >=128 MB inner fits and offloading converges to no-op.
#
# memcached is restarted before every configuration (fresh registration).
# Topology: NODENUM=2, THREADS<=KMAX -> CNodeCount=1 (node 0 compute, node 1 mem).
#
# HOW TO RUN:
#   1. start this on node 0 (10.30.1.9):   ./sweep.sh
#   2. then start ./sweep_other.sh on node 1 (10.30.1.6)
# ===========================================================================
set -u

# ---- fixed parameters (edit here) -----------------------------------------
NODENUM=2          # total machines
THREADS=16         # worker threads (small caches + many threads can crash DEX)
KMAX=36            # threads/node  -> CNodeCount = ceil(THREADS/KMAX) = 1
MEMTHREADS=4       # directory (memory-side) threads
BULK=50            # bulk-load keys, millions  (~1.7 GB leaf, ~60 MB inner)
WARMUP=10          # warmup ops, millions      (populate the cache)
OP=30              # measured ops, millions
CORRECT=0          # no post-run validation
TIMEBASE=1         # cap phases by wall-clock
EARLY=1            # first finisher stops the rest
INDEX=0            # 0 = DEX
ADMIT=0.1          # admission ratio (DEX default for leaves)
TUNE=0             # no auto-tune
ZIPF_THETA=0.99    # skew for the zipfian runs

# ---- sweep dimensions ------------------------------------------------------
# Small caches (< ~60 MB inner footprint) are where pushdown engages; 128/256
# are the convergence point where inner fits and offloading becomes a no-op.
CACHES=(16 32 48 64 128 256)

RESULTS=./results
mkdir -p "$RESULTS"

# --- preflight: catch a broken environment before burning hours on 48 runs --
if [ ! -x ./newbench ]; then
  echo "ERROR: ./newbench not found here. Build first and run from build/." >&2
  exit 1
fi
if ldd ./newbench 2>/dev/null | grep -q "not found"; then
  echo "ERROR: newbench has unresolved shared libraries:" >&2
  ldd ./newbench | grep "not found" >&2
  echo "Register the missing library directory and rerun, e.g. for cityhash:" >&2
  echo "  echo /usr/local/lib | sudo tee /etc/ld.so.conf.d/local.conf && sudo ldconfig" >&2
  exit 1
fi
FIRST_RUN=1

# run_one <tag> <read> <range> <uniform> <zipf> <rpc> <cache_mb>
run_one() {
  local tag=$1 r=$2 rg=$3 uni=$4 zipf=$5 rpc=$6 cache=$7
  local logf="$RESULTS/${tag}.log"
  echo "===================================================================="
  echo ">>> [$(date '+%H:%M:%S')] CONFIG: $tag"
  echo "===================================================================="

  # Fresh memcached for this configuration (resets serverNum/clientNum).
  if ! ./restartMemc.sh; then
    echo "ABORT: memcached restart failed for $tag (see message above)." >&2
    exit 1
  fi
  sleep 2

  # read insert update delete range = r 0 0 0 rg   (must sum to 100)
  sudo ./newbench "$NODENUM" "$r" 0 0 0 "$rg" "$THREADS" "$MEMTHREADS" "$cache" \
       "$uni" "$zipf" "$BULK" "$WARMUP" "$OP" "$CORRECT" "$TIMEBASE" "$EARLY" \
       "$INDEX" "$rpc" "$ADMIT" "$TUNE" "$KMAX" 2>&1 | tee "$logf"
  local rc=${PIPESTATUS[0]}

  if [ "$rc" -ne 0 ]; then
    echo "WARNING: newbench exited with code $rc for $tag" >&2
    if [ "$FIRST_RUN" = 1 ]; then
      echo "ABORT: first run failed -> environment not ready; fix it before sweeping." >&2
      exit 1
    fi
  fi
  FIRST_RUN=0

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
