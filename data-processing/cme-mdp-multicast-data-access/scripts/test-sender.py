import socket
import time

MCAST_GRP = '232.0.0.1'
MCAST_PORT = 5000

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 32)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, b'gre1')

for i in range(10):
    msg = f'Multicast test message {i}'
    sock.sendto(msg.encode(), (MCAST_GRP, MCAST_PORT))
    print(f'Sent: {msg}')
    time.sleep(0.5)
