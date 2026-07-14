#!/bin/bash
# ===========================================================================
# run_dex_cache_sweep.sh  --  DEX-comparable cache sweep on CHIME
#
# Comparable to DEX (which also uses 50M keys, 8B/8B):
#   * DEX caches whole pages incl. leaves; CHIME's kIndexCacheSize caches INTERNAL
#     nodes only. With stock leafSpanSize=64 CHIME's internals are ~20MB, so a
#     32-512MB sweep is flat. So the build sets leafSpanSize=16 (Common.h): more
#     leaves -> ~84MB internal working set -> the 8-512MB index-cache sweep is
#     meaningful, and offload (which serves internal MISSES) wins as cache shrinks.
#   * 50M keys, 50M OPS, OFFLOAD off vs on, uniform + zipf-0.99.
#   * cache size applied at RUNTIME via CHIME_CACHE_MB -> ONE build, no rebuilds.
#   REQUIRES a rebuild after the leafSpanSize=16 change (see build steps).
#
# Run the MEMORY node first, then the COMPUTE node with the SAME args:
#   ./run_dex_cache_sweep.sh memory      # on 10.30.1.8
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

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bench_common.sh"
run_sequence "$role"
