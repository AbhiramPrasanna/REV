#!/bin/bash
# ===========================================================================
# c8 -- Challenge 8: the online decision    (measurement summary, Challenge 8)
#
#   x  workload phase: P1 lookups (uniform), P2 100-key scans, P3 50% updates,
#      P4 lookups (Zipf 0.99)
#   y  throughput per phase, and the static policies' loss against the oracle
#   policies  static pull | static push (every op from the deepest cached node)
#             | each system's own rule (stock DEX: pushes inside its bottom 4
#             levels; CHIME: pushes only when an inner node misses)
#             | oracle = the best policy in each phase (computed afterwards)
#   caches  8 MB and warm (1 GB)
#   model   none; expected: each static policy is best in at most one phase
#   fails if the best static policy is within a few % of the oracle
#
# The harness runs one workload per process, so phases are separate runs (an
# emulated phase change: no transition cost is measured). Static pull/push for
# P1-P3 come from c1 (lookups), c4 (100-key scans, 50% updates); this script
# adds the systems' own rules for every phase and the Zipf phase. 32 cells, ~1.3 h.
#
#   bash fair/experiments/c8_online.sh memory|compute
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${TREES:=deep}"

for tree in $TREES; do
  for c in $(two_caches dexr "$tree"); do
    # each system's own rule, all four phases (2 memory cores)
    add_block "c8_dex_${tree}_c${c}_rule" dex "$tree" 2 \
      "CACHES=$c" "MEMTHREADS=2" "WORKLOADS=point-uniform range-uniform"
    add_block "c8_dex_${tree}_c${c}_rule_upd50" dex "$tree" 1 \
      "CACHES=$c" "MEMTHREADS=2" "WORKLOADS=point-uniform" "UPDATE_PCT=50"
    add_block "c8_dex_${tree}_c${c}_rule_zipf" dex "$tree" 1 \
      "ZIPF_THETA=0.99" "CACHES=$c" "MEMTHREADS=2" "WORKLOADS=point-zipf"
    add_block "c8_chime_${tree}_c${c}_rule" chime "$tree" 2 \
      "CACHES=$c" "MEMTHREADS=2" "WORKLOADS=point-uniform range-uniform"
    add_block "c8_chime_${tree}_c${c}_rule_upd50" chime "$tree" 1 \
      "CACHES=$c" "MEMTHREADS=2" "WORKLOADS=point-uniform" "UPDATE_PCT=50"
    add_block "c8_chime_${tree}_c${c}_rule_zipf" chime "$tree" 1 \
      "ZIPF_THETA=0.99" "CACHES=$c" "MEMTHREADS=2" "WORKLOADS=point-zipf"
    # static pull / push for the Zipf phase
    add_block "c8_dexr_${tree}_c${c}_zipf" dexr "$tree" 2 \
      "ZIPF_THETA=0.99" "CACHES=$c" "MEMTHREADS=0 2" "WORKLOADS=point-zipf"
    add_block "c8_chime_${tree}_c${c}_zipf" chime "$tree" 2 \
      "ZIPF_THETA=0.99" "CACHES=$c" "MEMTHREADS=0 2" "WORKLOADS=point-zipf" "CHIME_OFFLOAD_MIN_LEVEL=1"
  done
done

apply_skip; show_plan; run_plan
