#!/bin/bash
# ===========================================================================
# c2b -- Challenge 2a: CHIME at its shipped 70 MB tree cache, sweeping keys
#        (measurement summary Fig. 8)
#
#   x  keys (log): 10, 25, 50, 100, 200 M
#   y  (a) lookup throughput  (b) 100-key scan latency  (c) inner footprint vs 70 MB
#   curves  pull | push on a miss (2 cores)
#   model   lookups degrade gradually once the inner nodes outgrow 70 MB; pulled
#           scans fall off a cliff, pushed scans stay flat
# Each cell prints the tree it ran on (panel c). 200 M keys needs ~12 GB on the
# memory node: check free memory first.
#
#   bash fair/experiments/c2b_chime_keys.sh memory|compute
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${C2B_KEYS:=10 25 50 100 200}"
: "${C2B_WORKLOADS:=point-uniform range-uniform}"

for k in $C2B_KEYS; do
  add_block "c2b_chime_k${k}" chime stress "$(count_cells 70 "0 2" "$C2B_WORKLOADS")" \
    "KEYS_M=$k" "CACHES=70" "MEMTHREADS=0 2" "WORKLOADS=$C2B_WORKLOADS" \
    "@min=$(awk -v k="$k" 'BEGIN{printf "%.1f", 2 + k/12}')"
done

apply_skip; show_plan; run_plan
