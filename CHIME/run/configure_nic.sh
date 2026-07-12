#!/bin/bash
# ===========================================================================
# configure_nic.sh  --  set CHIME's 4 RDMA macros in include/Rdma.h to match
#                       the NIC this server already uses (the one on 10.30.1.x,
#                       i.e. the same device DART drives with nic_index/ib_port).
#
# RUN THIS ON EACH SERVER (memory node AND compute node) BEFORE building CHIME.
# It discovers, from the live system:
#   NET_DEV_NAME    = the ethernet iface holding the SUBNET ip   (ip -br addr)
#   IB_DEV_NAME_IDX = digit of that iface's IB device mlx5_<X>   (/sys or ibdev2netdev)
# and sets:
#   MLX_PORT = 1 , MLX_GID = 1   (match DART: ib_port=1, RACE dev(_,1,1) => gid 1)
# Overridable:  SUBNET=10.30.1.  PORT=1  GID=1  ./configure_nic.sh
#
# CHIME uses GLOBAL/GRH addressing (is_global=1), so GID must be a valid index;
# on RoCE that's the RoCEv2 GID matching this server's IPv4 -- see the show_gids
# hint printed at the end and override GID=<idx> if a run says "could not get gid".
# ===========================================================================
set -euo pipefail

SUBNET="${SUBNET:-10.30.1.}"
PORT="${PORT:-1}"
GID="${GID:-1}"

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHIME_DIR="$(cd "$RUN_DIR/.." && pwd)"
RDMA_H="$CHIME_DIR/include/Rdma.h"
[[ -f "$RDMA_H" ]] || { echo "ERROR: $RDMA_H not found" >&2; exit 1; }

# 1) netdev holding the subnet IP -----------------------------------------
line="$(ip -o -4 addr show 2>/dev/null | awk -v s="$SUBNET" '$4 ~ s {print; exit}')"
[[ -n "$line" ]] || { echo "ERROR: no interface has an IP in $SUBNET (check 'ip -br addr')" >&2; exit 1; }
NETDEV="$(awk '{print $2}' <<<"$line")"
MYIP="$(awk '{print $4}' <<<"$line" | cut -d/ -f1)"

# 2) IB device bound to that netdev -> its trailing digit ------------------
IBDEV=""
if [[ -d "/sys/class/net/$NETDEV/device/infiniband" ]]; then
  IBDEV="$(ls "/sys/class/net/$NETDEV/device/infiniband" 2>/dev/null | head -1)"
fi
if [[ -z "$IBDEV" ]] && command -v ibdev2netdev >/dev/null 2>&1; then
  IBDEV="$(ibdev2netdev | awk -v d="$NETDEV" '$0 ~ d {print $1; exit}')"
fi
[[ -n "$IBDEV" ]] || { echo "ERROR: could not map $NETDEV to an IB device (try 'ibdev2netdev')" >&2; exit 1; }

# CHIME matches ibv_get_device_name(dev)[5] == IB_DEV_NAME_IDX, i.e. mlx5_<X>[5]
DIGIT="${IBDEV:5:1}"
[[ -n "$DIGIT" ]] || { echo "ERROR: unexpected IB device name '$IBDEV' (expected mlx5_<X>)" >&2; exit 1; }
if [[ "${IBDEV:5}" == ?* && ${#IBDEV} -gt 6 ]]; then
  echo "WARN: '$IBDEV' has a multi-digit index; CHIME keys on a single char ('$DIGIT'). Verify no other mlx5_${DIGIT}* exists." >&2
fi

echo "discovered on $(hostname -s 2>/dev/null || hostname):"
echo "  IP          $MYIP  (subnet $SUBNET)"
echo "  NET_DEV     $NETDEV"
echo "  IB_DEV      $IBDEV   -> IB_DEV_NAME_IDX '$DIGIT'"
echo "  MLX_PORT    $PORT"
echo "  MLX_GID     $GID"

# 3) patch include/Rdma.h (comments preserved) ----------------------------
cp "$RDMA_H" "$RDMA_H.bak.$(date +%s)"
sed -i -E \
  -e "s|(#define[[:space:]]+NET_DEV_NAME[[:space:]]+\")[^\"]*(\".*)|\1${NETDEV}\2|" \
  -e "s|(#define[[:space:]]+IB_DEV_NAME_IDX[[:space:]]+')[^']*('.*)|\1${DIGIT}\2|" \
  -e "s|(#define[[:space:]]+MLX_PORT[[:space:]]+)[0-9]+|\1${PORT}|" \
  -e "s|(#define[[:space:]]+MLX_GID[[:space:]]+)[0-9]+|\1${GID}|" \
  "$RDMA_H"

echo
echo "patched $RDMA_H :"
grep -E "NET_DEV_NAME|IB_DEV_NAME_IDX|MLX_PORT|MLX_GID" "$RDMA_H" | sed 's/^/  /'
echo
echo "Now REBUILD on this server:  cd $CHIME_DIR/build && cmake -DENABLE_OFFLOAD=ON .. && make -j"
echo "(backup saved as $RDMA_H.bak.*)"

# 4) helpful GID hint on RoCE ---------------------------------------------
if command -v show_gids >/dev/null 2>&1; then
  echo
  echo "GID table for $IBDEV (if RoCE, pick the RoCEv2 row whose IPv4 = $MYIP and re-run with GID=<idx>):"
  show_gids 2>/dev/null | grep -E "^${IBDEV}|IPv4|$MYIP" | sed 's/^/  /' || true
fi
