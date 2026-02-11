# Kernel Bypass Technologies

## Understanding the Latency Problem

Traditional kernel path bottlenecks:

```txt
Hardware NIC → DMA to Ring Buffer (5 μs)
           ↓
     Hardware IRQ (2 μs)
           ↓
   CPU Interrupt Handler (3 μs)
           ↓
     SoftIRQ/NAPI (8 μs)
           ↓
  Network Stack Processing (15 μs)
      - IP routing
      - TCP/UDP protocol
      - Socket buffer management
           ↓
  Copy to User Space (8 μs)
           ↓
  Application Wake-up (varies)

TOTAL: 41+ μs minimum
P99: 150-300 μs (with congestion)
```

The bypass vision:

```txt
Hardware NIC → DMA directly to Application Memory
           ↓
     Poll from userspace (no interrupts!)
           ↓
  Application processes packet

TOTAL: 3-8 μs
P99: 12-25 μs
```

## Part 1: DPDK (Data Plane Development Kit)

What is DPDK?

DPDK is a complete kernel bypass framework that:

    - Moves networking entirely to userspace
    - Gives applications direct access to NIC hardware
    - Eliminates all kernel involvement in the data path
    - Provides optimized libraries for packet processing

AWS ENA PMD Driver

AWS provides fully supported DPDK Poll Mode Driver (PMD) for ENA with:

    - Zero-copy packet transmission/reception
    - Burst processing (multiple packets per call)
    - RSS (Receive Side Scaling) support
    - Multi-queue support
    - NUMA-aware memory allocation

Supported versions:

    - DPDK 20.11 LTS and later
    - DPDK 21.11 LTS (recommended)
    - DPDK 22.11 LTS (latest stable)

When DPDK Shines

Optimal use cases:

    - 1.High Packet Rate (>100k packets/sec)
```txt
Packet Rate vs Latency Benefit:
10k pps:   DPDK gain = ~5% (not worth complexity)
50k pps:   DPDK gain = ~25%
100k pps:  DPDK gain = ~60% ← Sweet spot begins
500k pps:  DPDK gain = ~85%
1M+ pps:   DPDK gain = ~90%
```
    - 2.Large Payloads with Batching
```txt
Packet Size   | Throughput    | DPDK Advantage
-------------------------------------------------
64 bytes      | 14.88 Mpps    | Minimal
256 bytes     | 3.72 Mpps     | Moderate (40%)
1024 bytes    | 930 kpps      | Significant (70%)
1500 bytes    | 812 kpps      | Maximum (85%)
```
    - 3.Market Data Distribution

    - Multicast fan-out to many subscribers
    - Packet replication at line rate
    - Minimal CPU overhead

When DPDK does NOT shine:

    - ❌ Low packet rates (<10k pps) - overhead exceeds benefit
    - ❌ Small payloads at low throughput - kernel stack already fast enough
    - ❌ Simple point-to-point flows - AF_XDP simpler and nearly as fast

Performance Characteristics

Benchmark: 100k msg/s, 288-byte UDP packets, c6in.32xlarge
```txt
Standard Kernel Stack:
  CPU:   35% (one core)
  P50:   52 μs
  P99:   145 μs
  P99.9: 380 μs

DPDK (ENA PMD):
  CPU:   98% (one core) ← Busy polling!
  P50:   18 μs  (65% improvement)
  P99:   28 μs  (81% improvement)
  P99.9: 45 μs  (88% improvement)
```
Throughput on c6in.32xlarge (200 Gbps network):
```txt
Kernel Stack Maximum:
  - 64-byte packets:  ~3.5 Mpps
  - 1500-byte packets: ~450 kpps

DPDK Maximum:
  - 64-byte packets:  ~14.8 Mpps (4.2x faster!)
  - 1500-byte packets: ~812 kpps (1.8x faster)
```

Implementation: Basic DPDK Application

1. Environment Setup

2. Hugepages Configuration
