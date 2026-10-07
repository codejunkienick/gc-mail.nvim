-- :GcMail works without setup(); the module loads only when it runs.
-- setup() adds the <Space>mm mapping.
vim.api.nvim_create_user_command('GcMail', function()
  require('gc_mail').open()
end, { desc = 'Mail the buffer to a gc city mayor' })
