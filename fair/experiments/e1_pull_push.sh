#!/bin/bash
# ===========================================================================
# e1: pull only vs push on a miss, at three caches (introduction; challenges 1, 2, 5)
#
# Why: shows each mechanism failing on its own, so tuning pull and push to the
# cache and the cores matters:
#
#   small  8 MB          nothing fits. Pull pays a round trip per uncached level;
#                        push on a miss is near push-only, bounded by memory cores.
#   inner  inner fits    every lookup = cached path + 1 leaf: one read (pull) vs
#                        one request (push). Scans still miss their leaves.
#   whole  tree fits     pull needs no network; push has nothing left to do.
#
#   pull only : memory threads 0 (caching, no offloading)
#   push      : memory threads 2, 4, 6, 8 (each system's own push on a miss)
#   CHIME     : leaf cache off AND on at every cache. Leaf on gets the memory left
#               after the inner nodes (CHIME_LEAF_CACHE_MB = total - inner need);
#               at 8 MB, where nothing fits, the default 50/50 split.
#               Leaf off can never use the "whole" memory: CHIME caches inner
#               nodes only -- that contrast is part of the result.
#   Scans pushed only on a miss, in both trees (CHIME_SCAN_OFFLOAD_ALWAYS=0).
#   Workloads : lookups and 100-key scans, uniform.
#
# Both systems run unchanged. DEX pushes a miss only inside its bottom 4 levels
# (megaLevel); CHIME pushes from wherever its cache stopped.
#
#   server 8:  bash fair/experiments/e1_pull_push.sh memory
#   server 6:  bash fair/experiments/e1_pull_push.sh compute
#   DRY_RUN=1  plan and time estimate only;  SKIP_TO=<block> resumes.
# ===========================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${SYSTEMS_E1:=dex chime}"
: "${TREES:=stress fair}"
: "${E1_MEMTHREADS:=0 2 4 6 8}"
: "${E1_WORKLOADS:=point-uniform range-uniform}"

# ---------------------------------------------------------------------------
# Cache sizes (MB): "small inner whole" per system and tree, plus the inner-node
# need used to size CHIME's leaf cache. From measured trees, ~30% headroom (DEX's
# cache also holds its cooling map and the leaves it admits):
#   DEX   stress  inner 3,846,104 x 512 B slot = 1,969 MB; whole 3,938 MB (stress1)
#   DEX   fair    inner 350 MB, leaves 2,098 MB, whole 2,448 MB (fair3; inner fits
#                 from ~512 MB)
#   CHIME stress  inner 129 MB (403K nodes), whole 1,627 MB (stress0, 7 levels)
#   CHIME fair    same node counts as DEX fair; sizes NOT yet measured here --
#                 read the fair3 CHIME '>> tree:' line and set these before running.
# Every cell prints the tree and the cache split, so a size that turns out too
# small shows up in the log (and as reads per op > 1 at "inner", > 0 at "whole").
# ---------------------------------------------------------------------------
: "${DEX_STRESS_CACHES:=8 2600 5200}"
: "${DEX_FAIR_CACHES:=8 640 3300}"
: "${CHIME_STRESS_CACHES:=8 192 2200}"    ; : "${CHIME_STRESS_INNER_NEED:=161}"
: "${CHIME_FAIR_CACHES:=8 640 3400}"      ; : "${CHIME_FAIR_INNER_NEED:=480}"   # VERIFY from fair3

# A cache that holds the whole tree only helps once the leaves are in it. DEX
# admits a leaf 1 time in 10 (admission 0.1), so with uniform access a 10 M-op
# warmup fills only ~23% of 3.85 M leaves; 200 M ops fill ~99% (stress) and
# ~96% (fair). CHIME admits every leaf it reads (LEAF_ADMIT_* = 1.0): 40 M is enough.
: "${DEX_WHOLE_WARMUP_M:=200}"
: "${CHIME_WHOLE_WARMUP_M:=40}"

labels=(small inner whole)
for sys in $SYSTEMS_E1; do
  for tree in $TREES; do
    key="$(echo "${sys}_${tree}" | tr a-z A-Z)"
    caches_var="${key}_CACHES"; read -ra cs <<< "${!caches_var}"
    for i in 0 1 2; do
      c=${cs[$i]}; lab=${labels[$i]}
      extra=("CACHES=$c" "MEMTHREADS=$E1_MEMTHREADS" "WORKLOADS=$E1_WORKLOADS")
      if [ "$sys" = chime ]; then
        need_var="${key}_INNER_NEED"; need=${!need_var}
        extra+=("CHIME_LEAF_SET=0 1" "CHIME_SCAN_OFFLOAD_ALWAYS=0")
        if [ "$lab" != small ] && [ "$c" -gt "$need" ]; then
          extra+=("LEAF_CACHE_MB=$((c - need))")
        fi
        [ "$lab" = whole ] && extra+=("WARMUP_M=$CHIME_WHOLE_WARMUP_M")
        n=$(( $(count_cells "$c" "$E1_MEMTHREADS" "$E1_WORKLOADS") * 2 ))   # leaf 0 and 1
      else
        [ "$lab" = whole ] && extra+=("WARMUP_M=$DEX_WHOLE_WARMUP_M")
        n=$(count_cells "$c" "$E1_MEMTHREADS" "$E1_WORKLOADS")
      fi
      plan_block "e1_${sys}_${tree}_${lab}" "$sys" "$tree" "$n" "${extra[@]}"
    done
  done
done

apply_skip
show_plan
echo "   NOTE: CHIME fair-tree sizes ($CHIME_FAIR_CACHES, inner need $CHIME_FAIR_INNER_NEED MB) are estimates;"
echo "         set CHIME_FAIR_CACHES / CHIME_FAIR_INNER_NEED from the fair3 '>> tree:' line first."
run_plan
