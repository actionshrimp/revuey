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

---Draw a layout as plain lines: `@` on PRs of `on`, `o` elsewhere, `*` the trunk.
local function draw(t, o)
  local out = {}
  for _, r in ipairs(tree.layout(t, o)) do
    local g = tree.graph(r, r.kind == 'trunk' and '*' or ((o.on_path or {})[r.node] and '@' or 'o'))
    local label = (r.kind == 'node' and ('#' .. r.node)) or (r.kind == 'trunk' and 'main') or ''
    out[#out + 1] = (g .. label .. (r.hidden and (' +' .. r.hidden) or '')):gsub('%s+$', '')
  end
  return out
end

local function set(list)
  local out = {}
  for _, n in ipairs(list) do
    out[n] = true
  end
  return out
end

---A tree straight from base links: { [child] = parent ('root' at the bottom) }, states.
local function shape(parents, states)
  local t = { nodes = {}, kids = { root = {} }, parent = {}, rep = {}, more = {}, unexpanded = {} }
  for c, p in pairs(parents) do
    t.nodes[c] = { number = c, state = (states or {})[c] or 'OPEN', head = 'b' .. c, title = '' }
    t.parent[c] = p
    t.kids[p] = t.kids[p] or {}
    table.insert(t.kids[p], c)
    t.kids[c] = t.kids[c] or {}
  end
  for _, l in pairs(t.kids) do
    table.sort(l)
  end
  return t
end

h.test('layout: git log --graph rows; side branches join just above their fork; closed hidden or shown', function()
  local t = tree.tree((fetch(small(), 'stack/b')))
  local on = set((tree.route(t, 12)))
  h.eq({
    '@ #15',
    '@ #13',
    '│ o #19',
    '├─╯',
    '@ #12 +1',
    '@ #11 +3',
    '* main',
  }, draw(t, { on_path = on, main = on }))
  h.eq({
    '@ #15',
    '@ #13',
    '│ o #19', -- open sides first (the longer open run), then by number
    '├─╯',
    '│ o #14', -- the column is free again: reused
    '├─╯',
    '@ #12',
    '│ o #10',
    '├─╯',
    '│ o #17', -- a 2-PR closed chain in its own column, two rows
    '│ o #16',
    '├─╯',
    '@ #11',
    '* main',
  }, draw(t, { show_closed = true, on_path = on, main = on }))
end)

h.test('layout: the reviewed path stays in column 0; nested forks go further right; forks at many heights', function()
  -- 1 ← 2 ← 3 ← 4 (the path); 2 ← 5 ← 6, 6 ← 7 (a fork off a side branch); 3 ← 8; 1 ← 9
  local t = shape({ [1] = 'root', [2] = 1, [3] = 2, [4] = 3, [5] = 2, [6] = 5, [7] = 6, [8] = 3, [9] = 1, [10] = 6 })
  local on = set({ 1, 2, 3, 4 })
  h.eq({
    '@ #4',
    '│ o #8', -- #3's side branch, right above #3 and below its main child
    '├─╯',
    '@ #3',
    '│ o #7', -- #6's main child (the lower number at an equal run)
    '│ │ o #10', -- #6's side branch, a column further right
    '│ ├─╯',
    '│ o #6',
    '│ o #5',
    '├─╯',
    '@ #2',
    '│ o #9',
    '├─╯',
    '@ #1',
    '* main',
  }, draw(t, { on_path = on, main = on }))
  -- another path chosen: it takes column 0, the old one moves right
  local on2 = set({ 1, 2, 5, 6, 10 })
  h.eq({
    '@ #10',
    '│ o #7',
    '├─╯',
    '@ #6',
    '@ #5',
    '│ o #4',
    '│ │ o #8',
    '│ ├─╯',
    '│ o #3',
    '├─╯',
    '@ #2',
    '│ o #9',
    '├─╯',
    '@ #1',
    '* main',
  }, draw(t, { on_path = on2, main = on2 }))
  h.eq(3, tree.width(tree.layout(t, { on_path = on, main = on })))
end)

h.test('layout: several forks off one PR reuse one column; a long side chain keeps its column', function()
  local parents = { [1] = 'root', [2] = 1 }
  for i = 3, 5 do
    parents[i] = 1 -- three more children of #1
  end
  local prev = 4
  for i = 20, 23 do
    parents[i] = prev -- a 4-PR closed chain on #4
    prev = i
  end
  local states = {}
  for i = 20, 23 do
    states[i] = 'CLOSED'
  end
  local t = shape(parents, states)
  local on = set({ 1, 2 })
  local rows = draw(t, { on_path = on, main = on, show_closed = true })
  h.eq({
    '@ #2',
    '│ o #3',
    '├─╯',
    '│ o #23',
    '│ o #22',
    '│ o #21',
    '│ o #20',
    '│ o #4',
    '├─╯',
    '│ o #5',
    '├─╯',
    '@ #1',
    '* main',
  }, rows)
  h.eq(2, tree.width(tree.layout(t, { on_path = on, main = on, show_closed = true })), 'two columns for all of it')
  h.eq({ '@ #2', '│ o #3', '├─╯', '│ o #4 +4', '├─╯', '│ o #5', '├─╯', '@ #1', '* main' }, draw(t, { on_path = on, main = on }))
end)

h.test('layout: segments name their node or edges, for colouring a path whole', function()
  local t = tree.tree((fetch(small(), 'stack/b')))
  local on = set((tree.route(t, 12)))
  local rows = tree.layout(t, { on_path = on, main = on })
  -- the side row: the main line beside it is edge #13 → #12, the node #19
  local g, segs = tree.graph(rows[3], 'o')
  h.eq('│ o ', g)
  h.eq({ { 0, 3, edges = { 13 } }, { 4, 5, node = 19 } }, segs)
  -- the join: `├` carries both edges into #12, `─` and `╯` the side's
  g, segs = tree.graph(rows[4], '')
  h.eq('├─╯ ', g)
  h.eq({ { 0, 3, edges = { 13, 19 } }, { 3, 6, edges = { 19 } }, { 6, 9, edges = { 19 } } }, segs)
end)

h.test('navigation: j to the base, k up the column, h/l across; every PR reachable', function()
  local t = tree.tree((fetch(small(), 'stack/b')))
  local on = set((tree.route(t, 12)))
  local rows = tree.layout(t, { show_closed = true, on_path = on, main = on })
  local nav = function(n, k)
    return tree.nav(t, rows, n, k)
  end
  h.eq(12, nav(13, 'j'))
  h.eq(15, nav(13, 'k'))
  h.eq(19, nav(13, 'l'), 'across to the sibling branch beside it')
  h.eq(13, nav(19, 'h'), 'and back')
  h.eq(12, nav(19, 'j'), 'a side branch\'s base: the fork point')
  h.eq(14, nav(12, 'l'), 'the nearest PR in the next column')
  h.eq(19, nav(14, 'k'), 'up a reused column to the branch above')
  h.eq(17, nav(16, 'k'))
  h.eq(16, nav(17, 'j'))
  h.eq(11, nav(16, 'j'))
  h.eq(15, nav(15, 'k'), 'nowhere to go: stays')
  h.eq(11, nav(11, 'j'), 'the trunk is not a PR')
  -- every PR from any PR, on this tree and on random ones
  local function reach_all(tt, rr)
    local nums = {}
    for _, r in ipairs(rr) do
      if r.kind == 'node' then
        nums[#nums + 1] = r.node
      end
    end
    for _, from in ipairs(nums) do
      local seen, queue = { [from] = true }, { from }
      while #queue > 0 do
        local n = table.remove(queue)
        for _, k in ipairs({ 'h', 'j', 'k', 'l' }) do
          local m = tree.nav(tt, rr, n, k)
          if not seen[m] then
            seen[m] = true
            queue[#queue + 1] = m
          end
        end
      end
      for _, n in ipairs(nums) do
        if not seen[n] then
          return ('#%d unreachable from #%d'):format(n, from)
        end
      end
    end
  end
  h.eq(nil, reach_all(t, rows))
  math.randomseed(23)
  for _ = 1, 200 do
    local parents = { [1] = 'root' }
    local n = math.random(2, 25)
    for i = 2, n do
      parents[i] = math.random(1, i - 1)
    end
    local tt = shape(parents)
    local path = { 1 }
    while #tt.kids[path[#path]] > 0 do
      path[#path + 1] = tt.kids[path[#path]][math.random(#tt.kids[path[#path]])]
    end
    local s2 = set(path)
    local why = reach_all(tt, tree.layout(tt, { on_path = s2, main = s2 }))
    h.eq(nil, why, vim.inspect(parents))
  end
end)

h.test('layout: below an earlier side branch\'s join the line carries that branch too', function()
  local t = tree.tree((fetch(small(), 'stack/b')))
  local on = set((tree.route(t, 12)))
  local rows = tree.layout(t, { show_closed = true, on_path = on, main = on })
  -- rows: #15, #13, #19, join, #14, join, #12: beside #14 the line runs #13 and #19 down to #12
  local _, segs = tree.graph(rows[5], 'o')
  h.eq({ 0, 3, edges = { 13, 19 } }, segs[1])
  _, segs = tree.graph(rows[6], '')
  h.eq({ 0, 3, edges = { 13, 19, 14 } }, segs[1], '`├` of the second join: all three')
end)

h.test('navigation: l goes into the PR\'s own branches only; h and l undo each other at a fork', function()
  -- 1 ← 2 ← 3 ← 4 ← 5 (the path); 6 off 2; 7 off 4
  local t = shape({ [1] = 'root', [2] = 1, [3] = 2, [4] = 3, [5] = 4, [6] = 2, [7] = 4 })
  local on = set({ 1, 2, 3, 4, 5 })
  local rows = tree.layout(t, { on_path = on, main = on })
  h.eq({ '@ #5', '│ o #7', '├─╯', '@ #4', '@ #3', '│ o #6', '├─╯', '@ #2', '@ #1', '* main' }, draw(t, { on_path = on, main = on }))
  h.eq(6, tree.nav(t, rows, 3, 'l'), 'the branch beside #3 (it is #2\'s, not #3\'s own: #3 has none)')
  h.eq(3, tree.nav(t, rows, 6, 'h'))
  h.eq(6, tree.nav(t, rows, 2, 'l'), '#2\'s own branch')
  h.eq(7, tree.nav(t, rows, 4, 'l'), '#4\'s own branch')
  h.eq(7, tree.nav(t, rows, 5, 'l'))
  h.eq(5, tree.nav(t, rows, 7, 'h'))
  -- h∘l is the identity from the PRs right beside a side branch
  for _, from in ipairs({ 3, 5 }) do
    h.eq(from, tree.nav(t, rows, tree.nav(t, rows, from, 'l'), 'h'))
  end
end)

h.test('footer path: shortened in the middle when long', function()
  h.eq('main › #1 › #2', tree.path_text('main', { 1, 2 }, 80))
  local long = {}
  for i = 1, 17 do
    long[i] = 200 + i
  end
  local text = tree.path_text('develop', long, 60)
  h.ok(vim.fn.strdisplaywidth(text) <= 60, text)
  h.ok(text:find('^develop › #201 › … %d+ more … › ') and text:find('#217$'), text)
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

h.test('stack: a local branch is the layer only when it is that PR\'s', function()
  local t = tree.tree((fetch(small(), 'stack/b')))
  local o = function(n)
    return ('%040d'):format(n)
  end
  local base = {
    remote = 'origin', trunk = 'origin/main', trunk_rev = 'T', trunk_state = 'main',
    refs = { ['origin/stack/a'] = o(11), ['origin/stack/c'] = o(13) }, objects = { [o(10)] = true },
    current = 'stack/b', head = o(12),
  }
  local function facts(extra)
    return vim.tbl_extend('force', base, extra)
  end
  -- an old closed PR of a moved branch: the local branch is the newer PR's, not this one's
  local st = tree.stack(t, { 11, 10 }, 10, facts({ heads = { ['stack/b'] = o(12), ['stack/c'] = o(13) } }))
  local l = st.layers[2]
  h.eq({ 'origin/stack/c', o(10), true }, { l.name, l.tip, l.unfetched }, 'its own commit, not the local stack/c')
  h.eq(nil, l.local_differs)
  -- the open PR's local branch behind GitHub (not checked out): GitHub's side, noted
  st = tree.stack(t, { 11, 12 }, nil, facts({ heads = { ['stack/a'] = 'main', ['stack/b'] = o(12) } }))
  l = st.layers[1]
  h.eq({ 'origin/stack/a', o(11), 'other', 'local' }, { l.name, l.tip, l.local_differs, l.fetch })
  -- ... containing the PR's head (your commits on top): yours
  st = tree.stack(t, { 11, 12 }, nil, facts({ heads = { ['stack/a'] = 'ahead', ['stack/b'] = o(12) }, contains = { ['stack/a'] = true } }))
  h.eq({ 'stack/a', 'ahead', nil }, { st.layers[1].name, st.layers[1].tip, st.layers[1].local_differs })
  -- ... checked out: its working tree is the layer's, noted when it is not the PR's
  st = tree.stack(t, { 11, 12 }, nil, facts({ heads = { ['stack/b'] = 'old-b' }, head = 'old-b' }))
  l = st.layers[2]
  h.eq({ 'stack/b', 'old-b', true, 'head' }, { l.name, l.tip, l.is_head, l.local_differs })
  -- the closed PR at its own head: the local branch is fine
  st = tree.stack(t, { 11, 10 }, 10, facts({ heads = { ['stack/c'] = o(10) } }))
  h.eq({ 'stack/c', o(10) }, { st.layers[2].name, st.layers[2].tip })
end)

h.test('stack: the bottom base whenever it is not the trunk; a base not fetched is said', function()
  -- the repository's default branch (main) is not the configured trunk (develop)
  local st0 = fetch({ node(1, 'a', 'main', 'OPEN'), node(2, 'b', 'a', 'OPEN') }, 'b', { trunk = 'develop' })
  local t = tree.tree(st0)
  h.eq('main', t.bottom_base)
  local f = {
    remote = 'origin', trunk = 'origin/develop', trunk_rev = 'D', heads = { b = 'B' },
    refs = { ['origin/a'] = 'A', ['origin/main'] = 'M' }, objects = {}, current = 'b', head = 'B',
  }
  local st = tree.stack(t, { 1, 2 }, nil, f)
  h.eq({ 'origin/main', 'M', nil }, { st.layers[1].parent, st.layers[1].parent_rev, st.base_missing })
  f.refs['origin/main'] = nil
  st = tree.stack(t, { 1, 2 }, nil, f)
  h.eq({ 'origin/develop', 'D', 'origin/main' }, { st.layers[1].parent, st.layers[1].parent_rev, st.base_missing })
  -- the bottom PR missing here: the layer above it still starts from the bottom base
  f.refs['origin/main'], f.refs['origin/a'] = 'M', nil
  st = tree.stack(t, { 1, 2 }, nil, f)
  h.eq({ 1 }, st.missing)
  h.eq({ 'b', 'origin/main', 'M' }, { st.layers[1].name, st.layers[1].parent, st.layers[1].parent_rev })
end)

h.test('phase one keeps a chosen PR\'s path whole, under a closed PR and above it', function()
  local nodes = small()
  nodes[#nodes + 1] = node(18, 'stack/revive', 'stack/old2', 'OPEN')
  local st = tree.new(REPO, 'main', { 'stack/b' })
  st.pin = { [11] = true, [16] = true, [17] = true } -- #17 chosen (under closed #16)
  local parts, aliases = tree.first_parts(st)
  tree.absorb(st, answer(nodes, tree.query(parts)), aliases)
  while true do
    local want = tree.plan(st, false)
    if not want then
      break
    end
    local p, a = tree.parts(st, want)
    tree.absorb(st, answer(nodes, tree.query(p)), a)
  end
  local t = tree.tree(st)
  h.ok(t.nodes[17], 'the chosen PR is in the tree after phase one')
  h.eq({ 11, 16, 17, 18 }, (tree.route(t, 17)), 'and the open PR above it')
  h.eq(nil, st.asked['stack/x'], 'other closed PRs still wait')
end)

h.test('limits: MAX_NODES caps the tree within a round', function()
  local nodes = { node(1, 'c/1', 'main', 'OPEN') }
  for i = 2, 40 do
    nodes[#nodes + 1] = node(i, 'k/' .. i, 'c/1', 'OPEN')
  end
  local saved = tree.MAX_NODES
  tree.MAX_NODES = 10
  local st = fetch(nodes, 'c/1')
  local t = tree.tree(st)
  tree.MAX_NODES = saved
  h.eq(10, t.count)
  h.ok(t.cut and t.cut:find('10 PRs', 1, true), tostring(t.cut))
end)

h.test('refspecs: names git would not take as a branch go by the pull ref', function()
  h.eq(true, tree.safe_ref('stack/a'))
  for _, bad in ipairs({ '', '-x', '--upload-pack=x', 'a..b', 'a b', 'a:b', 'a^b', 'a~1', 'x.lock', 'a/', '/a', 'a//b', '@', 'a@{1}', '.a', 'a/.b', 'a\\b' }) do
    h.eq(false, tree.safe_ref(bad), bad)
  end
  local t = tree.tree((fetch({ node(1, '-oops', 'main', 'OPEN') }, '-oops')))
  h.eq({ 'refs/pull/1/head' }, (tree.fetch_specs(t, { 1 }, { remote = 'origin', heads = {}, refs = {}, objects = {} })))
end)

h.test('fetch environment: no prompt from git or ssh, unless ssh is yours', function()
  local tv = require('revuey.stack_tree_view')
  h.eq({ GIT_TERMINAL_PROMPT = '0', GIT_SSH_COMMAND = 'ssh -o BatchMode=yes' }, tv.fetch_env(nil, ''))
  h.eq({ GIT_TERMINAL_PROMPT = '0' }, tv.fetch_env('my-ssh', ''))
  h.eq({ GIT_TERMINAL_PROMPT = '0' }, tv.fetch_env('', 'ssh -i key'))
  h.eq({ GIT_TERMINAL_PROMPT = '0' }, tv.fetch_env(nil, '', '/usr/bin/my-ssh'), 'GIT_SSH is yours too')
  h.eq({ 'git', 'fetch', '--no-tags', '--no-write-fetch-head', '--no-recurse-submodules', 'origin', 'refs/pull/1/head' },
    tv.fetch_cmd('origin', { 'refs/pull/1/head' }))
  -- per-ref retries only for errors about refs
  h.eq(true, tv.ref_error(128, "fatal: couldn't find remote ref refs/heads/stack/d"))
  h.eq(false, tv.ref_error(128, 'fatal: Could not read from remote repository.'))
  h.eq(false, tv.ref_error(124, "couldn't find remote ref"), 'a timeout never')
end)

h.test('stack: HEAD\'s branch is its PR\'s layer whatever the PR\'s state; restacked lower copies; stale refs', function()
  local nodes = small()
  nodes[3] = node(12, 'stack/b', 'stack/a', 'CLOSED', { updated = '2026-01-05T01:00:00Z' })
  local t = tree.tree((fetch(nodes, 'stack/b')))
  local o = function(n)
    return ('%040d'):format(n)
  end
  local f = {
    remote = 'origin', trunk = 'origin/main', trunk_rev = 'T', trunk_state = 'main',
    refs = { ['origin/stack/a'] = o(11), ['origin/stack/b'] = o(12), ['origin/stack/c'] = o(13) }, objects = {},
    heads = { ['stack/b'] = 'work' }, contains = { ['stack/b'] = true }, current = 'stack/b', head = 'work',
  }
  local st = tree.stack(t, tree.route(t, 12), nil, f)
  h.eq({ 'origin/stack/a', 'stack/b', 'origin/stack/c' }, vim.tbl_map(function(l)
    return l.name
  end, st.layers))
  h.eq({ true, nil }, { st.layers[2].is_head, st.layers[2].local_differs }, 'a closed PR, your work on top: HEAD\'s layer')
  -- HEAD's branch under another name than its PR's head (pushed as stack/b): still its layer
  local fb = vim.tbl_extend('force', f, { heads = { ['my-b'] = 'work' }, contains = { ['my-b'] = true }, current = 'my-b', head_num = 12 })
  st = tree.stack(t, tree.route(t, 12), nil, fb)
  h.eq({ 'my-b', true }, { st.layers[2].name, st.layers[2].is_head })
  -- a lower branch restacked locally (HEAD built on it, not merely behind the PR): your copy
  f.heads['stack/a'], f.in_head = 'a2', { ['stack/a'] = true }
  st = tree.stack(t, tree.route(t, 12), nil, f)
  h.eq({ 'stack/a', 'a2', 'restacked' }, { st.layers[1].name, st.layers[1].tip, st.layers[1].local_differs })
  h.eq('a2', st.layers[2].parent_rev)
  -- a stale origin ref while the PR's exact head is here: the head
  local r = tree.reach(t.nodes[13], { remote = 'origin', refs = { ['origin/stack/c'] = 'old' }, objects = { [o(13)] = true } })
  h.eq({ o(13), 'behind', 'commit' }, { r.tip, r.mark, r.how })
  -- the bottom base: GitHub's copy, a local one only when HEAD is built on it
  local t2 = tree.tree((fetch({ node(1, 'a', 'release', 'OPEN'), node(2, 'b', 'a', 'OPEN') }, 'b')))
  local g = {
    remote = 'origin', trunk = 'origin/main', trunk_rev = 'T', heads = { b = 'B', release = 'stale' },
    refs = { ['origin/a'] = 'A', ['origin/release'] = 'R' }, objects = {}, current = 'b', head = 'B',
  }
  h.eq('origin/release', tree.stack(t2, { 1, 2 }, nil, g).layers[1].parent)
  g.in_head = { release = true }
  h.eq('release', tree.stack(t2, { 1, 2 }, nil, g).layers[1].parent)
end)

h.run()
