#!/usr/bin/env python3
# udp_echo.py <host> <port> - background listener for the endpoint
import socket
import sys

host, port = sys.argv[1], int(sys.argv[2])
family = socket.AF_INET6 if ":" in host else socket.AF_INET
s = socket.socket(family, socket.SOCK_DGRAM)
s.bind((host, port))
while True:
    data, addr = s.recvfrom(1024)
    s.sendto(b"pong", addr)
