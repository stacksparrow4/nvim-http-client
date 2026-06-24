if vim.g.loaded_nvim_http_client then
  return
end
vim.g.loaded_nvim_http_client = true

vim.api.nvim_create_user_command("SendRequest", function()
  require("nvim-http-client").send_request()
end, {
  desc = "Send the current buffer as an HTTP request and show the response",
})

vim.api.nvim_create_user_command("SendRequestMany", function(opts)
  require("nvim-http-client").send_request_many(opts.args)
end, {
  nargs = 1,
  desc = "Send the current buffer as an HTTP request N times and show the aggregated responses",
})

vim.api.nvim_create_user_command("CopyURL", function()
  require("nvim-http-client").copy_url()
end, {
  desc = "Copy the URL of the request in the current .req buffer to the clipboard",
})

-- Open the interactive encode/decode panes for the current Visual selection.
-- Invoked from Visual mode (`:'<,'>Convert`); the selection is read from the
-- `'<` / `'>` marks.
vim.api.nvim_create_user_command("Convert", function()
  require("nvim-http-client.convert").start()
end, {
  range = true,
  desc = "Encode/decode the Visual selection in stacked workflow + output panes",
})

-- Treat *.req files as HTTP request documents.
vim.filetype.add({
  extension = {
    req = "req",
    resp = "req",
  },
})

-- Initial highlighting of request documents is provided by syntax/req.vim
-- (sourced by the standard syntax loader). Re-apply after saving so a changed
-- Content-Type updates the body highlighting.
local group = vim.api.nvim_create_augroup("SendRequestHighlight", { clear = true })
vim.api.nvim_create_autocmd("BufWritePost", {
  group = group,
  pattern = { "*.req" },
  callback = function(args)
    require("nvim-http-client").apply_syntax(args.buf)
  end,
})

-- When a *.req file is opened, automatically open its corresponding *.resp
-- file in a split if it already exists.
vim.api.nvim_create_autocmd("BufReadPost", {
  group = group,
  pattern = { "*.req" },
  nested = true,
  callback = function(args)
    require("nvim-http-client").open_existing_response(args.buf)
  end,
})

-- When a *.req.resp file is opened, automatically open its corresponding
-- *.req file in a split to the left if it already exists, mirroring the way a
-- *.req file opens its response to the right.
vim.api.nvim_create_autocmd("BufReadPost", {
  group = group,
  pattern = { "*.req.resp" },
  nested = true,
  callback = function(args)
    require("nvim-http-client").open_existing_request(args.buf)
  end,
})
