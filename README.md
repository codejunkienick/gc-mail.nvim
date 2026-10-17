# gc-mail.nvim

Mail the current Neovim buffer to a Gas City mayor, and read the mail sent to
you, without leaving the editor. Gas City is a set of named cities run by the
`gc` command-line tool. Each city has a mayor, and gc addresses everything
meant for you to `human`. `<Space>mm` sends the buffer to a mayor through a
send queue, `<Space>mi` reads the mail addressed to you in every city, and
`<Space>mp` keeps that mailbox docked below your work while you edit. Nothing
runs while the plugin loads, every `gc` call runs in the background with an
argument list, and the plugin needs no other plugins.

<a href="https://github.com/codejunkienick/gc-mail.nvim/releases/latest/download/gc-mail-demo.mp4"><picture><source srcset="https://raw.githubusercontent.com/codejunkienick/gc-mail.nvim/demo/assets/gc-mail-demo.webp" type="image/webp"><img src="https://raw.githubusercontent.com/codejunkienick/gc-mail.nvim/demo/assets/gc-mail-demo.gif" alt="gc-mail demo"></picture></a>

The [full demo video](https://github.com/codejunkienick/gc-mail.nvim/releases/latest/download/gc-mail-demo.mp4)
is on the latest release.

## Features

- [Send the current buffer](doc/sending.md) to a city's mayor or another address, through a queue on disk that retries failed sends.
- [Read your mail](doc/mailbox.md#the-mailbox) from every city in one float, and open, reply to, archive, delete or mark each message.
- [Dock the mailbox](doc/mailbox.md#the-mail-panel) in a split that gc's event log updates while you edit.
- [Preview](doc/mailbox.md#preview) the body of the message under the cursor in a pane beside the list.
- [Get a notice and an unread count](doc/mailbox.md#background-watch) for your statusline when mail for you arrives.
- [Chat](doc/chat.md) with a mayor or an agent in a two-window conversation that updates live.
- [Search](doc/search.md) the mail history of every city, 14 days by default.

## Requirements

- Neovim 0.10 or newer.
- The `gc` CLI on `PATH`, with at least one registered Gas City. There is no
  offline mode. [Troubleshooting](doc/troubleshooting.md) says what each view
  shows when `gc` or the city list is missing.
- No other plugins.

## Install

With lazy.nvim:

```lua
{
  'codejunkienick/gc-mail.nvim',
  opts = {},  -- calls require('gc_mail').setup({})
}
```

With vim-plug:

```vim
call plug#begin()
Plug 'codejunkienick/gc-mail.nvim'
call plug#end()
lua require('gc_mail').setup()
```

Without a plugin manager, clone the repository and add it to the
runtimepath:

```sh
git clone https://github.com/codejunkienick/gc-mail.nvim.git ~/.local/share/nvim/site/pack/plugins/start/gc-mail.nvim
```

```lua
vim.opt.runtimepath:append('~/.local/share/nvim/site/pack/plugins/start/gc-mail.nvim')
require('gc_mail').setup()
```

All seven commands exist as soon as the directory is on the runtimepath.
`setup()` adds the key mappings. Once Neovim has finished starting, it resumes
the send queue and preloads the city list with one background
`gc cities --json`. Unless you set `watch = false`, it also starts the
[background watch](doc/mailbox.md#background-watch). Nothing runs while the
plugin loads, so startup time does not change, and the mailbox lists mail only
when you open it.

## Quick start

1. Write the message in any buffer. The first non-empty line is the subject,
   and the whole buffer is the body.
2. Press `<Space>mm` or run `:GcMail`, pick a city, and press `<CR>` to send.
3. Press `<Space>mi` or run `:GcMailbox` to read the mail addressed to you.

## Commands

| command | what it does |
| --- | --- |
| `:GcMail [to]` | mail the current buffer to a city's mayor, or to `to` |
| `:GcMailQueue` | list the send queue on disk with pending, sending and failed messages |
| `:GcMailbox` | open the mailbox float with the unread mail of every city |
| `:GcMailPanel` | open or close the mailbox as a split below the current window |
| `:GcMailChat [city] [with]` | open a two-window conversation with `with`, by default the mayor |
| `:GcMailChats` | list one line per conversation across every city |
| `:GcMailSearch <text>` | search the mail history of every city for `text` |

## Default keys

`setup()` maps these keys in normal mode. Set the option to `false` to map
none. Each view's own keys are on its page.

| key | what it does | option |
| --- | --- | --- |
| `<Space>mm` | mail the current buffer | `keymap` |
| `<Space>mi` | open the mailbox | `mailbox_keymap` |
| `<Space>mp` | open or close the mail panel | `panel_keymap` |
| `<Space>mc` | open the last chat | `chat_keymap` |
| `<Space>ml` | list the conversations | `chats_keymap` |
| `<Space>ms` | send the message in the chat compose box | `chat_send_keys` |

## Documentation

- [Sending mail](doc/sending.md) covers the picker, subject labels and the send queue.
- [Mailbox](doc/mailbox.md) covers the mailbox float, the mail panel, the preview pane and the background watch.
- [Chat](doc/chat.md) covers the chat window and the conversations list.
- [Search and history](doc/search.md) covers `:GcMailSearch` and the mail history it reads.
- [Configuration](doc/configuration.md) lists every option with its default.
- [Troubleshooting](doc/troubleshooting.md) covers a missing `gc`, a missing city list and a stuck queue.
- `:help gc-mail` is the reference inside Neovim.

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) has the house rules every change follows,
the test suite and the demo recording.

## Version

The current release is 0.1.0. See [CHANGELOG.md](CHANGELOG.md) for the release
notes.

## License

MIT License, Copyright (c) 2026 Nikita Poteryaev. See [LICENSE](LICENSE) for
the full text.
