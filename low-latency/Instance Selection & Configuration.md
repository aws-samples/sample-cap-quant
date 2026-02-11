# Instance Selection & Configuration
## Instance Type Recommendations
**Current Generation Workhorses**
- c6i / c6in (Compute Optimized - Intel Ice Lake)

    - Processor: 3rd Gen Intel Xeon Scalable (Ice Lake) 8375C
    - Frequency: 3.5 GHz base / 4.0 GHz all-core turbo
    - Network: c6i up to 50 Gbps, c6in up to 200 Gbps
    - Best for: General purpose low-latency trading, order routing, market data processing
    - Key advantage: Mature availability, deep instance pools across regions

- m6i / m6in (Memory Optimized - Intel Ice Lake)

    - Same processor as c6i but with 4:1 memory-to-vCPU ratio (vs 2:1)
    - Network: m6in up to 200 Gbps
    - Best for: Large order books, complex multi-asset strategies, market data aggregation
    - Use when: Need to maintain extensive in-memory datasets

- m5zn (High-Frequency Memory Optimized)

    - Processor: 2nd Gen Intel Xeon Scalable (Cascade Lake)
    - All-Core Turbo: 4.5 GHz - highest frequency in EC2
    - Network: Up to 100 Gbps
    - Critical advantage: Best single-thread performance
    - Use cases: Order validation, risk checks, real-time pricing engines
    - Trade-off: Older generation, but frequency compensates

- z1d (High-Frequency + Local NVMe Storage)

    - Processor: Intel Xeon Platinum 8151 (Skylake)
    - Frequency: 4.0 GHz sustained
    - Storage: Local NVMe SSD up to 1.8 TB
    - Network: Up to 25 Gbps
    - Real-world success: Coinbase uses z1d in RAFT clusters within CPGs, achieving sub-millisecond latency
    - Use cases: Event sourcing, high-speed logging, market data replay

- x2iezn (Memory + High Frequency)

    - Frequency: 4.5 GHz all-core turbo
    - Memory: Up to 4 TB (highest capacity)
    - Network: Up to 100 Gbps
    - Best for: Global order book aggregation, complex portfolio analytics
    - Trade-off: Most expensive, limited AZ availability

**Latest Generation (7th Gen)**
- c7i / m7i / r7i (Intel Sapphire Rapids)

    - Processor: 4th Gen Intel Xeon Scalable
    - Memory: DDR5 (50% higher bandwidth than DDR4)
    - Network: Up to 200 Gbps with ENA Express
    - Improvements: ~15% IPC improvement, better cache hierarchy, enhanced crypto acceleration
    - When to use: New deployments, memory bandwidth-intensive workloads, future-proofing

- r7iz (High-Frequency + Sapphire Rapids)

    - Latest high-frequency option with DDR5 memory
    - Best for: Combining high single-core performance with memory capacity
    - Recommendation: Test against m5zn for your specific workload

- c7a / m7a / r7a (AMD EPYC Genoa)

    - Processor: AMD EPYC 9R14 (4th Gen)
    - Frequency: Up to 3.7 GHz boost
    - Cache: Large L3 cache (256 MB vs 105 MB Intel)
    - AMD advantages: Better NUMA characteristics, larger cache, often lower cost
    - Intel advantages: Higher single-thread frequencies, simpler NUMA topology
    - Critical: AMD can outperform Intel depending on NUMA characteristics - always benchmark both

## Instance Sizing: Why Bigger is Better

**The "Noisy Neighbor" Problem**
**Small instances share physical hosts:**

- Performance Impact on Shared Instances:
>c6i.4xlarge (half-slot):
>  P50:   45 μs
>  P99:   180 μs  ← High variance from other tenants
>  P99.9: 850 μs  ← Unacceptable spikes
>
>c6i.16xlarge (full-slot):
>  P50:   42 μs
>  P99:   65 μs   ← Consistent
>  P99.9: 95 μs   ← Predictable

**Full-Slot Instance Benefits**

- Instance Slot Hierarchy:

    - Small (.large, .xlarge, .2xlarge): Share physical host
    - Half-slot (.4xlarge, .8xlarge): Share physical host
    - Full-slot (.16xlarge, .32xlarge): Dedicated physical host
    - .metal: Full hardware access, no hypervisor

- Full-slot advantages:

    - No competition from other AWS customers
    - Complete NUMA domain access - full memory bandwidth
    - Dedicated network card - no queue sharing
    - C-state control support (critical for latency)
     -Predictable P99/P99.9 latency

**Metal vs. Full-Slot: The Truth**

Performance difference: Only 1-3 μs

- Choose Full-Slot (.16xlarge, .32xlarge) when:

    - ✅ Consistent low latency achieved
    - ✅ C-state control sufficient (most cases)
    - ✅ Cost optimization matters
    - ✅ Better availability (deeper instance pools)
    - ✅ Easier to provision at scale

- Choose .metal when:

    - ✅ Need P-state control (frequency locking)
    - ✅ Extracting last 1-2 μs matters
    - ✅ Specialized hardware access required
    - ⚠️ Limited availability
    - ⚠️ Higher cost

- Key insight from documentation:

>    ".metal instance types will not materially improve latency outside of having full P-State control... full slot instances also provide single tenancy and tend >to have deeper pools of instance availability."

## Processor Configuration
**P-States (Power States) - Frequency Control**

- Why disable:

    - Frequency transitions cause 10-100 μs latency spikes
    - OS decides transitions, not your critical path needs
    - Creates P99+ variance

- How to disable:
```sh
# Kernel parameters
intel_pstate=disable processor.max_cstate=1 idle=poll

# Set performance governor
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > $cpu
done
```

- Instance support:

    - ✅ .metal: Full P-state control
    - ❌ .16xlarge, .32xlarge: C-state only (no P-state)

**C-States (Idle States) - Sleep Depth Control**

- Wake-up latency impact:

>C-State    Wake Time
>C0 (active):  0 μs
>C1:           1-2 μs
>C3:           10-20 μs
>C6:           50-100 μs

- Performance improvement:

>Without C-state control:
>  P99:  125 μs  ← C-state wake-ups
>
>With C-states disabled:
>  P99:  58 μs   ← Consistent!

- How to disable:
```sh
# Kernel boot parameters
processor.max_cstate=1 idle=poll intel_idle.max_cstate=0

# Runtime disable
for cpu in /sys/devices/system/cpu/cpu*/cpuidle/state*/disable; do
    echo 1 > $cpu
done
```

- Trade-off: 20-40% higher power consumption, but 30-50% P99 latency improvement

**Hyper-Threading (SMT) - Always Disable**

- Why disable:

    - Resource contention - sibling threads share execution units, cache, branch predictor
    - Cache thrashing - other thread evicts your cache lines
    - Latency variance - unpredictable performance

- Performance impact:

>Hyper-Threading ON:
>  P99:  95 μs   ← Cache misses from sibling
>
>Hyper-Threading OFF:
>  P99:  62 μs   ← Predictable

- How to disable (at launch - preferred):

>EC2 Console:
>Advanced details → CPU options → Threads per core: 1

Result: Lose 50% of vCPU count, but gain 15-30% single-thread performance and much better tail latency

**Enhanced Networking Features**
- ENA Express

What it does: Uses AWS Scalable Reliable Datagram (SRD) protocol to spray packets across multiple paths, avoiding congestion

- Performance characteristics:

    - Reduces P99.9 latency by 15-30%
    - Slight increase in P50 latency (1-3 μs)
    - Most beneficial under network congestion

- When to use:

    - ✅ Long-running data distribution (market data feeds)
    - ✅ Applications sensitive to tail latency
    - ❌ Ultra-low-latency hot path (order entry)


>    "I generally recommend customers in your space use ENA Express for long running data distribution processes with it being less relevant for hot path trading >flows that need best per-packet latency."

- AF_XDP (Zero-Copy Packet Processing)

    - Native support in ENA driver 2.13.0+
    - Kernel fast-path with Direct Memory Access (DMA)
    - Eliminates memory copying for network packets
    - Excellent for UDP traffic and multicast solutions

- Ntuple Flow Steering (Nitro v5+)

    - Steer traffic to specific CPU cores
    - Isolate hot-path traffic to dedicated queues
    - Improves CPU utilization and performance

- Instance Selection Decision Tree
```txt
Order Entry/Execution:
├─ Need absolute lowest latency?
│  └─ m5zn.metal or x2iezn.metal (4.5 GHz)
├─ Balance latency + availability?
│  └─ c6i.16xlarge or c7i.16xlarge
└─ Future-proofing?
   └─ c7i.32xlarge or r7iz

Market Data Processing:
├─ High throughput (>100k msg/s)?
│  └─ c6in.32xlarge or c7i.48xlarge (200 Gbps)
├─ Multi-venue aggregation?
│  └─ m6i.32xlarge (memory for order books)
└─ Need local storage?
   └─ z1d.12xlarge (NVMe + 4.0 GHz)

Risk/Analytics:
├─ Large in-memory datasets?
│  └─ x2iezn (4.5 GHz + 4 TB RAM)
├─ Memory bandwidth critical?
│  └─ r7i or r7a (DDR5)
└─ Cost-sensitive?
   └─ m7a.16xlarge (AMD, good value)
```

## Final Recommendations

- Universal best practices:

    - Always use full-slot instances (.16xlarge minimum) for production
    - Disable hyper-threading at launch
    - Disable C-states via kernel parameters
    - Deploy in Cluster Placement Groups
    - Test multiple instance types with your actual code

- Starting point for most customers:

    - General trading: c6i.16xlarge or c7i.16xlarge
    - High frequency needs: m5zn.12xlarge
    - High throughput: c6in.32xlarge
    - Memory intensive: m6i.32xlarge or r7iz.16xlarge

- Avoid common mistakes:

    - ❌ Using small instances for production
    - ❌ Assuming .metal is always better than full-slot
    - ❌ Not disabling hyper-threading
    - ❌ Forgetting to configure C-states
    - ❌ Choosing instance type without benchmarking

