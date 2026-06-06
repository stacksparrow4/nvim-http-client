-- Convert: encode/decode of a captured selection region.
--
-- A user selects text in a request/response buffer ("target") in Visual mode
-- and runs `:Convert`. The selection is captured *once* into an internal
-- region (tracked with an extmark and highlighted); Visual mode is not used
-- afterwards. Two scratch panes open below the target:
--
--   1. workflow pane - two lines: an "encode" bash pipeline and a "decode"
--                      bash pipeline.
--   2. output pane   - the decoded form of the captured region.
--
-- The captured region cannot be retargeted without running `:Convert` again;
-- doing so tears down the previous session and starts a fresh one.
--
-- Saving the output pane (`:w`) pipes its contents through the *saved* encode
-- pipeline and replaces the region with the result (the region tracks the new
-- text). Saving the workflow pane re-applies the pipelines and re-decodes.

local M = {}

-- One active session per target buffer.
local sessions = {}

-- ---------------------------------------------------------------------------
-- Shell helpers
-- ---------------------------------------------------------------------------

-- Run a bash pipeline (resolved from PATH) with `input` on stdin.
local function run_pipeline(pipeline, input)
  return vim.fn.system({ "bash", "-c", pipeline }, input or "")
end

-- The workflow auto-detection: base64 if the selection decodes cleanly and is
-- at least 8 bytes long, otherwise urlenc.
local function default_workflow(text)
  if #text >= 8 then
    run_pipeline("base64 -d", text)
    -- vim.v.shell_error reflects the last :system call (base64 -d here).
    if vim.v.shell_error == 0 then
      return "base64 -w 0", "base64 -d"
    end
  end
  return "urlenc", "urlenc -d"
end

-- ---------------------------------------------------------------------------
-- Region helpers (0-indexed, half-open [start, end) coordinates)
-- ---------------------------------------------------------------------------

-- Order two getpos()-style positions so (l1,c1) <= (l2,c2).
local function normalize(p1, p2)
  local l1, c1 = p1[2], p1[3]
  local l2, c2 = p2[2], p2[3]
  if l1 > l2 or (l1 == l2 and c1 > c2) then
    l1, c1, l2, c2 = l2, c2, l1, c1
  end
  return l1, c1, l2, c2
end

-- Convert a Visual selection (two getpos() positions + type) into half-open
-- 0-indexed bounds: start_row, start_col, end_row, end_col. Columns are
-- clamped to the line's byte length (e.g. `$` reports a huge column).
local function compute_bounds(buf, p1, p2, vtype)
  local l1, c1, l2, c2 = normalize(p1, p2)
  local first = vim.api.nvim_buf_get_lines(buf, l1 - 1, l1, false)[1] or ""
  local last = vim.api.nvim_buf_get_lines(buf, l2 - 1, l2, false)[1] or ""
  local start_col, end_col
  if vtype == "V" then
    -- Linewise: whole lines.
    start_col = 0
    end_col = #last
  else
    c1 = math.min(c1, math.max(#first, 1))
    c2 = math.min(c2, #last)
    start_col = c1 - 1
    end_col = c2 -- inclusive 1-indexed -> exclusive 0-indexed
  end
  if start_col < 0 then
    start_col = 0
  end
  if end_col < 0 then
    end_col = 0
  end
  return l1 - 1, start_col, l2 - 1, end_col
end

local REGION_HL = "Visual"

-- Read the current region bounds from the tracking extmark, or nil if gone.
local function region_bounds(session)
  local m = vim.api.nvim_buf_get_extmark_by_id(
    session.target_buf,
    session.ns,
    session.mark_id,
    { details = true }
  )
  if not m or m[1] == nil then
    return nil
  end
  local d = m[3] or {}
  return m[1], m[2], d.end_row or m[1], d.end_col or m[2]
end

-- Place / update the tracking extmark over the given bounds.
local function set_region(session, srow, scol, erow, ecol)
  session.mark_id = vim.api.nvim_buf_set_extmark(session.target_buf, session.ns, srow, scol, {
    id = session.mark_id,
    end_row = erow,
    end_col = ecol,
    hl_group = REGION_HL,
  })
end

-- The text currently covered by the region.
local function region_text(session)
  local srow, scol, erow, ecol = region_bounds(session)
  if srow == nil then
    return ""
  end
  local ok, lines = pcall(vim.api.nvim_buf_get_text, session.target_buf, srow, scol, erow, ecol, {})
  if not ok then
    return ""
  end
  return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Output (decode) generation
-- ---------------------------------------------------------------------------

-- Pipe the region text through the saved decode pipeline into the output pane.
local function decode_to_output(session)
  if not vim.api.nvim_buf_is_valid(session.output_buf) then
    return
  end
  local result = run_pipeline(session.applied.decode, region_text(session))
  local lines = vim.split(result, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(session.output_buf, 0, -1, false, lines)
  vim.bo[session.output_buf].modified = false
end

-- ---------------------------------------------------------------------------
-- Write-back (encode)
-- ---------------------------------------------------------------------------

-- Pipe the output pane through the saved encode pipeline and replace the
-- region in the target buffer; the region then tracks the new text.
local function on_output_save(session)
  if not vim.api.nvim_buf_is_valid(session.target_buf) then
    return
  end
  local srow, scol, erow, ecol = region_bounds(session)
  if srow == nil then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(session.output_buf, 0, -1, false)
  local result = run_pipeline(session.applied.encode, table.concat(lines, "\n"))
  result = result:gsub("\n$", "") -- drop a single trailing newline
  local repl = vim.split(result, "\n", { plain = true })

  vim.api.nvim_buf_set_text(session.target_buf, srow, scol, erow, ecol, repl)
  vim.bo[session.output_buf].modified = false

  -- Recompute the region bounds to cover exactly the inserted text.
  local new_erow, new_ecol
  if #repl == 1 then
    new_erow, new_ecol = srow, scol + #repl[1]
  else
    new_erow, new_ecol = srow + #repl - 1, #repl[#repl]
  end
  set_region(session, srow, scol, new_erow, new_ecol)

  -- Keep the output in sync with the (re-)encoded region.
  decode_to_output(session)
end

-- ---------------------------------------------------------------------------
-- Workflow save
-- ---------------------------------------------------------------------------

-- Re-read the encode/decode pipelines from the workflow pane and act on what
-- changed relative to the previously applied pipelines:
--   * encode changed only -> re-encode (decoded pane -> main pane)
--   * decode changed only -> re-decode (main pane -> decoded pane)
--   * both changed         -> do nothing (ambiguous direction)
local function on_workflow_save(session)
  local lines = vim.api.nvim_buf_get_lines(session.workflow_buf, 0, -1, false)
  local new_encode = lines[1] or ""
  local new_decode = lines[2] or ""
  vim.bo[session.workflow_buf].modified = false

  local enc_changed = new_encode ~= session.applied.encode
  local dec_changed = new_decode ~= session.applied.decode
  session.applied = { encode = new_encode, decode = new_decode }

  if enc_changed and dec_changed then
    return -- ambiguous: do nothing
  elseif enc_changed then
    on_output_save(session) -- encode: decoded pane -> main pane
  elseif dec_changed then
    decode_to_output(session) -- decode: main pane -> decoded pane
  end
end

-- ---------------------------------------------------------------------------
-- Teardown
-- ---------------------------------------------------------------------------

local function teardown(session)
  if session.closing then
    return
  end
  session.closing = true
  sessions[session.target_buf] = nil
  pcall(vim.api.nvim_del_augroup_by_id, session.augroup)
  if vim.api.nvim_buf_is_valid(session.target_buf) then
    pcall(vim.api.nvim_buf_clear_namespace, session.target_buf, session.ns, 0, -1)
  end
  for _, w in ipairs({ session.workflow_win, session.output_win }) do
    if w and vim.api.nvim_win_is_valid(w) then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  for _, b in ipairs({ session.workflow_buf, session.output_buf }) do
    if b and vim.api.nvim_buf_is_valid(b) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
end

-- ---------------------------------------------------------------------------
-- Buffer / window construction
-- ---------------------------------------------------------------------------

local function make_scratch(name, ft)
  local b = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, b, name)
  vim.bo[b].buftype = "acwrite" -- :w is handled by our BufWriteCmd autocmd.
  vim.bo[b].bufhidden = "wipe"
  vim.bo[b].swapfile = false
  if ft then
    vim.bo[b].filetype = ft
  end
  return b
end

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

function M.start()
  local target_buf = vim.api.nvim_get_current_buf()
  local target_win = vim.api.nvim_get_current_win()

  -- Re-running Convert retargets: tear down the previous session first.
  if sessions[target_buf] then
    teardown(sessions[target_buf])
  end

  -- Capture the Visual selection (from the `'<` / `'>` marks set when `:`
  -- left Visual mode) into fixed region bounds.
  local p1 = vim.fn.getpos("'<")
  local p2 = vim.fn.getpos("'>")
  local vt = vim.fn.visualmode()
  if vt == "" then
    vt = "v"
  end
  local srow, scol, erow, ecol = compute_bounds(target_buf, p1, p2, vt)

  local ns = vim.api.nvim_create_namespace("nvim-http-client-convert")
  local text
  do
    local ok, lines = pcall(vim.api.nvim_buf_get_text, target_buf, srow, scol, erow, ecol, {})
    text = ok and table.concat(lines, "\n") or ""
  end
  local enc, dec = default_workflow(text)

  local workflow_buf =
    make_scratch(string.format("nvim-http-client://convert/%d/workflow", target_buf), "sh")
  local output_buf =
    make_scratch(string.format("nvim-http-client://convert/%d/output", target_buf), nil)
  vim.api.nvim_buf_set_lines(workflow_buf, 0, -1, false, { enc, dec })
  vim.bo[workflow_buf].modified = false

  -- Two stacked splits below the target window: workflow then output.
  vim.api.nvim_set_current_win(target_win)
  vim.cmd("belowright split")
  local workflow_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(workflow_win, workflow_buf)
  vim.cmd("belowright split")
  local output_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(output_win, output_buf)
  vim.api.nvim_win_set_height(workflow_win, 3)
  vim.wo[workflow_win].winfixheight = true

  local augroup = vim.api.nvim_create_augroup("NvimHttpConvert_" .. target_buf, { clear = true })

  local session = {
    target_buf = target_buf,
    target_win = target_win,
    workflow_buf = workflow_buf,
    workflow_win = workflow_win,
    output_buf = output_buf,
    output_win = output_win,
    augroup = augroup,
    ns = ns,
    mark_id = nil,
    applied = { encode = enc, decode = dec },
  }
  sessions[target_buf] = session

  -- Record and highlight the captured region, then do the initial decode.
  set_region(session, srow, scol, erow, ecol)
  decode_to_output(session)

  -- Apply workflow edits on save. Buffer mutation is deferred with
  -- vim.schedule to avoid textlock restrictions inside BufWriteCmd.
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = augroup,
    buffer = workflow_buf,
    callback = function()
      vim.bo[workflow_buf].modified = false
      vim.schedule(function()
        on_workflow_save(session)
      end)
    end,
  })
  -- Write-back encode on save (deferred, see above).
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = augroup,
    buffer = output_buf,
    callback = function()
      vim.bo[output_buf].modified = false
      vim.schedule(function()
        on_output_save(session)
      end)
    end,
  })
  -- Closing any of the panes tears the whole session down.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    callback = function(args)
      local w = tonumber(args.match)
      if w == session.workflow_win or w == session.output_win or w == session.target_win then
        teardown(session)
      end
    end,
  })

  -- Leave focus on the target.
  if vim.api.nvim_win_is_valid(target_win) then
    vim.api.nvim_set_current_win(target_win)
  end
end

return M
