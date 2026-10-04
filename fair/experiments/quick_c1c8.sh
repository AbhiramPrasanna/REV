#!/bin/bash
# ===========================================================================
# quick_c1c8.sh <memory|compute> -- the smallest set of cells that gives one
# figure per challenge (c1..c8) on the height-10 trees (TREE_SETUP=deep).
# 55 cells, ~2 h. Every cell is reused wherever it can be:
#
#   c1  1 GB: pull + push at 1/2/4/8 cores                       (10 cells)
#   c2  8 and 128 MB: pull + push 2 cores (1 GB from c1)          (8)
#   c3  1 client at 1 GB (m=0) and 8 MB (m~3): pull + push        (8)
#   c4  100-key scans at 8 MB and 1 GB; 100% updates at 1 GB      (11)
#   c5  nothing new: lookups (c1, c3), scans and updates (c4)     (0)
#   c6  8 clients at 128 MB (with 1 client from c3, 40 from c2);
#       Zipf 0.99 at 1 GB                                         (8)
#   c7  50% inserts at 1 GB (0% from c1)                          (4)
#   c8  each system's own rule: lookups, scans, Zipf at 1 GB;
#       static pull/push for those phases come from c1/c4/c6      (6)
#
# Push = one request from the deepest cached node (DEX-R; CHIME min level 1;
# CHIME scans pushed with CHIME_SCAN_OFFLOAD_ALWAYS=1). CHIME runs stock.
# The first DEX cell prints "Tree height" and the first CHIME cell "[TREE]
# height=": both must be 10.
#
#   server 8:  bash fair/experiments/quick_c1c8.sh memory  2>&1 | tee ~/q_memory.out
#   server 6:  bash fair/experiments/quick_c1c8.sh compute 2>&1 | tee ~/q_compute.out
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

T=deep W=1024 M1=128 S="$SMALL_MB"
P1="CHIME_OFFLOAD_MIN_LEVEL=1"
SCAN=("WORKLOADS=range-uniform" "SCAN_LEN=100" "OPS_M=2" "WARMUP_M=2")

# c1 -- push needs memory-node CPU
add_block q_c1_dexr       dexr  $T 5 "CACHES=$W" "MEMTHREADS=0 1 2 4 8" "WORKLOADS=point-uniform" "@min=1.7"
add_block q_c1_chime_pull chime $T 1 "CACHES=$W" "MEMTHREADS=0"         "WORKLOADS=point-uniform"
add_block q_c1_chime_push chime $T 4 "CACHES=$W" "MEMTHREADS=1 2 4 8"   "WORKLOADS=point-uniform" "$P1"
# c2 -- cache budget
add_block q_c2_dexr  dexr  $T 4 "CACHES=$S $M1" "MEMTHREADS=0 2" "WORKLOADS=point-uniform" "@min=1.7"
add_block q_c2_chime chime $T 4 "CACHES=$S $M1" "MEMTHREADS=0 2" "WORKLOADS=point-uniform" "$P1"
# c3 -- depth of the miss, 1 client
add_block q_c3_dexr  dexr  $T 4 "CACHES=$W $S" "MEMTHREADS=0 1" "WORKLOADS=point-uniform" "${IDLE_ENV[@]}" "@min=2.5"
add_block q_c3_chime chime $T 4 "CACHES=$W $S" "MEMTHREADS=0 1" "WORKLOADS=point-uniform" "${IDLE_ENV[@]}" "$P1"
# c4 -- query type
add_block q_c4_dexr_scan  dexr  $T 4 "CACHES=$S $W" "MEMTHREADS=0 2" "${SCAN[@]}" "@min=1.7"
add_block q_c4_chime_scan chime $T 4 "CACHES=$S $W" "MEMTHREADS=0 2" "${SCAN[@]}" "CHIME_SCAN_OFFLOAD_ALWAYS=1"
add_block q_c4_dexr_upd   dexr  $T 2 "CACHES=$W" "MEMTHREADS=0 2" "WORKLOADS=point-uniform" "UPDATE_PCT=100" "@min=1.7"
add_block q_c4_chime_upd  chime $T 1 "CACHES=$W" "MEMTHREADS=0"   "WORKLOADS=point-uniform" "UPDATE_PCT=100"
# c6 -- load and skew
add_block q_c6_dexr_t8    dexr  $T 2 "THREADS=8" "CACHES=$M1" "MEMTHREADS=0 2" "WORKLOADS=point-uniform" "@min=1.7"
add_block q_c6_chime_t8   chime $T 2 "THREADS=8" "CACHES=$M1" "MEMTHREADS=0 2" "WORKLOADS=point-uniform" "$P1"
add_block q_c6_dexr_zipf  dexr  $T 2 "ZIPF_THETA=0.99" "CACHES=$W" "MEMTHREADS=0 2" "WORKLOADS=point-zipf" "@min=1.7"
add_block q_c6_chime_zipf chime $T 2 "ZIPF_THETA=0.99" "CACHES=$W" "MEMTHREADS=0 2" "WORKLOADS=point-zipf" "$P1"
# c7 -- coherence (inserts split nodes that clients have cached)
add_block q_c7_dexr_ins50  dexr  $T 2 "INSERT_PCT=50" "CACHES=$W" "MEMTHREADS=0 2" "WORKLOADS=point-uniform" "@min=1.7"
add_block q_c7_chime_ins50 chime $T 2 "INSERT_PCT=50" "CACHES=$W" "MEMTHREADS=0 2" "WORKLOADS=point-uniform" "$P1"
# c8 -- each system's own rule (stock DEX: bottom 4 levels; CHIME: inner misses only)
add_block q_c8_dex_rule        dex   $T 1 "CACHES=$W" "MEMTHREADS=2" "WORKLOADS=point-uniform" "@min=1.7"
add_block q_c8_dex_rule_scan   dex   $T 1 "CACHES=$W" "MEMTHREADS=2" "${SCAN[@]}" "@min=1.7"
add_block q_c8_dex_rule_zipf   dex   $T 1 "ZIPF_THETA=0.99" "CACHES=$W" "MEMTHREADS=2" "WORKLOADS=point-zipf" "@min=1.7"
add_block q_c8_chime_rule      chime $T 1 "CACHES=$W" "MEMTHREADS=2" "WORKLOADS=point-uniform"
add_block q_c8_chime_rule_scan chime $T 1 "CACHES=$W" "MEMTHREADS=2" "${SCAN[@]}"
add_block q_c8_chime_rule_zipf chime $T 1 "ZIPF_THETA=0.99" "CACHES=$W" "MEMTHREADS=2" "WORKLOADS=point-zipf"

apply_skip; show_plan; run_plan
