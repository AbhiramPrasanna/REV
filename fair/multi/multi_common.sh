# ===========================================================================
# fair/multi/multi_common.sh -- shared by run_dex_multi.sh and run_chime_multi.sh:
# several compute and memory processes on the two servers (by default 4 compute
# processes on server 6 and 2 memory processes on server 8).
#
# Every cell is one run of all NCN + NMN processes. One side coordinates
# (it restarts memcached and then writes the key "mcell" = the cell number); the
# other side waits for that key before it starts its processes, so a slow cell
# can never be joined by the other side's next one.
# ===========================================================================
set -uo pipefail
MULTI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MULTI_DIR/../params.sh"

: "${NCN:=4}"          # compute processes (server 6)
: "${NMN:=2}"          # memory processes (server 8)
: "${CN_DSM_GB:=2}"    # memory pool of a compute process: it holds no tree nodes
: "${MN_DSM_GB:=30}"   # memory pool of a memory process: half the tree each
: "${MULTI_WAIT:=1800}"  # seconds to wait for the other side before giving up

T=$((THREADS / NCN))   # client threads per compute process
if [ $((T * NCN)) -ne "$THREADS" ] || [ "$T" -lt 1 ]; then
  echo "THREADS=$THREADS must be a multiple of NCN=$NCN" >&2; exit 1
fi
NODES=$((NCN + NMN))
NCPU=$(nproc)
PHYS=$((NCPU / 2))     # CPU c and c+PHYS are the two hyperthreads of one core (servers 6/8)

memc_set() {   # host port key value
  { exec 3<>"/dev/tcp/$1/$2"; } 2>/dev/null || return 1
  printf 'set %s 0 0 %d\r\n%s\r\n' "$3" "${#4}" "$4" >&3
  IFS= read -r -t 2 _ <&3
  exec 3>&- 3<&-
}

wait_key() {   # host port key want_value what -> wait until key == want
  local host=$1 port=$2 key=$3 want=$4 what=$5 waited=0 v
  while :; do
    v="$(memc_get "$host" "$port" "$key")"
    [ "$v" = "$want" ] && return 0
    sleep 1; waited=$((waited + 1))
    if [ "$waited" -ge "$MULTI_WAIT" ]; then
      echo "gave up waiting for $what ($key='$v', want '$want') after ${waited}s" >&2; return 1
    fi
  done
}

# The cell key carries RUN_ID, the cell number and the coordinating script's start
# time; the waiting side ignores the value it found when it started, so a key left
# by an earlier, aborted run is never taken for this run's cell.
# MULTI_BLOCK (set by run_multi_suite.sh, one name per block): the key also carries the
# block, so the next block's cell 1 can never be taken for a stale key, even when the
# coordinating side starts it before the waiting side looks.
MULTI_EPOCH=$(date +%s)
MULTI_TAG="${RUN_ID}${MULTI_BLOCK:+:$MULTI_BLOCK}"
set_cell() { memc_set "$1" "$2" mcell "${MULTI_TAG}:$3:${MULTI_EPOCH}"; }   # host port cell
MULTI_STALE=""
note_stale_cell() { MULTI_STALE="$(memc_get "$1" "$2" mcell)"; }         # host port
wait_cell() {   # host port cell -> wait until this run's coordinator started cell
  local host=$1 port=$2 cell=$3 waited=0 v
  while :; do
    v="$(memc_get "$host" "$port" mcell)"
    if [[ "$v" == "${MULTI_TAG}:${cell}:"* ]] && { [ -n "${MULTI_BLOCK:-}" ] || [ "$v" != "$MULTI_STALE" ]; }; then
      return 0
    fi
    sleep 1; waited=$((waited + 1))
    if [ "$waited" -ge "$MULTI_WAIT" ]; then
      echo "gave up waiting for the other side to start cell $cell (mcell='$v') after ${waited}s" >&2; return 1
    fi
  done
}

dead_pid() {   # pid -> true if that process has exited (gone or a zombie)
  local st; st=$(ps -o stat= -p "$1" 2>/dev/null)
  [ -z "$st" ] || [[ "$st" == Z* ]]
}

wait_count() {   # host port key min what -> wait until key >= min (a number);
  # gives up at once if one of this side's processes (the caller's pids) has exited
  local host=$1 port=$2 key=$3 min=$4 what=$5 waited=0 v p
  while :; do
    v="$(memc_get "$host" "$port" "$key")"
    [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge "$min" ] && return 0
    for p in ${pids[@]+"${pids[@]}"}; do
      if dead_pid "$p"; then
        echo "a process of this side exited while waiting for $what: see the logs of this cell" >&2; return 1
      fi
    done
    sleep 1; waited=$((waited + 1))
    if [ "$waited" -ge "$MULTI_WAIT" ]; then
      echo "gave up waiting for $what ($key='$v', want >= $min) after ${waited}s" >&2; return 1
    fi
  done
}

# CPUs, servers with PHYS physical cores (CPU c and c+PHYS share core c):
#   compute process c: clients on CPUs c*T .. c*T+T-1 (cores 0..THREADS-1), its
#                      idle directory threads parked on CPU NCPU-1-c
#   memory process m:  directory threads on physical cores PHYS-1-m*K down to
#                      PHYS-m*K-K (K = the cell's directory threads), main on core m
cn_cpu_base() { echo $(($1 * T)); }
cn_dir_cpus() { echo $((NCPU - 1 - $1)); }
mn_dir_cpus() {   # m count
  local m=$1 k=$2 start out="" c
  start=$((PHYS - 1 - m * k))
  for ((c = start; c > start - k; c--)); do out="$out${out:+,}$c"; done
  echo "$out"
}
check_layout() {   # max directory threads per memory process
  local k=$1
  if [ $((NMN * k + NMN)) -gt "$PHYS" ]; then
    echo "NMN=$NMN memory processes x $k directory threads do not fit $PHYS physical cores" >&2; return 1
  fi
  if [ "$THREADS" -gt $((NCPU - NCN)) ]; then
    echo "THREADS=$THREADS clients and $NCN parked CPUs do not fit $NCPU CPUs" >&2; return 1
  fi
}

# hugepages this side needs, in GB, printed at the start (2 MB pages: x 512)
hugepage_note() {   # role per_process_extra_gb
  local need
  if [ "$1" = compute ]; then need=$((NCN * (CN_DSM_GB + $2))); else need=$((NMN * (MN_DSM_GB + $2))); fi
  local have; have=$(awk '/HugePages_Total/{print $2}' /proc/meminfo 2>/dev/null)
  echo "hugepages: this side needs about ${need} GB ($((need * 512)) pages of 2 MB); configured: ${have:-?} pages"
  if [ -n "$have" ] && [ "$have" -lt $((need * 512)) ]; then
    echo "WARNING: too few hugepages. sudo sysctl -w vm.nr_hugepages=$((need * 512 + 2048))" >&2
  fi
}

# Memory-side CPU use of one cell, from the memory processes' periodic
# "AGGREGATE active = A% (of N dir-threads; P% per-thread avg)  msgs=M" lines
# (remote_load.h; time spent serving pushed requests, not spinning on the CQ).
# Only windows that served requests count, and the median of them is taken, so
# the load and ramp windows at either end do not pull it down. One row per cell:
#   mn_load_row csv system tag memthreads log...
# columns: per-thread busy % (mean of the memory processes, then the busiest one),
# the memory processes' medians, and requests served per second (all of them).
MNLOAD_HDR="system,ncn,nmn,memthreads,util_pct_mean,util_pct_max,util_pct_per_mn,msgs_per_s,log_prefix"
mn_load_row() {
  local csv=$1 sys=$2 tag=$3 mt=$4; shift 4
  local f per="" rates="" v
  for f in "$@"; do
    v=$(awk '
      /REMOTE CPU LOAD/ { if (match($0, /[0-9]+s window/)) win = substr($0, RSTART, RLENGTH) + 0 }
      /AGGREGATE active =/ {
        m = $0; sub(/.*msgs=/, "", m); m += 0
        if (m == 0) next
        p = $0; sub(/.*; /, "", p); sub(/%.*/, "", p)
        n++; u[n] = p + 0; r[n] = (win > 0 ? m / win : 0)
      }
      END {
        if (!n) { print "NA NA"; exit }
        for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) {
          if (u[j] < u[i]) { t = u[i]; u[i] = u[j]; u[j] = t }
          if (r[j] < r[i]) { t = r[i]; r[i] = r[j]; r[j] = t } }
        k = int((n + 1) / 2); printf "%.2f %.0f\n", u[k], r[k] }' "$f")
    per="$per ${v% *}"; rates="$rates ${v#* }"
  done
  local mean max tot
  mean=$(echo "$per" | awk '{for (i = 1; i <= NF; i++) if ($i != "NA") { s += $i; n++ } } END {if (n) printf "%.2f", s / n; else print "NA"}')
  max=$(echo "$per" | awk '{for (i = 1; i <= NF; i++) if ($i != "NA" && ($i > m || m == "")) m = $i} END {print (m == "" ? "NA" : m)}')
  tot=$(echo "$rates" | awk '{for (i = 1; i <= NF; i++) if ($i != "NA") { s += $i; n++ } } END {if (n) printf "%.0f", s; else print "NA"}')
  [ -f "$csv" ] && [ "$(head -1 "$csv")" != "$MNLOAD_HDR" ] && mv "$csv" "$csv.old-$(date +%s)"
  [ -f "$csv" ] || echo "$MNLOAD_HDR" > "$csv"
  per="${per# }"
  echo "$sys,$NCN,$NMN,$mt,$mean,$max,${per// /;},$tot,$tag" >> "$csv"
  echo "    -> memory CPU: per-thread busy ${mean}% (busiest memory process ${max}%), ${tot} requests/s"
}

# summed / worst / mean of a number found in several logs
sum_over()  { awk -v p="$1" '$0 ~ p { s += $NF; n++ } END { if (n) printf "%.4f", s; else print "NA" }' "${@:2}"; }
max_p99()   { local f m="" v; for f in "$@"; do
                v=$(awk '/\[ALL OPS\]/{a=1; next} a && /^[[:space:]]*ALL[[:space:]]/{ if (match($0,/p99=[ ]*[0-9.]+/)) { s=substr($0,RSTART,RLENGTH); gsub(/p99=[ ]*/,"",s); print s; exit } }' "$f")
                [ -n "$v" ] && m=$(awk -v a="${m:-0}" -v b="$v" 'BEGIN{print (b>a)?b:a}')
              done; echo "${m:-NA}"; }
