#!/bin/bash
# ===========================================================================
# run.sh  --  single DEX benchmark run, NODE 0 (memcached host: 10.30.1.9)
#
# Restarts memcached, then launches one newbench configuration.  Edit the
# variables below, run this on node 0, then run ./run_other.sh on node 1.
# For the full cache sweep use ./sweep.sh instead.
# ===========================================================================
set -u

# ---- workload (ratios must sum to 100) ------------------------------------
READ=100; INSERT=0; UPDATE=0; DELETE=0; RANGE=0

# ---- topology & sizes ------------------------------------------------------
NODENUM=2          # total machines
THREADS=36         # worker threads across all compute nodes
KMAX=36            # threads/node -> CNodeCount = ceil(THREADS/KMAX)
MEMTHREADS=4       # directory (memory-side) threads
CACHE_MB=256       # compute-node buffer cache
UNIFORM=0          # 0 = zipfian, 1 = uniform
ZIPF=0.99          # skew (used when UNIFORM=0)
BULK=50            # bulk-load keys, millions
WARMUP=10          # warmup ops, millions
OP=50              # measured ops, millions

# ---- knobs -----------------------------------------------------------------
CORRECT=0          # 1 = validate tree after run
TIMEBASE=1         # cap phases by wall-clock
EARLY=1            # first finisher stops the rest
INDEX=0            # 0 = DEX, 1 = Sherman, 2 = SMART
RPC=1              # offloading: 1 = on (pushdown), 0 = off
ADMIT=0.1          # admission ratio
TUNE=0             # auto-tune off

./restartMemc.sh
sleep 2
sudo ./newbench "$NODENUM" "$READ" "$INSERT" "$UPDATE" "$DELETE" "$RANGE" \
     "$THREADS" "$MEMTHREADS" "$CACHE_MB" "$UNIFORM" "$ZIPF" "$BULK" "$WARMUP" \
     "$OP" "$CORRECT" "$TIMEBASE" "$EARLY" "$INDEX" "$RPC" "$ADMIT" "$TUNE" "$KMAX"
