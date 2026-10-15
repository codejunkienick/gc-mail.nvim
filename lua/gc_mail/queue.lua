-- The on-disk send queue of gc-mail.nvim.
--
-- Each message is one JSON file in <state_dir>/queue/, named so that names
-- sort oldest first. One worker per Neovim sends the queue, one gc process at
-- a time: the oldest message of each city first, so messages to one mayor
-- arrive in the order they were written. Several Neovims may share a queue;
-- these rules keep it consistent (the README repeats them, the tests check
-- each one):
--
--   1. Whole files. A queue file is only created or replaced whole: written
--      to a temp file in the queue directory, fsynced, then renamed.
--   2. One lock. Every change to a queue file - adding, claiming, recording a
--      send's outcome, putting a claim back, retry, delete, dropping what a
--      gone Neovim left - runs under an exclusive flock on <queue>/.lock and
--      reads the files it decides on under that same lock. Only reads for
--      display take no lock. The worker never waits for the lock (it tries
--      again shortly); a user action waits up to lock_wait_ms.
--   3. Claims. A message being sent is renamed to
--      <id>.json.sending-<pid>-<token> (under the lock; the token is made once
--      per Neovim, the file's mtime is the claim's time), and nothing but its
--      sender changes it: retry and delete act only on an unclaimed <id>.json.
--      A claim is live while it is this Neovim's own (pid and token), or while
--      its pid is alive and it is younger than twice send_timeout_ms; its
--      sender keeps a claim it holds longer than a send young (its time set,
--      or the claim rewritten whole when that is refused; said once when
--      neither works). Every other claim is put back by the next worker
--      pass, or dropped if marked sent.
--   4. Settled outcomes. A claim is kept until its send's outcome is on disk:
--      the file deleted after success (or marked delivered while it cannot
--      be), rewritten with the failure and put back after one. Until then the
--      worker sends nothing else and tries again with a backoff.
--   5. Bounded. The queue holds at most max_files messages; add() counts and
--      renames in one hold of the lock.
--   6. Fail closed. A queue directory that cannot be listed, a lock that
--      cannot be taken or a file that does not parse is an error the caller
--      sees: add refuses, the worker waits and says so once, the list shows
--      it. None of them reads as an empty queue or a message to send.
--
-- A crash between gc's success and the delete can so send one message twice;
-- that is preferred to losing one.
local M = {}

local uv = vim.uv

local defaults = {
  dir = nil, -- <state_dir>/queue, set by configure()
  -- Delays before the 2nd, 3rd and 4th try; after the last one fails the
  -- message is marked failed and only a retry from :GcMailQueue sends it.
  retry_ms = { 10000, 60000, 300000 },
  -- Delays between tries to put a send's outcome on disk, or to read a queue
  -- directory that cannot be read; the last repeats.
  settle_ms = { 1000, 10000, 60000 },
  -- How long add(), retry() and delete() wait for another Neovim holding the
  -- queue lock; the worker does not wait, it looks again after busy_ms.
  lock_wait_ms = 500,
  busy_ms = 100,
  max_files = 100,
  send_timeout_ms = 120000,
  notify = function(message, level)
    vim.notify('gc-mail: ' .. message, level or vim.log.levels.INFO)
  end,
}

local config = vim.deepcopy(defaults)
-- held: a finished send whose outcome is not on disk yet (see settle()).
-- trouble: why the last worker pass could not read the queue (said once).
local worker = { busy = false, timer = nil, stopped = false, seq = 0, held = nil, trouble = nil, tries = 0 }

local NAME_RE = '^(%d+%-%d+%-%x+)%.json$'
local CLAIM_RE = '^(%d+%-%d+%-%x+)%.json%.sending%-(%d+)%-(%x+)$'
local TEMP_RE = '^%.(.+)%.(%d+)%.%x+%.tmp$'
local LOCK = '.lock'

local has_ffi, ffi = pcall(require, 'ffi')
if has_ffi then
  pcall(ffi.cdef, 'int flock(int fd, int operation);')
end
local LOCK_EX, LOCK_NB, EINTR = 2, 4, 4
local EWOULDBLOCK = has_ffi and ((ffi.os == 'OSX' or ffi.os == 'BSD') and 35 or 11) or nil

-- This Neovim's claim token: with the pid it tells its own claims from those
-- of an earlier process that had the same pid.
M.token = vim.text.hexencode(uv.random(8)):lower()

local subscribers = {}
local subscriber_errors = {}

local function notify_subscribers(payload)
  if not next(subscribers) then
    return
  end
  vim.schedule(function()
    local current = {}
    for name, fn in pairs(subscribers) do
      current[name] = fn
    end
    for name, fn in pairs(current) do
      if subscribers[name] then
        local ok, err = pcall(fn, payload)
        if not ok and not subscriber_errors[name] then
          subscriber_errors[name] = true
          config.notify(('subscriber %s failed: %s'):format(name, tostring(err)), vim.log.levels.ERROR)
        end
      end
    end
  end)
end

function M.subscribe(name, fn)
  if fn == nil then
    subscribers[name] = nil
    subscriber_errors[name] = nil
  else
    subscribers[name] = fn
    subscriber_errors[name] = nil
  end
end

function M.configure(opts)
  config = vim.tbl_extend('force', vim.deepcopy(defaults), opts or {})
  worker.stopped = false
end

local function first_lines(text, count)
  local lines = {}
  for line in (text or ''):gmatch('[^\n]+') do
    if vim.trim(line) ~= '' then
      lines[#lines + 1] = line
      if #lines == count then
        break
      end
    end
  end
  return table.concat(lines, '\n')
end
M.first_lines = first_lines

local function now_ms()
  local sec, usec = uv.gettimeofday()
  return sec * 1000 + math.floor(usec / 1000)
end

local function path(name)
  return config.dir .. '/' .. name
end

local function ensure_dir()
  if vim.fn.isdirectory(config.dir) == 0 then
    local ok, made = pcall(vim.fn.mkdir, config.dir, 'p', tonumber('700', 8))
    if not ok or made == 0 then
      return nil, 'cannot create ' .. config.dir .. (ok and '' or (': ' .. tostring(made)))
    end
  end
  return true
end

local FIELDS = {
  version = true, city = true, subject = true, body = true, created = true, attempts = true, next_at = true,
  failed = true, last_error = true, delivered = true, reply_to = true, to = true,
}

-- The ids gc 1.4.1 prints, matched whole: a mail id is a bead id (ab-1x2y3z)
-- or a wisp id (ab-wisp-1x2y3z), a thread id is thread-<hex> (gc's
-- generateThreadID). Neither can ever parse as an option or a path.
function M.mail_id(text)
  return type(text) == 'string' and #text <= 100
    and (text:match('^%l[%l%d]*%-[%l%d]+$') ~= nil or text:match('^%l[%l%d]*%-wisp%-[%l%d]+$') ~= nil)
end

function M.thread_id(text)
  return type(text) == 'string' and #text <= 100 and text:match('^thread%-%x+$') ~= nil
end

local function whole(n)
  return type(n) == 'number' and n >= 0 and n == math.floor(n)
end

-- Why `record` is not a version 1 queue record, or nil when it is one. Every
-- field is checked, so nothing that reads a record can trip over a bad value.
local function invalid(record)
  if type(record) ~= 'table' or record.version ~= 1 then
    return 'not a version 1 gc-mail message'
  end
  for key in pairs(record) do
    if not FIELDS[key] then
      return 'unknown field ' .. tostring(key)
    end
  end
  local city = record.city
  if type(city) ~= 'table' or vim.tbl_count(city) ~= 2 or type(city.name) ~= 'string' or city.name == ''
      or city.name:find('\n') or type(city.path) ~= 'string' or city.path == '' then
    return 'bad city'
  end
  if type(record.subject) ~= 'string' or record.subject == '' or record.subject:find('\n') then
    return 'bad subject'
  end
  if type(record.body) ~= 'string' then
    return 'bad body'
  end
  for _, key in ipairs({ 'created', 'attempts', 'next_at' }) do
    if not whole(record[key]) then
      return 'bad ' .. key
    end
  end
  if type(record.failed) ~= 'boolean' then
    return 'bad failed'
  end
  if record.last_error ~= nil and type(record.last_error) ~= 'string' then
    return 'bad last_error'
  end
  if record.delivered ~= nil and type(record.delivered) ~= 'boolean' then
    return 'bad delivered'
  end
  -- A reply names the message it answers and, for display, its sender.
  if record.reply_to ~= nil then
    if not M.mail_id(record.reply_to) then
      return 'bad reply_to'
    end
    if record.to == nil then
      return 'bad to'
    end
  end
  if record.to ~= nil then
    if type(record.to) ~= 'string' or record.to == '' or #record.to > 100
        or record.to:find('[%z\1-\31\127]') or record.to:sub(1, 1) == '-' then
      return 'bad to'
    end
  end
end

--- Who a record goes to, for messages: `<city> <to>`.
function M.who(record)
  return ('%s %s'):format(record.city.name, record.to or 'mayor')
end
local who = M.who

local function read(name)
  local fd, err = uv.fs_open(path(name), 'r', 0)
  if not fd then
    return nil, err
  end
  local stat = uv.fs_fstat(fd)
  local data = stat and uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if not data then
    return nil, 'unreadable'
  end
  local ok, record = pcall(vim.json.decode, data)
  local reason = ok and invalid(record) or (not ok and 'not JSON')
  if reason then
    return nil, 'not a gc-mail message: ' .. reason, data
  end
  return record
end

-- Writes `record` to a fresh temp file in the queue directory, in full and
-- fsynced; returns the temp file's path, which the caller renames.
local function stage(name, record)
  local ok, err = ensure_dir()
  if not ok then
    return nil, err
  end
  local text = vim.json.encode(record)
  local temp = path(('.%s.%d.%s.tmp'):format(name, uv.os_getpid(), vim.text.hexencode(uv.random(4))))
  local fd
  fd, err = uv.fs_open(temp, 'wx', tonumber('600', 8))
  if not fd then
    return nil, err
  end
  local written
  written, err = uv.fs_write(fd, text, 0)
  local synced = written == #text and uv.fs_fsync(fd)
  uv.fs_close(fd)
  if not synced then
    uv.fs_unlink(temp)
    return nil, err or 'short write'
  end
  return temp
end

-- Writes `record` as `name` atomically: staged, then renamed over `name`.
local function write(name, record)
  local temp, err = stage(name, record)
  if not temp then
    return nil, err
  end
  local ok
  ok, err = uv.fs_rename(temp, path(name))
  if not ok then
    uv.fs_unlink(temp)
    return nil, err
  end
  return true
end


local BUSY = 'the queue is busy (another Neovim is using it); try again'

-- Runs fn() holding an exclusive flock on <queue>/.lock (rule 2), waiting up
-- to wait_ms for another Neovim to let go, and returns what fn returns (at
-- most two values). A lock that cannot be taken is never skipped: it returns
-- nil, the reason and, when another Neovim holds it, true.
local function locked(wait_ms, fn)
  if not has_ffi then
    return nil, 'cannot lock the queue: this Neovim has no LuaJIT FFI'
  end
  local fd, err = uv.fs_open(path(LOCK), 'a', tonumber('600', 8))
  if not fd then
    return nil, 'cannot lock the queue: ' .. tostring(err)
  end
  local deadline = now_ms() + wait_ms
  while ffi.C.flock(fd, LOCK_EX + LOCK_NB) ~= 0 do
    local errno = ffi.errno()
    if errno ~= EINTR and (errno ~= EWOULDBLOCK or now_ms() >= deadline) then
      uv.fs_close(fd)
      if errno == EWOULDBLOCK then
        return nil, BUSY, true
      end
      return nil, ('cannot lock the queue (errno %d)'):format(errno)
    end
    uv.sleep(2)
  end
  local ok, a, b = pcall(fn)
  -- Closing the descriptor releases the lock.
  uv.fs_close(fd)
  if not ok then
    error(a, 0)
  end
  return a, b
end

local function alive(pid)
  if pid == uv.os_getpid() then
    return true
  end
  local ok, err = uv.kill(pid, 0)
  return ok == 0 or (err ~= nil and err:find('EPERM') ~= nil)
end

local function claim_of(id)
  return ('%s.json.sending-%d-%s'):format(id, uv.os_getpid(), M.token)
end

-- Whether claim `entry` is still being sent (rule 3): it is this Neovim's
-- own, or its pid is alive and it was taken (or kept young) less than twice
-- the send timeout ago. A pid alone is not enough: after a crash the pid can
-- belong to a new process. A claim whose age cannot be read is left alone.
local function live(entry)
  if entry.claimed == uv.os_getpid() then
    return entry.token == M.token
  end
  if not alive(entry.claimed) then
    return false
  end
  local stat = uv.fs_stat(path(entry.name))
  if not stat then
    return true
  end
  return now_ms() - (stat.mtime.sec * 1000 + math.floor(stat.mtime.nsec / 1e6)) < 2 * config.send_timeout_ms
end

-- Sets the mtime of queue file `name` to now: the time of a claim.
local function touch(name)
  local t = now_ms() / 1000
  return uv.fs_utime(path(name), t, t)
end

--- The raw text of queue file `name` (for one that does not parse).
function M.raw(name)
  local fd = uv.fs_open(path(name), 'r', 0)
  if not fd then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  local data = stat and uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  return data
end

-- Every name in the queue directory, or nil and the reason. A directory that
-- does not exist yet is an empty queue; any other failure to list it is an
-- error, never an empty list (rule 6).
local function scan()
  local handle, err = uv.fs_scandir(config.dir)
  if not handle then
    if tostring(err):find('ENOENT') then
      return {}
    end
    return nil, 'cannot read the queue directory: ' .. tostring(err)
  end
  local names = {}
  while true do
    local name, failure = uv.fs_scandir_next(handle)
    if not name then
      if failure then
        return nil, 'cannot read the queue directory: ' .. tostring(failure)
      end
      return names
    end
    names[#names + 1] = name
  end
end

-- The messages among `names`, oldest first: { id, name, claimed (pid or
-- nil), token, record (nil when unreadable), error }.
local function entries(names)
  local result = {}
  for _, name in ipairs(names) do
    local id = name:match(NAME_RE)
    local claimed_id, pid, token = name:match(CLAIM_RE)
    if id or claimed_id then
      local record, err = read(name)
      result[#result + 1] = {
        id = id or claimed_id, name = name, claimed = pid and tonumber(pid), token = token, record = record, error = err,
      }
    end
  end
  table.sort(result, function(a, b)
    return a.id < b.id
  end)
  return result
end

--- Every message in the queue, oldest first: { id, name, claimed (pid or
--- nil), record (nil when unreadable), error }; or nil and the reason when
--- the queue directory cannot be read.
function M.list()
  if not config.dir then
    return {}
  end
  local names, err = scan()
  if not names then
    return nil, err
  end
  return entries(names)
end

--- Queues `message` ({ subject, body, and for a reply reply_to and to }) for
--- `city` ({ name, path }). Returns the id, or nil and the reason (the queue is
--- full, busy or unreadable, or the write failed).
function M.add(city, message)
  if not config.dir then
    return nil, 'no queue directory'
  end
  local sec, usec = uv.gettimeofday()
  worker.seq = (worker.seq + 1) % 100000
  local id = ('%010d%06d-%05d-%s'):format(sec, usec, worker.seq, vim.text.hexencode(uv.random(4)))
  local name = id .. '.json'
  local record = {
    version = 1, city = { name = city.name, path = city.path }, subject = message.subject, body = message.body,
    created = sec, attempts = 0, next_at = 0, failed = false, reply_to = message.reply_to, to = message.to,
  }
  local bad = invalid(record)
  if bad then
    return nil, 'cannot queue the message: ' .. bad
  end
  local temp, err = stage(name, record)
  if not temp then
    return nil, 'cannot write the queue file: ' .. tostring(err)
  end
  -- Count and rename in one hold of the lock: the place counted is the place
  -- taken (rule 5).
  local added, reason = locked(config.lock_wait_ms, function()
    local names, serr = scan()
    if not names then
      return nil, serr
    end
    local count = 0
    for _, n in ipairs(names) do
      if n:match(NAME_RE) or n:match(CLAIM_RE) then
        count = count + 1
      end
    end
    if count >= config.max_files then
      return nil, ('the queue already holds %d messages; send or delete some with :GcMailQueue'):format(config.max_files)
    end
    local ok, rerr = uv.fs_rename(temp, path(name))
    if not ok then
      return nil, 'cannot write the queue file: ' .. tostring(rerr)
    end
    return true
  end)
  if not added then
    uv.fs_unlink(temp)
    return nil, reason
  end
  notify_subscribers()
  return id
end

local pump

local function arm(delay)
  if worker.timer then
    worker.timer:stop()
    worker.timer:close()
  end
  worker.timer = uv.new_timer()
  worker.timer:start(math.max(0, delay), 0, vim.schedule_wrap(function()
    pump()
  end))
end

local function backoff(tries)
  return config.settle_ms[math.max(1, math.min(tries, #config.settle_ms))]
end

-- Puts the outcome of the last send on disk under the lock (rules 2 and 4);
-- true once it is (or when there is nothing to put). Until then the message
-- stays claimed by this Neovim, so neither it nor another one sends it again,
-- and pump() sends nothing else. Returns false, true when the lock was busy.
--   delete   gc delivered it: remove the claim. If that fails, rewrite the
--            claim marked delivered, so a restart drops it instead of resending.
--   record   gc failed: rewrite the claim with the new tries, delay and error,
--            then rename it back to <id>.json.
local function settle(wait_ms)
  local held = worker.held
  if not held then
    return true
  end
  held.stale = nil
  local took_away = false
  local ok, err, busy = locked(wait_ms, function()
    -- Keep the claim young while it waits, so no other Neovim takes it back
    -- (rule 3). If one already has (this Neovim was stopped for longer than
    -- twice the send timeout), that one owns the message now.
    local touched, terr = touch(held.claimed)
    if not touched then
      if tostring(terr):find('ENOENT') then
        took_away = true
        return true
      end
      -- The time cannot be set: rewriting the claim whole makes it young as
      -- well (a new file has the time it was written), and a delivered one
      -- goes marked, so if it ages out after all it is dropped, never sent
      -- again. Only a claim that is still there is rewritten.
      if held.kind == 'delete' then
        held.record.delivered = true
      end
      local rewritten, rerr
      if uv.fs_stat(path(held.claimed)) then
        rewritten, rerr = write(held.claimed, held.record)
      end
      if rewritten then
        held[held.kind == 'delete' and 'marked' or 'written'] = true
      else
        held.stale = ('%s; %s'):format(tostring(terr), tostring(rerr or 'cannot read it'))
      end
    end
    if held.kind == 'delete' then
      local gone, uerr = uv.fs_unlink(path(held.claimed))
      if gone or tostring(uerr):find('ENOENT') then
        return true
      end
      if not held.marked then
        held.record.delivered = true
        held.marked = write(held.claimed, held.record) == true
      end
      return nil, uerr
    end
    if not held.written then
      local written, werr = write(held.claimed, held.record)
      if not written then
        return nil, werr
      end
      held.written = true
    end
    return uv.fs_rename(path(held.claimed), path(held.id .. '.json'))
  end)
  if busy then
    return false, true
  end
  local name = who(held.record)
  if ok then
    local settled_held = held
    worker.held = nil
    if held.notified then
      config.notify(('the queue file of the message to %s is in order again'):format(name))
    end
    if not took_away then
      notify_subscribers(settled_held)
    end
    return true
  end
  held.tries = held.tries + 1
  if held.stale and not held.stale_notified then
    -- Rule 3 cannot hold: the claim ages, and once it is older than twice
    -- the send timeout another Neovim may take it back.
    held.stale_notified = true
    config.notify(('cannot keep the claim on the message to %s young (%s); another Neovim may send it again after %d s')
      :format(name, held.stale, math.floor(2 * config.send_timeout_ms / 1000)), vim.log.levels.ERROR)
  end
  if not held.notified then
    held.notified = true
    local message
    if held.kind == 'delete' then
      message = ('sent to %s, but cannot remove its queue file (%s); %s'):format(name, tostring(err),
        held.marked and 'it is marked sent, removal retried' or 'removal retried, a restart before that sends it again')
    else
      message = ('cannot record the failed send to %s (%s); the queue waits until it is written'):format(name,
        tostring(err))
    end
    config.notify(message, vim.log.levels.ERROR)
  end
  return false
end

-- One send of the claimed message; the result reschedules the worker.
local function send(pick)
  worker.busy = true
  local record = pick.record
  local function finish(code, detail)
    worker.busy = false
    if code == 0 then
      config.notify(('sent to %s'):format(who(record)))
      worker.held = { kind = 'delete', id = pick.id, claimed = pick.claimed, record = record, tries = 0 }
    else
      record.attempts = record.attempts + 1
      record.last_error = ('exit %s%s'):format(code, detail ~= '' and (': ' .. detail) or '')
      local delay = config.retry_ms[record.attempts]
      record.failed = delay == nil
      record.next_at = delay and (now_ms() + delay) or 0
      if record.attempts == 1 then
        config.notify(('send to %s failed (%s)%s; retrying in the background'):format(who(record),
          'exit ' .. code, detail ~= '' and (':\n' .. detail) or ''), vim.log.levels.ERROR)
      elseif record.failed then
        config.notify(('gave up sending to %s after %d tries; :GcMailQueue to retry'):format(who(record),
          record.attempts), vim.log.levels.ERROR)
      end
      worker.held = { kind = 'record', id = pick.id, claimed = pick.claimed, record = record, tries = 0 }
    end
    if worker.stopped then
      -- Neovim may be quitting: wait for the lock rather than leave the
      -- outcome to a restart.
      settle(config.lock_wait_ms)
    else
      pump()
    end
  end
  local ok, err = pcall(vim.system, require('gc_mail').argv(record.city, record),
    { text = true, timeout = config.send_timeout_ms }, function(result)
      vim.schedule(function()
        local detail = first_lines(result.stderr, 3)
        if detail == '' then
          detail = first_lines(result.stdout, 3)
        end
        finish(result.code, result.code == 124 and 'gc did not answer in time' or detail)
      end)
    end)
  if not ok then
    finish('?', 'cannot run gc (is it on PATH?): ' .. tostring(err))
  end
end

-- Runs under the lock, from a listing taken under it (rule 2). Removes the
-- temp files of Neovims that are gone, puts back every claim that is not live
-- (rule 3), drops unclaimed files marked delivered, then claims the next due
-- message: the oldest unfailed one of its city, after every older one to that
-- city.
-- Returns { id, claimed, record } to send, or { wait = ms } (nil: nothing
-- waits), or nil and the reason.
local function choose()
  local names, err = scan()
  if not names then
    return nil, err
  end
  local changed = false
  local present = {}
  for _, name in ipairs(names) do
    present[name] = true
    local pid = select(2, name:match(TEMP_RE))
    if pid and not alive(tonumber(pid)) then
      if uv.fs_unlink(path(name)) then
        changed = true
      end
    end
  end
  local now, blocked, earliest = now_ms(), {}, nil
  local function later(at)
    earliest = math.min(earliest or math.huge, at)
  end
  for _, entry in ipairs(entries(names)) do
    local record = entry.record
    if entry.claimed and not live(entry) then
      local base = entry.id .. '.json'
      if (record and record.delivered) or present[base] then
        if uv.fs_unlink(path(entry.name)) then
          changed = true
        end
        record = nil
      elseif uv.fs_rename(path(entry.name), path(base)) then
        changed = true
        entry.name, entry.claimed = base, nil
      end
    end
    if not record then
      -- Unreadable, or dropped above: never sent.
    elseif record.delivered then
      -- Sent earlier, but its file could not be removed then.
      if not entry.claimed then
        if uv.fs_unlink(path(entry.name)) then
          changed = true
        end
      end
    elseif not record.failed and not blocked[record.city.path] then
      blocked[record.city.path] = true
      if entry.claimed then
        -- Another Neovim is sending it: look again once it is done.
        later(now + 1000)
      elseif record.next_at > now then
        later(record.next_at)
      else
        -- The claim's time is set before the rename, so it is never seen
        -- with the time the message was written.
        local claimed = claim_of(entry.id)
        if touch(entry.name) and uv.fs_rename(path(entry.name), path(claimed)) then
          return { id = entry.id, claimed = claimed, record = record, changed = true }
        end
        later(now + 1000)
      end
    end
  end
  return { wait = earliest and (earliest - now), changed = changed }
end

-- The worker could not read the queue: say why once, look again later.
local function trouble(reason)
  worker.tries = worker.tries + 1
  if worker.trouble ~= reason then
    worker.trouble = reason
    config.notify(reason .. '; nothing is sent until it can be read', vim.log.levels.ERROR)
  end
  arm(backoff(worker.tries))
end

--- One worker pass: settles the last send's outcome, then sends the next due
--- message or arms a timer for the earliest one waiting out a retry delay.
--- While the last outcome is not on disk, it only retries that.
function pump()
  if worker.busy or worker.stopped or not config.dir then
    return
  end
  local settled, busy = settle(0)
  if not settled then
    return arm(busy and config.busy_ms or backoff(worker.held.tries))
  end
  -- A first look without the lock: an empty queue needs none.
  local names, err = scan()
  if not names then
    return trouble(err)
  end
  local work = false
  for _, name in ipairs(names) do
    work = work or name:match(NAME_RE) ~= nil or name:match(CLAIM_RE) ~= nil or name:match(TEMP_RE) ~= nil
  end
  local pick
  if work then
    pick, err, busy = locked(0, choose)
    if busy then
      return arm(config.busy_ms)
    elseif not pick then
      return trouble(err)
    end
    if pick.changed then
      notify_subscribers()
    end
  end
  if worker.trouble then
    worker.trouble, worker.tries = nil, 0
    config.notify('the queue can be read again')
  end
  if pick and pick.record then
    return send(pick)
  elseif pick and pick.wait then
    arm(pick.wait)
  end
end
M.pump = pump

--- Starts the worker; its first pass puts back every claim that is not live
--- (drops those marked delivered) and removes the temp files of Neovims that
--- are gone. Failed messages stay failed.
function M.resume()
  pump()
end

--- Sends `id` again now (failed or waiting); nil and the reason if it is
--- being sent, gone, or the queue is busy. Read and rewritten under the
--- lock, so it can never recreate a file a worker has just claimed.
function M.retry(id)
  local name = id .. '.json'
  local ok, err = locked(config.lock_wait_ms, function()
    local record, rerr = read(name)
    if not record then
      return nil, rerr and tostring(rerr):find('ENOENT') and 'it is being sent or gone' or tostring(rerr)
    end
    if record.delivered then
      return nil, 'it was sent already'
    end
    record.failed, record.attempts, record.next_at = false, 0, 0
    local written, werr = write(name, record)
    if not written then
      return nil, tostring(werr)
    end
    return true
  end)
  if not ok then
    return nil, err
  end
  notify_subscribers()
  pump()
  return true
end

--- Deletes `id` unless it is being sent.
function M.delete(id)
  local ok, err = locked(config.lock_wait_ms, function()
    local ok, err = uv.fs_unlink(path(id .. '.json'))
    if not ok then
      return nil, err and err:find('ENOENT') and 'it is being sent or gone' or tostring(err)
    end
    return true
  end)
  if ok then
    notify_subscribers()
  end
  return ok, err
end

--- Stops the worker: no new send starts; one already running finishes.
function M.stop()
  worker.stopped = true
  if worker.timer then
    worker.timer:stop()
    worker.timer:close()
    worker.timer = nil
  end
end

function M.idle()
  return not worker.busy
end

return M
