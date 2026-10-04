#!/bin/bash
# ===========================================================================
# quick_c1c4_missing.sh <memory|compute> -- everything c1-c4 still needs on the
# height-10 trees (TREE_SETUP=deep), with the compute node's idle directory
# threads parked on one CPU (REV_PARK_CMP_DIRS=1, see params.sh).
#
#   memory threads 10/14/16, DEX and CHIME as shipped (hotspot buffer on):
#     c1  1 GB lookups: 10/14/16 (1/2/4/8 are in q_c1_*)    (DEX 3, CHIME 3)
#     c2  8 and 128 MB lookups                               (DEX 6, CHIME 6)
#     c4  100-key scans at 8 MB and 1 GB; DEX updates        (DEX 9, CHIME 6)
#   CHIME with its hotspot buffer off (CHIME_HOTSPOT=0), above 50 MB only:
#     c1  1 GB: pull, push at 1/2/4/8/10/14/16               (8)
#     c2  128 MB: pull, push at 2/10/14/16                   (5)
#     c3  1 GB, 1 client: pull, push                         (2)
#     c4  1 GB scans: pull, push at 2/10/14/16; updates      (6)
# 54 cells, ~1.9 h. Only cells that have not run yet. c3 needs no 10/14/16: one client keeps one memory thread busy.
#
# Cores. Memory node: thread k on CPU 80-k (79, 78, ... 64), one physical core
# each. Compute node: clients on CPUs 0-39 (one per physical core); the directory
# threads DEX and CHIME also start there (as many as on the memory node, all
# idle, all spinning) share CPU 79, so only client 39 shares its core.
#
#   server 8:  bash fair/experiments/quick_c1c4_missing.sh memory  2>&1 | tee ~/qm_memory.out
#   server 6:  bash fair/experiments/quick_c1c4_missing.sh compute 2>&1 | tee ~/qm_compute.out
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

T=deep W=1024 M1=128 S="$SMALL_MB"
H="10 14 16"
P1="CHIME_OFFLOAD_MIN_LEVEL=1"
PARK="REV_PARK_CMP_DIRS=1"
OFF="CHIME_HOTSPOT=0"
SCAN=("WORKLOADS=range-uniform" "SCAN_LEN=100" "OPS_M=2" "WARMUP_M=2")
n() { count_cells x "$1" x; }
n2() { count_cells "a b" "$1" x; }

# ---- memory threads up to 16, as shipped
add_block qm_c1_dexr       dexr  $T $(n "$H") "CACHES=$W" "MEMTHREADS=$H" "WORKLOADS=point-uniform" "$PARK" "@min=2.4"
add_block qm_c1_chime_push chime $T $(n "$H") "CACHES=$W" "MEMTHREADS=$H" "WORKLOADS=point-uniform" "$P1" "$PARK" "@min=1.8"
add_block qm_c2_dexr  dexr  $T $(n2 "$H") "CACHES=$S $M1" "MEMTHREADS=$H" "WORKLOADS=point-uniform" "$PARK" "@min=2.4"
add_block qm_c2_chime chime $T $(n2 "$H") "CACHES=$S $M1" "MEMTHREADS=$H" "WORKLOADS=point-uniform" "$P1" "$PARK" "@min=1.8"
add_block qm_c4_dexr_scan  dexr  $T $(n2 "$H") "CACHES=$S $W" "MEMTHREADS=$H" "${SCAN[@]}" "$PARK" "@min=2.4"
add_block qm_c4_chime_scan chime $T $(n2 "$H") "CACHES=$S $W" "MEMTHREADS=$H" "${SCAN[@]}" "CHIME_SCAN_OFFLOAD_ALWAYS=1" "$PARK" "@min=1.8"
add_block qm_c4_dexr_upd   dexr  $T $(n "$H") "CACHES=$W" "MEMTHREADS=$H" "WORKLOADS=point-uniform" "UPDATE_PCT=100" "$PARK" "@min=2.4"

# ---- CHIME with the hotspot buffer off
add_block qn_c1_chime_pull chime $T 1 "CACHES=$W" "MEMTHREADS=0" "WORKLOADS=point-uniform" "$OFF" "$PARK" "@min=1.8"
add_block qn_c1_chime_push chime $T $(n "1 2 4 8 $H") "CACHES=$W" "MEMTHREADS=1 2 4 8 $H" \
  "WORKLOADS=point-uniform" "$OFF" "$P1" "$PARK" "@min=1.8"
add_block qn_c2_chime chime $T $(n "0 2 $H") "CACHES=$M1" "MEMTHREADS=0 2 $H" \
  "WORKLOADS=point-uniform" "$OFF" "$P1" "$PARK" "@min=1.8"
add_block qn_c3_chime chime $T 2 "CACHES=$W" "MEMTHREADS=0 1" "WORKLOADS=point-uniform" "$OFF" "$P1" "$PARK" \
  "${IDLE_ENV[@]}" "@min=2.5"
add_block qn_c4_chime_scan chime $T $(n "0 2 $H") "CACHES=$W" "MEMTHREADS=0 2 $H" "${SCAN[@]}" \
  "CHIME_SCAN_OFFLOAD_ALWAYS=1" "$OFF" "$PARK" "@min=1.8"
add_block qn_c4_chime_upd chime $T 1 "CACHES=$W" "MEMTHREADS=0" "WORKLOADS=point-uniform" "UPDATE_PCT=100" "$OFF" "$PARK" "@min=1.8"

apply_skip; show_plan; run_plan
