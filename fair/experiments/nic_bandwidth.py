#!/usr/bin/env python3
"""Network bandwidth of every cell of a run, from the compute node's NIC counters.

  python3 nic_bandwidth.py <run>_ts.log <run>_nic.csv [out.csv]

<run>_ts.log is the compute node's console output with an epoch time in front of
every line (run_c3_c8.sh writes it); <run>_nic.csv is nic_sampler.sh's output.
For each cell the measured phase is found in the log:
  DEX    "Start collecting the statistic" ... "The time duration = N seconds"
  CHIME  "[RESULT node .] ... elapsed=Xs"   (phase = the X seconds before it)
and the NIC byte counters are interpolated at both ends. With two machines every
byte the compute node sends or receives crosses the one link, so rx is what the
memory node sent (reads, replies) and tx what the compute node sent (requests).
"""
import bisect, csv, re, sys


def load_nic(path):
    t, rx, tx = [], [], []
    for r in csv.DictReader(open(path)):
        t.append(float(r["epoch"])); rx.append(int(r["rx_bytes"])); tx.append(int(r["tx_bytes"]))
    return t, rx, tx


def at(nic, when):
    t, rx, tx = nic
    i = bisect.bisect_left(t, when)
    if i <= 0 or i >= len(t):
        return None
    f = (when - t[i - 1]) / (t[i] - t[i - 1])
    return rx[i - 1] + f * (rx[i] - rx[i - 1]), tx[i - 1] + f * (tx[i] - tx[i - 1])


def main():
    ts_log, nic_csv = sys.argv[1], sys.argv[2]
    out = sys.argv[3] if len(sys.argv) > 3 else nic_csv.replace("_nic.csv", "_bandwidth.csv")
    nic = load_nic(nic_csv)
    rows, block, system, mt, cell, start = [], None, None, None, None, None
    for line in open(ts_log, errors="replace"):
        m = re.match(r"^(\d+\.\d+) (.*)$", line.rstrip("\n"))
        if not m:
            continue
        now, text = float(m.group(1)), m.group(2)
        b = re.match(r"^######## .* block (\S+)\s+\((\w+),", text)
        if b:
            block, system = b.group(1), b.group(2)
            continue
        d = re.match(r"^>>> \[[\d:]+\] \(\d+/\d+\) dex_(\S+)_mt(\d+)_cache(\d+)", text)
        if d:
            cell = dict(workload=d.group(1), memthreads=int(d.group(2)), cache_mb=int(d.group(3)))
            continue
        c = re.match(r"^>>> CHIME fair: memory threads (\d+)", text)
        if c:
            mt = int(c.group(1)); continue
        c = re.match(r"^## OFFLOAD=\S+ .*WORKLOAD=(\S+)", text)
        if c:
            cell = dict(workload=c.group(1), memthreads=mt); continue
        c = re.match(r"^## TOTAL cache=(\d+)MB", text)
        if c and cell is not None:
            cell["cache_mb"] = int(c.group(1)); continue
        if text.startswith("Start collecting the statistic"):
            start = now; continue
        end = None
        e = re.match(r"^The time duration = ([\d.]+) seconds", text)
        if e and start is not None:
            end, begin = now, start
        e = re.match(r"^\[RESULT node \d+\].*elapsed=([\d.]+)s", text)
        if e:
            end, begin = now, now - float(e.group(1))
        if end is None or cell is None:
            continue
        a, z = at(nic, begin), at(nic, end)
        secs = end - begin
        if a and z and secs > 0:
            rx, tx = (z[0] - a[0]) / secs, (z[1] - a[1]) / secs
            rows.append(dict(run=block, system=system, workload=cell.get("workload"),
                             cache_mb=cell.get("cache_mb"), memthreads=cell.get("memthreads"),
                             seconds=round(secs, 2), rx_gbytes_per_s=round(rx / 1e9, 4),
                             tx_gbytes_per_s=round(tx / 1e9, 4), total_gbit_per_s=round((rx + tx) * 8 / 1e9, 3)))
        start = None
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, ["run", "system", "workload", "cache_mb", "memthreads", "seconds",
                               "rx_gbytes_per_s", "tx_gbytes_per_s", "total_gbit_per_s"])
        w.writeheader(); w.writerows(rows)
    print(f"{len(rows)} cells -> {out}")


if __name__ == "__main__":
    main()
