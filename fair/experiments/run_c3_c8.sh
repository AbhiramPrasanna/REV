#!/bin/bash
# ===========================================================================
# run_c3_c8.sh <memory|compute> -- everything left after c1-c4, end to end, on
# the height-10 trees (TREE_SETUP=deep), in the same setup as
# quick_c1c4_missing.sh: 40 clients on CPUs 0-39, memory thread k on CPU 80-k,
# the compute node's idle directory threads parked (REV_PARK_CMP_DIRS=1), DEX as
# DEX-R, CHIME with its hotspot buffer off (CHIME_HOTSPOT=0; set CHIME_HOTSPOT=1
# on both servers to run CHIME as shipped).
#
# Network bandwidth: on the compute node the script samples the RDMA port byte
# counters every 0.5 s (nic_sampler.sh) and stamps every console line with the
# time, so nic_bandwidth.py gives the bytes per second of every cell:
#   fair/results/nic/<stamp>_nic.csv, <stamp>_ts.log  ->  <stamp>_bandwidth.csv
#
# PARTS (default: all, in this order). 180 cells, about 7.5 h.
#   c3     one client, 1 GB and 8 MB, pull and 1 thread, 10 M warmup:
#          DEX and CHIME (CHIME's c3 done properly)                          8
#   c2     CHIME pull at 64 and 160 MB (its cache holds every inner node
#          at about 160 MB)                                                  2
#   c1     memory cores at 8 MB (pull, 1, 2, 4, 8, 16) and network
#          bandwidth at 1 GB (pull, 2, 16), both systems                    18
#   c4     scan length 10 and 1000 (pull, 2, 16); one client scans of 10
#          and 100 keys (pull, 1); 50% updates (pull, 2, 16); both systems  26
#   c5     inserts: 40 clients (pull, 2) and one client (pull, 1); CHIME
#          pushes no writes, so pull only                                    6
#   c6     load: 1, 8 and 24 clients (pull, 2, 4) plus 40 clients with 4;
#          DEX at 128 MB (one inner level missing, as in the summary's
#          Fig. 6), CHIME at 1 GB (its inner tree fits). Skew: Zipf 0.9
#          and 0.99 at 1 GB (pull, 2, 16)                                   32
#   c7     10% and 50% inserts at 1 GB (pull, 2, 16)                        12
#   c8     each system's own push rule (stock DEX, CHIME's own offload
#          rule) for lookups, 100 key scans and Zipf 0.99, at 2 and 16      12
#   lc     CHIME with its leaf cache (our add on) wherever the inner tree
#          fits: the inner nodes get what they need, the leaf cache the rest
#          (1 GB = about 830 MB of leaves). c1 to c8 cells at 1 GB, plus
#          256 and 512 MB for c2. Needs the CHIME build with
#          CHIME_LEAF_BEFORE_PUSH (rebuild CHIME on both servers first)       44
#   e.g.   PARTS="c3 c1" bash fair/experiments/run_c3_c8.sh <role>   (same on both)
#
# Resume after a failure: SKIP_TO=<block id> on both servers.
#
#   server 8:  bash fair/experiments/run_c3_c8.sh memory  2>&1 | tee ~/r_memory.out
#   server 6:  bash fair/experiments/run_c3_c8.sh compute 2>&1 | tee ~/r_compute.out
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${PARTS:=c3 c2 c1 c4 c5 c6 c7 c8 lc}"
has() { [[ " $PARTS " == *" $1 "* ]]; }
n() { count_cells x "$1" x; }

T=deep W=1024 M1=128 S=8
OFF="CHIME_HOTSPOT=${CHIME_HOTSPOT:-0}"
PARK="REV_PARK_CMP_DIRS=1"
P1="CHIME_OFFLOAD_MIN_LEVEL=1"                 # CHIME push from the deepest cached node
ALWAYS="CHIME_SCAN_OFFLOAD_ALWAYS=1"            # CHIME scans pushed whole (as in c4)
ONE=("THREADS=1" "OPS_M=1" "WARMUP_M=10")       # one client, warm cache (10 M lookups touch every inner node)
LOOK="WORKLOADS=point-uniform"

# DEX block and CHIME block with the same settings
both() {  # id_suffix dex_min chime_min cells VAR=value...   (CHIME gets OFF, PARK; DEX gets PARK)
  local id=$1 dm=$2 cm=$3 c=$4; shift 4
  add_block "r_${id}_dexr"  dexr  $T "$c" "$@" "$PARK" "@min=$dm"
  add_block "r_${id}_chime" chime $T "$c" "$@" "$OFF" "$PARK" "@min=$cm"
}
both_push() {  # same, CHIME pushing from the deepest cached node
  local id=$1 dm=$2 cm=$3 c=$4; shift 4
  add_block "r_${id}_dexr"  dexr  $T "$c" "$@" "$PARK" "@min=$dm"
  add_block "r_${id}_chime" chime $T "$c" "$@" "$OFF" "$P1" "$PARK" "@min=$cm"
}
both_scan() {  # id min_dex min_chime cells scan_len VAR=value...
  local id=$1 dm=$2 cm=$3 c=$4 len=$5; shift 5
  add_block "r_${id}_dexr"  dexr  $T "$c" "WORKLOADS=range-uniform" "SCAN_LEN=$len" "$@" "$PARK" "@min=$dm"
  add_block "r_${id}_chime" chime $T "$c" "WORKLOADS=range-uniform" "SCAN_LEN=$len" "$@" "$ALWAYS" "$OFF" "$PARK" "@min=$cm"
}

if has c3; then
  both_push c3 3 5 4 "CACHES=$W $S" "MEMTHREADS=0 1" "$LOOK" "${ONE[@]}"
fi
if has c2; then
  add_block r_c2_chime_fit chime $T 2 "CACHES=64 160" "MEMTHREADS=0" "$LOOK" "$OFF" "$PARK" "@min=2"
fi
if has c1; then
  both_push c1_8mb 2.4 2 6 "CACHES=$S" "MEMTHREADS=0 1 2 4 8 16" "$LOOK"
  both_push c1_1gb 2.4 2 3 "CACHES=$W" "MEMTHREADS=0 2 16" "$LOOK"
fi
if has c4; then
  both_scan c4_scan10   2.4 2.5 3 10   "CACHES=$W" "MEMTHREADS=0 2 16" "OPS_M=2" "WARMUP_M=2"
  both_scan c4_scan1000 3   4   3 1000 "CACHES=$W" "MEMTHREADS=0 2 16" "OPS_M=1" "WARMUP_M=1"
  both_scan c4_idle_scan10  3 4 2 10  "CACHES=$W" "MEMTHREADS=0 1" "THREADS=1" "OPS_M=1" "WARMUP_M=3"
  both_scan c4_idle_scan100 4 6 2 100 "CACHES=$W" "MEMTHREADS=0 1" "THREADS=1" "OPS_M=1" "WARMUP_M=3"
  both_push c4_w50 2.4 2 3 "CACHES=$W" "MEMTHREADS=0 2 16" "$LOOK" "UPDATE_PCT=50"
fi
if has c5; then
  add_block r_c5_dexr_ins       dexr  $T 2 "CACHES=$W" "MEMTHREADS=0 2" "$LOOK" "INSERT_PCT=100" "OPS_M=10" "$PARK" "@min=2.4"
  add_block r_c5_dexr_ins_idle  dexr  $T 2 "CACHES=$W" "MEMTHREADS=0 1" "$LOOK" "INSERT_PCT=100" "${ONE[@]}" "$PARK" "@min=4"
  add_block r_c5_chime_ins      chime $T 1 "CACHES=$W" "MEMTHREADS=0"   "$LOOK" "INSERT_PCT=100" "OPS_M=10" "$OFF" "$PARK" "@min=2.5"
  add_block r_c5_chime_ins_idle chime $T 1 "CACHES=$W" "MEMTHREADS=0"   "$LOOK" "INSERT_PCT=100" "${ONE[@]}" "$OFF" "$PARK" "@min=5"
fi
if has c6; then
  for cl in 1 8 24; do
    ops=10; [ "$cl" = 1 ] && ops=1
    add_block "r_c6_dexr_load_t$cl"  dexr  $T 3 "THREADS=$cl" "OPS_M=$ops" "CACHES=$M1" "MEMTHREADS=0 2 4" "$LOOK" "$PARK" "@min=3"
    add_block "r_c6_chime_load_t$cl" chime $T 3 "THREADS=$cl" "OPS_M=$ops" "CACHES=$W"  "MEMTHREADS=0 2 4" "$LOOK" "$OFF" "$P1" "$PARK" "@min=3.5"
  done
  add_block r_c6_dexr_load_t40  dexr  $T 1 "CACHES=$M1" "MEMTHREADS=4" "$LOOK" "$PARK" "@min=2.4"
  add_block r_c6_chime_load_t40 chime $T 1 "CACHES=$W"  "MEMTHREADS=4" "$LOOK" "$OFF" "$P1" "$PARK" "@min=2"
  for z in 0.9 0.99; do
    both_push "c6_zipf${z#0.}" 2.4 2 3 "CACHES=$W" "MEMTHREADS=0 2 16" "WORKLOADS=point-zipf" "ZIPF_THETA=$z"
  done
fi
if has c7; then
  for p in 10 50; do
    both_push "c7_ins$p" 2.4 2.5 3 "CACHES=$W" "MEMTHREADS=0 2 16" "$LOOK" "INSERT_PCT=$p" "OPS_M=10"
  done
fi
if has c8; then
  # each system's own rule: stock DEX (pushes only in its bottom levels) and
  # CHIME's own offload rule (no CHIME_OFFLOAD_MIN_LEVEL, scans pushed on a miss)
  add_block r_c8_dex_rule        dex   $T 2 "CACHES=$W" "MEMTHREADS=2 16" "$LOOK" "$PARK" "@min=2.4"
  add_block r_c8_dex_rule_scan   dex   $T 2 "CACHES=$W" "MEMTHREADS=2 16" "WORKLOADS=range-uniform" "SCAN_LEN=100" "OPS_M=2" "WARMUP_M=2" "$PARK" "@min=2.4"
  add_block r_c8_dex_rule_zipf   dex   $T 2 "CACHES=$W" "MEMTHREADS=2 16" "WORKLOADS=point-zipf" "ZIPF_THETA=0.99" "$PARK" "@min=2.4"
  add_block r_c8_chime_rule      chime $T 2 "CACHES=$W" "MEMTHREADS=2 16" "$LOOK" "$OFF" "$PARK" "@min=2"
  add_block r_c8_chime_rule_scan chime $T 2 "CACHES=$W" "MEMTHREADS=2 16" "WORKLOADS=range-uniform" "SCAN_LEN=100" "OPS_M=2" "WARMUP_M=2" "$OFF" "$PARK" "@min=2.5"
  add_block r_c8_chime_rule_zipf chime $T 2 "CACHES=$W" "MEMTHREADS=2 16" "WORKLOADS=point-zipf" "ZIPF_THETA=0.99" "$OFF" "$PARK" "@min=2"
fi

if has lc; then
  # CHIME with its leaf cache (our add on, not part of CHIME): the inner nodes
  # get what they need (the whole inner tree takes 162 MB of tree cache; 192 MB
  # leaves room, 256 MB for runs whose inserts grow the tree) and the leaf cache
  # gets the rest of the budget. Below that the leaf cache stays off, so 8 MB and
  # 128 MB are the same as plain CHIME and are not rerun.
  # CHIME_LEAF_BEFORE_PUSH=1: a lookup whose leaf is cached is answered from the
  # cache (one 16 byte check, no memory node CPU) instead of being pushed.
  lc() {  # id cache inner_mb cells VAR=value...
    local id=$1 c=$2 in=$3 cells=$4; shift 4
    add_block "r_lc_$id" chime $T "$cells" "CACHES=$c" "CHIME_LEAF_SET=1" "LEAF_CACHE_MB=$((c - in))" \
      "CHIME_LEAF_BEFORE_PUSH=1" "$@" "$OFF" "$PARK" "@min=2.5"
  }
  lc c1_1gb        $W 192 6 "MEMTHREADS=0 1 2 4 8 16" "$LOOK" "$P1"
  lc c2_256mb     256 192 3 "MEMTHREADS=0 2 16" "$LOOK" "$P1"
  lc c2_512mb     512 192 3 "MEMTHREADS=0 2 16" "$LOOK" "$P1"
  lc c3_1gb        $W 192 2 "MEMTHREADS=0 1" "$LOOK" "$P1" "${ONE[@]}"
  lc c4_scan100    $W 192 3 "MEMTHREADS=0 2 16" "WORKLOADS=range-uniform" "SCAN_LEN=100" "OPS_M=2" "WARMUP_M=2" "$ALWAYS" "LEAF_ADMIT_SCAN=0.1"
  lc c4_upd100     $W 192 1 "MEMTHREADS=0" "$LOOK" "UPDATE_PCT=100"
  lc c4_w50        $W 192 3 "MEMTHREADS=0 2 16" "$LOOK" "UPDATE_PCT=50" "$P1"
  lc c5_ins        $W 256 1 "MEMTHREADS=0" "$LOOK" "INSERT_PCT=100" "OPS_M=10"
  lc c5_ins_idle   $W 256 1 "MEMTHREADS=0" "$LOOK" "INSERT_PCT=100" "${ONE[@]}"
  lc c5_idle_scan100 $W 192 2 "MEMTHREADS=0 1" "WORKLOADS=range-uniform" "SCAN_LEN=100" "THREADS=1" "OPS_M=1" "WARMUP_M=3" "$ALWAYS" "LEAF_ADMIT_SCAN=0.1"
  lc c6_zipf99     $W 192 3 "MEMTHREADS=0 2 16" "WORKLOADS=point-zipf" "ZIPF_THETA=0.99" "$P1"
  lc c6_load_t8    $W 192 3 "THREADS=8" "MEMTHREADS=0 2 4" "$LOOK" "$P1"
  lc c6_load_t24   $W 192 3 "THREADS=24" "MEMTHREADS=0 2 4" "$LOOK" "$P1"
  lc c7_ins10      $W 256 3 "MEMTHREADS=0 2 16" "$LOOK" "INSERT_PCT=10" "OPS_M=10" "$P1"
  lc c7_ins50      $W 256 3 "MEMTHREADS=0 2 16" "$LOOK" "INSERT_PCT=50" "OPS_M=10" "$P1"
  lc c8_rule       $W 192 2 "MEMTHREADS=2 16" "$LOOK"
  lc c8_rule_zipf  $W 192 2 "MEMTHREADS=2 16" "WORKLOADS=point-zipf" "ZIPF_THETA=0.99"
fi

apply_skip; show_plan
[ "${DRY_RUN:-0}" = 1 ] && { run_plan; exit 0; }

# ---- compute node: NIC sampler + time-stamped console copy --------------------
if [ "$ROLE" = compute ]; then
  NIC_DIR="$FAIR/results/nic"; mkdir -p "$NIC_DIR"
  STAMP="r_$(date +%Y%m%d_%H%M%S)"
  NIC_CSV="$NIC_DIR/${STAMP}_nic.csv"; export TSLOG="$NIC_DIR/${STAMP}_ts.log"
  bash "$EXP_DIR/nic_sampler.sh" "$NIC_CSV" 0.5 & SAMPLER=$!
  trap 'kill $SAMPLER 2>/dev/null; echo "network samples: $NIC_CSV"; echo "bandwidth: python3 $EXP_DIR/nic_bandwidth.py $TSLOG $NIC_CSV"' EXIT
  if command -v perl >/dev/null; then
    exec > >(perl -MTime::HiRes=time -ne 'BEGIN{$|=1; open(F, ">>", $ENV{TSLOG}) or die; select((select(F), $|=1)[0])} print; printf F "%.3f %s", time, $_') 2>&1
  else
    exec > >(while IFS= read -r l; do printf '%s\n' "$l"; printf '%s %s\n' "$(date +%s.%N)" "$l" >> "$TSLOG"; done) 2>&1
  fi
  echo "== network samples -> $NIC_CSV (every 0.5 s), stamped console -> $TSLOG"
fi

run_plan
if [ "$ROLE" = compute ]; then
  python3 "$EXP_DIR/nic_bandwidth.py" "$TSLOG" "$NIC_CSV" || true
fi
