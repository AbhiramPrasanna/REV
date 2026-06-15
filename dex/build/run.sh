#!/bin/bash
# ===========================================================================
# run.sh  --  single DEX benchmark run, NODE 0 (memcached host: 10.30.1.9)
#
# Restarts memcached, then launches one newbench configuration.  Edit the
# variables below, run this on node 0, then run ./run_other.sh on node 1.
# For the full cache sweep use ./sweep.sh instead.
# ===========================================================================
set -u

# ===========================================================================
# OFFLOAD-FAVORABLE preset (the regime where pushdown should win on BOTH
# throughput and tail). Build with  -DMANUAL_PUSHDOWN=ON  so RPC is the knob.
# A/B the offload: run once with RPC=1 (offload) and once with RPC=0 (caching),
# compare Final throughput and the REMOTE (miss/rpc) p99 in the report.
# Tree shape (set in include/cache/btree_node.h): inner fanout 5 / leaf fanout
# 25 -> height ~10, ~2M leaves (~1GB) and ~500K inner nodes (~256MB in cache,
# since the cache slot is uniform = leafPageSize).
# Why these values favor offloading:
#   RANGE=100 / READ=100 - both win: a 100-key scan spans ~4 leaves (offload =
#                2 RTT vs ~4 reads); a lookup ships 8B vs reading a 512B leaf.
#   UNIFORM=1  - cold access, no hot set to cache -> caching is pure churn
#   CACHE_MB   - MUST hold the ~256MB inner working set (so the inner path stays
#                resident and misses are leaf-only) while leaves still churn.
#                Too small -> inner churns too and swamps the offload signal.
#   MEMTHREADS - MN directory threads that service RPCs. HARD CAP = NR_DIRECTORY
#                (4, in include/Common.h). To go higher (more RPC capacity) you
#                must raise NR_DIRECTORY and rebuild both nodes.
# Keep this block IDENTICAL in run_other.sh.
# ===========================================================================

# ---- workload (ratios must sum to 100) ------------------------------------
# Both win with the decoupled shape. Scans: RANGE=100. Lookups: READ=100;RANGE=0.
READ=0; INSERT=0; UPDATE=0; DELETE=0; RANGE=100

# ---- topology & sizes ------------------------------------------------------
NODENUM=2          # total machines
THREADS=36         # worker threads across all compute nodes
KMAX=36            # threads/node -> CNodeCount = ceil(THREADS/KMAX)
MEMTHREADS=4       # directory (memory-side) threads -- MUST be <= NR_DIRECTORY (4)
CACHE_MB=512       # must hold the ~256MB inner set; rest caches churning leaves
UNIFORM=1          # 0 = zipfian, 1 = uniform (uniform favors offloading)
ZIPF=0.99          # skew (used when UNIFORM=0)
BULK=50            # bulk-load keys, millions
WARMUP=10          # warmup ops, millions
OP=50              # measured ops, millions

# ---- knobs -----------------------------------------------------------------
CORRECT=0          # 1 = validate tree after run
TIMEBASE=1         # cap phases by wall-clock
EARLY=1            # first finisher stops the rest
INDEX=0            # 0 = DEX, 1 = Sherman, 2 = SMART
RPC=0              # offloading fraction [0,1]; A/B: 1 vs 0 (needs MANUAL_PUSHDOWN)
ADMIT=0.1          # admission ratio (caching share of NON-offloaded leaves)
TUNE=0             # auto-tune off

./restartMemc.sh
sleep 2
sudo ./newbench "$NODENUM" "$READ" "$INSERT" "$UPDATE" "$DELETE" "$RANGE" \
     "$THREADS" "$MEMTHREADS" "$CACHE_MB" "$UNIFORM" "$ZIPF" "$BULK" "$WARMUP" \
     "$OP" "$CORRECT" "$TIMEBASE" "$EARLY" "$INDEX" "$RPC" "$ADMIT" "$TUNE" "$KMAX"
