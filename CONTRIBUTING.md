# Contributing

This page covers the house rules, the test suite and the demo recording. The
[README](README.md) has the overview.

## Before you send a change

Run the headless suite from the repository root:

```sh
PATH="$PWD/tests/bin:$PATH" nvim --headless --clean -n -l tests/run.lua
```

Keep commit subjects short, imperative and without a final period.

## House rules

Every change follows these rules.

- Nothing runs while the plugin loads. `plugin/gc_mail.lua` only defines the
  seven commands, and each module loads when a command, a key or `setup()`
  needs it.
- Every `gc` call is asynchronous and passes an argument list, never a shell
  string.
- One strict decoder per answer shape checks a `gc` answer before anything
  reads it (I1).
- An answer changes what the plugin shows or keeps only while it is still
  current (I2).
- The plugin's own views are scratch buffers named `gc-mail://...`.
- The plugin has no plugin dependencies.
- The plugin runs on Neovim 0.11 or newer.
- No tracked file contains an internal id or an absolute home path.

### The I1 and I2 invariants

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

## Tests

The suite runs from the repository root with a fake `gc` (`tests/bin/gc`)
first on `PATH`, so the real gc never runs:

```sh
PATH="$PWD/tests/bin:$PATH" nvim --headless --clean -n -l tests/run.lua
```

It prints one line per test and exits 0 when all pass.

GitHub runs the same command on every push and pull request (`.github/workflows/tests.yml`), on Neovim 0.11 and current stable.

The fake answers `gc cities` after a delay or not at all, and fails a send a
given number of times. It answers each mailbox command (`inbox`, `count`,
`read`, `mark-read`, `mark-unread`, `thread`, `archive`, `delete`) from a
fixture per command and city. On request it fails, hangs, answers late or
prints malformed JSON, and I1 and I2 each have their own tests.

The panel tests give each city a real temporary directory and append lines to
its `.gc/events.jsonl`. They cover mail, other and malformed events, half
lines, rotation and a missing file, and count the inbox calls the fake
answers.

The tests point the queue and `XDG_STATE_HOME` at a scratch directory and use
millisecond retry delays. They simulate failing disk calls by wrapping
`vim.uv` functions. They check the lock rule by probing the lock at every
change to a queue file, and `tests/add_many.lua` is a second Neovim that adds
to the same queue at the same time.

The fake's `bd list` branch answers `gc --city <path> bd list ...` calls. It
logs its argument list to `$FAKE_GC_MAIL_LOG` like a mail command, with fields
delimited by `0x1f`. It answers from `$FAKE_GC_MAIL/bd-list.<city>.<ext>` or
`bd-list.<ext>`, where the extension picks what it does:

- `.json` is the standard output;
- `.exit` is the exit status;
- `.stderr` is the error output;
- `.hang` is how long it sleeps without answering;
- `.delay` is how long it sleeps before it prints.

These fixtures cover multi-line JSON lists, errors, timeouts and malformed
answers.

## Demo recording

The demo recording setup and the demo media live on the `demo` branch, not on
`main`. That branch holds the `demo/` scripts and tours, the `assets/` media
that the README embeds, and the tests for both. Nothing on `main` needs them.

`demo/record.sh` records the plugin headless, against a fake demo city, so no
real gc or city is touched. It needs `sh`, `nvim`, `Xvfb`, `xdotool`, `ffmpeg`
and `alacritty` or `wezterm`. To record the demo again:

1. Check out the `demo` branch.
2. Merge `main` into it, so the recording shows the current plugin.
3. Run the demo tour, which writes the MP4 and both media files:

   ```sh
   demo/record.sh --tour demo/tour-showcase.txt --out ./gc-mail-demo.mp4 --gif ./assets/gc-mail-demo.gif --webp ./assets/gc-mail-demo.webp
   ```

4. Commit the new media on the `demo` branch.

The README on `main` embeds the media from the `demo` branch by full URL, so
new media shows there with no change on `main`. The MP4 goes on a release as
`gc-mail-demo.mp4`, where the README links it.
