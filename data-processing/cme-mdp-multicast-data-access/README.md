# CME MDP Multicast Data Access on AWS Experiment
CME MDP data distribution utilizes multicast technology. Current native access method is suitable for on-premise scenarios. Refer to [link](https://cmegroupclientsite.atlassian.net/wiki/spaces/EPICSANDBOX/pages/457217128/CME+Market+Data+Platform+Connectivity) for more details. For financial institutions, trading institutions, data service providers, fintech companies, and research institutions that currently or may potentially build systems on Amazon Web Services, how to access CME MDP data on the platform is a topic worth exploring, and this is the purpose of this asset.

Because the production environment involves access and communication with the CME MDP product side, the reproduction cost is high. Therefore,  an experimental architecture is designed to showcase clearly the solution principles, as shown in the figure below

## Experiment Architecture Diagram
<img width="4120" height="2112" alt="01experiment" src="https://github.com/aws-samples/sample-cap-quant/blob/main/data-processing/cme-mdp-multicast-data-access/architecture-diagram/01experiment.png" />

## Experimental Environment Preparation
### VPC Planning
The experimental environment requires planning two VPCs: Transit VPC and App VPC. The Transit VPC is used to deploy the multicast sender, cvr-onprem, and cvr-cloud. The App VPC is used to deploy the multicast receiver. The Transit VPC requires planning four subnets: subnet1 and subnet2 in one AZ, and subnet3 and subnet4 in another AZ. The rationale is as follows:
- 1. Subnet1 Configuration The ENI (WAN Port) of the multicast sender and the ENI (LAN Port) of cvr-onprem must be in the same subnet, designated as subnet1. Because multicast traffic is Layer 2 broadcast, the sender and cvr-onprem must be in the same subnet to reach each other directly.
- 2. Subnet2 Configuration The other ENI (WAN Port) of cvr-onprem and its ENI (LAN Port) must be in the same AZ but cannot be in the same subnet. Therefore, subnet2 is planned to host the other ENI (WAN Port) of cvr-onprem.
- 3. Subnet3 and Subnet4 Configuration The WAN Port and LAN Port of cvr-cloud similarly need to be in the same AZ but cannot be in the same subnet. To more closely approximate the production environment, cvr-cloud's ENIs are planned in a different AZ from cvr-onprem. The cvr-cloud ENI (WAN Port) is placed in subnet3, and the ENI (LAN Port) in subnet4.
- 4. Subnet5 Configuration The ENI of the Multicast Receiver is planned for deployment in subnet5 of the App VPC. To achieve lower latency, subnet5 is planned to be in the same AZ as subnet3 and subnet4.

Both Transit VPC and App VPC require Internet accessibility because establishing GRE Tunnels and registering Multicast Group sources and members all require the EC2 instances' public IP addresses.

### EC2 Instance Deployment

In the experiment, the multicast sender and multicast receiver utilize the c5.large instance type. The operating system selected is ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-20251015. The multicast sender is deployed in subnet1 of the Transit VPC, while the multicast receiver is deployed in subnet5 of the App VPC.

The two virtual routers (cvr-onprem and cvr-cloud) are deployed in the Transit VPC by subscribing to Cisco Catalyst 8000V on AWS Marketplace. The cvr-onprem is deployed in subnet2, and the cvr-cloud is deployed in subnet3.

To deploy the virtual routers, you need to subscribe to Cisco Catalyst 8000V through the AWS Marketplace.

<img width="468" height="164" alt="image" src="https://github.com/user-attachments/assets/cb8e1a0b-5f3e-4e39-8e37-aa2c99adcc30" />
 
After successful subscription, you can view it in Manage subscriptions. Click the "Launch" button on the right side to proceed with deployment.
 
It is recommended to select Amazon EC2 in the Service option and choose Launch from EC2 Console as the Launch method. It is important to note that both EC2 instances must have Auto-assign public IP enabled.

<img width="468" height="225" alt="image" src="https://github.com/user-attachments/assets/d7df01e8-6330-4441-97be-412529759d7f" />

### Configuration Steps
#### Configuring cvr-cloud
Adding LAN Port ENI to cvr-cloud

Execute the following command from your local machine or a cloud-based bastion host to add a LAN interface to cvr-cloud. If executing locally, ensure that AWS CLI SDK is installed and API keys are configured for operating resources in this account. If executing from the cloud, ensure that the bastion host can access cvr-cloud. Note that the subnet-id in the command below is not the ID of subnet3, but rather the ID of subnet4. The Groups parameter is the security group ID of cvr-cloud.
```sh
aws ec2 create-network-interface \
    --subnet-id subnet-0524c3xxxxxxx \
    --description "LAN port" \
    --groups sg-xxxxxxx
```
After execution, you will receive the following JSON output. Extract the ENI ID from it to use as the network-interface-id parameter input for the subsequent command.
```sh
{
    "NetworkInterface": {
        "AvailabilityZone": "us-west-2c",
        "Description": "LAN port",
        "Groups": [
            {
                "GroupName": "default",
                "GroupId": "sg-xxxxxx"
            }
        ],
        "InterfaceType": "interface",
        "Ipv6Addresses": [],
        "MacAddress": "0a:6a:79:2e:58:47",
        "NetworkInterfaceId": "eni-0edcxxxxxxxx",
        "OwnerId": "xxxxxxxxxxxx",
        "PrivateDnsName": "ip-xx-xx-xx-xx.us-west-2.compute.internal",
        "PrivateIpAddress": "xx.xx.xx.xx",
        "PrivateIpAddresses": [
            {
                "Primary": true,
                "PrivateDnsName": "ip-xx-xx-xx-xx.us-west-2.compute.internal",
                "PrivateIpAddress": "xx.xx.xx.xx"
            }
        ],
        "RequesterId": "AROAxxxxxx:i-00d63xxxxxx",
        "RequesterManaged": false,
        "SourceDestCheck": true,
        "Status": "pending",
        "SubnetId": "subnet-0524xxxxxx",
        "TagSet": [],
        "VpcId": "vpc-7xxxxxx"
    }
}
```

The instance-id is the instance ID corresponding to cvr-cloud, which can be obtained from the EC2 console.
```sh
aws ec2 attach-network-interface \
    --network-interface-id eni-0edcxxxxxxxx \
    --instance-id i-05682xxxxxxxxx \
    --device-index 1
```
Next, you need to execute the following two commands separately to disable SourceDestCheck on both the WAN port and LAN port of cvr-cloud.
```sh
aws ec2 modify-network-interface-attribute --network-interface-id <WAN port ENI id> --no-source-dest-check
aws ec2 modify-network-interface-attribute --network-interface-id <LAN port ENI id> --no-source-dest-check
```
The CLI-based configuration operations from your local machine or cloud bastion host are now complete.
The following operations require logging into cvr-cloud directly.
First, use the following command to log into cvr-cloud:
```sh
ssh -i "<public key>" -o PubkeyAcceptedKeyTypes=+ssh-rsa ec2-user@<cvr-cloud’s IP address>
```
The public key format is xxx.pem.

IP Address Selection:
  - Internet login: Use the EC2's Public DNS with the format ec2-xx-xx-xx-xx.us-west-2.compute.amazonaws.com
  - Internal network login: Use the EC2's private IPv4 address with the format xx.xx.xx.xx

Once logged into cvr-cloud, execute config t to enter configuration mode. The following configuration items need to be configured:
- Configure the GRE tunnel on the WAN port, where A.B.C.D represents the public IP address of cvr-onprem.
```sh
interface tunnel 0
    ip address 169.254.100.2 255.255.255.252
    tunnel source GigabitEthernet1
    tunnel destination A.B.C.D
```

- Enable Multicast Routing
```sh
ip multicast-routing distributed
```
- Configure PIM multicast routing protocol on the upstream port, which is the WAN port of cvr-cloud (the tunnel port connected to the multicast source).
```sh
interface tunnel 0
    ip pim sparse-mode
```
- Configure PIM multicast routing protocol on the downstream port, which is the LAN port of cvr-cloud (the port where you want to forward multicast traffic).
```sh
interface GigabitEthernet2
    ip address dhcp
    no shutdown
    ip pim sparse-mode
```
- Since Transit Gateway does not support transparent transmission of IGMP join messages, the virtual router cannot dynamically detect receivers. Therefore, you must manually configure static IGMP join for the required multicast groups on the virtual router.
```sh
interface GigabitEthernet2
    ip igmp static-group 232.0.0.1
```
- If using PIM-SM (PIM Sparse Mode), you need to specify the Rendezvous Point (RP), which should be set to the local router's GRE tunnel address.
```sh
ip pim rp-address 169.254.100.1
```
- Enabling OSFP Routing Protocol
```sh
router ospf 1
 network 169.254.100.0 0.0.0.3 area 0
```
After entering the above configurations sequentially, type end to exit configuration mode. In the # (privileged EXEC) mode, enter write to save the configuration. To view all configurations, enter show run in the # mode.

#### Configuring cvr-onprem
After completing the cvr-cloud configuration, proceed to configure cvr-onprem.
Adding LAN Port ENI to cvr-onprem
Execute the following command from your local machine or a cloud-based bastion host to add a LAN interface to cvr-onprem. If executing locally, ensure that AWS CLI SDK is installed and API keys are configured for operating resources in this account. If executing from the cloud, ensure that the bastion host can access cvr-onprem. Note that the subnet-id in the command below is not the ID of subnet2, but rather the ID of subnet1. The Groups parameter is the security group ID of cvr-onprem.
```sh
aws ec2 create-network-interface \
    --subnet-id subnet-0524c3xxxxxxx \
    --description "LAN port" \
    --groups sg-xxxxxxx
```
After execution, you will receive the following JSON output. Extract the ENI ID from it to use as the network-interface-id parameter input for the subsequent command.
```sh
{
    "NetworkInterface": {
        "AvailabilityZone": "us-west-2c",
        "Description": "LAN port",
        "Groups": [
            {
                "GroupName": "default",
                "GroupId": "sg-xxxxxx"
            }
        ],
        "InterfaceType": "interface",
        "Ipv6Addresses": [],
        "MacAddress": "0a:6a:79:2e:58:47",
        "NetworkInterfaceId": "eni-0edcxxxxxxxx",
        "OwnerId": "xxxxxxxxxxxx",
        "PrivateDnsName": "ip-xx-xx-xx-xx.us-west-2.compute.internal",
        "PrivateIpAddress": "xx.xx.xx.xx",
        "PrivateIpAddresses": [
            {
                "Primary": true,
                "PrivateDnsName": "ip-xx-xx-xx-xx.us-west-2.compute.internal",
                "PrivateIpAddress": "xx.xx.xx.xx"
            }
        ],
        "RequesterId": "AROAxxxxxx:i-00d63xxxxxx",
        "RequesterManaged": false,
        "SourceDestCheck": true,
        "Status": "pending",
        "SubnetId": "subnet-0524xxxxxx",
        "TagSet": [],
        "VpcId": "vpc-7xxxxxx"
    }
}
```
The instance-id is the instance ID corresponding to cvr-onprem, which can be obtained from the EC2 console.
```sh
aws ec2 attach-network-interface \
    --network-interface-id eni-0edcxxxxxxxx \
    --instance-id i-05682xxxxxxxxx \
    --device-index 1
```
Next, you need to execute the following two commands separately to disable SourceDestCheck on both the WAN port and LAN port of cvr-onprem.
```sh
aws ec2 modify-network-interface-attribute --network-interface-id <WAN port ENI id> --no-source-dest-check
aws ec2 modify-network-interface-attribute --network-interface-id <LAN port ENI id> --no-source-dest-check
```
The CLI-based configuration operations from your local machine or cloud bastion host are now complete.
The following operations require logging into cvr-onprem directly.
First, use the following command to log into cvr-onprem:
```sh
ssh -i "<public key>" -o PubkeyAcceptedKeyTypes=+ssh-rsa ec2-user@<cvr-cloud’s IP address>
The public key format is xxx.pem.
```
IP Address Selection:
  - Internet login: Use the EC2's Public DNS with the format ec2-xx-xx-xx-xx.us-west-2.compute.amazonaws.com
  - Internal network login: Use the EC2's private IPv4 address with the format xx.xx.xx.xx
Once logged into cvr-cloud, execute config t to enter configuration mode. The following configuration items need to be configured:
- Configure the GRE tunnel on the WAN port, where E.F.G.H represents the public IP address of cvr-onprem.
```sh
interface tunnel 0
    ip address 169.254.100.2 255.255.255.252
    tunnel source GigabitEthernet1
    tunnel destination E.F.G.H
```
- Configure GRE Tunnel on LAN Port
```
interface GigabitEthernet2
    ip address dhcp
    no shutdown
interface tunnel 1
    ip address 169.254.200.1 255.255.255.252
    tunnel source GigabitEthernet2
    tunnel destination <multicast sender private IP address>
```
- Enable Multicast Routing
```sh
ip multicast-routing distributed
```
- Enable PIM Multicast Routing Protocol on Interfaces
```
interface tunnel 0
ip pim sparse-mode
interface tunnel 1
ip pim sparse-mode
```
- Specify Rendezvous Point (RP)
```sh
ip pim rp-address 169.254.100.1
```
- Enable OSPF Routing Protocol
```sh
router ospf 1
 network 169.254.100.0 0.0.0.3 area 0
 network 169.254.200.0 0.0.0.3 area 0
```
After entering the above configurations sequentially, type end to exit configuration mode. In the # (privileged EXEC) mode, enter write to save the configuration. To view all configurations, enter show run in the # mode.
With these steps completed, both cvr-cloud and cvr-onprem are now fully configured.

#### Configuring multicast sender and multicast receiver
You need to execute the following commands to disable SourceDestCheck on the WAN port of both the multicast sender and multicast receiver.
```sh
aws ec2 modify-network-interface-attribute --network-interface-id <WAN port ENI id> --no-source-dest-check
```
Log into the multicast sender and create a GRE tunnel between the multicast sender and cvr-onprem.
```sh
sudo ip tunnel add gre1 mode gre local <multicast sender private IP address> remote <cvr-onprem LAN IP address> ttl 255
sudo ip addr add 169.254.200.2/30 dev gre1
sudo ip link set gre1 up
sudo ip route add 224.0.0.0/4 dev gre1
```

The reason for creating this GRE tunnel is that the experimental environment is completed within an AWS VPC, and VPCs do not natively support multicast. Therefore, multicast data needs to be encapsulated within a GRE tunnel to enable transmission. In the actual production environment, this portion of the implementation is completed in CME's on-premises data center and is not subject to AWS VPC limitations.

#### Configuring Transit Gateway
- Navigate to below positon and creae transit gateway
<img width="152" height="131" alt="image" src="https://github.com/user-attachments/assets/fa62fc7a-a689-45b3-a3b2-6f66db4762e4" />

- Create Transit Gateway with Multicast Capability
<img width="285" height="119" alt="image" src="https://github.com/user-attachments/assets/ba3dfa14-4424-4c24-8d24-a88ab46ec030" />

- Navigate to below positon and creae transit gateway multicast
<img width="162" height="140" alt="image" src="https://github.com/user-attachments/assets/b1754ff0-975b-42d9-a10d-163ac72841a3" />
<img width="254" height="88" alt="image" src="https://github.com/user-attachments/assets/485d630d-4d2b-4518-b5c3-c93b8e9f25eb" />

- Create Transit gateway attachments
<img width="147" height="142" alt="image" src="https://github.com/user-attachments/assets/d5b8162c-884c-412c-89a6-9614e9a38e6e" />

VPC Attachment Configuration: Keep the VPC attachment settings at their default values, as shown in the screenshot.
<img width="219" height="149" alt="image" src="https://github.com/user-attachments/assets/027cd359-ffd7-49fb-9709-558dc7c9d6d1" />
 
Create two Transit Gateway attachments: 1/Transit VPC Attachment: Associate with subnet4 in the Transit VPC; 2/App VPC Attachment: Associate with subnet5 in the App VPC.
Associate these two Transit Gateway attachments with the previously created TGW Multicast Domain.
<img width="468" height="273" alt="image" src="https://github.com/user-attachments/assets/b4e586d5-603b-4dc7-b4c2-6dca371d7134" />

Configuration Parameters
1. Multicast Group Address: 232.0.0.1
2. Multicast Source: cvr-cloud's LAN port ENI
3. Multicast Member: Multicast Receiver's ENI
The configuration commands are as follows:
```sh
aws ec2 register-transit-gateway-multicast-group-sources \
  --transit-gateway-multicast-domain-id <tgw multicast domain id> \
  --group-ip-address 232.0.0.1 \
  --network-interface-ids <cvr-cloud LAN Port ENI id> \
  --region us-east-1
```
```sh
aws ec2 register-transit-gateway-multicast-group-members \
  --transit-gateway-multicast-domain-id <tgw multicast domain id> \
  --group-ip-address 232.0.0.1 \
  --network-interface-ids <multicast receiver ENI id> \
  --region us-east-1
```
#### Configuring Security Group
Ensure that the security group inbound rules in both the Transit VPC and App VPC allow traffic on UDP Port 5000. Port 5000 is the application-layer port used in this experiment for transmitting multicast data.



