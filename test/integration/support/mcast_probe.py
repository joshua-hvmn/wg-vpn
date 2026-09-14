#!/usr/bin/env python3
# mcast_probe.py <group> <port> [message] [iface_ip]
#
# Sends one multicast datagram. iface_ip (IPv4 only) forces it out a
# specific local interface via IP_MULTICAST_IF, mirroring "over the
# simulated physical interface" -- i.e. the same veth the killswitch is
# supposed to be blocking egress on.
import socket
import sys

group = sys.argv[1]
port = int(sys.argv[2])
message = sys.argv[3].encode() if len(sys.argv) > 3 else b"probe"
iface_ip = sys.argv[4] if len(sys.argv) > 4 else None

is_v6 = ":" in group
family = socket.AF_INET6 if is_v6 else socket.AF_INET
sock = socket.socket(family, socket.SOCK_DGRAM)

if is_v6:
    sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_HOPS, 4)
else:
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 4)
    if iface_ip:
        sock.setsockopt(
            socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(iface_ip)
        )

sock.sendto(message, (group, port))
