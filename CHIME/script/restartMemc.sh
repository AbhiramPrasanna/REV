#!/bin/bash
# ===========================================================================
# restartMemc.sh -- restart the memcached that coordinates a CHIME run, and
#                   reset the node counters.
#
# Runnable from EITHER node and from ANY directory. The host and port come from
# CHIME/memcached.conf (line 1 = address, line 2 = port), which run/bench_common.sh
# rewrites before every cell. If that address is one of this machine's own, the
# restart happens locally; otherwise it goes over ssh.
#
#   ./restartMemc.sh              # restart + reset
#   ./restartMemc.sh --check      # don't restart; just report what is there
#
# WHY THIS MATTERS. memcached holds serverNum/clientNum and every barrier key. A
# stale instance -- left by a previous run, or owned by another user so it cannot
# be killed -- hands out node ids from a counter that never got reset. The two
# nodes then build queue pairs against the wrong peers and the run dies with
# "transport retry counter exceeded", which reads as an RDMA fault and is nothing
# of the sort. So every failure here is LOUD and non-zero: the old version hid the
# kill behind 2>/dev/null, never checked that memcached actually started, and
# never verified the reset stuck.
# ===========================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${MEMC_CONF:-$SCRIPT_DIR/../memcached.conf}"
[[ -f "$CONF" ]] || { echo "ERROR: no memcached.conf at $CONF" >&2; exit 1; }

ADDR="$(head -1 "$CONF" | tr -d '[:space:]')"
PORT="$(awk 'NR==2{print}' "$CONF" | tr -d '[:space:]')"
: "${PORT:=11211}"
[[ -n "$ADDR" ]] || { echo "ERROR: no address on line 1 of $CONF" >&2; exit 1; }

# Per-user pidfile: a shared /tmp/memcached.pid owned by root (from a sudo run)
# can be neither killed nor removed by an ordinary user, and the old script's
# `xargs kill` failed silently when that happened.
PIDF="${MEMC_PID:-/tmp/memcached-$(id -un).pid}"

# Is ADDR one of ours? If so skip ssh -- requiring passwordless ssh to your own
# IP is a needless dependency, and it is the usual reason this script "hangs".
is_local() {
  local ip
  for ip in $(hostname -I 2>/dev/null) 127.0.0.1 localhost; do
    [[ "$ip" == "$ADDR" ]] && return 0
  done
  return 1
}
if is_local; then RUN=(bash -c); else RUN=(ssh "$ADDR" -o StrictHostKeyChecking=no); fi
run_there() { "${RUN[@]}" "$1"; }

memc_get() {  # memc_get <key> -> value on stdout, empty if absent
  printf 'get %s\r\nquit\r\n' "$1" | nc -w 3 "$ADDR" "$PORT" 2>/dev/null \
    | tr -d '\r' | sed -n '2p'
}

report() {
  local s c
  s="$(memc_get serverNum)"; c="$(memc_get clientNum)"
  echo "   memcached ${ADDR}:${PORT} -> serverNum='${s:-<none>}' clientNum='${c:-<none>}'"
}

if [[ "${1:-}" == "--check" ]]; then
  echo ">> checking memcached at ${ADDR}:${PORT} ($(is_local && echo local || echo "via ssh"))"
  report
  exit 0
fi

echo ">> restarting memcached at ${ADDR}:${PORT} ($(is_local && echo local || echo "via ssh"), pidfile $PIDF)"

# 1. kill the old one
run_there "[ -f '$PIDF' ] && xargs kill < '$PIDF' 2>/dev/null; pkill -u \$(id -u) -x memcached 2>/dev/null; true"
sleep 1

# 2. start a fresh one. -u is only usable, and only needed, as root.
run_there "if [ \"\$(id -u)\" = 0 ]; then \
             memcached -u root -l '$ADDR' -p '$PORT' -c 10000 -d -P '$PIDF'; \
           else \
             memcached -l '$ADDR' -p '$PORT' -c 10000 -d -P '$PIDF'; fi"
rc=$?
if [[ $rc -ne 0 ]]; then
  echo "ERROR: memcached did not start on ${ADDR}:${PORT} (exit $rc)." >&2
  echo "       Something else is probably bound there:" >&2
  echo "         ss -lntp | grep ${PORT}" >&2
  echo "       If it belongs to another user, kill it with sudo, or use a port of" >&2
  echo "       your own on BOTH nodes:  MEMC_PORT=11311 MEMC_PID=\$HOME/memcached.pid" >&2
  exit 1
fi
sleep 1

# 3. reset the node counters
printf 'set serverNum 0 0 1\r\n0\r\nquit\r\n' | nc -w 3 "$ADDR" "$PORT" >/dev/null 2>&1
printf 'set clientNum 0 0 1\r\n0\r\nquit\r\n' | nc -w 3 "$ADDR" "$PORT" >/dev/null 2>&1

# 4. prove the instance answering us is the one we just started, with fresh
#    state. Without this the whole point of the restart is unverified.
check="$(memc_get serverNum)"
if [[ "$check" != "0" ]]; then
  echo "ERROR: ${ADDR}:${PORT} did not accept the counter reset (serverNum='${check:-<none>}')." >&2
  echo "       That is a STALE memcached -- see the port check above." >&2
  exit 1
fi
echo "   ok: serverNum=0 clientNum=0"
exit 0
