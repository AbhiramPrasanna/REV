#!/bin/bash
# ===========================================================================
# run_pair_partners.sh <memory|compute> -- the "partner" cells the follow up
# scripts compare against, run on the SAME server pair, so a second pair (7 and
# 9, InfiniBand) never has to be compared with numbers from 6 and 8 (RoCE).
# Each block repeats, cell for cell, a block of run_c3_c8.sh or quick_c1c4.
#
#   block (r_p_...)            repeats                 partner of
#   c6_zipf99_chime            r_c6_zipf99_chime       r_hz_c6_zipf99_chime
#   lc_c6_zipf99               r_lc_c6_zipf99          r_hz_c6_zipf99_lc
#   c8_chime_rule_zipf         r_c8_chime_rule_zipf    r_hz_c8_rule_zipf_chime
#   w50_pull, upd100_pull      pulled CHIME updates    r_pw2_c4_w50, r_pw2_c4_upd100
#   ins_pull, ins_idle_pull    pulled CHIME inserts    r_pw2_c5_ins, r_pw2_c5_ins_idle
#   ins10_pull, ins50_pull     pulled CHIME C7         r_pw2_c7_ins10, r_pw2_c7_ins50
#   14 cells, ~35 min
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

T=deep W=1024
OFF="CHIME_HOTSPOT=0" PARK="REV_PARK_CMP_DIRS=1" P1="CHIME_OFFLOAD_MIN_LEVEL=1"
ZIPF=("WORKLOADS=point-zipf" "ZIPF_THETA=0.99")
PULLW=("CHIME_PUSH_WRITES=0" "MEMTHREADS=0" "$OFF" "$P1" "$PARK" "WORKLOADS=point-uniform")

add_block r_p_c6_zipf99_chime chime $T 3 "CACHES=$W" "MEMTHREADS=0 2 16" "${ZIPF[@]}" "$OFF" "$P1" "$PARK" "@min=2"
add_block r_p_lc_c6_zipf99    chime $T 3 "CACHES=$W" "CHIME_LEAF_SET=1" "LEAF_CACHE_MB=832" "CHIME_LEAF_BEFORE_PUSH=1" \
  "MEMTHREADS=0 2 16" "${ZIPF[@]}" "$P1" "$OFF" "$PARK" "@min=2.5"
add_block r_p_c8_chime_rule_zipf chime $T 2 "CACHES=$W" "MEMTHREADS=2 16" "${ZIPF[@]}" "$OFF" "$PARK" "@min=2"
add_block r_p_w50_pull      chime $T 1 "CACHES=$W" "UPDATE_PCT=50"  "${PULLW[@]}" "@min=2.5"
add_block r_p_upd100_pull   chime $T 1 "CACHES=$W" "UPDATE_PCT=100" "${PULLW[@]}" "@min=2.5"
add_block r_p_ins_pull      chime $T 1 "CACHES=$W" "INSERT_PCT=100" "OPS_M=10" "${PULLW[@]}" "@min=2.5"
add_block r_p_ins_idle_pull chime $T 1 "CACHES=$W" "INSERT_PCT=100" "THREADS=1" "OPS_M=1" "WARMUP_M=10" "${PULLW[@]}" "@min=5"
add_block r_p_ins10_pull    chime $T 1 "CACHES=$W" "INSERT_PCT=10" "OPS_M=10" "${PULLW[@]}" "@min=2.5"
add_block r_p_ins50_pull    chime $T 1 "CACHES=$W" "INSERT_PCT=50" "OPS_M=10" "${PULLW[@]}" "@min=2.5"

apply_skip; show_plan; run_plan
