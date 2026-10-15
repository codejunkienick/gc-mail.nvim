-- The gc-mail panel: the mailbox docked in a fixed-height split below the
-- current window, like a diagnostics list, kept current while it is open.
--
-- It is a second view of the mailbox (gc_mail.mailbox), not a copy: the same
-- inbox listing, decoders (I1), apply rules (I2), kept copies, lines and
-- actions, so an action taken in the panel or in the float shows in both.
-- Opening it, refreshing it or a mail arriving never moves the cursor or the
-- current window; at most one panel is open per tab page.
--
-- Live updates come from the shared event log watcher (gc_mail.events), not
-- from polling. While a panel is open it subscribes to gc_mail.events for
-- each listed city; on any mail event, overflow, or rotated event, it lists
-- that city again, debounced, with at most one inbox call in flight per city.
--
-- Fallback: every poll_ms the open panel lists every city again and ensures
-- its cities are subscribed in gc_mail.events.
-- Closing the last panel stops its timers and unsubscribes from events; every
-- callback checks that its watch is still the live one before touching state.
local mailbox = require('gc_mail.mailbox')

local M = {}

local uv = vim.uv

local TITLE = ' gc mail: <CR> open  r reply  t thread  c chat  s search  x mark  m read  u unread  a archive  d delete  H all  p preview  R refresh  q close '
local TITLE_ALL = ' all mail  <CR> open  r reply  t thread  c chat  s search  x mark  m read  u unread  a archive  d delete  H all  p preview  R refresh  q close '

local config = {
  poll_ms = nil, -- default: gc_mail.config.panel_poll_ms
  height = nil, -- default: gc_mail.config.panel_height
  debounce_ms = 500,
}

function M.configure(opts)
  config = vim.tbl_extend('force', config, opts or {})
  if package.loaded['gc_mail.events'] or (opts and (opts.rearm_ms or opts.events_rearm_ms)) then
    pcall(function()
      require('gc_mail.events').configure({
        rearm_ms = opts.rearm_ms,
        events_rearm_ms = opts.events_rearm_ms,
      })
    end)
  end
end

local function gc_mail()
  return require('gc_mail')
end

-- ---- the event log watch ------------------------------------------------------

-- The watch while any panel is open: { owner (for mailbox.list), cities (city
-- path -> w), timer (the fallback), handles (every uv handle it made) }.
-- File watching and event parsing are handled by gc_mail.events.
-- In panel.lua, w = { city, debounce (timer), busy (an inbox call in flight),
-- again (list once more when it ends), stopped }.
local live
-- The last watch started, kept after it stops (M.handles).
local last

-- Records `h` among the watch's handles; closed ones are dropped, so a watch
-- re-armed many times holds only what is open.
local function handle(this, h)
  this.handles = vim.tbl_filter(function(old)
    return not old:is_closing()
  end, this.handles)
  this.handles[#this.handles + 1] = h
  return h
end

local function close_handle(h)
  if h and not h:is_closing() then
    h:stop()
    h:close()
  end
end

-- Lists w's city, unless an inbox call of the panel is already in flight
-- for it: then once more when that one ends.
local function refresh(this, w)
  if w.busy then
    w.again = true
    return
  end
  w.busy = true
  mailbox.list(w.city, this.owner, function()
    w.busy = false
    if w.again and live == this and not w.stopped then
      w.again = false
      refresh(this, w)
    end
  end)
end

-- Lists w's city once debounce_ms after the first change that asks for it.
local function soon(this, w)
  if w.debounce:is_active() then
    return
  end
  w.debounce:start(config.debounce_ms, 0, function()
    vim.schedule(function()
      if live == this and not w.stopped then
        refresh(this, w)
      end
    end)
  end)
end

-- Starts watching `city` and lists it once; a city already watched is left.
local function add_city(this, city)
  if this.cities[city.path] then
    return
  end
  local w = {
    city = { name = city.name, path = city.path },
    debounce = handle(this, uv.new_timer()),
  }
  this.cities[city.path] = w
  local clist = {}
  for _, item in pairs(this.cities) do
    clist[#clist + 1] = item.city
  end
  require('gc_mail.events').cities('panel', clist)
  refresh(this, w)
end

local function add_cities(this, cities)
  for _, city in ipairs(cities or {}) do
    add_city(this, city)
  end
end

-- Lists every city again (the R key and the fallback timer), after the kept
-- copies are read again; a log not watched yet is tried once more.
local function refresh_all(this)
  mailbox.reload_kept()
  require('gc_mail.events').rearm()
  for _, w in pairs(this.cities) do
    refresh(this, w)
  end
end

local render

local function start()
  local this = { owner = { pending = 0 }, cities = {}, handles = {} }
  live, last = this, this
  local events = require('gc_mail.events')
  events.subscribe('panel', function(city, ev)
    if live ~= this then
      return
    end
    -- Whether a log is watched changes nothing the panel shows
    if ev.type == 'watching' then
      return
    end
    local w = this.cities[city.path]
    if w and not w.stopped then
      soon(this, w)
    end
  end)
  mailbox.subscribe('panel', function()
    render()
  end)
  mailbox.reload_kept()
  add_cities(this, gc_mail().cached_cities())
  -- Without a cached city list the panel waits for gc cities as well.
  local waiting = gc_mail().cached_cities() == nil
  if waiting then
    this.owner.pending = this.owner.pending + 1
  end
  gc_mail().refresh(function(cities)
    if waiting then
      this.owner.pending = this.owner.pending - 1
    end
    if live == this then
      add_cities(this, cities)
      render()
    end
  end)
  local poll = config.poll_ms or gc_mail().config.panel_poll_ms
  this.timer = handle(this, uv.new_timer())
  this.timer:start(poll, poll, function()
    vim.schedule(function()
      if live ~= this then
        return
      end
      refresh_all(this)
      gc_mail().refresh(function(cities)
        if live == this then
          add_cities(this, cities)
        end
      end)
    end)
  end)
end

local function stop()
  local this = live
  if not this then
    return
  end
  live = nil
  mailbox.subscribe('panel', nil)
  require('gc_mail.events').unsubscribe('panel')
  for _, w in pairs(this.cities) do
    w.stopped = true
  end
  for _, h in ipairs(this.handles) do
    close_handle(h)
  end
end

-- ---- the window ---------------------------------------------------------------

-- The open panels: tab page -> { tab, win, buf, origin (the window it opened
-- under), entries (as shown, by row) }.
local panels = {}

local function key_of(entry)
  return entry.city.path .. '\0' .. entry.message.id
end

local function valid(panel)
  return panel and vim.api.nvim_win_is_valid(panel.win) and vim.api.nvim_buf_is_valid(panel.buf)
    and vim.api.nvim_win_get_buf(panel.win) == panel.buf
end

-- Forgets `panel` (its window is closing or gone); the last one stops the watch.
local function forget(panel)
  if panels[panel.tab] ~= panel then
    return
  end
  panels[panel.tab] = nil
  if panel.preview then
    panel.preview.close()
  end
  pcall(vim.api.nvim_del_augroup_by_id, panel.group)
  if next(panels) == nil then
    stop()
  end
end

local function draw(panel)
  local entries = mailbox.entries()
  local lines = mailbox.lines(entries, os.time(), live ~= nil and live.owner.pending > 0)
  local row = vim.api.nvim_win_get_cursor(panel.win)[1]
  local was = panel.entries[row]
  vim.bo[panel.buf].modifiable = true
  vim.api.nvim_buf_set_lines(panel.buf, 0, -1, false, lines)
  vim.bo[panel.buf].modifiable = false
  panel.entries = entries
  vim.wo[panel.win].statusline = mailbox.all() and TITLE_ALL or TITLE
  -- The cursor stays on the message it was on; the current window is untouched.
  row = math.min(row, #lines)
  if was then
    local key = key_of(was)
    for i, entry in ipairs(entries) do
      if key_of(entry) == key then
        row = i
        break
      end
    end
  end
  vim.api.nvim_win_set_cursor(panel.win, { row, 0 })
  if panel.preview then
    panel.preview.update()
  end
end

render = function()
  for _, panel in pairs(panels) do
    if valid(panel) then
      draw(panel)
    else
      forget(panel)
    end
  end
end

-- Opens and enters a window above `panel` for a message, a thread or a
-- reply: a split of the window right above it, else a full-width one at the
-- top. Never inside the panel.
local function split_above(panel)
  return function()
    local above = vim.api.nvim_win_call(panel.win, function()
      return vim.fn.win_getid(vim.fn.winnr('k'))
    end)
    if above == 0 or above == panel.win then
      above = vim.api.nvim_win_is_valid(panel.origin) and panel.origin ~= panel.win
        and vim.api.nvim_win_get_tabpage(panel.origin) == panel.tab and panel.origin or nil
    end
    if above then
      vim.api.nvim_set_current_win(above)
      vim.cmd('new')
    else
      vim.cmd('topleft new')
    end
  end
end

-- Moves to the window `panel` is docked under (its origin), else the one
-- right above it, else a new window at the top: where a chat opens, never
-- inside the panel.
local function beside(panel)
  return function()
    local target = vim.api.nvim_win_is_valid(panel.origin) and panel.origin ~= panel.win
      and vim.api.nvim_win_get_tabpage(panel.origin) == panel.tab and panel.origin or nil
    if target then
      vim.api.nvim_set_current_win(target)
    else
      split_above(panel)()
    end
  end
end

local function close(panel)
  forget(panel)
  if vim.api.nvim_win_is_valid(panel.win) and not pcall(vim.api.nvim_win_close, panel.win, true) then
    -- The last window of the editor cannot close: show an empty buffer instead.
    vim.api.nvim_win_set_buf(panel.win, vim.api.nvim_create_buf(true, false))
  end
end

local function keys(panel)
  local actions = mailbox.actions
  local function on(fn)
    return function()
      local entry = valid(panel) and panel.entries[vim.api.nvim_win_get_cursor(panel.win)[1]]
      if entry then
        fn(entry)
      end
    end
  end
  local map = {
    ['<CR>'] = on(function(entry) actions.open(entry, split_above(panel)) end),
    r = on(function(entry) actions.reply(entry, split_above(panel)) end),
    t = on(function(entry) actions.thread(entry, split_above(panel)) end),
    c = on(function(entry) actions.chat(entry, beside(panel)) end),
    s = function()
      require('gc_mail.search').prompt()
    end,
    p = function()
      if panel.preview then
        panel.preview.toggle()
      end
    end,
    R = function()
      if live then
        refresh_all(live)
        mailbox.reload_history()
        render()
      end
    end,
    q = function() close(panel) end,
  }
  for lhs, fn in pairs(map) do
    vim.keymap.set('n', lhs, fn, { buffer = panel.buf, nowait = true, silent = true,
      desc = 'gc-mail: ' .. (mailbox.KEY_DESC[lhs] or lhs) })
  end
  -- x, X, H, and m, u, a, d on the selection, the marks or the cursor.
  mailbox.map_keys(panel.buf, function()
    if valid(panel) then
      return panel.entries, vim.api.nvim_win_get_cursor(panel.win)[1]
    end
  end)
end

--- Opens the panel below the current window of this tab page, without
--- entering it; a panel already open in this tab page is left as it is.
--- Returns its window, or nil.
function M.open()
  local tab = vim.api.nvim_get_current_tabpage()
  if valid(panels[tab]) then
    return panels[tab].win
  end
  local origin = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(origin).relative ~= '' then
    vim.notify('gc-mail: the mail panel opens below a normal window, not a floating one', vim.log.levels.WARN)
    return nil
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, 'gc-mail://panel/' .. tab)
  local win = vim.api.nvim_open_win(buf, false, {
    split = 'below', win = origin, height = config.height or gc_mail().config.panel_height,
  })
  local wo = vim.wo[win]
  wo.winfixheight, wo.number, wo.relativenumber, wo.signcolumn = true, false, false, 'no'
  wo.foldcolumn, wo.cursorline, wo.wrap, wo.list, wo.spell = '0', true, false, false, false
  wo.statusline = TITLE
  vim.bo[buf].filetype = 'gcmail-panel'
  if panels[tab] then
    forget(panels[tab]) -- its window shows another buffer now
  end
  local panel = { tab = tab, win = win, buf = buf, origin = origin, entries = {} }
  panel.group = vim.api.nvim_create_augroup('gc_mail_panel_' .. buf, { clear = true })
  vim.api.nvim_create_autocmd('WinClosed', { group = panel.group, pattern = tostring(win), callback = function()
    forget(panel)
  end })
  vim.api.nvim_create_autocmd('BufWipeout', { group = panel.group, buffer = buf, callback = function()
    forget(panel)
  end })
  panels[tab] = panel
  panel.preview = require('gc_mail.preview').attach({
    kind = 'split', win = win, buf = buf, entry_at = function(row) return panel.entries[row] end,
  })
  keys(panel)
  if not live then
    start()
  end
  render()
  return win
end

--- Closes the panel of this tab page.
function M.close()
  local panel = panels[vim.api.nvim_get_current_tabpage()]
  if panel then
    close(panel)
  end
end

--- Opens the panel of this tab page, or closes it when it is open.
function M.toggle()
  if valid(panels[vim.api.nvim_get_current_tabpage()]) then
    return M.close()
  end
  return M.open()
end

--- Closes every panel.
function M.close_all()
  for _, panel in pairs(panels) do
    close(panel)
  end
  stop()
end

--- The panel window of this tab page, or nil.
function M.win()
  local panel = panels[vim.api.nvim_get_current_tabpage()]
  return valid(panel) and panel.win or nil
end

--- Whether the event log watch runs.
function M.running()
  return live ~= nil
end

--- Every uv handle the last watch made (for the tests: once it stops, each
--- is closing).
function M.handles()
  local panel_handles = last and last.handles or {}
  return vim.list_extend(vim.list_slice(panel_handles), require('gc_mail.events').handles())
end

return M
