-- Stack detection: unit tests of the pure resolver, then detect() against real git repos.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
local stack = require('revuey.stack')
-- hermetic: the stack ignore list lives in the state dir, never the developer's own
local state_dir = h.tmpdir('stack-spec-state')
require('revuey.config').set({ state_dir = state_dir })

-- ---------------------------------------------------------------------------
-- Unit: resolve()
-- ---------------------------------------------------------------------------

---Build resolver input. `commits` maps commit -> first parent ('' = parent is in trunk); only
---commits not reachable from trunk are listed. `merged` tips are known to be in trunk.
local function input(o)
  local loaded = {}
  for c in pairs(o.commits) do
    loaded[c] = true
  end
  for _, c in ipairs(o.merged or {}) do
    loaded[c] = true
  end
  return {
    trunk = o.trunk or 'main',
    trunk_rev = 'T',
    trunk_names = o.trunk_names or { main = true },
    current = o.current,
    head = o.head or o.branches[o.current],
    branches = o.branches,
    graph = o.commits,
    loaded = loaded,
    above = o.above or {},
    explicit = o.explicit,
    owned = o.owned,
    merges = o.merges,
  }
end

local function names(st)
  return vim.tbl_map(function(l)
    return l.name
  end, st.layers)
end

local function note_of(notes, kind, branch)
  for _, n in ipairs(notes or {}) do
    if n.kind == kind and (branch == nil or n.branch == branch) then
      return n
    end
  end
end

local function has_note(st, kind, branch)
  return note_of(st.notes, kind, branch) ~= nil
end

local function parents(st)
  return vim.tbl_map(function(l)
    return l.parent
  end, st.layers)
end

-- main ── a1 ── a2 (feat/a) ── b1 (feat/b) ── c1 ── c2 (feat/c)
local linear = { a1 = '', a2 = 'a1', b1 = 'a2', c1 = 'b1', c2 = 'c1' }
local linear_branches = { main = 'T', ['feat/a'] = 'a2', ['feat/b'] = 'b1', ['feat/c'] = 'c2' }

h.test('linear stack, current in the middle: ordered trunk to top', function()
  local st = stack.resolve(input({
    commits = linear,
    branches = linear_branches,
    current = 'feat/b',
    above = { 'feat/b', 'feat/c' },
  }))
  h.eq({ 'feat/a', 'feat/b', 'feat/c' }, names(st))
  h.eq({ 'main', 'feat/a', 'feat/b' }, parents(st))
  h.eq({ 'T', 'a2', 'b1' }, vim.tbl_map(function(l)
    return l.parent_rev
  end, st.layers))
  h.eq(2, st.current)
  h.eq({ false, true, false }, vim.tbl_map(function(l)
    return l.is_head
  end, st.layers))
  h.eq('inferred', st.layers[1].source)
  h.eq({}, st.forks)
  h.eq({}, st.notes)
end)

h.test('current at the top and at the bottom', function()
  local top = stack.resolve(input({ commits = linear, branches = linear_branches, current = 'feat/c', above = { 'feat/c' } }))
  h.eq({ 'feat/a', 'feat/b', 'feat/c' }, names(top))
  h.eq(3, top.current)
  local bottom = stack.resolve(input({
    commits = linear,
    branches = linear_branches,
    current = 'feat/a',
    above = { 'feat/a', 'feat/b', 'feat/c' },
  }))
  h.eq({ 'feat/a', 'feat/b', 'feat/c' }, names(bottom))
  h.eq(1, bottom.current)
end)

h.test('single branch, detached HEAD, trunk checked out, nothing committed: no stack', function()
  h.eq(nil, stack.resolve(input({ commits = { a1 = '' }, branches = { main = 'T', a = 'a1' }, current = 'a', above = { 'a' } })))
  h.eq(nil, stack.resolve(input({ commits = linear, branches = linear_branches, current = nil, head = 'b1' })))
  h.eq(nil, stack.resolve(input({ commits = linear, branches = linear_branches, current = 'main', head = 'T' })))
  -- branch with no commits of its own (tip in trunk)
  h.eq(nil, stack.resolve(input({ commits = linear, branches = vim.tbl_extend('force', linear_branches, { fresh = 'T' }), current = 'fresh', head = 'T' })))
end)

h.test('fork above: stop and report it', function()
  local commits = vim.tbl_extend('force', linear, { d1 = 'b1' })
  local branches = vim.tbl_extend('force', linear_branches, { ['feat/d'] = 'd1' })
  local st = stack.resolve(input({ commits = commits, branches = branches, current = 'feat/b', above = { 'feat/b', 'feat/c', 'feat/d' } }))
  h.eq({ 'feat/a', 'feat/b' }, names(st))
  h.eq({ { at = 'feat/b', children = { 'feat/c', 'feat/d' } } }, st.forks)
  h.ok(note_of(st.notes, 'fork', 'feat/b') and #note_of(st.notes, 'fork').branches == 2, vim.inspect(st.notes))
  -- a fork right above a lone branch is still worth showing
  local lone = stack.resolve(input({
    commits = { a1 = '', c1 = 'a1', d1 = 'a1' },
    branches = { main = 'T', a = 'a1', c = 'c1', d = 'd1' },
    current = 'a',
    above = { 'a', 'c', 'd' },
  }))
  h.eq({ 'a' }, names(lone))
  h.eq({ 'c', 'd' }, lone.forks[1].children)
end)

h.test('fork further up: follows the single child, stops at the fork', function()
  local commits = vim.tbl_extend('force', linear, { d1 = 'c2', e1 = 'c2' })
  local branches = vim.tbl_extend('force', linear_branches, { d = 'd1', e = 'e1' })
  local st = stack.resolve(input({ commits = commits, branches = branches, current = 'feat/a', above = { 'feat/a', 'feat/b', 'feat/c', 'd', 'e' } }))
  h.eq({ 'feat/a', 'feat/b', 'feat/c' }, names(st))
  h.eq('feat/c', st.forks[1].at)
end)

h.test('duplicate tips: deterministic pick, others mentioned; current branch preferred', function()
  local branches = vim.tbl_extend('force', linear_branches, { ['feat/a-copy'] = 'a2', ['feat/b-wip'] = 'b1', ['feat/c2'] = 'c2' })
  local st = stack.resolve(input({
    commits = linear,
    branches = branches,
    current = 'feat/b-wip',
    above = { 'feat/b', 'feat/b-wip', 'feat/c', 'feat/c2' },
  }))
  h.eq({ 'feat/a', 'feat/b-wip', 'feat/c' }, names(st))
  h.eq({ 'feat/a-copy' }, st.layers[1].also)
  h.eq({ 'feat/b' }, st.layers[2].also)
  h.eq({ 'feat/c2' }, st.layers[3].also)
  h.eq('feat/b-wip', st.layers[3].parent)
  h.eq(3, #st.notes, vim.inspect(st.notes))
  -- same commit at two names with no current preference: a branch with an explicit parent wins
  local st2 = stack.resolve(input({
    commits = linear,
    branches = branches,
    current = 'feat/c',
    above = { 'feat/c', 'feat/c2' },
    explicit = { ['feat/a-copy'] = { parent = 'main', source = 'graphite' } },
  }))
  h.eq({ 'feat/a-copy', 'feat/b', 'feat/c' }, names(st2))
end)

h.test('explicit parent overrides the heuristic (skipping a branch)', function()
  local st = stack.resolve(input({
    commits = linear,
    branches = linear_branches,
    current = 'feat/c',
    above = { 'feat/c' },
    explicit = { ['feat/c'] = { parent = 'feat/a', source = 'graphite' } },
  }))
  h.eq({ 'feat/a', 'feat/c' }, names(st))
  h.eq('graphite', st.layers[2].source)
  h.eq('a2', st.layers[2].parent_rev)
end)

h.test('explicit parent that is not an ancestor: history is requested, layer diffs against trunk, with a note', function()
  -- feat/a was amended to a3 (sibling of a2); feat/b still sits on the old a2
  local commits = { a1 = '', a2 = 'a1', b1 = 'a2' }
  local branches = { main = 'T', ['feat/a'] = 'a3', ['feat/b'] = 'b1' }
  local inp = input({
    commits = commits,
    branches = branches,
    current = 'feat/b',
    above = { 'feat/b' },
    explicit = { ['feat/b'] = { parent = 'feat/a', source = 'config' } },
  })
  local st, need = stack.resolve(inp)
  h.eq(nil, st)
  h.eq({ 'a3' }, need)
  inp.graph.a3 = 'a1'
  inp.loaded.a3 = true
  st = stack.resolve(inp)
  h.eq({ 'feat/a', 'feat/b' }, names(st))
  -- feat/a's tip is not under feat/b: diffing from it (or their merge-base) would be wrong
  h.eq('T', st.layers[2].parent_rev)
  h.eq(true, st.layers[2].stale)
  h.eq({ 'feat/b', 'feat/a', 'config' }, (function(n) return { n.branch, n.parent, n.source } end)(note_of(st.notes, 'stale_parent')), vim.inspect(st.notes))
  -- with feat/a's reflog showing it used to be at a2, it is a parent that moved: diff from a2
  inp.owned = { a2 = { 'feat/a' } }
  st = stack.resolve(inp)
  h.eq('a2', st.layers[2].parent_rev)
  h.eq(true, st.layers[2].diverged)
  h.ok(has_note(st, 'not_restacked', 'feat/b'), vim.inspect(st.notes))
end)

h.test('explicit children above HEAD that do not contain it are followed', function()
  -- feat/b was rebuilt; feat/c (explicit child of b) still on the old b0
  local commits = { a1 = '', b1 = 'a1', b0 = 'a1', c1 = 'b0' }
  local branches = { main = 'T', ['feat/a'] = 'a1', ['feat/b'] = 'b1', ['feat/c'] = 'c1' }
  local inp = input({
    commits = { a1 = '', b1 = 'a1' },
    branches = branches,
    current = 'feat/b',
    above = { 'feat/b' },
    explicit = { ['feat/c'] = { parent = 'feat/b', source = 'graphite' } },
  })
  local st, need = stack.resolve(inp)
  h.eq({ 'c1' }, need)
  inp.graph = commits
  inp.loaded.c1 = true
  st = stack.resolve(inp)
  h.eq({ 'feat/a', 'feat/b', 'feat/c' }, names(st))
end)

h.test('merged lower layer: drops out (heuristic) or becomes trunk (explicit, with a note)', function()
  -- feat/a was fast-forward merged into main: its commits are no longer in the graph
  local commits = { b1 = '', c1 = 'b1' }
  local branches = { main = 'T', ['feat/a'] = 'a2', ['feat/b'] = 'b1', ['feat/c'] = 'c1' }
  local st = stack.resolve(input({ commits = commits, branches = branches, current = 'feat/c', above = { 'feat/c' }, merged = { 'a2' } }))
  h.eq({ 'feat/b', 'feat/c' }, names(st))
  h.eq('main', st.layers[1].parent)
  local st2 = stack.resolve(input({
    commits = commits,
    branches = branches,
    current = 'feat/c',
    above = { 'feat/c' },
    merged = { 'a2' },
    explicit = { ['feat/b'] = { parent = 'feat/a', source = 'graphite' } },
  }))
  h.eq({ 'feat/b', 'feat/c' }, names(st2))
  h.eq('main', st2.layers[1].parent)
  h.eq('feat/a', (note_of(st2.notes, 'parent_landed', 'feat/b') or {}).parent, vim.inspect(st2.notes))
end)

h.test('squash-merged lower layer (not in trunk history) stays a layer', function()
  local st = stack.resolve(input({ commits = linear, branches = linear_branches, current = 'feat/c', above = { 'feat/c' } }))
  h.eq({ 'feat/a', 'feat/b', 'feat/c' }, names(st))
end)

h.test('trunk ahead, stack not rebased: bottom layer diffs against trunk (merge-base taken later)', function()
  -- trunk moved on to T; the graph only holds the stack commits either way
  local st = stack.resolve(input({ commits = linear, branches = linear_branches, current = 'feat/c', above = { 'feat/c' } }))
  h.eq('T', st.layers[1].parent_rev)
  local t = stack.target(st, { kind = 'full' })
  h.eq('T', t.from)
end)

h.test('explicit parent naming trunk, unknown branch, or a cycle', function()
  local st = stack.resolve(input({
    commits = linear,
    branches = linear_branches,
    current = 'feat/c',
    above = { 'feat/c' },
    explicit = { ['feat/b'] = { parent = 'main', source = 'config' } },
  }))
  h.eq({ 'feat/b', 'feat/c' }, names(st))
  local st2 = stack.resolve(input({
    commits = linear,
    branches = linear_branches,
    current = 'feat/c',
    above = { 'feat/c' },
    explicit = { ['feat/c'] = { parent = 'gone', source = 'graphite' } },
  }))
  h.eq({ 'feat/a', 'feat/b', 'feat/c' }, names(st2))
  h.eq('gone', (note_of(st2.notes, 'unknown_parent', 'feat/c') or {}).parent, vim.inspect(st2.notes))
  local st3 = stack.resolve(input({
    commits = linear,
    branches = linear_branches,
    current = 'feat/b',
    above = { 'feat/b' },
    explicit = { ['feat/b'] = { parent = 'feat/a', source = 'config' }, ['feat/a'] = { parent = 'feat/b', source = 'config' } },
  }))
  h.eq({ 'feat/a', 'feat/b' }, names(st3))
  h.eq('main', st3.layers[1].parent)
  h.ok(has_note(st3, 'cycle'), vim.inspect(st3.notes))
end)

h.test('remote trunk: local branch of the same name is trunk, not a layer', function()
  local branches = vim.tbl_extend('force', linear_branches, { main = 'a1' })
  local st = stack.resolve(input({
    trunk = 'origin/main',
    trunk_names = { ['origin/main'] = true, main = true },
    commits = linear,
    branches = branches,
    current = 'feat/b',
    above = { 'feat/b', 'feat/c' },
  }))
  h.eq({ 'feat/a', 'feat/b', 'feat/c' }, names(st))
  h.eq('origin/main', st.layers[1].parent)
end)

h.test('merge commits: the heuristic follows first parents only', function()
  -- feat/b merged side branch `side` (tip s1); side must not become b's parent
  local commits = { a1 = '', s1 = '', m1 = 'a1', b1 = 'm1' }
  local st = stack.resolve(input({
    commits = commits,
    branches = { main = 'T', a = 'a1', side = 's1', b = 'b1' },
    current = 'b',
    above = { 'b' },
  }))
  h.eq({ 'a', 'b' }, names(st))
end)

h.test('target(): layer and full scope', function()
  local st = stack.resolve(input({ commits = linear, branches = linear_branches, current = 'feat/b', above = { 'feat/b', 'feat/c' } }))
  local t2 = stack.target(st, { kind = 'layer', index = 2 })
  h.eq({
    from = 'a2',
    floor = 'T',
    branch = 'feat/b',
    base = 'feat/a',
    state_branch = 'feat/b',
    state_base = 'feat/a',
    key_old = true,
    committed_only = false,
  }, t2)
  -- the bottom layer keeps chunk-1 keys (shared with the plain single-branch review)
  local t1 = stack.target(st, { kind = 'layer', index = 1 })
  h.eq({ 'T', nil, nil }, { t1.from, t1.floor, t1.key_old })
  local t3 = stack.target(st, { kind = 'layer', index = 3 })
  h.eq('c2', t3.to)
  h.eq(true, t3.committed_only)
  local full = stack.target(st, { kind = 'full' })
  h.eq({ 'T', 'c2', 'feat/c', 'main', 'main', true }, { full.from, full.to, full.branch, full.base, full.state_base, full.committed_only })
end)

h.test('graphite metadata parsing is defensive', function()
  h.eq('feat/a', stack.graphite_parent('{"parentBranchName":"feat/a","parentBranchRevision":"abc"}'))
  h.eq(nil, stack.graphite_parent('{"prInfo":{}}'))
  h.eq(nil, stack.graphite_parent('not json'))
  h.eq(nil, stack.graphite_parent(nil))
  h.eq(nil, stack.graphite_parent('[1,2]'))
end)

h.test('pick() is deterministic', function()
  h.eq({ 'a', { 'b', 'c' } }, { stack.pick({ 'c', 'a', 'b' }) })
  h.eq({ 'c', { 'a', 'b' } }, { stack.pick({ 'c', 'a', 'b' }, 'c') })
  h.eq({ 'b', { 'a', 'c' } }, { stack.pick({ 'c', 'a', 'b' }, nil, { b = {} }) })
end)

h.test('parent moved (new commit, amend or rebase): child stays in the stack, diffed from the old tip', function()
  -- feat/a: a1 -> a2, then moved on to a3 (new commit) / a2' (amend or rebase: not containing a2).
  -- feat/b still sits on a2. feat/a's reflog records a2 as an old tip.
  for _, case in ipairs({
    { what = 'new commit', commits = { a1 = '', a2 = 'a1', a3 = 'a2', b1 = 'a2' }, tip = 'a3' },
    { what = 'amend', commits = { a1 = '', a2 = 'a1', ['a2*'] = 'a1', b1 = 'a2' }, tip = 'a2*' },
    { what = 'rebase', commits = { a1 = '', a2 = 'a1', ['a1*'] = '', ['a2*'] = 'a1*', b1 = 'a2' }, tip = 'a2*' },
  }) do
    for _, current in ipairs({ 'feat/a', 'feat/b' }) do
      local st = stack.resolve(input({
        commits = case.commits,
        branches = { main = 'T', ['feat/a'] = case.tip, ['feat/b'] = 'b1' },
        current = current,
        above = current == 'feat/a' and { 'feat/a', 'feat/b' } or { 'feat/b' },
        owned = { a2 = { 'feat/a' } },
      }))
      local msg = case.what .. ' from ' .. current
      h.ok(st, msg)
      h.eq({ 'feat/a', 'feat/b' }, names(st), msg)
      h.eq('a2', st.layers[2].parent_rev, msg)
      h.eq(true, st.layers[2].diverged, msg)
      h.eq({ 'feat/a', 'a2' }, (function(n) return { n.parent, n.at } end)(note_of(st.notes, 'not_restacked', 'feat/b') or {}), msg .. vim.inspect(st.notes))
    end
  end
end)

h.test('reflog ownership: own old tips, descendants and a merged-in parent are not divergence', function()
  -- feat/b merged feat/a's new tip a3 (instead of rebasing): a is a normal parent at a3
  local st = stack.resolve(input({
    commits = { a1 = '', a2 = 'a1', a3 = 'a2', b1 = 'a2', m = 'b1' },
    branches = { main = 'T', ['feat/a'] = 'a3', ['feat/b'] = 'm' },
    current = 'feat/b',
    above = { 'feat/b' },
    owned = { a2 = { 'feat/a', 'feat/b' } },
    merges = { m = { 'a3' } },
  }))
  h.eq({ 'feat/a', 'feat/b' }, names(st))
  h.eq('a3', st.layers[2].parent_rev)
  h.eq(nil, st.layers[2].diverged)
  -- a child that once pointed at a commit of its parent's line is not the parent's parent
  local st2 = stack.resolve(input({
    commits = { a1 = '', a2 = 'a1', b1 = 'a2' },
    branches = { main = 'T', ['feat/a'] = 'a2', ['feat/b'] = 'b1' },
    current = 'feat/a',
    above = { 'feat/a', 'feat/b' },
    owned = { a1 = { 'feat/b' } },
  }))
  h.eq({ 'feat/a', 'feat/b' }, names(st2))
  h.eq('main', st2.layers[1].parent)
end)

h.test('reflog_tips(): commits/amends/rebases count, creation does not, a reset ends ownership', function()
  local z = string.rep('0', 40)
  local function log(entries)
    return table.concat(entries, '\n') .. '\n'
  end
  local created = z .. ' b0 me <m@x> 1 +0000\tbranch: Created from HEAD'
  local history = {
    created,
    'b0 a1 me <m@x> 2 +0000\tcommit: a.txt',
    'a1 a2 me <m@x> 3 +0000\tcommit (amend): a',
    'a2 a3 me <m@x> 4 +0000\trebase (finish): refs/heads/a onto main',
  }
  h.eq({ 'a2', 'a1' }, stack.reflog_tips(log(history), 'a3'))
  -- `git reset --hard z` / `git branch -f a z`: the branch was abandoned; older tips are not its own
  for _, msg in ipairs({ 'reset: moving to z', 'branch: Reset to z' }) do
    local entries = vim.deepcopy(history)
    entries[#entries + 1] = 'a3 dd me <m@x> 5 +0000\t' .. msg
    h.eq({}, stack.reflog_tips(log(entries), 'dd'), msg)
    entries[#entries + 1] = 'dd d1 me <m@x> 6 +0000\tcommit: after reset'
    h.eq({}, stack.reflog_tips(log(entries), 'd1'), msg .. ' then a commit')
    entries[#entries + 1] = 'd1 d2 me <m@x> 7 +0000\tcommit: another'
    h.eq({ 'd1' }, stack.reflog_tips(log(entries), 'd2'), msg .. ': tips after the reset count')
  end
  h.eq({}, stack.reflog_tips(nil, 'x'))
end)

h.test('long name lists in notes are capped', function()
  h.eq('a, b, c', stack.list({ 'a', 'b', 'c' }))
  h.eq('a, b, c and 147 more', stack.list(vim.list_extend({ 'a', 'b', 'c' }, vim.split(string.rep('x ', 147), ' ', { trimempty = true }))))
end)

-- ---------------------------------------------------------------------------
-- Integration: detect() on real repositories
-- ---------------------------------------------------------------------------

local function commit(d, file, text)
  h.write(d, file, text)
  h.git(d, 'add', '-A')
  h.git(d, 'commit', '-q', '-m', file .. ' ' .. text:sub(1, 10))
end

---main ── feat/a ── feat/b ── feat/c (checked out at `at`)
local function stack_repo(name, at)
  local d = h.tmpdir(name)
  h.git(d, 'init', '-q', '-b', 'main')
  commit(d, 'base.txt', 'base\n')
  h.git(d, 'checkout', '-q', '-b', 'feat/a')
  commit(d, 'a.txt', 'a1\n')
  commit(d, 'a.txt', 'a2\n')
  h.git(d, 'checkout', '-q', '-b', 'feat/b')
  commit(d, 'b.txt', 'b\n')
  h.git(d, 'checkout', '-q', '-b', 'feat/c')
  commit(d, 'c.txt', 'c\n')
  h.git(d, 'checkout', '-q', at or 'feat/b')
  return d
end

local function detect(d, trunk)
  return stack.detect(d, trunk or 'main')
end


h.test('detect: linear stack from the middle', function()
  local d = stack_repo('st-linear')
  local st = detect(d)
  h.eq({ 'feat/a', 'feat/b', 'feat/c' }, names(st))
  h.eq(2, st.current)
  h.eq(vim.trim(h.git(d, 'rev-parse', 'feat/a')), st.layers[2].parent_rev)
  h.eq(true, st.layers[2].is_head)
end)

h.test('detect: no stack for a lone branch, detached HEAD, or on trunk', function()
  local d = h.repo('st-lone', { ['x'] = '1\n' }, { ['x'] = '2\n' })
  h.eq(nil, detect(d))
  local s = stack_repo('st-detached')
  h.git(s, 'checkout', '-q', '--detach', 'feat/b')
  h.eq(nil, detect(s))
  h.git(s, 'checkout', '-q', 'main')
  h.eq(nil, detect(s))
end)

h.test('detect: Graphite metadata blob overrides the heuristic; revuey config overrides Graphite', function()
  local d = stack_repo('st-graphite', 'feat/c')
  local blob = vim.trim(vim.system({ 'git', 'hash-object', '-w', '--stdin' }, {
    cwd = d,
    stdin = '{"parentBranchName":"feat/a","parentBranchRevision":"x"}',
    text = true,
  }):wait().stdout)
  h.git(d, 'update-ref', 'refs/branch-metadata/feat/c', blob)
  -- garbage metadata on another branch is skipped
  local bad = vim.trim(vim.system({ 'git', 'hash-object', '-w', '--stdin' }, { cwd = d, stdin = '{oops', text = true }):wait().stdout)
  h.git(d, 'update-ref', 'refs/branch-metadata/feat/b', bad)
  local st = detect(d)
  h.eq({ 'feat/a', 'feat/c' }, names(st))
  h.eq('graphite', st.layers[2].source)
  h.git(d, 'config', 'branch.feat/c.revueyParent', 'feat/b')
  st = detect(d)
  h.eq({ 'feat/a', 'feat/b', 'feat/c' }, names(st))
  h.eq('config', st.layers[3].source)
end)

h.test('detect: trunk moved ahead, stack not rebased', function()
  local d = stack_repo('st-ahead')
  h.git(d, 'checkout', '-q', 'main')
  commit(d, 'main.txt', 'later\n')
  h.git(d, 'checkout', '-q', 'feat/b')
  local st = detect(d)
  h.eq({ 'feat/a', 'feat/b', 'feat/c' }, names(st))
  h.eq(vim.trim(h.git(d, 'rev-parse', 'main')), st.layers[1].parent_rev)
end)

h.test('detect: trunk moved ahead, stack rebased', function()
  local d = stack_repo('st-rebased', 'feat/c')
  h.git(d, 'checkout', '-q', 'main')
  commit(d, 'main.txt', 'later\n')
  h.git(d, 'checkout', '-q', 'feat/c')
  h.git(d, 'rebase', '-q', '--update-refs', 'main')
  local st = detect(d)
  h.eq({ 'feat/a', 'feat/b', 'feat/c' }, names(st))
end)

h.test('detect: lower layer merged into trunk drops out', function()
  local d = stack_repo('st-merged')
  h.git(d, 'checkout', '-q', 'main')
  h.git(d, 'merge', '-q', '--ff-only', 'feat/a')
  h.git(d, 'checkout', '-q', 'feat/b')
  local st = detect(d)
  h.eq({ 'feat/b', 'feat/c' }, names(st))
  h.eq('main', st.layers[1].parent)
end)

h.test('detect: remote trunk name, state keys normalised', function()
  local d = stack_repo('st-remote')
  local bare = h.tmpdir('st-remote-origin')
  h.git(bare, 'init', '-q', '--bare')
  h.git(d, 'remote', 'add', 'origin', bare)
  h.git(d, 'push', '-q', 'origin', 'main')
  h.git(d, 'fetch', '-q', 'origin')
  local st = detect(d, 'origin/main')
  h.eq({ 'feat/a', 'feat/b', 'feat/c' }, names(st))
  h.eq('main', st.layers[1].state_base)
  h.eq('main', st.trunk_state)
end)

h.test('detect: cache skips work when refs are unchanged, refreshes when they change', function()
  local d = stack_repo('st-cache')
  local cache = {}
  local a = stack.detect(d, 'main', cache)
  h.ok(stack.detect(d, 'main', cache) == a, 'cached stack reused')
  h.git(d, 'branch', 'feat/b2', 'feat/b')
  local b = stack.detect(d, 'main', cache)
  h.ok(b ~= a)
  h.eq({ 'feat/b2' }, b.layers[2].also)
end)

h.test('detect: many unrelated branches stay fast', function()
  local d = stack_repo('st-many')
  -- 300 stale branches on trunk history and 50 unrelated feature branches
  local cmds = {}
  for i = 1, 300 do
    cmds[#cmds + 1] = ('create refs/heads/old/%d main\n'):format(i)
  end
  vim.system({ 'git', 'update-ref', '--stdin' }, { cwd = d, stdin = table.concat(cmds) }):wait()
  for i = 1, 50 do
    h.git(d, 'branch', 'other/' .. i, 'main')
  end
  local t0 = vim.uv.hrtime()
  local st = detect(d)
  local ms = (vim.uv.hrtime() - t0) / 1e6
  h.eq({ 'feat/a', 'feat/b', 'feat/c' }, names(st))
  io.write(('    (detect with 350 extra branches: %.0fms)\n'):format(ms))
  h.ok(ms < 1000, ms)
end)

---Files of each layer's review (committed), plus the full scope.
local function layer_files(d, st)
  local review = require('revuey.review')
  local res = {}
  for i = 1, #st.layers + 1 do
    local scope = i <= #st.layers and { kind = 'layer', index = i } or { kind = 'full' }
    local r = assert(review.load({ cwd = d, target = stack.target(st, scope), mode = 'committed', state_dir = h.tmpdir('st-files-state') }))
    res[i] = vim.tbl_map(function(f)
      return f.path
    end, r.files)
  end
  return res
end

---main <- a (a.txt) <- b (b.txt) <- c (c.txt); `move` then changes `a` without restacking b/c.
local function moved_parent(name, move, at)
  local d = h.tmpdir(name)
  h.git(d, 'init', '-q', '-b', 'main')
  commit(d, 'base.txt', 'base\n')
  h.git(d, 'checkout', '-q', '-b', 'a')
  commit(d, 'a.txt', 'a\n')
  h.git(d, 'checkout', '-q', '-b', 'b')
  commit(d, 'b.txt', 'b\n')
  h.git(d, 'checkout', '-q', '-b', 'c')
  commit(d, 'c.txt', 'c\n')
  h.git(d, 'checkout', '-q', 'a')
  move(d)
  h.git(d, 'checkout', '-q', at)
  return d
end

local moves = {
  ['new commit'] = function(d)
    commit(d, 'a2.txt', 'a2\n')
  end,
  amend = function(d)
    h.write(d, 'a.txt', 'a amended\n')
    h.git(d, 'commit', '-q', '-a', '--amend', '-m', 'a amended')
  end,
  rebase = function(d)
    h.git(d, 'checkout', '-q', 'main')
    commit(d, 'm.txt', 'trunk moved\n')
    h.git(d, 'checkout', '-q', 'a')
    h.git(d, 'rebase', '-q', 'main')
  end,
}

h.test('detect: parent moved (new commit, amend, rebase) without restacking its children', function()
  for what, move in pairs(moves) do
    for _, at in ipairs({ 'a', 'b', 'c' }) do
      local d = moved_parent('st-moved-' .. what:gsub(' ', '-') .. '-' .. at, move, at)
      local msg = what .. ' at ' .. at
      local st = detect(d)
      h.ok(st, msg .. ': no stack')
      h.eq({ 'a', 'b', 'c' }, names(st), msg)
      h.eq(true, st.layers[2].diverged, msg)
      h.eq('a', (note_of(st.notes, 'not_restacked', 'b') or {}).parent, msg .. vim.inspect(st.notes))
      local files = layer_files(d, st)
      h.eq({ 'b.txt' }, files[2], msg .. ': layer b shows only its own commits')
      h.eq({ 'c.txt' }, files[3], msg)
      h.ok(vim.tbl_contains(files[1], 'a.txt'), msg)
    end
  end
end)

h.test('detect: without reflogs a moved parent is reported, never silently merged into the child', function()
  local d = moved_parent('st-moved-noreflog', moves['new commit'], 'c')
  vim.fn.delete(d .. '/.git/logs', 'rf')
  local st = detect(d)
  h.eq({ 'b', 'c' }, names(st))
  h.eq('b', (note_of(st.notes, 'outside', 'a') or {}).layer, vim.inspect(st.notes))
end)

h.test('detect: a branch reset elsewhere (reset --hard / branch -f) does not own its old tip', function()
  for _, how in ipairs({ 'reset', 'branch -f' }) do
    local d = h.tmpdir('st-reset-' .. how:gsub('[^%w]', ''))
    h.git(d, 'init', '-q', '-b', 'main')
    commit(d, 'base.txt', 'base\n')
    h.git(d, 'checkout', '-q', '-b', 'z')
    commit(d, 'z.txt', 'z\n')
    h.git(d, 'checkout', '-q', 'main')
    h.git(d, 'checkout', '-q', '-b', 'a')
    commit(d, 'a.txt', 'a\n')
    h.git(d, 'checkout', '-q', '-b', 'b')
    commit(d, 'b.txt', 'b\n')
    if how == 'reset' then
      h.git(d, 'checkout', '-q', 'a')
      h.git(d, 'reset', '-q', '--hard', 'z')
      h.git(d, 'checkout', '-q', 'b')
    else
      h.git(d, 'branch', '-f', 'a', 'z')
    end
    local st = detect(d)
    if st then
      h.eq(false, vim.tbl_contains(names(st), 'a'), how .. ': ' .. vim.inspect(names(st)))
      h.eq(false, has_note(st, 'not_restacked'), how .. vim.inspect(st.notes))
    end
  end
end)

h.test('detect: fresh clone, parent amended before cloning: no stack, but a note for the plain review', function()
  local src = h.tmpdir('st-clone-src')
  h.git(src, 'init', '-q', '-b', 'main')
  commit(src, 'base.txt', 'base\n')
  h.git(src, 'checkout', '-q', '-b', 'a')
  commit(src, 'a.txt', 'a\n')
  h.git(src, 'checkout', '-q', '-b', 'b')
  commit(src, 'b.txt', 'b\n')
  h.git(src, 'checkout', '-q', 'a')
  vim.env.GIT_COMMITTER_DATE = '@' .. tostring(os.time() + 3600) .. ' +0000' -- the amended copy is newer
  h.write(src, 'a.txt', 'a amended\n')
  h.git(src, 'commit', '-q', '-a', '--amend', '-m', 'a amended')
  vim.env.GIT_COMMITTER_DATE = nil
  h.git(src, 'checkout', '-q', 'main')
  local d = h.tmpdir('st-clone')
  vim.fn.delete(d, 'rf')
  h.git(vim.fs.dirname(d), 'clone', '-q', src, d)
  h.git(d, 'branch', '-q', 'a', 'origin/a')
  h.git(d, 'checkout', '-q', '-b', 'b', 'origin/b')
  local st, notes = detect(d)
  h.eq(nil, st)
  h.eq('b', (note_of(notes, 'newer_copy', 'a') or {}).layer, vim.inspect(notes))
  -- the same check runs alongside a stack, and stays quiet for ordinary stacks
  local _, quiet = detect(stack_repo('st-clone-quiet'))
  h.eq(nil, quiet)
end)

h.test('detect: no stack, but another branch shares commits (parent moved, no reflog): note', function()
  local d = moved_parent('st-moved-nostack', moves['new commit'], 'b')
  h.git(d, 'branch', '-D', 'c')
  vim.fn.delete(d .. '/.git/logs', 'rf')
  local st, notes = detect(d)
  h.eq(nil, st)
  h.eq('b', (note_of(notes, 'outside', 'a') or {}).layer, vim.inspect(notes))
end)

h.test('detect: stale explicit parent (squash-merged a, b rebased onto main): note, and b shows only b', function()
  local d = h.tmpdir('st-stale')
  h.git(d, 'init', '-q', '-b', 'main')
  commit(d, 'base.txt', 'base\n')
  h.git(d, 'checkout', '-q', '-b', 'a')
  commit(d, 'a.txt', 'a\n')
  h.git(d, 'checkout', '-q', 'main')
  h.git(d, 'merge', '-q', '--squash', 'a')
  h.git(d, 'commit', '-q', '-m', 'squash a')
  h.git(d, 'checkout', '-q', '-b', 'b')
  commit(d, 'b.txt', 'b\n')
  h.git(d, 'checkout', '-q', '-b', 'c')
  commit(d, 'c.txt', 'c\n')
  h.git(d, 'config', 'branch.b.revueyParent', 'a')
  local st = detect(d)
  h.eq({ 'a', 'b', 'c' }, names(st))
  h.eq(true, st.layers[2].stale)
  h.eq('a', (note_of(st.notes, 'stale_parent', 'b') or {}).parent, vim.inspect(st.notes))
  local files = layer_files(d, st)
  h.eq({ 'b.txt' }, files[2])
  h.eq({ 'b.txt', 'c.txt' }, files[4])
end)

h.test('detect: squash-merged bottom layer is dimmed as landed; the child still diffs from it', function()
  local d = stack_repo('st-landed', 'feat/c')
  h.git(d, 'checkout', '-q', 'main')
  h.git(d, 'merge', '-q', '--squash', 'feat/a')
  h.git(d, 'commit', '-q', '-m', 'squash a')
  h.git(d, 'checkout', '-q', 'feat/c')
  local st = detect(d)
  h.eq({ 'feat/a', 'feat/b', 'feat/c' }, names(st))
  h.eq({ true, true }, { st.layers[1].landed, st.layers[1].dimmed })
  h.eq(nil, st.layers[2].landed)
  h.ok(has_note(st, 'landed', 'feat/a'), vim.inspect(st.notes))
  local files = layer_files(d, st)
  h.eq({ 'b.txt' }, files[2])
  -- an unlanded bottom layer is not dimmed
  h.eq(nil, detect(stack_repo('st-not-landed')).layers[1].landed)
end)

---main ── x ── y (two commits) ── z ── w, with x and y squash-merged into main (trunk also edits
---a line near y's change first) and their branches deleted; `land_z` squash-merges z as well.
local function squashed_below(name, land_z)
  local d = h.tmpdir(name)
  h.git(d, 'init', '-q', '-b', 'main')
  commit(d, 'shared.txt', 'one\ntwo\nthree\nfour\n')
  h.git(d, 'checkout', '-q', '-b', 'x')
  commit(d, 'x.txt', 'x\n')
  h.git(d, 'checkout', '-q', '-b', 'y')
  commit(d, 'shared.txt', 'one\ntwo\nthree\nFOUR\n')
  commit(d, 'y.txt', 'y\n')
  h.git(d, 'checkout', '-q', '-b', 'z')
  commit(d, 'z.txt', 'z\n')
  h.git(d, 'checkout', '-q', '-b', 'w')
  commit(d, 'w.txt', 'w\n')
  h.git(d, 'checkout', '-q', 'main')
  commit(d, 'other.txt', 'unrelated\n')
  h.git(d, 'merge', '-q', '--squash', 'x')
  h.git(d, 'commit', '-q', '-m', 'squash x')
  commit(d, 'shared.txt', 'ONE\ntwo\nthree\nfour\n')
  h.git(d, 'merge', '-q', '--squash', 'y')
  h.git(d, 'commit', '-q', '-m', 'squash y')
  if land_z then
    h.git(d, 'merge', '-q', '--squash', 'z')
    h.git(d, 'commit', '-q', '-m', 'squash z')
  end
  h.git(d, 'checkout', '-q', 'w')
  h.git(d, 'branch', '-q', '-D', 'x', 'y')
  return d
end

h.test('detect: commits squash-merged below the bottom layer are skipped, not shown in it', function()
  local d = squashed_below('st-squashed-below')
  local st = detect(d)
  h.eq({ 'z', 'w' }, names(st))
  h.eq(nil, st.layers[1].landed)
  h.eq(3, (note_of(st.notes, 'squashed', 'z') or {}).count, vim.inspect(st.notes))
  h.eq({ { 'z.txt' }, { 'w.txt' }, { 'w.txt', 'z.txt' } }, layer_files(d, st))
end)

h.test('detect: a landed bottom layer keeps its own squash-merged commits as its diff', function()
  local d = squashed_below('st-squashed-landed', true)
  local st = detect(d)
  h.eq({ 'z', 'w' }, names(st))
  h.eq(true, st.layers[1].landed)
  -- landed entirely: one note, the landed one, which says how many commits are skipped
  h.eq(false, has_note(st, 'squashed'), vim.inspect(st.notes))
  h.eq(3, (note_of(st.notes, 'landed', 'z') or {}).count, vim.inspect(st.notes))
  h.eq({ { 'z.txt' }, { 'w.txt' }, { 'w.txt', 'z.txt' } }, layer_files(d, st))
end)

h.test('detect: no commits are skipped when trunk only has similar, not identical, changes', function()
  local d = squashed_below('st-squashed-none')
  h.git(d, 'checkout', '-q', 'main')
  h.git(d, 'reset', '-q', '--hard', 'HEAD~3')
  commit(d, 'x.txt', 'x but different\n')
  h.git(d, 'checkout', '-q', 'w')
  local st = detect(d)
  h.eq(false, has_note(st, 'squashed'), vim.inspect(st.notes))
  h.eq({ 'shared.txt', 'x.txt', 'y.txt', 'z.txt' }, layer_files(d, st)[1])
end)

local LUA = 'local M = {}\nfunction M.a()\n  return 1\nend\nfunction M.b()\n  return 2\nend\nreturn M\n'

---main ── x ── z ── w, with `x` (on top of `base` files) then `on_main` run on main, x's branch
---deleted and w checked out. `on_z` adds commits to z before z.txt.
local function bottom_case(name, o)
  local d = h.tmpdir(name)
  h.git(d, 'init', '-q', '-b', 'main')
  for p, c in pairs(o.base) do
    h.write(d, p, c)
  end
  h.git(d, 'add', '-A')
  h.git(d, 'commit', '-q', '-m', 'base')
  h.git(d, 'checkout', '-q', '-b', 'x')
  o.x(d)
  h.git(d, 'checkout', '-q', '-b', 'z')
  if o.on_z then
    o.on_z(d)
  end
  commit(d, 'z.txt', 'z\n')
  h.git(d, 'checkout', '-q', '-b', 'w')
  commit(d, 'w.txt', 'w\n')
  h.git(d, 'checkout', '-q', 'main')
  o.on_main(d)
  h.git(d, 'checkout', '-q', 'w')
  h.git(d, 'branch', '-q', '-D', 'x')
  return d
end

local function squash_x(d)
  h.git(d, 'merge', '-q', '--squash', 'x')
  h.git(d, 'commit', '-q', '-m', 'squash x')
end

local function bottom_files(d)
  local st = detect(d)
  return layer_files(d, st)[1], st
end

h.test('detect: a squash-merge trunk has since reverted is not skipped', function()
  local files, st = bottom_files(bottom_case('st-sq-revert', {
    base = { ['base.txt'] = 'base\n' },
    x = function(d)
      commit(d, 'x.txt', 'x\n')
    end,
    on_main = function(d)
      squash_x(d)
      h.git(d, 'revert', '--no-edit', 'HEAD')
    end,
  }))
  h.eq(false, has_note(st, 'squashed'), vim.inspect(st.notes))
  h.eq({ 'x.txt', 'z.txt' }, files)
end)

h.test('detect: the same line added at a different place in trunk is not a squash-merge', function()
  local files, st = bottom_files(bottom_case('st-sq-sameline', {
    base = { ['m.lua'] = LUA },
    x = function(d)
      commit(d, 'm.lua', (LUA:gsub('  return 2', '  -- TODO\n  return 2')))
    end,
    on_main = function(d)
      commit(d, 'm.lua', (LUA:gsub('  return 1', '  -- TODO\n  return 1')))
    end,
  }))
  h.eq(false, has_note(st, 'squashed'), vim.inspect(st.notes))
  h.eq({ 'm.lua', 'z.txt' }, files)
end)

h.test('detect: a whitespace-only difference from trunk is not a squash-merge', function()
  local files, st = bottom_files(bottom_case('st-sq-ws', {
    base = { ['f.lua'] = 'function f()\n  g()\nend\n' },
    x = function(d)
      commit(d, 'f.lua', 'function f()\n    g()\nend\n')
    end,
    on_main = function(d)
      commit(d, 'f.lua', 'function f()\n\tg()\nend\n')
    end,
  }))
  h.eq(false, has_note(st, 'squashed'), vim.inspect(st.notes))
  h.eq({ 'f.lua', 'z.txt' }, files)
end)

h.test('detect: each trunk squash-merge accounts for one run only', function()
  local files, st = bottom_files(bottom_case('st-sq-reuse', {
    base = { ['m.lua'] = LUA },
    x = function(d)
      commit(d, 'm.lua', (LUA:gsub('  return 1', '  -- TODO\n  return 1')))
    end,
    on_z = function(d)
      commit(d, 'm.lua', (LUA:gsub('  return 1', '  -- TODO\n  return 1'):gsub('  return 2', '  -- TODO\n  return 2')))
    end,
    on_main = squash_x,
  }))
  h.eq(1, (note_of(st.notes, 'squashed', 'z') or {}).count, vim.inspect(st.notes))
  h.eq({ 'm.lua', 'z.txt' }, files)
end)

h.test('detect: only the bottom layer skips squash-merged commits, never a stale layer above it', function()
  local d = h.tmpdir('st-sq-stale')
  h.git(d, 'init', '-q', '-b', 'main')
  commit(d, 'base.txt', 'base\n')
  h.git(d, 'checkout', '-q', '-b', 'x')
  commit(d, 'x.txt', 'x\n')
  h.git(d, 'checkout', '-q', '-b', 'b')
  commit(d, 'b.txt', 'b\n')
  h.git(d, 'checkout', '-q', 'main')
  squash_x(d)
  h.git(d, 'checkout', '-q', '-b', 'a')
  commit(d, 'a.txt', 'a\n')
  h.git(d, 'branch', '-q', '-D', 'x')
  h.git(d, 'config', 'branch.b.revueyParent', 'a')
  h.git(d, 'checkout', '-q', 'b')
  local st = detect(d)
  h.eq({ 'a', 'b' }, names(st))
  h.eq(true, st.layers[2].stale)
  h.eq(false, has_note(st, 'squashed'), vim.inspect(st.notes))
  h.eq(nil, st.base_rev)
end)

h.test('landed_runs: a multi-commit squash is one run', function()
  local d = h.tmpdir('st-sq-runs')
  h.git(d, 'init', '-q', '-b', 'main')
  commit(d, 'base.txt', 'base\n')
  h.git(d, 'checkout', '-q', '-b', 'x')
  commit(d, 'x.txt', 'x1\n')
  commit(d, 'x.txt', 'x2\n')
  h.git(d, 'checkout', '-q', '-b', 'y')
  commit(d, 'y.txt', 'y\n')
  commit(d, 'own.txt', 'own\n')
  h.git(d, 'checkout', '-q', 'main')
  h.git(d, 'merge', '-q', '--squash', 'x')
  h.git(d, 'commit', '-q', '-m', 'squash x')
  h.git(d, 'merge', '-q', '--squash', 'y~1')
  h.git(d, 'commit', '-q', '-m', 'squash y')
  local function rev(r)
    return vim.trim(h.git(d, 'rev-parse', r))
  end
  local runs = stack.landed_runs(d, rev('main'), rev('y'))
  h.eq({ { rev('x~1'), rev('x') }, { rev('y~1') } }, runs)
end)

h.test('detect: many duplicate tips are listed briefly', function()
  local d = stack_repo('st-dups')
  for i = 1, 40 do
    h.git(d, 'branch', 'dup/' .. i, 'feat/a')
  end
  local st = detect(d)
  local n = 0
  for _, x in ipairs(st.notes) do
    if x.kind == 'same_commit' then
      n = n + 1
      h.eq(st.layers[1].name, x.layer)
    end
  end
  h.eq(40, n)
  -- one short summary line for all of them
  local sum = require('revuey.stack_notes').summary(st.notes, st.ignored, { stack = true, trunk = 'main' })
  h.eq({ { glyph = '●', text = '40 other branches at ' .. st.layers[1].name, level = 'info' } }, sum)
end)

h.test('detect: old branches built on a pre-amend bottom layer are related, informational notes', function()
  local d = h.old_branches_repo('st-old-branches')
  local st = detect(d)
  h.eq({ 'stack/a', 'stack/b', 'stack/c' }, names(st))
  local olds = { 'dave/abc-1058-apply-price-check', 'dave/abc-1058-report-flow', 'dave/abc-1061-cleanup' }
  h.eq(3, #st.notes, vim.inspect(st.notes))
  for i, b in ipairs(olds) do
    h.eq({ 'outdated_copy', b, 'stack/a' }, { st.notes[i].kind, st.notes[i].branch, st.notes[i].layer })
    h.eq('info', require('revuey.stack_notes').level(st.notes[i]))
  end
  h.ok(st.notes[1].text:find("contains an older version of a commit that's now in your stack", 1, true), st.notes[1].text)
  h.eq({}, st.ignored)
  -- the layers are untouched by the notes
  h.eq({ nil, nil, nil }, { st.layers[1].diverged, st.layers[2].diverged, st.layers[3].diverged })
end)

h.test('detect: ignore patterns (config and persisted) hide related-branch notes, never layers', function()
  local ign = require('revuey.stack_ignore')
  local d = h.old_branches_repo('st-old-ignored')
  local config = require('revuey.config')
  config.set({ state_dir = state_dir, stack = { ignore_branches = { 'dave/abc-1058-*' } } })
  local cache = {}
  local st = stack.detect(d, 'main', cache)
  h.eq({ 'dave/abc-1061-cleanup' }, vim.tbl_map(function(n)
    return n.branch
  end, st.notes))
  h.eq(2, #st.ignored)
  h.eq('dave/abc-1058-*', st.ignored[1].pattern)
  -- the persisted list adds to the config, and changes the fingerprint (no stale cache)
  ign.update(state_dir, ign.repo_key(d), { add = { 'dave/abc-1061-cleanup' } })
  st = stack.detect(d, 'main', cache)
  h.eq({}, st.notes)
  h.eq(3, #st.ignored)
  -- ignoring a layer's name hides nothing about the layer and keeps it in the stack
  ign.update(state_dir, ign.repo_key(d), { add = { 'stack/*' } })
  st = stack.detect(d, 'main', cache)
  h.eq({ 'stack/a', 'stack/b', 'stack/c' }, names(st))
  config.set({ state_dir = state_dir })
  ign.update(state_dir, ign.repo_key(d), { remove = { 'dave/abc-1061-cleanup', 'stack/*' } })
  st = stack.detect(d, 'main', cache)
  h.eq(3, #st.notes)
end)

h.test('detect: a side branch off a layer below HEAD is told apart from one sharing commits', function()
  local d = stack_repo('st-side', 'feat/c')
  h.git(d, 'checkout', '-q', '-b', 'side', 'feat/a')
  commit(d, 'side.txt', 'side\n')
  h.git(d, 'checkout', '-q', 'feat/c')
  local st = detect(d)
  h.eq({ 'feat/a', 'feat/b', 'feat/c' }, names(st))
  local n = note_of(st.notes, 'side', 'side')
  h.eq('feat/a', n and n.layer, vim.inspect(st.notes))
  h.eq({}, require('revuey.stack_notes').actions(n)[1].id == 'parent' and { 'parent' } or {}, 'no set-as-parent for a side branch')
end)

h.test('raw_keys() (layer stats) agree with content keys of the parsed diff', function()
  local review = require('revuey.review')
  local state = require('revuey.state')
  local diff = require('revuey.diff')
  local git = require('revuey.git')
  local d = h.fixture()
  -- add a mode change and a file -> symlink type change on top of renames/deletes/binary
  vim.uv.fs_chmod(d .. '/src/index.ts', tonumber('755', 8))
  vim.fn.delete(d .. '/README.md')
  vim.uv.fs_symlink('src/index.ts', d .. '/README.md')
  h.git(d, 'add', '-A')
  h.git(d, 'commit', '-q', '-m', 'modes')
  local files = diff.parse(git.diff('main', 'HEAD', d, 3))
  local expected = {}
  for _, f in ipairs(files) do
    expected[f.path] = state.content_key(f)
  end
  h.eq(expected, review.raw_keys(d, 'main', 'HEAD'))
end)

h.run()
