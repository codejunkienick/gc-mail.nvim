# Troubleshooting

This page covers what the plugin shows when `gc`, the city list or the send
queue fails, and how to fix it. The [README](../README.md) has the overview.

## `gc` is not on `PATH`

When `gc` cannot run, every view but the panel reports the failing command
once and keeps what it showed. The panel stays empty and says nothing. Put the
`gc` binary on `PATH`, then press `R` in the mailbox or the panel, or reopen
the chat, to list again.

## No city list

The picker, the chat, the conversations list and the search read the city
list from `gc cities --json`. When the list is empty, they report
`no cities are registered with gc`. The mailbox and the panel show
` no mail ` and no notice. Register at least one Gas City with `gc`, then list
again. There is no offline mode.

## A send fails

The message stays in the queue, and the plugin retries it after 10 s, 1 min
and 5 min. Open `:GcMailQueue` to see the error. Press `r` there to send it
again now, or `d` to delete it. [The send queue](sending.md#the-send-queue)
has the details.

## The queue seems stuck

`:GcMailQueue` shows the error when the queue directory cannot be listed or a
send's outcome cannot be written. The queue lives in `<state_dir>/queue/`, by
default `~/.local/state/nvim/gc-mail/queue/`. Check that the directory is
writable.
