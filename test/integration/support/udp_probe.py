#!/usr/bin/env python3
# udp_probe.py <host> <port> - exit 0 if echoed back within timeout, else 1
import socket
import sys

host, port = sys.argv[1], int(sys.argv[2])
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(1.5)
s.sendto(b"ping", (host, port))
try:
    data, _ = s.recvfrom(1024)
    sys.exit(0 if data == b"pong" else 1)
except TimeoutError:
    sys.exit(1)
