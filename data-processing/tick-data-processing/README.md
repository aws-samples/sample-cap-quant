# Large-scale data synchronization across regions and accounts

## Requirements
- The data provider's data is stored in an S3 bucket in its AWS account in the Virginia region. The existing data volume is 100TB.

- You need to copy the S3 bucket data stored in the Virginia region of your data provider's AWS account to your own Singapore region of AWS account.

- The first synchronization involved 100TB of historical data, with approximately 100GB of incremental data to be added daily thereafter.

## Solution Brief

- AWS DataSync can be used to synchronize existing and incremental data.

## Implementatin

- The destination bucket on the metabit side needs to be configured with the following bucket policy:

```json
{
  "Version": "2008-10-17",
  "Statement": [
    {
      "Sid": "DataSyncCreateS3LocationAndTaskAccess",
      "Effect": "Allow",
      "Principal": {
        "AWS": [
          "arn:aws:iam::<metabit-aws-account-id>:role/datasync-role",
          "arn:aws:iam::<metabit-aws-account-id>:user/<specific-cx-iam-user>"
        ]
      },
      "Action": [
        "s3:GetBucketLocation",
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads",
        "s3:AbortMultipartUpload",
        "s3:DeleteObject",
        "s3:GetObject",
        "s3:ListMultipartUploadParts",
        "s3:PutObject",
        "s3:GetObjectTagging",
        "s3:PutObjectTagging"
      ],
      "Resource": [
        "arn:aws:s3:::<destination-bucket>",
        "arn:aws:s3:::<destination-bucket>/*"
      ]
    }
  ]
}
```
- On the cx side, an IAM role named datasync-role needs to be created. The creation process is as follows:

<img width="828" height="566" alt="image" src="https://github.com/user-attachments/assets/47e95946-e473-4b14-b870-52a5ae72ac72" />


<img width="828" height="292" alt="image" src="https://github.com/user-attachments/assets/ee61caf7-fdd9-4aef-ba19-f73d772b4efe" />


<img width="828" height="736" alt="image" src="https://github.com/user-attachments/assets/2bacefe5-a488-4d9f-8f5e-c6f9fb469458" />


<img width="828" height="512" alt="image" src="https://github.com/user-attachments/assets/6088c952-ecbd-472c-a0d4-4cb72b6b583e" />


Inline policy JSON:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "s3:GetBucketLocation",
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads"
      ],
      "Effect": "Allow",
      "Resource": "arn:aws:s3:::<source-bucket>"
    },
    {
      "Action": [
        "s3:AbortMultipartUpload",
        "s3:DeleteObject",
        "s3:GetObject",
        "s3:ListMultipartUploadParts",
        "s3:PutObject",
        "s3:GetObjectTagging",
        "s3:ListBucket",
        "s3:PutObjectTagging"
      ],
      "Effect": "Allow",
      "Resource": "arn:aws:s3:::<source-bucket>/*"
    }
  ]
}
```

- The data provider's source bucket requires a configured policy, and a sample configuration is shown below:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": [
                    "arn:aws:iam::<metabit-aws-account-id>:role/datasync-role",
                    "arn:aws:iam::<metabit-aws-account-id>:user/<specific-cx-iam-user>"
                ]
            },
            "Action": [
                "s3:GetBucketLocation",
                "s3:ListBucket",
                "s3:ListBucketMultipartUploads"
            ],
            "Resource": "arn:aws:s3:::<source-bucket>"
        },
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": [
                    "arn:aws:iam::<metabit-aws-account-id>:role/datasync-role",
                    "arn:aws:iam::<metabit-aws-account-id>:user/<specific-cx-iam-user>"
                ]
            },
            "Action": [
                "s3:AbortMultipartUpload",
                "s3:DeleteObject",
                "s3:GetObject",
                "s3:ListMultipartUploadParts",
                "s3:PutObjectTagging",
                "s3:GetObjectTagging",
                "s3:PutObject"
            ],
            "Resource": "arn:aws:s3:::<source-bucket>/*"
        }
    ]
}
```

- Create a datasync source location on the cx side.

```sh
aws datasync create-location-s3 --s3-bucket-arn arn:aws:s3:::<source-bucket> --s3-storage-class STANDARD --s3-config BucketAccessRoleArn="arn:aws:iam::<cx-aws-account-id>:role/datasync-role" --region us-east-1
```

- Create a data sync task on the cx side.

<img width="828" height="354" alt="image" src="https://github.com/user-attachments/assets/03e364b2-7826-4698-88ac-3e216bb44c1b" />


<img width="828" height="702" alt="image" src="https://github.com/user-attachments/assets/355bc88d-3b7e-4cc2-a1bd-d0f980c4e6bd" />


For the first full data synchronization, the task configuration should be set as follows:


<img width="828" height="590" alt="image" src="https://github.com/user-attachments/assets/5b56acc3-a0ef-4d97-9cb1-da5b56b4cffc" />


For incremental data, datasync provides options for processing incremental data, as well as the period for scheduled synchronization. metabit allows you to select the synchronization period for Daily.


<img width="828" height="726" alt="image" src="https://github.com/user-attachments/assets/57e49ef1-ea10-4e9a-bec6-6a95bdf58205" />


## Transmission speed estimation
- Datasync utilizes network bandwidth up to 10Gbps
- Actual bandwidth is limited by the actual network connectivity between the source and destination, and the influencing factors are as follows:
  - Network latency (vir to sg)
  - File size and number
  - Concurrent transmission status
  - Network congestion
- Estimated transfer time for 100TB of data
  - 1Gbps bandwidth: ~9-11 days
  - 5Gbps bandwidth: ~2-3 days
  - 10Gbps bandwidth: ~1-2 days
- datasync automatically optimizes the transmission.
- suggestion
  - Create multiple tasks in multiple batches (5TB/10TB, depending on the specific transmission execution) to complete the synchronization of existing data.
  - Transmit large amounts of data during off-peak business hours.
  - Data providers consider data compression.
  - Data Validation: Use S3 Inventory and DataSync validation features to ensure data integrity.

## Cost Estimation
- Synchronize existing data (100TB):
  - DataSync: ~$2,000 (100TB × $0.0125/GB)
  - Data transfer: ~$9,000 (100TB × $0.09/GB cross-regional transfer)
  - S3 Storage: ~$2,300/month (100TB × $0.023/GB Singapore)

- Incremental data synchronization (100GB per day):
  - Monthly transfer cost: ~$270 (3TB × $0.09/GB)
  - S3 replication cost: ~$37.5 (3TB × $0.0125/GB)


