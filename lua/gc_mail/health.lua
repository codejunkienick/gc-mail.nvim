-- The `:checkhealth gc_mail` report for gc-mail.nvim.
--
-- It reports local facts only and changes nothing: it runs no gc command
-- (every gc call in the plugin is asynchronous, and a health report is
-- synchronous), sends nothing and writes nothing. Each failed fact is an
-- error naming what to fix, in the wording of doc/troubleshooting.md.
-- Nothing runs at load time: the version is checked first and the plugin's
-- own modules are required lazily inside facts(), so the report itself
-- loads even on an older Neovim.
local M = {}

-- Whether `dir` can be used without creating or deleting anything: it is a
-- readable, writable and searchable directory (the queue lists it, so
-- readability matters as much as writability, and listing or creating
-- anything under it needs search permission), or it is missing and the
-- nearest directory above it exists and is writable and searchable, so the
-- first use creates it. Returns true and what to report, or false and the
-- fix.
local function usable(dir)
  if vim.fn.isdirectory(dir) == 1 then
    if vim.uv.fs_scandir(dir) == nil then
      return false, dir .. ' is not readable; check that the directory is readable'
    end
    if vim.fn.filewritable(dir) ~= 2 then
      return false, dir .. ' is not writable; check that the directory is writable'
    end
    if not vim.uv.fs_access(dir, 'X') then
      return false, dir .. ' is not searchable; check that the directory is searchable'
    end
    return true, dir .. ' is usable'
  end
  if vim.fn.getftype(dir) ~= '' then
    return false, dir .. ' is not a directory; move it aside so it can be created'
  end
  local parent = vim.fn.fnamemodify(dir, ':h')
  while parent ~= '' do
    local grandparent = vim.fn.fnamemodify(parent, ':h')
    if vim.fn.isdirectory(parent) == 1 or vim.fn.getftype(parent) ~= '' or grandparent == parent then
      break
    end
    parent = grandparent
  end
  if vim.fn.isdirectory(parent) == 1 then
    if vim.fn.filewritable(parent) ~= 2 then
      return false, dir .. ' cannot be created: ' .. parent .. ' is not writable; make it writable'
    end
    if not vim.uv.fs_access(parent, 'X') then
      return false, dir .. ' cannot be created: ' .. parent .. ' is not searchable; make it searchable'
    end
    return true, dir .. ' does not exist yet; it is created on first use'
  end
  if vim.fn.isdirectory(parent) == 0 and vim.fn.getftype(parent) ~= '' then
    return false, dir .. ' cannot be created: ' .. parent .. ' is in the way; move it aside'
  end
  return false, dir .. ' cannot be created: ' .. parent .. ' is not writable; make it writable'
end

--- The health facts as { { level, text } }, in report order. Gathering them
--- runs no gc command, sends nothing and writes nothing. The version comes
--- first and the plugin's own modules are required lazily only when it
--- passes, so the report itself loads on an older Neovim: there the state,
--- queue and lock facts are skipped, since the modules that compute them
--- need 0.10 to load.
function M.facts()
  local facts = {}
  local supported = vim.fn.has('nvim-0.10') == 1
  if supported then
    local version = vim.version()
    local shown = ('%d.%d.%d'):format(version.major, version.minor, version.patch)
    facts[#facts + 1] = { level = 'ok', text = ('Neovim %s meets the 0.10 minimum'):format(shown) }
  else
    local version = vim.version()
    local shown = ('%d.%d.%d'):format(version.major, version.minor, version.patch)
    facts[#facts + 1] = { level = 'error', text = ('Neovim %s is older than the required 0.10; upgrade Neovim to use gc-mail'):format(shown) }
  end
  if vim.fn.executable('gc') == 1 then
    facts[#facts + 1] = { level = 'ok', text = '`gc` is on PATH' }
  else
    facts[#facts + 1] = { level = 'error', text = '`gc` is not on PATH: put the `gc` binary on `PATH`' }
  end
  if not supported then
    return facts
  end
  local has_main, main = pcall(require, 'gc_mail')
  local state_dir = has_main and main.config.state_dir or nil
  if type(state_dir) ~= 'string' or state_dir == '' then
    facts[#facts + 1] = { level = 'error', text = 'state_dir must be a non-empty string; fix it in setup()' }
  else
    local good, text = usable(state_dir)
    facts[#facts + 1] = { level = good and 'ok' or 'error', text = 'state directory ' .. text }
  end
  local has_queue, queue = pcall(require, 'gc_mail.queue')
  local queue_dir = has_queue and queue.dir() or nil
  if type(queue_dir) ~= 'string' or queue_dir == '' then
    facts[#facts + 1] = { level = 'error', text = 'the send queue has no directory; set one with setup()' }
  else
    local good, text = usable(queue_dir)
    facts[#facts + 1] = { level = good and 'ok' or 'error', text = 'queue directory ' .. text }
  end
  if pcall(require, 'ffi') then
    facts[#facts + 1] = { level = 'ok', text = 'LuaJIT FFI is available, so the queue can lock' }
  else
    facts[#facts + 1] = { level = 'error', text = 'this Neovim has no LuaJIT FFI, so the queue refuses to lock' }
  end
  return facts
end

--- The `:checkhealth gc_mail` report: every fact through vim.health.
function M.check()
  local health = vim.health
  -- The ok/info/warn/error names are newer than report_ok() and friends:
  -- take what this Neovim has, so the report works from 0.10 on.
  local start = health.start or health.report_start
  local say = {
    ok = health.ok or health.report_ok,
    warn = health.warn or health.report_warn,
    error = health.error or health.report_error,
    info = health.info or health.report_info,
  }
  start('gc-mail')
  for _, fact in ipairs(M.facts()) do
    say[fact.level](fact.text)
  end
end

return M
