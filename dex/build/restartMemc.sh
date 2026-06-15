#!/bin/bash
# ===========================================================================
# restartMemc.sh  --  (re)start the coordination memcached and zero the
# registration counters.  Run on NODE 0, which IS the memcached host, so this
# starts memcached LOCALLY (no SSH) and initializes the counters via bash
# /dev/tcp (no `nc` needed).
#
# The keeper does memcached_increment() on serverNum/clientNum, which requires
# those keys to already exist -> we pre-set them to "0".
#
# Exits non-zero if memcached can't be started/reached so callers (run.sh /
# sweep.sh) can abort instead of hanging at the DSMKeeper barrier.
# ===========================================================================
addr=$(head -1 ../memcached.conf | tr -d '\r')
port=$(awk 'NR==2{print}' ../memcached.conf | tr -d '\r')

# memcached refuses to run as root unless -u is given; harmless otherwise.
if [ "$(id -u)" = "0" ]; then UOPT="-u root"; else UOPT=""; fi

# --- kill any previous instance --------------------------------------------
if [ -f /tmp/memcached.pid ]; then
  kill "$(cat /tmp/memcached.pid)" 2>/dev/null
fi
pkill -f "memcached.*-p[ ]*${port}" 2>/dev/null
sleep 1

# --- launch a fresh memcached bound to the coordination IP ------------------
memcached $UOPT -l "${addr}" -p "${port}" -c 10000 -d -P /tmp/memcached.pid
sleep 1

# --- initialize the counters the keeper increments, via /dev/tcp ------------
mem_set_zero() {
  local key=$1
  exec 3<>"/dev/tcp/${addr}/${port}" || return 1
  printf 'set %s 0 0 1\r\n0\r\n' "$key" >&3
  IFS= read -r -t 2 _reply <&3       # consume the STORED reply
  exec 3>&- 3<&-
  return 0
}

if ! mem_set_zero serverNum; then
  echo "restartMemc: ERROR - cannot reach memcached at ${addr}:${port}" >&2
  echo "  (is memcached installed?  is ${addr} this host's IP and reachable?)" >&2
  exit 1
fi
mem_set_zero clientNum

echo "restartMemc: memcached up on ${addr}:${port}, counters zeroed."
