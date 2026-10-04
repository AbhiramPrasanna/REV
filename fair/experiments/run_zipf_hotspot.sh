#!/bin/bash
# ===========================================================================
# run_zipf_hotspot.sh <memory|compute> -- CHIME with its hotspot buffer ON for
# the skewed (Zipf 0.99) cases, the access pattern the buffer is built for. Run
# it after run_c3_c8.sh, whose CHIME cells all have the buffer off. Same setup
# as run_c3_c8.sh: height-10 tree, 1 GB, 40 clients, idle directory threads
# parked, network samples on the compute node.
#
#   r_hz_c6_zipf99_chime     buffer on, no leaf cache: pull, 2, 16 threads,
#                            pushed from the deepest cached node             3
#   r_hz_c6_zipf99_lc        buffer on AND leaf cache (stacked): pull, 2, 16;
#                            inner nodes 192 MB, buffer 30 MB, leaves 802 MB   3
#   r_hz_c8_rule_zipf_chime  buffer on, CHIME's own push rule: 2, 16 threads  2
#
# Compare with run_c3_c8.sh's r_c6_zipf99_chime, r_lc_c6_zipf99 and
# r_c8_chime_rule_zipf (same cells, buffer off). ~20 min.
#
#   server 8:  bash fair/experiments/run_zipf_hotspot.sh memory  2>&1 | tee ~/hz_memory.out
#   server 6:  bash fair/experiments/run_zipf_hotspot.sh compute 2>&1 | tee ~/hz_compute.out
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

T=deep W=1024
HOT="CHIME_HOTSPOT=1"
PARK="REV_PARK_CMP_DIRS=1"
P1="CHIME_OFFLOAD_MIN_LEVEL=1"
ZIPF=("WORKLOADS=point-zipf" "ZIPF_THETA=0.99")

add_block r_hz_c6_zipf99_chime chime $T 3 "CACHES=$W" "MEMTHREADS=0 2 16" "${ZIPF[@]}" "$HOT" "$P1" "$PARK" "@min=2"
# stacked: the buffer's 30 MB comes out of the inner budget, so leaves get
# 1024 - 192 - 30 = 802 MB and the tree cache keeps its 192 MB
add_block r_hz_c6_zipf99_lc chime $T 3 "CACHES=$W" "MEMTHREADS=0 2 16" "${ZIPF[@]}" "$HOT" \
  "CHIME_LEAF_SET=1" "LEAF_CACHE_MB=802" "CHIME_LEAF_KEEP_SPECULATIVE=1" "CHIME_LEAF_BEFORE_PUSH=1" \
  "$P1" "$PARK" "@min=2.5"
add_block r_hz_c8_rule_zipf_chime chime $T 2 "CACHES=$W" "MEMTHREADS=2 16" "${ZIPF[@]}" "$HOT" "$PARK" "@min=2"

apply_skip; show_plan
[ "${DRY_RUN:-0}" = 1 ] && { run_plan; exit 0; }

# compute node: NIC sampler + time-stamped console copy (as in run_c3_c8.sh)
if [ "$ROLE" = compute ]; then
  NIC_DIR="$FAIR/results/nic"; mkdir -p "$NIC_DIR"
  STAMP="hz_$(date +%Y%m%d_%H%M%S)"
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
