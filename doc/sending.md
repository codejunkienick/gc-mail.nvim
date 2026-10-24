# Sending mail

This page covers sending a buffer with `:GcMail`, subject labels and the send
queue on disk. The [README](../README.md) has the overview.

## Send a buffer

1. Write the message in any buffer. The first non-empty line, trimmed to 72
   characters, is the subject, and the whole buffer is the body.
2. Press `<Space>mm` or run `:GcMail [to]`. The picker opens at once,
   unless `<to>` is a bad address: starting with `-`, holding a control
   character, or over 100 bytes. A bad address warns and opens no picker.
   `<Space>mm` and `:GcMail` list `<city>  mayor` for each city in the cached
   `gc cities --json` list. `:GcMail <to>`, for example `:GcMail planner`,
   opens with the title `mail buffer to <to> in` and lists `<city>  <to>` per
   city.
3. Move with `j`/`k` or the arrow keys. `<CR>` sends, and `<Esc>` or `q`
   cancels.

The picker shows `loading…` until the first answer and then fills in. The
plugin also fetches the city list again in the background, and the newer list
replaces the shown one when it arrives. The picker is sized to its cities and
is never taller than the editor less the command line and its border, so it
works in a window 10 lines tall. When there are more cities than fit, the list
scrolls.

### What `<CR>` does

`<CR>` writes the message to the queue first and only then empties the
buffer. The plugin marks the buffer unmodified and shows
`queued for <city> <to>: <subject>`, with the subject as sent, label included.
Clearing the buffer is one undo step, so `u` brings the text back.

- If the queue file cannot be written, the buffer stays as it was and the
  plugin shows the error.
- If the buffer cannot be cleared after the queue write, the message stays
  queued and is sent once. The buffer keeps its text and a warning says so. Do
  not send it again.

The queue's worker then runs this argument list, never through a shell:

```sh
gc --city <city path> mail send <to> -s <subject> -m <body> --notify
```

`<to>` is the address you chose, `mayor` by default. Outside an agent session
gc sends as its default sender, `human`. When gc exits 0, the worker deletes
the queue file and shows `sent to <city> <to>`.

### Buffers the plugin refuses

The plugin refuses these buffers before it runs anything:

- an empty or whitespace-only buffer;
- a buffer over 120 KiB, because one argument cannot be larger on Linux;
- a buffer that is not `modifiable`, because the plugin could not clear it
  and sending it again would mail it twice.

### The city list

The picker reads the city list from `gc cities --json`. The plugin kills that
call when it does not answer within 10 seconds. The answer must be exactly one
record that lists each city with a name and a path, and neither may contain a
control character. Any other answer counts as a failure. With no earlier list,
the picker then closes and shows why. With a list from an earlier answer, the
picker keeps that list and says once that the refresh failed.

## Subject labels

`subject_prefix` and `subject_suffix` label the subject of every message the
plugin sends, replies included. The plugin adds the label exactly once. It
first removes a copy of either that is already in the line, as in a reply to a
labelled message. The label counts toward the 72 characters. gc also sends
order and script mail as `human`, so the label is how a mayor tells your own
mail apart.

## The send queue

Unsent mail waits on disk, so it survives a restart. The queue hands each
message to `gc` in the background, oldest first. Each message is one JSON file
in `<state_dir>/queue/`, by default `~/.local/state/nvim/gc-mail/queue/`. The
file holds the city name and path, the subject, the body, the created time,
the number of tries, the last error and an optional recipient `to`. The plugin
checks every field when it reads a file. It lists a file that fails the check
as unreadable and never sends it, and `o` in `:GcMailQueue` shows its raw
text.

- One worker sends with one gc process at a time, oldest first. Messages to
  one city's mayor or recipient arrive in the order you wrote them.
- A failed send keeps its file and shows the first lines of gc's error once.
  The worker retries after 10 s, 1 min and 5 min (`retry_ms`). When the last
  try fails, the plugin marks the message failed, and only `:GcMailQueue`
  sends it again.
- A gc call that does not finish within 2 minutes counts as failed.
- `setup()` resumes the queue after a restart. A message whose gc call was
  still running when Neovim quit or crashed is sent again then.
- If Neovim crashes after gc delivered a message but before the worker deleted
  its file, the next start sends that message again. One duplicate is better
  than a lost message.

Other code can follow changes to the queue files with
`require('gc_mail.queue').subscribe(name, fn)`. A change is an add, a claim, a
send's outcome, a put-back, a retry, a delete, or dropping the claim of a
Neovim that is gone.

### The queue window

`:GcMailQueue` lists the queued messages in a float like the picker's. Each
line shows the city, the recipient, the subject, the age, the state and the
last error. The state is `pending`, `sending`, `failed` or
`sent, file not removed`. The plugin flattens line breaks and other control
characters, so each message takes one line.

| key | action |
| --- | --- |
| `r` | send the message again now, a failed one included |
| `o` | open its text in a new buffer |
| `d` | delete it, unless it is being sent |
| `<Esc>`, `q` | close |

### Several Neovims on one queue

Several Neovims may share one queue. Six rules keep it consistent, and the
tests check each one.

1. **Whole files.** The plugin only creates or replaces a queue file whole. It
   writes a temp file in the queue directory, fsyncs it and renames it into
   place.
2. **One lock.** Every change to a queue file runs under an exclusive `flock`
   on `queue/.lock`, and the plugin reads the files it decides on under that
   same lock. Only reading for display takes no lock. The worker never waits
   for the lock and looks again shortly. Adding a message, `r` and `d` wait up
   to half a second, then refuse as busy. A refused add keeps the buffer.
3. **Claims.** The worker renames a message it sends to
   `<id>.json.sending-<pid>-<token>`. Each Neovim makes its token once, and
   the file's modification time is the time of the claim. Only the sender
   changes a claimed file. `r` and `d` act only on an unclaimed `<id>.json`,
   so a retry can never recreate a file another Neovim is sending. A claim is
   live while it is this Neovim's own, or while its pid is alive and the claim
   is younger than twice the 2-minute send timeout. A sender whose outcome
   waits on the disk keeps its claim young, and says once when it cannot. The
   next worker pass puts back every other claim, such as one left by a crashed
   Neovim whose pid a new process now has, or drops it when it is marked sent.
   So another Neovim can send a message a second time when its sender stays
   suspended mid-send for longer than that.
4. **Settled outcomes.** A send ends only when its outcome is on disk. After a
   success the file is deleted, and after a failure it is rewritten with the
   new tries and error and put back. If the disk refuses that, the message
   stays claimed, nothing else is sent, and the plugin shows the error once.
   It tries the write again after 1 s, 10 s and then every minute. When a
   delivered message's file cannot be deleted, the plugin rewrites it as sent,
   so a restart drops it instead of sending it again.
5. **Bounded.** The queue holds at most 100 files, failed ones included. Past
   that, the plugin refuses a new message and its buffer stays as it was.
6. **Fail closed.** A queue directory that cannot be listed never counts as an
   empty queue. Adding refuses, and the worker sends nothing and says why
   once, then again when it can read the queue. `:GcMailQueue` shows the
   error.
