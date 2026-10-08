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
-- Two invariants hold every gc answer to what it can change:
--
-- I1 DECODE: every `gc mail <verb> --json` answer passes the one decoder of
--    its shape (DECODE) before any code reads it. A decoder requires every
--    field the code reads, with its type (`gc --json-schema=result mail
--    <verb>`): message and thread ids match the whole id gc prints
--    (queue.mail_id, queue.thread_id), counts are non-negative integers, an
--    action answer names its command, action and the message. Anything else
--    is nil and a reason; the caller says it and keeps what is on screen.
--    The argument a call puts in argv passes the same id check first, so
--    nothing that could parse as an option ever reaches gc.
-- I2 APPLY: every answer that changes what the mailbox shows or keeps goes
--    through current(): one clock, and per message the clock of the last
--    read, unread, archive or delete started here and of the last one
--    started or applied. An action answer applies (apply()) only when no
--    later action on its message started after its call; an inbox answer
--    lists a message only when nothing was started or applied on it since
--    its call started. So a late answer never brings back, or keeps a copy
--    of, a message archived, deleted or changed since.
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
local TITLE = ' gc mail: <CR> open  r reply  t thread  m read  u unread  a archive  d delete  R refresh '
local LOADING = ' loading… '
local EMPTY = ' no mail '
local KEYS_HINT = 'r reply  t thread  u unread  a archive  d delete  q close'
local READ_NOTE = 'Read mail stays in this mailbox until you archive or delete it; gc closes read mail an hour after it was sent.'

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

-- An action answer (mail_action): the command and action of `verb`, the
-- message asked about among `ids`, and a count; mark-read and mark-unread
-- also name it as `id` and count at least one.
local function action_of(verb)
  local marks = verb == 'mark-read' or verb == 'mark-unread'
  return function(record, id)
    if record.command ~= 'mail.' .. verb or record.action ~= verb then
      return nil, 'it is not a ' .. verb .. ' answer'
    end
    if not strings(record.ids) or not vim.tbl_contains(record.ids, id) or (marks and record.id ~= id) then
      return nil, 'it did not name the message'
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
local ARGS = {
  inbox = recipient, count = recipient, thread = thread_arg, read = queue.mail_id, ['mark-read'] = queue.mail_id,
  ['mark-unread'] = queue.mail_id, archive = queue.mail_id, delete = queue.mail_id,
}

-- Runs `gc --city <path> mail <verb> <arg> --json` in the background, never
-- through a shell; on_done(value, err) runs on the main loop with the
-- decoded answer (DECODE) or the reason it failed. An argument that is not
-- what `verb` takes runs nothing.
local function run(city, verb, arg, on_done)
  local what = ('gc mail %s in %s'):format(verb, city.name)
  if not (ARGS[verb] and DECODE[verb] and ARGS[verb](arg)) then
    return on_done(nil, ('%s was not run: %s is not what it takes'):format(what, vim.inspect(arg)))
  end
  local argv = { 'gc', '--city', city.path, 'mail', verb, arg, '--json' }
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
--         last one started or applied (I2).
local function empty_box()
  return { inbox = {}, kept = {}, said = {}, clock = 0, latest = {}, started = {}, changed = {} }
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
  box.changed[key] = tick()
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

--- Every listed entry, newest first: { city, message, read, kept }. A message
--- gc lists as unread is unread, whatever its kept copy says.
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
      list[#list + 1] = entry
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

--- The mailbox lines for `entries`: one sanitized line each.
function M.lines(entries, now, pending)
  if #entries == 0 then
    return { pending and LOADING or EMPTY }
  end
  local gc_mail = require('gc_mail')
  local one_line = gc_mail.one_line
  local lines = {}
  for i, entry in ipairs(entries) do
    local m = entry.message
    lines[i] = (' %s %s  %s  %s  %s '):format(entry.read and ' ' or '●', one_line(entry.city.name), one_line(m.from),
      one_line(m.subject), gc_mail.age(math.max(0, now - m.created)))
  end
  return lines
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

local function render()
  if view and not view.picker.closed() then
    view.entries = M.entries()
    view.picker.set(M.lines(view.entries, os.time(), view.pending > 0))
  end
  for _, fn in pairs(views) do
    fn()
  end
end
render_hook = render

-- Lists `city` for the mailbox `owner`: one inbox call. A good answer
-- replaces what the city showed; a failed one changes nothing on screen and
-- is said once. The answer to a call a later call to the same city replaced
-- is dropped (a mailbox closed and reopened while its first call still ran),
-- and an answer leaves out every message it is no longer current for (I2):
-- it would bring them back as they were. on_done(), when given, runs once
-- the answer is handled, applied or not.
local function list(city, owner, on_done)
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
    vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  vim.keymap.set('n', 'q', '<Cmd>close<CR>', { buffer = buf, nowait = true, silent = true })
  return buf
end

local function body_lines(text)
  return vim.split(text, '\n', { plain = true })
end

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
    vim.list_extend(lines, { '', ('## %s · %s'):format(md_escape(m.from), md_escape(m.created_at)), '' })
    vim.list_extend(lines, body_lines(m.body))
  end
  return lines
end

local actions = {}

-- Opens `entry` in a scratch buffer at once, from what the mailbox already
-- holds, and marks it read in gc in the background (one `gc mail read`; a
-- message already read here runs nothing). `split`, here and in thread and
-- reply, opens the window (new_window).
function actions.open(entry, split)
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
    u = function() actions.unread(entry) end,
    a = function() actions.archive(entry) end,
    d = function() actions.delete(entry) end,
  }, split, markdown() and 'markdown' or nil)
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

function actions.read(entry)
  local at = started(entry)
  run(entry.city, 'mark-read', entry.message.id, function(ok, err)
    if not ok then
      return notify(('cannot mark "%s" read: %s'):format(entry.message.subject, err), vim.log.levels.ERROR)
    end
    apply(entry, at, function()
      now_read(entry)
    end)
  end)
end

-- Unread again in gc; the kept copy stays (gc may already have closed the
-- message) and says unread.
function actions.unread(entry)
  local at = started(entry)
  run(entry.city, 'mark-unread', entry.message.id, function(ok, err)
    if not ok then
      return notify(('cannot mark "%s" unread: %s'):format(entry.message.subject, err), vim.log.levels.ERROR)
    end
    apply(entry, at, function()
      entry.read, entry.message.read = false, false
      if entry.kept then
        local kept, kerr = keep(entry)
        if not kept then
          notify(('cannot update the kept copy of "%s": %s'):format(entry.message.subject, kerr), vim.log.levels.ERROR)
        end
      end
    end)
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
  local id = entry.message.thread_id or entry.message.id
  run(entry.city, 'thread', id, function(messages, err)
    if not messages then
      return notify(('cannot show the thread of "%s": %s'):format(entry.message.subject, err), vim.log.levels.ERROR)
    end
    table.sort(messages, function(a, b)
      return a.created < b.created
    end)
    local lines
    if markdown() and #messages > 0 then
      lines = thread_markdown(messages)
    else
      lines = { ('Thread %s in %s, %d open message(s); gc lists no closed mail here'):format(id, entry.city.name, #messages) }
      for _, m in ipairs(messages) do
        lines[#lines + 1] = ''
        vim.list_extend(lines, header(m, entry.city))
        lines[#lines + 1] = ''
        vim.list_extend(lines, body_lines(m.body))
      end
    end
    scratch(('gc-mail://%s/thread/%s'):format(entry.city.name, id), lines, nil, split, markdown() and 'markdown' or nil)
  end)
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
  local picker = gc_mail.float(TITLE, M.lines(entries, os.time(), true), {
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
    m = on(actions.read),
    u = on(actions.unread),
    a = on(actions.archive),
    d = on(actions.delete),
    R = function()
      if view and view.pending == 0 then
        reload_kept()
        for _, city in ipairs(gc_mail.cached_cities() or {}) do
          view.listed[city.path] = true
          list(city, view)
        end
        render()
      end
    end,
  })
  local this = { picker = picker, entries = entries, pending = 0, listed = {} }
  view = this
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
