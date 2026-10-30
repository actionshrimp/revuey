-- The stack tree's glue (UI and git over stack_tree.lua): fetching it with the PR lookup (on
-- open and `R`, decision 20), the review's stack for the chosen path, the tree view (a float
-- over the diff window), and fetching the stack's branches (`git fetch`, never a GitHub write).
--
-- Session state `s.gh_tree`: {fetched, tree, sel (the PR chosen in the tree view; nil = the
-- default route through HEAD's PR), for_branch (the branch the tree was fetched for), version
-- (bumped when a fetch changes what the stack is built from), reason (why there is no tree),
-- remote, stale, loading (closed subtrees still coming), gen/job (the rounds in flight), saved
-- (other branches' trees, kept when HEAD moves), view (the open tree view)}. Nothing is stored:
-- reopening a review starts from the default route.
local tree_mod = require('revuey.stack_tree')
local forge = require('revuey.forge')
local git = require('revuey.git')
local log = require('revuey.log')
local config = require('revuey.config')
local api = vim.api

local M = {}

local ns = api.nvim_create_namespace('revuey.tree')
local ns_path = api.nvim_create_namespace('revuey.tree.path')

---Is the GitHub stack tree on (`stack.github`, and forge enabled)?
function M.enabled()
  return (config.options.stack or {}).github ~= false and forge.options().enabled
end

local function state(s)
  s.gh_tree = s.gh_tree or { version = 0, facts_gen = 0, gen = 0, saved = {} }
  return s.gh_tree
end
M.state = state

local function first_key(name)
  return require('revuey.keys').first(name)
end

---The branch the tree starts from: HEAD's layer in a git-detected stack, else the checked-out
---branch, else a remote-tracking branch detached HEAD is at.
function M.head_branch(root, git_stack)
  if git_stack then
    local l = git_stack.layers[git_stack.current]
    if l then
      return l.name
    end
  end
  local b = git.current_branch(root)
  if b then
    return b
  end
  local out = git.git({ 'for-each-ref', '--points-at', 'HEAD', '--format=%(refname:short)', 'refs/remotes' }, root) or ''
  for ref in out:gmatch('[^\n]+') do
    if not ref:match('/HEAD$') then
      return ref
    end
  end
end

-- ---------------------------------------------------------------------------
-- Fetching (with the PR lookup, forge_view.update)
-- ---------------------------------------------------------------------------

---Start a tree fetch when this review has none for HEAD's branch yet (or `force`: `R` only):
---the first round goes into the PR lookup's call (`extra`). nil when not wanted or not possible
---(`gt.reason` says why).
---@return {st:revuey.TreeFetch, extra:table}?
function M.begin(s, info, force)
  if not M.enabled() then
    return nil
  end
  local gt = state(s)
  if gt.fetched and not force then
    return nil
  end
  gt.fetched = true
  local name, trunk = s.review.head_branch, s.review.tree_trunk
  gt.for_branch = name
  if not trunk then
    gt.reason = 'this review has an explicit base (no stack)'
    return nil
  end
  if not name then
    gt.reason = 'HEAD is not on a branch'
    return nil
  end
  local base, explicit = forge.base_remote(trunk, info)
  if not base then
    gt.reason = 'no GitHub remote'
    return nil
  end
  local trunk_branch = trunk and forge.branch_name(trunk, info) or nil
  local remote = require('revuey.stack').split_remote(name, info.names)
  local t = forge.target(name, info.branches[name] == nil and remote ~= nil, nil, base, info, trunk_branch, explicit)
  if not t or not trunk_branch then
    gt.reason = 'no branch to look up'
    return nil
  end
  local branches, seen = {}, {}
  for _, c in ipairs(t.candidates) do
    if not seen[c.branch] then
      seen[c.branch] = true
      branches[#branches + 1] = c.branch
    end
  end
  local repo = info.remotes[base].repo
  local st = tree_mod.new(repo, trunk_branch, branches, t.candidates[1].head_owner)
  -- a chosen PR keeps its path whole in phase one (it may sit under a closed PR)
  if gt.sel and gt.tree and gt.tree.nodes[gt.sel] then
    st.pin = {}
    for _, num in ipairs(tree_mod.down(gt.tree, gt.sel)) do
      st.pin[num] = true
    end
  end
  gt.remote = base
  if force then
    gt.saved = {} -- `R`: other branches' trees are fetched again when HEAD goes back to them
  end
  -- a newer fetch replaces one in flight: its rounds stop and their answers are dropped
  gt.gen = gt.gen + 1
  M.stop_job(gt)
  local parts, aliases = tree_mod.first_parts(st)
  return {
    st = st,
    gen = gt.gen,
    extra = {
      host = repo.host,
      parts = parts,
      fragment = tree_mod.FRAGMENT,
      absorb = function(data, err)
        tree_mod.absorb(st, data, aliases, err)
      end,
    },
  }
end

function M.stop_job(gt)
  if gt.job then
    local job = gt.job
    gt.job = nil
    pcall(function()
      job:kill(15)
    end)
  end
end

---Take a fetch's tree. `final`: the closed subtrees are in too. The stack is rebuilt every
---time (the same stack keeps its object, so nothing reloads when the path did not change).
---Exposed for tests (M._take).
local function take(s, st, final)
  local gt = state(s)
  if st.failed then
    log.write('forge', 'stack tree: ' .. tostring(st.failed))
  end
  if st.cut then
    log.write('forge', 'stack tree cut: ' .. st.cut)
  end
  local t = tree_mod.tree(st)
  local changed = false
  if not t then
    if st.failed and gt.tree then
      gt.stale = true -- `R` failed: the last tree stays, marked
    else
      -- a failure is said in the panel: redraw the stack's notes
      changed = gt.tree ~= nil or (st.failed ~= nil and st.calls > 1)
      gt.tree = nil
      gt.reason = st.failed and 'the GitHub lookup failed (see revuey.log)'
        or ('no pull request for ' .. table.concat(st.start, ' / '))
      -- a failure of the first call is the PR lookup's too (no gh, offline, rate limits):
      -- quiet like it (decision 13); one in the tree's own rounds is noted in the panel
      gt.failed = (st.failed ~= nil and st.calls > 1) or nil
    end
  else
    changed = true
    -- a round that failed leaves a partial tree (the heading says so; `R` retries); `stale` is
    -- for the last good tree kept after a refetch that failed outright
    gt.tree, gt.stale, gt.reason, gt.failed = t, nil, nil, nil
    -- a chosen PR gone from GitHub's answer: only once the whole tree is in (phase one may lack
    -- a closed subtree), and not after a failed round (the tree is partial)
    if final and not st.failed and gt.sel and not t.nodes[gt.sel] then
      gt.sel = nil
    end
  end
  gt.loading = not final and t ~= nil
  gt.calls = st.calls
  if changed then
    gt.version = gt.version + 1
  end
  vim.schedule(function()
    if s.cleaned then
      return
    end
    if changed then
      -- without a tree, or a cut one, the diff may be the same and only the notes change:
      -- redraw anyway
      require('revuey.view').refresh({ force = (t == nil or t.cut ~= nil) or nil })
    end
    M.redraw(s)
  end)
end
M._take = take

---The rounds after the first, after the lookup, in a task of their own (so the PR lookup's lock,
---threads and `R` never wait for them): what routes need first, then the stack is rebuilt, then
---the closed subtrees. A newer fetch (`R`, a new branch) or closing the review stops them.
function M.continue(s, job)
  local gt = state(s)
  local st, gen = job.st, job.gen
  local function alive()
    return not s.cleaned and gt.gen == gen
  end
  if not alive() then
    return
  end
  gt.running = gen
  local function finished()
    if gt.running == gen then
      gt.running = nil
    end
  end
  git.async(function()
    local function rounds(closed)
      while alive() do
        local want = tree_mod.plan(st, closed)
        if not want then
          return
        end
        local parts, aliases = tree_mod.parts(st, want)
        local data, err = forge.run_graphql(tree_mod.query(parts), st.repo.host, function(obj)
          gt.job = obj
        end)
        if not alive() then
          return
        end
        gt.job = nil
        tree_mod.absorb(st, data, aliases, err)
      end
    end
    rounds(false)
    if not alive() then
      return finished()
    end
    local has = tree_mod.tree(st) ~= nil
    take(s, st, false)
    if has then
      rounds(true)
      if alive() then
        take(s, st, true)
      end
    end
    finished()
  end, function(err)
    finished()
    log.write('forge', 'stack tree error: ' .. tostring(err))
  end)
end

-- ---------------------------------------------------------------------------
-- HEAD moved (a checkout elsewhere, `gS`)
-- ---------------------------------------------------------------------------

---Follow HEAD to another branch. A branch of the tree (`gS` to a layer, a checkout of one of
---its PRs' branches) keeps the tree: its path when on it, else the route through its PR. Any
---other branch has its own stack: its tree when this review fetched one before, else a first
---fetch for it (decision 20: never fetched in this review), git detection meanwhile.
---@return boolean refetch a first fetch for the new branch is due
function M.follow_head(s, head_branch)
  local gt = s.gh_tree
  if not gt or not gt.fetched or head_branch == gt.for_branch then
    return false
  end
  local function short(branch, remote)
    if branch and remote and branch:sub(1, #remote + 1) == remote .. '/' then
      return branch:sub(#remote + 2) -- detached at `origin/x`: the PR branch x
    end
    return branch
  end
  -- into a tree: the path through the branch's PR (the same path when it is on it)
  local function enter(num)
    gt.for_branch = head_branch
    local path = M.path(s)
    if not vim.tbl_contains(path, num) then
      gt.sel = num
    elseif not gt.sel then
      gt.sel = gt.tree.start -- the same path; `@` moves along it
    end
    gt.version = gt.version + 1
    return false
  end
  local num = gt.tree and head_branch and gt.tree.rep[short(head_branch, gt.remote)]
  if num then
    return enter(num)
  end
  -- leaving: only a finished fetch is kept for coming back (a tree still loading, or a lookup
  -- in flight, is fetched again then: a first fetch)
  local old = gt.for_branch
  if old and not gt.loading and not gt.running and (gt.tree or gt.reason) then
    gt.saved[old] = { tree = gt.tree, sel = gt.sel, reason = gt.reason, stale = gt.stale, remote = gt.remote, failed = gt.failed }
  end
  gt.gen = gt.gen + 1
  M.stop_job(gt)
  gt.loading, gt.running, gt.version = nil, nil, gt.version + 1
  gt.built, gt.head_pr = nil, nil
  -- a tree kept for this branch, or one that has this branch's PR in it
  local key = head_branch and gt.saved[head_branch] and head_branch
  if not key and head_branch then
    for k, e in pairs(gt.saved) do
      if e.tree and e.tree.rep[short(head_branch, e.remote)] then
        key = k
        break
      end
    end
  end
  if key then
    local back = gt.saved[key]
    gt.saved[key] = nil
    gt.tree, gt.sel, gt.reason, gt.stale, gt.remote, gt.failed = back.tree, back.sel, back.reason, back.stale, back.remote, back.failed
    gt.for_branch = head_branch
    local n = gt.tree and gt.tree.rep[short(head_branch, gt.remote)]
    if n and key ~= head_branch then
      return enter(n)
    end
    return false
  end
  gt.for_branch = head_branch
  gt.tree, gt.sel, gt.reason, gt.stale, gt.failed = nil, nil, nil, nil, nil
  gt.fetched = false
  return true
end

-- ---------------------------------------------------------------------------
-- The stack for the chosen path
-- ---------------------------------------------------------------------------

---What the clone has (refs, head commits, which local branches contain their open PR's
---head). Inside git.async.
---@return revuey.TreeFacts
function M.facts(s, root, trunk, t)
  local gt = state(s)
  t = t or gt.tree
  local heads, refs = {}, {}
  local out = git.git({ 'for-each-ref', '--format=%(objectname) %(refname)', 'refs/heads', 'refs/remotes' }, root) or ''
  for line in out:gmatch('[^\n]+') do
    local sha, ref = line:match('^(%x+) (%S+)$')
    if ref and ref:sub(1, 11) == 'refs/heads/' then
      heads[ref:sub(12)] = sha
    elseif ref and ref:sub(1, 13) == 'refs/remotes/' then
      refs[ref:sub(14)] = sha
    end
  end
  local objects, oids = {}, {}
  for _, n in pairs(t and t.nodes or {}) do
    if n.head_oid then
      oids[#oids + 1] = n.head_oid
    end
  end
  if #oids > 0 then
    local res = git.system({ 'git', 'cat-file', '--batch-check' }, { cwd = root, stdin = table.concat(oids, '\n') .. '\n' })
    for oid, kind in tostring(res.stdout or ''):gmatch('(%x+) (%a+)') do
      if kind == 'commit' then
        objects[oid] = true
      end
    end
  end
  -- local branches of the tree's PRs that are not at their PR's head: do they contain it (your
  -- commits on top)? Is HEAD built on them (a lower branch restacked locally)?
  local current = git.current_branch(root)
  local head = git.rev_parse('HEAD', root)
  local contains, in_head, behind, fns, which = {}, {}, {}, {}, {}
  local function check(set, key, a, b)
    which[#which + 1] = { set, key }
    fns[#fns + 1] = function()
      return git.git({ 'merge-base', '--is-ancestor', a, b }, root) ~= nil
    end
  end
  -- HEAD's PR: its branch's in the tree, else the PR the tree was fetched for when HEAD is
  -- still that branch (its head may have another name on GitHub: a push name, a fork)
  local head_num = t and current and (t.rep[current] or (current == gt.for_branch and t.start)) or nil
  for name, lb in pairs(heads) do
    local num = t and t.rep[name]
    if name == current then
      num = head_num
    end
    local n = num and t.nodes[num]
    if n and n.head_oid and lb ~= n.head_oid then
      if objects[n.head_oid] then
        check(contains, name, n.head_oid, lb)
        check(behind, name, lb, n.head_oid)
      end
      if head and lb ~= head and name ~= current then
        check(in_head, name, lb, head)
      end
    end
  end
  local b = t and t.bottom_base
  if b and heads[b] and head and heads[b] ~= head then
    check(in_head, b, heads[b], head)
  end
  for i, r in ipairs(git.all(fns)) do
    which[i][1][which[i][2]] = (r[1] and r[2] == true) or nil
  end
  -- built on by HEAD but only behind the PR (an older commit of it, the trunk): not a local
  -- restack, just an old copy
  for name in pairs(behind) do
    in_head[name] = nil
  end
  local remotes = git.remotes(root)
  return {
    remote = gt.remote or 'origin',
    heads = heads,
    refs = refs,
    objects = objects,
    contains = contains,
    in_head = in_head,
    head_num = head_num,
    trunk = trunk,
    trunk_rev = git.rev_parse(trunk, root),
    current = current or s.review.head_branch,
    detached = current == nil or nil,
    head = head,
    normalize = function(n)
      return require('revuey.state').normalize_base(n, remotes)
    end,
  }
end

---The PRs of the chosen path (bottom first) and the index of the chosen PR.
---The chosen PR when the tree has it (after `R` it may not, until the closed PRs are read:
---the default route meanwhile).
function M.chosen(gt, t)
  t = t or gt.tree
  return t and gt.sel and t.nodes[gt.sel] and gt.sel or nil
end

function M.path(s, t)
  local gt = state(s)
  t = t or gt.tree
  if not t then
    return {}
  end
  return tree_mod.route(t, M.chosen(gt, t) or t.start)
end

local function signature(st)
  local parts = { st.trunk_rev or '', tostring(st.current) }
  for _, l in ipairs(st.layers) do
    parts[#parts + 1] = table.concat({
      l.name, l.tip, l.parent_rev, tostring(l.pr), tostring(l.others), tostring(l.others_closed), tostring(l.fetch),
      tostring(l.is_head), tostring(l.diverged),
    }, ' ')
  end
  for _, n in ipairs(st.notes) do
    parts[#parts + 1] = n.kind .. ' ' .. n.text
  end
  return table.concat(parts, '\n')
end

-- git detection's notes that stay true of a GitHub stack (the rest are about its own guesses)
local KEEP_NOTES = { upstream = true, detached = true, newer_copy = true, outdated_copy = true, other_copy = true }

---Notes about the tree for a review without a GitHub stack (a failed or cut fetch).
function M.review_notes(s, ctx)
  local gt = s.gh_tree
  if not (M.enabled() and gt and gt.fetched) then
    return {}
  end
  local notes_mod = require('revuey.stack_notes')
  local rk = first_key('refresh')
  if gt.failed then
    return { notes_mod.new('tree_incomplete', { branch = gt.for_branch or 'HEAD', why = 'failed', key = rk }, ctx) }
  end
  if gt.tree and gt.tree.cut then
    -- a tree cut short (a failed round, a limit) that left no stack of its own
    return { notes_mod.new('tree_incomplete', { branch = gt.for_branch or 'HEAD', why = gt.tree.cut, key = rk }, ctx) }
  end
  return {}
end

---The review's stack from the tree (inside git.async), or nil to keep git detection's: no tree,
---or a default route of one PR (a lone branch stays a plain review until a path is chosen).
---`git_stack` is what git detection found: local-only layers above the path's top (branches
---without a PR yet) stay on top; its notes that still hold are kept, and explicit parent
---settings GitHub disagrees with are noted. Unchanged inputs give the same stack object.
---@return revuey.Stack?
function M.stack(s, git_stack, root, trunk, fingerprint, git_notes)
  local gt = s.gh_tree
  if not (M.enabled() and gt and gt.tree and trunk) then
    return nil
  end
  -- one tree throughout: a fetch landing while git runs below must not mix two trees
  local t = gt.tree
  local sel = M.chosen(gt, t)
  local path = M.path(s, t)
  if #path < 2 and not sel then
    return nil
  end
  local key = table.concat({ fingerprint or '', gt.version, gt.facts_gen, tostring(sel) }, '\0')
  if gt.built and gt.built.key == key then
    return gt.built.stack
  end
  local facts = M.facts(s, root, trunk, t)
  if not facts.trunk_rev then
    return nil
  end
  local st = tree_mod.stack(t, path, sel, facts)
  if not st then
    return nil
  end
  local notes_mod = require('revuey.stack_notes')
  local ctx = { stack = true, trunk = trunk }
  local fk, rk = first_key('stack_fetch'), first_key('refresh')
  -- layers not restacked onto their parent PR's head: like GitHub's PR view, their diff from the
  -- merge base holds the parent's old commits
  local fns, pairs_ = {}, {}
  for i = 2, #st.layers do
    local l, p = st.layers[i], st.layers[i - 1]
    if l.pr and p.pr and l.parent_rev == p.tip then
      pairs_[#pairs_ + 1] = i
      fns[#fns + 1] = function()
        return git.git({ 'merge-base', '--is-ancestor', p.tip, l.tip }, root) ~= nil
      end
    end
  end
  for k, r in ipairs(git.all(fns)) do
    if r[1] and r[2] == false then
      local l = st.layers[pairs_[k]]
      l.diverged = true
      st.notes[#st.notes + 1] = notes_mod.new('pr_not_restacked', { branch = l.name, parent = st.layers[pairs_[k] - 1].name, pr = l.pr }, ctx)
    end
  end
  -- local branches above the top without a PR (yet): git detection's layers stay on top
  local top = st.layers[#st.layers]
  if git_stack and not top.remote then
    local at
    for i, l in ipairs(git_stack.layers) do
      if l.name == top.name then
        at = i
      end
    end
    for i = (at or #git_stack.layers) + 1, #git_stack.layers do
      local l = vim.deepcopy(git_stack.layers[i])
      -- a branch with a PR in the tree is placed by GitHub, not here: the local stack stops
      -- (gb shows where its PR is), never a layer pinned to nothing
      local num = t.rep[l.name] or t.rep[require('revuey.forge').branch_name(l.name)]
      if num then
        st.notes[#st.notes + 1] = notes_mod.new('local_above', { branch = l.name, pr = num, layer = top.name }, ctx)
        break
      end
      l.stats = nil
      st.layers[#st.layers + 1] = l
      if l.is_head and not st.head_index then
        st.head_index = #st.layers
        if not sel then
          st.current = #st.layers
        end
      end
    end
  end
  -- a parent you set (revuey setting, Graphite) that GitHub's base contradicts: the stack follows
  -- GitHub, and says so (inferred git parents are only guesses: not noted)
  for _, gl in ipairs(git_stack and git_stack.layers or {}) do
    if gl.source == 'config' or gl.source == 'graphite' then
      for i, l in ipairs(st.layers) do
        if l.pr and l.name == gl.name then
          local mine = i > 1 and st.layers[i - 1].name or st.trunk
          if gl.parent ~= mine and require('revuey.forge').branch_name(gl.parent) ~= require('revuey.forge').branch_name(mine) then
            st.notes[#st.notes + 1] = notes_mod.new('github_parent', {
              branch = l.name, parent = gl.parent, source = gl.source, layer = mine, pr = l.pr,
            }, ctx)
          end
        end
      end
    end
  end
  for _, n in ipairs(git_notes or {}) do
    if KEEP_NOTES[n.kind] then
      st.notes[#st.notes + 1] = n
    end
  end
  for _, num in ipairs(st.missing) do
    local n = t.nodes[num]
    st.notes[#st.notes + 1] = notes_mod.new('not_fetched', {
      branch = n.fork and ((n.head_owner or '?') .. ':' .. n.head) or n.head,
      pr = num,
      ref = (not n.fork) and (facts.remote .. '/' .. n.head) or ('pull/' .. num .. '/head'),
      key = fk,
    }, ctx)
  end
  for _, l in ipairs(st.layers) do
    if l.local_differs then
      st.notes[#st.notes + 1] = notes_mod.new('local_differs', {
        branch = l.remote and l.pr_head or l.name, pr = l.pr, layer = l.name,
        head = l.local_differs == 'head' or nil, restacked = l.local_differs == 'restacked' or nil,
      }, ctx)
    end
  end
  local bottom = t.nodes[t.chain[1]]
  if path[1] == t.chain[1] then
    if t.stop == 'cut' then
      st.notes[#st.notes + 1] = notes_mod.new('tree_incomplete', { branch = bottom.head, parent = bottom.base, why = 'chain', key = rk }, ctx)
    elseif t.stop == 'cycle' then
      st.notes[#st.notes + 1] = notes_mod.new('github_base', { branch = bottom.head, parent = bottom.base, why = 'cycle' }, ctx)
    elseif t.bottom_base then
      st.notes[#st.notes + 1] = notes_mod.new('github_base', {
        branch = bottom.head, parent = t.bottom_base, missing = st.base_missing, pr = bottom.number,
      }, ctx)
    end
  end
  if t.cut and t.stop ~= 'cut' then
    st.notes[#st.notes + 1] = notes_mod.new('tree_incomplete', { branch = bottom.head, why = t.cut, key = rk }, ctx)
  end
  local ign = require('revuey.stack_ignore')
  require('revuey.stack').finish(root, st, ign.patterns((ign.for_root(root, s.opts and s.opts.state_dir))))
  if sel and vim.tbl_contains(st.missing, sel) then
    gt.want_view = sel -- shown once it is fetched
  end
  if sel and gt.notify_missing == sel and vim.tbl_contains(st.missing, sel) then
    gt.notify_missing = nil
    vim.schedule(function()
      vim.notify(('revuey: PR #%d is not in this clone yet; %s fetches it'):format(sel, fk or 'stack_fetch'), vim.log.levels.WARN)
    end)
  end
  -- the checked-out branch off the chosen path (you picked another one): said
  if not st.head_index and facts.current and not facts.detached and facts.heads[facts.current] then
    st.notes[#st.notes + 1] = notes_mod.new('head_off_path', { branch = facts.current, key = first_key('stack_tree') }, ctx)
  end
  local cur = facts.current
  if cur and cur:sub(1, #facts.remote + 1) == facts.remote .. '/' then
    cur = cur:sub(#facts.remote + 2)
  end
  gt.head_pr = (st.head_index and st.layers[st.head_index].pr) or (cur and t.rep[cur]) or nil
  -- the same stack as before: keep the object (a new one reloads the review)
  local sig = signature(st)
  if gt.built and gt.built.sig == sig then
    gt.built.key = key
    return gt.built.stack
  end
  gt.built = { key = key, sig = sig, stack = st }
  return st
end

-- ---------------------------------------------------------------------------
-- Fetching the stack's branches (git; nothing on GitHub changes)
-- ---------------------------------------------------------------------------

---The chosen PR, missing when it was chosen, now a layer of `stack`: the scope to show it in
---(once).
function M.pending_view(s, stack)
  local gt = s.gh_tree
  local want = gt and gt.want_view
  if not (want and stack) then
    return nil
  end
  if want ~= gt.sel then
    gt.want_view = nil
    return nil
  end
  for _, l in ipairs(stack.layers) do
    if l.pr == want then
      gt.want_view = nil
      return { kind = 'layer', pr = want }
    end
  end
end

---Why the tree key does nothing here (nil: there is a tree).
function M.unavailable(s)
  local gt = s and s.gh_tree
  if not M.enabled() then
    return 'the stack tree is off (stack.github = false, or forge disabled)'
  end
  if gt and gt.tree then
    return nil
  end
  if not gt or not gt.fetched then
    return 'the stack tree comes from GitHub with the PR lookup; it has not run yet'
  end
  if not gt.reason then
    return 'the stack tree is still loading from GitHub'
  end
  return ('no stack tree from GitHub: %s (the stack comes from git)'):format(gt.reason or 'not loaded')
end

---Environment of `git fetch`: no prompt from git (GIT_TERMINAL_PROMPT=0) nor from ssh (BatchMode:
---no host key question, no passphrase on /dev/tty, which would draw over the editor), unless
---ssh is configured otherwise (GIT_SSH_COMMAND, GIT_SSH, core.sshCommand: yours is used as is).
---@param env_ssh? string $GIT_SSH_COMMAND
---@param core_ssh? string git config core.sshCommand
---@param git_ssh? string $GIT_SSH
function M.fetch_env(env_ssh, core_ssh, git_ssh)
  local env = { GIT_TERMINAL_PROMPT = '0' }
  local function unset(v)
    return v == nil or v == ''
  end
  if unset(env_ssh) and unset(core_ssh) and unset(git_ssh) then
    env.GIT_SSH_COMMAND = 'ssh -o BatchMode=yes'
  end
  return env
end

---The `git fetch` command line for `specs` from `remote`.
function M.fetch_cmd(remote, specs)
  local cmd = { 'git', 'fetch', '--no-tags', '--no-write-fetch-head', '--no-recurse-submodules', remote }
  return vim.list_extend(cmd, specs)
end

---Is a failed fetch's error about a ref (a branch gone on GitHub, a ref it won't serve), so
---the refspecs are worth trying one by one? Never for a timeout or a connection failure:
---those would only fail again, each after its own timeout.
function M.ref_error(code, stderr)
  if code == 124 then
    return false
  end
  stderr = stderr or ''
  return stderr:find("couldn't find remote ref", 1, true) ~= nil or stderr:find('not our ref', 1, true) ~= nil
    or stderr:find('invalid refspec', 1, true) ~= nil or stderr:find('unadvertised object', 1, true) ~= nil
end

---Stop a fetch in flight (the review closed): its process group, git and ssh with it.
function M.stop_fetch(gt)
  local proc = gt and gt.fetch_proc
  if proc then
    gt.fetch_proc = nil
    require('revuey.ai').terminate(proc)
  end
end

---`git fetch` the heads of `nums` (default: the chosen path) from the PRs' remote: branches
---that exist on GitHub into `<remote>/<head>`, forks, deleted branches and closed PRs through
---`refs/pull/N/head` (commits only, no ref written). All at once; when that fails on a ref,
---one by one, a branch that is gone through its pull ref, so what can be fetched is. Closing
---the review stops it. Then the review refreshes.
function M.fetch(s, nums)
  local why = M.unavailable(s)
  if why then
    return vim.notify('revuey: ' .. why, vim.log.levels.INFO)
  end
  local gt = state(s)
  if gt.fetching then
    return vim.notify('revuey: a fetch is already running', vim.log.levels.INFO)
  end
  nums = nums or M.path(s)
  local root = s.review.root
  local trunk = s.review.tree_trunk
  local t = gt.tree
  gt.fetching = true
  local ai = require('revuey.ai')
  git.async(function()
    local facts = M.facts(s, root, trunk, t)
    local specs, which = tree_mod.fetch_specs(t, nums, facts)
    if #specs == 0 or s.cleaned then
      gt.fetching = false
      if s.cleaned then
        return
      end
      return vim.notify('revuey: nothing to fetch: the stack is up to date with GitHub', vim.log.levels.INFO)
    end
    vim.notify(('revuey: fetching %d PR%s from %s…'):format(#which, #which == 1 and '' or 's', facts.remote), vim.log.levels.INFO)
    local env = M.fetch_env(vim.env.GIT_SSH_COMMAND, vim.trim(git.git({ 'config', '--get', 'core.sshCommand' }, root) or ''), vim.env.GIT_SSH)
    local co = coroutine.running()
    ---One `git fetch`, in a process group of its own (closing the review stops git and ssh).
    local function run(list)
      if s.cleaned then
        return { code = -1, stderr = 'review closed' }
      end
      local ok, proc = pcall(vim.system, M.fetch_cmd(facts.remote, list), {
        cwd = root, timeout = 120000, env = env, text = true, detach = true,
      }, function(res)
        vim.schedule(function()
          git.resume(co, res)
        end)
      end)
      if not ok then
        return { code = -1, stderr = tostring(proc) }
      end
      gt.fetch_proc = proc
      ai.live[proc] = true
      local res = coroutine.yield()
      ai.live[proc] = nil
      if gt.fetch_proc == proc then
        gt.fetch_proc = nil
      end
      return res
    end
    local res = run(specs)
    local ok, via_pull, failed, errs = {}, {}, {}, {}
    if res.code == 0 then
      ok = which
    else
      errs[#errs + 1] = vim.trim(tostring(res.stderr or ''))
      if M.ref_error(res.code, res.stderr) then
        for i, spec in ipairs(specs) do
          if s.cleaned then
            break
          end
          local r = run({ spec })
          if r.code == 0 then
            ok[#ok + 1] = which[i]
          else
            errs[#errs + 1] = vim.trim(tostring(r.stderr or ''))
            local pull = ('refs/pull/%d/head'):format(which[i])
            if spec ~= pull and M.ref_error(r.code, r.stderr) and run({ pull }).code == 0 then
              via_pull[#via_pull + 1] = which[i] -- the branch is gone on GitHub: its commits at least
            else
              failed[#failed + 1] = which[i]
            end
          end
        end
      else
        failed = which
      end
    end
    gt.fetching = false
    gt.facts_gen = gt.facts_gen + 1
    if s.cleaned then
      return
    end
    for _, e in ipairs(errs) do
      log.write('stack', 'git fetch: ' .. e)
    end
    local function list(l)
      return table.concat(vim.tbl_map(function(n)
        return '#' .. n
      end, l), ' ')
    end
    local parts = {}
    if #ok > 0 then
      parts[#parts + 1] = ('fetched %s'):format(list(ok))
    end
    if #via_pull > 0 then
      parts[#parts + 1] = ('%s only by their pull refs (branch gone on GitHub)'):format(list(via_pull))
    end
    if #failed > 0 then
      local last = (errs[#errs] or ''):match('([^\n]*)$') or ''
      if res.code == 124 then
        last = 'timed out'
      end
      parts[#parts + 1] = ('could not fetch %s%s'):format(list(failed), last ~= '' and (' (' .. last .. ')') or ' (see revuey.log)')
    end
    vim.notify(('revuey: %s from %s'):format(table.concat(parts, '; '), facts.remote),
      #failed > 0 and (#ok + #via_pull > 0 and vim.log.levels.WARN or vim.log.levels.ERROR) or vim.log.levels.INFO)
    require('revuey.view').refresh({ force = true })
    M.redraw(s)
  end, function(err)
    gt.fetching = false
    vim.schedule(function()
      vim.notify('revuey: ' .. tostring(err), vim.log.levels.ERROR)
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- The tree view (a float over the diff window)
-- ---------------------------------------------------------------------------

local function display_branch(n)
  return n.fork and ((n.head_owner or '?') .. ':' .. n.head) or n.head
end

---The PR the review is viewing (its layer's), if any.
local function viewed_pr(s)
  local r = s.review
  local l = r.stack and r.scope and r.scope.kind == 'layer' and r.stack.layers[r.scope.index]
  return l and l.pr or nil
end

---Right-side chunks of a node row.
local function right_chunks(s, t, n, row, marks)
  local out = {}
  local function add(text, hl)
    out[#out + 1] = { text, hl }
  end
  if row.hidden then
    add(('+%d closed  '):format(row.hidden), 'Comment')
  end
  if t.more[n.number] then
    add(('+%d more on GitHub  '):format(t.more[n.number]), 'Comment')
  elseif t.unexpanded[n.number] then
    add('…  ', 'Comment')
  end
  local reach = marks[n.number]
  if reach and reach.mark then
    add(tree_mod.MARK_TEXT[reach.mark] .. '  ', 'RevueyStackWarn')
  end
  if n.fork then
    add('fork  ', 'Comment')
  end
  local m = forge.row(n)
  if m.marker then
    add(m.marker, m.marker_hl)
  elseif m.glyph then
    add(m.glyph, m.glyph_hl)
  end
  local gt = s.gh_tree
  local head = gt.built and gt.head_pr or (not gt.built and t.start) or nil
  add(n.number == head and ' @' or '  ', 'RevueyUncommitted')
  add(n.number == viewed_pr(s) and ' ▶' or '  ', 'RevueyMode')
  return out
end

local function chunks_width(ch)
  local w = 0
  for _, c in ipairs(ch) do
    w = w + vim.fn.strdisplaywidth(c[1])
  end
  return w
end

---Lines of the tree at `width`: a title, then the graph (tree_mod.layout: the reviewed path in
---column 0, `●` on its PRs, `○` elsewhere), one row per PR with its number, branch and title
---after the graph, and the details right-aligned (virtual text, cut first in a narrow window).
---Returns lines, virtual text per row, row -> PR, and per row what M.highlight colours.
function M.lines(s, width, marks)
  local gt = s.gh_tree
  local t = gt.tree
  local v = gt.view or {}
  local path = M.path(s)
  local reviewed = {}
  for _, num in ipairs(path) do
    reviewed[num] = true
  end
  local rows = tree_mod.layout(t, { show_closed = v.show_closed, on_path = reviewed, main = reviewed })
  local lines, virt, row_pr, info = {}, {}, {}, {}
  local title = (' Stack tree · %d PR%s on %s'):format(t.count, t.count == 1 and '' or 's', t.trunk)
  local extra = (gt.loading and ' · loading closed PRs…' or '') .. (gt.stale and ' · stale (R failed)' or '')
    .. (t.cut and (' · cut: ' .. t.cut) or '')
  lines[1] = title .. extra
  info[1] = { title = #title, extra = #title + #extra }
  local panel = require('revuey.panel')
  for _, r in ipairs(rows) do
    local ln = #lines + 1
    if r.kind == 'trunk' then
      local g, segs = tree_mod.graph(r, '●')
      lines[ln] = g .. t.trunk
      info[ln] = { segs = segs, trunk = true, text = { #g, #lines[ln] } }
    elseif r.kind == 'join' then
      local g, segs = tree_mod.graph(r, '')
      lines[ln] = (g:gsub('%s+$', ''))
      info[ln] = { segs = segs }
    else
      local n = t.nodes[r.node]
      local g, segs = tree_mod.graph(r, reviewed[n.number] and '●' or '○')
      g = g:gsub('%s+$', '') .. ' '
      local right = right_chunks(s, t, n, r, marks)
      local num = '#' .. n.number
      local branch = display_branch(n)
      local gw = vim.fn.strdisplaywidth(g)
      local function room()
        return width - gw - #num - 1 - chunks_width(right) - 2
      end
      -- a wide graph or a narrow window: the right side shrinks to the review chip and the
      -- markers (its last three chunks), then goes, before the text would run under it
      if room() < 8 then
        right = vim.list_slice(right, math.max(#right - 2, 1))
      end
      if room() < 4 then
        right = {}
      end
      local avail = room()
      branch = panel.truncate(branch, math.max(math.min(vim.fn.strdisplaywidth(branch), math.max(avail - 12, math.floor(avail * 0.6))), 1))
      local title_room = avail - vim.fn.strdisplaywidth(branch) - 2
      local ttl = title_room >= 4 and ('  ' .. panel.truncate(n.title, title_room)) or ''
      lines[ln] = g .. num .. ' ' .. branch .. ttl
      local nstart = #g
      info[ln] = {
        segs = segs, node = n.number,
        num = { nstart, nstart + #num }, branch = { nstart + #num + 1, nstart + #num + 1 + #branch },
        title = { nstart + #num + 1 + #branch, #lines[ln] },
      }
      for _, sg in ipairs(segs) do
        if sg.node then
          info[ln].glyph = sg[1]
        end
      end
      virt[ln] = right
      row_pr[ln] = n.number
    end
  end
  return lines, virt, row_pr, info, rows
end

---Marks of every node (how the clone reaches its head), from the last facts.
local function node_marks(s)
  local gt = s.gh_tree
  local out = {}
  if not (gt.view and gt.view.facts) then
    return out
  end
  for num, n in pairs(gt.tree.nodes) do
    out[num] = tree_mod.reach(n, gt.view.facts)
  end
  return out
end

---The closed PRs of the tree (for the legend).
local function closed_count(t)
  local n = 0
  for _, x in pairs(t.nodes) do
    if x.state == 'CLOSED' then
      n = n + 1
    end
  end
  return n
end

---The footer: the path <CR> would review (from the trunk through the PR under the cursor and
---on along its default route), and the keys.
function M.footer_lines(s, width)
  local gt = s.gh_tree
  local v = gt.view
  local t = gt.tree
  local num = M.cursor_pr(s)
  local path = num and tree_mod.route(t, num) or M.path(s)
  local label = ' path: '
  -- `⇣` on PRs whose commits are not here: the stack would stop below them (gF fetches them)
  local marks = node_marks(s)
  local text = label .. tree_mod.path_text(t.trunk, path, math.max(width - #label - 1, 10), function(n)
    return (marks[n] and marks[n].how == 'none') and '⇣' or ''
  end)
  -- the keys, shortened to fit: fewer words before any key goes
  local keys = require('revuey.keys')
  local n = closed_count(t)
  local legend
  for _, tpl in ipairs({
    ' j/k up/down  h/l other branch  <CR> review  {tree_closed} closed (' .. n .. ')  {stack_fetch} fetch  q close',
    ' j/k up/down  h/l branch  <CR> review  {tree_closed} closed  {stack_fetch} fetch  q close',
    ' j k h l move  <CR> review  {tree_closed} closed  {stack_fetch} fetch  q',
  }) do
    legend = keys.line(tpl) or ''
    if vim.fn.strdisplaywidth(legend) <= width then
      break
    end
  end
  return { text, legend }, #label
end

---Colour the path under consideration: from the trunk to the PR under the cursor and on along
---its default route, nodes, lines and text, in RevueyTreePath; the rest of the graph and the
---other PRs dim. Also the footer.
function M.highlight(s)
  local gt = s.gh_tree
  local v = gt and gt.view
  if not (v and api.nvim_buf_is_valid(v.buf) and api.nvim_win_is_valid(v.win)) then
    return
  end
  api.nvim_buf_clear_namespace(v.buf, ns_path, 0, -1)
  local t = gt.tree
  local num = M.cursor_pr(s)
  local on = {}
  if num then
    for _, p in ipairs((tree_mod.route(t, num))) do
      on[p] = true
    end
  end
  local function edge_on(c)
    local p = t.parent[c]
    return on[c] and (p == 'root' or on[p]) or false
  end
  local function hl(row, a, b, group)
    if b > a then
      pcall(api.nvim_buf_set_extmark, v.buf, ns_path, row - 1, a, { end_col = b, hl_group = group, priority = 20 })
    end
  end
  for row, inf in pairs(v.info or {}) do
    if inf.extra then
      hl(row, 0, inf.title, 'RevueyPanelTitle')
      hl(row, inf.title, inf.extra, 'Comment')
    end
    for _, sg in ipairs(inf.segs or {}) do
      local lit = false
      if sg.node then
        lit = sg.node == 'root' or on[sg.node] or false
      else
        for _, c in ipairs(sg.edges or {}) do
          lit = lit or edge_on(c)
        end
      end
      hl(row, sg[1], sg[2], lit and 'RevueyTreePath' or 'RevueyTreeDim')
    end
    if inf.trunk then
      hl(row, inf.text[1], inf.text[2], 'RevueyTreePath')
    elseif inf.node then
      local lit = on[inf.node]
      hl(row, inf.num[1], inf.num[2], lit and 'RevueyTreePath' or 'RevueyTreeDim')
      hl(row, inf.branch[1], inf.branch[2], lit and 'RevueyTreePath' or 'RevueyTreeDim')
      hl(row, inf.title[1], inf.title[2], lit and 'Normal' or 'RevueyTreeDim')
    end
  end
  M.render_footer(s)
end

---Draw the footer float.
function M.render_footer(s)
  local v = s.gh_tree and s.gh_tree.view
  if not (v and v.fbuf and api.nvim_buf_is_valid(v.fbuf) and api.nvim_win_is_valid(v.fwin)) then
    return
  end
  local lines, label = M.footer_lines(s, api.nvim_win_get_width(v.fwin))
  vim.bo[v.fbuf].modifiable = true
  api.nvim_buf_set_lines(v.fbuf, 0, -1, false, lines)
  vim.bo[v.fbuf].modifiable = false
  api.nvim_buf_clear_namespace(v.fbuf, ns, 0, -1)
  api.nvim_buf_set_extmark(v.fbuf, ns, 0, 0, { end_col = label, hl_group = 'Comment' })
  api.nvim_buf_set_extmark(v.fbuf, ns, 0, label, { end_col = #lines[1], hl_group = 'RevueyTreePath' })
  api.nvim_buf_set_extmark(v.fbuf, ns, 1, 0, { end_col = #lines[2], hl_group = 'Comment' })
end

---The PR on the cursor's row (the nearest PR row above, on a connector row).
function M.cursor_pr(s)
  local v = s.gh_tree and s.gh_tree.view
  if not (v and api.nvim_win_is_valid(v.win)) then
    return nil
  end
  local row = api.nvim_win_get_cursor(v.win)[1]
  for r = row, 1, -1 do
    if v.row_pr[r] then
      return v.row_pr[r]
    end
  end
  for r = row + 1, #v.lines do
    if v.row_pr[r] then
      return v.row_pr[r]
    end
  end
end

---Put the cursor on PR `num`'s glyph.
local function put_cursor(s, num)
  local v = s.gh_tree.view
  for row, p in pairs(v.row_pr) do
    if p == num then
      api.nvim_win_set_cursor(v.win, { row, v.info[row].glyph or 0 })
      return true
    end
  end
end

---Draw the tree view (keeps the cursor on its PR).
function M.render_view(s)
  local gt = s.gh_tree
  local v = gt and gt.view
  if not (v and api.nvim_buf_is_valid(v.buf) and api.nvim_win_is_valid(v.win)) then
    return
  end
  if not gt.tree then
    return M.close_view(s)
  end
  local keep = M.cursor_pr(s) or v.want
  v.want = nil
  local width = api.nvim_win_get_width(v.win)
  local lines, virt, row_pr, info, rows = M.lines(s, width, node_marks(s))
  v.lines, v.row_pr, v.info, v.rows = lines, row_pr, info, rows
  vim.bo[v.buf].modifiable = true
  api.nvim_buf_set_lines(v.buf, 0, -1, false, lines)
  vim.bo[v.buf].modifiable = false
  api.nvim_buf_clear_namespace(v.buf, ns, 0, -1)
  for row, ch in pairs(virt) do
    api.nvim_buf_set_extmark(v.buf, ns, row - 1, 0, { virt_text = ch, virt_text_pos = 'right_align' })
  end
  if not (keep and put_cursor(s, keep)) then
    local first
    for row in pairs(row_pr) do
      first = (not first or row < first) and row or first
    end
    if first then
      put_cursor(s, row_pr[first])
    end
  end
  M.highlight(s)
end

---Redraw what shows the tree (the view when open). Called when a fetch lands.
function M.redraw(s)
  local v = s.gh_tree and s.gh_tree.view
  if not v then
    return
  end
  git.async(function()
    v.facts = M.facts(s, s.review.root, s.review.tree_trunk)
    vim.schedule(function()
      M.render_view(s)
    end)
  end, function() end)
end

function M.close_view(s)
  local gt = s and s.gh_tree
  local v = gt and gt.view
  if not v then
    return
  end
  gt.view = nil
  for _, w in ipairs({ v.win, v.fwin }) do
    if w and api.nvim_win_is_valid(w) then
      pcall(api.nvim_win_close, w, true)
    end
  end
  for _, b in ipairs({ v.buf, v.fbuf }) do
    if b and api.nvim_buf_is_valid(b) then
      pcall(api.nvim_buf_delete, b, { force = true })
    end
  end
  if s.diff_win and api.nvim_win_is_valid(s.diff_win) and not s.cleaned then
    pcall(api.nvim_set_current_win, s.diff_win)
  end
end

---Move the cursor with `key` (j k h l; tree_mod.nav), a count of times.
function M.move(s, key)
  local v = s.gh_tree.view
  local num = M.cursor_pr(s)
  if not (v and num) then
    return
  end
  for _ = 1, vim.v.count1 do
    local nxt = tree_mod.nav(s.gh_tree.tree, v.rows, num, key)
    if nxt == num then
      break
    end
    num = nxt
  end
  put_cursor(s, num)
  M.highlight(s)
end

---Review the path through `num`: the stack becomes the trunk-to-`num` chain plus its default
---continuation, viewing `num`'s layer. Session state only.
function M.select(s, num)
  local gt = state(s)
  if not (gt.tree and gt.tree.nodes[num]) then
    return
  end
  gt.sel = num
  gt.notify_missing = num
  M.close_view(s)
  require('revuey.view').refresh({ scope = { kind = 'layer', pr = num }, force = true })
end

---Where the tree and its footer go: over the diff window, the footer on its last two rows.
local function geometry(s)
  local w, hgt = api.nvim_win_get_width(s.diff_win), api.nvim_win_get_height(s.diff_win)
  -- a float relative to a window starts below its winbar: the rows below it are the text area
  local info = vim.fn.getwininfo(s.diff_win)[1]
  hgt = hgt - ((info and info.winbar) or 0)
  -- the footer only with room for it (hidden, not left where it was, in a short window)
  local room = hgt >= 6
  local fh = room and 2 or 0
  return {
    main = { relative = 'win', win = s.diff_win, row = 0, col = 0, width = w, height = math.max(hgt - fh, 1) },
    footer = {
      relative = 'win', win = s.diff_win, row = math.max(hgt - 2, 0), col = 0, width = w, height = 2, hide = not room,
    },
  }
end

---Open the tree view over the diff window (the tree key).
function M.open_view(s)
  if not s then
    return
  end
  local why = M.unavailable(s)
  if why then
    return vim.notify('revuey: ' .. why, vim.log.levels.INFO)
  end
  local gt = state(s)
  if gt.view then
    return M.close_view(s)
  end
  if not (s.diff_win and api.nvim_win_is_valid(s.diff_win)) then
    return
  end
  local geo = geometry(s)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'revuey-tree'
  pcall(api.nvim_buf_set_name, buf, 'revuey://stack-tree')
  local win = api.nvim_open_win(buf, true, vim.tbl_extend('force', geo.main, { style = 'minimal', border = 'none', zindex = 40 }))
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].scrolloff = 3
  vim.wo[win].winhighlight = 'NormalFloat:Normal,CursorLine:RevueyTreeCursor'
  local fbuf, fwin
  do
    fbuf = api.nvim_create_buf(false, true)
    vim.bo[fbuf].bufhidden = 'wipe'
    fwin = api.nvim_open_win(fbuf, false, vim.tbl_extend('force', geo.footer, {
      style = 'minimal', border = 'none', zindex = 41, focusable = false,
    }))
    vim.wo[fwin].wrap = false
    vim.wo[fwin].winhighlight = 'NormalFloat:Normal'
  end
  gt.view = {
    buf = buf, win = win, fbuf = fbuf, fwin = fwin, show_closed = false, lines = {}, row_pr = {}, info = {},
    want = viewed_pr(s) or gt.tree.start,
  }
  local function map(lhs, fn, desc)
    for _, l in ipairs(type(lhs) == 'table' and lhs or { lhs }) do
      vim.keymap.set('n', l, fn, { buffer = buf, nowait = true, silent = true, desc = 'revuey: ' .. desc })
    end
  end
  for key, lhs in pairs({ j = { 'j', '<Down>' }, k = { 'k', '<Up>' }, h = { 'h', '<Left>' }, l = { 'l', '<Right>' } }) do
    map(lhs, function()
      M.move(s, key)
    end, ({ j = 'stack tree: down (the PR it is based on)', k = 'stack tree: up the column',
      h = 'stack tree: the branch to the left', l = 'stack tree: the branch to the right' })[key])
  end
  map({ '<CR>', '<2-LeftMouse>' }, function()
    local num = M.cursor_pr(s)
    if num then
      M.select(s, num)
    end
  end, 'stack tree: review the path through this PR')
  map({ 'q', '<Esc>' }, function()
    M.close_view(s)
  end, 'stack tree: close')
  local ck = require('revuey.keys').list('tree_closed')
  if #ck > 0 then
    map(ck, function()
      gt.view.show_closed = not gt.view.show_closed
      M.render_view(s)
    end, 'stack tree: show / hide closed PRs')
  end
  local fk = require('revuey.keys').list('stack_fetch')
  if #fk > 0 then
    map(fk, function()
      local num = M.cursor_pr(s)
      M.fetch(s, num and (tree_mod.route(gt.tree, num)) or nil)
    end, 'stack tree: fetch the path under the cursor')
  end
  local hk = require('revuey.keys').list('help')
  if #hk > 0 then
    map(hk, require('revuey.key_help').toggle, 'all revuey keys (a float)')
  end
  local group = api.nvim_create_augroup('revuey.tree.' .. buf, { clear = true })
  api.nvim_create_autocmd('CursorMoved', {
    group = group, buffer = buf,
    callback = function()
      M.highlight(s)
    end,
  })
  api.nvim_create_autocmd('WinLeave', {
    group = group, buffer = buf,
    callback = function()
      vim.schedule(function()
        local cur = api.nvim_get_current_win()
        -- another float (the g? list of keys) keeps the tree; any other window closes it
        if gt.view and gt.view.buf == buf and cur ~= win and cur ~= fwin and api.nvim_win_get_config(cur).relative == '' then
          M.close_view(s)
        end
      end)
    end,
  })
  -- the diff window resized (the screen, the panel toggled): the tree follows it
  api.nvim_create_autocmd({ 'VimResized', 'WinResized' }, {
    group = group,
    callback = function()
      local v = gt.view
      if v and v.buf == buf and api.nvim_win_is_valid(v.win) and api.nvim_win_is_valid(s.diff_win) then
        local g = geometry(s)
        api.nvim_win_set_config(v.win, g.main)
        if v.fwin and api.nvim_win_is_valid(v.fwin) then
          api.nvim_win_set_config(v.fwin, g.footer)
        end
        M.render_view(s)
      end
    end,
  })
  api.nvim_create_autocmd('BufWipeout', {
    group = group, buffer = buf,
    callback = function()
      pcall(api.nvim_del_augroup_by_id, group)
    end,
  })
  -- draw at once from what is known, then again with the clone's refs (fetch marks)
  M.render_view(s)
  M.redraw(s)
end

---Review cleanup.
function M.detach(s)
  M.close_view(s)
  local gt = s and s.gh_tree
  if gt then
    gt.gen = gt.gen + 1 -- rounds in flight drop their answers
    M.stop_job(gt)
    M.stop_fetch(gt) -- and a `git fetch` stops
  end
end

---Short texts for a panel layer row's hint lines (under it while the panel has focus).
function M.hints(l)
  local out = {}
  local tk, fk = first_key('stack_tree'), first_key('stack_fetch')
  if l.others and tk then
    local closed = l.others_closed or 0
    local what = closed == l.others and (closed == 1 and '1 closed PR' or (closed .. ' closed PRs'))
      or (l.others == 1 and '1 other path' or (l.others .. ' other paths'))
    out[#out + 1] = ('%s tree: %s here'):format(tk, what)
  end
  if l.fetch and fk then
    out[#out + 1] = ('%s fetch: %s'):format(fk, l.fetch == 'behind' and 'origin is behind GitHub' or 'not fetched yet')
  end
  return out
end

return M
