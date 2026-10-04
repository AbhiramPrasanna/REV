#!/bin/bash
# ===========================================================================
# c4 -- Challenge 4: lookups, scans and writes want different paths
#       (measurement summary Fig. 4; Fig. 8b for CHIME's scans)
#
#   (a) x  scan length 10, 100 keys          y  latency, 1 client
#   (b) x  scan length 10, 100, 1000 keys    y  throughput, 40 clients
#   (c) x  update fraction 0 (= c1), 50, 100 %   y  throughput, 40 clients
#   curves  pull | push (2 memory cores); caches 8 MB and warm (1 GB)
#   model   warm cache: a page B+tree's pulled scan wins at every length (a few
#           leaves read together); at a small cache every leaf costs the missing
#           levels again. CHIME: when level 1 is not cached its pulled scan falls
#           back to one point lookup per key, so push wins by orders of magnitude
#           (lesson 2a). Writes favour push on latency, pull on throughput.
#   fails if the same path wins for every operation
#
# Push scans: DEX-R pushes a scan when its leaves are not cached; CHIME with
# CHIME_SCAN_OFFLOAD_ALWAYS=1 (every scan pushed). CHIME has no write push, so
# writes are pull only for CHIME; DEX keeps its own write rule (bottom 4 levels).
# Left out on purpose: 1-client 1000-key scans (each cell would take 20+ min)
# and CHIME 1-client scans at 8 MB (one point lookup per key: ~17 min per cell).
# Known deviation: DEX's pulled scan restarts from the root for every leaf (the
# model assumes Sherman's batched leaf reads). 46 cells, ~2.2 h.
#
#   bash fair/experiments/c4_query_type.sh memory|compute
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${TREES:=deep}"
: "${C4_LENGTHS:=10 100 1000}"
: "${C4_IDLE_LENGTHS:=10 100}"
: "${C4_UPDATES:=50 100}"

for tree in $TREES; do
  for c in $(two_caches dexr "$tree"); do
    for L in $C4_LENGTHS; do
      if [ "$L" -ge 1000 ]; then ops=("OPS_M=1" "WARMUP_M=1"); else ops=("OPS_M=10" "WARMUP_M=10"); fi
      add_block "c4_dexr_${tree}_c${c}_L${L}" dexr "$tree" 2 "SCAN_LEN=$L" "${ops[@]}" \
        "CACHES=$c" "MEMTHREADS=0 2" "WORKLOADS=range-uniform"
      add_block "c4_chime_${tree}_c${c}_L${L}" chime "$tree" 2 "SCAN_LEN=$L" "${ops[@]}" \
        "CACHES=$c" "MEMTHREADS=0 2" "WORKLOADS=range-uniform" "CHIME_SCAN_OFFLOAD_ALWAYS=1"
    done
    for L in $C4_IDLE_LENGTHS; do
      add_block "c4_dexr_${tree}_c${c}_L${L}_1client" dexr "$tree" 2 "SCAN_LEN=$L" "${IDLE_ENV[@]}" \
        "CACHES=$c" "MEMTHREADS=0 1" "WORKLOADS=range-uniform" "@min=4"
    done
    if [ "$c" != "$SMALL_MB" ]; then
      add_block "c4_chime_${tree}_c${c}_L100_1client" chime "$tree" 2 "SCAN_LEN=100" "${IDLE_ENV[@]}" \
        "CACHES=$c" "MEMTHREADS=0 1" "WORKLOADS=range-uniform" "CHIME_SCAN_OFFLOAD_ALWAYS=1" "@min=4"
    fi
    for U in $C4_UPDATES; do
      add_block "c4_dexr_${tree}_c${c}_upd${U}" dexr "$tree" 2 "UPDATE_PCT=$U" \
        "CACHES=$c" "MEMTHREADS=0 2" "WORKLOADS=point-uniform"
      add_block "c4_chime_${tree}_c${c}_upd${U}" chime "$tree" 1 "UPDATE_PCT=$U" \
        "CACHES=$c" "MEMTHREADS=0" "WORKLOADS=point-uniform"
    done
  done
done

apply_skip; show_plan; run_plan
