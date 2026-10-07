# gc-mail.nvim

Mail the current Neovim buffer to a Gas City mayor. `<Space>mm` (or
`:GcMail`) opens a small picker with one line per city registered with the gc
supervisor; `<CR>` sends the buffer to that city's mayor and clears it once gc
confirms. Requires Neovim 0.10 or newer and `gc` on `PATH`; no other plugins.

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

`:GcMail` exists as soon as the directory is on the runtimepath; `setup()`
adds the mapping. Nothing runs when the plugin loads: `gc cities` runs only
when the picker opens.

## Options

| option | default | meaning |
| --- | --- | --- |
| `keymap` | `'<Space>mm'` | normal-mode mapping that opens the picker; `false` sets none |

## Use

1. Write the message in any buffer. The first non-empty line, trimmed to 72
   characters, is the subject; the whole buffer is the body.
2. `<Space>mm`. The picker lists `<city>  mayor` for each city from
   `gc cities --json`, also when there is only one. `j`/`k` or the arrow keys
   move, `<CR>` sends, `<Esc>` or `q` cancels.
3. The plugin runs, as an argument list (never through a shell):

   ```sh
   gc --city <city path> mail send mayor -s <subject> -m <body> --notify
   ```

   The sender is gc's default outside an agent session (`human`).
4. When gc exits 0 the buffer is emptied, marked unmodified, and
   `sent to <city> mayor` is shown. On any other exit the buffer stays as it
   was and the first lines of gc's error output are shown. If you edit the
   buffer while gc runs, it is left alone after the send.

An empty or whitespace-only buffer is refused before anything runs, as is a
buffer over 120 KiB (one argument cannot be larger on Linux).
If `gc cities` does not answer within 10 seconds it is killed and the picker
does not open; the timeout is shown instead.

The picker is sized to its cities and never taller than the editor minus the
command line and its border, so it works in a window 10 lines tall; more
cities than fit scroll.

## Tests

From the repository root, with a fake `gc` (`tests/bin/gc`) first on `PATH`;
the real gc never runs:

```sh
nvim --headless -u NONE -i NONE -n -l tools/gc-mail.nvim/tests/run.lua
```

It prints one line per test and exits 0 when all pass.
