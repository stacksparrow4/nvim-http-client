-- Minimal config for testing the sendrequest plugin.
-- Launch with:  nvim -u /pwd/test_init.lua /pwd/test.req
vim.opt.runtimepath:prepend("/pwd")

-- plugin/sendrequest.lua is loaded automatically from runtimepath,
-- but with -u that auto-loading is skipped, so require it explicitly:
require("sendrequest").setup({
  python = "python3",
  open = "vsplit",
})
vim.api.nvim_create_user_command("SendRequest", function()
  require("sendrequest").send_request()
end, {})
