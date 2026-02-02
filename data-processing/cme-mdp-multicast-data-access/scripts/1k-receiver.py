import socket
import struct
import time
import threading

MCAST_GRP = '232.0.0.1'
MCAST_PORT = 5000

count = 0
lock = threading.Lock()

def print_stats():
    global count
    while True:
        time.sleep(5)
        with lock:
            print(f'Total records received: {count}')

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(('', MCAST_PORT))

mreq = struct.pack('4sl', socket.inet_aton(MCAST_GRP), socket.INADDR_ANY)
sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)

print('Listening for multicast on 232.0.0.1:5000...')
threading.Thread(target=print_stats, daemon=True).start()

while True:
    sock.recvfrom(1024)
    with lock:
        count += 1
