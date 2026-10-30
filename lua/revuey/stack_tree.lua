-- The stack tree from GitHub (pure: no git, no UI). Stacked PRs can branch: a branch with two
-- child PRs (one continuing the stack, one abandoned), a closed chain hanging off the middle, a
-- branch moved to a new base with its old PR closed. Parents come from PR base branches (declared
-- on GitHub, unambiguous), never from git ancestry.
--
--   * Fetching (`new`, `parts`, `absorb`, `plan`): rounds of batched, aliased GraphQL. A round
--     asks, in one call, for the base chain below the lowest PR known (`sdN`: the PRs of a head
--     branch, each with its base's PRs nested `NEST` levels deep through `baseRef {
--     associatedPullRequests }`, so seven PRs of the chain per call) and for the children of every
--     PR not yet expanded (`skN`: `pullRequests(baseRefName:)`). The first round rides on the PR
--     lookup's call (forge.fetch `extra`), so a branch without stacked PRs costs no extra call.
--   * The tree (`tree`): the chain from the trunk to HEAD's PR, plus every PR based on a branch
--     of the tree. One PR per head branch is its representative (`rep`: the newest OPEN, else the
--     newest) and only representatives have children; other PRs of a branch (closed, on an old
--     base) are leaves on their own base.
--   * The default route (`route`): the chain down to the trunk, then up through the longest run
--     of OPEN children, ties to the lower PR number.
--   * Drawing (`rows`) for the tree view, and the stack (`stack`) for a chosen path.
local M = {}

M.NEST = 6 -- base levels nested under a head lookup (GitHub caps a query's depth at 25)
M.NEST_FIRST = 2 -- PRs per branch in nested levels (more: a flat lookup of that branch)
M.HEAD_FIRST = 5 -- PRs per head branch in a flat lookup
M.CHILDREN_FIRST = 30 -- PRs based on one branch
M.MAX_CALLS = 25 -- gh calls per tree fetch, the first (shared with the PR lookup) included
M.MAX_ALIASES = 40 -- branch lookups per call
M.MAX_NODES = 300 -- PRs in a tree

local ORDER = 'orderBy: {field: UPDATED_AT, direction: DESC}'
M.FRAGMENT = [[
fragment tnode on PullRequest {
  number title url state isDraft updatedAt headRefName baseRefName headRefOid isCrossRepository
  headRepositoryOwner { login } headRef { name } reviewDecision
}]]

---@class revuey.TreeNode
---@field number integer
---@field title string
---@field url string
---@field state 'OPEN'|'MERGED'|'CLOSED'
---@field draft boolean
---@field updated_at string
---@field head string         head branch name
---@field base string         base branch name
---@field head_oid? string
---@field fork boolean        the head lives in another repository (a fork)
---@field head_owner? string
---@field head_exists boolean the head branch still exists on GitHub
---@field review_decision? string

local function lit(s)
  return vim.json.encode(s)
end

local function str(v)
  return type(v) == 'string' and v or nil
end

---@return revuey.TreeNode?
function M.normalize(n)
  if type(n) ~= 'table' or type(n.number) ~= 'number' then
    return nil
  end
  return {
    number = n.number,
    title = str(n.title) or '',
    url = str(n.url) or '',
    state = str(n.state) or 'OPEN',
    draft = n.isDraft == true,
    updated_at = str(n.updatedAt) or '',
    head = str(n.headRefName) or '',
    base = str(n.baseRefName) or '',
    head_oid = str(n.headRefOid),
    fork = n.isCrossRepository == true,
    head_owner = type(n.headRepositoryOwner) == 'table' and str(n.headRepositoryOwner.login) or nil,
    head_exists = type(n.headRef) == 'table',
    review_decision = str(n.reviewDecision),
  }
end

-- ---------------------------------------------------------------------------
-- Fetch state and rounds
-- ---------------------------------------------------------------------------

---@class revuey.TreeFetch
---@field repo {owner:string, name:string, host:string}
---@field trunk string                 trunk branch name on GitHub (`develop`)
---@field start string[]               head branch names to start from (forge candidates)
---@field start_owner? string          head owner of the start branch (a fork's owner)
---@field nodes table<integer, revuey.TreeNode>
---@field by_head table<string, integer[]> head branch -> PR numbers (same-repo heads only)
---@field listed table<string, boolean> head branch looked up: true = every PR of it is known
---@field flat table<string, true>     head branches asked with a flat lookup
---@field kids table<string, integer[]> base branch -> PR numbers (children asked)
---@field kids_total table<string, integer> base branch -> PRs GitHub has
---@field asked table<string, true>    branches whose children were asked
---@field calls integer
---@field failed? string               a round failed: the tree is cut there
---@field cut? string                  a limit was reached
---@field default_branch? string

---@return revuey.TreeFetch
function M.new(repo, trunk, start, start_owner)
  return {
    repo = repo, trunk = trunk, start = start, start_owner = start_owner,
    nodes = {}, by_head = {}, listed = {}, flat = {}, kids = {}, kids_total = {}, asked = {},
    calls = 0,
  }
end

local function nested(levels)
  local inner = '...tnode'
  for _ = 1, levels do
    inner = ('...tnode baseRef { name associatedPullRequests(first: %d, %s) { totalCount nodes { %s } } }')
      :format(M.NEST_FIRST, ORDER, inner)
  end
  return inner
end

---Alias text for this round (to go into a `query { }` with M.FRAGMENT) and alias -> what it
---asks. Empty when nothing is left to ask.
---@param want {down:string[], kids:string[]}
---@return string[] parts, table<string, {kind:'down'|'kids', branch:string}> aliases
function M.parts(st, want)
  local parts, aliases = {}, {}
  local repo = ('repository(owner: %s, name: %s)'):format(lit(st.repo.owner), lit(st.repo.name))
  for i, b in ipairs(want.down) do
    local alias = 'sd' .. i
    aliases[alias] = { kind = 'down', branch = b }
    -- the default branch once (a chain never goes below it)
    local extra = (i == 1 and not st.default_branch) and 'defaultBranchRef { name } ' or ''
    parts[#parts + 1] = ('  %s: %s { %spullRequests(headRefName: %s, first: %d, %s) { totalCount nodes { %s } } }')
      :format(alias, repo, extra, lit(b), M.HEAD_FIRST, ORDER, nested(M.NEST))
  end
  for i, b in ipairs(want.kids) do
    local alias = 'sk' .. i
    aliases[alias] = { kind = 'kids', branch = b }
    parts[#parts + 1] = ('  %s: %s { pullRequests(baseRefName: %s, first: %d, %s) { totalCount nodes { ...tnode } } }')
      :format(alias, repo, lit(b), M.CHILDREN_FIRST, ORDER)
  end
  return parts, aliases
end

---A whole round's query.
function M.query(parts)
  return 'query {\n' .. table.concat(parts, '\n') .. '\n}\n' .. M.FRAGMENT
end

local function add_node(st, raw)
  local n = M.normalize(raw)
  if not n then
    return nil
  end
  if not st.nodes[n.number] then
    st.nodes[n.number] = n
    if not n.fork then
      st.by_head[n.head] = st.by_head[n.head] or {}
      table.insert(st.by_head[n.head], n.number)
    end
  else
    st.nodes[n.number] = vim.tbl_extend('force', st.nodes[n.number], n)
  end
  return n
end

local function conn_nodes(conn)
  return type(conn) == 'table' and type(conn.nodes) == 'table' and conn.nodes or {}
end

---Record a head branch's PR list: complete when GitHub has no more than were returned.
local function listed(st, branch, conn)
  local list = conn_nodes(conn)
  local total = type(conn) == 'table' and tonumber(conn.totalCount) or #list
  local complete = total <= #list
  if st.listed[branch] ~= true then
    st.listed[branch] = complete
  end
end

---Take one round's answer in. `data` may be partial; a missing alias marks the fetch failed.
function M.absorb(st, data, aliases, err)
  st.calls = st.calls + 1
  if not data then
    st.failed = err or 'failed'
    return
  end
  local function walk(raw)
    local n = add_node(st, raw)
    local br = type(raw) == 'table' and raw.baseRef
    if n and type(br) == 'table' and type(br.associatedPullRequests) == 'table' then
      local name = str(br.name) or n.base
      listed(st, name, br.associatedPullRequests)
      for _, c in ipairs(conn_nodes(br.associatedPullRequests)) do
        walk(c)
      end
    end
  end
  for alias, a in pairs(aliases) do
    local repo = data[alias]
    if type(repo) ~= 'table' then
      st.failed = st.failed or ('no answer for ' .. a.branch)
    else
      if type(repo.defaultBranchRef) == 'table' then
        st.default_branch = str(repo.defaultBranchRef.name)
      end
      local conn = repo.pullRequests
      if a.kind == 'down' then
        st.flat[a.branch] = true
        listed(st, a.branch, conn)
        st.listed[a.branch] = st.listed[a.branch] or (type(conn) == 'table')
        for _, raw in ipairs(conn_nodes(conn)) do
          walk(raw)
        end
      else
        st.asked[a.branch] = true
        st.kids[a.branch] = {}
        st.kids_total[a.branch] = type(conn) == 'table' and tonumber(conn.totalCount) or 0
        for _, raw in ipairs(conn_nodes(conn)) do
          local n = add_node(st, raw)
          if n then
            table.insert(st.kids[a.branch], n.number)
          end
        end
      end
    end
  end
end

local function newer(a, b)
  if a.updated_at ~= b.updated_at then
    return a.updated_at > b.updated_at
  end
  return a.number > b.number
end

---The representative PR of a head branch: the newest OPEN one, else the newest (by updatedAt,
---then number). Same-repository heads only, or `owner`'s when given (a fork's start branch).
---@return revuey.TreeNode?
function M.rep(st, branch, owner)
  local best
  local list = {}
  if owner then
    for _, n in pairs(st.nodes) do
      if n.head == branch and n.head_owner and n.head_owner:lower() == owner:lower() then
        list[#list + 1] = n
      end
    end
  else
    for _, num in ipairs(st.by_head[branch] or {}) do
      list[#list + 1] = st.nodes[num]
    end
  end
  for _, n in ipairs(list) do
    if not best or ((n.state == 'OPEN') ~= (best.state == 'OPEN') and n.state == 'OPEN')
      or ((n.state == 'OPEN') == (best.state == 'OPEN') and newer(n, best)) then
      best = n
    end
  end
  return best
end

local function is_trunk(st, b)
  return b == st.trunk or (st.default_branch ~= nil and b == st.default_branch)
end

---The start PR (HEAD's branch) and the chain below it, bottom first. Second value: a branch
---to look up next (flat) to continue the chain, if any. Third: why the chain stops early
---('cycle', 'no_pr': a base branch without a PR, 'cut').
---@return revuey.TreeNode[]? chain, string? need, string? stop
function M.chain(st)
  local start
  -- a fork's branch (the head owner is not the repo's): its PR in the base repo
  local own = st.start_owner and st.repo.owner:lower() ~= st.start_owner:lower() and st.start_owner or nil
  for _, b in ipairs(st.start) do
    local r = M.rep(st, b, own)
    if r then
      start = r
      break
    end
    if st.listed[b] == nil then
      return nil, b
    end
  end
  if not start then
    return nil
  end
  local chain, seen = { start }, { [start.head] = true }
  local cur = start
  while not is_trunk(st, cur.base) do
    local b = cur.base
    if seen[b] then
      return chain, nil, 'cycle'
    end
    local r = M.rep(st, b)
    if st.listed[b] == nil or (r and r.state ~= 'OPEN' and st.listed[b] == false and not st.flat[b]) then
      return chain, b
    end
    if not r then
      return chain, nil, 'no_pr'
    end
    seen[b] = true
    table.insert(chain, 1, r)
    cur = r
  end
  return chain
end

---Membership: the chain plus every PR based on a representative's branch, recursively, at most
---MAX_NODES (`st.cut` says so). Returns the tree's numbers in BFS order and the representatives
---whose children were not asked (CLOSED ones only with `closed`: routes never pass through them,
---so their subtrees can wait; except those in `st.pin`, the chosen PR and the PRs below it, whose
---path must be complete in phase one).
local function members(st, chain, closed)
  local order, inside, frontier = {}, {}, {}
  local pin = st.pin or {}
  local queue = {}
  for _, n in ipairs(chain or {}) do
    if not inside[n.number] then
      inside[n.number] = true
      order[#order + 1] = n.number
      queue[#queue + 1] = n
    end
  end
  local qi = 1
  while qi <= #queue do
    local n = queue[qi]
    qi = qi + 1
    local r = (not n.fork) and M.rep(st, n.head)
    if r and r.number == n.number then
      if st.asked[n.head] then
        for _, num in ipairs(st.kids[n.head] or {}) do
          if not inside[num] then
            if #order >= M.MAX_NODES then
              st.cut = st.cut or ('stopped at %d PRs'):format(#order)
              break
            end
            inside[num] = true
            order[#order + 1] = num
            queue[#queue + 1] = st.nodes[num]
          end
        end
      elseif closed or n.state ~= 'CLOSED' or n.number == chain[#chain].number or pin[n.number] then
        frontier[#frontier + 1] = n.head
      end
    end
  end
  return order, frontier
end

---What the next round asks: {down = {branch}, kids = {branches}}, or nil when the tree is
---complete or a limit was reached (`st.cut` says which). Two phases: without `closed`, what
---routes need (the chain, and the children of every PR that is not CLOSED); with it, the
---subtrees of CLOSED PRs too (only the tree view shows them).
function M.plan(st, closed)
  if st.failed then
    return nil
  end
  local chain, need = M.chain(st)
  local want = { down = {}, kids = {} }
  if need then
    want.down[1] = need
  end
  if not chain and not need then
    return nil -- no PR for the branch
  end
  local order, frontier = members(st, chain, closed)
  for _, b in ipairs(frontier) do
    if #want.kids >= M.MAX_ALIASES then
      break
    end
    want.kids[#want.kids + 1] = b
  end
  if #want.down == 0 and #want.kids == 0 then
    return nil
  end
  if st.calls >= M.MAX_CALLS then
    st.cut = ('stopped after %d calls'):format(st.calls)
    return nil
  end
  if #order >= M.MAX_NODES then
    st.cut = ('stopped at %d PRs'):format(#order)
    return nil
  end
  return want
end

---The first round's parts (to ride on the PR lookup): the start branches' chain.
function M.first_parts(st)
  return M.parts(st, { down = vim.deepcopy(st.start), kids = {} })
end

-- ---------------------------------------------------------------------------
-- The tree
-- ---------------------------------------------------------------------------

---@class revuey.Tree
---@field trunk string
---@field nodes table<integer, revuey.TreeNode>
---@field kids table<integer|string, integer[]> number (or 'root') -> children, sorted by number
---@field parent table<integer, integer|string>
---@field more table<integer, integer> PRs based on its branch that were not read (cut lists)
---@field unexpanded table<integer, true> representatives whose children were not asked (a limit)
---@field start integer       HEAD's PR
---@field chain integer[]     trunk to HEAD's PR, bottom first
---@field stop? string        'cycle' | 'no_pr' | 'cut' | nil: why the chain stops above the trunk
---@field bottom_base? string the chain's bottom base when it is not the trunk
---@field rep table<string, integer> head branch -> its representative PR
---@field cut? string         a limit was reached or a round failed
---@field count integer

---Build the tree from a fetch. nil when HEAD's branch has no PR.
---@return revuey.Tree?
function M.tree(st)
  local chain, need, stop = M.chain(st)
  if not chain then
    return nil
  end
  if need then
    stop = 'cut'
  end
  local order, frontier = members(st, chain, true)
  local t = {
    trunk = st.trunk, nodes = {}, kids = { root = {} }, parent = {}, more = {}, unexpanded = {},
    start = chain[#chain].number, chain = {}, stop = stop, count = #order,
    cut = st.failed or st.cut, rep = {},
  }
  for _, num in ipairs(order) do
    t.nodes[num] = st.nodes[num]
  end
  for _, n in ipairs(chain) do
    t.chain[#t.chain + 1] = n.number
  end
  local unexp = {}
  for _, b in ipairs(frontier) do
    unexp[b] = true
  end
  t.parent[chain[1].number] = 'root'
  table.insert(t.kids.root, chain[1].number)
  -- the bottom PR's base when it is not the trunk (a branch without a PR, the repository's
  -- default branch when the trunk is another, where a cycle or a cut stopped the chain)
  if chain[1].base ~= st.trunk then
    t.bottom_base = chain[1].base
  end
  for _, num in ipairs(order) do
    local n = st.nodes[num]
    local r = (not n.fork) and M.rep(st, n.head)
    if r and r.number == num then
      t.rep[n.head] = num
      t.kids[num] = {}
      if unexp[n.head] then
        t.unexpanded[num] = true
      end
      for _, k in ipairs(st.kids[n.head] or {}) do
        if t.nodes[k] and t.parent[k] == nil and k ~= num then
          t.parent[k] = num
          table.insert(t.kids[num], k)
        end
      end
      local total = st.kids_total[n.head]
      if total and total > #(st.kids[n.head] or {}) then
        t.more[num] = total - #(st.kids[n.head] or {})
      end
    end
  end
  -- the chain itself, also where children were not asked (a cut)
  for i = 2, #chain do
    local p, c = chain[i - 1].number, chain[i].number
    if t.parent[c] == nil then
      t.parent[c] = p
      t.kids[p] = t.kids[p] or {}
      table.insert(t.kids[p], c)
    end
  end
  for _, list in pairs(t.kids) do
    table.sort(list)
  end
  return t
end

---Is a node shown as open for routes (OPEN, drafts included)?
local function open(n)
  return n and n.state == 'OPEN'
end

---Trunk-to-node numbers, bottom first.
function M.down(t, num)
  local out, seen = {}, {}
  local cur = num
  while cur and cur ~= 'root' and not seen[cur] do
    seen[cur] = true
    table.insert(out, 1, cur)
    cur = t.parent[cur]
  end
  return out
end

---The default route through `num`: down to the trunk by bases, then up through OPEN children,
---taking at each fork the child with the longest open continuation (ties: the lower PR number,
---the one opened first, which stays put as PRs are updated). Bottom first; second value: the
---index of `num`.
---@return integer[] path, integer index
function M.route(t, num)
  local path = M.down(t, num)
  local idx = #path
  local memo = {}
  local function best(n, seen)
    if memo[n] then
      return memo[n][1], memo[n][2]
    end
    local len, pick = 0, nil
    for _, k in ipairs(t.kids[n] or {}) do
      if open(t.nodes[k]) and not seen[k] then
        seen[k] = true
        local l = 1 + (best(k, seen))
        seen[k] = nil
        if l > len or (l == len and pick and k < pick) then
          len, pick = l, k
        end
      end
    end
    memo[n] = { len, pick }
    return len, pick
  end
  local seen = {}
  for _, p in ipairs(path) do
    seen[p] = true
  end
  local cur = num
  while true do
    local _, nxt = best(cur, seen)
    if not nxt or seen[nxt] then
      break
    end
    seen[nxt] = true
    path[#path + 1] = nxt
    cur = nxt
  end
  return path, idx
end

---Children of a node not on `path` (other paths through it), by state.
---@return integer total, integer closed
function M.others(t, num, on_path)
  local total, closed = 0, 0
  for _, k in ipairs(t.kids[num] or {}) do
    if not on_path[k] then
      total = total + 1
      if t.nodes[k].state == 'CLOSED' then
        closed = closed + 1
      end
    end
  end
  return total, closed
end

-- ---------------------------------------------------------------------------
-- Fetch marks (what the clone has of each PR's head)
-- ---------------------------------------------------------------------------

---@class revuey.TreeFacts
---@field remote string                  the PRs' remote (`origin`)
---@field heads table<string, string>    local branch -> tip
---@field refs table<string, string>     remote-tracking ref (`origin/x`) -> tip
---@field objects table<string, true>    head commits present in the clone
---@field trunk string
---@field trunk_rev string
---@field trunk_state string
---@field current? string                checked-out branch (or the branch detached HEAD is at)
---@field head string                    HEAD commit
---@field detached? boolean
---@field normalize? fun(name:string):string

---How a PR's head is reached in this clone, and whether it is up to date.
---@return {ref?:string, tip?:string, mark?:'missing'|'behind', how:'branch'|'remote'|'commit'|'none'}
function M.reach(n, facts)
  -- a closed or merged PR's branch may have moved on (to a newer PR of the same branch): its
  -- ref is that PR's, and only the commit is this one's
  local live = n.state == 'OPEN'
  if not n.fork then
    local ref = facts.remote .. '/' .. n.head
    local tip = facts.refs[ref]
    if tip and (live or tip == n.head_oid or not n.head_oid) then
      local mark = (n.head_oid and tip ~= n.head_oid and n.head_exists) and 'behind' or nil
      return { ref = ref, tip = tip, mark = mark, how = 'remote' }
    end
    if n.head_exists and live then
      if n.head_oid and facts.objects[n.head_oid] then
        return { tip = n.head_oid, mark = 'missing', how = 'commit' }
      end
      return { mark = 'missing', how = 'none' }
    end
  end
  -- a fork's head, a deleted branch, an old PR of a moved branch: only the commit
  -- (refs/pull/N/head brings it)
  if n.head_oid and facts.objects[n.head_oid] then
    return { tip = n.head_oid, how = 'commit' }
  end
  return { mark = 'missing', how = 'none' }
end

M.MARK_TEXT = { missing = 'not fetched', behind = 'origin behind · fetch', ['local'] = 'local branch differs' }

---Is `name` a branch name git accepts in a refspec (`git check-ref-format --branch` rules)? A
---guard before names from GitHub go into `git fetch` arguments; never true for anything that
---could read as an option or a second refspec.
function M.safe_ref(name)
  if type(name) ~= 'string' or name == '' or name:sub(1, 1) == '-' or name:sub(1, 1) == '/' then
    return false
  end
  if name:find('%.%.') or name:find('@{', 1, true) or name:find('//', 1, true) or name:find('[%c%s~%^:%?%*%[\\]')
    or name:sub(-1) == '/' or name:sub(-1) == '.' or name:sub(-5) == '.lock' or name == '@'
    or name:find('/%.') or name:sub(1, 1) == '.' then
    return false
  end
  return true
end

---What `git fetch` brings the given PRs with: branch refspecs for open PRs' heads (updating
---`<remote>/<head>`), `refs/pull/N/head` (objects only, no ref written) for forks, deleted
---branches and closed or merged PRs (their branch may hold a newer PR now).
---@return string[] refspecs, integer[] numbers fetched
function M.fetch_specs(t, nums, facts)
  local specs, which, seen = {}, {}, {}
  for _, num in ipairs(nums) do
    local n = t.nodes[num]
    local r = n and M.reach(n, facts)
    if n and r and r.mark and not seen[num] then
      seen[num] = true
      if not n.fork and n.head_exists and n.state == 'OPEN' and M.safe_ref(n.head) and M.safe_ref(facts.remote) then
        specs[#specs + 1] = ('+refs/heads/%s:refs/remotes/%s/%s'):format(n.head, facts.remote, n.head)
      else
        specs[#specs + 1] = ('refs/pull/%d/head'):format(num)
      end
      which[#which + 1] = num
    end
  end
  return specs, which
end

-- ---------------------------------------------------------------------------
-- The stack for a path
-- ---------------------------------------------------------------------------

---A revuey.Stack for a path (bottom first). Layers use the local branch of a PR's head when
---there is one, else `<remote>/<head>` (read-only), else the head commit when the clone has it
---(a fork's PR, a deleted branch, a branch never fetched: read-only, `unfetched`). PRs whose
---commits are not in the clone at all are left out, and the layer above diffs from the one
---below them (a note says which). `view` is the PR to view.
---@param facts revuey.TreeFacts
---@return revuey.Stack?
function M.stack(t, path, view, facts)
  local normalize = facts.normalize or function(x)
    return x
  end
  local layers, missing = {}, {}
  local on_path = {}
  for _, num in ipairs(path) do
    on_path[num] = true
  end
  local current, view_index, base_missing
  local prev
  for _, num in ipairs(path) do
    local n = t.nodes[num]
    local name, tip, remote, unfetched, key
    local r = M.reach(n, facts)
    -- a local branch of the head's name is the layer only when it is this PR's: at its head
    -- commit; or, for the branch's open PR, containing it (your commits on top), or checked out
    -- (its working tree is the layer's, whatever it holds: noted when it is not the PR's). An
    -- older closed PR of a moved branch, or a local copy behind or off the PR, is shown from
    -- GitHub's side (remote ref or commit) with a note.
    local lb = (not n.fork) and facts.heads[n.head] or nil
    local use_local, differs = false, nil
    if lb then
      if not n.head_oid or lb == n.head_oid then
        use_local = true
      elseif n.state == 'OPEN' and t.rep[n.head] == num then
        if (facts.contains or {})[n.head] then
          use_local = true
        elseif n.head == facts.current then
          use_local, differs = true, 'head'
        else
          differs = 'other'
        end
      end
    end
    if use_local then
      name, tip, key = n.head, lb, n.head
    elseif r.tip then
      remote = true
      if n.fork then
        name = (n.head_owner or '?') .. ':' .. n.head
        key = name
      else
        name, key = facts.remote .. '/' .. n.head, n.head
      end
      tip, unfetched = r.tip, r.how == 'commit' or nil
    end
    if not tip then
      missing[#missing + 1] = num
    else
      local others, closed = M.others(t, num, on_path)
      local parent = prev and prev.name or facts.trunk
      local parent_rev = prev and prev.tip or facts.trunk_rev
      if not prev and t.bottom_base and path[1] == t.chain[1] then
        -- the chain's bottom base (also below a bottom PR that is missing here)
        local b = t.bottom_base
        local brev = facts.heads[b] or facts.refs[facts.remote .. '/' .. b]
        if brev then
          parent, parent_rev = facts.heads[b] and b or (facts.remote .. '/' .. b), brev
        else
          base_missing = facts.remote .. '/' .. b
        end
      end
      local is_head = tip == facts.head and (name == facts.current or (facts.detached and true or false))
      local layer = {
        name = name,
        tip = tip,
        parent = parent,
        parent_rev = parent_rev,
        source = 'github',
        is_head = is_head and not unfetched or false,
        state_branch = key,
        state_base = prev and prev.state_branch
          or ((parent == facts.trunk and facts.trunk_state) or normalize(parent)),
        key_old = prev and true or nil,
        remote = remote,
        unfetched = unfetched,
        detached = (is_head and facts.detached) or nil,
        pr = num,
        others = others > 0 and others or nil,
        others_closed = closed > 0 and closed or nil,
        fetch = r.mark or (differs and 'local') or nil,
        local_differs = differs,
        fork_pr = n.fork or nil,
        pr_head = n.head,
        pr_owner = n.head_owner,
      }
      layers[#layers + 1] = layer
      if layer.is_head then
        current = #layers
      end
      if num == view then
        view_index = #layers
      end
      prev = layer
    end
  end
  if #layers == 0 then
    return nil
  end
  return {
    kind = 'github',
    trunk = facts.trunk,
    trunk_rev = facts.trunk_rev,
    trunk_state = facts.trunk_state or normalize(facts.trunk),
    layers = layers,
    current = view_index or current or #layers,
    head_index = current,
    forks = {},
    notes = {},
    missing = missing,
    path = path,
    base_missing = base_missing,
  }
end

-- ---------------------------------------------------------------------------
-- Drawing (Graphite-style: the top of the stack at the top, the trunk at the bottom)
-- ---------------------------------------------------------------------------

---Visible children of a node: CLOSED ones are hidden unless `show_closed`, they are on the
---chosen path, or something open or merged sits above them. Returns visible and the number of
---PRs hidden below this node's children.
local function visible_kids(t, num, o, memo)
  local function has_shown(k)
    if memo[k] ~= nil then
      return memo[k]
    end
    memo[k] = false
    local n = t.nodes[k]
    local res = o.show_closed or n.state ~= 'CLOSED' or (o.on_path and o.on_path[k]) or false
    if not res then
      for _, c in ipairs(t.kids[k] or {}) do
        if has_shown(c) then
          res = true
          break
        end
      end
    end
    memo[k] = res
    return res
  end
  local shown, hidden = {}, 0
  local function count(k)
    local c = 1
    for _, x in ipairs(t.kids[k] or {}) do
      c = c + count(x)
    end
    return c
  end
  for _, k in ipairs(t.kids[num] or {}) do
    if has_shown(k) then
      shown[#shown + 1] = k
    else
      hidden = hidden + count(k)
    end
  end
  return shown, hidden
end

---The graph rows, top first: {node = number?, col = integer, pipes = {cols}, join? = {from,
---to, tees}} where `node` rows draw the node at `col`; `hidden` = closed PRs hidden above it.
---`o`: {show_closed, on_path (set), main (set: preferred child at forks, e.g. the route)}.
function M.layout(t, o)
  o = o or {}
  local memo = {}
  local function block(num, col)
    local ks, hidden = visible_kids(t, num, o, memo)
    -- the child on the route stays in this column; the others go to the right, by number
    table.sort(ks, function(a, b)
      local ma, mb = o.main and o.main[a] or false, o.main and o.main[b] or false
      if ma ~= mb then
        return ma
      end
      return a < b
    end)
    local rows, width = {}, 1
    if #ks > 0 then
      local main, w0 = block(ks[1], col)
      vim.list_extend(rows, main)
      width = w0
      local starts, off = {}, col + 1
      for i = 2, #ks do
        local side, wi = block(ks[i], off)
        starts[i] = off
        for _, r in ipairs(side) do
          r.pipes[#r.pipes + 1] = col
          for j = 2, i - 1 do
            r.pipes[#r.pipes + 1] = starts[j]
          end
        end
        vim.list_extend(rows, side)
        off = off + wi
      end
      if #ks > 1 then
        local tees = {}
        for i = 2, #ks - 1 do
          tees[#tees + 1] = starts[i]
        end
        rows[#rows + 1] = { pipes = {}, join = { from = col, to = starts[#ks], tees = tees } }
      end
      width = math.max(width, off - col)
    end
    rows[#rows + 1] = { node = num, col = col, pipes = {}, hidden = hidden > 0 and hidden or nil }
    return rows, width
  end
  local rows = {}
  local roots = visible_kids(t, 'root', o, memo)
  for i, r in ipairs(roots) do
    local b = block(r, 0)
    if i > 1 then
      for _, x in ipairs(b) do
        x.pipes[#x.pipes + 1] = 0
      end
    end
    vim.list_extend(rows, b)
  end
  rows[#rows + 1] = { trunk = true, col = 0, pipes = {} }
  return rows
end

---The graph prefix of a row: two cells per column. `glyph` for its node. Also the byte range of
---the glyph.
function M.graph(row, glyph)
  local cells = {}
  local maxc = row.col or 0
  for _, p in ipairs(row.pipes) do
    maxc = math.max(maxc, p)
  end
  if row.join then
    maxc = math.max(maxc, row.join.to)
  end
  for c = 0, maxc do
    cells[c] = '  '
  end
  for _, p in ipairs(row.pipes) do
    cells[p] = '│ '
  end
  if row.join then
    local tees = {}
    for _, x in ipairs(row.join.tees) do
      tees[x] = true
    end
    for c = row.join.from, row.join.to do
      local ch = (c == row.join.from and '├') or (c == row.join.to and '┘') or (tees[c] and '┴') or '─'
      cells[c] = ch .. (c == row.join.to and ' ' or '─')
    end
  end
  if row.node or row.trunk then
    cells[row.col] = glyph .. ' '
  end
  local out, gs, ge = {}, nil, nil
  local len = 0
  for c = 0, maxc do
    if c == row.col and (row.node or row.trunk) then
      gs, ge = len, len + #glyph
    end
    out[#out + 1] = cells[c]
    len = len + #cells[c]
  end
  return table.concat(out), gs, ge
end

return M
