#!/bin/bash
# ===========================================================================
# run_followups.sh <memory|compute> -- the two follow up runs, one after the
# other, after run_c3_c8.sh has finished:
#   1. run_zipf_hotspot.sh   CHIME, Zipf 0.99, hotspot buffer on (with and
#                            without the leaf cache, and CHIME's own rule)   8 cells
#   2. run_writes_small.sh   DEX and CHIME writes at 8 and 128 MB           16 cells
# ~1 h. Run on both servers, memory node first. If one part fails, rerun that
# part's own script (with SKIP_TO=<block> to resume inside it).
#
#   server 8:  bash fair/experiments/run_followups.sh memory  2>&1 | tee ~/f_memory.out
#   server 6:  bash fair/experiments/run_followups.sh compute 2>&1 | tee ~/f_compute.out
# ===========================================================================
set -uo pipefail
ROLE="${1:?usage: run_followups.sh <memory|compute>}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$DIR/run_zipf_hotspot.sh" "$ROLE" || { echo "!! run_zipf_hotspot.sh failed on $ROLE" >&2; exit 1; }
bash "$DIR/run_writes_small.sh" "$ROLE" || { echo "!! run_writes_small.sh failed on $ROLE" >&2; exit 1; }
echo "== follow ups done ($ROLE) $(date '+%F %T')"
