#!/bin/bash
# ===========================================================================
# fair/run_chime.sh <memory|compute> -- CHIME over the fair matrix:
#     MEMTHREADS x (leaf cache 0/1) x WORKLOADS x CACHES
# memory threads 0 = no offloading (one directory thread, only for the chunk
# allocation the bulk load needs). k >= 1 = offloading on, k directory threads.
#
# CHIME+ settings used for every "on" cell (see ARCHITECTURE.md §6):
#   CHIME_MN_CLIENTS=0           clients only on the compute node (like DEX/DART)
#   CHIME_SCAN_FROM_CACHE=1      scan requests start from the deepest cached node
#   CHIME_SCAN_OFFLOAD_ALWAYS    stress: 0 (scans offload only on a cache miss); fair: 1 (every scan, like DEX+)
# Tree: TREE_SETUP=stress (default) = stock shuffled insert load; TREE_SETUP=fair
# = CHIME_BULK_BUILD=1, built with DEX's fill (same shape as DEX). See params.sh.
# With memory threads 0 the two scan switches have no effect (offloading is off).
#
# Driven through CHIME/run/run_leaf_cache.sh (same handshake, memcached reset,
# log layout and CSV as every earlier CHIME sweep), once per memory-thread count.
# CHIME node 0 is the MEMORY node: server 8 hosts memcached. Start either first.
#
#   server 8:  RUN_ID=fair1 ./fair/run_chime.sh memory
#   server 6:  RUN_ID=fair1 ./fair/run_chime.sh compute
#
# Output: fair/results/$RUN_ID/chime/sweep_mt<k>/summary_<role>.csv + logs
# ===========================================================================
set -uo pipefail
role="${1:?usage: run_chime.sh <memory|compute>}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/params.sh"

[ -x "$CHIME_BUILD/micro_test" ] || { echo "build first: RUN_ID=$RUN_ID TREE_SETUP=$TREE_SETUP ./fair/build.sh chime" >&2; exit 1; }
want="inner_span=$CHIME_INTERNAL_SPAN leaf_span=$CHIME_LEAF_SPAN value=$VALUE_B"
have="$(cat "$CHIME_BUILD/build_stamp.txt" 2>/dev/null || echo none)"
# builds made before the stamp existed are the 16/16 ones in build_fair
[ "$have" = none ] && [ "$CHIME_INTERNAL_SPAN:$CHIME_LEAF_SPAN" = 16:16 ] && have="$want"
if [ "$have" != "$want" ]; then
  echo "CHIME binary in $CHIME_BUILD was built for [$have], this run wants [$want]." >&2
  echo "Rebuild on BOTH servers: RUN_ID=$RUN_ID TREE_SETUP=$TREE_SETUP ./fair/build.sh chime" >&2
  exit 1
fi

max_mt=0; for m in $MEMTHREADS; do [ "$m" -gt "$max_mt" ] && max_mt=$m; done
# Clients on CPUs 0..THREADS-1 (REV_CLIENT_PIN=linear), dir threads on REV_DIR_CPUS.
if [ "$role" = compute ]; then preflight_cores $((THREADS + 2)); else preflight_cores $((THREADS + 2 + max_mt)); fi

export MEM_IP CMP_IP MEMC_PORT THREADS
export BUILD_DIR="$CHIME_BUILD"
export LOG_DIR="$RESULTS_DIR/chime"
export BULK="$KEYS_M" WARMUP="$WARMUP_M" POINT_OP="$OPS_M" RANGE_OP="$OPS_M"
export SCAN_RANGE="$SCAN_LEN" ZIPF_THETA
export CACHE_MB="$CACHES" WORKLOADS
export LEAF_SET="$CHIME_LEAF_SET" LEAF_CACHE_PCT="${LEAF_CACHE_PCT:-50}"
export CHIME_MN_CLIENTS=0
export CHIME_SCAN_FROM_CACHE="${CHIME_SCAN_FROM_CACHE:-1}"
export CHIME_SCAN_OFFLOAD_ALWAYS="${CHIME_SCAN_OFFLOAD_ALWAYS:-1}"
export CHIME_SORTED_LOAD CHIME_BULK_BUILD CHIME_BUILD_LEAF_KEYS CHIME_BUILD_INNER_FANOUT
mkdir -p "$LOG_DIR"
if [ "$CHIME_BULK_BUILD" = 1 ]; then
  echo "CHIME setup ($TREE_SETUP): ${CHIME_INTERNAL_SPAN}/${CHIME_LEAF_SPAN}-entry inner/leaf nodes, tree bulk-built with $CHIME_BUILD_LEAF_KEYS keys per leaf and $CHIME_BUILD_INNER_FANOUT children per inner node"
else
  echo "CHIME setup ($TREE_SETUP): ${CHIME_INTERNAL_SPAN}/${CHIME_LEAF_SPAN}-entry inner/leaf nodes, keys inserted $( [ "$CHIME_SORTED_LOAD" = 1 ] && echo sorted || echo shuffled ) (stock load)"
fi
echo "  each cell prints '>> tree:' (levels, inner and leaf nodes and MB) and '>> result:'"
pin_report

for mt in $MEMTHREADS; do
  if [ "$mt" -eq 0 ]; then
    export SEQUENCE=off DIR_THREADS=1
  else
    export SEQUENCE=on DIR_THREADS="$mt"
  fi
  export SEQ_TS="mt${mt}"
  echo "=================================================================="
  echo ">>> CHIME fair: memory threads $mt (offload $SEQUENCE, dir threads $DIR_THREADS), $role"
  echo "=================================================================="
  if ! "$REV_DIR/CHIME/run/run_leaf_cache.sh" "$role"; then
    echo "CHIME fair: memory-threads=$mt failed on $role; see $LOG_DIR/sweep_mt${mt}/" >&2
    exit 1
  fi
done
echo "CHIME fair sweep ($role) done -> $LOG_DIR"
