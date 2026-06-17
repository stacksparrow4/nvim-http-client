# nvim-http-client

A small Neovim plugin that sends HTTP requests written in a buffer and shows
the raw response in a split. A Lua frontend drives a self-contained Python
helper (a PEP 723 `uv run` script) that performs the actual HTTP I/O.

You write `req` documents: a raw HTTP request, optionally preceded by a `---`
delimited header block describing the connection target.

## Configuration

`setup()` is optional. Defaults:

```lua
require("nvim-http-client").setup({
  -- Command used to run the (self-contained uv) Python helper.
  runner = { "uv", "run" },
  -- How to open the response buffer: "vsplit", "split" or "tab".
  open = "vsplit",
})
```

## Usage

1. Open or create a `*.req` file and write a request (see format below).
2. Run `:SendRequest`. The buffer is saved, sent, and the raw response is
   written next to it as `<name>.req.resp` and opened in a split.

Opening a `*.req` file automatically opens its existing `*.resp` companion (if
present) in a split, keeping focus on the request.

### Commands

| Command        | Mode   | Description                                                        |
| -------------- | ------ | ------------------------------------------------------------------ |
| `:SendRequest` | Normal | Send the current `*.req` buffer and show the response.             |
| `:Convert`     | Visual | Open encode/decode panes for the Visual selection (see below).     |

## `req` document format

```
---
host: example.com
port: 443
protocol: https
sni: example.com
proxy: http://localhost:8080
format_json: false
---
GET / HTTP/1.1
Host: example.com

```

The leading `---` header block is optional; the remainder is treated as a raw
HTTP request. If the header is omitted, host/port are inferred from the
`Host:` request header and the protocol (default `https`).

### Header keys

| Key           | Default                       | Description                                                                 |
| ------------- | ----------------------------- | --------------------------------------------------------------------------- |
| `host`        | from `Host:` request header   | Connection host.                                                            |
| `port`        | `443` (https) / `80` (http)   | Connection port (1–65535).                                                  |
| `protocol`    | `https`                       | `http` or `https`.                                                          |
| `sni`         | `host`                        | TLS server name (lets the TLS SNI differ from the URL host); https only.    |
| `proxy`       | none                          | Proxy URL — see [Proxies](#proxies).                                        |
| `format_json` | `false`                       | Pretty-print the response body as JSON (left untouched if it doesn't parse). |

TLS certificate verification is disabled, so self-signed / mismatched certs
work out of the box. Response bodies are fully decoded (`gzip`, `deflate`,
`br`, `zstd`) and redirects are not followed.

### Proxies

Set `proxy:` in the header to route the request through a proxy. Environment
proxy variables (`HTTP_PROXY` etc.) and netrc are ignored — only this key is
used.

Supported schemes and forms:

```
proxy: http://localhost:8080      # HTTP proxy (e.g. Burp, mitmproxy, ZAP)
proxy: socks5://localhost:1080    # SOCKS5, DNS resolved locally
proxy: socks5h://localhost:1080   # SOCKS5, DNS resolved by the proxy
proxy: localhost:8080             # scheme defaults to http
```

If the port is omitted it defaults to `8080` for `http` and `1080` for SOCKS5.
Proxy authentication (`user:pass@host`) is not supported.

## Convert (encode/decode)

Select text in a `.req`/`.resp` buffer in Visual mode and run `:Convert`. The
selection is captured once into a tracked, highlighted region. Two scratch
panes open below the target:

1. **workflow pane** — line 1 is the encode pipeline, line 2 the decode
   pipeline. Auto-generated: `base64 -w 0` / `base64 -d` when the selection is
   ≥ 8 bytes and decodes cleanly as base64, otherwise `urlenc` / `urlenc -d`.
2. **output pane** — the decoded region.

Saving (`:w`) each pane runs the pipelines via `bash -c`:

- **output pane** → re-encodes through the saved encode pipeline and replaces
  the region.
- **workflow pane** → acts on whichever line changed: encode-line only
  re-encodes (output → region); decode-line only re-decodes (region → output);
  both changed does nothing (ambiguous).

Closing any pane tears the whole session down. Re-running `:Convert` starts a
fresh session.

## Testing the Python helper directly

```bash
printf '---\nhost: example.com\nprotocol: https\n---\nGET / HTTP/1.1\nHost: example.com\n' \
  | python3 python/send_request.py
```
