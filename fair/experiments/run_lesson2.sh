#!/bin/bash
# ===========================================================================
# run_lesson2.sh <memory|compute> -- every CHIME-2P run behind Lesson 2:
#   "Pushing and pulling should be selected by operation and index level."
#
# Five parts. Every part runs push OFF (0 memory threads) and push ON, for
# uniform AND Zipf keys, so each result has its pull and push side:
#
#   e1  where should a fixed cache go, inner nodes or leaves?      (lookups)
#       total cache x leaf share {0,25,50,75%} x push {off,on} x {uniform,zipf}
#   e2  how should a scan run?                                       (scans)
#       stock pull (one read per leaf) | batched pull, no leaf reuse |
#       batched pull + leaf cache  || push on a miss + leaf cache | push always
#   e3  one choice for every operation, or one per operation?   (50/50 mix)
#       pull all | push lookups only | push scans only | push both
#   e4  the headline: stock CHIME against CHIME-2P, every cache x threads
#       base (inner nodes only, pull) | leaf cache, pull | CHIME-2P with 4/8/16
#       threads; lookups and scans, uniform and Zipf
#   e5  how much skew does a leaf cache need?                (Zipf lookups)
#       theta {0.5,0.8,1.2} (0.99 is in e1) x leaf share {0,50%} x push {off,on}
#
# Same tree, clients and run length everywhere, so every part can be read
# against every other: TREE_SETUP=deep (bulk built, 10 levels, 1.25M inner
# nodes, about 162 MB of them in CHIME's cache), 36 clients, 50M keys, 10M
# warmup + 30M measured ops, scans of 100 keys, hotspot buffer off
# (CHIME_HOTSPOT=0, so the cache budget is exactly inner + leaf).
# The cache budget is ONE total: with the leaf cache on, LEAF_CACHE_PCT of it
# holds leaves and the rest inner nodes. Leaf caching never gets extra memory.
#
# Every cell also counts, with CHIME_LEVEL_STATS=1 (L2_LEVEL_STATS=0 turns it off),
# where the caches answer, as DEX's DEX_LEVEL_STATS does:
#   [LEVEL] level=<l> hits=.. misses=..   per tree level, lookups (level 0 = leaf)
#   [KIND]  inner_hit_pct=.. leaf_hit_pct=..   inner nodes against leaves, lookups
#   [SCANLEAF] leaf_cache_hits=.. leaf_reads=.. inner_complete_miss=..   scans
#
# Needs the CHIME build with CHIME_PUSH_OPS and CHIME_LEVEL_STATS (Tree.cpp) and
# the mixed workloads (CHIME/run/bench_common.sh), on BOTH servers, from ~/REV:
#   git pull --no-rebase --no-edit
#   RUN_ID=chime_build TREE_SETUP=deep ./fair/build.sh chime
#   strings CHIME/build_fair/micro_test | grep -c "CHIME_PUSH_OPS\|CHIME_LEVEL_STATS"   # >= 2
#
# Run (memory first, same variables on both, one terminal each, no tmux):
#   server 8:  cd ~/REV && bash fair/experiments/run_lesson2.sh memory  2>&1 | tee ~/l2_memory.out
#   server 6:  cd ~/REV && bash fair/experiments/run_lesson2.sh compute 2>&1 | tee ~/l2_compute.out
#
# Useful variables (set the SAME on both servers):
#   PARTS="e1 e2 e3"     run only some parts (default: all five)
#   DRY_RUN=1            print the plan and the time estimate, run nothing
#   SKIP_TO=<block>      resume from a block after a failure
#   E4_LEAF_PCT / E4_SCAN_ALWAYS   CHIME-2P's leaf share and scan rule in e4;
#                        set them from e1 and e2 if you run e4 in a second pass
#   L2_TAG=l2smoke       block-name prefix; a smoke test with another tag never
#                        mixes with the real results (the collector reads l2_*)
#
# Results: fair/results/l2_<part>_<arm>/chime/sweep_mt<k>/summary_<role>.csv
# and logs; fair/results/l2_manifest.csv lists every block's settings;
# fair/experiments/collect_lesson2.py merges it all into
# fair/results/lesson2_all.csv.
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${L2_TAG:=l2}"                       # block-name prefix; a smoke test uses another
: "${L2_TREE:=deep}"
: "${PARTS:=e1 e2 e3 e4 e5}"
: "${L2_THREADS:=36}"                    # clients, as in Lesson 1
: "${L2_OPS_M:=30}"
: "${PUSH_MT:=16}"                        # memory server threads when push is on
: "${E1_CACHES:=64 128 256 512 1024}"     # inner nodes ~162 MB: 64/128 never fit
: "${E1_PCTS:=25 50 75}"                  # leaf shares besides 0
: "${E2_CACHES:=32 128 512}"
: "${E3_CACHES:=32 128 512}"
: "${E3_SCAN_PCT:=50}"
: "${E4_CACHES:=16 32 64 128 256 512 1024}"
: "${E4_MEMTHREADS:=4 8 16}"
: "${E4_LEAF_PCT:=50}"
: "${E4_SCAN_ALWAYS:=1}"
: "${E5_CACHES:=64 256}"
: "${E5_THETAS:=0.5 0.8 1.2}"
DISTS="uniform zipf"
T="$L2_TREE"

: "${L2_LEVEL_STATS:=1}"                  # per-level / inner vs leaf hit counts in every cell
COMMON=("THREADS=$L2_THREADS" "OPS_M=$L2_OPS_M" "WARMUP_M=10" "REV_PARK_CMP_DIRS=1"
        "CHIME_HOTSPOT=0" "CHIME_PUSH_OPS=both" "LEAF_CACHE_MB=" "LEAF_ADMIT_SCAN=1.0"
        "CHIME_LEVEL_STATS=$L2_LEVEL_STATS")
wls() { local op=$1 o="" d; for d in $DISTS; do o="$o $op-$d"; done; echo "${o# }"; }

part_on() { [[ " $PARTS " == *" $1 "* ]]; }
MANIFEST=()   # "block,part,arm,leaf_pct,push,push_ops,scan_always,theta,workloads,caches,memthreads"
blk() {       # id part arm leaf_pct push_ops scan_always theta caches memthreads workloads min [VAR=..]
  local id=$1 part=$2 arm=$3 lp=$4 po=$5 sa=$6 th=$7 caches=$8 mts=$9 wl=${10} min=${11}; shift 11
  local leafset=0 leafenv=()
  case "$lp" in
    0)   leafset=0 ;;
    1mb) leafset=1; leafenv=("LEAF_CACHE_MB=1" "LEAF_ADMIT_SCAN=0") ;;   # batched path, nothing kept
    *)   leafset=1; leafenv=("LEAF_CACHE_PCT=$lp") ;;
  esac
  local n; n=$(count_cells "$caches" "$mts" "$wl")
  add_block "$id" chime "$T" "$n" "CACHES=$caches" "MEMTHREADS=$mts" "WORKLOADS=$wl" \
    "${COMMON[@]}" "CHIME_LEAF_SET=$leafset" ${leafenv[@]+"${leafenv[@]}"} \
    "CHIME_PUSH_OPS=$po" "CHIME_SCAN_OFFLOAD_ALWAYS=$sa" "ZIPF_THETA=$th" "$@" "@min=$min"
  MANIFEST+=("$id,$part,$arm,$lp,$po,$sa,$th,$wl,$caches,$mts")
}

# ---- e1: inner nodes or leaves, for lookups ---------------------------------
if part_on e1; then
  blk ${L2_TAG}_e1_leaf0 e1 "leaf 0%" 0 both 0 0.99 "$E1_CACHES" "0 $PUSH_MT" "$(wls point)" 2.6
  for p in $E1_PCTS; do
    blk "${L2_TAG}_e1_leaf$p" e1 "leaf $p%" "$p" both 0 0.99 "$E1_CACHES" "0 $PUSH_MT" "$(wls point)" 2.6
  done
fi

# ---- e2: how a scan should run ------------------------------------------------
if part_on e2; then
  blk ${L2_TAG}_e2_stock    e2 "pull, one read per leaf"      0   both 0 0.99 "$E2_CACHES" 0          "$(wls range)" 4
  blk ${L2_TAG}_e2_batch    e2 "pull, batched, no leaf reuse" 1mb both 0 0.99 "$E2_CACHES" 0          "$(wls range)" 3.5
  blk ${L2_TAG}_e2_leaf     e2 "pull, batched + leaf cache"   50  both 0 0.99 "$E2_CACHES" 0          "$(wls range)" 3.5
  blk ${L2_TAG}_e2_pushmiss e2 "push on a miss + leaf cache"  50  both 0 0.99 "$E2_CACHES" "$PUSH_MT" "$(wls range)" 3
  blk ${L2_TAG}_e2_pushall  e2 "push every scan"              0   both 1 0.99 "$E2_CACHES" "$PUSH_MT" "$(wls range)" 3
fi

# ---- e3: one choice per operation, 50/50 lookups and scans --------------------
if part_on e3; then
  mx="$(wls mixed)"
  blk ${L2_TAG}_e3_pull    e3 "pull everything"     0 both   0 0.99 "$E3_CACHES" 0          "$mx" 3.5 "MIX_SCAN_PCT=$E3_SCAN_PCT"
  blk ${L2_TAG}_e3_lookups e3 "push lookups only"   0 lookup 0 0.99 "$E3_CACHES" "$PUSH_MT" "$mx" 3.5 "MIX_SCAN_PCT=$E3_SCAN_PCT"
  blk ${L2_TAG}_e3_scans   e3 "push scans only"     0 scan   1 0.99 "$E3_CACHES" "$PUSH_MT" "$mx" 3   "MIX_SCAN_PCT=$E3_SCAN_PCT"
  blk ${L2_TAG}_e3_both    e3 "push both"           0 both   1 0.99 "$E3_CACHES" "$PUSH_MT" "$mx" 3   "MIX_SCAN_PCT=$E3_SCAN_PCT"
fi

# ---- e4: stock CHIME against CHIME-2P, the whole sweep ------------------------
if part_on e4; then
  all="$(wls point) $(wls range)"
  blk ${L2_TAG}_e4_base     e4 "stock CHIME (inner nodes, pull)" 0             both 0               0.99 "$E4_CACHES" 0                "$all" 3
  blk ${L2_TAG}_e4_leafpull e4 "leaf cache, pull"                "$E4_LEAF_PCT" both 0               0.99 "$E4_CACHES" 0                "$all" 3
  blk ${L2_TAG}_e4_2p       e4 "CHIME-2P"                        "$E4_LEAF_PCT" both "$E4_SCAN_ALWAYS" 0.99 "$E4_CACHES" "$E4_MEMTHREADS" "$all" 2.8
fi

# ---- e5: skew a leaf cache needs ------------------------------------------------
if part_on e5; then
  for th in $E5_THETAS; do
    tag="t$(echo "$th" | tr -d .)"
    for p in 0 50; do
      blk "${L2_TAG}_e5_${tag}_leaf$p" e5 "theta $th, leaf $p%" "$p" both 0 "$th" "$E5_CACHES" "0 $PUSH_MT" point-zipf 2.6
    done
  done
fi

apply_skip; show_plan

# The manifest says what every block ran; the collector joins on it.
if [ "$ROLE" = compute ] && [ "${DRY_RUN:-0}" != 1 ]; then
  mf="$FAIR/results/${L2_TAG}_manifest.csv"; mkdir -p "$FAIR/results"
  [ -f "$mf" ] || echo "block,part,arm,leaf_pct,push_ops,scan_always,theta,workloads,caches,memthreads" > "$mf"
  for m in "${MANIFEST[@]}"; do grep -q "^${m%%,*}," "$mf" || echo "$m" >> "$mf"; done
fi

[ "${DRY_RUN:-0}" = 1 ] && { run_plan; exit 0; }

# compute node: NIC sampler + time-stamped console copy (as in run_dxt_sweep.sh)
if [ "$ROLE" = compute ]; then
  NIC_DIR="$FAIR/results/nic"; mkdir -p "$NIC_DIR"
  STAMP="l2_$(date +%Y%m%d_%H%M%S)"
  NIC_CSV="$NIC_DIR/${STAMP}_nic.csv"; export TSLOG="$NIC_DIR/${STAMP}_ts.log"
  bash "$EXP_DIR/nic_sampler.sh" "$NIC_CSV" 0.5 & SAMPLER=$!
  trap 'kill $SAMPLER 2>/dev/null' EXIT
fi

run_plan
if [ "$ROLE" = compute ]; then
  python3 "$EXP_DIR/collect_lesson2.py" || true
  echo "== merged: fair/results/lesson2_all.csv"
fi
