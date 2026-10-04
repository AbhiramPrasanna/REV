#!/bin/bash
# ===========================================================================
# run_chime_pushw.sh <memory|compute> -- CHIME with write pushdown on
# (CHIME_PUSH_WRITES=1, see CHIME/include/push_write.h). Each cell matches a
# CHIME write cell that ran with writes pulled, so the pair shows what pushing
# writes changes. Needs the CHIME build that has push_write.h, on BOTH servers.
#
# Setup as run_c3_c8.sh: height-10 tree, hotspot buffer off, reads and writes
# pushed from the deepest cached node, compute node's idle directory threads
# parked. Memory node: one write worker per memory thread (the default), pinned
# to CPUs 0-15, which are physical cores the directory threads (CPUs 79 down)
# do not use. So "memory threads = m" here means m directory threads plus m
# write workers.
#
#   block                    cells                         pull partner
#   r_pw_c4_upd100           1 GB, 100% updates, 2 and 16  qn_c4_chime_upd
#   r_pw_c4_w50              1 GB, 50% updates, 2 and 16   r_c4_w50_chime
#   r_pw_c5_ins              1 GB, inserts, 2 and 16       r_c5_chime_ins
#   r_pw_c5_ins_idle         1 GB, inserts, 1 client, 1    r_c5_chime_ins_idle
#   r_pw_c5_upd_idle         1 GB, updates, 1 client, 0 1  (its own pull cell)
#   r_pw_c7_ins10, _ins50    1 GB, 10%/50% inserts, 2, 16  r_c7_ins10/50_chime
#   r_pw_small_upd, _ins     8 and 128 MB, 2 and 16        r_w_c45_chime_upd/ins
#   22 cells, ~1 h
#
#   server 8:  bash fair/experiments/run_chime_pushw.sh memory  2>&1 | tee ~/pw_memory.out
#   server 6:  bash fair/experiments/run_chime_pushw.sh compute 2>&1 | tee ~/pw_compute.out
# Each cell's compute log ends with "[PUSHW] node 1: writes pushed=..." and the
# memory log with "writes run for other nodes=...": both must be non zero in
# push cells.
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

T=deep W=1024
PW=("CHIME_PUSH_WRITES=1" "CHIME_PUSH_WRITE_CPUS=0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15")
COMMON=("CHIME_HOTSPOT=0" "CHIME_OFFLOAD_MIN_LEVEL=1" "REV_PARK_CMP_DIRS=1" "WORKLOADS=point-uniform")
ONE=("THREADS=1" "OPS_M=1" "WARMUP_M=10")
pw() {  # id cells VAR=value...
  local id=$1 c=$2; shift 2
  add_block "r_pw_$id" chime $T "$c" "$@" "${PW[@]}" "${COMMON[@]}" "@min=2.5"
}

pw c4_upd100     2 "CACHES=$W" "MEMTHREADS=2 16" "UPDATE_PCT=100"
pw c4_w50        2 "CACHES=$W" "MEMTHREADS=2 16" "UPDATE_PCT=50"
pw c5_ins        2 "CACHES=$W" "MEMTHREADS=2 16" "INSERT_PCT=100" "OPS_M=10"
pw c5_ins_idle   1 "CACHES=$W" "MEMTHREADS=1"    "INSERT_PCT=100" "${ONE[@]}"
pw c5_upd_idle   2 "CACHES=$W" "MEMTHREADS=0 1"  "UPDATE_PCT=100" "${ONE[@]}"
pw c7_ins10      2 "CACHES=$W" "MEMTHREADS=2 16" "INSERT_PCT=10" "OPS_M=10"
pw c7_ins50      2 "CACHES=$W" "MEMTHREADS=2 16" "INSERT_PCT=50" "OPS_M=10"
pw small_upd     4 "CACHES=8 128" "MEMTHREADS=2 16" "UPDATE_PCT=100" "OPS_M=10" "WARMUP_M=10"
pw small_ins     4 "CACHES=8 128" "MEMTHREADS=2 16" "INSERT_PCT=100" "OPS_M=10" "WARMUP_M=10"

apply_skip; show_plan
[ "${DRY_RUN:-0}" = 1 ] && { run_plan; exit 0; }

# compute node: NIC sampler + time-stamped console copy (as in run_c3_c8.sh)
if [ "$ROLE" = compute ]; then
  NIC_DIR="$FAIR/results/nic"; mkdir -p "$NIC_DIR"
  STAMP="pw_$(date +%Y%m%d_%H%M%S)"
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
