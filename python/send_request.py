#!/usr/bin/env python3
"""Helper for the SendRequest Neovim command.

Reads a "req" document on stdin of the form:

    ---
    host: example.com
    port: 443
    protocol: https
    sni: example.com
    ---
    GET / HTTP/1.1
    Host: example.com
    ...

The leading `---` delimited header is optional. The remainder of the
document is treated as a raw HTTP request which is sent over a (optionally
TLS-wrapped) socket. The raw HTTP response is written to stdout.
"""

import socket
import ssl
import sys

TIMEOUT = 15
RECV_SIZE = 65536


def parse_input(data):
    """Split the document into (header dict, raw request string)."""
    header = {}
    lines = data.split("\n")
    idx = 0

    # Optional `---` delimited header block.
    if lines and lines[0].strip() == "---":
        idx = 1
        while idx < len(lines):
            line = lines[idx]
            idx += 1
            if line.strip() == "---":
                break
            if ":" in line:
                key, value = line.split(":", 1)
                header[key.strip().lower()] = value.strip()

    request = "\n".join(lines[idx:])
    return header, request


def get_host_header(request):
    """Return the value of the HTTP `Host` header, if present."""
    for line in request.split("\n"):
        if line.strip() == "":
            # End of the request line / header block.
            break
        if ":" in line:
            key, value = line.split(":", 1)
            if key.strip().lower() == "host":
                return value.strip()
    return None


def resolve_target(header, request):
    """Compute (host, port, protocol, sni) using header values and defaults."""
    protocol = header.get("protocol", "https").lower()
    if protocol not in ("http", "https"):
        raise ValueError("protocol must be 'http' or 'https', got %r" % protocol)

    host = header.get("host")
    if not host:
        host_header = get_host_header(request)
        if not host_header:
            raise ValueError(
                "no host found: set 'host' in the header or a 'Host:' request header"
            )
        # The Host header may contain a port (e.g. example.com:8443).
        host = host_header.rsplit(":", 1)[0] if ":" in host_header else host_header
        host = host.strip("[]")  # tolerate bracketed IPv6

    if "port" in header:
        port = int(header["port"])
    else:
        port = 443 if protocol == "https" else 80

    sni = header.get("sni", host) if protocol == "https" else None
    return host, port, protocol, sni


def build_request_bytes(request):
    """Normalize line endings and ensure a terminating blank line."""
    raw = request.replace("\r\n", "\n").replace("\r", "\n")
    raw = raw.lstrip("\n")
    raw = raw.rstrip("\n") + "\n\n"
    return raw.replace("\n", "\r\n").encode("utf-8")


def connect(host, port, protocol, sni):
    sock = socket.create_connection((host, port), timeout=TIMEOUT)
    if protocol == "https":
        ctx = ssl.create_default_context()
        # Be permissive so self-signed / mismatched certs still work.
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        sock = ctx.wrap_socket(sock, server_hostname=sni)
    return sock


def recv_all(sock):
    """Read a complete HTTP response (best effort)."""
    sock.settimeout(TIMEOUT)
    buf = b""

    # Read at least the response headers.
    while b"\r\n\r\n" not in buf:
        try:
            chunk = sock.recv(RECV_SIZE)
        except socket.timeout:
            return buf
        if not chunk:
            return buf
        buf += chunk

    header_end = buf.index(b"\r\n\r\n") + 4
    headers_raw = buf[:header_end]
    body = buf[header_end:]

    headers = {}
    for line in headers_raw.decode("iso-8859-1").split("\r\n")[1:]:
        if ":" in line:
            key, value = line.split(":", 1)
            headers[key.strip().lower()] = value.strip()

    transfer_encoding = headers.get("transfer-encoding", "").lower()

    def read_more():
        try:
            chunk = sock.recv(RECV_SIZE)
        except socket.timeout:
            return None
        return chunk or None

    if "chunked" in transfer_encoding:
        while not body.endswith(b"0\r\n\r\n") and b"0\r\n\r\n" not in body:
            chunk = read_more()
            if chunk is None:
                break
            body += chunk
    elif "content-length" in headers:
        try:
            length = int(headers["content-length"])
        except ValueError:
            length = 0
        while len(body) < length:
            chunk = read_more()
            if chunk is None:
                break
            body += chunk
    else:
        # No length information: read until the connection closes.
        while True:
            chunk = read_more()
            if chunk is None:
                break
            body += chunk

    return headers_raw + body


def main():
    data = sys.stdin.read()
    header, request = parse_input(data)

    if not request.strip():
        sys.stderr.write("empty request\n")
        return 1

    try:
        host, port, protocol, sni = resolve_target(header, request)
    except ValueError as exc:
        sys.stderr.write("%s\n" % exc)
        return 1

    payload = build_request_bytes(request)

    sock = None
    try:
        sock = connect(host, port, protocol, sni)
        sock.sendall(payload)
        response = recv_all(sock)
    except (socket.error, ssl.SSLError) as exc:
        sys.stderr.write("connection error: %s\n" % exc)
        return 1
    finally:
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass

    sys.stdout.buffer.write(response)
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
