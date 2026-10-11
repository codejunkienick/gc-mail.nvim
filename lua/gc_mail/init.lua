-- gc-mail.nvim: mail the current buffer to a Gas City mayor, and read the mail
-- addressed to you.
--
-- <Space>mm (or :GcMail) opens a small floating picker of the cities
-- registered with the gc supervisor, at once: the list comes from a cache
-- that one background `gc cities --json` fills after startup and refreshes on
-- every open. Choosing a city writes the message to the on-disk queue
-- (gc_mail.queue) and only then clears the buffer; the queue's worker runs
--   gc --city <path> mail send mayor -s <subject> -m <body> --notify
-- in the background, in order, with retries. In a reply buffer the same keys
-- queue the reply instead (gc mail reply). <Space>mi (or :GcMailbox) opens
-- the mailbox (gc_mail.mailbox); <Space>mp (or :GcMailPanel) toggles the same
-- mailbox docked below the current window (gc_mail.panel). Nothing runs at
-- load time.
local queue = require('gc_mail.queue')

local M = {}

local defaults = {
  -- Normal-mode mapping; false sets none (:GcMail still works).
  keymap = '<Space>mm',
  -- Where the queue lives: <state_dir>/queue/.
  state_dir = vim.fn.stdpath('state') .. '/gc-mail',
  -- Delays (ms) before each retry of a failed send; then it is marked failed.
  retry_ms = { 10000, 60000, 300000 },
  -- Normal-mode mapping that opens the mailbox; false sets none (:GcMailbox works).
  mailbox_keymap = '<Space>mi',
  -- Added to the subject of every message the plugin sends, new mail and
  -- replies, exactly once and within the 72-character limit; '' adds nothing.
  subject_prefix = '',
  subject_suffix = '',
  -- false: no timer. A number of ms (at least 60000): while Neovim has focus,
  -- one `gc mail count` per city that often, and a notice when unread mail grows.
  check_ms = false,
  -- true: after startup, watch every city's event log: a notice when mail for
  -- you arrives and an unread count for require('gc_mail').status(). false: no
  -- watch.
  watch = true,
  -- While the watch runs: every city's unread mail counted again this often (ms,
  -- at least 60000), besides the events that move the count.
  watch_resync_ms = 300000,
  -- Normal-mode mapping that toggles the mail panel; false sets none (:GcMailPanel works).
  panel_keymap = '<Space>mp',
  -- Rows of the mail panel.
  panel_height = 10,
  -- While the panel is open: every city listed again this often (ms, at least
  -- 15000), besides the updates gc's event log brings.
  panel_poll_ms = 60000,
  -- true: the mailbox float and the panel show the body of the message under the
  -- cursor in a pane beside the list (p toggles it while a list is open). false:
  -- they open with the pane hidden.
  preview = true,
  -- How often to retry watching a missing or refused event log (ms, at least 15000).
  events_rearm_ms = 60000,
  -- true: the opened message and the thread are markdown buffers (filetype
  -- markdown, for whatever markdown renderer you run). false: plain text.
  markdown = true,
  -- How many days back to load mail history from the bead store.
  history_days = 14,
  -- Normal-mode mapping that opens the last chat; false sets none (:GcMailChat works).
  chat_keymap = '<Space>mc',
  -- Columns of the chat window (at least 20).
  chat_width = 60,
  -- Rows of the chat compose box (at least 1).
  chat_compose_height = 3,
  -- Keys mapped in normal mode of the chat compose box ({ '<Space>ms' }); false maps none.
  chat_send_keys = { '<Space>ms' },
  -- true: unread mail to human in the rendered conversation is marked read when viewed.
  chat_mark_read = true,
  -- While a chat is open: its city's history loaded again this often (ms, at
  -- least 15000), besides the updates gc's event log brings.
  chat_poll_ms = 60000,
}

M.config = vim.deepcopy(defaults)
M.queue = queue

local SUBJECT_MAX = 72
-- The label may take at most this many of the 72 characters.
local LABEL_MAX = 40
-- Linux refuses one argv string over 128 KiB (MAX_ARG_STRLEN); stay below it
-- so a huge buffer gets a clear message instead of a spawn error.
local BODY_MAX_BYTES = 120 * 1024
local CITIES_TIMEOUT_MS = 10000
local LOADING = ' loading… '

local function notify(message, level)
  vim.notify('gc-mail: ' .. message, level or vim.log.levels.INFO)
end

local first_lines = queue.first_lines

--- `subject` with the configured prefix and suffix, exactly once: any copy of
--- either already in it (a reply to a labelled message) is taken out first,
--- and the rest is cut so the whole stays within 72 characters.
function M.label(subject, opts)
  opts = opts or M.config
  local prefix, suffix = opts.subject_prefix or '', opts.subject_suffix or ''
  local core = subject
  for _, part in ipairs({ prefix, suffix }) do
    if part ~= '' then
      core = core:gsub(vim.pesc(part), '')
    end
  end
  core = vim.trim(core)
  local room = SUBJECT_MAX - vim.fn.strchars(prefix) - vim.fn.strchars(suffix)
  return prefix .. vim.fn.strcharpart(core, 0, room) .. suffix
end

--- The message a buffer would send: { subject, body }, or nil and the reason.
--- The subject is labelled (M.label). A buffer that cannot be cleared after
--- queueing is refused too: sending it again unchanged would mail it twice.
function M.message(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local body = table.concat(lines, '\n')
  if vim.trim(body) == '' then
    return nil, 'buffer is empty, nothing to send'
  end
  if #body > BODY_MAX_BYTES then
    return nil, ('buffer is %d bytes, over the %d byte limit for one message'):format(#body, BODY_MAX_BYTES)
  end
  if not vim.bo[buf].modifiable then
    return nil, 'buffer is not modifiable, so it cannot be cleared after sending'
  end
  local subject
  for _, line in ipairs(lines) do
    if vim.trim(line) ~= '' then
      subject = M.label(vim.trim(line))
      break
    end
  end
  return { subject = subject, body = body }
end

-- A control character (0x00-0x1f, 0x7f): a city name or path with one is
-- malformed (a picker line cannot hold a line break).
local CONTROL = '[%z\1-\31\127]'

-- The cities in a finished `gc cities --json` (a vim.system result), or nil
-- and the reason. Anything but the documented record is an error, and so is a
-- gc killed at the timeout.
local function parse_cities(result, timeout_ms)
  -- On timeout Neovim kills gc (SIGKILL from wait(), SIGTERM from the
  -- timeout option) and reports exit 124; a nil result is a child not reaped
  -- even after the kill.
  if result == nil or (result.code == 124 and (result.signal or 0) ~= 0) then
    return nil, ('gc cities did not answer within %g s'):format(timeout_ms / 1000)
  end
  if result.code ~= 0 then
    local detail = first_lines(result.stderr, 3)
    return nil, 'gc cities failed' .. (detail ~= '' and (':\n' .. detail) or (' (exit ' .. result.code .. ')'))
  end
  -- Exactly one record line: anything else on stdout is unexpected output.
  local line = vim.trim(result.stdout or '')
  local decoded_ok, record = pcall(vim.json.decode, line)
  if line:find('\n') or not decoded_ok or type(record) ~= 'table' or record.ok ~= true
      or type(record.cities) ~= 'table' then
    return nil, 'gc cities --json printed something unexpected'
  end
  local cities = {}
  for _, city in ipairs(record.cities) do
    if type(city) ~= 'table' or type(city.name) ~= 'string' or city.name == ''
        or type(city.path) ~= 'string' or city.path == '' then
      return nil, 'gc cities --json listed a city without a name or path'
    end
    if city.name:find(CONTROL) or city.path:find(CONTROL) then
      return nil, 'gc cities --json listed a city name or path with a control character'
    end
    cities[#cities + 1] = { name = city.name, path = city.path }
  end
  return cities
end

--- The registered cities from `gc cities --json`, waiting for gc: a list of
--- { name, path }, or nil and the reason. A gc that does not answer within
--- `timeout_ms` (default 10 s) is killed. The picker never waits on this; it
--- reads the cache M.refresh() fills.
function M.cities(timeout_ms)
  timeout_ms = timeout_ms or CITIES_TIMEOUT_MS
  local ok, proc = pcall(vim.system, { 'gc', 'cities', '--json' }, { text = true })
  if not ok then
    return nil, 'cannot run gc (is it on PATH?)'
  end
  local result = proc:wait(timeout_ms)
  if result == nil then
    pcall(proc.kill, proc, 9)
  end
  return parse_cities(result, timeout_ms)
end

-- The city list cache: the last good list (nil before the first), and the
-- callbacks waiting for the refresh in flight.
local cache = { cities = nil, error = nil, warned = false, waiting = nil }

--- Starts one background `gc cities --json` (joining one already running);
--- `on_done(cities, err)` runs on the main loop when it ends. A good answer
--- replaces the cache; a failed one keeps the last good list and records why.
function M.refresh(on_done, timeout_ms)
  timeout_ms = timeout_ms or CITIES_TIMEOUT_MS
  if cache.waiting then
    cache.waiting[#cache.waiting + 1] = on_done
    return
  end
  cache.waiting = { on_done }
  local function finish(cities, err)
    if cities then
      cache.cities, cache.error, cache.warned = cities, nil, false
    else
      cache.error = err
    end
    local waiting = cache.waiting
    cache.waiting = nil
    for _, fn in ipairs(waiting) do
      fn(cities, err)
    end
  end
  local ok, err = pcall(vim.system, { 'gc', 'cities', '--json' }, { text = true, timeout = timeout_ms }, function(result)
    vim.schedule(function()
      finish(parse_cities(result, timeout_ms))
    end)
  end)
  if not ok then
    finish(nil, 'cannot run gc (is it on PATH?): ' .. tostring(err))
  end
end

--- The cached city list (nil before the first good answer).
function M.cached_cities()
  return cache.cities
end

--- gc's argv for one send, or for a reply when `message.reply_to` is set;
--- never a shell string.
function M.argv(city, message)
  if message.reply_to then
    return { 'gc', '--city', city.path, 'mail', 'reply', message.reply_to, '-s', message.subject, '-m', message.body, '--notify' }
  end
  return { 'gc', '--city', city.path, 'mail', 'send', message.to or 'mayor', '-s', message.subject, '-m', message.body, '--notify' }
end

--- Queue `buf` for `city`'s mayor, or as a reply when `opts` ({ id, to })
--- is given, or to `opts.to`, then clear it. The message is on disk before
--- the buffer changes, and the clear is its own undo step, so `u` brings
--- the text back. A refused or failed queue write leaves the buffer as it
--- was. Returns the queue id, or nil.
function M.send(buf, city, opts)
  local message, reason = M.message(buf)
  if not message then
    notify(reason, vim.log.levels.WARN)
    return nil
  end
  local is_reply = false
  if opts then
    if opts.id or opts.reply_to then
      is_reply = true
      message.reply_to, message.to = opts.id or opts.reply_to, opts.to
    elseif opts.to ~= nil then
      message.to = opts.to
    end
  end
  local who = queue.who({ city = city, to = message.to })
  local id, err = queue.add(city, message)
  if not id then
    notify(err, vim.log.levels.ERROR)
    return nil
  end
  -- The message is queued whatever happens to the buffer now: a clear that
  -- fails leaves the buffer as it is and says so, the queue sends it once.
  local cleared, clear_err = pcall(function()
    if vim.api.nvim_buf_is_valid(buf) then
      -- Close the undo block of earlier edits so the clear undoes on its own.
      vim.bo[buf].undolevels = vim.bo[buf].undolevels
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
      vim.bo[buf].modified = false
    end
  end)
  if is_reply then
    -- Queued: the buffer is no longer a reply waiting to go, cleared or not.
    pcall(vim.api.nvim_buf_del_var, buf, 'gc_mail_reply')
  end
  if cleared then
    notify(('queued for %s: %s'):format(who, message.subject))
  else
    notify(('queued for %s: %s; the buffer was left as it is (cannot clear it: %s)'):format(who, message.subject,
      first_lines(tostring(clear_err), 1)), vim.log.levels.WARN)
  end
  queue.pump()
  return id
end

--- Height and position that keep a picker, border included, above the
--- command line in an editor of `lines` rows.
function M.layout(count, width, lines, columns, cmdheight)
  local room = math.max(1, lines - cmdheight - 2)
  local height = math.max(1, math.min(count, room))
  width = math.max(1, math.min(width, columns - 2))
  return {
    height = height,
    width = width,
    row = math.max(0, math.floor((lines - cmdheight - height - 2) / 2)),
    col = math.max(0, math.floor((columns - width - 2) / 2)),
  }
end

-- A small bordered float listing `items` with `title`, focused, closed by
-- <Esc>, q or leaving it. Returns { win, buf, set(items), close(), closed() }.
-- The mailbox uses it too (M.float).
local function float(title, items, keys)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  local function geometry(lines)
    local width = vim.fn.strdisplaywidth(title) + 2
    for _, item in ipairs(lines) do
      width = math.max(width, vim.fn.strdisplaywidth(item))
    end
    return M.layout(#lines, width, vim.o.lines, vim.o.columns, vim.o.cmdheight)
  end
  local function fill(lines)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
  end
  fill(items)
  local layout = geometry(items)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor', style = 'minimal', border = 'rounded', title = title, title_pos = 'center',
    row = layout.row, col = layout.col, width = layout.width, height = layout.height,
  })
  vim.wo[win].cursorline = true
  local picker = { win = win, buf = buf }
  local closed = false
  function picker.closed()
    return closed or not vim.api.nvim_win_is_valid(win)
  end
  function picker.close()
    if not closed then
      closed = true
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end
  end
  function picker.set(lines)
    if picker.closed() then
      return
    end
    local row = vim.api.nvim_win_get_cursor(win)[1]
    fill(lines)
    local l = geometry(lines)
    vim.api.nvim_win_set_config(win, { relative = 'editor', row = l.row, col = l.col, width = l.width, height = l.height })
    vim.api.nvim_win_set_cursor(win, { math.min(row, #lines), 0 })
  end
  local function map(lhs, rhs)
    vim.keymap.set('n', lhs, rhs, { buffer = buf, nowait = true, silent = true })
  end
  map('<Esc>', picker.close)
  map('q', picker.close)
  map('<Down>', 'j')
  map('<Up>', 'k')
  for lhs, fn in pairs(keys) do
    map(lhs, function()
      fn(picker, vim.api.nvim_win_get_cursor(win)[1])
    end)
  end
  vim.api.nvim_create_autocmd('WinLeave', { buffer = buf, once = true, callback = picker.close })
  return picker
end

M.float = float

local function city_items(cities, to)
  local items = {}
  local recipient = to or 'mayor'
  for i, city in ipairs(cities) do
    items[i] = (' %s  %s '):format(city.name, recipient)
  end
  return items
end

--- The reply a buffer is for ({ city, id, to }, set by the mailbox), or nil.
function M.reply_of(buf)
  local ok, reply = pcall(vim.api.nvim_buf_get_var, buf, 'gc_mail_reply')
  if ok and type(reply) == 'table' and type(reply.city) == 'table' and type(reply.city.name) == 'string'
      and type(reply.city.path) == 'string' and type(reply.id) == 'string' and type(reply.to) == 'string' then
    return reply
  end
end

--- Open the recipient picker for the current buffer. It shows the cached cities
--- (or a loading line) at once and refreshes them in the background. In a
--- reply buffer it queues the reply at once instead: the city and the
--- message it answers are known.
function M.open(opts)
  local to
  if type(opts) == 'string' and opts ~= '' then
    to = opts
  elseif type(opts) == 'table' then
    to = opts.to
  end
  local target = vim.api.nvim_get_current_buf()
  local _, reason = M.message(target)
  if reason then
    return notify(reason, vim.log.levels.WARN)
  end
  local reply = M.reply_of(target)
  if reply then
    if to then
      notify(('this buffer replies to %s; %s ignored'):format(reply.to, to), vim.log.levels.WARN)
    end
    M.send(target, reply.city, reply)
    return nil
  end
  local shown = cache.cities and #cache.cities > 0 and cache.cities or nil
  local title = to and (' mail buffer to %s in '):format(to) or ' mail buffer to '
  local picker = float(title, shown and city_items(shown, to) or { LOADING }, {
    ['<CR>'] = function(p, row)
      if shown then
        local city = shown[row]
        p.close()
        M.send(target, city, to and { to = to } or nil)
      end
    end,
  })
  M.refresh(function(cities, err)
    if not cities then
      if shown then
        if not cache.warned then
          cache.warned = true
          notify('gc cities failed, showing the last list:\n' .. err, vim.log.levels.WARN)
        end
        return
      end
      picker.close()
      return notify(err, vim.log.levels.ERROR)
    end
    if #cities == 0 then
      picker.close()
      return notify('no cities are registered with gc', vim.log.levels.WARN)
    end
    shown = cities
    picker.set(city_items(cities, to))
  end)
  return picker.win
end

local function age(seconds)
  seconds = math.floor(seconds)
  if seconds < 60 then
    return ('%ds'):format(seconds)
  elseif seconds < 3600 then
    return ('%dm'):format(seconds / 60)
  elseif seconds < 86400 then
    return ('%dh'):format(seconds / 3600)
  end
  return ('%dd'):format(seconds / 86400)
end

-- `text` as one display line: line breaks as ' / ', any other control
-- character as a space. Queue files are read from disk, and one line break
-- in a buffer line would make nvim_buf_set_lines() refuse the whole list.
local function one_line(text)
  return (tostring(text):gsub('\r?\n', ' / '):gsub('%c', ' '))
end
M.age, M.one_line = age, one_line

--- The :GcMailQueue lines for `entries` (queue.list()), or for `err` when
--- the queue cannot be read. Each line is one sanitized line.
function M.queue_lines(entries, now, err)
  if not entries then
    return { ' ' .. one_line(err) .. ' ' }
  elseif #entries == 0 then
    return { ' the queue is empty ' }
  end
  local lines = {}
  for i, entry in ipairs(entries) do
    local record = entry.record
    if not record then
      lines[i] = (' ? %s  unreadable: %s '):format(one_line(entry.name), one_line(entry.error))
    else
      local state = record.delivered and 'sent, file not removed' or entry.claimed and 'sending'
        or record.failed and 'failed' or 'pending'
      local line = (' %s  %s  %s  %s'):format(one_line(record.to and queue.who(record) or record.city.name),
        one_line(record.subject), age(math.max(0, now - record.created)), state)
      if record.last_error then
        line = line .. '  ' .. one_line(record.last_error)
      end
      lines[i] = line .. ' '
    end
  end
  return lines
end

--- Open the queue list: r retries, o opens the text in a new buffer, d
--- deletes (not one being sent), <Esc> or q closes.
function M.open_queue()
  local entries, err = queue.list()
  local function reload(picker)
    entries, err = queue.list()
    picker.set(M.queue_lines(entries, os.time(), err))
  end
  local function act(fn)
    return function(picker, row)
      local entry = entries and entries[row]
      if entry then
        fn(picker, entry)
      end
    end
  end
  return float(' gc-mail queue: r retry  o open  d delete ', M.queue_lines(entries, os.time(), err), {
    r = act(function(picker, entry)
      local ok, err = queue.retry(entry.id)
      if not ok then
        notify('cannot retry: ' .. err, vim.log.levels.WARN)
      end
      reload(picker)
    end),
    o = act(function(picker, entry)
      local text = entry.record and entry.record.body or queue.raw(entry.name) or ''
      picker.close()
      vim.cmd('new')
      vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(text, '\n', { plain = true }))
    end),
    d = act(function(picker, entry)
      local ok, err = queue.delete(entry.id)
      if not ok then
        notify('cannot delete: ' .. err, vim.log.levels.WARN)
      end
      reload(picker)
    end),
  }).win
end

-- Why `opts` cannot be used, or nil. A label with a control character could
-- not be one subject line; one longer than LABEL_MAX would leave no subject.
local function invalid_options(opts)
  for _, key in ipairs({ 'subject_prefix', 'subject_suffix' }) do
    if type(opts[key]) ~= 'string' or opts[key]:find(CONTROL) then
      return key .. ' must be a string without control characters'
    end
  end
  if vim.fn.strchars(opts.subject_prefix) + vim.fn.strchars(opts.subject_suffix) > LABEL_MAX then
    return ('subject_prefix and subject_suffix together are over %d characters'):format(LABEL_MAX)
  end
  if opts.check_ms ~= false and (type(opts.check_ms) ~= 'number' or opts.check_ms < 60000) then
    return 'check_ms must be false or a number of milliseconds of at least 60000'
  end
  if type(opts.watch) ~= 'boolean' then
    return 'watch must be true or false'
  end
  if type(opts.watch_resync_ms) ~= 'number' or opts.watch_resync_ms < 60000 then
    return 'watch_resync_ms must be a number of milliseconds of at least 60000'
  end
  if type(opts.markdown) ~= 'boolean' then
    return 'markdown must be true or false'
  end
  if type(opts.preview) ~= 'boolean' then
    return 'preview must be true or false'
  end
  if type(opts.panel_poll_ms) ~= 'number' or opts.panel_poll_ms < 15000 then
    return 'panel_poll_ms must be a number of milliseconds of at least 15000'
  end
  if type(opts.events_rearm_ms) ~= 'number' or opts.events_rearm_ms < 15000 then
    return 'events_rearm_ms must be a number of milliseconds of at least 15000'
  end
  if type(opts.panel_height) ~= 'number' or opts.panel_height < 1 or opts.panel_height ~= math.floor(opts.panel_height) then
    return 'panel_height must be a whole number of rows of at least 1'
  end
  if type(opts.history_days) ~= 'number' or opts.history_days < 1 or opts.history_days ~= math.floor(opts.history_days) then
    return 'history_days must be a whole number of at least 1'
  end
  if type(opts.chat_width) ~= 'number' or opts.chat_width < 20 or opts.chat_width ~= math.floor(opts.chat_width) then
    return 'chat_width must be a whole number of columns of at least 20'
  end
  if type(opts.chat_compose_height) ~= 'number' or opts.chat_compose_height < 1 or opts.chat_compose_height ~= math.floor(opts.chat_compose_height) then
    return 'chat_compose_height must be a whole number of rows of at least 1'
  end
  if opts.chat_send_keys ~= false then
    if type(opts.chat_send_keys) ~= 'table' or not vim.islist(opts.chat_send_keys) then
      return 'chat_send_keys must be false or a list of key mappings'
    end
    for _, key in ipairs(opts.chat_send_keys) do
      if type(key) ~= 'string' or key == '' then
        return 'chat_send_keys must be false or a list of key mappings'
      end
    end
  end
  if type(opts.chat_mark_read) ~= 'boolean' then
    return 'chat_mark_read must be true or false'
  end
  if type(opts.chat_poll_ms) ~= 'number' or opts.chat_poll_ms < 15000 then
    return 'chat_poll_ms must be a number of milliseconds of at least 15000'
  end
  if opts.chat_keymap ~= false and (type(opts.chat_keymap) ~= 'string' or opts.chat_keymap == '') then
    return 'chat_keymap must be false or a non-empty string'
  end
end

function M.setup(opts)
  local config = vim.tbl_extend('force', vim.deepcopy(defaults), opts or {})
  local bad = invalid_options(config)
  if bad then
    error('gc-mail: ' .. bad, 2)
  end
  M.config = config
  queue.configure({ dir = M.config.state_dir .. '/queue', retry_ms = M.config.retry_ms })
  -- The mailbox loads when it is first opened; its copies live in
  -- <state_dir>/mailbox/.
  if M.config.keymap then
    vim.keymap.set('n', M.config.keymap, M.open, { desc = 'Mail the buffer to a gc city mayor' })
  end
  if M.config.mailbox_keymap then
    vim.keymap.set('n', M.config.mailbox_keymap, function()
      require('gc_mail.mailbox').open()
    end, { desc = 'Open the gc mailbox' })
  end
  if M.config.panel_keymap then
    vim.keymap.set('n', M.config.panel_keymap, function()
      require('gc_mail.panel').toggle()
    end, { desc = 'Toggle the gc mail panel' })
  end
  if M.config.chat_keymap then
    vim.keymap.set('n', M.config.chat_keymap, function()
      require('gc_mail.chat').open_last()
    end, { desc = 'Open the gc chat' })
  end
  vim.api.nvim_create_user_command('GcMail', function(cmd_opts)
    local to = vim.trim(cmd_opts.args or '') ~= '' and vim.trim(cmd_opts.args) or nil
    require('gc_mail').open(to)
  end, { desc = 'Mail the buffer to a gc city mayor or recipient', force = true, nargs = '?' })
  vim.api.nvim_create_user_command('GcMailQueue', function()
    require('gc_mail').open_queue()
  end, { desc = 'List the gc-mail send queue', force = true })
  vim.api.nvim_create_user_command('GcMailbox', function()
    require('gc_mail.mailbox').open()
  end, { desc = 'Open the gc mailbox', force = true })
  vim.api.nvim_create_user_command('GcMailPanel', function()
    require('gc_mail.panel').toggle()
  end, { desc = 'Toggle the gc mail panel', force = true })
  vim.api.nvim_create_user_command('GcMailChat', function(cmd_opts)
    require('gc_mail.chat').command(cmd_opts.fargs)
  end, { desc = 'Open the gc chat window', force = true, nargs = '*' })
  -- check_ms = false stops a check an earlier setup() started (only then is
  -- the mailbox loaded already).
  if not M.config.check_ms and package.loaded['gc_mail.mailbox'] then
    package.loaded['gc_mail.mailbox'].stop_check()
  end
  -- watch = false stops a watch an earlier setup() started.
  if not M.config.watch and package.loaded['gc_mail.watch'] then
    package.loaded['gc_mail.watch'].stop()
  end
  -- After startup, never during it: resume the queue, preload the cities, start
  -- the watch unless watch = false and, only when check_ms is set, the new-mail
  -- check.
  local function start()
    queue.resume()
    M.refresh(function() end)
    if M.config.watch then
      require('gc_mail.watch').start()
    end
    if M.config.check_ms then
      require('gc_mail.mailbox').start_check(M.config.check_ms)
    end
  end
  if vim.v.vim_did_enter == 1 then
    vim.schedule(start)
  else
    vim.api.nvim_create_autocmd('VimEnter', { once = true, callback = vim.schedule_wrap(start) })
  end
end

--- The statusline text of the background watch: '' when no mail is unread or
--- the watch is off, else a space and the unread mail across cities. It runs
--- nothing and is safe before setup(); use it as
--- %{v:lua.require('gc_mail').status()}.
function M.status()
  local watch = package.loaded['gc_mail.watch']
  if not watch then
    return ''
  end
  local ok, text = pcall(watch.status)
  return ok and text or ''
end

-- :GcMail without setup() still queues to the default directory.
queue.configure({ dir = M.config.state_dir .. '/queue', retry_ms = M.config.retry_ms })

return M
