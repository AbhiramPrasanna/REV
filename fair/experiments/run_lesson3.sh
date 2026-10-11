#!/bin/bash
# ===========================================================================
# run_lesson3.sh <memory|compute> -- Lesson 3, on DART's own configuration:
#   "Execution placement can make up for inherent weakness. DART (SIGMOD'26)
#    argues for a radix tree over B+trees because of read amplification and
#    RDMA traffic, and reports DART ahead of DEX by 1.3x and of CHIME by 2-3x on
#    YCSB C. We rerun its configuration and add push."
#
# DART's setup (DART paper Section 5.1) and what this script does with it:
#   keys      60M random 8 B integers        KEYS_M=60 (DART's generator spreads
#                                            keys over 2^64; the B+trees hash theirs)
#   values    64 B                           VALUE_B=64 in all three: DART natively,
#                                            DEX and CHIME with simulated wide values
#                                            (DEX_VALUE_LEN, CHIME_VALUE_LEN +
#                                            CHIME_RPC_VALUE_PAD: every leaf entry and
#                                            every RPC message carries the whole value)
#   B+trees   as shipped (not stated)        TREE_SETUP=model: DEX 1 KB pages and its
#                                            sorted load, CHIME 64-entry nodes, CHIME's
#                                            own insert load, CHIME's hotspot buffer as
#                                            shipped (on above 50 MB)
#   workload  YCSB C, Zipf 0.99 (+ uniform)  part a; YCSB A (50% updates) in part b
#   cache     ~1 MB for every system, and    1 8 32 128 400 MB (DART keeps no node
#             a 1-400 MB sweep (Fig. 13)     cache in this build: a flat line)
#   machines  3 + 3 servers, 168 clients     1 + 1 servers, 36 clients (state it)
# DART runs exactly as shipped (only ips[0] points at the memory server).
#
# Parts (PARTS="a b", both by default):
#   a  YCSB C (lookups), uniform and Zipf 0.99, caches 1 8 32 128 400 MB:
#        DART                                                       (6 cells: 1, 128,
#                                                                    400 MB, repeats)
#        DEX           pull (0 memory server threads)                         (10)
#        DEX, own push DEX's rule (bottom four levels), 16 threads            (10)
#        DEX+Push      push from the deepest cached node, 4 8 16 threads      (30)
#        CHIME         as shipped, pull                                       (10)
#        CHIME+Push    as shipped + push, 4 8 16 threads                      (30)
#        CHIME+Push+Leaf  hot leaves (Lesson 2), Zipf, 8-400 MB, 4 8 16       (12)
#  b  YCSB A (50% lookups, 50% updates), Zipf 0.99, caches 1 and 128 MB:
#        DART, DEX, DEX+Push (16), CHIME, CHIME+Push (16; updates as CHIME
#        does them)                                                          (10)
#  118 cells, ~8.5 h. SMOKE=1: 3M + 3M ops, 1 and 128 MB, 16 threads, ~2 h (loading 60M keys dominates).
#
# Every cell records throughput, p99, round trips and network bytes per op;
# collect_lesson3.py adds each RPC reply, DART's uncounted shortcut-table read,
# and read amplification = bytes / (8 B key + value).
#
# Build on BOTH servers first, from ~/REV (DART: ips[0] must be 10.30.1.8):
#   git pull
#   RUN_ID=l3_build TREE_SETUP=model VALUE_B=64 ./fair/build.sh dex chime
#        -> dex/build_1024_1024_mn_only_v64, CHIME/build_span64_64_v64
#   RUN_ID=l3_build ./fair/build.sh dart
#   grep -c "value_bytes" dex/build_1024_1024_mn_only_v64/newbench    # >= 1
# Hugepages on the memory server (server 8): DEX and CHIME map a 64 GB pool and
# DART a 20 GiB region, one system at a time, so keep CHIME's setting:
#   sudo sysctl -w vm.nr_hugepages=36864      # 72 GiB (fewer: DEX/CHIME 'mmap failed!')
#
# Run (memory first, same variables on both, one terminal each, no tmux):
#   server 8:  cd ~/REV && bash fair/experiments/run_lesson3.sh memory  2>&1 | tee ~/l3_memory.out
#   server 6:  cd ~/REV && bash fair/experiments/run_lesson3.sh compute 2>&1 | tee ~/l3_compute.out
#
# Useful variables (set the SAME on both servers):
#   PARTS="a"       run only some parts
#   DRY_RUN=1       print the plan and the time estimate, run nothing
#   SKIP_TO=<block> resume from a block after a failure
#   SMOKE=1         the short check above
#   L3_TAG=l3smoke  block-name prefix (keeps a smoke test apart from the real run)
#
# Results: fair/results/<tag>_<part>_*/{dex,dart,chime}/..., merged by
# fair/experiments/collect_lesson3.py into fair/results/lesson3_all.csv.
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${L3_TAG:=l3}"
: "${PARTS:=a b}"
: "${L3_THREADS:=36}"                    # clients on the compute server, as Lessons 1 and 2
: "${L3_KEYS_M:=60}"                     # DART paper: 60M keys
: "${L3_VALUE_B:=64}"                    # DART paper: 64 B values
: "${L3_OPS_M:=30}"
: "${L3_WARMUP_M:=10}"
: "${L3_DART_MEM_MB:=20480}"             # DART's memory-server region (60M x 64 B + index)
: "${CACHES:=1 8 32 128 400}"
: "${DART_CACHES:=1 128 400}"            # no effect on DART: repeats
: "${LEAF_CACHES:=8 32 128 400}"         # the leaf split needs room beyond the top levels
: "${MTS:=4 8 16}"                       # memory server threads, push on
: "${OWN_MT:=16}"                        # DEX's own push rule
: "${B_CACHES:=1 128}"
: "${B_MT:=16}"
: "${INNER_MAX_MB:=32}"                  # CHIME+Push+Leaf: inner = min(this, cache / 2)
if [ "${SMOKE:-0}" = 1 ]; then
  L3_OPS_M=3; L3_WARMUP_M=3; CACHES="1 128"; DART_CACHES="1"; LEAF_CACHES="128"
  MTS="16"; B_CACHES="128"
fi
part_on() { [[ " $PARTS " == *" $1 "* ]]; }
C_WL="point-uniform point-zipf"
A_WL="point-zipf"

RUNENV=("THREADS=$L3_THREADS" "KEYS_M=$L3_KEYS_M" "VALUE_B=$L3_VALUE_B" "OPS_M=$L3_OPS_M"
        "WARMUP_M=$L3_WARMUP_M" "ZIPF_THETA=0.99" "REV_PARK_CMP_DIRS=1")
DEXENV=("${RUNENV[@]}" "DEX_SAFE_PT=1")
DARTENV=("${RUNENV[@]}" "DART_MEM_MB=$L3_DART_MEM_MB")
# CHIME as shipped: hotspot buffer on (CHIME turns it on by itself above 50 MB)
CHIMEENV=("${RUNENV[@]}" "CHIME_HOTSPOT=1" "CHIME_PUSH_OPS=both" "LEAF_CACHE_MB="
          "CHIME_LEAF_BY_KEY=0" "CHIME_LEAF_OWNER=0" "CHIME_LEAF_ADMIT_PUSH=0"
          "CHIME_LEVEL_STATS=0" "CHIME_RDMA_STATS=1")

MANIFEST=()   # chime blocks, in collect_lesson2.py's manifest format
dex_blk() {   # id system(dex|dexr) caches memthreads workloads min [VAR=..]
  local id=$1 sys=$2 cs=$3 mts=$4 wl=$5 min=$6; shift 6
  add_block "$id" "$sys" model "$(count_cells "$cs" "$mts" "$wl")" "CACHES=$cs" \
    "MEMTHREADS=$mts" "WORKLOADS=$wl" "${DEXENV[@]}" "$@" "@min=$min"
}
chime_blk() { # id part arm caches memthreads workloads min [VAR=..]
  local id=$1 part=$2 arm=$3 cs=$4 mts=$5 wl=$6 min=$7; shift 7
  add_block "$id" chime model "$(count_cells "$cs" "$mts" "$wl")" "CACHES=$cs" \
    "MEMTHREADS=$mts" "WORKLOADS=$wl" "${CHIMEENV[@]}" "CHIME_LEAF_SET=0" \
    "CHIME_SCAN_OFFLOAD_ALWAYS=0" "$@" "@min=$min"
  MANIFEST+=("$id,$part,\"$arm\",0,both,0,0.99,$wl,$cs,$mts")
}
dart_blk() {  # id caches workloads [VAR=..]
  local id=$1 cs=$2 wl=$3; shift 3
  add_block "$id" dart model "$(count_cells "$cs" 0 "$wl")" "CACHES=$cs" "MEMTHREADS=0" \
    "WORKLOADS=$wl" "${DARTENV[@]}" "$@" "@min=3"
}

# ---- a: YCSB C ------------------------------------------------------------------
if part_on a; then
  dart_blk  "${L3_TAG}_a_dart" "$DART_CACHES" "$C_WL"
  dex_blk   "${L3_TAG}_a_dex"     dex  "$CACHES" 0         "$C_WL" 3
  dex_blk   "${L3_TAG}_a_dexown"  dex  "$CACHES" "$OWN_MT" "$C_WL" 3
  dex_blk   "${L3_TAG}_a_dexpush" dexr "$CACHES" "$MTS"    "$C_WL" 3
  chime_blk "${L3_TAG}_a_chime" a "CHIME as shipped (+ push when threads > 0)" \
    "$CACHES" "0 $MTS" "$C_WL" 6
  for c in $LEAF_CACHES; do
    inner=$(( c / 2 < INNER_MAX_MB ? c / 2 : INNER_MAX_MB )); lmb=$(( c - inner ))
    chime_blk "${L3_TAG}_a_leaf_c$c" a "CHIME+Push+Leaf (${inner} MB inner + hot leaves)" \
      "$c" "$MTS" "$A_WL" 6 "CHIME_HOTSPOT=0" "LEAF_CACHE_MB=$lmb" "CHIME_LEAF_SET=1" \
      "CHIME_LEAF_BY_KEY=1" "CHIME_LEAF_OWNER=1" "CHIME_LEAF_ADMIT_PUSH=0.1"
  done
fi

# ---- b: YCSB A (50% updates) -----------------------------------------------------
if part_on b; then
  U=("UPDATE_PCT=50")
  dart_blk  "${L3_TAG}_b_dart" "$B_CACHES" "$A_WL" "${U[@]}"
  dex_blk   "${L3_TAG}_b_dex"     dex  "$B_CACHES" 0      "$A_WL" 3 "${U[@]}"
  dex_blk   "${L3_TAG}_b_dexpush" dexr "$B_CACHES" "$B_MT" "$A_WL" 3 "${U[@]}"
  chime_blk "${L3_TAG}_b_chime" b "CHIME as shipped, YCSB A" "$B_CACHES" "0 $B_MT" "$A_WL" 6 "${U[@]}"
fi

apply_skip; show_plan

if [ "$ROLE" = compute ] && [ "${DRY_RUN:-0}" != 1 ] && [ "${#MANIFEST[@]}" -gt 0 ]; then
  mf="$FAIR/results/${L3_TAG}_manifest.csv"; mkdir -p "$FAIR/results"
  [ -f "$mf" ] || echo "block,part,arm,leaf_pct,push_ops,scan_always,theta,workloads,caches,memthreads" > "$mf"
  for m in "${MANIFEST[@]}"; do grep -q "^${m%%,*}," "$mf" || echo "$m" >> "$mf"; done
fi

[ "${DRY_RUN:-0}" = 1 ] && { run_plan; exit 0; }

# The memory server maps DEX's and CHIME's 64 GB pool (and DART's region) in
# hugepages: stop before the first block if there are too few
if [ "$ROLE" = memory ]; then
  hp=$(awk '/HugePages_Total/{print $2}' /proc/meminfo 2>/dev/null)
  if [ -n "$hp" ] && [ "$hp" -lt 34816 ]; then
    echo "ERROR: $hp hugepages ($((hp * 2)) MiB); DEX and CHIME need a 64 GB pool plus buffers." >&2
    echo "       sudo sysctl -w vm.nr_hugepages=36864   then rerun" >&2
    exit 1
  fi
fi

# DEX and DART run under sudo: ask once, keep the ticket fresh for the whole run
echo "== sudo: enter your password once; it is kept fresh until the run ends"
sudo -v || { echo "sudo -v failed; DEX and DART need sudo" >&2; exit 1; }
( while kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 60; done ) &

run_plan
if [ "$ROLE" = compute ]; then
  L3_TAG="$L3_TAG" python3 "$EXP_DIR/collect_lesson3.py" || true
  echo "== merged: fair/results/lesson3_all.csv"
fi
