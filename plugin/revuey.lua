if vim.g.loaded_revuey then
  return
end
vim.g.loaded_revuey = true

local function branches(arg)
  local out = vim.fn.systemlist({ 'git', 'for-each-ref', '--format=%(refname:short)', 'refs/heads', 'refs/remotes' })
  if vim.v.shell_error ~= 0 then
    return {}
  end
  return vim.tbl_filter(function(r)
    return vim.startswith(r, arg)
  end, out)
end

vim.api.nvim_create_user_command('Revuey', function(cmd)
  require('revuey').open_args(cmd.fargs)
end, {
  nargs = '*',
  desc = 'Review the current branch or its local stack (incl. uncommitted work); [base] [--stack] [--committed]',
  complete = function(arg)
    if arg:sub(1, 1) == '-' then
      return vim.tbl_filter(function(f)
        return vim.startswith(f, arg)
      end, { '--stack', '--committed', '--worktree' })
    end
    return branches(arg)
  end,
})

vim.api.nvim_create_user_command('RevueyClose', function()
  require('revuey').close()
end, { desc = 'Close the current review' })

vim.api.nvim_create_user_command('RevueyStackParent', function(cmd)
  require('revuey').stack_parent(cmd.args ~= '' and cmd.args or nil)
end, {
  nargs = '?',
  desc = 'Set the stack parent of the reviewed layer (or current branch); --clear removes it; no arg: pick',
  complete = function(arg)
    local list = branches(arg)
    if vim.startswith('--clear', arg) then
      table.insert(list, 1, '--clear')
    end
    return list
  end,
})
