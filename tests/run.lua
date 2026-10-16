-- Headless tests for gc-mail.nvim. From the repository root:
--   nvim --headless --clean -n -l tools/gc-mail.nvim/tests/run.lua
-- A fake gc (tests/bin/gc) is first on PATH; the real gc never runs. Each test
-- gets a fresh module and its own queue directory under a scratch dir, which
-- is also XDG_STATE_HOME, so the real queue is never touched.
local here = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, 'S').source:sub(2)))
local root = vim.fs.dirname(here)
vim.opt.runtimepath:prepend(root)
-- Load plugin/ as startup would: it defines the seven commands, and
-- setup() no longer repeats them.
vim.cmd('runtime! plugin/gc_mail.lua')
package.path = root .. '/?.lua;' .. package.path

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

local TWO = { { name = 'demo-city', path = '/srv/demo-city' }, { name = 'other-city', path = '/srv/other city' } }

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
  if package.loaded['gc_mail.watch'] then
    pcall(package.loaded['gc_mail.watch'].reset)
  end
  if package.loaded['gc_mail.chat'] and package.loaded['gc_mail.chat'].reset then
    pcall(package.loaded['gc_mail.chat'].reset)
  end
  if package.loaded['gc_mail.events'] then
    pcall(package.loaded['gc_mail.events'].reset)
  end
  package.loaded['gc_mail.preview'] = nil
  if package.loaded['gc_mail.mailbox'] then
    package.loaded['gc_mail.mailbox'].stop_check()
  end
  package.loaded['gc_mail'] = nil
  package.loaded['gc_mail.queue'] = nil
  package.loaded['gc_mail.mailbox'] = nil
  package.loaded['gc_mail.panel'] = nil
  package.loaded['gc_mail.chat'] = nil
  package.loaded['gc_mail.events'] = nil
  package.loaded['gc_mail.watch'] = nil
  package.loaded['gc_mail.history'] = nil
  gc_mail = require('gc_mail')
  -- The preview pane has its own tests; the others count windows and floats.
  gc_mail.config.preview = false
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
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, watch = false })
  eq(gc_mail.cached_cities(), nil, 'setup ran gc cities before startup finished')
  eq(vim.fn.maparg('<Space>mm', 'n') ~= '', true, 'default keymap missing')
  eq(vim.fn.exists(':GcMail'), 2, ':GcMail missing')
  eq(vim.fn.exists(':GcMailQueue'), 2, ':GcMailQueue missing')
  eq(vim.fn.exists(':GcMailbox'), 2, ':GcMailbox missing')
  eq(vim.fn.maparg('<Space>mi', 'n') ~= '', true, 'default mailbox keymap missing')
  eq(vim.fn.exists(':GcMailPanel'), 2, ':GcMailPanel missing')
  eq(vim.fn.maparg('<Space>mp', 'n') ~= '', true, 'default panel keymap missing')
  eq(vim.fn.exists(':GcMailChat'), 2, ':GcMailChat missing')
  eq(vim.fn.exists(':GcMailChats'), 2, ':GcMailChats missing')
  eq(vim.fn.exists(':GcMailSearch'), 2, ':GcMailSearch missing')
  eq(vim.fn.maparg('<Space>ml', 'n') ~= '', true, 'default chats keymap missing')
  eq(vim.fn.maparg('<Space>mc', 'n') ~= '', true, 'default chat keymap missing')
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
  vim.keymap.del('n', '<Space>mc')
  vim.keymap.del('n', '<Space>ml')
  gc_mail.setup({ keymap = false, mailbox_keymap = false, panel_keymap = false, chat_keymap = false, chats_keymap = false, state_dir = vim.fs.dirname(queue_dir) })
  eq(vim.fn.maparg('<Space>mm', 'n'), '', 'keymap = false still mapped')
  eq(vim.fn.maparg('<Space>mi', 'n'), '', 'mailbox_keymap = false still mapped')
  eq(vim.fn.maparg('<Space>mp', 'n'), '', 'panel_keymap = false still mapped')
  eq(vim.fn.maparg('<Space>mc', 'n'), '', 'chat_keymap = false still mapped')
  eq(vim.fn.maparg('<Space>ml', 'n'), '', 'chats_keymap = false still mapped')
  eq(package.loaded['gc_mail.panel'], nil, 'setup loaded the panel')
  eq(package.loaded['gc_mail.events'], nil, 'setup loaded events')
  eq(package.loaded['gc_mail.history'], nil, 'history loaded at load time')
  eq(package.loaded['gc_mail.chat'], nil, 'chat loaded at load time')
  eq(package.loaded['gc_mail.search'], nil, 'search loaded at load time')
  local bad_zero = pcall(gc_mail.setup, { history_days = 0 })
  eq(bad_zero, false, 'setup refuses history_days = 0')
  local bad_str = pcall(gc_mail.setup, { history_days = 'x' })
  eq(bad_str, false, 'setup refuses history_days = x')
  local bad_cw = pcall(gc_mail.setup, { chat_width = 10 })
  eq(bad_cw, false, 'setup refuses chat_width = 10')
  local bad_ch = pcall(gc_mail.setup, { chat_compose_height = 0 })
  eq(bad_ch, false, 'setup refuses chat_compose_height = 0')
  local bad_cs = pcall(gc_mail.setup, { chat_send_keys = 'x' })
  eq(bad_cs, false, 'setup refuses chat_send_keys = "x"')
  local bad_ck, bad_ck_err = pcall(gc_mail.setup, { chat_keymap = '' })
  eq(bad_ck, false, 'setup refuses chat_keymap = ""')
  assert(tostring(bad_ck_err):find('chat_keymap', 1, true), 'the refusal names chat_keymap')
  eq(vim.fn.exists(':GcMail'), 2, ':GcMail missing without a keymap')
  gc_mail.setup({ keymap = '<leader>gm', state_dir = vim.fs.dirname(queue_dir) })
  eq(vim.fn.maparg('<leader>gm', 'n') ~= '', true, 'custom keymap missing')
  eq(recorded_argv(), nil, 'mail was sent during setup')
  -- The defaults keep the queue under stdpath('state') (here the scratch XDG dir).
  package.loaded['gc_mail'] = nil
  package.loaded['gc_mail.queue'] = nil
  local defaults = require('gc_mail')
  eq(defaults.config.state_dir .. '/queue', vim.env.XDG_STATE_HOME .. '/nvim/gc-mail/queue', 'default queue dir')
  gc_mail = defaults
  gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY })
end)

test('the seven commands exist in a child nvim that has not run setup()', function()
  -- fresh() keeps the commands setup() used to define, so only a child that
  -- has never run setup() can prove plugin/ defines them on its own.
  local check = "local ok, err = pcall(function() "
    .. "for _, name in ipairs({ 'GcMail', 'GcMailQueue', 'GcMailbox', 'GcMailPanel', 'GcMailChat', 'GcMailChats', 'GcMailSearch' }) do "
    .. "assert(vim.fn.exists(':' .. name) == 2, name .. ' missing') end "
    .. "assert(package.loaded['gc_mail'] == nil, 'the module loaded') end) "
    .. "if not ok then io.stderr:write(tostring(err) .. '\\n'); vim.cmd('cquit 1') end"
  local result = vim.system({ vim.v.progpath, '--headless', '--clean', '-n',
    '--cmd', ('lua vim.opt.runtimepath:prepend(%q)'):format(root),
    '-c', 'lua ' .. check, '-c', 'qa!' }, { text = true }):wait(20000)
  eq(result.code, 0, 'child nvim: ' .. (result.stderr or '') .. (result.stdout or ''))
end)

test('the picker lists one line per city mayor, even for a single city', function()
  preload()
  buffer({ 'hello' })
  local win = gc_mail.open()
  eq(#floats(), 1, 'picker window')
  eq(lines_of(win), { ' demo-city  mayor ', ' other-city  mayor ' }, 'picker lines')
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
    return vim.deep_equal(lines_of(win), { ' demo-city  mayor ' })
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
    return vim.deep_equal(lines_of(win), { ' demo-city  mayor ', ' other-city  mayor ' })
  end)
  eq(vim.api.nvim_win_get_height(win), 2, 'resized to the cities')
  -- The next open shows the cached list at once while gc runs again.
  vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'x', false)
  win = gc_mail.open()
  eq(lines_of(win), { ' demo-city  mayor ', ' other-city  mayor ' }, 'cached list at once')
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
  eq(notes[#notes].message, 'gc-mail: queued for other-city mayor: Deploy plan for tomorrow', 'queued notice')
  local record = vim.json.decode(read_file(queue_dir .. '/' .. spool()[1]))
  eq({ record.city, record.subject, type(record.created) }, { TWO[2], 'Deploy plan for tomorrow', 'number' }, 'queue record')
  wait('sent and removed', drained)
  eq(recorded_argv(), { '--city', '/srv/other city', 'mail', 'send', 'mayor', '-s', 'Deploy plan for tomorrow',
    '-m', '\n  Deploy plan for tomorrow  \nstep one\n\nstep "two" $(not run)', '--notify' }, 'argv')
  eq(notes[#notes].message, 'gc-mail: sent to other-city mayor', 'success notice')
  -- The clear is one undo step: u brings the text back.
  vim.cmd('silent undo')
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { '', '  Deploy plan for tomorrow  ', 'step one', '', 'step "two" $(not run)' },
    'undo restores the text')
end)

test(':GcMail planner queues a record with to = planner and sends the exact argv', function()
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY })
  local buf = buffer({ 'hello planner', 'here is the task' })
  preload()
  vim.cmd('GcMail planner')
  local picker_win = floats()[1]
  assert(picker_win, 'picker opened')
  eq(vim.api.nvim_win_get_config(picker_win).title[1][1], ' mail buffer to planner in ', 'picker title with to')
  eq(lines_of(picker_win), { ' demo-city  planner ', ' other-city  planner ' }, 'picker items with to')
  vim.api.nvim_feedkeys(vim.keycode('j<CR>'), 'x', false)
  eq(#floats(), 0, 'picker closes on <CR>')
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { '' }, 'buffer cleared')
  eq(notes[#notes].message, 'gc-mail: queued for other-city planner: hello planner', 'queued notice')
  local record = vim.json.decode(read_file(queue_dir .. '/' .. spool()[1]))
  eq(record.to, 'planner', 'queue record has to = planner')
  wait('sent and removed', drained)
  eq(recorded_argv(), { '--city', '/srv/other city', 'mail', 'send', 'planner', '-s', 'hello planner',
    '-m', 'hello planner\nhere is the task', '--notify' }, 'exact argv with planner')
  eq(notes[#notes].message, 'gc-mail: sent to other-city planner', 'success notice')
end)

test('a record file with invalid to is listed as unreadable and never sent; M.send refuses bad to', function()
  gc_mail.queue.stop()
  local good = { version = 1, city = TWO[1], subject = 's', body = 'b', created = 1, attempts = 0, next_at = 0, failed = false }
  local cases = {
    { '--all', 'bad to' },
    { 'ctrl\x01char', 'bad to' },
    { '', 'bad to' },
    { string.rep('x', 101), 'bad to' },
  }
  vim.fn.mkdir(queue_dir, 'p')
  for i, case in ipairs(cases) do
    local record = vim.deepcopy(good)
    record.to = case[1]
    write(('%s/%016d-00001-%08x.json'):format(queue_dir, i, i), vim.json.encode(record))
  end
  local valid = assert(gc_mail.queue.add(TWO[2], { subject = 'fine', body = 'ok' }))
  local entries = gc_mail.queue.list()
  for i, case in ipairs(cases) do
    eq({ entries[i].record, entries[i].error }, { nil, 'not a gc-mail message: ' .. case[2] }, 'case ' .. case[1])
  end
  eq(entries[#cases + 1].id, valid, 'valid message listed')
  gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY })
  gc_mail.queue.pump()
  wait('the valid one sent', function()
    return #sent() == 1 and gc_mail.queue.idle()
  end)
  eq(sent(), { '/srv/other city|fine' }, 'only the valid message was sent')

  -- M.send(buf, city, { to = '-x' }) is refused and the buffer unchanged
  notes = {}
  local buf = buffer({ 'keep this line', 'and this' })
  local ret = gc_mail.send(buf, TWO[1], { to = '-x' })
  eq(ret, nil, 'send refused')
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'keep this line', 'and this' }, 'buffer unchanged')
  eq(notes[#notes].message, 'gc-mail: cannot queue the message: bad to', 'refusal notice')
end)

test('shared text and address helpers give the answers their callers rely on', function()
  local queue = gc_mail.queue
  local mailbox = require('gc_mail.mailbox')
  local events = require('gc_mail.events')
  -- queue.CONTROL matches exactly the control characters, nothing else.
  for _, bad in ipairs({ string.char(0), string.char(1), string.char(31), string.char(127), '\n', '\t' }) do
    eq(('a' .. bad .. 'b'):find(queue.CONTROL) ~= nil, true, 'CONTROL matches ' .. vim.inspect(bad))
  end
  eq(('plain text 123'):find(queue.CONTROL), nil, 'CONTROL leaves plain text')
  -- queue.address_ok is the one to/with rule: non-empty, at most 100 bytes,
  -- no control character and no leading dash, for strings only.
  eq(queue.address_ok('mayor'), true, 'a plain address passes')
  eq(queue.address_ok(string.rep('x', 100)), true, '100 bytes passes')
  eq(queue.address_ok(string.rep('x', 101)), false, '101 bytes fails')
  eq(queue.address_ok(''), false, 'empty fails')
  eq(queue.address_ok('-x'), false, 'a leading dash fails')
  eq(queue.address_ok('a-b'), true, 'an inner dash passes')
  eq(queue.address_ok('a' .. string.char(1) .. 'b'), false, 'a control character fails')
  eq(queue.address_ok(nil), false, 'nil fails')
  eq(queue.address_ok(42), false, 'a number fails')
  -- queue.whole is the shared whole-number rule, without the 2^53 bound its
  -- mailbox callers add themselves.
  eq(queue.whole(0), true, 'zero is whole')
  eq(queue.whole(7), true, 'a whole number passes')
  eq(queue.whole(2 ^ 53), true, 'whole itself has no 2^53 bound')
  eq(queue.whole(1.5), false, 'a fraction fails')
  eq(queue.whole(-1), false, 'a negative fails')
  eq(queue.whole('7'), false, 'a string fails')
  eq(queue.whole(nil), false, 'whole nil fails')
  -- mailbox.key_of joins city path and id with one NUL, for every caller.
  eq(mailbox.key_of({ path = '/srv/demo-city' }, 'ic-wisp-a1'), '/srv/demo-city\0ic-wisp-a1', 'the message key')
  eq(mailbox.key_of({ path = '/srv/demo-city' }, 'mayor'), '/srv/demo-city\0mayor', 'the correspondent key')
  eq(mailbox.key_of({ path = '/srv/other' }, 'ic-wisp-a1') == mailbox.key_of({ path = '/srv/demo-city' }, 'ic-wisp-a1'),
    false, 'the city is part of the key')
  -- mailbox.md_escape escapes markdown markup (and the backslash) only, and
  -- mailbox.body_lines splits a body verbatim, nil as empty.
  eq(mailbox.md_escape('plain text'), 'plain text', 'plain text is not escaped')
  eq(mailbox.md_escape('*a* [b] #c a|b `d` _e_ <f> g\\h'), '\\*a\\* \\[b\\] \\#c a\\|b \\`d\\` \\_e\\_ \\<f\\> g\\\\h',
    'markup is escaped')
  eq(mailbox.md_escape('one\ntwo'), 'one / two', 'a line break becomes one line')
  eq(mailbox.body_lines('a\nb\n'), { 'a', 'b', '' }, 'body lines verbatim')
  eq(mailbox.body_lines(''), { '' }, 'an empty body is one empty line')
  eq(mailbox.body_lines(nil), { '' }, 'a nil body is one empty line')
  -- gc_mail.strip_label takes every copy of the prefix and suffix out and
  -- trims; gc_mail.label puts them back exactly once.
  local labelled = { subject_prefix = '[A] ', subject_suffix = ' (x)' }
  eq(gc_mail.strip_label('[A] [A] hi (x) (x)', labelled), 'hi', 'every copy is stripped')
  eq(gc_mail.strip_label('  hi  ', { subject_prefix = '', subject_suffix = '' }), 'hi', 'stripping trims')
  eq(gc_mail.strip_label(nil, labelled), '', 'a nil subject strips to empty')
  eq(gc_mail.label('[A] hi (x)', labelled), '[A] hi (x)', 'the label is applied once')
  -- The one notify helper: gc_mail.notify is queue.notify, it adds the
  -- gc-mail: prefix and defaults to INFO.
  eq(gc_mail.notify, queue.notify, 'one shared notify helper')
  notes = {}
  queue.notify('hello')
  queue.notify('oops', vim.log.levels.ERROR)
  eq(notes, { { message = 'gc-mail: hello', level = vim.log.levels.INFO },
    { message = 'gc-mail: oops', level = vim.log.levels.ERROR } }, 'the prefix and the levels')
  -- events.close_handle stops and closes a live handle once, and leaves a
  -- closing handle and nil alone.
  local calls = {}
  local live = { closing = false }
  function live:is_closing()
    return self.closing
  end
  function live:stop()
    calls[#calls + 1] = 'stop'
  end
  function live:close()
    calls[#calls + 1] = 'close'
    self.closing = true
  end
  events.close_handle(live)
  eq(calls, { 'stop', 'close' }, 'a live handle is stopped then closed')
  events.close_handle(live)
  eq(calls, { 'stop', 'close' }, 'a closing handle is left alone')
  eq(pcall(events.close_handle, nil), true, 'no handle is fine')
end)

test('a record without to still sends to mayor', function()
  gc_mail.queue.stop()
  local old_record = { version = 1, city = TWO[1], subject = 'legacy mail', body = 'legacy body', created = 1, attempts = 0, next_at = 0, failed = false }
  vim.fn.mkdir(queue_dir, 'p')
  write(queue_dir .. '/0000000000000001-00001-00000001.json', vim.json.encode(old_record))
  gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY })
  gc_mail.queue.pump()
  wait('legacy sent', drained)
  eq(recorded_argv(), { '--city', '/srv/demo-city', 'mail', 'send', 'mayor', '-s', 'legacy mail',
    '-m', 'legacy body', '--notify' }, 'sent to mayor')
end)

test('queue.subscribe: a subscriber runs after add, after successful send and after failed send, and errors do not stop send', function()
  local events = {}
  local count = 0
  gc_mail.queue.subscribe('test_sub', function()
    count = count + 1
    events[#events + 1] = { count = count, spool = spool() }
  end)
  gc_mail.queue.subscribe('broken_sub', function()
    error('subscriber failure')
  end)

  -- 1. Add
  local id = assert(gc_mail.queue.add(TWO[1], { subject = 'sub-test', body = 'body' }))
  wait('subscriber saw add', function()
    return #events >= 1
  end)
  eq(#events[1].spool, 1, 'subscriber saw queued file on disk after add')

  -- 2. Successful send (file gone)
  gc_mail.queue.pump()
  wait('sent and drained', drained)
  wait('subscriber saw delete', function()
    return #events >= 2
  end)
  eq(#events[#events].spool, 0, 'subscriber saw file gone after success')
  eq(sent(), { '/srv/demo-city|sub-test' }, 'message was sent despite broken subscriber')

  local sub_errors = vim.tbl_filter(function(n)
    return n.message:find('subscriber broken_sub failed')
  end, notes)
  eq(#sub_errors, 1, 'broken subscriber error shown once')

  -- 3. Failed send (file rewritten)
  reset({ FAKE_GC_FAIL_TIMES = '1' })
  events = {}
  gc_mail.queue.subscribe('test_sub', function()
    local sp = spool()
    local rec
    if #sp > 0 then
      rec = vim.json.decode(read_file(queue_dir .. '/' .. sp[1]))
    end
    events[#events + 1] = { spool = sp, record = rec }
  end)
  assert(gc_mail.queue.add(TWO[1], { subject = 'fail-test', body = 'body' }))
  wait('subscriber saw add', function()
    return #events >= 1
  end)
  gc_mail.queue.pump()
  wait('subscriber saw failure outcome', function()
    return #events >= 2 and events[#events].record and events[#events].record.attempts > 0
  end)
  local last = events[#events]
  eq(#last.spool, 1, 'file still in spool')
  eq(last.record.attempts, 1, 'file was rewritten with attempts = 1')
  eq(last.record.failed, false, 'not failed yet')
  assert(last.record.last_error:find('exit 1'), 'last_error written')

  -- Unsubscribe removes subscriber
  gc_mail.queue.subscribe('test_sub', nil)
  events = {}
  assert(gc_mail.queue.add(TWO[1], { subject = 'after unsub', body = 'body' }))
  vim.wait(100)
  eq(#events, 0, 'subscriber did not run after unsubscribe')
end)

test('fs.list: a missing directory lists as empty, and a written file lists back', function()
  local fs = require('gc_mail.fs')
  local dir = scratch .. '/fs-list-' .. run_id
  eq(fs.list(dir), {}, 'missing directory')
  assert(fs.ensure_dir(dir))
  write(dir .. '/a.txt', 'x')
  eq(fs.list(dir), { 'a.txt' }, 'listed')
end)

test('fs: stage plus commit leaves a 0600 file with the text and no temp file', function()
  local fs = require('gc_mail.fs')
  local dir = scratch .. '/fs-stage-' .. run_id
  assert(fs.ensure_dir(dir))
  local temp = assert(fs.stage(dir, 'note.json', '{"a":1}'))
  eq(fs.commit(temp, dir .. '/note.json'), true, 'committed')
  eq(read_file(dir .. '/note.json'), '{"a":1}', 'the text is there whole')
  eq(vim.uv.fs_stat(dir .. '/note.json').mode % 512, 384, 'mode 0600')
  eq(vim.tbl_filter(function(name)
    return name:find('%.tmp$') ~= nil
  end, vim.fn.readdir(dir)), {}, 'no temp file left')
  eq(fs.read(dir .. '/note.json'), '{"a":1}', 'read back')
end)

test('fs: a failed write leaves no temp file', function()
  local fs = require('gc_mail.fs')
  local dir = scratch .. '/fs-fail-' .. run_id
  assert(fs.ensure_dir(dir))
  local real_write = vim.uv.fs_write
  vim.uv.fs_write = function()
    return nil, 'ENOSPC: no space left on device'
  end
  local ok, temp, err = pcall(fs.stage, dir, 'note.json', 'x')
  vim.uv.fs_write = real_write
  assert(ok, temp)
  eq({ temp, err }, { nil, 'ENOSPC: no space left on device' }, 'stage refused')
  eq(vim.fn.readdir(dir), {}, 'no temp file left')
end)

test('fs.ensure_dir: a mkdir failure keeps the plain text and the raised detail apart', function()
  local fs = require('gc_mail.fs')
  local dir = scratch .. '/fs-mkdir-' .. run_id .. '/inner'
  local real_mkdir = vim.fn.mkdir
  vim.fn.mkdir = function()
    error('Vim:E739: Cannot create directory ' .. dir .. ': permission denied', 0)
  end
  local ok, err, detail = fs.ensure_dir(dir)
  vim.fn.mkdir = real_mkdir
  eq(ok, nil, 'ensure_dir refused')
  eq(err, 'cannot create ' .. dir, 'plain text')
  eq(detail, 'Vim:E739: Cannot create directory ' .. dir .. ': permission denied', 'detail apart')
  -- No raise, made == 0: the same plain text and no detail.
  vim.fn.mkdir = function()
    return 0
  end
  local ok2, err2, detail2 = fs.ensure_dir(dir)
  vim.fn.mkdir = real_mkdir
  eq({ ok2, err2, detail2 }, { nil, 'cannot create ' .. dir, nil }, 'made 0')
end)

test('the queue mkdir failure keeps the Vim detail; fs keeps it apart', function()
  local bad_dir = scratch .. '/queue-mkdir-' .. run_id .. '/queue'
  gc_mail.queue.configure({ dir = bad_dir, retry_ms = RETRY })
  local real_mkdir = vim.fn.mkdir
  vim.fn.mkdir = function()
    error('Vim:E739: Cannot create directory ' .. bad_dir .. ': permission denied', 0)
  end
  local id, err = gc_mail.queue.add(TWO[1], { subject = 'x', body = 'y' })
  vim.fn.mkdir = real_mkdir
  eq(id, nil, 'not queued')
  eq(err, 'cannot write the queue file: cannot create ' .. bad_dir
    .. ': Vim:E739: Cannot create directory ' .. bad_dir .. ': permission denied', 'queue detail kept')
end)

test('a queue entry that does not parse keeps its raw text on the entry', function()
  gc_mail.queue.stop()
  vim.fn.mkdir(queue_dir, 'p')
  write(queue_dir .. '/0000000000000007-00001-00000007.json', 'not json at all')
  local entries = gc_mail.queue.list()
  eq(#entries, 1, 'one entry')
  eq(entries[1].record, nil, 'no record')
  eq(entries[1].raw, 'not json at all', 'raw text kept')
  eq(gc_mail.queue.raw, nil, 'M.raw is gone')
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
  eq(sent(), { '/srv/demo-city|flaky store', '/srv/demo-city|flaky store', '/srv/demo-city|flaky store' }, 'three tries')
  local errors = vim.tbl_filter(function(note)
    return note.level == vim.log.levels.ERROR
  end, notes)
  eq(#errors, 1, 'the error is shown once')
  eq(errors[1].message, 'gc-mail: send to demo-city mayor failed (exit 1):\ngc mail send: store unavailable (try 1); retrying in the background',
    'failure notice')
  eq(notes[#notes].message, 'gc-mail: sent to demo-city mayor', 'sent in the end')

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
  eq(notes[#notes].message, 'gc-mail: gave up sending to demo-city mayor after 4 tries; :GcMailQueue to retry', 'give-up notice')
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
  eq(sent(), { '/srv/demo-city|first', '/srv/demo-city|second', '/srv/other city|to another city' }, 'order')
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
  assert(notes[1].message:find('^gc%-mail: queued for demo%-city mayor: locked text; the buffer was left as it is %(cannot clear it: .*E21'),
    notes[1].message)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'locked text' }, 'buffer changed')
  eq(vim.bo[buf].modified, true, 'modified flag changed')
  wait('sent', drained)
  eq(sent(), { '/srv/demo-city|locked text' }, 'sent once')
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

  -- A failing gc that says why on stderr: the detail follows on its own line.
  reset({ FAKE_GC_CITIES_EXIT = '1', FAKE_GC_STDERR = 'registry broken\nsecond line' })
  buffer({ 'hello' })
  gc_mail.open()
  wait('picker left open on gc stderr failure', function()
    return #floats() == 0
  end)
  eq(notes[#notes].message, 'gc-mail: gc cities failed:\nregistry broken\nsecond line', 'cities stderr notice')

  -- With a good list cached, a failing refresh keeps it and says so once.
  reset()
  preload()
  buffer({ 'hello' })
  vim.env.FAKE_GC_CITIES_EXIT = '1'
  for _ = 1, 2 do
    local win = gc_mail.open()
    eq(lines_of(win), { ' demo-city  mayor ', ' other-city  mayor ' }, 'last good list')
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
    cities_record({ { name = 'demo\ncity', path = '/srv/demo-city' } }),
    cities_record({ { name = 'demo-city', path = '/srv/demo\tcity' } }),
    cities_record({ { name = 'demo\127city', path = '/srv/demo-city' } }),
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
    eq(lines_of(win), { ' demo-city  mayor ', ' other-city  mayor ' }, 'last good list')
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
  local done, cities, err
  gc_mail.refresh(function(c, e)
    done, cities, err = true, c, e
  end, 200)
  wait('cities from a hung gc never arrived', function()
    return done
  end)
  eq(cities, nil, 'cities from a hung gc')
  eq(err, 'gc cities did not answer within 0.2 s', 'timeout reason')
  assert((vim.uv.hrtime() - started) / 1e6 < 5000, 'waited for the hung gc to finish')

  -- A child whose answer never arrives (a nil result): the same reason.
  local system = vim.system
  vim.system = function(_, _, cb)
    cb(nil)
    return {}
  end
  local nil_done, nil_result
  gc_mail.refresh(function(c, e)
    nil_done, nil_result = true, { c, e }
  end, 200)
  vim.system = system
  wait('nil result never arrived', function()
    return nil_done
  end)
  eq(nil_result, { nil, 'gc cities did not answer within 0.2 s' }, 'nil result')

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

test('gc.run reports exit 0, a timeout, an exit with stderr and a spawn failure', function()
  local gc = require('gc_mail.gc')
  local function run_once(argv, timeout_ms, what)
    local done, result, err
    gc.run(argv, timeout_ms, what, function(r, e)
      done, result, err = true, r, e
    end)
    wait('gc.run never finished', function()
      return done
    end)
    return result, err
  end

  reset()
  local result, err = run_once({ 'gc', 'cities', '--json' }, 10000, 'gc cities')
  eq(err, nil, 'exit 0 reason')
  eq(result.code, 0, 'exit 0 code')
  eq(vim.json.decode(vim.trim(result.stdout)).ok, true, 'exit 0 answer')

  reset({ FAKE_GC_CITIES_HANG = '5' })
  result, err = run_once({ 'gc', 'cities', '--json' }, 200, 'gc cities')
  eq(result, nil, 'timeout result')
  eq(err, 'gc cities did not answer within 0.2 s', 'timeout reason')

  reset({ FAKE_GC_EXIT = '3', FAKE_GC_STDERR = 'store unavailable' })
  result, err = run_once({ 'gc', '--city', '/srv/demo-city', 'mail', 'send', 'mayor', '-s', 'x', '-m', 'y' },
    10000, 'gc mail send in demo-city')
  eq(result.code, 3, 'failed code')
  eq(err, 'gc mail send in demo-city failed: store unavailable', 'exit reason')

  reset({ FAKE_GC_CITIES_EXIT = '1' })
  result, err = run_once({ 'gc', 'cities', '--json' }, 10000, 'gc cities')
  eq(result.code, 1, 'silent failure code')
  eq(err, 'gc cities failed (exit 1)', 'silent exit reason')

  local system = vim.system
  vim.system = function()
    error('gc is not here', 0)
  end
  result, err = run_once({ 'gc', 'cities', '--json' }, 10000, 'gc cities')
  vim.system = system
  eq(result, nil, 'spawn failure result')
  eq(err, 'cannot run gc (is it on PATH?): gc is not here', 'spawn failure reason')
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
  eq(sent(), { '/srv/demo-city|left mid-send', '/srv/demo-city|left pending' }, 'resent in order')
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
  assert(lines[1]:find('^ demo%-city  still pending  %d+s  pending $'), lines[1])
  eq(lines[2], ' other-city  gave up  2m  failed  exit 3: mayor not found ', 'failed line')
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
  eq(lines_of(floats()[1]), { ' other-city  gave up  2m  failed  exit 3: mayor not found ' }, 'list after delete')

  -- r sends a failed message again.
  gc_mail.queue.configure({ dir = queue_dir, retry_ms = RETRY })
  vim.api.nvim_feedkeys('r', 'x', false)
  wait('retried', drained)
  eq(sent(), { '/srv/other city|gave up' }, 'retry sent it')
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
  eq(sent(), { '/srv/demo-city|held' }, 'sent once')
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
    eq(sent(), { '/srv/demo-city|first' }, 'sent anything while held')
    wait('claim put back', function()
      return back_fails == 0 and #claims() == 0
    end)
  end)
  wait('all sent', drained)
  -- Its retry delay ran out during the hold, and it is the oldest.
  eq(sent(), { '/srv/demo-city|first', '/srv/demo-city|first', '/srv/other city|other city' }, 'resent once, then the next')
  eq(#errors_matching('cannot record the failed send to demo-city mayor (ENOSPC'), 1, 'the hold is shown once')
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
    eq(sent(), { '/srv/demo-city|delivered' }, 'sent anything while held')
    wait('removed', function()
      return unlink_fails == 0 and #claims() == 0
    end)
  end)
  wait('all sent', drained)
  eq(sent(), { '/srv/demo-city|delivered', '/srv/other city|next' }, 'each once')
  eq(#errors_matching('sent to demo-city mayor, but cannot remove its queue file (EACCES: permission denied); it is marked sent'),
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
  eq(sent(), { '/srv/demo-city|once only' }, 'a delivered message was sent again')
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
      eq(sent(), { '/srv/demo-city|delivered' }, 'sent anything while held')
      hold = false
    end)
  end)
  wait('removed', drained)
  eq(sent(), { '/srv/demo-city|delivered' }, 'sent once')
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
      eq(sent(), { '/srv/demo-city|failed once' }, 'resent while held')
      hold = false
    end)
  end)
  wait('retried and removed', drained)
  eq(sent(), { '/srv/demo-city|failed once', '/srv/demo-city|failed once' }, 'one retry')
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
        eq(sent(), { '/srv/demo-city|stuck' }, 'sent anything while held')
        hold = false
      end)
    end)
  end)
  wait('removed', drained)
  eq(sent(), { '/srv/demo-city|stuck' }, 'sent once')
  eq(#errors_matching('cannot keep the claim on the message to demo-city mayor young (EPERM: operation not permitted; ENOSPC: no space left on device); another Neovim may send it again after 240 s'),
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
  eq(sent(), { '/srv/other city|fine' }, 'sent')
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
  eq(sent(), { '/srv/demo-city|fails once', '/srv/demo-city|fails once', '/srv/demo-city|retried', '/srv/demo-city|again' },
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
  eq(sent(), { '/srv/demo-city|already queued' }, 'sent after recovery')
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
  if cmd == 'thread' and record.messages then
    local bd_list = {}
    for _, tm in ipairs(record.messages) do
      bd_list[#bd_list + 1] = {
        id = tm.id,
        title = tm.subject,
        sender = tm.from,
        assignee = tm.to,
        status = tm.closed and 'closed' or 'open',
        created_at = tm.created_at,
        description = tm.body,
        labels = (record.thread_id or tm.thread_id) and { 'thread:' .. (record.thread_id or tm.thread_id) } or {},
      }
    end
    write(vim.env.FAKE_GC_MAIL .. '/bd-list' .. (city and ('.' .. city) or '') .. '.json', vim.json.encode(bd_list) .. '\n')
  end
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
  inbox('demo-city', {
    msg('ic-wisp-a1', { subject = 'at noon', created_at = '2026-10-07T12:00:00Z' }),
    msg('ic-wisp-a2', { subject = 'at eleven', from = 'builder-1', created_at = '2026-10-07T13:00:00.123+02:00' }),
  })
  inbox('other city', { msg('sc-wisp-b1', { subject = 'Re: side\nwith a break', created_at = '2026-10-07T11:30:00Z' }) })
  local win = mailbox().open()
  eq(#floats(), 1, 'mailbox window')
  settled(win, 3)
  eq(rows(win), {
    '  ● demo-city  mayor  at noon',
    '  ● other-city  mayor  Re: side / with a break',
    '  ● demo-city  builder-1  at eleven',
  }, 'newest first across cities (13:00+02:00 is 11:00Z), one sanitized line each')
  wait('the city refresh', function()
    return gc_mail.cached_cities() ~= nil and #mail_calls() >= 2
  end)
  vim.wait(200)
  local calls = mail_calls()
  table.sort(calls, function(a, b)
    return a[2] < b[2]
  end)
  eq(calls, { call('inbox', '/srv/demo-city', 'human', '--json'), call('inbox', '/srv/other city', 'human', '--json') },
    'one inbox call per city, also after the city list refreshed')
  eq(recorded_argv(), nil, 'nothing was sent')
  vim.api.nvim_feedkeys('q', 'x', false)
  eq(#floats(), 0, 'q closes')
end)

test('opening a message shows it at once, marks it read once, and keeps it listed after gc closes it', function()
  preload()
  inbox('demo-city', { msg('ic-wisp-a1', { subject = 'Mailbox plan' }) })
  inbox('other city', {})
  answer('read', { message = msg('ic-wisp-a1', { subject = 'Mailbox plan', read = true }) })
  local win = mailbox().open()
  settled(win, 1)
  eq(rows(win), { '  ● demo-city  mayor  Mailbox plan' }, 'unread')
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  eq(#floats(), 0, 'the mailbox closes on open')
  local shown = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  eq(vim.list_slice(shown, 1, 3), { '# Mailbox plan', '',
    '**From** mayor · **To** human · **City** demo-city · 2026-10-07T12:00:00Z' }, 'headers')
  eq(vim.list_slice(shown, #shown - 1), { 'body of ic-wisp-a1', 'second line' }, 'body')
  wait('marked read and kept', function()
    return has_call(call('read', '/srv/demo-city', 'ic-wisp-a1', '--json')) and #kept_files() == 1
  end)
  -- gc's sweep closes read mail: the inbox no longer lists it.
  inbox('demo-city', {})
  local before = #mail_calls()
  win = mailbox().open()
  settled(win, 1)
  wait('the inbox answered', function()
    return #mail_calls() == before + 2
  end)
  vim.wait(100)
  eq(rows(win), { '    demo-city  mayor  Mailbox plan' }, 'read and still listed')
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
  eq(rows(win), { '    demo-city  mayor  Mailbox plan' }, 'kept across a restart')
  vim.api.nvim_feedkeys('q', 'x', false)
end)

test('a kept copy whose directory cannot be created says only the plain cannot-create text', function()
  preload()
  inbox('demo-city', { msg('ic-wisp-a1', { subject = 'Keep plain' }) })
  inbox('other city', {})
  answer('read', { message = msg('ic-wisp-a1', { subject = 'Keep plain', read = true }) })
  local blocker = scratch .. '/keep-block-' .. run_id
  write(blocker, 'x')
  local bad_dir = blocker .. '/mailbox'
  mailbox().configure({ dir = bad_dir })
  local win = mailbox().open()
  settled(win, 1)
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  wait('the kept copy failure was said', function()
    return vim.tbl_filter(function(n)
      return n.message:find('cannot keep a copy', 1, true) ~= nil
    end, notes)[1] ~= nil
  end)
  local said = vim.tbl_filter(function(n)
    return n.message:find('cannot keep a copy', 1, true) ~= nil
  end, notes)
  eq(#said, 1, 'said once')
  eq(said[1].message,
    ('gc-mail: read, but cannot keep a copy of "Keep plain" (cannot create %s); it leaves the mailbox once gc closes it'):format(bad_dir),
    'plain text, no Vim detail')
  vim.api.nvim_feedkeys('q', 'x', false)
end)

test('mark read, mark unread, archive, delete and thread call gc with the exact argv for the picked message only', function()
  preload()
  inbox('demo-city', {
    msg('ic-wisp-a1', { subject = 'first', created_at = '2026-10-07T13:00:00Z' }),
    msg('ic-wisp-a2', { subject = 'second', created_at = '2026-10-07T12:00:00Z' }),
  })
  inbox('other city', {})
  local win = mailbox().open()
  settled(win, 2)
  acted('mark-read', 'ic-wisp-a1')
  vim.api.nvim_feedkeys('m', 'x', false)
  wait('marked read', function()
    return rows(win)[1] == '    demo-city  mayor  first'
  end)
  eq(has_call(call('mark-read', '/srv/demo-city', 'ic-wisp-a1', '--json')), true, 'mark-read argv')
  eq(#kept_files(), 1, 'kept once read')
  acted('mark-unread', 'ic-wisp-a1')
  vim.api.nvim_feedkeys('u', 'x', false)
  wait('unread again', function()
    return rows(win)[1] == '  ● demo-city  mayor  first'
  end)
  eq(has_call(call('mark-unread', '/srv/demo-city', 'ic-wisp-a1', '--json')), true, 'mark-unread argv')
  eq(vim.json.decode(read_file(mailbox_dir .. '/' .. kept_files()[1])).read, false, 'the kept copy says unread')
  acted('archive', 'ic-wisp-a1')
  vim.api.nvim_feedkeys('a', 'x', false)
  wait('archived', function()
    return #rows(win) == 1
  end)
  eq(has_call(call('archive', '/srv/demo-city', 'ic-wisp-a1', '--json')), true, 'archive argv')
  eq(kept_files(), {}, 'the kept copy goes with it')
  eq(rows(win), { '  ● demo-city  mayor  second' }, 'the other message stays')
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
  eq(has_call(call('delete', '/srv/demo-city', 'ic-wisp-a2', '--json')), false, 'No deleted it')
  vim.fn.confirm = function()
    return 1
  end
  vim.api.nvim_feedkeys('d', 'x', false)
  vim.fn.confirm = confirm
  wait('deleted', function()
    return rows(win)[1] == ' no mail '
  end)
  eq(has_call(call('delete', '/srv/demo-city', 'ic-wisp-a2', '--json')), true, 'delete argv')
  for _, c in ipairs(mail_calls()) do
    if c[4] == 'archive' or c[4] == 'delete' then
      eq(#c, 6, 'one id per archive or delete: ' .. table.concat(c, ' '))
    end
  end
  vim.api.nvim_feedkeys('q', 'x', false)
  -- t shows the thread, oldest first.
  local m3 = msg('ic-wisp-a3', { subject = 'Re: plan' })
  m3.thread_id = nil
  inbox('demo-city', { m3 })
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
  eq(has_call(call('thread', '/srv/demo-city', 'ic-wisp-a3', '--json')), true, 'thread argv')
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  assert(text:find('# plan', 1, true) == 1, 'titled with the first subject')
  assert(text:find('## human', 1, true) < text:find('## mayor', 1, true), 'oldest first')
end)

-- Opens the message `m` from the mailbox with gc's answers for it in place.
local function open_message(m, thread_messages)
  preload()
  inbox('demo-city', { m })
  inbox('other city', {})
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
  eq(vim.api.nvim_buf_get_name(buf):match('gc%-mail://.*$'), 'gc-mail://demo-city/ic-wisp-a1', 'name')
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(lines[1], '# Re: \\*plan\\* \\[v2\\] \\<now\\> \\#1 \\| \\`x\\` \\\\ end', 'escaped title')
  eq(lines[3], '**From** may\\_or · **To** human · **City** demo-city · 2026-10-07T12:00:00Z', 'sender line')
  assert(lines[5]:find('^`ic%-wisp%-a1` · thread `thread%-0a1b2c3d4e5f` · r reply  t thread  c chat  u unread  a archive  d delete  q close · Read mail stays'),
    'id line: ' .. lines[5])
  eq(lines[7], '---', 'rule')
  eq(vim.list_slice(lines, 9), vim.split(body, '\n', { plain = true }), 'body verbatim, not escaped')
  -- Blank lines keep the id line from reading as a heading over the rule.
  eq({ lines[2], lines[4], lines[6], lines[8] }, { '', '', '', '' }, 'blank separators')
  eq(view_keys(buf), { 'a', 'c', 'd', 'q', 'r', 't', 'u' }, 'the same keys as before')
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
  eq(vim.api.nvim_buf_get_name(buf):match('gc%-mail://.*$'), 'gc-mail://demo-city/thread/thread-0a1b2c3d4e5f', 'name')
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
  inbox('demo-city', { second })
  inbox('other city', {})
  answer('read', { message = second })
  answer('thread', { thread_id = 'thread-0a1b2c3d4e5f', messages = { second, first } })
  local win = mailbox().open()
  settled(win, 1)
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  local buf = vim.api.nvim_get_current_buf()
  eq(vim.bo[buf].filetype, '', 'no filetype')
  eq(vim.bo[buf].modifiable, false, 'nomodifiable')
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), {
    'From:    mayor', 'To:      human', 'City:    demo-city', 'Date:    2026-10-07T13:00:00Z', 'Subject: Re: plan',
    'Id:      ic-wisp-a3   thread thread-0a1b2c3d4e5f',
    'Keys:    r reply  t thread  c chat  u unread  a archive  d delete  q close',
    'Read mail stays in this mailbox until you archive or delete it; gc closes read mail an hour after it was sent.',
    '', 'body of ic-wisp-a3', 'second line',
  }, 'plain message')
  vim.api.nvim_feedkeys('t', 'x', false)
  wait('thread shown', function()
    return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:find('^Thread thread%-0a1b2c3d4e5f in demo%-city, 2 message%(s%)') ~= nil
  end)
  buf = vim.api.nvim_get_current_buf()
  eq(vim.bo[buf].filetype, '', 'no filetype on the thread')
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), {
    'Thread thread-0a1b2c3d4e5f in demo-city, 2 message(s)',
    '', 'From:    human', 'To:      mayor', 'City:    demo-city', 'Date:    2026-10-07T12:00:00Z', 'Subject: plan',
    'Id:      ic-wisp-a0   thread thread-0a1b2c3d4e5f',
    '', 'body of ic-wisp-a0', 'second line',
    '', 'From:    mayor', 'To:      human', 'City:    demo-city', 'Date:    2026-10-07T13:00:00Z', 'Subject: Re: plan',
    'Id:      ic-wisp-a3   thread thread-0a1b2c3d4e5f',
    '', 'body of ic-wisp-a3', 'second line',
  }, 'plain thread')
end)

test('a malformed, failed or hung gc answer is said once and leaves the mailbox as it was', function()
  preload()
  mailbox().configure({ timeout_ms = 300 })
  inbox('demo-city', { msg('ic-wisp-a1', { subject = 'kept on screen' }) })
  inbox('other city', {})
  local win = mailbox().open()
  settled(win, 1)
  vim.api.nvim_feedkeys('q', 'x', false)
  local cases = {
    { 'not json', function() raw_answer('inbox', 'json', 'gc mail inbox: not json\n', 'demo-city') end,
      'gc mail inbox in demo-city printed something unexpected' },
    { 'a message without its read flag', function()
      local m = msg('ic-wisp-a9')
      m.read = nil
      inbox('demo-city', { m })
    end, 'gc mail inbox in demo-city printed something unexpected (a message has no read flag)' },
    { 'ok false', function() answer('inbox', { ok = false, messages = {} }, 'demo-city') end,
      'gc mail inbox in demo-city printed something unexpected' },
    { 'messages as an empty object', function()
      raw_answer('inbox', 'json', '{"schema_version":"1","ok":true,"recipient":"human","recipients":["human"],"messages":{}}\n',
        'demo-city')
    end, 'gc mail inbox in demo-city printed something unexpected (no message list)' },
    { 'a failing gc', function()
      inbox('demo-city', {})
      raw_answer('inbox', 'exit', '1', 'demo-city')
      raw_answer('inbox', 'stderr', 'gc mail inbox: store unavailable\n', 'demo-city')
    end, 'gc mail inbox in demo-city failed: gc mail inbox: store unavailable' },
    { 'a hung gc', function()
      vim.fn.delete(vim.env.FAKE_GC_MAIL .. '/inbox.demo-city.exit')
      vim.fn.delete(vim.env.FAKE_GC_MAIL .. '/inbox.demo-city.stderr')
      raw_answer('inbox', 'hang', '5', 'demo-city')
    end, 'gc mail inbox in demo-city did not answer within 0.3 s' },
  }
  for _, case in ipairs(cases) do
    local name, setup, expected = case[1], case[2], case[3]
    vim.fn.delete(vim.env.FAKE_GC_MAIL .. '/inbox.demo-city.json')
    setup()
    for round = 1, 2 do
      notes = {}
      win = mailbox().open()
      wait(name .. ': the inbox did not finish', function()
        return #notes > 0 or (round == 2 and vim.wait(600) == false)
      end, 5000)
      vim.wait(100)
      eq(rows(win), { '  ● demo-city  mayor  kept on screen' }, name .. ': the list on screen')
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
  inbox('demo-city', { msg('ic-wisp-a1', { subject = 'Mailbox plan' }) })
  inbox('other city', {})
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
  eq(notes[1].message, 'gc-mail: queued for demo-city mayor: Re: Mailbox plan', 'queued notice')
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { '' }, 'cleared once on disk')
  eq(vim.b[buf].gc_mail_reply, nil, 'no longer a reply waiting')
  local record = vim.json.decode(read_file(queue_dir .. '/' .. spool()[1]))
  eq({ record.reply_to, record.to, record.subject }, { 'ic-wisp-a1', 'mayor', 'Re: Mailbox plan' }, 'queue record')
  eq(gc_mail.queue_lines({ { record = record } }, record.created)[1], ' demo-city mayor  Re: Mailbox plan  0s  pending ',
    ':GcMailQueue line')
  wait('retried until sent', drained)
  eq(sent(), { '/srv/demo-city|Re: Mailbox plan', '/srv/demo-city|Re: Mailbox plan' }, 'two tries')
  eq(recorded_argv(), { '--city', '/srv/demo-city', 'mail', 'reply', 'ic-wisp-a1', '-s', 'Re: Mailbox plan', '-m',
    'Re: Mailbox plan\n\nlooks good', '--notify' }, 'reply argv')
  eq(notes[#notes].message, 'gc-mail: sent to demo-city mayor', 'sent notice')
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
  eq(notes[#notes - 1].message, 'gc-mail: queued for demo-city mayor: [Nick] Deploy plan (nvim)', 'queued line shows the label')
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
  answer('count', { recipient = 'human', recipients = { 'human' }, total = 3, unread = 1 }, 'demo-city')
  answer('count', { recipient = 'human', recipients = { 'human' }, total = 0, unread = 0 }, 'other city')
  mailbox().start_check(1000)
  eq(mailbox().checking(), true, 'started')
  mailbox().check_once()
  wait('one count per city', function()
    return #mail_calls() == 2
  end)
  vim.wait(100)
  eq(#notes, 0, 'the first pass only learns the counts')
  answer('count', { recipient = 'human', recipients = { 'human' }, total = 4, unread = 2 }, 'demo-city')
  mailbox().check_once()
  wait('second pass', function()
    return #notes == 1
  end)
  eq(notes[1].message, 'gc-mail: 2 unread mail in demo-city; <Space>mi opens the mailbox', 'notice')
  eq(has_call(call('count', '/srv/demo-city', 'human', '--json')), true, 'count argv')
  vim.api.nvim_exec_autocmds('FocusLost', {})
  mailbox().check_once()
  vim.wait(200)
  eq(#mail_calls(), 4, 'nothing runs without focus')
  vim.api.nvim_exec_autocmds('FocusGained', {})
  mailbox().stop_check()
  eq(mailbox().checking(), false, 'stopped')
  gc_mail.setup({ keymap = false, mailbox_keymap = false, state_dir = vim.fs.dirname(queue_dir), check_ms = 60000, watch = false })
  wait('started after startup', mailbox().checking)
  -- setup() again with check_ms = false stops it at once.
  gc_mail.setup({ keymap = false, mailbox_keymap = false, state_dir = vim.fs.dirname(queue_dir), check_ms = false, watch = false })
  eq(mailbox().checking(), false, 'check_ms = false stops a running check')
  vim.wait(200)
  eq(mailbox().checking(), false, 'and nothing starts it again after startup')
end)

test('an outdated inbox answer never brings back what a later call, a read or an archive changed', function()
  preload()
  inbox('other city', {})
  -- A mailbox closed and reopened while its first inbox call still runs.
  inbox('demo-city', { msg('ic-wisp-a1', { subject = 'old' }) })
  raw_answer('inbox', 'delay', '1', 'demo-city')
  local win = mailbox().open()
  vim.wait(100)
  vim.api.nvim_feedkeys('q', 'x', false)
  vim.fn.delete(vim.env.FAKE_GC_MAIL .. '/inbox.demo-city.delay')
  inbox('demo-city', {})
  win = mailbox().open()
  wait('the second call answered', function()
    return rows(win)[1] == ' no mail '
  end)
  vim.wait(1500)
  eq(rows(win), { ' no mail ' }, 'the first call\'s late answer is dropped')
  vim.api.nvim_feedkeys('q', 'x', false)
  -- An archive and a read while a refresh still runs.
  inbox('demo-city', {
    msg('ic-wisp-a2', { subject = 'to archive', created_at = '2026-10-07T13:00:00Z' }),
    msg('ic-wisp-a3', { subject = 'to read', created_at = '2026-10-07T12:00:00Z' }),
    msg('ic-wisp-a4', { subject = 'untouched', created_at = '2026-10-07T11:00:00Z' }),
  })
  win = mailbox().open()
  settled(win, 3)
  raw_answer('inbox', 'delay', '1', 'demo-city')
  vim.api.nvim_feedkeys('R', 'x', false)
  acted('archive', 'ic-wisp-a2')
  vim.api.nvim_feedkeys('a', 'x', false)
  wait('archived', function()
    return rows(win)[1] == '  ● demo-city  mayor  to read'
  end)
  acted('mark-read', 'ic-wisp-a3')
  vim.api.nvim_feedkeys('m', 'x', false)
  wait('marked read', function()
    return rows(win)[1] == '    demo-city  mayor  to read'
  end)
  vim.wait(1500) -- the refresh answers 1 s after it was made
  eq(rows(win), { '    demo-city  mayor  to read', '  ● demo-city  mayor  untouched' },
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
  answer('count', { recipient = 'human', recipients = { 'human' }, total = 1, unread = 1 }, 'demo-city')
  answer('count', { recipient = 'human', recipients = { 'human' }, total = 0, unread = 0 }, 'other city')
  mailbox().check_once()
  wait('first pass', function()
    return #mail_calls() == 2
  end)
  vim.wait(100)
  answer('count', { recipient = 'human', recipients = { 'human' }, unread = 5 }, 'demo-city')
  for _ = 1, 2 do
    mailbox().check_once()
    vim.wait(300)
  end
  eq(vim.tbl_filter(function(m)
    return m:find('unread mail in') ~= nil
  end, vim.tbl_map(function(n)
    return n.message
  end, notes)), {}, 'no new-mail notice from a malformed count')
  eq(errors(), { 'gc-mail: gc mail count in demo-city printed something unexpected (no total and unread count)' }, 'said once')
  -- Actions: an answer without command and action, or with a negative count.
  notes = {}
  inbox('demo-city', { msg('ic-wisp-a1', { subject = 'stays' }) })
  inbox('other city', {})
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
  eq(rows(win), { '  ● demo-city  mayor  stays' }, 'still listed, still unread')
  eq(kept_files(), {}, 'no kept copy')
  local said = errors()
  table.sort(said)
  eq(said, {
    'gc-mail: cannot archive "stays": gc mail archive in demo-city printed something unexpected (no count)',
    'gc-mail: cannot mark "stays" read: gc mail mark-read in demo-city printed something unexpected (it is not a mark-read answer)',
  }, 'each said (in either order)')
  vim.api.nvim_feedkeys('q', 'x', false)
end)

test('r2a2: a thread id that is not one gc prints is refused, never passed to gc', function()
  preload()
  inbox('demo-city', { msg('ic-wisp-a1', { subject = 'kept on screen' }) })
  inbox('other city', {})
  local win = mailbox().open()
  settled(win, 1)
  vim.api.nvim_feedkeys('q', 'x', false)
  inbox('demo-city', { msg('ic-wisp-a1', { subject = 'kept on screen', thread_id = '--all' }) })
  notes = {}
  win = mailbox().open()
  wait('the inbox answered', function()
    return #errors() == 1
  end)
  eq(errors(), { 'gc-mail: gc mail inbox in demo-city printed something unexpected (a message thread_id is not a gc thread id)' },
    'said')
  eq(rows(win), { '  ● demo-city  mayor  kept on screen' }, 'the list on screen stays')
  vim.api.nvim_feedkeys('t', 'x', false)
  vim.wait(200)
  for _, c in ipairs(mail_calls()) do
    assert(c[4] ~= 'thread' or c[5] == 'thread-' .. vim.fn.sha256('ic-wisp-a1'):sub(1, 12), 'thread argv: ' .. table.concat(c, ' '))
    assert(c[3] ~= 'mail' or not vim.tbl_contains(c, '--all'), 'an option reached gc: ' .. table.concat(c, ' '))
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
  inbox('demo-city', { alone })
  inbox('other city', {})
  answer('thread', { thread_id = id, messages = { alone } })
  local win = mailbox().open()
  settled(win, 1)
  notes = {}
  vim.api.nvim_feedkeys('t', 'x', false)
  wait('the thread answered', function()
    return #errors() == 1
  end)
  eq(has_call(call('thread', '/srv/demo-city', id, '--json')), true, 'asked by the message id')
  eq(errors(), { 'gc-mail: cannot show the thread of "kept on screen": gc mail thread in demo-city printed something '
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
    inbox('demo-city', { msg('ic-wisp-a1', { subject = 'gone' }) })
    inbox('other city', {})
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
      return has_call(call('read', '/srv/demo-city', 'ic-wisp-a1', '--json'))
    end)
    vim.wait(1500) -- the read answers 1 s after it was made
    eq(kept_files(), {}, verb .. ': no kept copy recreated')
    vim.cmd('only')
    inbox('demo-city', {})
    win = mailbox().open()
    settled(win, 1)
    vim.wait(200)
    eq(rows(win), { ' no mail ' }, verb .. ': not listed again')
    vim.api.nvim_feedkeys('q', 'x', false)
  end
end)

test('I2: action answers apply in the order their calls started, whatever order they arrive in', function()
  preload()
  inbox('demo-city', {
    msg('ic-wisp-a1', { subject = 'late read', created_at = '2026-10-07T13:00:00Z' }),
    msg('ic-wisp-a2', { subject = 'late archive', created_at = '2026-10-07T12:00:00Z' }),
  })
  inbox('other city', {})
  local win = mailbox().open()
  settled(win, 2)
  -- A mark-read that answers after a later mark-unread is dropped.
  acted('mark-read', 'ic-wisp-a1')
  raw_answer('mark-read', 'delay', '1')
  vim.api.nvim_feedkeys('m', 'x', false)
  acted('mark-unread', 'ic-wisp-a1')
  vim.api.nvim_feedkeys('u', 'x', false)
  vim.wait(1500)
  eq(rows(win)[1], '  ● demo-city  mayor  late read', 'unread, as the later call left it')
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
  eq(rows(win), { '  ● demo-city  mayor  late read' }, 'the archive applied after the read')
  eq(kept_files(), {}, 'its kept copy went with it')
  vim.api.nvim_feedkeys('q', 'x', false)
end)

-- ---- the preview pane ----------------------------------------------------------

-- The preview pane window of the current tab page, or nil.
local function preview_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)):find('gc-mail://preview', 1, true) then
      return win
    end
  end
  return nil
end

-- Feeds `keys` in the current window, then fires CursorMoved as Neovim does
-- after a key in a redrawn UI (a headless -l run draws nothing, so it never
-- does after feedkeys).
local function move(keys)
  vim.api.nvim_feedkeys(keys, 'x', false)
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = vim.api.nvim_get_current_buf() })
end

-- Waits until the pane shows exactly `expected`.
local function pane_shows(expected, what)
  local function shown()
    local pane = preview_win()
    return pane and lines_of(pane)
  end
  if not vim.wait(5000, function()
    return vim.deep_equal(shown(), expected)
  end, 10) then
    eq(shown(), expected, what)
  end
end

-- Two messages in one city, newest first; a wide editor so the pane fits right of the list.
local function two_messages(extra)
  preload()
  gc_mail.config.preview = true
  vim.o.columns = 200
  inbox('demo-city', {
    msg('ic-wisp-a1', vim.tbl_extend('force', { subject = 'newer subject', body = 'alpha one\nalpha two',
      created_at = '2026-10-07T13:00:00Z' }, extra or {})),
    msg('ic-wisp-a2', { subject = 'older subject', body = 'beta only', created_at = '2026-10-07T12:00:00Z' }),
  })
  inbox('other city', {})
end

-- Waits until every inbox call of the open has answered and nothing else runs.
local function quiet()
  wait('both cities were listed', function()
    return #mail_calls() >= 2
  end)
  vim.wait(200)
end

test('preview: the float shows the body under the cursor, follows it, and never moves focus', function()
  two_messages()
  local win = mailbox().open()
  settled(win, 2)
  pane_shows({ 'alpha one', 'alpha two' }, 'the first body')
  local pane = preview_win()
  eq(vim.api.nvim_get_current_win(), win, 'focus stays in the list')
  local list_at, pane_at = vim.api.nvim_win_get_config(win), vim.api.nvim_win_get_config(pane)
  eq(pane_at.relative, 'editor', 'a second float')
  eq(pane_at.row, list_at.row, 'the top of the list')
  eq(pane_at.height, vim.o.lines - vim.o.cmdheight - list_at.row - 2, 'down to the bottom of the editor')
  eq(pane_at.col, list_at.col + list_at.width + 2, 'right of the list')
  eq(pane_at.width, 200 - pane_at.col - 2 - 1, 'the rest of the editor minus a margin')
  eq(pane_at.focusable, false, 'it cannot take focus')
  local buf = vim.api.nvim_win_get_buf(pane)
  eq({ vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].modifiable, vim.bo[buf].filetype },
    { 'nofile', 'wipe', false, 'markdown' }, 'a markdown scratch buffer')
  move('j')
  pane_shows({ 'beta only' }, 'the second body after the debounce')
  for _, line in ipairs(lines_of(preview_win())) do
    eq(line:find('From', 1, true) or line:find('ubject', 1, true) or line:find('thread-', 1, true), nil, 'only the body')
  end
  vim.api.nvim_feedkeys('q', 'x', false)
  eq(#floats(), 0, 'the pane closes with the float')
  eq(preview_win(), nil, 'and its window is gone')
end)

test('preview: the buffer name, and no filetype with markdown = false', function()
  two_messages()
  gc_mail.config.markdown = false
  local win = mailbox().open()
  settled(win, 2)
  pane_shows({ 'alpha one', 'alpha two' }, 'the body')
  local buf = vim.api.nvim_win_get_buf(preview_win())
  eq(vim.api.nvim_buf_get_name(buf):sub(-18), 'gc-mail://preview', 'its name')
  eq(vim.bo[buf].filetype, '', 'no filetype')
  vim.api.nvim_feedkeys('q', 'x', false)
end)

test('preview: updates make no gc call and mark nothing read', function()
  two_messages()
  local win = mailbox().open()
  settled(win, 2)
  pane_shows({ 'alpha one', 'alpha two' }, 'the first body')
  quiet()
  local before = mail_calls()
  move('j')
  pane_shows({ 'beta only' }, 'the second body')
  move('k')
  pane_shows({ 'alpha one', 'alpha two' }, 'the first body again')
  vim.api.nvim_feedkeys('p', 'x', false)
  vim.api.nvim_feedkeys('p', 'x', false)
  pane_shows({ 'alpha one', 'alpha two' }, 'shown again')
  eq(mail_calls(), before, 'the fake gc mail log gained no line')
  eq(#vim.tbl_filter(function(c)
    return c[4] == 'read' or c[4] == 'mark-read'
  end, mail_calls()), 0, 'no read or mark-read')
  eq(rows(win), { '  ● demo-city  mayor  newer subject', '  ● demo-city  mayor  older subject' }, 'both still unread')
  eq(#kept_files(), 0, 'and no kept copy')
  vim.api.nvim_feedkeys('q', 'x', false)
end)

test('preview: holding j redraws once after the debounce, not once per line', function()
  preload()
  gc_mail.config.preview = true
  vim.o.columns = 200
  local messages = {}
  for i = 1, 4 do
    messages[i] = msg('ic-wisp-a' .. i, { body = 'body ' .. i, created_at = ('2026-10-07T1%d:00:00Z'):format(5 - i) })
  end
  inbox('demo-city', messages)
  inbox('other city', {})
  local win = mailbox().open()
  settled(win, 4)
  pane_shows({ 'body 1' }, 'the first body')
  quiet()
  local changes = 0
  vim.api.nvim_buf_attach(vim.api.nvim_win_get_buf(preview_win()), false, { on_lines = function()
    changes = changes + 1
  end })
  move('j')
  move('j')
  move('j')
  pane_shows({ 'body 4' }, 'the last body')
  vim.wait(150)
  eq(changes, 1, 'one redraw for three lines')
  vim.api.nvim_feedkeys('q', 'x', false)
end)

test('preview: an empty body shows one dim line, a line that is no message clears the pane', function()
  two_messages({ body = '' })
  local win = mailbox().open()
  settled(win, 2)
  pane_shows({ '(no content)' }, 'one line for an empty body')
  local marks = vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(preview_win()), -1, 0, -1, { details = true })
  eq(#marks, 1, 'one highlight')
  eq(marks[1][4].line_hl_group, 'Comment', 'a dim line')
  vim.api.nvim_feedkeys('q', 'x', false)
  -- Nothing listed: the only row is "no mail", which is no message.
  inbox('demo-city', {})
  vim.fn.delete(mailbox_dir, 'rf')
  mailbox().reset()
  win = mailbox().open()
  settled(win, 1)
  pane_shows({ '' }, 'a cleared pane')
  vim.api.nvim_feedkeys('q', 'x', false)
end)

test('preview: p hides and shows the pane for that float; preview = false opens it hidden', function()
  two_messages()
  local win = mailbox().open()
  settled(win, 2)
  pane_shows({ 'alpha one', 'alpha two' }, 'shown by default')
  vim.api.nvim_feedkeys('p', 'x', false)
  eq(preview_win(), nil, 'p hides it')
  eq(#floats(), 1, 'only the list is left')
  move('j')
  vim.wait(150)
  eq(preview_win(), nil, 'moving the cursor keeps it hidden')
  vim.api.nvim_feedkeys('p', 'x', false)
  pane_shows({ 'beta only' }, 'p shows it again, on the message under the cursor')
  vim.api.nvim_feedkeys('q', 'x', false)
  -- The choice lasts until the view closes: a new float starts from the option.
  gc_mail.config.preview = false
  win = mailbox().open()
  settled(win, 2)
  vim.wait(150)
  eq(preview_win(), nil, 'hidden when preview = false')
  vim.api.nvim_feedkeys('p', 'x', false)
  pane_shows({ 'alpha one', 'alpha two' }, 'p shows it for this view')
  vim.api.nvim_feedkeys('q', 'x', false)
end)

test('preview: setup refuses anything but true or false, and defaults to true', function()
  local ok, err = pcall(gc_mail.setup, { preview = 'yes' })
  eq(ok, false, 'preview = yes')
  assert(tostring(err):find('preview must be true or false', 1, true), tostring(err))
  local opts = { keymap = false, mailbox_keymap = false, panel_keymap = false, chat_keymap = false, watch = false,
    state_dir = vim.fs.dirname(queue_dir) }
  gc_mail.setup(opts)
  eq(gc_mail.config.preview, true, 'the default')
  gc_mail.setup(vim.tbl_extend('force', opts, { preview = false }))
  eq(gc_mail.config.preview, false, 'false is accepted')
end)

test('preview: the pane goes below a list with no room on its right, and hides without room below', function()
  local preview = require('gc_mail.preview')
  local list = { row = 5, col = 10, width = 40, height = 6 }
  eq(preview.float_layout(list, 120, 40, 1), { row = 5, col = 52, width = 65, height = 32 }, 'right of the list, down to the bottom')
  eq(preview.float_layout(list, 120, 10, 1), { row = 5, col = 52, width = 65, height = 6 }, 'never shorter than the list')
  eq(preview.float_layout(list, 82, 40, 1), { row = 13, col = 10, width = 40, height = 24 }, 'below at the list width')
  eq(preview.float_layout({ row = 5, col = 10, width = 20, height = 6 }, 60, 40, 1),
    { row = 13, col = 10, width = 30, height = 24 }, 'below, at least 30 wide')
  eq(preview.float_layout(list, 82, 18, 1), nil, 'under 3 rows below: hidden')
  eq(preview.float_layout({ row = 5, col = 10, width = 20, height = 6 }, 35, 40, 1), nil, 'under 30 columns: hidden')
  eq(preview.split_width(80), 40, 'half the panel')
  eq(preview.split_width(61), 30, 'at least 30 columns')
  eq(preview.split_width(50), nil, 'the list would keep under 20 columns')
end)

test('preview: a narrow editor puts the pane below the list', function()
  two_messages()
  vim.o.columns = 80
  local win = mailbox().open()
  settled(win, 2)
  pane_shows({ 'alpha one', 'alpha two' }, 'the body')
  local list_at, pane_at = vim.api.nvim_win_get_config(win), vim.api.nvim_win_get_config(preview_win())
  eq(pane_at.row, list_at.row + list_at.height + 2, 'under the list')
  eq(pane_at.col, list_at.col, 'in its column')
  vim.api.nvim_feedkeys('q', 'x', false)
end)

test('preview: a refresh that removes the message under the cursor shows the next one', function()
  two_messages()
  local win = mailbox().open()
  settled(win, 2)
  pane_shows({ 'alpha one', 'alpha two' }, 'the first body')
  quiet()
  inbox('demo-city', { msg('ic-wisp-a2', { subject = 'older subject', body = 'beta only',
    created_at = '2026-10-07T12:00:00Z' }) })
  vim.api.nvim_feedkeys('R', 'x', false)
  pane_shows({ 'beta only' }, 'the message now under the cursor')
  inbox('demo-city', {})
  quiet()
  vim.api.nvim_feedkeys('R', 'x', false)
  pane_shows({ '' }, 'a cleared pane when nothing is under the cursor')
  vim.api.nvim_feedkeys('q', 'x', false)
end)

test('preview: nothing exists before a list opens and nothing is left when it closes', function()
  local function groups()
    local found = {}
    for _, au in ipairs(vim.api.nvim_get_autocmds({})) do
      if au.group_name and au.group_name:find('^gc_mail_preview') then
        found[au.group_name] = true
      end
    end
    return vim.tbl_keys(found)
  end
  two_messages()
  eq(groups(), {}, 'no autocmd before the float opens')
  local win = mailbox().open()
  settled(win, 2)
  eq(#groups(), 1, 'one group while it is open')
  vim.api.nvim_feedkeys('q', 'x', false)
  eq(groups(), {}, 'none after it closed')
  eq(preview_win(), nil, 'no pane')
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
  for _, dir in ipairs({ 'demo-city', 'other city' }) do
    vim.fn.mkdir(base .. '/' .. dir .. '/.gc', 'p')
    cities[#cities + 1] = { name = dir == 'other city' and 'other-city' or dir, path = base .. '/' .. dir }
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
  inbox('demo-city', { msg('ic-wisp-a1', { subject = 'first' }) })
  inbox('other city', {})
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
  eq(rows(win), { '  ● demo-city  mayor  first' }, 'the mailbox lines')
  -- A mail arriving changes the panel, not the focus.
  inbox('demo-city', { msg('ic-wisp-a2', { subject = 'second', created_at = '2026-10-07T13:00:00Z' }),
    msg('ic-wisp-a1', { subject = 'first' }) })
  append(log, event('mail.sent'))
  wait('the new mail is shown', function()
    return #rows(win) == 2
  end)
  eq(rows(win), { '  ● demo-city  mayor  second', '  ● demo-city  mayor  first' }, 'newest first')
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
  inbox('demo-city', {
    msg('ic-wisp-a1', { subject = 'at noon', created_at = '2026-10-07T12:00:00Z' }),
    msg('ic-wisp-a2', { subject = 'at eleven', from = 'builder-1', created_at = '2026-10-07T11:00:00Z' }),
  })
  inbox('other city', { msg('sc-wisp-b1', { subject = 'side', created_at = '2026-10-07T11:30:00Z' }) })
  answer('read', { message = msg('ic-wisp-a1', { subject = 'at noon', read = true }) })
  local origin = vim.api.nvim_get_current_win()
  local pwin = panel().open()
  settled(pwin, 3)
  local fwin = mailbox().open()
  settled(fwin, 3)
  eq(rows(pwin), rows(fwin), 'the same lines')
  eq(rows(pwin), { '  ● demo-city  mayor  at noon', '  ● other-city  mayor  side', '  ● demo-city  builder-1  at eleven' }, 'lines')
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
    return rows(pwin)[1] == '    demo-city  mayor  at noon'
  end)
  eq(has_call(call('read', cities[1].path, 'ic-wisp-a1', '--json')), true, 'gc mail read')
  -- m and u from the panel without entering it.
  vim.api.nvim_win_set_cursor(pwin, { 2, 0 })
  acted('mark-read', 'sc-wisp-b1')
  panel_key(pwin, 'm')()
  wait('marked read', function()
    return rows(pwin)[2] == '    other-city  mayor  side'
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
  inbox('demo-city', {})
  inbox('other city', {})
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
  inbox('demo-city', {})
  inbox('other city', {})
  panel().open()
  listed(cities)
  raw_answer('inbox', 'delay', '3', 'demo-city')
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
  vim.fn.delete(vim.env.FAKE_GC_MAIL .. '/inbox.demo-city.delay')
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
  inbox('demo-city', {})
  inbox('other city', {})
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
  inbox('demo-city', {})
  inbox('other city', {})
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
  inbox('demo-city', {})
  inbox('other city', {})
  local win = panel().open()
  listed(cities)
  local handles = panel().handles()
  eq(#handles >= 6, true, 'a timer, two debounce and two rearm timers and a watcher: ' .. #handles)
  -- A mail event whose debounce is still waiting, and an inbox call in flight.
  raw_answer('inbox', 'delay', '0.5', 'other city')
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
  inbox('demo-city', {
    msg('ic-wisp-a1', { subject = 'to archive', created_at = '2026-10-07T13:00:00Z' }),
    msg('ic-wisp-a2', { subject = 'stays', created_at = '2026-10-07T12:00:00Z' }),
  })
  inbox('other city', {})
  local pwin = panel().open()
  settled(pwin, 2)
  listed(cities)
  local fwin = mailbox().open()
  settled(fwin, 2)
  vim.wait(200)
  -- A panel refresh that answers late, with the message still in it.
  raw_answer('inbox', 'delay', '1', 'demo-city')
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
  eq(rows(pwin), { '  ● demo-city  mayor  stays' }, 'panel')
  eq(rows(fwin), { '  ● demo-city  mayor  stays' }, 'float')
  vim.wait(1500) -- the refresh answers 1 s after it was made
  eq(rows(pwin), { '  ● demo-city  mayor  stays' }, 'the late answer does not bring it back to the panel')
  eq(rows(fwin), { '  ● demo-city  mayor  stays' }, 'nor to the float')
  eq(#floats(), 1, 'the float stayed open')
  vim.api.nvim_feedkeys('q', 'x', false)
end)

test('preview: the panel shows the pane as a split right of the list, follows its cursor and closes with it', function()
  local cities, log = city_dirs()
  write(log, '')
  gc_mail.config.preview = true
  inbox('demo-city', {
    msg('ic-wisp-a1', { subject = 'newer subject', body = 'alpha one', created_at = '2026-10-07T13:00:00Z' }),
    msg('ic-wisp-a2', { subject = 'older subject', body = 'beta only', created_at = '2026-10-07T12:00:00Z' }),
  })
  inbox('other city', {})
  local origin = vim.api.nvim_get_current_win()
  local pwin = panel().open()
  settled(pwin, 2)
  pane_shows({ 'alpha one' }, 'the first body')
  local pane = preview_win()
  eq(#floats(), 0, 'a split, not a float')
  eq(vim.api.nvim_get_current_win(), origin, 'focus stays where it was')
  eq(vim.api.nvim_win_get_position(pane)[1], vim.api.nvim_win_get_position(pwin)[1], 'in the panel row')
  eq(vim.api.nvim_win_get_position(pane)[2] > vim.api.nvim_win_get_position(pwin)[2], true, 'right of the list')
  eq(vim.api.nvim_win_get_height(pane), vim.api.nvim_win_get_height(pwin), 'the height of the panel')
  eq(vim.api.nvim_win_get_width(pane), 40, 'about half the panel width')
  local wo = vim.wo[pane]
  eq({ wo.winfixheight, wo.number, wo.signcolumn }, { true, false, 'no' }, 'a quiet window')
  vim.api.nvim_set_current_win(pwin)
  move('j')
  pane_shows({ 'beta only' }, 'it follows the panel cursor')
  eq(vim.api.nvim_get_current_win(), pwin, 'focus is in the list')
  -- p hides and shows it for this panel.
  panel_key(pwin, 'p')()
  eq(preview_win(), nil, 'p hides it')
  panel_key(pwin, 'p')()
  pane_shows({ 'beta only' }, 'p shows it again')
  vim.api.nvim_set_current_win(origin)
  panel().toggle()
  eq(vim.api.nvim_win_is_valid(pwin), false, 'the panel closed')
  eq(preview_win(), nil, 'and the pane with it')
  eq(#vim.api.nvim_tabpage_list_wins(0), 1, 'one window is left')
end)

test('preview: a panel refresh that removes the message under the cursor updates the pane', function()
  local cities, log = city_dirs()
  write(log, '')
  gc_mail.config.preview = true
  inbox('demo-city', {
    msg('ic-wisp-a1', { subject = 'newer subject', body = 'alpha one', created_at = '2026-10-07T13:00:00Z' }),
    msg('ic-wisp-a2', { subject = 'older subject', body = 'beta only', created_at = '2026-10-07T12:00:00Z' }),
  })
  inbox('other city', {})
  local pwin = panel().open()
  settled(pwin, 2)
  pane_shows({ 'alpha one' }, 'the first body')
  listed(cities)
  inbox('demo-city', { msg('ic-wisp-a2', { subject = 'older subject', body = 'beta only',
    created_at = '2026-10-07T12:00:00Z' }) })
  append(log, event('mail.sent'))
  pane_shows({ 'beta only' }, 'the message now under the cursor')
  local before = #mail_calls()
  vim.wait(200)
  eq(#vim.tbl_filter(function(c)
    return c[4] == 'read' or c[4] == 'mark-read'
  end, mail_calls()), 0, 'no read mark')
  eq(#mail_calls() >= before, true, 'only inbox calls')
  panel().toggle()
end)

test('preview: a panel too narrow for the pane keeps it hidden and the panel works', function()
  local cities, log = city_dirs()
  write(log, '')
  gc_mail.config.preview = true
  vim.cmd('vsplit')
  vim.cmd('vertical resize 50')
  inbox('demo-city', { msg('ic-wisp-a1', { subject = 'newer subject', body = 'alpha one' }) })
  inbox('other city', {})
  local pwin = panel().open()
  eq(vim.api.nvim_win_get_width(pwin), 50, 'a panel 50 columns wide')
  settled(pwin, 1)
  vim.wait(150)
  eq(preview_win(), nil, 'no pane')
  eq(#vim.api.nvim_tabpage_list_wins(0), 3, 'both windows and the panel only')
  panel().toggle()
end)

test('history.load runs the exact argv and returns the five good messages oldest first; skipped = 2 and the notice said once', function()
  local fixture = [=[
[
  {
    "id": "ic-wisp-a0",
    "title": "first thread message",
    "sender": "human",
    "assignee": "mayor",
    "status": "closed",
    "created_at": "2026-10-07T10:00:00Z",
    "description": "body of first",
    "labels": [
      "thread:thread-0a1b2c3d4e5f"
    ]
  },
  {
    "id": "ic-wisp-a1",
    "title": "reply message",
    "sender": "mayor",
    "assignee": "human",
    "status": "open",
    "created_at": "2026-10-07T11:00:00Z",
    "description": "body of reply",
    "labels": [
      "thread:thread-0a1b2c3d4e5f",
      "reply-to:ic-wisp-a0"
    ]
  },
  {
    "id": "ic-wisp-a2",
    "title": "read message",
    "sender": "mayor",
    "assignee": "human",
    "status": "open",
    "created_at": "2026-10-07T12:00:00Z",
    "description": "body of read",
    "labels": [
      "read"
    ]
  },
  {
    "id": "ic-wisp-a3",
    "title": "no assignee",
    "sender": "mayor",
    "assignee": "",
    "status": "open",
    "created_at": "2026-10-07T13:00:00Z",
    "description": "skipped"
  },
  {
    "id": "ic-wisp-a4",
    "title": "bad date",
    "sender": "mayor",
    "assignee": "human",
    "status": "open",
    "created_at": "not-a-date",
    "description": "skipped"
  },
  {
    "id": "ic-wisp-a5",
    "title": "no labels",
    "sender": "human",
    "assignee": "mayor",
    "status": "open",
    "created_at": "2026-10-07T14:00:00Z",
    "description": "body without labels"
  },
  {
    "id": "ic-wisp-a6",
    "title": "no description",
    "sender": "planner",
    "assignee": "human",
    "status": "open",
    "created_at": "2026-10-07T15:00:00Z",
    "labels": []
  }
]
]=]
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fixture)
  local history = require('gc_mail.history')
  history.reset()
  notes = {}
  local done, res_list, res_err, res_skipped
  local before_time = os.time()
  history.load(TWO[1], {}, function(list, err, skipped)
    done, res_list, res_err, res_skipped = true, list, err, skipped
  end)
  wait('history load finished', function() return done end)
  eq(res_err, nil, 'no error')
  eq(res_skipped, 2, 'skipped count is 2')
  eq(#res_list, 5, 'five good messages')
  local calls = mail_calls()
  eq(#calls, 1, 'one bd list call')
  local argv = calls[1]
  eq(argv[1], '--city', '--city flag')
  eq(argv[2], '/srv/demo-city', 'city path')
  eq(argv[3], 'bd', 'bd command')
  eq(argv[4], 'list', 'list subcommand')
  eq(argv[5], '--type', '--type flag')
  eq(argv[6], 'message', 'type argument')
  eq(argv[7], '--all', '--all flag')
  eq(argv[8], '--json', '--json flag')
  eq(argv[9], '--limit', '--limit flag')
  eq(argv[10], '0', 'limit argument')
  eq(argv[11], '--created-after', '--created-after flag')
  local t_str = argv[12]
  local t_epoch = require('gc_mail.mailbox').epoch(t_str)
  assert(t_epoch, 'valid created-after timestamp')
  local expected_epoch = before_time - 14 * 86400
  assert(math.abs(t_epoch - expected_epoch) <= 60, 'T within a minute of now minus history_days')

  eq(res_list[1].id, 'ic-wisp-a0', 'msg 1 id')
  eq(res_list[1].from, 'human', 'msg 1 from')
  eq(res_list[1].to, 'mayor', 'msg 1 to')
  eq(res_list[1].subject, 'first thread message', 'msg 1 subject')
  eq(res_list[1].body, 'body of first', 'msg 1 body')
  eq(res_list[1].closed, true, 'msg 1 closed')
  eq(res_list[1].read, true, 'msg 1 read')
  eq(res_list[1].thread_id, 'thread-0a1b2c3d4e5f', 'msg 1 thread_id')
  eq(res_list[1].reply_to, nil, 'msg 1 reply_to')

  eq(res_list[2].id, 'ic-wisp-a1', 'msg 2 id')
  eq(res_list[2].from, 'mayor', 'msg 2 from')
  eq(res_list[2].to, 'human', 'msg 2 to')
  eq(res_list[2].subject, 'reply message', 'msg 2 subject')
  eq(res_list[2].body, 'body of reply', 'msg 2 body')
  eq(res_list[2].closed, false, 'msg 2 closed')
  eq(res_list[2].read, false, 'msg 2 read')
  eq(res_list[2].thread_id, 'thread-0a1b2c3d4e5f', 'msg 2 thread_id')
  eq(res_list[2].reply_to, 'ic-wisp-a0', 'msg 2 reply_to')

  eq(res_list[3].id, 'ic-wisp-a2', 'msg 3 id')
  eq(res_list[3].from, 'mayor', 'msg 3 from')
  eq(res_list[3].to, 'human', 'msg 3 to')
  eq(res_list[3].subject, 'read message', 'msg 3 subject')
  eq(res_list[3].body, 'body of read', 'msg 3 body')
  eq(res_list[3].closed, false, 'msg 3 closed')
  eq(res_list[3].read, true, 'msg 3 read')
  eq(res_list[3].thread_id, nil, 'msg 3 thread_id')
  eq(res_list[3].reply_to, nil, 'msg 3 reply_to')

  eq(res_list[4].id, 'ic-wisp-a5', 'msg 4 id')
  eq(res_list[4].from, 'human', 'msg 4 from')
  eq(res_list[4].to, 'mayor', 'msg 4 to')
  eq(res_list[4].subject, 'no labels', 'msg 4 subject')
  eq(res_list[4].body, 'body without labels', 'msg 4 body')
  eq(res_list[4].closed, false, 'msg 4 closed')
  eq(res_list[4].read, false, 'msg 4 read')
  eq(res_list[4].thread_id, nil, 'msg 4 thread_id')
  eq(res_list[4].reply_to, nil, 'msg 4 reply_to')

  eq(res_list[5].id, 'ic-wisp-a6', 'msg 5 id')
  eq(res_list[5].from, 'planner', 'msg 5 from')
  eq(res_list[5].to, 'human', 'msg 5 to')
  eq(res_list[5].subject, 'no description', 'msg 5 subject')
  eq(res_list[5].body, '', 'msg 5 body absent is empty string')
  eq(res_list[5].closed, false, 'msg 5 closed')
  eq(res_list[5].read, false, 'msg 5 read')
  eq(res_list[5].thread_id, nil, 'msg 5 thread_id')
  eq(res_list[5].reply_to, nil, 'msg 5 reply_to')

  local skipped_notes = vim.tbl_filter(function(n)
    return n.message:find('2 messages could not be read', 1, true) ~= nil
  end, notes)
  eq(#skipped_notes, 1, 'skipped notice said once')

  done = false
  history.load(TWO[1], {}, function() done = true end)
  wait('second load done', function() return done end)
  skipped_notes = vim.tbl_filter(function(n)
    return n.message:find('2 messages could not be read', 1, true) ~= nil
  end, notes)
  eq(#skipped_notes, 1, 'notice still said once')
end)

test('a thread load runs -l thread:<id> and no --created-after; an id that is not a thread id runs nothing', function()
  local history = require('gc_mail.history')
  history.reset()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', '[]')
  local done, res_list, res_err
  history.load(TWO[1], { thread = 'thread-0a1b2c3d4e5f' }, function(list, err)
    done, res_list, res_err = true, list, err
  end)
  wait('thread load finished', function() return done end)
  eq(res_err, nil, 'no error')
  local calls = mail_calls()
  eq(#calls, 1, 'one call made')
  local argv = calls[1]
  eq(vim.tbl_contains(argv, '-l'), true, '-l flag present')
  eq(vim.tbl_contains(argv, 'thread:thread-0a1b2c3d4e5f'), true, 'thread id argument present')
  eq(vim.tbl_contains(argv, '--created-after'), false, 'no --created-after')

  local bad_done, bad_res, bad_err
  history.load(TWO[1], { thread = 'bad-thread-id' }, function(list, err)
    bad_done, bad_res, bad_err = true, list, err
  end)
  eq(bad_done, true, 'bad id returned immediately')
  eq(bad_res, nil, 'no list returned')
  assert(bad_err ~= nil, 'error returned')
  eq(#mail_calls(), 1, 'bad thread id ran no commands')
end)

test('a non-zero exit, a hung fake, a non-list answer and malformed JSON each give nil and the reason, and the cache is unchanged', function()
  local history = require('gc_mail.history')
  history.reset()
  eq(history.messages(TWO[1]), {}, 'cache empty initially')

  reset()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.exit', '1')
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.stderr', 'bd list: store failed\nline 2')
  local done, res_list, res_err
  history.load(TWO[1], {}, function(l, e) done, res_list, res_err = true, l, e end)
  wait('non-zero exit finished', function() return done end)
  eq(res_list, nil, 'exit 1 gives nil list')
  assert(res_err:find('failed: bd list: store failed'), 'exit 1 reason: ' .. tostring(res_err))
  eq(history.messages(TWO[1]), {}, 'cache unchanged on exit 1')

  reset()
  history.configure({ timeout_ms = 200 })
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.hang', '5')
  done, res_list, res_err = false, nil, nil
  history.load(TWO[1], {}, function(l, e) done, res_list, res_err = true, l, e end)
  wait('timeout finished', function() return done end, 5000)
  eq(res_list, nil, 'hang gives nil list')
  assert(res_err:find('did not answer within 0.2 s'), 'hang reason: ' .. tostring(res_err))
  eq(history.messages(TWO[1]), {}, 'cache unchanged on timeout')
  history.configure({ timeout_ms = 10000 })

  reset()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', '{"ok": true}')
  done, res_list, res_err = false, nil, nil
  history.load(TWO[1], {}, function(l, e) done, res_list, res_err = true, l, e end)
  wait('non-list finished', function() return done end)
  eq(res_list, nil, 'non-list gives nil list')
  assert(res_err:find('printed something unexpected'), 'non-list reason: ' .. tostring(res_err))
  eq(history.messages(TWO[1]), {}, 'cache unchanged on non-list')

  reset()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', '{ bad json')
  done, res_list, res_err = false, nil, nil
  history.load(TWO[1], {}, function(l, e) done, res_list, res_err = true, l, e end)
  wait('malformed finished', function() return done end)
  eq(res_list, nil, 'malformed gives nil list')
  assert(res_err:find('printed something unexpected'), 'malformed reason: ' .. tostring(res_err))
  eq(history.messages(TWO[1]), {}, 'cache unchanged on malformed json')
end)

test('two loads at once make one gc call and both callbacks run', function()
  local history = require('gc_mail.history')
  history.reset()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.delay', '0.2')
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', '[]')
  local done1, done2 = false, false
  local list1, list2
  history.load(TWO[1], {}, function(l) done1, list1 = true, l end)
  history.load(TWO[1], {}, function(l) done2, list2 = true, l end)
  wait('both callbacks run', function() return done1 and done2 end)
  eq(#list1, 0, 'list 1')
  eq(#list2, 0, 'list 2')
  eq(#mail_calls(), 1, 'only one gc call was made')
end)

test('history.conversation(city, mayor) returns only the human<->mayor messages, oldest first', function()
  local history = require('gc_mail.history')
  history.reset()
  history.put(TWO[1], { id = 'ic-wisp-a0', from = 'human', to = 'mayor', created = 100 })
  history.put(TWO[1], { id = 'ic-wisp-a1', from = 'mayor', to = 'human', created = 200 })
  history.put(TWO[1], { id = 'ic-wisp-a2', from = 'planner', to = 'human', created = 300 })
  history.put(TWO[1], { id = 'ic-wisp-a3', from = 'human', to = 'mayor', created = 400 })
  local conv = history.conversation(TWO[1], 'mayor')
  eq(#conv, 3, 'three human<->mayor messages')
  eq(conv[1].id, 'ic-wisp-a0', 'first')
  eq(conv[2].id, 'ic-wisp-a1', 'second')
  eq(conv[3].id, 'ic-wisp-a3', 'third')
end)

test('the thread view t in the mailbox renders every message of the thread, closed ones marked, from one bd list call', function()
  preload()
  local history = require('gc_mail.history')
  history.reset()
  local fixture = [=[
[
  {
    "id": "ic-wisp-a0",
    "title": "first thread message",
    "sender": "human",
    "assignee": "mayor",
    "status": "closed",
    "created_at": "2026-10-07T10:00:00Z",
    "description": "body of first",
    "labels": [
      "thread:thread-0a1b2c3d4e5f"
    ]
  },
  {
    "id": "ic-wisp-a1",
    "title": "second thread message",
    "sender": "mayor",
    "assignee": "human",
    "status": "open",
    "created_at": "2026-10-07T11:00:00Z",
    "description": "body of second",
    "labels": [
      "thread:thread-0a1b2c3d4e5f"
    ]
  }
]
]=]
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fixture)
  write(vim.env.FAKE_GC_MAIL .. '/inbox.demo-city.json', vim.json.encode({
    schema_version = '1', ok = true, recipients = { 'human' },
    messages = {
      { id = 'ic-wisp-a1', from = 'mayor', to = 'human', subject = 'second thread message', body = 'body of second',
        created_at = '2026-10-07T11:00:00Z', read = false, thread_id = 'thread-0a1b2c3d4e5f' }
    }
  }))
  write(vim.env.FAKE_GC_MAIL .. '/inbox.other-city.json', vim.json.encode({ schema_version = '1', ok = true, recipients = { 'human' }, messages = {} }))

  local win = require('gc_mail.mailbox').open()
  wait('mailbox filled', function()
    return #lines_of(win) == 1 and not lines_of(win)[1]:find('loading')
  end)

  vim.api.nvim_feedkeys('t', 'x', false)
  wait('thread scratch opened', function()
    return #floats() == 0 and vim.api.nvim_buf_get_name(0):find('^gc%-mail://demo%-city/thread/thread%-0a1b2c3d4e5f') ~= nil
  end)
  local t_buf = vim.api.nvim_get_current_buf()
  local t_lines = vim.api.nvim_buf_get_lines(t_buf, 0, -1, false)
  eq(t_lines[1], '# first thread message', 'title is first subject')
  assert(t_lines[3]:find('^## human · 2026%-10%-07T10:00:00Z %(closed%)'), 'closed message marked (closed): ' .. t_lines[3])
  assert(t_lines[9]:find('^## mayor · 2026%-10%-07T11:00:00Z$'), 'open message has no (closed): ' .. t_lines[9])

  local calls = mail_calls()
  local thread_calls = vim.tbl_filter(function(c) return c[4] == 'thread' end, calls)
  local bd_list_calls = vim.tbl_filter(function(c) return c[3] == 'bd' and c[4] == 'list' end, calls)
  eq(#thread_calls, 0, 'no gc mail thread call made')
  eq(#bd_list_calls, 1, 'one bd list call made')

  vim.cmd('silent! close')
  reset()
  write(vim.env.FAKE_GC_MAIL .. '/inbox.demo-city.json', vim.json.encode({
    schema_version = '1', ok = true, recipients = { 'human' },
    messages = {
      { id = 'ic-wisp-a2', from = 'mayor', to = 'human', subject = 'no thread id', body = 'body',
        created_at = '2026-10-07T12:00:00Z', read = false }
    }
  }))
  write(vim.env.FAKE_GC_MAIL .. '/inbox.other-city.json', vim.json.encode({ schema_version = '1', ok = true, recipients = { 'human' }, messages = {} }))
  write(vim.env.FAKE_GC_MAIL .. '/thread.demo-city.json', vim.json.encode({
    schema_version = '1', ok = true, thread_id = 'thread-112233445566',
    messages = {
      { id = 'ic-wisp-a2', from = 'mayor', to = 'human', subject = 'no thread id', body = 'body',
        created_at = '2026-10-07T12:00:00Z', read = false, thread_id = 'thread-112233445566' }
    }
  }))
  win = require('gc_mail.mailbox').open()
  wait('mailbox filled', function()
    return #lines_of(win) == 1 and not lines_of(win)[1]:find('loading')
  end)
  vim.api.nvim_feedkeys('t', 'x', false)
  wait('thread scratch opened for fallback', function()
    return #floats() == 0 and vim.api.nvim_buf_get_name(0):find('^gc%-mail://demo%-city/thread/ic%-wisp%-a2') ~= nil
  end)
  calls = mail_calls()
  thread_calls = vim.tbl_filter(function(c) return c[4] == 'thread' and c[5] == 'ic-wisp-a2' end, calls)
  eq(#thread_calls, 1, 'message without thread_id called gc mail thread')
end)

test('settle after another process took the claim leaves the subscriber count of calls unchanged', function()
  local sub_calls = 0
  gc_mail.queue.subscribe('count_sub', function()
    sub_calls = sub_calls + 1
  end)
  vim.env.FAKE_GC_DELAY = '0.3'
  local id = assert(gc_mail.queue.add(TWO[1], { subject = 'claim-test', body = 'body' }))
  wait('subscriber saw add', function() return sub_calls == 1 end)
  gc_mail.queue.pump()
  wait('claimed file exists', function()
    local sp = spool()
    return #sp > 0 and sp[1]:find('%.sending%-') ~= nil
  end)
  wait('subscriber saw claim', function() return sub_calls == 2 end)
  local claimed_file = spool()[1]
  assert(os.remove(queue_dir .. '/' .. claimed_file))
  local before_calls = sub_calls
  wait('send finished', gc_mail.queue.idle)
  vim.wait(100)
  eq(sub_calls, before_calls, 'subscriber count of calls unchanged')
  gc_mail.queue.subscribe('count_sub', nil)
end)

test(':GcMail <to> in a reply buffer sends to sender and warns', function()
  notes = {}
  local buf = buffer({ 'Re: test reply', '', 'reply body' })
  vim.api.nvim_buf_set_var(buf, 'gc_mail_reply', {
    city = TWO[1], id = 'ic-wisp-a0', to = 'mayor',
  })
  preload()
  vim.cmd('GcMail other')
  wait('sent', drained)
  eq(recorded_argv()[4], 'reply', 'verb is reply')
  eq(recorded_argv()[5], 'ic-wisp-a0', 'replies to message id')
  local warns = vim.tbl_filter(function(n)
    return n.level == vim.log.levels.WARN and n.message == 'gc-mail: this buffer replies to mayor; other ignored'
  end, notes)
  eq(#warns, 1, 'warning shown')
end)

test('events subscriber receives decoded mail.sent with payload.message, nil message for mail.read, and drops non-mail/non-JSON/half-lines', function()
  local cities, log = city_dirs()
  write(log, '')
  local events = require('gc_mail.events')
  local received = {}
  events.subscribe('test_sub', function(city, ev)
    received[#received + 1] = { city = city, event = ev }
  end)
  events.cities('test_sub', { cities[1] })

  local payload_msg = {
    id = 'ic-wisp-a1',
    from = 'human',
    to = 'mayor',
    subject = 'test subject',
    body = 'test body',
    created_at = '2026-10-08T10:00:00Z',
    read = false,
    thread_id = 'thread-0a1b2c3d4e5f',
  }
  local line1 = vim.json.encode({
    seq = 1,
    type = 'mail.sent',
    subject = 'ic-wisp-a1',
    actor = 'human',
    payload = { message = payload_msg },
  }) .. '\n'
  append(log, line1)
  wait('received mail.sent', function()
    return #received == 1
  end)
  local ev1 = received[1].event
  eq(ev1.type, 'mail.sent')
  eq(ev1.id, 'ic-wisp-a1')
  eq(ev1.message.id, 'ic-wisp-a1')
  eq(ev1.message.from, 'human')
  eq(ev1.message.to, 'mayor')
  eq(ev1.message.subject, 'test subject')
  eq(ev1.message.body, 'test body')
  eq(ev1.message.created_at, '2026-10-08T10:00:00Z')
  eq(ev1.message.read, false)
  eq(ev1.message.thread_id, 'thread-0a1b2c3d4e5f')

  local line2 = vim.json.encode({
    seq = 2,
    type = 'mail.read',
    subject = 'ic-wisp-a1',
  }) .. '\n'
  append(log, line2)
  wait('received mail.read', function()
    return #received == 2
  end)
  local ev2 = received[2].event
  eq(ev2.type, 'mail.read')
  eq(ev2.id, 'ic-wisp-a1')
  eq(ev2.message, nil)

  local bead_line = vim.json.encode({ seq = 3, type = 'bead.updated', subject = 'ic-wisp-a1' }) .. '\n'
  local not_json = 'not json line\n'
  local half = '{"type":"mail.marked_read","subject":"ic-wisp-a1"'
  append(log, bead_line .. not_json .. half)
  vim.wait(300)
  eq(#received, 2, 'nothing for bead.updated, not JSON, or half line')
  append(log, '}\n')
  wait('received finished line', function()
    return #received == 3
  end)
  eq(received[3].event.type, 'mail.marked_read')
  eq(received[3].event.id, 'ic-wisp-a1')
  events.unsubscribe('test_sub')
end)

test('two subscribers on the same city both receive an event; after one unsubscribes the other still does; after both, events.running() is false and events.handles() is empty', function()
  local cities, log = city_dirs()
  write(log, '')
  local events = require('gc_mail.events')
  local rec1, rec2 = {}, {}
  events.subscribe('sub1', function(city, ev)
    rec1[#rec1 + 1] = ev
  end)
  events.cities('sub1', { cities[1] })
  events.subscribe('sub2', function(city, ev)
    rec2[#rec2 + 1] = ev
  end)
  events.cities('sub2', { cities[1] })

  append(log, event('mail.sent'))
  wait('both received event', function()
    return #rec1 == 1 and #rec2 == 1
  end)
  eq(rec1[1].type, 'mail.sent')
  eq(rec2[1].type, 'mail.sent')

  events.unsubscribe('sub1')
  append(log, event('mail.read'))
  wait('sub2 received second event', function()
    return #rec2 == 2
  end)
  vim.wait(100)
  eq(#rec1, 1, 'sub1 did not receive after unsubscribe')

  events.unsubscribe('sub2')
  eq(events.running(), false, 'running is false after all unsubscribe')
  eq(events.handles(), {}, 'handles is empty after all unsubscribe')
end)

test('an appended chunk over 1 MiB gives one overflow event and later lines are received; a recreated file gives rotated and later lines are received', function()
  local cities, log = city_dirs()
  write(log, '')
  local events = require('gc_mail.events')
  local rec = {}
  events.subscribe('test_overflow', function(city, ev)
    rec[#rec + 1] = ev
  end)
  events.cities('test_overflow', { cities[1] })

  append(log, string.rep('x', 1024 * 1024 + 10) .. '\n')
  wait('overflow event received', function()
    return #rec == 1
  end)
  eq(rec[1].type, 'overflow')

  append(log, event('mail.sent'))
  wait('later line received after overflow', function()
    return #rec == 2
  end)
  eq(rec[2].type, 'mail.sent')

  assert(os.remove(log))
  vim.wait(50)
  write(log, '')
  wait('rotated event received after recreate', function()
    return rec[#rec].type == 'watching' and rec[#rec].watching == true
  end)
  -- The log gone unwatched, then the new one armed and reported once
  eq(vim.tbl_map(function(ev)
    return ev.type == 'watching' and 'watching ' .. tostring(ev.watching) or ev.type
  end, vim.list_slice(rec, 3)), { 'watching false', 'rotated', 'watching true' })

  append(log, event('mail.read'))
  wait('later line received after rotation', function()
    return #rec == 6
  end)
  eq(rec[6].type, 'mail.read')
  events.unsubscribe('test_overflow')
end)

test('events.cities with a second city watches both; dropping the city from every subscriber closes its handle', function()
  local cities, log1 = city_dirs()
  local log2 = cities[2].path .. '/.gc/events.jsonl'
  write(log1, '')
  write(log2, '')
  local events = require('gc_mail.events')
  local rec = {}
  events.subscribe('multi_city', function(city, ev)
    rec[#rec + 1] = { city = city, event = ev }
  end)
  events.cities('multi_city', { cities[1], cities[2] })

  local function has_fs_event(path)
    for _, h in ipairs(events.handles()) do
      if h:get_type() == 'fs_event' and not h:is_closing() and h:getpath() == path then
        return true
      end
    end
    return false
  end

  wait('both files watched', function()
    return has_fs_event(log1) and has_fs_event(log2)
  end)

  append(log1, event('mail.sent'))
  append(log2, event('mail.sent'))
  wait('both events received', function()
    return #rec == 2
  end)
  eq(rec[1].city.name, 'demo-city')
  eq(rec[2].city.name, 'other-city')

  events.cities('multi_city', { cities[1] })
  wait('city2 handle closed', function()
    return not has_fs_event(log2)
  end)
  eq(has_fs_event(log1), true, 'city1 still watched')

  append(log2, event('mail.read'))
  vim.wait(300)
  eq(#rec, 2, 'dropped city event not received')

  append(log1, event('mail.read'))
  wait('city1 event received', function()
    return #rec == 3
  end)
  events.unsubscribe('multi_city')
end)

test('a subscriber that raises does not stop a second subscriber (its error said once)', function()
  notes = {}
  local cities, log = city_dirs()
  write(log, '')
  local events = require('gc_mail.events')
  local rec = {}
  events.subscribe('broken', function(city, ev)
    error('subscriber exploded')
  end)
  events.subscribe('good', function(city, ev)
    rec[#rec + 1] = ev
  end)
  events.cities('broken', { cities[1] })
  events.cities('good', { cities[1] })

  append(log, event('mail.sent'))
  wait('good received first event', function()
    return #rec == 1
  end)
  eq(rec[1].type, 'mail.sent')

  local err_notes = vim.tbl_filter(function(n)
    return n.level == vim.log.levels.ERROR and n.message:find('subscriber broken failed')
  end, notes)
  eq(#err_notes, 1, 'error said once')

  append(log, event('mail.read'))
  wait('good received second event', function()
    return #rec == 2
  end)
  eq(rec[2].type, 'mail.read')

  err_notes = vim.tbl_filter(function(n)
    return n.level == vim.log.levels.ERROR and n.message:find('subscriber broken failed')
  end, notes)
  eq(#err_notes, 1, 'error still said only once')

  events.unsubscribe('broken')
  events.unsubscribe('good')
end)

-- ---- the background watch ----------------------------------------------------

local function count_answer(city, unread)
  answer('count', { recipient = 'human', recipients = { 'human' }, total = unread + 2, unread = unread }, city)
end

local function count_calls(path)
  return #vim.tbl_filter(function(c)
    return c[4] == 'count' and (path == nil or c[2] == path)
  end, mail_calls())
end

-- One mail line of an event log, as gc writes it, for message `id`.
local function mail_line(kind, id, fields)
  local line = { seq = 1, type = kind, ts = '2026-10-08T10:00:00Z', actor = 'mayor', subject = id }
  if fields then
    line.payload = { message = msg(id, fields) }
  end
  return vim.json.encode(line) .. '\n'
end

-- The two cities with empty event logs, counts of 2 and 1 unread mail, and
-- the plugin set up with the watch on (or as `opts` say).
local function watched(opts, unread)
  unread = unread or { 2, 1 }
  local cities, log = city_dirs()
  local log2 = cities[2].path .. '/.gc/events.jsonl'
  write(log, '')
  write(log2, '')
  count_answer('demo-city', unread[1])
  count_answer('other city', unread[2])
  gc_mail.setup(vim.tbl_extend('force', { keymap = false, mailbox_keymap = false, panel_keymap = false,
    state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY }, opts or {}))
  return cities, log, log2
end

local function seeded(total)
  wait('the watch counted every city', function()
    return gc_mail.status() == ' ' .. total
  end)
end

test('the watch is on by default: nothing runs before startup finishes, then one count per city and status() is the total', function()
  eq(gc_mail.status(), '', 'status before setup')
  eq(package.loaded['gc_mail.watch'], nil, 'the watch loaded at load time')
  local cities = watched()
  eq(count_calls(), 0, 'setup counted mail')
  eq(package.loaded['gc_mail.watch'], nil, 'setup loaded the watch')
  seeded(3)
  vim.wait(200)
  eq(count_calls(), 2, 'one count call per city')
  eq(count_calls(cities[1].path), 1, 'the first city once')
  eq(count_calls(cities[2].path), 1, 'the second city once')
  eq(has_call(call('count', cities[1].path, 'human', '--json')), true, 'count argv')
  eq(#notes, 0, 'the first count is no arrival')
end)

test('watch = false starts nothing after startup and status() stays empty', function()
  watched({ watch = false })
  wait('the city list was preloaded', function()
    return gc_mail.cached_cities() ~= nil
  end)
  vim.wait(200)
  eq(mail_calls(), {}, 'a mail command ran')
  eq(gc_mail.status(), '', 'status')
  eq(package.loaded['gc_mail.watch'], nil, 'the watch was loaded')
  eq(package.loaded['gc_mail.events'], nil, 'events were loaded')
end)

test('a mail for you raises one notice and adds one; the same id again, other recipients and your own mail change nothing', function()
  local _, log = watched()
  seeded(3)
  append(log, mail_line('mail.sent', 'ic-wisp-a1', { subject = 'Build done', created_at = '2026-10-08T10:00:00Z' }))
  seeded(4)
  eq(#notes, 1, 'one notice')
  eq(notes[1].message, 'gc-mail: mayor in demo-city: Build done', 'the notice')
  eq(notes[1].level, vim.log.levels.INFO, 'its level')
  append(log, mail_line('mail.sent', 'ic-wisp-a1', { subject = 'Build done' }))
  vim.wait(300)
  eq({ #notes, gc_mail.status() }, { 1, ' 4' }, 'the same id again')
  append(log, mail_line('mail.marked_read', 'ic-wisp-a1'))
  seeded(3)
  append(log, mail_line('mail.marked_unread', 'ic-wisp-a1'))
  seeded(4)
  eq(#notes, 1, 'marking it unread says nothing')
  append(log, mail_line('mail.sent', 'ic-wisp-b2', { to = 'planner' }))
  append(log, mail_line('mail.sent', 'ic-wisp-c3', { from = 'human', to = 'human' }))
  append(log, mail_line('mail.sent', 'ic-wisp-d4', { from = 'human', to = 'mayor' }))
  vim.wait(300)
  eq({ #notes, gc_mail.status() }, { 1, ' 4' }, 'mail for others and from you')
  append(log, mail_line('mail.replied', 'ic-wisp-e5', { subject = 'Re: Build done' }))
  seeded(5)
  eq(notes[2].message, 'gc-mail: mayor in demo-city: Re: Build done', 'a reply counts too')
  append(log, mail_line('mail.archived', 'ic-wisp-e5'))
  seeded(4)
  append(log, mail_line('mail.deleted', 'ic-wisp-a1'))
  seeded(3)
  eq(count_calls(), 2, 'the events moved the count without another call')
end)

test('a notice is one line and the subject is cut at 72 characters', function()
  local _, log = watched()
  seeded(3)
  append(log, mail_line('mail.sent', 'ic-wisp-a1', { from = 'may\nor', subject = 'first\nsecond ' .. string.rep('x', 100) }))
  seeded(4)
  local subject = ('first / second ' .. string.rep('x', 100)):sub(1, 72)
  eq(notes[1].message, 'gc-mail: may / or in demo-city: ' .. subject, 'one line, 72 characters of subject')
end)

test('no notice while the chat of that city and sender is open and current; the count still grows', function()
  local _, log = watched()
  seeded(3)
  local asked = {}
  package.loaded['gc_mail.chat'] = {
    is_current = function(city, with)
      asked[#asked + 1] = { city.name, with }
      return city.name == 'demo-city' and with == 'mayor'
    end,
  }
  append(log, mail_line('mail.sent', 'ic-wisp-a1', { from = 'mayor' }))
  seeded(4)
  eq(#notes, 0, 'the chat shows it')
  eq(asked, { { 'demo-city', 'mayor' } }, 'asked the chat once')
  append(log, mail_line('mail.sent', 'ic-wisp-b2', { from = 'planner' }))
  seeded(5)
  eq(#notes, 1, 'another sender still raises a notice')
end)

test('a count never goes below zero and an unknown id changes nothing', function()
  local cities, log = watched(nil, { 0, 0 })
  wait('counted', function()
    return count_calls() == 2 and require('gc_mail.watch').unread[cities[2].path] ~= nil
  end)
  eq(gc_mail.status(), '', 'nothing unread')
  append(log, mail_line('mail.read', 'ic-wisp-zz'))
  append(log, mail_line('mail.marked_read', 'ic-wisp-zz'))
  append(log, mail_line('mail.archived', 'ic-wisp-zz'))
  append(log, mail_line('mail.deleted', 'ic-wisp-zz'))
  vim.wait(300)
  eq(gc_mail.status(), '', 'still zero')
  eq(require('gc_mail.watch').unread, { [cities[1].path] = 0, [cities[2].path] = 0 }, 'counts')
end)

test('an overflow or a recreated log counts that city again; the resync timer counts every city again', function()
  local cities, log = watched()
  seeded(3)
  eq(count_calls(), 2, 'one count per city')
  append(log, string.rep('x', 1024 * 1024 + 10) .. '\n')
  wait('counted again after an overflow', function()
    return count_calls(cities[1].path) == 2
  end)
  vim.wait(200)
  eq(count_calls(cities[2].path), 1, 'the other city was not counted')
  assert(os.remove(log))
  vim.wait(50)
  write(log, '')
  wait('counted again after a recreated log', function()
    return count_calls(cities[1].path) == 3
  end)
  count_answer('demo-city', 5)
  append(log, string.rep('x', 1024 * 1024 + 10) .. '\n')
  seeded(6)
  require('gc_mail.watch').configure({ resync_ms = 100 })
  wait('the timer counts every city', function()
    return count_calls(cities[2].path) >= 3
  end)
end)

test('a mail counted by a recount is still taken off when it is read; a repeat of an old arrival counts nothing', function()
  local cities, log = watched()
  seeded(3)
  append(log, mail_line('mail.sent', 'ic-wisp-a1', { subject = 'Build done' }))
  seeded(4)
  count_answer('demo-city', 3)
  append(log, string.rep('x', 1024 * 1024 + 10) .. '\n')
  wait('counted again after an overflow', function()
    return count_calls(cities[1].path) == 2
  end)
  vim.wait(100)
  eq(gc_mail.status(), ' 4', 'the recount includes the arrival')
  append(log, mail_line('mail.read', 'ic-wisp-a1'))
  seeded(3)
  -- More arrivals than any bounded memory of ids would keep: the first one
  -- repeated is still not a new message.
  local lines = {}
  for n = 1, 600 do
    lines[#lines + 1] = mail_line('mail.sent', ('ic-wisp-m%d'):format(n), { subject = 'bulk' })
  end
  append(log, table.concat(lines))
  seeded(603)
  eq(#notes, 601, 'one notice per message')
  append(log, mail_line('mail.sent', 'ic-wisp-a1', { subject = 'Build done' }))
  append(log, mail_line('mail.sent', 'ic-wisp-m1', { subject = 'bulk' }))
  vim.wait(300)
  eq({ #notes, gc_mail.status() }, { 601, ' 603' }, 'repeats of old arrivals')
end)

test('a failed count is said once and the count is kept', function()
  local cities, log = watched()
  seeded(3)
  raw_answer('count', 'exit', '1', 'demo-city')
  raw_answer('count', 'stderr', 'store unavailable\n', 'demo-city')
  for n = 2, 3 do
    append(log, string.rep('x', 1024 * 1024 + 10) .. '\n')
    wait('counted again', function()
      return count_calls(cities[1].path) == n
    end)
    vim.wait(100)
  end
  local errors_said = vim.tbl_filter(function(n)
    return n.level == vim.log.levels.ERROR
  end, notes)
  eq(#errors_said, 1, 'said once')
  assert(errors_said[1].message:find('store unavailable', 1, true), errors_said[1].message)
  eq(gc_mail.status(), ' 3', 'the count is kept')
end)

test('setup({ watch = false }) again stops a running watch', function()
  local _, log = watched()
  seeded(3)
  local events = require('gc_mail.events')
  eq(events.running(), true, 'events are watched')
  gc_mail.setup({ keymap = false, mailbox_keymap = false, panel_keymap = false, state_dir = vim.fs.dirname(queue_dir),
    retry_ms = RETRY, watch = false })
  eq(require('gc_mail.watch').running(), false, 'stopped')
  eq(gc_mail.status(), '', 'status')
  eq(events.running(), false, 'events unsubscribed')
  append(log, mail_line('mail.sent', 'ic-wisp-a1', { from = 'mayor' }))
  vim.wait(300)
  eq({ #notes, gc_mail.status() }, { 0, '' }, 'a mail after the stop')
end)

test('setup refuses watch that is not true or false and a watch_resync_ms under a minute', function()
  local ok, err = pcall(gc_mail.setup, { watch = 'yes' })
  eq(ok, false, 'watch = yes')
  assert(tostring(err):find('watch must be true or false', 1, true), tostring(err))
  ok, err = pcall(gc_mail.setup, { watch_resync_ms = 1000 })
  eq(ok, false, 'watch_resync_ms = 1000')
  assert(tostring(err):find('watch_resync_ms must be a number of milliseconds of at least 60000', 1, true), tostring(err))
  eq(gc_mail.status(), '', 'status')
end)

test('setup({ events_rearm_ms = 1000 }) raises', function()
  local ok, err = pcall(gc_mail.setup, { events_rearm_ms = 1000 })
  eq(ok, false, 'raises on events_rearm_ms < 15000')
  assert(tostring(err):find('events_rearm_ms must be a number of milliseconds of at least 15000'), tostring(err))
end)

test('history.load decodes recipient as metadata["gc.routed_to"] when assignee is null, and skips when both are missing or assignee is malformed', function()
  local history = require('gc_mail.history')
  history.reset()
  local fixture = [=[
[
  {
    "id": "sc-wisp-r1",
    "title": "routed to pool",
    "sender": "human",
    "assignee": null,
    "status": "open",
    "created_at": "2026-10-07T10:00:00Z",
    "description": "body",
    "metadata": {
      "gc.routed_to": "rig/builder"
    }
  },
  {
    "id": "sc-wisp-r2",
    "title": "missing both",
    "sender": "human",
    "assignee": null,
    "status": "open",
    "created_at": "2026-10-07T11:00:00Z",
    "description": "body",
    "metadata": {}
  },
  {
    "id": "sc-wisp-r3",
    "title": "malformed assignee type",
    "sender": "human",
    "assignee": 7,
    "status": "open",
    "created_at": "2026-10-07T12:00:00Z",
    "description": "body",
    "metadata": {
      "gc.routed_to": "rig/builder"
    }
  }
]
]=]
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fixture)
  local done, res_list, res_err, res_skipped
  history.load(TWO[1], function(list, err, skipped)
    done, res_list, res_err, res_skipped = true, list, err, skipped
  end)
  wait('history.load finished', function()
    return done
  end)
  eq(res_err, nil)
  eq(#res_list, 1, 'one valid decoded message')
  eq(res_list[1].id, 'sc-wisp-r1')
  eq(res_list[1].to, 'rig/builder', 'to is rig/builder from gc.routed_to')
  eq(res_skipped, 2, 'two skipped: one missing both, one with malformed assignee number')
end)

test('events subscriber receives event with escaped JSON type', function()
  local events = require('gc_mail.events')
  events.reset()
  local cities, log = city_dirs()
  write(log, '')
  local rec = {}
  events.subscribe('escaped_test', function(city, ev)
    table.insert(rec, { city = city.name, event = ev })
  end)
  events.cities('escaped_test', { cities[1] })
  wait('watcher is running', events.running)

  local line = '{"type":"\\u006dail.sent","subject":"ic-wisp-esc","actor":"human","payload":{"message":{"id":"ic-wisp-esc","from":"human","to":"mayor","subject":"hello","body":"body","created_at":"2026-10-07T10:00:00Z"}}}\n'
  append(log, line)

  wait('escaped type event received', function()
    return #rec == 1
  end)
  eq(rec[1].event.type, 'mail.sent')
  eq(rec[1].event.id, 'ic-wisp-esc')
  events.unsubscribe('escaped_test')
end)

test('rearm_missing reports rotated when a previously armed city log is recreated and rearmed', function()
  local events = require('gc_mail.events')
  events.reset()
  local cities, log = city_dirs()
  write(log, '')
  local rec = {}
  events.subscribe('rot_test', function(city, ev)
    table.insert(rec, ev.type)
  end)
  events.cities('rot_test', { cities[1] })
  wait('watcher is running', events.running)

  assert(os.remove(log))
  vim.wait(300)

  write(log, '')
  events.rearm()

  wait('rotated received after rearm_missing', function()
    return vim.tbl_contains(rec, 'rotated')
  end)

  append(log, event('mail.sent'))
  wait('mail.sent received after rotated', function()
    return vim.tbl_contains(rec, 'mail.sent')
  end)

  events.unsubscribe('rot_test')
end)

-- ---- the demo recording ---------------------------------------------------------

local function keys()
  package.loaded['demo.keys'] = nil
  return require('demo.keys')
end

test('demo keys: special keys, chords and plain keys read as on a keyboard', function()
  local k = keys()
  eq(k.format({ ' ', 'm', 'p' }), '<Space> m p', 'a mapped sequence one key at a time')
  eq(k.format({ ' mp' }), '<Space> m p', 'a mapped sequence typed as one string')
  eq(k.format({ '\r', '\27', '\t', vim.api.nvim_replace_termcodes('<BS>', true, true, true) }), '<CR> <Esc> <Tab> <BS>',
    'special keys')
  eq(k.format({ '\23', 'j' }), '<C-w> j', 'a control chord is lower case')
  eq(k.format({ '<', '|' }), '< |', 'a literal < is not read as a key name')
  eq(k.format({}), '', 'nothing typed')
  eq(k.format({ vim.api.nvim_replace_termcodes('<LeftMouse>', true, true, true), 'x' }), 'x', 'a mouse key is not shown')
end)

test('demo keys: plain characters typed as text are grouped, other keys stay labels', function()
  local k = keys()
  local function typed(text)
    local list = {}
    for char in text:gmatch('.') do
      list[#list + 1] = { key = char, text = true }
    end
    return list
  end
  eq(k.format(typed('thanks, shipping')), 'thanks, shipping', 'letters and spaces are one text')
  local mixed = { 'i' }
  vim.list_extend(mixed, typed('ok '))
  mixed[#mixed + 1] = { key = '\27' }
  eq(k.format(mixed), 'i ok  <Esc>', 'a text between keys')
  eq(k.format({ { key = ' ', text = false }, { key = 'm', text = false } }), '<Space> m', 'in normal mode a space is a key')
end)

test('demo keys: the shown line is capped and keeps the newest keys', function()
  local k = keys()
  local long = {}
  for _ = 1, 30 do
    long[#long + 1] = 'j'
  end
  long[#long + 1] = '\r'
  local line = k.format(long, 12)
  eq(vim.fn.strchars(line), 12, 'at most max characters')
  eq(vim.startswith(line, '…'), true, 'cut at the old end')
  eq(vim.endswith(line, '<CR>'), true, 'the newest key stays')
  eq(vim.fn.strchars(k.format(long)) <= k.MAX, true, 'the default cap')
end)

-- demo/bin/gc runs as a child on a demo directory of its own.
local demo_gc = root .. '/demo/bin/gc'

local function demo_dir()
  local dir = ('%s/demo-%d'):format(scratch, vim.uv.hrtime())
  vim.fn.mkdir(dir, 'p')
  return dir, dir .. '/demo-city'
end

local function gc_run(dir, args, extra)
  local result = vim.system(vim.list_extend({ demo_gc }, args), {
    text = true, env = vim.tbl_extend('force', { GC_DEMO_DIR = dir }, extra or {}),
  }):wait(20000)
  return result
end

-- A demo gc call as the plugin's own decoders read it.
local function gc_json(dir, city, verb, ...)
  local result = gc_run(dir, vim.list_extend({ '--city', city, 'mail', verb }, { ... }))
  eq(result.code, 0, 'exit of ' .. verb .. ': ' .. (result.stderr or ''))
  local record, why = mailbox().answer(result, 'demo ' .. verb)
  assert(record, why)
  return record
end

local function inbox_of(dir, city, who)
  local record = gc_json(dir, city, 'inbox', who, '--json')
  local messages, why = mailbox().DECODE.inbox(record)
  assert(messages, why)
  return messages
end

test('demo gc: refuses to run without its own directory', function()
  local result = vim.system({ demo_gc, 'cities', '--json' }, { text = true, env = { GC_DEMO_DIR = '' } }):wait(20000)
  eq(result.code, 2, 'refused')
  eq(result.stderr:find('GC_DEMO_DIR', 1, true) ~= nil, true, 'says why')
  eq(result.stdout, '', 'prints no answer')
end)

test('demo gc: the seeded store lists in inbox, as the mailbox decoder reads it', function()
  local dir, city = demo_dir()
  eq(gc_run(dir, { 'seed' }).code, 0, 'seed')
  local cities = gc_run(dir, { 'cities', '--json' })
  local record = vim.json.decode(vim.trim(cities.stdout))
  eq({ record.ok, #record.cities, record.cities[1].name, record.cities[1].path }, { true, 1, 'demo-city', city }, 'one demo city')
  eq(vim.fn.isdirectory(city .. '/.gc'), 1, 'its event log directory exists')
  eq(vim.fn.filereadable(city .. '/.gc/events.jsonl'), 1, 'and its event log')
  local messages = inbox_of(dir, city, 'human')
  eq(#messages >= 5 and #messages <= 8, true, '5 to 8 messages for human, got ' .. #messages)
  local unread, senders, threads, days = 0, {}, {}, {}
  for _, m in ipairs(messages) do
    unread = unread + (m.read and 0 or 1)
    senders[m.from] = true
    threads[m.thread_id] = (threads[m.thread_id] or 0) + 1
    days[os.date('!%Y-%m-%d', m.created)] = true
  end
  eq(#messages - unread, 1, 'one message is read')
  eq({ senders.mayor, senders.builder, senders.reviewer }, { true, true, true }, 'from mayor, builder and reviewer')
  eq(vim.tbl_count(days) >= 3, true, 'spread over a few days')
  local biggest = 0
  for _, count in pairs(threads) do
    biggest = math.max(biggest, count)
  end
  eq(biggest >= 2, true, 'a thread in the inbox')
  -- The thread of three: mail thread, and bd list for the history decoder.
  local thread_id
  for id, count in pairs(threads) do
    if count == biggest then
      thread_id = id
    end
  end
  local thread = gc_json(dir, city, 'thread', thread_id, '--json')
  local listed = mailbox().DECODE.thread(thread, thread_id)
  eq(#listed, 3, 'the thread has three messages')
  local counted = gc_json(dir, city, 'count', 'human', '--json')
  eq(mailbox().DECODE.count(counted), unread, 'count agrees with the inbox')
end)

test('demo gc: bd list decodes as history, and a thread loads by label', function()
  local dir, city = demo_dir()
  gc_run(dir, { 'seed' })
  local old_path, old_dir = vim.env.PATH, vim.env.GC_DEMO_DIR
  vim.env.PATH, vim.env.GC_DEMO_DIR = root .. '/demo/bin:' .. old_path, dir
  local history = require('gc_mail.history')
  history.reset()
  local list, err, skipped
  history.load({ name = 'demo-city', path = city }, function(l, e, s)
    list, err, skipped = l, e, s
    list = list or {}
  end)
  wait('history loaded', function()
    return list ~= nil
  end)
  vim.env.PATH, vim.env.GC_DEMO_DIR = old_path, old_dir
  eq(err, nil, 'no error')
  eq(skipped, 0, 'no record skipped')
  eq(#list, 7, 'every message of the store')
  local by_thread = {}
  for _, m in ipairs(list) do
    by_thread[m.thread_id] = (by_thread[m.thread_id] or 0) + 1
  end
  local thread_id
  for id, count in pairs(by_thread) do
    if count == 3 then
      thread_id = id
    end
  end
  assert(thread_id, 'a thread of three')
  eq(vim.tbl_count(vim.tbl_filter(function(m)
    return m.read
  end, list)), 1, 'the read label becomes read')
end)

test('demo gc: mail send and reply are stored as sent by human and can be listed', function()
  local dir, city = demo_dir()
  gc_run(dir, { 'seed' })
  local sent = gc_run(dir, { '--city', city, 'mail', 'send', 'mayor', '-s', 'Staging refresh', '-m', 'Who owns it?', '--notify' })
  eq(sent.code, 0, 'send: ' .. (sent.stderr or ''))
  local to_mayor = inbox_of(dir, city, 'mayor')
  eq(#to_mayor, 1, 'the sent message is in the mayor inbox')
  eq({ to_mayor[1].from, to_mayor[1].to, to_mayor[1].subject, to_mayor[1].body, to_mayor[1].read },
    { 'human', 'mayor', 'Staging refresh', 'Who owns it?', false }, 'as sent')
  local target = inbox_of(dir, city, 'human')[1]
  local replied = gc_run(dir, { '--city', city, 'mail', 'reply', target.id, '-s', 'Re: ' .. target.subject, '-m', 'Thanks', '--notify' })
  eq(replied.code, 0, 'reply: ' .. (replied.stderr or ''))
  local back = inbox_of(dir, city, target.from)
  eq(back[#back].thread_id, target.thread_id, 'a reply stays in its thread')
  -- mark-read / archive answer in the shapes the decoders require and change the inbox.
  local first = inbox_of(dir, city, 'human')[1]
  local marked = gc_json(dir, city, 'mark-read', first.id, '--json')
  assert(mailbox().DECODE['mark-read'](marked, first.id))
  local archived = gc_json(dir, city, 'archive', first.id, '--json')
  assert(mailbox().DECODE.archive(archived, first.id))
  for _, m in ipairs(inbox_of(dir, city, 'human')) do
    assert(m.id ~= first.id, 'an archived message leaves the inbox')
  end
  local bad = gc_run(dir, { '--city', dir .. '/elsewhere', 'mail', 'inbox', 'human', '--json' })
  eq(bad.code, 1, 'another city is refused')
end)

test('demo gc: an agent reply appends to the store and the event log, and the watcher decodes it', function()
  local dir, city = demo_dir()
  gc_run(dir, { 'seed' })
  local log = city .. '/.gc/events.jsonl'
  local before = #inbox_of(dir, city, 'human')
  local seen = {}
  local events = require('gc_mail.events')
  events.subscribe('demo_test', function(_, ev)
    seen[#seen + 1] = ev
  end)
  events.cities('demo_test', { { name = 'demo-city', path = city } })
  wait('watcher is running', events.running)
  local mayor_last = nil
  for _, m in ipairs(inbox_of(dir, city, 'human')) do
    if m.from == 'mayor' and (not mayor_last or m.created >= mayor_last.created) then
      mayor_last = m
    end
  end
  local result = gc_run(dir, { 'agent', 'mayor', 'reply', 'latest', 'Looks', 'good,', 'shipping', 'it' })
  eq(result.code, 0, 'agent reply: ' .. (result.stderr or ''))
  wait('the reply event arrives', function()
    return #seen > 0
  end)
  local ev = seen[1]
  eq(ev.type, 'mail.replied', 'event type')
  eq({ ev.message.from, ev.message.to }, { 'mayor', 'human' }, 'from and to')
  eq(ev.message.subject, 'Re: ' .. mayor_last.subject:gsub('^Re: ', ''), 'subject of the answered message')
  eq(ev.message.body, 'Looks good, shipping it', 'the text')
  eq(ev.id, ev.message.id, 'the event subject is the message id')
  eq(ev.message.thread_id, mayor_last.thread_id, 'in the same thread')
  eq(#inbox_of(dir, city, 'human'), before + 1, 'the store has the new message')
  local lines = vim.fn.readfile(log)
  eq(#lines, 1, 'one line in the event log')
  local raw = vim.json.decode(lines[1])
  eq({ raw.type, raw.seq, type(raw.ts) }, { 'mail.replied', 1, 'string' }, 'the line gc writes')
  -- A message of an agent's own: mail.sent.
  local send = gc_run(dir, { 'agent', 'builder', 'send', 'human', 'Build is green', 'All 214 specs pass on main.' })
  eq(send.code, 0, 'agent send: ' .. (send.stderr or ''))
  wait('the sent event arrives', function()
    return #seen > 1
  end)
  eq({ seen[2].type, seen[2].message.from, seen[2].message.subject }, { 'mail.sent', 'builder', 'Build is green' }, 'agent send')
  events.unsubscribe('demo_test')
  events.reset()
  local bad = gc_run(dir, { 'agent', 'mayor', 'reply', 'dc-zzzzzz', 'x' })
  eq(bad.code, 1, 'an unknown message is refused')
  eq(#vim.fn.readfile(log), 2, 'and writes nothing')
end)

test('demo gc: GC_DEMO_SEND_DELAY_MS holds a send back and the event follows it', function()
  local dir, city = demo_dir()
  gc_run(dir, { 'seed' })
  local started = vim.uv.hrtime()
  local sent = gc_run(dir, { '--city', city, 'mail', 'send', 'mayor', '-s', 'Slow', '-m', 'Takes a moment', '--notify' },
    { GC_DEMO_SEND_DELAY_MS = '400' })
  eq(sent.code, 0, 'send: ' .. (sent.stderr or ''))
  eq((vim.uv.hrtime() - started) / 1e6 >= 380, true, 'the send waited for the delay')
  local lines = vim.fn.readfile(city .. '/.gc/events.jsonl')
  eq(#lines, 1, 'one event after it')
  eq(vim.json.decode(lines[1]).type, 'mail.sent', 'a mail.sent')
end)

test('demo gc: an agent reply started while a send is still waiting answers that send', function()
  local dir, city = demo_dir()
  gc_run(dir, { 'seed' })
  -- An older exchange the agent has already answered would be the wrong target
  eq(gc_run(dir, { '--city', city, 'mail', 'send', 'mayor', '-s', 'First', '-m', 'first question', '--notify' }).code, 0, 'first send')
  eq(gc_run(dir, { 'agent', 'mayor', 'reply', 'latest', 'first', 'answer' }).code, 0, 'first answer')
  local send = vim.system({ demo_gc, '--city', city, 'mail', 'send', 'mayor', '-s', 'Second', '-m', 'second question', '--notify' },
    { text = true, env = { GC_DEMO_DIR = dir, GC_DEMO_SEND_DELAY_MS = '1200' } })
  wait('the send is waiting', function()
    return #vim.fn.glob(dir .. '/sending.*', false, true) == 1
  end)
  local result = gc_run(dir, { 'agent', 'mayor', 'reply', 'latest', 'second', 'answer' })
  eq(result.code, 0, 'agent reply: ' .. (result.stderr or ''))
  eq(send:wait(20000).code, 0, 'the send ended')
  eq(vim.fn.glob(dir .. '/sending.*', false, true), {}, 'and left no marker')
  local last
  for _, m in ipairs(inbox_of(dir, city, 'human')) do
    if m.from == 'mayor' and m.body == 'second answer' then
      last = m
    end
  end
  assert(last, 'the second answer is stored')
  eq(last.subject, 'Re: Second', 'it answers the second send, not the first')
end)

test('demo gc: an agent step ignores the marker of a send that is gone', function()
  local dir, city = demo_dir()
  gc_run(dir, { 'seed' })
  write(dir .. '/sending.99999999', '')
  local started = vim.uv.hrtime()
  local result = gc_run(dir, { 'agent', 'mayor', 'reply', 'latest', 'Fine' })
  eq(result.code, 0, 'agent reply: ' .. (result.stderr or ''))
  eq((vim.uv.hrtime() - started) / 1e6 < 5000, true, 'it did not wait for the dead marker')
end)

test('demo tours: every line is a step record.sh accepts, and the chat tour opens, sends and closes the chat', function()
  local steps = { key = true, type = true, wait = true, say = true, agent = true }
  for _, name in ipairs({ 'tour-basic.txt', 'tour-chat.txt' }) do
    for n, line in ipairs(vim.fn.readfile(root .. '/demo/' .. name)) do
      local text = vim.trim(line)
      if text ~= '' and text:sub(1, 1) ~= '#' then
        local step = text:match('^(%S+)')
        eq(steps[step], true, ('%s line %d: unknown step %s'):format(name, n, step))
        if step == 'agent' then
          eq(text:match('^agent%s+%l+%s+reply%s+latest%s+%S') ~= nil or text:match('^agent%s+%l+%s+send%s+human%s+%S') ~= nil,
            true, ('%s line %d: not a demo gc agent verb'):format(name, n))
        end
      end
    end
  end
  local tour = table.concat(vim.fn.readfile(root .. '/demo/tour-chat.txt'), '\n')
  eq(tour:find('key space m c', 1, true) ~= nil, true, 'opens the chat with its mapping')
  eq(tour:find('key space m s', 1, true) ~= nil, true, 'sends with the documented key')
  eq(tour:find('agent mayor reply latest', 1, true) ~= nil, true, 'the mayor answers with no key')
  eq(tour:find('key q', 1, true) ~= nil, true, 'closes the chat')
  eq(tour:find('/ho' .. 'me/', 1, true), nil, 'no host path')
  eq(tour:find('ic%-%l'), nil, 'no bead id')
end)

test('demo gc: a chat on the demo city shows its history, sends through it, and an agent reply becomes a new row', function()
  local dir, city = demo_dir()
  gc_run(dir, { 'seed' })
  local old_path, old_dir = vim.env.PATH, vim.env.GC_DEMO_DIR
  vim.env.PATH, vim.env.GC_DEMO_DIR = root .. '/demo/bin:' .. old_path, dir
  require('gc_mail.history').reset()
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = true, watch = false })
  local ok, err = pcall(function()
    preload()
    vim.cmd('GcMailChat demo-city mayor')
    local timeline, compose
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
      if name:match('/chat/') then
        timeline = w
      elseif name:match('/compose/') then
        compose = w
      end
    end
    assert(timeline and compose, 'the chat opened')
    local function shown()
      return table.concat(lines_of(timeline), '\n')
    end
    wait('the history of the demo city shows', function()
      return shown():find('Deploy plan for Thursday', 1, true) ~= nil and shown():find('Weekly summary is ready', 1, true) ~= nil
    end)
    eq(shown():find('● ', 1, true), nil, 'nothing is left unread once the chat marks it read: ' .. shown())

    -- A send goes through the demo gc; its own event replaces the sending block
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(compose), 0, -1, false, { 'Which questions block Thursday?' })
    vim.api.nvim_set_current_win(compose)
    vim.api.nvim_feedkeys(vim.keycode('<Space>ms'), 'x', false)
    wait('the send shows once, delivered', function()
      local text = shown()
      return select(2, text:gsub('Which questions block Thursday%?', '')) == 1 and text:find('sending', 1, true) == nil
        and text:find('## you', 1, true) ~= nil
    end, 8000)

    -- The load after the delivery is over, so only the event can bring the answer
    wait('the send is delivered', drained, 5000)
    vim.wait(700)
    -- The agent answers with no key pressed: the event becomes a new row
    local before = #lines_of(timeline)
    local result = gc_run(dir, { 'agent', 'mayor', 'reply', 'latest', 'Only', 'the', 'staging', 'refresh.' })
    eq(result.code, 0, 'agent reply: ' .. (result.stderr or ''))
    wait('the answer is a new row of the timeline', function()
      return shown():find('Only the staging refresh.', 1, true) ~= nil
    end, 8000)
    eq(#lines_of(timeline) > before, true, 'the timeline grew')
    eq(shown():find('## mayor', 1, true) ~= nil, true, 'as a row of the mayor')
    vim.api.nvim_set_current_win(timeline)
    vim.api.nvim_feedkeys('q', 'x', false)
  end)
  vim.env.PATH, vim.env.GC_DEMO_DIR = old_path, old_dir
  assert(ok, err)
end)

local function conversation_fixture()
  local now = os.time()
  local past = now - 86400 * 3
  local past_stamp = os.date('!%Y-%m-%dT%H:%M:%SZ', past)
  local today_stamp = os.date('!%Y-%m-%dT%H:%M:%SZ', now - 1800)
  local today_stamp2 = os.date('!%Y-%m-%dT%H:%M:%SZ', now - 900)

  local msgs = {
    {
      id = "tc-wisp-m1",
      title = "closed topic",
      sender = "human",
      assignee = "mayor",
      status = "closed",
      description = "closed topic\nfirst message body",
      created_at = past_stamp,
      labels = {},
    },
    {
      id = "tc-wisp-m2",
      title = "Re: closed topic",
      sender = "mayor",
      assignee = "human",
      status = "open",
      description = "this is a reply",
      created_at = today_stamp,
      labels = { "thread:thread-1a2b3c", "reply-to:tc-wisp-m1" },
    },
    {
      id = "tc-wisp-m3",
      title = "read update",
      sender = "mayor",
      assignee = "human",
      status = "open",
      description = "read update\nall good",
      created_at = today_stamp2,
      labels = { "read" },
    },
    {
      id = "tc-wisp-m4",
      title = "secret planner talk",
      sender = "mayor",
      assignee = "planner",
      status = "open",
      description = "secret planner talk\nshould not show",
      created_at = today_stamp2,
      labels = {},
    },
  }
  return vim.json.encode(msgs), past, now - 1800, now - 900
end

test(':GcMailChat demo-city opens two windows to the right with expected geometry and markdown timeline', function()
  local fix, past, t1, t2 = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = false })
  preload()

  local origin_win = vim.api.nvim_get_current_win()
  local origin_buf = vim.api.nvim_win_get_buf(origin_win)
  local origin_width_before = vim.api.nvim_win_get_width(origin_win)

  vim.cmd('GcMailChat demo-city')
  local compose_win = vim.api.nvim_get_current_win()
  assert(compose_win ~= origin_win, 'cursor in compose box')
  eq(vim.api.nvim_get_mode().mode, 'n', 'normal mode in compose box')

  local wins = vim.api.nvim_tabpage_list_wins(0)
  eq(#wins, 3, 'origin + timeline + compose windows')

  local timeline_win = nil
  for _, w in ipairs(wins) do
    if w ~= origin_win and w ~= compose_win then
      timeline_win = w
    end
  end
  assert(timeline_win, 'timeline window exists')

  eq(vim.api.nvim_win_get_width(timeline_win), 59, 'timeline width 59: the origin keeps 20 columns')
  eq(vim.api.nvim_win_get_width(compose_win), 59, 'compose width 59')
  eq(vim.api.nvim_win_get_height(compose_win), 3, 'compose height 3')
  eq(vim.api.nvim_win_get_width(origin_win), origin_width_before - 59 - 1, 'origin keeps 20 columns beside the split')
  eq(vim.api.nvim_win_get_buf(origin_win), origin_buf, 'origin buffer unchanged')

  local tl_buf = vim.api.nvim_win_get_buf(timeline_win)
  local cp_buf = vim.api.nvim_win_get_buf(compose_win)
  eq(vim.api.nvim_buf_get_name(tl_buf):match('gc%-mail://demo%-city/chat/mayor$') ~= nil, true, 'timeline buf name')
  eq(vim.api.nvim_buf_get_name(cp_buf):match('gc%-mail://demo%-city/compose/mayor$') ~= nil, true, 'compose buf name')

  wait('timeline rendered', function()
    local lines = vim.api.nvim_buf_get_lines(tl_buf, 0, -1, false)
    return #lines > 1
  end)

  local expected_lines = {
    '## you · ' .. os.date('%Y-%m-%d %H:%M', past) .. ' (closed)',
    '',
    'closed topic',
    'first message body',
    '',
    '---',
    '## mayor · ' .. os.date('%H:%M', t1) .. ' ●',
    '',
    'Re: closed topic',
    '',
    'this is a reply',
    '',
    '---',
    '## mayor · ' .. os.date('%H:%M', t2),
    '',
    'read update',
    'all good',
    '',
    '---',
  }
  eq(vim.api.nvim_buf_get_lines(tl_buf, 0, -1, false), expected_lines, 'exact timeline markdown lines')
end)

-- A single window holding the session's only listed buffer: empty, unnamed
-- and unmodified.
local function only_empty_buffer()
  vim.cmd('silent! tabonly!')
  vim.cmd('silent! only!')
  vim.cmd('enew!')
  local cur = vim.api.nvim_get_current_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= cur and vim.api.nvim_buf_is_valid(b) and vim.fn.buflisted(b) == 1 then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  return vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
end

test('chat full-window: the only empty buffer is taken over full-size, and q returns to it', function()
  local fix = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = false })
  preload()

  local origin_win, origin_buf = only_empty_buffer()
  local full_width = vim.api.nvim_win_get_width(origin_win)
  local st_before = vim.api.nvim_get_option_value('statusline', { win = origin_win, scope = 'local' })
  local wfw_before = vim.api.nvim_get_option_value('winfixwidth', { win = origin_win, scope = 'local' })

  vim.cmd('GcMailChat demo-city')
  local compose_win = vim.api.nvim_get_current_win()
  assert(compose_win ~= origin_win, 'cursor in compose box')
  eq(vim.api.nvim_get_mode().mode, 'n', 'normal mode in compose box')

  local wins = vim.api.nvim_tabpage_list_wins(0)
  eq(#wins, 2, 'timeline in the origin window plus the compose box: no leftover window')
  local timeline_win = wins[1] == compose_win and wins[2] or wins[1]
  eq(timeline_win, origin_win, 'the timeline took over the origin window')
  eq(vim.api.nvim_win_get_width(origin_win), full_width, 'full width kept')
  eq(vim.api.nvim_win_get_width(compose_win), full_width, 'compose spans the full width')
  eq(vim.api.nvim_win_get_height(compose_win), 3, 'compose height 3')

  local tl_buf = vim.api.nvim_win_get_buf(timeline_win)
  local cp_buf = vim.api.nvim_win_get_buf(compose_win)
  eq(vim.api.nvim_buf_get_name(tl_buf):match('gc%-mail://demo%-city/chat/mayor$') ~= nil, true, 'timeline buf name')
  eq(vim.api.nvim_buf_get_name(cp_buf):match('gc%-mail://demo%-city/compose/mayor$') ~= nil, true, 'compose buf name')
  eq(vim.api.nvim_buf_is_valid(origin_buf), true, 'the empty buffer is kept')
  eq(vim.api.nvim_buf_get_name(origin_buf), '', 'the empty buffer is not renamed')

  wait('timeline rendered', function()
    return #vim.api.nvim_buf_get_lines(tl_buf, 0, -1, false) > 1
  end)

  vim.api.nvim_set_current_win(timeline_win)
  vim.api.nvim_feedkeys('q', 'x', false)
  eq(vim.api.nvim_win_is_valid(compose_win), false, 'compose closed')
  eq(#vim.api.nvim_tabpage_list_wins(0), 1, 'one window again')
  eq(vim.api.nvim_get_current_win(), origin_win, 'focus back in the origin window')
  eq(vim.api.nvim_get_current_buf(), origin_buf, 'the empty buffer is current again')
  eq(vim.api.nvim_buf_get_name(origin_buf), '', 'still unnamed')
  eq(vim.api.nvim_buf_get_lines(origin_buf, 0, -1, false), { '' }, 'still empty')
  eq(vim.api.nvim_get_option_value('statusline', { win = origin_win, scope = 'local' }), st_before, 'statusline local restored')
  eq(vim.api.nvim_get_option_value('winfixwidth', { win = origin_win, scope = 'local' }), wfw_before, 'winfixwidth restored')
  -- No pinned local copy of the global default: a later global change still
  -- reaches the window and splits of it.
  vim.go.statusline = 'gc-mail-test-global'
  eq(vim.wo[origin_win].statusline, 'gc-mail-test-global', 'global statusline reaches the origin')
  vim.cmd('vsplit')
  local split_win = vim.api.nvim_get_current_win()
  eq(vim.wo[split_win].statusline, 'gc-mail-test-global', 'global statusline reaches a new split')
  vim.cmd('close')
  vim.go.statusline = ''
end)

test('chat full-window: q with the taken buffer wiped falls back to a fresh empty buffer', function()
  local fix = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = false })
  preload()

  local origin_win, origin_buf = only_empty_buffer()
  vim.cmd('GcMailChat demo-city')
  local compose_win = vim.api.nvim_get_current_win()
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local timeline_win = wins[1] == compose_win and wins[2] or wins[1]
  eq(timeline_win, origin_win, 'the timeline took over the origin window')
  local tl_buf = vim.api.nvim_win_get_buf(timeline_win)
  wait('timeline rendered', function()
    return #vim.api.nvim_buf_get_lines(tl_buf, 0, -1, false) > 1
  end)

  vim.api.nvim_buf_delete(origin_buf, { force = true })
  eq(vim.api.nvim_buf_is_valid(origin_buf), false, 'the taken buffer is gone')

  vim.api.nvim_set_current_win(timeline_win)
  vim.api.nvim_feedkeys('q', 'x', false)
  eq(#vim.api.nvim_tabpage_list_wins(0), 1, 'one window again')
  eq(vim.api.nvim_get_current_win(), origin_win, 'focus back in the origin window')
  local cur = vim.api.nvim_get_current_buf()
  assert(cur ~= tl_buf, 'not left showing the closed timeline')
  eq(vim.api.nvim_buf_get_name(cur), '', 'fallback buffer unnamed')
  eq(vim.api.nvim_buf_get_lines(cur, 0, -1, false), { '' }, 'fallback buffer empty')
end)

test('chat full-window: closing the timeline window directly leaves an empty buffer, not the compose scratch', function()
  local fix = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = false })
  preload()

  local origin_win, origin_buf = only_empty_buffer()
  vim.cmd('GcMailChat demo-city')
  local compose_win = vim.api.nvim_get_current_win()
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local timeline_win = wins[1] == compose_win and wins[2] or wins[1]
  eq(timeline_win, origin_win, 'the timeline took over the origin window')
  local compose_buf = vim.api.nvim_win_get_buf(compose_win)
  local tl_buf = vim.api.nvim_win_get_buf(timeline_win)
  wait('timeline rendered', function()
    return #vim.api.nvim_buf_get_lines(tl_buf, 0, -1, false) > 1
  end)

  vim.api.nvim_buf_set_lines(compose_buf, 0, -1, false, { 'draft line' })
  vim.api.nvim_set_current_win(timeline_win)
  vim.cmd('q')
  -- The WinClosed close runs on schedule after :q drops the timeline window.
  wait('compose window given the empty buffer back', function()
    local ws = vim.api.nvim_tabpage_list_wins(0)
    return #ws == 1 and vim.api.nvim_win_get_buf(ws[1]) == origin_buf
  end)
  local only = vim.api.nvim_tabpage_list_wins(0)[1]
  local cur = vim.api.nvim_win_get_buf(only)
  assert(cur ~= tl_buf, 'not left on the closed timeline')
  assert(cur ~= compose_buf, 'not stranded in the compose scratch buffer')
  eq(cur, origin_buf, 'the empty buffer is back')
  eq(vim.api.nvim_buf_get_name(cur), '', 'still unnamed')
  eq(vim.api.nvim_buf_get_lines(cur, 0, -1, false), { '' }, 'still empty')
  eq(vim.api.nvim_buf_is_valid(compose_buf), true, 'non-empty draft preserved')
end)

test('chat split: a named, textured, modified or second buffer keeps the three-window geometry', function()
  local function split_geometry(what)
    local origin_win = vim.api.nvim_get_current_win()
    local origin_buf = vim.api.nvim_win_get_buf(origin_win)
    vim.cmd('GcMailChat demo-city')
    local compose_win = vim.api.nvim_get_current_win()
    assert(compose_win ~= origin_win, what .. ': cursor in compose box')
    eq(vim.api.nvim_get_mode().mode, 'n', what .. ': normal mode in compose box')
    local wins = vim.api.nvim_tabpage_list_wins(0)
    eq(#wins, 3, what .. ': origin + timeline + compose windows')
    local timeline_win = nil
    for _, w in ipairs(wins) do
      if w ~= origin_win and w ~= compose_win then
        timeline_win = w
      end
    end
    assert(timeline_win, what .. ': timeline window exists')
    eq(vim.api.nvim_win_get_width(timeline_win), 59, what .. ': timeline width 59: the origin keeps 20 columns')
    eq(vim.api.nvim_win_get_width(compose_win), 59, what .. ': compose width 59')
    eq(vim.api.nvim_win_get_height(compose_win), 3, what .. ': compose height 3')
    eq(vim.api.nvim_win_get_buf(origin_win), origin_buf, what .. ': origin buffer unchanged')
    vim.api.nvim_set_current_win(timeline_win)
    vim.api.nvim_feedkeys('q', 'x', false)
    eq(#vim.api.nvim_tabpage_list_wins(0), 1, what .. ': q closes back to one window')
  end

  local cases = {
    named = function()
      vim.cmd('file chat-split-named')
    end,
    text = function()
      buffer({ 'hello' })
      vim.bo[vim.api.nvim_get_current_buf()].modified = false
    end,
    modified = function()
      buffer({ 'x' })
      buffer({ '' })
    end,
    second = function()
      vim.api.nvim_create_buf(true, false)
    end,
  }
  for name, mutate in pairs(cases) do
    reset()
    local fix = conversation_fixture()
    write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
    gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = false })
    preload()
    only_empty_buffer()
    mutate()
    split_geometry(name)
  end
end)

test('chat split: an extra window keeps the split geometry, not full-size', function()
  local function split_not_fullsize(what, setup_extra)
    local origin_win = vim.api.nvim_get_current_win()
    local origin_buf = vim.api.nvim_win_get_buf(origin_win)
    setup_extra()
    eq(#vim.api.nvim_tabpage_list_wins(0), 2, what .. ': two windows before open')
    vim.api.nvim_set_current_win(origin_win)
    vim.cmd('GcMailChat demo-city')
    local compose_win = vim.api.nvim_get_current_win()
    assert(compose_win ~= origin_win, what .. ': cursor in compose box')
    local wins = vim.api.nvim_tabpage_list_wins(0)
    eq(#wins, 4, what .. ': extra window + origin + timeline + compose')
    local timeline_win = nil
    for _, w in ipairs(wins) do
      if w ~= origin_win and w ~= compose_win then
        local b = vim.api.nvim_win_get_buf(w)
        if vim.api.nvim_buf_get_name(b):match('/chat/') then
          timeline_win = w
        end
      end
    end
    assert(timeline_win, what .. ': timeline window exists')
    assert(timeline_win ~= origin_win, what .. ': the origin window is not taken over')
    -- Beside a vertical neighbour the split as opened would leave the
    -- origin below 20 columns, so the timeline gives the shortfall back
    eq(vim.api.nvim_win_get_width(timeline_win), what == 'same_buffer' and 55 or 59, what .. ': timeline width: the origin keeps 20 columns')
    eq(vim.api.nvim_win_get_width(origin_win) >= 20, true, what .. ': the origin keeps at least 20 columns')
    eq(vim.api.nvim_win_get_buf(origin_win), origin_buf, what .. ': origin buffer unchanged')
    vim.api.nvim_set_current_win(timeline_win)
    vim.api.nvim_feedkeys('q', 'x', false)
    eq(#vim.api.nvim_tabpage_list_wins(0), 2, what .. ': q closes back to the two windows')
    eq(vim.api.nvim_win_get_buf(origin_win), origin_buf, what .. ': origin buffer still unchanged')
  end

  local cases = {
    same_buffer = function()
      vim.cmd('vsplit')
    end,
    unlisted_window = function()
      vim.cmd('split')
      local scratch = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_win_set_buf(0, scratch)
    end,
  }
  for name, setup_extra in pairs(cases) do
    reset()
    local fix = conversation_fixture()
    write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
    gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = false })
    preload()
    only_empty_buffer()
    split_not_fullsize(name, setup_extra)
  end
end)

-- Opens a split chat (the current buffer carries text, so no full-size
-- takeover) with the conversation fixture and returns its windows.
local function resize_chat(with, opts)
  local fix = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  gc_mail.setup(vim.tbl_extend('force', { state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY,
    chat_mark_read = false }, opts or {}))
  preload()
  -- One normal origin window, whatever an earlier test left behind
  vim.cmd('silent! tabonly!')
  vim.cmd('silent! only!')
  local kept = vim.api.nvim_get_current_win()
  vim.wo[kept].winfixwidth, vim.wo[kept].winfixheight = false, false
  -- The headless screen keeps the last layout's total until a window is
  -- resized: widen the kept window beside a temporary split, then drop it
  vim.cmd('vsplit')
  pcall(vim.api.nvim_win_set_width, kept, vim.o.columns)
  pcall(vim.api.nvim_win_close, vim.api.nvim_get_current_win(), true)
  vim.api.nvim_set_current_win(kept)
  buffer({ 'work in progress' })
  local origin_win = vim.api.nvim_get_current_win()
  vim.cmd('GcMailChat demo-city' .. (with and (' ' .. with) or ''))
  local wins = { origin = origin_win, compose = vim.api.nvim_get_current_win() }
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= origin_win and w ~= wins.compose then
      wins.timeline = w
    end
  end
  assert(wins.timeline, 'timeline window exists')
  return wins
end

local function close_chat(wins)
  vim.api.nvim_set_current_win(wins.timeline)
  vim.api.nvim_feedkeys('q', 'x', false)
end

test('chat resize: a narrow editor opens clamped so the origin keeps 20 columns', function()
  vim.o.columns = 70
  local wins = resize_chat()
  eq(vim.api.nvim_win_get_width(wins.timeline), 49, 'timeline clamped to 70 - 20 - 1 separator')
  eq(vim.api.nvim_win_get_width(wins.origin) >= 20, true, 'the origin keeps at least 20 columns')
  eq(vim.api.nvim_win_get_width(wins.compose), 49, 'compose as wide as the timeline')
  close_chat(wins)

  -- Below winwidth's own floor for the current window, so the clamp shows
  vim.o.columns, vim.o.winwidth = 30, 1
  wins = resize_chat()
  eq(vim.api.nvim_win_get_width(wins.timeline), 9, 'timeline clamped to 30 - 20 - 1 separator')
  eq(vim.api.nvim_win_get_width(wins.origin) >= 20, true, 'the origin still keeps at least 20 columns')
  close_chat(wins)
  vim.o.winwidth = 20
end)

test('chat resize: an open beside another window clamps to the origin window, not the editor', function()
  vim.o.columns = 120
  local fix = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = false })
  preload()
  vim.cmd('silent! tabonly!')
  vim.cmd('silent! only!')
  buffer({ 'work in progress' })
  local origin = vim.api.nvim_get_current_win()
  -- The headless screen keeps the last layout's total until a window is
  -- resized: widen the origin beside a temporary split, then drop it
  vim.cmd('vsplit')
  pcall(vim.api.nvim_win_set_width, origin, vim.o.columns)
  pcall(vim.api.nvim_win_close, vim.api.nvim_get_current_win(), true)
  vim.api.nvim_set_current_win(origin)
  vim.cmd('vsplit')
  local other = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(other, 39)
  vim.api.nvim_win_set_width(origin, 80)
  eq(vim.api.nvim_win_get_width(origin), 80, 'the origin starts at 80 of the 120 columns')
  vim.api.nvim_set_current_win(origin)
  vim.cmd('GcMailChat demo-city')
  local compose = vim.api.nvim_get_current_win()
  local timeline
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= origin and w ~= other and w ~= compose then
      timeline = w
    end
  end
  assert(timeline, 'timeline window exists')
  eq(vim.api.nvim_win_get_width(timeline), 59, 'timeline clamped to the 80-column origin, not the editor')
  eq(vim.api.nvim_win_get_width(origin), 20, 'the origin keeps 20 columns')
  vim.api.nvim_exec_autocmds('VimResized', {})
  eq(vim.api.nvim_win_get_width(timeline), 59, 'an editor resize does not regrow the timeline past the origin floor')
  eq(vim.api.nvim_win_get_width(origin), 20, 'an editor resize keeps the origin at 20 columns')
  vim.api.nvim_set_current_win(timeline)
  vim.api.nvim_feedkeys('q', 'x', false)
end)

-- Opens a split chat at a 160-column editor laid out origin | chat |
-- other as 58 | 60 | 40 and returns its windows.
local function resize_chat_left_of_other()
  vim.o.columns = 160
  local fix = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = false })
  preload()
  vim.cmd('silent! tabonly!')
  vim.cmd('silent! only!')
  buffer({ 'work in progress' })
  local other = vim.api.nvim_get_current_win()
  vim.wo[other].winfixwidth, vim.wo[other].winfixheight = false, false
  -- The headless screen keeps the last layout's total until a window is
  -- resized: widen the window beside a temporary split, then drop it
  vim.cmd('vsplit')
  pcall(vim.api.nvim_win_set_width, other, vim.o.columns)
  pcall(vim.api.nvim_win_close, vim.api.nvim_get_current_win(), true)
  vim.api.nvim_set_current_win(other)
  vim.cmd('vsplit')
  local origin = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(other, 40)
  vim.cmd('GcMailChat demo-city')
  local wins = { origin = origin, other = other, compose = vim.api.nvim_get_current_win() }
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= origin and w ~= other and w ~= wins.compose then
      wins.timeline = w
    end
  end
  assert(wins.timeline, 'timeline window exists')
  return wins
end

local function widths(wins)
  return {
    vim.api.nvim_win_get_width(wins.origin),
    vim.api.nvim_win_get_width(wins.timeline),
    vim.api.nvim_win_get_width(wins.other),
  }
end

test('chat resize: a window right of the chat keeps its width when the origin floor is restored', function()
  local wins = resize_chat_left_of_other()
  eq(widths(wins), { 58, 60, 40 }, 'origin | chat | other opens as 58 | 60 | 40')

  -- A separator drag narrows the origin and widens the timeline
  vim.api.nvim_win_set_width(wins.origin, 10)
  vim.api.nvim_exec_autocmds('WinResized', {})
  wait('the origin gets its floor back once the resize settles', function()
    return vim.api.nvim_win_get_width(wins.origin) == 20
  end)
  eq(widths(wins), { 20, 98, 40 }, 'the timeline gives the shortfall back; the other window keeps 40')
  vim.api.nvim_exec_autocmds('VimResized', {})
  vim.api.nvim_exec_autocmds('VimResized', {})
  vim.api.nvim_exec_autocmds('WinResized', {})
  vim.wait(50)
  eq(widths(wins), { 20, 98, 40 }, 'further editor resizes change no width')
  close_chat(wins)

  -- A timeline widened past the origin's floor takes the other window's
  -- columns first, then the origin's
  require('gc_mail.chat').reset()
  wins = resize_chat_left_of_other()
  eq(widths(wins), { 58, 60, 40 }, 'reopens as 58 | 60 | 40 in a new session')
  vim.api.nvim_win_set_width(wins.timeline, 140)
  eq(vim.api.nvim_win_get_width(wins.origin) < 20, true, 'the widened timeline leaves the origin short')
  local other_width = vim.api.nvim_win_get_width(wins.other)
  vim.api.nvim_exec_autocmds('WinResized', {})
  wait('the origin gets its floor back once the resize settles', function()
    return vim.api.nvim_win_get_width(wins.origin) == 20
  end)
  local settled = widths(wins)
  eq(settled[3], other_width, 'the other window keeps its width')
  vim.api.nvim_exec_autocmds('VimResized', {})
  vim.api.nvim_exec_autocmds('VimResized', {})
  vim.wait(50)
  eq(widths(wins), settled, 'further editor resizes change no width')
  close_chat(wins)
end)

test('chat resize: closing the origin window does not make the spanned width the remembered one', function()
  vim.o.columns = 200
  local wins = resize_chat()
  eq(vim.api.nvim_win_get_width(wins.timeline), 60, 'opens at chat_width')
  vim.api.nvim_win_close(wins.origin, true)
  eq(vim.api.nvim_win_get_width(wins.timeline), 200, 'the timeline spans the editor once the origin is gone')
  vim.api.nvim_exec_autocmds('WinResized', {})
  close_chat(wins)
  -- The close leaves a chat window behind in the tab (its origin is
  -- gone); give it a plain buffer before reopening
  vim.cmd('enew!')

  wins = resize_chat()
  eq(vim.api.nvim_win_get_width(wins.timeline), 60, 'reopens at chat_width, not the spanned width')
  close_chat(wins)
end)

test('chat resize: a resized timeline width is remembered for that chat only', function()
  local wins = resize_chat(nil, { chat_width = 40 })
  eq(vim.api.nvim_win_get_width(wins.timeline), 40, 'opens at chat_width')
  vim.api.nvim_win_set_width(wins.timeline, 52)
  vim.api.nvim_exec_autocmds('WinResized', {})
  eq(vim.api.nvim_win_get_width(wins.timeline), 52, 'the wider user width stays')
  close_chat(wins)

  wins = resize_chat(nil, { chat_width = 40 })
  eq(vim.api.nvim_win_get_width(wins.timeline), 52, 'reopens at the remembered width')
  close_chat(wins)

  wins = resize_chat('planner', { chat_width = 40 })
  eq(vim.api.nvim_win_get_width(wins.timeline), 40, 'another chat still opens at chat_width')
  close_chat(wins)

  -- A new session (a fresh chat module) starts from chat_width again
  require('gc_mail.chat').reset()
  wins = resize_chat(nil, { chat_width = 40 })
  eq(vim.api.nvim_win_get_width(wins.timeline), 40, 'no width is remembered across sessions')
  close_chat(wins)
end)

test('chat resize: a wide editor with no user resize reopens at chat_width', function()
  vim.o.columns = 120
  local wins = resize_chat()
  eq(vim.api.nvim_win_get_width(wins.timeline), 60, 'opens at chat_width')
  close_chat(wins)
  wins = resize_chat()
  eq(vim.api.nvim_win_get_width(wins.timeline), 60, 'reopens at chat_width')
  close_chat(wins)
end)

test('chat resize: the full-size open is unaffected by a remembered width', function()
  local wins = resize_chat(nil, { chat_width = 40 })
  vim.api.nvim_win_set_width(wins.timeline, 52)
  vim.api.nvim_exec_autocmds('WinResized', {})
  close_chat(wins)

  local _, empty_buf = only_empty_buffer()
  local full_width = vim.api.nvim_win_get_width(vim.api.nvim_get_current_win())
  vim.cmd('GcMailChat demo-city')
  local compose_win = vim.api.nvim_get_current_win()
  local timeline_win = vim.api.nvim_tabpage_list_wins(0)[1] == compose_win
    and vim.api.nvim_tabpage_list_wins(0)[2] or vim.api.nvim_tabpage_list_wins(0)[1]
  eq(vim.api.nvim_win_get_width(timeline_win), full_width, 'full-size timeline spans the editor, not the remembered width')
  assert(vim.api.nvim_win_get_buf(timeline_win) ~= empty_buf, 'the timeline took over the empty window')
  vim.api.nvim_set_current_win(timeline_win)
  vim.api.nvim_feedkeys('q', 'x', false)

  wins = resize_chat(nil, { chat_width = 40 })
  eq(vim.api.nvim_win_get_width(wins.timeline), 52, 'the remembered width survived the full-size open')
  close_chat(wins)
end)

test('chat resize: a resized compose height is remembered in the split and full-size layouts', function()
  vim.o.columns = 120
  local wins = resize_chat()
  eq(vim.api.nvim_win_get_height(wins.compose), 3, 'opens at chat_compose_height')
  vim.api.nvim_win_set_height(wins.compose, 6)
  vim.api.nvim_exec_autocmds('WinResized', {})
  eq(vim.api.nvim_win_get_height(wins.compose), 6, 'the user height stays')
  close_chat(wins)

  wins = resize_chat()
  eq(vim.api.nvim_win_get_height(wins.compose), 6, 'the split reopens at the remembered height')
  close_chat(wins)

  only_empty_buffer()
  vim.cmd('GcMailChat demo-city')
  local compose_win = vim.api.nvim_get_current_win()
  eq(vim.api.nvim_win_get_height(compose_win), 6, 'the full-size chat reopens at the remembered height')
  vim.api.nvim_win_set_height(compose_win, 8)
  vim.api.nvim_exec_autocmds('WinResized', {})
  local timeline_win = vim.api.nvim_tabpage_list_wins(0)[1] == compose_win
    and vim.api.nvim_tabpage_list_wins(0)[2] or vim.api.nvim_tabpage_list_wins(0)[1]
  vim.api.nvim_set_current_win(timeline_win)
  vim.api.nvim_feedkeys('q', 'x', false)

  only_empty_buffer()
  vim.cmd('GcMailChat demo-city')
  eq(vim.api.nvim_win_get_height(vim.api.nvim_get_current_win()), 8, 'a full-size resize is remembered too')
  compose_win = vim.api.nvim_get_current_win()
  timeline_win = vim.api.nvim_tabpage_list_wins(0)[1] == compose_win
    and vim.api.nvim_tabpage_list_wins(0)[2] or vim.api.nvim_tabpage_list_wins(0)[1]
  vim.api.nvim_set_current_win(timeline_win)
  vim.api.nvim_feedkeys('q', 'x', false)
end)

test('chat resize: closing the timeline of a full-size chat does not remember the expanded compose height', function()
  vim.o.columns = 120
  local fix = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = false })
  preload()
  local _, origin_buf = only_empty_buffer()
  vim.cmd('GcMailChat demo-city')
  local compose_win = vim.api.nvim_get_current_win()
  eq(vim.api.nvim_win_get_height(compose_win), 3, 'opens at chat_compose_height')
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local timeline_win = wins[1] == compose_win and wins[2] or wins[1]
  vim.api.nvim_set_current_win(timeline_win)
  vim.cmd('q')
  wait('compose window given the empty buffer back', function()
    local ws = vim.api.nvim_tabpage_list_wins(0)
    return #ws == 1 and vim.api.nvim_win_get_buf(ws[1]) == origin_buf
  end)

  vim.cmd('GcMailChat demo-city')
  compose_win = vim.api.nvim_get_current_win()
  eq(vim.api.nvim_win_get_height(compose_win), 3,
    'reopens at chat_compose_height, not the height the surviving compose window expanded to')
  wins = vim.api.nvim_tabpage_list_wins(0)
  timeline_win = wins[1] == compose_win and wins[2] or wins[1]
  vim.api.nvim_set_current_win(timeline_win)
  vim.api.nvim_feedkeys('q', 'x', false)
end)

test('chat resize: with no user resize the compose box opens at chat_compose_height', function()
  vim.o.columns = 120
  local wins = resize_chat()
  eq(vim.api.nvim_win_get_height(wins.compose), 3, 'opens at chat_compose_height')
  close_chat(wins)
  wins = resize_chat()
  eq(vim.api.nvim_win_get_height(wins.compose), 3, 'reopens at chat_compose_height')
  close_chat(wins)
end)

test('chat resize: the compose box is clamped so the timeline keeps 5 rows', function()
  vim.o.columns = 120
  local wins = resize_chat()
  vim.api.nvim_win_set_height(wins.compose, 30)
  vim.api.nvim_exec_autocmds('WinResized', {})
  wait('the compose height is clamped once the resize settles', function()
    return vim.api.nvim_win_get_height(wins.compose) == 16
  end)
  eq(vim.api.nvim_win_get_height(wins.timeline), 5, 'the timeline keeps 5 rows')
  eq(vim.api.nvim_win_get_height(wins.compose), 16, 'compose clamped to the rows above that floor')
  close_chat(wins)
  wins = resize_chat()
  eq(vim.api.nvim_win_get_height(wins.compose), 16, 'the clamped height is what reopens')
  close_chat(wins)
end)

test('chat resize: an editor resize restores the wanted sizes at the floors', function()
  vim.o.columns = 120
  local wins = resize_chat()
  eq(vim.api.nvim_win_get_width(wins.timeline), 60, 'opens at chat_width')

  vim.o.columns = 70
  vim.api.nvim_exec_autocmds('VimResized', {})
  eq(vim.api.nvim_win_get_width(wins.timeline), 49, 'a narrower editor clamps the timeline')
  eq(vim.api.nvim_win_get_width(wins.origin) >= 20, true, 'the origin keeps at least 20 columns')

  vim.api.nvim_set_current_win(wins.origin)
  vim.cmd('wincmd =')
  vim.api.nvim_exec_autocmds('WinResized', {})
  eq(vim.api.nvim_win_get_width(wins.timeline), 49, 'equalisation does not move the timeline')
  eq(vim.api.nvim_win_get_width(wins.origin) >= 20, true, 'equalisation keeps the origin floor')

  vim.o.columns = 120
  vim.api.nvim_exec_autocmds('VimResized', {})
  eq(vim.api.nvim_win_get_width(wins.timeline), 60, 'a wider editor restores chat_width')
  close_chat(wins)

  wins = resize_chat()
  eq(vim.api.nvim_win_get_width(wins.timeline), 60, 'the editor resize wrote no width memory')
  close_chat(wins)
end)

test('<Space>ms in normal mode queues to mayor; typing ms in insert mode, <C-s> and <CR> queue nothing', function()
  local fix = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY })
  preload()

  vim.cmd('GcMailChat demo-city')
  local compose_win = vim.api.nvim_get_current_win()
  local compose_buf = vim.api.nvim_win_get_buf(compose_win)
  local timeline_buf = nil
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(b):match('/chat/') then
      timeline_buf = b
    end
  end

  vim.env.FAKE_GC_DELAY = '0.3'

  vim.api.nvim_set_current_win(compose_win)
  -- Typing " ms" in insert mode does NOT trigger send
  vim.api.nvim_feedkeys('ihello mayor' .. vim.keycode('<CR>') .. 'body line ms', 'x', false)
  eq(#gc_mail.queue.list(), 0, 'nothing queued while typing ms in insert mode')

  -- <C-s> and <CR> in normal mode do NOT trigger send with defaults
  vim.api.nvim_feedkeys(vim.keycode('<C-s>'), 'x', false)
  eq(#gc_mail.queue.list(), 0, 'nothing queued by <C-s>')
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  eq(#gc_mail.queue.list(), 0, 'nothing queued by <CR>')

  -- Clear buffer and write test content for send
  vim.api.nvim_buf_set_lines(compose_buf, 0, -1, false, { 'hello mayor', 'body line' })
  -- <Space>ms in normal mode sends
  vim.api.nvim_feedkeys(vim.keycode('<Space>ms'), 'x', false)

  eq(vim.api.nvim_buf_get_lines(compose_buf, 0, -1, false), { '' }, 'box empty after send')
  vim.cmd('silent undo')
  eq(vim.api.nvim_buf_get_lines(compose_buf, 0, -1, false), { 'hello mayor', 'body line' }, 'u restores text')
  vim.api.nvim_buf_set_lines(compose_buf, 0, -1, false, { '' })

  wait('sending… appears in timeline', function()
    local text = table.concat(vim.api.nvim_buf_get_lines(timeline_buf, 0, -1, false), '\n')
    return text:find('## you · sending…', 1, true) ~= nil
  end)
  local sending_text = table.concat(vim.api.nvim_buf_get_lines(timeline_buf, 0, -1, false), '\n')
  assert(sending_text:find('hello mayor\nbody line', 1, true) ~= nil, 'sending… includes body')

  local updated_fixture = vim.json.decode(fix)
  updated_fixture[#updated_fixture + 1] = {
    id = "tc-wisp-sent1",
    title = "hello mayor",
    sender = "human",
    assignee = "mayor",
    status = "open",
    description = "hello mayor\nbody line",
    created_at = os.date('!%Y-%m-%dT%H:%M:%SZ', os.time()),
    labels = {},
  }
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', vim.json.encode(updated_fixture))

  wait('sent and drained', drained)
  eq(recorded_argv(), { '--city', '/srv/demo-city', 'mail', 'send', 'mayor', '-s', 'hello mayor',
    '-m', 'hello mayor\nbody line', '--notify' }, 'exact argv sent')

  wait('sending… line gone and message shows once', function()
    local text = table.concat(vim.api.nvim_buf_get_lines(timeline_buf, 0, -1, false), '\n')
    return text:find('sending…', 1, true) == nil and text:find('hello mayor\nbody line', 1, true) ~= nil
  end)

  vim.env.FAKE_GC_DELAY = '0.3'
  vim.api.nvim_buf_set_lines(compose_buf, 0, -1, false, { 'second test', 'second body' })
  vim.api.nvim_set_current_win(compose_win)
  vim.api.nvim_feedkeys(vim.keycode('<Space>ms'), 'x', false)

  eq(vim.api.nvim_buf_get_lines(compose_buf, 0, -1, false), { '' }, 'box empty after <Space>ms send')
  vim.cmd('silent undo')
  eq(vim.api.nvim_buf_get_lines(compose_buf, 0, -1, false), { 'second test', 'second body' }, 'u restores text')

  wait('sending… appears for second message', function()
    local text = table.concat(vim.api.nvim_buf_get_lines(timeline_buf, 0, -1, false), '\n')
    return text:find('## you · sending…', 1, true) ~= nil
  end)

  updated_fixture[#updated_fixture + 1] = {
    id = "tc-wisp-sent2",
    title = "second test",
    sender = "human",
    assignee = "mayor",
    status = "open",
    description = "second test\nsecond body",
    created_at = os.date('!%Y-%m-%dT%H:%M:%SZ', os.time()),
    labels = {},
  }
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', vim.json.encode(updated_fixture))

  wait('second sent and drained', drained)
  eq(recorded_argv(), { '--city', '/srv/demo-city', 'mail', 'send', 'mayor', '-s', 'second test',
    '-m', 'second test\nsecond body', '--notify' }, 'exact argv for second send')

  wait('second sending… line gone and message shows', function()
    local text = table.concat(vim.api.nvim_buf_get_lines(timeline_buf, 0, -1, false), '\n')
    return text:find('sending…', 1, true) == nil and text:find('second test\nsecond body', 1, true) ~= nil
  end)
end)

test('a failed send (FAKE_GC_FAIL_TIMES) shows ## you · queued during retries, and ## you · failed: after last retry', function()
  reset({ FAKE_GC_FAIL_TIMES = '1' })
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', '[]')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = { 5000, 5000 } })
  preload()

  vim.cmd('GcMailChat demo-city')
  local compose_win = vim.api.nvim_get_current_win()
  local compose_buf = vim.api.nvim_win_get_buf(compose_win)
  local timeline_buf = nil
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(b):match('/chat/') then
      timeline_buf = b
    end
  end

  vim.api.nvim_buf_set_lines(compose_buf, 0, -1, false, { 'will retry', 'body' })
  vim.api.nvim_feedkeys(vim.keycode('<Space>ms'), 'x', false)

  wait('attempt failed and queued retry scheduled', function()
    local entries = gc_mail.queue.list()
    return entries and entries[1] and entries[1].record and entries[1].record.attempts == 1 and not entries[1].record.failed
  end)

  wait('timeline shows ## you · queued during retry', function()
    local text = table.concat(vim.api.nvim_buf_get_lines(timeline_buf, 0, -1, false), '\n')
    return text:find('## you · queued', 1, true) ~= nil and text:find('## you · failed', 1, true) == nil
  end)

  reset({ FAKE_GC_FAIL_TIMES = '99' })
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', '[]')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = { 20 } })
  preload()
  vim.cmd('GcMailChat demo-city')
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(b):match('/chat/') then
      timeline_buf = b
    end
  end
  compose_win = vim.api.nvim_get_current_win()
  compose_buf = vim.api.nvim_win_get_buf(compose_win)
  vim.api.nvim_buf_set_lines(compose_buf, 0, -1, false, { 'will fail permanently', 'body' })
  vim.api.nvim_feedkeys(vim.keycode('<Space>ms'), 'x', false)

  wait('failed line appears in timeline after all retries', function()
    local text = table.concat(vim.api.nvim_buf_get_lines(timeline_buf, 0, -1, false), '\n')
    return text:find('## you · failed:', 1, true) ~= nil
  end)
  local text = table.concat(vim.api.nvim_buf_get_lines(timeline_buf, 0, -1, false), '\n')
  assert(text:find('store unavailable', 1, true) ~= nil, 'error message shown in failed line')
end)

test('RS6: refused mark-read keeps dot, is called exactly once, and does not loop', function()
  local history = require('gc_mail.history')
  history.reset()
  local fix = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  write(vim.env.FAKE_GC_MAIL .. '/mark-read.exit', '1\n')
  write(vim.env.FAKE_GC_MAIL .. '/mark-read.stderr', 'fake mark-read error\n')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = true })
  preload()

  vim.cmd('GcMailChat demo-city')
  local timeline_buf = nil
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(b):match('/chat/') then
      timeline_buf = b
    end
  end

  wait('mark-read called once in fake gc', function()
    local calls = mail_calls()
    for _, call in ipairs(calls) do
      if call[4] == 'mark-read' and call[5] == 'tc-wisp-m2' then
        return true
      end
    end
    return false
  end)

  vim.wait(300)

  local mark_calls = 0
  for _, call in ipairs(mail_calls()) do
    if call[4] == 'mark-read' and call[5] == 'tc-wisp-m2' then
      mark_calls = mark_calls + 1
    end
  end
  eq(mark_calls, 1, 'mark-read was refused and called exactly once (no loop)')

  wait('dot is still present for refused message', function()
    local text = table.concat(vim.api.nvim_buf_get_lines(timeline_buf, 0, -1, false), '\n')
    return text:find('●', 1, true) ~= nil
  end)
end)

local function header_row(win, stamp)
  for i, l in ipairs(lines_of(win)) do
    if l:find('## mayor · ' .. stamp, 1, true) then
      return i
    end
  end
end

local function list_calls()
  local n = 0
  for _, c in ipairs(mail_calls()) do
    if c[3] == 'bd' and c[4] == 'list' then
      n = n + 1
    end
  end
  return n
end

local function read_calls(id)
  local n = 0
  for _, c in ipairs(mail_calls()) do
    if c[4] == 'mark-read' and c[5] == id then
      n = n + 1
    end
  end
  return n
end

test('RS4: u in the chat keeps the message unread with the default chat_mark_read until the chat is left', function()
  local fix, _, t1, t2 = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  acted('mark-read', 'tc-wisp-m2')
  acted('mark-unread', 'tc-wisp-m3')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = true })
  preload()

  local chat_mod = require('gc_mail.chat')
  local chat = chat_mod.open('demo-city', 'mayor')
  local win = chat.timeline_win
  local stamp = os.date('%H:%M', t2)
  wait('history rendered', function()
    return header_row(win, stamp) ~= nil
  end)
  wait('the unread message is marked read', function()
    return read_calls('tc-wisp-m2') == 1
  end)

  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { header_row(win, stamp), 0 })
  vim.api.nvim_feedkeys('u', 'x', false)
  wait('mark-unread called', function()
    for _, c in ipairs(mail_calls()) do
      if c[4] == 'mark-unread' and c[5] == 'tc-wisp-m3' then
        return true
      end
    end
    return false
  end)
  vim.wait(300)
  eq(read_calls('tc-wisp-m3'), 0, 'u does not undo itself')
  assert(table.concat(lines_of(win), '\n'):find('## mayor · ' .. stamp .. ' ●', 1, true),
    'the dot stays: ' .. table.concat(lines_of(win), '|'))

  -- Moving to the chat's other window keeps it; leaving the chat lets the
  -- next entry mark it read.
  vim.api.nvim_set_current_win(chat.compose_win)
  vim.wait(100)
  eq(read_calls('tc-wisp-m3'), 0, 'compose box is the same chat')
  vim.api.nvim_set_current_win(chat.origin)
  vim.wait(100)
  vim.api.nvim_set_current_win(win)
  wait('entering the chat again marks it read', function()
    return read_calls('tc-wisp-m3') == 1
  end)
  vim.api.nvim_set_current_win(chat.origin)
end)

test('RS5: a load while a mark-read is pending keeps the local read value', function()
  local fix, _, t1 = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  acted('mark-read', 'tc-wisp-m2')
  write(vim.env.FAKE_GC_MAIL .. '/mark-read.delay', '0.8\n')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = true })
  preload()

  local chat_mod = require('gc_mail.chat')
  local chat = chat_mod.open('demo-city', 'mayor')
  local win = chat.timeline_win
  local stamp = os.date('%H:%M', t1)
  wait('mark-read started', function()
    return read_calls('tc-wisp-m2') == 1
  end)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_feedkeys('R', 'x', false)
  vim.wait(400)
  -- The list still says unread; the pending mark-read keeps the local value
  assert(header_row(win, stamp), 'history rendered')
  assert(not table.concat(lines_of(win), '\n'):find('## mayor · ' .. stamp .. ' ●', 1, true), 'no dot while pending')
  vim.wait(900)
  eq(read_calls('tc-wisp-m2'), 1, 'not passed again')
  vim.api.nvim_set_current_win(chat.origin)
end)

test('RS5 and RS6: a refused mark-read is not retried until a load shows the message read', function()
  local fix, _, t1 = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  write(vim.env.FAKE_GC_MAIL .. '/mark-read.exit', '1\n')
  write(vim.env.FAKE_GC_MAIL .. '/mark-read.stderr', 'fake mark-read error\n')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = true })
  preload()

  local chat_mod = require('gc_mail.chat')
  local chat = chat_mod.open('demo-city', 'mayor')
  local win = chat.timeline_win
  local stamp = os.date('%H:%M', t1)
  local function dot()
    return table.concat(lines_of(win), '\n'):find('## mayor · ' .. stamp .. ' ●', 1, true) ~= nil
  end
  wait('refused once', function()
    return read_calls('tc-wisp-m2') == 1
  end)
  vim.wait(300)
  vim.api.nvim_set_current_win(win)
  -- A load that still lists it unread: the dot stays, no retry
  vim.api.nvim_feedkeys('R', 'x', false)
  vim.wait(400)
  eq(dot(), true, 'the dot stays')
  eq(read_calls('tc-wisp-m2'), 1, 'not retried')
  -- A load that lists it read drops the record
  local read_fix = vim.json.decode(fix)
  for _, m in ipairs(read_fix) do
    if m.id == 'tc-wisp-m2' then
      table.insert(m.labels, 'read')
    end
  end
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', vim.json.encode(read_fix))
  vim.api.nvim_feedkeys('R', 'x', false)
  wait('the dot is gone', function()
    return not dot()
  end)
  eq(read_calls('tc-wisp-m2'), 1, 'still not retried')
  -- Unread again in gc: with the record gone it is passed once more
  vim.fn.delete(vim.env.FAKE_GC_MAIL .. '/mark-read.exit')
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  vim.api.nvim_feedkeys('R', 'x', false)
  wait('passed again', function()
    return read_calls('tc-wisp-m2') == 2
  end)
  vim.api.nvim_set_current_win(chat.origin)
end)

test('RS4: u with a second chat open in another tab page keeps the message unread through window moves', function()
  local fix, _, _, t2 = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  acted('mark-read', 'tc-wisp-m2')
  acted('mark-unread', 'tc-wisp-m3')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = true })
  preload()

  local chat_mod = require('gc_mail.chat')
  local chat = chat_mod.open('demo-city', 'mayor')
  local win = chat.timeline_win
  local stamp = os.date('%H:%M', t2)
  wait('history rendered', function()
    return header_row(win, stamp) ~= nil
  end)
  wait('the unread message is marked read', function()
    return read_calls('tc-wisp-m2') == 1
  end)

  vim.cmd('tabnew')
  local other = chat_mod.open('demo-city', 'planner')
  assert(other, 'second chat opened')
  vim.cmd('tabprevious')
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { header_row(win, stamp), 0 })
  vim.api.nvim_feedkeys('u', 'x', false)
  wait('mark-unread called', function()
    for _, c in ipairs(mail_calls()) do
      if c[4] == 'mark-unread' and c[5] == 'tc-wisp-m3' then
        return true
      end
    end
    return false
  end)

  -- Moves inside the first chat must not reach the other chat's handler
  vim.api.nvim_set_current_win(chat.compose_win)
  vim.wait(150)
  vim.api.nvim_set_current_win(win)
  vim.wait(300)
  eq(read_calls('tc-wisp-m3'), 0, 'a second chat does not end the u')
  assert(table.concat(lines_of(win), '\n'):find('## mayor · ' .. stamp .. ' ●', 1, true),
    'the dot stays: ' .. table.concat(lines_of(win), '|'))

  vim.api.nvim_set_current_win(chat.origin)
  vim.wait(100)
  vim.api.nvim_set_current_win(win)
  wait('entering the chat again marks it read', function()
    return read_calls('tc-wisp-m3') == 1
  end)
  vim.api.nvim_set_current_win(chat.origin)
  vim.cmd('tabclose!')
end)

test('RS2: a u that a later read on the message made stale takes the state from gc', function()
  local fix, _, _, t2 = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  acted('mark-unread', 'tc-wisp-m3')
  write(vim.env.FAKE_GC_MAIL .. '/mark-unread.delay', '0.6\n')
  acted('mark-read', 'tc-wisp-m3')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = false })
  preload()

  local chat_mod = require('gc_mail.chat')
  local chat = chat_mod.open('demo-city', 'mayor')
  local win = chat.timeline_win
  local stamp = os.date('%H:%M', t2)
  wait('history rendered', function()
    return header_row(win, stamp) ~= nil
  end)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { header_row(win, stamp), 0 })
  vim.api.nvim_feedkeys('u', 'x', false)
  -- A read from elsewhere (the mailbox) starts after the u and wins
  require('gc_mail.mailbox').actions.read({
    city = chat.city,
    message = { id = 'tc-wisp-m3', subject = 'read update', from = 'mayor' },
    read = false,
  })
  wait('the late unread answer is dropped and the history reloaded', function()
    local text = table.concat(lines_of(win), '\n')
    return text:find('## mayor · ' .. stamp, 1, true) ~= nil and not text:find('## mayor · ' .. stamp .. ' ●', 1, true)
  end)
  vim.api.nvim_set_current_win(chat.origin)
end)

test('RS4 and RS2: a stale mark-unread answer after the chat was left drops the record', function()
  local fix, _, _, t2 = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  acted('mark-unread', 'tc-wisp-m3')
  write(vim.env.FAKE_GC_MAIL .. '/mark-unread.delay', '0.6\n')
  acted('mark-read', 'tc-wisp-m3')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = true })
  preload()

  local chat_mod = require('gc_mail.chat')
  local chat = chat_mod.open('demo-city', 'mayor')
  local win = chat.timeline_win
  local stamp = os.date('%H:%M', t2)
  wait('history rendered', function()
    return header_row(win, stamp) ~= nil
  end)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { header_row(win, stamp), 0 })
  vim.api.nvim_feedkeys('u', 'x', false)
  -- The chat is left while the unread is pending
  vim.api.nvim_set_current_win(chat.origin)
  vim.wait(100)
  -- A read from elsewhere starts after the u and wins; gc lists it unread
  require('gc_mail.mailbox').actions.read({
    city = chat.city,
    message = { id = 'tc-wisp-m3', subject = 'read update', from = 'mayor' },
    read = false,
  })
  local unread = vim.json.decode(fix)
  for _, m in ipairs(unread) do
    if m.id == 'tc-wisp-m3' then
      m.labels = {}
    end
  end
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', vim.json.encode(unread))
  vim.wait(1000)
  local before = read_calls('tc-wisp-m3')
  -- The stale unread record is gone: entering the chat passes the message
  vim.api.nvim_set_current_win(win)
  wait('entering the chat marks the unread message read', function()
    return read_calls('tc-wisp-m3') == before + 1
  end)
  vim.api.nvim_set_current_win(chat.origin)
end)

-- The fake gc refuses every mark-unread
local function refuse_unread()
  raw_answer('mark-unread', 'exit', '1\n')
  raw_answer('mark-unread', 'stderr', 'fake mark-unread error\n')
end

local function unread_calls(id)
  local n = 0
  for _, c in ipairs(mail_calls()) do
    if c[4] == 'mark-unread' and c[5] == id then
      n = n + 1
    end
  end
  return n
end

test('RS6: a refused u on a message that was unread keeps its dot, with chat_mark_read false', function()
  local fix, _, t1 = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  refuse_unread()
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = false })
  preload()

  local chat = require('gc_mail.chat').open('demo-city', 'mayor')
  local win = chat.timeline_win
  local stamp = os.date('%H:%M', t1)
  local function dot()
    return table.concat(lines_of(win), '\n'):find('## mayor · ' .. stamp .. ' ●', 1, true) ~= nil
  end
  wait('history rendered with the dot', function()
    return header_row(win, stamp) ~= nil and dot()
  end)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { header_row(win, stamp), 0 })
  vim.api.nvim_feedkeys('u', 'x', false)
  wait('mark-unread refused', function()
    return unread_calls('tc-wisp-m2') == 1
  end)
  vim.wait(300)
  eq(dot(), true, 'the dot stays: ' .. table.concat(lines_of(win), '|'))
  eq(read_calls('tc-wisp-m2'), 0, 'no mark-read call')
  -- A load that lists it read takes gc's state
  local read_fix = vim.json.decode(fix)
  for _, m in ipairs(read_fix) do
    if m.id == 'tc-wisp-m2' then
      table.insert(m.labels, 'read')
    end
  end
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', vim.json.encode(read_fix))
  vim.api.nvim_feedkeys('R', 'x', false)
  wait('the load decides again', function()
    return not dot()
  end)
  eq(read_calls('tc-wisp-m2'), 0, 'still no mark-read call')
  vim.api.nvim_set_current_win(chat.origin)
end)

test('RS6: a refused u on a message that was read shows it read with no extra mark-read call', function()
  local fix, _, _, t2 = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  acted('mark-read', 'tc-wisp-m2')
  refuse_unread()
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = true })
  preload()

  local chat = require('gc_mail.chat').open('demo-city', 'mayor')
  local win = chat.timeline_win
  local stamp = os.date('%H:%M', t2)
  wait('history rendered and tc-wisp-m2 marked read', function()
    return header_row(win, stamp) ~= nil and read_calls('tc-wisp-m2') == 1
  end)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { header_row(win, stamp), 0 })
  vim.api.nvim_feedkeys('u', 'x', false)
  wait('mark-unread refused', function()
    return unread_calls('tc-wisp-m3') == 1
  end)
  vim.wait(300)
  local text = table.concat(lines_of(win), '\n')
  eq(text:find('## mayor · ' .. stamp, 1, true) ~= nil, true, 'the message is shown')
  eq(text:find('## mayor · ' .. stamp .. ' ●', 1, true), nil, 'it shows read')
  eq(read_calls('tc-wisp-m3'), 0, 'no mark-read call for it')
  eq(read_calls('tc-wisp-m2'), 1, 'and none again for the other')
  vim.api.nvim_set_current_win(chat.origin)
end)

test('RS6: with chat_mark_read true a refused u on a message that was unread keeps its dot and is not marked read', function()
  local fix, _, _, t2 = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  acted('mark-read', 'tc-wisp-m2')
  acted('mark-unread', 'tc-wisp-m3')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = true })
  preload()

  local chat = require('gc_mail.chat').open('demo-city', 'mayor')
  local win = chat.timeline_win
  local stamp = os.date('%H:%M', t2)
  local function dot()
    return table.concat(lines_of(win), '\n'):find('## mayor · ' .. stamp .. ' ●', 1, true) ~= nil
  end
  wait('history rendered and the unread message marked read', function()
    return header_row(win, stamp) ~= nil and read_calls('tc-wisp-m2') == 1
  end)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { header_row(win, stamp), 0 })
  -- The first u is accepted: unread, held out of the automatic pass
  vim.api.nvim_feedkeys('u', 'x', false)
  wait('the first mark-unread answered', function()
    return unread_calls('tc-wisp-m3') == 1 and dot()
  end)
  vim.wait(200)
  -- The second u is refused: the message was unread, so it stays unread and
  -- the automatic pass does not mark it read while the chat is open
  refuse_unread()
  vim.api.nvim_win_set_cursor(win, { header_row(win, stamp), 0 })
  vim.api.nvim_feedkeys('u', 'x', false)
  wait('the second mark-unread refused', function()
    return unread_calls('tc-wisp-m3') == 2
  end)
  vim.wait(500)
  eq(dot(), true, 'the dot stays: ' .. table.concat(lines_of(win), '|'))
  eq(read_calls('tc-wisp-m3'), 0, 'no mark-read call for it')
  -- Leaving the chat releases it (RS4): entering again marks it read
  vim.api.nvim_set_current_win(chat.origin)
  vim.wait(100)
  vim.api.nvim_set_current_win(win)
  wait('entering the chat again marks it read', function()
    return read_calls('tc-wisp-m3') == 1
  end)
  vim.api.nvim_set_current_win(chat.origin)
end)

test('RS4 and RS6: a refusal that arrives after the chat was left leaves no record', function()
  local fix, _, _, t2 = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  refuse_unread()
  raw_answer('mark-unread', 'delay', '0.6\n')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = false })
  preload()

  local chat = require('gc_mail.chat').open('demo-city', 'mayor')
  local win = chat.timeline_win
  local stamp = os.date('%H:%M', t2)
  local function dot()
    return table.concat(lines_of(win), '\n'):find('## mayor · ' .. stamp .. ' ●', 1, true) ~= nil
  end
  wait('history rendered', function()
    return header_row(win, stamp) ~= nil
  end)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { header_row(win, stamp), 0 })
  vim.api.nvim_feedkeys('u', 'x', false)
  eq(dot(), true, 'unread while the u is pending')
  -- The chat is left while the u is pending
  vim.api.nvim_set_current_win(chat.origin)
  vim.wait(100)
  -- A load that began before the refusal lists the message unread and ends
  -- after it: with no record kept, gc's list decides
  local unread = vim.json.decode(fix)
  for _, m in ipairs(unread) do
    if m.id == 'tc-wisp-m3' then
      m.labels = {}
    end
  end
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', vim.json.encode(unread))
  raw_answer('bd-list', 'delay', '1\n', 'demo-city')
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_feedkeys('R', 'x', false)
  vim.api.nvim_set_current_win(chat.origin)
  wait('mark-unread refused', function()
    return unread_calls('tc-wisp-m3') == 1
  end)
  vim.wait(1500)
  eq(dot(), true, 'the list decides: ' .. table.concat(lines_of(win), '|'))
end)

test('RS5: the load after a send keeps a pending mark-read from bringing the dot back', function()
  local fix, _, t1 = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  acted('mark-read', 'tc-wisp-m2')
  write(vim.env.FAKE_GC_MAIL .. '/mark-read.delay', '1.0\n')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = true })
  preload()

  local chat_mod = require('gc_mail.chat')
  local chat = chat_mod.open('demo-city', 'mayor')
  local win = chat.timeline_win
  local stamp = os.date('%H:%M', t1)
  local function dot()
    return table.concat(lines_of(win), '\n'):find('## mayor · ' .. stamp .. ' ●', 1, true) ~= nil
  end
  wait('mark-read started', function()
    return read_calls('tc-wisp-m2') == 1
  end)
  wait('the opening load ran', function()
    return list_calls() == 1
  end)
  vim.wait(300)
  local loads = list_calls()
  vim.api.nvim_set_current_win(chat.compose_win)
  vim.api.nvim_buf_set_lines(chat.compose_buf, 0, -1, false, { 'hello', 'body' })
  vim.api.nvim_feedkeys(vim.keycode('<Space>ms'), 'x', false)
  wait('the send drained', drained)
  wait('the load after the send ran', function()
    return list_calls() > loads
  end)
  vim.wait(300)
  eq(dot(), false, 'no dot from the send load while the mark-read is pending')
  vim.wait(1000)
  eq(dot(), false, 'no dot after gc answered')
  eq(read_calls('tc-wisp-m2'), 1, 'not passed again')
  vim.api.nvim_set_current_win(chat.origin)
end)

test('RS5: a u during a load that a later R joined is not undone by the older snapshot', function()
  local fix, _, _, t2 = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  acted('mark-unread', 'tc-wisp-m3')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = false })
  preload()

  local chat_mod = require('gc_mail.chat')
  local chat = chat_mod.open('demo-city', 'mayor')
  local win = chat.timeline_win
  local stamp = os.date('%H:%M', t2)
  wait('history rendered', function()
    return header_row(win, stamp) ~= nil
  end)
  local function dot()
    return table.concat(lines_of(win), '\n'):find('## mayor · ' .. stamp .. ' ●', 1, true) ~= nil
  end
  wait('the opening load ran', function()
    return list_calls() == 1
  end)
  vim.wait(300)
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.delay', '0.8\n')
  local loads = list_calls()
  vim.api.nvim_set_current_win(chat.compose_win)
  vim.api.nvim_buf_set_lines(chat.compose_buf, 0, -1, false, { 'hello', 'body' })
  vim.api.nvim_feedkeys(vim.keycode('<Space>ms'), 'x', false)
  wait('the load after the send started', function()
    return list_calls() > loads
  end)
  -- u while that load runs, then R joins it with a later start
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { header_row(win, stamp), 0 })
  vim.api.nvim_feedkeys('u', 'x', false)
  wait('mark-unread answered', function()
    return dot()
  end)
  vim.wait(200)
  vim.api.nvim_feedkeys('R', 'x', false)
  vim.wait(1500)
  eq(list_calls(), loads + 1, 'R joined the running load')
  eq(dot(), true, 'the older snapshot did not undo the u')
  vim.api.nvim_set_current_win(chat.origin)
end)

test('GcMailChat with a registry that lists no city says so instead of raising', function()
  write(vim.env.FAKE_GC_CITIES, cities_record({}))
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY })
  preload()
  notes = {}
  local chat_mod = require('gc_mail.chat')
  local ok, result = pcall(chat_mod.open, nil, 'mayor')
  eq(ok, true, 'no error raised: ' .. tostring(result))
  eq(result, nil, 'no chat opened')
  wait('the no-cities notice', function()
    for _, n in ipairs(notes) do
      if n.message == 'gc-mail: no cities are registered with gc' then
        return true
      end
    end
    return false
  end)
end)

test('RS1: a mark-read answer that a later u made stale leaves the message unread', function()
  local fix, _, t1 = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  acted('mark-read', 'tc-wisp-m2')
  write(vim.env.FAKE_GC_MAIL .. '/mark-read.delay', '0.6\n')
  acted('mark-unread', 'tc-wisp-m2')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = true })
  preload()

  local chat_mod = require('gc_mail.chat')
  local chat = chat_mod.open('demo-city', 'mayor')
  local win = chat.timeline_win
  local stamp = os.date('%H:%M', t1)
  wait('history rendered', function()
    return header_row(win, stamp) ~= nil
  end)
  wait('mark-read started', function()
    return read_calls('tc-wisp-m2') == 1
  end)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { header_row(win, stamp), 0 })
  vim.api.nvim_feedkeys('u', 'x', false)
  vim.wait(1200)
  chat_mod.render(chat)
  assert(table.concat(lines_of(win), '\n'):find('## mayor · ' .. stamp .. ' ●', 1, true), 'the late read answer leaves the dot')
  eq(read_calls('tc-wisp-m2'), 1, 'not passed again')
  vim.api.nvim_set_current_win(chat.origin)
end)

test('RS5: a message marked unread outside the chat is passed again on the next reload', function()
  local fix = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  acted('mark-read', 'tc-wisp-m2')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = true })
  preload()

  local chat_mod = require('gc_mail.chat')
  local chat = chat_mod.open('demo-city', 'mayor')
  wait('marked read', function()
    return read_calls('tc-wisp-m2') == 1
  end)
  vim.wait(300)
  -- The list still says unread: the mark-read answered before this reload began
  vim.api.nvim_set_current_win(chat.timeline_win)
  vim.api.nvim_feedkeys('R', 'x', false)
  wait('passed again', function()
    return read_calls('tc-wisp-m2') == 2
  end)
  vim.wait(300)
  eq(read_calls('tc-wisp-m2'), 2, 'once per reload, no loop')
  vim.api.nvim_set_current_win(chat.origin)
end)

test('two drafts of one chat kept from two tab pages both come back', function()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', '[]')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = false })
  preload()
  local chat_mod = require('gc_mail.chat')

  vim.cmd('tabnew')
  local chat1 = chat_mod.open('demo-city', 'mayor')
  vim.api.nvim_buf_set_lines(chat1.compose_buf, 0, -1, false, { 'draft one' })
  vim.cmd('tabnew')
  local chat2 = chat_mod.open('demo-city', 'mayor')
  assert(chat2.compose_buf ~= chat1.compose_buf, 'own compose buffer per tab page')
  vim.api.nvim_buf_set_lines(chat2.compose_buf, 0, -1, false, { 'draft two' })
  chat_mod.close(chat1)
  chat_mod.close(chat2)
  eq({ vim.api.nvim_buf_is_valid(chat1.compose_buf), vim.api.nvim_buf_is_valid(chat2.compose_buf) }, { true, true },
    'both drafts are kept')

  local seen = {}
  vim.cmd('tabnew')
  local chat3 = chat_mod.open('demo-city', 'mayor')
  seen[#seen + 1] = vim.api.nvim_buf_get_lines(chat3.compose_buf, 0, -1, false)[1]
  vim.cmd('tabnew')
  local chat4 = chat_mod.open('demo-city', 'mayor')
  seen[#seen + 1] = vim.api.nvim_buf_get_lines(chat4.compose_buf, 0, -1, false)[1]
  table.sort(seen)
  eq(seen, { 'draft one', 'draft two' }, 'each reopening gets a kept draft')
  chat_mod.close(chat3)
  chat_mod.close(chat4)
  while #vim.api.nvim_list_tabpages() > 1 do
    vim.cmd('tabclose!')
  end
end)

test('chat opened in a second tab does not share compose buffer or close first tab windows', function()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', '[]')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY })
  preload()

  vim.cmd('tabnew')
  local tab1 = vim.api.nvim_get_current_tabpage()
  vim.cmd('GcMailChat demo-city')
  local tab1_wins = #vim.api.nvim_tabpage_list_wins(tab1)
  eq(tab1_wins, 3, 'tab1 has 3 windows')

  -- A kept draft is reopened in tab 1; tab 2 must not share its buffer.
  local kept_buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
  vim.api.nvim_buf_set_lines(kept_buf, 0, -1, false, { 'kept draft' })
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab1)) do
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):match('/chat/') then
      vim.api.nvim_set_current_win(w)
    end
  end
  vim.api.nvim_feedkeys('q', 'x', false)
  vim.cmd('GcMailChat demo-city')
  eq(vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win()), kept_buf, 'kept draft comes back in tab 1')
  eq(#vim.api.nvim_tabpage_list_wins(tab1), 3, 'tab1 has 3 windows again')

  vim.cmd('tabnew')
  local tab2 = vim.api.nvim_get_current_tabpage()
  vim.cmd('GcMailChat demo-city')
  local tab2_wins = #vim.api.nvim_tabpage_list_wins(tab2)
  eq(tab2_wins, 3, 'tab2 has 3 windows')
  assert(vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win()) ~= kept_buf, 'tab 2 has its own compose buffer')

  local tab2_tl = nil
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab2)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(b):match('/chat/') then
      tab2_tl = w
    end
  end
  assert(tab2_tl)
  vim.api.nvim_set_current_win(tab2_tl)
  vim.api.nvim_feedkeys('q', 'x', false)

  eq(#vim.api.nvim_tabpage_list_wins(tab1), 3, 'tab1 still has 3 windows after tab2 chat closed')
  vim.cmd('tabclose!')
  vim.cmd('tabclose!')
end)

test('all chat compose and timeline buffer mappings have desc', function()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', '[]')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY })
  preload()

  vim.cmd('GcMailChat demo-city')
  local compose_win = vim.api.nvim_get_current_win()
  local compose_buf = vim.api.nvim_win_get_buf(compose_win)
  local timeline_buf = nil
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(b):match('/chat/') then
      timeline_buf = b
    end
  end

  local cp_maps = vim.api.nvim_buf_get_keymap(compose_buf, 'n')
  local has_send_desc = false
  for _, m in ipairs(cp_maps) do
    if m.lhs == '<Space>ms' or m.lhs == ' ms' then
      eq(m.desc, 'gc-mail: send', 'compose mapping has desc')
      has_send_desc = true
    end
  end
  assert(has_send_desc, 'compose has <Space>ms mapping with desc')

  local cp_descs = {}
  for _, m in ipairs(cp_maps) do
    cp_descs[m.lhs] = m.desc
  end
  eq(cp_descs['q'], 'gc-mail: close chat')
  eq(cp_descs['<C-J>'] or cp_descs['<C-j>'], 'gc-mail: focus compose')
  eq(cp_descs['<C-K>'] or cp_descs['<C-k>'], 'gc-mail: focus timeline')
  eq(cp_descs['G'], nil, 'the compose box keeps Vim its own G: no buffer mapping')

  local tl_maps = vim.api.nvim_buf_get_keymap(timeline_buf, 'n')
  local descs = {}
  for _, m in ipairs(tl_maps) do
    descs[m.lhs] = m.desc
  end
  eq(descs['<CR>'], 'gc-mail: open message')
  eq(descs['t'], 'gc-mail: open thread')
  eq(descs['u'], 'gc-mail: mark unread')
  eq(descs['R'], 'gc-mail: reload history')
  eq(descs['q'], 'gc-mail: close chat')
  eq(descs['G'], 'gc-mail: jump to the latest message')
  eq(descs['<C-J>'] or descs['<C-j>'], 'gc-mail: focus compose')
  eq(descs['<C-K>'] or descs['<C-k>'], 'gc-mail: focus timeline')
  eq(descs[']m'], 'gc-mail: next message')
  eq(descs['[m'], 'gc-mail: previous message')
  -- Every chat mapping carries a gc-mail: desc.
  for _, m in ipairs(cp_maps) do
    if m.lhs ~= '[[' and m.lhs ~= ']]' and m.lhs ~= 'gO' then
      assert(type(m.desc) == 'string' and m.desc:sub(1, 9) == 'gc-mail: ', 'compose mapping ' .. m.lhs .. ' has a gc-mail: desc')
    end
  end
  for _, m in ipairs(tl_maps) do
    if m.lhs ~= '[[' and m.lhs ~= ']]' and m.lhs ~= 'gO' then
      assert(type(m.desc) == 'string' and m.desc:sub(1, 9) == 'gc-mail: ', 'timeline mapping ' .. m.lhs .. ' has a gc-mail: desc')
    end
  end
end)

test('RS3: with chat_mark_read true the unread message is marked read once when current, not twice; with false, no call', function()
  local fix = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  acted('mark-read', 'tc-wisp-m2')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = true })
  preload()

  vim.cmd('GcMailChat demo-city')
  local timeline_buf = nil
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(b):match('/chat/') then
      timeline_buf = b
    end
  end

  wait('mark-read called in fake gc', function()
    local calls = mail_calls()
    for _, call in ipairs(calls) do
      if call[4] == 'mark-read' and call[5] == 'tc-wisp-m2' then
        return true
      end
    end
    return false
  end)

  local mark_calls = 0
  for _, call in ipairs(mail_calls()) do
    if call[4] == 'mark-read' and call[5] == 'tc-wisp-m2' then
      mark_calls = mark_calls + 1
    end
  end
  eq(mark_calls, 1, 'mark-read called exactly once')

  wait('● is gone from timeline', function()
    local text = table.concat(vim.api.nvim_buf_get_lines(timeline_buf, 0, -1, false), '\n')
    return text:find('●', 1, true) == nil
  end)

  require('gc_mail.chat').render(require('gc_mail.chat').open('demo-city', 'mayor'))
  vim.wait(100)
  mark_calls = 0
  for _, call in ipairs(mail_calls()) do
    if call[4] == 'mark-read' and call[5] == 'tc-wisp-m2' then
      mark_calls = mark_calls + 1
    end
  end
  eq(mark_calls, 1, 'not called twice on re-render')

  reset()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = false })
  preload()
  vim.cmd('GcMailChat demo-city')
  vim.wait(200)
  mark_calls = 0
  for _, call in ipairs(mail_calls()) do
    if call[4] == 'mark-read' then
      mark_calls = mark_calls + 1
    end
  end
  eq(mark_calls, 0, 'no mark-read call with chat_mark_read = false')
end)

test('q closes both windows and keeps non-empty compose text for next open; <Space>mc reopens last chat', function()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', '[]')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY })
  preload()

  vim.cmd('GcMailChat demo-city')
  local compose_win = vim.api.nvim_get_current_win()
  local compose_buf = vim.api.nvim_win_get_buf(compose_win)
  local timeline_win = nil
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(b):match('/chat/') then
      timeline_win = w
    end
  end
  assert(timeline_win and compose_win)

  vim.api.nvim_buf_set_lines(compose_buf, 0, -1, false, { 'draft in progress', 'line 2' })

  vim.api.nvim_set_current_win(timeline_win)
  vim.api.nvim_feedkeys('q', 'x', false)

  eq(vim.api.nvim_win_is_valid(timeline_win), false, 'timeline window closed')
  eq(vim.api.nvim_win_is_valid(compose_win), false, 'compose window closed')

  vim.api.nvim_feedkeys(vim.keycode('<Space>mc'), 'x', false)
  local new_compose_win = vim.api.nvim_get_current_win()
  local new_compose_buf = vim.api.nvim_win_get_buf(new_compose_win)
  eq(vim.api.nvim_buf_get_lines(new_compose_buf, 0, -1, false), { 'draft in progress', 'line 2' }, 'compose text preserved')

  vim.api.nvim_buf_set_lines(new_compose_buf, 0, -1, false, { '' })
  local new_timeline_win = nil
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(b):match('/chat/') then
      new_timeline_win = w
    end
  end
  vim.api.nvim_set_current_win(new_timeline_win)
  vim.api.nvim_feedkeys('q', 'x', false)
  eq(vim.api.nvim_buf_is_valid(new_compose_buf), false, 'empty compose buffer was wiped')
end)

test('chat focus: q from the compose box closes both windows like q in the timeline and keeps the draft', function()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', '[]')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY })
  preload()

  local origin_win = vim.api.nvim_get_current_win()
  vim.cmd('GcMailChat demo-city')
  local compose_win = vim.api.nvim_get_current_win()
  local compose_buf = vim.api.nvim_win_get_buf(compose_win)
  local timeline_win = nil
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(b):match('/chat/') then
      timeline_win = w
    end
  end
  assert(timeline_win and compose_win and timeline_win ~= compose_win, 'both chat windows open')
  eq(vim.api.nvim_get_current_win(), compose_win, 'the cursor starts in the compose box')

  vim.api.nvim_buf_set_lines(compose_buf, 0, -1, false, { 'draft from compose', 'line 2' })
  vim.api.nvim_set_current_win(compose_win)
  vim.api.nvim_feedkeys('q', 'x', false)
  eq(vim.api.nvim_win_is_valid(timeline_win), false, 'timeline window closed from compose q')
  eq(vim.api.nvim_win_is_valid(compose_win), false, 'compose window closed from compose q')
  eq(vim.api.nvim_get_current_win(), origin_win, 'focus back in the origin window')

  vim.cmd('GcMailChat demo-city')
  local new_compose_buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
  eq(vim.api.nvim_buf_get_lines(new_compose_buf, 0, -1, false), { 'draft from compose', 'line 2' }, 'non-empty draft returns on reopen')

  -- Insert-mode typing is unaffected: q in insert mode inserts text, it does not close.
  vim.api.nvim_buf_set_lines(new_compose_buf, 0, -1, false, { '' })
  vim.api.nvim_feedkeys('iq]mG' .. vim.keycode('<Esc>'), 'x', false)
  eq(vim.api.nvim_get_mode().mode, 'n', 'back in normal mode')
  eq(vim.api.nvim_buf_get_lines(new_compose_buf, 0, -1, false), { 'q]mG' }, 'insert-mode typing inserts, mappings are normal mode only')
  local still_open = false
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):match('/chat/') then
      still_open = true
    end
  end
  eq(still_open, true, 'the chat stays open after insert-mode typing')

  -- No key but the send key sends: the focus, navigation and close keys queue nothing.
  eq(gc_mail.queue.list(), {}, 'nothing queued by the focus keys')
end)

test('chat focus: <C-j>/<C-k> move between timeline and compose and a u-held id stays held across those moves (RS4)', function()
  local fix, _, _, t2 = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  acted('mark-read', 'tc-wisp-m2')
  acted('mark-unread', 'tc-wisp-m3')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = true })
  preload()

  local chat_mod = require('gc_mail.chat')
  local chat = chat_mod.open('demo-city', 'mayor')
  local win = chat.timeline_win
  local stamp = os.date('%H:%M', t2)
  wait('history rendered', function()
    return header_row(win, stamp) ~= nil
  end)
  wait('the unread message is marked read', function()
    return read_calls('tc-wisp-m2') == 1
  end)

  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { header_row(win, stamp), 0 })
  vim.api.nvim_feedkeys('u', 'x', false)
  wait('mark-unread called', function()
    for _, c in ipairs(mail_calls()) do
      if c[4] == 'mark-unread' and c[5] == 'tc-wisp-m3' then
        return true
      end
    end
    return false
  end)
  vim.wait(300)
  eq(read_calls('tc-wisp-m3'), 0, 'u does not undo itself')

  -- The focus keys move between the chat's own windows and never release the hold.
  vim.api.nvim_feedkeys(vim.keycode('<C-j>'), 'x', false)
  eq(vim.api.nvim_get_current_win(), chat.compose_win, '<C-j> focuses the compose box')
  vim.wait(150)
  eq(read_calls('tc-wisp-m3'), 0, 'compose focus keeps the hold (RS4)')
  vim.api.nvim_feedkeys(vim.keycode('<C-k>'), 'x', false)
  eq(vim.api.nvim_get_current_win(), win, '<C-k> focuses the timeline')
  vim.wait(150)
  eq(read_calls('tc-wisp-m3'), 0, 'timeline focus keeps the hold (RS4)')
  -- From the compose box back again, still held.
  vim.api.nvim_feedkeys(vim.keycode('<C-j>'), 'x', false)
  eq(vim.api.nvim_get_current_win(), chat.compose_win, 'back in the compose box')
  vim.wait(150)
  eq(read_calls('tc-wisp-m3'), 0, 'still held')
  vim.api.nvim_feedkeys(vim.keycode('<C-k>'), 'x', false)
  eq(vim.api.nvim_get_current_win(), win, 'back in the timeline')

  -- Leaving the chat releases it: entering again marks it read.
  vim.api.nvim_set_current_win(chat.origin)
  vim.wait(100)
  vim.api.nvim_set_current_win(win)
  wait('entering the chat again marks it read', function()
    return read_calls('tc-wisp-m3') == 1
  end)
  vim.api.nvim_set_current_win(chat.origin)
end)

test('chat navigation: ]m/[m walk the three message headings and stop at the ends; G jumps to latest and follows', function()
  local fix = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = false })
  preload()

  local chat_mod = require('gc_mail.chat')
  local chat = chat_mod.open('demo-city', 'mayor')
  local win = chat.timeline_win
  wait('three messages rendered', function()
    local n = 0
    for _, block in ipairs(chat.message_blocks) do
      if block.message then
        n = n + 1
      end
    end
    return n == 3
  end)
  local starts = {}
  for _, block in ipairs(chat.message_blocks) do
    if block.message then
      starts[#starts + 1] = block.start_line
    end
  end
  eq(#starts, 3, 'three message headings')
  local last_line = #vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)

  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { starts[1], 0 })
  vim.api.nvim_feedkeys(']m', 'x', false)
  eq(vim.api.nvim_win_get_cursor(win)[1], starts[2], ']m lands on the second heading')
  vim.api.nvim_feedkeys(']m', 'x', false)
  eq(vim.api.nvim_win_get_cursor(win)[1], starts[3], ']m lands on the third heading')
  vim.api.nvim_feedkeys(']m', 'x', false)
  eq(vim.api.nvim_win_get_cursor(win)[1], starts[3], ']m stops at the last message')
  vim.api.nvim_feedkeys('[m', 'x', false)
  eq(vim.api.nvim_win_get_cursor(win)[1], starts[2], '[m lands on the second heading')
  vim.api.nvim_feedkeys('[m', 'x', false)
  eq(vim.api.nvim_win_get_cursor(win)[1], starts[1], '[m lands on the first heading')
  vim.api.nvim_feedkeys('[m', 'x', false)
  eq(vim.api.nvim_win_get_cursor(win)[1], starts[1], '[m stops at the first message')

  -- G in the timeline lands on the last line and follows again.
  vim.api.nvim_feedkeys('G', 'x', false)
  eq(vim.api.nvim_win_get_cursor(win)[1], last_line, 'G lands on the last line')

  -- Nothing queued or sent by the navigation keys.
  eq(gc_mail.queue.list(), {}, 'navigation queues nothing')

  vim.api.nvim_set_current_win(chat.origin)
end)

test('chat compose: a configured send key keeps sending where it meets a close or focus key', function()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', '[]')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_send_keys = { '<C-j>' } })
  preload()

  vim.cmd('GcMailChat demo-city')
  local compose_win = vim.api.nvim_get_current_win()
  local compose_buf = vim.api.nvim_win_get_buf(compose_win)

  local cp_descs = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(compose_buf, 'n')) do
    cp_descs[m.lhs] = m.desc
  end
  eq(cp_descs['<C-J>'] or cp_descs['<C-j>'], 'gc-mail: send', 'the configured <C-j> still sends')

  vim.api.nvim_buf_set_lines(compose_buf, 0, -1, false, { 'hello mayor', 'body line' })
  vim.api.nvim_feedkeys(vim.keycode('<C-j>'), 'x', false)
  eq(vim.api.nvim_buf_get_lines(compose_buf, 0, -1, false), { '' }, '<C-j> sends the draft instead of focusing')
  eq(vim.api.nvim_get_current_win(), compose_win, 'focus stays in the compose box')

  -- A send key on the close key: q in the compose box sends and the chat stays open.
  reset()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', '[]')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_send_keys = { 'q' } })
  preload()

  vim.cmd('GcMailChat demo-city')
  compose_win = vim.api.nvim_get_current_win()
  compose_buf = vim.api.nvim_win_get_buf(compose_win)
  local timeline_win = nil
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(b):match('/chat/') then
      timeline_win = w
    end
  end
  assert(timeline_win, 'the timeline is open')

  cp_descs = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(compose_buf, 'n')) do
    cp_descs[m.lhs] = m.desc
  end
  eq(cp_descs['q'], 'gc-mail: send', 'the configured q still sends')

  vim.api.nvim_buf_set_lines(compose_buf, 0, -1, false, { 'hello mayor', 'body line' })
  vim.api.nvim_feedkeys('q', 'x', false)
  eq(vim.api.nvim_buf_get_lines(compose_buf, 0, -1, false), { '' }, 'q sends the draft instead of closing')
  eq(vim.api.nvim_win_is_valid(timeline_win), true, 'the timeline stays open')
  eq(vim.api.nvim_win_is_valid(compose_win), true, 'the compose box stays open')

  -- A send key that starts with a shared key: the shared mapping is skipped
  -- so the longer send key stays reachable.
  reset()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', '[]')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_send_keys = { 'qs' } })
  preload()

  vim.cmd('GcMailChat demo-city')
  compose_win = vim.api.nvim_get_current_win()
  compose_buf = vim.api.nvim_win_get_buf(compose_win)
  timeline_win = nil
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(b):match('/chat/') then
      timeline_win = w
    end
  end
  assert(timeline_win, 'the timeline is open')

  cp_descs = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(compose_buf, 'n')) do
    cp_descs[m.lhs] = m.desc
  end
  eq(cp_descs['q'], nil, 'no q close mapping when a send key starts with q')
  eq(cp_descs['qs'], 'gc-mail: send', 'the qs send key is mapped')

  vim.api.nvim_buf_set_lines(compose_buf, 0, -1, false, { 'hello mayor', 'body line' })
  vim.api.nvim_feedkeys('qs', 'x', false)
  eq(vim.api.nvim_buf_get_lines(compose_buf, 0, -1, false), { '' }, 'qs sends the draft instead of closing')
  eq(vim.api.nvim_win_is_valid(timeline_win), true, 'the timeline stays open')
  eq(vim.api.nvim_win_is_valid(compose_win), true, 'the compose box stays open')
end)

test('chat compose: the statusline only advertises close and focus keys that are actually mapped', function()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', '[]')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY })
  preload()

  vim.cmd('GcMailChat demo-city')
  local compose_win = vim.api.nvim_get_current_win()
  local st = vim.wo[compose_win].statusline
  assert(st:find('q close', 1, true), 'the default statusline advertises q close: ' .. st)
  assert(st:find('<C-j>/<C-k> focus', 1, true), 'the default statusline advertises the focus pair: ' .. st)

  -- A send key on the close key: the statusline stops advertising q close.
  reset()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', '[]')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_send_keys = { 'q' } })
  preload()

  vim.cmd('GcMailChat demo-city')
  compose_win = vim.api.nvim_get_current_win()
  st = vim.wo[compose_win].statusline
  assert(st:find('q send', 1, true), 'the send key stays advertised: ' .. st)
  eq(st:find('q close', 1, true), nil, 'no q close advertised when q sends: ' .. st)
  assert(st:find('<C-j>/<C-k> focus', 1, true), 'the focus pair stays advertised: ' .. st)

  -- A send key starting with a focus key: only the other half is advertised.
  reset()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', '[]')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_send_keys = { '<C-j>s' } })
  preload()

  vim.cmd('GcMailChat demo-city')
  compose_win = vim.api.nvim_get_current_win()
  st = vim.wo[compose_win].statusline
  assert(st:find('q close', 1, true), 'q close stays advertised: ' .. st)
  eq(st:find('<C-j> focus', 1, true), nil, 'no <C-j> focus advertised when a send key starts with it: ' .. st)
  assert(st:find('<C-k> focus', 1, true), 'the other half stays advertised: ' .. st)
end)

test('chat compose: G keeps Vim its own motion in the draft and never leaves the compose box', function()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', '[]')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY })
  preload()

  vim.cmd('GcMailChat demo-city')
  local compose_win = vim.api.nvim_get_current_win()
  local compose_buf = vim.api.nvim_win_get_buf(compose_win)

  vim.api.nvim_buf_set_lines(compose_buf, 0, -1, false, { 'one', 'two', 'three' })
  vim.api.nvim_win_set_cursor(compose_win, { 1, 0 })
  vim.api.nvim_feedkeys('G', 'x', false)
  eq(vim.api.nvim_win_get_cursor(compose_win), { 3, 0 }, 'G moves to the last draft line')
  eq(vim.api.nvim_get_current_win(), compose_win, 'focus stays in the compose box')
  vim.api.nvim_feedkeys('gg', 'x', false)
  eq(vim.api.nvim_win_get_cursor(compose_win), { 1, 0 }, 'gg moves back to the first draft line')
  eq(gc_mail.queue.list(), {}, 'motion queues nothing')
end)

test('timeline keys: <CR> opens message, t opens thread, u marks unread, R reloads', function()
  local fix, past, t1, t2 = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  acted('mark-unread', 'tc-wisp-m3')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = false })
  preload()

  vim.cmd('GcMailChat demo-city')
  local timeline_win = nil
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(b):match('/chat/') then
      timeline_win = w
    end
  end
  wait('timeline rendered', function()
    return #vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(timeline_win), 0, -1, false) > 5
  end)

  vim.api.nvim_set_current_win(timeline_win)
  vim.api.nvim_win_set_cursor(timeline_win, { 1, 0 })

  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  wait('message view opened', function()
    local b = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
    return vim.api.nvim_buf_get_name(b):match('gc%-mail://demo%-city/tc%-wisp%-m1$') ~= nil
  end)
  vim.cmd('close')

  vim.api.nvim_set_current_win(timeline_win)
  vim.api.nvim_win_set_cursor(timeline_win, { 7, 0 })
  vim.api.nvim_feedkeys('t', 'x', false)
  wait('thread view opened', function()
    local b = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
    return vim.api.nvim_buf_get_name(b):match('gc%-mail://demo%-city/thread/thread%-1a2b3c$') ~= nil
  end)
  vim.cmd('close')

  vim.api.nvim_set_current_win(timeline_win)
  vim.api.nvim_win_set_cursor(timeline_win, { 14, 0 })
  vim.api.nvim_feedkeys('u', 'x', false)
  wait('mark-unread called in fake log', function()
    for _, call in ipairs(mail_calls()) do
      if call[4] == 'mark-unread' and call[5] == 'tc-wisp-m3' then
        return true
      end
    end
    return false
  end)
  wait('● appears for tc-wisp-m3', function()
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(timeline_win), 0, -1, false)
    return table.concat(lines, '\n'):find('## mayor · ' .. os.date('%H:%M', t2) .. ' ●', 1, true) ~= nil
  end)

  local before_calls = #mail_calls()
  vim.api.nvim_feedkeys('R', 'x', false)
  wait('history.load called from R', function()
    return #mail_calls() > before_calls
  end)
end)

-- ---- the chat's live updates ---------------------------------------------------

local function bd_list_calls(path)
  return #vim.tbl_filter(function(c)
    return c[3] == 'bd' and c[4] == 'list' and c[2] == path
  end, mail_calls())
end

-- One event log line of a mail event that carries its message, as gc writes it.
local function message_line(kind, fields)
  local m = vim.tbl_extend('force', {
    from = 'mayor', to = 'human', read = false, created_at = os.date('!%Y-%m-%dT%H:%M:%SZ', os.time()),
  }, fields)
  return vim.json.encode({ seq = 1, type = kind, ts = m.created_at, actor = m.from, subject = m.id,
    payload = { message = m } }) .. '\n'
end

-- One event log line of a mail event about message `id`, with no payload.
local function id_line(kind, id)
  return vim.json.encode({ seq = 1, type = kind, ts = '2026-10-08T10:00:00Z', actor = 'human', subject = id }) .. '\n'
end

-- A chat with mayor in demo-city (a real directory with an empty event log, or
-- none with `no_log`), opened on the conversation fixture, after its first
-- history load. No background watch; nothing is marked read unless `opts` says so.
local function live_chat(opts, no_log)
  require('gc_mail.history').reset()
  local fix, past, t1, t2 = conversation_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', fix)
  gc_mail.setup(vim.tbl_extend('force', { state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY,
    chat_mark_read = false, watch = false }, opts or {}))
  local cities, log = city_dirs()
  if not no_log then
    write(log, '')
  end
  vim.cmd('GcMailChat demo-city')
  local chat = { cities = cities, log = log, compose_win = vim.api.nvim_get_current_win(), past = past, t1 = t1, t2 = t2,
    fix = fix }
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):match('/chat/') then
      chat.timeline_win = w
    end
  end
  wait('the chat loaded its history once', function()
    return bd_list_calls(cities[1].path) == 1 and table.concat(lines_of(chat.timeline_win), '\n'):find('all good', 1, true)
  end)
  vim.wait(100)
  return chat
end

local function shown(chat)
  return table.concat(lines_of(chat.timeline_win), '\n')
end

test('chat live: a mail.replied for the conversation renders at once with no gc call; another conversation changes nothing; no message loads once', function()
  local chat = live_chat()
  local path = chat.cities[1].path
  local calls = #mail_calls()
  local lines = lines_of(chat.timeline_win)
  eq(vim.api.nvim_win_get_cursor(chat.timeline_win)[1], #lines, 'the timeline cursor starts at the end')
  local when = os.time()
  append(chat.log, message_line('mail.replied', { id = 'tc-wisp-live1', subject = 'live answer',
    body = 'live answer\nfrom the log', created_at = os.date('!%Y-%m-%dT%H:%M:%SZ', when) }))
  wait('the answer shows within 1 s', function()
    return shown(chat):find('from the log', 1, true) ~= nil
  end, 1000)
  local after = lines_of(chat.timeline_win)
  eq(vim.list_slice(after, #after - 5), { '## mayor · ' .. os.date('%H:%M', when) .. ' ●', '', 'live answer',
    'from the log', '', '---' }, 'at the bottom, unread')
  eq(vim.api.nvim_win_get_cursor(chat.timeline_win)[1], #after, 'the cursor follows the end')
  eq(#mail_calls(), calls, 'no bd list, inbox or other gc call')

  append(chat.log, message_line('mail.replied', { id = 'tc-wisp-live2', to = 'planner', subject = 'for the planner',
    body = 'for the planner' }))
  vim.wait(300)
  eq(lines_of(chat.timeline_win), after, 'another conversation changes nothing shown')
  eq(require('gc_mail.history').cache[path].by_id['tc-wisp-live2'] ~= nil, true, 'but it is cached')
  eq(#mail_calls(), calls, 'and calls nothing')

  append(chat.log, id_line('mail.sent', 'tc-wisp-live3'))
  wait('a mail.sent without its message loads the city', function()
    return bd_list_calls(path) == 2
  end)
  vim.wait(300)
  eq(bd_list_calls(path), 2, 'exactly one bd list call')
  eq(#mail_calls(), calls + 1, 'and nothing else')
end)

test('chat live: read, unread and archived events move the dot and the closed mark; an unknown id changes nothing', function()
  local chat = live_chat()
  local heading = '## mayor · ' .. os.date('%H:%M', chat.t1)
  local calls = #mail_calls()
  eq(lines_of(chat.timeline_win)[7], heading .. ' ●', 'unread to begin with')
  append(chat.log, id_line('mail.marked_read', 'tc-wisp-m2'))
  wait('marked_read removes the dot', function()
    return lines_of(chat.timeline_win)[7] == heading
  end, 1000)
  append(chat.log, id_line('mail.marked_unread', 'tc-wisp-m2'))
  wait('marked_unread brings it back', function()
    return lines_of(chat.timeline_win)[7] == heading .. ' ●'
  end, 1000)
  append(chat.log, id_line('mail.archived', 'tc-wisp-m2'))
  wait('archived marks it closed in the heading', function()
    return lines_of(chat.timeline_win)[7] == heading .. ' (closed) ●'
  end, 1000)
  local before = lines_of(chat.timeline_win)
  append(chat.log, id_line('mail.read', 'tc-wisp-nope') .. id_line('mail.deleted', 'tc-wisp-nope'))
  vim.wait(300)
  eq(lines_of(chat.timeline_win), before, 'an unknown id changes nothing')
  eq(#mail_calls(), calls, 'no gc call for any of them')
end)

test('chat live: with the timeline cursor moved up, an appended message does not move it', function()
  local chat = live_chat()
  vim.api.nvim_win_set_cursor(chat.timeline_win, { 3, 0 })
  append(chat.log, message_line('mail.replied', { id = 'tc-wisp-live1', subject = 'later', body = 'later\nanswer' }))
  wait('the answer shows', function()
    return shown(chat):find('later\nanswer', 1, true) ~= nil
  end, 1000)
  eq(vim.api.nvim_win_get_cursor(chat.timeline_win), { 3, 0 }, 'the cursor stays where it was')
end)

-- The timeline of `chat` six rows high, too short for the conversation, with
-- the cursor and the view at its end.
local function short_timeline(chat)
  vim.api.nvim_win_set_height(chat.timeline_win, 6)
  vim.api.nvim_win_set_cursor(chat.timeline_win, { #lines_of(chat.timeline_win), 0 })
end

-- The timeline's cursor line, first and last line shown, and last line.
local function timeline_view(chat)
  return vim.api.nvim_win_call(chat.timeline_win, function()
    return { cursor = vim.fn.line('.'), top = vim.fn.line('w0'), bottom = vim.fn.line('w$'), last = vim.fn.line('$') }
  end)
end

-- The count of newer messages below the view the timeline's statusline shows.
local function newer_below(chat)
  return tonumber(vim.wo[chat.timeline_win].statusline:match('↓ (%d+) newer below'))
end

-- The timeline's view scrolled up 8 lines with <C-y>, no cursor motion.
local function scroll_up(chat)
  vim.api.nvim_win_call(chat.timeline_win, function()
    vim.cmd('exe "normal! 8\\<C-y>"')
  end)
end

test('chat live: with the view scrolled up, an appended message keeps cursor and topline and counts one newer below', function()
  local chat = live_chat()
  short_timeline(chat)
  local start = timeline_view(chat)
  eq(start.bottom, start.last, 'the view shows the end')
  scroll_up(chat)
  local before = timeline_view(chat)
  assert(before.bottom < before.last, 'the view no longer shows the end')
  local compose_cursor = vim.api.nvim_win_get_cursor(chat.compose_win)
  eq(newer_below(chat), nil, 'nothing waits below yet')
  append(chat.log, message_line('mail.replied', { id = 'tc-wisp-live1', subject = 'later', body = 'later\nanswer' }))
  wait('the answer shows', function()
    return shown(chat):find('later\nanswer', 1, true) ~= nil
  end, 1000)
  local after = timeline_view(chat)
  eq({ after.cursor, after.top, after.bottom }, { before.cursor, before.top, before.bottom }, 'cursor and view held')
  eq(newer_below(chat), 1, 'one newer message below')
  eq(vim.api.nvim_win_get_cursor(chat.compose_win), compose_cursor, 'the compose cursor did not move')

  -- A read flag and a closed mark above change no message id: no new count
  local heading = '## mayor · ' .. os.date('%H:%M', chat.t1)
  append(chat.log, id_line('mail.marked_read', 'tc-wisp-m2') .. id_line('mail.archived', 'tc-wisp-m3'))
  wait('the read flag and the closed mark show', function()
    local lines = lines_of(chat.timeline_win)
    return lines[7] == heading and lines[14]:find('(closed)', 1, true) ~= nil
  end, 1000)
  local later = timeline_view(chat)
  eq({ later.cursor, later.top }, { before.cursor, before.top }, 'still held')
  eq(newer_below(chat), 1, 'still one newer message below')
end)

test('chat live: with the cursor and the view at the end, the view follows an appended message', function()
  local chat = live_chat()
  short_timeline(chat)
  append(chat.log, message_line('mail.replied', { id = 'tc-wisp-live1', subject = 'later', body = 'later\nanswer' }))
  wait('the answer shows', function()
    return shown(chat):find('later\nanswer', 1, true) ~= nil
  end, 1000)
  local after = timeline_view(chat)
  eq({ after.cursor, after.bottom }, { after.last, after.last }, 'cursor and view on the new end')
  eq(lines_of(chat.timeline_win)[after.last], '---', 'the end of the new message')
  eq(newer_below(chat), nil, 'nothing counted below')
end)

test('chat live: G jumps to the latest message, clears the count and follows again', function()
  local chat = live_chat()
  short_timeline(chat)
  scroll_up(chat)
  append(chat.log, message_line('mail.replied', { id = 'tc-wisp-live1', subject = 'later', body = 'later\nanswer' })
    .. message_line('mail.replied', { id = 'tc-wisp-live2', subject = 'and more', body = 'and more' }))
  wait('both answers counted', function()
    return newer_below(chat) == 2
  end, 1000)
  vim.api.nvim_set_current_win(chat.timeline_win)
  vim.api.nvim_feedkeys('G', 'x', false)
  local at = timeline_view(chat)
  eq({ at.cursor, at.bottom }, { at.last, at.last }, 'at the latest message')
  eq(newer_below(chat), nil, 'the count is cleared')
  append(chat.log, message_line('mail.replied', { id = 'tc-wisp-live3', subject = 'newest', body = 'newest' }))
  wait('the newest shows', function()
    return shown(chat):find('newest', 1, true) ~= nil
  end, 1000)
  local after = timeline_view(chat)
  eq({ after.cursor, after.bottom }, { after.last, after.last }, 'following again')
  eq(newer_below(chat), nil, 'nothing counted below')
end)

-- The timeline window of a reopened chat, found by its buffer name.
local function reopened_timeline()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):match('/chat/') then
      return w
    end
  end
end

-- The cursor line, first and last line shown, and last line of window `win`.
local function view_of_win(win)
  return vim.api.nvim_win_call(win, function()
    return { cursor = vim.fn.line('.'), top = vim.fn.line('w0'), bottom = vim.fn.line('w$'), last = vim.fn.line('$') }
  end)
end

test('chat reopen: closing scrolled-up reopens with the same message at the top', function()
  local chat = live_chat()
  short_timeline(chat)
  -- The middle message at the top of the view: the anchor is the message at
  -- the top, plus the held following state.
  vim.api.nvim_win_set_cursor(chat.timeline_win, { 7, 0 })
  vim.api.nvim_win_call(chat.timeline_win, function()
    vim.cmd('normal! zt')
  end)
  local before = timeline_view(chat)
  eq({ before.cursor, before.top }, { 7, 7 }, 'the middle message at the top')
  assert(before.bottom < before.last, 'the view no longer shows the end')
  local top_text = lines_of(chat.timeline_win)[before.top]
  eq(top_text, '## mayor · ' .. os.date('%H:%M', chat.t1) .. ' ●', 'the anchored heading')
  vim.api.nvim_set_current_win(chat.timeline_win)
  vim.api.nvim_feedkeys('q', 'x', false)
  wait('closed', function()
    return not vim.api.nvim_win_is_valid(chat.timeline_win)
  end)
  vim.cmd('GcMailChat demo-city')
  local win = reopened_timeline()
  assert(win, 'reopened')
  wait('the anchor is back at the top', function()
    local ok, top = pcall(function()
      return view_of_win(win).top
    end)
    return ok and top == before.top
  end)
  vim.wait(100)
  local after = view_of_win(win)
  eq({ after.cursor, after.top }, { before.cursor, before.top }, 'the same message at the same view position')
  eq(lines_of(win)[after.top], top_text, 'the anchored heading')
  eq(newer_below({ timeline_win = win }), nil, 'nothing counted below')
end)

test('chat reopen: closing at the end reopens following the new end', function()
  local chat = live_chat()
  short_timeline(chat)
  local start = timeline_view(chat)
  eq({ start.cursor, start.bottom }, { start.last, start.last }, 'at the end')
  vim.api.nvim_set_current_win(chat.timeline_win)
  vim.api.nvim_feedkeys('q', 'x', false)
  wait('closed', function()
    return not vim.api.nvim_win_is_valid(chat.timeline_win)
  end)
  local list = vim.json.decode(chat.fix)
  list[#list + 1] = { id = 'tc-wisp-new1', title = 'new arrival', sender = 'mayor', assignee = 'human',
    status = 'open', description = 'new arrival\nfresh body', created_at = os.date('!%Y-%m-%dT%H:%M:%SZ'), labels = {} }
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', vim.json.encode(list))
  vim.cmd('GcMailChat demo-city')
  local win = reopened_timeline()
  assert(win, 'reopened')
  wait('the new message shows', function()
    return table.concat(lines_of(win), '\n'):find('fresh body', 1, true) ~= nil
  end)
  vim.wait(100)
  local after = view_of_win(win)
  eq(after.last > start.last, true, 'the message was appended')
  eq({ after.cursor, after.bottom }, { after.last, after.last }, 'following the new end')
  eq(newer_below({ timeline_win = win }), nil, 'nothing counted below')
end)

test('chat reopen: a gone anchor reopens at the end', function()
  local chat = live_chat()
  short_timeline(chat)
  vim.api.nvim_win_set_cursor(chat.timeline_win, { 7, 0 })
  vim.api.nvim_win_call(chat.timeline_win, function()
    vim.cmd('normal! zt')
  end)
  local before = timeline_view(chat)
  eq({ before.cursor, before.top }, { 7, 7 }, 'the middle message at the top')
  vim.api.nvim_set_current_win(chat.timeline_win)
  vim.api.nvim_feedkeys('q', 'x', false)
  wait('closed', function()
    return not vim.api.nvim_win_is_valid(chat.timeline_win)
  end)
  local list = vim.json.decode(chat.fix)
  local kept = {}
  for _, entry in ipairs(list) do
    if entry.id ~= 'tc-wisp-m2' then
      kept[#kept + 1] = entry
    end
  end
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', vim.json.encode(kept))
  vim.cmd('GcMailChat demo-city')
  local win = reopened_timeline()
  assert(win, 'reopened')
  wait('the anchor is gone', function()
    return table.concat(lines_of(win), '\n'):find('this is a reply', 1, true) == nil
      and table.concat(lines_of(win), '\n'):find('all good', 1, true) ~= nil
  end)
  vim.wait(100)
  local after = view_of_win(win)
  eq({ after.cursor, after.bottom }, { after.last, after.last }, 'at the end instead')
end)

-- No chat window left anywhere: a directly closed timeline window finishes
-- closing on schedule, so the timeline being gone is not enough.
local function wait_chat_closed()
  wait('closed', function()
    if #vim.api.nvim_tabpage_list_wins(0) ~= 1 then
      return false
    end
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win()))
    return name:find('/chat/', 1, true) == nil and name:find('/compose/', 1, true) == nil
  end)
end

test('chat reopen: closing the timeline window itself keeps the place, with no stale anchor', function()
  local chat = live_chat()
  short_timeline(chat)
  vim.api.nvim_win_set_cursor(chat.timeline_win, { 7, 0 })
  vim.api.nvim_win_call(chat.timeline_win, function()
    vim.cmd('normal! zt')
  end)
  local before = timeline_view(chat)
  eq({ before.cursor, before.top }, { 7, 7 }, 'the middle message at the top')
  local top_text = lines_of(chat.timeline_win)[before.top]
  -- Close the timeline window directly, not through the q mapping: the window
  -- is already gone when its WinClosed runs.
  vim.api.nvim_set_current_win(chat.timeline_win)
  vim.cmd('q')
  wait_chat_closed()
  vim.cmd('GcMailChat demo-city')
  local win = reopened_timeline()
  assert(win, 'reopened')
  wait('the anchor is back at the top', function()
    local ok, top = pcall(function()
      return view_of_win(win).top
    end)
    return ok and top == before.top
  end)
  vim.wait(100)
  local after = view_of_win(win)
  eq({ after.cursor, after.top }, { before.cursor, before.top }, 'the same message at the same view position')
  eq(lines_of(win)[after.top], top_text, 'the anchored heading')
  -- At the end now: closing the timeline window again must record the end,
  -- not keep the stale anchor.
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_feedkeys('G', 'x', false)
  wait('at the end', function()
    local v = view_of_win(win)
    return v.cursor == v.last and v.bottom == v.last
  end)
  vim.cmd('q')
  wait_chat_closed()
  vim.cmd('GcMailChat demo-city')
  local win2 = reopened_timeline()
  assert(win2, 'reopened again')
  wait('following the end', function()
    local ok, v = pcall(function()
      return view_of_win(win2)
    end)
    return ok and v.cursor == v.last and v.bottom == v.last
  end)
  vim.wait(100)
  local final = view_of_win(win2)
  eq({ final.cursor, final.bottom }, { final.last, final.last }, 'the end, not the stale anchor')
end)

test('chat reopen: restoring with scrolloff keeps the same top across reopenings', function()
  local chat = live_chat()
  short_timeline(chat)
  vim.wo[chat.timeline_win].scrolloff = 3
  vim.api.nvim_win_set_cursor(chat.timeline_win, { 14, 0 })
  vim.api.nvim_win_call(chat.timeline_win, function()
    vim.cmd('normal! zt')
  end)
  local before = timeline_view(chat)
  eq(before.top, 12, 'scrolloff keeps context above the cursor')
  -- The anchor is the message holding the top line: its heading.
  local anchor = before.top
  while anchor > 1 and lines_of(chat.timeline_win)[anchor]:match('^## ') == nil do
    anchor = anchor - 1
  end
  local heading = lines_of(chat.timeline_win)[anchor]
  assert(heading:match('^## ') ~= nil, 'an anchor heading')
  -- The open's load is slow, so the scrolloff is set before it answers.
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.delay', '1\n')
  vim.api.nvim_set_current_win(chat.timeline_win)
  vim.api.nvim_feedkeys('q', 'x', false)
  wait('closed', function()
    return not vim.api.nvim_win_is_valid(chat.timeline_win)
  end)
  vim.cmd('GcMailChat demo-city')
  local win = reopened_timeline()
  assert(win, 'reopened')
  vim.wo[win].scrolloff = 3
  wait('the anchor is back at the top', function()
    local ok, top = pcall(function()
      return view_of_win(win).top
    end)
    return ok and top == anchor
  end)
  vim.wait(100)
  local after = view_of_win(win)
  eq(after.top, anchor, 'the anchored heading back at the top')
  eq(lines_of(win)[after.top], heading, 'the anchored heading')
  -- Closing and reopening again stays on the same message: no drift.
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_feedkeys('q', 'x', false)
  wait('closed again', function()
    return not vim.api.nvim_win_is_valid(win)
  end)
  vim.cmd('GcMailChat demo-city')
  local win2 = reopened_timeline()
  assert(win2, 'reopened again')
  vim.wo[win2].scrolloff = 3
  wait('still at the anchor', function()
    local ok, top = pcall(function()
      return view_of_win(win2).top
    end)
    return ok and top == anchor
  end)
  vim.wait(100)
  eq(view_of_win(win2).top, anchor, 'no drift across reopenings')
end)

test('chat reopen: restoring with a huge scrolloff keeps the anchor at the top', function()
  local chat = live_chat()
  short_timeline(chat)
  vim.wo[chat.timeline_win].scrolloff = 999
  vim.api.nvim_win_set_cursor(chat.timeline_win, { 7, 0 })
  vim.api.nvim_win_call(chat.timeline_win, function()
    vim.cmd('normal! zt')
  end)
  local before = timeline_view(chat)
  -- The anchor is the message holding the top line: its heading.
  local anchor = before.top
  while anchor > 1 and lines_of(chat.timeline_win)[anchor]:match('^## ') == nil do
    anchor = anchor - 1
  end
  local heading = lines_of(chat.timeline_win)[anchor]
  assert(heading:match('^## ') ~= nil, 'an anchor heading')
  -- The open's load is slow, so the short height and scrolloff are set before
  -- it answers (Neovim clamps scrolloff=999 to half the 6-row height).
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.delay', '1\n')
  vim.api.nvim_set_current_win(chat.timeline_win)
  vim.api.nvim_feedkeys('q', 'x', false)
  wait('closed', function()
    return not vim.api.nvim_win_is_valid(chat.timeline_win)
  end)
  vim.cmd('GcMailChat demo-city')
  local win = reopened_timeline()
  assert(win, 'reopened')
  vim.api.nvim_win_set_height(win, 6)
  vim.api.nvim_exec_autocmds('WinResized', {})
  vim.wo[win].scrolloff = 999
  wait('the anchor is back at the top', function()
    local ok, top = pcall(function()
      return view_of_win(win).top
    end)
    return ok and top == anchor
  end)
  vim.wait(100)
  local after = view_of_win(win)
  eq(after.top, anchor, 'the anchored heading back at the top')
  eq(lines_of(win)[after.top], heading, 'the anchored heading')
  assert(after.bottom < after.last, 'the view is not at the end')
  -- Closing and reopening again stays on the same message: no drift to the end.
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_feedkeys('q', 'x', false)
  wait('closed again', function()
    return not vim.api.nvim_win_is_valid(win)
  end)
  vim.cmd('GcMailChat demo-city')
  local win2 = reopened_timeline()
  assert(win2, 'reopened again')
  vim.api.nvim_win_set_height(win2, 6)
  vim.api.nvim_exec_autocmds('WinResized', {})
  vim.wo[win2].scrolloff = 999
  wait('still at the anchor', function()
    local ok, top = pcall(function()
      return view_of_win(win2).top
    end)
    return ok and top == anchor
  end)
  vim.wait(100)
  eq(view_of_win(win2).top, anchor, 'no drift across reopenings')
end)

test('chat reopen: a scrolloff of half an even height keeps the last heading at the top', function()
  local chat = live_chat()
  short_timeline(chat)
  vim.wo[chat.timeline_win].scrolloff = 3
  -- The last heading at the top and the view ending on the buffer's last
  -- line, the cursor above it: not following.
  local all = lines_of(chat.timeline_win)
  local anchor = #all
  while anchor > 1 and all[anchor]:match('^## ') == nil do
    anchor = anchor - 1
  end
  local heading = all[anchor]
  assert(heading:match('^## ') ~= nil, 'an anchor heading')
  vim.api.nvim_win_call(chat.timeline_win, function()
    vim.fn.winrestview({ topline = anchor, lnum = anchor + 3, col = 0, coladd = 0 })
  end)
  local before = timeline_view(chat)
  eq({ before.top, before.cursor, before.bottom }, { anchor, anchor + 3, before.last }, 'the closed view')
  assert(before.cursor < before.last, 'not following')
  for round = 1, 2 do
    -- The open's load is slow, so the short height and scrolloff are set
    -- before it answers.
    write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.delay', '1\n')
    local closing = vim.api.nvim_get_current_win()
    if round == 1 then
      closing = chat.timeline_win
      vim.api.nvim_set_current_win(closing)
    end
    vim.api.nvim_feedkeys('q', 'x', false)
    wait('closed', function()
      return not vim.api.nvim_win_is_valid(closing)
    end)
    vim.cmd('GcMailChat demo-city')
    local win = reopened_timeline()
    assert(win, 'reopened')
    vim.api.nvim_win_set_height(win, 6)
    vim.api.nvim_exec_autocmds('WinResized', {})
    vim.wo[win].scrolloff = 3
    wait('the anchor is back at the top', function()
      local ok, v = pcall(view_of_win, win)
      return ok and v.top == anchor and v.cursor < v.last
    end)
    vim.wait(100)
    local after = view_of_win(win)
    eq(after.top, anchor, 'reopening ' .. round .. ' keeps the anchor at the top')
    eq(lines_of(win)[after.top], heading, 'the anchored heading')
    vim.api.nvim_set_current_win(win)
  end
end)

test('chat reopen: moving during a slow open load keeps the view instead of yanking back', function()
  local chat = live_chat()
  short_timeline(chat)
  vim.api.nvim_win_set_cursor(chat.timeline_win, { 7, 0 })
  vim.api.nvim_win_call(chat.timeline_win, function()
    vim.cmd('normal! zt')
  end)
  eq(timeline_view(chat).top, 7, 'the anchor in view')
  vim.api.nvim_set_current_win(chat.timeline_win)
  vim.api.nvim_feedkeys('q', 'x', false)
  wait('closed', function()
    return not vim.api.nvim_win_is_valid(chat.timeline_win)
  end)
  -- The open's load takes a second: move before it answers.
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.delay', '1\n')
  vim.cmd('GcMailChat demo-city')
  local win = reopened_timeline()
  assert(win, 'reopened')
  vim.api.nvim_win_set_height(win, 6)
  -- A headless run has no main loop to notice the new size: say it as Neovim does
  vim.api.nvim_exec_autocmds('WinResized', {})
  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd('normal! zt')
  end)
  wait('the open load answered', function()
    return bd_list_calls(chat.cities[1].path) == 2
  end)
  vim.wait(1500)
  local after = view_of_win(win)
  eq({ after.cursor, after.top }, { 3, 3 }, 'stayed where the user moved, not yanked to the anchor')
end)

test('chat reopen: a failed open load drops the anchor, so the next load stays at the end', function()
  local chat = live_chat()
  short_timeline(chat)
  vim.api.nvim_win_set_cursor(chat.timeline_win, { 7, 0 })
  vim.api.nvim_win_call(chat.timeline_win, function()
    vim.cmd('normal! zt')
  end)
  eq(timeline_view(chat).top, 7, 'the anchor in view')
  vim.api.nvim_set_current_win(chat.timeline_win)
  vim.api.nvim_feedkeys('q', 'x', false)
  wait('closed', function()
    return not vim.api.nvim_win_is_valid(chat.timeline_win)
  end)
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.exit', '1\n')
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.stderr', 'store unavailable\n')
  vim.cmd('GcMailChat demo-city')
  local win = reopened_timeline()
  assert(win, 'reopened')
  wait('the open load failed', function()
    return (vim.wo[win].statusline:find('stale', 1, true) ~= nil)
  end)
  local failed_view = view_of_win(win)
  eq({ failed_view.cursor, failed_view.bottom }, { failed_view.last, failed_view.last }, 'at the end meanwhile')
  -- The next successful load (a manual reload) must not yank back.
  vim.fn.delete(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.exit')
  vim.fn.delete(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.stderr')
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_feedkeys('R', 'x', false)
  wait('reloaded', function()
    return (vim.wo[win].statusline:find('live', 1, true) ~= nil)
  end)
  vim.wait(100)
  local after = view_of_win(win)
  eq({ after.cursor, after.bottom }, { after.last, after.last }, 'still at the end, not yanked to the anchor')
end)

test('chat reopen: mail that arrived while closed counts as newer below the restored view', function()
  local chat = live_chat()
  short_timeline(chat)
  vim.api.nvim_win_set_cursor(chat.timeline_win, { 7, 0 })
  vim.api.nvim_win_call(chat.timeline_win, function()
    vim.cmd('normal! zt')
  end)
  local before = timeline_view(chat)
  eq({ before.cursor, before.top }, { 7, 7 }, 'the middle message at the top')
  vim.api.nvim_set_current_win(chat.timeline_win)
  vim.api.nvim_feedkeys('q', 'x', false)
  wait('closed', function()
    return not vim.api.nvim_win_is_valid(chat.timeline_win)
  end)
  local list = vim.json.decode(chat.fix)
  list[#list + 1] = { id = 'tc-wisp-new1', title = 'new arrival', sender = 'mayor', assignee = 'human',
    status = 'open', description = 'new arrival\nfresh body', created_at = os.date('!%Y-%m-%dT%H:%M:%SZ'), labels = {} }
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', vim.json.encode(list))
  -- The open's load is slow, so the short height is set before it answers.
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.delay', '1\n')
  vim.cmd('GcMailChat demo-city')
  local win = reopened_timeline()
  assert(win, 'reopened')
  vim.api.nvim_win_set_height(win, 6)
  -- A headless run has no main loop to notice the new size: say it as Neovim does
  vim.api.nvim_exec_autocmds('WinResized', {})
  wait('the anchor is back at the top', function()
    local ok, top = pcall(function()
      return view_of_win(win).top
    end)
    return ok and top == before.top
  end)
  vim.wait(100)
  eq(view_of_win(win).top, before.top, 'the same message at the top')
  eq(newer_below({ timeline_win = win }), 1, 'the arrival waits below')
end)

test('chat live: your own mail.sent hides its sending record without a load', function()
  local chat = live_chat()
  local path = chat.cities[1].path
  vim.env.FAKE_GC_DELAY = '2'
  local compose_buf = vim.api.nvim_win_get_buf(chat.compose_win)
  vim.api.nvim_buf_set_lines(compose_buf, 0, -1, false, { 'my question', 'more of it' })
  vim.api.nvim_set_current_win(chat.compose_win)
  vim.api.nvim_feedkeys(vim.keycode('<Space>ms'), 'x', false)
  wait('sending… shows', function()
    return shown(chat):find('## you · sending…', 1, true) ~= nil
  end)
  append(chat.log, message_line('mail.sent', { id = 'tc-wisp-mine', from = 'human', to = 'mayor', read = false,
    subject = 'my question', body = 'my question\nmore of it' }))
  wait('the logged message replaces the record', function()
    local text = shown(chat)
    return text:find('sending…', 1, true) == nil and select(2, text:gsub('more of it', '')) == 1
  end, 1500)
  eq(bd_list_calls(path), 1, 'no load before the send ends')
  wait('the send ends', drained, 5000)
end)

test('chat live: the fallback loads the city again every poll period with no event', function()
  require('gc_mail.chat').configure({ poll_ms = 100 })
  local chat = live_chat()
  wait('the fallback loaded again', function()
    return bd_list_calls(chat.cities[1].path) >= 3
  end, 2000)
end)

test('chat live: after q nothing runs and the watcher stops; an open panel keeps its own subscription', function()
  local events = require('gc_mail.events')
  require('gc_mail.chat').configure({ poll_ms = 100 })
  local chat = live_chat()
  local path = chat.cities[1].path
  eq(events.running(), true, 'the chat subscribed')
  vim.api.nvim_set_current_win(chat.timeline_win)
  vim.api.nvim_feedkeys('q', 'x', false)
  eq(vim.api.nvim_win_is_valid(chat.timeline_win), false, 'closed')
  eq(events.running(), false, 'no subscriber left')
  local calls = #mail_calls()
  append(chat.log, message_line('mail.replied', { id = 'tc-wisp-late', subject = 'late', body = 'late' })
    .. id_line('mail.sent', 'tc-wisp-late2') .. id_line('mail.marked_read', 'tc-wisp-m2'))
  vim.wait(500)
  eq(#mail_calls(), calls, 'no call after close, from the events or the fallback')
  eq(require('gc_mail.history').cache[path].by_id['tc-wisp-late'], nil, 'and nothing cached')

  -- The panel's subscription outlives the chat's.
  inbox('demo-city', {})
  inbox('other city', {})
  panel().open()
  listed(chat.cities)
  vim.cmd('GcMailChat demo-city')
  wait('the chat loaded', function()
    return bd_list_calls(path) >= 2
  end)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):match('/chat/') then
      vim.api.nvim_set_current_win(w)
    end
  end
  vim.api.nvim_feedkeys('q', 'x', false)
  eq(events.running(), true, 'the panel still watches')
  local inboxes = inbox_calls(path)
  local loads = bd_list_calls(path)
  append(chat.log, id_line('mail.sent', 'tc-wisp-late3'))
  wait('the panel lists the city', function()
    return inbox_calls(path) == inboxes + 1
  end)
  vim.wait(300)
  eq(bd_list_calls(path), loads, 'the closed chat loads nothing')
end)

test('chat live: a failing load is said once over every fallback tick and shown, never as an empty conversation', function()
  require('gc_mail.history').reset()
  require('gc_mail.chat').configure({ poll_ms = 100 })
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.exit', '1\n')
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.stderr', 'store unavailable\n')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_mark_read = false, watch = false })
  local cities, log = city_dirs()
  write(log, '')
  vim.cmd('GcMailChat demo-city')
  wait('three failed loads', function()
    return bd_list_calls(cities[1].path) >= 3
  end, 2000)
  local errors = vim.tbl_filter(function(note)
    return note.level == vim.log.levels.ERROR
  end, notes)
  eq(#errors, 1, 'said once')
  eq(errors[1].message:find('store unavailable', 1, true) ~= nil, true, errors[1].message)
  local timeline
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):match('/chat/') then
      timeline = w
    end
  end
  eq(lines_of(timeline)[1]:find('^cannot load the history: ') ~= nil, true, lines_of(timeline)[1])
end)

-- The fixture's list with `change(list)` applied, as the next bd list answer.
local function relist(chat, change)
  local list = vim.json.decode(chat.fix)
  change(list)
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', vim.json.encode(list))
end

test('chat live: a load that began before an event never takes back what the event showed', function()
  local chat = live_chat()
  local path = chat.cities[1].path
  local m2 = '## mayor · ' .. os.date('%H:%M', chat.t1)
  local m3 = '## mayor · ' .. os.date('%H:%M', chat.t2)
  -- The answer is read before the events are logged and given a second later
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.delay', '1\n')
  vim.api.nvim_set_current_win(chat.timeline_win)
  vim.api.nvim_feedkeys('R', 'x', false)
  wait('the slow load started', function()
    return bd_list_calls(path) == 2
  end)
  vim.wait(200)
  append(chat.log, message_line('mail.replied', { id = 'tc-wisp-live1', subject = 'live answer',
    body = 'live answer\nduring the load' }) .. id_line('mail.marked_read', 'tc-wisp-m2')
    .. id_line('mail.archived', 'tc-wisp-m3'))
  local function current()
    local text = shown(chat)
    return text:find('during the load', 1, true) ~= nil and lines_of(chat.timeline_win)[7] == m2
      and text:find(m3 .. ' (closed)', 1, true) ~= nil
  end
  wait('the events show', current, 1000)
  vim.wait(1500)
  eq(bd_list_calls(path), 2, 'the slow load ended with no other load')
  eq(current(), true, 'the answer, the read message and the closed one stay after the load ends: '
    .. table.concat(lines_of(chat.timeline_win), '|'))

  -- A load that began after the events lists them: no duplicate
  vim.fn.delete(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.delay')
  relist(chat, function(list)
    list[2].labels[#list[2].labels + 1] = 'read'
    list[3].status = 'closed'
    list[#list + 1] = { id = 'tc-wisp-live1', title = 'live answer', sender = 'mayor', assignee = 'human',
      status = 'open', description = 'live answer\nduring the load', created_at = os.date('!%Y-%m-%dT%H:%M:%SZ'),
      labels = {} }
  end)
  vim.api.nvim_feedkeys('R', 'x', false)
  wait('the next load', function()
    return bd_list_calls(path) == 3
  end)
  vim.wait(300)
  eq(select(2, shown(chat):gsub('during the load', '')), 1, 'the answer shows once')
  eq(current(), true, 'as gc lists it')

  -- After that, gc's list decides again
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', chat.fix)
  vim.api.nvim_feedkeys('R', 'x', false)
  wait('a later load takes gc\'s flags', function()
    return lines_of(chat.timeline_win)[7] == m2 .. ' ●'
  end)
end)

-- A new message an event brought in while a slow load is in flight, then the
-- events that changed it: the heading shows the same dot and closed mark while
-- the load runs and after it ends, with no other load. The chat keeps the
-- event's own table for it; a copy would lose what the later events changed.
for _, case in ipairs({
  { 'no later event', '', ' ●' },
  { 'mark-read', id_line('mail.marked_read', 'tc-wisp-live1'), '' },
  { 'read', id_line('mail.read', 'tc-wisp-live1'), '' },
  { 'archived', id_line('mail.archived', 'tc-wisp-live1'), ' (closed) ●' },
  { 'read and deleted', id_line('mail.read', 'tc-wisp-live1') .. id_line('mail.deleted', 'tc-wisp-live1'), ' (closed)' },
}) do
  local name, later, suffix = case[1], case[2], case[3]
  test('chat live: a new message then ' .. name .. ' during a slow load keeps its dot and closed mark', function()
    local chat = live_chat()
    local path = chat.cities[1].path
    local when = os.time()
    local heading = '## mayor · ' .. os.date('%H:%M', when) .. suffix
    local function live_heading()
      local lines = lines_of(chat.timeline_win)
      for i, l in ipairs(lines) do
        if l == 'live body' then
          return lines[i - 4]
        end
      end
    end
    write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.delay', '1\n')
    vim.api.nvim_set_current_win(chat.timeline_win)
    vim.api.nvim_feedkeys('R', 'x', false)
    wait('the slow load started', function()
      return bd_list_calls(path) == 2
    end)
    vim.wait(200)
    append(chat.log, message_line('mail.replied', { id = 'tc-wisp-live1', subject = 'live',
      body = 'live body', created_at = os.date('!%Y-%m-%dT%H:%M:%SZ', when) }) .. later)
    wait('the events show while the load runs', function()
      return live_heading() == heading
    end, 1000)
    eq(bd_list_calls(path), 2, 'the load is still the only one')
    vim.wait(1500)
    eq(bd_list_calls(path), 2, 'the slow load ended with no other load')
    eq(live_heading(), heading, 'the same heading after the load ends: ' .. table.concat(lines_of(chat.timeline_win), '|'))
  end)
end

test('chat live: a read event moves the dot of a message the chat marked read itself', function()
  acted('mark-read', 'tc-wisp-m2')
  local chat = live_chat({ chat_mark_read = true })
  local heading = '## mayor · ' .. os.date('%H:%M', chat.t1)
  wait('the chat marked it read', function()
    return read_calls('tc-wisp-m2') == 1 and lines_of(chat.timeline_win)[7] == heading
  end)
  vim.cmd('wincmd h')
  append(chat.log, id_line('mail.marked_unread', 'tc-wisp-m2'))
  wait('marked_unread brings the dot back', function()
    return lines_of(chat.timeline_win)[7] == heading .. ' ●'
  end, 1000)
  append(chat.log, id_line('mail.marked_read', 'tc-wisp-m2'))
  wait('marked_read removes it', function()
    return lines_of(chat.timeline_win)[7] == heading
  end, 1000)
  eq(read_calls('tc-wisp-m2'), 1, 'the chat marked nothing again')
end)

test('chat live: a mail.read event clears the dot a refused mark-read kept', function()
  write(vim.env.FAKE_GC_MAIL .. '/mark-read.exit', '1\n')
  write(vim.env.FAKE_GC_MAIL .. '/mark-read.stderr', 'fake mark-read error\n')
  local chat = live_chat({ chat_mark_read = true })
  local heading = '## mayor · ' .. os.date('%H:%M', chat.t1)
  wait('the mark-read was refused', function()
    return read_calls('tc-wisp-m2') == 1 and lines_of(chat.timeline_win)[7] == heading .. ' ●'
  end)
  vim.cmd('wincmd h')
  append(chat.log, id_line('mail.read', 'tc-wisp-m2'))
  wait('mail.read removes the dot', function()
    return lines_of(chat.timeline_win)[7] == heading
  end, 1000)
end)

test('chat live: a failed load after a delivered send is said as an error', function()
  local chat = live_chat()
  local path = chat.cities[1].path
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.exit', '1\n')
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.stderr', 'store unavailable\n')
  vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(chat.compose_win), 0, -1, false, { 'my question' })
  vim.api.nvim_set_current_win(chat.compose_win)
  vim.api.nvim_feedkeys(vim.keycode('<Space>ms'), 'x', false)
  wait('the send ends', drained, 5000)
  wait('the load after it failed', function()
    return bd_list_calls(path) == 2
  end)
  local function errors()
    return vim.tbl_filter(function(note)
      return note.level == vim.log.levels.ERROR and note.message:find('store unavailable', 1, true) ~= nil
    end, notes)
  end
  wait('the failure is said', function()
    return #errors() == 1
  end)
  eq(shown(chat):find('all good', 1, true) ~= nil, true, 'the timeline keeps what it showed')
end)

-- ---- the chat's statuslines -----------------------------------------------------

test('chat status: correspondent, city, liveness and unread count; a narrow window cuts from the end; the keys stay below', function()
  local chat = live_chat()
  local status = function()
    return vim.wo[chat.timeline_win].statusline
  end
  eq(status(), ' mayor in demo-city · live · 1 unread ', 'idle, one unread')
  eq(vim.wo[chat.compose_win].statusline, ' <Space>ms send · q close · <C-j>/<C-k> focus · above: <CR…',
    'the keys, cut at the chat width')
  append(chat.log, message_line('mail.replied', { id = 'tc-wisp-live1', subject = 'later', body = 'later' }))
  wait('the arrival counts', function()
    return status() == ' mayor in demo-city · live · 2 unread '
  end, 1000)

  -- A new width cuts again; neither the timeline nor a cursor moves
  local tick = vim.api.nvim_buf_get_changedtick(vim.api.nvim_win_get_buf(chat.timeline_win))
  local cursors = { vim.api.nvim_win_get_cursor(chat.timeline_win), vim.api.nvim_win_get_cursor(chat.compose_win) }
  -- A headless run has no main loop to notice the new size: say it as Neovim does
  vim.api.nvim_win_set_width(chat.timeline_win, 24)
  vim.api.nvim_exec_autocmds('WinResized', {})
  wait('cut to 24 columns', function()
    return status() == ' mayor in demo-city · l…'
  end, 1000)
  eq(vim.api.nvim_buf_get_changedtick(vim.api.nvim_win_get_buf(chat.timeline_win)), tick, 'the timeline was not rendered')
  eq({ vim.api.nvim_win_get_cursor(chat.timeline_win), vim.api.nvim_win_get_cursor(chat.compose_win) }, cursors,
    'no cursor moved')
  vim.api.nvim_win_set_width(chat.timeline_win, 12)
  vim.api.nvim_exec_autocmds('WinResized', {})
  wait('the correspondent stays first', function()
    return status() == ' mayor in d…'
  end, 1000)

  -- A % in the correspondent shows as itself
  local other = require('gc_mail.chat').open('demo-city', '50%off')
  eq(vim.wo[other.timeline_win].statusline, ' 50%%off in demo-city · live ', 'escaped for the statusline')
end)

test('chat status: a send shows sending…, then queued while it retries, then failed', function()
  vim.env.FAKE_GC_FAIL_TIMES = '1'
  vim.env.FAKE_GC_DELAY = '0.5'
  local chat = live_chat({ retry_ms = { 5000, 5000 } })
  local status = function()
    return vim.wo[chat.timeline_win].statusline
  end
  local compose_buf = vim.api.nvim_win_get_buf(chat.compose_win)
  vim.api.nvim_buf_set_lines(compose_buf, 0, -1, false, { 'will retry' })
  vim.api.nvim_set_current_win(chat.compose_win)
  vim.api.nvim_feedkeys(vim.keycode('<Space>ms'), 'x', false)
  wait('sending', function()
    return status() == ' mayor in demo-city · sending… · live · 1 unread '
  end)
  wait('queued for a retry', function()
    return status() == ' mayor in demo-city · queued · live · 1 unread '
  end)

  vim.env.FAKE_GC_FAIL_TIMES = '99'
  vim.env.FAKE_GC_DELAY = nil
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = { 20 }, chat_mark_read = false, watch = false })
  vim.api.nvim_buf_set_lines(compose_buf, 0, -1, false, { 'will fail' })
  vim.api.nvim_feedkeys(vim.keycode('<Space>ms'), 'x', false)
  -- The send's state outranks liveness and the counts: a long error cuts them
  wait('failed', function()
    return status():find('^ mayor in demo%-city · failed: ') ~= nil
  end)
  eq(status(), ' mayor in demo-city · failed: exit 1: gc mail send: store …', 'the first error line')
end)

test('chat status: a failed load shows stale until a load succeeds', function()
  require('gc_mail.chat').configure({ poll_ms = 100 })
  local chat = live_chat()
  local status = function()
    return vim.wo[chat.timeline_win].statusline
  end
  eq(status(), ' mayor in demo-city · live · 1 unread ', 'live')
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.exit', '1\n')
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.stderr', 'store unavailable\n')
  wait('stale', function()
    return status() == ' mayor in demo-city · stale · 1 unread '
  end, 2000)
  os.remove(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.exit')
  os.remove(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.stderr')
  wait('live again', function()
    return status() == ' mayor in demo-city · live · 1 unread '
  end, 2000)
end)

test('chat status: a city with no event log is polling, live once its log is watched, polling when it goes', function()
  -- No fallback load comes within the test: the watcher's own notice moves the word
  require('gc_mail.chat').configure({ poll_ms = 600000 })
  require('gc_mail.events').configure({ rearm_ms = 600000 })
  local chat = live_chat(nil, true)
  local path = chat.cities[1].path
  local status = function()
    return vim.wo[chat.timeline_win].statusline
  end
  eq(status(), ' mayor in demo-city · polling · 1 unread ', 'no event log to watch')
  local calls = #mail_calls()
  write(chat.log, '')
  require('gc_mail.events').rearm()
  wait('live once the log is armed', function()
    return status() == ' mayor in demo-city · live · 1 unread '
  end, 1000)
  os.remove(chat.log)
  wait('polling once the log is gone', function()
    return status() == ' mayor in demo-city · polling · 1 unread '
  end, 1000)
  vim.wait(100)
  eq(bd_list_calls(path), 1, 'no history load moved it')
  eq(#mail_calls(), calls, 'no gc call either')
end)

test('chat status: an unreadable queue file shows in the timeline but is no send of the chat', function()
  local chat = live_chat()
  local status = function()
    return vim.wo[chat.timeline_win].statusline
  end
  vim.fn.mkdir(queue_dir, 'p')
  write(queue_dir .. '/9999999999999999-00001-00000099.json', '{"version": 1, ')
  vim.api.nvim_set_current_win(chat.timeline_win)
  vim.api.nvim_feedkeys('R', 'x', false)
  wait('the unreadable file shows', function()
    return shown(chat):find('## you · failed: not a gc-mail message: not JSON', 1, true) ~= nil
  end)
  eq(status(), ' mayor in demo-city · live · 1 unread ', 'no send state')

  -- A failed send of the chat is its last send, though the unreadable file sorts after it
  vim.env.FAKE_GC_FAIL_TIMES = '99'
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = { 20 }, chat_mark_read = false, watch = false })
  local compose_buf = vim.api.nvim_win_get_buf(chat.compose_win)
  vim.api.nvim_buf_set_lines(compose_buf, 0, -1, false, { 'will fail' })
  vim.api.nvim_set_current_win(chat.compose_win)
  vim.api.nvim_feedkeys(vim.keycode('<Space>ms'), 'x', false)
  wait('failed', function()
    return status() == ' mayor in demo-city · failed: exit 1: gc mail send: store …'
  end)
end)

test('chat is_current: only the current chat of that city and correspondent in this tab page; the watch keeps quiet only then', function()
  local cities, log = watched({ chat_mark_read = false })
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', (conversation_fixture()))
  seeded(3)
  local chat = require('gc_mail.chat')
  local origin = vim.api.nvim_get_current_win()
  vim.cmd('GcMailChat demo-city')
  local function notices()
    return #vim.tbl_filter(function(note)
      return note.level == vim.log.levels.INFO
    end, notes)
  end
  eq(chat.is_current(cities[1], 'mayor'), true, 'the compose window is current')
  eq(chat.is_current(cities[1], 'planner'), false, 'another correspondent')
  eq(chat.is_current(cities[2], 'mayor'), false, 'another city')
  append(log, mail_line('mail.sent', 'ic-wisp-a1', { from = 'mayor', subject = 'in the chat' }))
  seeded(4)
  eq(notices(), 0, 'the chat shows it')
  append(log, mail_line('mail.sent', 'ic-wisp-b2', { from = 'planner' }))
  seeded(5)
  eq(notices(), 1, 'another correspondent is said')

  vim.cmd('tabnew')
  eq(chat.is_current(cities[1], 'mayor'), false, 'the chat of another tab page')
  append(log, mail_line('mail.sent', 'ic-wisp-c3', { from = 'mayor' }))
  seeded(6)
  eq(notices(), 2, 'said from another tab page')
  vim.cmd('tabclose')

  vim.api.nvim_set_current_win(origin)
  eq(chat.is_current(cities[1], 'mayor'), false, 'a window beside the chat')
  local timeline
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):match('/chat/') then
      timeline = w
    end
  end
  vim.api.nvim_set_current_win(timeline)
  eq(chat.is_current(cities[1], 'mayor'), true, 'the timeline is current')
  vim.api.nvim_feedkeys('q', 'x', false)
  eq(chat.is_current(cities[1], 'mayor'), false, 'after close')
  append(log, mail_line('mail.sent', 'ic-wisp-d4', { from = 'mayor' }))
  seeded(7)
  eq(notices(), 3, 'said after close')
end)

test('setup({ chat_poll_ms = 1000 }) raises; 15000 is taken', function()
  local ok, err = pcall(gc_mail.setup, { chat_poll_ms = 1000 })
  eq(ok, false, 'refused')
  eq(tostring(err):find('chat_poll_ms must be a number of milliseconds of at least 15000', 1, true) ~= nil, true, err)
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, chat_poll_ms = 15000, watch = false })
  eq(gc_mail.config.chat_poll_ms, 15000, 'taken')
end)

-- ---- the conversations list ---------------------------------------------------

-- A bd list record of a mail message, `ago` seconds old.
local function bd_mail(id, sender, assignee, title, ago, read)
  return { id = id, title = title, sender = sender, assignee = assignee, status = 'open', description = title .. '\nbody',
    created_at = os.date('!%Y-%m-%dT%H:%M:%SZ', os.time() - ago), labels = read and { 'read' } or {}, issue_type = 'message' }
end

-- demo-city: a conversation with the mayor of three messages, two unread, and
-- one with the planner; other-city has no mail at all.
local function chats_fixture()
  local cities = city_dirs()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', vim.json.encode({
    bd_mail('ic-wisp-c1', 'human', 'mayor', 'Deploy question', 3 * 3600, true),
    bd_mail('ic-wisp-c2', 'mayor', 'human', 'Re: Deploy question', 2 * 3600, false),
    bd_mail('ic-wisp-c3', 'mayor', 'human', 'Plan update', 1800, false),
    bd_mail('ic-wisp-c4', 'human', 'planner', 'Plan check', 5 * 3600, true),
  }))
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.other city.json', '[]')
  return cities
end

local CHAT_LINES = {
  '  2  demo-city  mayor  Plan update  30m ',
  '     demo-city  planner  Plan check  5h ',
  '     other-city  mayor  no messages yet ',
}

local function chat_timeline_names()
  local names = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
    if name:match('/chat/') then
      names[#names + 1] = name:match('gc%-mail://(.*)$')
    end
  end
  return names
end

test(':GcMailChats opens at once with loading…, then lists every conversation newest first, one bd list per city', function()
  local cities = chats_fixture()
  vim.env.FAKE_GC_DELAY = nil
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.delay', '0.4\n')
  vim.cmd('GcMailChats')
  local win = vim.api.nvim_get_current_win()
  eq(#floats(), 1, 'the float is open')
  eq(vim.api.nvim_win_get_config(win).title[1][1], ' gc mail chats: <CR> open  q close ', 'its title')
  eq(lines_of(win), { ' loading… ' }, 'loading… until the first answer')
  wait('the lists arrive', function()
    return #lines_of(win) == 3
  end)
  eq(lines_of(win), CHAT_LINES, 'one line per conversation, newest last message first')
  vim.wait(300)
  eq({ bd_list_calls(cities[1].path), bd_list_calls(cities[2].path) }, { 1, 1 }, 'one bd list call per city')
  eq(#mail_calls(), 2, 'and nothing else')

  -- Opened again with the cache: the lines at once, one more load per city
  vim.api.nvim_feedkeys('q', 'x', false)
  eq(#floats(), 0, 'q closes')
  vim.cmd('GcMailChats')
  eq(lines_of(vim.api.nvim_get_current_win()), CHAT_LINES, 'from the cache at once')
  vim.wait(800)
  eq({ bd_list_calls(cities[1].path), bd_list_calls(cities[2].path) }, { 2, 2 }, 'each city loaded once more')
  vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'x', false)
  eq(#floats(), 0, '<Esc> closes')
end)

test('<CR> in the conversations list closes it and opens the chat of that line', function()
  chats_fixture()
  vim.cmd('GcMailChats')
  local win = vim.api.nvim_get_current_win()
  wait('the lists arrive', function()
    return #lines_of(win) == 3
  end)
  vim.api.nvim_win_set_cursor(win, { 2, 0 })
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  eq(#floats(), 0, 'the float is closed')
  eq(chat_timeline_names(), { 'demo-city/chat/planner' }, 'the chat of the planner in demo-city')
  vim.cmd('only')
  vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'x', false)

  -- The empty city's mayor line starts a first chat
  vim.cmd('GcMailChats')
  win = vim.api.nvim_get_current_win()
  wait('the lists arrive', function()
    return #lines_of(win) == 3
  end)
  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  eq(vim.tbl_contains(chat_timeline_names(), 'other-city/chat/mayor'), true, 'the first chat with other-city mayor')
end)

test('a failed load for one city is said once and the other city still lists', function()
  local cities = chats_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.other city.exit', '1\n')
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.other city.stderr', 'store unavailable\n')
  vim.cmd('GcMailChats')
  local win = vim.api.nvim_get_current_win()
  wait('both answered', function()
    return bd_list_calls(cities[1].path) == 1 and bd_list_calls(cities[2].path) == 1 and #lines_of(win) == 3
  end)
  vim.wait(300)
  eq(lines_of(win), { CHAT_LINES[1], CHAT_LINES[2], '     other-city  cannot load the history ' },
    'demo-city lists, other-city says it could not load')
  local errors = vim.tbl_filter(function(note)
    return note.level == vim.log.levels.ERROR
  end, notes)
  eq(#errors, 1, 'said once')
  eq(errors[1].message:find('store unavailable', 1, true) ~= nil, true, errors[1].message)
  eq(bd_list_calls(cities[2].path), 1, 'and not retried')
  vim.api.nvim_feedkeys('q', 'x', false)
end)

test('c in the mailbox float opens the chat with the sender in its city and closes the float', function()
  chats_fixture()
  inbox('demo-city', { msg('ic-wisp-a1', { from = 'planner', subject = 'from the planner' }) })
  inbox('other city', {})
  local win = mailbox().open()
  settled(win, 1)
  vim.api.nvim_feedkeys('c', 'x', false)
  eq(#floats(), 0, 'the float is closed')
  eq(chat_timeline_names(), { 'demo-city/chat/planner' }, 'the chat with the sender, in the message city')
  -- A message from human opens the chat with its recipient
  vim.cmd('only')
  local entry = { city = { name = 'demo-city', path = '/srv/demo-city' }, message = msg('ic-wisp-a9', { from = 'human', to = 'builder' }) }
  mailbox().actions.chat(entry)
  eq(vim.tbl_contains(chat_timeline_names(), 'demo-city/chat/builder'), true, 'a message from human: its recipient')
end)

test('preview: closing the mailbox over an open chat removes the pane and keeps the chat', function()
  chats_fixture()
  inbox('demo-city', { msg('ic-wisp-a1', { subject = 'only subject', body = 'only body' }) })
  inbox('other city', {})
  gc_mail.config.preview = true
  gc_mail.config.chat_mark_read = false
  local chat = require('gc_mail.chat').open('demo-city', 'mayor')
  assert(chat, 'the chat opened')
  local chat_win, chat_buf = chat.compose_win, chat.compose_buf
  local chat_cursor = vim.api.nvim_win_get_cursor(chat_win)
  local win = mailbox().open()
  settled(win, 1)
  pane_shows({ 'only body' }, 'the preview over the chat')
  vim.api.nvim_feedkeys('q', 'x', false)
  eq(preview_win(), nil, 'no preview window remains')
  eq(#floats(), 0, 'no float remains')
  local groups = {}
  for _, au in ipairs(vim.api.nvim_get_autocmds({})) do
    if au.group_name and au.group_name:find('^gc_mail_preview') then
      groups[#groups + 1] = au.group_name
    end
  end
  eq(groups, {}, 'no preview autocmd group remains')
  eq(vim.api.nvim_win_is_valid(chat_win), true, 'the chat window is still valid')
  eq(vim.api.nvim_win_get_buf(chat_win), chat_buf, 'with its buffer')
  eq(vim.api.nvim_win_get_cursor(chat_win), chat_cursor, 'and its cursor')
  eq(vim.api.nvim_win_is_valid(chat.timeline_win), true, 'the timeline stays too')
  -- Leaving the mailbox for the chat closes the list from its own WinLeave,
  -- which never fires WinClosed: the pane must go with it all the same.
  win = mailbox().open()
  settled(win, 1)
  pane_shows({ 'only body' }, 'the preview again')
  vim.api.nvim_set_current_win(chat_win)
  eq(preview_win(), nil, 'no preview window remains after leaving it')
  eq(#floats(), 0, 'no float remains after leaving it')
  groups = {}
  for _, au in ipairs(vim.api.nvim_get_autocmds({})) do
    if au.group_name and au.group_name:find('^gc_mail_preview') then
      groups[#groups + 1] = au.group_name
    end
  end
  eq(groups, {}, 'no preview autocmd group remains after leaving it')
  eq(vim.api.nvim_win_is_valid(chat_win), true, 'the chat window is still valid')
  eq(vim.api.nvim_win_get_buf(chat_win), chat_buf, 'with its buffer')
end)

test('c in the panel opens the chat beside its origin window and the panel stays', function()
  local cities = chats_fixture()
  inbox('demo-city', { msg('ic-wisp-a1', { subject = 'first' }) })
  inbox('other city', {})
  buffer({ 'one', 'two' })
  local origin = vim.api.nvim_get_current_win()
  local win = panel().open()
  listed(cities)
  settled(win, 1)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_feedkeys('c', 'x', false)
  eq(chat_timeline_names(), { 'demo-city/chat/mayor' }, 'the chat with the sender')
  eq(vim.api.nvim_win_is_valid(win), true, 'the panel stays')
  local timeline
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):match('/chat/') then
      timeline = w
    end
  end
  eq(vim.api.nvim_win_get_position(timeline)[1], vim.api.nvim_win_get_position(origin)[1], 'level with the origin window')
  eq(vim.api.nvim_win_get_position(timeline)[2] > vim.api.nvim_win_get_position(origin)[2], true, 'to its right')
  eq(vim.api.nvim_win_get_buf(win) ~= vim.api.nvim_win_get_buf(timeline), true, 'never inside the panel')
  eq(vim.api.nvim_win_get_height(win), 10, 'the panel keeps its rows')
end)

test('c in the message view opens the chat and keeps the view', function()
  chats_fixture()
  inbox('demo-city', { msg('ic-wisp-a1', { subject = 'first' }) })
  inbox('other city', {})
  acted('read', 'ic-wisp-a1')
  local win = mailbox().open()
  settled(win, 1)
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  local view_win = vim.api.nvim_get_current_win()
  local view_buf = vim.api.nvim_win_get_buf(view_win)
  eq(vim.api.nvim_buf_get_name(view_buf):match('gc%-mail://demo%-city/ic%-wisp%-a1') ~= nil, true, 'the message view')
  vim.api.nvim_feedkeys('c', 'x', false)
  eq(chat_timeline_names(), { 'demo-city/chat/mayor' }, 'the chat opened')
  eq(vim.api.nvim_win_is_valid(view_win) and vim.api.nvim_win_get_buf(view_win) == view_buf, true, 'the view stays')
end)

test('every mapping the conversations list and the c key add carries a gc-mail: desc', function()
  chats_fixture()
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, watch = false })
  local function desc_of(maps, lhs)
    for _, map in ipairs(maps) do
      if map.lhs == lhs then
        return map.desc
      end
    end
  end
  local function every_desc(buf, lhs_list)
    local maps = vim.api.nvim_buf_get_keymap(buf, 'n')
    for _, lhs in ipairs(lhs_list) do
      local desc = desc_of(maps, lhs)
      eq(type(desc) == 'string' and desc:sub(1, 9) == 'gc-mail: ', true, ('mapping %s has a gc-mail: desc, got %s'):format(lhs, tostring(desc)))
    end
  end
  eq((vim.fn.maparg('<Space>ml', 'n', false, true).desc or ''):sub(1, 9), 'gc-mail: ', 'the <Space>ml mapping')
  vim.cmd('GcMailChats')
  every_desc(vim.api.nvim_get_current_buf(), { '<CR>', 'q', '<Esc>' })
  vim.api.nvim_feedkeys('q', 'x', false)
  inbox('demo-city', { msg('ic-wisp-a1', { subject = 'first' }) })
  inbox('other city', {})
  local win = mailbox().open()
  settled(win, 1)
  every_desc(vim.api.nvim_win_get_buf(win), { '<CR>', 'r', 't', 'c', 'm', 'u', 'a', 'd', 'p', 'R', 'q' })
  vim.api.nvim_feedkeys('q', 'x', false)
  local pwin = panel().open()
  settled(pwin, 1)
  every_desc(vim.api.nvim_win_get_buf(pwin), { '<CR>', 'r', 't', 'c', 'm', 'u', 'a', 'd', 'p', 'R', 'q' })
end)

test('setup({ chats_keymap = false }) maps nothing, a bad value is refused, and the command is there', function()
  eq(vim.fn.exists(':GcMailChats'), 2, ':GcMailChats exists before setup')
  gc_mail.setup({ state_dir = vim.fs.dirname(queue_dir), retry_ms = RETRY, watch = false })
  eq(vim.fn.maparg('<Space>ml', 'n') ~= '', true, 'the default mapping')
  vim.keymap.del('n', '<Space>ml')
  gc_mail.setup({ chats_keymap = false, state_dir = vim.fs.dirname(queue_dir), watch = false })
  eq(vim.fn.maparg('<Space>ml', 'n'), '', 'chats_keymap = false maps nothing')
  eq(vim.fn.exists(':GcMailChats'), 2, ':GcMailChats still works')
  local ok, err = pcall(gc_mail.setup, { chats_keymap = '' })
  eq(ok, false, 'an empty chats_keymap is refused')
  eq(tostring(err):find('chats_keymap', 1, true) ~= nil, true, 'the refusal names it')
end)

-- ---- the mail search ----------------------------------------------------------

-- A bd list record of a mail message, `ago` seconds old, with a body of its own.
local function found_mail(id, sender, assignee, title, body, ago)
  return { id = id, title = title, sender = sender, assignee = assignee, status = 'open', description = body,
    created_at = os.date('!%Y-%m-%dT%H:%M:%SZ', os.time() - ago), labels = {}, issue_type = 'message' }
end

-- Hits for "markdown": other-city by subject (upper case), demo-city by subject,
-- by sender and by body; one more sent by human, to the reviewer.
local function search_fixture()
  local cities = city_dirs()
  local demo = {
    found_mail('ic-wisp-s1', 'mayor', 'human', 'Markdown renderer ready', 'it is done', 3600),
    found_mail('ic-wisp-s3', 'markdown-bot', 'human', 'Nightly', 'all green', 2 * 3600),
    found_mail('ic-wisp-s2', 'builder', 'human', 'Weekly build', 'the changelog is in markdown', 3 * 3600),
    found_mail('ic-wisp-s4', 'mayor', 'human', 'Deploy plan', 'freeze at ten', 4 * 3600),
  }
  local side = {
    found_mail('ic-wisp-s5', 'planner', 'human', 'MARKDOWN spec', 'draft', 1800),
    found_mail('ic-wisp-s6', 'human', 'reviewer', 'A question', 'is the Markdown table fine?', 5 * 3600),
  }
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.json', vim.json.encode(demo))
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.other city.json', vim.json.encode(side))
  return cities, demo
end

local SEARCH_LINES = {
  ' other-city  planner→you  MARKDOWN spec  30m ',
  ' demo-city  mayor→you  Markdown renderer ready  1h ',
  ' demo-city  markdown-bot→you  Nightly  2h ',
  ' demo-city  builder→you  Weekly build  3h ',
  ' other-city  you→reviewer  A question  5h ',
}

-- The results float for `text`, once it shows `count` lines (the hits arrive city by city).
local function search_open(text, count)
  vim.cmd('GcMailSearch ' .. text)
  local win = vim.api.nvim_get_current_win()
  wait('the hits arrive', function()
    return #lines_of(win) == (count or 5) and lines_of(win)[1] ~= ' searching… '
  end)
  return win
end

test(':GcMailSearch lists the hits across cities newest first, one bd list per city, case-insensitive', function()
  local cities = search_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.demo-city.delay', '0.4\n')
  vim.cmd('GcMailSearch markdown')
  local win = vim.api.nvim_get_current_win()
  eq(#floats(), 1, 'the float is open')
  eq(vim.api.nvim_win_get_config(win).title[1][1], ' gc mail search "markdown": <CR> open  c chat  q close ', 'its title')
  eq(lines_of(win), { ' searching… ' }, 'searching… at once')
  wait('the hits arrive', function()
    return #lines_of(win) == 5
  end)
  eq(lines_of(win), SEARCH_LINES, 'one line per hit: a subject, a sender, a body, both cases')
  vim.wait(200)
  eq({ bd_list_calls(cities[1].path), bd_list_calls(cities[2].path) }, { 1, 1 }, 'one bd list call per city')
  vim.api.nvim_feedkeys('q', 'x', false)
  eq(#floats(), 0, 'q closes')

  -- Searched again from the cache: the same lines, no more calls
  win = search_open('MARKDOWN')
  eq(lines_of(win), SEARCH_LINES, 'the same hits from the cache')
  vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'x', false)
  win = search_open('no-such-word-anywhere', 1)
  eq(lines_of(win), { ' no mail matches ' }, 'a word in no message')
  vim.api.nvim_feedkeys('q', 'x', false)
  vim.wait(200)
  eq({ bd_list_calls(cities[1].path), bd_list_calls(cities[2].path) }, { 1, 1 }, 'still one load each')

  -- Sender and recipient are searched too
  win = search_open('reviewer', 1)
  eq(lines_of(win), { SEARCH_LINES[5] }, 'a recipient')
  vim.api.nvim_feedkeys('q', 'x', false)
end)

test(':GcMailSearch without text is refused', function()
  search_fixture()
  eq(pcall(vim.cmd, 'GcMailSearch'), false, 'the command needs an argument')
  eq(require('gc_mail.search').run('   '), nil, 'a blank text opens nothing')
  eq(#floats(), 0, 'no float')
  eq(notes[#notes].level, vim.log.levels.WARN, 'a notice says so')
  eq(notes[#notes].message:find('nothing to search', 1, true) ~= nil, true, notes[#notes].message)
  eq(#mail_calls(), 0, 'and nothing ran')
end)

test('<CR> on a hit shows the message in the render-only view, with no gc mail read', function()
  local _, demo = search_fixture()
  local win = search_open('markdown')
  vim.api.nvim_win_set_cursor(win, { 2, 0 })
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  eq(#floats(), 0, 'the float is closed')
  local buf = vim.api.nvim_get_current_buf()
  eq(vim.api.nvim_buf_get_name(buf):match('gc%-mail://demo%-city/ic%-wisp%-s1') ~= nil, true, 'the message view')
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(lines[1], '# Markdown renderer ready', 'the title')
  eq(lines[3], '**From** mayor · **To** human · **City** demo-city · ' .. demo[1].created_at, 'the sender line')
  eq(lines[#lines], 'it is done', 'the body verbatim')
  eq(vim.bo[buf].filetype, 'markdown', 'a markdown view')
  vim.wait(300)
  eq(vim.tbl_filter(function(c)
    return c[4] == 'read' or c[4] == 'mark-read'
  end, mail_calls()), {}, 'no gc mail read call')
  -- The view's keys
  local keys = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    -- The markdown ftplugin adds its own outline keys
    if not vim.tbl_contains({ '[[', ']]', 'gO' }, map.lhs) then
      keys[#keys + 1] = map.lhs
    end
  end
  table.sort(keys)
  eq(keys, { 'a', 'c', 'd', 'q', 'r', 't', 'u' }, 'the keys of the message view')
end)

test('c on a hit opens the chat with its correspondent, the recipient for a message from you', function()
  search_fixture()
  local win = search_open('markdown')
  vim.api.nvim_win_set_cursor(win, { 2, 0 })
  vim.api.nvim_feedkeys('c', 'x', false)
  eq(#floats(), 0, 'the float is closed')
  eq(chat_timeline_names(), { 'demo-city/chat/mayor' }, 'the chat with the sender')
  vim.cmd('silent! only')
  win = search_open('markdown')
  vim.api.nvim_win_set_cursor(win, { 5, 0 })
  vim.api.nvim_feedkeys('c', 'x', false)
  eq(vim.tbl_contains(chat_timeline_names(), 'other-city/chat/reviewer'), true, 'the recipient of a message from you')
  vim.cmd('silent! only')
end)

test('s in the mailbox float and in the panel asks for the text and opens the same results', function()
  local cities = search_fixture()
  inbox('demo-city', { msg('ic-wisp-a1', { subject = 'first' }) })
  inbox('other city', {})
  local asked = {}
  local answer
  local real_input = vim.ui.input
  vim.ui.input = function(opts, on_confirm)
    asked[#asked + 1] = opts.prompt
    on_confirm(answer)
  end
  local ok, err = pcall(function()
    local win = mailbox().open()
    settled(win, 1)
    -- An empty answer cancels
    answer = ''
    vim.api.nvim_feedkeys('s', 'x', false)
    eq(#floats(), 1, 'cancelled: only the mailbox float')
    answer = 'markdown'
    vim.api.nvim_feedkeys('s', 'x', false)
    local results = vim.api.nvim_get_current_win()
    wait('the results arrive', function()
      return #lines_of(results) == 5
    end)
    eq(lines_of(results), SEARCH_LINES, 'the results of the search')
    eq(#asked, 2, 'asked each time')
    vim.api.nvim_feedkeys('q', 'x', false)
    vim.cmd('silent! only')

    local pwin = panel().open()
    listed(cities)
    settled(pwin, 1)
    vim.api.nvim_set_current_win(pwin)
    answer = 'markdown'
    vim.api.nvim_feedkeys('s', 'x', false)
    results = vim.api.nvim_get_current_win()
    wait('the panel results arrive', function()
      return #lines_of(results) == 5
    end)
    eq(lines_of(results), SEARCH_LINES, 'the same results from the panel')
    eq(vim.api.nvim_win_is_valid(pwin), true, 'the panel stays')
  end)
  vim.ui.input = real_input
  assert(ok, err)
end)

test('a failed load for one city is said once and the other city\'s hits still list', function()
  local cities = search_fixture()
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.other city.exit', '1\n')
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.other city.stderr', 'store unavailable\n')
  vim.cmd('GcMailSearch markdown')
  local win = vim.api.nvim_get_current_win()
  wait('both answered', function()
    return bd_list_calls(cities[1].path) == 1 and bd_list_calls(cities[2].path) == 1 and #lines_of(win) == 4
  end)
  vim.wait(300)
  eq(lines_of(win), { SEARCH_LINES[2], SEARCH_LINES[3], SEARCH_LINES[4], ' other-city  cannot load the history ' },
    'the other city lists, the failed one says so')
  local errors = vim.tbl_filter(function(note)
    return note.level == vim.log.levels.ERROR
  end, notes)
  eq(#errors, 1, 'said once')
  eq(errors[1].message:find('store unavailable', 1, true) ~= nil, true, errors[1].message)
  vim.api.nvim_feedkeys('q', 'x', false)
end)

test('a city registered after the list was cached is searched too, and a failed refresh keeps the cached cities', function()
  local cities = search_fixture()
  local gc_mail = require('gc_mail')
  eq(#gc_mail.cached_cities(), 2, 'the cached list has two cities')
  local late_path = vim.fn.fnamemodify(cities[1].path, ':h') .. '/late-city'
  vim.fn.mkdir(late_path .. '/.gc', 'p')
  local all = vim.list_extend(vim.deepcopy(cities), { { name = 'late-city', path = late_path } })
  write(vim.env.FAKE_GC_CITIES, cities_record(all))
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.late-city.json',
    vim.json.encode({ found_mail('ic-wisp-s7', 'mayor', 'human', 'Markdown late', 'x', 60) }))
  local win = search_open('markdown', 6)
  eq(lines_of(win)[1], ' late-city  mayor→you  Markdown late  1m ', 'the newly registered city is searched')
  eq(#gc_mail.cached_cities(), 3, 'the refresh replaced the cached list')
  eq(bd_list_calls(late_path), 1, 'one bd list for the new city')
  vim.api.nvim_feedkeys('q', 'x', false)

  -- gc cities failing leaves the cached list searched, said once as a warning
  notes = {}
  vim.env.FAKE_GC_CITIES_EXIT = '1'
  win = search_open('markdown', 6)
  vim.wait(200)
  local warns = vim.tbl_filter(function(note)
    return note.level == vim.log.levels.WARN
  end, notes)
  eq(#warns, 1, 'the failed refresh is said once')
  eq(warns[1].message:find('not refreshed', 1, true) ~= nil, true, warns[1].message)
  eq(#lines_of(win), 6, 'the cached cities are still searched')
  vim.api.nvim_feedkeys('q', 'x', false)
  vim.env.FAKE_GC_CITIES_EXIT = nil
end)

test('every mapping of the search results and of the s key carries a gc-mail: desc', function()
  search_fixture()
  inbox('demo-city', { msg('ic-wisp-a1', { subject = 'first' }) })
  inbox('other city', { msg('sc-wisp-b1', { subject = 'second' }) })
  local win = search_open('markdown')
  for _, lhs in ipairs({ '<CR>', 'c', 'q', '<Esc>' }) do
    local desc
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_win_get_buf(win), 'n')) do
      if map.lhs == lhs then
        desc = map.desc
      end
    end
    eq(type(desc) == 'string' and desc:sub(1, 9) == 'gc-mail: ', true, ('mapping %s has a gc-mail: desc, got %s'):format(lhs, tostring(desc)))
  end
  vim.api.nvim_feedkeys('q', 'x', false)
  local mwin = mailbox().open()
  -- A row from each city: both inbox calls have answered. preload joins the
  -- float's gc cities refresh, so its callback has run too: no call of this
  -- test answers into the next one.
  settled(mwin, 2)
  preload()
  local desc
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_win_get_buf(mwin), 'n')) do
    if map.lhs == 's' then
      desc = map.desc
    end
  end
  eq(type(desc) == 'string' and desc:sub(1, 9) == 'gc-mail: ', true, 'the s key of the mailbox float: ' .. tostring(desc))
  vim.api.nvim_feedkeys('q', 'x', false)
end)

-- ---- all mail, marks and bulk actions ------------------------------------------

-- A message as `gc bd list` prints it (history.load reads it): open, to `human`.
local function bead(id, fields)
  return vim.tbl_extend('force', {
    id = id, title = 'subject ' .. id, sender = 'mayor', assignee = 'human', status = 'open',
    created_at = '2026-10-07T12:00:00Z', description = 'body of ' .. id,
  }, fields or {})
end

local function bd_list(city, beads)
  write(vim.env.FAKE_GC_MAIL .. '/bd-list.' .. city .. '.json', vim.json.encode(beads) .. '\n')
end

local function calls_of(verb)
  return vim.tbl_filter(function(c)
    return c[4] == verb
  end, mail_calls())
end

-- gc's answer to an archive or delete of every id in `ids`.
local function acted_many(cmd, ids, city)
  answer(cmd, { command = 'mail.' .. cmd, action = cmd, ids = ids, count = #ids }, city)
end

local function title_of(win)
  local title = vim.api.nvim_win_get_config(win).title
  return table.concat(vim.tbl_map(function(chunk)
    return chunk[1]
  end, title or {}))
end

local function press(keys)
  vim.api.nvim_feedkeys(keys, 'x', false)
end

-- Marks the rows `list` of the window `win` with x, from that window.
local function mark_rows(win, list)
  for _, row in ipairs(list) do
    vim.api.nvim_win_set_cursor(win, { row, 0 })
    press('x')
  end
end

-- demo-city's inbox: one unread message. Its history: that one, a read one,
-- a closed one, and one Nick sent; other city's history: a read one.
local function all_mail_fixture()
  local cities, log = city_dirs()
  write(log, '')
  inbox('demo-city', { msg('ic-wisp-u1', { subject = 'unread', created_at = '2026-10-07T13:00:00Z' }) })
  inbox('other city', {})
  bd_list('demo-city', {
    bead('ic-wisp-u1', { title = 'unread', created_at = '2026-10-07T13:00:00Z' }),
    bead('ic-wisp-r1', { title = 'was read', created_at = '2026-10-07T12:00:00Z', labels = { 'read' } }),
    bead('ic-wisp-c1', { title = 'closed', created_at = '2026-10-07T11:00:00Z', status = 'closed' }),
    bead('ic-wisp-o1', { title = 'to the mayor', sender = 'human', assignee = 'mayor',
      created_at = '2026-10-07T10:00:00Z' }),
  })
  bd_list('other city', { bead('sc-wisp-r2', { title = 'side read', created_at = '2026-10-07T11:30:00Z',
    labels = { 'read' } }) })
  return cities
end

local ALL_MAIL = {
  '  ● demo-city  mayor  unread',
  '    demo-city  mayor  was read',
  '    other-city  mayor  side read',
  '  × demo-city  mayor  closed',
}

test('H lists read and closed mail to human from the history in both views, one bd list per city; H again lists today\'s set', function()
  local cities = all_mail_fixture()
  local pwin = panel().open()
  settled(pwin, 1)
  listed(cities)
  local fwin = mailbox().open()
  settled(fwin, 1)
  eq(rows(fwin), { '  ● demo-city  mayor  unread' }, 'today\'s set: the unread inbox')
  eq(title_of(fwin):find('all mail', 1, true), nil, 'the title does not say all mail')
  press('H')
  wait('all mail in the float', function()
    return #rows(fwin) == 4
  end)
  eq(rows(fwin), ALL_MAIL, 'unread ●, read blank, closed ×, newest first; mail Nick sent is not listed')
  wait('all mail in the panel', function()
    return vim.deep_equal(rows(pwin), ALL_MAIL)
  end)
  eq(title_of(fwin):sub(1, 10), ' all mail ', 'the float title says all mail')
  eq(vim.wo[pwin].statusline:sub(1, 10), ' all mail ', 'the panel status line says all mail')
  eq({ bd_list_calls(cities[1].path), bd_list_calls(cities[2].path) }, { 1, 1 }, 'one bd list call per city')
  -- H in the panel turns it off for both views.
  panel_key(pwin, 'H')()
  eq(rows(fwin), { '  ● demo-city  mayor  unread' }, 'the float lists today\'s set again')
  eq(rows(pwin), { '  ● demo-city  mayor  unread' }, 'and the panel')
  eq(title_of(fwin):find('all mail', 1, true), nil, 'the title too')
  -- On again: the history already loaded, no second load; R in the mode loads it again.
  press('H')
  eq(rows(fwin), ALL_MAIL, 'all mail again at once')
  vim.wait(200)
  eq({ bd_list_calls(cities[1].path), bd_list_calls(cities[2].path) }, { 1, 1 }, 'no second load for a second H')
  press('R')
  wait('R loads the history again', function()
    return bd_list_calls(cities[1].path) == 2 and bd_list_calls(cities[2].path) == 2
  end)
  vim.wait(200)
  eq(errors(), {}, 'nothing said')
  press('q')
end)

test('a failed history load is said once and all mail shows what the mailbox has', function()
  local cities = all_mail_fixture()
  raw_answer('bd-list', 'exit', '1', 'other city')
  raw_answer('bd-list', 'stderr', 'store unavailable\n', 'other city')
  preload()
  local fwin = mailbox().open()
  settled(fwin, 1)
  vim.wait(100)
  press('H')
  wait('demo-city history listed', function()
    return #rows(fwin) == 3
  end)
  wait('the failure said', function()
    return #errors() == 1
  end)
  eq(rows(fwin), { ALL_MAIL[1], ALL_MAIL[2], ALL_MAIL[4] }, 'the city that answered')
  assert(errors()[1]:find('store unavailable', 1, true), errors()[1])
  press('R')
  wait('loaded again', function()
    return bd_list_calls(cities[2].path) == 2
  end)
  vim.wait(200)
  eq(#errors(), 1, 'the same failure is not said again')
  press('q')
end)

test('x marks lines in both views; a archives exactly the marked ones in one call; a late inbox answer does not bring them back', function()
  local cities, log = city_dirs()
  write(log, '')
  inbox('demo-city', {
    msg('ic-wisp-a1', { subject = 'first', created_at = '2026-10-07T13:00:00Z' }),
    msg('ic-wisp-a2', { subject = 'second', created_at = '2026-10-07T12:00:00Z' }),
    msg('ic-wisp-a3', { subject = 'third', created_at = '2026-10-07T11:00:00Z' }),
  })
  inbox('other city', {})
  local pwin = panel().open()
  settled(pwin, 3)
  listed(cities)
  local fwin = mailbox().open()
  settled(fwin, 3)
  vim.wait(200)
  mark_rows(fwin, { 1, 3 })
  local marked = { 'x ● demo-city  mayor  first', '  ● demo-city  mayor  second', 'x ● demo-city  mayor  third' }
  eq(rows(fwin), marked, 'x in the first column of the marked lines')
  eq(rows(pwin), marked, 'the panel shows the same marks')
  -- A refresh that answers late, with both messages still in it.
  raw_answer('inbox', 'delay', '1', 'demo-city')
  local n = inbox_calls(cities[1].path)
  press('R')
  wait('the refresh started', function()
    return inbox_calls(cities[1].path) == n + 1
  end)
  acted_many('archive', { 'ic-wisp-a1', 'ic-wisp-a3' })
  vim.api.nvim_win_set_cursor(fwin, { 2, 0 })
  press('a')
  wait('archived in both views', function()
    return #rows(fwin) == 1 and #rows(pwin) == 1
  end)
  eq(calls_of('archive'), { call('archive', cities[1].path, 'ic-wisp-a1', 'ic-wisp-a3', '--json') },
    'one archive call with exactly the marked ids, in list order')
  eq(rows(fwin), { '  ● demo-city  mayor  second' }, 'the float')
  eq(rows(pwin), { '  ● demo-city  mayor  second' }, 'the panel')
  vim.wait(1500) -- the refresh answers 1 s after it was made
  eq(rows(fwin), { '  ● demo-city  mayor  second' }, 'the late answer does not bring them back to the float')
  eq(rows(pwin), { '  ● demo-city  mayor  second' }, 'nor to the panel')
  -- The marks went with their messages: a now acts on the line under the cursor.
  acted('archive', 'ic-wisp-a2')
  press('a')
  wait('the cursor message archived', function()
    return rows(fwin)[1] == ' no mail '
  end)
  eq(calls_of('archive')[2], call('archive', cities[1].path, 'ic-wisp-a2', '--json'), 'one id')
  eq(errors(), {}, 'nothing said')
  press('q')
end)

test('V over three lines then m marks each read with its own call, in order, one at a time; u likewise', function()
  preload()
  inbox('demo-city', {
    msg('ic-wisp-a1', { subject = 'one', created_at = '2026-10-07T13:00:00Z' }),
    msg('ic-wisp-a2', { subject = 'two', created_at = '2026-10-07T12:00:00Z' }),
    msg('ic-wisp-a3', { subject = 'three', created_at = '2026-10-07T11:00:00Z' }),
    msg('ic-wisp-a4', { subject = 'four', created_at = '2026-10-07T10:00:00Z' }),
  })
  inbox('other city', {})
  local win = mailbox().open()
  settled(win, 4)
  vim.wait(200)
  local ids = { 'ic-wisp-a1', 'ic-wisp-a2', 'ic-wisp-a3' }
  -- Each call answers 0.3 s after it started; the next answer is put in place
  -- once a call has read its own.
  local function through(verb, key)
    raw_answer(verb, 'delay', '0.3')
    acted(verb, ids[1])
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    press('Vjj' .. key)
    eq(vim.api.nvim_get_mode().mode, 'n', key .. ' leaves visual mode')
    for i = 1, #ids do
      wait(('%s call %d'):format(verb, i), function()
        return #calls_of(verb) == i
      end)
      vim.wait(100)
      eq(#calls_of(verb), i, verb .. ': one call at a time')
      if ids[i + 1] then
        acted(verb, ids[i + 1])
      end
    end
    eq(vim.tbl_map(function(c)
      return c[5]
    end, calls_of(verb)), ids, verb .. ': one call per selected message, in list order')
  end
  through('mark-read', 'm')
  wait('all three read', function()
    return rows(win)[3] == '    demo-city  mayor  three'
  end)
  eq(rows(win), { '    demo-city  mayor  one', '    demo-city  mayor  two', '    demo-city  mayor  three',
    '  ● demo-city  mayor  four' }, 'the selected three are read, the fourth is not')
  eq(#kept_files(), 3, 'each read one is kept')
  through('mark-unread', 'u')
  wait('all three unread', function()
    return rows(win)[3] == '  ● demo-city  mayor  three'
  end)
  eq(rows(win)[1], '  ● demo-city  mayor  one', 'unread again')
  vim.wait(400)
  eq(#calls_of('mark-unread'), 3, 'nothing more ran')
  eq(errors(), {}, 'nothing said')
  press('q')
end)

test('d with marks asks once and deletes them in one call; No deletes nothing', function()
  preload()
  inbox('demo-city', {
    msg('ic-wisp-a1', { subject = 'one', created_at = '2026-10-07T13:00:00Z' }),
    msg('ic-wisp-a2', { subject = 'two', created_at = '2026-10-07T12:00:00Z' }),
    msg('ic-wisp-a3', { subject = 'three', created_at = '2026-10-07T11:00:00Z' }),
  })
  inbox('other city', {})
  local win = mailbox().open()
  settled(win, 3)
  vim.wait(200)
  mark_rows(win, { 1, 2 })
  acted_many('delete', { 'ic-wisp-a1', 'ic-wisp-a2' })
  local confirm = vim.fn.confirm
  local asked = {}
  vim.fn.confirm = function(question)
    asked[#asked + 1] = question
    return 2
  end
  press('d')
  vim.wait(300)
  eq(asked, { 'Delete 2 messages?' }, 'asks once for all of them')
  eq(calls_of('delete'), {}, 'No deletes nothing')
  eq(rows(win)[1], 'x ● demo-city  mayor  one', 'the marks stay')
  vim.fn.confirm = function(question)
    asked[#asked + 1] = question
    return 1
  end
  press('d')
  vim.fn.confirm = confirm
  wait('deleted', function()
    return #rows(win) == 1
  end)
  eq(#asked, 2, 'asked once more, for the second d')
  eq(calls_of('delete'), { call('delete', '/srv/demo-city', 'ic-wisp-a1', 'ic-wisp-a2', '--json') }, 'one delete call')
  eq(rows(win), { '  ● demo-city  mayor  three' }, 'the unmarked one stays')
  press('q')
end)

test('an archive answer that names only one of two ids is refused, said once, and nothing changes', function()
  preload()
  inbox('demo-city', {
    msg('ic-wisp-a1', { subject = 'one', created_at = '2026-10-07T13:00:00Z' }),
    msg('ic-wisp-a2', { subject = 'two', created_at = '2026-10-07T12:00:00Z' }),
  })
  inbox('other city', {})
  local win = mailbox().open()
  settled(win, 2)
  vim.wait(200)
  mark_rows(win, { 1, 2 })
  answer('archive', { command = 'mail.archive', action = 'archive', ids = { 'ic-wisp-a1' }, count = 1 })
  press('a')
  wait('refused', function()
    return #errors() == 1
  end)
  vim.wait(200)
  local said = errors()
  eq(#said, 1, 'said once')
  assert(said[1]:find('ic-wisp-a1 ic-wisp-a2', 1, true) and said[1]:find('did not name ic-wisp-a2', 1, true), said[1])
  eq(rows(win), { 'x ● demo-city  mayor  one', 'x ● demo-city  mayor  two' }, 'both lines and marks stay')
  eq(#calls_of('archive'), 1, 'one call, never retried')
  press('q')
end)

test('a failed archive of one city\'s set leaves every line of it; the other city\'s set is archived in its own call', function()
  preload()
  inbox('demo-city', {
    msg('ic-wisp-a1', { subject = 'one', created_at = '2026-10-07T13:00:00Z' }),
    msg('ic-wisp-a2', { subject = 'two', created_at = '2026-10-07T12:00:00Z' }),
  })
  inbox('other city', {
    msg('sc-wisp-b1', { subject = 'side one', created_at = '2026-10-07T12:30:00Z' }),
    msg('sc-wisp-b2', { subject = 'side two', created_at = '2026-10-07T11:30:00Z' }),
  })
  raw_answer('archive', 'exit', '1', 'demo-city')
  raw_answer('archive', 'stderr', 'gc mail archive: message is closed\n', 'demo-city')
  acted_many('archive', { 'sc-wisp-b1', 'sc-wisp-b2' })
  local win = mailbox().open()
  settled(win, 4)
  vim.wait(200)
  mark_rows(win, { 1, 2, 3, 4 })
  press('a')
  wait('the other city set archived', function()
    return #rows(win) == 2
  end)
  vim.wait(200)
  local archives = calls_of('archive')
  table.sort(archives, function(a, b)
    return a[2] < b[2]
  end)
  eq(archives, {
    call('archive', '/srv/demo-city', 'ic-wisp-a1', 'ic-wisp-a2', '--json'),
    call('archive', '/srv/other city', 'sc-wisp-b1', 'sc-wisp-b2', '--json'),
  }, 'one call per city')
  eq(rows(win), { 'x ● demo-city  mayor  one', 'x ● demo-city  mayor  two' }, 'every line of the failed city stays')
  local said = errors()
  eq(#said, 1, 'said once')
  assert(said[1]:find('ic-wisp-a1 ic-wisp-a2', 1, true) and said[1]:find('message is closed', 1, true), said[1])
  press('q')
end)

test('a bulk archive that fails while a refresh runs leaves every line: the refresh answer does not drop them (I2)', function()
  preload()
  inbox('demo-city', {
    msg('ic-wisp-a1', { subject = 'one', created_at = '2026-10-07T13:00:00Z' }),
    msg('ic-wisp-a2', { subject = 'two', created_at = '2026-10-07T12:00:00Z' }),
  })
  inbox('other city', {})
  local win = mailbox().open()
  settled(win, 2)
  vim.wait(200)
  mark_rows(win, { 1, 2 })
  -- The refresh answers after 0.5 s, while the archive (1 s) still runs; then the archive fails.
  raw_answer('inbox', 'delay', '0.5', 'demo-city')
  local n = inbox_calls('/srv/demo-city')
  press('R')
  wait('the refresh started', function()
    return inbox_calls('/srv/demo-city') == n + 1
  end)
  raw_answer('archive', 'delay', '1', 'demo-city')
  raw_answer('archive', 'exit', '1', 'demo-city')
  raw_answer('archive', 'stderr', 'gc mail archive: store unavailable\n', 'demo-city')
  press('a')
  wait('the archive failure said', function()
    return #errors_matching('cannot archive 2 messages') == 1
  end)
  vim.wait(200)
  eq(#calls_of('archive'), 1, 'one archive call')
  eq(rows(win), { 'x ● demo-city  mayor  one', 'x ● demo-city  mayor  two' }, 'both lines and their marks stay')
  eq(#errors_matching('cannot archive'), 1, 'said once')
  press('q')
end)

test('H before the first city list arrives loads the history of every city once the list comes', function()
  local cities = all_mail_fixture()
  -- A new session: no cached city list, and gc cities answers after 0.5 s.
  fresh()
  vim.env.FAKE_GC_CITIES_DELAY = '0.5'
  eq(gc_mail.cached_cities(), nil, 'no cached city list')
  local fwin = mailbox().open()
  press('H')
  wait('all mail once the cities arrived', function()
    return vim.deep_equal(rows(fwin), ALL_MAIL)
  end)
  eq({ bd_list_calls(cities[1].path), bd_list_calls(cities[2].path) }, { 1, 1 }, 'one bd list call per city')
  vim.wait(200)
  eq({ bd_list_calls(cities[1].path), bd_list_calls(cities[2].path) }, { 1, 1 }, 'and no more')
  eq(errors(), {}, 'nothing said')
  press('q')
end)

test('X clears every mark; a mark on a message that leaves the list is dropped', function()
  preload()
  inbox('demo-city', {
    msg('ic-wisp-a1', { subject = 'one', created_at = '2026-10-07T13:00:00Z' }),
    msg('ic-wisp-a2', { subject = 'two', created_at = '2026-10-07T12:00:00Z' }),
  })
  inbox('other city', {})
  local win = mailbox().open()
  settled(win, 2)
  vim.wait(200)
  mark_rows(win, { 1, 2 })
  eq(rows(win), { 'x ● demo-city  mayor  one', 'x ● demo-city  mayor  two' }, 'marked')
  press('X')
  eq(rows(win), { '  ● demo-city  mayor  one', '  ● demo-city  mayor  two' }, 'X clears them')
  mark_rows(win, { 2, 1, 1 })
  eq(rows(win), { '  ● demo-city  mayor  one', 'x ● demo-city  mayor  two' }, 'x again unmarks')
  -- two leaves the inbox (read elsewhere and closed), then comes back unread.
  inbox('demo-city', { msg('ic-wisp-a1', { subject = 'one', created_at = '2026-10-07T13:00:00Z' }) })
  press('R')
  wait('two left', function()
    return #rows(win) == 1
  end)
  inbox('demo-city', {
    msg('ic-wisp-a1', { subject = 'one', created_at = '2026-10-07T13:00:00Z' }),
    msg('ic-wisp-a2', { subject = 'two', created_at = '2026-10-07T12:00:00Z' }),
  })
  vim.wait(200)
  press('R')
  wait('two is back', function()
    return #rows(win) == 2
  end)
  eq(rows(win), { '  ● demo-city  mayor  one', '  ● demo-city  mayor  two' }, 'without its old mark')
  press('q')
end)

test('all mail: history-only messages are archived like any other and come back closed only from a later load', function()
  local cities = all_mail_fixture()
  local fwin = mailbox().open()
  settled(fwin, 1)
  vim.wait(200)
  press('H')
  wait('all mail', function()
    return #rows(fwin) == 4
  end)
  mark_rows(fwin, { 2, 3 })
  acted_many('archive', { 'ic-wisp-r1' }, 'demo-city')
  acted_many('archive', { 'sc-wisp-r2' }, 'other city')
  press('a')
  wait('archived', function()
    return #rows(fwin) == 2
  end)
  eq(rows(fwin), { ALL_MAIL[1], ALL_MAIL[4] }, 'the two read ones left')
  local archives = calls_of('archive')
  table.sort(archives, function(a, b)
    return a[2] < b[2]
  end)
  eq(archives, { call('archive', cities[1].path, 'ic-wisp-r1', '--json'),
    call('archive', cities[2].path, 'sc-wisp-r2', '--json') }, 'one call per city, both through gc')
  -- gc closed them; the next history load lists them closed.
  bd_list('demo-city', {
    bead('ic-wisp-u1', { title = 'unread', created_at = '2026-10-07T13:00:00Z' }),
    bead('ic-wisp-r1', { title = 'was read', created_at = '2026-10-07T12:00:00Z', status = 'closed' }),
    bead('ic-wisp-c1', { title = 'closed', created_at = '2026-10-07T11:00:00Z', status = 'closed' }),
  })
  bd_list('other city', { bead('sc-wisp-r2', { title = 'side read', created_at = '2026-10-07T11:30:00Z',
    status = 'closed' }) })
  local closed_now = { ALL_MAIL[1], '  × demo-city  mayor  was read', '  × other-city  mayor  side read', ALL_MAIL[4] }
  press('R')
  wait('listed closed', function()
    return vim.deep_equal(rows(fwin), closed_now)
  end)
  -- A closed message gc refuses to archive stays, said once. Only the
  -- refusal is counted: R's inbox calls may still be running.
  raw_answer('archive', 'exit', '1', 'demo-city')
  raw_answer('archive', 'stderr', 'message is closed\n', 'demo-city')
  vim.api.nvim_win_set_cursor(fwin, { 2, 0 })
  press('a')
  local refusal = 'cannot archive "was read": gc mail archive in demo-city failed: message is closed'
  wait('refused', function()
    return #errors_matching(refusal) == 1
  end)
  vim.wait(200)
  eq(rows(fwin), closed_now, 'the line stays')
  eq(#errors_matching(refusal), 1, 'said once')
  press('q')
end)

test('single archive and delete take the bulk route, read and unread share one callback, and one builder makes every title', function()
  eq(mailbox().title(false),
    ' gc mail: <CR> open  r reply  t thread  c chat  s search  x mark  m read  u unread  a archive  d delete  H all  R refresh ',
    'the mailbox title')
  eq(mailbox().title(true),
    ' all mail  <CR> open  r reply  t thread  c chat  s search  x mark  m read  u unread  a archive  d delete  H all  R refresh ',
    'the all-mail title')
  eq(mailbox().title(false, true),
    ' gc mail: <CR> open  r reply  t thread  c chat  s search  x mark  m read  u unread  a archive  d delete  H all  p preview  R refresh  q close ',
    'the panel title')
  eq(mailbox().title(true, true),
    ' all mail  <CR> open  r reply  t thread  c chat  s search  x mark  m read  u unread  a archive  d delete  H all  p preview  R refresh  q close ',
    'the all-mail panel title')
  preload()
  inbox('demo-city', {
    msg('ic-wisp-a1', { subject = 'first', created_at = '2026-10-07T13:00:00Z' }),
    msg('ic-wisp-a2', { subject = 'second', created_at = '2026-10-07T12:00:00Z' }),
    msg('ic-wisp-a3', { subject = 'third', created_at = '2026-10-07T11:00:00Z' }),
  })
  inbox('other city', {})
  local pwin = panel().open()
  settled(pwin, 3)
  eq(vim.wo[pwin].statusline, mailbox().title(false, true), 'the panel status line is the built title')
  local win = mailbox().open()
  settled(win, 3)
  eq(title_of(win), mailbox().title(false), 'the float title is the built title')
  -- One message through M.act: one call with one id, the single notice.
  acted('archive', 'ic-wisp-a1')
  mailbox().act('archive', { mailbox().entries()[1] })
  wait('the single archive notice', function()
    return notes[#notes] ~= nil and notes[#notes].message == 'gc-mail: archived: first'
  end)
  eq(rows(win), { '  ● demo-city  mayor  second', '  ● demo-city  mayor  third' }, 'only the archived one left')
  eq(calls_of('archive'), { call('archive', '/srv/demo-city', 'ic-wisp-a1', '--json') }, 'one archive call, one id')
  local confirm = vim.fn.confirm
  local asked
  vim.fn.confirm = function(question)
    asked = question
    return 1
  end
  acted('delete', 'ic-wisp-a2')
  mailbox().act('delete', { mailbox().entries()[1] })
  vim.fn.confirm = confirm
  eq(asked, 'Delete "second" from mayor?', 'the single delete asks its own question')
  wait('the single delete notice', function()
    return notes[#notes] ~= nil and notes[#notes].message == 'gc-mail: deleted: second'
  end)
  eq(rows(win), { '  ● demo-city  mayor  third' }, 'the deleted one left too')
  eq(calls_of('delete'), { call('delete', '/srv/demo-city', 'ic-wisp-a2', '--json') }, 'one delete call, one id')
  -- The bulk route checks every id before any gc call: a bad single id is
  -- refused in its words and runs nothing.
  local bad = { city = { name = 'demo-city', path = '/srv/demo-city' },
    message = { id = 'not an id', from = 'mayor', subject = 'bad one' }, read = false }
  mailbox().act('archive', { bad })
  eq(errors(), { 'gc-mail: cannot archive "bad one": not a list of distinct gc mail ids' },
    'the single archive is refused before gc runs')
  eq(#calls_of('archive'), 1, 'no second archive call')
  -- Read and unread answer through the one callback rule: (true, nil,
  -- applied) on success, (false, err) on failure, and no callback is fine.
  local entry = mailbox().entries()[1]
  local seen
  acted('mark-read', 'ic-wisp-a3')
  mailbox().actions.read(entry, function(ok, err, applied)
    seen = { ok, err, applied }
  end)
  wait('the read callback', function()
    return seen ~= nil
  end)
  eq(seen, { true, nil, true }, 'read answers true, no error, applied')
  eq(entry.read, true, 'read applied')
  seen = nil
  acted('mark-unread', 'ic-wisp-a3')
  mailbox().actions.unread(entry, function(ok, err, applied)
    seen = { ok, err, applied }
  end)
  wait('the unread callback', function()
    return seen ~= nil
  end)
  eq(seen, { true, nil, true }, 'unread answers the same way')
  eq(entry.read, false, 'unread applied')
  seen = nil
  raw_answer('mark-read', 'exit', '1')
  raw_answer('mark-read', 'stderr', 'fake mark-read error\n')
  mailbox().actions.read(entry, function(ok, err)
    seen = { ok, err }
  end)
  wait('the failed read callback', function()
    return seen ~= nil
  end)
  eq(seen[1], false, 'a failed read answers false')
  eq(type(seen[2]) == 'string' and seen[2]:find('mark-read', 1, true) ~= nil, true, 'with the reason')
  eq(entry.read, false, 'the failed read changed nothing')
  vim.fn.delete(vim.env.FAKE_GC_MAIL .. '/mark-read.exit')
  vim.fn.delete(vim.env.FAKE_GC_MAIL .. '/mark-read.stderr')
  acted('mark-read', 'ic-wisp-a3')
  mailbox().actions.read(entry)
  wait('a read with no callback still applies', function()
    return entry.read == true
  end)
  eq(#errors_matching('cannot mark "third" read'), 1, 'only the failed read was said')
  press('q')
end)

test('every mailbox mapping this view adds carries a gc-mail: desc, in normal and visual mode', function()
  local cities, log = city_dirs()
  write(log, '')
  inbox('demo-city', { msg('ic-wisp-a1') })
  inbox('other city', {})
  local pwin = panel().open()
  settled(pwin, 1)
  listed(cities)
  local fwin = mailbox().open()
  settled(fwin, 1)
  for _, win in ipairs({ fwin, pwin }) do
    local buf = vim.api.nvim_win_get_buf(win)
    local found = {}
    for _, mode in ipairs({ 'n', 'x' }) do
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
        found[mode .. map.lhs] = map.desc
      end
    end
    for _, key in ipairs({ 'nx', 'nX', 'nH', 'nm', 'nu', 'na', 'nd', 'xm', 'xu', 'xa', 'xd' }) do
      assert(type(found[key]) == 'string' and found[key]:find('^gc%-mail: '), key .. ': ' .. tostring(found[key]))
    end
  end
  press('q')
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
