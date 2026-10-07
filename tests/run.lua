-- Headless tests for gc-mail.nvim. From the repository root:
--   nvim --headless -u NONE -i NONE -n -l tools/gc-mail.nvim/tests/run.lua
-- A fake gc (tests/bin/gc) is first on PATH; the real gc never runs.
local here = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, 'S').source:sub(2)))
local root = vim.fs.dirname(here)
vim.opt.runtimepath:prepend(root)
package.loaded.gc_mail = nil
local gc_mail = require('gc_mail')

local scratch = vim.fn.tempname()
vim.fn.mkdir(scratch, 'p')
vim.env.PATH = here .. '/bin:' .. vim.env.PATH
vim.env.FAKE_GC_CITIES = scratch .. '/cities.jsonl'
vim.env.FAKE_GC_LOG = scratch .. '/argv'

local function write(path, text)
  local file = assert(io.open(path, 'w'))
  file:write(text)
  file:close()
end

local function cities_record(cities)
  return vim.json.encode({ schema_version = '1', ok = true, registry_path = '/r/cities.toml', cities = cities }) .. '\n'
end

local TWO = { { name = 'imd-city', path = '/srv/imd-city' }, { name = 'side-city', path = '/srv/side city' } }

local notes = {}
vim.notify = function(message, level)
  notes[#notes + 1] = { message = message, level = level }
end

local function reset(env)
  notes = {}
  os.remove(vim.env.FAKE_GC_LOG)
  write(vim.env.FAKE_GC_CITIES, cities_record(TWO))
  vim.env.FAKE_GC_EXIT, vim.env.FAKE_GC_STDERR, vim.env.FAKE_GC_CITIES_EXIT = nil, nil, nil
  vim.env.FAKE_GC_CITIES_HANG = nil
  for k, v in pairs(env or {}) do
    vim.env[k] = v
  end
  vim.o.lines, vim.o.columns, vim.o.cmdheight = 24, 80, 1
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= '' then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.cmd('enew!')
end

local function buffer(lines)
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function recorded_argv()
  local file = io.open(vim.env.FAKE_GC_LOG, 'rb')
  if not file then
    return nil
  end
  local data = file:read('*a')
  file:close()
  local argv = {}
  for arg in data:gmatch('([^%z]*)%z') do
    argv[#argv + 1] = arg
  end
  return argv
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

local function wait_send(buf, city)
  local finished, sent = false, nil
  gc_mail.send(buf, city, function(result)
    finished, sent = true, result
  end)
  assert(vim.wait(5000, function()
    return finished
  end), 'send did not finish')
  return sent
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

test('nothing runs at load time and setup maps <Space>mm and :GcMail', function()
  eq(recorded_argv(), nil, 'gc ran at load')
  gc_mail.setup()
  eq(vim.fn.maparg('<Space>mm', 'n') ~= '', true, 'default keymap missing')
  eq(vim.fn.exists(':GcMail'), 2, ':GcMail missing')
  vim.keymap.del('n', '<Space>mm')
  gc_mail.setup({ keymap = false })
  eq(vim.fn.maparg('<Space>mm', 'n'), '', 'keymap = false still mapped')
  eq(vim.fn.exists(':GcMail'), 2, ':GcMail missing without a keymap')
  gc_mail.setup({ keymap = '<leader>gm' })
  eq(vim.fn.maparg('<leader>gm', 'n') ~= '', true, 'custom keymap missing')
  eq(recorded_argv(), nil, 'gc ran during setup')
end)

test('the picker lists one line per city mayor, even for a single city', function()
  buffer({ 'hello' })
  local win = gc_mail.open()
  eq(#floats(), 1, 'picker window')
  eq(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false),
    { ' imd-city  mayor ', ' side-city  mayor ' }, 'picker lines')
  eq(vim.api.nvim_win_get_height(win), 2, 'picker height = city count')
  eq(recorded_argv(), nil, 'opening the picker sent mail')
  vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'x', false)
  eq(#floats(), 0, '<Esc> closes')

  reset()
  write(vim.env.FAKE_GC_CITIES, cities_record({ TWO[1] }))
  buffer({ 'hello' })
  gc_mail.open()
  eq(#floats(), 1, 'a single city still asks')
  vim.api.nvim_feedkeys('q', 'x', false)
  eq(#floats(), 0, 'q closes')
  eq(recorded_argv(), nil, 'cancel sent mail')
end)

test('choosing a city sends the exact argv and clears the buffer on success', function()
  local buf = buffer({ '', '  Deploy plan for tomorrow  ', 'step one', '', 'step "two" $(not run)' })
  gc_mail.open()
  vim.api.nvim_feedkeys(vim.keycode('j<CR>'), 'x', false)
  eq(#floats(), 0, 'picker closes on <CR>')
  assert(vim.wait(5000, function()
    return #vim.api.nvim_buf_get_lines(buf, 0, -1, false) == 1
  end), 'buffer not cleared')
  eq(recorded_argv(), { '--city', '/srv/side city', 'mail', 'send', 'mayor', '-s', 'Deploy plan for tomorrow',
    '-m', '\n  Deploy plan for tomorrow  \nstep one\n\nstep "two" $(not run)', '--notify' }, 'argv')
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { '' }, 'buffer cleared')
  eq(vim.bo[buf].modified, false, 'modified reset')
  eq(notes[#notes].message, 'gc-mail: sent to side-city mayor', 'success notice')
end)

test('the subject is the first non-empty line trimmed to 72 characters', function()
  local long = string.rep('é', 80)
  local buf = buffer({ '   ', '\t' .. long .. '  ', 'body' })
  eq(wait_send(buf, TWO[1]), true, 'sent')
  local argv = recorded_argv()
  eq(argv[7], string.rep('é', 72), 'subject')
end)

test('a failed send keeps the buffer and shows the start of gc stderr', function()
  reset({ FAKE_GC_EXIT = '3', FAKE_GC_STDERR = 'gc mail send: mayor not found\nsecond line\nthird\nfourth' })
  local buf = buffer({ 'keep me', 'please' })
  vim.bo[buf].modified = true
  eq(wait_send(buf, TWO[1]), false, 'reported failure')
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'keep me', 'please' }, 'buffer kept')
  eq(vim.bo[buf].modified, true, 'modified kept')
  eq(notes[#notes].level, vim.log.levels.ERROR, 'error level')
  eq(notes[#notes].message, 'gc-mail: send to imd-city mayor failed (exit 3):\ngc mail send: mayor not found\nsecond line\nthird',
    'failure notice')
end)

test('an empty or whitespace-only buffer is refused and nothing runs', function()
  write(vim.env.FAKE_GC_CITIES, 'not reached')
  for _, lines in ipairs({ { '' }, { '   ', '\t', '' } }) do
    notes = {}
    local buf = buffer(lines)
    eq(gc_mail.open(), nil, 'picker opened')
    eq(#floats(), 0, 'picker window')
    eq(notes[1].message, 'gc-mail: buffer is empty, nothing to send', 'refusal')
    eq(wait_send(buf, TWO[1]), false, 'send refused')
  end
  eq(recorded_argv(), nil, 'gc ran')
end)

test('the picker fits a 10-line editor, border included, and scrolls past that', function()
  local many = {}
  for i = 1, 12 do
    many[i] = { name = 'city-' .. i, path = '/srv/c' .. i }
  end
  write(vim.env.FAKE_GC_CITIES, cities_record(many))
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
  assert(vim.wait(5000, function()
    return recorded_argv() ~= nil
  end), 'no send')
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

test('bad gc cities output or a failing gc opens no picker', function()
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
    eq(gc_mail.open(), nil, 'picker opened')
    eq(notes[#notes].message, case.want, 'notice')
  end
  reset({ FAKE_GC_CITIES_EXIT = '1' })
  buffer({ 'hello' })
  eq(gc_mail.open(), nil, 'picker opened on gc failure')
  eq(#floats(), 0, 'picker window')
  eq(recorded_argv(), nil, 'mail sent')
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

  reset()
  vim.system = function()
    return { wait = function() return nil end, kill = function() end }
  end
  buffer({ 'hello' })
  ok, a = pcall(gc_mail.open)
  vim.system = system
  eq({ ok, a }, { true, nil }, 'open raised on a hung gc')
  eq(#floats(), 0, 'picker window')
  eq(notes[#notes].message, 'gc-mail: gc cities did not answer within 10 s', 'open notice')
  eq(notes[#notes].level, vim.log.levels.ERROR, 'error level')
end)

test('a buffer edited while gc runs is not cleared', function()
  local buf = buffer({ 'first draft' })
  local finished = false
  gc_mail.send(buf, TWO[1], function()
    finished = true
  end)
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { 'typed meanwhile' })
  assert(vim.wait(5000, function()
    return finished
  end), 'send did not finish')
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'first draft', 'typed meanwhile' }, 'buffer kept')
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
vim.fn.delete(scratch, 'rf')
io.stdout:write(('%d tests, %d failed\n'):format(#tests, failed))
os.exit(failed == 0 and 0 or 1)
