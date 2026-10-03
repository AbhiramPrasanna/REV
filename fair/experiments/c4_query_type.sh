#!/bin/bash
# ===========================================================================
# c4 -- Challenge 4: lookups, scans and writes want different paths
#       (measurement summary Fig. 4)
#
#   (a) x  scan length 10, 100, 1000 keys   y  latency, 1 client
#   (b) x  scan length 10, 100, 1000 keys   y  throughput, 40 clients
#   (c) x  update fraction 50, 100 %        y  throughput, 40 clients
#       (0 % = the c1 warm lookup cells)
#   curves  pull | push (2 memory cores) for the page B+tree (DEX-R) and the
#           hashed-leaf B+tree (CHIME)
#   model   warm cache: a page B+tree's pulled scan wins at every length (a few
#           1 KB leaves); writes favour push on latency, pull on throughput
#   fails if the same path wins for every operation
#
# Warm cache. Push scans: DEX-R pushes a scan when its leaves are not cached;
# CHIME with CHIME_SCAN_OFFLOAD_ALWAYS=1 (every scan pushed). Writes: CHIME has
# no write push, so pull only; DEX keeps its own write rule (bottom 4 levels).
# Where we expect to deviate: DEX's pulled scan restarts from the root for every
# leaf (the model assumes Sherman's batched leaf reads).
# 26 cells, ~1.7 h.
#
#   bash fair/experiments/c4_query_type.sh memory|compute
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${TREES:=model}"
: "${C4_LENGTHS:=10 100 1000}"
: "${C4_IDLE_CHIME_LEN:=100}"     # one CHIME 1-client length: each such cell loads for ~11 min
: "${C4_UPDATES:=50 100}"

for tree in $TREES; do
  cd_=$(size_of dexr "$tree" INNER); cc=$(size_of chime "$tree" INNER)
  for L in $C4_LENGTHS; do
    if [ "$L" -ge 1000 ]; then ops=("OPS_M=2" "WARMUP_M=4"); else ops=("OPS_M=10" "WARMUP_M=10"); fi
    add_block "c4_dexr_${tree}_L${L}" dexr "$tree" 2 "SCAN_LEN=$L" "${ops[@]}" \
      "CACHES=$cd_" "MEMTHREADS=0 2" "WORKLOADS=range-uniform"
    add_block "c4_chime_${tree}_L${L}" chime "$tree" 2 "SCAN_LEN=$L" "${ops[@]}" \
      "CACHES=$cc" "MEMTHREADS=0 2" "WORKLOADS=range-uniform" "CHIME_SCAN_OFFLOAD_ALWAYS=1"
    add_block "c4_dexr_${tree}_L${L}_c1" dexr "$tree" 2 "SCAN_LEN=$L" "${IDLE_ENV[@]}" \
      "CACHES=$cd_" "MEMTHREADS=0 1" "WORKLOADS=range-uniform" "@min=3"
  done
  add_block "c4_chime_${tree}_L${C4_IDLE_CHIME_LEN}_c1" chime "$tree" 2 "SCAN_LEN=$C4_IDLE_CHIME_LEN" \
    "${IDLE_ENV[@]}" "CACHES=$cc" "MEMTHREADS=0 1" "WORKLOADS=range-uniform" \
    "CHIME_SCAN_OFFLOAD_ALWAYS=1" "@min=13"
  for U in $C4_UPDATES; do
    add_block "c4_dexr_${tree}_upd${U}" dexr "$tree" 2 "UPDATE_PCT=$U" \
      "CACHES=$cd_" "MEMTHREADS=0 2" "WORKLOADS=point-uniform"
    add_block "c4_chime_${tree}_upd${U}" chime "$tree" 1 "UPDATE_PCT=$U" \
      "CACHES=$cc" "MEMTHREADS=0" "WORKLOADS=point-uniform"
  done
done

apply_skip; show_plan; run_plan
