#!/bin/bash
# ===========================================================================
# run_chime_pushw.sh <memory|compute> -- CHIME with write pushdown, for every
# challenge that has writes. Default mode 2 (PUSHW_MODE=2): the memory node
# owns writes, as DEX's memory node does and as the pull/push model assumes --
# every insert and update is pushed, the memory node's workers lock with CPU
# atomics and write with one NIC write (CHIME/include/push_write.h).
# PUSHW_MODE=1 runs the same cells in mode 1 (delegation) instead.
# Needs the CHIME build that has push_write.h, on BOTH servers.
#
# Setup as run_c3_c8.sh: height-10 tree, hotspot buffer off, reads pushed from
# the deepest cached node, compute node's idle directory threads parked.
# Memory node: one write worker per memory thread (the default), pinned to
# CPUs 0-15, physical cores the directory threads (CPUs 79 down) do not use.
# So "memory threads = m" in a push cell means m directory threads plus m
# write workers. Pull cells run with CHIME_PUSH_WRITES=0.
#
#   challenge  block (r_pw<mode>_...)  cells                       pull partner
#   C4         c4_w25, c4_w75          1 GB, 25/75% updates, 2 16  c4_w25_pull, c4_w75_pull (here)
#              c4_w50, c4_upd100       1 GB, 50/100% updates, 2 16 r_c4_w50_chime, qn_c4_chime_upd
#   C5         c5_ins                  1 GB, inserts, 2 16         r_c5_chime_ins
#              c5_ins_idle             1 client, inserts, 1        r_c5_chime_ins_idle
#              c5_upd_idle             1 client, updates, 1        c5_upd_idle_pull (here)
#   C7         c7_ins10, c7_ins50      1 GB, 10/50% inserts, 2 16  r_c7_ins10/50_chime
#   small      small_upd, small_ins    8 and 128 MB, 2 16          r_w_c45_chime_upd/ins
#   27 cells, ~1.2 h
#
#   server 8:  bash fair/experiments/run_chime_pushw.sh memory  2>&1 | tee ~/pw_memory.out
#   server 6:  bash fair/experiments/run_chime_pushw.sh compute 2>&1 | tee ~/pw_compute.out
# Each push cell's compute log ends with "[PUSHW] node 1: writes pushed=<n>"
# and the memory log with "writes run for other nodes=<n>": both must be non
# zero. Mode 2 stops with "[PUSHW] mode 2: ..." rather than run unsafely.
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${PUSHW_MODE:=2}"
T=deep W=1024 M="pw${PUSHW_MODE}"
PUSH=("CHIME_PUSH_WRITES=$PUSHW_MODE" "CHIME_PUSH_WRITE_CPUS=0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15")
COMMON=("CHIME_HOTSPOT=0" "CHIME_OFFLOAD_MIN_LEVEL=1" "REV_PARK_CMP_DIRS=1" "WORKLOADS=point-uniform")
ONE=("THREADS=1" "OPS_M=1" "WARMUP_M=10")
push() {  # id cells VAR=value...   writes pushed
  local id=$1 c=$2; shift 2
  add_block "r_${M}_$id" chime $T "$c" "$@" "${PUSH[@]}" "${COMMON[@]}" "@min=2.5"
}
pull() {  # id cells VAR=value...   writes pulled, 0 memory threads
  local id=$1 c=$2; shift 2
  add_block "r_${M}_$id" chime $T "$c" "$@" "CHIME_PUSH_WRITES=0" "MEMTHREADS=0" "${COMMON[@]}" "@min=2.5"
}

# C4: write fraction
push c4_w25       2 "CACHES=$W" "MEMTHREADS=2 16" "UPDATE_PCT=25"
pull c4_w25_pull  1 "CACHES=$W" "UPDATE_PCT=25"
push c4_w50       2 "CACHES=$W" "MEMTHREADS=2 16" "UPDATE_PCT=50"
push c4_w75       2 "CACHES=$W" "MEMTHREADS=2 16" "UPDATE_PCT=75"
pull c4_w75_pull  1 "CACHES=$W" "UPDATE_PCT=75"
push c4_upd100    2 "CACHES=$W" "MEMTHREADS=2 16" "UPDATE_PCT=100"
# C5: inserts and updates, throughput and one client latency
push c5_ins       2 "CACHES=$W" "MEMTHREADS=2 16" "INSERT_PCT=100" "OPS_M=10"
push c5_ins_idle  1 "CACHES=$W" "MEMTHREADS=1"    "INSERT_PCT=100" "${ONE[@]}"
push c5_upd_idle  1 "CACHES=$W" "MEMTHREADS=1"    "UPDATE_PCT=100" "${ONE[@]}"
pull c5_upd_idle_pull 1 "CACHES=$W"               "UPDATE_PCT=100" "${ONE[@]}"
# C7: inserts mixed with lookups (coherence)
push c7_ins10     2 "CACHES=$W" "MEMTHREADS=2 16" "INSERT_PCT=10" "OPS_M=10"
push c7_ins50     2 "CACHES=$W" "MEMTHREADS=2 16" "INSERT_PCT=50" "OPS_M=10"
# writes at small caches (a write misses inner nodes there)
push small_upd    4 "CACHES=8 128" "MEMTHREADS=2 16" "UPDATE_PCT=100" "OPS_M=10" "WARMUP_M=10"
push small_ins    4 "CACHES=8 128" "MEMTHREADS=2 16" "INSERT_PCT=100" "OPS_M=10" "WARMUP_M=10"

apply_skip; show_plan
[ "${DRY_RUN:-0}" = 1 ] && { run_plan; exit 0; }

# compute node: NIC sampler + time-stamped console copy (as in run_c3_c8.sh)
if [ "$ROLE" = compute ]; then
  NIC_DIR="$FAIR/results/nic"; mkdir -p "$NIC_DIR"
  STAMP="${M}_$(date +%Y%m%d_%H%M%S)"
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
