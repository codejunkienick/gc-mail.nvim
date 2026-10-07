-- gc-mail.nvim: mail the current buffer to a Gas City mayor.
--
-- <Space>mm (or :GcMail) lists the cities registered with the gc supervisor
-- in a small floating picker; choosing one runs
--   gc --city <path> mail send mayor -s <subject> -m <body> --notify
-- and clears the buffer once gc exits 0. Nothing runs at load time.
local M = {}

local defaults = {
  -- Normal-mode mapping; false sets none (:GcMail still works).
  keymap = '<Space>mm',
}

M.config = vim.deepcopy(defaults)

local SUBJECT_MAX = 72
-- Linux refuses one argv string over 128 KiB (MAX_ARG_STRLEN); stay below it
-- so a huge buffer gets a clear message instead of a spawn error.
local BODY_MAX_BYTES = 120 * 1024
local CITIES_TIMEOUT_MS = 10000

local function notify(message, level)
  vim.notify('gc-mail: ' .. message, level or vim.log.levels.INFO)
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

--- The message a buffer would send: { subject, body }, or nil and the reason.
function M.message(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local body = table.concat(lines, '\n')
  if vim.trim(body) == '' then
    return nil, 'buffer is empty, nothing to send'
  end
  if #body > BODY_MAX_BYTES then
    return nil, ('buffer is %d bytes, over the %d byte limit for one message'):format(#body, BODY_MAX_BYTES)
  end
  local subject
  for _, line in ipairs(lines) do
    if vim.trim(line) ~= '' then
      subject = vim.fn.strcharpart(vim.trim(line), 0, SUBJECT_MAX)
      break
    end
  end
  return { subject = subject, body = body }
end

--- The registered cities from `gc cities --json`: a list of { name, path },
--- or nil and the reason. Anything but the documented record is an error, and
--- so is a gc that does not answer within `timeout_ms` (default 10 s).
function M.cities(timeout_ms)
  timeout_ms = timeout_ms or CITIES_TIMEOUT_MS
  local ok, proc = pcall(vim.system, { 'gc', 'cities', '--json' }, { text = true })
  if not ok then
    return nil, 'cannot run gc (is it on PATH?)'
  end
  local result = proc:wait(timeout_ms)
  -- On timeout Neovim kills gc with SIGKILL and reports exit 124; it returns
  -- nil when even the killed child is not reaped in time.
  if result == nil or (result.code == 124 and result.signal == 9) then
    if result == nil then
      pcall(proc.kill, proc, 9)
    end
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
    cities[#cities + 1] = { name = city.name, path = city.path }
  end
  return cities
end

--- gc's argv for one send; never a shell string.
function M.argv(city, message)
  return { 'gc', '--city', city.path, 'mail', 'send', 'mayor', '-s', message.subject, '-m', message.body, '--notify' }
end

--- Send `buf` to `city`'s mayor. On exit 0 the buffer is cleared (unless it
--- changed while gc ran, so nothing typed meanwhile is lost); otherwise it is
--- left as it was. `on_done(sent)` runs afterwards on the main loop.
function M.send(buf, city, on_done)
  local function done(sent)
    if on_done then
      on_done(sent)
    end
  end
  local message, reason = M.message(buf)
  if not message then
    notify(reason, vim.log.levels.WARN)
    return done(false)
  end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local ok, err = pcall(vim.system, M.argv(city, message), { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local detail = first_lines(result.stderr, 3)
        if detail == '' then
          detail = first_lines(result.stdout, 3)
        end
        notify(('send to %s mayor failed (exit %d)%s'):format(city.name, result.code,
          detail ~= '' and (':\n' .. detail) or ''), vim.log.levels.ERROR)
        return done(false)
      end
      if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_changedtick(buf) ~= tick then
        notify(('sent to %s mayor; the buffer changed meanwhile, so it was not cleared'):format(city.name),
          vim.log.levels.WARN)
        return done(true)
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
      vim.bo[buf].modified = false
      notify(('sent to %s mayor'):format(city.name))
      done(true)
    end)
  end)
  if not ok then
    notify('cannot run gc (is it on PATH?): ' .. tostring(err), vim.log.levels.ERROR)
    return done(false)
  end
end

--- Height and position that keep the picker, border included, above the
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

--- Open the mayor picker for the current buffer.
function M.open()
  local target = vim.api.nvim_get_current_buf()
  local _, reason = M.message(target)
  if reason then
    return notify(reason, vim.log.levels.WARN)
  end
  local cities, err = M.cities()
  if not cities then
    return notify(err, vim.log.levels.ERROR)
  end
  if #cities == 0 then
    return notify('no cities are registered with gc', vim.log.levels.WARN)
  end

  local width = 0
  local items = {}
  for i, city in ipairs(cities) do
    items[i] = ' ' .. city.name .. '  mayor '
    width = math.max(width, vim.fn.strdisplaywidth(items[i]))
  end
  local title = ' mail buffer to '
  width = math.max(width, vim.fn.strdisplaywidth(title) + 2)
  local layout = M.layout(#items, width, vim.o.lines, vim.o.columns, vim.o.cmdheight)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, items)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor', style = 'minimal', border = 'rounded', title = title, title_pos = 'center',
    row = layout.row, col = layout.col, width = layout.width, height = layout.height,
  })
  vim.wo[win].cursorline = true

  local closed = false
  local function close()
    if not closed then
      closed = true
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end
  end
  local function choose()
    local city = cities[vim.api.nvim_win_get_cursor(win)[1]]
    close()
    M.send(target, city)
  end
  local function map(lhs, rhs)
    vim.keymap.set('n', lhs, rhs, { buffer = buf, nowait = true, silent = true })
  end
  map('<CR>', choose)
  map('<Esc>', close)
  map('q', close)
  map('<Down>', 'j')
  map('<Up>', 'k')
  vim.api.nvim_create_autocmd('WinLeave', { buffer = buf, once = true, callback = close })
  return win
end

function M.setup(opts)
  M.config = vim.tbl_extend('force', vim.deepcopy(defaults), opts or {})
  if M.config.keymap then
    vim.keymap.set('n', M.config.keymap, M.open, { desc = 'Mail the buffer to a gc city mayor' })
  end
  vim.api.nvim_create_user_command('GcMail', M.open, { desc = 'Mail the buffer to a gc city mayor', force = true })
end

return M
