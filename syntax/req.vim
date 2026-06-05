" Syntax for HTTP request documents handled by the sendrequest plugin.
" This is sourced by Neovim's standard syntax loader (after `syntax clear`),
" so the highlighting we set up here is not wiped afterwards.
if exists("b:current_syntax")
  finish
endif

lua require("sendrequest").apply_syntax()
