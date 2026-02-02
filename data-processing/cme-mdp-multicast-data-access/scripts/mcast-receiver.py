import socket
import struct

MCAST_GRP = '232.0.0.1'
MCAST_PORT = 5000

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(('', MCAST_PORT))

mreq = struct.pack('4sl', socket.inet_aton(MCAST_GRP), socket.INADDR_ANY)
sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)

print('Listening for multicast on 232.0.0.1:5000...')
while True:
    data, addr = sock.recvfrom(1024)
    print(f'Received from {addr}: {data.decode()}')
