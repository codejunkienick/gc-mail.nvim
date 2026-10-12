-- The gc-mail mailbox: the mail addressed to `human` in every city the
-- plugin lists, read and acted on from Neovim.
--
-- Opening it runs one `gc --city <path> mail inbox human --json` per city, in
-- the background; nothing runs while the plugin loads. That lists unread mail
-- only, and gc 1.4.1 lists no read mail from its command line; its
-- nudge-mail-sweep (every 5 minutes) also closes read mail sent more than an
-- hour ago. So every message read here (opened, or marked read) is kept on
-- disk too, one JSON file per message in <state_dir>/mailbox/, and listed
-- until it is archived or deleted here: a mayor's answer stays in the mailbox
-- after it was read, across restarts and compactions. The mail panel
-- (gc_mail.panel) is a second view of this same state (M.subscribe).
--
-- All-mail mode (H, one flag for both views) also lists every message to
-- `human` in the mail history (gc_mail.history: read and closed mail, from
-- `gc bd list`). Marks (x) live here too, by message, so both views show
-- them; a, d, m and u act on a visual selection, else the marked set, else
-- the message under the cursor. A bulk archive or delete is one gc call per
-- city naming every id; mark read and unread run one call per id (gc takes
-- one).
--
-- Two invariants hold every gc answer to what it can change:
--
-- I1 DECODE: every `gc mail <verb> --json` answer passes the one decoder of
--    its shape (DECODE) before any code reads it. A decoder requires every
--    field the code reads, with its type (`gc --json-schema=result mail
--    <verb>`): message and thread ids match the whole id gc prints
--    (queue.mail_id, queue.thread_id), counts are non-negative integers, an
--    action answer names its command, action and every message asked about
--    (a bulk archive or delete asks about several). Anything else
--    is nil and a reason; the caller says it and keeps what is on screen.
--    The argument a call puts in argv passes the same id check first, so
--    nothing that could parse as an option ever reaches gc.
-- I2 APPLY: every answer that changes what the mailbox shows or keeps goes
--    through current(): one clock, and per message the clock of the last
--    read, unread, archive or delete started here and of the last one
--    started or applied. An action answer applies (apply()) only when no
--    later action on its message started after its call; an inbox answer
--    takes a message only when nothing was started or applied on it since
--    its call started, and otherwise leaves it as the mailbox has it. So a
--    late answer never brings back, or keeps a copy of, a message archived,
--    deleted or changed since, and never drops one whose action then fails.
local queue = require('gc_mail.queue')

local M = {}

local uv = vim.uv

local config = {
  dir = nil, -- <state_dir>/mailbox, set by configure() (default: from gc_mail.config)
  timeout_ms = 10000,
  notify = function(message, level)
    vim.notify('gc-mail: ' .. message, level or vim.log.levels.INFO)
  end,
}

function M.configure(opts)
  config = vim.tbl_extend('force', config, opts or {})
end

local function dir()
  return config.dir or (require('gc_mail').config.state_dir .. '/mailbox')
end
M.dir = dir

local first_lines = queue.first_lines
local RECIPIENT = 'human'
local TITLE = ' gc mail: <CR> open  r reply  t thread  c chat  s search  x mark  m read  u unread  a archive  d delete  H all  R refresh '
local TITLE_ALL = ' all mail  <CR> open  r reply  t thread  c chat  s search  x mark  m read  u unread  a archive  d delete  H all  R refresh '
local LOADING = ' loading… '
local EMPTY = ' no mail '
local KEYS_HINT = 'r reply  t thread  c chat  u unread  a archive  d delete  q close'
local READ_NOTE = 'Read mail stays in this mailbox until you archive or delete it; gc closes read mail an hour after it was sent.'

-- What each key of the mailbox float, the panel and the message view does, for
-- the desc of its mapping (all start with `gc-mail: ` once mapped).
M.KEY_DESC = {
  ['<CR>'] = 'open message', r = 'reply', t = 'open thread', c = 'open chat with the sender', m = 'mark read',
  u = 'mark unread', a = 'archive', d = 'delete', p = 'toggle preview', R = 'refresh', q = 'close',
  s = 'search the mail history',
}

local function notify(message, level)
  config.notify(message, level)
end

-- ---- time ----------------------------------------------------------------

-- Days from 1970-01-01 to the civil date y-m-d (proleptic Gregorian).
local function days_from_civil(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * ((m + 9) % 12) + 2) / 5) + d - 1
  return era * 146097 + yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy - 719468
end

--- Seconds since the epoch of an RFC 3339 time as gc prints it
--- (2026-10-07T14:00:01Z, fractions and numeric offsets allowed), or nil.
function M.epoch(text)
  if type(text) ~= 'string' then
    return nil
  end
  local y, mo, d, h, mi, s, rest = text:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$')
  if not y then
    return nil
  end
  y, mo, d, h, mi, s = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s)
  if mo < 1 or mo > 12 or d < 1 or d > 31 or h > 23 or mi > 59 or s > 60 then
    return nil
  end
  rest = rest:gsub('^%.%d+', '')
  local offset = 0
  if rest ~= 'Z' then
    local sign, oh, om = rest:match('^([+-])(%d%d):(%d%d)$')
    if not sign then
      return nil
    end
    offset = (tonumber(oh) * 60 + tonumber(om)) * 60 * (sign == '+' and 1 or -1)
  end
  return days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s - offset
end

-- ---- gc answers ----------------------------------------------------------

local function decode(text)
  return pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
end

local function whole(n)
  return type(n) == 'number' and n >= 0 and n == math.floor(n) and n < 2 ^ 53
end

local function strings(list)
  if type(list) ~= 'table' or not vim.islist(list) then
    return false
  end
  for _, item in ipairs(list) do
    if type(item) ~= 'string' then
      return false
    end
  end
  return true
end

--- I1: the message in `m` as gc prints it (mail_message), or nil and why.
function M.message(m)
  if type(m) ~= 'table' then
    return nil, 'a message is not an object'
  end
  for _, key in ipairs({ 'id', 'from', 'to', 'subject', 'body', 'created_at' }) do
    if type(m[key]) ~= 'string' then
      return nil, 'a message has no ' .. key
    end
  end
  if not queue.mail_id(m.id) then
    return nil, 'a message id is not a gc mail id'
  end
  if type(m.read) ~= 'boolean' then
    return nil, 'a message has no read flag'
  end
  if m.thread_id ~= nil and not queue.thread_id(m.thread_id) then
    return nil, 'a message thread_id is not a gc thread id'
  end
  local created = M.epoch(m.created_at)
  if not created then
    return nil, 'a message has a bad created_at'
  end
  return {
    id = m.id, from = m.from, to = m.to, subject = m.subject, body = m.body, created_at = m.created_at,
    created = created, read = m.read, thread_id = m.thread_id,
  }
end

-- A JSON array of messages; an object, empty or not, is no list (decode
-- marks an empty one with vim.empty_dict's metatable, so vim.islist is false).
local function messages_of(list)
  if type(list) ~= 'table' or not vim.islist(list) then
    return nil, 'no message list'
  end
  local result = {}
  for i, m in ipairs(list) do
    local message, why = M.message(m)
    if not message then
      return nil, why
    end
    result[i] = message
  end
  return result
end

--- The record of a finished `gc ... --json` (a vim.system result), or nil
--- and the reason. `what` names the call in the reason. Only the envelope:
--- the fields of the answer are DECODE's.
function M.answer(result, what)
  if result == nil or (result.code == 124 and (result.signal or 0) ~= 0) then
    return nil, ('%s did not answer within %g s'):format(what, config.timeout_ms / 1000)
  end
  local line = vim.trim(result.stdout or '')
  local ok, record = decode(line)
  if result.code ~= 0 then
    -- gc puts the reason on stderr; its JSON failure says only that it failed.
    local detail = first_lines(result.stderr, 3)
    if detail == '' and ok and type(record) == 'table' and type(record.error) == 'table'
        and type(record.error.message) == 'string' then
      detail = first_lines(record.error.message, 3)
    end
    return nil, what .. ' failed' .. (detail ~= '' and (': ' .. detail) or (' (exit ' .. tostring(result.code) .. ')'))
  end
  if line == '' or line:find('\n') or not ok or type(record) ~= 'table' or record.ok ~= true
      or record.schema_version ~= '1' then
    return nil, what .. ' printed something unexpected'
  end
  return record
end

-- An action answer (mail_action): the command and action of `verb`, every
-- message asked about (one id, or the list of a bulk archive or delete)
-- among `ids`, and a count; mark-read and mark-unread also name it as `id`
-- and count at least one.
local function action_of(verb)
  local marks = verb == 'mark-read' or verb == 'mark-unread'
  return function(record, arg)
    if record.command ~= 'mail.' .. verb or record.action ~= verb then
      return nil, 'it is not a ' .. verb .. ' answer'
    end
    if not strings(record.ids) or (marks and record.id ~= arg) then
      return nil, 'it did not name the message'
    end
    local asked = type(arg) == 'table' and arg or { arg }
    for _, id in ipairs(asked) do
      if not vim.tbl_contains(record.ids, id) then
        return nil, #asked == 1 and 'it did not name the message' or ('it did not name ' .. id)
      end
    end
    if not whole(record.count) or (marks and record.count < 1) then
      return nil, 'no count'
    end
    return true
  end
end

--- I1: one decoder per answer shape. Each takes the record (M.answer) and
--- the argument of the call and returns the value its caller uses, or nil
--- and why. run() reads no answer any other way.
local DECODE = {
  inbox = function(record)
    if not strings(record.recipients) then
      return nil, 'no recipients'
    end
    return messages_of(record.messages)
  end,
  -- gc answers a message id with that message's thread-<hex>; it echoes the
  -- argument only when it found no such thread, so an echoed message id is
  -- no thread either.
  thread = function(record, id)
    if not queue.thread_id(record.thread_id) then
      return nil, 'no thread_id'
    end
    if queue.thread_id(id) and record.thread_id ~= id then
      return nil, 'it answered for another thread'
    end
    return messages_of(record.messages)
  end,
  read = function(record, id)
    local message, why = M.message(record.message)
    if message and message.id ~= id then
      return nil, 'it answered for another message'
    end
    return message, why
  end,
  count = function(record)
    if type(record.recipient) ~= 'string' or not strings(record.recipients) then
      return nil, 'no recipient'
    end
    if not whole(record.total) or not whole(record.unread) then
      return nil, 'no total and unread count'
    end
    return record.unread
  end,
}
for _, verb in ipairs({ 'mark-read', 'mark-unread', 'archive', 'delete' }) do
  DECODE[verb] = action_of(verb)
end
M.DECODE = DECODE

-- The argument each verb puts in argv, checked before the call (I1).
local function recipient(arg)
  return arg == RECIPIENT
end
local function thread_arg(arg)
  return queue.thread_id(arg) or queue.mail_id(arg)
end
-- One message id, or a list of distinct ones (a bulk archive or delete).
local function mail_ids(arg)
  if type(arg) ~= 'table' then
    return queue.mail_id(arg)
  end
  if not vim.islist(arg) or #arg == 0 then
    return false
  end
  local seen = {}
  for _, id in ipairs(arg) do
    if not queue.mail_id(id) or seen[id] then
      return false
    end
    seen[id] = true
  end
  return true
end
local ARGS = {
  inbox = recipient, count = recipient, thread = thread_arg, read = queue.mail_id, ['mark-read'] = queue.mail_id,
  ['mark-unread'] = queue.mail_id, archive = mail_ids, delete = mail_ids,
}

-- Runs `gc --city <path> mail <verb> <arg> --json` in the background, never
-- through a shell; on_done(value, err) runs on the main loop with the
-- decoded answer (DECODE) or the reason it failed. A list argument (archive
-- and delete) puts every id in argv, in order. An argument that is not what
-- `verb` takes runs nothing.
local function run(city, verb, arg, on_done)
  local what = ('gc mail %s in %s'):format(verb, city.name)
  if not (ARGS[verb] and DECODE[verb] and ARGS[verb](arg)) then
    return on_done(nil, ('%s was not run: %s is not what it takes'):format(what, vim.inspect(arg)))
  end
  local argv = { 'gc', '--city', city.path, 'mail', verb }
  vim.list_extend(argv, type(arg) == 'table' and arg or { arg })
  argv[#argv + 1] = '--json'
  local ok, err = pcall(vim.system, argv, { text = true, timeout = config.timeout_ms }, function(result)
    vim.schedule(function()
      local record, why = M.answer(result, what)
      if not record then
        return on_done(nil, why)
      end
      local value, bad = DECODE[verb](record, arg)
      if value == nil then
        return on_done(nil, ('%s printed something unexpected (%s)'):format(what, bad or 'no value'))
      end
      on_done(value)
    end)
  end)
  if not ok then
    on_done(nil, 'cannot run gc (is it on PATH?): ' .. tostring(err))
  end
end
M.run = run

-- ---- kept copies -----------------------------------------------------------

local function key_of(city, id)
  return city.path .. '\0' .. id
end

local function file_of(city, id)
  return vim.fn.sha256(city.path):sub(1, 16) .. '-' .. id .. '.json'
end

-- Why `record` is not a kept copy, or nil when it is one.
local function invalid_kept(record)
  if type(record) ~= 'table' or record.version ~= 1 or type(record.read) ~= 'boolean' then
    return 'not a version 1 kept message'
  end
  local city = record.city
  if type(city) ~= 'table' or type(city.name) ~= 'string' or city.name == '' or type(city.path) ~= 'string'
      or city.path == '' or city.name:find('[%z\1-\31\127]') or city.path:find('[%z\1-\31\127]') then
    return 'bad city'
  end
  local _, why = M.message(record.message)
  return why
end

-- Writes `entry` as its kept copy: a temp file in the mailbox directory,
-- fsynced, then renamed over the old copy. true, or nil and the reason.
local function keep(entry)
  local folder = dir()
  if vim.fn.isdirectory(folder) == 0 then
    local ok, made = pcall(vim.fn.mkdir, folder, 'p', tonumber('700', 8))
    if not ok or made == 0 then
      return nil, 'cannot create ' .. folder
    end
  end
  local m = entry.message
  local text = vim.json.encode({
    version = 1, city = { name = entry.city.name, path = entry.city.path }, read = entry.read,
    message = { id = m.id, from = m.from, to = m.to, subject = m.subject, body = m.body, created_at = m.created_at,
      read = entry.read, thread_id = m.thread_id },
  })
  local name = file_of(entry.city, m.id)
  local temp = ('%s/.%s.%d.%s.tmp'):format(folder, name, uv.os_getpid(), vim.text.hexencode(uv.random(4)))
  local fd, err = uv.fs_open(temp, 'wx', tonumber('600', 8))
  if not fd then
    return nil, tostring(err)
  end
  local written
  written, err = uv.fs_write(fd, text, 0)
  local synced = written == #text and uv.fs_fsync(fd)
  uv.fs_close(fd)
  if synced then
    synced, err = uv.fs_rename(temp, folder .. '/' .. name)
  end
  if not synced then
    uv.fs_unlink(temp)
    return nil, tostring(err or 'short write')
  end
  return true
end

local function read_file(path)
  local fd = uv.fs_open(path, 'r', 0)
  if not fd then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  local data = stat and uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  return data
end

-- Removes the kept copy of `entry`; a copy that is not there is fine.
local function forget(entry)
  local ok, err = uv.fs_unlink(dir() .. '/' .. file_of(entry.city, entry.message.id))
  if ok or tostring(err):find('ENOENT') then
    return true
  end
  return nil, tostring(err)
end

--- The kept copies: a table key -> entry and a list of files that do not
--- parse; or nil and the reason when the directory cannot be read (never an
--- empty mailbox).
function M.kept()
  local folder = dir()
  local handle, err = uv.fs_scandir(folder)
  if not handle then
    if tostring(err):find('ENOENT') then
      return {}, {}
    end
    return nil, 'cannot read the mailbox directory: ' .. tostring(err)
  end
  local kept, bad = {}, {}
  while true do
    local name, failure = uv.fs_scandir_next(handle)
    if not name then
      if failure then
        return nil, 'cannot read the mailbox directory: ' .. tostring(failure)
      end
      break
    end
    if name:match('^%x+%-.+%.json$') then
      local data = read_file(folder .. '/' .. name)
      local ok, record = decode(data or '')
      local why = data == nil and 'unreadable' or (not ok and 'not JSON') or invalid_kept(record)
      if why then
        bad[#bad + 1] = name .. ': ' .. why
      else
        local message = M.message(record.message)
        local city = { name = record.city.name, path = record.city.path }
        kept[key_of(city, message.id)] = { city = city, message = message, read = record.read, kept = true }
      end
    end
  end
  return kept, bad
end

-- ---- the mailbox model ------------------------------------------------------

-- inbox: city path -> { [id] = entry } from the last good inbox answer.
-- kept:  key -> entry, from disk. said: errors already shown, by source.
-- clock: counts calls and changes, so their order is known.
-- latest: city path -> clock of its last inbox call; an earlier call's answer
--         is outdated. started: key -> clock of the last read, unread,
--         archive or delete of that message started here; changed: of the
--         last one started or applied (I2). touched: key -> vim.uv.hrtime()
--         of the last action answer applied to it, held against a history
--         message's loaded_since (history.load stamps it in hrtime, not this
--         clock); an action refused or still running hides nothing.
-- all:   all-mail mode (H) is on; history: city path -> true once its
--        history load was started (in the mode, on the first H or when the
--        city is first listed; R again); loading: history loads still running.
-- marks: key -> true, the messages marked with x.
local function empty_box()
  return { inbox = {}, kept = {}, said = {}, clock = 0, latest = {}, started = {}, changed = {}, touched = {},
    all = false, history = {}, loading = 0, marks = {} }
end
local box = empty_box()
local render_hook = function() end

function M.reset()
  box = empty_box()
end

local function tick()
  box.clock = box.clock + 1
  return box.clock
end

-- I2: whether the answer to a call started at clock `at` may still change
-- the message `key`. An action answer (`action` true): no later action on
-- the message started here. An inbox answer: no action on it started or
-- was applied since.
local function current(key, at, action)
  return ((action and box.started or box.changed)[key] or 0) <= at
end

-- I2: a read, unread, archive or delete of `entry` starts: the clock its
-- answer is checked against.
local function started(entry)
  local at = tick()
  local key = key_of(entry.city, entry.message.id)
  box.started[key], box.changed[key] = at, at
  return at
end

-- I2: applies change() to `entry` for the answer to the action started at
-- `at`, unless a later action on the message started since (current); then
-- the answer is dropped and nothing on screen or on disk changes. true when
-- applied.
local function apply(entry, at, change)
  local key = key_of(entry.city, entry.message.id)
  if not current(key, at, true) then
    return false
  end
  box.changed[key], box.touched[key] = tick(), uv.hrtime()
  change()
  render_hook()
  return true
end

local function say_once(source, message)
  if box.said[source] ~= message then
    box.said[source] = message
    notify(message, vim.log.levels.ERROR)
  end
end

-- The history copy of message `id` of `city` that all-mail mode may list: a
-- cached message to `human`, unless a read, unread, archive or delete of it
-- was applied here since the load that listed it started (I2), so an older
-- load never brings back a message archived, deleted or changed since. nil
-- otherwise.
local function history_copy(city, id)
  local history = package.loaded['gc_mail.history']
  local cached = history and history.cache[city.path]
  local m = cached and cached.by_id and cached.by_id[id]
  if not m or m.to ~= RECIPIENT then
    return nil
  end
  local touched = box.touched[key_of(city, id)]
  if touched and touched >= (m.loaded_since or 0) then
    return nil
  end
  return m
end

--- Every listed entry, newest first: { city, message, read, kept }. A message
--- gc lists as unread is unread, whatever its kept copy says. In all-mail
--- mode the history's messages to `human` (history_copy) join them, after
--- the inbox and the kept copies, which win for the same message. A mark
--- whose message is no longer listed is dropped.
function M.entries()
  local seen, list = {}, {}
  for _, entries in pairs(box.inbox) do
    for _, entry in pairs(entries) do
      local key = key_of(entry.city, entry.message.id)
      seen[key] = true
      list[#list + 1] = entry
    end
  end
  for key, entry in pairs(box.kept) do
    if not seen[key] then
      seen[key] = true
      list[#list + 1] = entry
    end
  end
  if box.all then
    local history = package.loaded['gc_mail.history']
    for _, city in ipairs(require('gc_mail').cached_cities() or {}) do
      local cached = history and history.cache[city.path]
      for id in pairs(cached and cached.by_id or {}) do
        local key = key_of(city, id)
        local m = not seen[key] and history_copy(city, id)
        if m then
          seen[key] = true
          -- A copy: the history cache is the chat's too, and actions change the entry.
          local message = {}
          for k, v in pairs(m) do
            message[k] = v
          end
          list[#list + 1] = { city = { name = city.name, path = city.path }, message = message, read = m.read }
        end
      end
    end
  end
  for key in pairs(box.marks) do
    if not seen[key] then
      box.marks[key] = nil
    end
  end
  table.sort(list, function(a, b)
    if a.message.created ~= b.message.created then
      return a.message.created > b.message.created
    end
    if a.city.name ~= b.city.name then
      return a.city.name < b.city.name
    end
    return a.message.id < b.message.id
  end)
  return list
end

-- The state column of `entry`: × for a message the history shows closed
-- (all-mail mode, not in the inbox), else ● unread, blank read.
local function state(entry)
  local inbox = box.inbox[entry.city.path]
  if box.all and not (inbox and inbox[entry.message.id]) then
    local m = history_copy(entry.city, entry.message.id)
    if m and m.closed then
      return '×'
    end
  end
  return entry.read and ' ' or '●'
end

--- The mailbox lines for `entries`: one sanitized line each, its first
--- column `x` for a marked message.
function M.lines(entries, now, pending)
  if #entries == 0 then
    return { (pending or box.loading > 0) and LOADING or EMPTY }
  end
  local gc_mail = require('gc_mail')
  local one_line = gc_mail.one_line
  local lines = {}
  for i, entry in ipairs(entries) do
    local m = entry.message
    lines[i] = ('%s %s %s  %s  %s  %s '):format(box.marks[key_of(entry.city, m.id)] and 'x' or ' ', state(entry),
      one_line(entry.city.name), one_line(m.from), one_line(m.subject), gc_mail.age(math.max(0, now - m.created)))
  end
  return lines
end

--- Whether all-mail mode is on.
function M.all()
  return box.all
end

-- Marks `entry` read in the model and keeps its copy. The copy failing is
-- said; the entry stays on screen read for this session either way.
local function now_read(entry, message)
  entry.message, entry.read = message or entry.message, true
  entry.message.read = true
  local inbox = box.inbox[entry.city.path]
  if inbox then
    inbox[entry.message.id] = nil
  end
  local ok, err = keep(entry)
  entry.kept = true
  box.kept[key_of(entry.city, entry.message.id)] = entry
  if not ok then
    notify(('read, but cannot keep a copy of "%s" (%s); it leaves the mailbox once gc closes it'):format(
      entry.message.subject, err), vim.log.levels.ERROR)
  end
end

local function gone(entry)
  local inbox = box.inbox[entry.city.path]
  if inbox then
    inbox[entry.message.id] = nil
  end
  box.kept[key_of(entry.city, entry.message.id)] = nil
  local ok, err = forget(entry)
  if not ok then
    notify(('cannot remove the kept copy of "%s": %s'):format(entry.message.subject, err), vim.log.levels.ERROR)
  end
end

-- ---- the window --------------------------------------------------------------

-- The open mailbox: { picker, entries (as shown, by row), pending (calls
-- whose answer the list still waits for), listed (city paths listed) }.
local view
-- Other views of the same mailbox (the panel): name -> function that redraws it.
local views = {}

--- Registers `fn` as the view `name`, redrawn whenever the mailbox changes;
--- nil removes it.
function M.subscribe(name, fn)
  views[name] = fn
end

-- Shows `title` on the float `picker`, widened (and centred again) when the
-- float is narrower than it.
local function show_title(picker, title)
  local config_now = vim.api.nvim_win_get_config(picker.win)
  local width = vim.fn.strdisplaywidth(title) + 2
  local update = { title = title, title_pos = 'center' }
  if config_now.width < width then
    local l = require('gc_mail').layout(vim.api.nvim_buf_line_count(picker.buf), width, vim.o.lines, vim.o.columns,
      vim.o.cmdheight)
    update = vim.tbl_extend('force', update, { relative = 'editor', row = l.row, col = l.col, width = l.width,
      height = l.height })
  end
  vim.api.nvim_win_set_config(picker.win, update)
end

local function render()
  if view and not view.picker.closed() then
    view.entries = M.entries()
    view.picker.set(M.lines(view.entries, os.time(), view.pending > 0))
    show_title(view.picker, box.all and TITLE_ALL or TITLE)
    if view.preview then
      view.preview.update()
    end
  end
  for _, fn in pairs(views) do
    fn()
  end
end
render_hook = render

local load_history

-- Lists `city` for the mailbox `owner`: one inbox call. A good answer
-- replaces what the city showed; a failed one changes nothing on screen and
-- is said once. The answer to a call a later call to the same city replaced
-- is dropped (a mailbox closed and reopened while its first call still ran),
-- and a message the answer is no longer current for (I2) stays as the
-- mailbox has it, listed or not: the answer would bring it back as it was,
-- or drop it while an action on it may still fail. In all-mail mode a city
-- listed for the first time loads its history too. on_done(), when given,
-- runs once the answer is handled, applied or not.
local function list(city, owner, on_done)
  if box.all then
    load_history({ city })
  end
  owner.pending = owner.pending + 1
  local at = tick()
  box.latest[city.path] = at
  run(city, 'inbox', RECIPIENT, function(messages, err)
    owner.pending = owner.pending - 1
    if box.latest[city.path] ~= at then
      render()
      if on_done then
        on_done()
      end
      return
    end
    if not messages then
      say_once('inbox ' .. city.path, err)
    else
      box.said['inbox ' .. city.path] = nil
      local entries = {}
      for _, message in ipairs(messages) do
        if current(key_of(city, message.id), at) then
          entries[message.id] = { city = { name = city.name, path = city.path }, message = message, read = message.read }
        end
      end
      for id, entry in pairs(box.inbox[city.path] or {}) do
        if not current(key_of(city, id), at) then
          entries[id] = entry
        end
      end
      box.inbox[city.path] = entries
    end
    render()
    if on_done then
      on_done()
    end
  end)
end
M.list = list

local function reload_kept()
  local kept, bad = M.kept()
  if not kept then
    say_once('kept', bad)
    return
  end
  box.said.kept = nil
  box.kept = kept
  for _, why in ipairs(bad) do
    say_once('kept ' .. why, 'a kept message cannot be read: ' .. why)
  end
end
M.reload_kept = reload_kept

-- Opens and enters a new window: `split` when given (the panel opens its
-- windows above itself), else :new beside the current one.
local function new_window(split)
  if split then
    split()
  else
    vim.cmd('new')
  end
end

-- A scratch buffer in a new window (new_window) with `lines` and buffer-local
-- `keys`; with `filetype`, it is set before the lines are written.
local function scratch(name, lines, keys, split, filetype)
  new_window(split)
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  if filetype then
    vim.bo[buf].filetype = filetype
  end
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  for lhs, fn in pairs(keys or {}) do
    vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, silent = true, desc = 'gc-mail: ' .. (M.KEY_DESC[lhs] or lhs) })
  end
  vim.keymap.set('n', 'q', '<Cmd>close<CR>', { buffer = buf, nowait = true, silent = true, desc = 'gc-mail: close' })
  return buf
end

--- The lines of a message body, verbatim: the one renderer of a body, for the
--- message view, the thread view and the preview pane.
local function body_lines(text)
  return vim.split(text, '\n', { plain = true })
end
M.body_lines = body_lines

local function header(m, city)
  local one_line = require('gc_mail').one_line
  return {
    'From:    ' .. one_line(m.from),
    'To:      ' .. one_line(m.to),
    'City:    ' .. one_line(city.name),
    'Date:    ' .. one_line(m.created_at),
    'Subject: ' .. one_line(m.subject),
    'Id:      ' .. m.id .. (m.thread_id and ('   thread ' .. one_line(m.thread_id)) or ''),
  }
end

-- Backslash-escapes what markdown reads as markup in a header value (the
-- backslash itself too), so a subject or sender never turns into emphasis, a
-- link, a heading or a table. Bodies are never escaped.
local function md_escape(text)
  return (require('gc_mail').one_line(text):gsub('[\\`*_%[%]<>#|]', '\\%0'))
end

local function markdown()
  return require('gc_mail').config.markdown
end

-- A message as markdown: a title, the sender line, the id line, a rule, then
-- the body. Blank lines keep each line its own block (a line followed by `---`
-- would otherwise read as a heading).
local function message_markdown(m, city)
  local lines = {
    '# ' .. md_escape(m.subject),
    '',
    ('**From** %s · **To** %s · **City** %s · %s'):format(md_escape(m.from), md_escape(m.to), md_escape(city.name),
      md_escape(m.created_at)),
    '',
    ('`%s`%s · %s · %s'):format(m.id, m.thread_id and (' · thread `' .. m.thread_id .. '`') or '', KEYS_HINT, READ_NOTE),
    '',
    '---',
    '',
  }
  vim.list_extend(lines, body_lines(m.body))
  return lines
end

-- A thread as markdown: the first subject as the title, then each message
-- (oldest first) under a sender and date heading, a rule between messages.
local function thread_markdown(messages)
  local lines = { '# ' .. md_escape(messages[1].subject) }
  for i, m in ipairs(messages) do
    if i > 1 then
      vim.list_extend(lines, { '', '---' })
    end
    local closed_mark = m.closed and ' (closed)' or ''
    vim.list_extend(lines, { '', ('## %s · %s%s'):format(md_escape(m.from), md_escape(m.created_at), closed_mark), '' })
    vim.list_extend(lines, body_lines(m.body))
  end
  return lines
end

local actions = {}

-- `entry` in a scratch buffer at once, from what the mailbox already holds;
-- `split`, here and in thread and reply, opens the window (new_window).
local function message_view(entry, split)
  local lines
  if markdown() then
    lines = message_markdown(entry.message, entry.city)
  else
    lines = header(entry.message, entry.city)
    lines[#lines + 1] = 'Keys:    ' .. KEYS_HINT
    lines[#lines + 1] = READ_NOTE
    lines[#lines + 1] = ''
    vim.list_extend(lines, body_lines(entry.message.body))
  end
  local buf = scratch(('gc-mail://%s/%s'):format(entry.city.name, entry.message.id), lines, {
    r = function() actions.reply(entry) end,
    t = function() actions.thread(entry) end,
    c = function() actions.chat(entry) end,
    u = function() actions.unread(entry) end,
    a = function() actions.archive(entry) end,
    d = function() actions.delete(entry) end,
  }, split, markdown() and 'markdown' or nil)
  return buf
end

--- Shows `entry` (a hit of the search or any { city, message, read }) in the
--- message view and calls no gc: nothing is marked read, as the message may be
--- closed. The keys are the view's.
function M.show(entry, split)
  return message_view(entry, split)
end

-- Opens `entry` in the message view at once and marks it read in gc in the
-- background (one `gc mail read`; a message already read here runs nothing).
function actions.open(entry, split)
  local buf = message_view(entry, split)
  if not entry.read then
    local at = started(entry)
    run(entry.city, 'read', entry.message.id, function(message, err)
      if not message then
        return notify(('cannot mark "%s" read: %s'):format(entry.message.subject, err), vim.log.levels.ERROR)
      end
      apply(entry, at, function()
        now_read(entry, message)
      end)
    end)
  end
  return buf
end

function actions.read(entry, on_done)
  local at = started(entry)
  run(entry.city, 'mark-read', entry.message.id, function(ok, err)
    if not ok then
      notify(('cannot mark "%s" read: %s'):format(entry.message.subject, err), vim.log.levels.ERROR)
      if type(on_done) == 'function' then
        on_done(false, err)
      end
      return
    end
    local applied = apply(entry, at, function()
      now_read(entry)
    end)
    if type(on_done) == 'function' then
      on_done(true, nil, applied)
    end
  end)
end

-- Unread again in gc; the kept copy stays (gc may already have closed the
-- message) and says unread. A message with no kept copy (one all-mail mode
-- listed from the history) is listed as the inbox lists it now, until the
-- next inbox answer.
function actions.unread(entry, on_done)
  local at = started(entry)
  run(entry.city, 'mark-unread', entry.message.id, function(ok, err)
    if not ok then
      notify(('cannot mark "%s" unread: %s'):format(entry.message.subject, err), vim.log.levels.ERROR)
      if type(on_done) == 'function' then
        on_done(false, err)
      end
      return
    end
    local applied = apply(entry, at, function()
      entry.read, entry.message.read = false, false
      if entry.kept then
        local kept, kerr = keep(entry)
        if not kept then
          notify(('cannot update the kept copy of "%s": %s'):format(entry.message.subject, kerr), vim.log.levels.ERROR)
        end
      else
        box.inbox[entry.city.path] = box.inbox[entry.city.path] or {}
        box.inbox[entry.city.path][entry.message.id] = entry
      end
    end)
    if type(on_done) == 'function' then
      on_done(true, nil, applied)
    end
  end)
end

local function remove(verb)
  return function(entry)
    local at = started(entry)
    run(entry.city, verb, entry.message.id, function(ok, err)
      if not ok then
        return notify(('cannot %s "%s": %s'):format(verb, entry.message.subject, err), vim.log.levels.ERROR)
      end
      apply(entry, at, function()
        gone(entry)
        notify(('%s: %s'):format(verb == 'archive' and 'archived' or 'deleted', entry.message.subject))
      end)
    end)
  end
end
actions.archive = remove('archive')
local delete = remove('delete')

-- Delete asks first; only the message asked about is deleted.
function actions.delete(entry)
  local choice = vim.fn.confirm(('Delete "%s" from %s?'):format(require('gc_mail').one_line(entry.message.subject),
    entry.message.from), '&Yes\n&No', 2)
  if choice == 1 then
    delete(entry)
  end
end

function actions.thread(entry, split)
  local function show_thread(id, messages)
    table.sort(messages, function(a, b)
      return a.created < b.created
    end)
    local lines
    if markdown() and #messages > 0 then
      lines = thread_markdown(messages)
    else
      lines = { ('Thread %s in %s, %d message(s)'):format(id, entry.city.name, #messages) }
      for _, m in ipairs(messages) do
        lines[#lines + 1] = ''
        vim.list_extend(lines, header(m, entry.city))
        lines[#lines + 1] = ''
        vim.list_extend(lines, body_lines(m.body))
      end
    end
    scratch(('gc-mail://%s/thread/%s'):format(entry.city.name, id), lines, nil, split, markdown() and 'markdown' or nil)
  end

  if entry.message.thread_id then
    require('gc_mail.history').load(entry.city, { thread = entry.message.thread_id }, function(messages, err)
      if not messages then
        return notify(('cannot show the thread of "%s": %s'):format(entry.message.subject, err), vim.log.levels.ERROR)
      end
      show_thread(entry.message.thread_id, messages)
    end)
  else
    local id = entry.message.id
    run(entry.city, 'thread', id, function(messages, err)
      if not messages then
        return notify(('cannot show the thread of "%s": %s'):format(entry.message.subject, err), vim.log.levels.ERROR)
      end
      show_thread(id, messages)
    end)
  end
end

-- Opens the chat with the other side of `entry`'s message in its city: the
-- sender, or for a message from human its recipient. `enter` (optional) first
-- moves to the window the chat should open beside, as `split` does for the
-- other actions.
function actions.chat(entry, enter)
  local m = entry.message
  local with = m.from == 'human' and m.to or m.from
  if enter then
    enter()
  end
  return require('gc_mail.chat').open(entry.city.name, with)
end

-- A compose buffer for a reply to `entry`; the send keys (<Space>mm,
-- :GcMail) queue it as `gc mail reply` (gc_mail.open()).
function actions.reply(entry, split)
  local subject = entry.message.subject
  if not subject:match('^[Rr][Ee]:') then
    subject = 'Re: ' .. subject
  end
  new_window(split)
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { subject, '', '' })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  vim.api.nvim_buf_set_var(buf, 'gc_mail_reply', {
    city = { name = entry.city.name, path = entry.city.path }, id = entry.message.id, to = entry.message.from,
  })
  notify(('reply to %s in %s: write it, then %s (or :GcMail) queues it'):format(entry.message.from, entry.city.name,
    require('gc_mail').config.keymap or ':GcMail'))
  return buf
end
M.actions = actions

-- ---- marks, selections and bulk actions ------------------------------------

local function unmark(entry)
  box.marks[key_of(entry.city, entry.message.id)] = nil
end

--- Marks `entry` (x), or unmarks it when it is marked.
function M.toggle_mark(entry)
  local key = key_of(entry.city, entry.message.id)
  box.marks[key] = not box.marks[key] or nil
  render_hook()
end

--- Clears every mark (X).
function M.clear_marks()
  box.marks = {}
  render_hook()
end

--- The entries an action key acts on, in list order: the rows of the visual
--- selection in `buf` when the key was pressed in visual mode (which it
--- leaves), else every marked entry, else the one on `row`.
function M.targets(entries, row, buf)
  local mode = vim.fn.mode()
  local list = {}
  if mode == 'v' or mode == 'V' or mode == '\22' then
    vim.cmd('normal! ' .. vim.keycode('<Esc>'))
    local first, last = vim.api.nvim_buf_get_mark(buf, '<')[1], vim.api.nvim_buf_get_mark(buf, '>')[1]
    for i = math.min(first, last), math.max(first, last) do
      list[#list + 1] = entries[i]
    end
    return list
  end
  for _, entry in ipairs(entries) do
    if box.marks[key_of(entry.city, entry.message.id)] then
      list[#list + 1] = entry
    end
  end
  if #list == 0 then
    list[1] = entries[row]
  end
  return list
end

-- m and u on `list`: one gc call per message, in list order, the next once
-- the last answered (gc marks one id per call). Each is actions.read or
-- actions.unread, with its own clock and apply (I2); a refused one is said
-- there and the next still runs, nothing is retried. An applied one loses
-- its mark.
local function one_by_one(action, list)
  local i = 0
  local function step()
    i = i + 1
    local entry = list[i]
    if not entry then
      return
    end
    action(entry, function(ok, _, applied)
      if ok and applied then
        unmark(entry)
        render_hook()
      end
      step()
    end)
  end
  step()
end

-- a and d on several messages: one `gc mail archive|delete <id> <id> ...`
-- per city, every id checked before any clock starts and each message's
-- clock started before the call (I2). The answer must name every id (I1);
-- then each message is applied on its own (a later action on one drops only
-- that one). A refused or failed call says the city's ids once and changes
-- nothing.
local function remove_many(verb, list)
  local order, groups = {}, {}
  for _, entry in ipairs(list) do
    local path = entry.city.path
    if not groups[path] then
      groups[path] = { city = entry.city, entries = {} }
      order[#order + 1] = path
    end
    table.insert(groups[path].entries, entry)
  end
  for _, path in ipairs(order) do
    local group = groups[path]
    local ids = vim.tbl_map(function(entry)
      return entry.message.id
    end, group.entries)
    local function refused(err)
      notify(('cannot %s %d messages in %s (%s): %s'):format(verb, #ids, group.city.name, table.concat(ids, ' '), err),
        vim.log.levels.ERROR)
    end
    if not mail_ids(ids) then
      refused('not a list of distinct gc mail ids')
    else
      local ats = vim.tbl_map(started, group.entries)
      run(group.city, verb, ids, function(ok, err)
        if not ok then
          return refused(err)
        end
        local done = 0
        for i, entry in ipairs(group.entries) do
          if apply(entry, ats[i], function() gone(entry) end) then
            done = done + 1
          end
        end
        if done > 0 then
          notify(('%s %d messages in %s'):format(verb == 'archive' and 'archived' or 'deleted', done, group.city.name))
        end
      end)
    end
  end
end

--- Runs `verb` (read, unread, archive or delete) on `list` (M.targets). One
--- message is today's single action; several are a bulk action, and delete
--- asks once for all of them.
function M.act(verb, list)
  if #list == 0 then
    return
  end
  if verb == 'read' or verb == 'unread' then
    return one_by_one(actions[verb], list)
  end
  if #list == 1 then
    return actions[verb](list[1])
  end
  if verb == 'delete' and vim.fn.confirm(('Delete %d messages?'):format(#list), '&Yes\n&No', 2) ~= 1 then
    return
  end
  remove_many(verb, list)
end

-- ---- all-mail mode -------------------------------------------------------------

-- Loads the history of every city in `cities` for all-mail mode (gc bd list,
-- gc_mail.history; a load already running is joined): a city whose load was
-- already started only `again` (R). A failed load is said once; the mode
-- shows what it has.
function load_history(cities, again)
  if not cities then
    return
  end
  local history = require('gc_mail.history')
  local this = box
  for _, city in ipairs(cities) do
    if again or not this.history[city.path] then
      this.history[city.path] = true
      local c = { name = city.name, path = city.path }
      this.loading = this.loading + 1
      history.load(c, function(messages, err)
        if this ~= box then
          return
        end
        this.loading = this.loading - 1
        if messages then
          this.said['history ' .. c.path] = nil
        else
          say_once('history ' .. c.path, err)
        end
        render_hook()
      end)
    end
  end
end

--- Turns all-mail mode on or off (H) for both views. Turning it on loads the
--- history of every cached city not loaded yet; a city the city list adds
--- later loads it when it is first listed (list()).
function M.toggle_all()
  box.all = not box.all
  if box.all then
    load_history(require('gc_mail').cached_cities())
  end
  render_hook()
end

--- R in all-mail mode loads the history again too.
function M.reload_history()
  if box.all then
    load_history(require('gc_mail').cached_cities(), true)
  end
end

--- Maps the keys both views share on their buffer `buf`: x and X (marks), H
--- (all-mail mode), and m, u, a and d in normal and visual mode (M.targets).
--- `at()` gives the entries as shown and the cursor row, or nothing once the
--- view is gone.
function M.map_keys(buf, at)
  local function set(modes, lhs, fn, desc)
    vim.keymap.set(modes, lhs, fn, { buffer = buf, nowait = true, silent = true, desc = 'gc-mail: ' .. desc })
  end
  local function act(verb)
    return function()
      local entries, row = at()
      if entries then
        M.act(verb, M.targets(entries, row, buf))
      end
    end
  end
  set({ 'n', 'x' }, 'm', act('read'), 'mark the selected, marked or current mail read')
  set({ 'n', 'x' }, 'u', act('unread'), 'mark the selected, marked or current mail unread')
  set({ 'n', 'x' }, 'a', act('archive'), 'archive the selected, marked or current mail')
  set({ 'n', 'x' }, 'd', act('delete'), 'delete the selected, marked or current mail')
  set('n', 'x', function()
    local entries, row = at()
    local entry = entries and entries[row]
    if entry then
      M.toggle_mark(entry)
    end
  end, 'mark or unmark the mail under the cursor')
  set('n', 'X', M.clear_marks, 'clear every mark')
  set('n', 'H', M.toggle_all, 'all mail or unread and kept mail')
end

--- Opens the mailbox: the kept copies and the last answers at once, then one
--- inbox call per listed city (a city the refreshed city list adds is listed
--- once it arrives).
function M.open()
  local gc_mail = require('gc_mail')
  reload_kept()
  local function on(fn)
    return function(picker, row)
      local entry = view and view.entries[row]
      if entry then
        fn(entry, picker)
      end
    end
  end
  local entries = M.entries()
  local picker = gc_mail.float(box.all and TITLE_ALL or TITLE, M.lines(entries, os.time(), true), {
    ['<CR>'] = on(function(entry, picker)
      picker.close()
      actions.open(entry)
    end),
    r = on(function(entry, picker)
      picker.close()
      actions.reply(entry)
    end),
    t = on(function(entry, picker)
      picker.close()
      actions.thread(entry)
    end),
    c = on(function(entry, picker)
      picker.close()
      actions.chat(entry)
    end),
    s = function()
      require('gc_mail.search').prompt()
    end,
    p = function()
      if view and view.preview then
        view.preview.toggle()
      end
    end,
    R = function()
      if view and view.pending == 0 then
        reload_kept()
        for _, city in ipairs(gc_mail.cached_cities() or {}) do
          view.listed[city.path] = true
          list(city, view)
        end
        M.reload_history()
        render()
      end
    end,
  }, M.KEY_DESC)
  local this = { picker = picker, entries = entries, pending = 0, listed = {} }
  view = this
  this.preview = require('gc_mail.preview').attach({
    kind = 'float', win = picker.win, buf = picker.buf, entry_at = function(row) return this.entries[row] end,
  })
  M.map_keys(picker.buf, function()
    if view == this and not picker.closed() then
      return this.entries, vim.api.nvim_win_get_cursor(picker.win)[1]
    end
  end)
  local function list_new(cities)
    for _, city in ipairs(cities or {}) do
      if not this.listed[city.path] then
        this.listed[city.path] = true
        list(city, this)
      end
    end
  end
  list_new(gc_mail.cached_cities())
  -- Without a cached city list the mailbox waits for gc cities as well.
  local waiting = gc_mail.cached_cities() == nil
  if waiting then
    this.pending = this.pending + 1
  end
  gc_mail.refresh(function(cities, err)
    if waiting then
      this.pending = this.pending - 1
    end
    if cities then
      list_new(cities)
    elseif not gc_mail.cached_cities() then
      say_once('cities', err)
    end
    render()
  end)
  render()
  return picker.win
end

-- ---- the opt-in new-mail check ---------------------------------------------

local check = { timer = nil, focused = true, last = {}, busy = {}, group = nil }

--- Starts the new-mail check: every `ms` (at least a minute), while Neovim
--- has focus, one `gc mail count human` per cached city, and a notice when a
--- city's unread count grows.
function M.start_check(ms)
  M.stop_check()
  ms = math.max(60000, ms)
  check.group = vim.api.nvim_create_augroup('gc_mail_check', { clear = true })
  vim.api.nvim_create_autocmd('FocusLost', { group = check.group, callback = function() check.focused = false end })
  vim.api.nvim_create_autocmd('FocusGained', { group = check.group, callback = function() check.focused = true end })
  check.timer = uv.new_timer()
  check.timer:start(ms, ms, vim.schedule_wrap(function()
    M.check_once()
  end))
end

--- One pass of the new-mail check (what the timer runs).
function M.check_once()
  if not check.focused then
    return
  end
  for _, city in ipairs(require('gc_mail').cached_cities() or {}) do
    if not check.busy[city.path] then
      check.busy[city.path] = true
      run(city, 'count', RECIPIENT, function(unread, err)
        check.busy[city.path] = nil
        local last = check.last[city.path]
        if not unread then
          say_once('count ' .. city.path, err)
        else
          box.said['count ' .. city.path] = nil
          check.last[city.path] = unread
          if last and unread > last then
            notify(('%d unread mail in %s; %s opens the mailbox'):format(unread, city.name,
              require('gc_mail').config.mailbox_keymap or ':GcMailbox'))
          end
        end
      end)
    end
  end
end

function M.stop_check()
  if check.timer then
    check.timer:stop()
    check.timer:close()
  end
  if check.group then
    pcall(vim.api.nvim_del_augroup_by_id, check.group)
  end
  check = { timer = nil, focused = true, last = {}, busy = {}, group = nil }
end

function M.checking()
  return check.timer ~= nil
end

return M
