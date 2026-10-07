# gc-mail.nvim

Mail the current Neovim buffer to a Gas City mayor. `<Space>mm` (or
`:GcMail`) opens a small picker with one line per city registered with the gc
supervisor, at once; `<CR>` puts the buffer in an on-disk send queue, clears
it, and gc sends it in the background. Requires Neovim 0.10 or newer and `gc`
on `PATH`; no other plugins.

## Install

lazy.nvim, from a local checkout of this repository:

```lua
{
  dir = '/path/to/checkout/tools/gc-mail.nvim',
  opts = {},  -- calls require('gc_mail').setup({})
}
```

Without a plugin manager, add the directory to the runtimepath and call setup:

```lua
vim.opt.runtimepath:append('/path/to/checkout/tools/gc-mail.nvim')
require('gc_mail').setup()
```

`:GcMail` and `:GcMailQueue` exist as soon as the directory is on the
runtimepath; `setup()` adds the mapping, and once Neovim has finished starting
it resumes the send queue and preloads the city list with one background
`gc cities --json`. Nothing runs while the plugin loads, so startup time is
unchanged.

## Options

| option | default | meaning |
| --- | --- | --- |
| `keymap` | `'<Space>mm'` | normal-mode mapping that opens the picker; `false` sets none |
| `state_dir` | `stdpath('state') .. '/gc-mail'` | the queue lives in `<state_dir>/queue/` |
| `retry_ms` | `{ 10000, 60000, 300000 }` | delays before each retry of a failed send |

## Use

1. Write the message in any buffer. The first non-empty line, trimmed to 72
   characters, is the subject; the whole buffer is the body.
2. `<Space>mm`. The picker opens at once and lists `<city>  mayor` for each
   city from the cached `gc cities --json`, also when there is only one, while
   the list is fetched again in the background (the newer list replaces it
   when it arrives). Before the first answer it shows `loading…` and fills in.
   `j`/`k` or the arrow keys move, `<CR>` sends, `<Esc>` or `q` cancels.
3. `<CR>` writes the message to the queue and only then empties the buffer
   (marked unmodified, `queued for <city> mayor`); the clear is one undo
   step, so `u` brings the text back. If the queue file cannot be written the
   buffer stays as it was and the error is shown. If the buffer cannot be
   cleared after all, the message stays queued and is sent once, the buffer
   is left as it is and a warning says so: do not send it again.
4. The queue's worker runs, as an argument list (never through a shell):

   ```sh
   gc --city <city path> mail send mayor -s <subject> -m <body> --notify
   ```

   The sender is gc's default outside an agent session (`human`). On exit 0
   it deletes the queue file and shows `sent to <city> mayor`.

An empty or whitespace-only buffer is refused before anything runs, as is a
buffer over 120 KiB (one argument cannot be larger on Linux) and a buffer that
is not `modifiable` (it could not be cleared, and sending it again would mail
it twice).
If `gc cities` does not answer within 10 seconds it is killed. Its output must
be exactly one record listing each city with a name and a path, neither
containing a control character; anything else counts as a failed answer. With
no list yet, the picker then closes and shows why; with a list from an earlier
answer it keeps that list and says once that the refresh failed.

The picker is sized to its cities and never taller than the editor minus the
command line and its border, so it works in a window 10 lines tall; more
cities than fit scroll.

## The send queue

Each message is one JSON file (city name and path, subject, body, created
time, tries, last error) in `<state_dir>/queue/`, by default
`~/.local/state/nvim/gc-mail/queue/`. Every field of a file is checked when
it is read; a file that does not pass is listed as unreadable and never sent,
and `o` shows its raw text.

- One worker sends, one gc process at a time, oldest first: messages to one
  city's mayor arrive in the order you wrote them.
- A failed send keeps its file and shows the first lines of gc's error once,
  then retries after 10 s, 1 min and 5 min (`retry_ms`). After the last try
  fails the message is marked failed and is sent again only from
  `:GcMailQueue`. A gc that does not finish within 2 minutes counts as failed.
- `setup()` resumes the queue after a restart. A message whose gc was still
  running when Neovim quit or crashed is sent again then.
- Trade-off: a crash after gc has delivered a message but before its file is
  deleted sends that message again on the next start. One duplicate is
  preferred to a lost message.

Several Neovims may share one queue. Six rules keep it consistent; the
source states them too, and the tests check each one:

1. **Whole files.** A queue file is only created or replaced whole: written to
   a temp file in the queue directory, fsynced, then renamed into place.
2. **One lock.** Every change to a queue file (adding, claiming, recording a
   send's outcome, putting a claim back, retry, delete, dropping what a gone
   Neovim left) runs under an exclusive `flock` on `queue/.lock`, through
   LuaJIT's FFI, and reads the files it decides on under that same lock.
   Only reading for display takes no lock. The worker never waits for the
   lock, it looks again shortly; adding, `r` and `d` wait up to half a
   second, then refuse as busy (adding keeps the buffer).
3. **Claims.** A message being sent is renamed to
   `<id>.json.sending-<pid>-<token>` under the lock, where the token is made
   once per Neovim and the file's modification time is the time of the claim.
   Nothing but its sender changes it: `r` and `d` act only on an unclaimed
   `<id>.json`, so a retry can never recreate a file another Neovim is
   sending. A claim is live while it is this Neovim's own (pid and token), or
   while its pid is alive and the claim is younger than twice the 2-minute
   send timeout; a sender whose outcome waits on the disk keeps its claim
   young, by setting its time or, when that is refused, by rewriting it whole
   (marked sent if gc delivered it), and says once when it can do neither.
   Every other claim, such as one of a crashed Neovim whose pid a new
   process now has, is put back by the next worker pass, or dropped if it is
   marked sent. A Neovim suspended mid-send for longer than that can so have
   its message sent a second time by another one.
4. **Settled outcomes.** A send ends only when its outcome is on disk: the
   file deleted after success, or rewritten with the new tries and error and
   put back after a failure. If the disk refuses that, the message stays
   claimed, nothing else is sent, the error is shown once and the write is
   tried again after 1 s, 10 s and then every minute. A delivered message
   whose file cannot be deleted is rewritten as sent, so a restart drops it
   instead of sending it again.
5. **Bounded.** The queue holds at most 100 files, failed ones included; past
   that a new message is refused and its buffer stays as it was. The count
   and the rename into the queue happen in one hold of the lock.
6. **Fail closed.** A queue directory that cannot be listed is never read as
   an empty queue: adding refuses, the worker sends nothing and says why once
   (and again when it can read the queue), and `:GcMailQueue` shows the error.

`:GcMailQueue` lists the queued messages (city, subject, age, `pending`,
`sending`, `failed` or `sent, file not removed`, and the last error), one
line each with line breaks and other control characters flattened, in the
same kind of float: `r`
sends one again now (also a failed one), `o` opens its text in a new buffer,
`d` deletes it (not while it is being sent), `<Esc>` or `q` closes.

## Tests

From the repository root, with a fake `gc` (`tests/bin/gc`) first on `PATH`;
the real gc never runs:

```sh
nvim --headless --clean -n -l tools/gc-mail.nvim/tests/run.lua
```

The fake answers `gc cities` after a delay or not at all, and fails a send a
given number of times; the tests point the queue and `XDG_STATE_HOME` at a
scratch directory and use millisecond retry delays. Failing disk calls are
simulated by wrapping `vim.uv` functions; the lock rule is checked by probing
the lock at every change to a queue file, and `tests/add_many.lua` is a second
Neovim that adds to the same queue at the same time. It prints one line per
test and exits 0 when all pass.
