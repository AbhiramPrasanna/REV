#!/bin/bash
# ===========================================================================
# run_writes_small.sh <memory|compute> -- writes at small caches, where they
# miss on inner nodes and DEX's own rule pushes them (at 1 GB every inner node
# is cached and DEX pulls about 99% of its writes). Same setup as
# run_c3_c8.sh: height-10 tree, 40 clients, idle directory threads parked,
# network samples on the compute node. DEX as DEX-R (its writes follow DEX's
# own rule); CHIME with its hotspot buffer off, pull only (CHIME pushes no
# writes).
#
#   r_w_c45_dexr_upd    100% updates, 8 and 128 MB: pull, 2, 16 threads     6
#   r_w_c45_dexr_ins    100% inserts, 8 and 128 MB: pull, 2, 16 threads     6
#   r_w_c45_chime_upd   100% updates, 8 and 128 MB: pull                    2
#   r_w_c45_chime_ins   100% inserts, 8 and 128 MB: pull                    2
#   16 cells, ~40 min
#
#   server 8:  bash fair/experiments/run_writes_small.sh memory  2>&1 | tee ~/w_memory.out
#   server 6:  bash fair/experiments/run_writes_small.sh compute 2>&1 | tee ~/w_compute.out
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

T=deep
OFF="CHIME_HOTSPOT=0"
PARK="REV_PARK_CMP_DIRS=1"
SAFE="DEX_SAFE_PT=1"   # DEX page table safe under churn (dex/include/tree/page_table.h)
SMALL="CACHES=8 128"
OPS=("OPS_M=10" "WARMUP_M=10")

add_block r_w_c45_dexr_upd  dexr  $T 6 "$SMALL" "MEMTHREADS=0 2 16" "WORKLOADS=point-uniform" "UPDATE_PCT=100" "${OPS[@]}" "$PARK" "$SAFE" "@min=2.4"
add_block r_w_c45_dexr_ins  dexr  $T 6 "$SMALL" "MEMTHREADS=0 2 16" "WORKLOADS=point-uniform" "INSERT_PCT=100" "${OPS[@]}" "$PARK" "$SAFE" "@min=2.4"
add_block r_w_c45_chime_upd chime $T 2 "$SMALL" "MEMTHREADS=0" "WORKLOADS=point-uniform" "UPDATE_PCT=100" "${OPS[@]}" "$OFF" "$PARK" "@min=3"
add_block r_w_c45_chime_ins chime $T 2 "$SMALL" "MEMTHREADS=0" "WORKLOADS=point-uniform" "INSERT_PCT=100" "${OPS[@]}" "$OFF" "$PARK" "@min=3"

apply_skip; show_plan
[ "${DRY_RUN:-0}" = 1 ] && { run_plan; exit 0; }

# DEX runs under sudo: ask once, keep the ticket fresh for the whole run
if [[ "${PLAN[*]}" == *"|dex|"* ]]; then
  echo "== sudo: enter your password once; it is kept fresh until the run ends"
  sudo -v || { echo "sudo -v failed; the DEX cells need sudo" >&2; exit 1; }
  ( while kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 60; done ) &
fi

# compute node: NIC sampler + time-stamped console copy (as in run_c3_c8.sh)
if [ "$ROLE" = compute ]; then
  NIC_DIR="$FAIR/results/nic"; mkdir -p "$NIC_DIR"
  STAMP="w_$(date +%Y%m%d_%H%M%S)"
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
fi
