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
local notes_mod = require('revuey.stack_notes')
local ignore_mod = require('revuey.stack_ignore')

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
---@field notes revuey.StackNote[]  shown notes (see stack_notes.lua)
---@field ignored? {branch:string, kind:string, pattern:string}[] notes hidden by the ignore list
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
  local ctx = { stack = true, trunk = trunk }
  local function note(kind, fields)
    local id = table.concat({ kind, fields.branch or '', fields.layer or '', fields.parent or '' }, '\0')
    if not noted[id] then
      noted[id] = true
      notes[#notes + 1] = notes_mod.new(kind, fields, ctx)
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
          note('parent_landed', { branch = name, parent = p, source = ex.source })
          res = { parent = trunk, source = ex.source }
        elseif is_ancestor(branches[p], tip) then
          res = { parent = p, source = ex.source }
        else
          local fork = old_tip_of(p, tip)
          if fork then
            res = { parent = p, source = ex.source, fork = fork, diverged = true }
          else
            -- not built on the parent at all (e.g. rebased onto trunk after the parent landed)
            note('stale_parent', { branch = name, parent = p, source = ex.source })
            res = { parent = p, source = ex.source, fork = input.trunk_rev, stale = true }
          end
        end
      else
        note('unknown_parent', { branch = name, parent = p, source = ex.source })
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
      note('cycle', { branch = name, parent = p.parent, source = p.source })
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
      note('fork', { branch = x, branches = kids })
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
    for _, n in ipairs(also) do
      note('same_commit', { branch = n, layer = l.name })
    end
    if info.diverged then
      note('not_restacked', { branch = l.name, parent = info.parent, at = short(info.fork) })
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

---Cheap fingerprint of everything detection depends on (refs, overrides, HEAD, trunk, and the
---ignore list for notes).
---@param state_dir? string state dir of the ignore list (default: the configured one)
function M.fingerprint(root, trunk, state_dir)
  local refs = git.git({ 'for-each-ref', '--format=%(objectname) %(refname)', 'refs/heads', 'refs/branch-metadata' }, root) or ''
  local cfg = git.git({ 'config', '--get-regexp', [[^branch\..*\.revueyparent$]] }, root) or ''
  local head = git.rev_parse('HEAD', root) or ''
  local trunk_rev = git.rev_parse(trunk, root) or ''
  local current = git.current_branch(root) or ''
  local ignore = ignore_mod.patterns((ignore_mod.for_root(root, state_dir)))
  local key = table.concat({ head, current, trunk, trunk_rev, refs, cfg, table.concat(ignore, '\n') }, '\0')
  return key, refs, cfg, head, trunk_rev, current, ignore
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
-- One line of context: the same line added somewhere else does not match, a trunk change two
-- lines away does.
local PATCH = { '-U1', '--no-prefix', '--no-renames', '--no-ext-diff', '--no-color' }

---Patch ids of a stream of `commit <label>`-headed patches: label -> id. Whitespace counts.
local function patch_ids(root, patches)
  local res = git.system({ 'git', 'patch-id', '--verbatim' }, { cwd = root, stdin = patches })
  local ids = {}
  for id, label in (res.code == 0 and res.stdout or ''):gmatch('(%x+) (%x+)') do
    ids[label] = id
  end
  return ids
end

---Patch ids of trunk commits (`-R`: of their reverts): commit -> id.
local function commit_patch_ids(root, shas, reverse)
  local args = vim.list_extend({ 'git', 'log', '--stdin', '--no-walk', '-p', '--format=commit %H' }, PATCH)
  if reverse then
    args[#args + 1] = '-R'
  end
  local res = git.system(args, { cwd = root, stdin = table.concat(shas, '\n') .. '\n' })
  return patch_ids(root, res.code == 0 and res.stdout or '')
end

---Commits listed by `git log <args> --name-only`, newest first, each with its changed paths.
local function changed_paths(root, args)
  local res = {}
  local out = git.git(vim.list_extend({ 'log', '--no-renames', '--format=%x00%H', '--name-only' }, args), root)
  for rec in (out or ''):gmatch('%z([^%z]*)') do
    local sha, rest = rec:match('^(%x+)\n?(.*)$')
    if sha then
      res[#res + 1] = { sha = sha, paths = vim.split(rest, '\n', { trimempty = true }) }
    end
  end
  return res
end

---Order-independent key of a set of paths.
local function key_of(set)
  local t = vim.tbl_keys(set)
  table.sort(t)
  return table.concat(t, '\0')
end

local function set_of(list, set)
  set = set or {}
  for _, x in ipairs(list) do
    set[x] = true
  end
  return set
end

---The oldest commits on `tip`'s first-parent line above trunk that trunk already has as commits of
---their own (squash merges, cherry-picks) and has not reverted since, grouped into runs, oldest
---first. A run must change the same paths as a trunk commit and have the same patch id; each trunk
---commit accounts for one run. The longest run starting at a commit wins; matching stops at the
---first commit no run starts at. Runs longer than MAX_RUN, branches over 200 commits or 500 paths,
---and trunk commits beyond the latest 2000 touching the branch's paths are not matched.
---@return string[][]
function M.landed_runs(root, trunk_rev, tip)
  local mb = git.merge_base(trunk_rev, tip, root)
  local commits = mb and changed_paths(root, { '--first-parent', '--max-count=201', mb .. '..' .. tip }) or {}
  if #commits == 0 or #commits > 200 then
    return {}
  end
  commits = vim.iter(commits):rev():totable()
  local all = {}
  for _, c in ipairs(commits) do
    set_of(c.paths, all)
  end
  local paths = vim.tbl_map(function(p)
    return ':(literal)' .. p
  end, vim.tbl_keys(all))
  if #paths == 0 or #paths > 500 then
    return {}
  end
  local trunk_range = vim.list_extend({ '--full-diff', '--no-merges', '--max-count=2000', mb .. '..' .. trunk_rev, '--' }, paths)
  local trunk_by_key = {}
  for _, c in ipairs(changed_paths(root, trunk_range)) do
    local k = key_of(set_of(c.paths))
    trunk_by_key[k] = trunk_by_key[k] or {}
    table.insert(trunk_by_key[k], c.sha)
  end
  -- candidate runs i..j whose paths match some trunk commit's
  local cands, patches, trunk_shas = {}, {}, {}
  for i = 1, #commits do
    local set = {}
    for j = i, math.min(#commits, i + MAX_RUN - 1) do
      local same = trunk_by_key[key_of(set_of(commits[j].paths, set))]
      if same then
        local label = ('%040x'):format(#patches + 1)
        local from = i == 1 and mb or commits[i - 1].sha
        local d = git.git(vim.list_extend({ 'diff', from, commits[j].sha }, PATCH), root)
        if d and d ~= '' then
          cands[i .. ':' .. j] = label
          patches[#patches + 1] = 'commit ' .. label .. '\n' .. d
          set_of(same, trunk_shas)
        end
      end
    end
  end
  if #patches == 0 then
    return {}
  end
  local ids = patch_ids(root, table.concat(patches))
  local shas, unused, any = vim.tbl_keys(trunk_shas), {}, false
  for _, id in pairs(commit_patch_ids(root, shas)) do
    unused[id] = (unused[id] or 0) + 1
  end
  for _, id in pairs(ids) do
    any = any or unused[id] ~= nil
  end
  if not any then
    return {}
  end
  -- trunk commits not reverted since: a revert's reversed patch cancels the commit it reverts
  for _, id in pairs(commit_patch_ids(root, shas, true)) do
    if unused[id] then
      unused[id] = unused[id] - 1
    end
  end
  local runs, i = {}, 1
  while i <= #commits do
    local matched
    for j = math.min(#commits, i + MAX_RUN - 1), i, -1 do
      local id = ids[cands[i .. ':' .. j] or '']
      if id and (unused[id] or 0) > 0 then
        unused[id] = unused[id] - 1
        matched = j
        break
      end
    end
    if not matched then
      break
    end
    runs[#runs + 1] = vim.tbl_map(function(c)
      return c.sha
    end, vim.list_slice(commits, i, matched))
    i = matched + 1
  end
  return runs
end

---Where a branch diffed from trunk should start instead: after the commits at its bottom that
---trunk already has as squash merges (lower PRs merged, the branch not restacked). A branch that
---landed entirely keeps its last run, its own squash-merged PR, as its diff.
---@return {rev:string, skipped:integer, note:revuey.StackNote}?
function M.squash_skip(root, trunk, trunk_rev, name, tip)
  local runs = M.landed_runs(root, trunk_rev, tip)
  local last = runs[#runs]
  if last and last[#last] == tip then
    runs[#runs] = nil
  end
  if #runs == 0 then
    return nil
  end
  local skipped = vim.iter(runs):fold(0, function(n, r)
    return n + #r
  end)
  local top = runs[#runs]
  return {
    rev = top[#top],
    skipped = skipped,
    note = notes_mod.new('squashed', { branch = name, count = skipped, at = short(top[#top]) }, { stack = true, trunk = trunk }),
  }
end

---The bottom layer, when diffed from trunk, skips squash-merged commits (`M.squash_skip`); so does
---the full scope.
local function skip_squashed(root, stack)
  local l = stack.layers[1]
  if not l or l.parent_rev ~= stack.trunk_rev or l.stale then
    return
  end
  local skip = M.squash_skip(root, stack.trunk, stack.trunk_rev, l.name, l.tip)
  if skip then
    l.parent_rev, l.skipped, stack.base_rev = skip.rev, skip.skipped, skip.rev
    stack.notes[#stack.notes + 1] = skip.note
  end
end

---A layer that landed entirely gets one note: its `squashed` note (commits skipped below its own
---squash-merged PR) folds into its `landed` note.
local function merge_landed_squashed(stack)
  local landed = {}
  for _, n in ipairs(stack.notes) do
    if n.kind == 'landed' then
      landed[n.branch] = n
    end
  end
  local kept = {}
  for _, n in ipairs(stack.notes) do
    local l = n.kind == 'squashed' and landed[n.branch]
    if l then
      l.count = n.count
      l.text = notes_mod.KINDS.landed.one(l, { stack = true, trunk = stack.trunk })
    else
      kept[#kept + 1] = n
    end
  end
  stack.notes = kept
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
    table.insert(stack.notes, 1, notes_mod.new('landed', { branch = l.name }, { stack = true, trunk = stack.trunk }))
  end
end

---Suggest-only notes about related branches outside the stack (or outside the lone branch), for
---when no reflog links them (e.g. a fresh clone, or old branches left on an earlier version):
---  * branches holding another copy of a commit of the stack (same author, author date and changed
---    paths, different commit: amended, rebased or cherry-picked), from one `git log` over
---    unmerged branches. Commits marked `(cherry picked from commit …)` are skipped. Committer
---    dates give the direction: older copies elsewhere = that branch may be built on an outdated
---    copy of the stack (`outdated_copy`). Newer copies elsewhere are a warning (`newer_copy`: the
---    stack may be built on an old version of that branch) only when shaped like a parent that was
---    amended under the stack: the matched commits are the bottom run of the bottom layer (which
---    has commits of its own above them) and the branch ends at the newer copy of the top one.
---    Anything else (backports, clock skew, whole-stack rebases) is `other_copy`, informational;
---  * other branches sharing commits above trunk with HEAD's line: built on a layer below HEAD
---    (`side`), or not (`outside`, a warning: perhaps a parent that moved on without restacking,
---    whose commits are then part of the layer's diff).
---Notes that could suggest "set as parent" carry `parent_ok` when the branch tip is an ancestor
---of the layer (so the setting would not be stale). One note per branch; the ignore list is
---applied by the caller.
---@return revuey.StackNote[]
local function foreign_notes(root, input, stack, above_set, trunk_names)
  local ctx = { stack = stack ~= nil, trunk = input.trunk }
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
  -- commits of the stack (every layer; HEAD's line for a lone branch) above trunk, and the lowest
  -- layer each belongs to
  local layers = stack and stack.layers or { { name = input.current, tip = input.head } }
  local owner = {} ---@type table<string, integer>
  for i, l in ipairs(layers) do
    local queue = { l.tip }
    if input.graph[l.tip] ~= nil and not owner[l.tip] then
      owner[l.tip] = i
    end
    while #queue > 0 do
      local c = table.remove(queue)
      local ps = { input.graph[c] }
      vim.list_extend(ps, input.merges[c] or {})
      for _, p in ipairs(ps) do
        if p and p ~= '' and input.graph[p] ~= nil and not owner[p] then
          owner[p] = i
          queue[#queue + 1] = p
        end
      end
    end
  end
  local root_commit = input.head
  while input.graph[root_commit] and input.graph[root_commit] ~= '' do
    root_commit = input.graph[root_commit]
  end
  -- the bottom layer's first-parent line, bottom up: pos[sha] = 1 for its lowest commit
  local pos, chain_len = {}, 0
  do
    local line, c = {}, layers[1].tip
    while c and c ~= '' and input.graph[c] ~= nil do
      line[#line + 1] = c
      c = input.graph[c]
    end
    chain_len = #line
    for i, sha in ipairs(line) do
      pos[sha] = chain_len - i + 1
    end
  end
  local function layer_name(i)
    return layers[i or 1] and layers[i or 1].name or input.current
  end

  -- deliberate copies (backports): `git cherry-pick -x` leaves a marker in the message
  local picked = {}
  for sha in (git.git({
    'log', '--branches', '--not', input.trunk_rev, '--fixed-strings', '--grep=(cherry picked from commit', '--format=%H',
  }, root) or ''):gmatch('%x+') do
    picked[sha] = true
  end
  -- other copies of the stack's commits, grouped by the branch `--source` names for them
  local out = git.git({
    'log', '--no-merges', '--branches', '--not', input.trunk_rev, '--source', '--max-count=2000',
    '--format=%x00%H%x09%S%x09%ae%x09%at%x09%ct', '--name-only',
  }, root) or ''
  local mine_keys, others = {}, {}
  for rec in out:gmatch('%z([^%z]*)') do
    local header, rest = rec:match('^([^\n]*)\n?(.*)$')
    local sha, src, ae, at, ct = (header or ''):match('^(%x+)\t(%S+)\t([^\t]*)\t(%d+)\t(%d+)')
    if sha and not picked[sha] then
      local files = vim.split(rest or '', '\n', { trimempty = true })
      table.sort(files)
      if #files > 0 then
        local k = ae .. '\0' .. at .. '\0' .. table.concat(files, '\0')
        if owner[sha] then
          mine_keys[k] = { sha = sha, ct = tonumber(ct) }
        else
          others[#others + 1] = { sha = sha, key = k, ct = tonumber(ct), branch = (src:gsub('^refs/heads/', '')) }
        end
      end
    end
  end
  local groups, order = {}, {}
  for _, o in ipairs(others) do
    local m = mine_keys[o.key]
    if m and m.sha ~= o.sha then
      if not groups[o.branch] then
        groups[o.branch] = {}
        order[#order + 1] = o.branch
      end
      table.insert(groups[o.branch], { m = m, o = o })
    end
  end

  ---Kind of a branch holding these copies (with tip `tip`).
  local function classify(matches, tip)
    local newer, older = 0, 0
    for _, p in ipairs(matches) do
      if p.o.ct > p.m.ct then
        newer = newer + 1
      elseif p.o.ct < p.m.ct then
        older = older + 1
      end
    end
    if older > 0 and newer == 0 then
      return 'outdated_copy'
    end
    if newer > 0 and older == 0 then
      local top, seen, n = nil, {}, 0
      for _, p in ipairs(matches) do
        local k = pos[p.m.sha]
        if not k or seen[k] then
          return 'other_copy'
        end
        seen[k] = true
        n = n + 1
        if not top or k > pos[top.m.sha] then
          top = p
        end
      end
      -- a bottom run 1..n, below the layer's own commits, and the branch ends at its newer copy
      if pos[top.m.sha] == n and n < chain_len and tip == top.o.sha then
        return 'newer_copy'
      end
    end
    return 'other_copy'
  end

  local rank = { newer_copy = 3, outdated_copy = 2, other_copy = 1 }
  local rel = {} ---@type table<string, {kind:string, layer:integer}>
  for gi, src in ipairs(order) do
    local matches = groups[src]
    local layer, rep = 1, matches[1]
    for _, p in ipairs(matches) do
      local i = owner[p.m.sha] or 1
      if i >= layer then
        layer, rep = i, p
      end
    end
    -- `--source` names one branch per commit: ask once per source for every branch holding it
    local holders = { src }
    if gi <= 30 then
      holders = refs_list(git.git({ 'for-each-ref', '--contains', rep.o.sha, '--format=%(refname)', 'refs/heads' }, root))
    end
    for _, b in ipairs(holders) do
      if outside(b) then
        local kind = classify(matches, input.branches[b])
        local r = rel[b]
        if not r or rank[kind] > rank[r.kind] then
          rel[b] = { kind = kind, layer = layer }
        elseif kind == r.kind and layer > r.layer then
          r.layer = layer
        end
      end
    end
  end

  -- branches sharing the stack's commits
  local sharing = {}
  for _, b in ipairs(refs_list(git.git({ 'for-each-ref', '--contains', root_commit, '--format=%(refname)', 'refs/heads' }, root))) do
    if outside(b) and not rel[b] then
      sharing[#sharing + 1] = b
    end
  end
  table.sort(sharing)
  if #sharing > 0 then
    local left = {}
    for _, b in ipairs(sharing) do
      left[b] = true
    end
    -- built on a layer below HEAD (branches containing HEAD are above it, not here)
    for i = (stack and stack.current or 1) - 1, 1, -1 do
      if not next(left) then
        break
      end
      for _, b in ipairs(refs_list(git.git({ 'for-each-ref', '--contains', layers[i].tip, '--format=%(refname)', 'refs/heads' }, root))) do
        if left[b] then
          left[b] = nil
          rel[b] = { kind = 'side', layer = i }
        end
      end
    end
    for b in pairs(left) do
      rel[b] = { kind = 'outside', layer = owner[root_commit] or 1 }
    end
  end

  local names = vim.tbl_keys(rel)
  table.sort(names)
  local notes, checked = {}, 0
  for _, b in ipairs(names) do
    local r = rel[b]
    local fields = { branch = b, layer = layer_name(r.layer) }
    if (r.kind == 'newer_copy' or r.kind == 'outside') and checked < 20 then
      -- only offer "set as parent" when the setting would hold (tip is an ancestor of the layer)
      checked = checked + 1
      local tip = layers[r.layer] and layers[r.layer].tip or input.head
      local res = git.system({ 'git', 'merge-base', '--is-ancestor', input.branches[b], tip }, { cwd = root })
      fields.parent_ok = res.code == 0 or nil
    end
    notes[#notes + 1] = notes_mod.new(r.kind, fields, ctx)
  end
  return notes
end


---Detect the local stack around HEAD. Returns nil when there is none (single branch, detached
---HEAD, nothing committed above trunk).
---@param root string
---@param trunk string
---Notes about related branches matching the ignore list (config `stack.ignore_branches` plus the
---repo's persisted list) are moved to `stack.ignored`; detection itself ignores the list.
---@param cache? table reused across refreshes: unchanged refs skip detection entirely
---@param opts? {state_dir?:string}
---@return revuey.Stack?
---@return revuey.StackNote[]? notes when there is no stack: suggestions for the plain review
---@return string? from when there is no stack: where the plain review's diff starts, when the
---branch's bottom commits are already squash-merged into trunk
---@return table[]? ignored notes hidden by the ignore list when there is no stack
function M.detect(root, trunk, cache, opts)
  local key, refs, cfg, head, trunk_rev, current, ignore = M.fingerprint(root, trunk, opts and opts.state_dir)
  if cache and cache.key == key then
    return cache.stack, cache.notes, cache.from, cache.ignored
  end
  local stack, notes, from, ignored
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
      merge_landed_squashed(stack)
      stack.notes, stack.ignored = notes_mod.filter(stack.notes, ignore)
    else
      local skip = input.graph[head] ~= nil and M.squash_skip(root, trunk, trunk_rev, current, head)
      if skip then
        extra[#extra + 1] = skip.note
        from = skip.rev
      end
      if #extra > 0 then
        notes, ignored = notes_mod.filter(extra, ignore)
      end
    end
  end
  if cache then
    cache.key, cache.stack, cache.notes, cache.from, cache.ignored = key, stack, notes, from, ignored
  end
  return stack, notes, from, ignored
end

return M
