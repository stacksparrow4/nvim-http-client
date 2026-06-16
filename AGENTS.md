# AGENTS.md

## Overview

`nvim-http-client` is a small Neovim plugin (a git submodule, typically loaded
from a package manager) that sends HTTP requests written in a buffer and shows
the raw response in a split. It pairs a Lua frontend with a dependency-free
Python helper that performs the actual socket I/O.

The plugin works with `req` documents: a raw HTTP request, optionally preceded
by a `---` delimited YAML-style header block describing the connection target.

## Repository layout

```
plugin/nvim-http-client.lua Entry point: registers the :SendRequest command,
                            the `req` filetype (*.req, *.resp), a
                            BufWritePost autocmd to re-apply syntax, and a
                            BufReadPost autocmd to auto-open an existing
                            *.resp alongside a *.req file.
lua/nvim-http-client/init.lua
                            Core module: M.setup/config, syntax highlighting
                            (apply_syntax), request dispatch (send_request),
                            and response buffer handling.
lua/nvim-http-client/convert.lua
                            :Convert feature: encode/decode of a captured
                            selection region in two stacked scratch panes
                            (workflow pipelines + decoded output).
python/send_request.py      stdin->stdout HTTP client. Parses the `---` header,
                            opens a (optionally TLS) socket, sends the request,
                            reads the response. Stdlib only (socket, ssl, sys).
syntax/req.vim              Syntax loader; defers to require("nvim-http-client").apply_syntax().
```

## How it works (data flow)

1. User runs `:SendRequest` in a saved `req` buffer.
2. `send_request()` reads the whole buffer and pipes it to
   `python/send_request.py` via `vim.fn.system`.
3. The Python helper parses an optional `---` header (host, port, protocol,
   sni), builds CRLF-terminated request bytes, connects, and writes the raw
   response to stdout.
4. Lua strips CRs, writes the response next to the request as `<name>.resp`,
   and opens it in a split (`vsplit` / `split` / `tab`, per `config.open`).

## req document format

```
---
host: example.com
port: 443
protocol: https
sni: example.com
format_json: false
---
GET / HTTP/1.1
Host: example.com

```

The header block is optional; if omitted, host/port are inferred from the
`Host:` request header and the protocol (default `https`).

The `format_json` key (default `false`) pretty-prints the response body as
JSON before writing the response file; if the body is not valid JSON the
body is left untouched.

## Convert (encode/decode) feature

Select text in a `.req`/`.resp` buffer (the "target") in Visual mode and run
`:Convert`. The selection is captured *once* into a fixed region (tracked with
an extmark and highlighted); Visual mode is not used afterwards. Two scratch
panes open *below* the target (split downwards):

1. workflow pane - line 1 is the encode bash pipeline, line 2 the decode
   pipeline. Auto-generated from the selection: `base64 -w 0` / `base64 -d`
   when the selection is >= 8 bytes and decodes cleanly as base64, otherwise
   `urlenc` / `urlenc -d`.
2. output pane - the decoded region.

The captured region cannot be retargeted without running `:Convert` again,
which tears down the previous session and starts a fresh one. The output pane
regenerates on startup and after write-back. Saving the output pane (`:w`)
pipes it through the *saved* encode pipeline and replaces the region with the
result (the extmark tracks the new text).

Saving the workflow pane (`:w`) acts on which line changed relative to the
previously applied pipelines:

* encode line changed only -> re-encode (decoded pane -> main pane)
* decode line changed only -> re-decode (main pane -> decoded pane)
* both changed             -> do nothing (ambiguous direction)

Closing any pane tears the whole session down. Pipelines run via `bash -c`
(resolved from `PATH`); the panes are `acwrite` scratch buffers whose saves
are intercepted with `BufWriteCmd`.

## Testing

There is no automated test suite. Verify changes manually:

```bash
# Exercise the Python helper directly (no Neovim needed):
printf '---\nhost: example.com\nprotocol: https\n---\nGET / HTTP/1.1\nHost: example.com\n' \
  | python3 python/send_request.py
```

Syntax-check the Python helper before committing:

```bash
python3 -m py_compile python/send_request.py
```

For Lua/plugin changes, load the plugin in Neovim, open a `*.req` file, and run
`:SendRequest` to confirm the response buffer opens and highlighting applies.
