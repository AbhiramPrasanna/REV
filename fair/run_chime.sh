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
#   CHIME_SCAN_OFFLOAD_ALWAYS=1  every scan goes to the memory node (like DEX+)
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

[ -x "$CHIME_BUILD/micro_test" ] || { echo "build first: RUN_ID=$RUN_ID ./fair/build.sh chime" >&2; exit 1; }

max_mt=0; for m in $MEMTHREADS; do [ "$m" -gt "$max_mt" ] && max_mt=$m; done
# CHIME pins app thread i to core 2i+1 and dir threads to the top cores.
if [ "$role" = compute ]; then preflight_cores $((2 * THREADS + 2)); else preflight_cores $((2 * THREADS + 2 + 2 * max_mt)); fi

export MEM_IP CMP_IP MEMC_PORT THREADS
export BUILD_DIR="$CHIME_BUILD"
export LOG_DIR="$RESULTS_DIR/chime"
export BULK="$KEYS_M" WARMUP="$WARMUP_M" POINT_OP="$OPS_M" RANGE_OP="$OPS_M"
export SCAN_RANGE="$SCAN_LEN" ZIPF_THETA
export CACHE_MB="$CACHES" WORKLOADS
export LEAF_SET="$CHIME_LEAF_SET" LEAF_CACHE_PCT="${LEAF_CACHE_PCT:-50}"
export CHIME_MN_CLIENTS=0
export CHIME_SCAN_FROM_CACHE=1
export CHIME_SCAN_OFFLOAD_ALWAYS="${CHIME_SCAN_OFFLOAD_ALWAYS:-1}"
mkdir -p "$LOG_DIR"

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
