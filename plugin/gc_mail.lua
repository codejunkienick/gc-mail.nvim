-- :GcMail, :GcMailQueue, :GcMailbox, :GcMailPanel, :GcMailChat, :GcMailChats
-- and :GcMailSearch work without setup(); the module loads only when one runs.
-- setup() adds the <Space>mm, <Space>mi, <Space>mp, <Space>mc and <Space>ml
-- mappings, resumes the send queue and preloads the city list after startup.
vim.api.nvim_create_user_command('GcMail', function(opts)
  local to = vim.trim(opts.args or '') ~= '' and vim.trim(opts.args) or nil
  require('gc_mail').open(to)
end, { desc = 'Mail the buffer to a gc city mayor or recipient', nargs = '?' })
vim.api.nvim_create_user_command('GcMailQueue', function()
  require('gc_mail').open_queue()
end, { desc = 'List the gc-mail send queue' })
vim.api.nvim_create_user_command('GcMailbox', function()
  require('gc_mail.mailbox').open()
end, { desc = 'Open the gc mailbox' })
vim.api.nvim_create_user_command('GcMailPanel', function()
  require('gc_mail.panel').toggle()
end, { desc = 'Toggle the gc mail panel' })
vim.api.nvim_create_user_command('GcMailChat', function(opts)
  require('gc_mail.chat').command(opts.fargs)
end, { desc = 'Open the gc chat window', nargs = '*' })
vim.api.nvim_create_user_command('GcMailChats', function()
  require('gc_mail.chat').open_list()
end, { desc = 'List the gc conversations with their unread counts' })
vim.api.nvim_create_user_command('GcMailSearch', function(opts)
  require('gc_mail.search').run(opts.args)
end, { desc = 'Search the mail history of every city', nargs = '+' })
