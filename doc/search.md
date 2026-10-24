# Search and history

This page covers `:GcMailSearch` and the mail history it reads. The
[README](../README.md) has the overview.

## Search

`:GcMailSearch <text>` searches the mail history of every city for `text`,
which is the whole argument, trimmed. The text is required. Without it,
Neovim refuses the command with `E471: Argument required`. `s` in the mailbox
float or the panel asks for the text with `vim.ui.input`, and an empty answer
cancels.

The search ignores case and matches plain text, not regular expressions. It
looks in the subject, body, sender and recipient of every message in the
history cache, which holds the last `history_days` days. The plugin loads a
city whose history is not cached once first, with one `gc bd list` (see
[History](#history)), and searches it when the answer arrives. Nothing runs at
load time, and the search code loads only when the command or the key runs.

The results float opens at once with ` searching… ` and fills in. Its title
is ` gc mail search "<text>": <CR> open  c chat  R refresh  q close `. It
shows one line per hit, newest first, as
` <city>  <from>→<to>  <subject>  <age> `, or ` no mail matches ` when nothing
matches. `you` stands for `human`, every part is one sanitized line, and the
subject is cut at 60 characters. A city that fails to load is reported once
as an error and listed as `cannot load the history`, and the other cities'
hits still show. `R` loads every shown city's history once more (a load
already in flight is joined, not run twice) and searches the same text again,
so mail that arrived after the search appears without retyping it. The cursor
stays on its row.

| key | action |
| --- | --- |
| `<CR>` | close the results and show the hit in the message view, with the same layout and keys as an opened message; nothing is marked read, because the message may be closed |
| `c` | open the chat with the hit's correspondent, its sender or, for a message from you, its recipient; says so when the chat is not installed |
| `R` | reload every shown city's history and search the same text again |
| `q`, `<Esc>` | close |

The search runs no gc command beyond the history loads.

## History

Old mail lives in each city, where `gc` keeps it as bead records. The plugin
reads the mail history and thread records from the bead store in the
background:

```sh
gc --city <city path> bd list --type message --all --json --limit 0 --created-after <T>
```

`T` is the current UTC time minus `history_days` (default 14 days), in
RFC 3339 UTC format. A thread load uses `-l thread:<id>` instead of
`--created-after`. Each call is an argument list with a 10 second timeout,
never a shell string.

The plugin skips a record it cannot decode and says `N messages could not be
read` once per city. A full listing replaces the cached history of its city,
and a thread listing adds its messages to the cache. Identical calls that are
in flight at the same time share one `gc` call.
