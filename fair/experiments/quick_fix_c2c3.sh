#!/bin/bash
# ===========================================================================
# quick_fix_c2c3.sh <memory|compute> -- 6 cells on the height-10 trees
# (TREE_SETUP=deep), run after quick_c1c4_missing.sh.
#
#   c3  one client at 1 GB with a full warm-up (10 M lookups, not 2 M):
#       DEX-R pull and push (1 thread), CHIME pull and push (1 thread)   (4)
#       With 2 M the deep tree's cache was not warm: CHIME held 1.10 M of
#       1.25 M inner nodes, DEX had 22% of its misses in inner nodes. The
#       bottom inner level has 1.04 M nodes; 10 M uniform lookups touch all.
#   c2  CHIME pull at 64 MB and 160 MB (hotspot buffer off)              (2)
#       CHIME's tree cache holds the whole inner tree in 142 MB. At 128 MB it
#       is full and evicting, and pull fell from 5.95 to 0.81 Mops with the
#       same 1.0 leaf round trip per lookup. 160 MB (fits) and 64 MB (half)
#       show whether the drop follows the cache being full, not the reads.
#
# CHIME runs with its hotspot buffer off; the compute node's idle directory
# threads are parked, as in quick_c1c4_missing.sh. ~20 min.
#
#   server 8:  bash fair/experiments/quick_fix_c2c3.sh memory  2>&1 | tee ~/qx_memory.out
#   server 6:  bash fair/experiments/quick_fix_c2c3.sh compute 2>&1 | tee ~/qx_compute.out
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

T=deep
OFF="CHIME_HOTSPOT=0"
PARK="REV_PARK_CMP_DIRS=1"
WARM=("THREADS=1" "OPS_M=1" "WARMUP_M=10")

add_block qx_c3_dexr  dexr  $T 2 "CACHES=1024" "MEMTHREADS=0 1" "WORKLOADS=point-uniform" "${WARM[@]}" "$PARK" "@min=3"
add_block qx_c3_chime chime $T 2 "CACHES=1024" "MEMTHREADS=0 1" "WORKLOADS=point-uniform" "${WARM[@]}" \
  "$OFF" "CHIME_OFFLOAD_MIN_LEVEL=1" "$PARK" "@min=5"
add_block qx_c2_chime_pull chime $T 2 "CACHES=64 160" "MEMTHREADS=0" "WORKLOADS=point-uniform" "$OFF" "$PARK" "@min=2"

apply_skip; show_plan; run_plan
