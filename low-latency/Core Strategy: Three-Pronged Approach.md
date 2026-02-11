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

