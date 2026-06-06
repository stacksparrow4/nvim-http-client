local M = {}

-- Directory containing this Lua file.
local function script_dir()
  local source = debug.getinfo(1, "S").source:sub(2)
  return source:match("(.*[/\\])") or "./"
end

-- Absolute path to the Python helper (lua/sendrequest/ -> ../../python/).
local function python_helper()
  return script_dir() .. ".." .. "/.." .. "/python/send_request.py"
end

M.config = {
  python = "python3",
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

-- Find an existing window in the current tab that is already showing a
-- response (*.resp) file, so we can reuse it instead of opening a new split.
local function existing_response_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    if name:match("%.resp$") then
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
  local bufnr = vim.fn.bufnr(path)
  local win = (bufnr ~= -1) and vim.fn.bufwinid(bufnr) or -1

  if win == -1 then
    win = existing_response_win()
  end

  if win ~= -1 then
    -- Reuse an existing response window: focus it and load the new file.
    vim.api.nvim_set_current_win(win)
    vim.cmd("edit " .. escaped)
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

-- When a .req file is opened, open its corresponding .resp file (if any) in a
-- split, leaving focus on the request buffer.
function M.open_existing_response(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local reqpath = vim.api.nvim_buf_get_name(buf)
  if reqpath == "" or not reqpath:match("%.req$") then
    return
  end
  local resppath = vim.fn.fnamemodify(reqpath, ":r") .. ".resp"
  if vim.fn.filereadable(resppath) == 0 then
    return
  end
  local reqwin = vim.fn.bufwinid(buf)
  open_response_file(resppath)
  -- Keep focus on the request buffer.
  if reqwin ~= -1 then
    vim.api.nvim_set_current_win(reqwin)
  end
end

function M.send_request()
  local reqpath = vim.api.nvim_buf_get_name(0)
  if reqpath == "" then
    vim.notify("SendRequest: save the request to a file first", vim.log.levels.ERROR)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local content = table.concat(lines, "\n")

  local helper = python_helper()
  if vim.fn.filereadable(helper) == 0 then
    vim.notify("SendRequest: python helper not found at " .. helper, vim.log.levels.ERROR)
    return
  end

  local result = vim.fn.system({ M.config.python, helper }, content)

  if vim.v.shell_error ~= 0 then
    vim.notify("SendRequest failed:\n" .. result, vim.log.levels.ERROR)
    return
  end

  -- HTTP responses use CRLF; strip CR for clean display.
  result = result:gsub("\r", "")
  local out_lines = vim.split(result, "\n", { plain = true })

  -- Write the response next to the request, with a .resp extension.
  local resppath = vim.fn.fnamemodify(reqpath, ":r") .. ".resp"
  local ok, err = pcall(vim.fn.writefile, out_lines, resppath)
  if not ok then
    vim.notify("SendRequest: failed to write " .. resppath .. ": " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  open_response_file(resppath)
end

return M
