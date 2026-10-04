#!/bin/bash
# ===========================================================================
# quick_hi_c1c8.sh <memory|compute> -- two additions to quick_c1c8.sh on the
# height-10 trees (TREE_SETUP=deep), same build. Pick them with PARTS:
#
#   PARTS="hi"     10, 14 and 16 memory threads for every push cell of
#                  quick_c1c8: DEX, and CHIME as shipped (hotspot buffer on)
#                  69 cells, ~2.4 h
#   PARTS="nohot"  CHIME's c1-c4 cells of quick_c1c8 again with CHIME's hotspot
#                  buffer off (CHIME_HOTSPOT=0): pull, the quick run's thread
#                  counts (1/2/4/8 in c1, 2 elsewhere) and 10/14/16
#                  21 cells, ~45 min (NOHOT_MORE=1 adds c6-c8: +27 cells)
#   default: PARTS="hi nohot", ~3.2 h
#
# The hotspot buffer is a 30 MB cache of recently used key positions that stock
# CHIME turns on above 50 MB of cache. On the model tree, turning it off raised
# CHIME's warm pull from 3.5 to 7.6 Mops. The hopscotch leaf layout stays on in
# both cases. At 8 MB the buffer is off anyway, so the "nohot" part skips 8 MB
# (those cells are identical to quick_c1c8's).
#
#   c1  1 GB lookups: memory cores
#   c2  8 and 128 MB lookups: cache budget
#   c3  1 client (1 thread is enough: one client keeps one memory thread busy)
#   c4  100-key scans; updates (CHIME pushes no writes: pull only)
#   c5  nothing: built from c1, c3, c4
#   c6  8 clients at 128 MB; Zipf 0.99 at 1 GB
#   c7  50% inserts at 1 GB
#   c8  each system's own rule: lookups, scans, Zipf at 1 GB
# With 40 clients push stopped rising after ~4-8 memory threads (each waiting
# client holds a client core), so 10-16 should be close to 8.
#
#   server 8:  bash fair/experiments/quick_hi_c1c8.sh memory  2>&1 | tee ~/qh_memory.out
#   server 6:  bash fair/experiments/quick_hi_c1c8.sh compute 2>&1 | tee ~/qh_compute.out
#   one part:  PARTS=nohot bash fair/experiments/quick_hi_c1c8.sh <role>   (same on both)
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

T=deep W=1024 M1=128 S="$SMALL_MB"
: "${MT_HI:=10 14 16}"
: "${PARTS:=hi nohot}"
P1="CHIME_OFFLOAD_MIN_LEVEL=1"
SCAN=("WORKLOADS=range-uniform" "SCAN_LEN=100" "OPS_M=2" "WARMUP_M=2")
n() { count_cells x "$1" x; }               # cells for one cache and these memory threads
n2() { count_cells "a b" "$1" x; }          # cells for two caches

if [[ " $PARTS " == *" hi "* ]]; then
  # ---- 10/14/16 memory threads: DEX, and CHIME as shipped (hotspot buffer on)
  H="$MT_HI"
  add_block qh_c1_dexr       dexr  $T $(n "$H") "CACHES=$W" "MEMTHREADS=$H" "WORKLOADS=point-uniform" "@min=2.4"
  add_block qh_c1_chime_push chime $T $(n "$H") "CACHES=$W" "MEMTHREADS=$H" "WORKLOADS=point-uniform" "$P1" "@min=1.8"
  add_block qh_c2_dexr  dexr  $T $(n2 "$H") "CACHES=$S $M1" "MEMTHREADS=$H" "WORKLOADS=point-uniform" "@min=2.4"
  add_block qh_c2_chime chime $T $(n2 "$H") "CACHES=$S $M1" "MEMTHREADS=$H" "WORKLOADS=point-uniform" "$P1" "@min=1.8"
  add_block qh_c4_dexr_scan  dexr  $T $(n2 "$H") "CACHES=$S $W" "MEMTHREADS=$H" "${SCAN[@]}" "@min=2.4"
  add_block qh_c4_chime_scan chime $T $(n2 "$H") "CACHES=$S $W" "MEMTHREADS=$H" "${SCAN[@]}" "CHIME_SCAN_OFFLOAD_ALWAYS=1" "@min=1.8"
  add_block qh_c4_dexr_upd   dexr  $T $(n "$H") "CACHES=$W" "MEMTHREADS=$H" "WORKLOADS=point-uniform" "UPDATE_PCT=100" "@min=2.4"
  add_block qh_c6_dexr_t8    dexr  $T $(n "$H") "THREADS=8" "CACHES=$M1" "MEMTHREADS=$H" "WORKLOADS=point-uniform" "@min=2.4"
  add_block qh_c6_chime_t8   chime $T $(n "$H") "THREADS=8" "CACHES=$M1" "MEMTHREADS=$H" "WORKLOADS=point-uniform" "$P1" "@min=1.8"
  add_block qh_c6_dexr_zipf  dexr  $T $(n "$H") "ZIPF_THETA=0.99" "CACHES=$W" "MEMTHREADS=$H" "WORKLOADS=point-zipf" "@min=2.4"
  add_block qh_c6_chime_zipf chime $T $(n "$H") "ZIPF_THETA=0.99" "CACHES=$W" "MEMTHREADS=$H" "WORKLOADS=point-zipf" "$P1" "@min=1.8"
  add_block qh_c7_dexr_ins50  dexr  $T $(n "$H") "INSERT_PCT=50" "CACHES=$W" "MEMTHREADS=$H" "WORKLOADS=point-uniform" "@min=2.4"
  add_block qh_c7_chime_ins50 chime $T $(n "$H") "INSERT_PCT=50" "CACHES=$W" "MEMTHREADS=$H" "WORKLOADS=point-uniform" "$P1" "@min=1.8"
  add_block qh_c8_dex_rule        dex   $T $(n "$H") "CACHES=$W" "MEMTHREADS=$H" "WORKLOADS=point-uniform" "@min=2.4"
  add_block qh_c8_dex_rule_scan   dex   $T $(n "$H") "CACHES=$W" "MEMTHREADS=$H" "${SCAN[@]}" "@min=2.4"
  add_block qh_c8_dex_rule_zipf   dex   $T $(n "$H") "ZIPF_THETA=0.99" "CACHES=$W" "MEMTHREADS=$H" "WORKLOADS=point-zipf" "@min=2.4"
  add_block qh_c8_chime_rule      chime $T $(n "$H") "CACHES=$W" "MEMTHREADS=$H" "WORKLOADS=point-uniform" "@min=1.8"
  add_block qh_c8_chime_rule_scan chime $T $(n "$H") "CACHES=$W" "MEMTHREADS=$H" "${SCAN[@]}" "@min=1.8"
  add_block qh_c8_chime_rule_zipf chime $T $(n "$H") "ZIPF_THETA=0.99" "CACHES=$W" "MEMTHREADS=$H" "WORKLOADS=point-zipf" "@min=1.8"
fi

if [[ " $PARTS " == *" nohot "* ]]; then
  # ---- CHIME with the hotspot buffer off, c1-c4: quick_c1c8's thread counts and 10/14/16
  O="CHIME_HOTSPOT=0"
  add_block qn_c1_chime_pull chime $T 1 "CACHES=$W" "MEMTHREADS=0" "WORKLOADS=point-uniform" "$O" "@min=1.8"
  add_block qn_c1_chime_push chime $T $(n "1 2 4 8 $MT_HI") "CACHES=$W" "MEMTHREADS=1 2 4 8 $MT_HI" \
    "WORKLOADS=point-uniform" "$O" "$P1" "@min=1.8"
  add_block qn_c2_chime chime $T $(n "0 2 $MT_HI") "CACHES=$M1" "MEMTHREADS=0 2 $MT_HI" \
    "WORKLOADS=point-uniform" "$O" "$P1" "@min=1.8"
  add_block qn_c3_chime chime $T 2 "CACHES=$W" "MEMTHREADS=0 1" "WORKLOADS=point-uniform" "$O" "$P1" \
    "${IDLE_ENV[@]}" "@min=2.5"
  add_block qn_c4_chime_scan chime $T $(n "0 2 $MT_HI") "CACHES=$W" "MEMTHREADS=0 2 $MT_HI" "${SCAN[@]}" \
    "CHIME_SCAN_OFFLOAD_ALWAYS=1" "$O" "@min=1.8"
  add_block qn_c4_chime_upd chime $T 1 "CACHES=$W" "MEMTHREADS=0" "WORKLOADS=point-uniform" "UPDATE_PCT=100" "$O" "@min=1.8"
fi
# c6-c8 with the hotspot buffer off only when asked: NOHOT_MORE=1
if [[ " $PARTS " == *" nohot "* && "${NOHOT_MORE:-0}" == 1 ]]; then
  add_block qn_c6_chime_t8 chime $T $(n "0 2 $MT_HI") "THREADS=8" "CACHES=$M1" "MEMTHREADS=0 2 $MT_HI" \
    "WORKLOADS=point-uniform" "$O" "$P1" "@min=1.8"
  add_block qn_c6_chime_zipf chime $T $(n "0 2 $MT_HI") "ZIPF_THETA=0.99" "CACHES=$W" "MEMTHREADS=0 2 $MT_HI" \
    "WORKLOADS=point-zipf" "$O" "$P1" "@min=1.8"
  add_block qn_c7_chime_ins50 chime $T $(n "0 2 $MT_HI") "INSERT_PCT=50" "CACHES=$W" "MEMTHREADS=0 2 $MT_HI" \
    "WORKLOADS=point-uniform" "$O" "$P1" "@min=1.8"
  add_block qn_c8_chime_rule chime $T $(n "2 $MT_HI") "CACHES=$W" "MEMTHREADS=2 $MT_HI" \
    "WORKLOADS=point-uniform" "$O" "@min=1.8"
  add_block qn_c8_chime_rule_scan chime $T $(n "2 $MT_HI") "CACHES=$W" "MEMTHREADS=2 $MT_HI" "${SCAN[@]}" "$O" "@min=1.8"
  add_block qn_c8_chime_rule_zipf chime $T $(n "2 $MT_HI") "ZIPF_THETA=0.99" "CACHES=$W" "MEMTHREADS=2 $MT_HI" \
    "WORKLOADS=point-zipf" "$O" "@min=1.8"
fi

apply_skip; show_plan; run_plan
