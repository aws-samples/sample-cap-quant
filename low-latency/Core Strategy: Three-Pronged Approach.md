# Core Strategy: Three-Pronged Approach

## 1. Accessing External Matching Engines
### Identifying Exchange Endpoints

- Cryptocurrency Trading Endpoints (Priority Order):

    - Futures Liquidity Provider Programs: fapi-mm.binxxxx.com | wss://fstream-mm.binxxxx.com
    - Futures Trading (USDT-M): fapi.binxxxx.com | wss://fstream.binxxxx.com
    - Futures Trading (COIN-M): dapi.binxxxx.com | wss://dstream.binxxxx.com
    - Spot Trading: api.binxxxx.com | api1-4.binxxxx.com | api-gcp.binxxxx.com

- Endpoint Discovery Process: When you don't have terminal access, use mobile tools:

    - Tool: https://mxtoolbox.com/SuperTool.aspx
    - Perform DNS lookups to identify IP addresses
    - Perform Reverse Lookups to identify the exact Availability Zone
    - Critical: AZ name-to-ID mapping differs across AWS accounts, so verify using EC2 → Settings or RAM homepage

### "EC2 Hunting" Methodology

**This is a systematic approach to finding optimal instance placement:**

- Step 1: Narrow Down Location

    - Identify specific Region and Availability Zone where the exchange endpoint resides
    - Use DNS/reverse lookup tools to pinpoint the exact location

- Step 2: Deploy Test Infrastructure

    - Launch instances across spread/partition placement groups to scatter them across different racks
    - Deploy different EC2 instance types to prevent clustering within a single data center
    - This ensures you're testing from various physical locations within the AZ

- Step 3: Comprehensive Testing

    - Test connectivity from a broad set of EC2 instances
    - Use TCP ping + application-level ping for benchmarking
    - Measure latency from each instance to the target endpoint
    - Capture extensive data for offline analysis (histograms, percentiles)

- Step 4: Selection Strategy

    - Keep only the instances with the best performance
    - Consider spinning up many instances, measuring all, then terminating all except the fastest

### Cluster Placement Groups (CPGs)

- Standard CPGs:

    - Essential for lowest latency within your own infrastructure
    - Places instances in close physical proximity within a single AZ
    - Provides single-digit microsecond latency between instances

- Shared CPGs (Advanced):

    - Allows cross-account connectivity with exchanges
    - Requires NDA discussions with the exchange
    - Provides the absolute lowest latency to exchange matching engines
    - Not all exchanges offer this, but it's worth requesting

- Alternative: PrivateLink

    - Some exchanges offer PrivateLink connectivity
    - Trade-off: Adds Network Load Balancer (NLB) overhead
    - Slower than shared CPGs but still better than public internet
    - Easier to set up than shared CPGs

### Connectivity Performance Hierarchy

- Fastest to Slowest:

    - Shared CPG (cross-account, same physical rack)
    - Public IP in same AZ (removes NLB from path)
    - PrivateLink (adds NLB overhead)
    - Public internet (variable latency)

## 2. Intra-VPC Optimization
### Single AZ Deployment Strategy

- Core Principle: Static Stability

    - Deploy all hot-path components in **a single Availability Zone**
    - Keep spares and failover instances in the same AZ
    - Send data asynchronously to other AZs only for disaster recovery
    - Avoid cross-AZ traffic in normal operations (adds 1-2ms latency)

- Architecture Separation:

    - Data Plane: Maximize resilience per AZ, minimize complexity
        - Handle all latency-sensitive trading operations
        - Keep simple, fast, and reliable
        - Over-provision for baseline and burst characteristics
    - Control Plane: Handle complexity, can be multi-AZ
        - Configuration management
        - Monitoring and alerting
        - Non-latency-sensitive mutations

### VPC Connectivity Options

- VPC Peering (Recommended):

    - Lowest latency for VPC-to-VPC traffic
    - Direct connection without intermediate hops
    - Supports high bandwidth with consistent latency
    - Use case: Connecting trading systems across different VPCs

- Transit Gateway (Avoid for Hot Path):

    - Adds latency and jitter
    - Introduces additional network hop
    - Only use for: Control plane traffic or non-latency-sensitive workloads
    - Some customers use TGW for multicast, but this adds significant overhead

- Public IP (Same AZ):

    - Lower latency than PrivateLink
    - Removes NLB from the path
    - Traffic stays within AWS network despite using public IPs
    - Surprising finding: Can be faster than PrivateLink for same-AZ communication

### Removing Middleboxes from Hot Paths

- Load Balancers:

    - Remove all load balancers (ELB, ALB, NLB) from latency-sensitive paths
    - Each load balancer adds latency and introduces jitter
    - Use direct instance-to-instance communication

- Service Discovery Alternatives:

    - Implement distributed consensus mechanisms (e.g., Raft, Paxos)
    - Use client-side intelligence for routing decisions
    - Maintain in-memory caching of service membership
    - Avoid DNS lookups in hot paths; use async lookups if needed
    - Consider service mesh patterns with sidecar proxies (but measure impact)

- Cache Co-location:

    - Co-locate caches "on-box" rather than using ElastiCache
    - Use in-process or shared memory for fastest access
    - Eliminates network round-trip for cache lookups
    - Trade-off: Less cache sharing, but much lower latency

### Inter-Process Communication (IPC) Techniques

- Minimize Number of Boxes:

    - Fewer boxes = fewer network hops
    - Consolidate services on larger instances rather than microservices on small instances

- IPC Methods (Fastest to Slowest):

    - Shared Memory: Fastest, zero-copy communication between processes
    - UNIX Domain Sockets: Very fast, local to single machine
    - Loopback (localhost): Fast, but involves network stack
    - Same-AZ network: Microsecond latency with CPGs
    - Cross-AZ network: Millisecond latency (avoid)

- High Availability Strategy:

    - Run multiple processes on the same large instance
    - Use IPC for communication between components
    - Keep hot standby processes on the same instance or nearby instances in CPG
    - Fail over locally before failing over to another instance

## 3. Inter-Region Connectivity
**Third-Party Network Providers**

- Why Use Third-Party Providers:

    - AWS backbone optimizes for aggregate throughput, not minimum latency
    - Third-party providers offer dedicated low-latency routes
    - Particularly beneficial for specific region pairs (APAC-Europe, APAC-US)

- Major Providers:

    - McKay Brothers: Specializes in ultra-low-latency routes
    - BSO (BT Radianz): Global financial network
    - Avelacom: Low-latency connectivity for trading
    - Equinix
    - Colts
    - Megaport

- How It Works:

    - Provision Direct Connect (DX) in each region
    - Third-party provider carries traffic between DX locations
    - You control routing to prefer third-party paths

**Direct Connect Setup and Architecture**

- Optimal Routing Architecture:

- Best Practice:

    - Direct VIF (Virtual Interface) association to DX Gateways or Virtual Private Gateways
    - Minimize hops from VPC to Direct Connect location
    - Avoid routing through Transit Gateway or inspection VPCs

- Latency Considerations:

    - Region-to-DX latency: Distance from your VPC to the DX location
    - DX-to-DX latency: Third-party provider's network performance
    - Total latency = Region-to-DX + DX-to-DX + DX-to-Region

- Strategy: Multiple Connections

    - Provision multiple DX connections with different providers
    - Measure latency on each path
    - Arbitrage latency by routing traffic over the fastest path
    - Use BGP routing policies to prefer lower-latency paths

- Architecture Patterns:

    - Single-Region to Single-Region:

    ```txt
    VPC → VGW → DX → Third-Party Network → DX → VGW → VPC
    ```

    - Multi-Region Hub:
    ```txt
    VPC → DX Gateway → Multiple DX Connections → Third-Party Providers
    ```
    - Avoid:
    ```txt
    VPC → TGW → DX Gateway → DX (adds TGW hop)
    VPC → Inspection VPC → DX (adds inspection overhead)
    ```

**Latency Optimization Checklist for Inter-Region**

- Planning Phase:

    - Identify required region pairs
    - Measure baseline AWS backbone latency
    - Contact third-party providers for quotes and latency estimates
    - Calculate total latency including DX location distances

- Implementation Phase:

    - Provision DX in each region (prefer locations closest to your VPCs)
    - Set up VIFs with direct association (avoid TGW)
    - Configure BGP with latency-based routing
    - Implement monitoring for path latency

- Optimization Phase:

    - Measure actual latency on all paths
    - Adjust BGP preferences based on measurements
    - Consider multiple providers for redundancy and latency arbitrage
    - Monitor for path changes and re-optimize

- Real-World Performance Expectations

    - Typical Latencies:

        - Same AZ (CPG): 10-50μs round-trip
        - Cross-AZ (same region): 1-2ms round-trip
        - Cross-region (AWS backbone): 20-100ms depending on distance
        - Cross-region (third-party): 10-50% improvement over AWS backbone
