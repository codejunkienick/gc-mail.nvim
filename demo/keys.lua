-- The key overlay of the recording demo: the last few keys in a small float
-- at the bottom right, each gone after about 1.5 s, and a compact caption
-- banner at the top right above it. Only demo/init.lua loads it. `format()`
-- is pure so the tests cover it; the rest needs a UI.
local M = {}

M.KEY_MS = 1500
M.SHOWN = 6
M.MAX = 40
M.CAPTION_MS = 9000

-- Keys that are not keystrokes of the person at the keyboard.
local IGNORED = { 'Mouse', 'ScrollWheel', 'Drag', 'Release', 'Focus', 'Cursor', 'Paste', 'Ignore' }

local function ignored(label)
  for _, word in ipairs(IGNORED) do
    if label:find(word, 1, true) then
      return true
    end
  end
  return false
end

--- The labels of the keys in `raw` (one or several keys as Neovim typed
--- them): `<Space>`, `<CR>`, `<Esc>`, `<C-w>`, a letter as itself. A mapped
--- sequence such as <Space>mp can arrive as one string. Keys that are not
--- shown (mouse, focus) leave no label.
function M.labels(raw)
  local text = vim.fn.keytrans(raw)
  local list, i = {}, 1
  while i <= #text do
    local label = text:match('^<[^<>]+>', i) or text:match('^[%z\1-\127\194-\244][\128-\191]*', i)
    i = i + #label
    if label == '<lt>' then
      label = '<'
    end
    -- <C-W> is how keytrans spells a control chord; the keyboard shows <C-w>.
    label = label:gsub('^<C%-(%u)>$', function(c)
      return '<C-' .. c:lower() .. '>'
    end)
    if not ignored(label) then
      list[#list + 1] = label
    end
  end
  return list
end

-- The character a label stands for when typed as text, or nil for a key.
local function character(label)
  if label == '<Space>' then
    return ' '
  end
  if vim.fn.strchars(label) == 1 and not label:find('^%c') and label:byte() ~= 127 then
    return label
  end
  return nil
end

--- The text of `keys`, oldest first, for the overlay. An entry is a raw key
--- string (or several, as typed), or { key = raw, text = true } for keys
--- typed as text (insert mode): a run of plain characters is shown as the text
--- it is, the other keys as labels, all separated by one space. Longer than
--- `max` characters: the oldest part is cut and a `…` leads.
function M.format(keys, max)
  max = max or M.MAX
  local parts = {}
  local run
  local function flush()
    if run then
      parts[#parts + 1] = table.concat(run)
      run = nil
    end
  end
  for _, entry in ipairs(keys or {}) do
    local raw, text = entry, false
    if type(entry) == 'table' then
      raw, text = entry.key, entry.text
    end
    for _, label in ipairs(M.labels(raw)) do
      local char = text and character(label)
      if char then
        run = run or {}
        run[#run + 1] = char
      else
        flush()
        parts[#parts + 1] = label
      end
    end
  end
  flush()
  local line = table.concat(parts, ' ')
  if vim.fn.strchars(line) > max then
    line = '…' .. vim.fn.strcharpart(line, vim.fn.strchars(line) - (max - 1))
  end
  return line
end

-- ---- the overlay -------------------------------------------------------------

local uv = vim.uv
local state = { keys = {}, floats = {}, ns = nil }

local function float(name)
  local f = state.floats[name]
  if not f then
    f = {}
    state.floats[name] = f
  end
  return f
end

local function close(f)
  if f.win and vim.api.nvim_win_is_valid(f.win) then
    vim.api.nvim_win_close(f.win, true)
  end
  f.win = nil
end

-- Shows `text` in the float `f`, anchored to the bottom right above the
-- command line (and `lift` rows higher).
local function show(f, text, lift, hl)
  local width = math.max(1, vim.fn.strdisplaywidth(text))
  if not (f.buf and vim.api.nvim_buf_is_valid(f.buf)) then
    f.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[f.buf].bufhidden = 'hide'
  end
  vim.api.nvim_buf_set_lines(f.buf, 0, -1, false, { text })
  local config = {
    relative = 'editor', anchor = 'SE', row = vim.o.lines - vim.o.cmdheight - lift, col = vim.o.columns,
    width = width, height = 1, focusable = false, style = 'minimal', zindex = 250, noautocmd = true,
  }
  if f.win and vim.api.nvim_win_is_valid(f.win) then
    vim.api.nvim_win_set_config(f.win, config)
  else
    f.win = vim.api.nvim_open_win(f.buf, false, config)
  end
  vim.wo[f.win].winhighlight = 'Normal:' .. hl .. ',NormalFloat:' .. hl
  return f.win
end

local function expire()
  local now = uv.now()
  state.keys = vim.tbl_filter(function(k)
    return now - k.at < M.KEY_MS
  end, state.keys)
end

local show_caption

local function redraw()
  if vim.in_fast_event() then
    return vim.schedule(redraw)
  end
  expire()
  local keys = float('keys')
  if #state.keys == 0 then
    close(keys)
  else
    local shown = vim.list_slice(state.keys, math.max(1, #state.keys - M.SHOWN + 1))
    local entries = vim.tbl_map(function(k)
      return { key = k.raw, text = k.text }
    end, shown)
    local text = M.format(entries)
    if text ~= '' then
      local win = show(keys, ' ' .. text .. ' ', 0, 'GcDemoKeys')
      -- The newest key fades over its last half second.
      local age = uv.now() - shown[#shown].at
      vim.wo[win].winblend = age > M.KEY_MS - 500 and math.min(100, math.floor((age - (M.KEY_MS - 500)) / 5)) or 0
    else
      close(keys)
    end
  end
  if state.caption then
    show_caption(state.caption)
  else
    close(float('caption'))
  end
  if #state.keys == 0 and not state.caption and state.timer then
    state.timer:stop()
  end
end

local function tick()
  if not state.timer then
    state.timer = uv.new_timer()
  end
  if not state.timer:is_active() then
    state.timer:start(100, 100, vim.schedule_wrap(redraw))
  end
end

--- Shows `text` as the caption above the keys until the next `say`, or for
--- `ms` (default M.CAPTION_MS); an empty text clears it. Called from the tour
--- through the Neovim socket, so a caption is never a typed key.
function M.say(text, ms)
  state.caption = (text and text ~= '') and text:gsub('[%c]', ' ') or nil
  state.caption_at = uv.now()
  state.caption_ms = ms or M.CAPTION_MS
  vim.schedule(function()
    redraw()
    if state.caption then
      tick()
      local mine = state.caption_at
      vim.defer_fn(function()
        if state.caption_at == mine and state.caption then
          state.caption = nil
          redraw()
        end
      end, state.caption_ms)
    end
  end)
  return ''
end

-- Shows `text` as a compact caption banner at the top right: a bordered
-- box about half the screen wide and two lines high, with one space of
-- padding, legible in the 960 px recording. The key overlay stays the
-- small float at the bottom right.
function show_caption(text)
  local caption = float('caption')
  local cols = vim.o.columns
  local wide = math.min(cols - 2, math.max(vim.fn.strdisplaywidth(text) + 8, math.floor(cols * 0.7)))
  local width = math.max(1, math.floor(wide * 0.75))
  if vim.fn.strdisplaywidth(text) > width then
    text = '…' .. vim.fn.strcharpart(text, vim.fn.strchars(text) - (width - 1))
  end
  local padded = ' ' .. text .. ' '
  local line = padded .. string.rep(' ', math.max(0, width - vim.fn.strdisplaywidth(padded)))
  if not (caption.buf and vim.api.nvim_buf_is_valid(caption.buf)) then
    caption.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[caption.buf].bufhidden = 'hide'
  end
  vim.api.nvim_buf_set_lines(caption.buf, 0, -1, false, { line, '' })
  local config = {
    relative = 'editor', row = 1, col = math.max(0, cols - width - 2),
    width = width, height = 2, focusable = false, style = 'minimal', border = 'rounded', zindex = 250,
    noautocmd = true,
  }
  if caption.win and vim.api.nvim_win_is_valid(caption.win) then
    vim.api.nvim_win_set_config(caption.win, config)
  else
    caption.win = vim.api.nvim_open_win(caption.buf, false, config)
  end
  vim.wo[caption.win].winhighlight = 'Normal:GcDemoCaption,NormalFloat:GcDemoCaption,FloatBorder:GcDemoCaption'
  vim.wo[caption.win].wrap = false
end

local function highlights()
  vim.api.nvim_set_hl(0, 'GcDemoKeys', { fg = '#ffffff', bg = '#2f6f4f', bold = true })
  vim.api.nvim_set_hl(0, 'GcDemoCaption', { fg = '#ffffff', bg = '#0b3d62', bold = true })
end

--- Starts the overlay: records each typed key.
function M.start()
  if state.ns then
    return
  end
  highlights()
  vim.api.nvim_create_autocmd('ColorScheme', { callback = highlights })
  state.ns = vim.on_key(function(_, typed)
    if typed == nil or typed == '' then
      return
    end
    local mode = vim.api.nvim_get_mode().mode
    local insert = mode:sub(1, 1) == 'i' or mode:sub(1, 1) == 'R'
    if #M.labels(typed) == 0 then
      return
    end
    state.keys[#state.keys + 1] = { raw = typed, text = insert, at = uv.now() }
    vim.schedule(function()
      redraw()
      tick()
    end)
  end, nil, {})
end

-- For the tests: forget what is shown.
function M.reset()
  state.keys, state.caption = {}, nil
  close(float('keys'))
  close(float('caption'))
end

M._state = state

return M
