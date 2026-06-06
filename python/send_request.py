#!/usr/bin/env python3
"""Helper for the SendRequest Neovim command.

Reads a "req" document on stdin of the form:

    ---
    host: example.com
    port: 443
    protocol: https
    sni: example.com
    proxy: http://localhost:8080
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

# Keys recognized inside the `---` delimited header block.
VALID_HEADER_KEYS = ("host", "port", "protocol", "sni", "proxy")


def parse_input(data):
    """Split the document into (header dict, raw request string).

    Raises ValueError if the `---` header block contains malformed or
    unrecognized entries.
    """
    header = {}
    lines = data.split("\n")
    idx = 0

    # Optional `---` delimited header block.
    if lines and lines[0].strip() == "---":
        idx = 1
        closed = False
        while idx < len(lines):
            line = lines[idx]
            lineno = idx + 1
            idx += 1
            if line.strip() == "---":
                closed = True
                break
            if line.strip() == "":
                continue
            if ":" not in line:
                raise ValueError(
                    "invalid header entry on line %d: %r "
                    "(expected 'key: value')" % (lineno, line)
                )
            key, value = line.split(":", 1)
            key = key.strip().lower()
            if not key:
                raise ValueError(
                    "invalid header entry on line %d: %r "
                    "(missing key)" % (lineno, line)
                )
            if key not in VALID_HEADER_KEYS:
                raise ValueError(
                    "unknown header key %r on line %d (valid keys: %s)"
                    % (key, lineno, ", ".join(VALID_HEADER_KEYS))
                )
            if key in header:
                raise ValueError(
                    "duplicate header key %r on line %d" % (key, lineno)
                )
            header[key] = value.strip()
        if not closed:
            raise ValueError("header block not closed with '---'")

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
        try:
            port = int(header["port"])
        except ValueError:
            raise ValueError("port must be an integer, got %r" % header["port"])
        if not 0 < port < 65536:
            raise ValueError("port must be between 1 and 65535, got %d" % port)
    else:
        port = 443 if protocol == "https" else 80

    sni = header.get("sni", host) if protocol == "https" else None
    proxy = parse_proxy(header.get("proxy"))
    return host, port, protocol, sni, proxy


def parse_proxy(value):
    """Parse a proxy URL into (host, port).

    Accepts forms like ``http://localhost:8080`` or ``localhost:8080``.
    Returns None when no proxy is configured.
    """
    if not value:
        return None
    raw = value.strip()
    if "://" in raw:
        scheme, raw = raw.split("://", 1)
        scheme = scheme.lower()
        if scheme not in ("http", ""):
            raise ValueError("proxy scheme must be 'http', got %r" % scheme)
    raw = raw.rstrip("/")
    if not raw:
        raise ValueError("proxy must include a host")
    if ":" in raw:
        proxy_host, proxy_port = raw.rsplit(":", 1)
        try:
            proxy_port = int(proxy_port)
        except ValueError:
            raise ValueError("proxy port must be an integer, got %r" % proxy_port)
    else:
        proxy_host, proxy_port = raw, 8080
    proxy_host = proxy_host.strip("[]")
    if not proxy_host:
        raise ValueError("proxy must include a host")
    if not 0 < proxy_port < 65536:
        raise ValueError("proxy port must be between 1 and 65535, got %d" % proxy_port)
    return proxy_host, proxy_port


def build_request_bytes(request):
    """Normalize line endings and ensure a terminating blank line."""
    raw = request.replace("\r\n", "\n").replace("\r", "\n")
    raw = raw.lstrip("\n")
    raw = raw.rstrip("\n") + "\n\n"
    return raw.replace("\n", "\r\n").encode("utf-8")


def proxy_connect(sock, host, port):
    """Establish a tunnel to host:port through an HTTP proxy via CONNECT."""
    target = "%s:%d" % (host, port)
    request = (
        "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n" % (target, target)
    ).encode("ascii")
    sock.sendall(request)

    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(RECV_SIZE)
        if not chunk:
            break
        buf += chunk

    status_line = buf.split(b"\r\n", 1)[0].decode("iso-8859-1")
    parts = status_line.split(" ", 2)
    if len(parts) < 2 or parts[1] != "200":
        raise socket.error("proxy CONNECT failed: %s" % status_line)


def connect(host, port, protocol, sni, proxy=None):
    if proxy is not None:
        sock = socket.create_connection(proxy, timeout=TIMEOUT)
        proxy_connect(sock, host, port)
    else:
        sock = socket.create_connection((host, port), timeout=TIMEOUT)
    if protocol == "https":
        ctx = ssl.create_default_context()
        # Be permissive so self-signed / mismatched certs still work.
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        sock = ctx.wrap_socket(sock, server_hostname=sni)
    return sock


def get_request_method(request):
    """Return the HTTP method from the request line, upper-cased."""
    for line in request.replace("\r\n", "\n").split("\n"):
        if line.strip():
            return line.split(" ", 1)[0].strip().upper()
    return ""


def get_status_code(headers_raw):
    """Return the integer status code from the response status line, or None."""
    status_line = headers_raw.split(b"\r\n", 1)[0].decode("iso-8859-1")
    parts = status_line.split(" ", 2)
    if len(parts) >= 2:
        try:
            return int(parts[1])
        except ValueError:
            return None
    return None


def recv_all(sock, method=""):
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

    # Per RFC 7230 these responses never carry a message body, regardless of
    # any Content-Length/Transfer-Encoding header. Returning early avoids
    # blocking on a kept-alive connection that will never send more bytes.
    status = get_status_code(headers_raw)
    if method.upper() == "HEAD" or status in (204, 304) or (
        status is not None and 100 <= status < 200
    ):
        return headers_raw + body

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
    try:
        header, request = parse_input(data)
    except ValueError as exc:
        sys.stderr.write("%s\n" % exc)
        return 1

    if not request.strip():
        sys.stderr.write("empty request\n")
        return 1

    try:
        host, port, protocol, sni, proxy = resolve_target(header, request)
    except ValueError as exc:
        sys.stderr.write("%s\n" % exc)
        return 1

    payload = build_request_bytes(request)

    sock = None
    try:
        sock = connect(host, port, protocol, sni, proxy)
        sock.sendall(payload)
        response = recv_all(sock, get_request_method(request))
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
