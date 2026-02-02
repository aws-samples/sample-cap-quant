#!/usr/bin/env python3
import socket, time

MCAST_GRP = '232.0.0.1'
MCAST_PORT = 5000

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 32)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, b'gre1')

print(f'Sending 500 packets to {MCAST_GRP}:{MCAST_PORT}')
for i in range(500):
    ts = time.time_ns()
    msg = f'TS:{ts}|seq:{i}'.encode()
    sock.sendto(msg, (MCAST_GRP, MCAST_PORT))
    time.sleep(0.01)
print('Done')
