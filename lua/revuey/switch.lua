-- Checking out a stack layer in the current worktree (`gS`, `:RevueySwitch`): the decision
-- (`plan`, pure), the checks (dirty worktree, untracked files the target would overwrite, a
-- branch checked out in another worktree), the message texts, and the plain `git switch` run.
-- No UI calls: the view asks the questions (a conflicting local name, a connected agent).
--
-- Rules (ARCHITECTURE decision 7, "Switching layers"):
--   * a local layer: `git switch <branch>`;
--   * a remote-tracking layer `origin/x`: a local branch tracking it is switched to; else, when
--     a local `x` exists that tracks something else or nothing, it is never touched (the user may
--     switch to it anyway, or cancel); else `git switch --track origin/x` creates `x`;
--   * already on it: nothing to do. Detached at the layer's tip is not "on it": the switch
--     attaches HEAD to the branch;
--   * refused when tracked files have changes (staged, unstaged, deleted, conflicts): revuey
--     never stashes. Untracked files are carried over as git does, unless the target has a file
--     at the same path (git would refuse to overwrite it): those are named;
--   * refused when the branch is checked out in another worktree (git refuses; we name the path).
local git = require('revuey.git')
local stack_mod = require('revuey.stack')

local M = {}

---@class revuey.SwitchPlan
---@field kind 'noop'|'switch'|'track'|'conflict'
---@field branch string        local branch to end up on
---@field ref? string          remote-tracking ref of the layer (`origin/x`)
---@field upstream? string     conflict: what the local branch tracks ('' = nothing)
---@field attach? boolean      switch: HEAD is detached at the layer (attaching it)
---@field args? string[]       git arguments

---Decide what checking out `layer` means. Pure.
---@param o {layer:{name:string, remote?:boolean, detached?:boolean, is_head?:boolean}, short?:string, current?:string, locals:table<string, string>}
---  `short`: the remote layer's branch name without the remote; `current`: the checked-out
---  branch (nil when detached); `locals`: local branch -> its upstream (`origin/x`, '' for none)
---@return revuey.SwitchPlan
function M.plan(o)
  local layer = o.layer
  if not layer.remote then
    if o.current == layer.name then
      return { kind = 'noop', branch = layer.name }
    end
    return { kind = 'switch', branch = layer.name, attach = layer.detached or nil, args = { 'switch', layer.name } }
  end
  local ref, short = layer.name, o.short or layer.name
  local tracking = {}
  for b, up in pairs(o.locals or {}) do
    if up == ref then
      tracking[#tracking + 1] = b
    end
  end
  -- the branch of the same name first, then alphabetical
  table.sort(tracking, function(a, b)
    if (a == short) ~= (b == short) then
      return a == short
    end
    return a < b
  end)
  if tracking[1] then
    local b = tracking[1]
    if o.current and vim.tbl_contains(tracking, o.current) then
      return { kind = 'noop', branch = o.current, ref = ref }
    end
    return { kind = 'switch', branch = b, ref = ref, args = { 'switch', b } }
  end
  if (o.locals or {})[short] then
    return { kind = 'conflict', branch = short, ref = ref, upstream = o.locals[short] }
  end
  return { kind = 'track', branch = short, ref = ref, args = { 'switch', '--track', ref } }
end

---The plan for "switch to the local branch anyway" after a conflict.
---@param p revuey.SwitchPlan
---@param current? string
---@return revuey.SwitchPlan
function M.anyway(p, current)
  if current == p.branch then
    return { kind = 'noop', branch = p.branch }
  end
  return { kind = 'switch', branch = p.branch, args = { 'switch', p.branch } }
end

---Parse `git status --porcelain=v1 -z --untracked-files=all`: tracked paths with changes
---(staged or not, renames by their new path) and untracked paths.
---@return {tracked:string[], untracked:string[]}
function M.parse_status(out)
  local res = { tracked = {}, untracked = {} }
  local parts = vim.split(out or '', '\0', { plain = true })
  local i = 1
  while i <= #parts do
    local e = parts[i]
    if #e >= 4 then
      local xy, path = e:sub(1, 2), e:sub(4)
      if xy == '??' then
        res.untracked[#res.untracked + 1] = path
      elseif xy ~= '!!' then
        res.tracked[#res.tracked + 1] = path
        if xy:find('[RC]') then
          i = i + 1 -- the rename's source path follows
        end
      end
    end
    i = i + 1
  end
  return res
end

---Parse `git worktree list --porcelain`: branch -> worktree path.
---@return table<string, string>
function M.parse_worktrees(out)
  local res, path = {}, nil
  for line in (out or ''):gmatch('[^\n]*') do
    local p = line:match('^worktree (.+)$')
    if p then
      path = p
    end
    local b = line:match('^branch refs/heads/(.+)$')
    if b and path then
      res[b] = path
    end
  end
  return res
end

---A short list of paths for a message: `a, b, c and 4 more`.
function M.list(paths, max)
  max = max or 3
  local shown = vim.list_slice(paths, 1, max)
  local text = table.concat(shown, ', ')
  if #paths > max then
    text = text .. (' and %d more'):format(#paths - max)
  end
  return text
end

-- ---------------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------------

M.msg = {}

function M.msg.noop(p)
  if p.ref then
    return ('revuey: already on %s (tracks %s)'):format(p.branch, p.ref)
  end
  return ('revuey: already on %s'):format(p.branch)
end

function M.msg.dirty(target, paths)
  return ('revuey: not switching to %s: uncommitted changes in %s. Commit or stash them first (revuey never stashes).')
    :format(target, M.list(paths))
end

function M.msg.untracked(target, paths)
  return ('revuey: not switching to %s: it has files at the paths of untracked %s. Move or remove them first.')
    :format(target, M.list(paths))
end

function M.msg.elsewhere(branch, path)
  return ('revuey: not switching: %s is checked out in another worktree, at %s'):format(branch, path)
end

function M.msg.failed(target, err)
  return ('revuey: git switch to %s failed: %s'):format(target, err)
end

---The question for a conflicting local name, and its choices.
---@return string prompt, string[] items
function M.msg.conflict(p)
  local tracks = (p.upstream and p.upstream ~= '') and ('tracks ' .. p.upstream) or 'tracks no remote branch'
  return ('A local branch %s already exists and %s, not %s. revuey will not change it.'):format(p.branch, tracks, p.ref),
    { ('Switch to the local %s anyway'):format(p.branch), 'Cancel' }
end

---The question when an agent is connected to the review.
---@return string prompt, string[] items
function M.msg.agent(target)
  return ('An agent is connected to this review. Switching the worktree to %s changes the files it may be working on.'):format(target),
    { ('Switch to %s'):format(target), 'Cancel' }
end

function M.msg.done(p, note)
  local text
  if p.kind == 'track' then
    text = ('revuey: created %s tracking %s, and switched to it'):format(p.branch, p.ref)
  elseif p.ref then
    text = ('revuey: switched to %s (tracks %s)'):format(p.branch, p.ref)
  else
    text = ('revuey: switched to %s'):format(p.branch)
  end
  return text .. (note and ('; ' .. note) or '')
end

---What `]s`/`[s` with switch_on_navigate say when the switch is refused: the view moved anyway.
function M.msg.navigate(layer, reason)
  return ('revuey: showing %s, branch not switched: %s'):format(layer, (reason:gsub('^revuey: ', '')))
end

-- ---------------------------------------------------------------------------
-- Git (inside git.async, or blocking outside a coroutine)
-- ---------------------------------------------------------------------------

---Local branches and what each tracks ('' = nothing), the checked-out branch, the branch tips.
local function locals(root)
  local out = git.git({ 'for-each-ref', '--format=%(refname:short)%00%(upstream:short)%00%(objectname)', 'refs/heads' }, root) or ''
  local ups, tips = {}, {}
  for line in out:gmatch('[^\n]+') do
    local b, up, sha = line:match('^(.-)%z(.-)%z(%x+)$')
    if b then
      ups[b], tips[b] = up, sha
    end
  end
  return ups, tips
end

---Everything needed to check out `layer` of `stack` in `root`, and the decision.
---@return {plan:revuey.SwitchPlan, current?:string, tips:table<string, string>, refusal?:string}
function M.prepare(root, layer)
  local current = git.current_branch(root)
  local ups, tips = locals(root)
  local short
  if layer.remote then
    local _, sh = stack_mod.split_remote(layer.name, git.remotes(root))
    short = sh or layer.name
  end
  local p = M.plan({ layer = layer, short = short, current = current, locals = ups })
  local res = { plan = p, current = current, tips = tips }
  if p.kind == 'noop' or p.kind == 'conflict' then
    return res
  end
  res.refusal = M.check(root, p, p.kind == 'switch' and tips[p.branch] or layer.tip)
  return res
end

---Refusal message for running plan `p` now, or nil when it may run.
---@param target_rev string commit the worktree will have (the layer's tip, or the local branch's)
function M.check(root, p, target_rev)
  if p.kind == 'switch' then
    local wts = M.parse_worktrees(git.git({ 'worktree', 'list', '--porcelain' }, root))
    local at = wts[p.branch]
    if at and vim.fs.normalize(vim.uv.fs_realpath(at) or at) ~= vim.fs.normalize(vim.uv.fs_realpath(root) or root) then
      return M.msg.elsewhere(p.branch, at)
    end
  end
  local st = M.parse_status(git.git({ 'status', '--porcelain=v1', '-z', '--untracked-files=all' }, root))
  if #st.tracked > 0 then
    return M.msg.dirty(p.branch, st.tracked)
  end
  if #st.untracked > 0 and target_rev then
    -- untracked files are kept, as git does, unless the target has a file there
    local args = { '--literal-pathspecs', 'ls-tree', '-r', '-z', '--name-only', target_rev, '--' }
    vim.list_extend(args, vim.list_slice(st.untracked, 1, 500))
    local hit = {}
    for _, path in ipairs(vim.split(git.git(args, root) or '', '\0', { trimempty = true })) do
      hit[#hit + 1] = path
    end
    table.sort(hit)
    if #hit > 0 then
      return M.msg.untracked(p.branch, hit)
    end
  end
end

---Run the plan's `git switch`. Returns nil, or an error message (git's own, with the path of
---another worktree when git names one).
function M.run(root, p)
  local cmd = { 'git', 'switch', '--quiet' }
  vim.list_extend(cmd, vim.list_slice(p.args, 2))
  local res = git.system(cmd, { cwd = root, text = true })
  if res.code == 0 then
    return nil
  end
  local err = vim.trim(res.stderr or '')
  local path = err:match("already used by worktree at '([^']+)'") or err:match("already checked out at '([^']+)'")
  if path then
    return M.msg.elsewhere(p.branch, path)
  end
  return M.msg.failed(p.branch, err:gsub('^fatal: ', ''):gsub('\n', ' '))
end

return M
