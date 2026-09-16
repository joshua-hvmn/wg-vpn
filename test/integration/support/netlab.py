#!/usr/bin/env python3
"""Network probes and listeners for the wg-vpn kill-switch integration suite.

Exit codes:

    0   the traffic got through
    1   the traffic was blocked, refused, or timed out
    2   the probe could not run at all (bad usage, bind failure, ...)

Verbs:

    serve-tcp ADDR PORT     echo server, writes --ready once it is listening
    serve-udp ADDR PORT     echo server, writes --ready once it is bound
    tcp HOST PORT           connect, round-trip a payload
    udp HOST PORT           send a datagram, expect it echoed back
    hold-tcp HOST PORT      open a connection, wait, then re-use it
    mcast-listen GROUP PORT join a multicast group, wait for one datagram
    mcast-send GROUP PORT   send one multicast datagram

Only the standard library is used; the test image installs no Python
packages.
"""

from __future__ import annotations

import argparse
import os
import socket
import socketserver
import struct
import sys
import time
from typing import NoReturn

BLOCKED = 1
ERROR = 2

PAYLOAD = b"wg-vpn-probe"
DEFAULT_TIMEOUT = 2.0


def fail(message: str) -> NoReturn:
    """Exit 2: probe itself is broken."""
    print(f"netlab: error: {message}", file=sys.stderr)
    raise SystemExit(ERROR)


def blocked(message: str) -> NoReturn:
    """Exit 1: traffic did not get through."""
    print(f"netlab: blocked: {message}", file=sys.stderr)
    raise SystemExit(BLOCKED)


def resolve(host: str, port: int, socktype: int):
    """Return (family, sockaddr) for host/port, IPv4 or 6"""
    try:
        infos = socket.getaddrinfo(host, port, type=socktype)
    except socket.gaierror as exc:
        fail(f"cannot resolve {host}:{port}: {exc}")
    family, _, _, _, sockaddr = infos[0]
    return family, sockaddr


def announce_ready(path: str | None, what: str) -> None:
    print(f"READY {what}", flush=True)
    if path:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(f"{what}\n")


# --------------------------------------------------------------------------
# Listeners
# --------------------------------------------------------------------------


class _TCPEchoHandler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        self.request.settimeout(120.0)
        while True:
            try:
                data = self.request.recv(4096)
                if not data:
                    return
                self.request.sendall(data)
            except OSError:
                return


class _UDPEchoHandler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        data, sock = self.request
        try:
            sock.sendto(data, self.client_address)
        except OSError:
            pass


def serve(kind: str, host: str, port: int, ready: str | None) -> None:
    socktype = socket.SOCK_STREAM if kind == "tcp" else socket.SOCK_DGRAM
    family, _ = resolve(host, port, socktype)

    base = (
        socketserver.ThreadingTCPServer
        if kind == "tcp"
        else socketserver.ThreadingUDPServer
    )
    handler = _TCPEchoHandler if kind == "tcp" else _UDPEchoHandler
    server_cls = type(
        "LabServer",
        (base,),
        {"address_family": family, "allow_reuse_address": True, "daemon_threads": True},
    )

    try:
        server = server_cls((host, port), handler)
    except OSError as exc:
        fail(f"cannot bind {kind} {host}:{port}: {exc}")

    announce_ready(ready, f"{kind} {host}:{port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


# --------------------------------------------------------------------------
# Probes
# --------------------------------------------------------------------------


def probe_tcp(host: str, port: int, timeout: float) -> None:
    family, sockaddr = resolve(host, port, socket.SOCK_STREAM)
    sock = socket.socket(family, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect(sockaddr)
        sock.sendall(PAYLOAD)
        data = sock.recv(len(PAYLOAD))
    except OSError as exc:
        blocked(f"tcp {host}:{port}: {exc}")
    finally:
        sock.close()

    if data != PAYLOAD:
        blocked(f"tcp {host}:{port}: echo mismatch ({data!r})")


def probe_udp(host: str, port: int, timeout: float) -> None:
    family, sockaddr = resolve(host, port, socket.SOCK_DGRAM)
    sock = socket.socket(family, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sock.sendto(PAYLOAD, sockaddr)
        data, _ = sock.recvfrom(len(PAYLOAD))
    except OSError as exc:
        blocked(f"udp {host}:{port}: {exc}")
    finally:
        sock.close()

    if data != PAYLOAD:
        blocked(f"udp {host}:{port}: echo mismatch ({data!r})")


def hold_tcp(
    host: str, port: int, ready: str, go: str, wait: float, timeout: float
) -> None:
    """This is the conntrack probe. ufw's stock before.rules accepts
    RELATED,ESTABLISHED on output ahead of any user rule, so a flow that was
    open before the kill-switch engaged keeps flowing after it unless the
    tool explicitly tears down existing conntrack entries. The suite opens
    the connection, brings the kill-switch up, then touches the go file and
    asks whether the old socket still works.
    """

    family, sockaddr = resolve(host, port, socket.SOCK_STREAM)
    sock = socket.socket(family, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect(sockaddr)
        sock.sendall(PAYLOAD)
        if sock.recv(len(PAYLOAD)) != PAYLOAD:
            fail(f"hold-tcp {host}:{port}: connection unusable before the test started")
    except OSError as exc:
        fail(f"hold-tcp {host}:{port}: could not establish baseline connection: {exc}")

    announce_ready(ready, f"held tcp {host}:{port}")

    deadline = time.monotonic() + wait
    while not os.path.exists(go):
        if time.monotonic() > deadline:
            fail(f"hold-tcp {host}:{port}: timed out waiting for {go}")
        time.sleep(0.05)

    try:
        sock.sendall(PAYLOAD)
        data = sock.recv(len(PAYLOAD))
    except OSError as exc:
        blocked(f"held tcp {host}:{port}: {exc}")
    finally:
        sock.close()

    if data != PAYLOAD:
        blocked(f"held tcp {host}:{port}: connection no longer carries data")


# --------------------------------------------------------------------------
# Multicast
# --------------------------------------------------------------------------


def mcast_listen(
    group: str, port: int, marker: str, timeout: float, iface_ip: str | None
) -> None:
    is_v6 = ":" in group
    family = socket.AF_INET6 if is_v6 else socket.AF_INET

    sock = socket.socket(family, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("::" if is_v6 else "0.0.0.0", port))
        if is_v6:
            mreq = socket.inet_pton(family, group) + struct.pack("@I", 0)
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_JOIN_GROUP, mreq)
        else:
            local = (
                socket.inet_aton(iface_ip) if iface_ip else socket.inet_aton("0.0.0.0")
            )
            sock.setsockopt(
                socket.IPPROTO_IP,
                socket.IP_ADD_MEMBERSHIP,
                socket.inet_aton(group) + local,
            )
    except OSError as exc:
        fail(f"cannot join {group}:{port}: {exc}")

    announce_ready(None, f"multicast {group}:{port}")
    sock.settimeout(timeout)
    try:
        data, addr = sock.recvfrom(2048)
    except OSError:
        blocked(f"no multicast datagram on {group}:{port} within {timeout}s")
    finally:
        sock.close()

    with open(marker, "w", encoding="utf-8") as handle:
        handle.write(f"{addr[0]} {data!r}\n")


def mcast_send(group: str, port: int, message: bytes, iface_ip: str | None) -> None:
    is_v6 = ":" in group
    family = socket.AF_INET6 if is_v6 else socket.AF_INET
    sock = socket.socket(family, socket.SOCK_DGRAM)
    try:
        if is_v6:
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_HOPS, 4)
        else:
            sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 4)
            if iface_ip:
                sock.setsockopt(
                    socket.IPPROTO_IP,
                    socket.IP_MULTICAST_IF,
                    socket.inet_aton(iface_ip),
                )
        sock.sendto(message, (group, port))
    except OSError as exc:
        blocked(f"multicast send to {group}:{port}: {exc}")
    finally:
        sock.close()


# --------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="netlab.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="verb", required=True)

    for kind in ("tcp", "udp"):
        serve_cmd = sub.add_parser(f"serve-{kind}", help=f"{kind} echo server")
        serve_cmd.add_argument("address")
        serve_cmd.add_argument("port", type=int)
        serve_cmd.add_argument("--ready", help="file to create once listening")

        probe_cmd = sub.add_parser(kind, help=f"{kind} round-trip probe")
        probe_cmd.add_argument("host")
        probe_cmd.add_argument("port", type=int)
        probe_cmd.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT)

    hold = sub.add_parser(
        "hold-tcp", help="hold a connection opend across a firewall change"
    )
    hold.add_argument("host")
    hold.add_argument("port", type=int)
    hold.add_argument("--ready", required=True, help="file to create once connected")
    hold.add_argument(
        "--go", required=True, help="file to wait for before re-using the socket"
    )
    hold.add_argument(
        "--wait", type=float, default=60.0, help="how long to wait for --go"
    )
    hold.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT)

    listen = sub.add_parser(
        "mcast-listen", help="join a group and wait for one datagram"
    )
    listen.add_argument("group")
    listen.add_argument("port", type=int)
    listen.add_argument(
        "--marker", required=True, help="file to write if a datagram arrives"
    )
    listen.add_argument("--timeout", type=float, default=3.0)
    listen.add_argument("--iface-ip", help="local address to join on (IPv4)")

    send = sub.add_parser("mcast-send", help="send one multicast datagram")
    send.add_argument("group")
    send.add_argument("port", type=int)
    send.add_argument("--message", default=PAYLOAD.decode())
    send.add_argument("--iface-ip", help="local address to send from (IPv4)")

    return parser


def main(argv: list[str] | None = None) -> None:
    args = build_parser().parse_args(argv)

    if args.verb in ("serve-tcp", "serve-udp"):
        serve(args.verb.removeprefix("serve-"), args.address, args.port, args.ready)
    elif args.verb == "tcp":
        probe_tcp(args.host, args.port, args.timeout)
    elif args.verb == "udp":
        probe_udp(args.host, args.port, args.timeout)
    elif args.verb == "hold-tcp":
        hold_tcp(args.host, args.port, args.ready, args.go, args.wait, args.timeout)
    elif args.verb == "mcast-listen":
        mcast_listen(args.group, args.port, args.marker, args.timeout, args.iface_ip)
    elif args.verb == "mcast-send":
        mcast_send(args.group, args.port, args.message.encode(), args.iface_ip)


if __name__ == "__main__":
    main()
