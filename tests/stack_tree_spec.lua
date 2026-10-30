-- The stack tree from GitHub (stack_tree.lua), pure: the batched rounds against an in-memory
-- GitHub (answering the same aliases as tests/bin/fake_gh.lua), the tree with its
-- representatives, the default route and its tie-break, limits, cycles and broken chains, the
-- drawing, the fetch marks and specs, and the stack built for a path.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
local tree = require('revuey.stack_tree')

local REPO = { host = 'github.com', owner = 'acme', name = 'shop' }

---A PR node as GitHub returns it.
local function node(number, head, base, state, o)
  o = o or {}
  return {
    number = number, title = o.title or ('PR ' .. number), url = 'https://github.com/acme/shop/pull/' .. number,
    state = state or 'OPEN', isDraft = o.draft == true, updatedAt = o.updated or ('2026-01-01T00:%02d:00Z'):format(number % 60),
    headRefName = head, baseRefName = base, headRefOid = o.oid or ('%040d'):format(number),
    isCrossRepository = o.fork ~= nil, headRepositoryOwner = { login = o.fork or 'acme' },
    headRef = o.deleted and vim.NIL or { name = head }, reviewDecision = o.decision or vim.NIL,
  }
end

---Answer a round's aliases from `nodes` as GitHub would (newest first, `first`, nesting as deep
---as the query asks).
local function answer(nodes, query)
  local function newest(list)
    table.sort(list, function(a, b)
      if a.updatedAt ~= b.updatedAt then
        return a.updatedAt > b.updatedAt
      end
      return a.number > b.number
    end)
    return list
  end
  -- `pullRequests(headRefName:)` lists forks' PRs of that head name too; a Ref's
  -- `associatedPullRequests` only the repository's own
  local function heads(b, forks)
    local l = {}
    for _, n in ipairs(nodes) do
      if n.headRefName == b and (forks or not n.isCrossRepository) then
        l[#l + 1] = n
      end
    end
    return newest(l)
  end
  local function conn(list, first, fn)
    local out = {}
    for i = 1, math.min(#list, first) do
      out[i] = fn and fn(list[i]) or vim.deepcopy(list[i])
    end
    return { totalCount = #list, nodes = out }
  end
  local data = {}
  for line in query:gmatch('[^\n]+') do
    local alias, rest = line:match('^%s*(s[dk]%d+): repository%b() { (.*)$')
    if alias and alias:sub(2, 2) == 'd' then
      local b, first = rest:match('headRefName: (%b""), first: (%d+)')
      local _, depth = line:gsub('associatedPullRequests%(', '')
      local nfirst = tonumber(line:match('associatedPullRequests%(first: (%d+)') or '2')
      local function nest(level)
        return function(n)
          local out = vim.deepcopy(n)
          if level > 0 then
            out.baseRef = { name = n.baseRefName, associatedPullRequests = conn(heads(n.baseRefName), nfirst, nest(level - 1)) }
          end
          return out
        end
      end
      data[alias] = { pullRequests = conn(heads(vim.json.decode(b), true), tonumber(first), nest(depth)) }
      if rest:find('defaultBranchRef', 1, true) then
        data[alias].defaultBranchRef = { name = 'main' }
      end
    elseif alias then
      local b, first = rest:match('baseRefName: (%b""), first: (%d+)')
      b = vim.json.decode(b)
      local l = {}
      for _, n in ipairs(nodes) do
        if n.baseRefName == b then
          l[#l + 1] = n
        end
      end
      data[alias] = { pullRequests = conn(newest(l), tonumber(first)) }
    end
  end
  return data
end

---Fetch the whole tree for `start` (both phases). Returns the fetch state and per-call queries.
local function fetch(nodes, start, o)
  o = o or {}
  local st = tree.new(REPO, o.trunk or 'main', { start }, o.owner)
  local queries = {}
  local parts, aliases = tree.first_parts(st)
  local q = tree.query(parts)
  queries[1] = q
  tree.absorb(st, answer(nodes, q), aliases)
  for _, closed in ipairs({ false, true }) do
    while true do
      local want = tree.plan(st, closed)
      if not want then
        break
      end
      local p, a = tree.parts(st, want)
      q = tree.query(p)
      queries[#queries + 1] = q
      if o.fail_after and #queries > o.fail_after then
        tree.absorb(st, nil, a, 'gh exited 1')
      else
        tree.absorb(st, answer(nodes, q), a)
      end
    end
    if o.phase_a then
      break
    end
  end
  return st, queries
end

-- The fixture's shape (tests/helpers.lua tree_repo), as nodes.
local function small()
  return {
    node(10, 'stack/c', 'stack/a', 'CLOSED', { updated = '2026-01-02T00:00:00Z' }),
    node(11, 'stack/a', 'main', 'OPEN', { updated = '2026-01-05T00:00:00Z', decision = 'APPROVED' }),
    node(12, 'stack/b', 'stack/a', 'OPEN', { updated = '2026-01-05T01:00:00Z' }),
    node(13, 'stack/c', 'stack/b', 'OPEN', { updated = '2026-01-05T02:00:00Z' }),
    node(14, 'stack/x', 'stack/b', 'CLOSED', { updated = '2026-01-03T00:00:00Z' }),
    node(15, 'stack/d', 'stack/c', 'OPEN', { updated = '2026-01-05T03:00:00Z', draft = true }),
    node(16, 'stack/old1', 'stack/a', 'CLOSED', { updated = '2026-01-01T10:00:00Z' }),
    node(17, 'stack/old2', 'stack/old1', 'CLOSED', { updated = '2026-01-01T11:00:00Z', deleted = true }),
    node(19, 'fix-d', 'stack/b', 'OPEN', { updated = '2026-01-04T00:00:00Z', fork = 'bob' }),
  }
end

h.test('normalize: fields, a fork, a deleted head branch', function()
  local n = tree.normalize(node(7, 'x', 'main', 'OPEN', { fork = 'bob', deleted = true, decision = 'APPROVED', draft = true }))
  h.eq(7, n.number)
  h.eq(true, n.fork)
  h.eq('bob', n.head_owner)
  h.eq(false, n.head_exists)
  h.eq(true, n.draft)
  h.eq('APPROVED', n.review_decision)
  h.eq(nil, tree.normalize({ title = 'no number' }))
end)

h.test('query: a head lookup nests NEST base levels; children by base; the default branch once', function()
  local st = tree.new(REPO, 'main', { 'stack/d' })
  local parts, aliases = tree.parts(st, { down = { 'stack/d' }, kids = { 'stack/a', 'stack/b' } })
  h.eq({ 'sd1', 'sk1', 'sk2' }, vim.tbl_keys(aliases) and (function()
    local k = vim.tbl_keys(aliases)
    table.sort(k)
    return k
  end)())
  local q = tree.query(parts)
  local sd = q:match('[^\n]*sd1:[^\n]*')
  local _, n = sd:gsub('associatedPullRequests%(', '')
  -- GitHub caps a query's depth at 25: measured, 6 nested levels under a head lookup fit, 7 do not
  h.eq(tree.NEST, n)
  h.eq(6, tree.NEST)
  h.ok(sd:find('defaultBranchRef { name }', 1, true), 'the default branch is asked once')
  h.ok(q:find('sk1: repository(owner: "acme", name: "shop") { pullRequests(baseRefName: "stack/a", first: 30', 1, true))
  h.ok(q:find('fragment tnode on PullRequest', 1, true))
  h.ok(not q:find('fragment pr ', 1, true))
end)

h.test('fetch from the top: the chain in one call, children batched per level', function()
  local st, queries = fetch(small(), 'stack/d')
  local t = tree.tree(st)
  h.eq({ 11, 12, 13, 15 }, t.chain)
  h.eq(15, t.start)
  h.eq(nil, t.stop)
  h.eq(9, t.count)
  -- 1: the chain (rides on the PR lookup); then one call per level of children: the chain's
  -- (11, 12, 13, 15), then (phase two) the closed ones' (16, 14), then 17's
  h.eq(4, #queries)
  h.eq(1, select(2, queries[1]:gsub('sd%d+:', '')))
  h.eq(4, select(2, queries[2]:gsub('sk%d+:', '')))
  h.eq({ 13, 14, 19 }, t.kids[12])
  h.eq({ 10, 12, 16 }, t.kids[11])
  h.eq({ 17 }, t.kids[16])
  h.eq({}, t.kids[17])
end)

h.test('fetch from the middle: down by bases, up through every child', function()
  local st = fetch(small(), 'stack/b')
  local t = tree.tree(st)
  h.eq({ 11, 12 }, t.chain)
  h.eq(12, t.start)
  h.eq(9, t.count)
  h.eq({ 11, 12, 13, 15 }, (tree.route(t, 12)))
end)

h.test('a branch with several PRs: the open one is its representative, the old closed one a leaf on its old base', function()
  local st = fetch(small(), 'stack/b')
  h.eq(13, tree.rep(st, 'stack/c').number)
  local t = tree.tree(st)
  h.eq(11, t.parent[10], '#10 (stack/c, closed) on its old base stack/a')
  h.eq(12, t.parent[13])
  h.eq(nil, t.kids[10], 'not a representative: no children (stack/d is #13\'s)')
  h.eq({ 15 }, t.kids[13])
end)

h.test('phases: routes first (closed subtrees wait), then the closed subtrees', function()
  local st = fetch(small(), 'stack/b', { phase_a = true })
  h.eq(true, st.asked['stack/c'])
  h.eq(nil, st.asked['stack/old1'], 'closed #16 not expanded yet')
  h.eq(nil, st.asked['stack/x'])
  local t = tree.tree(st)
  h.eq(true, t.unexpanded[16])
  h.eq({ 11, 12, 13, 15 }, (tree.route(t, 12)), 'the route is complete after phase one')
  local want = tree.plan(st, true)
  table.sort(want.kids)
  h.eq({ 'stack/old1', 'stack/x' }, want.kids)
end)

h.test('a long chain from its top: seven PRs per call down, children in the same calls', function()
  local nodes = {}
  for i = 1, 20 do
    nodes[#nodes + 1] = node(100 + i, 'c/' .. i, i == 1 and 'main' or ('c/' .. (i - 1)), 'OPEN')
  end
  local st, queries = fetch(nodes, 'c/20')
  local t = tree.tree(st)
  h.eq(20, #t.chain)
  -- down: 20 PRs at 7 per call = 3 calls; children ride along, plus one call for the last level
  h.eq(4, #queries)
  h.eq(20, #(tree.route(t, 120)))
end)

h.test('limits: a cut after MAX_CALLS keeps what was read and says so', function()
  local nodes = { node(1, 'c/1', 'main', 'OPEN') }
  for i = 2, 12 do
    nodes[#nodes + 1] = node(i, 'c/' .. i, 'c/' .. (i - 1), 'OPEN')
  end
  local saved = tree.MAX_CALLS
  tree.MAX_CALLS = 4
  local st, queries = fetch(nodes, 'c/1')
  tree.MAX_CALLS = saved
  h.eq(4, #queries)
  h.ok(st.cut and st.cut:find('4 calls', 1, true), tostring(st.cut))
  local t = tree.tree(st)
  h.ok(t.cut ~= nil)
  h.eq({ 1, 2, 3, 4 }, (tree.route(t, 1)), 'the route goes as far as the tree was read')
  h.eq(true, t.unexpanded[4])
end)

h.test('limits: MAX_NODES stops the expansion', function()
  local nodes = { node(1, 'c/1', 'main', 'OPEN') }
  for i = 2, 30 do
    nodes[#nodes + 1] = node(i, 'k/' .. i, 'c/1', 'CLOSED')
  end
  for i = 31, 40 do
    nodes[#nodes + 1] = node(i, 'g/' .. i, 'k/2', 'CLOSED')
  end
  local saved = tree.MAX_NODES
  tree.MAX_NODES = 20
  local st = fetch(nodes, 'c/1')
  tree.MAX_NODES = saved
  h.ok(st.cut and st.cut:find('PRs', 1, true), tostring(st.cut))
end)

h.test('cycles and broken chains: bases that loop, a base without a PR, no PR at all', function()
  local st = fetch({ node(1, 'a', 'b', 'OPEN'), node(2, 'b', 'a', 'OPEN') }, 'a')
  local t = tree.tree(st)
  h.eq('cycle', t.stop)
  h.eq({ 2, 1 }, t.chain)
  st = fetch({ node(1, 'a', 'release', 'OPEN'), node(2, 'b', 'a', 'OPEN') }, 'b')
  t = tree.tree(st)
  h.eq('no_pr', t.stop)
  h.eq('release', t.bottom_base)
  h.eq({ 1, 2 }, t.chain)
  st = fetch({ node(1, 'a', 'main', 'OPEN') }, 'other')
  h.eq(nil, tree.tree(st), 'no PR for the branch: no tree')
  -- the repository's default branch stops the chain too (a trunk configured as `develop`)
  st = fetch({ node(1, 'a', 'main', 'OPEN'), node(2, 'main', 'prod', 'OPEN') }, 'a', { trunk = 'develop' })
  t = tree.tree(st)
  h.eq({ 1 }, t.chain)
  h.eq(nil, t.stop)
end)

h.test('a failed round: what was read stays, marked failed', function()
  local st = fetch(small(), 'stack/b', { fail_after = 1 })
  h.eq('gh exited 1', st.failed)
  local t = tree.tree(st)
  h.eq({ 11, 12 }, t.chain)
  h.eq('gh exited 1', t.cut)
end)

h.test('a fork\'s branch as HEAD: its PR in the base repo is the start, never expanded', function()
  local nodes = small()
  nodes[#nodes + 1] = node(20, 'stack/b', 'stack/a', 'OPEN', { fork = 'bob', updated = '2026-02-01T00:00:00Z' })
  local st = fetch(nodes, 'stack/b', { owner = 'bob' })
  local t = tree.tree(st)
  h.eq(20, t.start)
  h.eq({ 11, 20 }, t.chain)
  h.eq(nil, t.kids[20])
  st = fetch(nodes, 'stack/b')
  h.eq(12, tree.tree(st).start, 'the same branch name in the base repo is not the fork\'s')
end)

h.test('route: longest open continuation, ties to the lower PR number, closed start, drafts count', function()
  local nodes = {
    node(1, 'a', 'main', 'OPEN'),
    node(2, 'b', 'a', 'OPEN'), node(3, 'c', 'b', 'OPEN'), -- a → b → c (2 long)
    node(4, 'x', 'a', 'OPEN', { draft = true }), node(5, 'y', 'x', 'OPEN'), node(6, 'z', 'y', 'OPEN'), -- a → x → y → z (3 long)
    node(7, 'p', 'b', 'OPEN'), -- b → c or b → p: a tie
    node(8, 'q', 'z', 'CLOSED'), node(9, 'r', 'q', 'OPEN'), -- above a closed PR
  }
  local t = tree.tree((fetch(nodes, 'a')))
  h.eq({ 1, 4, 5, 6 }, (tree.route(t, 1)), 'the longest open continuation (a draft is open)')
  local path, idx = tree.route(t, 2)
  h.eq({ 1, 2, 3 }, path, 'a tie goes to the lower PR number')
  h.eq(2, idx)
  h.eq({ 1, 4, 5, 6 }, (tree.route(t, 5)))
  h.eq({ 1, 4, 5, 6, 8, 9 }, (tree.route(t, 8)), 'a closed PR chosen: its own path, open above it')
  local on = {}
  for _, n in ipairs({ 1, 2, 3 }) do
    on[n] = true
  end
  h.eq({ 1, 0 }, { tree.others(t, 2, on) })
  h.eq({ 1, 0 }, { tree.others(t, 1, on) })
end)

h.test('layout: Graphite-style rows, closed PRs hidden with a count, or shown', function()
  local t = tree.tree((fetch(small(), 'stack/b')))
  local path = tree.route(t, 12)
  local on = {}
  for _, n in ipairs(path) do
    on[n] = true
  end
  local function draw(show)
    local out = {}
    for _, r in ipairs(tree.layout(t, { show_closed = show, on_path = on, main = on })) do
      local g = tree.graph(r, r.trunk and 'o' or (on[r.node] and '@' or 'o'))
      out[#out + 1] = (g .. (r.node and ('#' .. r.node) or (r.trunk and 'main' or '')) .. (r.hidden and (' +' .. r.hidden) or '')):gsub('%s+$', '')
    end
    return out
  end
  h.eq({
    '@ #15',
    '@ #13',
    '│ o #19',
    '├─┘',
    '@ #12 +1',
    '@ #11 +3',
    'o main',
  }, draw(false))
  h.eq({
    '@ #15',
    '@ #13',
    '│ o #14',
    '│ │ o #19',
    '├─┴─┘',
    '@ #12',
    '│ o #10',
    '│ │ o #17',
    '│ │ o #16',
    '├─┴─┘',
    '@ #11',
    'o main',
  }, draw(true))
  local _, gs, ge = tree.graph({ node = 1, col = 1, pipes = { 0 } }, '◉')
  h.eq({ 4, 7 }, { gs, ge }, 'the glyph\'s byte range (after "│ ")')
end)

h.test('reach and fetch specs: missing, behind, a commit only, forks and deleted branches', function()
  local t = tree.tree((fetch(small(), 'stack/b')))
  local facts = {
    remote = 'origin', heads = {}, objects = { [('%040d'):format(10)] = true },
    -- origin/stack/c is #13's branch now (moved): #10 needs its own commit
    refs = { ['origin/stack/a'] = ('%040d'):format(11), ['origin/stack/c'] = 'old' },
  }
  h.eq({ ref = 'origin/stack/a', tip = ('%040d'):format(11), how = 'remote' }, tree.reach(t.nodes[11], facts))
  h.eq('behind', tree.reach(t.nodes[13], facts).mark)
  h.eq({ mark = 'missing', how = 'none' }, tree.reach(t.nodes[15], facts))
  h.eq({ tip = ('%040d'):format(10), how = 'commit' }, tree.reach(t.nodes[10], facts), 'an old closed PR: its commit is enough')
  h.eq('missing', tree.reach(t.nodes[19], facts).mark)
  h.eq('missing', tree.reach(t.nodes[17], facts).mark)
  local specs, which = tree.fetch_specs(t, { 11, 12, 13, 15, 17, 19 }, facts)
  h.eq({
    '+refs/heads/stack/b:refs/remotes/origin/stack/b',
    '+refs/heads/stack/c:refs/remotes/origin/stack/c',
    '+refs/heads/stack/d:refs/remotes/origin/stack/d',
    'refs/pull/17/head',
    'refs/pull/19/head',
  }, specs)
  h.eq({ 12, 13, 15, 17, 19 }, which)
  specs = tree.fetch_specs(t, { 10, 16 }, { remote = 'origin', heads = {}, objects = {}, refs = {} })
  h.eq({ 'refs/pull/10/head', 'refs/pull/16/head' }, specs, 'closed PRs: by their pull ref')
end)

h.test('stack: local branch first, then the remote ref, then the commit; missing PRs left out', function()
  local t = tree.tree((fetch(small(), 'stack/b')))
  local o = function(n)
    return ('%040d'):format(n)
  end
  local facts = {
    remote = 'origin', trunk = 'origin/main', trunk_rev = 'T', trunk_state = 'main',
    heads = { ['stack/b'] = o(12) }, refs = { ['origin/stack/a'] = o(11), ['origin/stack/c'] = 'stale' },
    objects = { [o(19)] = true }, current = 'stack/b', head = o(12),
  }
  local st = tree.stack(t, { 11, 12, 13, 15 }, nil, facts)
  h.eq('github', st.kind)
  h.eq({ 'origin/stack/a', 'stack/b', 'origin/stack/c' }, vim.tbl_map(function(l)
    return l.name
  end, st.layers))
  h.eq({ 15 }, st.missing)
  local a, b, c = st.layers[1], st.layers[2], st.layers[3]
  h.eq({ 'origin/main', 'T', 'stack/a', 'main', true }, { a.parent, a.parent_rev, a.state_branch, a.state_base, a.remote })
  h.eq({ 'origin/stack/a', o(11), 'stack/b', 'stack/a', true, nil }, { b.parent, b.parent_rev, b.state_branch, b.state_base, b.is_head, b.remote })
  h.eq({ 'stale', 'behind', 13 }, { c.tip, c.fetch, c.pr })
  h.eq(2, st.current, 'HEAD\'s layer')
  h.eq({ 2, 2 }, { a.others, a.others_closed })
  h.eq({ 2, 1 }, { b.others, b.others_closed })
  -- the fork's PR chosen: its commit is here, read-only, viewed
  st = tree.stack(t, { 11, 12, 19 }, 19, facts)
  local f = st.layers[3]
  h.eq({ 'bob:fix-d', o(19), true, true, true }, { f.name, f.tip, f.remote, f.unfetched, f.fork_pr })
  h.eq(3, st.current)
end)

h.test('stack: a base without a PR is the bottom layer\'s parent', function()
  local st0 = fetch({ node(1, 'a', 'release', 'OPEN'), node(2, 'b', 'a', 'OPEN') }, 'b')
  local t = tree.tree(st0)
  local st = tree.stack(t, { 1, 2 }, nil, {
    remote = 'origin', trunk = 'origin/main', trunk_rev = 'T', heads = { b = 'B' },
    refs = { ['origin/a'] = 'A', ['origin/release'] = 'R' }, objects = {}, current = 'b', head = 'B',
  })
  h.eq({ 'origin/release', 'R' }, { st.layers[1].parent, st.layers[1].parent_rev })
end)

h.run()
