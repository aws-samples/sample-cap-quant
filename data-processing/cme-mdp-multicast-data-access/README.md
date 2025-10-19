# CME DMP Multicast Data Access on AWS Experiment
This experiment showcases the core steps of achieving multicast data access on AWS.

## Experiment Architecture Diagram
<img width="4120" height="2112" alt="01experiment" src="https://github.com/user-attachments/assets/a4e4e1c3-92fa-41c3-99c8-e8122b4ee998" />

The multicast data sender + virtual router (in the simulated cloud) is implemented by subscribing to the Cisco Catalyst 8000V on the Amazon Web Services Marketplace and provisioning it in the designated/created Transit VPC. It is an EC2 instance with the c5n.large specification visible in the Amazon Web Services console . The virtual router (on the cloud) is created in the Transit VPC in the same way. The difference is that this EC2 instance needs to be configured with a LAN port (note that the original WAN port and the newly added LAN port need to be in different subnets). A GRE tunnel and PIM neighbor relationship need to be established between the two virtual routers. An EC2 instance needs to be provisioned in the designated/created App VPC as the multicast data receiver. A Transit Gateway is created through the Amazon Web Services console. During the creation process, please note: (1) Multicast needs to be enabled; (2) The Transit Gateway needs to have two attachments: one associated with the subnet where the LAN port of the virtual router (on the cloud) is located; the other associated with the subnet where the WAN port of the multicast data receiver EC2 is located.

## Implementation Steps

### Cisco Catalyst 8000V in the Amazon Web Services Marketplace
