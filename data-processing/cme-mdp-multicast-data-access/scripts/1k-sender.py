#!/usr/bin/env python3
import socket
import struct
import time
import random

MCAST_GRP = '232.0.0.1'
MCAST_PORT = 5000
RECORDS_PER_SEC = 1000

def generate_record(seq, msg_seq, trade_id):
    date = "20171025"
    base_time = 123000000000000
    transact = base_time + seq * 1000
    sending = transact + random.randint(1000, 5000)

    return (f"{date}|{msg_seq}|{date}{sending}|{date}{transact}|GCZ7|"
            f"{5207583 + seq}|{round(1273.5 + random.random() * 0.2, 1)}|"
            f"{random.randint(1, 5)}|{random.randint(2, 4)}|1|{trade_id}|"
            f"76298198{random.randint(3000, 4000)}|{random.randint(1, 5)}")

def main():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 32)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, b'gre1')

    seq = 0
    msg_seq = 14899367
    trade_id = 15508475
    interval = 1.0 / RECORDS_PER_SEC

    print(f"Sending {RECORDS_PER_SEC} records/sec to {MCAST_GRP}:{MCAST_PORT}")

    end_time = time.time() + 60  # 1 minutes
    while time.time() < end_time:
        start = time.perf_counter()
        batch_start = time.perf_counter()
        sent = 0

        while sent < RECORDS_PER_SEC:
            record = generate_record(seq, msg_seq, trade_id)
            sock.sendto(record.encode(), (MCAST_GRP, MCAST_PORT))

            seq += 1
            msg_seq += 1
            trade_id += 1
            sent += 1

            # Pace sending to spread across the second
            elapsed = time.perf_counter() - batch_start
            expected = sent * interval
            if expected > elapsed:
                time.sleep(expected - elapsed)

        total = time.perf_counter() - start
        print(f"Sent {sent} records in {total:.3f}s ({sent/total:.0f}/sec)")

if __name__ == "__main__":
    main()
