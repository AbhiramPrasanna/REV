#!/bin/bash
# ===========================================================================
# run_pair79.sh <memory|compute> -- everything for the second server pair
# (server 9 = memory, server 7 = compute, InfiniBand), one script after another:
#
#   1 check     run_pair_check.sh     3 reference cells (compare with 6 and 8)    ~8 min
#   2 zipf      run_zipf_hotspot.sh   CHIME, Zipf 0.99, hotspot buffer on          ~20 min
#   3 writes    run_writes_small.sh   DEX and CHIME writes at 8 and 128 MB         ~40 min
#   4 pushw     run_chime_pushw.sh    CHIME, writes pushed, mode 2                 ~1.2 h
#   5 partners  run_pair_partners.sh  the cells 2 and 4 compare with, on this pair ~35 min
#   ~3 h in all. STEPS="..." runs a subset (same on both servers), e.g. STEPS="pushw partners".
#   To resume inside a step: STEPS="<that step> <later steps>" SKIP_TO=<block>.
#
# The pair's addresses and NIC are set here (override any of them first):
#   MEM_IP=10.30.2.9 CMP_IP=10.30.2.7 REV_IB_DEV=ibp59s0 REV_IB_PORT=1 REV_IB_GID=0
# sudo is asked once and kept fresh for the whole run (the DEX steps need it).
#
#   server 9:  cd ~/REV && bash fair/experiments/run_pair79.sh memory 2>&1 | tee ~/p79_memory.out
#   server 7:  cd /storage/apa222/REV && TMPDIR=/storage/apa222/tmp \
#              bash fair/experiments/run_pair79.sh compute 2>&1 | tee /storage/apa222/p79_compute.out
# ===========================================================================
set -uo pipefail
ROLE="${1:?usage: run_pair79.sh <memory|compute>}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export MEM_IP="${MEM_IP:-10.30.2.9}" CMP_IP="${CMP_IP:-10.30.2.7}"
export REV_IB_DEV="${REV_IB_DEV:-ibp59s0}" REV_IB_PORT="${REV_IB_PORT:-1}" REV_IB_GID="${REV_IB_GID:-0}"
: "${STEPS:=check zipf writes pushw partners}"
echo "== pair 7/9 ($ROLE): MEM_IP=$MEM_IP CMP_IP=$CMP_IP REV_IB_DEV=$REV_IB_DEV port $REV_IB_PORT gid $REV_IB_GID"
echo "== steps: $STEPS"

# One sudo prompt for everything; the steps' own `sudo -v` then pass silently.
echo "== sudo: enter your password once; it is kept fresh until the run ends"
sudo -v || { echo "sudo -v failed" >&2; exit 1; }
( while kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 60; done ) &

step() {  # name script
  [[ " $STEPS " == *" $1 "* ]] || return 0
  echo; echo "################ step $1: $2  $(date '+%F %T')"
  bash "$DIR/$2" "$ROLE" || { echo "!! step $1 ($2) failed on $ROLE; fix it, then rerun with STEPS=\"$1 ...\" (SKIP_TO=<block> to resume inside it)" >&2; exit 1; }
}
step check    run_pair_check.sh
step zipf     run_zipf_hotspot.sh
step writes   run_writes_small.sh
step pushw    run_chime_pushw.sh
step partners run_pair_partners.sh
echo "== pair 7/9 done ($ROLE) $(date '+%F %T')"
