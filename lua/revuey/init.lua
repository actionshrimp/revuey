local M = {}

---@param opts? table see lua/revuey/config.lua for defaults
function M.setup(opts)
  require('revuey.config').set(opts)
end

---Open a review of the current branch. Without `base` the local stack around HEAD is detected
---and the review opens at HEAD's layer; `scope = 'full'` opens the whole stack against trunk.
---With an explicit `base` (and no scope) it is the plain single-branch review.
---@param opts? {base?:string, scope?:'full', mode?:'worktree'|'committed', cwd?:string, standalone?:boolean, on_ready?:fun(session)}
function M.open(opts)
  require('revuey.view').open(opts)
end

---Parse `:Revuey` / `bin/revuey` arguments: [base] [--stack] [--committed|--worktree].
---@param args string[]
---@return table? opts, string? err
function M.parse_args(args)
  local opts = {}
  for _, a in ipairs(args) do
    if a == '--committed' then
      opts.mode = 'committed'
    elseif a == '--worktree' then
      opts.mode = 'worktree'
    elseif a == '--stack' then
      opts.scope = 'full'
    elseif a:sub(1, 2) == '--' then
      return nil, 'unknown flag ' .. a .. ' (use --stack, --committed or --worktree)'
    elseif opts.base then
      return nil, 'more than one base given: ' .. opts.base .. ', ' .. a
    else
      opts.base = a
    end
  end
  return opts
end

---Open from command-line style arguments (used by :Revuey and bin/revuey).
---@param args string[]
---@param extra? table merged into the parsed options
function M.open_args(args, extra)
  local opts, err = M.parse_args(args)
  if not opts then
    return vim.notify('revuey: ' .. err, vim.log.levels.ERROR)
  end
  M.open(vim.tbl_extend('force', opts, extra or {}))
end

function M.close()
  require('revuey.view').close()
end

---Set (or with parent = '' clear) the explicit stack parent of the layer being reviewed, or of
---the current branch. Without `parent`, pick from a list.
---@param parent? string
function M.stack_parent(parent)
  require('revuey.view').stack_parent(parent)
end

---`:RevueyGuide[!] [cancel]`: toggle the AI guide view (offering to generate a guide when there is
---none); `bang` generates a new one; `arg = 'cancel'` stops a running generation.
---@param bang? boolean
---@param arg? string
function M.guide(bang, arg)
  require('revuey.view').guide_command(bang, arg)
end

---`:RevueyGuideDiagram mermaid [register]`: copy the guide's overview diagram as Mermaid
---flowchart text (default register: `+` when there is a clipboard, else `"`).
---@param what? string
---@param reg? string
function M.guide_diagram(what, reg)
  return require('revuey.view').guide_diagram(what, reg)
end

return M
