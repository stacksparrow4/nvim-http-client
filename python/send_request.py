#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = [
#     "httpx[http2,socks]",
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
    proxy: http://localhost:8080   # or socks5://localhost:1080
    format_json: false
    ---
    GET / HTTP/2
    Host: example.com
    ...

The leading `---` delimited header is optional. The remainder of the
document is treated as a raw HTTP request which is sent with `httpx`.
The raw HTTP response is written to stdout, with the body fully decoded
(content encodings such as gzip, deflate, br and zstd are transparently
decompressed by httpx, given the dependencies declared in the inline
script metadata above).

The HTTP version is taken from the request line: `HTTP/2` forces HTTP/2
and `HTTP/1.1` (or `HTTP/1.0`) forces HTTP/1.1. If the request line omits
the version, HTTP/2 is negotiated over TLS via ALPN with a fallback to
HTTP/1.1. The response status line reports the protocol version that was
actually used (`HTTP/1.1`, `HTTP/2`, ...).

The response is prefixed with its own `---` delimited frontmatter block
carrying a single `time` key: the elapsed request time in milliseconds.

This file is a self-contained uv script: the dependencies in the `/// script`
block are installed automatically when run via `uv run`.
"""

import json
import sys
import time

import httpx

TIMEOUT = 15

# Keys recognized inside the `---` delimited header block.
VALID_HEADER_KEYS = (
    "host",
    "port",
    "protocol",
    "sni",
    "proxy",
    "format_json",
)

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
    """Parse a raw HTTP request into (method, target, version, headers, body).

    `headers` is a list of (name, value) pairs preserving order. `target` is
    the request-target from the request line (path + query). `version` is the
    HTTP version token from the request line (e.g. "HTTP/2"), or None if the
    request line omits it.

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
    version = parts[2] if len(parts) > 2 else None

    headers = []
    for line in head_lines[1:]:
        if line.strip() == "":
            continue
        if ":" not in line:
            raise ValueError("invalid request header line: %r" % line)
        key, value = line.split(":", 1)
        headers.append((key.strip(), value.strip()))

    return method, target, version, headers, body


def get_header(headers, name):
    """Case-insensitive lookup in a list of (name, value) header pairs."""
    name = name.lower()
    for key, value in headers:
        if key.lower() == name:
            return value
    return None


def resolve_target(header, request_headers):
    """Compute (host, port, protocol, sni, proxy) from header + defaults."""
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
    proxy = parse_proxy(header.get("proxy"))
    return host, port, protocol, sni, proxy


def parse_http_version(version):
    """Map a request-line HTTP version token to (enable_http2, force_http2).

    ``HTTP/2`` (or ``HTTP/2.0``) forces HTTP/2, ``HTTP/1.1``/``HTTP/1.0``
    force HTTP/1.1, and a missing version negotiates HTTP/2 via ALPN with a
    fallback to HTTP/1.1.
    """
    if version is None:
        return True, False
    raw = version.strip().lower()
    if raw in ("http/1.1", "http/1.0"):
        return False, False
    if raw in ("http/2", "http/2.0"):
        return True, True
    raise ValueError(
        "unsupported HTTP version in request line: %r "
        "(expected HTTP/1.0, HTTP/1.1 or HTTP/2)" % version
    )


def parse_bool(value):
    """Parse a header value into a boolean.

    Accepts true/false, yes/no, 1/0, on/off (case-insensitive).
    """
    raw = value.strip().lower()
    if raw in ("true", "yes", "1", "on"):
        return True
    if raw in ("false", "no", "0", "off"):
        return False
    raise ValueError("expected a boolean, got %r" % value)


# Recognized proxy schemes and their default ports.
_PROXY_SCHEMES = {
    "http": 8080,
    "socks5": 1080,
    "socks5h": 1080,
}


def parse_proxy(value):
    """Parse a proxy URL into an httpx proxy URL string, or None.

    Accepts forms like ``http://localhost:8080``, ``socks5://localhost:1080``
    or ``localhost:8080`` (defaulting to the ``http`` scheme). For SOCKS5,
    ``socks5h`` routes DNS resolution through the proxy.
    """
    if not value:
        return None
    raw = value.strip()
    scheme = "http"
    if "://" in raw:
        scheme, raw = raw.split("://", 1)
        scheme = scheme.lower() or "http"
        if scheme not in _PROXY_SCHEMES:
            raise ValueError(
                "proxy scheme must be one of %s, got %r"
                % (", ".join(sorted(_PROXY_SCHEMES)), scheme)
            )
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
        proxy_host, proxy_port = raw, _PROXY_SCHEMES[scheme]
    proxy_host = proxy_host.strip("[]")
    if not proxy_host:
        raise ValueError("proxy must include a host")
    if not 0 < proxy_port < 65536:
        raise ValueError("proxy port must be between 1 and 65535, got %d" % proxy_port)
    return "%s://%s:%d" % (scheme, proxy_host, proxy_port)


def send(header, request):
    """Send the parsed request via `httpx`.

    Returns (Response, elapsed_ms) where elapsed_ms is the wall-clock time
    taken to send the request and fully receive/decode the response body.
    """
    method, target, version, req_headers, body = parse_http_request(request)
    host, port, protocol, sni, proxy = resolve_target(header, req_headers)
    enable_http2, force_http2 = parse_http_version(version)

    url = "%s://%s:%d%s" % (protocol, host, port, target)

    # `httpx` manages Content-Length itself; passing it through causes
    # conflicts. Other headers are forwarded verbatim, preserving order.
    headers = [(k, v) for (k, v) in req_headers if k.lower() != "content-length"]

    data = body.encode("utf-8") if body.strip() else None

    # Override the TLS SNI when it differs from the connection host. httpx
    # forwards the `sni_hostname` request extension down to httpcore's TLS
    # handshake, mirroring the original `sni` header support.
    extensions = {}
    if protocol == "https" and sni and sni != host:
        extensions["sni_hostname"] = sni

    client = httpx.Client(
        http2=enable_http2,
        verify=False,
        # Don't let environment proxies / netrc surprise the user; we pass
        # the proxy explicitly.
        trust_env=False,
        proxy=proxy,
        follow_redirects=False,
        timeout=TIMEOUT,
    )
    try:
        start = time.perf_counter()
        req = client.build_request(
            method, url, headers=headers, content=data, extensions=extensions
        )
        resp = client.send(req)
        # Force the body to be fully received/decoded so the timing covers
        # the whole response, not just the headers.
        resp.read()
        elapsed_ms = (time.perf_counter() - start) * 1000.0
    finally:
        client.close()

    if force_http2 and resp.http_version != "HTTP/2":
        raise ValueError(
            "requested HTTP/2 but the server negotiated %s" % resp.http_version
        )

    return resp, elapsed_ms


def format_response(resp, elapsed_ms, format_json=False):
    """Reconstruct a raw HTTP response with a fully-decoded body.

    The output is prefixed with a `---` delimited frontmatter block carrying
    a single `time` key (elapsed request time in milliseconds).

    When `format_json` is true, attempt to pretty-print the body as JSON,
    leaving it untouched if it does not parse cleanly.
    """
    frontmatter = "---\r\ntime: %d\r\n---\r\n" % round(elapsed_ms)
    # `resp.http_version` already includes the "HTTP/" prefix and reports the
    # protocol version actually negotiated (e.g. "HTTP/1.1" or "HTTP/2").
    reason = resp.reason_phrase or ""
    status_line = "%s %d %s" % (resp.http_version, resp.status_code, reason)

    out_lines = [status_line.rstrip()]
    # Use the raw header list so duplicate headers (e.g. Set-Cookie) are
    # preserved rather than comma-folded, and original casing is kept.
    for raw_key, raw_value in resp.headers.raw:
        name = raw_key.decode("iso-8859-1")
        if name.lower() in _DROPPED_RESPONSE_HEADERS:
            continue
        out_lines.append("%s: %s" % (name, raw_value.decode("iso-8859-1")))

    # `resp.content` is the decoded body; advertise its real length.
    body = resp.content
    if format_json:
        try:
            parsed = json.loads(body)
            body = json.dumps(parsed, indent=2, ensure_ascii=False).encode("utf-8")
        except (ValueError, UnicodeDecodeError):
            # Leave the body as-is on any JSON/decoding error.
            pass
    out_lines.append("Content-Length: %d" % len(body))

    blob = (frontmatter + "\r\n".join(out_lines) + "\r\n\r\n").encode("iso-8859-1")
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
        resp, elapsed_ms = send(header, request)
    except ValueError as exc:
        sys.stderr.write("%s\n" % exc)
        return 1
    except httpx.HTTPError as exc:
        sys.stderr.write("connection error: %s\n" % exc)
        return 1

    try:
        format_json = parse_bool(header.get("format_json", "false"))
    except ValueError as exc:
        sys.stderr.write("format_json: %s\n" % exc)
        return 1

    sys.stdout.buffer.write(
        format_response(resp, elapsed_ms, format_json=format_json)
    )
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
