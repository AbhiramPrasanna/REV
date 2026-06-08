#!/bin/bash
# ===========================================================================
# run_other.sh  --  single DEX benchmark run, NODE 1 (memory node: 10.30.1.6)
#
# Mirror of run.sh WITHOUT the memcached restart (node 0 owns memcached).
# Start AFTER run.sh on node 0.  The argument list MUST match run.sh exactly.
# ===========================================================================
set -u

# ---- workload (ratios must sum to 100) ------------------------------------
READ=100; INSERT=0; UPDATE=0; DELETE=0; RANGE=0

# ---- topology & sizes ------------------------------------------------------
NODENUM=2
THREADS=36
KMAX=36
MEMTHREADS=4
CACHE_MB=256
UNIFORM=0
ZIPF=0.99
BULK=50
WARMUP=10
OP=50

# ---- knobs -----------------------------------------------------------------
CORRECT=0
TIMEBASE=1
EARLY=1
INDEX=0
RPC=1
ADMIT=0.1
TUNE=0

# Give node 0 time to restart memcached before we register.
sleep 8
sudo ./newbench "$NODENUM" "$READ" "$INSERT" "$UPDATE" "$DELETE" "$RANGE" \
     "$THREADS" "$MEMTHREADS" "$CACHE_MB" "$UNIFORM" "$ZIPF" "$BULK" "$WARMUP" \
     "$OP" "$CORRECT" "$TIMEBASE" "$EARLY" "$INDEX" "$RPC" "$ADMIT" "$TUNE" "$KMAX"
