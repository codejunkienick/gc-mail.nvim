-- The shared Gas City event-log watcher of gc-mail.nvim.
--
-- Serves every live view: the panel today, the chat and background watch
-- later. Subscribers get decoded mail.* events instead of each view watching
-- the files itself. Nothing runs at load time; nothing runs while no
-- subscriber exists; every handle is closed when the last subscriber leaves;
-- callbacks never touch a stopped watch.
local queue = require('gc_mail.queue')
local mailbox = require('gc_mail.mailbox')

local M = {}

local uv = vim.uv

local MAX_READ = 1024 * 1024

local function default_events_rearm_ms()
  local ok, gc_mail = pcall(require, 'gc_mail')
  return (ok and gc_mail.config and gc_mail.config.events_rearm_ms) or 60000
end

local config = {
  rearm_ms = 1000,
  events_rearm_ms = default_events_rearm_ms(),
}

local live
local subscribers = {}
local subscriber_cities = {}
local subscriber_errors = {}

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

local function subscriber_has_city(name, city_path)
  local list = subscriber_cities[name]
  if not list then
    return false
  end
  for _, c in ipairs(list) do
    if c.path == city_path then
      return true
    end
  end
  return false
end

local function dispatch(this, city, event)
  vim.schedule(function()
    if live ~= this then
      return
    end
    for name, fn in pairs(subscribers) do
      if subscriber_has_city(name, city.path) then
        local ok, err = pcall(fn, city, event)
        if not ok and not subscriber_errors[name] then
          subscriber_errors[name] = true
          vim.notify('gc-mail: subscriber ' .. name .. ' failed: ' .. tostring(err), vim.log.levels.ERROR)
        end
      end
    end
  end)
end

--- Whether one line of the event log is a mail event: a JSON object whose
--- type is a string starting with `mail.`. Anything else is false, never an
--- error.
function M.mail_event(line)
  local ok, event = pcall(vim.json.decode, line)
  return ok and type(event) == 'table' and type(event.type) == 'string' and event.type:sub(1, 5) == 'mail.'
end

local on_change

local function arm(this, w)
  close_handle(w.event)
  w.event, w.carry = nil, ''
  local stat = uv.fs_stat(w.path)
  if not stat or stat.type ~= 'file' then
    return false
  end
  local event = uv.new_fs_event()
  if not event then
    return false
  end
  handle(this, event)
  local ok = event:start(w.path, {}, function()
    if w.queued then
      return
    end
    w.queued = true
    vim.schedule(function()
      w.queued = false
      on_change(this, w)
    end)
  end)
  if not ok then
    event:close()
    return false
  end
  w.event, w.ino, w.dev, w.offset = event, stat.ino, stat.dev, stat.size
  return true
end

local function rotated(this, w)
  if arm(this, w) then
    return dispatch(this, w.city, { type = 'rotated' })
  end
  w.rearm:start(config.rearm_ms or 1000, 0, function()
    vim.schedule(function()
      if live == this and not w.stopped and arm(this, w) then
        dispatch(this, w.city, { type = 'rotated' })
      end
    end)
  end)
end

local function process_line(this, w, line)
  local ok, raw = pcall(vim.json.decode, line)
  if not ok or type(raw) ~= 'table' or type(raw.type) ~= 'string' or raw.type:sub(1, 5) ~= 'mail.' then
    return
  end
  local id = nil
  if type(raw.subject) == 'string' and queue.mail_id(raw.subject) then
    id = raw.subject
  end
  local actor = nil
  if type(raw.actor) == 'string' then
    actor = raw.actor
  end
  local message = nil
  if type(raw.payload) == 'table' and type(raw.payload.message) == 'table' then
    message = mailbox.message(raw.payload.message)
  end
  local event = {
    type = raw.type,
    id = id,
    actor = actor,
    message = message,
  }
  dispatch(this, w.city, event)
end

local function scan(this, w, data)
  local text = w.carry .. data
  local start = 1
  while true do
    local nl = text:find('\n', start, true)
    if not nl then
      break
    end
    local line = text:sub(start, nl - 1)
    start = nl + 1
    process_line(this, w, line)
  end
  w.carry = text:sub(start)
  if #w.carry > MAX_READ then
    w.carry = ''
    dispatch(this, w.city, { type = 'overflow' })
  end
end

on_change = function(this, w)
  if live ~= this or w.stopped or not w.event then
    return
  end
  local fd = uv.fs_open(w.path, 'r', 0)
  local stat = fd and uv.fs_fstat(fd)
  if not stat or stat.ino ~= w.ino or stat.dev ~= w.dev or stat.size < w.offset then
    if fd then
      uv.fs_close(fd)
    end
    return rotated(this, w)
  end
  local size = stat.size - w.offset
  if size > MAX_READ then
    w.offset, w.carry = stat.size, ''
    uv.fs_close(fd)
    return dispatch(this, w.city, { type = 'overflow' })
  elseif size > 0 then
    local data = uv.fs_read(fd, size, w.offset)
    if data then
      w.offset = w.offset + #data
      scan(this, w, data)
    end
  end
  uv.fs_close(fd)
end

local function rearm_missing(this)
  if live ~= this then
    return
  end
  for _, w in pairs(this.cities) do
    if not w.event and not w.stopped then
      local had_ino = w.ino ~= nil
      if arm(this, w) then
        if w.rearm and w.rearm:is_active() then
          w.rearm:stop()
        end
        if had_ino then
          dispatch(this, w.city, { type = 'rotated' })
        end
      end
    end
  end
end

local function stop()
  local this = live
  if not this then
    return
  end
  live = nil
  for _, w in pairs(this.cities) do
    w.stopped = true
    close_handle(w.event)
    close_handle(w.rearm)
  end
  this.cities = {}
  close_handle(this.timer)
  for _, h in ipairs(this.handles) do
    close_handle(h)
  end
end

local function reconcile(this)
  if not this then
    return
  end
  if next(subscribers) == nil then
    stop()
    return
  end

  local union = {}
  for name, _ in pairs(subscribers) do
    for _, city in ipairs(subscriber_cities[name] or {}) do
      union[city.path] = city
    end
  end

  if next(union) == nil then
    for _, w in pairs(this.cities) do
      w.stopped = true
      close_handle(w.event)
      close_handle(w.rearm)
    end
    this.cities = {}
    close_handle(this.timer)
    this.timer = nil
    return
  end

  if not this.timer or this.timer:is_closing() then
    local poll = config.events_rearm_ms or 60000
    this.timer = handle(this, uv.new_timer())
    this.timer:start(poll, poll, function()
      vim.schedule(function()
        if live ~= this then
          return
        end
        rearm_missing(this)
      end)
    end)
  end

  for path, w in pairs(this.cities) do
    if not union[path] then
      w.stopped = true
      close_handle(w.event)
      close_handle(w.rearm)
      this.cities[path] = nil
    end
  end

  for path, city in pairs(union) do
    if not this.cities[path] then
      local w = {
        city = { name = city.name, path = city.path },
        path = city.path .. '/.gc/events.jsonl',
        offset = 0,
        carry = '',
        stopped = false,
        rearm = handle(this, uv.new_timer()),
      }
      this.cities[path] = w
      arm(this, w)
    end
  end
end

function M.configure(opts)
  config = vim.tbl_extend('force', config, opts or {})
  if live and live.timer and not live.timer:is_closing() and opts and opts.events_rearm_ms then
    live.timer:stop()
    live.timer:start(config.events_rearm_ms, config.events_rearm_ms, function()
      vim.schedule(function()
        if live then
          rearm_missing(live)
        end
      end)
    end)
  end
end

function M.subscribe(name, fn)
  if fn == nil then
    return M.unsubscribe(name)
  end
  subscribers[name] = fn
  subscriber_errors[name] = nil
  if not live then
    live = { cities = {}, handles = {} }
  end
  reconcile(live)
end

function M.unsubscribe(name)
  subscribers[name] = nil
  subscriber_errors[name] = nil
  subscriber_cities[name] = nil
  if live then
    reconcile(live)
  end
end

function M.cities(name, cities)
  subscriber_cities[name] = cities
  if live then
    reconcile(live)
  end
end

function M.rearm()
  if live then
    rearm_missing(live)
  end
end

function M.running()
  return live ~= nil and next(subscribers) ~= nil and next(live.cities) ~= nil
end

function M.handles()
  if not live then
    return {}
  end
  return vim.tbl_filter(function(h)
    return not h:is_closing()
  end, live.handles)
end

function M.reset()
  stop()
  subscribers = {}
  subscriber_cities = {}
  subscriber_errors = {}
  config = {
    rearm_ms = 1000,
    events_rearm_ms = default_events_rearm_ms(),
  }
end

return M
