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

-- Short retry delays: no test waits on a real backoff.
local RETRY = { 40, 40, 40 }
local gc_mail, queue_dir
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
  package.loaded['gc_mail'] = nil
  package.loaded['gc_mail.queue'] = nil
  gc_mail = require('gc_mail')
  run_id = run_id + 1
  queue_dir = ('%s/state-%d/queue'):format(scratch, run_id)
  gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY })
end

local function reset(env)
  notes = {}
  for _, path in ipairs({ vim.env.FAKE_GC_LOG, vim.env.FAKE_GC_SENT, vim.env.FAKE_GC_COUNT }) do
    os.remove(path)
  end
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

test('nothing runs at load time and setup maps <Space>mm, :GcMail and :GcMailQueue', function()
  eq(recorded_argv(), nil, 'gc ran at load')
  eq(gc_mail.cached_cities(), nil, 'cities loaded at load time')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY })
  eq(gc_mail.cached_cities(), nil, 'setup ran gc cities before startup finished')
  eq(vim.fn.maparg('<Space>mm', 'n') ~= '', true, 'default keymap missing')
  eq(vim.fn.exists(':GcMail'), 2, ':GcMail missing')
  eq(vim.fn.exists(':GcMailQueue'), 2, ':GcMailQueue missing')
  -- After startup the list is preloaded in the background.
  wait('no preload after setup', function()
    return gc_mail.cached_cities() ~= nil
  end)
  eq(gc_mail.cached_cities(), TWO, 'preloaded cities')
  vim.keymap.del('n', '<Space>mm')
  gc_mail.setup({ keymap = false, state_dir = vim.fs.dirname(queue_dir) })
  eq(vim.fn.maparg('<Space>mm', 'n'), '', 'keymap = false still mapped')
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
  eq(notes[#notes].message, 'gc-mail: queued for side-city mayor', 'queued notice')
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
  assert(notes[1].message:find('^gc%-mail: queued for imd%-city mayor; the buffer was left as it is %(cannot clear it: .*E21'),
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
