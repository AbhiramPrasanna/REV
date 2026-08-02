#!/bin/bash
# ===========================================================================
# run_dex_cache_sweep.sh  --  DEX-comparable cache sweep on CHIME
#
# Comparable to DEX (which also uses 50M keys):
#   * DEX caches whole pages incl. leaves; CHIME's kIndexCacheSize caches INTERNAL
#     nodes only. With stock leafSpanSize=64 CHIME's internals are ~20MB, so a
#     32-512MB sweep is flat. The build therefore sets (Common.h):
#         leafSpanSize     16   more leaves -> index ~65-95MB, so the sweep straddles it
#         internalSpanSize 16   internal node 319B < leaf 979B, index unchanged
#         simulatedValLen  48   leaf-only inflation -> DEX-scale ~3GB tree
#   * 50M keys, 50M OPS, OFFLOAD off vs on, uniform + zipf-0.99.
#   * cache size AND dir-thread count applied at RUNTIME -> ONE build, no rebuilds.
#
# CALIBRATE FIRST -- the index size depends on the bulk-load fill factor (67MB if
# leaves end up 100% full, 95MB at 70%), and that difference decides whether a
# 64MB point evicts at all. Do one run with a cache far above the index and read
# the truth off the log:
#   CACHE_MB=1024 POINT_OP=1 WORKLOADS=point-uniform SEQUENCE=off ./run_dex_cache_sweep.sh memory
#   -> grep "consumed cache size" = the TRUE index working set.
# Then choose the sweep so the index falls inside it. It is also recorded in the
# index_mb CSV column for every cell.
#
# Run the MEMORY node first, then the COMPUTE node with the SAME args:
#   ./run_dex_cache_sweep.sh memory      # on 10.30.1.7
#   ./run_dex_cache_sweep.sh compute     # on 10.30.1.6
#
# Every knob is overridable, e.g. a faster/smaller run:
#   BULK=60 CACHE_MB="4 8 16 32" WORKLOADS=point-zipf ./run_dex_cache_sweep.sh memory
# ===========================================================================
role="${1:?usage: run_dex_cache_sweep.sh <memory|compute>}"

export BULK="${BULK:-50}"                       # 50M keys (same as DEX)
export WARMUP="${WARMUP:-10}"
export POINT_OP="${POINT_OP:-50}"              # 50M measured ops
export RANGE_OP="${RANGE_OP:-50}"
export ZIPF_THETA="${ZIPF_THETA:-0.99}"
# Cache axis. With leafSpanSize=16 the internal working set is ~84MB, so the
# offload/no-offload crossover sits ~64-128MB; the low end shows the offload win.
export CACHE_MB="${CACHE_MB:-8 16 32 64 128 256 512}"
export WORKLOADS="${WORKLOADS:-point-uniform point-zipf}"
export SEQUENCE="${SEQUENCE:-off on}"
# MN dir threads = DEX's "memory threads" (its offload runs are labelled 4mt).
# This is offload's hard ceiling -- every offloaded lookup costs one MN core-slice,
# whereas a one-sided read costs the MN nothing (the NIC serves it). MUST be the
# same on both machines. Sweep it (1/2/4/8) to separate "offload is slower" from
# "offload is starved of MN cores".
export DIR_THREADS="${DIR_THREADS:-4}"

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bench_common.sh"
run_sequence "$role"
