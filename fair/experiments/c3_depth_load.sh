#!/bin/bash
# ===========================================================================
# c3 -- Challenge 3: the depth of the miss, and load    (measurement summary Fig. 3)
#
#   x  uncached inner levels m (from each cache's reads per lookup)
#   y  (a) median latency   (b) heatmap: winner over (m, rho)
#   curves  pull | push at several loads
#   model   pull = (m+1)·R; push = R_rpc + t_msg + (m+1)·t_lvl, flat until the
#           memory core is busy; the crossover m* grows with load
#   fails if m* is the same at every load
#
# Idle part (this script): ONE client -- the model's idle latency -- lookups,
# the c2 cache sweep (m from ~9 down to 0), pull (0) vs push (1 thread).
# These cells also measure the model's constants on our cluster (R, R_rpc,
# t_msg, t_lvl). Loaded part: c2's 40-client cells at 2 and 4 cores, with rho
# from memory-node CPU.
# Systems: dexr and chime push from the deepest cached node (push latency vs m
# as in the model); stock dex is included to show its fixed push depth.
#
# One client with DEX: run_dex.sh passes THREADS as DEX's max thread count, so the
# compute node still registers first; check with one cell first:
#   C3_ONE=1 bash fair/experiments/c3_depth_load.sh <role>
#
#   bash fair/experiments/c3_depth_load.sh memory|compute
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${SYSTEMS_C:=dexr chime}"            # add "dex" for stock DEX
: "${TREES:=model}"                   # original node formats (stress / fair also work)
: "${C2_DEX_STRESS:=8 32 128 512 1024 2600}"   # CHIME sweeps: C2_CHIME_<TREE> in common.sh
: "${C2_DEX_FAIR:=8 32 64 128 256 640}"
: "${C2_DEX_MODEL:=2 4 8 16 32 64 128}"

for sys in $SYSTEMS_C; do
  for tree in $TREES; do
    v="$(echo "C2_$(real_sys "$sys")_${tree}" | tr a-z A-Z)"; caches="${!v}"
    [ "${C3_ONE:-0}" = 1 ] && caches=128
    case "$(real_sys "$sys"):$tree" in dex:*) m=5 ;; chime:stress) m=8 ;; chime:model) m=6 ;; *) m=4 ;; esac
    add_block "c3_${sys}_${tree}_idle" "$sys" "$tree" \
      "$(count_cells "$caches" "0 1" point-uniform)" \
      "CACHES=$caches" "MEMTHREADS=0 1" "WORKLOADS=point-uniform" "${IDLE_ENV[@]}" "@min=$m"
    [ "${C3_ONE:-0}" = 1 ] && break 2
  done
done

apply_skip; show_plan; run_plan
