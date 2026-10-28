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

---Open from command-line style arguments (used by :Revuey and bin/revuey). `pr <N|url|cancel>`
---reviews a pull request in its own worktrunk worktree (M.pr).
---@param args string[]
---@param extra? table merged into the parsed options
function M.open_args(args, extra)
  if args[1] == 'pr' then
    if #args > 2 then
      return vim.notify('revuey: usage: :Revuey pr <number|url> (or :Revuey pr cancel)', vim.log.levels.ERROR)
    end
    return M.pr(args[2])
  end
  local opts, err = M.parse_args(args)
  if not opts then
    return vim.notify('revuey: ' .. err, vim.log.levels.ERROR)
  end
  M.open(vim.tbl_extend('force', opts, extra or {}))
end

---`:Revuey pr <N|url>`: run `wt switch pr:<N> --no-cd` (worktrunk; your hooks set the worktree
---up) in the background, then open the review in that worktree in a new tab (`:tcd` to it).
---`cancel` stops a running setup.
---@param arg? string
---@param opts? {cwd?:string, on_open?:fun(session)}
function M.pr(arg, opts)
  require('revuey.pr_view').command(arg, opts)
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

---`:RevueyStackIgnore [pattern]` adds a branch glob to the repo's ignore list for stack notes;
---with `bang` it removes it; with no pattern it lists the ignore list.
---@param bang? boolean
---@param pattern? string
function M.stack_ignore(bang, pattern)
  require('revuey.view').stack_ignore_command(bang, pattern)
end

---`:RevueySwitch [layer]`: check out a stack layer of the open review in this worktree
---(`git switch`; the viewed layer when `layer` is nil).
---@param layer? string
function M.switch(layer)
  require('revuey.view').switch_command(layer)
end

---Open the stack notes float of the open review (details and actions).
function M.stack_notes()
  local view = require('revuey.view')
  require('revuey.notes_float').open(view.session)
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

---`:RevueyAIReview[!] [skill|cancel]`: run an AI review of the open review's scope with your
---`claude` CLI (read-only); its findings become AI comments to accept (`ca`) or dismiss (`cn`).
---`skill`: a skill name or path whose SKILL.md guides the review. `bang` replaces the last
---review's untriaged findings without asking; `cancel` stops a run.
---@param bang? boolean
---@param arg? string
function M.ai_review(bang, arg)
  require('revuey.view').ai_review_command(bang, arg)
end

---`:RevueyComments`: all comments of the open review in a float (<CR> jumps to one).
function M.comments()
  return require('revuey.view').comments_list()
end

---`:RevueySubmit [approve|comment|request-changes|pending]`: post the comments added to the
---review (`ci`) to GitHub as one review with that verdict (asked when not given), after a
---confirmation; `pending` adds them to your pending review on GitHub without submitting.
---@param verdict? string
function M.submit(verdict)
  return require('revuey.view').submit(verdict)
end

---`:RevueyCommentsExport [markdown|json] [--all] [register|file]`: export the review's comments
---(default: Markdown for an AI session, to the `+` register). Returns the text.
---@param args? string[]
function M.comments_export(args)
  return require('revuey.view').comments_export(args or {})
end

return M
