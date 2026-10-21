if vim.g.loaded_revuey then
  return
end
vim.g.loaded_revuey = true

vim.api.nvim_create_user_command('Revuey', function(cmd)
  local opts = {}
  for _, a in ipairs(cmd.fargs) do
    if a == '--committed' then
      opts.mode = 'committed'
    elseif a == '--worktree' then
      opts.mode = 'worktree'
    elseif a:sub(1, 2) == '--' then
      return vim.notify('revuey: unknown flag ' .. a .. ' (use --committed or --worktree)', vim.log.levels.ERROR)
    else
      opts.base = a
    end
  end
  require('revuey').open(opts)
end, {
  nargs = '*',
  desc = 'Review the current branch (incl. uncommitted work) against a base; --committed for commits only',
  complete = function(arg)
    if arg:sub(1, 1) == '-' then
      return vim.tbl_filter(function(f)
        return vim.startswith(f, arg)
      end, { '--committed', '--worktree' })
    end
    local out = vim.fn.systemlist({ 'git', 'for-each-ref', '--format=%(refname:short)', 'refs/heads', 'refs/remotes' })
    if vim.v.shell_error ~= 0 then
      return {}
    end
    return vim.tbl_filter(function(r)
      return vim.startswith(r, arg)
    end, out)
  end,
})

vim.api.nvim_create_user_command('RevueyClose', function()
  require('revuey').close()
end, { desc = 'Close the current review' })
