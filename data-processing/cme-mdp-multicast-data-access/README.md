# CME DMP Multicast Data Access on AWS Experiment
This experiment showcases the core steps of achieving multicast data access on AWS.

## Experiment Architecture Diagram
<img width="4120" height="2112" alt="01experiment" src="https://github.com/user-attachments/assets/a4e4e1c3-92fa-41c3-99c8-e8122b4ee998" />

The multicast data sender + virtual router (in the simulated cloud) is implemented by subscribing to the Cisco Catalyst 8000V on the Amazon Web Services Marketplace and provisioning it in the designated/created Transit VPC. It is an EC2 instance with the c5n.large specification visible in the Amazon Web Services console . The virtual router (on the cloud) is created in the Transit VPC in the same way. The difference is that this EC2 instance needs to be configured with a LAN port (note that the original WAN port and the newly added LAN port need to be in different subnets). A GRE tunnel and PIM neighbor relationship need to be established between the two virtual routers. An EC2 instance needs to be provisioned in the designated/created App VPC as the multicast data receiver. A Transit Gateway is created through the Amazon Web Services console. During the creation process, please note: (1) Multicast needs to be enabled; (2) The Transit Gateway needs to have two attachments: one associated with the subnet where the LAN port of the virtual router (on the cloud) is located; the other associated with the subnet where the WAN port of the multicast data receiver EC2 is located.

## Implementation Steps

### Cisco Catalyst 8000V in the Amazon Web Services Marketplace
<img width="624" height="218.67" alt="image" src="https://github.com/user-attachments/assets/83e35770-521f-4252-9333-9db079e4f237" />

After the subscription is successful, you can see it in Manage subscripts . Click "Launch" on the right to deploy.

<img width="468" height="110" alt="image" src="https://github.com/user-attachments/assets/f845be8b-8e8a-43f7-b693-1d0cd7144e7f" />

We recommend selecting Amazon EC2 as the Service and Launch from EC2 Console as the Launch method. Note that both EC2 instances require the Auto- assign public IP setting .

<img width="468" height="225" alt="image" src="https://github.com/user-attachments/assets/846c51bc-0a81-411c-8a88-03d9ca3ec40e" />

### Create a data receiver EC2

Provision an EC2 instance as the data receiver in the specified/created App VPC.

### Create and configure a multicast data sender + virtual router (under the simulated cloud) and a virtual router (on the cloud)

In the Transit VPC you created, provision two EC2 instances as described above, naming them cvr -onprem and cvr -cloud .
Execute the following command locally or on a jump server in the cloud to add a LAN port to cvr -cloud . If executing locally, ensure that the AWS CLI SDK is installed locally and that the API key for operating this account's resources is configured. If operating on the cloud, ensure that the jump server can access cvr -cloud and cvr -onprem . Note that the subnet - id in the command below cannot be the ID of the subnet where cvr -cloud is currently located; it must be the ID of another subnet. The Groups parameter is the ID of the security group of this EC2 instance.

```sh
aws ec2 create-network-interface \
    --subnet-id subnet-0524c3xxxxxxx \
    --description "LAN port" \
    --groups sg-xxxxxxx
```

After execution, the following Json is obtained, from which the ENI ID is read as the input of the network-interface-id parameter of the following command.

```json
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

instance-id is the instance-id corresponding to cvr -cloud , which can be obtained from the EC2 console.

```sh
aws ec2 attach-network-interface \
    --network-interface-id eni-0edcxxxxxxxx \
    --instance-id i-05682xxxxxxxxx \
    --device-index 1
```
Next, you need to execute the following two commands to shut down the source- dest -desk of the WAN port and LAN port of cvr -cloud respectively.

```sh
aws ec2 modify-network-interface-attribute --network-interface-id <WAN port ENI id> --no-source- dest -check
aws ec2 modify-network-interface-attribute --network-interface-id <LAN port ENI id> --no-source- dest -check
```

This concludes the configuration process using the CLI locally or remotely from a cloud-based jump server. The remaining operations require logging in to cvr -cloud or cvr -onprem .

log in to cvr -cloud using the following command .

```sh
ssh -i " <public key>" -o PubkeyAcceptedKeyTypes =+ssh- rsa ec2-user@< cvr -cloud's IP address>
```

The public key format is xxx.pem . If logging in via the internet, the IP address is the EC2's public DNS address, in the format ec2-xx-xx-xx-xx.us-west-2.compute.amazonaws.com . If logging in via the intranet, the IP address is the EC2's private IPv4 address , in the format xx.xx.xx.xx.

In cvr -cloud , execute config t to enter config mode. You need to configure the following configuration items.

- Configure a GRE tunnel on the WAN port. ABCD is the public network address of c vr-onprem .

```txt
interface tunnel 0
    ip address 169.254.100.2 255.255.255.252
    tunnel source GigabitEthernet1
    tunnel destination A.B.C.D
```

- Enable multicast routing

```txt
ip multicast-routing distributed
```

- Enable PIM multicast routing protocol on the port - upstream port (tunnel port connected to the multicast source), which is the WAN port of cvr - cloud.

```txt
interface tunnel 0
    ip pim sparse-mode
```

- Enable PIM multicast routing protocol on the downstream port (the LAN port you want to forward traffic to), which is the LAN port of the cvr -cloud .

```txt
interface GigabitEthernet3
    ip address dhcp
    no shutdown
    ip pim sparse-mode
```

- Because the Transit Gateway does not support transparent transmission of IGMP Join messages, the virtual router cannot dynamically detect receivers . Please manually configure static IGMP Join for the required multicast group on the virtual router .

```txt
interface GigabitEthernet3
    ip igmp static-group 232.0.0.1
```

- If it is PIM-SM mode, you need to specify RP, which is the GRE tunnel address of the local router.

```txt
ip pim rp-address 169.254.100.1
```

After entering the above configurations, press end to exit config mode. Then, press write in # mode to save the configurations. To view all configurations, press show run in # mode .

configuring cvr -cloud , configure cvr- onprem . Log in to cvr- onprem in the same way . After entering config mode, configure as follows

- Configure a GRE tunnel on the WAN port, where ABCD is the public network address of cvr - cloud .

```txt
interface tunnel 0
    ip address 169.254.100.2 255.255.255.252
    tunnel source GigabitEthernet1
    tunnel destination A.B.C.D
```
In this way, cvr -cloud and cvr- onprem are configured.

### Creating and configuring a Transit Gateway

- Gateway with Multicast Capabilities

<img width="285" height="119" alt="image" src="https://github.com/user-attachments/assets/6ce996f9-9209-4aaa-8948-33ade07351a4" />

- Creating a multicast domain

<img width="351" height="158" alt="image" src="https://github.com/user-attachments/assets/62b63d4e-762e-4f29-8ef5-def68eb6f478" />

- Associate the LAN subnet of the virtual router in the Transit VPC with the subnet of the multicast receiving EC2 in the App VPC

<img width="468" height="185" alt="image" src="https://github.com/user-attachments/assets/5686e350-e04a-4d16-9080-a9558f768cc4" />

- Configure IGMP v2 on the EC2 receiving multicast data and join the 232.0.0.1 multicast group. To do this, log in to the EC2 receiving multicast data from a local or cloud-based server and run the following commands one by one.

```sh
sudo -i
route add -net 224.0.0.0 netmask 240.0.0.0 ens5
echo '2' > /proc/sys/net/ipv4/conf/ens5/force_igmp_version
cat /proc/net/ igmp
```

The screenshot after the command is executed is as follows :

<img width="468" height="50" alt="image" src="https://github.com/user-attachments/assets/dadfeb03-7222-4c91-b0ec-673f861fc705" />

```sh
iperf -s -u -B 232.0.0.1- i 1
```

The screenshot after the command is executed is as follows:

<img width="468" height="59" alt="image" src="https://github.com/user-attachments/assets/d23ea6b4-7d56-43ee-b620-05323bdc7a40" />

Multicast reception observed on Transit Gateway EC2 ENI joins a multicast group

<img width="468" height="184" alt="image" src="https://github.com/user-attachments/assets/5dc4a9e5-3561-46d0-9b1d-650a8a11aa4d" />

## Experimental verification
### Multicast Configuration Verification

- Check whether IGMP has joined the 232.0.0.1 multicast group status

Log in to cvr -cloud and execute the following command in # mode

```sh
show ip igmp groups
```
The results are shown below:

<img width="468" height="34" alt="image" src="https://github.com/user-attachments/assets/9679d82b-1410-44e1-949d-4eee9f860e94" />


- Check whether the PIM port is enabled

Log in to cvr -cloud and execute the following command in # mode

```sh
show ip pim interface
```

The results are shown below (GigabitEthernet2 is optional):

<img width="468" height="46" alt="image" src="https://github.com/user-attachments/assets/d9b97145-7243-4258-a87f-1a11d9d2797f" />

- Check the PIM neighbor status

Log in to cvr -cloud and execute the following command in # mode

```sh
show ip pim neighbor
```

The results are shown below:

<img width="468" height="61" alt="image" src="https://github.com/user-attachments/assets/6994df5c-34c8-4e08-afa5-b254bc92e232" />

- Check the multicast routing table

Log in to cvr -cloud and execute the following command in # mode

```sh
show ip mroute
```

The results are shown below:

<img width="468" height="211" alt="image" src="https://github.com/user-attachments/assets/a311b337-0255-4012-b955-b65bebe304b2" />

### Multicast data reception verification

Log in to the multicast data receiver EC2 and execute the following command

```sh
sudo tcpdump -n icmp
```

Log in to cvr- onprem and execute the following command in # mode:

```sh
ping 232.0.0.1 source tunnel 0 repeat 5
```

the cvr- onprem side are as follows:

<img width="468" height="34" alt="image" src="https://github.com/user-attachments/assets/3882a93c-02fa-438a-bb79-65786343bf82" />

The results of logging into the EC2 side of the multicast data receiver are as follows:

<img width="468" height="70" alt="image" src="https://github.com/user-attachments/assets/703a1a14-f9f7-4a81-bfa3-09a2680e8a4c" />




