-- Helper for run.lua: one of two Neovims that add to one queue at the same
-- time. Usage: nvim --headless --clean -n -l add_many.lua <queue dir> <count> <go file>
-- Waits for <go file>, adds <count> messages, prints how many were taken.
local here = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, 'S').source:sub(2)))
vim.opt.runtimepath:prepend(vim.fs.dirname(here))
local dir, n, go = arg[1], tonumber(arg[2]), arg[3]
local queue = require('gc_mail.queue')
queue.configure({ dir = dir, lock_wait_ms = 5000 })
queue.stop()
assert(vim.wait(5000, function()
  return vim.uv.fs_stat(go) ~= nil
end, 1), 'no go file')
local taken = 0
for i = 1, n do
  if queue.add({ name = 'imd-city', path = '/srv/imd-city' }, { subject = 's' .. i, body = 'b' }) then
    taken = taken + 1
  end
end
io.stdout:write(taken .. '\n')
