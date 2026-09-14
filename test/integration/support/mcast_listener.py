#!/usr/bin/env python3
# mcast_listener.py <group> <port> <marker_file> [timeout_s] [iface_ip]
#
# Joins <group>:<port> and, if any packet arrives before the timeout,
# writes it to <marker_file>. Used by the mDNS/multicast leak check to
# prove whether a probe sent from the host actually reached this
# network namespace, i.e. whether it leaked past the killswitch.
#
# iface_ip (IPv4 only) pins group membership to a specific local
# interface by address, so behaviour is deterministic even when the
# namespace has several veth interfaces present.

import socket
import struct
import sys

group = sys.argv[1]
port = int(sys.argv[2])
marker = sys.argv[3]
timeout = float(sys.argv[4]) if len(sys.argv) > 4 else 3.0
iface_ip = sys.argv[5] if len(sys.argv) > 5 else None

is_v6 = ":" in group
family = socket.AF_INET6 if is_v6 else socket.AF_INET

sock = socket.socket(family, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("::" if is_v6 else "0.0.0.0", port))

if is_v6:
    mreq = socket.inet_pton(family, group) + struct.pack("@I", 0)
    sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_JOIN_GROUP, mreq)
else:
    local_addr = socket.inet_aton(iface_ip) if iface_ip else socket.inet_aton("0.0.0.0")
    mreq = socket.inet_aton(group) + local_addr
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)

sock.settimeout(timeout)
try:
    data, addr = sock.recvfrom(2048)
    with open(marker, "w") as f:
        f.write(f"{addr[0]}: {data!r}\n")
except TimeoutError:
    pass
