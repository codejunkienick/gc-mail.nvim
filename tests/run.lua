-- Headless tests for gc-mail.nvim. From the repository root:
--   nvim --headless --clean -n -l tools/gc-mail.nvim/tests/run.lua
-- A fake gc (tests/bin/gc) is first on PATH; the real gc never runs. Each test
-- gets a fresh module and its own queue directory under a scratch dir, which
-- is also XDG_STATE_HOME, so the real queue is never touched.
local here = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, 'S').source:sub(2)))
local root = vim.fs.dirname(here)
vim.opt.runtimepath:prepend(root)

local scratch = vim.fn.tempname()
vim.fn.mkdir(scratch, 'p')
vim.env.XDG_STATE_HOME = scratch .. '/xdg-state'
vim.env.PATH = here .. '/bin:' .. vim.env.PATH
vim.env.FAKE_GC_CITIES = scratch .. '/cities.jsonl'
vim.env.FAKE_GC_LOG = scratch .. '/argv'
vim.env.FAKE_GC_SENT = scratch .. '/sent'
vim.env.FAKE_GC_COUNT = scratch .. '/count'
vim.env.FAKE_GC_MAIL = scratch .. '/mail'
vim.env.FAKE_GC_MAIL_LOG = scratch .. '/mail-calls'

-- Short retry delays: no test waits on a real backoff.
local RETRY = { 40, 40, 40 }
local gc_mail, queue_dir, mailbox_dir
local run_id = 0

local function write(path, text)
  local file = assert(io.open(path, 'w'))
  file:write(text)
  file:close()
end

local function read_file(path)
  local file = io.open(path, 'rb')
  if not file then
    return nil
  end
  local data = file:read('*a')
  file:close()
  return data
end

local function cities_record(cities)
  return vim.json.encode({ schema_version = '1', ok = true, registry_path = '/r/cities.toml', cities = cities }) .. '\n'
end

local TWO = { { name = 'imd-city', path = '/srv/imd-city' }, { name = 'side-city', path = '/srv/side city' } }

local notes = {}
vim.notify = function(message, level)
  notes[#notes + 1] = { message = message, level = level }
end

local function floats()
  local result = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= '' then
      result[#result + 1] = win
    end
  end
  return result
end

local function wait(what, fn, ms)
  assert(vim.wait(ms or 5000, fn, 10), what)
end

-- A fresh module on its own queue directory; nothing else configured.
local function fresh()
  if gc_mail then
    gc_mail.queue.stop()
    wait('the previous test left a send running', gc_mail.queue.idle)
  end
  if package.loaded['gc_mail.panel'] then
    package.loaded['gc_mail.panel'].close_all()
  end
  if package.loaded['gc_mail.mailbox'] then
    package.loaded['gc_mail.mailbox'].stop_check()
  end
  package.loaded['gc_mail'] = nil
  package.loaded['gc_mail.queue'] = nil
  package.loaded['gc_mail.mailbox'] = nil
  package.loaded['gc_mail.panel'] = nil
  gc_mail = require('gc_mail')
  run_id = run_id + 1
  queue_dir = ('%s/state-%d/queue'):format(scratch, run_id)
  mailbox_dir = ('%s/state-%d/mailbox'):format(scratch, run_id)
  gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY })
  require('gc_mail.mailbox').configure({ dir = mailbox_dir })
end

local function reset(env)
  notes = {}
  for _, path in ipairs({ vim.env.FAKE_GC_LOG, vim.env.FAKE_GC_SENT, vim.env.FAKE_GC_COUNT, vim.env.FAKE_GC_MAIL_LOG }) do
    os.remove(path)
  end
  vim.fn.delete(vim.env.FAKE_GC_MAIL, 'rf')
  vim.fn.mkdir(vim.env.FAKE_GC_MAIL, 'p')
  write(vim.env.FAKE_GC_CITIES, cities_record(TWO))
  for _, key in ipairs({ 'FAKE_GC_EXIT', 'FAKE_GC_STDERR', 'FAKE_GC_CITIES_EXIT', 'FAKE_GC_CITIES_HANG', 'FAKE_GC_CITIES_DELAY',
    'FAKE_GC_DELAY', 'FAKE_GC_FAIL_TIMES' }) do
    vim.env[key] = nil
  end
  for k, v in pairs(env or {}) do
    vim.env[k] = v
  end
  vim.o.lines, vim.o.columns, vim.o.cmdheight = 24, 80, 1
  for _, win in ipairs(floats()) do
    vim.api.nvim_win_close(win, true)
  end
  vim.cmd('silent! tabonly!')
  vim.cmd('silent! only!')
  vim.cmd('enew!')
  fresh()
end

local function buffer(lines)
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function recorded_argv()
  local data = read_file(vim.env.FAKE_GC_LOG)
  if not data then
    return nil
  end
  local argv = {}
  for arg in data:gmatch('([^%z]*)%z') do
    argv[#argv + 1] = arg
  end
  return argv
end

local function sent()
  local data = read_file(vim.env.FAKE_GC_SENT) or ''
  return vim.split(vim.trim(data), '\n', { trimempty = true })
end

local function spool()
  return vim.fn.readdir(queue_dir, function(name)
    return name:sub(1, 1) ~= '.' and 1 or 0
  end)
end

local function drained()
  return gc_mail.queue.idle() and vim.fn.isdirectory(queue_dir) == 1 and #spool() == 0
end

-- Fills the city cache as the startup preload does.
local function preload()
  local done = false
  gc_mail.refresh(function()
    done = true
  end)
  wait('preload did not finish', function()
    return done
  end)
end

local function lines_of(win)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

local function eq(actual, expected, what)
  if not vim.deep_equal(actual, expected) then
    error(('%s\nexpected: %s\nactual:   %s'):format(what or 'mismatch', vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local tests = {}
local function test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

-- The name of a claim of message `id` by `pid` with `token` (default: some
-- other Neovim's token).
local function claim_name(id, pid, token)
  return ('%s/%s.json.sending-%d-%s'):format(queue_dir, id, pid, token or 'feedface')
end

-- A pid that is certainly gone: a child that has already exited.
local function dead_pid()
  local proc = vim.system({ 'true' })
  local pid = proc.pid
  proc:wait()
  return pid
end

-- The calls the fake gc answered from FAKE_GC_MAIL, in order: argv lists.
local function mail_calls()
  local data = read_file(vim.env.FAKE_GC_MAIL_LOG) or ''
  local calls = {}
  for line in data:gmatch('([^\n]*)\n') do
    local argv = {}
    for arg in line:gmatch('([^\31]*)\31') do
      argv[#argv + 1] = arg
    end
    calls[#calls + 1] = argv
  end
  return calls
end

test('nothing runs at load time and setup maps <Space>mm, <Space>mi, <Space>mp and the commands', function()
  eq(recorded_argv(), nil, 'gc ran at load')
  eq(mail_calls(), {}, 'a mail command ran at load')
  eq(gc_mail.cached_cities(), nil, 'cities loaded at load time')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY })
  eq(gc_mail.cached_cities(), nil, 'setup ran gc cities before startup finished')
  eq(vim.fn.maparg('<Space>mm', 'n') ~= '', true, 'default keymap missing')
  eq(vim.fn.exists(':GcMail'), 2, ':GcMail missing')
  eq(vim.fn.exists(':GcMailQueue'), 2, ':GcMailQueue missing')
  eq(vim.fn.exists(':GcMailbox'), 2, ':GcMailbox missing')
  eq(vim.fn.maparg('<Space>mi', 'n') ~= '', true, 'default mailbox keymap missing')
  eq(vim.fn.exists(':GcMailPanel'), 2, ':GcMailPanel missing')
  eq(vim.fn.maparg('<Space>mp', 'n') ~= '', true, 'default panel keymap missing')
  -- After startup the list is preloaded in the background.
  wait('no preload after setup', function()
    return gc_mail.cached_cities() ~= nil
  end)
  eq(gc_mail.cached_cities(), TWO, 'preloaded cities')
  eq(mail_calls(), {}, 'startup listed mail')
  eq(require('gc_mail.mailbox').checking(), false, 'a new-mail timer runs by default')
  vim.keymap.del('n', '<Space>mm')
  vim.keymap.del('n', '<Space>mi')
  vim.keymap.del('n', '<Space>mp')
  gc_mail.setup({ keymap = false, mailbox_keymap = false, panel_keymap = false, state_dir = vim.fs.dirname(queue_dir) })
  eq(vim.fn.maparg('<Space>mm', 'n'), '', 'keymap = false still mapped')
  eq(vim.fn.maparg('<Space>mi', 'n'), '', 'mailbox_keymap = false still mapped')
  eq(vim.fn.maparg('<Space>mp', 'n'), '', 'panel_keymap = false still mapped')
  eq(package.loaded['gc_mail.panel'], nil, 'setup loaded the panel')
  eq(vim.fn.exists(':GcMail'), 2, ':GcMail missing without a keymap')
  gc_mail.setup({ keymap = '<leader>gm', state_dir = vim.fs.dirname(queue_dir) })
  eq(vim.fn.maparg('<leader>gm', 'n') ~= '', true, 'custom keymap missing')
  eq(recorded_argv(), nil, 'mail was sent during setup')
  -- The defaults keep the queue under stdpath('state') (here the scratch XDG dir).
  package.loaded['gc_mail'] = nil
  package.loaded['gc_mail.queue'] = nil
  local defaults = require('gc_mail')
  eq(defaults.queue.dir(), vim.env.XDG_STATE_HOME .. '/nvim/gc-mail/queue', 'default queue dir')
  gc_mail = defaults
  gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY })
end)

test('the picker lists one line per city mayor, even for a single city', function()
  preload()
  buffer({ 'hello' })
  local win = gc_mail.open()
  eq(#floats(), 1, 'picker window')
  eq(lines_of(win), { ' imd-city  mayor ', ' side-city  mayor ' }, 'picker lines')
  eq(vim.api.nvim_win_get_height(win), 2, 'picker height = city count')
  wait('background refresh', function()
    return vim.fn.filereadable(vim.env.FAKE_GC_CITIES) == 1 and gc_mail.cached_cities() ~= nil
  end)
  eq(recorded_argv(), nil, 'opening the picker sent mail')
  vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'x', false)
  eq(#floats(), 0, '<Esc> closes')

  reset()
  write(vim.env.FAKE_GC_CITIES, cities_record({ TWO[1] }))
  buffer({ 'hello' })
  win = gc_mail.open()
  wait('the single city is listed', function()
    return vim.deep_equal(lines_of(win), { ' imd-city  mayor ' })
  end)
  eq(#floats(), 1, 'a single city still asks')
  vim.api.nvim_feedkeys('q', 'x', false)
  eq(#floats(), 0, 'q closes')
  eq(recorded_argv(), nil, 'cancel sent mail')
end)

test('the picker opens before a slow gc cities answers, then fills in', function()
  reset({ FAKE_GC_CITIES_DELAY = '0.5' })
  buffer({ 'hello' })
  local started = vim.uv.hrtime()
  local win = gc_mail.open()
  local opened_ms = (vim.uv.hrtime() - started) / 1e6
  eq(#floats(), 1, 'picker window before gc answers')
  eq(lines_of(win), { ' loading… ' }, 'loading line')
  assert(opened_ms < 250, ('open took %d ms'):format(opened_ms))
  -- <CR> on the loading line does nothing.
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  eq(#floats(), 1, '<CR> while loading')
  wait('cities filled in', function()
    return vim.deep_equal(lines_of(win), { ' imd-city  mayor ', ' side-city  mayor ' })
  end)
  eq(vim.api.nvim_win_get_height(win), 2, 'resized to the cities')
  -- The next open shows the cached list at once while gc runs again.
  vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'x', false)
  win = gc_mail.open()
  eq(lines_of(win), { ' imd-city  mayor ', ' side-city  mayor ' }, 'cached list at once')
  vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'x', false)
end)

test('choosing a city queues the message on disk before the buffer clears, then sends the exact argv', function()
  local buf = buffer({ '', '  Deploy plan for tomorrow  ', 'step one', '', 'step "two" $(not run)' })
  preload()
  vim.bo[buf].modified = true
  -- The queue file must exist at the moment the buffer is cleared.
  local spooled_at_clear
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if spooled_at_clear == nil then
        spooled_at_clear = #spool()
      end
    end,
  })
  vim.env.FAKE_GC_DELAY = '0.2'
  gc_mail.open()
  vim.api.nvim_feedkeys(vim.keycode('j<CR>'), 'x', false)
  eq(#floats(), 0, 'picker closes on <CR>')
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { '' }, 'buffer cleared at once')
  eq(spooled_at_clear, 1, 'queue file written before the clear')
  eq(vim.bo[buf].modified, false, 'modified reset')
  eq(notes[#notes].message, 'gc-mail: queued for side-city mayor: Deploy plan for tomorrow', 'queued notice')
  local record = vim.json.decode(read_file(queue_dir .. '/' .. spool()[1]))
  eq({ record.city, record.subject, type(record.created) }, { TWO[2], 'Deploy plan for tomorrow', 'number' }, 'queue record')
  wait('sent and removed', drained)
  eq(recorded_argv(), { '--city', '/srv/side city', 'mail', 'send', 'mayor', '-s', 'Deploy plan for tomorrow',
    '-m', '\n  Deploy plan for tomorrow  \nstep one\n\nstep "two" $(not run)', '--notify' }, 'argv')
  eq(notes[#notes].message, 'gc-mail: sent to side-city mayor', 'success notice')
  -- The clear is one undo step: u brings the text back.
  vim.cmd('silent undo')
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { '', '  Deploy plan for tomorrow  ', 'step one', '', 'step "two" $(not run)' },
    'undo restores the text')
end)

test('the subject is the first non-empty line trimmed to 72 characters', function()
  local long = string.rep('é', 80)
  local buf = buffer({ '   ', '\t' .. long .. '  ', 'body' })
  assert(gc_mail.send(buf, TWO[1]), 'not queued')
  wait('sent', drained)
  eq(recorded_argv()[7], string.rep('é', 72), 'subject')
end)

test('a failed send keeps its file, shows gc stderr once, retries, and is marked failed after the last retry', function()
  reset({ FAKE_GC_FAIL_TIMES = '2' })
  local buf = buffer({ 'flaky store', 'please' })
  assert(gc_mail.send(buf, TWO[1]), 'not queued')
  wait('retried until sent', drained)
  eq(sent(), { '/srv/imd-city|flaky store', '/srv/imd-city|flaky store', '/srv/imd-city|flaky store' }, 'three tries')
  local errors = vim.tbl_filter(function(note)
    return note.level == vim.log.levels.ERROR
  end, notes)
  eq(#errors, 1, 'the error is shown once')
  eq(errors[1].message, 'gc-mail: send to imd-city mayor failed (exit 1):\ngc mail send: store unavailable (try 1); retrying in the background',
    'failure notice')
  eq(notes[#notes].message, 'gc-mail: sent to imd-city mayor', 'sent in the end')

  reset({ FAKE_GC_EXIT = '3', FAKE_GC_STDERR = 'gc mail send: mayor not found\nsecond line\nthird\nfourth' })
  buf = buffer({ 'never lands' })
  local id = gc_mail.send(buf, TWO[1])
  wait('gave up', function()
    local entry = gc_mail.queue.list()[1]
    return gc_mail.queue.idle() and entry and entry.record and entry.record.failed
  end)
  eq(#sent(), 4, 'first try and three retries')
  local entry = gc_mail.queue.list()[1]
  eq({ entry.id, entry.record.attempts, entry.record.last_error },
    { id, 4, 'exit 3: gc mail send: mayor not found\nsecond line\nthird' }, 'failed record')
  eq(notes[#notes].message, 'gc-mail: gave up sending to imd-city mayor after 4 tries; :GcMailQueue to retry', 'give-up notice')
  -- A failed message is never resent on its own.
  gc_mail.queue.resume()
  vim.wait(150)
  eq(#sent(), 4, 'a failed message was resent without a request')
end)

test('two messages are sent one at a time, in order', function()
  reset({ FAKE_GC_DELAY = '0.2' })
  local buf = buffer({ 'first' })
  gc_mail.send(buf, TWO[1])
  buffer({ 'second' })
  gc_mail.send(buf, TWO[1])
  buffer({ 'to another city' })
  gc_mail.send(buf, TWO[2])
  wait('the first send started', function()
    return #sent() > 0
  end)
  vim.wait(100)
  eq(gc_mail.queue.idle(), false, 'the first send is running')
  eq(#sent(), 1, 'only one gc at a time')
  wait('all sent', drained)
  eq(sent(), { '/srv/imd-city|first', '/srv/imd-city|second', '/srv/side city|to another city' }, 'order')
end)

test('an empty buffer, a full queue or a failed queue write leaves the buffer as it was', function()
  write(vim.env.FAKE_GC_CITIES, 'not reached')
  for _, lines in ipairs({ { '' }, { '   ', '\t', '' } }) do
    notes = {}
    local buf = buffer(lines)
    eq(gc_mail.open(), nil, 'picker opened')
    eq(#floats(), 0, 'picker window')
    eq(notes[1].message, 'gc-mail: buffer is empty, nothing to send', 'refusal')
    eq(gc_mail.send(buf, TWO[1]), nil, 'send refused')
  end
  local huge = buffer({ string.rep('x', 120 * 1024 + 1) })
  eq(gc_mail.send(huge, TWO[1]), nil, 'oversize queued')
  eq(vim.fn.isdirectory(queue_dir), 0, 'a refused message made a queue')

  -- 100 messages queued (the worker stopped): the next is refused.
  gc_mail.queue.stop()
  for i = 1, 100 do
    assert(gc_mail.queue.add(TWO[1], { subject = 's' .. i, body = 'b' }))
  end
  notes = {}
  local buf = buffer({ 'one too many' })
  eq(gc_mail.send(buf, TWO[1]), nil, 'queued past the bound')
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'one too many' }, 'buffer kept')
  eq(notes[#notes].message, 'gc-mail: the queue already holds 100 messages; send or delete some with :GcMailQueue', 'full notice')

  -- The queue directory cannot be created: nothing is cleared.
  fresh()
  write(scratch .. '/not-a-dir', 'x')
  gc_mail.queue.configure({ dir = scratch .. '/not-a-dir/queue', retry_ms = RETRY })
  notes = {}
  buf = buffer({ 'keep me' })
  vim.bo[buf].modified = true
  eq(gc_mail.send(buf, TWO[1]), nil, 'queued into a file')
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'keep me' }, 'buffer kept')
  eq(vim.bo[buf].modified, true, 'modified kept')
  eq(notes[#notes].level, vim.log.levels.ERROR, 'error shown')
  assert(notes[#notes].message:find('^gc%-mail: cannot write the queue file'), notes[#notes].message)
  eq(recorded_argv(), nil, 'gc ran')
end)

test('a buffer that is not modifiable is refused before anything is queued; a failed clear leaves the message queued', function()
  write(vim.env.FAKE_GC_CITIES, 'not reached')
  local buf = buffer({ 'locked text' })
  vim.bo[buf].modifiable = false
  eq(gc_mail.open(), nil, 'picker opened')
  eq(#floats(), 0, 'picker window')
  eq(notes[1].message, 'gc-mail: buffer is not modifiable, so it cannot be cleared after sending', 'refusal')
  eq(notes[1].level, vim.log.levels.WARN, 'refusal level')
  eq(gc_mail.send(buf, TWO[1]), nil, 'send refused')
  eq(vim.fn.isdirectory(queue_dir), 0, 'a refused message made a queue')
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'locked text' }, 'buffer changed')
  eq(recorded_argv(), nil, 'gc ran')

  -- The clear fails anyway (here: an error from Neovim): the message stays
  -- queued and is sent once, the buffer is left as it is.
  vim.bo[buf].modifiable = true
  vim.bo[buf].modified = true
  local set_lines = vim.api.nvim_buf_set_lines
  vim.api.nvim_buf_set_lines = function(b, ...)
    if b == buf then
      error('E21: Cannot make changes, simulated')
    end
    return set_lines(b, ...)
  end
  notes = {}
  local ok, id = pcall(gc_mail.send, buf, TWO[1])
  vim.api.nvim_buf_set_lines = set_lines
  assert(ok, id)
  assert(id, 'nothing queued')
  eq(#notes, 1, 'notices')
  eq(notes[1].level, vim.log.levels.WARN, 'notice level')
  assert(notes[1].message:find('^gc%-mail: queued for imd%-city mayor: locked text; the buffer was left as it is %(cannot clear it: .*E21'),
    notes[1].message)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'locked text' }, 'buffer changed')
  eq(vim.bo[buf].modified, true, 'modified flag changed')
  wait('sent', drained)
  eq(sent(), { '/srv/imd-city|locked text' }, 'sent once')
end)

test('the picker fits a 10-line editor, border included, and scrolls past that', function()
  local many = {}
  for i = 1, 12 do
    many[i] = { name = 'city-' .. i, path = '/srv/c' .. i }
  end
  write(vim.env.FAKE_GC_CITIES, cities_record(many))
  preload()
  vim.o.lines = 10
  buffer({ 'hello' })
  local win = gc_mail.open()
  local config = vim.api.nvim_win_get_config(win)
  local height = vim.api.nvim_win_get_height(win)
  local row = vim.api.nvim_win_get_position(win)[1]
  assert(row + height + 2 <= vim.o.lines - vim.o.cmdheight,
    ('picker rows %d..%d overrun a %d-line editor'):format(row, row + height + 1, vim.o.lines))
  -- 10 lines - command line - 2 border rows. Neovim also clamps a taller
  -- float, so the next test pins the size the plugin itself computes.
  eq(height, 7, 'picker rows in a 10-line editor')
  eq(row, 0, 'picker top row')
  eq(config.border ~= nil, true, 'bordered')
  vim.api.nvim_feedkeys(vim.keycode('G<CR>'), 'x', false)
  wait('no send', function()
    return recorded_argv() ~= nil
  end)
  eq(recorded_argv()[2], '/srv/c12', 'last city reachable by scrolling')
end)

test('layout keeps the window above the command line for any small editor', function()
  for lines = 4, 15 do
    for _, count in ipairs({ 1, 3, 12 }) do
      local l = gc_mail.layout(count, 20, lines, 80, 1)
      assert(l.height >= 1 and l.row >= 0 and l.row + l.height + 2 <= math.max(lines - 1, 3),
        ('layout overruns: lines=%d count=%d %s'):format(lines, count, vim.inspect(l)))
    end
  end
end)

test('bad gc cities output or a failing gc closes the loading picker; a failed refresh keeps the last good list', function()
  for _, case in ipairs({
    { text = 'garbage\n', want = 'gc-mail: gc cities --json printed something unexpected' },
    { text = cities_record(TWO) .. 'warning: registry is stale\n',
      want = 'gc-mail: gc cities --json printed something unexpected' },
    { text = cities_record(TWO) .. cities_record(TWO), want = 'gc-mail: gc cities --json printed something unexpected' },
    -- One JSON value, but not one record line.
    { text = cities_record(TWO):gsub('","', '",\n"'), want = 'gc-mail: gc cities --json printed something unexpected' },
    { text = vim.json.encode({ ok = true, cities = { { name = 'x' } } }) .. '\n',
      want = 'gc-mail: gc cities --json listed a city without a name or path' },
    { text = cities_record({}), want = 'gc-mail: no cities are registered with gc' },
    { text = '\n' .. cities_record({}) .. '\n  \n', want = 'gc-mail: no cities are registered with gc' },
  }) do
    reset()
    write(vim.env.FAKE_GC_CITIES, case.text)
    buffer({ 'hello' })
    gc_mail.open()
    wait('the picker stayed open: ' .. case.want, function()
      return #floats() == 0
    end)
    eq(notes[#notes].message, case.want, 'notice')
  end
  reset({ FAKE_GC_CITIES_EXIT = '1' })
  buffer({ 'hello' })
  gc_mail.open()
  wait('picker left open on gc failure', function()
    return #floats() == 0
  end)
  eq(recorded_argv(), nil, 'mail sent')

  -- With a good list cached, a failing refresh keeps it and says so once.
  reset()
  preload()
  buffer({ 'hello' })
  vim.env.FAKE_GC_CITIES_EXIT = '1'
  for _ = 1, 2 do
    local win = gc_mail.open()
    eq(lines_of(win), { ' imd-city  mayor ', ' side-city  mayor ' }, 'last good list')
    -- The refresh (a failing fake gc) ends well within this.
    vim.wait(300)
    eq(#floats(), 1, 'picker kept')
    eq(gc_mail.cached_cities(), TWO, 'cache kept')
    vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'x', false)
  end
  local warnings = vim.tbl_filter(function(note)
    return note.message:find('showing the last list', 1, true) ~= nil
  end, notes)
  eq(#warnings, 1, 'said once')
  eq(warnings[1].message, 'gc-mail: gc cities failed, showing the last list:\ngc cities failed (exit 1)', 'stale notice')
end)

test('a city name or path with a control character makes gc cities malformed and raises nothing', function()
  local bad = {
    cities_record({ { name = 'imd\ncity', path = '/srv/imd-city' } }),
    cities_record({ { name = 'imd-city', path = '/srv/imd\tcity' } }),
    cities_record({ { name = 'imd\127city', path = '/srv/imd-city' } }),
  }
  local want = 'gc-mail: gc cities --json listed a city name or path with a control character'
  for _, text in ipairs(bad) do
    reset()
    vim.v.errmsg = ''
    write(vim.env.FAKE_GC_CITIES, text)
    buffer({ 'hello' })
    gc_mail.open()
    wait('the loading picker stayed open', function()
      return #floats() == 0
    end)
    eq(notes[#notes].message, want, 'notice')
    eq(vim.v.errmsg, '', 'an error reached Neovim')
  end
  -- With a good list cached: it stays, and the failure is said once.
  reset()
  preload()
  vim.v.errmsg = ''
  write(vim.env.FAKE_GC_CITIES, bad[1])
  buffer({ 'hello' })
  for _ = 1, 2 do
    local win = gc_mail.open()
    vim.wait(300)
    eq(lines_of(win), { ' imd-city  mayor ', ' side-city  mayor ' }, 'last good list')
    eq(gc_mail.cached_cities(), TWO, 'cache kept')
    vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'x', false)
  end
  local warnings = vim.tbl_filter(function(note)
    return note.message:find('showing the last list', 1, true) ~= nil
  end, notes)
  eq(#warnings, 1, 'said once')
  eq(warnings[1].message, 'gc-mail: gc cities failed, showing the last list:\n' .. want:sub(10), 'stale notice')
  eq(vim.v.errmsg, '', 'an error reached Neovim')
end)

test('a gc cities that does not answer in time is reported, not raised', function()
  reset({ FAKE_GC_CITIES_HANG = '30' })
  local started = vim.uv.hrtime()
  local cities, err = gc_mail.cities(200)
  eq(cities, nil, 'cities from a hung gc')
  eq(err, 'gc cities did not answer within 0.2 s', 'timeout reason')
  assert((vim.uv.hrtime() - started) / 1e6 < 5000, 'waited for the hung gc to finish')

  -- A child that is not reaped even after the kill: wait() returns nil.
  local system, killed = vim.system, nil
  vim.system = function()
    return {
      wait = function()
        return nil
      end,
      kill = function(_, signal)
        killed = signal
      end,
    }
  end
  local ok, a, b = pcall(gc_mail.cities, 200)
  vim.system = system
  eq({ ok, a, b }, { true, nil, 'gc cities did not answer within 0.2 s' }, 'nil wait result')
  eq(killed, 9, 'unreaped child killed')

  -- The background refresh has the same bound, and keeps the cache.
  local done, result
  started = vim.uv.hrtime()
  gc_mail.refresh(function(c, e)
    done, result = true, { c, e }
  end, 200)
  wait('refresh never ended', function()
    return done
  end)
  eq(result, { nil, 'gc cities did not answer within 0.2 s' }, 'refresh timeout')
  assert((vim.uv.hrtime() - started) / 1e6 < 5000, 'waited for the hung gc to finish')
  eq(gc_mail.cached_cities(), nil, 'cache filled by a timeout')
end)

test('a fresh setup resends what an earlier Neovim left: pending files and claims of a gone process', function()
  -- An earlier Neovim queued two messages and died while sending the first.
  gc_mail.queue.stop()
  local first = assert(gc_mail.queue.add(TWO[1], { subject = 'left mid-send', body = 'a' }))
  assert(gc_mail.queue.add(TWO[1], { subject = 'left pending', body = 'b' }))
  local failed = assert(gc_mail.queue.add(TWO[2], { subject = 'failed earlier', body = 'c' }))
  local record = vim.json.decode(read_file(queue_dir .. '/' .. failed .. '.json'))
  record.failed = true
  write(queue_dir .. '/' .. failed .. '.json', vim.json.encode(record))
  assert(vim.uv.fs_rename(queue_dir .. '/' .. first .. '.json', claim_name(first, dead_pid())))
  -- A claim of a live process (another Neovim sending it) is left alone.
  local live = vim.system({ 'sleep', '5' })
  local busy = assert(gc_mail.queue.add(TWO[2], { subject = 'another nvim sends it', body = 'd' }))
  assert(vim.uv.fs_rename(queue_dir .. '/' .. busy .. '.json', claim_name(busy, live.pid)))

  local dir = queue_dir
  fresh()
  queue_dir = dir
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY })
  wait('resumed', function()
    return #sent() == 2 and gc_mail.queue.idle()
  end)
  eq(sent(), { '/srv/imd-city|left mid-send', '/srv/imd-city|left pending' }, 'resent in order')
  local left = vim.tbl_map(function(entry)
    return { entry.record.subject, entry.claimed ~= nil, entry.record.failed }
  end, gc_mail.queue.list())
  eq(left, { { 'failed earlier', false, true }, { 'another nvim sends it', true, false } }, 'failed and live-claimed stay')
  live:kill(9)
  live:wait()
end)

test(':GcMailQueue lists pending and failed messages, and retries, opens and deletes them', function()
  gc_mail.queue.stop()
  local a = assert(gc_mail.queue.add(TWO[1], { subject = 'still pending', body = 'pending body\nline 2' }))
  local b = assert(gc_mail.queue.add(TWO[2], { subject = 'gave up', body = 'failed body' }))
  local record = vim.json.decode(read_file(queue_dir .. '/' .. b .. '.json'))
  record.failed, record.attempts, record.last_error, record.created = true, 4, 'exit 3: mayor not found', os.time() - 125
  write(queue_dir .. '/' .. b .. '.json', vim.json.encode(record))
  vim.cmd('GcMailQueue')
  local win = floats()[1]
  local lines = lines_of(win)
  eq(#lines, 2, 'one line per message')
  assert(lines[1]:find('^ imd%-city  still pending  %d+s  pending $'), lines[1])
  eq(lines[2], ' side-city  gave up  2m  failed  exit 3: mayor not found ', 'failed line')
  eq(gc_mail.queue_lines({}, os.time()), { ' the queue is empty ' }, 'empty queue')

  -- o opens the text in a new buffer and leaves the queue as it is.
  vim.api.nvim_feedkeys('o', 'x', false)
  eq(#floats(), 0, 'o closes the list')
  eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'pending body', 'line 2' }, 'opened text')
  eq(#spool(), 2, 'o changed the queue')

  -- d deletes the line under the cursor.
  vim.cmd('GcMailQueue')
  vim.api.nvim_feedkeys('d', 'x', false)
  eq(vim.uv.fs_stat(queue_dir .. '/' .. a .. '.json'), nil, 'deleted')
  eq(lines_of(floats()[1]), { ' side-city  gave up  2m  failed  exit 3: mayor not found ' }, 'list after delete')

  -- r sends a failed message again.
  gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY })
  vim.api.nvim_feedkeys('r', 'x', false)
  wait('retried', drained)
  eq(sent(), { '/srv/side city|gave up' }, 'retry sent it')
  vim.api.nvim_feedkeys('q', 'x', false)
  eq(#floats(), 0, 'q closes')
end)

-- Runs fn with vim.uv[name] failing (EACCES-like `err`) while `fails(...)`
-- says so; the real function is back afterwards, also when fn raises.
local function failing(name, err, fails, fn)
  local real = vim.uv[name]
  vim.uv[name] = function(...)
    if fails(...) then
      return nil, err
    end
    return real(...)
  end
  local ok, e = pcall(fn)
  vim.uv[name] = real
  if not ok then
    error(e, 0)
  end
end

local function errors_matching(pattern)
  return vim.tbl_filter(function(note)
    return note.level == vim.log.levels.ERROR and note.message:find(pattern, 1, true) ~= nil
  end, notes)
end

local function claims()
  return vim.tbl_filter(function(name)
    return name:find('%.sending%-%d+%-%x+$') ~= nil
  end, spool())
end

test('a claim is live only while its own Neovim holds it, or a living one took it within twice the send timeout', function()
  gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY, send_timeout_ms = 60000 })
  gc_mail.queue.stop()
  local function city(n)
    return { name = 'c' .. n, path = '/srv/c' .. n }
  end
  local ids = {}
  for n = 1, 4 do
    ids[n] = assert(gc_mail.queue.add(city(n), { subject = 'm' .. n, body = 'b' }))
  end
  local function claim(n, pid, token, age_s)
    local name = claim_name(ids[n], pid, token)
    assert(vim.uv.fs_rename(queue_dir .. '/' .. ids[n] .. '.json', name))
    local t = os.time() - age_s
    assert(vim.uv.fs_utime(name, t, t))
    return name
  end
  local live = vim.system({ 'sleep', '5' })
  -- (a) this process's pid, another token: an earlier Neovim with this pid.
  claim(1, vim.uv.os_getpid(), 'feedface', 0)
  -- (b) a living foreign pid whose claim is older than 2 x 60 s.
  claim(2, live.pid, 'feedface', 130)
  -- (c) a living foreign pid, fresh claim; and one just inside the bound.
  local fresh_claim = claim(3, live.pid, 'feedface', 0)
  local young_claim = claim(4, live.pid, 'feedface', 100)

  local dir = queue_dir
  fresh()
  queue_dir = dir
  gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY, send_timeout_ms = 60000 })
  gc_mail.queue.resume()
  wait('put back and sent', function()
    return #sent() == 2 and gc_mail.queue.idle()
  end)
  vim.wait(100)
  eq(sent(), { '/srv/c1|m1', '/srv/c2|m2' }, 'stale claims put back and sent, live ones left')
  eq(claims(), { vim.fs.basename(fresh_claim), vim.fs.basename(young_claim) }, 'live claims kept')

  -- (d) A claim's time is when it was taken, not when the message was
  -- written; and a send whose outcome waits on the disk keeps its claim
  -- young, so another Neovim never takes it back meanwhile.
  live:kill(9)
  live:wait()
  reset({ FAKE_GC_DELAY = '0.3' })
  gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY, settle_ms = { 30 }, send_timeout_ms = 60000 })
  local id = assert(gc_mail.queue.add(TWO[1], { subject = 'held', body = 'a' }))
  local written = os.time() - 1000
  assert(vim.uv.fs_utime(queue_dir .. '/' .. id .. '.json', written, written))
  local hold = true
  failing('fs_unlink', 'EACCES: permission denied', function(p)
    return hold and p:find('%.sending%-%d+%-%x+$') ~= nil
  end, function()
    gc_mail.queue.pump()
    wait('sending', function()
      return #sent() == 1 and #claims() == 1
    end)
    eq(gc_mail.queue.idle(), false, 'the send already ended')
    local name = queue_dir .. '/' .. claims()[1]
    assert(vim.uv.fs_stat(name).mtime.sec >= os.time() - 5, 'the claim has the time the message was written')
    wait('held', function()
      return gc_mail.queue.idle() and #claims() == 1
    end)
    local old = os.time() - 1000
    assert(vim.uv.fs_utime(name, old, old))
    wait('claim made young again', function()
      local stat = vim.uv.fs_stat(name)
      return stat and stat.mtime.sec >= os.time() - 5
    end)
    eq(claims(), { vim.fs.basename(name) }, 'claim renamed')
    eq(vim.fs.basename(name):match('%-(%x+)$'), gc_mail.queue.token, 'claim token')
    hold = false
  end)
  wait('removed', drained)
  eq(sent(), { '/srv/imd-city|held' }, 'sent once')
end)


test('a failed send whose new state cannot be written stays claimed and holds the queue until it is', function()
  reset({ FAKE_GC_FAIL_TIMES = '1' })
  gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY, settle_ms = { 30 } })
  gc_mail.queue.stop()
  local a = assert(gc_mail.queue.add(TWO[1], { subject = 'first', body = 'a' }))
  assert(gc_mail.queue.add(TWO[2], { subject = 'other city', body = 'b' }))
  gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY, settle_ms = { 30 } })
  -- The failure record cannot be staged over the claim 3 times, then the
  -- claim cannot be renamed back 3 times.
  local write_fails, back_fails = 3, 3
  failing('fs_rename', 'ENOSPC: no space left on device', function(from, to)
    if from:find('/%.[^/]+%.tmp$') and to:find('%.sending%-%d+%-%x+$') and write_fails > 0 then
      write_fails = write_fails - 1
      return true
    end
    if from:find('%.sending%-%d+%-%x+$') and to:find('%.json$') and write_fails == 0 and back_fails > 0 then
      back_fails = back_fails - 1
      return true
    end
  end, function()
    gc_mail.queue.pump()
    wait('the first send failed', function()
      return #sent() == 1 and gc_mail.queue.idle()
    end)
    -- Held: still claimed, nothing put back, nothing else sent, no resend.
    wait('state written', function()
      return write_fails == 0
    end)
    eq(claims(), { ('%s.json.sending-%d-%s'):format(a, vim.uv.os_getpid(), gc_mail.queue.token) },
      'claim kept while the state is not written')
    eq(sent(), { '/srv/imd-city|first' }, 'sent anything while held')
    wait('claim put back', function()
      return back_fails == 0 and #claims() == 0
    end)
  end)
  wait('all sent', drained)
  -- Its retry delay ran out during the hold, and it is the oldest.
  eq(sent(), { '/srv/imd-city|first', '/srv/imd-city|first', '/srv/side city|other city' }, 'resent once, then the next')
  eq(#errors_matching('cannot record the failed send to imd-city mayor (ENOSPC'), 1, 'the hold is shown once')
end)

test('a delivered message whose file cannot be removed is marked sent, holds the queue, and is never resent', function()
  gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY, settle_ms = { 30 } })
  gc_mail.queue.stop()
  assert(gc_mail.queue.add(TWO[1], { subject = 'delivered', body = 'a' }))
  assert(gc_mail.queue.add(TWO[2], { subject = 'next', body = 'b' }))
  gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY, settle_ms = { 30 } })
  local unlink_fails = 3
  failing('fs_unlink', 'EACCES: permission denied', function(p)
    if p:find('%.sending%-%d+%-%x+$') and unlink_fails > 0 then
      unlink_fails = unlink_fails - 1
      return true
    end
  end, function()
    gc_mail.queue.pump()
    wait('sent', function()
      return #sent() == 1 and gc_mail.queue.idle()
    end)
    local claim = claims()[1]
    eq(vim.json.decode(read_file(queue_dir .. '/' .. claim)).delivered, true, 'claim marked delivered')
    eq(sent(), { '/srv/imd-city|delivered' }, 'sent anything while held')
    wait('removed', function()
      return unlink_fails == 0 and #claims() == 0
    end)
  end)
  wait('all sent', drained)
  eq(sent(), { '/srv/imd-city|delivered', '/srv/side city|next' }, 'each once')
  eq(#errors_matching('sent to imd-city mayor, but cannot remove its queue file (EACCES: permission denied); it is marked sent'),
    1, 'shown once')

  -- Neovim quits while the file still cannot be removed: the next start
  -- drops the delivered claim instead of sending it again.
  reset()
  gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY, settle_ms = { 30 } })
  local id = assert(gc_mail.queue.add(TWO[1], { subject = 'once only', body = 'c' }))
  failing('fs_unlink', 'EACCES: permission denied', function(p)
    return p:find('%.sending%-%d+%-%x+$') ~= nil
  end, function()
    gc_mail.queue.pump()
    wait('marked', function()
      local claim = claims()[1]
      return #sent() == 1 and claim and vim.json.decode(read_file(queue_dir .. '/' .. claim)).delivered
    end)
    gc_mail.queue.stop()
    eq(gc_mail.queue_lines(gc_mail.queue.list(), os.time())[1]:find('sent, file not removed', 1, true) ~= nil, true,
      'shown as sent')
    eq({ gc_mail.queue.retry(id) }, { nil, 'it is being sent or gone' }, 'retry of a held claim')
  end)
  assert(vim.uv.fs_rename(queue_dir .. '/' .. claims()[1], claim_name(id, dead_pid())))
  local dir = queue_dir
  fresh()
  queue_dir = dir
  gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY })
  gc_mail.queue.resume()
  wait('dropped', drained)
  vim.wait(100)
  eq(sent(), { '/srv/imd-city|once only' }, 'a delivered message was sent again')
end)

-- vim.uv.fs_utime refused on claims while `hold()`, with the real one to age a claim.
local function utime_refused(hold, fn)
  local real = vim.uv.fs_utime
  failing('fs_utime', 'EPERM: operation not permitted', function(p)
    return hold() and p:find('%.sending%-%d+%-%x+$') ~= nil
  end, function()
    fn(real)
  end)
end

local function made_young(name, real_utime)
  local old = os.time() - 1000
  assert(real_utime(name, old, old))
  wait('claim made young again', function()
    local stat = vim.uv.fs_stat(name)
    return stat and stat.mtime.sec >= os.time() - 5
  end)
end

test('a held claim whose time cannot be set is rewritten whole to stay young, marked sent when gc delivered it', function()
  gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY, settle_ms = { 30 } })
  local hold = true
  local held = function()
    return hold
  end
  assert(gc_mail.queue.add(TWO[1], { subject = 'delivered', body = 'a' }))
  utime_refused(held, function(real_utime)
    failing('fs_unlink', 'EACCES: permission denied', function(p)
      return hold and p:find('%.sending%-%d+%-%x+$') ~= nil
    end, function()
      gc_mail.queue.pump()
      wait('held', function()
        return #sent() == 1 and gc_mail.queue.idle() and #claims() == 1
      end)
      local name = queue_dir .. '/' .. claims()[1]
      eq(vim.json.decode(read_file(name)).delivered, true, 'claim marked delivered')
      made_young(name, real_utime)
      eq(sent(), { '/srv/imd-city|delivered' }, 'sent anything while held')
      hold = false
    end)
  end)
  wait('removed', drained)
  eq(sent(), { '/srv/imd-city|delivered' }, 'sent once')
  eq(#errors_matching('cannot keep the claim'), 0, 'a claim kept young by a rewrite needs no warning')

  -- A failed send: the rewrite is its new state, and only the rename back waits.
  reset({ FAKE_GC_FAIL_TIMES = '1' })
  gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY, settle_ms = { 30 } })
  hold = true
  assert(gc_mail.queue.add(TWO[1], { subject = 'failed once', body = 'b' }))
  utime_refused(held, function(real_utime)
    failing('fs_rename', 'ENOSPC: no space left on device', function(from, to)
      return hold and from:find('%.sending%-%d+%-%x+$') ~= nil and to:find('%.json$') ~= nil
    end, function()
      gc_mail.queue.pump()
      wait('held', function()
        return #sent() == 1 and gc_mail.queue.idle() and #claims() == 1
      end)
      local name = queue_dir .. '/' .. claims()[1]
      wait('the failure is written', function()
        return vim.json.decode(read_file(name)).attempts == 1
      end)
      made_young(name, real_utime)
      eq(sent(), { '/srv/imd-city|failed once' }, 'resent while held')
      hold = false
    end)
  end)
  wait('retried and removed', drained)
  eq(sent(), { '/srv/imd-city|failed once', '/srv/imd-city|failed once' }, 'one retry')
  eq(#errors_matching('cannot keep the claim'), 0, 'no warning')
end)

test('a held claim that can neither have its time set nor be rewritten is said once and still never resent here', function()
  gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY, settle_ms = { 30 } })
  local hold = true
  local claim = function(p)
    return hold and p ~= nil and p:find('%.sending%-%d+%-%x+$') ~= nil
  end
  assert(gc_mail.queue.add(TWO[1], { subject = 'stuck', body = 'a' }))
  utime_refused(function()
    return hold
  end, function()
    failing('fs_unlink', 'EACCES: permission denied', claim, function()
      -- No staged file can replace the claim either.
      failing('fs_rename', 'ENOSPC: no space left on device', function(from, to)
        return from:find('/%.[^/]+%.tmp$') ~= nil and claim(to)
      end, function()
        gc_mail.queue.pump()
        wait('said', function()
          return #errors_matching('cannot keep the claim') > 0
        end)
        vim.wait(200)
        eq(#claims(), 1, 'still claimed')
        eq(sent(), { '/srv/imd-city|stuck' }, 'sent anything while held')
        hold = false
      end)
    end)
  end)
  wait('removed', drained)
  eq(sent(), { '/srv/imd-city|stuck' }, 'sent once')
  eq(#errors_matching('cannot keep the claim on the message to imd-city mayor young (EPERM: operation not permitted; ENOSPC: no space left on device); another Neovim may send it again after 240 s'),
    1, 'said once')
end)

test('a queue file with any malformed field is listed as unreadable and never sent or crashes the worker', function()
  gc_mail.queue.stop()
  local good = { version = 1, city = TWO[1], subject = 's', body = 'b', created = 1, attempts = 0, next_at = 0, failed = false }
  local cases = {
    { 'created', 'bad', 'bad created' },
    { 'attempts', -1, 'bad attempts' },
    { 'attempts', 1.5, 'bad attempts' },
    { 'next_at', 'soon', 'bad next_at' },
    { 'failed', 'no', 'bad failed' },
    { 'last_error', 5, 'bad last_error' },
    { 'last_error', vim.NIL, 'bad last_error' },
    { 'delivered', 1, 'bad delivered' },
    { 'subject', 'two\nlines', 'bad subject' },
    { 'body', false, 'bad body' },
    { 'city', { name = 'x' }, 'bad city' },
    { 'city', { name = 'x', path = '/p', extra = 1 }, 'bad city' },
    { 'version', 2, 'not a version 1 gc-mail message' },
    { 'surprise', true, 'unknown field surprise' },
  }
  vim.fn.mkdir(queue_dir, 'p')
  for i, case in ipairs(cases) do
    local record = vim.deepcopy(good)
    record[case[1]] = case[2]
    write(('%s/%016d-00001-%08x.json'):format(queue_dir, i, i), vim.json.encode(record))
  end
  write(queue_dir .. '/0000000000000099-00001-00000099.json', '{"version": 1, ')
  local valid = assert(gc_mail.queue.add(TWO[2], { subject = 'fine', body = 'ok' }))
  local entries = gc_mail.queue.list()
  for i, case in ipairs(cases) do
    eq({ entries[i].record, entries[i].error }, { nil, 'not a gc-mail message: ' .. case[3] }, 'case ' .. case[1])
  end
  eq(entries[#cases + 1].error, 'not a gc-mail message: not JSON', 'truncated file')
  eq(entries[#cases + 2].id, valid, 'the good one is last')
  -- The list renders, and the worker sends only the good message.
  vim.cmd('GcMailQueue')
  local lines = lines_of(floats()[1])
  eq(#lines, #cases + 2, 'one line each')
  eq(lines[1]:find('^ %? %d+%-00001%-00000001%.json  unreadable: not a gc%-mail message: bad created $') ~= nil, true, lines[1])
  vim.api.nvim_feedkeys('q', 'x', false)
  gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY })
  gc_mail.queue.pump()
  wait('the good one sent', function()
    return #sent() == 1 and gc_mail.queue.idle()
  end)
  eq(sent(), { '/srv/side city|fine' }, 'sent')
  eq(#spool(), #cases + 1, 'malformed files kept for a look')
end)

test('adding takes the queue lock: a held lock refuses, and two Neovims never pass the bound together', function()
  local ffi = require('ffi')
  pcall(ffi.cdef, 'int flock(int fd, int operation);')
  gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY, lock_wait_ms = 50 })
  gc_mail.queue.stop()
  vim.fn.mkdir(queue_dir, 'p')
  local fd = assert(vim.uv.fs_open(queue_dir .. '/.lock', 'a', 384))
  eq(ffi.C.flock(fd, 2), 0, 'lock taken by the test')
  local buf = buffer({ 'while locked' })
  local started = vim.uv.hrtime()
  eq(gc_mail.send(buf, TWO[1]), nil, 'queued under a held lock')
  assert((vim.uv.hrtime() - started) / 1e6 < 1000, 'waited too long for the lock')
  eq(notes[#notes].message, 'gc-mail: the queue is busy (another Neovim is using it); try again', 'busy notice')
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'while locked' }, 'buffer kept')
  eq(vim.fn.readdir(queue_dir), { '.lock' }, 'nothing left behind')
  vim.uv.fs_close(fd)
  assert(gc_mail.queue.add(TWO[1], { subject = 'after', body = 'b' }), 'not queued once the lock is free')

  -- Two Neovims add 60 messages each to an empty queue at the same moment.
  vim.fn.delete(queue_dir, 'rf')
  local go = scratch .. '/go-' .. run_id
  local function adder()
    return vim.system({ vim.v.progpath, '--headless', '--clean', '-n', '-l', here .. '/add_many.lua', queue_dir, '60', go },
      { text = true })
  end
  local one, two = adder(), adder()
  vim.wait(200)
  write(go, '')
  local r1, r2 = one:wait(20000), two:wait(20000)
  eq({ r1.code, r2.code }, { 0, 0 }, 'adders: ' .. (r1.stderr or '') .. (r2.stderr or ''))
  eq(tonumber(r1.stdout) + tonumber(r2.stdout), 100, 'messages taken')
  eq(#spool(), 100, 'queue files')
end)

-- True when another Neovim could take the queue lock right now (it is free).
local function lock_free(dir, open)
  local ffi = require('ffi')
  pcall(ffi.cdef, 'int flock(int fd, int operation);')
  local fd = assert((open or vim.uv.fs_open)(dir .. '/.lock', 'a', 384))
  local free = ffi.C.flock(fd, 2 + 4) == 0
  vim.uv.fs_close(fd)
  return free
end

test('rules 1 and 2: queue files change only whole, by rename or unlink, and only under the queue lock', function()
  reset({ FAKE_GC_FAIL_TIMES = '1' })
  gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY, settle_ms = { 30 } })
  local real = { fs_rename = vim.uv.fs_rename, fs_unlink = vim.uv.fs_unlink, fs_open = vim.uv.fs_open }
  local changes, unlocked, in_place = {}, {}, {}
  -- A change to a message file (not a private temp file) in the queue.
  local function check(op, target)
    local name = target:match('^' .. vim.pesc(queue_dir) .. '/([^/]+)$')
    if name and name:sub(1, 1) ~= '.' then
      local kind = op .. ':' .. (name:match('%.sending%-%d+%-%x+$') and 'claim' or 'file')
      changes[kind] = true
      if lock_free(queue_dir, real.fs_open) then
        unlocked[#unlocked + 1] = op .. ' ' .. name
      end
    end
  end
  vim.uv.fs_rename = function(from, to)
    check('rename', to)
    return real.fs_rename(from, to)
  end
  vim.uv.fs_unlink = function(p)
    check('unlink', p)
    return real.fs_unlink(p)
  end
  -- Rule 1: a message file is never opened to be written in place.
  vim.uv.fs_open = function(p, mode, ...)
    local name = p:match('^' .. vim.pesc(queue_dir) .. '/([^/]+)$')
    if name and name:sub(1, 1) ~= '.' and mode ~= 'r' then
      in_place[#in_place + 1] = mode .. ' ' .. name
    end
    return real.fs_open(p, mode, ...)
  end
  local ok, err = pcall(function()
    -- add, claim, failure recorded and put back, resent, deleted.
    assert(gc_mail.queue.add(TWO[1], { subject = 'fails once', body = 'a' }))
    gc_mail.queue.pump()
    wait('sent after one failure', drained)
    -- retry and delete of an unclaimed file.
    gc_mail.queue.stop()
    local a = assert(gc_mail.queue.add(TWO[1], { subject = 'retried', body = 'b' }))
    local b = assert(gc_mail.queue.add(TWO[2], { subject = 'deleted', body = 'c' }))
    assert(gc_mail.queue.delete(b))
    -- What a gone Neovim left: a claim to put back, and one marked delivered.
    assert(real.fs_rename(queue_dir .. '/' .. a .. '.json', claim_name(a, dead_pid())))
    local c = assert(gc_mail.queue.add(TWO[2], { subject = 'delivered', body = 'd' }))
    local record = vim.json.decode(read_file(queue_dir .. '/' .. c .. '.json'))
    record.delivered = true
    write(queue_dir .. '/' .. c .. '.json', vim.json.encode(record))
    gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY, settle_ms = { 30 } })
    gc_mail.queue.resume()
    wait('put back and sent, delivered dropped', drained)
    assert(gc_mail.queue.add(TWO[1], { subject = 'again', body = 'e' }))
    gc_mail.queue.stop()
    local d = gc_mail.queue.list()[1].id
    gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY, settle_ms = { 30 } })
    assert(gc_mail.queue.retry(d))
    wait('retried', drained)
  end)
  vim.uv.fs_rename, vim.uv.fs_unlink, vim.uv.fs_open = real.fs_rename, real.fs_unlink, real.fs_open
  assert(ok, err)
  eq(in_place, {}, 'message files written in place')
  eq(unlocked, {}, 'changes made without the lock')
  local kinds = vim.tbl_keys(changes)
  table.sort(kinds)
  eq(kinds, { 'rename:claim', 'rename:file', 'unlink:claim', 'unlink:file' }, 'every kind of change was seen')
  eq(sent(), { '/srv/imd-city|fails once', '/srv/imd-city|fails once', '/srv/imd-city|retried', '/srv/imd-city|again' },
    'each sent once (the failure aside), the delivered one never')
end)

test('rule 3: retry reads and rewrites under one hold of the lock, so it never recreates a claimed file', function()
  gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY, lock_wait_ms = 50 })
  gc_mail.queue.stop()
  local id = assert(gc_mail.queue.add(TWO[1], { subject = 'gave up', body = 'a' }))
  local file = queue_dir .. '/' .. id .. '.json'
  local record = vim.json.decode(read_file(file))
  record.failed, record.attempts = true, 4
  write(file, vim.json.encode(record))
  -- While retry reads the file, another Neovim's worker tries to claim it:
  -- it must find the lock held, so it cannot rename the file in between.
  local real_open, probed = vim.uv.fs_open, {}
  vim.uv.fs_open = function(p, mode, ...)
    if p == file and mode == 'r' then
      probed[#probed + 1] = lock_free(queue_dir, real_open)
    end
    return real_open(p, mode, ...)
  end
  local ok, a, b = pcall(gc_mail.queue.retry, id)
  vim.uv.fs_open = real_open
  eq({ ok, a, b }, { true, true, nil }, 'retry')
  eq(probed, { false }, 'the lock was free while retry read the file')
  eq(vim.json.decode(read_file(file)).failed, false, 'retried')

  -- Another Neovim holds the lock: retry and delete refuse busy and change nothing.
  local ffi = require('ffi')
  local fd = assert(vim.uv.fs_open(queue_dir .. '/.lock', 'a', 384))
  eq(ffi.C.flock(fd, 2), 0, 'lock taken by the test')
  local before = read_file(file)
  eq({ gc_mail.queue.retry(id) }, { nil, 'the queue is busy (another Neovim is using it); try again' }, 'retry while locked')
  eq({ gc_mail.queue.delete(id) }, { nil, 'the queue is busy (another Neovim is using it); try again' }, 'delete while locked')
  eq(read_file(file), before, 'file changed under a held lock')
  vim.uv.fs_close(fd)

  -- Claimed by another live Neovim: retry and delete refuse, no <id>.json appears.
  local live = vim.system({ 'sleep', '5' })
  local claim = claim_name(id, live.pid)
  assert(vim.uv.fs_rename(file, claim))
  eq({ gc_mail.queue.retry(id) }, { nil, 'it is being sent or gone' }, 'retry of a claimed message')
  eq({ gc_mail.queue.delete(id) }, { nil, 'it is being sent or gone' }, 'delete of a claimed message')
  eq(vim.uv.fs_stat(file), nil, 'the claimed message was recreated')
  eq(vim.uv.fs_stat(claim) ~= nil, true, 'claim kept')
  live:kill(9)
  live:wait()
end)

test('rule 6: a queue directory that cannot be read refuses adds, shows the error and holds the worker', function()
  gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY, settle_ms = { 30 } })
  gc_mail.queue.stop()
  assert(gc_mail.queue.add(TWO[1], { subject = 'already queued', body = 'a' }))
  gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY, settle_ms = { 30 } })
  local function unreadable(p)
    return p == queue_dir
  end
  failing('fs_scandir', 'EACCES: permission denied', unreadable, function()
    notes = {}
    local buf = buffer({ 'not now' })
    eq(gc_mail.send(buf, TWO[1]), nil, 'queued into an unreadable queue')
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'not now' }, 'buffer kept')
    eq(notes[1].message, 'gc-mail: cannot read the queue directory: EACCES: permission denied', 'refusal')
    eq({ gc_mail.queue.list() }, { nil, 'cannot read the queue directory: EACCES: permission denied' }, 'list')
    vim.cmd('GcMailQueue')
    eq(lines_of(floats()[1]), { ' cannot read the queue directory: EACCES: permission denied ' }, 'queue window')
    vim.api.nvim_feedkeys('r', 'x', false)
    vim.api.nvim_feedkeys('q', 'x', false)
    -- The worker says so once and sends nothing.
    gc_mail.queue.pump()
    vim.wait(200)
    eq(sent(), {}, 'sent from an unreadable queue')
    eq(#errors_matching('cannot read the queue directory: EACCES: permission denied; nothing is sent until it can be read'),
      1, 'worker error shown once')
  end)
  wait('sent once readable', drained)
  eq(sent(), { '/srv/imd-city|already queued' }, 'sent after recovery')
  eq(#vim.tbl_filter(function(note)
    return note.message == 'gc-mail: the queue can be read again'
  end, notes), 1, 'recovery shown')
  -- A listing that fails part-way is an error too, not a short list.
  failing('fs_scandir_next', 'EIO: i/o error', function()
    return true
  end, function()
    eq({ gc_mail.queue.list() }, { nil, 'cannot read the queue directory: EIO: i/o error' }, 'list cut short')
  end)
  -- A real directory without read permission (the queue still writable).
  if vim.uv.getuid() ~= 0 then
    gc_mail.queue.stop()
    vim.uv.fs_chmod(queue_dir, 448 - 256) -- 0300: write and search, no read
    local id, err = gc_mail.queue.add(TWO[1], { subject = 'x', body = 'y' })
    vim.uv.fs_chmod(queue_dir, 448)
    eq(id, nil, 'added to an unreadable directory')
    assert(err:find('^cannot read the queue directory: EACCES'), err)
    eq(spool(), {}, 'a file was added')
  end
end)

test(':GcMailQueue renders every queue file as one sanitized line and can still delete it', function()
  gc_mail.queue.stop()
  vim.fn.mkdir(queue_dir, 'p')
  local good = { version = 1, city = { name = 'tab\tcity', path = '/p' }, subject = 'cr\rhere', body = 'b', created = os.time(),
    attempts = 1, next_at = 0, failed = true, last_error = 'exit 1: one\r\ntwo\27[31m' }
  write(queue_dir .. '/0000000000000001-00001-00000001.json', vim.json.encode(good))
  write(queue_dir .. '/0000000000000002-00001-00000002.json', vim.json.encode(vim.tbl_extend('force', good,
    { ['evil\nkey'] = true })))
  vim.cmd('GcMailQueue')
  local lines = lines_of(floats()[1])
  eq(#lines, 2, 'one line per file')
  for _, line in ipairs(lines) do
    eq(line:find('%c'), nil, 'control character in ' .. vim.inspect(line))
  end
  eq(lines[1], ' tab city  cr here  0s  failed  exit 1: one / two [31m ', 'valid record')
  eq(lines[2], ' ? 0000000000000002-00001-00000002.json  unreadable: not a gc-mail message: unknown field evil / key ',
    'unreadable record')
  vim.api.nvim_feedkeys('jd', 'x', false)
  eq(spool(), { '0000000000000001-00001-00000001.json' }, 'the unreadable file deleted')
  vim.api.nvim_feedkeys('q', 'x', false)
end)


-- ---- the mailbox -------------------------------------------------------------

local function mailbox()
  return require('gc_mail.mailbox')
end

-- A message as gc prints it (mail_message), in a thread of its own.
local function msg(id, fields)
  return vim.tbl_extend('force', {
    id = id, from = 'mayor', to = 'human', subject = 'subject ' .. id, body = 'body of ' .. id .. '\nsecond line',
    created_at = '2026-10-07T12:00:00Z', read = false, thread_id = 'thread-' .. vim.fn.sha256(id):sub(1, 12),
  }, fields or {})
end

-- The fake's answer to `gc mail <cmd>`, for one city (the path's last part) or all.
local function answer(cmd, record, city)
  local base = vim.env.FAKE_GC_MAIL .. '/' .. cmd .. (city and ('.' .. city) or '')
  write(base .. '.json', vim.json.encode(vim.tbl_extend('keep', record, { schema_version = '1', ok = true })) .. '\n')
end

local function raw_answer(cmd, ext, text, city)
  write(vim.env.FAKE_GC_MAIL .. '/' .. cmd .. (city and ('.' .. city) or '') .. '.' .. ext, text)
end

local function inbox(city, messages)
  answer('inbox', { recipient = 'human', recipients = { 'human' }, messages = messages }, city)
end

local function acted(cmd, id)
  answer(cmd, { command = 'mail.' .. cmd, action = cmd, id = id, ids = { id }, count = 1 })
end

local function call(cmd, city, ...)
  return vim.list_extend({ '--city', city, 'mail', cmd }, { ... })
end

local function has_call(argv)
  for _, c in ipairs(mail_calls()) do
    if vim.deep_equal(c, argv) then
      return true
    end
  end
  return false
end

-- The mailbox lines without their age column, which depends on the clock.
local function rows(win)
  return vim.tbl_map(function(line)
    return (line:gsub('  %d+[smhd] $', ''))
  end, lines_of(win))
end

local function kept_files()
  if vim.fn.isdirectory(mailbox_dir) == 0 then
    return {}
  end
  return vim.fn.readdir(mailbox_dir, function(name)
    return name:sub(1, 1) ~= '.' and 1 or 0
  end)
end

local function settled(win, count)
  wait('the mailbox did not settle', function()
    local now = rows(win)
    return #now == count and now[1] ~= ' loading… '
  end)
end

test('the mailbox lists the human mail of every city, newest first, with one inbox call per city', function()
  preload()
  inbox('imd-city', {
    msg('ic-wisp-a1', { subject = 'at noon', created_at = '2026-10-07T12:00:00Z' }),
    msg('ic-wisp-a2', { subject = 'at eleven', from = 'builder-1', created_at = '2026-10-07T13:00:00.123+02:00' }),
  })
  inbox('side city', { msg('sc-wisp-b1', { subject = 'Re: side\nwith a break', created_at = '2026-10-07T11:30:00Z' }) })
  local win = mailbox().open()
  eq(#floats(), 1, 'mailbox window')
  settled(win, 3)
  eq(rows(win), {
    ' ● imd-city  mayor  at noon',
    ' ● side-city  mayor  Re: side / with a break',
    ' ● imd-city  builder-1  at eleven',
  }, 'newest first across cities (13:00+02:00 is 11:00Z), one sanitized line each')
  wait('the city refresh', function()
    return gc_mail.cached_cities() ~= nil and #mail_calls() >= 2
  end)
  vim.wait(200)
  local calls = mail_calls()
  table.sort(calls, function(a, b)
    return a[2] < b[2]
  end)
  eq(calls, { call('inbox', '/srv/imd-city', 'human', '--json'), call('inbox', '/srv/side city', 'human', '--json') },
    'one inbox call per city, also after the city list refreshed')
  eq(recorded_argv(), nil, 'nothing was sent')
  vim.api.nvim_feedkeys('q', 'x', false)
  eq(#floats(), 0, 'q closes')
end)

test('opening a message shows it at once, marks it read once, and keeps it listed after gc closes it', function()
  preload()
  inbox('imd-city', { msg('ic-wisp-a1', { subject = 'Mailbox plan' }) })
  inbox('side city', {})
  answer('read', { message = msg('ic-wisp-a1', { subject = 'Mailbox plan', read = true }) })
  local win = mailbox().open()
  settled(win, 1)
  eq(rows(win), { ' ● imd-city  mayor  Mailbox plan' }, 'unread')
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  eq(#floats(), 0, 'the mailbox closes on open')
  local shown = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  eq(vim.list_slice(shown, 1, 3), { '# Mailbox plan', '',
    '**From** mayor · **To** human · **City** imd-city · 2026-10-07T12:00:00Z' }, 'headers')
  eq(vim.list_slice(shown, #shown - 1), { 'body of ic-wisp-a1', 'second line' }, 'body')
  wait('marked read and kept', function()
    return has_call(call('read', '/srv/imd-city', 'ic-wisp-a1', '--json')) and #kept_files() == 1
  end)
  -- gc's sweep closes read mail: the inbox no longer lists it.
  inbox('imd-city', {})
  local before = #mail_calls()
  win = mailbox().open()
  settled(win, 1)
  wait('the inbox answered', function()
    return #mail_calls() == before + 2
  end)
  vim.wait(100)
  eq(rows(win), { '   imd-city  mayor  Mailbox plan' }, 'read and still listed')
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  vim.wait(200)
  eq(#vim.tbl_filter(function(c)
    return c[4] == 'read'
  end, mail_calls()), 1, 'a message already read runs no second read')
  -- A restart reads the kept copy from disk.
  vim.api.nvim_feedkeys('q', 'x', false)
  package.loaded['gc_mail.mailbox'] = nil
  mailbox().configure({ dir = mailbox_dir })
  win = mailbox().open()
  settled(win, 1)
  vim.wait(100)
  eq(rows(win), { '   imd-city  mayor  Mailbox plan' }, 'kept across a restart')
  vim.api.nvim_feedkeys('q', 'x', false)
end)

test('mark read, mark unread, archive, delete and thread call gc with the exact argv for the picked message only', function()
  preload()
  inbox('imd-city', {
    msg('ic-wisp-a1', { subject = 'first', created_at = '2026-10-07T13:00:00Z' }),
    msg('ic-wisp-a2', { subject = 'second', created_at = '2026-10-07T12:00:00Z' }),
  })
  inbox('side city', {})
  local win = mailbox().open()
  settled(win, 2)
  acted('mark-read', 'ic-wisp-a1')
  vim.api.nvim_feedkeys('m', 'x', false)
  wait('marked read', function()
    return rows(win)[1] == '   imd-city  mayor  first'
  end)
  eq(has_call(call('mark-read', '/srv/imd-city', 'ic-wisp-a1', '--json')), true, 'mark-read argv')
  eq(#kept_files(), 1, 'kept once read')
  acted('mark-unread', 'ic-wisp-a1')
  vim.api.nvim_feedkeys('u', 'x', false)
  wait('unread again', function()
    return rows(win)[1] == ' ● imd-city  mayor  first'
  end)
  eq(has_call(call('mark-unread', '/srv/imd-city', 'ic-wisp-a1', '--json')), true, 'mark-unread argv')
  eq(vim.json.decode(read_file(mailbox_dir .. '/' .. kept_files()[1])).read, false, 'the kept copy says unread')
  acted('archive', 'ic-wisp-a1')
  vim.api.nvim_feedkeys('a', 'x', false)
  wait('archived', function()
    return #rows(win) == 1
  end)
  eq(has_call(call('archive', '/srv/imd-city', 'ic-wisp-a1', '--json')), true, 'archive argv')
  eq(kept_files(), {}, 'the kept copy goes with it')
  eq(rows(win), { ' ● imd-city  mayor  second' }, 'the other message stays')
  -- Delete asks first; No deletes nothing.
  local confirm = vim.fn.confirm
  local asked
  vim.fn.confirm = function(question)
    asked = question
    return 2
  end
  acted('delete', 'ic-wisp-a2')
  vim.api.nvim_feedkeys('d', 'x', false)
  vim.wait(200)
  eq(asked, 'Delete "second" from mayor?', 'delete asks')
  eq(has_call(call('delete', '/srv/imd-city', 'ic-wisp-a2', '--json')), false, 'No deleted it')
  vim.fn.confirm = function()
    return 1
  end
  vim.api.nvim_feedkeys('d', 'x', false)
  vim.fn.confirm = confirm
  wait('deleted', function()
    return rows(win)[1] == ' no mail '
  end)
  eq(has_call(call('delete', '/srv/imd-city', 'ic-wisp-a2', '--json')), true, 'delete argv')
  for _, c in ipairs(mail_calls()) do
    if c[4] == 'archive' or c[4] == 'delete' then
      eq(#c, 6, 'one id per archive or delete: ' .. table.concat(c, ' '))
    end
  end
  vim.api.nvim_feedkeys('q', 'x', false)
  -- t shows the thread, oldest first.
  inbox('imd-city', { msg('ic-wisp-a3', { subject = 'Re: plan', thread_id = 'thread-0a1b2c3d4e5f' }) })
  answer('thread', { thread_id = 'thread-0a1b2c3d4e5f', messages = {
    msg('ic-wisp-a3', { subject = 'Re: plan', thread_id = 'thread-0a1b2c3d4e5f', created_at = '2026-10-07T13:00:00Z' }),
    msg('ic-wisp-a0', { from = 'human', to = 'mayor', subject = 'plan', thread_id = 'thread-0a1b2c3d4e5f', read = true }),
  } })
  win = mailbox().open()
  settled(win, 1)
  vim.wait(100)
  vim.api.nvim_feedkeys('t', 'x', false)
  wait('thread shown', function()
    return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == '# plan'
  end)
  eq(has_call(call('thread', '/srv/imd-city', 'thread-0a1b2c3d4e5f', '--json')), true, 'thread argv')
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  assert(text:find('# plan', 1, true) == 1, 'titled with the first subject')
  assert(text:find('## human', 1, true) < text:find('## mayor', 1, true), 'oldest first')
end)

-- Opens the message `m` from the mailbox with gc's answers for it in place.
local function open_message(m, thread_messages)
  preload()
  inbox('imd-city', { m })
  inbox('side city', {})
  answer('read', { message = vim.tbl_extend('force', m, { read = true }) })
  if thread_messages then
    answer('thread', { thread_id = m.thread_id, messages = thread_messages })
  end
  local win = mailbox().open()
  settled(win, 1)
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  return vim.api.nvim_get_current_buf()
end

-- The plugin's own keys: the markdown ftplugin adds [[, ]] and gO, none nowait.
local function view_keys(buf)
  local keys = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if map.nowait == 1 then
      keys[#keys + 1] = map.lhs
    end
  end
  table.sort(keys)
  return keys
end

test('markdown message view: title, escaped header lines, a rule, then the body verbatim', function()
  local body = 'a *bold* line with _under_ and [link](x) <tag> # not a heading | pipe\n```lua\nlocal x = "*y*"\n```\n---\nlast'
  local buf = open_message(msg('ic-wisp-a1', {
    subject = 'Re: *plan* [v2] <now> #1 | `x` \\ end', from = 'may_or', body = body,
    thread_id = 'thread-0a1b2c3d4e5f' }))
  eq(vim.bo[buf].filetype, 'markdown', 'filetype')
  eq(vim.bo[buf].buftype, 'nofile', 'buftype')
  eq(vim.bo[buf].modifiable, false, 'nomodifiable')
  eq(vim.bo[buf].bufhidden, 'wipe', 'bufhidden')
  eq(vim.api.nvim_buf_get_name(buf):match('gc%-mail://.*$'), 'gc-mail://imd-city/ic-wisp-a1', 'name')
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(lines[1], '# Re: \\*plan\\* \\[v2\\] \\<now\\> \\#1 \\| \\`x\\` \\\\ end', 'escaped title')
  eq(lines[3], '**From** may\\_or · **To** human · **City** imd-city · 2026-10-07T12:00:00Z', 'sender line')
  assert(lines[5]:find('^`ic%-wisp%-a1` · thread `thread%-0a1b2c3d4e5f` · r reply  t thread  u unread  a archive  d delete  q close · Read mail stays'),
    'id line: ' .. lines[5])
  eq(lines[7], '---', 'rule')
  eq(vim.list_slice(lines, 9), vim.split(body, '\n', { plain = true }), 'body verbatim, not escaped')
  -- Blank lines keep the id line from reading as a heading over the rule.
  eq({ lines[2], lines[4], lines[6], lines[8] }, { '', '', '', '' }, 'blank separators')
  eq(view_keys(buf), { 'a', 'd', 'q', 'r', 't', 'u' }, 'the same keys as before')
end)

test('markdown thread view: first subject as the title, a heading per message, a rule between messages', function()
  local first = msg('ic-wisp-a0', { from = 'human', to = 'mayor', subject = 'plan *v1*', thread_id = 'thread-0a1b2c3d4e5f',
    body = '*asked*\n```\ncode\n```', created_at = '2026-10-07T11:00:00Z' })
  local second = msg('ic-wisp-a3', { subject = 'Re: plan', thread_id = 'thread-0a1b2c3d4e5f',
    body = 'answer', created_at = '2026-10-07T13:00:00Z' })
  open_message(second, { second, first })
  vim.api.nvim_feedkeys('t', 'x', false)
  wait('thread shown', function()
    return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == '# plan \\*v1\\*'
  end)
  local buf = vim.api.nvim_get_current_buf()
  eq(vim.bo[buf].filetype, 'markdown', 'filetype')
  eq(vim.bo[buf].modifiable, false, 'nomodifiable')
  eq(vim.bo[buf].buftype, 'nofile', 'buftype')
  eq(vim.bo[buf].bufhidden, 'wipe', 'bufhidden')
  eq(vim.api.nvim_buf_get_name(buf):match('gc%-mail://.*$'), 'gc-mail://imd-city/thread/thread-0a1b2c3d4e5f', 'name')
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), {
    '# plan \\*v1\\*', '',
    '## human · 2026-10-07T11:00:00Z', '',
    '*asked*', '```', 'code', '```', '',
    '---', '',
    '## mayor · 2026-10-07T13:00:00Z', '',
    'answer',
  }, 'thread layout')
  eq(view_keys(buf), { 'q' }, 'the thread view only has q')
end)

test('markdown = false keeps the plain message and thread layouts, with no filetype', function()
  preload()
  gc_mail.setup({ keymap = false, mailbox_keymap = false, panel_keymap = false, state_dir = vim.fs.dirname(queue_dir),
    markdown = false })
  local first = msg('ic-wisp-a0', { from = 'human', to = 'mayor', subject = 'plan', thread_id = 'thread-0a1b2c3d4e5f' })
  local second = msg('ic-wisp-a3', { subject = 'Re: plan', thread_id = 'thread-0a1b2c3d4e5f',
    created_at = '2026-10-07T13:00:00Z' })
  inbox('imd-city', { second })
  inbox('side city', {})
  answer('read', { message = second })
  answer('thread', { thread_id = 'thread-0a1b2c3d4e5f', messages = { second, first } })
  local win = mailbox().open()
  settled(win, 1)
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  local buf = vim.api.nvim_get_current_buf()
  eq(vim.bo[buf].filetype, '', 'no filetype')
  eq(vim.bo[buf].modifiable, false, 'nomodifiable')
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), {
    'From:    mayor', 'To:      human', 'City:    imd-city', 'Date:    2026-10-07T13:00:00Z', 'Subject: Re: plan',
    'Id:      ic-wisp-a3   thread thread-0a1b2c3d4e5f',
    'Keys:    r reply  t thread  u unread  a archive  d delete  q close',
    'Read mail stays in this mailbox until you archive or delete it; gc closes read mail an hour after it was sent.',
    '', 'body of ic-wisp-a3', 'second line',
  }, 'plain message')
  vim.api.nvim_feedkeys('t', 'x', false)
  wait('thread shown', function()
    return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:find('^Thread thread%-0a1b2c3d4e5f in imd%-city, 2 open') ~= nil
  end)
  buf = vim.api.nvim_get_current_buf()
  eq(vim.bo[buf].filetype, '', 'no filetype on the thread')
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), {
    'Thread thread-0a1b2c3d4e5f in imd-city, 2 open message(s); gc lists no closed mail here',
    '', 'From:    human', 'To:      mayor', 'City:    imd-city', 'Date:    2026-10-07T12:00:00Z', 'Subject: plan',
    'Id:      ic-wisp-a0   thread thread-0a1b2c3d4e5f',
    '', 'body of ic-wisp-a0', 'second line',
    '', 'From:    mayor', 'To:      human', 'City:    imd-city', 'Date:    2026-10-07T13:00:00Z', 'Subject: Re: plan',
    'Id:      ic-wisp-a3   thread thread-0a1b2c3d4e5f',
    '', 'body of ic-wisp-a3', 'second line',
  }, 'plain thread')
end)

test('a malformed, failed or hung gc answer is said once and leaves the mailbox as it was', function()
  preload()
  mailbox().configure({ timeout_ms = 300 })
  inbox('imd-city', { msg('ic-wisp-a1', { subject = 'kept on screen' }) })
  inbox('side city', {})
  local win = mailbox().open()
  settled(win, 1)
  vim.api.nvim_feedkeys('q', 'x', false)
  local cases = {
    { 'not json', function() raw_answer('inbox', 'json', 'gc mail inbox: not json\n', 'imd-city') end,
      'gc mail inbox in imd-city printed something unexpected' },
    { 'a message without its read flag', function()
      local m = msg('ic-wisp-a9')
      m.read = nil
      inbox('imd-city', { m })
    end, 'gc mail inbox in imd-city printed something unexpected (a message has no read flag)' },
    { 'ok false', function() answer('inbox', { ok = false, messages = {} }, 'imd-city') end,
      'gc mail inbox in imd-city printed something unexpected' },
    { 'messages as an empty object', function()
      raw_answer('inbox', 'json', '{"schema_version":"1","ok":true,"recipient":"human","recipients":["human"],"messages":{}}\n',
        'imd-city')
    end, 'gc mail inbox in imd-city printed something unexpected (no message list)' },
    { 'a failing gc', function()
      inbox('imd-city', {})
      raw_answer('inbox', 'exit', '1', 'imd-city')
      raw_answer('inbox', 'stderr', 'gc mail inbox: store unavailable\n', 'imd-city')
    end, 'gc mail inbox in imd-city failed: gc mail inbox: store unavailable' },
    { 'a hung gc', function()
      vim.fn.delete(vim.env.FAKE_GC_MAIL .. '/inbox.imd-city.exit')
      vim.fn.delete(vim.env.FAKE_GC_MAIL .. '/inbox.imd-city.stderr')
      raw_answer('inbox', 'hang', '5', 'imd-city')
    end, 'gc mail inbox in imd-city did not answer within 0.3 s' },
  }
  for _, case in ipairs(cases) do
    local name, setup, expected = case[1], case[2], case[3]
    vim.fn.delete(vim.env.FAKE_GC_MAIL .. '/inbox.imd-city.json')
    setup()
    for round = 1, 2 do
      notes = {}
      win = mailbox().open()
      wait(name .. ': the inbox did not finish', function()
        return #notes > 0 or (round == 2 and vim.wait(600) == false)
      end, 5000)
      vim.wait(100)
      eq(rows(win), { ' ● imd-city  mayor  kept on screen' }, name .. ': the list on screen')
      local errors = vim.tbl_filter(function(note)
        return note.level == vim.log.levels.ERROR
      end, notes)
      if round == 1 then
        eq(#errors, 1, name .. ': said once')
        eq(errors[1].message, 'gc-mail: ' .. expected, name)
      else
        eq(#errors, 0, name .. ': said again')
      end
      vim.api.nvim_feedkeys('q', 'x', false)
    end
  end
end)

test('a reply opens a compose buffer, goes through the disk queue and survives a failed first send', function()
  preload()
  inbox('imd-city', { msg('ic-wisp-a1', { subject = 'Mailbox plan' }) })
  inbox('side city', {})
  local win = mailbox().open()
  settled(win, 1)
  vim.api.nvim_feedkeys('r', 'x', false)
  eq(#floats(), 0, 'the mailbox closes')
  local buf = vim.api.nvim_get_current_buf()
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'Re: Mailbox plan', '', '' }, 'prefilled subject')
  eq(vim.b[buf].gc_mail_reply, { city = TWO[1], id = 'ic-wisp-a1', to = 'mayor' }, 'reply context')
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { 'looks good' })
  vim.env.FAKE_GC_FAIL_TIMES = '1'
  notes = {}
  eq(gc_mail.open(), nil, 'no city picker for a reply')
  eq(#floats(), 0, 'no float')
  eq(notes[1].message, 'gc-mail: queued for imd-city mayor: Re: Mailbox plan', 'queued notice')
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { '' }, 'cleared once on disk')
  eq(vim.b[buf].gc_mail_reply, nil, 'no longer a reply waiting')
  local record = vim.json.decode(read_file(queue_dir .. '/' .. spool()[1]))
  eq({ record.reply_to, record.to, record.subject }, { 'ic-wisp-a1', 'mayor', 'Re: Mailbox plan' }, 'queue record')
  eq(gc_mail.queue_lines({ { record = record } }, record.created)[1], ' imd-city mayor  Re: Mailbox plan  0s  pending ',
    ':GcMailQueue line')
  wait('retried until sent', drained)
  eq(sent(), { '/srv/imd-city|Re: Mailbox plan', '/srv/imd-city|Re: Mailbox plan' }, 'two tries')
  eq(recorded_argv(), { '--city', '/srv/imd-city', 'mail', 'reply', 'ic-wisp-a1', '-s', 'Re: Mailbox plan', '-m',
    'Re: Mailbox plan\n\nlooks good', '--notify' }, 'reply argv')
  eq(notes[#notes].message, 'gc-mail: sent to imd-city mayor', 'sent notice')
  -- A reply record that names no message, or an option-like id, is refused.
  eq(select(2, gc_mail.queue.add(TWO[1], { subject = 's', body = 'b', reply_to = '--all', to = 'mayor' })),
    'cannot queue the message: bad reply_to', 'option-like id refused')
end)

test('subject_prefix and subject_suffix label every sent subject once, within 72 characters', function()
  gc_mail.setup({ keymap = false, mailbox_keymap = false, state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY,
    subject_prefix = '[Nick] ', subject_suffix = ' (nvim)' })
  local buf = buffer({ 'Deploy plan', 'body' })
  assert(gc_mail.send(buf, TWO[1]), 'not queued')
  wait('sent', drained)
  eq(recorded_argv()[7], '[Nick] Deploy plan (nvim)', 'labelled send')
  eq(notes[#notes - 1].message, 'gc-mail: queued for imd-city mayor: [Nick] Deploy plan (nvim)', 'queued line shows the label')
  buf = buffer({ string.rep('x', 80) })
  assert(gc_mail.send(buf, TWO[1]), 'not queued')
  wait('sent', drained)
  eq(recorded_argv()[7], '[Nick] ' .. string.rep('x', 58) .. ' (nvim)', 'the label counts in the 72 characters')
  eq(vim.fn.strchars(recorded_argv()[7]), 72, 'at most 72')
  -- A reply to a labelled subject is labelled once.
  buf = buffer({ 'Re: [Nick] Deploy plan (nvim)', '', 'ok' })
  vim.api.nvim_buf_set_var(buf, 'gc_mail_reply', { city = TWO[1], id = 'ic-wisp-a1', to = 'mayor' })
  gc_mail.open()
  wait('sent', drained)
  eq(recorded_argv()[4], 'reply', 'sent as a reply')
  eq(recorded_argv()[7], '[Nick] Re: Deploy plan (nvim)', 'labelled once')
  eq(gc_mail.label('[Nick] already (nvim)'), '[Nick] already (nvim)', 'idempotent')
  -- Empty options leave the subject as it is.
  eq(gc_mail.label('Re: x', { subject_prefix = '', subject_suffix = '' }), 'Re: x', 'no label')
  for _, bad in ipairs({ { subject_prefix = 'a\nb' }, { subject_suffix = 3 }, { subject_prefix = string.rep('p', 41) },
    { check_ms = 1000 }, { check_ms = 'often' }, { panel_poll_ms = 14999 }, { panel_poll_ms = false },
    { panel_height = 0 }, { panel_height = 2.5 } }) do
    eq(pcall(gc_mail.setup, bad), false, 'refused: ' .. vim.inspect(bad))
  end
end)

test('the opt-in new-mail check: no timer by default, one count per city while focused, a notice when unread grows', function()
  preload()
  eq(mailbox().checking(), false, 'no timer')
  answer('count', { recipient = 'human', recipients = { 'human' }, total = 3, unread = 1 }, 'imd-city')
  answer('count', { recipient = 'human', recipients = { 'human' }, total = 0, unread = 0 }, 'side city')
  mailbox().start_check(1000)
  eq(mailbox().checking(), true, 'started')
  mailbox().check_once()
  wait('one count per city', function()
    return #mail_calls() == 2
  end)
  vim.wait(100)
  eq(#notes, 0, 'the first pass only learns the counts')
  answer('count', { recipient = 'human', recipients = { 'human' }, total = 4, unread = 2 }, 'imd-city')
  mailbox().check_once()
  wait('second pass', function()
    return #notes == 1
  end)
  eq(notes[1].message, 'gc-mail: 2 unread mail in imd-city; <Space>mi opens the mailbox', 'notice')
  eq(has_call(call('count', '/srv/imd-city', 'human', '--json')), true, 'count argv')
  vim.api.nvim_exec_autocmds('FocusLost', {})
  mailbox().check_once()
  vim.wait(200)
  eq(#mail_calls(), 4, 'nothing runs without focus')
  vim.api.nvim_exec_autocmds('FocusGained', {})
  mailbox().stop_check()
  eq(mailbox().checking(), false, 'stopped')
  gc_mail.setup({ keymap = false, mailbox_keymap = false, state_dir = vim.fs.dirname(queue_dir), check_ms = 60000 })
  wait('started after startup', mailbox().checking)
  -- setup() again with check_ms = false stops it at once.
  gc_mail.setup({ keymap = false, mailbox_keymap = false, state_dir = vim.fs.dirname(queue_dir), check_ms = false })
  eq(mailbox().checking(), false, 'check_ms = false stops a running check')
  vim.wait(200)
  eq(mailbox().checking(), false, 'and nothing starts it again after startup')
end)

test('an outdated inbox answer never brings back what a later call, a read or an archive changed', function()
  preload()
  inbox('side city', {})
  -- A mailbox closed and reopened while its first inbox call still runs.
  inbox('imd-city', { msg('ic-wisp-a1', { subject = 'old' }) })
  raw_answer('inbox', 'delay', '1', 'imd-city')
  local win = mailbox().open()
  vim.wait(100)
  vim.api.nvim_feedkeys('q', 'x', false)
  vim.fn.delete(vim.env.FAKE_GC_MAIL .. '/inbox.imd-city.delay')
  inbox('imd-city', {})
  win = mailbox().open()
  wait('the second call answered', function()
    return rows(win)[1] == ' no mail '
  end)
  vim.wait(1500)
  eq(rows(win), { ' no mail ' }, 'the first call\'s late answer is dropped')
  vim.api.nvim_feedkeys('q', 'x', false)
  -- An archive and a read while a refresh still runs.
  inbox('imd-city', {
    msg('ic-wisp-a2', { subject = 'to archive', created_at = '2026-10-07T13:00:00Z' }),
    msg('ic-wisp-a3', { subject = 'to read', created_at = '2026-10-07T12:00:00Z' }),
    msg('ic-wisp-a4', { subject = 'untouched', created_at = '2026-10-07T11:00:00Z' }),
  })
  win = mailbox().open()
  settled(win, 3)
  raw_answer('inbox', 'delay', '1', 'imd-city')
  vim.api.nvim_feedkeys('R', 'x', false)
  acted('archive', 'ic-wisp-a2')
  vim.api.nvim_feedkeys('a', 'x', false)
  wait('archived', function()
    return rows(win)[1] == ' ● imd-city  mayor  to read'
  end)
  acted('mark-read', 'ic-wisp-a3')
  vim.api.nvim_feedkeys('m', 'x', false)
  wait('marked read', function()
    return rows(win)[1] == '   imd-city  mayor  to read'
  end)
  vim.wait(1500) -- the refresh answers 1 s after it was made
  eq(rows(win), { '   imd-city  mayor  to read', ' ● imd-city  mayor  untouched' },
    'the refresh answer brings back neither the archived nor the unread copy of the read message')
end)

local function errors()
  return vim.tbl_map(function(note)
    return note.message
  end, vim.tbl_filter(function(note)
    return note.level == vim.log.levels.ERROR
  end, notes))
end

test('I1: every answer shape has one decoder that takes only what gc prints', function()
  preload()
  local decode = mailbox().DECODE
  local id, thread = 'ic-wisp-a1', 'thread-0a1b2c3d4e5f'
  local function action(verb)
    return { command = 'mail.' .. verb, action = verb, id = id, ids = { id }, count = 1 }
  end
  local good = {
    inbox = { { recipients = { 'human' }, messages = { msg(id) } }, 'human' },
    thread = { { thread_id = thread, messages = { msg(id, { thread_id = thread }) } }, thread },
    read = { { message = msg(id, { read = true }) }, id },
    count = { { recipient = 'human', recipients = { 'human' }, total = 3, unread = 1 }, 'human' },
    ['mark-read'] = { action('mark-read'), id },
    ['mark-unread'] = { action('mark-unread'), id },
    archive = { action('archive'), id },
    delete = { action('delete'), id },
  }
  eq(vim.tbl_count(decode), vim.tbl_count(good), 'one decoder per answer shape')
  for verb, case in pairs(good) do
    local record, arg = case[1], case[2]
    assert(decode[verb](record, arg) ~= nil, verb .. ': the good answer decodes')
    -- Every field the code reads is required.
    for key in pairs(record) do
      if not (verb == 'archive' or verb == 'delete') or key ~= 'id' then
        local copy = vim.deepcopy(record)
        copy[key] = nil
        local value, why = decode[verb](copy, arg)
        eq(value, nil, verb .. ' without ' .. key)
        eq(type(why), 'string', verb .. ' without ' .. key .. ': a reason')
      end
    end
  end
  local bad = {
    { 'count', { recipient = 'human', recipients = { 'human' }, total = 3, unread = -1 } },
    { 'count', { recipient = 'human', recipients = { 'human' }, total = 3, unread = 1.5 } },
    { 'count', { recipient = 'human', recipients = { 'human' }, total = '3', unread = 1 } },
    { 'mark-read', vim.tbl_extend('force', action('mark-read'), { command = 'mail.mark-unread' }) },
    { 'mark-read', vim.tbl_extend('force', action('mark-read'), { action = 'archive' }) },
    { 'mark-read', vim.tbl_extend('force', action('mark-read'), { count = 0 }) },
    { 'mark-read', vim.tbl_extend('force', action('mark-read'), { id = 'ic-wisp-a2' }) },
    { 'archive', vim.tbl_extend('force', action('archive'), { ids = { 'ic-wisp-a2' } }) },
    { 'archive', vim.tbl_extend('force', action('archive'), { count = -1 }) },
    { 'delete', vim.tbl_extend('force', action('delete'), { ids = { id, 7 } }) },
    { 'inbox', { recipients = { 'human' }, messages = { msg('--all') } } },
    { 'inbox', { recipients = { 'human' }, messages = { msg(id, { thread_id = '--all' }) } } },
    { 'inbox', { recipients = { 'human' }, messages = { msg('ic-wisp-a1/../x') } } },
    { 'thread', { thread_id = '--all', messages = {} } },
    { 'read', { message = msg('ic-wisp-a2') } },
  }
  for _, case in ipairs(bad) do
    local verb, record = case[1], case[2]
    eq(decode[verb](record, good[verb][2]), nil, verb .. ' refuses ' .. vim.inspect(record))
  end
  -- An argument that is not what the verb takes never reaches argv.
  for _, case in ipairs({ { 'thread', '--all' }, { 'archive', '-h' }, { 'read', 'IC-1' }, { 'inbox', 'mayor' },
    { 'delete', 'ic-wisp-a1 ic-wisp-a2' } }) do
    local got
    mailbox().run(TWO[1], case[1], case[2], function(value, err)
      got = { value, err }
    end)
    eq(got[1], nil, 'not run: ' .. table.concat(case, ' '))
    assert(got[2]:find('was not run', 1, true), got[2])
  end
  vim.wait(200)
  eq(mail_calls(), {}, 'no gc call ran')
end)

test('r2a1: a count or action answer missing a field is said and changes nothing', function()
  preload()
  -- The check: a count without its total notifies nothing and is said once.
  answer('count', { recipient = 'human', recipients = { 'human' }, total = 1, unread = 1 }, 'imd-city')
  answer('count', { recipient = 'human', recipients = { 'human' }, total = 0, unread = 0 }, 'side city')
  mailbox().check_once()
  wait('first pass', function()
    return #mail_calls() == 2
  end)
  vim.wait(100)
  answer('count', { recipient = 'human', recipients = { 'human' }, unread = 5 }, 'imd-city')
  for _ = 1, 2 do
    mailbox().check_once()
    vim.wait(300)
  end
  eq(vim.tbl_filter(function(m)
    return m:find('unread mail in') ~= nil
  end, vim.tbl_map(function(n)
    return n.message
  end, notes)), {}, 'no new-mail notice from a malformed count')
  eq(errors(), { 'gc-mail: gc mail count in imd-city printed something unexpected (no total and unread count)' }, 'said once')
  -- Actions: an answer without command and action, or with a negative count.
  notes = {}
  inbox('imd-city', { msg('ic-wisp-a1', { subject = 'stays' }) })
  inbox('side city', {})
  local win = mailbox().open()
  settled(win, 1)
  answer('mark-read', { id = 'ic-wisp-a1', ids = { 'ic-wisp-a1' }, count = 1 })
  vim.api.nvim_feedkeys('m', 'x', false)
  answer('archive', { command = 'mail.archive', action = 'archive', ids = { 'ic-wisp-a1' }, count = -1 })
  vim.api.nvim_feedkeys('a', 'x', false)
  wait('both answered', function()
    return #errors() == 2
  end)
  vim.wait(100)
  eq(rows(win), { ' ● imd-city  mayor  stays' }, 'still listed, still unread')
  eq(kept_files(), {}, 'no kept copy')
  local said = errors()
  table.sort(said)
  eq(said, {
    'gc-mail: cannot archive "stays": gc mail archive in imd-city printed something unexpected (no count)',
    'gc-mail: cannot mark "stays" read: gc mail mark-read in imd-city printed something unexpected (it is not a mark-read answer)',
  }, 'each said (in either order)')
  vim.api.nvim_feedkeys('q', 'x', false)
end)

test('r2a2: a thread id that is not one gc prints is refused, never passed to gc', function()
  preload()
  inbox('imd-city', { msg('ic-wisp-a1', { subject = 'kept on screen' }) })
  inbox('side city', {})
  local win = mailbox().open()
  settled(win, 1)
  vim.api.nvim_feedkeys('q', 'x', false)
  inbox('imd-city', { msg('ic-wisp-a1', { subject = 'kept on screen', thread_id = '--all' }) })
  notes = {}
  win = mailbox().open()
  wait('the inbox answered', function()
    return #errors() == 1
  end)
  eq(errors(), { 'gc-mail: gc mail inbox in imd-city printed something unexpected (a message thread_id is not a gc thread id)' },
    'said')
  eq(rows(win), { ' ● imd-city  mayor  kept on screen' }, 'the list on screen stays')
  vim.api.nvim_feedkeys('t', 'x', false)
  vim.wait(200)
  for _, c in ipairs(mail_calls()) do
    assert(c[4] ~= 'thread' or c[5] == 'thread-' .. vim.fn.sha256('ic-wisp-a1'):sub(1, 12), 'thread argv: ' .. table.concat(c, ' '))
    assert(not vim.tbl_contains(c, '--all'), 'an option reached gc: ' .. table.concat(c, ' '))
  end
end)

test('r3a1: a thread answer is a thread only when its thread_id is a gc thread id', function()
  preload()
  local thread = mailbox().DECODE.thread
  local id, tid = 'ic-wisp-a1', 'thread-0a1b2c3d4e5f'
  local list = { msg(id, { thread_id = tid }) }
  assert(thread({ thread_id = tid, messages = list }, id) ~= nil, 'a message id answered with its thread')
  assert(thread({ thread_id = tid, messages = list }, tid) ~= nil, 'a thread id answered with that thread')
  for _, case in ipairs({
    { { thread_id = id, messages = list }, id, 'no thread_id' },
    { { thread_id = id, messages = {} }, id, 'no thread_id' },
    { { thread_id = 'thread-ffff', messages = list }, tid, 'it answered for another thread' },
  }) do
    local value, why = thread(case[1], case[2])
    eq({ value, why }, { nil, case[3] }, 'refuses ' .. vim.inspect(case[1]) .. ' for ' .. case[2])
  end
  -- From the mailbox: a message with no thread asks by its own id; gc echoing
  -- that id back is said, and no thread buffer opens.
  local alone = msg(id, { subject = 'kept on screen' })
  alone.thread_id = nil
  inbox('imd-city', { alone })
  inbox('side city', {})
  answer('thread', { thread_id = id, messages = { alone } })
  local win = mailbox().open()
  settled(win, 1)
  notes = {}
  vim.api.nvim_feedkeys('t', 'x', false)
  wait('the thread answered', function()
    return #errors() == 1
  end)
  eq(has_call(call('thread', '/srv/imd-city', id, '--json')), true, 'asked by the message id')
  eq(errors(), { 'gc-mail: cannot show the thread of "kept on screen": gc mail thread in imd-city printed something '
    .. 'unexpected (no thread_id)' }, 'said')
  vim.wait(100)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    assert(not vim.api.nvim_buf_get_name(buf):find('/thread/', 1, true), 'no thread buffer')
  end
end)

test('r2a3 and I2: a read answer that arrives after an archive or delete never brings the message or its copy back', function()
  preload()
  for _, verb in ipairs({ 'archive', 'delete' }) do
    reset()
    preload()
    inbox('imd-city', { msg('ic-wisp-a1', { subject = 'gone' }) })
    inbox('side city', {})
    answer('read', { message = msg('ic-wisp-a1', { subject = 'gone', read = true }) })
    raw_answer('read', 'delay', '1')
    acted(verb, 'ic-wisp-a1')
    local win = mailbox().open()
    settled(win, 1)
    vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
    local confirm = vim.fn.confirm
    vim.fn.confirm = function()
      return 1
    end
    vim.api.nvim_feedkeys(verb == 'archive' and 'a' or 'd', 'x', false)
    vim.fn.confirm = confirm
    wait(verb .. ' answered', function()
      return #vim.tbl_filter(function(n)
        return n.message:find('^gc%-mail: ' .. (verb == 'archive' and 'archived' or 'deleted')) ~= nil
      end, notes) == 1
    end)
    wait('the read answered', function()
      return has_call(call('read', '/srv/imd-city', 'ic-wisp-a1', '--json'))
    end)
    vim.wait(1500) -- the read answers 1 s after it was made
    eq(kept_files(), {}, verb .. ': no kept copy recreated')
    vim.cmd('only')
    inbox('imd-city', {})
    win = mailbox().open()
    settled(win, 1)
    vim.wait(200)
    eq(rows(win), { ' no mail ' }, verb .. ': not listed again')
    vim.api.nvim_feedkeys('q', 'x', false)
  end
end)

test('I2: action answers apply in the order their calls started, whatever order they arrive in', function()
  preload()
  inbox('imd-city', {
    msg('ic-wisp-a1', { subject = 'late read', created_at = '2026-10-07T13:00:00Z' }),
    msg('ic-wisp-a2', { subject = 'late archive', created_at = '2026-10-07T12:00:00Z' }),
  })
  inbox('side city', {})
  local win = mailbox().open()
  settled(win, 2)
  -- A mark-read that answers after a later mark-unread is dropped.
  acted('mark-read', 'ic-wisp-a1')
  raw_answer('mark-read', 'delay', '1')
  vim.api.nvim_feedkeys('m', 'x', false)
  acted('mark-unread', 'ic-wisp-a1')
  vim.api.nvim_feedkeys('u', 'x', false)
  vim.wait(1500)
  eq(rows(win)[1], ' ● imd-city  mayor  late read', 'unread, as the later call left it')
  eq(kept_files(), {}, 'and no copy kept by the dropped read')
  vim.fn.delete(vim.env.FAKE_GC_MAIL .. '/mark-read.delay')
  -- A mark-read that answers first does not hold back a later archive.
  vim.cmd('normal! j')
  raw_answer('archive', 'delay', '1')
  acted('archive', 'ic-wisp-a2')
  acted('mark-read', 'ic-wisp-a2')
  vim.api.nvim_feedkeys('m', 'x', false)
  vim.api.nvim_feedkeys('a', 'x', false)
  wait('archived', function()
    return #rows(win) == 1
  end, 3000)
  eq(rows(win), { ' ● imd-city  mayor  late read' }, 'the archive applied after the read')
  eq(kept_files(), {}, 'its kept copy went with it')
  vim.api.nvim_feedkeys('q', 'x', false)
end)

-- ---- the panel ---------------------------------------------------------------

local function panel()
  return require('gc_mail.panel')
end

-- The two cities in real directories (the fake answers by the last part of
-- the path, as for TWO), cached as the startup preload does. An event log
-- is written only where a test writes one.
local function city_dirs()
  local base = ('%s/cities-%d'):format(scratch, run_id)
  local cities = {}
  for _, dir in ipairs({ 'imd-city', 'side city' }) do
    vim.fn.mkdir(base .. '/' .. dir .. '/.gc', 'p')
    cities[#cities + 1] = { name = dir == 'side city' and 'side-city' or dir, path = base .. '/' .. dir }
  end
  write(vim.env.FAKE_GC_CITIES, cities_record(cities))
  preload()
  return cities, cities[1].path .. '/.gc/events.jsonl'
end

local function append(path, text)
  local file = assert(io.open(path, 'a'))
  file:write(text)
  file:close()
end

-- One event log line as gc writes it.
local function event(kind)
  return vim.json.encode({ seq = 1, type = kind, ts = '2026-10-08T10:00:00Z', actor = 'human', subject = 'ic-wisp-a1' }) .. '\n'
end

local function inbox_calls(path)
  return #vim.tbl_filter(function(c)
    return c[4] == 'inbox' and c[2] == path
  end, mail_calls())
end

-- Waits until the panel has listed each city once and nothing else runs.
local function listed(cities)
  wait('the panel listed every city', function()
    return inbox_calls(cities[1].path) >= 1 and inbox_calls(cities[2].path) >= 1
  end)
  vim.wait(200)
end

local function panel_key(win, lhs)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_win_get_buf(win), 'n')) do
    if map.lhs == lhs then
      return map.callback
    end
  end
  error('no panel mapping for ' .. lhs)
end

test('the panel opens below the current window without moving focus or the cursor, one per tab page', function()
  local cities, log = city_dirs()
  write(log, event('order.completed'))
  inbox('imd-city', { msg('ic-wisp-a1', { subject = 'first' }) })
  inbox('side city', {})
  buffer({ 'line one', 'line two', 'line three' })
  vim.api.nvim_win_set_cursor(0, { 2, 3 })
  local origin = vim.api.nvim_get_current_win()
  local origin_height = vim.api.nvim_win_get_height(origin)
  local win = panel().toggle()
  eq(vim.api.nvim_get_current_win(), origin, 'the current window is unchanged')
  eq(vim.api.nvim_win_get_cursor(origin), { 2, 3 }, 'the cursor is unchanged')
  eq(vim.api.nvim_get_mode().mode, 'n', 'still in normal mode')
  eq(#floats(), 0, 'a split, not a float')
  local below = vim.api.nvim_win_get_position(win)
  eq(below[1] > vim.api.nvim_win_get_position(origin)[1], true, 'below the current window')
  eq(below[2], vim.api.nvim_win_get_position(origin)[2], 'in its column')
  eq(vim.api.nvim_win_get_height(win), 10, 'panel_height rows')
  eq(vim.wo[win].winfixheight, true, 'fixed height')
  local buf = vim.api.nvim_win_get_buf(win)
  eq({ vim.bo[buf].buftype, vim.bo[buf].buflisted, vim.bo[buf].filetype }, { 'nofile', false, 'gcmail-panel' },
    'its own unlisted nofile buffer')
  eq(vim.api.nvim_win_get_height(origin) < origin_height, true, 'the split took rows from the current window')
  settled(win, 1)
  eq(rows(win), { ' ● imd-city  mayor  first' }, 'the mailbox lines')
  -- A mail arriving changes the panel, not the focus.
  inbox('imd-city', { msg('ic-wisp-a2', { subject = 'second', created_at = '2026-10-07T13:00:00Z' }),
    msg('ic-wisp-a1', { subject = 'first' }) })
  append(log, event('mail.sent'))
  wait('the new mail is shown', function()
    return #rows(win) == 2
  end)
  eq(rows(win), { ' ● imd-city  mayor  second', ' ● imd-city  mayor  first' }, 'newest first')
  eq(vim.api.nvim_win_get_cursor(win)[1], 2, 'the panel cursor stays on the message it was on')
  eq(vim.api.nvim_get_current_win(), origin, 'still the same window')
  eq(vim.api.nvim_win_get_cursor(origin), { 2, 3 }, 'still the same cursor')
  -- One per tab page: opening again keeps it; another tab page has its own.
  eq(panel().open(), win, 'the same panel')
  eq(#vim.api.nvim_tabpage_list_wins(0), 2, 'no second panel')
  vim.cmd('tabnew')
  local other = panel().toggle()
  eq(other ~= win and vim.api.nvim_win_get_tabpage(other) == vim.api.nvim_get_current_tabpage(), true, 'its own panel')
  settled(other, 2)
  vim.cmd('tabclose')
  eq(panel().running(), true, 'the first tab page still has its panel')
  eq(vim.api.nvim_get_current_win(), origin, 'back in the first tab page')
  panel().toggle()
  eq(vim.api.nvim_win_is_valid(win), false, 'the toggle closes it')
  eq(panel().running(), false, 'and stops the watch')
  eq(vim.api.nvim_get_current_win(), origin, 'focus never moved')
  -- :GcMailPanel toggles too.
  vim.cmd('GcMailPanel')
  eq(panel().win() ~= nil, true, ':GcMailPanel opens it')
  vim.cmd('GcMailPanel')
  eq(panel().win(), nil, ':GcMailPanel closes it')
end)

test('the panel lines equal the float\'s, and its keys act on the message under its cursor', function()
  local cities, log = city_dirs()
  write(log, '')
  inbox('imd-city', {
    msg('ic-wisp-a1', { subject = 'at noon', created_at = '2026-10-07T12:00:00Z' }),
    msg('ic-wisp-a2', { subject = 'at eleven', from = 'builder-1', created_at = '2026-10-07T11:00:00Z' }),
  })
  inbox('side city', { msg('sc-wisp-b1', { subject = 'side', created_at = '2026-10-07T11:30:00Z' }) })
  answer('read', { message = msg('ic-wisp-a1', { subject = 'at noon', read = true }) })
  local origin = vim.api.nvim_get_current_win()
  local pwin = panel().open()
  settled(pwin, 3)
  local fwin = mailbox().open()
  settled(fwin, 3)
  eq(rows(pwin), rows(fwin), 'the same lines')
  eq(rows(pwin), { ' ● imd-city  mayor  at noon', ' ● side-city  mayor  side', ' ● imd-city  builder-1  at eleven' }, 'lines')
  vim.api.nvim_feedkeys('q', 'x', false)
  -- <CR> in the panel opens the message in a window above it, never inside it.
  vim.api.nvim_win_set_cursor(pwin, { 1, 0 })
  vim.api.nvim_set_current_win(pwin)
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  local shown = vim.api.nvim_get_current_win()
  eq(shown ~= pwin and shown ~= origin, true, 'a new window')
  eq(vim.api.nvim_buf_get_lines(0, 0, 1, false), { '# at noon' }, 'the message under the panel cursor')
  eq(vim.api.nvim_win_get_position(shown)[1] < vim.api.nvim_win_get_position(pwin)[1], true, 'above the panel')
  eq(vim.bo[vim.api.nvim_win_get_buf(pwin)].filetype, 'gcmail-panel', 'the panel still shows the panel')
  eq(vim.api.nvim_win_get_height(pwin), 10, 'at its height')
  wait('marked read in both views', function()
    return rows(pwin)[1] == '   imd-city  mayor  at noon'
  end)
  eq(has_call(call('read', cities[1].path, 'ic-wisp-a1', '--json')), true, 'gc mail read')
  -- m and u from the panel without entering it.
  vim.api.nvim_win_set_cursor(pwin, { 2, 0 })
  acted('mark-read', 'sc-wisp-b1')
  panel_key(pwin, 'm')()
  wait('marked read', function()
    return rows(pwin)[2] == '   side-city  mayor  side'
  end)
  eq(has_call(call('mark-read', cities[2].path, 'sc-wisp-b1', '--json')), true, 'gc mail mark-read in its city')
  -- q in the panel closes it.
  vim.api.nvim_set_current_win(pwin)
  vim.api.nvim_feedkeys('q', 'x', false)
  eq(vim.api.nvim_win_is_valid(pwin), false, 'q closes the panel')
  eq(panel().running(), false, 'and stops the watch')
end)

test('a mail line in a city event log lists that city once after the debounce; other lines list nothing', function()
  local cities, log = city_dirs()
  write(log, event('order.completed'))
  inbox('imd-city', {})
  inbox('side city', {})
  local win = panel().open()
  listed(cities)
  eq({ inbox_calls(cities[1].path), inbox_calls(cities[2].path) }, { 1, 1 }, 'one listing each on open')
  append(log, event('order.completed') .. 'not json "mail.sent"\n' .. '{"seq":2,"note":"mail.sent"}\n'
    .. '["mail.sent"]\n' .. '{"type":7,"subject":"mail.sent"}\n' .. '{"type":"mailbox.x","subject":"mail."}\n'
    .. vim.json.encode({ type = vim.NIL, x = 'mail.' }) .. '\n' .. '{"type":"mail.sent"\n')
  vim.wait(1000)
  eq(inbox_calls(cities[1].path), 1, 'a non-mail or malformed line lists nothing')
  eq(vim.tbl_filter(function(note)
    return note.level == vim.log.levels.ERROR
  end, notes), {}, 'and says nothing')
  append(log, event('mail.sent'))
  vim.wait(250)
  eq(inbox_calls(cities[1].path), 1, 'not before the debounce')
  wait('listed after the debounce', function()
    return inbox_calls(cities[1].path) == 2
  end)
  vim.wait(800)
  eq({ inbox_calls(cities[1].path), inbox_calls(cities[2].path) }, { 2, 1 }, 'exactly one call, for that city only')
  -- A burst of mail events is one call.
  for _, kind in ipairs({ 'mail.read', 'mail.marked_read', 'mail.archived' }) do
    append(log, event(kind))
    vim.wait(30)
  end
  wait('the burst listed', function()
    return inbox_calls(cities[1].path) == 3
  end)
  vim.wait(800)
  eq(inbox_calls(cities[1].path), 3, 'one call for the burst')
  -- A line written in two parts counts once it ends.
  append(log, '{"seq":9,"type":"mail.del')
  vim.wait(800)
  eq(inbox_calls(cities[1].path), 3, 'half a line is not read yet')
  append(log, 'eted"}\n')
  wait('the finished line listed', function()
    return inbox_calls(cities[1].path) == 4
  end)
  -- More than 1 MiB appended at once is simply a refresh.
  append(log, string.rep('x', 1024 * 1024 + 10) .. '\n')
  wait('a huge append listed', function()
    return inbox_calls(cities[1].path) == 5
  end)
  vim.wait(800)
  eq(inbox_calls(cities[1].path), 5, 'once')
  eq(vim.api.nvim_win_is_valid(win), true, 'the panel stays open')
end)

test('at most one inbox call per city is in flight: mail during a call lists the city once more after it', function()
  local cities, log = city_dirs()
  write(log, '')
  inbox('imd-city', {})
  inbox('side city', {})
  panel().open()
  listed(cities)
  raw_answer('inbox', 'delay', '3', 'imd-city')
  append(log, event('mail.sent'))
  wait('the first call started', function()
    return inbox_calls(cities[1].path) == 2
  end)
  for _, kind in ipairs({ 'mail.read', 'mail.archived' }) do
    vim.wait(600) -- past the debounce, while the call still runs
    append(log, event(kind))
  end
  vim.wait(200)
  eq(inbox_calls(cities[1].path), 2, 'no second call while one is in flight')
  vim.fn.delete(vim.env.FAKE_GC_MAIL .. '/inbox.imd-city.delay')
  wait('one more call after it', function()
    return inbox_calls(cities[1].path) == 3
  end, 5000)
  vim.wait(800)
  eq(inbox_calls(cities[1].path), 3, 'exactly one more')
end)

test('a rotated or recreated event log is watched again; the old file no longer is', function()
  panel().configure({ rearm_ms = 200 })
  local cities, log = city_dirs()
  write(log, event('order.completed'))
  inbox('imd-city', {})
  inbox('side city', {})
  panel().open()
  listed(cities)
  local n = inbox_calls(cities[1].path)
  -- gc renames the log and starts a new one with an events.rotated line.
  assert(os.rename(log, log .. '.archive-1'))
  write(log, event('events.rotated'))
  wait('listed once after the rotation', function()
    return inbox_calls(cities[1].path) == n + 1
  end)
  vim.wait(800)
  n = inbox_calls(cities[1].path)
  append(log, event('mail.archived'))
  wait('the new file is watched', function()
    return inbox_calls(cities[1].path) == n + 1
  end)
  vim.wait(800)
  n = inbox_calls(cities[1].path)
  append(log .. '.archive-1', event('mail.sent'))
  vim.wait(1000)
  eq(inbox_calls(cities[1].path), n, 'the renamed file is not watched')
  -- Removed, and created again a moment later.
  assert(os.remove(log))
  vim.wait(50)
  write(log, '')
  wait('listed once the new file is watched', function()
    return inbox_calls(cities[1].path) == n + 1
  end)
  vim.wait(800)
  n = inbox_calls(cities[1].path)
  append(log, event('mail.sent'))
  wait('the recreated file is watched', function()
    return inbox_calls(cities[1].path) == n + 1
  end)
end)

test('with no event log the fallback timer lists every city, and watches the log once it appears', function()
  panel().configure({ poll_ms = 300 }) -- under setup's 15 s floor, for the test only
  local cities, log = city_dirs()
  inbox('imd-city', {})
  inbox('side city', {})
  panel().open()
  wait('the fallback timer lists both cities again', function()
    return inbox_calls(cities[1].path) >= 3 and inbox_calls(cities[2].path) >= 3
  end, 3000)
  local function watched()
    for _, h in ipairs(panel().handles()) do
      if h:get_type() == 'fs_event' and h:is_active() and h:getpath() == log then
        return true
      end
    end
    return false
  end
  eq(watched(), false, 'nothing to watch yet')
  write(log, '')
  wait('a tick watches the new log', watched, 2000)
end)

test('after close no watcher or timer fires and no callback touches the closed panel', function()
  panel().configure({ poll_ms = 300, rearm_ms = 100 })
  local cities, log = city_dirs()
  write(log, '')
  inbox('imd-city', {})
  inbox('side city', {})
  local win = panel().open()
  listed(cities)
  local handles = panel().handles()
  eq(#handles >= 6, true, 'a timer, two debounce and two rearm timers and a watcher: ' .. #handles)
  -- A mail event whose debounce is still waiting, and an inbox call in flight.
  raw_answer('inbox', 'delay', '0.5', 'side city')
  panel_key(win, 'R')()
  append(log, event('mail.sent'))
  vim.wait(50)
  local n = #mail_calls()
  panel().close()
  eq(vim.api.nvim_win_is_valid(win), false, 'closed')
  eq(panel().running(), false, 'the watch stopped')
  for i, h in ipairs(vim.list_extend(vim.list_slice(handles), panel().handles())) do
    eq(h:is_closing(), true, 'handle ' .. i .. ' closed')
  end
  append(log, event('mail.sent'))
  assert(os.rename(log, log .. '.old'))
  write(log, event('mail.sent'))
  vim.wait(1500)
  eq(#mail_calls(), n, 'nothing ran after close')
  eq(#floats(), 0, 'nothing opened')
  eq(#vim.api.nvim_list_wins(), 1, 'no panel came back')
end)

test('an archive from the panel also leaves the open float and survives a late inbox answer (I2)', function()
  local cities, log = city_dirs()
  write(log, '')
  inbox('imd-city', {
    msg('ic-wisp-a1', { subject = 'to archive', created_at = '2026-10-07T13:00:00Z' }),
    msg('ic-wisp-a2', { subject = 'stays', created_at = '2026-10-07T12:00:00Z' }),
  })
  inbox('side city', {})
  local pwin = panel().open()
  settled(pwin, 2)
  listed(cities)
  local fwin = mailbox().open()
  settled(fwin, 2)
  vim.wait(200)
  -- A panel refresh that answers late, with the message still in it.
  raw_answer('inbox', 'delay', '1', 'imd-city')
  local n = inbox_calls(cities[1].path)
  append(log, event('mail.sent'))
  wait('the panel refresh started', function()
    return inbox_calls(cities[1].path) == n + 1
  end)
  acted('archive', 'ic-wisp-a1')
  vim.api.nvim_win_set_cursor(pwin, { 1, 0 })
  panel_key(pwin, 'a')() -- the float keeps the focus
  wait('archived in both views', function()
    return #rows(pwin) == 1 and #rows(fwin) == 1
  end)
  eq(has_call(call('archive', cities[1].path, 'ic-wisp-a1', '--json')), true, 'gc mail archive')
  eq(rows(pwin), { ' ● imd-city  mayor  stays' }, 'panel')
  eq(rows(fwin), { ' ● imd-city  mayor  stays' }, 'float')
  vim.wait(1500) -- the refresh answers 1 s after it was made
  eq(rows(pwin), { ' ● imd-city  mayor  stays' }, 'the late answer does not bring it back to the panel')
  eq(rows(fwin), { ' ● imd-city  mayor  stays' }, 'nor to the float')
  eq(#floats(), 1, 'the float stayed open')
  vim.api.nvim_feedkeys('q', 'x', false)
end)

local failed = 0
for _, t in ipairs(tests) do
  reset()
  local ok, err = pcall(t.fn)
  if ok then
    io.stdout:write('ok   ' .. t.name .. '\n')
  else
    failed = failed + 1
    io.stdout:write('FAIL ' .. t.name .. '\n     ' .. tostring(err):gsub('\n', '\n     ') .. '\n')
  end
end
gc_mail.queue.stop()
vim.wait(5000, gc_mail.queue.idle, 10)
vim.fn.delete(scratch, 'rf')
io.stdout:write(('%d tests, %d failed\n'):format(#tests, failed))
os.exit(failed == 0 and 0 or 1)
