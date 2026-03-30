#!/usr/bin/env python3
"""Minimal DNS-over-HTTPS server that resolves all queries to a fixed IP.

Usage: doh-server.py [--port PORT] [--resolve-to IP] [--cert CERT] [--key KEY]

Accepts POST /dns-query with application/dns-message body (RFC 8484).
Returns A records pointing to --resolve-to for all queries.
"""
import argparse
import http.server
import socket
import ssl
import struct
import sys


def build_dns_response(query: bytes, resolve_to: str) -> bytes:
    """Parse a DNS query and build a response with a single A record."""
    if len(query) < 12:
        return b""

    # Parse header
    txn_id, flags, qdcount = struct.unpack("!HHH", query[:6])

    # Response flags: QR=1, AA=1, RCODE=0
    resp_flags = 0x8400

    # Find end of question section (skip past QNAME + QTYPE + QCLASS)
    offset = 12
    for _ in range(qdcount):
        while offset < len(query):
            length = query[offset]
            if length == 0:
                offset += 1  # null terminator
                break
            offset += 1 + length
        offset += 4  # QTYPE (2) + QCLASS (2)

    question = query[12:offset]

    # Build response header: same ID, response flags, 1 question, 1 answer
    header = struct.pack("!HHHHHH", txn_id, resp_flags, qdcount, 1, 0, 0)

    # Build answer: pointer to question name (0xC00C), type A, class IN, TTL 60, 4-byte IP
    ip_bytes = socket.inet_aton(resolve_to)
    answer = struct.pack("!HHHLH", 0xC00C, 1, 1, 60, 4) + ip_bytes

    return header + question + answer


class DoHHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/dns-query":
            self.send_error(404)
            return

        content_length = int(self.headers.get("Content-Length", 0))
        query = self.rfile.read(content_length)

        response = build_dns_response(query, self.server.resolve_to)

        self.send_response(200)
        self.send_header("Content-Type", "application/dns-message")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, format, *args):
        # Suppress access logs (they clutter test output)
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18444)
    parser.add_argument("--resolve-to", default="127.0.0.1")
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    args = parser.parse_args()

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.cert, args.key)

    server = http.server.HTTPServer(("0.0.0.0", args.port), DoHHandler)
    server.resolve_to = args.resolve_to
    server.socket = context.wrap_socket(server.socket, server_side=True)

    print(f"DoH server listening on 0.0.0.0:{args.port}, resolving all to {args.resolve_to}", file=sys.stderr)
    print("READY", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
