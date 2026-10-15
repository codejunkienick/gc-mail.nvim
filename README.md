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
background `gc cities --json`. Unless `watch = false`, it also starts the
background watch below. Nothing runs while the plugin loads, so startup time is
unchanged; the mailbox lists mail only when you open it.

## Options

| option | default | meaning |
| --- | --- | --- |
| `keymap` | `'<Space>mm'` | normal-mode mapping that opens the picker; `false` sets none |
| `state_dir` | `stdpath('state') .. '/gc-mail'` | the queue lives in `<state_dir>/queue/` |
| `retry_ms` | `{ 10000, 60000, 300000 }` | delays before each retry of a failed send |
| `mailbox_keymap` | `'<Space>mi'` | normal-mode mapping that opens the mailbox; `false` sets none |
| `subject_prefix` | `''` | text put before the subject of every message the plugin sends, e.g. `'[Nick] '` |
| `subject_suffix` | `''` | text put after it, e.g. `' (nvim)'` |
| `check_ms` | `false` | `false`: no timer. A number of ms, at least `60000`: the older new-mail check below; use `watch` instead |
| `watch` | `true` | the background watch below, on without any configuration; `false` turns it off |
| `watch_resync_ms` | `300000` | while the watch runs, every city's unread mail is counted again this often (ms, at least `60000`) |
| `panel_keymap` | `'<Space>mp'` | normal-mode mapping that opens or closes the mail panel; `false` sets none |
| `panel_height` | `10` | rows of the mail panel |
| `panel_poll_ms` | `60000` | while the panel is open, every city is listed again this often (ms, at least `15000`) |
| `preview` | `true` | the mailbox float and the panel show the body of the message under the cursor in a pane beside the list; `false` opens them with the pane hidden (`p` shows it) |
| `events_rearm_ms` | `60000` | how often to retry watching a missing or refused event log (ms, at least `15000`) |
| `history_days` | `14` | how many days of mail history to load from the bead store; a whole number of at least 1 |
| `markdown` | `true` | the opened message and the thread are markdown buffers; `false` keeps the plain text layout |
| `chat_keymap` | `'<Space>mc'` | normal-mode mapping that opens the last chat; `false` sets none |
| `chats_keymap` | `'<Space>ml'` | normal-mode mapping that opens the conversations list; `false` sets none |
| `chat_width` | `60` | columns of the chat window (whole number of at least 20) |
| `chat_compose_height` | `3` | rows of the chat compose box (whole number of at least 1) |
| `chat_send_keys` | `{ '<Space>ms' }` | keys mapped in normal mode of the compose box that send the message; `false` maps none |
| `chat_mark_read` | `true` | `true`: unread mail to human in the rendered conversation is marked read when viewed; `false` marks nothing |
| `chat_poll_ms` | `60000` | while a chat is open, its city's history is loaded again this often (ms, at least `15000`) |

`setup()` refuses (raises an error) a prefix or suffix with a control
character, the two together over 40 characters, a `check_ms` that is
neither `false` nor at least a minute, a `watch` that is not `true` or
`false`, a `watch_resync_ms` under a minute, a `panel_poll_ms` under 15 seconds,
an `events_rearm_ms` under 15 seconds, a `preview` that is not `true` or
`false`, a `panel_height` that is not a
whole number of at least 1, a `history_days` that is not a whole number
of at least 1, a `markdown` that is not `true` or `false`, a `chat_width`
under 20, a `chat_compose_height` under 1, a `chat_send_keys` that is neither
`false` nor a list of key mapping strings, a `chat_mark_read` that is not
`true` or `false`, a `chat_keymap` or `chats_keymap` that is neither `false` nor a
non-empty string, and a `chat_poll_ms` under 15 seconds.

## Use

1. Write the message in any buffer. The first non-empty line, trimmed to 72
   characters, is the subject; the whole buffer is the body. With
   `subject_prefix` or `subject_suffix` set, the subject is labelled with
   them exactly once (a copy of either already in the line, as in a reply to
   a labelled message, is taken out first), and the label counts in the 72
   characters. gc files order and script mail as `human` too, so the label
   is what tells a mayor your own mail apart.
2. `<Space>mm` (or `:GcMail [to]`). The picker opens at once: `<Space>mm` or
   `:GcMail` lists `<city>  mayor` for each city from the cached `gc cities --json`;
   `:GcMail <to>` (e.g. `:GcMail planner`) opens with the title
   `mail buffer to <to> in` and lists `<city>  <to>` per city. The list is
   fetched again in the background (the newer list replaces it when it
   arrives). Before the first answer it shows `loading…` and fills in.
   `j`/`k` or the arrow keys move, `<CR>` sends, `<Esc>` or `q` cancels.
3. `<CR>` writes the message to the queue and only then empties the buffer
   (marked unmodified, `queued for <city> <to>: <subject>`, the subject as
   sent, label included); the clear is one undo
   step, so `u` brings the text back. If the queue file cannot be written the
   buffer stays as it was and the error is shown. If the buffer cannot be
   cleared after all, the message stays queued and is sent once, the buffer
   is left as it is and a warning says so: do not send it again.
4. The queue's worker runs, as an argument list (never through a shell):

   ```sh
   gc --city <city path> mail send <to> -s <subject> -m <body> --notify
   ```

   `<to>` is the chosen recipient, or `mayor` by default. The sender is gc's
   default outside an agent session (`human`). On exit 0 it deletes the queue
   file and shows `sent to <city> <to>`.

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
x   imd-city  mayor  Deploy plan accepted  2h
```

The first column is `x` on a marked message (see below); `●` marks unread
mail; then city, sender, subject and age. The float's title is the key hint. While it is open, the plugin runs one

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
  that names its command (`mail.archive`), its action and every message it
  was asked about (in `ids`); a thread answer whose `thread_id` is a
  `thread-` id (the one asked for, when a thread was asked for). The id a call puts in its argument list passes
  the same check first, so nothing that could read as an option ever reaches
  gc.
- **I2, apply.** An answer that changes what the mailbox shows or keeps is
  applied only while it is still current for its message. An action answer
  (read, mark read or unread, archive, delete) is dropped when a later action
  on the same message started after its call; an inbox answer leaves every
  message acted on since its call started as the mailbox has it, and in
  all-mail mode a history load leaves out every message an action answer was
  applied to since the load started. A late answer therefore
  never brings back a message you archived or deleted, never recreates its
  kept copy, never undoes a later mark, and never drops a message whose
  action then fails.

| key | action | gc |
| --- | --- | --- |
| `<CR>` | open the message in a new window: headers, then the body | `mail read <id>` (marks it read; nothing for mail already read) |
| `r` | reply: a new buffer with `Re: <subject>`; `<Space>mm` (or `:GcMail`) in it queues the reply | `mail reply <id> -s <subject> -m <body> --notify`, from the send queue |
| `t` | the thread, oldest first, in a new window | load from the bead store (`gc bd list`); `mail thread <id>` if no thread id |
| `c` | open the chat with the message's sender in its city (with the recipient, for a message from you); the float closes first | none (the chat loads its own history) |
| `s` | search the mail history of every city (asks for the text; see [Search](#search)) | none until a city's history is not cached, then one `bd list` |
| `x` | mark or unmark the message under the cursor | |
| `X` | clear every mark | |
| `m` | mark read | `mail mark-read <id>`, one call per message |
| `u` | mark unread | `mail mark-unread <id>`, one call per message |
| `a` | archive | `mail archive <id> [<id> ...]`, one call per city |
| `d` | delete, after a Yes/No question | `mail delete <id> [<id> ...]`, one call per city |
| `H` | all mail on or off | `bd list` (the history), once per city the first time |
| `p` | show or hide the preview pane for this view | none |
| `R` | list every city again (ignored while a listing is still running); in all-mail mode the history too | `mail inbox human`, once per city |
| `q`, `<Esc>` | close | |

`m`, `u`, `a` and `d` act on the lines of a visual selection (`V`, then the
key), else on every marked message, else on the message under the cursor.
Each refusal from gc is shown as an error once and never retried. The opened
message has the same keys (`r`, `t`, `c`, `u`, `a`, `d`, and `q` to close the
window); `c` opens the chat beside the view and keeps it.

**All mail and bulk actions.** `H` switches the mailbox (both the float and
the panel: one switch) to all mail: besides the unread inbox and the kept
copies, every message to you in the mail history (`gc bd list`, the last
`history_days` days, read and closed mail included). The first `H` loads the
history of every known city in the background, and a city the city list adds
later (or that arrives after an early `H`) loads it when it is first listed;
a city whose load fails is said once and the list shows what the mailbox has. The title starts with
` all mail ` while it is on, and a closed message shows `×` where an unread
one shows `●`. `H` again lists the usual set.

`x` marks the message under the cursor and `X` clears every mark; the marks
belong to the mailbox, so both views show them, and a mark goes away when its
message leaves the list. With several messages picked (a selection or marks),
`a` and `d` run one `gc mail archive|delete <id> <id> ...` per city (`d` asks
once, `Delete N messages?`); the answer must name every id asked for (I1),
or nothing changes and the city's ids are said once. On success each message
leaves the list on its own (I2: a later action on one of them drops only
that one). `m` and `u` run one `gc mail mark-read|mark-unread <id>` per
message, in list order, one at a time, each with its own I2 clock; a
message whose action applied loses its mark. A message listed only from the
history is archived or deleted through gc the same way; gc refusing it (a
closed message) is said and the line stays. A message archived or deleted
here leaves all mail until the history is loaded again (`R`), which then
lists it closed.

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
messages. Closed messages carry ` (closed)` in the header. In header values (subject, sender, recipient, city, date) each of
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

**New-mail check.** The older, polling way, off by default: no timer runs.
With `check_ms` set (at least 60000), every `check_ms` while Neovim has focus
(`FocusGained` and `FocusLost`) it runs one
`gc --city <path> mail count human --json` per city and says
`<n> unread mail in <city>` when a city's unread count grows. The background
watch below does this without polling and also keeps the count for a
statusline: `watch` is the one to use. The two can run together.

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

 gc mail: <CR> open  r reply  t thread  c chat  s search  x mark  m read  u unread  a archive  d delete  H all  p preview  R refresh  q close
```

It is a second view of the mailbox, not a copy: the same `gc mail inbox`
listing, I1 and I2, kept copies and actions, so an action taken in the panel
or in the float shows in both, marks and all-mail mode too. The keys are the
mailbox's (`p` shows or hides its preview pane); `<CR>`, `r` and `t` open
their window above the panel, never inside it; `c` opens the chat beside the
window the panel is docked under, and the panel stays; `q` closes the panel.
The panel's cursor stays on the message it was on when the list
changes.

**Live updates without polling.** A shared event-log watcher
(`lua/gc_mail/events.lua`, `require('gc_mail.events')`) watches each listed
city's `<city path>/.gc/events.jsonl` (`vim.uv` fs_event, inotify on Linux)
from its current end and decodes `mail.*` events (`mail.sent`, `mail.read`,
`mail.marked_read`, `mail.archived` and `mail.deleted`), pushing them to live
views (the panel, the chat and the background watch) without each view
watching the files itself. A missing file or refused watch is retried every
`events_rearm_ms` (default 60000 ms, minimum 15000 ms). On a change, only the
bytes appended since its last read are read (more than 1 MiB at once is
reported as `overflow`, triggering a refresh). A line whose `type` starts with
`mail.` lists that city again, about 500 ms after the first such line (a burst
is one call) and never with a second inbox call for the city while one runs
(then once more after it). A line that is not JSON, or has no `type`, is
ignored. When gc rotates the file (renames it and starts a new one with an
`events.rotated` line) or it is recreated, the file now at the path is watched
instead and reported as `rotated`, listing the city once.

**Fallback.** Every `panel_poll_ms` (default one minute) while the panel is
open, every city is listed again and the kept copies are read again, also for
a city whose events file is missing or cannot be watched; each tick tries to
watch such a file again, and refreshes the city list.

Nothing runs while the panel is closed: closing the last one (the key, `q`,
`:close`, or closing its tab page) stops every watcher and timer, and an
answer that arrives later only updates the mailbox state.

## Preview

Moving onto a message in the mailbox float or the panel shows just its body
in a pane beside the list: no `From`, `To`, city or thread lines and no
subject, which the list line already shows. It comes from the message the
list holds in memory, so it is instant, runs no gc command and never marks
anything read; the body is drawn the way the opened message draws it, and an
empty body shows one dim `(no content)` line. A cursor on a line that is not
a message (a header, an empty list) clears the pane, and a refresh or a live
mail event redraws it for whatever is under the cursor then. The pane
follows the cursor after about 50 ms, so holding `j` does not redraw on
every line.

In the float the pane is a second float right of the list at the same top,
running down to the bottom of the editor, as wide as the rest of the editor less a one-column margin (at
least 30 columns); in an editor too narrow for that it goes below the list
when 3 rows fit, else stays hidden. In the panel it is a vertical split in
the panel's row, about half its width (at least 30 columns; hidden when the
list would keep under 20). Focus never moves into it, and it closes with
its list. `p` in either list shows or hides it until that list closes;
`preview = false` opens lists with it hidden. The pane buffer is
`gc-mail://preview`, `nofile` and not modifiable, with `filetype=markdown`
when `markdown` is on. A body that cannot be drawn is reported once and
clears the pane.

## Background watch

On by default: after Neovim has finished starting, the plugin watches every
city's event log (the shared watcher above) and needs no timer to see mail.
`watch = false` in `setup()` turns it off, also while Neovim runs (a second
`setup()` with `watch = false` stops it).

- **Notice.** When mail for you arrives (a `mail.sent` or `mail.replied` event
  whose message is addressed to `human` and not from `human`), it says
  `gc-mail: <from> in <city>: <subject>`, each part on one line and the
  subject cut at 72 characters, once per message. If the chat window of that
  city and sender is open and current, there is no notice: the chat shows it.
- **Unread count.** One `gc --city <path> mail count human --json` per city
  seeds the count when the watch starts, every `watch_resync_ms` (default five
  minutes) and after an `overflow` or `rotated` event of that city. Between
  seeds the events move it: an arrival adds one; `mail.read`,
  `mail.marked_read`, `mail.archived` and `mail.deleted` of an arrival the
  watch counted take one off; `mail.marked_unread` of one it no longer counts
  puts it back. An event without a decodable message, or about a message the
  watch has not counted, changes nothing, and the count never goes below zero.
  A failed count is shown once and the last count is kept. A city is watched
  when the city list first brings it, also later.
- **Statusline.** `require('gc_mail').status()` is `''` when no mail is
  unread or the watch is off, else a space and the unread total across cities,
  taken from what the watch already counted: it runs nothing and is safe to
  call before `setup()`.

```lua
-- lualine
sections = { lualine_x = { function() return 'mail' .. require('gc_mail').status() end } }
```

```vim
" the built-in statusline: shows " 3" with three unread mails, else nothing
set statusline+=%{v:lua.require('gc_mail').status()}
```

## The chat

`<Space>mc` (configured via `chat_keymap`, `false` for none, default `'<Space>mc'`)
or `:GcMailChat [city] [with]` opens a two-window conversation view
beside the current window: a vertical split of `chat_width` columns (default 60,
`winfixwidth`) on the right for the timeline, and a split below of
`chat_compose_height` rows (default 3, `winfixheight`) for the compose box,
placing the cursor in the compose box in normal mode.

| key | context | action |
| --- | --- | --- |
| `<Space>ms` | compose box | send message (normal mode only; option `chat_send_keys`, default `{ '<Space>ms' }`) |
| `<CR>` | timeline | open message under cursor in message view |
| `t` | timeline | open thread of message under cursor |
| `u` | timeline | mark message under cursor unread (`mailbox.actions.unread`) |
| `R` | timeline | reload history (`history.load`) and re-render |
| `G` | timeline | jump to the latest message and follow the end again (with a count, `G`'s own line) |
| `q` | timeline | close both chat windows (non-empty draft preserved) |

- **Timeline rendering.** Rendered oldest first from `history.conversation(city, with)`
  and pending send queue records for `(city.path, with)` that are not replies or
  reply to this conversation. Each message displays `## <who> · <when>[ ●]`,
  followed by the subject line unless it equals the first non-empty line of the body
  (after stripping prefix and suffix), an empty line, the body verbatim, and `---`.
  `<who>` is `you` for `human`, else the sender. `<when>` is `%H:%M` for today, else
  `%Y-%m-%d %H:%M`. `●` indicates unread mail to `human`.
- **Closed mail.** A closed message (archived, deleted, or read and swept by
  gc) stays in the conversation, its heading marked ` (closed)` before any `●`.
- **Pending and failed sends.** Queue records render `## you · sending…` (claimed),
  `## you · queued` (pending), or `## you · failed: <error>` (failed), followed by
  the body verbatim. The record is replaced once the delivered message appears in
  history. An empty conversation displays `no messages with <with> in <city> yet`.
- **Scrolling.** The timeline follows the end while its view shows the last line
  with the cursor on it: on open and on every re-render the cursor lands on the
  new last line. Scrolling the view up (the wheel, `<C-y>`) or moving the cursor up
  stops following: a re-render then keeps the cursor and the first line shown, and
  counts each message (by id) first shown below the view; a changed read or closed
  mark is never counted. The timeline's statusline shows ` ↓ <n> newer below (G)`
  until the view shows them; `G` jumps to the latest message, clears the count and
  follows again. A re-render never moves cursors in other windows.
- **Sending.** Sends through `gc_mail.send(compose_buf, city, { to = with })`.
  The compose box clears in one undo step (`u` restores the text). The timeline
  shows `sending…` immediately, and refreshes via `history.load` upon queue delivery.
- **Read marks.** With `chat_mark_read` (default `true`), unread messages to `human`
  are passed to `mailbox.actions.read` when the chat is current or on `WinEnter`.
  The `●` bullet disappears immediately, returning if gc refuses. `u` on a message
  keeps it unread until you leave the chat. `chat_mark_read = false` marks nothing.
  The chat keeps one record per message id (`reading`, `read`, `refused` or
  `unreading`; no record is idle), under these rules:
  1. **RS1** Every read or unread the chat starts bumps that id's sequence number; an
     answer whose number is no longer current changes nothing (state, cache, render).
  2. **RS2** `actions.unread` reports whether its answer was applied, as `actions.read`
     does; an answer that was not applied is the stale case of RS1, and gc's state
     is taken from a history load (RS5).
  3. **RS3** Automatic mark-read passes only an id with no record, at most once until
     its record is dropped.
  4. **RS4** `u` marks the message `unreading`, owned by the chat that pressed it; only
     leaving that chat's own two windows releases the ids it owns. Moving between
     windows of another chat never touches them.
  5. **RS5** After a history load, an id whose last action answered before the load
     began takes gc's loaded read flag and drops its record when they disagree
     (a message marked unread elsewhere is then passed again); an action still pending,
     or answered after the load began, keeps the local value.
  6. **RS6** A refused mark-read keeps the `●` and is not retried automatically until
     a load shows the message read.
- **Live updates.** While a chat is open it follows its city's event log through the
  shared watcher, with no polling: a `mail.sent` or `mail.replied` event carrying its
  message puts the message in the history cache and renders every open chat of that
  conversation at once, with no gc call (your own sends arrive the same way and
  replace their `sending…` record); a message of another conversation is only cached.
  `mail.read` and `mail.marked_read` clear the `●` of a cached message,
  `mail.marked_unread` brings it back, `mail.archived` and `mail.deleted` mark it
  closed; an id not cached changes nothing. An event is newer than any read or
  unread the chat had already got gc's answer to, so it moves the `●` also of a
  message the chat marked read itself (RS5). A history load that began before an
  event never takes back what the event showed: the chat keeps the event's message
  and flags until a load that began after it lists the city. A mail event without a
  readable message, an `overflow` or a `rotated` log loads the city's history once.
  The scrolling rule holds on every live render.
- **Fallback.** Every `chat_poll_ms` (default one minute) the history of each city
  with an open chat is loaded again, also when its event log cannot be watched; a
  city with an open chat is also loaded once after a queued send to it is delivered.
  A failed load, that one included, is said once, until a load of that city
  succeeds; the timeline keeps what it showed, and one that has nothing to show
  says `cannot load the history: <error>`.
  Closing the last chat of a city stops that city's timer and watch; closing the last
  chat stops everything the chat started (the watcher itself stops when no panel or
  background watch uses it), and an event or answer that arrives later touches no
  closed chat.

- **Conversations.** `<Space>ml` (option `chats_keymap`, `false` for none) or
  `:GcMailChats` opens a float, ` gc mail chats: <CR> open  q close `, with one line
  per conversation across the cached cities, newest last message first:
  ` <unread, 2 wide>  <city>  <with>  <subject of the last message>  <age> `. A
  conversation is the messages between `human` and one other address in one city
  (the rule of `history.conversation`); unread counts its messages to `human` that are
  not read. A city with no conversation gets a ` <city>  mayor  no messages yet ` line,
  so a first chat can start from here. The float opens at once from the history
  cache (` loading… ` while nothing is known) and loads each city once, in the
  background, filling the lines in; a city that fails to load is said once as an error,
  its line says `cannot load the history`, and the other cities still list. It is not
  live: it shows what the cache held when it opened and after each load it started.
  `<CR>` closes it and opens that chat; `q` and `<Esc>` close it. `c` in the mailbox
  float, the message view and the panel opens the chat with the message's sender
  (or, for a message from you, its recipient) in the message's city.

## Search

`:GcMailSearch <text>` (the whole argument, trimmed; no text is refused with a
notice), or `s` in the mailbox float and the panel (which ask for the text with
`vim.ui.input`; an empty answer cancels), searches the mail history of every
city: the text is found case-insensitively, as plain text (no regular
expressions), in the subject, body, sender and recipient of every message in the
history cache. A city whose history is not cached is loaded once first (one
`gc bd list`, see [History](#history)) and searched when its answer arrives; the
cache holds the last `history_days` days. Nothing runs at load time: the search
module loads when the command or the key runs.

The results float opens at once with ` searching… ` and fills in, titled
` gc mail search "<text>": <CR> open  c chat  q close `: one line per hit, newest
first, ` <city>  <from>→<to>  <subject>  <age> ` (`you` for human, every part one
sanitized line, the subject cut at 60 characters), or ` no mail matches `. A city
that fails to load is said once as an error and listed as `cannot load the
history`; the other cities' hits still show.

| key | action | gc |
| --- | --- | --- |
| `<CR>` | close the results and show the hit in the message view: the same layout and keys as an opened message, but nothing is marked read, as the message may be closed | none |
| `c` | open the chat with the hit's correspondent (its sender, or its recipient for a message from you); says so when the chat is not installed | none |
| `q`, `<Esc>` | close | |

## The send queue

Each message is one JSON file (city name and path, subject, body, created
time, tries, last error, and optional recipient `to`) in `<state_dir>/queue/`,
by default `~/.local/state/nvim/gc-mail/queue/`. Every field of a file is
checked when it is read; a file that does not pass is listed as unreadable and
never sent, and `o` shows its raw text.

- One worker sends, one gc process at a time, oldest first: messages to one
  city's mayor or recipient arrive in the order you wrote them.
- Other views can subscribe to queue file changes (add, claim, a send's
  outcome, put back, retry, delete, dropping a gone process's claim) via
  `require('gc_mail.queue').subscribe(name, fn)`.
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

## History

The plugin queries mail history and thread records directly from the bead store
in the background:

```sh
gc --city <city path> bd list --type message --all --json --limit 0 --created-after <T>
```

where `T` is the current UTC time minus `history_days` (default 14 days,
RFC 3339 UTC format). For a thread load (`opts.thread`), it queries with
`-l thread:<id>` instead of `--created-after`. All queries run through
`vim.system` (argument list, 10 s timeout, never a shell).

- **H1 decoder.** Every record returned by `gc bd list` passes the strict H1
  decoder (`id`, `title`, `sender`, recipient as `assignee` when a non-empty string or
  `metadata['gc.routed_to']` when a non-empty string, `status`, `created_at`, optional
  `description`, `labels`, and `metadata`), verifying identifiers and mapping to
  message records with `thread_id`, `reply_to`, `closed` (when status is
  `closed`), and `read` (`closed`, `'read'` label, or `metadata['mail.read'] == 'true'`),
  before passing `mailbox.message()`. Records that fail decoding are skipped and
  counted; the caller notifies "N messages could not be read" once per city.
- **Cache.** Decoded messages are cached per city in `history.cache[city.path]`.
  A full listing replaces the city's cache whole, while a thread listing merges
  its messages in. In-flight requests with identical arguments collapse into a
  single `gc` call and invoke all registered callbacks in order.
  `history.messages(city)` returns cached messages oldest first, and
  `history.conversation(city, with)` filters for bidirectional messages
  between `human` and the specified party.

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

The fake's `bd list` branch answers `gc --city <path> bd list ...` calls,
logging its argument list to `$FAKE_GC_MAIL_LOG` like a mail command (fields
delimited by `0x1f`). It answers from `$FAKE_GC_MAIL/bd-list.<city>.<ext>` or
`bd-list.<ext>` (`.json` for stdout, `.exit` for status code, `.stderr` for
error output, `.hang` for hanging sleep duration, or `.delay` to sleep before
printing), supporting test fixtures for multi-line JSON lists, errors, timeouts,
and malformed answers.

## Demo recording

`demo/record.sh` records a presentation video of the plugin's windows, headless:
nothing appears on your screen and no real gc or city is touched.

```sh
tools/gc-mail.nvim/demo/record.sh [--out FILE.mp4] [--tour FILE] [--size WxH]
```

It starts its own Xvfb display, runs alacritty (wezterm as the fallback) with
`nvim --clean -u demo/init.lua` and the plugin against a fake demo city, types
the tour at human speed, and grabs the display with ffmpeg (30 fps, H.264) into
an MP4 (default `./gc-mail-demo.mp4`, 1920x1080). Requires `sh`, `nvim`, `Xvfb`,
`xdotool`, `ffmpeg` and `alacritty` or `wezterm`; nothing is downloaded.

- `demo/bin/gc` is the demo gc: a small mail store in a temporary directory,
  seeded with a few days of mail from `mayor`, `builder` and `reviewer` to
  `human` (city `demo-city`). `record.sh` puts it first on `PATH`, unsets every
  `GC_*` variable and refuses to start unless `gc` resolves to it. It answers
  the calls the plugin makes, and two demo-only verbs write a message from an
  agent and the matching line of the city's event log, so the panel and an open
  chat show the mail live: `gc agent <name> reply latest|<id> <text>` and
  `gc agent <name> send human <subject> <text>`.
- `demo/keys.lua` is the overlay: the last keys at the bottom right (each gone
  after about 1.5 s) and a caption line above them. Captions come through the
  Neovim socket, so they never show up as keys.
- A tour is a text file, one step per line: `key <xdotool key names>`,
  `type <text>`, `wait <ms>`, `say <caption>`, `agent <args...>` (the demo gc as
  an agent), `# comment`. An unknown step stops the run and names its line.
  `demo/tour-basic.txt` is the default (about 85 seconds); `demo/tour-chat.txt`
  (`--tour demo/tour-chat.txt`, about 70 seconds) records the chat: a notes
  buffer with the chat with the mayor opened beside it by `<Space>mc`, a message
  typed and sent with `<Space>ms` (its `sending…` block shows, as `record.sh`
  makes each send take 2.5 s through `GC_DEMO_SEND_DELAY_MS`; an agent step started
  meanwhile waits for the send to land), the mayor's
  answers arriving live from the event log with no key pressed, a second
  exchange, `u` on a message, and `q`.
- Everything lives in one temporary directory, removed on exit; Ctrl-C or a
  failure stops ffmpeg, the terminal, Neovim and Xvfb first. Exit status is 0
  only when a non-empty MP4 was written.

The tests for the overlay's key labels and for the demo gc are in
`tests/run.lua`; the recording itself is not part of the suite.
