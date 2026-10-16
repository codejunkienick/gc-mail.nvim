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
vim.o.statusline = " %f %m%=%{v:lua.require('gc_mail').status()} "
vim.o.background = 'dark'
vim.cmd.colorscheme('habamax')

-- Recording-only markdown rendering: GC_DEMO_MARKVIEW names a local
-- markview.nvim checkout; skipped cleanly when unset or missing.
local markview_path = os.getenv('GC_DEMO_MARKVIEW')
if markview_path and markview_path ~= '' and vim.fn.isdirectory(markview_path) == 1 then
  vim.opt.runtimepath:prepend(markview_path)
  local ok, markview = pcall(require, 'markview')
  if ok then
    -- The demo shows nofile buffers (notes, chat, preview): markview skips
    -- those by default, so clear its ignore list for the recording. The
    -- list-item soft-wrap indent misplaces wrapped text under the demo's
    -- wrap + linebreak options, so disable it for the recording.
    pcall(markview.setup, {
      preview = { ignore_buftypes = {} },
      markdown = { list_items = { wrap = false } },
    })
    -- Markview redraws only on events in the current buffer, but the plugin
    -- writes the chat timeline from the compose window, so timelines updated
    -- in the background keep raw markdown until focused. Re-render markdown
    -- buffers on line changes (recording config only).
    local rendered_pending = {}
    local rendered_attached = {}
    local function demo_attach(buf)
      if rendered_attached[buf] or not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      rendered_attached[buf] = true
      pcall(vim.api.nvim_buf_attach, buf, false, {
        on_lines = function()
          if rendered_pending[buf] then
            return
          end
          rendered_pending[buf] = true
          vim.schedule(function()
            rendered_pending[buf] = nil
            if vim.api.nvim_buf_is_valid(buf) then
              pcall(require('markview').render, buf)
            end
          end)
        end,
        on_detach = function()
          rendered_attached[buf] = nil
        end,
      })
    end
    local demo_group = vim.api.nvim_create_augroup('GcMailDemoMarkview', { clear = true })
    vim.api.nvim_create_autocmd('FileType', {
      group = demo_group,
      pattern = 'markdown',
      callback = function(args)
        demo_attach(args.buf)
      end,
    })
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == 'markdown' and vim.api.nvim_buf_is_loaded(buf) then
        demo_attach(buf)
      end
    end
  end
end

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
