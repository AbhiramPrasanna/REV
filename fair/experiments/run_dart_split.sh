#!/bin/bash
# ===========================================================================
# run_dart_split.sh <memory|compute> -- DART with a fixed memory budget split
# between its shortcut table (memory server) and the hot-entry cache (compute
# server): is a bigger shortcut table or a cache of hot shortcuts the better
# use of the same memory?
#
# For every budget B and every table depth d whose table fits in B, one block:
#   shortcut table  2^d segments of 13.5 KiB (DART_INIT_DEPTH=d):
#                   d=10 13.5 MiB, 11 27, 12 54, 13 108, 14 216, 15 432 (as released)
#   hot-entry cache the rest of B (DART_EST_CACHE=1, include/prheart/est_cache.hpp);
#                   none when the table takes the whole budget
# The table's directory (2^d x 24 B, at most 0.75 MiB) is not counted, as in
# the l3_m runs. A table too small for the 16.8M shortcuts drops the rest
# (shortcuts_dropped_pct); the cache can hold only shortcuts the table kept.
#
# Defaults: budgets 27 54 108 216 433 866 MB, depths 10-15, uniform and Zipfian
# lookups, 60M keys, 64 B values, 36 clients, 10M warmup lookups (fills the
# cache; also run when the cache is off, so every block warms up the same way),
# 30M measured. 26 blocks x 2 = 52 cells, ~2.2 h.
#
# Needs DART built at each depth on BOTH servers (depth 15 = DART/bin, others
# DART/bin_d<d>; depth 10 is new):
#   for d in 10 11 12 13 14 15; do RUN_ID=b DART_INIT_DEPTH=$d ./fair/build.sh dart; done
#
#   server 8:  bash fair/experiments/run_dart_split.sh memory  2>&1 | tee ~/dsplit_memory.out
#   server 6:  bash fair/experiments/run_dart_split.sh compute 2>&1 | tee ~/dsplit_compute.out
#
# Variables (set the SAME on both servers):
#   BUDGETS="27 54 108 216 433 866"   DEPTHS="10 11 12 13 14 15"
#   DS_TAG=dsplit   block prefix: blocks are <tag>_b<B>_d<d>
#   DRY_RUN=1       print the plan only        SKIP_TO=<block>  resume
#   SUMMARY_ONLY=1  (compute) print the table of finished blocks and exit
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${BUDGETS:=27 54 108 216 433 866}"
: "${DEPTHS:=10 11 12 13 14 15}"
: "${DS_TAG:=dsplit}"
: "${DS_THREADS:=36}" "${DS_OPS_M:=30}" "${DS_WARMUP_M:=10}"
WL="point-uniform point-zipf"
REV_DIR="$(cd "$FAIR/.." && pwd)"

table_mb() {   # depth -> shortcut-table MiB, rounded up (13.5 KiB x 2^d)
  awk -v d="$1" 'BEGIN{t = 13.5 * 2^d / 1024; printf "%d", (t == int(t)) ? t : int(t) + 1}'
}
bin_of() { [ "$1" = 15 ] && echo "$REV_DIR/DART/bin" || echo "$REV_DIR/DART/bin_d$1"; }

summary() {
  local f
  printf "%-6s %-5s %-9s %-9s | %-8s %-6s %-6s | %-8s %-6s %-6s | %s\n" budget depth table_MiB cache_MB \
    uni_Mops trips hit% zipf_Mops trips hit% dropped%
  for B in $BUDGETS; do for d in $DEPTHS; do
    f="$FAIR/results/${DS_TAG}_b${B}_d${d}/dart/dart.csv"
    [ -f "$f" ] || continue
    awk -F, -v B="$B" -v d="$d" '
      NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
      { k = $c["dist"]; t[k] = $c["tput_mops"]; e = $c["est_cache_mb"] + 0
        # the shipped counters skip the shortcut-table search; with the cache on it is counted
        r[k] = $c["rtt_per_op"] + (e > 0 ? 0 : 1); h[k] = $c["est_hit_pct"]; tm = $c["table_mib"]
        dr = $c["shortcuts_dropped_pct"]; cm = e }
      END { printf "%-6s %-5s %-9s %-9s | %-8s %-6.2f %-6s | %-8s %-6.2f %-6s | %s\n", B, d, tm, cm,
            t["uniform"], r["uniform"], h["uniform"], t["zipf"], r["zipf"], h["zipf"], dr }' "$f"
  done; done
}
if [ "${SUMMARY_ONLY:-0}" = 1 ]; then summary; exit 0; fi

missing=0
for d in $DEPTHS; do
  [ -x "$(bin_of "$d")/compute" ] && [ -x "$(bin_of "$d")/memory" ] || {
    echo "missing DART build for depth $d ($(bin_of "$d")): RUN_ID=b DART_INIT_DEPTH=$d ./fair/build.sh dart" >&2
    missing=1; }
done
[ "$missing" = 1 ] && [ "${DRY_RUN:-0}" != 1 ] && exit 1

RUNENV=("THREADS=$DS_THREADS" "KEYS_M=60" "VALUE_B=64" "OPS_M=$DS_OPS_M" "WARMUP_M=$DS_WARMUP_M"
        "ZIPF_THETA=0.99" "REV_PARK_CMP_DIRS=1" "DART_MEM_MB=20480" "DART_WARMUP_M=$DS_WARMUP_M"
        "MEMTHREADS=0" "WORKLOADS=$WL")
for B in $BUDGETS; do
  for d in $DEPTHS; do
    t=$(table_mb "$d")
    [ "$t" -le "$B" ] || continue
    if [ $((B - t)) -gt 1 ]; then
      # the cache gets cache - DART_DIR_MB (run_dart.sh): DART_DIR_MB = the table
      est=("DART_EST_CACHE=1" "DART_DIR_MB=$t")
    else
      est=("DART_EST_CACHE=0")          # the table takes the whole budget
    fi
    plan_block "${DS_TAG}_b${B}_d${d}" dart model 2 "CACHES=$B" "DART_INIT_DEPTH=$d" \
      "${est[@]}" "${RUNENV[@]}" "@min=2.5"
  done
done

apply_skip; show_plan
[ "${DRY_RUN:-0}" = 1 ] && { run_plan; exit 0; }
run_plan
[ "$ROLE" = compute ] && { echo; echo "== budget split summary"; summary; }
