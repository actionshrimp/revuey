-- Stack model plus local stack detection. The model (layers with a tip, a parent rev and a
-- reviewed-state key) does not assume layers are local branches, so other sources (e.g. PR
-- stacks) can produce a revuey.Stack and reuse the same UI and scopes.
--
-- A stack is an ordered list of layers, bottom (next to trunk) first. Each layer is reviewed
-- against its parent layer's tip ("layer scope"), or the whole stack against trunk ("full scope").
--
-- Local detection (no UI calls) is split in two:
--   * `M.resolve(input)` is pure: given branch tips, a first-parent commit graph of everything not
--     reachable from trunk, and explicit parents (Graphite metadata, `branch.<b>.revueyParent`),
--     it builds the stack. It may ask for more history (`need`) when an explicit parent points
--     at a branch whose commits haven't been loaded yet.
--   * `M.detect(root, trunk)` gathers that input with a handful of git calls (async inside a
--     `git.async` coroutine) and loops `resolve` until nothing more is needed.
--
-- The heuristic parent of a branch is the nearest other local branch tip on its first-parent
-- line above trunk. It cannot tell a parent from a child branch cut mid-way (the "child-branch
-- trap"), so ambiguous cases (several branches at one commit, forks) are reported as notes and
-- can be fixed with an explicit parent (`:RevueyStackParent`); nothing inferred is ever persisted.
local git = require('revuey.git')
local state = require('revuey.state')

local M = {}

---@class revuey.Layer
---@field name string           display name (a branch name for local stacks)
---@field tip string            commit of the layer head
---@field parent string         parent layer name, or the trunk name for the bottom layer
---@field parent_rev string     rev of the parent's tip (diff base = merge-base(parent_rev, tip))
---@field source string         how the parent was found: 'inferred'|'graphite'|'config'|...
---@field is_head boolean       the layer is the checked-out HEAD (working-tree changes belong here)
---@field also? string[]        other branches pointing at the same commit
---@field state_branch string   reviewed-state key: layer identity
---@field state_base string     reviewed-state key: parent identity (normalised)
---@field title? string         optional description shown after the name
---@field dimmed? boolean       shown dimmed (e.g. already landed)
---@field landed? boolean       its changes are already in trunk (squash-merged)
---@field diverged? boolean     not restacked on its moved parent: diffed from the parent's old tip
---@field stale? boolean        explicit parent that is not an ancestor: diffed against trunk
---@field skipped? integer      commits at its bottom already squash-merged into trunk, left out
---@field key_old? boolean      reviewed marks also key on the old side (parent content)
---@field stats? {commits?:integer, files?:integer, reviewed?:integer}

---@class revuey.Stack
---@field kind string           'local' (other sources may add kinds)
---@field trunk string
---@field trunk_rev string
---@field trunk_state string    normalised trunk for state keys
---@field base_rev? string      full-scope old side when the bottom layer skips squash-merged commits
---@field layers revuey.Layer[] bottom first
---@field current integer       layer to open at (e.g. HEAD's branch)
---@field forks {at:string, children:string[]}[]
---@field notes string[]
---@field state_repo? string    reviewed-state repo key (nil = repo root)

---Pick one of several names at the same commit, deterministically: `prefer` if present, else one
---with an explicit parent, else the alphabetically first. Returns the pick and the others.
---@param names string[]
---@return string, string[]
function M.pick(names, prefer, explicit)
  names = vim.deepcopy(names)
  table.sort(names)
  local chosen
  if prefer and vim.tbl_contains(names, prefer) then
    chosen = prefer
  else
    for _, n in ipairs(names) do
      if explicit and explicit[n] then
        chosen = n
        break
      end
    end
    chosen = chosen or names[1]
  end
  local others = {}
  for _, n in ipairs(names) do
    if n ~= chosen then
      others[#others + 1] = n
    end
  end
  return chosen, others
end

---Format a list for a note, capped: "a, b, c and 12 more".
function M.list(names, max)
  max = max or 3
  if #names <= max then
    return table.concat(names, ', ')
  end
  return table.concat(vim.list_slice(names, 1, max), ', ') .. (' and %d more'):format(#names - max)
end

local function short(sha)
  return (sha or ''):sub(1, 8)
end

---@class revuey.StackInput
---@field trunk string                  trunk label (e.g. "main" or "origin/main")
---@field trunk_rev string              trunk commit
---@field trunk_names table<string, true> names that mean trunk (e.g. origin/main and main)
---@field current? string               checked-out branch (nil = detached: no stack)
---@field head string                   HEAD commit
---@field branches table<string, string> local branch -> tip
---@field graph table<string, string>   commit -> first parent ('' when the parent is in trunk);
---                                     only commits not reachable from trunk
---@field merges? table<string, string[]> commit -> further parents that are in `graph`
---@field loaded table<string, true>    tips whose history is in `graph` (absent = merged into trunk)
---@field above? string[]               branches that may sit above HEAD (contain HEAD or an old tip
---                                     of a stack branch)
---@field owned? table<string, string[]> commit -> branches that used to point at it (reflog; branch
---                                     creation and resets excluded): links a branch that moved
---                                     (amend, new commit, rebase) to children left on its old tip
---@field explicit? table<string, {parent:string, source:string}>
---@field normalize? fun(name:string):string  state-key normalisation of parent names

---Resolve the stack around the current branch.
---@param input revuey.StackInput
---@return revuey.Stack? stack nil when there is no stack (or more history is needed)
---@return string[]? need tips whose history must be loaded into `graph` before resolving again
function M.resolve(input)
  local trunk, graph, branches = input.trunk, input.graph, input.branches
  local loaded, explicit = input.loaded or {}, input.explicit or {}
  local owned, merges = input.owned or {}, input.merges or {}
  local normalize = input.normalize or function(n)
    return n
  end
  local function is_trunk(name)
    return input.trunk_names[name] == true
  end
  if not input.current or is_trunk(input.current) or graph[input.head] == nil then
    return nil
  end
  local at = {} -- tip -> names (trunk names excluded)
  for name, sha in pairs(branches) do
    if not is_trunk(name) then
      at[sha] = at[sha] or {}
      table.insert(at[sha], name)
    end
  end
  local need, need_set = {}, {}
  local function want(sha)
    if not need_set[sha] then
      need_set[sha] = true
      need[#need + 1] = sha
    end
  end
  local notes, noted = {}, {}
  local function note(msg)
    if not noted[msg] then
      noted[msg] = true
      notes[#notes + 1] = msg
    end
  end
  local function status(sha)
    if graph[sha] ~= nil then
      return 'stack'
    end
    return loaded[sha] and 'merged' or 'unknown'
  end
  local anc = {}
  ---Is commit `a` an ancestor of (or equal to) `b`? Both above trunk; follows merge parents.
  local function is_ancestor(a, b)
    if a == b then
      return true
    end
    if graph[a] == nil or graph[b] == nil then
      return false
    end
    local key = a .. b
    if anc[key] == nil then
      local seen, queue, found = { [b] = true }, { b }, false
      while #queue > 0 and not found do
        local c = table.remove(queue)
        local ps = { graph[c] }
        vim.list_extend(ps, merges[c] or {})
        for _, p in ipairs(ps) do
          if p == a then
            found = true
            break
          end
          if p and p ~= '' and graph[p] ~= nil and not seen[p] then
            seen[p] = true
            queue[#queue + 1] = p
          end
        end
      end
      anc[key] = found
    end
    return anc[key]
  end
  ---Nearest commit on `tip`'s first-parent line that `owner` used to point at.
  local function old_tip_of(owner, tip)
    local c = graph[tip]
    while c and c ~= '' and graph[c] ~= nil do
      for _, n in ipairs(owned[c] or {}) do
        if n == owner then
          return c
        end
      end
      c = graph[c]
    end
  end

  local parents = {} -- name -> {parent, source, fork?, diverged?, stale?}
  ---@return {parent:string, source:string, fork?:string, diverged?:boolean, stale?:boolean}? nil = history needed
  local function parent_of(name)
    if parents[name] then
      return parents[name]
    end
    local tip = branches[name]
    local res
    local ex = explicit[name]
    if ex then
      local p = ex.parent
      if is_trunk(p) then
        res = { parent = trunk, source = ex.source }
      elseif branches[p] and p ~= name then
        local st = status(branches[p])
        if st == 'unknown' then
          want(branches[p])
          return nil
        elseif st == 'merged' then
          note(('%s (parent of %s) is already in %s'):format(p, name, trunk))
          res = { parent = trunk, source = ex.source }
        elseif is_ancestor(branches[p], tip) then
          res = { parent = p, source = ex.source }
        else
          local fork = old_tip_of(p, tip)
          if fork then
            res = { parent = p, source = ex.source, fork = fork, diverged = true }
          else
            -- not built on the parent at all (e.g. rebased onto trunk after the parent landed)
            note(('%s (%s parent of %s) is not an ancestor of %s: showing %s against %s. Fix it, or :RevueyStackParent --clear'):format(
              p,
              ex.source,
              name,
              name,
              name,
              trunk
            ))
            res = { parent = p, source = ex.source, fork = input.trunk_rev, stale = true }
          end
        end
      else
        note(('ignoring %s parent "%s" of %s: no such local branch'):format(ex.source, p, name))
      end
    end
    if not res then
      res = { parent = trunk, source = 'inferred' }
      local c = graph[tip]
      local steps = 0
      while c and c ~= '' and graph[c] ~= nil and steps < 100000 do
        if at[c] then
          res = { parent = (M.pick(at[c], input.current, explicit)), source = 'inferred' }
          break
        end
        if owned[c] then
          -- a branch that used to point here has moved on (amend, new commits, rebase)
          local owners = {}
          for _, n in ipairs(owned[c]) do
            local t = branches[n]
            if n ~= name and t and not is_trunk(n) then
              local st = status(t)
              if st == 'unknown' then
                want(t)
              elseif st == 'stack' and not is_ancestor(tip, t) then
                owners[#owners + 1] = n
              end
            end
          end
          if #need > 0 then
            return nil
          end
          if #owners > 0 then
            local p = M.pick(owners, input.current, explicit)
            if is_ancestor(branches[p], tip) then
              res = { parent = p, source = 'inferred' } -- parent merged into this branch: fine
            else
              res = { parent = p, source = 'inferred', fork = c, diverged = true }
            end
            break
          end
        end
        c = graph[c]
        steps = steps + 1
      end
    end
    parents[name] = res
    return res
  end

  -- Down: from the current branch to trunk.
  local chain, seen = {}, {}
  local name = input.current
  while true do
    seen[name] = true
    local p = parent_of(name)
    if not p then
      return nil, need
    end
    table.insert(chain, 1, { name = name, info = p })
    if p.parent == trunk then
      break
    end
    if seen[p.parent] then
      note(('parent cycle at %s; treating %s as based on %s'):format(p.parent, name, trunk))
      chain[1].info = { parent = trunk, source = p.source }
      break
    end
    if not branches[p.parent] or status(branches[p.parent]) ~= 'stack' then
      if branches[p.parent] and status(branches[p.parent]) == 'unknown' then
        want(branches[p.parent])
        return nil, need
      end
      break
    end
    name = p.parent
  end

  -- Up: follow the single child while there is exactly one.
  local forks = {}
  local candidates, cand_set = {}, {}
  for _, c in ipairs(input.above or {}) do
    if not cand_set[c] and branches[c] and not is_trunk(c) then
      cand_set[c] = true
      candidates[#candidates + 1] = c
    end
  end
  local x = input.current
  while true do
    -- explicit children of x are candidates even when they don't contain it (not restacked)
    for n, ex in pairs(explicit) do
      if ex.parent == x and not cand_set[n] and branches[n] and not is_trunk(n) then
        cand_set[n] = true
        candidates[#candidates + 1] = n
      end
    end
    table.sort(candidates)
    local by_tip, tips = {}, {}
    for _, c in ipairs(candidates) do
      local tip = branches[c]
      if not seen[c] and tip ~= branches[x] then
        local st = status(tip)
        if st == 'unknown' then
          want(tip)
        elseif st == 'stack' then
          local p = parent_of(c)
          if not p then
            return nil, need
          end
          if p.parent ~= trunk and (p.parent == x or branches[p.parent] == branches[x]) then
            if not by_tip[tip] then
              by_tip[tip] = {}
              tips[#tips + 1] = tip
            end
            table.insert(by_tip[tip], c)
          end
        end
      end
    end
    if #need > 0 then
      return nil, need
    end
    if #tips == 0 then
      break
    end
    if #tips > 1 then
      local kids = {}
      for _, t in ipairs(tips) do
        kids[#kids + 1] = (M.pick(by_tip[t], nil, explicit))
      end
      table.sort(kids)
      forks[#forks + 1] = { at = x, children = kids }
      note(('%s has %d child branches (%s); the stack stops there'):format(x, #kids, M.list(kids)))
      break
    end
    local chosen = M.pick(by_tip[tips[1]], nil, explicit)
    seen[chosen] = true
    chain[#chain + 1] = { name = chosen, info = parent_of(chosen) }
    x = chosen
  end

  if #chain < 2 and #forks == 0 then
    return nil
  end
  local layers, current = {}, 1
  for i, l in ipairs(chain) do
    local tip = branches[l.name]
    local info = l.info
    local also = {}
    for _, n in ipairs(at[tip] or {}) do
      if n ~= l.name then
        also[#also + 1] = n
      end
    end
    table.sort(also)
    if #also > 0 then
      note(('%s also at %s; pick another with :RevueyStackParent'):format(M.list(also), l.name))
    end
    if info.diverged then
      note(('%s is not restacked on %s (%s moved): showing only %s\'s own commits, since %s\'s old tip %s'):format(
        l.name,
        info.parent,
        info.parent,
        l.name,
        info.parent,
        short(info.fork)
      ))
    end
    local parent_rev = info.fork or (info.parent == trunk and input.trunk_rev) or branches[info.parent]
    layers[i] = {
      name = l.name,
      tip = tip,
      parent = info.parent,
      parent_rev = parent_rev,
      source = info.source,
      diverged = info.diverged or nil,
      stale = info.stale or nil,
      is_head = tip == input.head and l.name == input.current,
      also = #also > 0 and also or nil,
      state_branch = l.name,
      state_base = normalize(info.parent),
      key_old = info.parent ~= trunk or nil,
    }
    if l.name == input.current then
      current = i
    end
  end
  return {
    kind = 'local',
    trunk = trunk,
    trunk_rev = input.trunk_rev,
    trunk_state = normalize(trunk),
    layers = layers,
    current = current,
    forks = forks,
    notes = notes,
  }
end

---Review target for a scope of a stack.
---@param stack revuey.Stack
---@param scope {kind:'layer'|'full', index?:integer}
---@return revuey.Target
function M.target(stack, scope)
  if scope.kind == 'full' then
    local top = stack.layers[#stack.layers]
    return {
      from = stack.base_rev or stack.trunk_rev,
      to = not top.is_head and top.tip or nil,
      branch = top.name,
      base = stack.trunk,
      state_repo = stack.state_repo,
      state_branch = top.state_branch,
      state_base = stack.trunk_state,
      committed_only = not top.is_head,
    }
  end
  local l = stack.layers[scope.index]
  return {
    from = l.parent_rev,
    -- never diff below trunk's merge-base (stale explicit parents, landed parents)
    floor = l.parent_rev ~= stack.trunk_rev and stack.trunk_rev or nil,
    to = not l.is_head and l.tip or nil,
    branch = l.name,
    base = l.parent,
    state_repo = stack.state_repo,
    state_branch = l.state_branch,
    state_base = l.state_base,
    key_old = l.key_old,
    committed_only = not l.is_head,
  }
end

---Stable identity of a scope (for per-scope view state).
function M.scope_key(stack, scope)
  local t = M.target(stack, scope)
  return (scope.kind == 'full' and 'full\0' or 'layer\0') .. t.state_branch .. '\0' .. t.state_base
end

-- ---------------------------------------------------------------------------
-- Gathering (git)
-- ---------------------------------------------------------------------------

---Parse `git cat-file --batch` output into sha -> content.
local function parse_batch(out)
  local res, pos = {}, 1
  while pos <= #out do
    local nl = out:find('\n', pos, true)
    if not nl then
      break
    end
    local header = out:sub(pos, nl - 1)
    local sha, _, size = header:match('^(%x+) (%S+) (%d+)$')
    if not sha then
      pos = nl + 1 -- "<sha> missing"
    else
      size = tonumber(size)
      res[sha] = out:sub(nl + 1, nl + size)
      pos = nl + size + 2
    end
  end
  return res
end

---Parent recorded in Graphite branch metadata (JSON blob), or nil when absent/unparseable.
function M.graphite_parent(text)
  local ok, data = pcall(vim.json.decode, text or '')
  if not ok or type(data) ~= 'table' then
    return nil
  end
  local p = data.parentBranchName or data.parent
  return type(p) == 'string' and p ~= '' and p or nil
end

---Old tips of a branch from its reflog text (newest last in the file): entries written by
---commits, amends, rebases, merges... Branch creation is skipped: being created at a commit
---doesn't make it yours. A reset (`reset --hard`, `branch -f`) abandons the branch's history,
---so scanning stops at the newest one.
---@return string[] shas, newest first
function M.reflog_tips(text, current_tip)
  local res, seen = {}, {}
  local lines = vim.split(text or '', '\n', { trimempty = true })
  for i = #lines, 1, -1 do
    local new, msg = lines[i]:match('^%x+ (%x+) .-\t(.*)$')
    if msg and (msg:match('^reset:') or msg:match('^branch: Reset')) then
      break
    end
    if new and not new:match('^0+$') and new ~= current_tip and not seen[new] and not msg:match('^branch: Created from') then
      seen[new] = true
      res[#res + 1] = new
      if #res >= 50 then
        break
      end
    end
  end
  return res
end

---Load first-parent history (plus merge parents) of `tips` excluding trunk into `input.graph`.
local function load_graph(root, input, tips)
  local stdin = {}
  for _, t in ipairs(tips) do
    stdin[#stdin + 1] = t
    input.loaded[t] = true
  end
  if #stdin == 0 then
    return
  end
  stdin[#stdin + 1] = '^' .. input.trunk_rev
  local out = git.system({ 'git', 'rev-list', '--parents', '--stdin' }, { cwd = root, stdin = table.concat(stdin, '\n') .. '\n' })
  if out.code ~= 0 then
    return
  end
  local rows = {}
  for line in (out.stdout or ''):gmatch('[^\n]+') do
    local shas = vim.split(line, ' ', { trimempty = true })
    rows[#rows + 1] = shas
    if input.graph[shas[1]] == nil then
      input.graph[shas[1]] = shas[2] or ''
    end
  end
  for _, r in ipairs(rows) do
    local sha = r[1]
    if input.graph[sha] ~= '' and input.graph[input.graph[sha]] == nil then
      input.graph[sha] = ''
    end
    for k = 3, #r do
      if input.graph[r[k]] ~= nil then
        input.merges[sha] = input.merges[sha] or {}
        if not vim.tbl_contains(input.merges[sha], r[k]) then
          table.insert(input.merges[sha], r[k])
        end
      end
    end
  end
end

---Cheap fingerprint of everything detection depends on (refs, overrides, HEAD, trunk).
function M.fingerprint(root, trunk)
  local refs = git.git({ 'for-each-ref', '--format=%(objectname) %(refname)', 'refs/heads', 'refs/branch-metadata' }, root) or ''
  local cfg = git.git({ 'config', '--get-regexp', [[^branch\..*\.revueyparent$]] }, root) or ''
  local head = git.rev_parse('HEAD', root) or ''
  local trunk_rev = git.rev_parse(trunk, root) or ''
  local current = git.current_branch(root) or ''
  return table.concat({ head, current, trunk, trunk_rev, refs, cfg }, '\0'), refs, cfg, head, trunk_rev, current
end

local function refs_list(out)
  local t = {}
  for ref in (out or ''):gmatch('[^\n]+') do
    t[#t + 1] = (ref:gsub('^refs/heads/', ''))
  end
  return t
end

---Read the tail of a file (reflogs can be long; recent entries are at the end).
local function read_tail(path, bytes)
  local fd = io.open(path, 'rb')
  if not fd then
    return nil
  end
  local size = fd:seek('end')
  fd:seek('set', math.max(0, size - bytes))
  local data = fd:read('*a')
  fd:close()
  if size > bytes then
    data = data:gsub('^[^\n]*\n', '') -- drop the partial first line
  end
  return data
end

local MAX_RUN = 20
local NO_CONTEXT = { '-U0', '--no-renames', '--no-ext-diff', '--no-color' }

---Patch ids (`git patch-id --stable`) of a stream of `commit <sha>`-headed patches: sha -> id.
local function patch_ids(root, patches)
  local res = git.system({ 'git', 'patch-id', '--stable' }, { cwd = root, stdin = patches })
  local ids = {}
  for id, sha in (res.code == 0 and res.stdout or ''):gmatch('(%x+) (%x+)') do
    ids[sha] = id
  end
  return ids
end

---Patch id of the change `from..to`, labelled `to`; nil when there is no change.
local function range_patch_id(root, from, to)
  local d = git.git(vim.list_extend({ 'diff', from, to }, NO_CONTEXT), root)
  return d and d ~= '' and patch_ids(root, 'commit ' .. to .. '\n' .. d)[to] or nil
end

---The oldest commits on `tip`'s first-parent line above trunk that are already in trunk as
---commits of their own (squash merges, cherry-picks), grouped into runs: one run per trunk commit,
---oldest first. Patches are compared without context lines, so a trunk change next to a hunk does
---not stop a match. Stops at the first commit no run starting there matches.
---@return string[][]
function M.landed_runs(root, trunk_rev, tip)
  local mb = git.merge_base(trunk_rev, tip, root)
  local out = mb and git.git({ 'rev-list', '--reverse', '--first-parent', '--max-count=200', mb .. '..' .. tip }, root)
  local commits = vim.split(out or '', '\n', { trimempty = true })
  if #commits == 0 then
    return {}
  end
  local out_paths = git.git({ 'log', '--format=', '--name-only', '--no-renames', mb .. '..' .. tip }, root) or ''
  local paths = vim.fn.uniq(vim.fn.sort(vim.split(out_paths, '\n', { trimempty = true })))
  if #paths == 0 or #paths > 500 then
    return {}
  end
  local args = vim.list_extend({ 'log', '-p', '--full-diff', '--no-merges', '--max-count=2000', '--format=commit %H' }, NO_CONTEXT)
  vim.list_extend(args, { mb .. '..' .. trunk_rev, '--' })
  vim.list_extend(args, vim.tbl_map(function(p)
    return ':(literal)' .. p
  end, paths))
  local in_trunk = {}
  for _, id in pairs(patch_ids(root, git.git(args, root) or '')) do
    in_trunk[id] = true
  end
  if next(in_trunk) == nil then
    return {}
  end
  local runs, from, i = {}, mb, 1
  while i <= #commits do
    local matched
    for j = i, math.min(#commits, i + MAX_RUN - 1) do
      if in_trunk[range_patch_id(root, from, commits[j]) or ''] then
        matched = j
        break
      end
    end
    if not matched then
      break
    end
    runs[#runs + 1] = vim.list_slice(commits, i, matched)
    from, i = commits[matched], matched + 1
  end
  return runs
end

---Layers diffed from trunk start after the commits at their bottom that trunk already has as
---squash merges (lower PRs merged, the branch not restacked). A layer that landed entirely keeps
---its last run, its own squash-merged PR, as its diff.
local function skip_squashed(root, stack)
  for i, l in ipairs(stack.layers) do
    if l.parent_rev == stack.trunk_rev then
      local runs = M.landed_runs(root, stack.trunk_rev, l.tip)
      local last = runs[#runs]
      if last and last[#last] == l.tip then
        runs[#runs] = nil
      end
      if #runs > 0 then
        local skipped = vim.iter(runs):fold(0, function(n, r)
          return n + #r
        end)
        local top = runs[#runs]
        l.parent_rev, l.skipped = top[#top], skipped
        stack.notes[#stack.notes + 1] = ('%s skips %d commit%s already squash-merged into %s (not restacked?)'):format(
          l.name,
          skipped,
          skipped == 1 and '' or 's',
          stack.trunk
        )
        if i == 1 then
          stack.base_rev = l.parent_rev
        end
      end
    end
  end
end

---Mark bottom layers whose changes are already in trunk (squash-merged): the layer's changed
---files are identical in trunk and the layer tip.
local function mark_landed(root, stack)
  for _, l in ipairs(stack.layers) do
    local files = git.git({ 'diff', '--name-only', '-z', '--no-renames', l.parent_rev .. '...' .. l.tip, '--' }, root)
    local list = files and vim.split(files, '\0', { trimempty = true }) or {}
    if #list == 0 or #list > 500 then
      return
    end
    local args = { 'diff', '--quiet', '--no-renames', '--no-ext-diff', stack.trunk_rev, l.tip, '--' }
    for _, f in ipairs(list) do
      args[#args + 1] = ':(literal)' .. f
    end
    local res = git.system(vim.list_extend({ 'git' }, args), { cwd = root })
    if res.code ~= 0 then
      return
    end
    l.landed, l.dimmed = true, true
    table.insert(stack.notes, 1, ('%s looks landed in %s (its changes are already there)'):format(l.name, stack.trunk))
  end
end

---Suggest-only notes about branches outside the stack (or outside the lone branch) that look like
---they should be in it but no reflog says so (e.g. a fresh clone):
---  * they share commits above trunk with HEAD's line (a parent that moved on, not restacked);
---  * they hold a rewritten copy of a commit on HEAD's line: same author, author date and changed
---    paths, different commit (a parent amended or rebased) - one `git log` over unmerged branches.
local function foreign_notes(root, input, stack, above_set, trunk_names)
  local notes = {}
  local in_stack = { [input.current] = true }
  for _, l in ipairs(stack and stack.layers or {}) do
    in_stack[l.name] = true
    for _, n in ipairs(l.also or {}) do
      in_stack[n] = true
    end
  end
  for _, f in ipairs(stack and stack.forks or {}) do
    for _, n in ipairs(f.children) do
      in_stack[n] = true
    end
  end
  for n, sha in pairs(input.branches) do
    if sha == input.head then
      in_stack[n] = true
    end
  end
  local function outside(b)
    return b and not in_stack[b] and not above_set[b] and not trunk_names[b] and input.branches[b] ~= nil
  end
  local what = stack and 'this stack' or 'this branch'
  -- commits on HEAD's line above trunk
  local mine, queue = { [input.head] = true }, { input.head }
  local root_commit = input.head
  while #queue > 0 do
    local c = table.remove(queue)
    local ps = { input.graph[c] }
    vim.list_extend(ps, input.merges[c] or {})
    for _, p in ipairs(ps) do
      if p and p ~= '' and input.graph[p] ~= nil and not mine[p] then
        mine[p] = true
        queue[#queue + 1] = p
      end
    end
  end
  while input.graph[root_commit] and input.graph[root_commit] ~= '' do
    root_commit = input.graph[root_commit]
  end
  local sharing = {}
  for _, b in ipairs(refs_list(git.git({ 'for-each-ref', '--contains', root_commit, '--format=%(refname)', 'refs/heads' }, root))) do
    if outside(b) then
      sharing[#sharing + 1] = b
    end
  end
  table.sort(sharing)
  if #sharing > 0 then
    notes[#notes + 1] = ('%s share%s commits with %s but %s not in it (not restacked?); set a parent with :RevueyStackParent'):format(
      M.list(sharing),
      #sharing == 1 and 's' or '',
      what,
      #sharing == 1 and 'is' or 'are'
    )
  end
  local out = git.git({
    'log', '--no-merges', '--branches', '--not', input.trunk_rev, '--source', '--max-count=2000',
    '--format=%x00%H%x09%S%x09%ae%x09%at', '--name-only',
  }, root) or ''
  local mine_keys, others = {}, {}
  for rec in out:gmatch('%z([^%z]*)') do
    local header, rest = rec:match('^([^\n]*)\n?(.*)$')
    local sha, src, ae, at = (header or ''):match('^(%x+)\t(%S+)\t([^\t]*)\t(%d+)')
    if sha then
      local files = vim.split(rest or '', '\n', { trimempty = true })
      table.sort(files)
      if #files > 0 then
        local k = ae .. '\0' .. at .. '\0' .. table.concat(files, '\0')
        if mine[sha] then
          mine_keys[k] = sha
        else
          others[#others + 1] = { sha = sha, key = k, branch = (src:gsub('^refs/heads/', '')) }
        end
      end
    end
  end
  local rewritten, seen = {}, {}
  for _, o in ipairs(others) do
    if mine_keys[o.key] and mine_keys[o.key] ~= o.sha and outside(o.branch) and not seen[o.branch] then
      seen[o.branch] = true
      rewritten[#rewritten + 1] = o.branch
    end
  end
  table.sort(rewritten)
  for _, b in ipairs(rewritten) do
    notes[#notes + 1] = ('%s has a rewritten copy of a commit on %s (amended or rebased?): %s may be built on an old version of %s; set a parent with :RevueyStackParent'):format(
      b,
      input.current,
      input.current,
      b
    )
  end
  return notes
end

---Detect the local stack around HEAD. Returns nil when there is none (single branch, detached
---HEAD, nothing committed above trunk).
---@param root string
---@param trunk string
---@param cache? table reused across refreshes: unchanged refs skip detection entirely
---@return revuey.Stack?
---@return string[]? notes when there is no stack: suggestions for the plain review
function M.detect(root, trunk, cache)
  local key, refs, cfg, head, trunk_rev, current = M.fingerprint(root, trunk)
  if cache and cache.key == key then
    return cache.stack, cache.notes
  end
  local stack, notes
  if head ~= '' and trunk_rev ~= '' and current ~= '' then
    local remotes = git.remotes(root)
    local function normalize(n)
      return state.normalize_base(n, remotes)
    end
    local branches, meta = {}, {}
    for line in refs:gmatch('[^\n]+') do
      local sha, ref = line:match('^(%x+) (.+)$')
      if ref and ref:sub(1, 11) == 'refs/heads/' then
        branches[ref:sub(12)] = sha
      elseif ref and ref:sub(1, 21) == 'refs/branch-metadata/' then
        meta[ref:sub(22)] = sha
      end
    end
    local explicit = {}
    if next(meta) then
      local shas = {}
      for _, sha in pairs(meta) do
        shas[#shas + 1] = sha
      end
      local out = git.system({ 'git', 'cat-file', '--batch' }, { cwd = root, stdin = table.concat(shas, '\n') .. '\n' })
      local blobs = out.code == 0 and parse_batch(out.stdout or '') or {}
      for b, sha in pairs(meta) do
        local p = M.graphite_parent(blobs[sha])
        if p and branches[b] then
          explicit[b] = { parent = p, source = 'graphite' }
        end
      end
    end
    -- revuey overrides win over Graphite (they are the user's explicit choice here)
    for line in cfg:gmatch('[^\n]+') do
      local b, p = line:match('^branch%.(.+)%.revueyparent%s+(.+)$')
      if b and branches[b] then
        explicit[b] = { parent = vim.trim(p), source = 'config' }
      end
    end
    -- Old tips of unmerged branches (most recently committed first, capped), from their reflogs.
    local owned, owned_by = {}, {}
    local common = git.git({ 'rev-parse', '--path-format=absolute', '--git-common-dir' }, root)
    local unmerged = refs_list(git.git({
      'for-each-ref', '--no-merged', trunk_rev, '--sort=-committerdate', '--count=300', '--format=%(refname)', 'refs/heads',
    }, root))
    if common then
      common = vim.trim(common)
      for _, b in ipairs(unmerged) do
        local text = read_tail(vim.fs.joinpath(common, 'logs', 'refs', 'heads', b), 16384)
        local tips = M.reflog_tips(text, branches[b])
        owned_by[b] = tips
        for _, sha in ipairs(tips) do
          owned[sha] = owned[sha] or {}
          table.insert(owned[sha], b)
        end
      end
    end
    local trunk_names = { [trunk] = true, [normalize(trunk)] = true }
    local input = {
      trunk = trunk,
      trunk_rev = trunk_rev,
      trunk_names = trunk_names,
      current = current,
      head = head,
      branches = branches,
      graph = {},
      merges = {},
      loaded = {},
      above = {},
      owned = owned,
      explicit = explicit,
      normalize = normalize,
    }
    local above_set = {}
    local function add_above(list)
      local new = {}
      for _, b in ipairs(list) do
        if not above_set[b] and branches[b] then
          above_set[b] = true
          input.above[#input.above + 1] = b
          new[#new + 1] = b
        end
      end
      return new
    end
    local new = add_above(refs_list(git.git({ 'for-each-ref', '--contains', head, '--format=%(refname)', 'refs/heads' }, root)))
    local tips = { head }
    for _, b in ipairs(new) do
      tips[#tips + 1] = branches[b]
    end
    load_graph(root, input, tips)
    -- Branches left on an old tip of a stack branch (not restacked) sit above it too.
    local frontier, queried = vim.list_extend({ current }, new), {}
    for _ = 1, 3 do
      local olds = {}
      for _, b in ipairs(frontier) do
        for _, sha in ipairs(owned_by[b] or {}) do
          if not queried[sha] and #olds < 50 then
            queried[sha] = true
            olds[#olds + 1] = sha
          end
        end
      end
      if #olds == 0 then
        break
      end
      load_graph(root, input, olds)
      local args = { 'for-each-ref', '--format=%(refname)' }
      for _, sha in ipairs(olds) do
        if input.graph[sha] ~= nil then
          vim.list_extend(args, { '--contains', sha })
        end
      end
      if #args == 2 then
        break
      end
      args[#args + 1] = 'refs/heads'
      frontier = add_above(refs_list(git.git(args, root)))
      local t = {}
      for _, b in ipairs(frontier) do
        t[#t + 1] = branches[b]
      end
      load_graph(root, input, t)
    end
    for _ = 1, 20 do
      local st, need = M.resolve(input)
      if not need or #need == 0 then
        stack = st
        break
      end
      load_graph(root, input, need)
    end
    local extra = {}
    if input.graph[head] ~= nil then
      extra = foreign_notes(root, input, stack, above_set, trunk_names)
    end
    if stack then
      vim.list_extend(stack.notes, extra)
      skip_squashed(root, stack)
      mark_landed(root, stack)
    elseif #extra > 0 then
      notes = extra
    end
  end
  if cache then
    cache.key, cache.stack, cache.notes = key, stack, notes
  end
  return stack, notes
end

return M
