"""Static WAN traffic fixture: bound listeners, a wildcard IP_PKTINFO responder and probes."""

import pathlib
import select
import socket
import struct
import sys

IP_PKTINFO = getattr(socket, "IP_PKTINFO", 8)


def listener(spec):
    kind, *rest = spec.split(":")
    if kind in ("tcp", "tcp-peer"):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((rest[0], int(rest[1])))
        sock.listen()
    elif kind == "udp":
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind((rest[0], int(rest[1])))
    elif kind == "udp-pktinfo":
        # Kernel UDP services such as WireGuard bind the wildcard address and
        # answer from the destination address the peer contacted.
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.IPPROTO_IP, IP_PKTINFO, 1)
        sock.bind(("0.0.0.0", int(rest[0])))
    else:
        raise SystemExit(f"unknown listener {spec}")
    return sock, kind


def serve(ready, specs):
    sockets = dict(listener(spec) for spec in specs)
    pathlib.Path(ready).touch()
    while True:
        for sock in select.select(list(sockets), [], [])[0]:
            kind = sockets[sock]
            if kind in ("tcp", "tcp-peer"):
                conn, peer = sock.accept()
                reply = f"peer {peer[0]}" if kind == "tcp-peer" else f"tcp {conn.getsockname()[0]}"
                conn.sendall(reply.encode())
                conn.close()
            elif kind == "udp":
                _, peer = sock.recvfrom(1024)
                sock.sendto(f"udp {sock.getsockname()[0]}".encode(), peer)
            else:
                _, ancillary, _, peer = sock.recvmsg(1024, socket.CMSG_SPACE(12))
                destination = next(
                    socket.inet_ntoa(data[8:12])
                    for level, kind_, data in ancillary
                    if level == socket.IPPROTO_IP and kind_ == IP_PKTINFO
                )
                info = struct.pack("i4s4s", 0, socket.inet_aton(destination), bytes(4))
                sock.sendmsg(
                    [f"pktinfo {destination}".encode()],
                    [(socket.IPPROTO_IP, IP_PKTINFO, info)],
                    0,
                    peer,
                )


def probe(kind, source, destination, port, expected):
    family = socket.SOCK_STREAM if kind == "tcp" else socket.SOCK_DGRAM
    sock = socket.socket(socket.AF_INET, family)
    sock.settimeout(2)
    sock.bind((source, 0))
    try:
        # A connected UDP socket accepts replies only from the contacted address.
        sock.connect((destination, int(port)))
        if kind == "udp":
            sock.send(b"probe")
        reply = sock.recv(1024).decode()
    except (socket.timeout, ConnectionError) as error:
        raise SystemExit(f"{kind} {source} -> {destination}:{port}: {error!r}")
    if reply != expected:
        raise SystemExit(f"{kind} {source} -> {destination}:{port}: got {reply!r}, want {expected!r}")
    print(f"{kind} {source} -> {destination}:{port}: {reply}")


if __name__ == "__main__":
    if sys.argv[1] == "serve":
        serve(sys.argv[2], sys.argv[3:])
    else:
        probe(*sys.argv[1:])
