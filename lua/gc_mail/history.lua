-- The mail history cache and bead-store loader for gc-mail.nvim.
--
-- Loads messages from `gc bd list` into an in-memory cache, indexed by city.
-- Messages include open and closed mail. Nothing runs at load time.
local queue = require('gc_mail.queue')
local mailbox = require('gc_mail.mailbox')
local gc = require('gc_mail.gc')

local M = {}

M.cache = {}

local defaults = {
  days = nil,
  timeout_ms = 10000,
}

local config = vim.deepcopy(defaults)
local inflight = {}
local said_skipped = {}

local function notify(message, level)
  vim.notify('gc-mail: ' .. message, level or vim.log.levels.WARN)
end

function M.configure(opts)
  config = vim.tbl_extend('force', config, opts or {})
end

function M.reset()
  M.cache = {}
  said_skipped = {}
  inflight = {}
end

local function all_strings(list)
  for _, item in ipairs(list) do
    if type(item) ~= 'string' then
      return false
    end
  end
  return true
end

--- Messages oldest first: created, then id.
function M.by_created(a, b)
  if a.created ~= b.created then
    return a.created < b.created
  end
  return a.id < b.id
end

--- Entries newest first: created, then city name, then id. An entry is a
--- mailbox or search entry ({ city, message }) or a conversation
--- ({ city, with, last }); for a conversation the last message gives the
--- created and the correspondent gives the final key.
function M.newest_first(a, b)
  local am = a.message or a.last
  local bm = b.message or b.last
  if am.created ~= bm.created then
    return am.created > bm.created
  end
  if a.city.name ~= b.city.name then
    return a.city.name < b.city.name
  end
  local ai = a.message and a.message.id or a.with
  local bi = b.message and b.message.id or b.with
  return ai < bi
end

--- The other side of message `m`: its non-human sender or recipient, or
--- nil when neither side is human or both are.
function M.correspondent(m)
  if m.from == 'human' and m.to ~= 'human' then
    return m.to
  end
  if m.to == 'human' and m.from ~= 'human' then
    return m.from
  end
  return nil
end

-- The one strict decoder of the bd-list shape (I1): one element as gc
-- prints it, with `started` stamped on the message, or nil when the
-- element is not a message this plugin can read.
local function bead_message(elem, started)
  if type(elem) ~= 'table' then
    return nil
  end
  if type(elem.id) ~= 'string' or not queue.mail_id(elem.id) then
    return nil
  end
  if type(elem.title) ~= 'string' then
    return nil
  end
  if type(elem.sender) ~= 'string' or elem.sender == '' then
    return nil
  end
  if type(elem.status) ~= 'string' then
    return nil
  end
  if type(elem.created_at) ~= 'string' or not mailbox.epoch(elem.created_at) then
    return nil
  end
  if elem.description ~= nil and type(elem.description) ~= 'string' then
    return nil
  end
  if elem.metadata ~= nil and type(elem.metadata) ~= 'table' then
    return nil
  end
  if elem.labels ~= nil then
    if type(elem.labels) ~= 'table' or not vim.islist(elem.labels) or not all_strings(elem.labels) then
      return nil
    end
  end
  local recipient = nil
  if type(elem.assignee) == 'string' and elem.assignee ~= '' then
    recipient = elem.assignee
  elseif elem.assignee == nil or elem.assignee == vim.NIL or elem.assignee == '' then
    if elem.metadata and type(elem.metadata) == 'table'
        and type(elem.metadata['gc.routed_to']) == 'string' and elem.metadata['gc.routed_to'] ~= '' then
      recipient = elem.metadata['gc.routed_to']
    else
      return nil
    end
  else
    return nil
  end
  local thread_id = nil
  local reply_to = nil
  local has_read_label = false
  if elem.labels then
    for _, lbl in ipairs(elem.labels) do
      if thread_id == nil then
        local tid = lbl:match('^thread:(.*)$')
        if tid and queue.thread_id(tid) then
          thread_id = tid
        end
      end
      if reply_to == nil then
        local rid = lbl:match('^reply%-to:(.*)$')
        if rid and queue.mail_id(rid) then
          reply_to = rid
        end
      end
      if lbl == 'read' then
        has_read_label = true
      end
    end
  end
  local closed = (elem.status == 'closed')
  local read = (closed or has_read_label or (elem.metadata and elem.metadata['mail.read'] == 'true')) and true or false
  local msg = mailbox.message({
    id = elem.id,
    from = elem.sender,
    to = recipient,
    subject = elem.title,
    body = elem.description or '',
    created_at = elem.created_at,
    read = read,
    thread_id = thread_id,
  })
  if not msg then
    return nil
  end
  msg.closed = closed
  msg.reply_to = reply_to
  msg.loaded_since = started
  return msg
end

--- Loads mail history for `city` from the bead store:
---   gc --city <path> bd list --type message --all --json --limit 0 --created-after <T>
--- or with `opts.thread` set:
---   gc --city <path> bd list --type message --all --json --limit 0 -l thread:<id>
--- `on_done(list, err, skipped)` runs on the main loop. Every message it
--- caches carries `loaded_since`, the vim.uv.hrtime() at which the gc call that
--- listed it started (a joined load keeps the running call's stamp); a load
--- of the whole history stamps the city's cache entry the same way.
function M.load(city, opts, on_done)
  if type(opts) == 'function' and on_done == nil then
    on_done = opts
    opts = {}
  else
    opts = opts or {}
  end

  if opts.thread ~= nil then
    if not queue.thread_id(opts.thread) then
      return on_done(nil, 'not a gc thread id')
    end
  end

  local inflight_key = city.path .. '\0' .. (opts.thread or '')
  if inflight[inflight_key] then
    inflight[inflight_key][#inflight[inflight_key] + 1] = on_done
    return
  end
  inflight[inflight_key] = { on_done }
  -- The stamp is the call's own; a caller that joins it shares the stamp
  local started = vim.uv.hrtime()

  local argv
  if opts.thread then
    argv = { 'gc', '--city', city.path, 'bd', 'list', '--type', 'message', '--all', '--json', '--limit', '0', '-l', 'thread:' .. opts.thread }
  else
    local days = config.days or require('gc_mail').config.history_days
    local cutoff = os.time() - days * 86400
    local t_stamp = os.date('!%Y-%m-%dT%H:%M:%SZ', cutoff)
    argv = { 'gc', '--city', city.path, 'bd', 'list', '--type', 'message', '--all', '--json', '--limit', '0', '--created-after', t_stamp }
  end

  local timeout_ms = config.timeout_ms
  local what = ('gc bd list in %s'):format(city.name)

  local function finish(list, err, skipped)
    local waiters = inflight[inflight_key]
    inflight[inflight_key] = nil
    if waiters then
      for _, cb in ipairs(waiters) do
        cb(list, err, skipped)
      end
    end
  end

  gc.run(argv, timeout_ms, what, function(result, err)
    if err then
      return finish(nil, err)
    end

    local decoded_ok, raw_list = pcall(vim.json.decode, result.stdout or '')
    if not decoded_ok or type(raw_list) ~= 'table' or not vim.islist(raw_list) then
      return finish(nil, what .. ' printed something unexpected')
    end

    local list = {}
    local skipped = 0
    for _, elem in ipairs(raw_list) do
      local msg = bead_message(elem, started)
      if not msg then
        skipped = skipped + 1
      else
        list[#list + 1] = msg
      end
    end

    table.sort(list, M.by_created)

    if opts.thread then
      local cache_entry = M.cache[city.path]
      if not cache_entry then
        cache_entry = { by_id = {} }
        M.cache[city.path] = cache_entry
      end
      for _, msg in ipairs(list) do
        cache_entry.by_id[msg.id] = msg
      end
    else
      local by_id = {}
      for _, msg in ipairs(list) do
        by_id[msg.id] = msg
      end
      M.cache[city.path] = { by_id = by_id, loaded_since = started }
    end

    if skipped > 0 and not said_skipped[city.path] then
      said_skipped[city.path] = true
      notify(('%d messages could not be read'):format(skipped), vim.log.levels.WARN)
    end

    finish(list, nil, skipped)
  end)
end

--- Inserts or replaces one message in the cache.
function M.put(city, message)
  local entry = M.cache[city.path]
  if not entry then
    entry = { by_id = {} }
    M.cache[city.path] = entry
  end
  entry.by_id[message.id] = message
end

--- Returns the cached list oldest first.
function M.messages(city)
  local entry = M.cache[city.path]
  if not entry then
    return {}
  end
  local list = {}
  for _, m in pairs(entry.by_id) do
    list[#list + 1] = m
  end
  table.sort(list, M.by_created)
  return list
end

--- Returns the subset of messages with (from == with and to == 'human') or
--- (from == 'human' and to == with), oldest first.
function M.conversation(city, with)
  local all = M.messages(city)
  local list = {}
  for _, m in ipairs(all) do
    local other = M.correspondent(m)
    if other and other == with then
      list[#list + 1] = m
    end
  end
  return list
end

return M
