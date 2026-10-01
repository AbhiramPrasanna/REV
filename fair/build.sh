#!/bin/bash
# ===========================================================================
# fair/build.sh -- build all three systems for the fair sweep. Run on BOTH
# servers (6 and 8) from the same commit: DEX and CHIME bake node geometry into
# the on-wire layout, so the two servers must run identical binaries.
#
#   RUN_ID=fair1 ./fair/build.sh            # builds dex, chime, dart
#   RUN_ID=fair1 ./fair/build.sh dex chime  # only some
#
# DEX   -> dex/build_<inner>_<leaf>_<placement>/newbench (one dir per geometry,
#          from TREE_SETUP in params.sh; dex/build is untouched)
# CHIME -> CHIME/build_fair/micro_test (separate dir; CHIME/build is untouched)
# DART  -> DART/bin/{monitor,compute,memory} built by DART's own build.sh,
#          exactly as shipped (no flags, no source changes).
# ===========================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/params.sh"

targets=("$@"); [ ${#targets[@]} -eq 0 ] && targets=(dex chime dart)

build_dex() {
  local mn_only
  case "$DEX_PLACEMENT" in
    mn_only) mn_only=ON ;;
    both)    mn_only=OFF ;;
    *) echo "DEX_PLACEMENT must be mn_only or both (got '$DEX_PLACEMENT')" >&2; exit 1 ;;
  esac
  echo "== DEX ($TREE_SETUP): inner=${DEX_INNER_PAGE}B leaf=${DEX_LEAF_PAGE}B, placement=$DEX_PLACEMENT, manual pushdown"
  rm -rf "$DEX_BUILD" && mkdir -p "$DEX_BUILD" && cd "$DEX_BUILD"
  cmake -DCMAKE_BUILD_TYPE=Release \
        -DMANUAL_PUSHDOWN=ON \
        -DMN_ONLY_PLACEMENT="$mn_only" \
        -DDEX_INNER_PAGE="$DEX_INNER_PAGE" -DDEX_LEAF_PAGE="$DEX_LEAF_PAGE" ..
  make -j"$(nproc)" newbench
  grep -q -- "-DMANUAL_PUSHDOWN" CMakeFiles/newbench.dir/flags.make
  if [ "$mn_only" = ON ]; then grep -q -- "-DMN_ONLY_PLACEMENT" CMakeFiles/newbench.dir/flags.make; fi
  # Record what this binary was built for; run_dex.sh refuses a mismatch.
  printf 'inner_page=%s leaf_page=%s placement=%s\n' "$DEX_INNER_PAGE" "$DEX_LEAF_PAGE" "$DEX_PLACEMENT" > build_stamp.txt
  echo "   ok: $DEX_BUILD/newbench"
}

build_chime() {
  echo "== CHIME: inner span=${CHIME_INTERNAL_SPAN}, leaf span=16, value=${VALUE_B}B, offload + leaf cache compiled in"
  echo "   (CHIME's NIC macros live in include/Rdma.h; if this server was never set up,"
  echo "    run CHIME/run/configure_nic.sh on it first)"
  rm -rf "$CHIME_BUILD" && mkdir -p "$CHIME_BUILD" && cd "$CHIME_BUILD"
  cmake -DENABLE_OFFLOAD=ON -DCACHE_LEAF_NODE=ON \
        -DCHIME_VALUE_LEN="$VALUE_B" -DCHIME_INTERNAL_SPAN="$CHIME_INTERNAL_SPAN" ..
  make -j"$(nproc)" micro_test
  echo "   ok: $CHIME_BUILD/micro_test"
}

build_dart() {
  echo "== DART: built as shipped (DART/build.sh)"
  if ! grep -q "\"$MEM_IP\"" "$DART_DIR/src/main/compute.cc"; then
    echo "   NOTE: DART/src/main/compute.cc:41 ips[0] is not $MEM_IP (the memory server)." >&2
    echo "         DART dials that address for its shortcut table; set ips[0]=\"$MEM_IP\"" >&2
    echo "         (address configuration only) and re-run this build, or DART cannot start." >&2
  fi
  cd "$DART_DIR" && ./build.sh
  ls -l "$DART_DIR/bin/"{monitor,compute,memory}
}

for t in "${targets[@]}"; do
  case "$t" in
    dex) build_dex ;; chime) build_chime ;; dart) build_dart ;;
    *) echo "unknown target $t (dex|chime|dart)" >&2; exit 1 ;;
  esac
done
echo "== build done: ${targets[*]}"
