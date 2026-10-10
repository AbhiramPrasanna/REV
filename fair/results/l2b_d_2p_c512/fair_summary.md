# Fair sweep: DEX and CHIME against DART

Results: `/home/apa222/REV/fair/results/l2b_d_2p_c512`. Each cell is throughput / DART's throughput at the same
workload and cache size. Above 1.00 = faster than DART. Memory threads 0 = no
offloading. CHIME+ = the better leaf-cache arm. DART scans return one key, so
scan ratios understate the B+trees.

## DEX

### point-uniform

| memory threads | 512 MB |
|---|---:|
| 16 | - |

Reaches DART first at: not reached

### point-zipf

| memory threads | 512 MB |
|---|---:|
| 16 | - |

Reaches DART first at: not reached

### range-uniform

| memory threads | 512 MB |
|---|---:|
| 16 | - |

Reaches DART first at: not reached

### range-zipf

| memory threads | 512 MB |
|---|---:|
| 16 | - |

Reaches DART first at: not reached

## CHIME+

### point-uniform

| memory threads | 512 MB |
|---|---:|
| 16 | - |

Reaches DART first at: not reached

### point-zipf

| memory threads | 512 MB |
|---|---:|
| 16 | - |

Reaches DART first at: not reached

### range-uniform

| memory threads | 512 MB |
|---|---:|
| 16 | - |

Reaches DART first at: not reached

### range-zipf

| memory threads | 512 MB |
|---|---:|
| 16 | - |

Reaches DART first at: not reached

