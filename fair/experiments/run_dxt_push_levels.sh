#!/bin/bash
# ===========================================================================
# run_dxt_push_levels.sh <memory|compute> -- where pushed requests enter the
# tree, for the DxTree section's RDMA figure (fig_dxtree_rdma_*): the Push cells
# of run_dxt_sweep.sh (16 memory server threads) rerun with DEX_LEVEL_STATS=1.
#
# The compute server records every level it visits, hit or miss, before it
# decides to push (dex/include/tree/leanstore_tree.h, lookup and range_scan). A
# pushed operation stops at its first miss, so in these runs
#   [LEVEL] level=L ... misses=M
# means M pushed requests entered the tree at level L (0 = leaf); the memory
# server then walked L+1 nodes down to the leaf (a scan then follows the leaf
# chain: "leaves / scan pushdown" in the same log). The hits on the levels above
# are the part of the path the compute cache answered.
#
#   block (RUN_ID)         rule                  caches                      cells
#   plvl_point_uniform     DEX-R (deepest), 16   8 32 128 512 1024           5
#   plvl_point_uniform_fit stock rule, 16        2600 (all inner nodes fit)  1
#   plvl_range_uniform     DEX-R (deepest), 16   8 128 1024                  3
#   plvl_range_uniform_fit stock rule, 16        2600                        1
#   10 cells, ~30 min. The same cells as the figure: Push is DEX-R where the inner
#   nodes do not fit and the stock run at 2600 MB (Plots/make_dxtree_figures.py,
#   pall()). Throughput in the paper stays from run_dxt_sweep.sh; these runs only
#   add the entry levels.
#
# Same tree, build and clients as run_dxt_sweep.sh / run_dxt_levels.sh (needs the
# DEX build with the per-level counter on BOTH servers):
#   strings dex/build_160_512_mn_only/newbench | grep -c DEX_LEVEL_STATS   # >= 1
#
#   server 8:  cd ~/REV && sudo -v && sudo nohup setsid bash fair/experiments/run_dxt_push_levels.sh memory  > ~/plvl_memory.out  2>&1 < /dev/null &
#   server 6:  cd ~/REV && sudo -v && sudo nohup setsid bash fair/experiments/run_dxt_push_levels.sh compute > ~/plvl_compute.out 2>&1 < /dev/null &
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

T=stress
COMMON=("THREADS=36" "OPS_M=${OPS_M:-30}" "WARMUP_M=10" "DEX_SAFE_PT=1" "DEX_LEVEL_STATS=1"
        "REV_PARK_CMP_DIRS=1" "MEMTHREADS=16")
add_block plvl_point_uniform     dexr $T 5 "CACHES=8 32 128 512 1024" "WORKLOADS=point-uniform" "${COMMON[@]}" "@min=2.4"
add_block plvl_point_uniform_fit dex  $T 1 "CACHES=2600"              "WORKLOADS=point-uniform" "${COMMON[@]}" "@min=2.4"
add_block plvl_range_uniform     dexr $T 3 "CACHES=8 128 1024"        "WORKLOADS=range-uniform" "${COMMON[@]}" "@min=3"
add_block plvl_range_uniform_fit dex  $T 1 "CACHES=2600"              "WORKLOADS=range-uniform" "${COMMON[@]}" "@min=3"

apply_skip; show_plan
[ "${DRY_RUN:-0}" = 1 ] && { run_plan; exit 0; }

echo "== sudo: enter your password once; it is kept fresh until the run ends"
sudo -v || { echo "sudo -v failed; the DEX cells need sudo" >&2; exit 1; }
( while kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 60; done ) &

run_plan
if [ "$ROLE" = compute ]; then
  echo "== where pushes entered (misses per level), first cell:"
  grep -h "^\[LEVEL\]" "$FAIR"/results/plvl_point_uniform/dex/*cache8.compute.log | head -12
fi
