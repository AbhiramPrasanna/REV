#!/bin/bash
# ===========================================================================
# run_dxt_levels.sh <memory|compute> -- per-level cache hits for the DxTree
# section: for each of the 22 levels, how many visits the cache answered and how
# many went to the memory server. Base only (pull everything), so every visit is
# a real cache lookup. Same tree, build and clients as run_dxt_sweep.sh.
#
#   block (RUN_ID)        workload            caches                    cells
#   lvl_point_uniform     lookups, uniform    8 32 128 512 1024 2600    6
#   lvl_point_zipf        lookups, Zipf 0.99  8 32 128 512 1024 2600    6
#   lvl_range_uniform     scans, uniform      8 128 1024 2600           4
#   lvl_range_zipf        scans, Zipf 0.99    8 128 1024 2600           4
#   20 cells, ~50 min
#
# Each log gets a block of lines like
#   [LEVEL] level=0 hits=... misses=... hit_rate=...      (level 0 = leaf)
# printed only because DEX_LEVEL_STATS=1 (dex/include/cache/leanstore_cache.h).
#
# Needs the DEX build with the per-level counter, on BOTH servers, from ~/REV:
#   git pull && RUN_ID=dex_build TREE_SETUP=stress ./fair/build.sh dex
#   strings dex/build_160_512_mn_only/newbench | grep -c DEX_LEVEL_STATS   # >= 1
#
#   server 8:  cd ~/REV && sudo -v && sudo nohup setsid bash fair/experiments/run_dxt_levels.sh memory  > ~/lvl_memory.out  2>&1 < /dev/null &
#   server 6:  cd ~/REV && sudo -v && sudo nohup setsid bash fair/experiments/run_dxt_levels.sh compute > ~/lvl_compute.out 2>&1 < /dev/null &
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

T=stress
COMMON=("THREADS=36" "OPS_M=${OPS_M:-30}" "WARMUP_M=10" "DEX_SAFE_PT=1" "DEX_LEVEL_STATS=1"
        "REV_PARK_CMP_DIRS=1" "MEMTHREADS=0")
add_block lvl_point_uniform dex $T 6 "CACHES=8 32 128 512 1024 2600" "WORKLOADS=point-uniform" "${COMMON[@]}" "@min=2.4"
add_block lvl_point_zipf    dex $T 6 "CACHES=8 32 128 512 1024 2600" "WORKLOADS=point-zipf"    "${COMMON[@]}" "@min=2.4"
add_block lvl_range_uniform dex $T 4 "CACHES=8 128 1024 2600"        "WORKLOADS=range-uniform" "${COMMON[@]}" "@min=3"
add_block lvl_range_zipf    dex $T 4 "CACHES=8 128 1024 2600"        "WORKLOADS=range-zipf"    "${COMMON[@]}" "@min=3"

apply_skip; show_plan
[ "${DRY_RUN:-0}" = 1 ] && { run_plan; exit 0; }

echo "== sudo: enter your password once; it is kept fresh until the run ends"
sudo -v || { echo "sudo -v failed; the DEX cells need sudo" >&2; exit 1; }
( while kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 60; done ) &

run_plan
if [ "$ROLE" = compute ]; then
  echo "== per-level lines:"; grep -h "^\[LEVEL\]" "$FAIR"/results/lvl_*/dex/*.compute.log | head -5
fi
