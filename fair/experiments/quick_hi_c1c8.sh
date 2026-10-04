#!/bin/bash
# ===========================================================================
# quick_hi_c1c8.sh <memory|compute> -- the push cells of quick_c1c8.sh again at
# 10, 14 and 16 memory threads (height-10 trees, TREE_SETUP=deep). Pull cells are
# not repeated (pull uses no memory threads; quick_c1c8 has them).
# 69 cells, ~2.5 h. Run after quick_c1c8.sh, with the same build.
#
#   c1  1 GB lookups: push at 10/14/16                      (6 cells)
#   c2  8 and 128 MB lookups: push                           (12)
#   c3  nothing: 1 client keeps at most one memory thread busy
#   c4  100-key scans at 8 MB and 1 GB: push; DEX updates     (15)
#   c5  nothing: built from c1, c3, c4
#   c6  8 clients at 128 MB, Zipf 0.99 at 1 GB: push          (12)
#   c7  50% inserts at 1 GB: push                            (6)
#   c8  each system's own rule: lookups, scans, Zipf          (18)
#
# Expect: with 40 clients push stops rising after ~4-8 memory threads (each
# waiting client holds a client core), so 10-16 should be close to 8. Note: DEX
# and CHIME start the same number of directory threads on the compute node; at
# 10-16 they spin on the second hyperthreads of clients 24-39, which can lower
# push a little.
#
#   server 8:  bash fair/experiments/quick_hi_c1c8.sh memory  2>&1 | tee ~/qh_memory.out
#   server 6:  bash fair/experiments/quick_hi_c1c8.sh compute 2>&1 | tee ~/qh_compute.out
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

T=deep W=1024 M1=128 S="$SMALL_MB"
: "${MT_HI:=10 14 16}"
P1="CHIME_OFFLOAD_MIN_LEVEL=1"
SCAN=("WORKLOADS=range-uniform" "SCAN_LEN=100" "OPS_M=2" "WARMUP_M=2")
n1=$(count_cells x "$MT_HI" x)          # cells per single-cache block
n2=$(count_cells "a b" "$MT_HI" x)      # cells per two-cache block

# c1
add_block qh_c1_dexr       dexr  $T $n1 "CACHES=$W" "MEMTHREADS=$MT_HI" "WORKLOADS=point-uniform" "@min=2.4"
add_block qh_c1_chime_push chime $T $n1 "CACHES=$W" "MEMTHREADS=$MT_HI" "WORKLOADS=point-uniform" "$P1" "@min=1.8"
# c2
add_block qh_c2_dexr  dexr  $T $n2 "CACHES=$S $M1" "MEMTHREADS=$MT_HI" "WORKLOADS=point-uniform" "@min=2.4"
add_block qh_c2_chime chime $T $n2 "CACHES=$S $M1" "MEMTHREADS=$MT_HI" "WORKLOADS=point-uniform" "$P1" "@min=1.8"
# c4
add_block qh_c4_dexr_scan  dexr  $T $n2 "CACHES=$S $W" "MEMTHREADS=$MT_HI" "${SCAN[@]}" "@min=2.4"
add_block qh_c4_chime_scan chime $T $n2 "CACHES=$S $W" "MEMTHREADS=$MT_HI" "${SCAN[@]}" "CHIME_SCAN_OFFLOAD_ALWAYS=1" "@min=1.8"
add_block qh_c4_dexr_upd   dexr  $T $n1 "CACHES=$W" "MEMTHREADS=$MT_HI" "WORKLOADS=point-uniform" "UPDATE_PCT=100" "@min=2.4"
# c6
add_block qh_c6_dexr_t8    dexr  $T $n1 "THREADS=8" "CACHES=$M1" "MEMTHREADS=$MT_HI" "WORKLOADS=point-uniform" "@min=2.4"
add_block qh_c6_chime_t8   chime $T $n1 "THREADS=8" "CACHES=$M1" "MEMTHREADS=$MT_HI" "WORKLOADS=point-uniform" "$P1" "@min=1.8"
add_block qh_c6_dexr_zipf  dexr  $T $n1 "ZIPF_THETA=0.99" "CACHES=$W" "MEMTHREADS=$MT_HI" "WORKLOADS=point-zipf" "@min=2.4"
add_block qh_c6_chime_zipf chime $T $n1 "ZIPF_THETA=0.99" "CACHES=$W" "MEMTHREADS=$MT_HI" "WORKLOADS=point-zipf" "$P1" "@min=1.8"
# c7
add_block qh_c7_dexr_ins50  dexr  $T $n1 "INSERT_PCT=50" "CACHES=$W" "MEMTHREADS=$MT_HI" "WORKLOADS=point-uniform" "@min=2.4"
add_block qh_c7_chime_ins50 chime $T $n1 "INSERT_PCT=50" "CACHES=$W" "MEMTHREADS=$MT_HI" "WORKLOADS=point-uniform" "$P1" "@min=1.8"
# c8
add_block qh_c8_dex_rule        dex   $T $n1 "CACHES=$W" "MEMTHREADS=$MT_HI" "WORKLOADS=point-uniform" "@min=2.4"
add_block qh_c8_dex_rule_scan   dex   $T $n1 "CACHES=$W" "MEMTHREADS=$MT_HI" "${SCAN[@]}" "@min=2.4"
add_block qh_c8_dex_rule_zipf   dex   $T $n1 "ZIPF_THETA=0.99" "CACHES=$W" "MEMTHREADS=$MT_HI" "WORKLOADS=point-zipf" "@min=2.4"
add_block qh_c8_chime_rule      chime $T $n1 "CACHES=$W" "MEMTHREADS=$MT_HI" "WORKLOADS=point-uniform" "@min=1.8"
add_block qh_c8_chime_rule_scan chime $T $n1 "CACHES=$W" "MEMTHREADS=$MT_HI" "${SCAN[@]}" "@min=1.8"
add_block qh_c8_chime_rule_zipf chime $T $n1 "ZIPF_THETA=0.99" "CACHES=$W" "MEMTHREADS=$MT_HI" "WORKLOADS=point-zipf" "@min=1.8"

apply_skip; show_plan; run_plan
