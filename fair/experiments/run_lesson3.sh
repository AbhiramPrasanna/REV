#!/bin/bash
# ===========================================================================
# run_lesson3.sh <memory|compute> -- the Lesson 3 sweep:
#   "Execution placement can make up for inherent weakness. Prior work argues
#    for radix trees over B+tree indexes (DART) because of read amplification
#    and RDMA traffic. Pushing cuts the B+tree's round trips and network bytes
#    and lets it compete with the radix tree."
#
# DART runs exactly as shipped (only ips[0] points at the memory server). It has
# no compute-side node cache and its memory server does no index work, so its
# lookups are one flat line at every cache size: the reference. DEX and CHIME run
# on the SAME 10-level tree as Lesson 2 (TREE_SETUP=deep: 50M keys, 6.25M
# leaves of 8 keys, 6 children per inner node, 1.25M inner nodes), with the same
# 36 clients, 10M warmup + 30M measured lookups, uniform and Zipf 0.99 keys.
#
# Parts (PARTS="a b c", all by default):
#   a  DEX on the Lesson 2 tree: DEX (pull, 0 memory server threads) and
#      DEX+Push (push from the deepest cached node, 1 2 4 8 16 threads), caches
#      8..1024 MB, lookups                                            (96 cells)
#      CHIME, CHIME+Push and CHIME+Push+Leaf on this tree are Lesson 2's part a
#      (l2b); collect_lesson3.py reads them from lesson2_all.csv, nothing reruns.
#   b  DART as shipped, lookups, at 8, 128 and 1024 MB: the cache value is
#      passed the way DART's own sweep passes it and has no effect, so the three
#      are repeats of the reference                                    (6 cells)
#   c  simple tuning, node size: each B+tree with the node size it ships with
#      (TREE_SETUP=model: DEX 1 KB pages, CHIME 64-entry nodes), pull against
#      push with 8 and 16 threads, caches 8 16 32 128 MB, lookups. With part a
#      (16-entry nodes, 10 levels) it shows the trade: big nodes read more
#      bytes per level but make the tree short; push takes away the height
#      cost, so small nodes stop costing round trips                  (48 cells)
#
# Every cell records throughput, p99, round trips per lookup and network bytes
# per lookup, which collect_lesson3.py turns into read amplification (bytes per
# 16 B key-value pair):
#   DEX    [newbench] "Avg. rdma read / op", "rdma rpc / op", "rdma read size/ op"
#          (the request is already in the read size; the 33 B reply is added)
#   CHIME  [RDMA node N] per_op round_trips / sends / bytes (CHIME_RDMA_STATS=1;
#          the 41 B reply of each pushed request is added)
#   DART   per-thread "avg rtt count" and "avg bandwidth consumption"; this build
#          does not count the shortcut-table search, so one round trip of 128 B
#          is added, the way DART's own DYNAMIC path counts it (art-node.cc:136)
# and memory server cores busy (DEX: memory log; CHIME: memory log; DART: 0).
#
# Build on BOTH servers first, from ~/REV (DART: ips[0] must be 10.30.1.8):
#   git pull
#   RUN_ID=l3_build TREE_SETUP=deep  ./fair/build.sh dex      # dex/build_288_352_mn_only
#   RUN_ID=l3_build TREE_SETUP=model ./fair/build.sh dex      # dex/build_1024_1024_mn_only (part c)
#   RUN_ID=l3_build TREE_SETUP=model ./fair/build.sh chime    # CHIME/build_span64_64      (part c)
#   RUN_ID=l3_build ./fair/build.sh dart
#   grep -n '"10.30.1.8"' DART/src/main/compute.cc            # ips[0]
#
# Run (memory first, same variables on both, one terminal each, no tmux):
#   server 8:  cd ~/REV && bash fair/experiments/run_lesson3.sh memory  2>&1 | tee ~/l3_memory.out
#   server 6:  cd ~/REV && bash fair/experiments/run_lesson3.sh compute 2>&1 | tee ~/l3_compute.out
#
# Useful variables (set the SAME on both servers):
#   PARTS="a b"     run only some parts
#   DRY_RUN=1       print the plan and the time estimate, run nothing
#   SKIP_TO=<block> resume from a block after a failure
#   SMOKE=1         3M warmup + 3M measured ops, caches 8 and 1024, threads 0 and 16,
#                   one DART cell per distribution: a ~25 minute check
#   L3_TAG=l3smoke  block-name prefix (keeps a smoke test apart from the real run)
#
# Results: fair/results/<tag>_<part>_*/{dex,dart,chime}/..., merged by
# fair/experiments/collect_lesson3.py into fair/results/lesson3_all.csv.
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${L3_TAG:=l3}"
: "${PARTS:=a b c}"
: "${L3_THREADS:=36}"                    # clients on the compute server, as Lessons 1 and 2
: "${L3_OPS_M:=30}"
: "${L3_WARMUP_M:=10}"
: "${MTS:=1 2 4 8 16}"                   # DEX+Push memory server threads (0 = DEX, part a)
: "${CACHES:=8 16 32 64 128 256 512 1024}"
: "${DART_CACHES:=8 128 1024}"           # no effect on DART: three repeats
: "${C_CACHES:=8 16 32 128}"
: "${C_MTS:=0 8 16}"
if [ "${SMOKE:-0}" = 1 ]; then
  L3_OPS_M=3; L3_WARMUP_M=3; MTS="16"; CACHES="8 1024"; DART_CACHES="8"
  C_CACHES="8"; C_MTS="0 16"
fi
part_on() { [[ " $PARTS " == *" $1 "* ]]; }
LOOKUPS="point-uniform point-zipf"

RUNENV=("THREADS=$L3_THREADS" "OPS_M=$L3_OPS_M" "WARMUP_M=$L3_WARMUP_M" "REV_PARK_CMP_DIRS=1")
DEXENV=("${RUNENV[@]}" "DEX_SAFE_PT=1")
# CHIME as in Lesson 2: hotspot buffer off, inner nodes only, [RDMA] counters on
CHIMEENV=("${RUNENV[@]}" "CHIME_HOTSPOT=0" "CHIME_PUSH_OPS=both" "LEAF_CACHE_MB="
          "CHIME_LEAF_BY_KEY=0" "CHIME_LEAF_OWNER=0" "CHIME_LEAF_ADMIT_PUSH=0"
          "CHIME_LEVEL_STATS=0" "CHIME_RDMA_STATS=1" "ZIPF_THETA=0.99")

MANIFEST=()   # chime blocks, in collect_lesson2.py's manifest format
dex_pair() {  # id-prefix tree caches memthreads(push) min
  local id=$1 tree=$2 cs=$3 mts=$4 min=$5 n
  n=$(count_cells "$cs" 0 "$LOOKUPS")
  add_block "${id}_dex" dex "$tree" "$n" "CACHES=$cs" "MEMTHREADS=0" "WORKLOADS=$LOOKUPS" "${DEXENV[@]}" "@min=$min"
  n=$(count_cells "$cs" "$mts" "$LOOKUPS")
  add_block "${id}_dexpush" dexr "$tree" "$n" "CACHES=$cs" "MEMTHREADS=$mts" "WORKLOADS=$LOOKUPS" "${DEXENV[@]}" "@min=$min"
}

# ---- a: DEX on the Lesson 2 tree ---------------------------------------------
part_on a && dex_pair "${L3_TAG}_a" deep "$CACHES" "$MTS" 2.4

# ---- b: DART as shipped ----------------------------------------------------------
if part_on b; then
  n=$(count_cells "$DART_CACHES" 0 "$LOOKUPS")
  add_block "${L3_TAG}_b_dart" dart deep "$n" "CACHES=$DART_CACHES" "MEMTHREADS=0" \
    "WORKLOADS=$LOOKUPS" "${RUNENV[@]}" "@min=2"
fi

# ---- c: node size as shipped (TREE_SETUP=model) -------------------------------------
if part_on c; then
  push_mts=""; for m in $C_MTS; do [ "$m" -gt 0 ] && push_mts="$push_mts $m"; done
  dex_pair "${L3_TAG}_c" model "$C_CACHES" "${push_mts# }" 2.4
  n=$(count_cells "$C_CACHES" "$C_MTS" "$LOOKUPS")
  add_block "${L3_TAG}_c_chime" chime model "$n" "CACHES=$C_CACHES" "MEMTHREADS=$C_MTS" \
    "WORKLOADS=$LOOKUPS" "${CHIMEENV[@]}" "CHIME_LEAF_SET=0" "CHIME_SCAN_OFFLOAD_ALWAYS=0" "@min=4"
  MANIFEST+=("${L3_TAG}_c_chime,c,\"CHIME, 64-entry nodes (as shipped)\",0,both,0,0.99,$LOOKUPS,$C_CACHES,$C_MTS")
fi

apply_skip; show_plan

if [ "$ROLE" = compute ] && [ "${DRY_RUN:-0}" != 1 ] && [ "${#MANIFEST[@]}" -gt 0 ]; then
  mf="$FAIR/results/${L3_TAG}_manifest.csv"; mkdir -p "$FAIR/results"
  [ -f "$mf" ] || echo "block,part,arm,leaf_pct,push_ops,scan_always,theta,workloads,caches,memthreads" > "$mf"
  for m in "${MANIFEST[@]}"; do grep -q "^${m%%,*}," "$mf" || echo "$m" >> "$mf"; done
fi

[ "${DRY_RUN:-0}" = 1 ] && { run_plan; exit 0; }

# DEX and DART run under sudo: ask once, keep the ticket fresh for the whole run
echo "== sudo: enter your password once; it is kept fresh until the run ends"
sudo -v || { echo "sudo -v failed; DEX and DART need sudo" >&2; exit 1; }
( while kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 60; done ) &

run_plan
if [ "$ROLE" = compute ]; then
  L3_TAG="$L3_TAG" python3 "$EXP_DIR/collect_lesson3.py" || true
  echo "== merged: fair/results/lesson3_all.csv"
fi
