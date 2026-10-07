-- :GcMail, :GcMailQueue and :GcMailbox work without setup(); the module loads
-- only when one runs. setup() adds the <Space>mm and <Space>mi mappings,
-- resumes the send queue and preloads the city list after startup.
vim.api.nvim_create_user_command('GcMail', function()
  require('gc_mail').open()
end, { desc = 'Mail the buffer to a gc city mayor' })
vim.api.nvim_create_user_command('GcMailQueue', function()
  require('gc_mail').open_queue()
end, { desc = 'List the gc-mail send queue' })
vim.api.nvim_create_user_command('GcMailbox', function()
  require('gc_mail.mailbox').open()
end, { desc = 'Open the gc mailbox' })
