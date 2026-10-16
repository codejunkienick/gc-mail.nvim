# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-16

### Added

- Send queue (`:GcMail`, `:GcMailQueue`): mail the current buffer through an
  on-disk queue that survives restarts, with delayed retries, one sender at a
  time, and rules that keep several editors sharing one queue consistent.
- Mailbox (`:GcMailbox`): unread mail across every registered city in one
  float, newest first, with one strict decoder per answer shape and
  apply-only-while-current updates, bulk mark, read, unread, archive and
  delete, plus an all-mail mode over the loaded history.
- Mail panel (`:GcMailPanel`): the same mailbox docked as a split below the
  current window, kept live from each city's event log with a periodic
  re-list fallback, never moving the cursor.
- Preview: the message body beside the mailbox and panel lists, drawn from
  the listed message with no extra call, shown or hidden per view.
- Background watch (on by default): arrival notices, per-city unread counts
  refreshed from the event log, and a statusline function that runs nothing.
- Chat (`:GcMailChat`, `:GcMailChats`): a two-window conversation with a
  correspondent, with live arrivals, automatic read marks with stale-answer
  guards, scroll holding with a newer-below count, remembered sizes, and a
  conversations list with unread counts.
- Search (`:GcMailSearch`): plain-text, case-insensitive search over the
  cached history of every city, loading each city's history once where
  needed.
- History: history loads from the bead store with a strict decoder, cached
  per city and shared by the mailbox, chat, and search.
- Docs and demo: a public audience README, the `:help gc-mail` vimdoc, and
  the showcase recording embedded as an animated WebP with a GIF fallback
  beside the full video link.

[unreleased]: https://github.com/codejunkienick/gc-mail.nvim/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/codejunkienick/gc-mail.nvim/releases/tag/v0.1.0
