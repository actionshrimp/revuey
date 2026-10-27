-- Checking out a stack layer in the current worktree (`gS`, `:RevueySwitch`): the decision
-- (`plan`, pure), the checks (dirty worktree, untracked files the target would overwrite, a
-- branch checked out in another worktree), the message texts, and the plain `git switch` run.
-- No UI calls: the view asks the question (a conflicting local name) and tells a connected agent
-- (agent_link.tell_switch).
--
-- Rules (ARCHITECTURE decision 7, "Switching layers"):
--   * a local layer: `git switch <branch>`;
--   * a remote-tracking layer `origin/x`: a local branch tracking it is switched to; else, when
--     a local `x` exists that tracks something else or nothing, it is never touched (the user may
--     switch to it anyway, or cancel); else `git switch --track origin/x` creates `x`;
--   * already on it: nothing to do. Detached at the layer's tip is not "on it": the switch
--     attaches HEAD to the branch;
--   * refused when tracked files have changes (staged, unstaged, deleted, conflicts; submodule
--     pointers and contents are ignored: git switch leaves submodule checkouts alone): revuey
--     never stashes. Untracked files are carried over as git does, unless the switch would write
--     a file at their path (or under a file in their place): untracked and ignored ones alike
--     (git would refuse for untracked files and silently overwrite ignored ones). They are named;
--   * refused when the branch is checked out in another worktree (git refuses; we name the path);
--   * a layer above a remote-tracking layer gets `branch.<b>.revueyParent` set to it (`set_parent`),
--     since on a local branch remote refs are only layers when a parent setting names them.
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
  return ('revuey: not switching to %s: it has files at the paths of untracked or ignored %s. Move or remove them first.')
    :format(target, M.list(paths))
end

function M.msg.unsaved(target, paths)
  return ('revuey: not switching to %s: unsaved changes in buffers for %s. Write or discard them first.')
    :format(target, M.list(paths))
end

function M.msg.kept_parent(branch, existing, suggested)
  return ('revuey: kept your stack parent of %s (%s); this stack has %s below it'):format(branch, existing, suggested)
end

function M.msg.busy()
  return 'revuey: a switch is already running; this one is dropped'
end

function M.msg.hook(target, err)
  return ('revuey: switched to %s, but git reported an error (a hook?): %s'):format(target, err)
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

---The note on the done message for what agent_link.tell_switch did (nil: nothing to say).
---@param told? 'told'|'later'|'failed'|'unchanged'
function M.msg.told(told)
  if told == 'told' then
    return 'told the connected agent'
  elseif told == 'later' then
    return 'the connected agent is told when you stop switching'
  elseif told == 'failed' then
    return 'could not tell the connected agent (see revuey.log)'
  end
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

---Which paths would the switch write over? `changes`: {status, path} from `git diff --name-status
---HEAD <target>`; `kind(path)`: 'file', 'directory' or nil for what is in the worktree there. Clean
---tracked files are already known; so anything at an added path (or a non-directory in place of
---one of its parent directories) is untracked or ignored. A directory at an added path only
---collides when the switch removes nothing under it (it holds no tracked files). Pure.
---@param changes {[1]:string, [2]:string}[]
---@param kind fun(path:string):string?
---@return string[] sorted
function M.collisions(changes, kind)
  local removed, hits, seen = {}, {}, {}
  for _, c in ipairs(changes) do
    if c[1] == 'D' then
      removed[c[2]] = true
    end
  end
  local function removes_under(dir)
    for path in pairs(removed) do
      if vim.startswith(path, dir .. '/') then
        return true
      end
    end
    return false
  end
  local function hit(path)
    if not seen[path] then
      seen[path] = true
      hits[#hits + 1] = path
    end
  end
  for _, c in ipairs(changes) do
    if c[1] == 'A' then
      local path = c[2]
      local k = kind(path)
      if k == 'directory' then
        if not removes_under(path) then
          hit(path)
        end
      elseif k then
        hit(path)
      else
        -- a file (or link) where the target needs a directory
        local dir = vim.fs.dirname(path)
        while dir and dir ~= '.' and dir ~= '' and dir ~= '/' do
          local dk = kind(dir)
          if dk and dk ~= 'directory' and not removed[dir] then
            hit(dir)
            break
          end
          dir = vim.fs.dirname(dir)
        end
      end
    end
  end
  table.sort(hits)
  return hits
end

---The parent setting to record when checking out `layers[index]` as plan `p`: the layer below's
---name when it is a remote-tracking layer (on a local branch, remote refs are layers only when a
---parent setting names them) and the layer's parent was inferred (a revuey or Graphite setting
---already says it). Never for the bottom layer (its parent is trunk), never for a branch other
---than the layer's own (the "switch anyway" to an unrelated local branch), never itself. Pure.
---@param layers revuey.Layer[]
---@param index integer
---@param p revuey.SwitchPlan
---@return string?
function M.parent_setting(layers, index, p)
  local layer, below = layers[index], layers[index - 1]
  if not (layer and below and below.remote) then
    return nil
  end
  if layer.source ~= 'inferred' or layer.parent ~= below.name then
    return nil
  end
  if layer.remote and not p.ref then
    return nil -- an unrelated local branch of the same name
  end
  if p.branch == below.name then
    return nil
  end
  return below.name
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
  local st = M.parse_status(git.git({ 'status', '--porcelain=v1', '-z', '--untracked-files=all', '--ignore-submodules=all' }, root))
  if #st.tracked > 0 then
    return M.msg.dirty(p.branch, st.tracked)
  end
  if target_rev then
    -- what the switch writes that is not in HEAD: anything on disk there is untracked or ignored
    local out = git.git({ 'diff', '--name-status', '-z', '--no-renames', '--ignore-submodules=all', 'HEAD', target_rev, '--' }, root) or ''
    local parts = vim.split(out, '\0', { trimempty = true })
    local changes = {}
    for i = 1, #parts - 1, 2 do
      changes[#changes + 1] = { parts[i], parts[i + 1] }
    end
    local hits = M.collisions(changes, function(path)
      local stat = vim.uv.fs_lstat(vim.fs.joinpath(root, path))
      return stat and stat.type or nil
    end)
    if #hits > 0 then
      return M.msg.untracked(p.branch, hits)
    end
  end
end

---Record the layer below as the explicit stack parent of `branch` (`branch.<b>.revueyParent`;
---`git branch -d` removes it with the branch), but never over a setting that exists (the user's,
---or an earlier switch's), and only when `parent` is an ancestor of the branch (a local copy
---behind a restack of the remote stack is not built on it).
---@return 'set'|'kept'|'same'|'skipped' what, string? message (a note for 'kept', an error)
function M.record_parent(root, branch, parent)
  local key = 'branch.' .. branch .. '.revueyParent'
  local existing = vim.trim(git.git({ 'config', '--get', key }, root) or '')
  if existing == parent then
    return 'same'
  elseif existing ~= '' then
    return 'kept', M.msg.kept_parent(branch, existing, parent)
  end
  if not git.is_ancestor(parent, 'refs/heads/' .. branch, root) then
    return 'skipped'
  end
  local _, err = git.git({ 'config', key, parent }, root)
  if err then
    return 'skipped', 'revuey: could not record the stack parent: ' .. err
  end
  return 'set'
end

---Run the plan's `git switch`. Returns nil, or an error message (git's own, with the path of
---another worktree when git names one).
---A failing `post-checkout` hook makes git exit non-zero after HEAD moved: then the second value
---is a warning and the switch counts as done.
---@return string? err, string? warning
function M.run(root, p)
  local cmd = { 'git', 'switch', '--quiet' }
  vim.list_extend(cmd, vim.list_slice(p.args, 2))
  local res = git.system(cmd, { cwd = root, text = true })
  if res.code == 0 then
    return nil
  end
  local err = vim.trim(res.stderr or '')
  if git.current_branch(root) == p.branch then
    return nil, M.msg.hook(p.branch, (err:gsub('\n', ' ')))
  end
  local path = err:match("already used by worktree at '([^']+)'") or err:match("already checked out at '([^']+)'")
  if path then
    return M.msg.elsewhere(p.branch, path)
  end
  return M.msg.failed(p.branch, err:gsub('^fatal: ', ''):gsub('\n', ' '))
end

return M
