-- The gc-mail chat window: a two-window docked conversation view
-- (timeline above, compose box below) beside the current window.
--
-- Opening it splits the current window to the right and puts the cursor in the
-- compose box in normal mode; nothing else about the user's windows changes.
-- q in the timeline closes both windows.
--
-- Live updates: while at least one chat is open, the chat is one subscriber
-- ('chat') of the shared event log watcher (gc_mail.events) for the open
-- chats' cities, and each such city has one fallback timer that loads its
-- history every chat_poll_ms. Closing the last chat of a city drops the city
-- and stops its timer; closing the last chat unsubscribes. Every callback
-- checks that its watch is still the live one before touching anything.
local gc_mail = require('gc_mail')
local queue = require('gc_mail.queue')
local history = require('gc_mail.history')
local mailbox = require('gc_mail.mailbox')
local events = require('gc_mail.events')

local M = {}

local TITLE = ' gc mail: <CR> open  t thread  u unread  R refresh  q close '

-- Active chats: tab -> key -> chat
-- where key is city.path .. '\0' .. with
local chats = {}

-- Last chat opened in this session: { city = city, with = with }
local last_chat = nil

-- Compose buffers kept across reopenings while they have text:
-- key (city.path .. '\0' .. with) -> list of buffer numbers (the same chat
-- open in two tab pages keeps one draft per tab page)
local saved_compose = {}

-- Read state, one record per message id (no record = idle):
-- reads[id] = { phase = 'reading' | 'read' | 'refused' | 'unreading',
--   seq = <number>, owner = <chat that pressed u>, answered = <hrtime> }
-- Invariants:
--  RS1 Every read or unread the chat starts bumps that id's seq; an answer
--      whose seq is no longer current changes nothing (state, cache, render).
--  RS2 actions.unread hands apply()'s result to on_done as actions.read does;
--      the chat treats applied = false as the stale case of RS1 and takes
--      gc's answer from a history load (RS5).
--  RS3 Automatic mark-read passes only an id with no record, at most once
--      until its record is dropped.
--  RS4 u sets 'unreading', owned by the chat that pressed it; only leaving
--      that chat's own two windows releases the ids it owns. Another chat's
--      window moves never touch them.
--  RS5 Every render first reconciles the cached messages with the records,
--      whichever load cached them (the chat's own, the send's, a thread view):
--      a cached message carries loaded_since, when the gc call that listed it
--      started (history.load). A message whose last action answered before
--      then takes gc's flag and drops its record when they disagree; an
--      action still pending, or answered at or after then, keeps the local
--      value. An event that changes a cached message's read flag stamps
--      the message with the event's time, so it wins over an action answered
--      before it.
--  RS6 A refused mark-read keeps the dot and is not retried automatically
--      until a load shows the message read.
local reads = {}
local seq_counter = 0

local function next_seq()
  seq_counter = seq_counter + 1
  return seq_counter
end

-- What the record says the message's read flag is
local function local_read(rec)
  return rec.phase == 'reading' or rec.phase == 'read'
end

local function set_buf_name_unique(buf, base_name, tab)
  if pcall(vim.api.nvim_buf_set_name, buf, base_name) then
    return
  end
  local tab_name = ('%s (%d)'):format(base_name, tab)
  if pcall(vim.api.nvim_buf_set_name, buf, tab_name) then
    return
  end
  local i = 2
  while true do
    local alt = ('%s (%d_%d)'):format(base_name, tab, i)
    if pcall(vim.api.nvim_buf_set_name, buf, alt) then
      return
    end
    i = i + 1
  end
end

local function key_of(city, with)
  return city.path .. '\0' .. with
end

local function valid_chat(chat)
  return chat ~= nil
    and vim.api.nvim_win_is_valid(chat.timeline_win)
    and vim.api.nvim_win_is_valid(chat.compose_win)
    and vim.api.nvim_buf_is_valid(chat.timeline_buf)
    and vim.api.nvim_buf_is_valid(chat.compose_buf)
end

local function body_lines(text)
  return vim.split(text or '', '\n', { plain = true })
end

local function md_escape(text)
  return (gc_mail.one_line(text):gsub('[\\`*_%[%]<>#|]', '\\%0'))
end

local function strip_label(text)
  local prefix = gc_mail.config.subject_prefix or ''
  local suffix = gc_mail.config.subject_suffix or ''
  local core = text or ''
  for _, part in ipairs({ prefix, suffix }) do
    if part ~= '' then
      core = core:gsub(vim.pesc(part), '')
    end
  end
  return vim.trim(core)
end

local function first_non_empty_line(body)
  for _, line in ipairs(vim.split(body or '', '\n', { plain = true })) do
    if vim.trim(line) ~= '' then
      return vim.trim(line)
    end
  end
  return nil
end

local function format_when(created)
  local now = os.time()
  local msg_day = os.date('%Y-%m-%d', created)
  local today = os.date('%Y-%m-%d', now)
  if msg_day == today then
    return os.date('%H:%M', created)
  else
    return os.date('%Y-%m-%d %H:%M', created)
  end
end

-- Resolve city and recipient according to the rules:
-- - city: only cached city, else the first; unknown is an error naming known
-- - with: defaults to 'mayor'; must pass queue's 'to' rule
local function resolve_city_and_with(city_arg, with_arg)
  local cities = gc_mail.cached_cities()
  if not cities or #cities == 0 then
    error('gc-mail: no cities are registered with gc', 2)
  end

  local city
  if city_arg and city_arg ~= '' then
    for _, c in ipairs(cities) do
      if c.name == city_arg then
        city = c
        break
      end
    end
    if not city then
      local names = {}
      for _, c in ipairs(cities) do
        names[#names + 1] = c.name
      end
      error(('gc-mail: unknown city "%s", known: %s'):format(city_arg, table.concat(names, ', ')), 2)
    end
  else
    city = cities[1]
  end

  local with = 'mayor'
  if with_arg and with_arg ~= '' then
    with = with_arg
  end

  if type(with) ~= 'string' or with == '' or #with > 100
      or with:find('[%z\1-\31\127]') or with:sub(1, 1) == '-' then
    error(('gc-mail: cannot chat with "%s": bad address'):format(tostring(with)), 2)
  end

  return city, with
end

local function split_target(chat)
  return function()
    local left = vim.api.nvim_win_call(chat.timeline_win, function()
      return vim.fn.win_getid(vim.fn.winnr('h'))
    end)
    if left ~= 0 and left ~= chat.timeline_win and left ~= chat.compose_win and vim.api.nvim_win_is_valid(left) then
      vim.api.nvim_set_current_win(left)
      vim.cmd('new')
    else
      vim.cmd('new')
    end
  end
end

-- Sets the read flag of message `id` in the chat's list and the history cache
local function set_read(chat, m, value)
  m.read = value
  local cached = history.cache[chat.city.path]
  if cached and cached.by_id and cached.by_id[m.id] then
    cached.by_id[m.id].read = value
  end
end

-- RS5
local function sync_cache_read(city)
  local cached = history.cache[city.path]
  if not (cached and cached.by_id) then
    return
  end
  for id, rec in pairs(reads) do
    local m = cached.by_id[id]
    if m then
      if rec.answered == nil or rec.answered >= (m.loaded_since or 0) then
        m.read = local_read(rec)
      elseif m.read ~= local_read(rec) then
        reads[id] = nil
      end
    end
  end
end

-- What events changed, per city path: id -> { at = <hrtime of the event>,
-- target = <the cached message it put or changed>, message = <the message an
-- event carried>, read = <boolean>, closed = <true> }. A history load that
-- began before an event replaces the cache with a list gc made before it:
-- every render first puts the changes back on such a copy, and drops a change
-- once a load that began after its event has listed the city.
local live_changes = {}

local function apply_live(city)
  local changes = live_changes[city.path]
  if not changes then
    return
  end
  local cached = history.cache[city.path]
  for id, ch in pairs(changes) do
    local m = cached and cached.by_id and cached.by_id[id]
    if m ~= ch.target then
      local seen = (m and m.loaded_since) or (cached and cached.loaded_since) or 0
      if seen >= ch.at then
        changes[id] = nil
      elseif m then
        if ch.read ~= nil or ch.closed then
          if ch.read ~= nil then
            m.read = ch.read
          end
          if ch.closed then
            m.closed = true
          end
          m.loaded_since = ch.at
        end
        ch.target = m
      elseif ch.message then
        history.put(city, ch.message)
        ch.target = ch.message
      end
    end
  end
  if next(changes) == nil then
    live_changes[city.path] = nil
  end
end

local render_city

-- The watch while any chat is open: { cities = city path -> { city, timer } }.
local live = nil

-- Cities whose last history load failed, with the error: it is said once,
-- until a load of that city succeeds again.
local load_failed = {}

-- Loads `city`'s history (joining a load already running) and renders every
-- open chat of that city; an answer after the last chat closed does nothing.
local function load_city(city)
  history.load(city, function(_, err)
    if not live then
      return
    end
    if err then
      if not load_failed[city.path] then
        vim.notify('gc-mail: ' .. err, vim.log.levels.ERROR)
      end
      load_failed[city.path] = err
    else
      load_failed[city.path] = nil
    end
    render_city(city)
  end)
end

local function reload(chat)
  load_city(chat.city)
end

-- An answer is stale (RS1) when the id's record is gone or carries a newer seq
local function current(id, seq)
  local rec = reads[id]
  return rec ~= nil and rec.seq == seq and rec or nil
end

local function check_mark_read(chat, history_messages, should_render)
  if gc_mail.config.chat_mark_read == false then
    return
  end
  local cur_win = vim.api.nvim_get_current_win()
  if cur_win ~= chat.timeline_win and cur_win ~= chat.compose_win then
    return
  end

  if not history_messages then
    history_messages = history.conversation(chat.city, chat.with)
  end

  local marked_any = false
  for _, m in ipairs(history_messages) do
    -- RS3
    if m.to == 'human' and not m.read and not reads[m.id] then
      local id, seq = m.id, next_seq()
      reads[id] = { phase = 'reading', seq = seq }
      m.read = true
      marked_any = true
      local entry = { city = chat.city, message = m, read = true }
      mailbox.actions.read(entry, function(ok, _, applied)
        local rec = current(id, seq)
        if not rec then
          return
        end
        rec.answered = vim.uv.hrtime()
        if not ok then
          -- RS6
          rec.phase = 'refused'
          set_read(chat, m, false)
          if valid_chat(chat) then
            M.render(chat)
          end
          return
        end
        rec.phase = 'read'
        if applied == false then
          reload(chat)
        else
          set_read(chat, m, true)
        end
      end)
    end
  end

  if marked_any and should_render and valid_chat(chat) then
    M.render(chat)
  end
end

local function is_queue_hidden(rec, history_messages)
  for _, m in ipairs(history_messages) do
    if m.from == 'human' and m.subject == rec.subject and m.body == rec.body and m.created >= rec.created then
      return true
    end
  end
  return false
end

-- The timeline window's view: { view = winsaveview(), bottom = the last line
-- shown, last = the buffer's last line }, read in that window
local function view_of(chat)
  return vim.api.nvim_win_call(chat.timeline_win, function()
    return { view = vim.fn.winsaveview(), bottom = vim.fn.line('w$'), last = vim.fn.line('$') }
  end)
end

-- The timeline follows the end while its view shows the last line with the
-- cursor on it: scrolling the view up (the wheel, <C-y>) or moving the cursor
-- up stops following, G resumes it
local function following(at)
  return at.view.lnum >= at.last and at.bottom >= at.last
end

-- Drops from the messages waiting below what the view now shows, all of them
-- once it follows the end again, and shows their count in the timeline's
-- statusline
local function update_below(chat)
  if not valid_chat(chat) then
    return
  end
  if next(chat.below) ~= nil then
    local at = view_of(chat)
    local waiting = {}
    if not following(at) then
      for _, block in ipairs(chat.message_blocks) do
        if block.message and chat.below[block.message.id] and block.start_line > at.bottom then
          waiting[block.message.id] = true
        end
      end
    end
    chat.below = waiting
  end
  local count = vim.tbl_count(chat.below)
  local status = count > 0 and (' ↓ %d newer below (G) %%<'):format(count) .. TITLE or TITLE
  if vim.wo[chat.timeline_win].statusline ~= status then
    vim.wo[chat.timeline_win].statusline = status
  end
end

function M.render(chat)
  if not valid_chat(chat) then
    return
  end

  apply_live(chat.city)
  sync_cache_read(chat.city)
  local history_messages = history.conversation(chat.city, chat.with)
  check_mark_read(chat, history_messages)

  local conv_ids = {}
  for _, m in ipairs(history_messages) do
    conv_ids[m.id] = true
  end

  local queue_entries, queue_err = queue.list()
  local relevant_queue = {}
  if not queue_entries then
    relevant_queue[#relevant_queue + 1] = {
      record = {
        failed = true,
        last_error = queue_err or 'cannot read queue',
        body = queue_err or '',
      },
    }
  else
    for _, q in ipairs(queue_entries) do
      if not q.record or q.error then
        relevant_queue[#relevant_queue + 1] = {
          record = {
            failed = true,
            last_error = q.error or ('unreadable: ' .. tostring(q.name)),
            body = q.name or '',
          },
        }
      else
        local rec = q.record
        if type(rec) == 'table' and type(rec.city) == 'table' and rec.city.path == chat.city.path then
          local to = rec.to or 'mayor'
          local is_match = false
          if rec.reply_to == nil and to == chat.with then
            is_match = true
          elseif rec.reply_to ~= nil and conv_ids[rec.reply_to] then
            is_match = true
          end
          if is_match and not is_queue_hidden(rec, history_messages) then
            relevant_queue[#relevant_queue + 1] = q
          end
        elseif type(rec) ~= 'table' or type(rec.city) ~= 'table' then
          relevant_queue[#relevant_queue + 1] = {
            record = {
              failed = true,
              last_error = 'malformed queue record: ' .. tostring(q.name),
              body = q.name or '',
            },
          }
        end
      end
    end
  end

  local lines = {}
  local blocks = {}

  if #history_messages == 0 and #relevant_queue == 0 then
    local err = load_failed[chat.city.path]
    if err then
      lines[1] = 'cannot load the history: ' .. md_escape(err)
    else
      lines[1] = ('no messages with %s in %s yet'):format(chat.with, chat.city.name)
    end
  else
    for _, m in ipairs(history_messages) do
      local start_line = #lines + 1
      local who = (m.from == 'human') and 'you' or m.from
      local when = format_when(m.created)
      local closed_mark = m.closed and ' (closed)' or ''
      local unread_bullet = (m.to == 'human' and not m.read) and ' ●' or ''
      lines[#lines + 1] = ('## %s · %s%s%s'):format(md_escape(who), md_escape(when), closed_mark, unread_bullet)
      lines[#lines + 1] = ''

      local omit_subject = false
      local first_line = first_non_empty_line(m.body)
      if first_line ~= nil and strip_label(m.subject) == strip_label(first_line) then
        omit_subject = true
      end

      if not omit_subject then
        lines[#lines + 1] = md_escape(m.subject)
        lines[#lines + 1] = ''
      end

      for _, bline in ipairs(body_lines(m.body)) do
        lines[#lines + 1] = bline
      end
      lines[#lines + 1] = ''
      lines[#lines + 1] = '---'
      local end_line = #lines
      blocks[#blocks + 1] = { message = m, start_line = start_line, end_line = end_line }
    end

    for _, q in ipairs(relevant_queue) do
      local rec = q.record
      local start_line = #lines + 1
      local heading
      if q.claimed then
        heading = '## you · sending…'
      elseif rec.failed then
        local first_err = (rec.last_error or ''):match('[^\n]+') or ''
        heading = '## you · failed: ' .. md_escape(first_err)
      else
        heading = '## you · queued'
      end
      lines[#lines + 1] = heading
      lines[#lines + 1] = ''
      for _, bline in ipairs(body_lines(rec.body)) do
        lines[#lines + 1] = bline
      end
      lines[#lines + 1] = ''
      lines[#lines + 1] = '---'
      local end_line = #lines
      blocks[#blocks + 1] = { record = rec, start_line = start_line, end_line = end_line }
    end
  end

  local before = view_of(chat)
  local follow = chat.just_opened or #chat.lines == 0 or following(before)
  chat.just_opened = false
  local shown_ids = {}
  for _, block in ipairs(chat.message_blocks) do
    if block.message then
      shown_ids[block.message.id] = true
    end
  end

  vim.bo[chat.timeline_buf].modifiable = true
  vim.api.nvim_buf_set_lines(chat.timeline_buf, 0, -1, false, lines)
  vim.bo[chat.timeline_buf].modifiable = false

  chat.lines = lines
  chat.message_blocks = blocks

  local new_count = math.max(1, #lines)
  if follow then
    chat.below = {}
    vim.api.nvim_win_set_cursor(chat.timeline_win, { new_count, 0 })
  else
    -- Held: the same cursor and topline; a message first shown below the
    -- view waits there, counted by its id
    local view = before.view
    view.lnum = math.min(view.lnum, new_count)
    view.topline = math.min(view.topline, new_count)
    local bottom = vim.api.nvim_win_call(chat.timeline_win, function()
      vim.fn.winrestview(view)
      return vim.fn.line('w$')
    end)
    for _, block in ipairs(blocks) do
      if block.message and not shown_ids[block.message.id] and block.start_line > bottom then
        chat.below[block.message.id] = true
      end
    end
  end
  update_below(chat)
end

-- Whether message `m` belongs to the conversation of the human with `with`
local function belongs(m, with)
  return (m.from == with and m.to == 'human') or (m.from == 'human' and m.to == with)
end

-- Renders every open chat of `city`; with `m`, only those whose conversation
-- holds it
render_city = function(city, m)
  for _, tab_chats in pairs(chats) do
    for _, chat in pairs(tab_chats) do
      if valid_chat(chat) and chat.city.path == city.path and (m == nil or belongs(m, chat.with)) then
        M.render(chat)
      end
    end
  end
end

local function render_all()
  for _, tab_chats in pairs(chats) do
    for _, chat in pairs(tab_chats) do
      if valid_chat(chat) then
        M.render(chat)
      end
    end
  end
end

-- ---- live updates -------------------------------------------------------------

-- chat.configure({ poll_ms = ... }): the fallback period without setup()'s
-- floor (the tests); nil takes gc_mail.config.chat_poll_ms.
local poll_override = nil

local READ_EVENTS = { ['mail.read'] = true, ['mail.marked_read'] = true, ['mail.marked_unread'] = false }
local CLOSED_EVENTS = { ['mail.archived'] = true, ['mail.deleted'] = true }

function M.configure(opts)
  opts = opts or {}
  if opts.poll_ms ~= nil then
    poll_override = opts.poll_ms
  end
end

-- One decoded event of a watched city's log (gc_mail.events). A message the
-- event carries is put in the history cache with no gc call; an event that
-- tells less than that loads the city once.
local function on_event(this, city, event)
  if live ~= this or not this.cities[city.path] then
    return
  end
  local kind = event.type
  local cached = history.cache[city.path]
  if kind == 'mail.sent' or kind == 'mail.replied' then
    local m = event.message
    if not m then
      return load_city(city)
    end
    -- A copy already cached came from a load that listed the message
    if not (cached and cached.by_id and cached.by_id[m.id]) then
      history.put(city, m)
      live_changes[city.path] = live_changes[city.path] or {}
      -- `message` is the event's own table, cached as it is: later read and
      -- archive events mutate this same table and apply_live puts it back, so
      -- a copy here would lose what they changed while a load is in flight
      live_changes[city.path][m.id] = { at = vim.uv.hrtime(), target = m, message = m }
    end
    render_city(city, m)
  elseif kind == 'overflow' or kind == 'rotated' then
    -- A rotated reported twice joins the load still running (history.load)
    load_city(city)
  elseif READ_EVENTS[kind] ~= nil or CLOSED_EVENTS[kind] then
    local m = event.id and cached and cached.by_id and cached.by_id[event.id]
    if not m then
      return
    end
    local changed = false
    if READ_EVENTS[kind] ~= nil and m.read ~= READ_EVENTS[kind] then
      m.read = READ_EVENTS[kind]
      changed = true
    elseif CLOSED_EVENTS[kind] and not m.closed then
      m.closed = true
      changed = true
    end
    if changed then
      -- RS5: the event is newer than any action the chat had answered
      local at = vim.uv.hrtime()
      m.loaded_since = at
      live_changes[city.path] = live_changes[city.path] or {}
      local ch = live_changes[city.path][event.id] or {}
      live_changes[city.path][event.id] = ch
      ch.at, ch.target = at, m
      if READ_EVENTS[kind] ~= nil then
        ch.read = m.read
      else
        ch.closed = true
      end
      render_city(city, m)
    end
  end
end

local function close_handle(h)
  if h and not h:is_closing() then
    h:stop()
    h:close()
  end
end

-- The fallback: `entry`'s city loaded every poll period while it is watched.
local function start_timer(this, entry)
  local ms = poll_override or gc_mail.config.chat_poll_ms or 60000
  entry.timer = vim.uv.new_timer()
  entry.timer:start(ms, ms, function()
    vim.schedule(function()
      if live ~= this or this.cities[entry.city.path] ~= entry then
        return
      end
      load_city(entry.city)
    end)
  end)
end

local function stop_live()
  local this = live
  if not this then
    return
  end
  live = nil
  live_changes = {}
  for _, entry in pairs(this.cities) do
    close_handle(entry.timer)
  end
  this.cities = {}
  events.unsubscribe('chat')
end

-- Makes the watch match the open chats: their cities subscribed and timed,
-- nothing at all once none is open.
local function sync_live()
  local open = {}
  for _, tab_chats in pairs(chats) do
    for _, chat in pairs(tab_chats) do
      open[chat.city.path] = chat.city
    end
  end
  if next(open) == nil then
    return stop_live()
  end
  local this = live
  local first = this == nil
  if first then
    this = { cities = {} }
    live = this
  end
  for path, entry in pairs(this.cities) do
    if not open[path] then
      close_handle(entry.timer)
      this.cities[path] = nil
      live_changes[path] = nil
    end
  end
  local list = {}
  for path, city in pairs(open) do
    if not this.cities[path] then
      local entry = { city = { name = city.name, path = city.path } }
      this.cities[path] = entry
      start_timer(this, entry)
    end
    list[#list + 1] = this.cities[path].city
  end
  events.cities('chat', list)
  if first then
    events.subscribe('chat', function(city, event)
      on_event(this, city, event)
    end)
  end
end

local queue_subscribed = false

local function ensure_queue_subscriber()
  if queue_subscribed then
    return
  end
  queue_subscribed = true
  queue.subscribe('chat', function(held)
    if held and held.kind == 'delete' and held.record and held.record.city then
      -- A delivered send: its city loaded once, if a chat of it is open
      local c = held.record.city
      if live and type(c.path) == 'string' and live.cities[c.path] then
        load_city(live.cities[c.path].city)
      end
    else
      render_all()
    end
  end)
end

-- Drops the ids `chat` holds unread (RS4); one still waiting for gc's answer
-- is dropped when it comes
local function release_unreading(chat)
  for id, rec in pairs(reads) do
    if rec.phase == 'unreading' and rec.owner == chat then
      if rec.answered then
        reads[id] = nil
      else
        rec.release = true
      end
    end
  end
end

function M.close(chat)
  local k = key_of(chat.city, chat.with)
  local compose_key = chat.city.path .. '\0' .. chat.with
  local tab = chat.tab

  if vim.api.nvim_buf_is_valid(chat.compose_buf) then
    local lines = vim.api.nvim_buf_get_lines(chat.compose_buf, 0, -1, false)
    local text = vim.trim(table.concat(lines, '\n'))
    local kept = vim.tbl_filter(function(b)
      return b ~= chat.compose_buf and vim.api.nvim_buf_is_valid(b)
    end, saved_compose[compose_key] or {})
    if text == '' then
      pcall(vim.api.nvim_buf_delete, chat.compose_buf, { force = true })
    else
      kept[#kept + 1] = chat.compose_buf
    end
    saved_compose[compose_key] = #kept > 0 and kept or nil
  end

  -- A late second close never drops a newer chat opened under the same key
  if chats[tab] and chats[tab][k] == chat then
    chats[tab][k] = nil
    if next(chats[tab]) == nil then
      chats[tab] = nil
    end
  end
  sync_live()

  pcall(vim.api.nvim_del_augroup_by_id, chat.group)
  release_unreading(chat)

  if vim.api.nvim_win_is_valid(chat.timeline_win) then
    pcall(vim.api.nvim_win_close, chat.timeline_win, true)
  end
  if vim.api.nvim_win_is_valid(chat.compose_win) then
    pcall(vim.api.nvim_win_close, chat.compose_win, true)
  end

  if vim.api.nvim_win_is_valid(chat.origin) then
    pcall(vim.api.nvim_set_current_win, chat.origin)
  end
end

local function send_chat(chat)
  vim.cmd('stopinsert')
  local id = gc_mail.send(chat.compose_buf, chat.city, { to = chat.with })
  if id then
    M.render(chat)
  end
end

local function on_open_message(chat)
  if not valid_chat(chat) then
    return
  end
  local row = vim.api.nvim_win_get_cursor(chat.timeline_win)[1]
  for _, block in ipairs(chat.message_blocks) do
    if row >= block.start_line and row <= block.end_line and block.message then
      local entry = { city = chat.city, message = block.message, read = block.message.read }
      mailbox.actions.open(entry, split_target(chat))
      return
    end
  end
end

local function on_thread_message(chat)
  if not valid_chat(chat) then
    return
  end
  local row = vim.api.nvim_win_get_cursor(chat.timeline_win)[1]
  for _, block in ipairs(chat.message_blocks) do
    if row >= block.start_line and row <= block.end_line and block.message then
      local entry = { city = chat.city, message = block.message, read = block.message.read }
      mailbox.actions.thread(entry, split_target(chat))
      return
    end
  end
end

local function on_unread_message(chat)
  if not valid_chat(chat) then
    return
  end
  local row = vim.api.nvim_win_get_cursor(chat.timeline_win)[1]
  for _, block in ipairs(chat.message_blocks) do
    if row >= block.start_line and row <= block.end_line and block.message then
      local m = block.message
      local id, seq = m.id, next_seq()
      local was_read = m.read
      -- Held out of the automatic pass (RS3) until the chat is left (RS4)
      reads[id] = { phase = 'unreading', seq = seq, owner = chat }
      set_read(chat, m, false)
      local entry = { city = chat.city, message = m, read = false }
      mailbox.actions.unread(entry, function(ok, _, applied)
        local rec = current(id, seq)
        if not rec then
          return
        end
        rec.answered = vim.uv.hrtime()
        if not ok then
          if rec.release then
            -- Refused after the chat was left: no record outlives it
            reads[id] = nil
            set_read(chat, m, was_read)
          elseif not was_read then
            -- Refused on a message that was unread: it stays unread, and the
            -- record stays 'unreading' so the automatic pass (RS3) does not
            -- mark it read while this chat is open; leaving the chat (RS4)
            -- drops it
            set_read(chat, m, false)
          else
            rec.phase = 'read'
            rec.owner = nil
            set_read(chat, m, true)
          end
        elseif rec.release then
          -- RS4: the chat was left while this was pending
          reads[id] = nil
        end
        if ok and applied == false then
          -- RS2: a later action owns the message; gc's answer comes from a load
          reload(chat)
          return
        end
        if valid_chat(chat) then
          M.render(chat)
        end
      end)
      M.render(chat)
      return
    end
  end
end

function M.open(city_arg, with_arg)
  local cached = gc_mail.cached_cities()
  if not cached or #cached == 0 then
    gc_mail.refresh(function(refreshed, err)
      if refreshed and #refreshed > 0 then
        M.open(city_arg, with_arg)
      elseif refreshed then
        vim.notify('gc-mail: no cities are registered with gc', vim.log.levels.WARN)
      else
        vim.notify('gc-mail: ' .. tostring(err), vim.log.levels.ERROR)
      end
    end)
    return nil
  end

  local city, with = resolve_city_and_with(city_arg, with_arg)
  last_chat = { city = city, with = with }

  local tab = vim.api.nvim_get_current_tabpage()
  local k = key_of(city, with)
  if not chats[tab] then
    chats[tab] = {}
  end

  local existing = chats[tab][k]
  if valid_chat(existing) then
    vim.api.nvim_set_current_win(existing.compose_win)
    return existing
  end

  local origin = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(origin).relative ~= '' then
    vim.notify('gc-mail: the chat opens beside a normal window, not a floating one', vim.log.levels.WARN)
    return nil
  end

  local compose_key = city.path .. '\0' .. with
  local compose_buf
  for _, b in ipairs(saved_compose[compose_key] or {}) do
    -- Reuse a kept compose buffer: it is shown in no window of any tab page
    if vim.api.nvim_buf_is_valid(b) and #vim.fn.win_findbuf(b) == 0 then
      compose_buf = b
      break
    end
  end
  if not compose_buf then
    compose_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[compose_buf].buftype = 'nofile'
    vim.bo[compose_buf].swapfile = false
    vim.bo[compose_buf].modifiable = true
    vim.bo[compose_buf].filetype = 'markdown'
    set_buf_name_unique(compose_buf, ('gc-mail://%s/compose/%s'):format(city.name, with), tab)
  end

  local timeline_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[timeline_buf].buftype = 'nofile'
  vim.bo[timeline_buf].bufhidden = 'wipe'
  vim.bo[timeline_buf].modifiable = false
  vim.bo[timeline_buf].filetype = 'markdown'
  set_buf_name_unique(timeline_buf, ('gc-mail://%s/chat/%s'):format(city.name, with), tab)

  local chat_width = gc_mail.config.chat_width or 60
  local compose_height = gc_mail.config.chat_compose_height or 3

  local timeline_win = vim.api.nvim_open_win(timeline_buf, false, {
    split = 'right', win = origin, width = chat_width,
  })
  local compose_win = vim.api.nvim_open_win(compose_buf, true, {
    split = 'below', win = timeline_win, height = compose_height,
  })

  local wo_tl = vim.wo[timeline_win]
  wo_tl.winfixwidth = true
  wo_tl.statusline = TITLE

  local wo_cp = vim.wo[compose_win]
  wo_cp.winfixwidth = true
  wo_cp.winfixheight = true

  vim.cmd('stopinsert')

  local chat = {
    tab = tab,
    city = city,
    with = with,
    origin = origin,
    timeline_win = timeline_win,
    timeline_buf = timeline_buf,
    compose_win = compose_win,
    compose_buf = compose_buf,
    lines = {},
    message_blocks = {},
    -- Messages first shown below the view while it did not follow: id -> true
    below = {},
    just_opened = true,
  }

  chats[tab][k] = chat
  sync_live()

  local send_keys = gc_mail.config.chat_send_keys
  if send_keys ~= false and type(send_keys) == 'table' then
    for _, key in ipairs(send_keys) do
      vim.keymap.set('n', key, function() send_chat(chat) end, {
        buffer = compose_buf,
        nowait = true,
        silent = true,
        desc = 'gc-mail: send',
      })
    end
  end

  local tl_map = {
    { '<CR>', function() on_open_message(chat) end, 'gc-mail: open message' },
    { 't', function() on_thread_message(chat) end, 'gc-mail: open thread' },
    { 'u', function() on_unread_message(chat) end, 'gc-mail: mark unread' },
    { 'R', function()
      reload(chat)
    end, 'gc-mail: reload history' },
    { 'G', function()
      -- A count keeps G's own meaning: that line
      vim.cmd('normal! ' .. (vim.v.count > 0 and vim.v.count or '') .. 'G')
      update_below(chat)
    end, 'gc-mail: jump to the latest message' },
    { 'q', function() M.close(chat) end, 'gc-mail: close chat' },
  }
  for _, item in ipairs(tl_map) do
    vim.keymap.set('n', item[1], item[2], {
      buffer = timeline_buf,
      nowait = true,
      silent = true,
      desc = item[3],
    })
  end

  local group = vim.api.nvim_create_augroup(('gc_mail_chat_%d_%d'):format(timeline_win, compose_win), { clear = true })
  chat.group = group

  local closing = false
  local function on_win_closed()
    if not closing then
      closing = true
      vim.schedule(function()
        M.close(chat)
      end)
    end
  end

  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    pattern = tostring(timeline_win),
    callback = on_win_closed,
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    pattern = tostring(compose_win),
    callback = on_win_closed,
  })

  -- Reading down to a waiting message takes it off the count
  vim.api.nvim_create_autocmd('WinScrolled', {
    group = group,
    pattern = tostring(timeline_win),
    callback = function()
      update_below(chat)
    end,
  })
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = group,
    buffer = timeline_buf,
    callback = function()
      update_below(chat)
    end,
  })

  vim.api.nvim_create_autocmd('WinEnter', {
    group = group,
    callback = function()
      local cur = vim.api.nvim_get_current_win()
      if cur == timeline_win or cur == compose_win then
        check_mark_read(chat, nil, true)
      end
    end,
  })

  vim.api.nvim_create_autocmd('WinLeave', {
    group = group,
    callback = function()
      -- RS4: only leaving this chat's own windows counts, and only for the
      -- ids this chat holds
      local left = vim.api.nvim_get_current_win()
      if left ~= timeline_win and left ~= compose_win then
        return
      end
      -- Moving between the chat's own windows keeps it; the window entered
      -- is known only after the event
      vim.schedule(function()
        local cur = vim.api.nvim_get_current_win()
        if cur ~= timeline_win and cur ~= compose_win then
          release_unreading(chat)
        end
      end)
    end,
  })

  ensure_queue_subscriber()

  M.render(chat)

  reload(chat)

  return chat
end

function M.open_last()
  if last_chat then
    return M.open(last_chat.city.name, last_chat.with)
  else
    return M.open(nil, 'mayor')
  end
end

-- ---- the conversations list --------------------------------------------------

local CHATS_TITLE = ' gc mail chats: <CR> open  q close '
local CHATS_LOADING = ' loading… '

--- The conversations of the cached history of `city`, newest last message
--- first: { city, with, last (the newest message), unread (messages to human
--- not read) }. A conversation is the messages between human and one other
--- address (history.conversation's rule).
function M.conversations(city)
  local by_with, list = {}, {}
  for _, m in ipairs(history.messages(city)) do
    local with = (m.from == 'human' and m.to ~= 'human') and m.to or (m.to == 'human' and m.from ~= 'human') and m.from or nil
    if with then
      local c = by_with[with]
      if not c then
        c = { city = city, with = with, unread = 0 }
        by_with[with] = c
        list[#list + 1] = c
      end
      -- history.messages is oldest first: the last one seen is the newest
      c.last = m
      if m.to == 'human' and not m.read then
        c.unread = c.unread + 1
      end
    end
  end
  table.sort(list, function(a, b)
    if a.last.created ~= b.last.created then
      return a.last.created > b.last.created
    end
    return a.with < b.with
  end)
  return list
end

-- The rows of the list for `view` ({ cities, loaded (city path -> true once
-- its answer came), failed (city path -> error) }): every city's
-- conversations newest first, then a line for each city without one, so a
-- first chat can start from the list (the mayor), or says why it has none.
local function chat_rows(view)
  local conversations, bare = {}, {}
  for _, city in ipairs(view.cities) do
    local found = M.conversations(city)
    if #found > 0 then
      vim.list_extend(conversations, found)
    elseif view.failed[city.path] then
      bare[#bare + 1] = { city = city, error = view.failed[city.path] }
    elseif view.loaded[city.path] or history.cache[city.path] then
      bare[#bare + 1] = { city = city, with = 'mayor' }
    end
  end
  table.sort(conversations, function(a, b)
    if a.last.created ~= b.last.created then
      return a.last.created > b.last.created
    end
    if a.city.name ~= b.city.name then
      return a.city.name < b.city.name
    end
    return a.with < b.with
  end)
  return vim.list_extend(conversations, bare)
end

-- One line of the list: ` <unread or blank, 2 wide>  <city>  <with>  <subject>  <age> `
local function chat_line(row, now)
  local city = gc_mail.one_line(row.city.name)
  if row.error then
    return ('     %s  cannot load the history '):format(city)
  elseif not row.last then
    return ('     %s  %s  no messages yet '):format(city, gc_mail.one_line(row.with))
  end
  return (' %2s  %s  %s  %s  %s '):format(row.unread > 0 and tostring(row.unread) or '', city, gc_mail.one_line(row.with),
    gc_mail.one_line(row.last.subject), gc_mail.age(math.max(0, now - row.last.created)))
end

--- Opens the conversations float: every cached city's conversations, newest
--- first, with the unread count of each, at once from the history cache, and
--- one history load per city in the background that fills it in (` loading… `
--- while nothing is known). <CR> opens the chat of the line; q and <Esc> close.
function M.open_list()
  local cached = gc_mail.cached_cities()
  local view = { cities = cached or {}, loaded = {}, failed = {}, rows = {}, pending = 0 }
  local picker

  local function render()
    if not picker or picker.closed() then
      return
    end
    view.rows = chat_rows(view)
    local lines = {}
    local now = os.time()
    for i, row in ipairs(view.rows) do
      lines[i] = chat_line(row, now)
    end
    if #lines == 0 then
      lines = { view.pending > 0 and CHATS_LOADING or ' no conversations ' }
    end
    picker.set(lines)
  end

  picker = gc_mail.float(CHATS_TITLE, { CHATS_LOADING }, {
    ['<CR>'] = function(p, row)
      local entry = view.rows[row]
      if entry and entry.with then
        p.close()
        M.open(entry.city.name, entry.with)
      end
    end,
  }, { ['<CR>'] = 'open the chat' })

  local function load(city)
    view.pending = view.pending + 1
    history.load(city, function(_, err)
      view.pending = view.pending - 1
      if err then
        view.failed[city.path] = err
        if not picker.closed() then
          vim.notify('gc-mail: ' .. err, vim.log.levels.ERROR)
        end
      else
        view.loaded[city.path] = true
        view.failed[city.path] = nil
      end
      render()
    end)
  end

  local function start(cities)
    view.cities = cities
    for _, city in ipairs(cities) do
      load(city)
    end
    render()
  end

  if cached and #cached > 0 then
    -- What the cache holds shows at once; each city loads once, in the background
    start(cached)
  else
    view.pending = 1
    gc_mail.refresh(function(cities, err)
      view.pending = view.pending - 1
      if picker.closed() then
        return
      end
      if not cities then
        picker.close()
        return vim.notify('gc-mail: ' .. tostring(err), vim.log.levels.ERROR)
      elseif #cities == 0 then
        picker.close()
        return vim.notify('gc-mail: no cities are registered with gc', vim.log.levels.WARN)
      end
      start(cities)
    end)
  end
  return picker.win
end

function M.command(fargs)
  fargs = fargs or {}
  if #fargs > 2 then
    error('gc-mail: too many arguments for GcMailChat', 2)
  end
  return M.open(fargs[1], fargs[2])
end

function M.reset()
  for _, tab_chats in pairs(chats) do
    for _, chat in pairs(tab_chats) do
      if valid_chat(chat) then
        pcall(vim.api.nvim_win_close, chat.timeline_win, true)
        pcall(vim.api.nvim_win_close, chat.compose_win, true)
      end
    end
  end
  chats = {}
  last_chat = nil
  stop_live()
  poll_override = nil
  load_failed = {}
  for _, bufs in pairs(saved_compose) do
    for _, buf in ipairs(bufs) do
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end
  saved_compose = {}
  reads = {}
  if queue_subscribed then
    queue.subscribe('chat', nil)
    queue_subscribed = false
  end
end

return M
