-- The background watch of gc-mail.nvim: on by default (watch = false turns it
-- off). After startup it follows every city's event log through gc_mail.events,
-- says "gc-mail: <from> in <city>: <subject>" when mail for you arrives, keeps
-- an unread count per city that the events move, and M.status() hands the
-- total to a statusline. No polling: gc counts the unread mail once per city
-- at start, after an overflow or a rotated log, and every resync_ms.
--
-- Nothing runs at load time and nothing runs until start(); callbacks check
-- that their watch is still the live one before they touch it.
local events = require('gc_mail.events')
local mailbox = require('gc_mail.mailbox')

local M = {}

local uv = vim.uv

local RECIPIENT = 'human'
local SUBJECT_MAX = 72
local config = {
  resync_ms = nil, -- default: gc_mail.config.watch_resync_ms
}

--- City path -> unread mail of that city, as seeded by gc and moved by the
--- events since. A city without a good seed has no entry.
M.unread = {}

-- The running watch: { cities (path -> w), timer }.
-- In watch.lua, w = { city, busy (a count call in flight), again (count once
-- more when it ends), known (id -> true, unread messages the events told of),
-- seen (id -> true) and order (ids in the order seen), said (last error shown) }.
local live

local function gc_mail()
  return require('gc_mail')
end

local function resync_ms()
  return config.resync_ms or gc_mail().config.watch_resync_ms
end

local seed

-- (Re)starts the one resync timer of `this`.
local function arm_timer(this)
  local ms = resync_ms()
  this.timer = this.timer or uv.new_timer()
  this.timer:start(ms, ms, function()
    vim.schedule(function()
      if live ~= this then
        return
      end
      for _, w in pairs(this.cities) do
        seed(this, w)
      end
    end)
  end)
end

function M.configure(opts)
  config = vim.tbl_extend('force', config, opts or {})
  if live and live.timer and opts and opts.resync_ms then
    arm_timer(live)
  end
end

-- A statusline shows status() only when it is drawn: ask for that when a
-- count changes.
local function redraw()
  pcall(vim.api.nvim_command, 'redrawstatus')
end

local function say(w, message)
  if w.said ~= message then
    w.said = message
    vim.notify('gc-mail: ' .. message, vim.log.levels.ERROR)
  end
end

-- Counts w's city again, unless a count of it is already in flight: then once
-- more when that one ends.
seed = function(this, w)
  if w.busy then
    w.again = true
    return
  end
  w.busy = true
  mailbox.run(w.city, 'count', RECIPIENT, function(unread, err)
    w.busy = false
    if live ~= this or w.stopped then
      return
    end
    if unread then
      w.said = nil
      M.unread[w.city.path] = unread
      redraw()
    else
      say(w, err)
    end
    if w.again then
      w.again = false
      seed(this, w)
    end
  end)
end

-- Whether the chat of this city and `from` is open and current: it shows the
-- message itself. The chat is not required here.
local function in_chat(city, from)
  local chat = package.loaded['gc_mail.chat']
  if type(chat) ~= 'table' or type(chat.is_current) ~= 'function' then
    return false
  end
  local ok, current = pcall(chat.is_current, city, from)
  return ok and current == true
end

local function bump(w, by)
  local path = w.city.path
  if M.unread[path] ~= nil then
    M.unread[path] = math.max(0, M.unread[path] + by)
    redraw()
  end
end

local function arrived(this, w, message)
  if w.seen[message.id] then
    return
  end
  w.seen[message.id] = true
  w.known[message.id] = true
  bump(w, 1)
  -- A count that is being made may or may not include this message: the one
  -- after it settles the number.
  if w.busy then
    w.again = true
  end
  if not in_chat(w.city, message.from) then
    local one_line = gc_mail().one_line
    local subject = vim.fn.strcharpart(one_line(message.subject), 0, SUBJECT_MAX)
    vim.notify(('gc-mail: %s in %s: %s'):format(one_line(message.from), one_line(w.city.name), subject),
      vim.log.levels.INFO)
  end
end

local ARRIVALS = { ['mail.sent'] = true, ['mail.replied'] = true }
local GONE = { ['mail.read'] = true, ['mail.marked_read'] = true, ['mail.archived'] = true, ['mail.deleted'] = true }

local function on_event(this, city, event)
  local w = this.cities[city.path]
  if live ~= this or not w or w.stopped then
    return
  end
  local kind = event.type
  if kind == 'overflow' or kind == 'rotated' then
    return seed(this, w)
  end
  if ARRIVALS[kind] then
    local m = event.message
    if m and m.to == RECIPIENT and m.from ~= RECIPIENT then
      arrived(this, w, m)
    end
  elseif event.id and GONE[kind] then
    if w.known[event.id] then
      w.known[event.id] = nil
      bump(w, -1)
    end
  elseif event.id and kind == 'mail.marked_unread' then
    if not w.known[event.id] then
      w.known[event.id] = true
      bump(w, 1)
    end
  end
end

-- Pushes the watched cities to the event watcher.
local function publish(this)
  local list = {}
  for _, w in pairs(this.cities) do
    list[#list + 1] = w.city
  end
  table.sort(list, function(a, b)
    return a.path < b.path
  end)
  events.cities('watch', list)
end

-- Watches the cities not watched yet and counts each of them once.
local function add_cities(this, cities)
  local added = {}
  for _, city in ipairs(cities or {}) do
    if not this.cities[city.path] then
      local w = {
        city = { name = city.name, path = city.path },
        known = {}, seen = {},
      }
      this.cities[city.path] = w
      added[#added + 1] = w
    end
  end
  if #added == 0 then
    return
  end
  publish(this)
  for _, w in ipairs(added) do
    seed(this, w)
  end
end

--- Starts the watch (once): the cached cities now, every city a later list
--- brings as it arrives.
function M.start()
  if live then
    return
  end
  local this = { cities = {} }
  live = this
  M.unread = {}
  events.subscribe('watch', function(city, event)
    on_event(this, city, event)
  end)
  add_cities(this, gc_mail().cached_cities())
  gc_mail().refresh(function(cities)
    if live == this then
      add_cities(this, cities)
    end
  end)
  arm_timer(this)
end

--- Stops the watch: unsubscribes, stops the timer, forgets the counts.
function M.stop()
  local this = live
  if not this then
    return
  end
  live = nil
  M.unread = {}
  for _, w in pairs(this.cities) do
    w.stopped = true
  end
  events.unsubscribe('watch')
  if this.timer and not this.timer:is_closing() then
    this.timer:stop()
    this.timer:close()
  end
end

function M.running()
  return live ~= nil
end

--- '' for no unread mail or a stopped watch, else ' <total>' across cities.
--- Reads what is counted already; it runs nothing.
function M.status()
  if not live then
    return ''
  end
  local total = 0
  for _, n in pairs(M.unread) do
    total = total + n
  end
  return total > 0 and (' ' .. total) or ''
end

function M.reset()
  M.stop()
  config = { resync_ms = nil }
end

return M
