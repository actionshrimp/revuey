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

vim.api.nvim_create_user_command('RevueySwitch', function(cmd)
  require('revuey').switch(cmd.args ~= '' and cmd.args or nil)
end, {
  nargs = '?',
  desc = 'Check out a stack layer of the open review in this worktree (default: the viewed layer)',
  complete = function(arg)
    local ok, view = pcall(require, 'revuey.view')
    return vim.tbl_filter(function(n)
      return vim.startswith(n, arg)
    end, ok and view.layer_names() or {})
  end,
})

vim.api.nvim_create_user_command('RevueyStackIgnore', function(cmd)
  require('revuey').stack_ignore(cmd.bang, cmd.args)
end, {
  nargs = '?',
  bang = true,
  desc = 'Hide stack notes about branches matching a glob (per repo); ! removes the pattern; no arg: list',
  complete = function(arg)
    return branches(arg)
  end,
})

vim.api.nvim_create_user_command('RevueyGuide', function(cmd)
  require('revuey').guide(cmd.bang, cmd.args ~= '' and cmd.args or nil)
end, {
  nargs = '?',
  bang = true,
  desc = 'Toggle the AI guide view of the review (offers to generate one); ! regenerates; cancel stops a run',
  complete = function(arg)
    return vim.startswith('cancel', arg) and { 'cancel' } or {}
  end,
})

vim.api.nvim_create_user_command('RevueyGuideDiagram', function(cmd)
  require('revuey').guide_diagram(cmd.fargs[1], cmd.fargs[2])
end, {
  nargs = '*',
  desc = "Copy the guide's overview diagram as Mermaid text: mermaid [register] (default +)",
  complete = function(arg, line)
    if #vim.split(line, '%s+', { trimempty = true }) <= 2 and vim.startswith('mermaid', arg) then
      return { 'mermaid' }
    end
    return {}
  end,
})

vim.api.nvim_create_user_command('RevueyAIReview', function(cmd)
  require('revuey').ai_review(cmd.bang, cmd.args ~= '' and cmd.args or nil)
end, {
  nargs = '?',
  bang = true,
  desc = 'AI review of the open review (claude, read-only): findings to triage; [skill]; ! replaces without asking; cancel',
  complete = function(arg)
    local s = package.loaded['revuey.view'] and package.loaded['revuey.view'].session
    local root = s and s.review and s.review.root or vim.fn.getcwd()
    local list = require('revuey.ai_review').skill_names(root)
    table.insert(list, 1, 'cancel')
    return vim.tbl_filter(function(x)
      return vim.startswith(x, arg)
    end, list)
  end,
})

vim.api.nvim_create_user_command('RevueyComments', function()
  require('revuey').comments()
end, { desc = 'List the comments of the open review (<CR> jumps)' })

vim.api.nvim_create_user_command('RevueyCommentsExport', function(cmd)
  require('revuey').comments_export(cmd.fargs)
end, {
  nargs = '*',
  desc = 'Export the review comments: [markdown|json] [--all] [register|file] (default: markdown to +)',
  complete = function(arg)
    return vim.tbl_filter(function(x)
      return vim.startswith(x, arg)
    end, { 'markdown', 'json', '--all' })
  end,
})
