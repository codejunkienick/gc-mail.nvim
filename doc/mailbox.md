# Mailbox

This page covers the mailbox float, the mail panel, the preview pane and the
background watch. The [README](../README.md) has the overview.

## The mailbox

`<Space>mi` or `:GcMailbox` opens a float like the picker's, at once. It shows
one line per message, newest first, across every city in the cached
`gc cities --json` list:

```text
  ● demo-city  mayor  Re: mailbox for gc-mail  5m
x   demo-city  mayor  Deploy plan accepted  2h
```

The first column is `x` on a marked message, and `●` marks unread mail. Then
come the city, the sender, the subject and the age. The float's title lists
the keys.

While the float is open, the plugin runs this command for each city in the
background, with a 10 second timeout:

```sh
gc --city <city path> mail inbox human --json
```

When a refreshed city list adds a city, the plugin lists that city once. `R`
lists every city again. When gc fails, does not answer, or sends an answer the
plugin cannot decode, the plugin shows one error and changes nothing on
screen. A late answer never brings back a message you archived or deleted, and
never undoes a later mark.

| key | action | gc call |
| --- | --- | --- |
| `<CR>` | open the message in a new window, headers first, then the body | `mail read <id>`, which marks it read; none for mail already read |
| `r` | reply in a new buffer with the subject `Re: <subject>`; `<Space>mm` or `:GcMail` in it queues the reply | `mail reply <id> -s <subject> -m <body> --notify`, from the send queue |
| `t` | open the thread, oldest first, in a new window | a load from the bead store (`gc bd list`); `mail thread <id>` when the message has no thread id |
| `c` | close the float and open the chat with the message's sender in its city, or with the recipient for a message from you | none, the chat loads its own history |
| `s` | search the mail history of every city; it asks for the text (see [Search](search.md#search)) | one `bd list` for each city whose history is not cached |
| `x` | mark or unmark the message under the cursor | none |
| `X` | clear every mark | none |
| `m` | mark read | `mail mark-read <id>`, one call per message |
| `u` | mark unread | `mail mark-unread <id>`, one call per message |
| `a` | archive | `mail archive <id> [<id> ...]`, one call per city |
| `d` | delete, after a Yes/No question | `mail delete <id> [<id> ...]`, one call per city |
| `H` | turn all mail on or off | `bd list` for the history, once per city the first time |
| `p` | show or hide the preview pane for this view | none |
| `R` | list every city again, and the history too in all-mail mode; ignored while a listing still runs | `mail inbox human`, once per city |
| `q`, `<Esc>` | close | none |

`m`, `u`, `a` and `d` act on the lines of a visual selection (`V`, then the
key). Without a selection they act on every marked message, and without marks
on the message under the cursor. The plugin shows each refusal from gc once as
an error and never retries it.

The window that `<CR>` opens has the keys `r`, `t`, `c`, `u`, `a` and `d`
too, and `q` closes it. There, `c` opens the chat beside the message and keeps
the message window open.

### Marks and bulk actions

`x` marks the message under the cursor, and `X` clears every mark. The marks
belong to the mailbox, so the float and the panel both show them. A mark goes
away when its message leaves the list.

With several messages picked by a selection or by marks, `a` and `d` run one
`gc mail archive <id> <id> ...` or `gc mail delete <id> <id> ...` per city.
`d` asks once, `Delete N messages?`. gc's answer must name every id asked for.
Otherwise nothing changes and the plugin names that city's ids once. On
success each message leaves the list on its own, and a later action on one of
them drops only that one.

`m` and `u` run one `gc mail mark-read <id>` or `gc mail mark-unread <id>` per
message, in list order, one at a time. A message whose action applied loses
its mark.

### All mail

`H` switches the mailbox to all mail, in the float and the panel at once. All
mail lists the unread inbox, the kept copies, and every message to you in the
mail history. The history is what `gc bd list` returns for the last
`history_days` days, read and closed mail included. The first `H` loads the
history of every known city in the background. A city that the city list adds
later, or that arrives after an early `H`, loads its history when it is first
listed. When a city's load fails, the plugin says so once and the list shows
what the mailbox has. While all mail is on, the title starts with
` all mail `, and a closed message shows `×` where an unread one shows `●`.
`H` again goes back to the usual list.

A message listed only from the history is archived or deleted through gc in
the same way. When gc refuses, as it does for a closed message, the plugin
says so and the line stays. A message you archive or delete here leaves all
mail until you load the history again with `R`, which then lists it as
closed.

### Markdown views

With `markdown = true`, the default, the opened message and the thread are
scratch buffers with `filetype=markdown`. A markdown renderer you run, such as
render-markdown.nvim, draws them. Without one, Neovim's own markdown
highlighting applies. The plugin needs no renderer. A message reads like
this:

```markdown
# Re: mailbox for gc-mail

**From** mayor · **To** human · **City** demo-city · 2026-10-07T12:00:00Z

`ic-wisp-a1` · thread `thread-0a1b2c3d4e5f` · r reply  t thread  u unread  a archive  d delete  q close · Read mail stays in this mailbox …

---

the body, exactly as gc stores it
```

A thread starts with `# <subject of the first message>`. Then each message
follows, oldest first, as `## <sender> · <date>` and its body, with a `---`
rule between messages. A closed message has ` (closed)` in its header. In
header values (subject, sender, recipient, city and date) the plugin puts a
backslash before each of the characters `` \ ` * _ [ ] < > # | ``, so they
never read as markup. A body shows verbatim, so its own markdown renders as
written. The buffers stay `nofile`, not modifiable and wiped when hidden,
with the same keys and the same `gc-mail://` names. `markdown = false` gives
the plain layout, with `From:` and `To:` lines and no filetype.

### How long read mail stays

`gc mail inbox` lists unread mail only, and gc 1.4.1 has no command that lists
read mail. gc also closes read mail by itself. Its nudge-mail-sweep closes
every read message sent more than an hour ago, as a controller watchdog every
5 minutes and as the core `nudge-mail-sweep` order. `gc mail thread` then
leaves the message out.

So the mailbox keeps a copy of every message you open or mark read in it. Each
copy is one JSON file in `<state_dir>/mailbox/`, written whole. The mailbox
lists the copy across restarts, until you archive or delete the message in the
mailbox. A mayor's answer therefore stays in the mailbox after you read it.
Mail read elsewhere, such as with `gc mail read` in a terminal, gets no copy
and leaves the mailbox when gc closes it. Marking a kept message unread marks
it unread in gc and in the copy.

### Replies

A reply goes through the [send queue](sending.md#the-send-queue) like any
message. It is on disk before its buffer is cleared, and a failed send is
retried. `:GcMailQueue` lists it as `<city> <sender>`. Once the reply is
queued, its buffer stops being a reply buffer.

## The mail panel

`<Space>mp` or `:GcMailPanel` docks the mailbox right below the current
window, like a diagnostics list. The panel is a horizontal split of
`panel_height` rows, with a fixed height and the same lines as the float. The
same key closes it. Opening the panel, refreshing it, or new mail arriving
never moves the cursor or changes the current window, so you keep typing where
you were. A tab page has at most one panel. Its buffer is an unlisted scratch
buffer with filetype `gcmail-panel`, and its status line lists the keys.

```text
the buffer you are editing
~
notes.md
  ● demo-city  mayor  Re: mail panel  2m
    demo-city  mayor  Deploy plan accepted  1h

 gc mail: <CR> open  r reply  t thread  c chat  s search  x mark  m read  u unread  a archive  d delete  H all  p preview  R refresh  q close
```

The panel and the float are two views of one mailbox. They share the
`gc mail inbox` listing, the kept copies, the actions, the marks and all-mail
mode, so an action in one view shows in both. The panel has the mailbox keys,
with these differences:

- `<CR>`, `r` and `t` open their window above the panel, never inside it.
- `c` opens the chat beside the window the panel is docked under, and the
  panel stays open.
- `p` shows or hides the panel's own preview pane.
- `q` closes the panel.

When the list changes, the panel's cursor stays on the message it was on.

### Live updates

The panel, the chat and the background watch share one watcher of each listed
city's event log, `<city path>/.gc/events.jsonl`. The watcher uses `vim.uv`
fs_event (inotify on Linux), starts at the current end of the file, and
decodes the `mail.sent`, `mail.read`, `mail.marked_read`, `mail.archived` and
`mail.deleted` events. It retries a missing file or a refused watch every
`events_rearm_ms` (default 60000 ms, at least 15000 ms).

On a change the watcher reads only the bytes appended since its last read.
More than 1 MiB at once counts as an `overflow` event, which refreshes the
city. A line whose `type` starts with `mail.` lists that city again about
500 ms after the first such line, so a burst makes one call. The plugin never
starts a second inbox call for a city while one runs, and lists the city once
more after it. The watcher ignores a line that is not JSON or has no `type`.

gc rotates the file by renaming it and starting a new one with an
`events.rotated` line. After a rotation, or when the file is recreated, the
watcher follows the file now at the path, reports a `rotated` event and lists
the city once. When a city's log starts or stops being watched, for example a
missing log that appears or a rotated one that cannot be watched again, the
watcher reports a `watching` event, which lists nothing.

### Fallback polling

While the panel is open, every `panel_poll_ms` (default one minute) the plugin
lists every city again and reads the kept copies again. That includes a city
whose events file is missing or cannot be watched. Each tick also tries to
watch such a file again and refreshes the city list.

Nothing runs while the panel is closed. Closing the last panel, with its key,
`q`, `:close` or by closing its tab page, stops every watcher and timer. An
answer that arrives later only updates the mailbox state.

## Preview

When the cursor moves onto a message in the mailbox float or the panel, a pane
beside the list shows the message body. The pane leaves out the `From`, `To`,
city and thread lines and the subject, which the list line already shows. The
body comes from the message the list holds in memory, so the pane shows it at
once, runs no gc command and never marks anything read. The pane draws the
body the way the opened message does, and an empty body shows one dim
`(no content)` line. On a line that is not a message, such as a header or an
empty list, the pane is empty. A refresh or a live mail event redraws the pane
for the message under the cursor at that time. The pane follows the cursor
after about 50 ms, so holding `j` does not redraw it on every line.

In the float, the pane is a second float to the right of the list, at the same
top, reaching down to the bottom of the editor. It is as wide as the rest of
the editor less a one-column margin, and at least 30 columns. In an editor too
narrow for that, it goes below the list when 3 rows fit and otherwise stays
hidden. In the panel, the pane is a vertical split in the panel's row, about
half its width and at least 30 columns. It stays hidden when the list would
keep fewer than 20 columns.

Focus never moves into the pane, and the pane closes with its list. `p` in
either list shows or hides the pane until that list closes. `preview = false`
opens the lists with the pane hidden. The pane buffer is `gc-mail://preview`,
`nofile` and not modifiable, with `filetype=markdown` when `markdown` is on.
When the plugin cannot draw a body, it reports that once and clears the pane.

## Background watch

The watch is on by default. After Neovim has finished starting, the plugin
watches every city's event log through the shared watcher and needs no timer
to see mail. `watch = false` in `setup()` turns it off, and a second `setup()`
with `watch = false` stops it while Neovim runs.

When mail for you arrives, the watch shows `gc-mail: <from> in <city>: <subject>`
once per message. Mail for you is a `mail.sent` or `mail.replied` event whose
message is addressed to `human` and is not from `human`. Each part of the
notice is one line, and the subject is cut at 72 characters. There is no
notice when the chat of that city and sender is open in the current tab page
with one of its windows current, because the chat shows the message.
`require('gc_mail.chat').is_current(city, with)` tells whether that is the
case. A chat in another tab page, or one you are not in, still gets a notice.

The watch also keeps an unread count. One
`gc --city <path> mail count human --json` per city sets the count when the
watch starts, every `watch_resync_ms` (default five minutes), and after an
`overflow` or `rotated` event of that city. Between those calls the events
move the count:

- an arrival adds one;
- `mail.read`, `mail.marked_read`, `mail.archived` or `mail.deleted` of an
  arrival the watch counted takes one off;
- `mail.marked_unread` of a message the watch no longer counts puts it back.

An event without a message the plugin can decode, or about a message the watch
has not counted, changes nothing, and the count never goes below zero. A
failed count is shown once, and the watch keeps the last count. The watch
starts on a city when the city list first brings it, also later in the
session.

`require('gc_mail').status()` returns `''` when no mail is unread or the watch
is off. Otherwise it returns a space and the unread total across cities. It
reads what the watch already counted, runs nothing, and is safe to call before
`setup()`.

```lua
-- lualine
sections = { lualine_x = { function() return 'mail' .. require('gc_mail').status() end } }
```

```vim
" the built-in statusline: shows " 3" with three unread mails, else nothing
set statusline+=%{v:lua.require('gc_mail').status()}
```
