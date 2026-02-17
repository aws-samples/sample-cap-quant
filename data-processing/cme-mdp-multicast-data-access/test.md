# Connectivity Verification
## Test Objective
The connectivity test validates end-to-end multicast data transmission across the complete path: multicast sender → cvr-onprem → cvr-cloud → TGW Multicast Domain → multicast receiver. This verification is accomplished by deploying multicast transmission and reception scripts on the sender and receiver instances respectively.
## Test Execution
On the multicast receiver instance:
```sh
git clone https://github.com/aws-samples/sample-cap-quant.git
cd sample-cap-quant/data-processing/cme-mdp-multicast-data-access/scripts/
chmod +x test-receiver.py
python3 test-receiver.py
```
On the multicast sender instance:
```sh
git clone https://github.com/aws-samples/sample-cap-quant.git
cd sample-cap-quant/data-processing/cme-mdp-multicast-data-access/scripts/
chmod +x test-sender.py
python3 test-sender.py
```

# TGW Multicast Transfer Mode Test
## Test Scope and Rationale
According to AWS Transit Gateway service quotas ,
Key Service Limits:
  - Attachments per transit gateway: 5,000 (default)
  - Bandwidth per VPC attachment per Availability Zone: Up to 100 Gbps
These specifications indicate that a single TGW instance can theoretically support up to 500 Tbps aggregate bandwidth under default configurations. Consequently, the performance bottleneck resides in the EC2 instances serving as senders and receivers rather than the TGW infrastructure itself. Higher throughput requirements necessitate larger EC2 instance specifications. Given the experimental objectives and associated testing costs, this evaluation focuses on validating TGW multicast distribution patterns rather than exhaustive throughput benchmarking.
## Test Scenario Design
Three multicast distribution modes were evaluated to assess TGW's multi-receiver capabilities:
- Mode 1: Single App VPC with 1 multicast receiver
- Mode 2: Single App VPC with 2 multicast receivers
- Mode 3: Two App VPCs, each hosting 1 multicast receiver
These scenarios validate TGW's ability to efficiently distribute multicast traffic across different VPC topologies.

<img width="4120" height="2305" alt="01 mode" src="https://github.com/user-attachments/assets/a49ea024-a106-4aff-af6c-029236ac558f" />


 
## Test Data Specification
The throughput test simulates COMEX gold futures market data at 1,000 records per second. Each record follows the CME MDP data format:
```sh
#>        Date   MsgSeq             SendingTime            TransactTime   Code
#>      <char>    <num>                  <char>                  <char> <char>
#> 1: 20171025 14899367 20171025123000003425726 20171025123000000215181   GCZ7
#> 2: 20171025 14899367 20171025123000003425726 20171025123000000215181   GCZ7
#> 3: 20171025 14899504 20171025123000007263052 20171025123000007035151   GCZ7
#> 4: 20171025 14899504 20171025123000007263052 20171025123000007035151   GCZ7
#> 5: 20171025 14899513 20171025123000008425450 20171025123000008189723   GCZ7
#> 6: 20171025 14899513 20171025123000008425450 20171025123000008189723   GCZ7
#>        Seq     PX   Qty   Ord   agg trade_id     order_id matched_qty
#>      <num>  <num> <num> <num> <num>    <num>       <char>       <num>
#> 1: 5207583 1273.6     1     2     1 15508475 762981983336           1
#> 2: 5207583 1273.6     1     2     1 15508475 762981983304           1
#> 3: 5207611 1273.5     1     2     1 15508484 762981983442           1
#> 4: 5207611 1273.5     1     2     1 15508484 762981983435           1
#> 5: 5207616 1273.6     3     3     1 15508485 762981983447           3
#> 6: 5207616 1273.6     3     3     1 15508485 762981983367           2
```
On each multicast receiver instance:
```sh
cd sample-cap-quant/data-processing/cme-mdp-multicast-data-access/scripts/
chmod +x 1k-receiver.py
python3 1k-receiver.py
```
On the multicast sender instance:
```sh
cd sample-cap-quant/data-processing/cme-mdp-multicast-data-access/scripts/
chmod +x 1k-sender.py
python3 1k-sender.py
```
## TGW Latency Test
On the multicast receiver instance:
```sh
cd sample-cap-quant/data-processing/cme-mdp-multicast-data-access/scripts/
chmod +x latency-receiver.py
python3 latency -receiver.py
```
On the multicast sender instance:
```sh
cd sample-cap-quant/data-processing/cme-mdp-multicast-data-access/scripts/
chmod +x latency-sender.py
python3 latency-sender.py
```
