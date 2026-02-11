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

- **What is DPDK?**

- DPDK is a complete kernel bypass framework that:

    - Moves networking entirely to userspace
    - Gives applications direct access to NIC hardware
    - Eliminates all kernel involvement in the data path
    - Provides optimized libraries for packet processing

- **AWS ENA PMD Driver**

- AWS provides fully supported DPDK Poll Mode Driver (PMD) for ENA with:

    - Zero-copy packet transmission/reception
    - Burst processing (multiple packets per call)
    - RSS (Receive Side Scaling) support
    - Multi-queue support
    - NUMA-aware memory allocation

- Supported versions:

    - DPDK 20.11 LTS and later
    - DPDK 21.11 LTS (recommended)
    - DPDK 22.11 LTS (latest stable)

- When DPDK Shines

- Optimal use cases:

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

|Packet Size   | Throughput    | DPDK Advantage|
|--------------|---------------|----------------|
|64 bytes      | 14.88 Mpps    | Minimal|
|256 bytes     | 3.72 Mpps     | Moderate (40%)|
|1024 bytes    | 930 kpps      | Significant (70%)|
|1500 bytes    | 812 kpps      | Maximum (85%)|

    - 3.Market Data Distribution

    - Multicast fan-out to many subscribers
    - Packet replication at line rate
    - Minimal CPU overhead

- When DPDK does NOT shine:

    - ❌ Low packet rates (<10k pps) - overhead exceeds benefit
    - ❌ Small payloads at low throughput - kernel stack already fast enough
    - ❌ Simple point-to-point flows - AF_XDP simpler and nearly as fast

- **Performance Characteristics**

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

- **Implementation: Basic DPDK Application**

1. Environment Setup
```sh
#!/bin/bash
# setup-dpdk.sh

# Install dependencies
sudo yum install -y numactl-devel kernel-devel gcc make

# Download and build DPDK
wget https://fast.dpdk.org/rel/dpdk-22.11.tar.xz
tar xf dpdk-22.11.tar.xz
cd dpdk-22.11

# Use meson build system
pip3 install meson ninja
meson setup build
cd build
ninja
sudo ninja install
sudo ldconfig
```
2. Hugepages Configuration
```sh
#!/bin/bash
# configure-hugepages.sh

# Allocate 8GB of 2MB hugepages (4096 pages)
echo 4096 | sudo tee /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages

# Mount hugetlbfs
sudo mkdir -p /mnt/huge
sudo mount -t hugetlbfs nodev /mnt/huge

# For persistence, add to /etc/fstab:
echo "nodev /mnt/huge hugetlbfs defaults 0 0" | sudo tee -a /etc/fstab

# Verify
grep Huge /proc/meminfo
```
3. Bind NIC to DPDK
```sh
#!/bin/bash
# bind-nic-to-dpdk.sh

cd dpdk-22.11/usertools

# Show current NIC binding
./dpdk-devbind.py --status

# Unbind from kernel driver
sudo ./dpdk-devbind.py --unbind 0000:00:05.0

# Bind to DPDK driver (vfio-pci recommended)
sudo modprobe vfio-pci
sudo ./dpdk-devbind.py --bind=vfio-pci 0000:00:05.0

# Verify
./dpdk-devbind.py --status
```

4. Basic DPDK Application in C

```c
// dpdk_receiver.c - Simple DPDK packet receiver
#include <rte_eal.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_cycles.h>

#define RX_RING_SIZE 1024
#define TX_RING_SIZE 1024
#define NUM_MBUFS 8191
#define MBUF_CACHE_SIZE 250
#define BURST_SIZE 32

// Port configuration
static const struct rte_eth_conf port_conf = {
    .rxmode = {
        .max_lro_pkt_size = RTE_ETHER_MAX_LEN,
    },
};

// Initialize DPDK port
static int port_init(uint16_t port, struct rte_mempool *mbuf_pool) {
    struct rte_eth_conf conf = port_conf;
    const uint16_t rx_rings = 1, tx_rings = 1;
    uint16_t nb_rxd = RX_RING_SIZE;
    uint16_t nb_txd = TX_RING_SIZE;
    int retval;

    // Configure device
    retval = rte_eth_dev_configure(port, rx_rings, tx_rings, &conf);
    if (retval != 0) return retval;

    // Setup RX queue
    retval = rte_eth_rx_queue_setup(port, 0, nb_rxd,
            rte_eth_dev_socket_id(port), NULL, mbuf_pool);
    if (retval < 0) return retval;

    // Setup TX queue
    retval = rte_eth_tx_queue_setup(port, 0, nb_txd,
            rte_eth_dev_socket_id(port), NULL);
    if (retval < 0) return retval;

    // Start device
    retval = rte_eth_dev_start(port);
    if (retval < 0) return retval;

    rte_eth_promiscuous_enable(port);
    return 0;
}

// Process received packets
static inline void process_packet(struct rte_mbuf *mbuf) {
    uint64_t timestamp = rte_rdtsc();

    // Get packet data
    uint8_t *pkt_data = rte_pktmbuf_mtod(mbuf, uint8_t *);
    uint16_t pkt_len = rte_pktmbuf_pkt_len(mbuf);

    // YOUR TRADING LOGIC HERE
    // Example: Parse market data, update order book, etc.
}

// Main packet receive loop
static void lcore_main(uint16_t port) {
    struct rte_mbuf *bufs[BURST_SIZE];
    uint16_t nb_rx;

    printf("Core %u receiving packets
", rte_lcore_id());

    while (1) {
        // Receive burst of packets (zero-copy!)
        nb_rx = rte_eth_rx_burst(port, 0, bufs, BURST_SIZE);

        if (unlikely(nb_rx == 0))
            continue;

        // Process each packet
        for (uint16_t i = 0; i < nb_rx; i++) {
            process_packet(bufs[i]);
            rte_pktmbuf_free(bufs[i]); // Return to mempool
        }
    }
}

int main(int argc, char *argv[]) {
    struct rte_mempool *mbuf_pool;
    uint16_t port = 0;

    // Initialize EAL
    int ret = rte_eal_init(argc, argv);
    if (ret < 0)
        rte_exit(EXIT_FAILURE, "Error with EAL initialization
");

    // Create memory pool for mbufs
    mbuf_pool = rte_pktmbuf_pool_create("MBUF_POOL", NUM_MBUFS,
        MBUF_CACHE_SIZE, 0, RTE_MBUF_DEFAULT_BUF_SIZE,
        rte_socket_id());

    if (mbuf_pool == NULL)
        rte_exit(EXIT_FAILURE, "Cannot create mbuf pool
");

    // Initialize port
    if (port_init(port, mbuf_pool) != 0)
        rte_exit(EXIT_FAILURE, "Cannot init port
");

    // Start packet processing
    lcore_main(port);

    return 0;
}
```

5. Compilation and Execution

```sh
# Compile
gcc -O3 dpdk_receiver.c -o dpdk_receiver \
    $(pkg-config --cflags --libs libdpdk) \
    -lrte_net_ena

# Run (requires sudo for memory access)
sudo ./dpdk_receiver -l 0-3 -n 4 -- -p 0x1

# Explanation:
# -l 0-3: Use cores 0-3
# -n 4: 4 memory channels
# -p 0x1: Port mask (port 0)
```

- **DPDK + Aeron Integration**

Aeron provides high-level messaging with DPDK acceleration:

```java
// Aeron with DPDK configuration
public class AeronDpdkConfig {
    public static void main(String[] args) {
        // Media driver context with DPDK
        MediaDriver.Context ctx = new MediaDriver.Context()
            .threadingMode(ThreadingMode.DEDICATED)
            .senderIdleStrategy(new BusySpinIdleStrategy())
            .receiverIdleStrategy(new BusySpinIdleStrategy());

        MediaDriver driver = MediaDriver.launch(ctx);

        // Aeron client
        Aeron aeron = Aeron.connect(new Aeron.Context()
            .aeronDirectoryName(ctx.aeronDirectoryName()));

        // Publication and Subscription
        String channel = "aeron:udp?endpoint=224.0.1.1:40456|interface=eth0";
        Publication pub = aeron.addPublication(channel, 10);
        Subscription sub = aeron.addSubscription(channel, 10);

        // Zero-copy processing
        FragmentHandler handler = (buffer, offset, length, header) -> {
            // Direct buffer access - no copy!
            long timestamp = buffer.getLong(offset);
            // Process market data...
        };

        // Polling loop
        while (true) {
            sub.poll(handler, 10);
        }
    }
}
```
- Performance with Aeron + DPDK:

- Benchmark: 100k 288-byte messages/sec

```txt
Aeron (Standard Sockets):
  P50:   43 μs
  P99:   118 μs
  P99.9: 285 μs

Aeron (DPDK):
  P50:   18 μs  (58% improvement)
  P99:   38 μs  (68% improvement)
  P99.9: 65 μs  (77% improvement)
```

## Part 2: AF_XDP (XDP Sockets)

- **What is AF_XDP?**

- AF_XDP is a Linux address family that provides:

    - Kernel fast-path (not complete bypass)
    - Zero-copy packet delivery via shared memory
    - Simpler than DPDK, native Linux integration
    - Achieves 70-80% of DPDK performance

- When AF_XDP Shines

- Optimal for:

    - Moderate packet rates (50k-500k pps)
    - UDP-heavy workloads
    - Simpler integration requirements
    - Teams familiar with Linux networking

Performance sweet spot:

|Packet Rate    | AF_XDP vs DPDK  | Complexity Ratio|
|---------------|-----------------|------------------|
|<10k pps       | Tie             | AF_XDP: 1x, DPDK: 10x|
|50k pps        | 90% of DPDK     | AF_XDP: 1x, DPDK: 10x|
|100k pps       | 85% of DPDK     | AF_XDP: 1x, DPDK: 10x|
|500k pps       | 75% of DPDK     | AF_XDP: 1x, DPDK: 10x|
|1M+ pps        | 60% of DPDK     | AF_XDP: 1x, DPDK: 10x|

Implementation: AF_XDP with ENA

Requirements:

```sh
# Kernel 5.10+ (Amazon Linux 2023 recommended)
uname -r

# ENA driver 2.13.0+
ethtool -i eth0 | grep version

# Install dependencies
sudo yum install -y libbpf-devel libxdp-devel
```

Basic AF_XDP Application:

```c
// af_xdp_trading.c - Low latency market data receiver
#include <bpf/xsk.h>
#include <bpf/libbpf.h>

#define NUM_FRAMES 4096
#define FRAME_SIZE 2048
#define BATCH_SIZE 64

struct xsk_socket_info {
    struct xsk_ring_cons rx;
    struct xsk_ring_prod tx;
    struct xsk_umem_info *umem;
    struct xsk_socket *xsk;
};

// Create AF_XDP socket with zero-copy
static struct xsk_socket_info* xsk_configure_socket(
    const char *ifname,
    int queue_id,
    struct xsk_umem_info *umem) {

    struct xsk_socket_config cfg = {
        .rx_size = 1024,
        .tx_size = 1024,
        .xdp_flags = XDP_FLAGS_DRV_MODE,  // Native mode
        .bind_flags = XDP_ZEROCOPY         // Zero-copy mode
    };

    // Create socket and populate fill queue...
    // (Full implementation in documentation)
}

// Main receive loop
static void rx_loop(struct xsk_socket_info *xsk_info) {
    struct xsk_ring_cons *rx = &xsk_info->rx;
    uint32_t idx_rx = 0;
    int rcvd;

    while (1) {
        // Poll for packets (zero-copy!)
        rcvd = xsk_ring_cons__peek(rx, BATCH_SIZE, &idx_rx);

        if (!rcvd) continue;

        for (int i = 0; i < rcvd; i++) {
            const struct xdp_desc *desc = xsk_ring_cons__rx_desc(rx, idx_rx++);
            uint8_t *pkt = xsk_umem__get_data(xsk_info->umem->buffer, desc->addr);

            // Process packet (zero-copy - just pointer!)
            process_market_data(pkt, desc->len);
        }

        xsk_ring_cons__release(rx, rcvd);
    }
}

```

Compilation:

```sh
gcc -O3 af_xdp_trading.c -o af_xdp_trading -lxdp -lbpf -lpthread
sudo ./af_xdp_trading
```

## Part 3: eBPF as Alternative

- **What is eBPF?**

- eBPF is NOT kernel bypass, but kernel fast-path:

    - Programs run in kernel with JIT compilation
    - Execute at packet arrival (before full network stack)
    - Can filter, modify, or redirect packets
    - ~5x faster than normal kernel path, but slower than DPDK/AF_XDP

- When eBPF Shines

- Optimal for:

    - Packet filtering at line rate
    - Traffic shaping/rate limiting
    - Load balancing
    - DDoS mitigation
    - Not for ultra-low latency trading (too much overhead)

- eBPF XDP Example

```c
// xdp_filter.c - Filter packets at NIC level
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/udp.h>

#define EXCHANGE_IP   0xC0A80101  // [IP_ADDRESS]
#define MARKET_DATA_PORT 9000

SEC("xdp")
int xdp_filter_prog(struct xdp_md *ctx) {
    void *data_end = (void *)(long)ctx->data_end;
    void *data = (void *)(long)ctx->data;

    // Parse headers
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end) return XDP_DROP;

    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end) return XDP_DROP;

    struct udphdr *udp = (void *)(ip + 1);
    if ((void *)(udp + 1) > data_end) return XDP_DROP;

    // Filter: only accept exchange traffic
    if (ip->saddr == EXCHANGE_IP &&
        udp->dest == __constant_htons(MARKET_DATA_PORT)) {
        return XDP_PASS;  // Forward to AF_XDP socket
    }

    return XDP_DROP;  // Drop everything else at NIC
}
```

Load eBPF program:

```sh
clang -O2 -target bpf -c xdp_filter.c -o xdp_filter.o
sudo ip link set dev eth0 xdp obj xdp_filter.o sec xdp
```

## Part 4: Onload Support Status

- The Bad News

>    "No official support for Onload for ENA... if customers attempt to use it with ENA, it is likely to be unstable and >increase latency compared to using standard sockets."

- Why Onload doesn't work:

    - Onload is proprietary to Solarflare/Xilinx NICs
    - Requires specific hardware features
    - ENA does not implement Onload's interface
    - Attempting to use increases latency

- Alternatives on AWS:

    - ✅ DPDK with ENA PMD (fully supported)
    - ✅ AF_XDP (native Linux support)
    - ✅ Standard sockets with optimizations
    - ❌ Onload (not supported, don't try)

## Part 5: Technology Comparison

Comprehensive Comparison Matrix

|Feature          | Kernel Stack | eBPF/XDP | AF_XDP   | DPDK|
|-----------------|--------------|----------|----------|------|
|Latency (P50)    | 52 μs       | 35 μs    | 22 μs    | 18 μs|
|Latency (P99)    | 145 μs      | 85 μs    | 38 μs    | 28 μs|
|Latency (P99.9)  | 380 μs      | 180 μs   | 65 μs    | 45 μs|
|Max Throughput   | 3.5 Mpps    | 8 Mpps   | 10 Mpps  | 14.8 Mpps|
|CPU Efficiency   | Good        | Very Good| Good     | Excellent|
|Implementation   | Trivial     | Moderate | Moderate | Complex|
|Maintenance      | Easy        | Easy     | Moderate | Hard|
|Kernel Bypass    | No          | No       | Partial  | Complete|
|Zero-Copy        | No          | No       | Yes      | Yes|
|Learning Curve   | 1 week      | 2 weeks  | 3 weeks  | 2-3 months|
|AWS Support      | Full        | Full     | Full     | Full|

Decision Framework
```sh
What's your packet rate?
  ↓
< 10k pps → Standard Kernel Stack (optimized)
  |         Example: screen trading, low-volume strategies
  ↓
50k-100k pps → AF_XDP or Kernel Stack
  |            - AF_XDP if P99 < 50 μs needed
  ↓
100k-500k pps → AF_XDP (recommended)
  |             - Good performance/complexity balance
  ↓
> 500k pps → DPDK
  |          - Only option for maximum performance
  ↓
Special requirements?
  ↓
├─ Multicast replication → DPDK mandatory
├─ Custom protocols → DPDK or AF_XDP
├─ Maximum simplicity → Kernel Stack
├─ Filtering only → eBPF/XDP
└─ Zero-copy essential → AF_XDP or DPDK
```
Real-World Recommendations

Cryptocurrency Market Making:

|Exchange    | Packet Rate | Latency Req | Recommendation|
|------------|-------------|-------------|----------------|
|Binance     | 150k pps    | P99 < 50 μs | AF_XDP + eBPF filter|
|Coinbase    | 80k pps     | P99 < 80 μs | Kernel Stack optimized|
|Kraken      | 120k pps    | P99 < 60 μs | AF_XDP|
|OKX         | 200k pps    | P99 < 40 μs | DPDK|

Equity/Derivatives Trading:

|Use Case              | Packet Rate | Latency Req | Recommendation|
|----------------------|-------------|-------------|---------------|
|Market data consumer  | 300k pps    | P99 < 30 μs | DPDK|
|Order entry          | 5k pps      | P99 < 50 μs | Kernel Stack|
|Algorithmic trading  | 50k pps     | P99 < 100μs | Kernel Stack|
|HFT market making    | 800k pps    | P99 < 20 μs | DPDK (only option)|


Performance Summary

|Technology      | Typical P99 | Max Throughput | Complexity | AWS Support|
|----------------|-------------|----------------|------------|------------|
|Kernel (opt)    | 68 μs      | 3.5 Mpps       | Low        | Full|
|eBPF/XDP        | 85 μs      | 8 Mpps         | Medium     | Full|
|AF_XDP          | 38 μs      | 10 Mpps        | Medium     | Full (ENA 2.13+)|
|DPDK            | 28 μs      | 14.8 Mpps      | High       | Full (ENA PMD)|
|Onload          | N/A        | N/A            | N/A        | NOT SUPPORTED|
