#!/bin/bash
# ===========================================================================
# restartMemc.sh -- (re)start the coordination memcached and zero the
# registration counters.
#
# RUN ON THE MEMORY NODE, which IS the memcached host: this starts memcached
# LOCALLY (no ssh) and talks to it through bash /dev/tcp (no `nc`). Modelled on
# dex/script/restartMemc.sh, which is the version proven on this cluster.
#
#   ./restartMemc.sh            # restart + zero the counters
#   ./restartMemc.sh --check    # report what is there, change nothing
#
# Two dependencies this deliberately does NOT have, because both have bitten us:
#   * ssh -- the old CHIME version ssh'd to the address in memcached.conf even
#     when that address is this very machine, which needs passwordless ssh to
#     your own IP and otherwise dies with "Permission denied (publickey)".
#   * nc  -- not reliably present, and its variants differ over whether they
#     close on stdin EOF. /dev/tcp is pure bash.
#
# Keeper::serverEnter does memcached_increment() on serverNum/clientNum, which
# requires the keys to ALREADY EXIST -- hence pre-setting them to "0". A stale
# memcached whose counters were never zeroed hands out the wrong node ids, the
# two nodes build queue pairs against the wrong peers, and the run dies with
# "transport retry counter exceeded" -- which reads as an RDMA fault and is
# nothing of the sort. So failures here are loud and non-zero: callers abort
# instead of hanging at the DSMKeeper barrier.
# ===========================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${MEMC_CONF:-$SCRIPT_DIR/../memcached.conf}"
[ -f "$CONF" ] || { echo "restartMemc: ERROR - no memcached.conf at $CONF" >&2; exit 1; }

ADDR="$(head -1 "$CONF" | tr -d '\r[:space:]')"
PORT="$(awk 'NR==2{print}' "$CONF" | tr -d '\r[:space:]')"
: "${PORT:=11211}"
[ -n "$ADDR" ] || { echo "restartMemc: ERROR - no address on line 1 of $CONF" >&2; exit 1; }

PIDF="${MEMC_PID:-/tmp/memcached-$(id -un).pid}"

# --- memcached over /dev/tcp ------------------------------------------------
memc_set_zero() {   # memc_set_zero <key>
  local key=$1 _reply
  exec 3<>"/dev/tcp/${ADDR}/${PORT}" 2>/dev/null || return 1
  printf 'set %s 0 0 1\r\n0\r\n' "$key" >&3
  IFS= read -r -t 3 _reply <&3        # consume STORED
  exec 3>&- 3<&-
  return 0
}

memc_get() {        # memc_get <key> -> value on stdout ("" if absent/unreachable)
  local key=$1 line val=""
  exec 3<>"/dev/tcp/${ADDR}/${PORT}" 2>/dev/null || return 1
  printf 'get %s\r\nquit\r\n' "$key" >&3
  while IFS= read -r -t 3 line <&3; do
    line="${line%$'\r'}"
    case "$line" in
      VALUE*) IFS= read -r -t 3 val <&3; val="${val%$'\r'}" ;;
      END|ERROR*) break ;;
    esac
  done
  exec 3>&- 3<&-
  printf '%s' "$val"
  return 0
}

if [ "${1:-}" = "--check" ]; then
  echo ">> memcached ${ADDR}:${PORT}"
  if s="$(memc_get serverNum)"; then
    echo "   reachable: serverNum='${s:-<unset>}' clientNum='$(memc_get clientNum)'"
  else
    echo "   NOT reachable"
    exit 1
  fi
  exit 0
fi

echo ">> restarting memcached locally on ${ADDR}:${PORT} (pidfile $PIDF)"

# --- kill any previous instance --------------------------------------------
[ -f "$PIDF" ] && kill "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null
kill "$(cat /tmp/memcached.pid 2>/dev/null)" 2>/dev/null   # legacy shared pidfile
pkill -f "memcached.*-p[ ]*${PORT}" 2>/dev/null
sleep 1

# --- launch a fresh one -----------------------------------------------------
# memcached refuses to run as root unless -u is given; -u is unusable otherwise.
if [ "$(id -u)" = "0" ]; then UOPT="-u root"; else UOPT=""; fi
memcached $UOPT -l "${ADDR}" -p "${PORT}" -c 10000 -d -P "$PIDF"
sleep 1

# --- zero the counters the keeper increments --------------------------------
if ! memc_set_zero serverNum; then
  echo "restartMemc: ERROR - cannot reach memcached at ${ADDR}:${PORT}" >&2
  echo "  Is memcached installed?  Is ${ADDR} an IP of THIS host?" >&2
  echo "  Is something else holding the port:  ss -lntp | grep ${PORT}" >&2
  echo "  A port of your own works too, on BOTH nodes: MEMC_PORT=11311" >&2
  exit 1
fi
memc_set_zero clientNum

# --- prove the reset stuck --------------------------------------------------
check="$(memc_get serverNum)"
if [ "$check" != "0" ]; then
  echo "restartMemc: ERROR - ${ADDR}:${PORT} did not accept the reset" \
       "(serverNum='${check:-<unset>}')." >&2
  echo "  That is a STALE memcached this user could not kill." >&2
  exit 1
fi

echo "restartMemc: memcached up on ${ADDR}:${PORT}, counters zeroed."
exit 0
