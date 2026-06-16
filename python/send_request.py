#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = [
#     "requests",
#     "brotli",
#     "zstandard",
# ]
# ///
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
document is treated as a raw HTTP request which is sent with `requests`.
The raw HTTP response is written to stdout, with the body fully decoded
(content/transfer encodings such as gzip, deflate, br and zstd are
transparently decompressed by urllib3, given the dependencies declared in
the inline script metadata above).

This file is a self-contained uv script: the dependencies in the `/// script`
block are installed automatically when run via `uv run`.
"""

import sys

import requests
import urllib3

# Permissive TLS (self-signed / mismatched certs) means urllib3 would
# otherwise emit InsecureRequestWarning noise on stderr.
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

TIMEOUT = 15

# Keys recognized inside the `---` delimited header block.
VALID_HEADER_KEYS = ("host", "port", "protocol", "sni", "proxy")

# Response headers that no longer describe the decoded body we emit.
_DROPPED_RESPONSE_HEADERS = (
    "content-encoding",
    "transfer-encoding",
    "content-length",
)


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


def parse_http_request(request):
    """Parse a raw HTTP request into (method, target, headers, body).

    `headers` is a list of (name, value) pairs preserving order. `target` is
    the request-target from the request line (path + query).

    The body is returned with its original line endings untouched. This
    matters for multipart/form-data, whose boundary delimiters must be CRLF
    (RFC 2046); rewriting them corrupts the upload.
    """
    text = request.lstrip("\r\n")

    # Split the header block from the body at the first blank line, accepting
    # either a CRLF or LF separator, without modifying the body bytes.
    sep_crlf = text.find("\r\n\r\n")
    sep_lf = text.find("\n\n")
    if sep_crlf != -1 and (sep_lf == -1 or sep_crlf < sep_lf):
        head, body = text[:sep_crlf], text[sep_crlf + 4:]
    elif sep_lf != -1:
        head, body = text[:sep_lf], text[sep_lf + 2:]
    else:
        head, body = text, ""

    # Normalize only the head for parsing; the body is left verbatim.
    head = head.replace("\r\n", "\n").replace("\r", "\n")
    head_lines = head.split("\n")
    request_line = head_lines[0].strip()
    parts = request_line.split()
    if not parts:
        raise ValueError("missing request line")
    method = parts[0].upper()
    target = parts[1] if len(parts) > 1 else "/"

    headers = []
    for line in head_lines[1:]:
        if line.strip() == "":
            continue
        if ":" not in line:
            raise ValueError("invalid request header line: %r" % line)
        key, value = line.split(":", 1)
        headers.append((key.strip(), value.strip()))

    return method, target, headers, body


def get_header(headers, name):
    """Case-insensitive lookup in a list of (name, value) header pairs."""
    name = name.lower()
    for key, value in headers:
        if key.lower() == name:
            return value
    return None


def resolve_target(header, request_headers):
    """Compute (host, port, protocol, sni, proxies) from header + defaults."""
    protocol = header.get("protocol", "https").lower()
    if protocol not in ("http", "https"):
        raise ValueError("protocol must be 'http' or 'https', got %r" % protocol)

    host = header.get("host")
    if not host:
        host_header = get_header(request_headers, "host")
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
    proxies = parse_proxy(header.get("proxy"))
    return host, port, protocol, sni, proxies


def parse_proxy(value):
    """Parse a proxy URL into a `requests` proxies dict, or None.

    Accepts forms like ``http://localhost:8080`` or ``localhost:8080``.
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
    proxy_url = "http://%s:%d" % (proxy_host, proxy_port)
    return {"http": proxy_url, "https": proxy_url}


class _SNIAdapter(requests.adapters.HTTPAdapter):
    """HTTPAdapter that pins the TLS SNI to an explicit server hostname.

    This lets the connection target (URL host) differ from the name sent in
    the TLS ClientHello, mirroring the original `sni` header support.
    """

    def __init__(self, server_hostname, *args, **kwargs):
        self._server_hostname = server_hostname
        super().__init__(*args, **kwargs)

    def init_poolmanager(self, *args, **kwargs):
        kwargs["server_hostname"] = self._server_hostname
        super().init_poolmanager(*args, **kwargs)


def build_session(host, protocol, sni):
    """Create a session, mounting an SNI-overriding adapter when needed."""
    session = requests.Session()
    # Don't let environment proxies / netrc surprise the user; we pass proxies
    # explicitly per request.
    session.trust_env = False
    if protocol == "https" and sni and sni != host:
        session.mount("https://", _SNIAdapter(sni))
    return session


def send(header, request):
    """Send the parsed request via `requests` and return the Response."""
    method, target, req_headers, body = parse_http_request(request)
    host, port, protocol, sni, proxies = resolve_target(header, req_headers)

    url = "%s://%s:%d%s" % (protocol, host, port, target)

    # `requests` manages these itself; passing them through causes conflicts.
    headers = {
        k: v
        for (k, v) in req_headers
        if k.lower() not in ("content-length",)
    }

    data = body.encode("utf-8") if body.strip() else None

    session = build_session(host, protocol, sni)
    return session.request(
        method,
        url,
        headers=headers,
        data=data,
        proxies=proxies,
        verify=False,
        allow_redirects=False,
        timeout=TIMEOUT,
    )


def format_response(resp):
    """Reconstruct a raw HTTP response with a fully-decoded body."""
    version = {10: "1.0", 11: "1.1"}.get(getattr(resp.raw, "version", 11), "1.1")
    reason = resp.reason or ""
    status_line = "HTTP/%s %d %s" % (version, resp.status_code, reason)

    out_lines = [status_line.rstrip()]
    # Use the raw urllib3 header dict so duplicate headers (e.g. Set-Cookie)
    # are preserved rather than comma-folded.
    raw_headers = getattr(resp.raw, "headers", None) or resp.headers
    for key, value in raw_headers.items():
        if key.lower() in _DROPPED_RESPONSE_HEADERS:
            continue
        out_lines.append("%s: %s" % (key, value))

    # `resp.content` is the decoded body; advertise its real length.
    body = resp.content
    out_lines.append("Content-Length: %d" % len(body))

    blob = ("\r\n".join(out_lines) + "\r\n\r\n").encode("iso-8859-1")
    return blob + body


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
        resp = send(header, request)
    except ValueError as exc:
        sys.stderr.write("%s\n" % exc)
        return 1
    except requests.exceptions.RequestException as exc:
        sys.stderr.write("connection error: %s\n" % exc)
        return 1

    sys.stdout.buffer.write(format_response(resp))
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
