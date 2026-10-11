-- The Neovim config of the recording demo: nvim --clean -u demo/init.lua.
-- The plugin is used as a user would use it (`require('gc_mail').setup({})`),
-- plus the key overlay of demo/keys.lua.
local here = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, 'S').source:sub(2)))
local root = vim.fs.dirname(here)

vim.opt.runtimepath:prepend(root)
package.path = root .. '/?.lua;' .. package.path

vim.o.swapfile = false
vim.o.shadafile = 'NONE'
vim.o.termguicolors = true
vim.o.shortmess = 'filnxtToOFcIsW'
vim.o.cmdheight = 1
vim.o.laststatus = 2
vim.o.showmode = false
vim.o.ruler = false
vim.o.number = false
vim.o.signcolumn = 'no'
vim.o.mouse = ''
vim.o.splitbelow = true
vim.o.wrap = true
vim.o.linebreak = true
vim.o.statusline = ' %f %m'
vim.o.background = 'dark'
vim.cmd.colorscheme('habamax')

require('gc_mail').setup({})
require('demo.keys').start()

-- A buffer to be working in: notes of a small team.
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(buf, 'team-notes.md')
vim.bo[buf].buftype = 'nofile'
vim.bo[buf].filetype = 'markdown'
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  '# Team notes',
  '',
  '## This week',
  '',
  '- Export change: waiting for the review to be approved',
  '- Search index: rebuild is back to normal',
  '- Thursday: deploy window, plan from the mayor',
  '',
  '## Open questions',
  '',
  '- Who owns the staging database refresh?',
})
vim.api.nvim_win_set_cursor(0, { 1, 0 })
