#!/usr/bin/env python3
# tcp_probe.py <host> <port> - exot 0 of a real TCP connect succeeds
import socket
import sys

host, port = sys.argv[1], int(sys.argv[2])
try:
    with socket.create_connection((host, port), timeout=1.5):
        sys.exit(0)
except OSError:
    sys.exit(1)
