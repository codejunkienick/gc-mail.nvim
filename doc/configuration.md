# Configuration

This page lists every `setup()` option with its default, and the values
`setup()` refuses. The [README](../README.md) has the overview.

Pass any of these keys to `require('gc_mail').setup()`. With lazy.nvim, put
them in `opts`. For example:

```lua
require('gc_mail').setup({
  subject_prefix = '[work] ',
  panel_height = 15,
})
```

## Options

| option | default | meaning |
| --- | --- | --- |
| `keymap` | `'<Space>mm'` | normal-mode mapping that opens the picker; `false` sets none |
| `state_dir` | `stdpath('state') .. '/gc-mail'` | the queue lives in `<state_dir>/queue/` and the kept copies in `<state_dir>/mailbox/` |
| `retry_ms` | `{ 10000, 60000, 300000 }` | delays before each retry of a failed send |
| `mailbox_keymap` | `'<Space>mi'` | normal-mode mapping that opens the mailbox; `false` sets none |
| `subject_prefix` | `''` | text put before the subject of every message the plugin sends, for example `'[work] '` |
| `subject_suffix` | `''` | text put after the subject, for example `' (nvim)'` |
| `watch` | `true` | the [background watch](mailbox.md#background-watch); `false` turns it off |
| `watch_resync_ms` | `300000` | while the watch runs, how often it counts every city's unread mail again (ms, at least `60000`) |
| `panel_keymap` | `'<Space>mp'` | normal-mode mapping that opens or closes the mail panel; `false` sets none |
| `panel_height` | `10` | rows of the mail panel |
| `panel_poll_ms` | `60000` | while the panel is open, how often it lists every city again (ms, at least `15000`) |
| `preview` | `true` | the mailbox float and the panel show the body of the message under the cursor in a pane beside the list; `false` opens them with the pane hidden, and `p` shows it |
| `events_rearm_ms` | `60000` | how often to retry watching a missing or refused event log (ms, at least `15000`) |
| `history_days` | `14` | how many days of mail history to load from the bead store; a whole number of at least 1 |
| `markdown` | `true` | the opened message and the thread are markdown buffers; `false` keeps the plain text layout |
| `chat_keymap` | `'<Space>mc'` | normal-mode mapping that opens the last chat; `false` sets none |
| `chats_keymap` | `'<Space>ml'` | normal-mode mapping that opens the conversations list; `false` sets none |
| `chat_width` | `60` | columns of the chat window, a whole number of at least 20; the opening width before any width remembered for that chat in the session (see [Resizing](chat.md#resizing)) |
| `chat_compose_height` | `3` | rows of the chat compose box, a whole number of at least 1; the opening height before any height remembered for that chat in the session (see [Resizing](chat.md#resizing)) |
| `chat_send_keys` | `{ '<Space>ms' }` | keys mapped in normal mode of the compose box that send the message; a send key always wins over a close or focus key on the same key; `false` maps none |
| `chat_mark_read` | `true` | unread mail to `human` in the shown conversation is marked read when viewed; `false` marks nothing |
| `chat_poll_ms` | `60000` | while a chat is open, how often its city's history is loaded again (ms, at least `15000`) |
| `chat_city_key` | `'C'` | normal-mode mapping in the chat timeline that opens the city picker; `false` sets none |

## Values `setup()` refuses

`setup()` raises an error for any of these values:

- a `subject_prefix` or `subject_suffix` with a control character, or the two
  together over 40 characters;
- a `watch`, `preview`, `markdown` or `chat_mark_read` that is not `true` or
  `false`;
- a `watch_resync_ms` under a minute;
- a `panel_poll_ms`, `events_rearm_ms` or `chat_poll_ms` under 15 seconds;
- a `panel_height` or `history_days` that is not a whole number of at least 1;
- a `chat_width` under 20 or a `chat_compose_height` under 1;
- a `chat_send_keys` that is neither `false` nor a list of key mapping
  strings;
- a `keymap`, `mailbox_keymap`, `panel_keymap`, `chat_keymap`, `chats_keymap`
  or `chat_city_key` that is neither `false` nor a non-empty string.
