#!/bin/bash
# nic_sampler.sh <out.csv> [seconds between samples, default 0.5]
# Appends "epoch,rx_bytes,tx_bytes" lines: the sum over every RDMA port on this
# machine of its port_rcv_data / port_xmit_data counters (kept by the NIC in
# 4-byte units, converted to bytes here). Read-only; runs until killed.
# nic_bandwidth.py turns these samples into bytes per second for each cell.
out="${1:?usage: nic_sampler.sh <out.csv> [interval_s]}"
iv="${2:-0.5}"
ports=(/sys/class/infiniband/*/ports/*/counters)
[ -e "${ports[0]}/port_rcv_data" ] || { echo "nic_sampler: no RDMA port counters under /sys/class/infiniband" >&2; exit 1; }
[ -s "$out" ] || echo "epoch,rx_bytes,tx_bytes" > "$out"
while :; do
  rx=0; tx=0
  for p in "${ports[@]}"; do
    r=$(<"$p/port_rcv_data"); t=$(<"$p/port_xmit_data")
    rx=$((rx + r * 4)); tx=$((tx + t * 4))
  done
  echo "$(date +%s.%N),$rx,$tx" >> "$out"
  sleep "$iv"
done
