-- Search of the mail history across cities: :GcMailSearch <text>, and s in the
-- mailbox float and the panel.
--
-- It searches the history cache (gc_mail.history), not gc: case-insensitively,
-- as plain text, in the subject, body, sender and recipient of every message of
-- every cached city. A city whose history is not cached is loaded once first
-- and searched when its answer arrives. Nothing runs at load time; this module
-- is required by the command or the key.
local history = require('gc_mail.history')

local M = {}

local SUBJECT_MAX = 60
local SEARCHING = ' searching… '
local NO_MATCH = ' no mail matches '

local function gc_mail()
  return require('gc_mail')
end

local function notify(message, level)
  vim.notify('gc-mail: ' .. message, level or vim.log.levels.INFO)
end

--- Whether `m` has `needle` (already lower case) in its subject, body, sender
--- or recipient, ignoring case.
function M.matches(m, needle)
  for _, field in ipairs({ m.subject, m.body, m.from, m.to }) do
    if type(field) == 'string' and field:lower():find(needle, 1, true) then
      return true
    end
  end
  return false
end

--- The hits in the cached history of `city`: { city, message, read }, oldest first.
function M.hits(city, text)
  local needle = text:lower()
  local list = {}
  for _, m in ipairs(history.messages(city)) do
    if M.matches(m, needle) then
      list[#list + 1] = { city = city, message = m, read = m.read }
    end
  end
  return list
end

local function who(name)
  return name == 'human' and 'you' or name
end

--- The line of one hit: ` <city>  <from>→<to>  <subject>  <age> `, every part
--- one sanitized line, the subject cut at 60 characters.
function M.line(hit, now)
  local one_line = gc_mail().one_line
  local m = hit.message
  local subject = vim.fn.strcharpart(one_line(m.subject), 0, SUBJECT_MAX)
  return (' %s  %s→%s  %s  %s '):format(one_line(hit.city.name), one_line(who(m.from)), one_line(who(m.to)), subject,
    gc_mail().age(math.max(0, now - m.created)))
end

local function newest_first(a, b)
  if a.message.created ~= b.message.created then
    return a.message.created > b.message.created
  end
  if a.city.name ~= b.city.name then
    return a.city.name < b.city.name
  end
  return a.message.id < b.message.id
end

local DESC = { ['<CR>'] = 'open the message', c = 'open the chat with its correspondent' }

--- Opens the results float for `text` (the whole argument, trimmed; empty is
--- refused with a notice). It shows ` searching… ` at once and fills in as the
--- cities' histories arrive; a city that fails to load is said once, its line
--- says so, and the other cities' hits still show.
function M.run(text)
  text = vim.trim(text or '')
  if text == '' then
    notify('nothing to search for: give some text', vim.log.levels.WARN)
    return nil
  end
  local mailbox = require('gc_mail.mailbox')
  local title = (' gc mail search "%s": <CR> open  c chat  q close '):format(gc_mail().one_line(text))
  local view = { cities = {}, started = {}, hits = {}, failed = {}, rows = {}, pending = 0 }
  local picker

  local function render()
    if not picker or picker.closed() then
      return
    end
    local hits = {}
    for _, list in pairs(view.hits) do
      vim.list_extend(hits, list)
    end
    table.sort(hits, newest_first)
    view.rows = hits
    local lines, now = {}, os.time()
    for i, hit in ipairs(hits) do
      lines[i] = M.line(hit, now)
    end
    for _, city in ipairs(view.cities) do
      if view.failed[city.path] then
        lines[#lines + 1] = (' %s  cannot load the history '):format(gc_mail().one_line(city.name))
      end
    end
    if #lines == 0 then
      lines = { view.pending > 0 and SEARCHING or NO_MATCH }
    end
    picker.set(lines)
  end

  picker = gc_mail().float(title, { SEARCHING }, {
    ['<CR>'] = function(p, row)
      local hit = view.rows[row]
      if hit then
        p.close()
        mailbox.show(hit)
      end
    end,
    c = function(p, row)
      local hit = view.rows[row]
      if not hit then
        return
      end
      p.close()
      mailbox.actions.chat(hit)
    end,
  }, DESC)

  local function search_city(city)
    view.hits[city.path] = M.hits(city, text)
  end

  -- Starts the cities not yet searched: the cached list first, then whatever
  -- the refresh of `gc cities` adds (a city registered since the list was cached).
  local function start(cities)
    for _, city in ipairs(cities) do
      if not view.started[city.path] then
        view.started[city.path] = true
        view.cities[#view.cities + 1] = city
        local entry = history.cache[city.path]
        if entry and entry.loaded_since then
          search_city(city)
        else
          -- Not cached (or only some messages of it are): one load, then the search
          view.pending = view.pending + 1
          history.load(city, function(_, err)
            view.pending = view.pending - 1
            if err then
              view.failed[city.path] = err
              if not picker.closed() then
                notify(err, vim.log.levels.ERROR)
              end
            else
              search_city(city)
            end
            render()
          end)
        end
      end
    end
    render()
  end

  -- The city list is refreshed on every search, never trusted from the cache
  -- alone; the cached list is searched meanwhile.
  local cached = gc_mail().cached_cities() or {}
  view.pending = 1
  start(cached)
  gc_mail().refresh(function(cities, err)
    view.pending = view.pending - 1
    if picker.closed() then
      return
    end
    if not cities then
      if #cached == 0 then
        picker.close()
        return notify(tostring(err), vim.log.levels.ERROR)
      end
      notify('the city list was not refreshed: ' .. tostring(err), vim.log.levels.WARN)
      return render()
    elseif #cities == 0 and #cached == 0 then
      picker.close()
      return notify('no cities are registered with gc', vim.log.levels.WARN)
    end
    start(cities)
  end)
  return picker.win
end

--- Asks for the text (vim.ui.input) and searches it; an empty answer cancels.
--- The s key of the mailbox float and the panel.
function M.prompt()
  vim.ui.input({ prompt = 'gc-mail search: ' }, function(text)
    if text and vim.trim(text) ~= '' then
      M.run(text)
    end
  end)
end

return M
