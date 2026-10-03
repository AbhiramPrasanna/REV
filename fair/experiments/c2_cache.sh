#!/bin/bash
# ===========================================================================
# c2 -- Challenge 2: the cache budget flips the winner   (measurement summary Fig. 2, 2b)
#
#   x  cache / inner footprint (log)    y  (a) throughput   (b) round trips per op
#   curves  pull | push on a miss, 2 and 4 cores | oracle (better per point) | DART
#   model   pull collapses once the bottom inner level stops fitting; push from
#           the missed node stays nearly flat; they cross at a budget that
#           differs by structure (~6 MB for a 1 KB-page B+tree at 1e9 keys)
#   fails if the curves never cross
#
# Sweeps run from 8 MB to just past "inner nodes fit", plus one "whole tree
# fits" point per tree. Round trips: DEX's reads/op + requests/op counters.
# Systems: dex, dexr, chime (lookups + 100-key scans), dart (pull reference).
# Where we expect to deviate: stock DEX push still pulls the levels above its
# bottom 4 (flat with cores); DEX's pulled scans read one leaf at a time.
#
#   bash fair/experiments/c2_cache.sh memory|compute     (DRY_RUN=1 to preview)
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${SYSTEMS_C:=dex dexr chime dart}"
: "${TREES:=stress fair}"
: "${C2_MEMTHREADS:=0 2 4}"
: "${C2_WORKLOADS:=point-uniform range-uniform}"
: "${C2_DEX_STRESS:=8 32 128 512 1024 2600 5200}"     # 5200: whole tree fits
: "${C2_DEX_FAIR:=8 32 64 128 256 640 3300}"          # 3300: whole tree fits
: "${C2_CHIME_STRESS:=8 16 32 64 128 192}"
: "${C2_CHIME_FAIR:=8 32 64 128 256 640}"
: "${C2_DART:=8 128 1024}"
: "${WHOLE_WARMUP_M:=200}"     # DEX admits 1 leaf in 10: fill the whole tree

for sys in $SYSTEMS_C; do
  if [ "$sys" = dart ]; then
    add_block "c2_dart" dart stress "$(count_cells "$C2_DART" x "$C2_WORKLOADS")" \
      "CACHES=$C2_DART" "WORKLOADS=$C2_WORKLOADS"
    continue
  fi
  for tree in $TREES; do
    v="$(echo "C2_$(real_sys "$sys")_${tree}" | tr a-z A-Z)"; read -ra cs <<< "${!v}"
    last=${cs[${#cs[@]}-1]}
    rest="${cs[*]:0:${#cs[@]}-1}"
    if [ "$(real_sys "$sys")" = dex ]; then
      # all but the whole-tree point, then the whole-tree point with a long warmup
      add_block "c2_${sys}_${tree}" "$sys" "$tree" \
        "$(count_cells "$rest" "$C2_MEMTHREADS" "$C2_WORKLOADS")" \
        "CACHES=$rest" "MEMTHREADS=$C2_MEMTHREADS" "WORKLOADS=$C2_WORKLOADS"
      add_block "c2_${sys}_${tree}_whole" "$sys" "$tree" \
        "$(count_cells "$last" "$C2_MEMTHREADS" "$C2_WORKLOADS")" \
        "CACHES=$last" "MEMTHREADS=$C2_MEMTHREADS" "WORKLOADS=$C2_WORKLOADS" \
        "WARMUP_M=$WHOLE_WARMUP_M" "@min=4"
    else
      add_block "c2_${sys}_${tree}" "$sys" "$tree" \
        "$(count_cells "${cs[*]}" "$C2_MEMTHREADS" "$C2_WORKLOADS")" \
        "CACHES=${cs[*]}" "MEMTHREADS=$C2_MEMTHREADS" "WORKLOADS=$C2_WORKLOADS"
    fi
  done
done

apply_skip; show_plan; run_plan
