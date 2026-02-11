# Network Stack Tuning

## Understanding the Latency Problem

- Traditional kernel network stack journey:
```txt
Packet arrives → DMA to ring buffer (5 μs)
→ Hardware IRQ (2 μs)
→ CPU handles interrupt, schedules softirq (3 μs)
→ softirq processes packet (10 μs)
→ Network stack processing (15 μs)
→ Socket buffer copy (8 μs)
→ Application wakes (varies)

TOTAL: 43+ μs per packet (unoptimized)
```

**Our goal: Reduce to sub-20 μs**

## Part 1: ENA Driver Optimization
- Disabling Hardware Offloads

**Generic Receive Offload (GRO) - The Latency Killer**

GRO aggregates multiple small packets into larger ones, introducing 50-200 μs buffering delay:

```sh
# Disable GRO
sudo ethtool -K eth0 gro off

# Verify
ethtool -k eth0 | grep generic-receive-offload
```

**TCP/Generic Segmentation Offload (TSO/GSO)**

These batch packets for efficiency but add latency variance:
```sh
# Disable both
sudo ethtool -K eth0 tso off gso off

# Verify
ethtool -k eth0 | grep -E 'tcp-segmentation-offload|generic-segmentation-offload'
```

Complete offload disabling script:

```sh
#!/bin/bash
# disable-offloads.sh
INTERFACE=${1:-eth0}

echo "Disabling network offloads on $INTERFACE..."

# Disable all receive offloads
sudo ethtool -K $INTERFACE gro off
sudo ethtool -K $INTERFACE lro off
sudo ethtool -K $INTERFACE rx-gro-hw off 2>/dev/null || true

# Disable all transmit offloads
sudo ethtool -K $INTERFACE tso off
sudo ethtool -K $INTERFACE gso off
sudo ethtool -K $INTERFACE ufo off 2>/dev/null || true

# Verify
echo "Current offload settings:"
ethtool -k $INTERFACE | grep -E 'offload|segmentation'
```

Performance impact:

>Before: P99 = 145 μs, P99.9 = 320 μs
>After:  P99 = 68 μs (53% improvement!), P99.9 = 95 μs (70% improvement!)

- Disabling Dynamic Interrupt Moderation (DIM)

DIM automatically adjusts interrupt coalescing, creating unpredictable latency:
```sh
#!/bin/bash
# disable-dim.sh
INTERFACE=${1:-eth0}

# Disable adaptive moderation, set immediate interrupts
sudo ethtool -C $INTERFACE adaptive-rx off rx-usecs 0 tx-usecs 0 adaptive-tx off

# Verify
ethtool -c $INTERFACE
```

Performance impact:

>With DIM:    P99 = 180 μs, P99.9 = 650 μs (high variance)
>Without DIM: P99 = 62 μs (66% improvement!), P99.9 = 88 μs (86% improvement!)

- Ring Buffer Sizing

Optimal sizing balances latency vs. burst handling:
```sh
# For low latency: keep RX ring small
sudo ethtool -G eth0 rx 256 tx 512

# Verify
ethtool -g eth0
```

Sizing recommendations:

    - 256 (recommended): Good latency (P99: 58 μs), handles moderate bursts
    - 512: Acceptable latency (P99: 65 μs), handles large bursts
    - 4096 (default): High latency (P99: 145 μs) - avoid for trading

## Part 2: AF_XDP Zero-Copy Support

The Game Changer

>Traditional socket: 2 memory copies, ~43 μs 
>AF_XDP: Zero copies via DMA, ~18 μs (58% reduction!)

Requirements
```sh
# 1. Kernel 5.10+ (Amazon Linux 2023 or Ubuntu 22.04+)
uname -r

# 2. ENA driver 2.13.0+
ethtool -i eth0 | grep version

# 3. Install libraries
sudo yum install libbpf-devel libxdp-devel  # Amazon Linux
sudo apt install libbpf-dev libxdp-dev      # Ubuntu
```

C Implementation Example
```c
// af_xdp_receiver.c - Zero-copy packet receiver
#include <bpf/xsk.h>
#include <bpf/libbpf.h>

#define NUM_FRAMES 4096
#define FRAME_SIZE 2048
#define BATCH_SIZE 64

int setup_xsk_socket(const char *ifname, int queue_id) {
    struct xsk_socket_config xsk_cfg = {
        .rx_size = 2048,
        .tx_size = 2048,
        .xdp_flags = XDP_FLAGS_DRV_MODE,  // Native mode
        .bind_flags = XDP_ZEROCOPY        // Zero-copy mode
    };

    // Allocate UMEM (shared memory region)
    void *umem_area;
    posix_memalign(&umem_area, getpagesize(), NUM_FRAMES * FRAME_SIZE);

    struct xsk_umem *umem;
    struct xsk_ring_prod fq;  // Fill queue
    struct xsk_ring_cons cq;  // Completion queue

    xsk_umem__create(&umem, umem_area, NUM_FRAMES * FRAME_SIZE,
                     &fq, &cq, &umem_cfg);

    // Create XDP socket
    struct xsk_socket *xsk;
    struct xsk_ring_cons rx;
    struct xsk_ring_prod tx;

    xsk_socket__create(&xsk, ifname, queue_id, umem, &rx, &tx, &xsk_cfg);

    return 0;
}

// Fast receive loop - zero-copy!
void receive_packets(struct xsk_socket *xsk, struct xsk_ring_cons *rx) {
    __u32 idx_rx = 0;
    int rcvd;

    while (1) {
        rcvd = xsk_ring_cons__peek(rx, BATCH_SIZE, &idx_rx);

        if (rcvd == 0) continue;

        for (int i = 0; i < rcvd; i++) {
            __u64 addr = xsk_ring_cons__rx_desc(rx, idx_rx)->addr;
            __u32 len = xsk_ring_cons__rx_desc(rx, idx_rx++)->len;

            // Packet data directly accessible (no copy!)
            uint8_t *pkt = xsk_umem__get_data(umem_area, addr);

            // YOUR TRADING LOGIC HERE
            process_market_data(pkt, len);
        }

        xsk_ring_cons__release(rx, rcvd);
    }
}
```

AF_XDP with Aeron (Recommended)

Aeron provides higher-level abstractions:
```sh
# Build Aeron with AF_XDP support
git clone https://github.com/real-logic/aeron.git
cd aeron
./gradlew clean build -x test

# Configure
cat > aeron.properties << EOF
aeron.use.af.xdp=true
aeron.af.xdp.interface=eth0
aeron.af.xdp.zero.copy=true
aeron.threading.mode=DEDICATED
EOF
```
Performance with AF_XDP:

```txt
Benchmark: 100k messages/sec, 288-byte UDP packets

Standard Socket:
  P50:   52 μs
  P99:   118 μs
  P99.9: 285 μs

AF_XDP Zero-Copy:
  P50:   22 μs  ← 58% improvement
  P99:   38 μs  ← 68% improvement
  P99.9: 65 μs  ← 77% improvement
```

## Part 3: Ntuple Flow Steering
Purpose: Direct Specific Traffic to Specific CPU Cores

Requirements: Nitro v5+ instances (c6i, m6i, c7i, m7i, r7i)

```sh
# Check support
ethtool -k eth0 | grep ntuple-filters
```

Configuration

```sh
#!/bin/bash
# setup-flow-steering.sh
INTERFACE=${1:-eth0}

# Enable ntuple
sudo ethtool -K $INTERFACE ntuple on

# Steer exchange traffic (UDP port 9000) to queue 0 (CPU 0)
sudo ethtool -N $INTERFACE flow-type udp4 \
    dst-port 9000 \
    action 0

# Steer market data feed (UDP port 9001) to queue 1
sudo ethtool -N $INTERFACE flow-type udp4 \
    dst-port 9001 \
    action 1

# Steer specific source IP to queue 2
sudo ethtool -N $INTERFACE flow-type tcp4 \
    src-ip [IP_ADDRESS] \
    action 2

# View all rules
sudo ethtool -n $INTERFACE
```

Architecture benefit:
```txt
Without Flow Steering:
  All traffic → Round-robin across cores
  Result: Cache thrashing, unpredictable

With Flow Steering:
  Hot path:    → CPU 0 (dedicated)
  Market data: → CPU 1 (dedicated)
  Background:  → CPU 2-15
  Result: Optimized caching, predictable
```

## Part 4: Kernel Tuning
1. Busy Poll Mode

Eliminates interrupt latency by continuous polling:

```sh
#!/bin/bash
# setup-busy-poll.sh

# Enable busy polling globally
echo "50" | sudo tee /proc/sys/net/core/busy_poll
echo "50" | sudo tee /proc/sys/net/core/busy_read

# For persistence
cat | sudo tee -a /etc/sysctl.conf << EOF
net.core.busy_poll = 50
net.core.busy_read = 50
EOF

sudo sysctl -p
```

Fine-tuning:

    - Few sockets (1-10): busy_poll = 50
    - Many sockets (10-100): busy_poll = 100
    - Hundreds of sockets: busy_poll = 200

Application-level:

```c
int sock = socket(AF_INET, SOCK_DGRAM, 0);
int busy_poll_usecs = 50;
setsockopt(sock, SOL_SOCKET, SO_BUSY_POLL,
           &busy_poll_usecs, sizeof(busy_poll_usecs));
```

2. Disable IRQ Balancer

```sh
# Stop and disable
sudo systemctl stop irqbalance
sudo systemctl disable irqbalance

# Manual IRQ affinity
#!/bin/bash
INTERFACE="eth0"
IRQS=$(grep $INTERFACE /proc/interrupts | awk '{print $1}' | sed 's/://')

CPU=0
for IRQ in $IRQS; do
    MASK=$(printf "%x" $((1 << $CPU)))
    echo $MASK | sudo tee /proc/irq/$IRQ/smp_affinity
    echo "IRQ $IRQ → CPU $CPU"
    CPU=$((CPU + 1))
done
```

3. Network Buffer Tuning

```sh
#!/bin/bash
# tune-network-buffers.sh

cat | sudo tee -a /etc/sysctl.conf << EOF
# Network buffer tuning
net.core.rmem_max = 134217728           # 128 MB
net.core.wmem_max = 134217728           # 128 MB
net.core.rmem_default = 16777216        # 16 MB
net.core.wmem_default = 16777216        # 16 MB

# TCP buffer sizes (min, default, max)
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728

# Increase max backlog
net.core.netdev_max_backlog = 10000
net.core.somaxconn = 4096
EOF

sudo sysctl -p
```

4. RSS (Receive Side Scaling)

Hardware-level packet distribution:

```sh
# Check current RSS
ethtool -x eth0

# Set RSS to distribute equally across 4 queues
sudo ethtool -X eth0 equal 4

# Monitor per-queue packets
watch -n 1 'ethtool -S eth0 | grep rx_queue'
```

5. XPS (Transmit Packet Steering)

```sh
#!/bin/bash
# configure-xps.sh
INTERFACE="eth0"
NUM_QUEUES=$(ls -d /sys/class/net/$INTERFACE/queues/tx-* | wc -l)

for ((i=0; i<$NUM_QUEUES; i++)); do
    CPU_MASK=$(printf "%x" $((1 << $i)))
    echo $CPU_MASK | sudo tee /sys/class/net/$INTERFACE/queues/tx-$i/xps_cpus
    echo "TX queue $i → CPU $i"
done
```

## Part 5: CPU Affinity and NUMA Configuration
Understanding NUMA

```txt
c6i.16xlarge (64 vCPUs):
┌─────────────────────────────────────┐
│ NUMA Node 0                         │
│ ├─ CPUs: 0-31                       │
│ ├─ Memory: 64 GB (local)            │
│ └─ PCIe: eth0 (NIC)                 │
├─────────────────────────────────────┤
│ NUMA Node 1                         │
│ ├─ CPUs: 32-63                      │
│ └─ Memory: 64 GB (remote to Node 0) │
└─────────────────────────────────────┘

Local access:  ~85 ns
Remote access: ~140 ns (65% slower!)
```

Identifying NUMA Topology

```sh
# Install numactl
sudo yum install numactl -y

# Show NUMA nodes
numactl --hardware

# Find which NUMA node the NIC is on
INTERFACE="eth0"
PCI_ADDRESS=$(ethtool -i $INTERFACE | grep bus-info | awk '{print $2}')
cat /sys/bus/pci/devices/$PCI_ADDRESS/numa_node
```

CPU Isolation

```sh
# Edit GRUB configuration
sudo vi /etc/default/grub

# Add isolcpus parameter:
GRUB_CMDLINE_LINUX="isolcpus=0-7 nohz_full=0-7 rcu_nocbs=0-7"

# Update GRUB and reboot
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
sudo reboot
```

Pinning Applications

Method 1: taskset

```sh
# Pin to CPU 0
taskset -c 0 ./trading_engine

# Pin to CPUs 0-7
taskset -c 0-7 ./trading_engine
```

Method 2: numactl (NUMA-aware)

```sh
# Run on NUMA node 0, CPUs 0-7
numactl --cpunodebind=0 --membind=0 --physcpubind=0-7 ./trading_engine
```

Complete NUMA-Aware Setup

```sh
#!/bin/bash
# numa-optimized-setup.sh
INTERFACE="eth0"

# Find NIC's NUMA node
NIC_NUMA=$(cat /sys/class/net/$INTERFACE/device/numa_node)
echo "NIC is on NUMA node: $NIC_NUMA"

# Get CPUs for that NUMA node
NUMA_CPUS=$(numactl --hardware | grep "node $NIC_NUMA cpus" | cut -d: -f2)
echo "NUMA node $NIC_NUMA CPUs: $NUMA_CPUS"

# Pin IRQs to NUMA-local CPUs
IRQ_CPU=0
for IRQ in $(grep $INTERFACE /proc/interrupts | awk '{print $1}' | sed 's/://'); do
    echo $((1 << $IRQ_CPU)) | sudo tee /proc/irq/$IRQ/smp_affinity
    IRQ_CPU=$((IRQ_CPU + 1))
done

# Launch app on NUMA-local CPUs
numactl --cpunodebind=$NIC_NUMA --membind=$NIC_NUMA \
    taskset -c $NUMA_CPUS ./trading_engine
```

## Part 6: Production-Ready Complete Setup

```sh
#!/bin/bash
# production-low-latency-setup.sh
set -e

INTERFACE="eth0"
HOT_PATH_CPUS="0-7"

echo "Low Latency Network Stack Configuration"
echo "========================================"

# 1. ENA Driver Optimization
echo -e "
 Configuring ENA driver..."
sudo ethtool -K $INTERFACE gro off lro off tso off gso off
sudo ethtool -C $INTERFACE adaptive-rx off adaptive-tx off rx-usecs 0 tx-usecs 0
sudo ethtool -G $INTERFACE rx 256 tx 512
sudo ethtool -K $INTERFACE ntuple on

# 2. Kernel Network Stack
echo -e "
 Tuning kernel network stack..."
sudo tee /etc/sysctl.d/99-low-latency-network.conf > /dev/null << EOF
net.core.busy_poll = 50
net.core.busy_read = 50
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.netdev_max_backlog = 10000
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
EOF
sudo sysctl -p /etc/sysctl.d/99-low-latency-network.conf

# 3. Disable IRQ Balancer
echo -e "
 Disabling IRQ balancer..."
sudo systemctl stop irqbalance
sudo systemctl disable irqbalance

# 4. Configure IRQ Affinity
echo -e "
 Configuring IRQ affinity..."
CPU=0
for IRQ in $(grep $INTERFACE /proc/interrupts | awk '{print $1}' | sed 's/://'); do
    MASK=$(printf "%x" $((1 << $CPU)))
    echo $MASK | sudo tee /proc/irq/$IRQ/smp_affinity > /dev/null
    echo "  IRQ $IRQ → CPU $CPU"
    CPU=$((CPU + 1))
done

# 5. Processor Configuration
echo -e "
 Optimizing processor settings..."
for cpu in /sys/devices/system/cpu/cpu*/cpuidle/state*/disable; do
    echo 1 | sudo tee $cpu > /dev/null 2>&1 || true
done
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance | sudo tee $cpu > /dev/null 2>&1 || true
done

echo -e "
Configuration Complete!"
```

## Performance Summary

- Baseline (no optimization):

    - P50: 52 μs, P99: 145 μs, P99.9: 320 μs

- After ENA optimization:

    - P50: 48 μs (-8%), P99: 68 μs (-53%), P99.9: 95 μs (-70%)

- After full kernel tuning:

    - P50: 45 μs (-13%), P99: 58 μs (-60%), P99.9: 82 μs (-74%)

- With AF_XDP zero-copy:

    - P50: 22 μs (-58%), P99: 38 μs (-74%), P99.9: 65 μs (-80%)

## Key Takeaways

    - Disable all offloads (GRO, TSO, GSO) for predictable latency
    - Disable DIM to eliminate adaptive buffering
    - Enable busy polling for sub-20μs response
    - Pin IRQs and applications to NUMA-local CPUs
    - Use AF_XDP for ultimate performance (58% latency reduction)
    - Test iteratively - layer optimizations and measure each step
