-- The one runner for every gc call in gc-mail.nvim.
--
-- Nothing runs at load time. Every call is asynchronous, passes an argument
-- list (never a shell string) and hops back to the main loop before its
-- callback runs. Each caller keeps its own strict decoder for the answer
-- shape it asked for; this module only owns the spawn, the hop, the timeout
-- and the reason a call failed.
local M = {}

-- The first `count` non-empty lines of `text`, joined with newlines: the
-- detail a failed gc puts on stderr.
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

--- Spawns `argv` in the background and calls `on_done(result, err)` on the
--- main loop. `err` is only the reason gc could not be started at all;
--- a finished call, whatever its exit code, gives its vim.system result.
--- Callers that need the exit code itself (the send queue) use this half.
function M.spawn(argv, timeout_ms, on_done)
  local ok, err = pcall(vim.system, argv, { text = true, timeout = timeout_ms }, function(result)
    vim.schedule(function()
      on_done(result)
    end)
  end)
  if not ok then
    vim.schedule(function()
      on_done(nil, 'cannot run gc (is it on PATH?): ' .. tostring(err))
    end)
  end
end

--- Runs `argv` in the background; `on_done(result, err)` runs once, on the
--- main loop. `err` is nil on exit 0, else the reason: a call gc did not
--- answer within `timeout_ms`, or `what` failed with the first lines of
--- stderr (or its exit code when it said nothing). `sep` joins `what`
--- failed to that detail and defaults to ': '; a caller whose failure text
--- has always used another joiner passes it.
function M.run(argv, timeout_ms, what, on_done, sep)
  M.spawn(argv, timeout_ms, function(result, spawn_err)
    if spawn_err then
      return on_done(nil, spawn_err)
    end
    -- On timeout Neovim kills gc (SIGKILL from wait(), SIGTERM from the
    -- timeout option) and reports exit 124; a nil result is a child not
    -- reaped even after the kill.
    if result == nil or (result.code == 124 and (result.signal or 0) ~= 0) then
      return on_done(nil, ('%s did not answer within %g s'):format(what, timeout_ms / 1000))
    end
    if result.code ~= 0 then
      local detail = first_lines(result.stderr, 3)
      return on_done(result,
        what .. ' failed' .. (detail ~= '' and ((sep or ': ') .. detail) or (' (exit ' .. tostring(result.code) .. ')')))
    end
    return on_done(result)
  end)
end

return M
