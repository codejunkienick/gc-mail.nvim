# gc-mail.nvim

Mail the current Neovim buffer to a Gas City mayor, and read the mail sent to
you. `<Space>mm` (or `:GcMail`) opens a small picker with one line per city
registered with the gc supervisor, at once; `<CR>` puts the buffer in an
on-disk send queue, clears it, and gc sends it in the background. `<Space>mi`
(or `:GcMailbox`) opens the mailbox: the mail addressed to you (`human`) in
every city, to open, reply to, mark, archive or delete; `<Space>mp` (or
`:GcMailPanel`) docks the same mailbox in a split below the current window
and keeps it current while you edit. Requires Neovim 0.10 or newer and `gc`
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

`:GcMail`, `:GcMailQueue`, `:GcMailbox` and `:GcMailPanel` exist as soon as the directory is
on the runtimepath; `setup()` adds the mappings, and once Neovim has finished
starting it resumes the send queue and preloads the city list with one
background `gc cities --json`. Nothing runs while the plugin loads, so startup
time is unchanged; the mailbox lists mail only when you open it.

## Options

| option | default | meaning |
| --- | --- | --- |
| `keymap` | `'<Space>mm'` | normal-mode mapping that opens the picker; `false` sets none |
| `state_dir` | `stdpath('state') .. '/gc-mail'` | the queue lives in `<state_dir>/queue/` |
| `retry_ms` | `{ 10000, 60000, 300000 }` | delays before each retry of a failed send |
| `mailbox_keymap` | `'<Space>mi'` | normal-mode mapping that opens the mailbox; `false` sets none |
| `subject_prefix` | `''` | text put before the subject of every message the plugin sends, e.g. `'[Nick] '` |
| `subject_suffix` | `''` | text put after it, e.g. `' (nvim)'` |
| `check_ms` | `false` | `false`: no timer. A number of ms, at least `60000`: the new-mail check below |
| `panel_keymap` | `'<Space>mp'` | normal-mode mapping that opens or closes the mail panel; `false` sets none |
| `panel_height` | `10` | rows of the mail panel |
| `panel_poll_ms` | `60000` | while the panel is open, every city is listed again this often (ms, at least `15000`) |
| `markdown` | `true` | the opened message and the thread are markdown buffers; `false` keeps the plain text layout |

`setup()` refuses (raises an error) a prefix or suffix with a control
character, the two together over 40 characters, a `check_ms` that is
neither `false` nor at least a minute, a `panel_poll_ms` under 15 seconds and
a `panel_height` that is not a whole number of at least 1, and a `markdown` that
is not `true` or `false`.

## Use

1. Write the message in any buffer. The first non-empty line, trimmed to 72
   characters, is the subject; the whole buffer is the body. With
   `subject_prefix` or `subject_suffix` set, the subject is labelled with
   them exactly once (a copy of either already in the line, as in a reply to
   a labelled message, is taken out first), and the label counts in the 72
   characters. gc files order and script mail as `human` too, so the label
   is what tells a mayor your own mail apart.
2. `<Space>mm`. The picker opens at once and lists `<city>  mayor` for each
   city from the cached `gc cities --json`, also when there is only one, while
   the list is fetched again in the background (the newer list replaces it
   when it arrives). Before the first answer it shows `loading…` and fills in.
   `j`/`k` or the arrow keys move, `<CR>` sends, `<Esc>` or `q` cancels.
3. `<CR>` writes the message to the queue and only then empties the buffer
   (marked unmodified, `queued for <city> mayor: <subject>`, the subject as
   sent, label included); the clear is one undo
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

## The mailbox

`<Space>mi` (or `:GcMailbox`) opens a float like the picker's, at once: one
line per message, newest first, across every city of the cached
`gc cities --json` list:

```text
 ● imd-city  mayor  Re: mailbox for gc-mail  5m
   imd-city  mayor  Deploy plan accepted  2h
```

`●` marks unread mail; the columns are city, sender, subject and age. The
float's title is the key hint. While it is open, the plugin runs one

```sh
gc --city <city path> mail inbox human --json
```

per city in the background (10 s timeout, argument lists, never a shell); a
city the refreshed city list adds is listed once when it arrives, and `R`
lists every city again. A failing gc, one that does not answer, or an answer
the decoder refuses (I1) is shown once as an error and changes nothing on
screen.

Two invariants hold every gc answer to what it may change:

- **I1, decode.** Every `gc mail <command> --json` answer the mailbox acts on
  (`inbox`, `thread`, `read`, `count`, `mark-read`, `mark-unread`, `archive`,
  `delete`) passes the one decoder of its shape before anything reads it. The
  decoder requires every field the plugin reads, with its type, as
  `gc --json-schema=result mail <command>` documents it: each message's `id`,
  `from`, `to`, `subject`, `body`, `created_at` and `read`; message ids and
  thread ids that match the whole id gc prints (`ab-wisp-1x2y3z`, `ab-1x2y3z`,
  `thread-` and hex); counts that are non-negative integers; an action answer
  that names its command (`mail.archive`), its action and the message; a
  thread answer whose `thread_id` is a `thread-` id (the one asked for, when
  a thread was asked for). The id a call puts in its argument list passes
  the same check first, so nothing that could read as an option ever reaches
  gc.
- **I2, apply.** An answer that changes what the mailbox shows or keeps is
  applied only while it is still current for its message. An action answer
  (read, mark read or unread, archive, delete) is dropped when a later action
  on the same message started after its call; an inbox answer leaves out
  every message acted on since its call started. A late answer therefore
  never brings back a message you archived or deleted, never recreates its
  kept copy, and never undoes a later mark.

| key | action | gc |
| --- | --- | --- |
| `<CR>` | open the message in a new window: headers, then the body | `mail read <id>` (marks it read; nothing for mail already read) |
| `r` | reply: a new buffer with `Re: <subject>`; `<Space>mm` (or `:GcMail`) in it queues the reply | `mail reply <id> -s <subject> -m <body> --notify`, from the send queue |
| `t` | the thread, oldest first, in a new window | `mail thread <thread id>` |
| `m` | mark read | `mail mark-read <id>` |
| `u` | mark unread | `mail mark-unread <id>` |
| `a` | archive | `mail archive <id>` |
| `d` | delete, after a Yes/No question | `mail delete <id>` |
| `R` | list every city again (ignored while a listing is still running) | `mail inbox human`, once per city |
| `q`, `<Esc>` | close | |

Each action names only the message under the cursor and is shown as an error
when gc refuses it. The opened message has the same keys (`r`, `t`, `u`, `a`,
`d`, and `q` to close the window).

**Markdown views.** With `markdown = true` (the default) the opened message
and the thread are scratch buffers with `filetype=markdown`, so a markdown
renderer you run (render-markdown.nvim and the like) draws them; with none,
Neovim's own markdown highlighting still applies. The plugin requires no
renderer. A message reads

```markdown
# Re: mailbox for gc-mail

**From** mayor · **To** human · **City** imd-city · 2026-10-07T12:00:00Z

`ic-wisp-a1` · thread `thread-0a1b2c3d4e5f` · r reply  t thread  u unread  a archive  d delete  q close · Read mail stays in this mailbox …

---

the body, exactly as gc stores it
```

and a thread is `# <subject of the first message>`, then for each message,
oldest first, `## <sender> · <date>`, its body, and a `---` rule between
messages. In header values (subject, sender, recipient, city, date) each of
the characters `` \ ` * _ [ ] < > # | `` gets a backslash, so they never read
as markup; a body is shown verbatim, so its own markdown renders as written.
The buffers stay `nofile`, not modifiable and wiped when hidden, with the
same keys and the same `gc-mail://` names. `markdown = false` gives the
earlier plain layout (`From:`, `To:`, … lines) and no filetype.

**How long read mail stays.** `gc mail inbox` lists unread mail only, and gc
1.4.1 has no command that lists read mail. gc also closes read mail by itself:
its nudge-mail-sweep (a controller watchdog every 5 minutes, and the core
`nudge-mail-sweep` order) closes every read message sent more than an hour
ago, and `gc mail thread` then leaves it out. So the mailbox keeps a copy of
every message you open or mark read here: one JSON file per message in
`<state_dir>/mailbox/` (written whole: temp file, fsync, rename), listed until
you archive or delete it in the mailbox, across restarts. A mayor's answer
therefore stays in the mailbox after you read it. Mail read elsewhere (with
`gc mail read` in a terminal) is not copied and leaves the mailbox when gc
closes it. Marking a kept message unread marks it unread in gc and in the
copy.

**Replies** go through the send queue like any message: the reply is on disk
before its buffer is cleared, failed sends are retried, `:GcMailQueue` lists
it as `<city> <sender>`, and the reply buffer stops being one once queued.

**New-mail check.** Off by default: no timer runs. With `check_ms` set (at
least 60000), every `check_ms` while Neovim has focus (`FocusGained` and
`FocusLost`) it runs one `gc --city <path> mail count human --json` per city
and says `<n> unread mail in <city>` when a city's unread count grows.

## The mail panel

`<Space>mp` (or `:GcMailPanel`) opens the mailbox as a docked list, like a
diagnostics list: a horizontal split of `panel_height` rows (fixed height)
right below the current window, with the same lines as the float. The same
key closes it. Opening it, refreshing it or a mail arriving never moves the
cursor or the current window, so you keep typing where you were; there is at
most one panel per tab page, in its own unlisted scratch buffer with
filetype `gcmail-panel` and the key hint in its status line.

```text
the buffer you are editing
~
notes.md
 ● imd-city  mayor  Re: mail panel  2m
   imd-city  mayor  Deploy plan accepted  1h

 gc mail: <CR> open  r reply  t thread  m read  u unread  a archive  d delete  R refresh  q close
```

It is a second view of the mailbox, not a copy: the same `gc mail inbox`
listing, I1 and I2, kept copies and actions, so an action taken in the panel
or in the float shows in both. The keys are the mailbox's; `<CR>`, `r` and
`t` open their window above the panel, never inside it, and `q` closes the
panel. The panel's cursor stays on the message it was on when the list
changes.

**Live updates without polling.** gc appends one JSON line per event to
`<city path>/.gc/events.jsonl`, among them `mail.sent`, `mail.read`,
`mail.marked_read`, `mail.archived` and `mail.deleted`. While the panel is
open, the plugin watches each listed city's file (`vim.uv` fs_event, inotify
on Linux) and, on a change, reads only the bytes appended since its last read
(more than 1 MiB at once is simply a refresh). A line whose `type` starts
with `mail.` lists that city again, about 500 ms after the first such line
(a burst is one call) and never with a second inbox call for the city while
one runs (then once more after it). A line that is not JSON, or has no
`type`, is ignored. When gc rotates the file (renames it and starts a new
one with an `events.rotated` line) or it is recreated, the file now at the
path is watched instead and the city is listed once, since what was appended
just before the rotation was not read.

**Fallback.** Every `panel_poll_ms` (default one minute) while the panel is
open, every city is listed again and the kept copies are read again, also for
a city whose events file is missing or cannot be watched; each tick tries to
watch such a file again, and refreshes the city list.

Nothing runs while the panel is closed: closing the last one (the key, `q`,
`:close`, or closing its tab page) stops every watcher and timer, and an
answer that arrives later only updates the mailbox state.

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

The fake answers `gc cities` after a delay or not at all, fails a send a
given number of times, and answers each mailbox command (`inbox`, `count`,
`read`, `mark-read`, `mark-unread`, `thread`, `archive`, `delete`) from a
fixture per command and city, failing, hanging, answering late or printing
malformed JSON on request (I1 and I2 each have their own tests). The panel
tests give each city a real temporary directory and append lines to its
`.gc/events.jsonl` (mail, other and malformed events, half lines, rotation,
a missing file), counting the inbox calls the fake answers. The tests point the queue and `XDG_STATE_HOME` at a
scratch directory and use millisecond retry delays. Failing disk calls are
simulated by wrapping `vim.uv` functions; the lock rule is checked by probing
the lock at every change to a queue file, and `tests/add_many.lua` is a second
Neovim that adds to the same queue at the same time. It prints one line per
test and exits 0 when all pass.
