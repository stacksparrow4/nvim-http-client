local M = {}

-- Directory containing this Lua file.
local function script_dir()
  local source = debug.getinfo(1, "S").source:sub(2)
  return source:match("(.*[/\\])") or "./"
end

-- Absolute path to the Python helper (lua/nvim-http-client/ -> ../../python/).
local function python_helper()
  return script_dir() .. ".." .. "/.." .. "/python/send_request.py"
end

M.config = {
  -- Command used to run the (self-contained uv) Python helper. The helper
  -- declares its own dependencies inline (PEP 723), which `uv run` installs
  -- into an ephemeral environment on first use.
  runner = { "uv", "run" },
  -- How to open the response buffer: "vsplit", "split" or "tab".
  open = "vsplit",
}

function M.setup(opts)
  M.config = vim.tbl_extend("force", M.config, opts or {})
end

-- ---------------------------------------------------------------------------
-- Syntax highlighting
-- ---------------------------------------------------------------------------

-- Maps a substring of a Content-Type value to the syntax/<ft>.vim to embed.
-- Order matters: the first matching pattern wins.
local CONTENT_TYPE_MAP = {
  { pat = "json", ft = "json" },
  { pat = "xhtml", ft = "html" },
  { pat = "html", ft = "html" },
  { pat = "javascript", ft = "javascript" },
  { pat = "ecmascript", ft = "javascript" },
  { pat = "typescript", ft = "typescript" },
  { pat = "css", ft = "css" },
  { pat = "xml", ft = "xml" },
  { pat = "yaml", ft = "yaml" },
  { pat = "markdown", ft = "markdown" },
  { pat = "csv", ft = "csv" },
  { pat = "graphql", ft = "graphql" },
}

-- Scan the header section of the buffer for a Content-Type and return the
-- filetype whose syntax should be embedded in the body, or nil.
local function detect_body_ft(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, line in ipairs(lines) do
    -- The blank line terminates the header section / starts the body.
    if line == "" then
      break
    end
    local key, value = line:match("^([%w%-]+)%s*:%s*(.+)$")
    if key and key:lower() == "content-type" then
      value = value:gsub(";.*", ""):lower():gsub("%s+", "")
      for _, entry in ipairs(CONTENT_TYPE_MAP) do
        if value:find(entry.pat, 1, true) then
          return entry.ft
        end
      end
      return nil
    end
  end
  return nil
end

-- Apply HTTP request/response highlighting to a buffer. The optional `---`
-- front matter is highlighted as YAML and the body is highlighted according
-- to the Content-Type header (HTML, JSON, JavaScript, ...).
function M.apply_syntax(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local body_ft = detect_body_ft(buf)

  vim.api.nvim_buf_call(buf, function()
    vim.cmd("syntax clear")
    vim.cmd("unlet! b:current_syntax")
    -- Parse from the top so multi-line body regions are tracked correctly.
    vim.cmd("syntax sync fromstart")

    -- YAML-style `---` front matter (request format only; matches at top).
    pcall(vim.cmd, "syntax include @reqYaml syntax/yaml.vim")
    vim.cmd(
      [[syntax region reqFrontmatter matchgroup=reqDelimiter ]]
        .. [[start=/\%^---$/ end=/^---$/ keepend contains=@reqYaml]]
    )
    vim.cmd("unlet! b:current_syntax")

    -- Request line, e.g. "GET / HTTP/1.1".
    vim.cmd(
      [[syntax match httpRequestLine /\v^\u+ +\S+ +HTTP\/\d+(\.\d+)?\s*$/ ]]
        .. [[contains=httpMethod,httpVersion]]
    )
    vim.cmd(
      "syntax keyword httpMethod contained "
        .. "GET POST PUT DELETE PATCH HEAD OPTIONS TRACE CONNECT"
    )
    -- Status line, e.g. "HTTP/1.1 200 OK".
    vim.cmd(
      [[syntax match httpStatusLine /\v^HTTP\/\d+(\.\d+)? +\d+.*$/ ]]
        .. [[contains=httpVersion,httpStatusCode]]
    )
    vim.cmd([[syntax match httpVersion /\vHTTP\/\d+(\.\d+)?/ contained]])
    vim.cmd([[syntax match httpStatusCode /\v<\d{3}>/ contained]])

    -- Header field names, e.g. "Content-Type:".
    vim.cmd([[syntax match httpHeaderName /\v^[A-Za-z][A-Za-z0-9-]*\ze:/]])

    -- Body, highlighted via the detected content type.
    if body_ft then
      local ok = pcall(vim.cmd, "syntax include @httpBody syntax/" .. body_ft .. ".vim")
      if ok then
        vim.cmd([[syntax region httpBody start=/\v^\s*$/ end=/\%$/ keepend contains=@httpBody]])
      end
      vim.cmd("unlet! b:current_syntax")
    end

    -- Default highlight links.
    vim.cmd("highlight default link httpRequestLine Function")
    vim.cmd("highlight default link httpStatusLine Function")
    vim.cmd("highlight default link httpMethod Keyword")
    vim.cmd("highlight default link httpVersion Constant")
    vim.cmd("highlight default link httpStatusCode Number")
    vim.cmd("highlight default link httpHeaderName Identifier")
    vim.cmd("highlight default link reqDelimiter Delimiter")

    vim.b.current_syntax = "http"
  end)
end

-- ---------------------------------------------------------------------------
-- Response buffer handling
-- ---------------------------------------------------------------------------

-- Find a window in the current tab showing exactly `path`, or -1. (Unlike
-- vim.fn.bufnr, which matches buffer names as a substring/pattern and would
-- e.g. match "foo.req.resp" when looking for "foo.req".)
local function win_showing(path)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == path then
      return win
    end
  end
  return -1
end

-- Find an existing window in the current tab that is already showing a
-- response (*.resp or *.resp.many) file, so we can reuse it instead of
-- opening a new split.
local function existing_response_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    if name:match("%.resp$") or name:match("%.resp%.many$") then
      return win
    end
  end
  return -1
end

-- Open the response file in a window and (re)load it from disk. Reuses the
-- window already showing the file if present, otherwise reuses any window
-- already showing a response file, falling back to a new split.
local function open_response_file(path)
  local escaped = vim.fn.fnameescape(path)
  local win = win_showing(path)

  if win == -1 then
    win = existing_response_win()
  end

  if win ~= -1 then
    -- Reuse an existing response window: focus it and load the new file.
    -- Force (edit!) so a dirty/stale response buffer is replaced cleanly.
    vim.api.nvim_set_current_win(win)
    vim.cmd("edit! " .. escaped)
  elseif M.config.open == "split" then
    vim.cmd("split " .. escaped)
  elseif M.config.open == "tab" then
    vim.cmd("tabedit " .. escaped)
  else
    vim.cmd("vsplit " .. escaped)
  end

  -- Reload from disk so a reused buffer shows the new response.
  vim.cmd("edit!")
end

-- Build the response file path for a given request path:
-- <dir>/<name>.req -> <dir>/<name>.req.resp
local function response_path_for(reqpath)
  local dir = vim.fn.fnamemodify(reqpath, ":h")
  local name = vim.fn.fnamemodify(reqpath, ":t")
  return dir .. "/" .. name .. ".resp"
end

-- Build the aggregate response file path for SendRequestMany:
-- <dir>/<name>.req -> <dir>/<name>.req.resp.many
local function many_response_path_for(reqpath)
  return response_path_for(reqpath) .. ".many"
end

-- Build the request file path for a given response path:
-- <dir>/<name>.req.resp -> <dir>/<name>.req
local function request_path_for(resppath)
  return (resppath:gsub("%.resp$", ""))
end

-- Find an existing window in the current tab already showing a request (*.req)
-- file, so we can reuse it instead of opening a new split.
local function existing_request_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    if name:match("%.req$") then
      return win
    end
  end
  return -1
end

-- Open the request file in a window to the left (mirroring how the response is
-- opened to the right). Reuses the window already showing the file if present,
-- otherwise reuses any window already showing a request file, falling back to
-- a new split.
local function open_request_file(path)
  local escaped = vim.fn.fnameescape(path)
  local win = win_showing(path)

  if win == -1 then
    win = existing_request_win()
  end

  if win ~= -1 then
    vim.api.nvim_set_current_win(win)
    vim.cmd("edit! " .. escaped)
  elseif M.config.open == "split" then
    vim.cmd("leftabove split " .. escaped)
  elseif M.config.open == "tab" then
    vim.cmd("tabedit " .. escaped)
  else
    vim.cmd("leftabove vsplit " .. escaped)
  end
end

-- When a .req file is opened, open its corresponding .resp file (if any) in a
-- split, leaving focus on the request buffer.
-- Re-entrancy guard: opening the counterpart file fires nested BufReadPost
-- autocmds (request <-> response), which would otherwise ping-pong forever.
local auto_opening = false

local function with_auto_open_guard(fn)
  if auto_opening then
    return
  end
  auto_opening = true
  local ok, err = pcall(fn)
  auto_opening = false
  if not ok then
    error(err)
  end
end

function M.open_existing_response(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local reqpath = vim.api.nvim_buf_get_name(buf)
  if reqpath == "" or not reqpath:match("%.req$") then
    return
  end
  local resppath = response_path_for(reqpath)
  if vim.fn.filereadable(resppath) == 0 then
    return
  end
  with_auto_open_guard(function()
    local reqwin = vim.fn.bufwinid(buf)
    open_response_file(resppath)
    -- Keep focus on the request buffer.
    if reqwin ~= -1 then
      vim.api.nvim_set_current_win(reqwin)
    end
  end)
end

-- When a .req.resp file is opened, open its corresponding .req file (if any)
-- in a split to the left, leaving focus on the response buffer.
function M.open_existing_request(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local resppath = vim.api.nvim_buf_get_name(buf)
  if resppath == "" or not resppath:match("%.req%.resp$") then
    return
  end
  local reqpath = request_path_for(resppath)
  if vim.fn.filereadable(reqpath) == 0 then
    return
  end
  with_auto_open_guard(function()
    local respwin = vim.fn.bufwinid(buf)
    open_request_file(reqpath)
    -- Keep focus on the response buffer.
    if respwin ~= -1 then
      vim.api.nvim_set_current_win(respwin)
    end
  end)
end

-- Parse the buffer of a .req document and build the request URL in the form
-- scheme://<Host header>/<path including query>. Returns the URL or nil plus
-- an error message.
local function build_url(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local protocol
  local idx = 1
  -- Optional `---` front matter: scan it for an explicit protocol.
  if lines[1] == "---" then
    idx = 2
    while idx <= #lines and lines[idx] ~= "---" do
      local key, value = lines[idx]:match("^([%w_]+)%s*:%s*(.+)$")
      if key and key:lower() == "protocol" then
        protocol = value:gsub("%s+", ""):lower()
      end
      idx = idx + 1
    end
    idx = idx + 1 -- skip the closing `---`
  end

  -- The request line, e.g. "GET /path?q=1 HTTP/1.1".
  local path
  while idx <= #lines do
    if lines[idx] ~= "" then
      path = lines[idx]:match("^%u+%s+(%S+)%s+HTTP/%d")
      break
    end
    idx = idx + 1
  end
  if not path then
    return nil, "could not find the request line"
  end
  idx = idx + 1

  -- The Host header (terminated by the blank line before the body).
  local host
  while idx <= #lines and lines[idx] ~= "" do
    local value = lines[idx]:match("^[Hh][Oo][Ss][Tt]%s*:%s*(.+)$")
    if value then
      host = value:gsub("%s+$", "")
      break
    end
    idx = idx + 1
  end
  if not host then
    return nil, "no Host header found"
  end

  protocol = protocol or "https"
  if not path:match("^/") then
    path = "/" .. path
  end

  return protocol .. "://" .. host .. path
end

function M.copy_url()
  local reqpath = vim.api.nvim_buf_get_name(0)
  if not reqpath:match("%.req$") then
    vim.notify("CopyURL: not a .req file: " .. reqpath, vim.log.levels.ERROR)
    return
  end

  local url, err = build_url(0)
  if not url then
    vim.notify("CopyURL: " .. err, vim.log.levels.ERROR)
    return
  end

  vim.fn.setreg("+", url)
  vim.fn.setreg('"', url)
  vim.notify("CopyURL: " .. url)
end

-- Validate the current buffer as a saved .req document and gather everything
-- needed to dispatch it: the request file path, its byte content, and the
-- helper command. Returns (reqpath, content, cmd) or nil after notifying the
-- user of the failure. `cmdname` labels error messages.
local function prepare_request(cmdname)
  local reqpath = vim.api.nvim_buf_get_name(0)
  if reqpath == "" then
    vim.notify(cmdname .. ": save the request to a file first", vim.log.levels.ERROR)
    return nil
  end

  -- Sanity check: only operate on .req files.
  if not reqpath:match("%.req$") then
    vim.notify(cmdname .. ": not a .req file: " .. reqpath, vim.log.levels.ERROR)
    return nil
  end

  -- Send the request exactly as it exists on disk so the body (notably
  -- multipart/form-data, whose boundary delimiters must be CRLF) is preserved
  -- byte-for-byte. Save first if the buffer has unsaved changes.
  if vim.bo.modified then
    local saved = pcall(function()
      vim.cmd("silent keepjumps write")
    end)
    if not saved then
      vim.notify(cmdname .. ": failed to save buffer before sending", vim.log.levels.ERROR)
      return nil
    end
  end

  local rf = io.open(reqpath, "rb")
  if not rf then
    vim.notify(cmdname .. ": cannot read " .. reqpath, vim.log.levels.ERROR)
    return nil
  end
  local content = rf:read("*a")
  rf:close()

  local helper = python_helper()
  if vim.fn.filereadable(helper) == 0 then
    vim.notify(cmdname .. ": python helper not found at " .. helper, vim.log.levels.ERROR)
    return nil
  end

  local cmd = vim.deepcopy(M.config.runner)
  table.insert(cmd, helper)
  return reqpath, content, cmd
end

-- Run the helper once for `content`. Returns the normalized response text on
-- success, or nil plus the helper's error output. Only CRs in the header
-- block (HTTP headers are always CRLF) are normalized so the headers display
-- cleanly; the body is preserved verbatim.
local function run_helper(cmd, content)
  local result = vim.fn.system(cmd, content)
  if vim.v.shell_error ~= 0 then
    return nil, result
  end
  local sep = result:find("\r\n\r\n", 1, true)
  if sep then
    local head = result:sub(1, sep - 1):gsub("\r", "")
    return head .. "\n\n" .. result:sub(sep + 4)
  end
  return (result:gsub("\r", ""))
end

-- Write `text` to `path` (binary). Returns true on success, false after
-- notifying the user.
local function write_file(cmdname, path, text)
  local wf, werr = io.open(path, "wb")
  if not wf then
    vim.notify(cmdname .. ": failed to write " .. path .. ": " .. tostring(werr), vim.log.levels.ERROR)
    return false
  end
  wf:write(text)
  wf:close()
  return true
end

function M.send_request()
  local reqpath, content, cmd = prepare_request("SendRequest")
  if not reqpath then
    return
  end

  local out, err = run_helper(cmd, content)
  if not out then
    vim.notify("SendRequest failed:\n" .. err, vim.log.levels.ERROR)
    return
  end

  local resppath = response_path_for(reqpath)
  if not write_file("SendRequest", resppath, out) then
    return
  end

  open_response_file(resppath)
end

function M.send_request_many(arg)
  local count = tonumber(arg)
  if not count or count < 1 or count ~= math.floor(count) then
    vim.notify("SendRequestMany: argument must be a positive integer", vim.log.levels.ERROR)
    return
  end

  local reqpath, content, cmd = prepare_request("SendRequestMany")
  if not reqpath then
    return
  end

  local sections = {}
  local total = 0
  for i = 1, count do
    local out, err = run_helper(cmd, content)
    if not out then
      vim.notify(
        string.format("SendRequestMany failed on request %d/%d:\n%s", i, count, err),
        vim.log.levels.ERROR
      )
      return
    end
    -- The per-response frontmatter carries the elapsed time in milliseconds.
    local t = tonumber(out:match("^%-%-%-\ntime:%s*(%d+)")) or 0
    total = total + t
    if out:sub(-1) ~= "\n" then
      out = out .. "\n"
    end
    table.insert(sections, out)
  end

  local avg = math.floor(total / count + 0.5)
  local parts = {
    string.format("---\navg-time: %d\ntotal-time: %d\nnumber: %d\n---\n", avg, total, count),
  }
  for _, section in ipairs(sections) do
    table.insert(parts, "-----\n")
    table.insert(parts, section)
  end

  local manypath = many_response_path_for(reqpath)
  if not write_file("SendRequestMany", manypath, table.concat(parts)) then
    return
  end

  open_response_file(manypath)
end

return M
