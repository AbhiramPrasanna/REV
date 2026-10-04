#!/bin/bash
# ===========================================================================
# run_pair_check.sh <memory|compute> -- three reference cells to check that a
# second pair of servers measures the same as servers 6 and 8, before any of
# its results go next to theirs. Same setup as the c1-c4 runs: height-10 tree,
# 1 GB, 40 clients, uniform lookups, idle directory threads parked.
#
#   cell                         servers 6 and 8 measured
#   DEX-R pull                   13.88 Mops  (q_c1_dexr, mt 0)
#   DEX-R push, 16 threads        8.48 Mops  (qm_c1_dexr, mt 16)
#   CHIME pull, no hotspot        5.95 Mops  (qn_c1_chime_pull)
# Within about 5% of these = the pair is interchangeable. ~8 min.
#
# Run with the pair's own addresses (and the same CHK on both servers):
#   memory:   MEM_IP=<memory ip> CMP_IP=<compute ip> bash fair/experiments/run_pair_check.sh memory  2>&1 | tee ~/chk_memory.out
#   compute:  MEM_IP=<memory ip> CMP_IP=<compute ip> bash fair/experiments/run_pair_check.sh compute 2>&1 | tee ~/chk_compute.out
# Results: fair/results/r_chk_${CHK}_{dexr,chime}
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${CHK:=79}"
T=deep W=1024
add_block "r_chk_${CHK}_dexr"  dexr  $T 2 "CACHES=$W" "MEMTHREADS=0 16" "WORKLOADS=point-uniform" "REV_PARK_CMP_DIRS=1" "@min=2.4"
add_block "r_chk_${CHK}_chime" chime $T 1 "CACHES=$W" "MEMTHREADS=0" "WORKLOADS=point-uniform" "CHIME_HOTSPOT=0" "REV_PARK_CMP_DIRS=1" "@min=2.5"

apply_skip; show_plan
[ "${DRY_RUN:-0}" = 1 ] && { run_plan; exit 0; }

# DEX runs under sudo: ask once, keep the ticket fresh for the whole run
if [[ "${PLAN[*]}" == *"|dex|"* ]]; then
  echo "== sudo: enter your password once; it is kept fresh until the run ends"
  sudo -v || { echo "sudo -v failed; the DEX cells need sudo" >&2; exit 1; }
  ( while kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 60; done ) &
fi
run_plan
