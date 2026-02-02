#!/usr/bin/env python3
import socket, struct, time

MCAST_GRP = '232.0.0.1'
MCAST_PORT = 5000

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(('', MCAST_PORT))
mreq = struct.pack('4sl', socket.inet_aton(MCAST_GRP), socket.INADDR_ANY)
sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
sock.settimeout(15)

latencies = []
print('Listening...')
try:
    while len(latencies) < 500:
        data, addr = sock.recvfrom(1024)
        recv_ts = time.time_ns()
        msg = data.decode()
        if msg.startswith('TS:'):
            send_ts = int(msg.split('|')[0][3:])
            latencies.append((recv_ts - send_ts) / 1000)
except socket.timeout:
    pass

if latencies:
    latencies.sort()
    print(f'Packets: {len(latencies)}')
    print(f'Latency(us): min={min(latencies):.0f} avg={sum(latencies)/len(latencies):.0f} p50={latencies[len(latencies)//2]:.0f} p99={latencies[int(len(latencies)*0.99)]:.0f} max={max(latencies):.0f}')
else:
    print('No packets received')
