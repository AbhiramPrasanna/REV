#!/bin/bash
# ===========================================================================
# quick_chime_nohot.sh <memory|compute> -- CHIME's c1-c3 cells of quick_c1c8.sh
# again with its hotspot buffer off (CHIME_HOTSPOT=0), height-10 tree.
#
# Stock CHIME keeps a 30 MB hotspot buffer (speculative read) above 50 MB of
# cache. On the model tree, turning it off raised CHIME's warm pull from 3.5 to
# 7.6 Mops (40 clients, uniform keys). Only cells above 50 MB are rerun: at 8 MB
# the buffer is already off, so q_c2_chime and q_c3_chime at 8 MB stand as they are.
#
#   c1  1 GB: pull + push at 1/2/4/8 memory threads     (5 cells)
#   c2  128 MB: pull + push at 2 threads                 (2)
#   c3  1 GB, 1 client: pull + push                      (2)
# 9 cells, ~20 min. Push = one request from the deepest cached node
# (CHIME_OFFLOAD_MIN_LEVEL=1), as in quick_c1c8.sh.
#
#   server 8:  bash fair/experiments/quick_chime_nohot.sh memory  2>&1 | tee ~/qn_memory.out
#   server 6:  bash fair/experiments/quick_chime_nohot.sh compute 2>&1 | tee ~/qn_compute.out
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

T=deep W=1024 M1=128
P1="CHIME_OFFLOAD_MIN_LEVEL=1"
OFF="CHIME_HOTSPOT=0"

add_block qn_c1_chime_pull chime $T 1 "CACHES=$W" "MEMTHREADS=0"       "WORKLOADS=point-uniform" "$OFF" "@min=2"
add_block qn_c1_chime_push chime $T 4 "CACHES=$W" "MEMTHREADS=1 2 4 8" "WORKLOADS=point-uniform" "$OFF" "$P1" "@min=2"
add_block qn_c2_chime      chime $T 2 "CACHES=$M1" "MEMTHREADS=0 2"    "WORKLOADS=point-uniform" "$OFF" "$P1" "@min=2"
add_block qn_c3_chime      chime $T 2 "CACHES=$W" "MEMTHREADS=0 1"     "WORKLOADS=point-uniform" "$OFF" "$P1" \
  "${IDLE_ENV[@]}" "@min=2.5"

apply_skip; show_plan; run_plan
