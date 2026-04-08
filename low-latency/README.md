# Core Strategy

## 1. Accessing Crypto Exchange Matching Engines
### Cryptocurrency and the Financial System

- The Role of Cryptocurrency:

    - Has come to play a critically important role in modern financial systems
    - Possesses a mechanism that autonomously builds trust in the transaction process
    - Achieves in a decentralized manner what central financial institutions like central banks and state-owned banks have traditionally provided
      >💡Cryptocurrency is not a replacement for fiat currency, but rather a beneficial complement to it

- Classification of Crypto-Asset Companies:

    - Crypto-asset exchanges
    - Crypto-asset quantitative trading firms
    - Crypto-asset market data providers
      >💡Individual traders exist in large numbers but are not treated as clients in this context since they are not enterprises

- Current State of Cloud Adoption:

    - Nearly all crypto-asset companies build their workloads on the cloud
    - Over 90% of exchange workloads run on AWS
    - Quantitative trading firms and data providers also almost universally use AWS

### Identifying Exchange Endpoints

- Endpoint Discovery Process:

    - First, confirm where the matching engine endpoints are located
    - Using Binance as an example, list the matching engine endpoints actually in use

      | Endpoint | Protocol | Purpose |
      |---|---|---|                                                          
      | api.binance.com | REST / WSS | **Main** |
      | fapi.binance.com | REST / WSS | **Futures** |
      | dapi.binance.com | REST / WSS | Delivery |
      | stream.binance.com | WSS | Streaming |
      >💡The endpoint listed at the top is the most frequently used                 

- Leveraging Lookup Tools:

    - Use DNS Lookup to identify IP addresses
      ```sh
      % dig api.binance.com +short
      ```
    - Perform reverse lookups to obtain the Availability Zone (AZ) where the endpoint is placed
      ```sh
      % dig -x <IP_ADDRESS> +short
      ```
      >💡Even without terminal access, web-based tools can be used to perform the same lookups

### "EC2 Hunting" Methodology

**A systematic approach to finding optimal instance placement:**

- Step 1: Build Test Infrastructure

    - After confirming the location of the matching engine endpoint, create multiple EC2 instances and compare performance
    - Avoid creating only a single instance type, as they are likely to be placed in the same data center
      >💡Creating multiple instance types is recommended

- Step 2: Verify AZ Mapping

    - AZ name-to-ID mapping often differs across AWS accounts
      >💡Use EC2 placement information and RAM to investigate the mapping yourself

- Step 3: Measure Latency and Select

    - Measure communication latency between each instance and the endpoint
    - Use both TCP ping and application-level ping for testing
    - Select the best-performing instance and terminate the rest

### Cluster Placement Groups (CPGs)

- Standard CPGs:

    - A mechanism to reduce communication latency between EC2 instances
    - Placing multiple EC2 instances in the same CPG increases the likelihood of placement within the same physical data center, rack, or server
    - Available within a single AWS account
    - Quantitative trading firms can achieve single-digit microsecond latency by placing trading workloads in the same CPG

- Shared CPGs (Advanced):

    - Available across multiple AWS accounts
    - Enables placing quantitative trading firm EC2 instances and exchange EC2 instances in the same shared CPG
    - Requires the exchange to offer shared CPG availability
    - Requires an NDA (Non-Disclosure Agreement) between parties
      >💡Currently, not many exchanges offer shared CPGs

- Alternative: PrivateLink

    - Many exchanges offer PrivateLink connectivity
    - Higher latency than CPGs, but lower than public internet
    - Easier to set up and deploy than shared CPGs

### Connectivity Performance Hierarchy

- Fastest to Slowest:

    - Shared CPG (cross-account, same physical rack)
    - Public IP in same AZ (removes NLB from path)
    - PrivateLink (NLB overhead added)
    - Public internet (variable latency)

## 2. Intra-VPC Optimization
### Single AZ Deployment Strategy

- Core Principle: Consolidate into a Single AZ

    - All core trading workloads must be deployed in **a single Availability Zone**
    - Peripheral workloads such as disaster recovery (DR) can be placed in other AZs
    - Cross-AZ communication latency is approximately 1-2 milliseconds, so cross-AZ traffic should be avoided as much as possible
      >💡When prioritizing low latency, cross-AZ traffic must always be avoided

- Architecture Separation:

    - Data Plane: Deploy in a single AZ to handle latency-sensitive trading operations
    - Control Plane: Can be deployed in a separate AZ (configuration management, monitoring, alerting, etc.)

### VPC Connectivity Options

- VPC Peering (Recommended):
    - Lowest latency for VPC-to-VPC traffic
    - Direct connection without intermediate hops
    - Trade-off: Management is somewhat more complex

- Transit Gateway (TGW) (Avoid for Hot Path):
    - Adds latency and jitter
    - Suitable for control plane and non-latency-sensitive workloads
    - Easier to manage compared to VPC peering
      >💡Some use cases leverage TGW for multicast

- Public IP (Same AZ):
    - Achieves lower latency than PrivateLink
    - Removes NLB from the path

### Removing Middleboxes from Hot Paths

- Reducing Load Balancers:
    - Remove load balancers (ELB, ALB, NLB) from latency-sensitive paths
    - Design to minimize the number of load balancers wherever possible
      >💡Eliminating middleboxes from high-priority communication paths is critically important for latency reduction

## 3. Inter-Region Connectivity Optimization
### Leveraging Third-Party Network Providers

- Why Use Third-Party Providers:

    - The AWS global network backbone is optimized for throughput (bandwidth capacity)
    - Third-party provider dedicated networks are designed and optimized with latency as the top priority
    - Particularly significant benefits for long-distance international routes such as APAC-Europe and APAC-US

- Major Providers:

    - McKay Brothers
    - BSO
    - Avelacom
    - Equinix
    - Colts
    - Megaport

- Implementation Approach:

    - Building a Direct Connect between AWS and the third-party network is mandatory
    - After Direct Connect setup is complete, routing must be strictly controlled to ensure traffic is correctly directed through the third-party network

### Direct Connect Architecture Design

- Architecture Patterns:

    - Single-Region to Single-Region:
    ```txt
    VPC → VGW → DX → Third-Party Network → DX → VGW → VPC
    ```

    - Multi-Region Hub:
    ```txt
    VPC → DX Gateway → Multiple DX Connections → Third-Party Providers
    ```

    - Patterns to Avoid:
    ```txt
    VPC → TGW → DX Gateway → DX (adds TGW hop)
    VPC → Inspection VPC → DX (adds inspection overhead)
    ```

      >💡When prioritizing low latency, avoid using TGW or Inspection VPCs in the design wherever possible

### Achievable Latency in Practice

- Representative Latency Figures:

    - Same AZ (with CPG): RTT latency 10-50 microseconds
    - Cross-AZ within same region: RTT latency 1-2 milliseconds
    - Cross-region via AWS backbone: 20-100 milliseconds depending on geographic distance
    - With third-party dedicated networks: **10-50% improvement** in inter-region latency

## Summary

- The above covers the overall strategy for achieving low latency on AWS in the crypto-asset space
- In practice, there are many fine-grained considerations to account for
- Optimal strategies vary depending on environment and requirements, necessitating case-by-case validation
