#!/bin/bash
# ===========================================================================
# run_dxt_sweep.sh <memory|compute> -- the full DxT sweep on the paper's tree
# (TREE_SETUP=stress: 22 levels, 160 B inner pages, 512 B slots, tree on the
# memory server only, 36 clients), DEX only, servers 6 (compute) and 8 (memory).
#
#   rules     stock DEX (DEX_PUSH_READS_DEEPEST=0): a lookup pulls every missing
#             level above the bottom four, then pushes those four levels; a scan
#             pulls the path to its first leaf, then pushes the leaves
#             DEX-R (DEX_PUSH_READS_DEEPEST=1): push from the deepest cached node,
#             nothing pulled first; at 8 MB this is the near pure push point
#   variants  Base = 0 memory threads; push = 1 2 4 8 16 memory threads
#             PLk on point lookups, PSc on 100-key scans, PAll on a 50/50 mix
#   caches    8 32 64 128 256 512 1024 2600 MB, and 5200 MB (whole tree)
#             - the inner nodes need 1,969 MB (3,846,104 x 512 B), so 1800 MB
#               does not hold them; 2600 MB does (run e1: 0.6 reads/lookup,
#               leaves only)
#             - the whole tree needs 3,938 MB plus the cache's cooling share,
#               so 3600 MB does not hold it; 5200 MB does (run e1: 0 reads)
#   dists     uniform, then Zipf 0.99
#
#   Order: lookups and scans first (both rules, uniform then Zipf, then their
#   whole-tree cells), and the 50/50 mix last, so lookups and scans are complete
#   before the mix starts.
#   block (RUN_ID)            workload        cells
#   part 1, lookups and scans                                          ~15.0 h
#   dxt_point_uniform         lookups, stock  8 caches x 6 thread counts = 48   ~1.9 h
#   dxtr_point_uniform        lookups, DEX-R  7 caches x 5 thread counts = 35   ~1.4 h
#   dxt_range_uniform         scans, stock    48                                ~2.3 h
#   dxtr_range_uniform        scans, DEX-R    35                                ~1.7 h
#   dxt_point_zipf ... dxtr_range_zipf        the same four for Zipf 0.99       ~7.3 h
#   dxt_whole_tree            lookups and scans, 5200 MB, Base only    4        ~0.3 h
#   part 2, the 50/50 mix (PAll)                                       ~7.7 h
#   dxt_mixed_uniform         50/50, stock    48                                ~2.2 h
#   dxtr_mixed_uniform        50/50, DEX-R    35                                ~1.6 h
#   dxt_mixed_zipf            50/50, stock    48                                ~2.2 h
#   dxtr_mixed_zipf           50/50, DEX-R    35                                ~1.6 h
#   dxt_whole_mixed           50/50, 5200 MB, Base only                2        ~0.2 h
#   504 cells, ~22.6 h (uniform only: 252 cells, ~11.3 h)
#   MIXED=0 leaves part 2 out (~15.0 h); MIXED=only runs part 2 alone.
#
# DEX-R leaves out two settings that are identical to stock: 0 memory threads
# (with no threads DEX-R pulls exactly as Base does) and 2600 MB (every inner
# node is cached, so both rules push only the leaf). RULES=stock or
# RULES=deepest runs one rule only.
#
# Why 5200 MB is Base only: DEX starts pushing only once its cache is full,
# and a cache bigger than the tree never fills, so every push cell there would
# just be Base. Set WHOLE_MEMTHREADS="0 1 2 4 8 16" to run them anyway. The
# whole-tree cells warm with 200 M operations (DEX admits a leaf 1 time in 10,
# so 10 M fill only ~23% of the leaves).
#
# Memory threads run on separate physical cores of the memory server (params.sh
# reserves no client cores there), so 8 and 16 threads are 8 and 16 real cores.
# DEX_SAFE_PT=1 keeps the page table safe under heavy push churn at 8 MB
# (dex/include/tree/page_table.h); it changes no measured path.
#
# Before the first run, on BOTH servers, from ~/REV:
#   git pull && RUN_ID=dex_build TREE_SETUP=stress ./fair/build.sh dex
#   strings dex/build_160_512_mn_only/newbench | grep -c DEX_SAFE_PT   # >= 1
#
#   server 8:  cd ~/REV && bash fair/experiments/run_dxt_sweep.sh memory  2>&1 | tee -a ~/dxt_memory.out
#   server 6:  cd ~/REV && bash fair/experiments/run_dxt_sweep.sh compute 2>&1 | tee -a ~/dxt_compute.out
#
# Trim or resume (same values on both servers):
#   DISTS=uniform           only the uniform blocks and their whole-tree cells (~11.3 h)
#   RULES=stock             stock DEX only (~13.3 h); RULES=deepest: DEX-R only (~9.3 h)
#   MIXED=0 / MIXED=only    leave out the 50/50 mix / run only the mix
#   SKIP_TO=<block>         resume from a block after a failure
#   OPS_M=10                10 M measured operations instead of 30 M (~1/3 faster)
#   DRY_RUN=1               print the plan only
# Afterwards (compute server):  python3 fair/experiments/collect_dxt_sweep.py
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

T=stress
: "${DXT_CACHES:=8 32 64 128 256 512 1024 2600}"
: "${DXT_MEMTHREADS:=0 1 2 4 8 16}"
: "${DXTR_CACHES:=8 32 64 128 256 512 1024}"   # DEX-R: 2600 MB is identical to stock
: "${DXTR_MEMTHREADS:=1 2 4 8 16}"             # DEX-R: 0 threads is Base
: "${RULES:=stock deepest}"
: "${WHOLE_MB:=5200}"
: "${WHOLE_MEMTHREADS:=0}"
: "${WHOLE_WARMUP_M:=200}"
: "${DISTS:=uniform zipf}"
: "${DXT_THREADS:=36}"            # clients, as in stress1 and the paper
: "${DXT_OPS_M:=${OPS_M:-30}}"
COMMON=("THREADS=$DXT_THREADS" "OPS_M=$DXT_OPS_M" "WARMUP_M=10" "DEX_SAFE_PT=1" "REV_PARK_CMP_DIRS=1")

add_rules() {   # op dist minutes-per-cell: the stock block, then the DEX-R block
  local op=$1 d=$2 m=$3 wl="$1-$2" n
  if [[ " $RULES " == *" stock "* ]]; then
    n=$(count_cells "$DXT_CACHES" "$DXT_MEMTHREADS" "$wl")
    add_block "dxt_${op}_${d}" dex $T "$n" "CACHES=$DXT_CACHES" "MEMTHREADS=$DXT_MEMTHREADS"       "WORKLOADS=$wl" "${COMMON[@]}" "@min=$m"
  fi
  if [[ " $RULES " == *" deepest "* ]]; then
    n=$(count_cells "$DXTR_CACHES" "$DXTR_MEMTHREADS" "$wl")
    add_block "dxtr_${op}_${d}" dexr $T "$n" "CACHES=$DXTR_CACHES" "MEMTHREADS=$DXTR_MEMTHREADS"       "WORKLOADS=$wl" "${COMMON[@]}" "@min=$m"
  fi
}
add_whole() {  # block-id workloads: Base at the whole-tree cache (stock rule only)
  [[ " $RULES " == *" stock "* ]] || return 0
  [ -n "$2" ] || return 0
  local n; n=$(count_cells "$WHOLE_MB" "$WHOLE_MEMTHREADS" "$2")
  add_block "$1" dex $T "$n" "CACHES=$WHOLE_MB" "MEMTHREADS=$WHOLE_MEMTHREADS"     "WORKLOADS=$2" "THREADS=$DXT_THREADS" "OPS_M=$DXT_OPS_M" "WARMUP_M=$WHOLE_WARMUP_M"     "DEX_SAFE_PT=1" "REV_PARK_CMP_DIRS=1" "@min=5"
}

# minutes per cell: scans and the mix are slower at small caches
: "${MIXED:=1}"
if [ "$MIXED" != only ]; then          # part 1: lookups and scans
  pr=""
  for d in $DISTS; do
    add_rules point "$d" 2.4
    add_rules range "$d" 2.9
    pr="$pr point-$d range-$d"
  done
  add_whole dxt_whole_tree "${pr# }"
fi
if [ "$MIXED" != 0 ]; then             # part 2: the 50/50 mix, last
  mx=""
  for d in $DISTS; do
    add_rules mixed "$d" 2.7
    mx="$mx mixed-$d"
  done
  add_whole dxt_whole_mixed "${mx# }"
fi

apply_skip; show_plan
[ "${DRY_RUN:-0}" = 1 ] && { run_plan; exit 0; }

# DEX runs under sudo: ask once, keep the ticket fresh for the whole run
echo "== sudo: enter your password once; it is kept fresh until the run ends"
sudo -v || { echo "sudo -v failed; the DEX cells need sudo" >&2; exit 1; }
( while kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 60; done ) &

# compute node: NIC sampler + time-stamped console copy (as in run_c3_c8.sh)
if [ "$ROLE" = compute ]; then
  NIC_DIR="$FAIR/results/nic"; mkdir -p "$NIC_DIR"
  STAMP="dxt_$(date +%Y%m%d_%H%M%S)"
  NIC_CSV="$NIC_DIR/${STAMP}_nic.csv"; export TSLOG="$NIC_DIR/${STAMP}_ts.log"
  bash "$EXP_DIR/nic_sampler.sh" "$NIC_CSV" 0.5 & SAMPLER=$!
  trap 'kill $SAMPLER 2>/dev/null' EXIT
  if command -v perl >/dev/null; then
    exec > >(perl -MTime::HiRes=time -ne 'BEGIN{$|=1; open(F, ">>", $ENV{TSLOG}) or die; select((select(F), $|=1)[0])} print; printf F "%.3f %s", time, $_') 2>&1
  else
    exec > >(while IFS= read -r l; do printf '%s\n' "$l"; printf '%s %s\n' "$(date +%s.%N)" "$l" >> "$TSLOG"; done) 2>&1
  fi
fi

run_plan
if [ "$ROLE" = compute ]; then
  python3 "$EXP_DIR/nic_bandwidth.py" "$TSLOG" "$NIC_CSV" || true
  python3 "$EXP_DIR/collect_dxt_sweep.py" || true
fi
