aws ec2 create-network-interface \
    --subnet-id subnet-0524c3xxxxxxx \
    --description "LAN port" \
    --groups sg-xxxxxxx

aws ec2 attach-network-interface \
    --network-interface-id eni-0edcxxxxxxxx \
    --instance-id i-05682xxxxxxxxx \
    --device-index 1

aws ec2 modify-network-interface-attribute --network-interface-id <WAN port ENI id> --no-source- dest -check
aws ec2 modify-network-interface-attribute --network-interface-id <LAN port ENI id> --no-source- dest -check

sudo -i
route add -net 224.0.0.0 netmask 240.0.0.0 ens5
echo '2' > /proc/sys/net/ipv4/conf/ens5/force_igmp_version
cat /proc/net/ igmp

iperf -s -u -B 232.0.0.1- i 1

show ip igmp groups

show ip pim interface

show ip pim neighbor

show ip mroute


sudo tcpdump -n icmp

ping 232.0.0.1 source tunnel 0 repeat 5

