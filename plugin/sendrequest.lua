if vim.g.loaded_sendrequest then
  return
end
vim.g.loaded_sendrequest = true

vim.api.nvim_create_user_command("SendRequest", function()
  require("sendrequest").send_request()
end, {
  desc = "Send the current buffer as an HTTP request and show the response",
})

-- Treat *.req (and *.http) files as HTTP request documents.
vim.filetype.add({
  extension = {
    req = "req",
    http = "req",
    resp = "req",
  },
})

-- Initial highlighting of request documents is provided by syntax/req.vim
-- (sourced by the standard syntax loader). Re-apply after saving so a changed
-- Content-Type updates the body highlighting.
local group = vim.api.nvim_create_augroup("SendRequestHighlight", { clear = true })
vim.api.nvim_create_autocmd("BufWritePost", {
  group = group,
  pattern = { "*.req", "*.http" },
  callback = function(args)
    require("sendrequest").apply_syntax(args.buf)
  end,
})
