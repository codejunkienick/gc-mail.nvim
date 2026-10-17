# Chat

This page covers the chat window and the conversations list. The
[README](../README.md) has the overview.

## Open a chat

`<Space>mc` opens the last chat. `:GcMailChat [city] [with]` opens the chat
with `with` in `city`, by default with the mayor. `chat_keymap` sets the key,
`'<Space>mc'` by default, and `false` maps none.

The chat opens beside the current window as two windows:

- the timeline, a vertical split on the right of `chat_width` columns
  (default 60, `winfixwidth`), sized as [Resizing](#resizing) says;
- the compose box, a split below the timeline of `chat_compose_height` rows
  (default 3, `winfixheight`).

The cursor lands in the compose box in normal mode.

When the current window is the tab's only window, holds the session's only
listed buffer, is a normal window, and that buffer is empty (unnamed,
unmodified, no text), the chat takes over that window full-size instead. The
timeline fills the window and the compose box splits below it. `q` in either
window then closes both chat windows and returns to the empty buffer. Closing
the timeline window itself with `:q` or `<C-w>c` also leaves one window with
the empty buffer, and keeps any compose draft.

## Keys

| key | window | action |
| --- | --- | --- |
| `<Space>ms` | compose box | send the message, in normal mode only (option `chat_send_keys`, default `{ '<Space>ms' }`) |
| `<CR>` | timeline | open the message under the cursor in the message view |
| `t` | timeline | open the thread of the message under the cursor |
| `u` | timeline | mark the message under the cursor unread |
| `R` | timeline | load the history again and render the timeline |
| `G` | timeline | jump to the latest message and follow the end again; with a count, go to that line; the compose box keeps Vim's own `G` motion |
| `q` | both | close both chat windows; a non-empty draft is kept and focus returns to the origin window |
| `<C-j>`, `<C-k>` | both | move focus to the compose box, or to the timeline; moving inside the chat never releases a message that `u` keeps unread |
| `]m`, `[m` | timeline | go to the heading line of the next or previous message, stopping at the last or first message |
| `C` | timeline | open a picker of every registered city, with the current one marked, and open the picked city's mayor chat (option `chat_city_key`, default `'C'`) |

All chat keys are buffer-local normal-mode mappings with a `gc-mail: ` desc.
Only the configured `chat_send_keys` send mail, and typing in insert mode in
the compose box works as usual. A send key always wins over a close or focus
key on the same key.

In the `C` picker, picking the current city closes the picker and changes
nothing. Picking another city closes this chat as `q` does, keeping a
non-empty draft with this chat, and opens that city's mayor chat with the
focus in its compose box. With `chat_city_key = false`, `C` is not mapped and
neither statusline shows its hint.

## The timeline

The timeline shows the conversation oldest first, followed by the queued sends
to the same city and address, except replies to another conversation. Each
message starts with the heading `## <who> · <when>`, which ends in ` ●` when
the message is unread mail to `human`. `<who>` is `you` for `human`, else the
sender. `<when>` is `%H:%M` for today, else `%Y-%m-%d %H:%M`. The subject line
comes next, unless it equals the first non-empty line of the body once the
subject prefix and suffix are removed. Then come an empty line, the body
verbatim, and `---`.

A closed message (archived, deleted, or read and swept by gc) stays in the
conversation, and its heading has ` (closed)` before any `●`.

A queued send shows `## you · sending…` while the worker sends it,
`## you · queued` while it waits, or `## you · failed: <error>` after it
failed, followed by the body verbatim. The delivered message replaces it once
it appears in the history. An empty conversation shows
`no messages with <with> in <city> yet`.

### Rendering

The timeline is filled by API writes, which fire no change event, so after
each render gc-mail reports the finished write as a `TextChanged` for the
timeline buffer while it is current: once at once, and once about 200 ms
later, past renderer debounce windows. Reports made while typing in the
compose box wait until insert mode is left, so renderers never read them as
insert-mode changes. A renderer with a longer debounce can still miss a burst
and leave the timeline raw until the next render.

### Scrolling

The timeline follows the end while its view shows the last line with the
cursor on it. On open and on every render, the cursor then lands on the new
last line. Scrolling the view up, with the wheel or `<C-y>`, or moving the
cursor up stops following. A render then keeps the cursor and the first line
shown, and counts each message, by id, that first appears below the view. A
changed read or closed mark does not count. The timeline's statusline shows
`↓ <n> newer below (G)` until the view shows those messages. `G` jumps to the
latest message, clears the count and follows the end again. A render never
moves the cursor in another window.

Closing a chat keeps its place in session memory, which is the message at the
top of the view and whether the view followed the end. Reopening the chat puts
that message back at the top with the same following state. A first open, or
one whose message is gone, opens at the end. Mail that arrived while the chat
was closed and sits below the restored view keeps its
`↓ <n> newer below (G)` count.

### Resizing

The chat remembers, per conversation, the width you give the timeline window
and the height you give the compose window by resizing them. The memory lasts
for the session only. Nothing goes to disk, and a new session starts from the
options again. Reopening a chat in the same session uses the remembered width
and compose height instead of `chat_width` and `chat_compose_height`. Other
conversations keep their own sizes.

The width is clamped so the origin window keeps at least 20 text columns.

- The effective width is the wanted width cut to `columns - 21`, which leaves
  the 20 columns and their separator. On an editor narrower than that, it is
  1 column.
- When other windows share the row and the split as opened would still leave
  the origin under 20 columns, the timeline gives the shortfall back.
- A resize that narrows the origin under 20 columns gets the same answer, and
  a window on the chat's far side keeps its width.

The compose height is clamped so the timeline keeps at least 5 rows. The
effective height is the wanted height cut to the two windows' combined rows
minus 5. On a shorter editor, it is 1 row.

A resize remembers the clamped size, not the wanted one. An editor resize
(`VimResized`) or equalising the windows restores the wanted width and compose
height under the same clamps, without writing the memory. So while a chat is
open, the origin never drops under 20 columns and the timeline never under 5
rows. The chat windows keep `winfixwidth` and `winfixheight` throughout.

Some layout changes are not resizes, and the chat never remembers them.
Closing the origin window while a split chat is open leaves the timeline
spanning the editor. Closing the timeline window leaves the compose box with
the rows the timeline gave up. A full-size chat has no width of its own, so it
neither takes a remembered width nor replaces one. Its compose height is
remembered and restored like any other chat's.

### Statuslines

The timeline's statusline shows the state of the conversation from what the
chat already holds, with no gc call. It reads
` <with> in <city> (<key> city) · <last send> · <liveness> · <n> unread · ↓ <n> newer below (G) `.

- `<key>` is the `chat_city_key`, `C` by default.
- `<last send>` is the state of the last pending send as its timeline heading
  shows it, `sending…`, `queued` or `failed: <first error line>`. It is left
  out once no send is pending. An unreadable queue file shows in the timeline
  but is not a send of the chat.
- `<liveness>` is `live` while the event watcher follows the city's event log,
  and `polling` when only the fallback timer loads the history because the log
  is missing or cannot be watched. It is `stale` from a failed history load
  until a load succeeds.
- `<n> unread` counts the conversation's unread mail to you, by the rule of
  the conversations list. It is left out at zero, and so is the newer-below
  count.

When the window is narrower than the line, the line is cut from the end, with
`…` marking the cut. The correspondent always shows, and the counts go first.
The line changes only when a value it shows changes, after a render, a load, a
send, a scroll, a new width, or the city's log starting or stopping being
watched. It never renders the timeline again or moves a cursor.

The compose window's statusline lists the keys as
` <send key> send · q close · <C-j>/<C-k> focus · <key> city `, cut the same
way. It leaves out any close or focus key that a configured send key uses or
starts with, so it lists only keys that are mapped. The timeline keys stay
mapped but are not listed there.

### Sending

A send key queues the compose box for the chat's city and address through the
[send queue](sending.md#the-send-queue), like `:GcMail`. The compose box
clears in one undo step, and `u` restores the text. The timeline shows
`sending…` at once and loads the history again when the queue delivers the
message.

### Read marks

With `chat_mark_read = true`, the default, the chat marks unread messages to
`human` read while the chat is current and on `WinEnter`. The `●` goes away at
once and comes back if gc refuses. `chat_mark_read = false` marks nothing.

- The chat marks a message read automatically at most once, until a history
  load clears that.
- `u` on a message keeps it unread until you leave that chat's two windows.
  Moving between the windows of another chat does not release it.
- A refused mark-read keeps the `●`, and the chat does not retry it until a
  load shows the message read.
- Once the chat starts a newer read or unread of a message, the answer to
  the earlier one changes nothing.
- After a history load, gc's read flag wins for a message whose last action
  answered before the load began. So when a message was marked unread
  elsewhere, the chat marks it read again. A pending action, or one answered
  after the load began, keeps the chat's value.

### Live updates

While a chat is open, it follows its city's event log through the shared
watcher, with no polling.

- A `mail.sent` or `mail.replied` event that carries its message puts the
  message in the history cache and renders every open chat of that
  conversation at once, with no gc call. Your own sends arrive the same way
  and replace their `sending…` record. A message of another conversation is
  only cached.
- `mail.read` and `mail.marked_read` clear the `●` of a cached message, and
  `mail.marked_unread` brings it back. `mail.archived` and `mail.deleted` mark
  it closed. An event about a message that is not cached changes nothing.
- An event is newer than any read or unread whose answer the chat already
  has, so it moves the `●` even on a message the chat marked read itself.
- A history load that began before an event never takes back what the event
  showed. The chat keeps the event's message and flags until a load that began
  after the event lists the city.
- A mail event without a readable message, an `overflow` or a `rotated` log
  loads the city's history once.

The scrolling rules hold on every live render.

### Fallback polling

Every `chat_poll_ms` (default one minute) the plugin loads the history of each
city with an open chat again, also when its event log cannot be watched. It
also loads a city with an open chat once after a queued send to it is
delivered. The plugin reports a failed load, that one included, once until a
load of that city succeeds. The timeline keeps what it showed, and a timeline
with nothing to show says `cannot load the history: <error>`.

Closing the last chat of a city stops that city's timer and watch. Closing the
last chat stops everything the chat started, and the shared watcher stops when
no panel or background watch uses it. An event or answer that arrives later
touches no closed chat.

## Conversations

`<Space>ml` or `:GcMailChats` opens a float titled
` gc mail chats: <CR> open  q close `. `chats_keymap` sets the key, and
`false` maps none. The float lists one line per conversation across the cached
cities, newest last message first, as
` <unread, 2 wide>  <city>  <with>  <subject of the last message>  <age> `.

A conversation is the messages between `human` and one other address in one
city. Its unread count is the number of its messages to `human` that are not
read. A city with no conversation gets a ` <city>  mayor  no messages yet `
line, so you can start a first chat from here.

The float opens at once from the history cache and shows ` loading… ` while
nothing is known. It loads each city once in the background and fills the
lines in. A city that fails to load is reported once as an error, its line
says `cannot load the history`, and the other cities still list. The list is
not live. It shows what the cache held when it opened and after each load it
started.

`<CR>` closes the float and opens that chat, and `q` or `<Esc>` closes it. `c`
in the mailbox float, the message view and the panel opens the chat with the
message's sender, or its recipient for a message from you, in the message's
city.
