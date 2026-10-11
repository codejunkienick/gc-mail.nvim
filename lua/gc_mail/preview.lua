-- The mail preview: a pane beside a mailbox list (the float or the panel)
-- that shows the body of the message under the list cursor, and only the
-- body: no header lines, no subject.
--
-- It reads the entry the list already holds in memory (entry_at), so it makes
-- no gc call and marks nothing read. Moving the cursor redraws it after a
-- short debounce (one timer per list); a re-render of the list redraws it at
-- once. It exists only while its list is open: the pane, its timer and its
-- autocmds are made by attach() and removed with the list's window.
local M = {}

local uv = vim.uv

local DEBOUNCE_MS = 50
local MIN_WIDTH = 30
-- Columns kept free at the right edge of the editor beside a float list.
local MARGIN = 1
-- Fewest rows a pane below a float list may have.
local MIN_ROWS = 3
-- Columns the panel list keeps when its pane takes the right part of the row.
local LIST_MIN_WIDTH = 20
local EMPTY = '(no content)'

local ns = vim.api.nvim_create_namespace('gc_mail_preview')

--- Where the pane of a float list goes: right of the list at the list's top,
--- down to the bottom of the editor (never shorter than the list) so a long
--- body has room, `columns` minus a margin wide (at least 30); else below the
--- list when 3 rows fit; else nil (hidden). `list` is { row, col, width,
--- height } of the list window, border not included; `lines` and `columns`
--- are the editor's.
function M.float_layout(list, columns, lines, cmdheight)
  local left = list.col + list.width + 2
  local width = columns - left - 2 - MARGIN
  if width >= MIN_WIDTH then
    local height = math.max(list.height, lines - cmdheight - list.row - 2)
    return { row = list.row, col = left, width = width, height = height }
  end
  local top = list.row + list.height + 2
  local height = lines - cmdheight - top - 2
  width = math.min(math.max(list.width, MIN_WIDTH), columns - list.col - 2)
  if height >= MIN_ROWS and width >= MIN_WIDTH then
    return { row = top, col = list.col, width = width, height = height }
  end
  return nil
end

--- The columns of a pane split off a panel `panel_width` columns wide: about
--- half of it, at least 30; nil when the list would keep under 20.
function M.split_width(panel_width)
  local width = math.max(MIN_WIDTH, math.floor(panel_width / 2))
  if panel_width - width - 1 < LIST_MIN_WIDTH then
    return nil
  end
  return width
end

local function markdown()
  return require('gc_mail').config.markdown
end

--- Shows a preview of the entries `opts.entry_at(row)` finds under the cursor
--- of the list window `opts.win` (buffer `opts.buf`). `opts.kind` is 'float'
--- (a second float beside the list) or 'split' (a vertical split inside the
--- list's row). Returns { update(), toggle(), close(), pane() }; the pane
--- starts hidden when the preview option is false, and nothing is drawn
--- before the first update().
function M.attach(opts)
  local list_win, list_buf = opts.win, opts.buf
  local handle = {}
  local shown = require('gc_mail').config.preview ~= false
  local closed = false
  local pane_win, pane_buf
  local last, said
  local timer = uv.new_timer()
  local group = vim.api.nvim_create_augroup('gc_mail_preview_' .. list_buf, { clear = true })

  local function close_pane()
    local win = pane_win
    pane_win, pane_buf, last = nil, nil, nil
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  -- The window config for the pane, or nil when it has no room.
  local function placement()
    if opts.kind == 'split' then
      local width = M.split_width(vim.api.nvim_win_get_width(list_win))
      return width and { split = 'right', win = list_win, width = width } or nil
    end
    local at = vim.api.nvim_win_get_config(list_win)
    local layout = M.float_layout({ row = math.floor(at.row), col = math.floor(at.col), width = at.width,
      height = at.height }, vim.o.columns, vim.o.lines, vim.o.cmdheight)
    if not layout then
      return nil
    end
    return vim.tbl_extend('force', layout, { relative = 'editor', style = 'minimal', border = 'rounded',
      focusable = false, title = ' preview ', title_pos = 'center' })
  end

  local function make_buffer()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].swapfile = false
    if markdown() then
      vim.bo[buf].filetype = 'markdown'
    end
    if not pcall(vim.api.nvim_buf_set_name, buf, 'gc-mail://preview') then
      pcall(vim.api.nvim_buf_set_name, buf, 'gc-mail://preview/' .. buf)
    end
    vim.bo[buf].modifiable = false
    return buf
  end

  -- Opens the pane, or moves a float pane to follow its list. true when a
  -- pane is open after it.
  local function ensure_pane()
    -- A split pane stays where it is: placing it again would measure a list
    -- it already narrowed.
    if opts.kind == 'split' and pane_win and vim.api.nvim_win_is_valid(pane_win) then
      return true
    end
    local config = placement()
    if not config then
      close_pane()
      return false
    end
    if pane_win and vim.api.nvim_win_is_valid(pane_win) then
      vim.api.nvim_win_set_config(pane_win, config)
      return true
    end
    close_pane()
    local buf = make_buffer()
    -- A list in another tab page cannot be split from here: the pane stays
    -- hidden until its list is drawn again in its own tab page.
    local made, win = pcall(vim.api.nvim_open_win, buf, false, config)
    if not made then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      return false
    end
    pane_win, pane_buf = win, buf
    local wo = vim.wo[win]
    wo.wrap, wo.linebreak, wo.number, wo.relativenumber, wo.signcolumn = true, true, false, false, 'no'
    wo.foldcolumn, wo.cursorline, wo.list, wo.spell = '0', false, false, false
    if opts.kind == 'split' then
      wo.winfixheight = true
    end
    return true
  end

  local function show(lines, dim)
    vim.bo[pane_buf].modifiable = true
    vim.api.nvim_buf_set_lines(pane_buf, 0, -1, false, lines)
    vim.bo[pane_buf].modifiable = false
    vim.bo[pane_buf].modified = false
    vim.api.nvim_buf_clear_namespace(pane_buf, ns, 0, -1)
    if dim then
      vim.api.nvim_buf_set_extmark(pane_buf, ns, 0, 0, { line_hl_group = 'Comment' })
    end
    pcall(vim.api.nvim_win_set_cursor, pane_win, { 1, 0 })
  end

  --- Draws the pane for the message under the list cursor now.
  function handle.update()
    if closed then
      return
    end
    if not vim.api.nvim_win_is_valid(list_win) then
      return handle.close()
    end
    if not shown then
      return close_pane()
    end
    if not ensure_pane() then
      return
    end
    local entry = opts.entry_at(vim.api.nvim_win_get_cursor(list_win)[1])
    local signature = entry and (entry.city.path .. '\0' .. entry.message.id .. '\0' .. entry.message.body) or false
    if signature == last then
      return
    end
    last = signature
    if not entry then
      return show({ '' })
    end
    local ok, lines = pcall(function()
      return require('gc_mail.mailbox').body_lines(entry.message.body)
    end)
    if not ok then
      if not said then
        said = true
        vim.notify('gc-mail: cannot show the preview: ' .. tostring(lines), vim.log.levels.ERROR)
      end
      return show({ '' })
    end
    if vim.trim(entry.message.body) == '' then
      return show({ EMPTY }, true)
    end
    show(lines)
  end

  --- Shows or hides the pane for as long as the list is open.
  function handle.toggle()
    shown = not shown
    handle.update()
  end

  --- Removes the pane, the timer and the autocmds; the list stays as it is.
  function handle.close()
    if closed then
      return
    end
    closed = true
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    pcall(vim.api.nvim_del_augroup_by_id, group)
    close_pane()
  end

  --- The pane window, or nil when it is hidden.
  function handle.pane()
    return pane_win and vim.api.nvim_win_is_valid(pane_win) and pane_win or nil
  end

  vim.api.nvim_create_autocmd('CursorMoved', { group = group, buffer = list_buf, callback = function()
    if not timer:is_closing() then
      timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(handle.update))
    end
  end })
  vim.api.nvim_create_autocmd('WinClosed', { group = group, callback = function(args)
    local win = tonumber(args.match)
    if win == list_win then
      handle.close()
    elseif win == pane_win then
      -- The pane was closed by hand: it stays away until p shows it again.
      pane_win, pane_buf, last, shown = nil, nil, nil, false
    end
  end })
  return handle
end

return M
