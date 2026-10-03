#!/bin/bash
# ===========================================================================
# c2b -- Challenge 2a: CHIME at its shipped 70 MB tree cache, sweeping keys
#        (measurement summary Fig. 8)
#
#   x  keys (log): 10, 25, 50, 100, 200, 400 M
#   y  (a) lookup throughput  (b) 100-key scan latency  (c) inner footprint vs 70 MB
#   curves  pull | push on a miss (2 cores)
#   model   lookups degrade gradually once the inner nodes outgrow 70 MB; pulled
#           scans fall off a cliff, pushed scans stay flat
# Original CHIME (TREE_SETUP=model: 64-entry nodes) at its shipped cache: 100 MB
# total = 70 MB tree cache + 30 MB hotspot buffer. The model puts the cliff near
# 170 M keys. Each cell prints the tree it ran on (panel c). 400 M keys needs
# ~12-15 GB on the memory node: check free memory first.
#
#   bash fair/experiments/c2b_chime_keys.sh memory|compute
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${C2B_KEYS:=10 25 50 100 200 400}"
: "${C2B_TREE:=model}"
: "${C2B_CACHE:=100}"
: "${C2B_WORKLOADS:=point-uniform range-uniform}"

for k in $C2B_KEYS; do
  add_block "c2b_chime_${C2B_TREE}_k${k}" chime "$C2B_TREE" "$(count_cells "$C2B_CACHE" "0 2" "$C2B_WORKLOADS")" \
    "KEYS_M=$k" "CACHES=$C2B_CACHE" "MEMTHREADS=0 2" "WORKLOADS=$C2B_WORKLOADS" \
    "@min=$(awk -v k="$k" 'BEGIN{printf "%.1f", 2 + k/12}')"
done

apply_skip; show_plan; run_plan
