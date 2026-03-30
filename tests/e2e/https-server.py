#!/usr/bin/env python3
"""Simple HTTPS server with self-signed cert for stress testing.

Generates small files and serves them over HTTPS.
Usage: https-server.py [--port PORT] [--file-count N] [--file-size BYTES] [--cert-dir DIR] [--data-dir DIR]
"""
import argparse
import http.server
import os
import socketserver
import ssl
import subprocess
import sys


def generate_cert(cert_dir):
    """Generate a self-signed certificate."""
    os.makedirs(cert_dir, exist_ok=True)
    cert_path = os.path.join(cert_dir, "cert.pem")
    key_path = os.path.join(cert_dir, "key.pem")

    subprocess.run(
        [
            "openssl", "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", key_path, "-out", cert_path,
            "-days", "1", "-nodes",
            "-subj", "/CN=stress-test-server",
            "-addext", "subjectAltName=IP:0.0.0.0,IP:127.0.0.1",
        ],
        check=True,
        capture_output=True,
    )
    print(f"Certificate: {cert_path}", file=sys.stderr)
    print(f"Key: {key_path}", file=sys.stderr)
    return cert_path, key_path


def generate_files(data_dir, count, size):
    """Generate test files filled with random bytes."""
    os.makedirs(data_dir, exist_ok=True)
    for i in range(count):
        path = os.path.join(data_dir, f"file-{i:04d}.bin")
        with open(path, "wb") as f:
            f.write(os.urandom(size))
    print(f"Generated {count} files of {size} bytes in {data_dir}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18443)
    parser.add_argument("--file-count", type=int, default=500)
    parser.add_argument("--file-size", type=int, default=4096)
    parser.add_argument("--cert-dir", default="/tmp/stress-test-cert")
    parser.add_argument("--data-dir", default="/tmp/stress-test-data")
    args = parser.parse_args()

    cert_path, key_path = generate_cert(args.cert_dir)
    generate_files(args.data_dir, args.file_count, args.file_size)

    os.chdir(args.data_dir)

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert_path, key_path)

    class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True

    server = ThreadedHTTPServer(("0.0.0.0", args.port), http.server.SimpleHTTPRequestHandler)
    server.socket = context.wrap_socket(server.socket, server_side=True)

    print(f"HTTPS server listening on 0.0.0.0:{args.port} (threaded)", file=sys.stderr)
    print(f"READY", flush=True)  # Signal to parent process
    server.serve_forever()


if __name__ == "__main__":
    main()
