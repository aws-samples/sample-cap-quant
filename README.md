# Capital Market - Quant Trading Engineering - Solution Guidance

## Introduction
Cloud computing platforms have emerged as the foundational paradigm for modern IT infrastructure. With their robust global deployment capabilities and centralized operations management, enterprises can confidently pursue worldwide business expansion while substantially reducing operational costs and achieving streamlined infrastructure management. Aligned with this transformative trend, quant trading firms as well as private equity firms are increasingly migrating their infrastructure to cloud platforms.

This repository consolidates best practices from cloud-native quantitative trading institutions, focusing on building research environments and data processing systems on the AWS platform. It aims to provide valuable references and actionable guidance for industry peers navigating their own cloud transformation journeys.

## Quant Trading Context

<img width="3735" height="2112" alt="1" src="https://github.com/user-attachments/assets/031c7a71-bc5a-48c8-b275-7eadd2fbf2bd" />

**Key Components:**
- **Quant Trading** serves as the primary actor initiating trading activities using algorithmic and quantitative strategies.
- **Market Data Provider** supplies real-time and historical market data to multiple participants through both direct feeds to quant trading firms and distribution channels to broker-dealers.
- **Broker-Dealer** acts as the central intermediary hub, receiving orders from quant trading firms and routing them to exchanges while maintaining connections to market surveillance systems.
- **Exchange** is the marketplace where actual trade execution occurs, receiving orders from broker-dealers and routing completed trades to settlement services.
- **Custody, Clearing & Settlement** handles all post-trade processes including asset custody, trade clearing, and final settlement of transactions.
- **Market Surveillance** monitors market activity for regulatory compliance, market manipulation detection, and trading pattern analysis, overseeing both quant trading activities and broker-dealer operations.

**Workflow:**

**Transaction Flow**
- Quant Trading → Broker-Dealer: Quantitative trading firms generate and submit buy/sell orders and trading instructions to their broker-dealers. This represents the core transactional order flow.
- Broker-Dealer → Exchange: Broker-dealer route client orders to exchanges for matching and execution in the public marketplace. This is the primary execution pathway where trades are actually executed.
- Exchange → Custody, Clearing & Settlement: Once trades are executed on the exchange, the trade details flow to custody, clearing, and settlement services for finalization.
- Broker-Dealer → Custody, Clearing & Settlement: Some trades (particularly OTC transactions) may settle directly through broker relationships, providing an alternative settlement pathway.
- Exchange → Market Surveillance: Trade execution data sent directly to surveillance systems for monitoring

**Information Flow**
- Market Data Provider → Quant Trading: Market data providers supply real-time prices, historical data, and market information to quant trading firms for algorithmic analysis and strategy development.
- Market Surveillance → Quant Trading: Market surveillance monitors quant trading patterns for potential manipulation, spoofing, or regulatory violations, providing oversight and compliance alerts.



## Contents

- Quant Research
  - [Leveraging on GPU](https://github.com/aws-samples/sample-cap-quant/tree/main/quant-research/vit_tr_ray_on_gpu)
  - [Leveraging on Trainium1](https://github.com/aws-samples/sample-cap-quant/tree/main/quant-research/llama3.1_8B_finetune_ray_on_trn1)
- Data Processing
  - [CME MDP Multicast Data Access](https://github.com/aws-samples/sample-cap-quant/tree/main/data-processing/cme-mdp-multicast-data-access)
  - [Cross Region, Cross Account Large Historical Data Sync from Data Vendor ](https://github.com/aws-samples/sample-cap-quant/blob/main/data-processing/tick-data-processing/large-scale-data-sync-across-regions-accounts.md)


# 
*built by Shiyang Wei, Sr. Solutions Architect, AWS*

# Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

# License

This library is licensed under the MIT-0 License. See the [LICENSE](https://github.com/aws-samples/sample-cap-quant/blob/main/LICENSE) file.

