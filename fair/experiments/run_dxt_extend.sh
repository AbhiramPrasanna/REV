#!/bin/bash
# ===========================================================================
# run_dxt_extend.sh <memory|compute> -- two more cache sizes for the DxTree
# sweep, so the cache axis doubles all the way: ... 512, 1024, 2048, 4096 MB.
# Same tree, build, clients and settings as run_dxt_sweep.sh (servers 6 and 8).
#
#   2048 MB = 4,194,304 slots: holds all 3,846,104 inner nodes, with a little
#             room for leaves (the "inner nodes fit" step, in place of 2600 MB)
#   4096 MB = 8,388,608 slots: holds the whole tree (7,692,257 nodes); the cache
#             never fills, so DEX never pushes and every thread count is Base:
#             Base only (in place of 5200 MB)
#
#   block (RUN_ID)            workload                         cells
#   dxt_point_uniform_2048    lookups, stock, 0 1 2 4 8 16      6   ~0.3 h
#   dxt_range_uniform_2048    scans                             6   ~0.3 h
#   dxt_point_zipf_2048       lookups, Zipf                     6   ~0.3 h
#   dxt_range_zipf_2048       scans, Zipf                       6   ~0.3 h
#   dxt_whole_4096            all four, Base, 200 M warmup      4   ~0.3 h
#   28 cells, ~1.5 h
#
# DEX-R is left out: at 2048 MB every inner node is cached, so DEX-R pushes from
# the same place as stock DEX (set EXT_RULES="stock deepest" to run it anyway).
#
# Start it after run_dxt_sweep.sh has finished, server 8 first:
#   cd ~/REV && git pull && sudo -v
#   sudo nohup setsid bash fair/experiments/run_dxt_extend.sh memory  > ~/dxt_ext_memory.out  2>&1 < /dev/null &
#   sudo nohup setsid bash fair/experiments/run_dxt_extend.sh compute > ~/dxt_ext_compute.out 2>&1 < /dev/null &
# The DEX build of run_dxt_sweep.sh is reused (no rebuild).
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

T=stress
: "${EXT_CACHE:=2048}"
: "${EXT_WHOLE:=4096}"
: "${EXT_RULES:=stock}"
: "${DISTS:=uniform zipf}"
: "${DXT_THREADS:=36}"
: "${DXT_OPS_M:=${OPS_M:-30}}"
COMMON=("THREADS=$DXT_THREADS" "OPS_M=$DXT_OPS_M" "WARMUP_M=10" "DEX_SAFE_PT=1" "REV_PARK_CMP_DIRS=1")

wl_all=""
for d in $DISTS; do
  for op in point range; do
    wl="$op-$d"; wl_all="$wl_all $wl"
    case $op in point) m=2.4 ;; range) m=2.9 ;; esac
    if [[ " $EXT_RULES " == *" stock "* ]]; then
      add_block "dxt_${op}_${d}_${EXT_CACHE}" dex $T 6 "CACHES=$EXT_CACHE" "MEMTHREADS=0 1 2 4 8 16" \
        "WORKLOADS=$wl" "${COMMON[@]}" "@min=$m"
    fi
    if [[ " $EXT_RULES " == *" deepest "* ]]; then
      add_block "dxtr_${op}_${d}_${EXT_CACHE}" dexr $T 5 "CACHES=$EXT_CACHE" "MEMTHREADS=1 2 4 8 16" \
        "WORKLOADS=$wl" "${COMMON[@]}" "@min=$m"
    fi
  done
done
wl_all="${wl_all# }"
n=$(count_cells "$EXT_WHOLE" "0" "$wl_all")
add_block "dxt_whole_${EXT_WHOLE}" dex $T "$n" "CACHES=$EXT_WHOLE" "MEMTHREADS=0" "WORKLOADS=$wl_all" \
  "THREADS=$DXT_THREADS" "OPS_M=$DXT_OPS_M" "WARMUP_M=200" "DEX_SAFE_PT=1" "REV_PARK_CMP_DIRS=1" "@min=5"

apply_skip; show_plan
[ "${DRY_RUN:-0}" = 1 ] && { run_plan; exit 0; }

echo "== sudo: enter your password once; it is kept fresh until the run ends"
sudo -v || { echo "sudo -v failed; the DEX cells need sudo" >&2; exit 1; }
( while kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 60; done ) &

run_plan
if [ "$ROLE" = compute ]; then
  python3 "$EXP_DIR/collect_dxt_sweep.py" || true
fi
