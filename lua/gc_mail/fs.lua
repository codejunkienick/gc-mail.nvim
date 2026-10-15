-- One small on-disk helper for gc-mail.nvim, shared by the send queue
-- (gc_mail.queue) and the kept message copies (gc_mail.mailbox).
--
-- It owns only the file primitives both sides used to copy: a whole-file
-- read, a directory listing, a private directory, and an atomic write split
-- into stage (a synced temp file) and commit (a rename over the target).
-- Nothing runs at load time; every function is synchronous file work the
-- caller has already decided on, and every failure is nil plus a reason.
local M = {}

local uv = vim.uv

--- The whole text of `path`, or nil and the reason: the open's error, or
--- 'unreadable' when the file opens but cannot be read.
function M.read(path)
  local fd, err = uv.fs_open(path, 'r', 0)
  if not fd then
    return nil, err
  end
  local stat = uv.fs_fstat(fd)
  local data = stat and uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if not data then
    return nil, 'unreadable'
  end
  return data
end

--- Every name in `dir`, in listing order. A directory that does not exist
--- yet is an empty list; any other failure to list it (at the open or part
--- way through) is nil and the reason, never a short list.
function M.list(dir)
  local handle, err = uv.fs_scandir(dir)
  if not handle then
    if tostring(err):find('ENOENT') then
      return {}
    end
    return nil, err
  end
  local names = {}
  while true do
    local name, failure = uv.fs_scandir_next(handle)
    if not name then
      if failure then
        return nil, failure
      end
      return names
    end
    names[#names + 1] = name
  end
end

--- Makes `dir` (and its parents) with mode 0700 when it is not there.
--- true, or nil, the plain 'cannot create <dir>' text and, when mkdir
--- raised, its message as a separate third value. The kept copies show
--- only the plain text; the queue appends the detail.
function M.ensure_dir(dir)
  if vim.fn.isdirectory(dir) == 0 then
    local ok, made = pcall(vim.fn.mkdir, dir, 'p', tonumber('700', 8))
    if not ok or made == 0 then
      if not ok then
        return nil, 'cannot create ' .. dir, tostring(made)
      end
      return nil, 'cannot create ' .. dir
    end
  end
  return true
end

--- Writes `text` in full to a fresh temp file in `dir`, named after `name`,
--- opened 'wx' with mode 0600 and fsynced; returns the temp file's path.
--- Any failure removes the temp file and returns nil and the reason (the
--- write's error, or 'short write').
function M.stage(dir, name, text)
  local temp = ('%s/.%s.%d.%s.tmp'):format(dir, name, uv.os_getpid(), vim.text.hexencode(uv.random(4)))
  local fd, err = uv.fs_open(temp, 'wx', tonumber('600', 8))
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

--- Renames the staged temp file `temp` over `path`; true, or nil and the
--- reason (the temp file is removed either way it fails).
function M.commit(temp, path)
  local ok, err = uv.fs_rename(temp, path)
  if not ok then
    uv.fs_unlink(temp)
    return nil, err
  end
  return true
end

return M
