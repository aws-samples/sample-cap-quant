# Large-scale data synchronization across regions and accounts

## Requirements
•	The data provider's data is stored in an S3 bucket in its AWS account in the Virginia region. The existing data volume is 100TB.
•	You need to copy the S3 bucket data stored in the Virginia region of your data provider's AWS account to your own Singapore region of AWS account.
•	The first synchronization involved 100TB of historical data, with approximately 100GB of incremental data to be added daily thereafter.

## Solution Brief
•	AWS DataSync can be used to synchronize existing and incremental data.

## Implementatin

•	The destination bucket on the metabit side needs to be configured with the following bucket policy:
