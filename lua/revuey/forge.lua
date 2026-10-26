-- GitHub pull request lookup for review branches and stack layers. No UI: remote parsing, the
-- batched GraphQL query, response mapping, a per-repo TTL cache, and the row/detail models the
-- panel draws (forge_view.lua). Shells out to the user's own `gh` (assumed authenticated; revuey
-- never reads credentials). Failures (gh missing, non-zero exit, bad JSON, offline, rate
-- limits) are never shown: the lookup yields nothing and the reason goes to revuey.log.
--
-- Also the review threads of open PRs (`fetch_threads`: paginated, cached per PR like the PR
-- lookup; placement and display are in forge_threads.lua). Reusable for later forge work
-- (posting reviews): `remote_info`, `parse_remote_url`, `base_remote`, `targets` and
-- `run_graphql` know nothing about the panel.
local git = require('revuey.git')
local stack_mod = require('revuey.stack')
local log = require('revuey.log')

local M = {}

---@class revuey.ForgeRepo
---@field host string     web host (github.com, or an enterprise host)
---@field owner string
---@field name string

---@class revuey.ForgeCandidate  one head branch name to try
---@field branch string       head branch name on the remote (remote prefix stripped)
---@field head_owner string   owner of the repo the branch lives in (filters fork PRs)
---@field repos revuey.ForgeRepo[] repos to search: the base repo, then the fork (each also
---                           asks its `parent`)
---@field remote string       remote the branch comes from

---@class revuey.ForgeTarget  what to look up for one layer (or the plain review branch)
---@field candidates revuey.ForgeCandidate[] in order; the first with a PR wins
---@field tip? string         the branch tip commit (closed/merged PRs must have their head in it)

---@class revuey.ForgeInfo
---@field names string[]      remote names
---@field remotes table<string, {url:string, repo?:revuey.ForgeRepo}>
---@field branches table<string, {up_remote?:string, up_ref?:string, push_remote?:string, push_ref?:string}>
---@field resolved table<string, string> remote.<name>.gh-resolved values

---@class revuey.PR
---@field number integer
---@field title string
---@field url string
---@field state 'OPEN'|'MERGED'|'CLOSED'
---@field draft boolean
---@field author? string
---@field review_decision? 'APPROVED'|'CHANGES_REQUESTED'|'REVIEW_REQUIRED'
---@field reviews {author:string, state:string}[]  latest review per reviewer
---@field requested string[]  pending requested reviewers (users, or teams as `@org/slug`-less slug)
---@field checks {success:integer, failure:integer, pending:integer, total:integer}
---@field mergeable? 'MERGEABLE'|'CONFLICTING'|'UNKNOWN'
---@field base string
---@field head string
---@field head_owner? string  nil for a deleted fork
---@field head_oid? string    head commit
---@field updated_at string   ISO time of the last update (sorts as text)
---@field repo string         host/owner/name it was found in

-- ---------------------------------------------------------------------------
-- Remotes
-- ---------------------------------------------------------------------------

---Is `host` a GitHub host? github.com (and ssh aliases such as `github.com-work`,
---`ssh.github.com`), any host with "github" in its name, or one listed in `hosts`.
---@return string? api_host the host to pass to `gh --hostname`
function M.github_host(host, hosts)
  if not host or host == '' then
    return nil
  end
  host = host:lower()
  for _, h in ipairs(hosts or {}) do
    if h:lower() == host then
      return host
    end
  end
  if host == 'github.com' or host == 'ssh.github.com' or host:match('^github%.com[-_]') or host == 'www.github.com' then
    return 'github.com'
  end
  if host:find('github', 1, true) then
    return host
  end
  return nil
end

---Parse a remote URL (scp-like `git@host:owner/repo.git`, `ssh://`, `https://`, `git://`) into
---a GitHub repo, or nil (a local path, another forge, an unknown host).
---@param url string
---@param hosts? string[] extra (enterprise) hosts
---@return revuey.ForgeRepo?
function M.parse_remote_url(url, hosts)
  if not url then
    return nil
  end
  url = vim.trim(url)
  local host, path
  local scheme, rest = url:match('^(%a[%w+.-]*)://(.+)$')
  if scheme then
    scheme = scheme:lower()
    if scheme == 'file' then
      return nil
    end
    local authority
    authority, path = rest:match('^([^/]+)(/.*)$')
    if not authority then
      return nil
    end
    host = authority:gsub('^.*@', ''):gsub(':%d*$', '')
  else
    -- scp-like: [user@]host:path (not a local path such as /x or ./x or C:\x)
    local h, p = url:match('^([^/:]+):(.+)$')
    if not h or #h == 1 then
      return nil
    end
    host, path = h:gsub('^.*@', ''), p
  end
  local api = M.github_host(host, hosts)
  if not api then
    return nil
  end
  path = path:gsub('^/+', ''):gsub('/+$', ''):gsub('%.git$', '')
  local segs = vim.split(path, '/', { trimempty = true })
  if #segs < 2 then
    return nil
  end
  return { host = api, owner = segs[#segs - 1], name = segs[#segs] }
end

---"host/owner/name" (lower-cased: GitHub owners and names are case-insensitive).
function M.repo_key(repo)
  return (repo.host .. '/' .. repo.owner .. '/' .. repo.name):lower()
end

---Remotes, branch upstream/push config and gh's resolved base of a repo, via plain git (`git
---remote`, `git remote get-url`, one `git for-each-ref` for upstreams and push targets, `git
---config --get-regexp` for `remote.<name>.gh-resolved`). In a coroutine (git.async) the calls
---do not block.
---@return revuey.ForgeInfo
function M.remote_info(root, hosts)
  local info = { names = git.remotes(root), remotes = {}, branches = {}, resolved = {} }
  local fns = {}
  for i, name in ipairs(info.names) do
    fns[i] = function()
      return vim.trim(git.git({ 'remote', 'get-url', name }, root) or '')
    end
  end
  local fmt = '%(refname:short)%00%(upstream:remotename)%00%(upstream:remoteref)%00%(push:remotename)%00%(push:remoteref)'
  fns[#fns + 1] = function()
    return git.git({ 'for-each-ref', '--format=' .. fmt, 'refs/heads' }, root) or ''
  end
  fns[#fns + 1] = function()
    return git.git({ 'config', '--get-regexp', '^remote\\..*\\.gh-resolved$' }, root) or ''
  end
  local res = git.all(fns)
  for i, name in ipairs(info.names) do
    local url = res[i][1] and res[i][2] or ''
    info.remotes[name] = { url = url, repo = url ~= '' and M.parse_remote_url(url, hosts) or nil }
  end
  local refs = res[#info.names + 1]
  for line in ((refs[1] and refs[2]) or ''):gmatch('[^\n]+') do
    local f = vim.split(line, '\0', { plain = true })
    local function v(k)
      return f[k] ~= nil and f[k] ~= '' and f[k] or nil
    end
    if v(1) then
      info.branches[f[1]] = { up_remote = v(2), up_ref = v(3), push_remote = v(4), push_ref = v(5) }
    end
  end
  local resolved = res[#info.names + 2]
  for line in ((resolved[1] and resolved[2]) or ''):gmatch('[^\n]+') do
    local r, val = line:match('^remote%.(.+)%.gh%-resolved (.*)$')
    if r then
      info.resolved[r] = val
    end
  end
  return info
end

local function strip_ref(ref)
  return (ref:gsub('^refs/heads/', ''))
end

---A known remote with a GitHub repo?
local function gh_remote(info, r)
  return r and r ~= '.' and info.remotes[r] and info.remotes[r].repo and r or nil
end

---`origin/x` -> origin, x when `origin` is a configured remote.
local function split_known(name, info)
  local remote, short = stack_mod.split_remote(name, info.names)
  if remote and info.remotes[remote] then
    return remote, short
  end
end

---Branch name of a ref as GitHub sees it: the remote prefix stripped (`origin/main` -> main).
function M.branch_name(name, info)
  local _, short = split_known(name, info or { names = {}, remotes = {} })
  return short or name
end

---The repo PRs are opened against, resolved like gh does: a remote marked
---`remote.<name>.gh-resolved = base` (gh repo set-default), else `upstream`, else the trunk's
---remote, else `origin`, else the only GitHub remote. A fork without any of these is still
---covered: the query asks each repo's `parent` too, unless the base was chosen explicitly
---(`gh-resolved` or `upstream`: an internal fork must not match its public parent's PRs). nil
---when there is no GitHub remote. Second value: true when chosen explicitly.
function M.base_remote(trunk, info)
  local names = vim.deepcopy(info.names)
  table.sort(names)
  for _, n in ipairs(names) do
    if info.resolved and info.resolved[n] == 'base' and gh_remote(info, n) then
      return n, true
    end
  end
  if gh_remote(info, 'upstream') then
    return 'upstream', true
  end
  if trunk then
    local r = split_known(trunk, info)
    if not r and info.branches[trunk] then
      r = info.branches[trunk].up_remote
    end
    if gh_remote(info, r) then
      return r
    end
  end
  if gh_remote(info, 'origin') then
    return 'origin'
  end
  local gh = {}
  for _, n in ipairs(names) do
    if gh_remote(info, n) then
      gh[#gh + 1] = n
    end
  end
  return #gh == 1 and gh[1] or nil
end

---Lookup target for one branch (a layer name, `origin/x` for a remote layer). Candidates in
---order: a remote layer's branch on its remote; for a local branch its own name, then its push
---target's name (`@{push}`), then its upstream's name when that differs, never the trunk (a
---branch made with `git switch -c feat origin/main` tracks main).
---@param tip? string commit of the branch tip (closed/merged PRs must have their head in it)
---@return revuey.ForgeTarget?
---@param explicit? boolean the base repo was chosen explicitly: no `parent` lookups
function M.target(name, remote_layer, tip, base, info, trunk_branch, explicit)
  if not base or not name or name == '' or name == 'HEAD' then
    return nil
  end
  local base_repo = info.remotes[base].repo
  local t = { candidates = {}, tip = tip }
  local seen = {}
  local function add(branch, remote)
    if not branch or branch == '' then
      return
    end
    remote = gh_remote(info, remote) or base
    if seen[remote .. '\0' .. branch] then
      return
    end
    seen[remote .. '\0' .. branch] = true
    local own = info.remotes[remote].repo
    local repos = { base_repo }
    if M.repo_key(own) ~= M.repo_key(base_repo) then
      -- a fork: its PR is usually in the base repo (head owner = the fork's owner), else in the fork
      repos[2] = own
    end
    t.candidates[#t.candidates + 1] = { branch = branch, remote = remote, head_owner = own.owner, repos = repos, parent = not explicit }
  end
  local b = info.branches[name]
  local remote, short = split_known(name, info)
  if not b and (remote_layer or remote) then
    if not remote then
      remote, short = stack_mod.split_remote(name, info.names)
    end
    add(short, remote)
  else
    b = b or {}
    add(name, gh_remote(info, b.push_remote) or gh_remote(info, b.up_remote))
    if b.push_ref and strip_ref(b.push_ref) ~= trunk_branch then
      add(strip_ref(b.push_ref), b.push_remote)
    end
    if b.up_ref and gh_remote(info, b.up_remote) and strip_ref(b.up_ref) ~= trunk_branch then
      add(strip_ref(b.up_ref), b.up_remote)
    end
  end
  return #t.candidates > 0 and t or nil
end

---Targets for a review: one per stack layer (by layer name), or `['']` for a plain review.
---@return table<string, revuey.ForgeTarget>
function M.targets(review, info)
  local out = {}
  local trunk = review.stack and review.stack.trunk or review.base
  local base, explicit = M.base_remote(trunk, info)
  if not base then
    return out
  end
  local trunk_branch = trunk and M.branch_name(trunk, info)
  if review.stack then
    for _, l in ipairs(review.stack.layers) do
      out[l.name] = M.target(l.name, l.remote, l.tip, base, info, trunk_branch, explicit)
    end
  else
    out[''] = M.target(review.branch, false, review.head, base, info, trunk_branch, explicit)
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Query and response
-- ---------------------------------------------------------------------------

local PR_FIELDS = [[
fragment pr on PullRequest {
  number title url state isDraft updatedAt headRefOid
  author { login }
  reviewDecision
  latestReviews(first: 50) { nodes { author { login } state } }
  reviewRequests(first: 50) { nodes { requestedReviewer { __typename ... on User { login } ... on Team { slug } ... on Bot { login } ... on Mannequin { login } } } }
  mergeable baseRefName headRefName
  headRepositoryOwner { login }
  commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 1) {
    checkRunCountsByState { state count }
    statusContextCountsByState { state count }
  } } } } }
}]]

---GraphQL string literal (JSON escaping is valid GraphQL).
local function lit(s)
  return vim.json.encode(s)
end

---One query for many (repo, branch) pairs: an aliased `repository { pullRequests(headRefName) }`
---each, plus the same lookup in the repo's `parent` (a fork's upstream; null otherwise) unless
---the pair has `parent = false`. Returns the query and alias -> pair.
---@param pairs {repo:revuey.ForgeRepo, branch:string, parent?:boolean}[]
---@return string query, table<string, {repo:revuey.ForgeRepo, branch:string}> aliases
function M.build_query(pairs)
  local parts, aliases = { 'query {' }, {}
  for i, p in ipairs(pairs) do
    local alias = 'l' .. i
    aliases[alias] = p
    local prs = ('pullRequests(headRefName: %s, first: 30, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { ...pr } }'):format(lit(p.branch))
    local parent = p.parent ~= false and (' parent { nameWithOwner %s }'):format(prs) or ''
    parts[#parts + 1] = ('  %s: repository(owner: %s, name: %s) { %s%s }')
      :format(alias, lit(p.repo.owner), lit(p.repo.name), prs, parent)
  end
  parts[#parts + 1] = '}'
  parts[#parts + 1] = PR_FIELDS
  return table.concat(parts, '\n'), aliases
end

local CHECK_KIND = {
  SUCCESS = 'success', NEUTRAL = 'success', SKIPPED = 'success', COMPLETED = 'success',
  FAILURE = 'failure', ERROR = 'failure', CANCELLED = 'failure', TIMED_OUT = 'failure',
  ACTION_REQUIRED = 'failure', STARTUP_FAILURE = 'failure', STALE = 'failure',
  PENDING = 'pending', QUEUED = 'pending', IN_PROGRESS = 'pending', WAITING = 'pending',
  EXPECTED = 'pending', REQUESTED = 'pending',
}

local function nodes(conn)
  return type(conn) == 'table' and type(conn.nodes) == 'table' and conn.nodes or {}
end

local function str(v)
  return type(v) == 'string' and v or nil
end

---Map a GraphQL PullRequest node to a revuey.PR.
---@return revuey.PR?
function M.normalize(n, repo_key)
  if type(n) ~= 'table' or type(n.number) ~= 'number' then
    return nil
  end
  local pr = {
    number = n.number,
    title = str(n.title) or '',
    url = str(n.url) or '',
    state = str(n.state) or 'OPEN',
    draft = n.isDraft == true,
    author = type(n.author) == 'table' and str(n.author.login) or nil,
    review_decision = str(n.reviewDecision),
    reviews = {},
    requested = {},
    checks = { success = 0, failure = 0, pending = 0, total = 0 },
    mergeable = str(n.mergeable),
    base = str(n.baseRefName) or '',
    head = str(n.headRefName) or '',
    head_owner = type(n.headRepositoryOwner) == 'table' and str(n.headRepositoryOwner.login) or nil,
    head_oid = str(n.headRefOid),
    updated_at = str(n.updatedAt) or '',
    repo = repo_key,
  }
  for _, r in ipairs(nodes(n.latestReviews)) do
    if type(r) == 'table' then
      pr.reviews[#pr.reviews + 1] = { author = type(r.author) == 'table' and str(r.author.login) or 'ghost', state = str(r.state) or '' }
    end
  end
  for _, rr in ipairs(nodes(n.reviewRequests)) do
    local who = type(rr) == 'table' and type(rr.requestedReviewer) == 'table' and rr.requestedReviewer
    local name = who and (str(who.login) or str(who.slug))
    if name then
      pr.requested[#pr.requested + 1] = name
    end
  end
  local commit = nodes(n.commits)[1]
  local rollup = type(commit) == 'table' and type(commit.commit) == 'table' and commit.commit.statusCheckRollup
  local ctx = type(rollup) == 'table' and type(rollup.contexts) == 'table' and rollup.contexts
  if ctx then
    for _, field in ipairs({ 'checkRunCountsByState', 'statusContextCountsByState' }) do
      for _, c in ipairs(type(ctx[field]) == 'table' and ctx[field] or {}) do
        local kind = CHECK_KIND[c.state]
        if kind and type(c.count) == 'number' then
          pr.checks[kind] = pr.checks[kind] + c.count
          pr.checks.total = pr.checks.total + c.count
        end
      end
    end
  end
  return pr
end

---The PR for a branch among candidates: OPEN first, then MERGED/CLOSED, each the most recently
---updated first (across repos). With `head_owner`, only PRs whose head repo has that owner (a
---deleted fork's PR has none: not ours). With `accept`, closed/merged PRs must pass it (their
---head commit is in the branch); open ones are taken by name.
---@param prs revuey.PR[]
---@param accept? fun(pr:revuey.PR):boolean
---@return revuey.PR?
function M.pick(prs, head_owner, accept)
  local list = {}
  for i, pr in ipairs(prs) do
    list[i] = { pr = pr, i = i }
  end
  table.sort(list, function(a, b)
    if a.pr.updated_at ~= b.pr.updated_at then
      return (a.pr.updated_at or '') > (b.pr.updated_at or '')
    end
    return a.i < b.i
  end)
  local function ours(pr)
    return not head_owner or (pr.head_owner ~= nil and pr.head_owner:lower() == head_owner:lower())
  end
  for _, e in ipairs(list) do
    if ours(e.pr) and e.pr.state == 'OPEN' then
      return e.pr
    end
  end
  for _, e in ipairs(list) do
    if ours(e.pr) and (not accept or accept(e.pr)) then
      return e.pr
    end
  end
end

---Decode `gh api graphql` output. Returns data (may be partial) and a list of error messages.
---@return table? data, string[] errors
function M.decode(stdout)
  local ok, obj = pcall(vim.json.decode, stdout or '', { luanil = { object = true, array = true } })
  if not ok or type(obj) ~= 'table' then
    return nil, { 'unparsable output: ' .. tostring(stdout or ''):sub(1, 200) }
  end
  local errs = {}
  for _, e in ipairs(type(obj.errors) == 'table' and obj.errors or {}) do
    errs[#errs + 1] = type(e) == 'table' and tostring(e.message or e.type) or tostring(e)
  end
  if type(obj.message) == 'string' then -- REST-style error body (e.g. rate limit)
    errs[#errs + 1] = obj.message
  end
  return type(obj.data) == 'table' and obj.data or nil, errs
end

-- ---------------------------------------------------------------------------
-- Fetching and cache
-- ---------------------------------------------------------------------------

---Cache per queried repo: { at = ms, failed? = reason, branches = { [branch] = revuey.PR[] } }.
---A failure keeps the last good `branches` (shown as stale) until a fetch works.
M.cache = {}

---Is a commit an ancestor of (or equal to) a tip? `oid .. ' ' .. tip` -> boolean (immutable
---facts, kept for the session).
M.ancestry = {}

---Clock in ms (tests replace it).
function M.now()
  return vim.uv.hrtime() / 1e6
end

local function opts()
  local o = require('revuey.config').options.forge or {}
  return {
    enabled = o.enabled ~= false,
    ttl = (o.ttl or 60) * 1000,
    timeout = (o.timeout or 15) * 1000,
    cmd = o.cmd or 'gh',
    hosts = o.hosts or {},
    -- review threads of open PRs, shown inline (`forge.threads = false` or `{enabled = false}`)
    threads = o.enabled ~= false and o.threads ~= false and not (type(o.threads) == 'table' and o.threads.enabled == false),
  }
end
M.options = opts

local function fresh(entry, branch, ttl)
  return entry and (M.now() - entry.at) < ttl and (entry.failed or entry.branches[branch] ~= nil)
end

local function each_lookup(targets, fn)
  for _, t in pairs(targets) do
    for _, c in ipairs(t.candidates) do
      for _, repo in ipairs(c.repos) do
        fn(repo, c.branch, c)
      end
    end
  end
end

---Is every target answered by the cache (results or a recent failure) within the TTL?
---@param targets table<any, revuey.ForgeTarget>
function M.is_fresh(targets)
  local ttl, ok = opts().ttl, true
  each_lookup(targets, function(repo, branch)
    if not fresh(M.cache[M.repo_key(repo)], branch, ttl) then
      ok = false
    end
  end)
  return ok
end

---Does a closed/merged PR belong to this branch? Its head commit and the tip must be on one line:
---the head in the tip's history, or the tip in the head's (the local branch is behind commits
---made on GitHub, "Update branch" or a suggestion). A new branch reusing an old name must not
---show the old PR; an unknown commit counts as unrelated. Needs `check_heads` first.
local function accept_for(t)
  return function(pr)
    return t.tip ~= nil and pr.head_oid ~= nil and M.ancestry[pr.head_oid .. ' ' .. t.tip] == true
  end
end

local function prs_for(c)
  local all, seen = {}, {}
  for _, repo in ipairs(c.repos) do
    local e = M.cache[M.repo_key(repo)]
    for _, pr in ipairs(e and e.branches[c.branch] or {}) do
      if not seen[pr.url] then
        seen[pr.url] = true
        all[#all + 1] = pr
      end
    end
  end
  return all
end

---The PR for a target from the cache (first candidate branch with one), or nil (none, failed,
---not fetched yet). The second value is true when it comes from data a later fetch failed to
---renew (stale).
---@return revuey.PR?, boolean?
function M.get(t)
  if not t then
    return nil
  end
  for _, c in ipairs(t.candidates) do
    local pr = M.pick(prs_for(c), c.head_owner, accept_for(t))
    if pr then
      local stale = false
      for _, repo in ipairs(c.repos) do
        local e = M.cache[M.repo_key(repo)]
        stale = stale or (e ~= nil and e.failed ~= nil)
      end
      return pr, stale
    end
  end
end

---Check the head commits of cached closed/merged PRs against the targets' tips (`git
---merge-base --is-ancestor`, run concurrently, remembered). Call inside git.async.
function M.check_heads(root, targets)
  local todo, seen = {}, {}
  for _, t in pairs(targets) do
    if t.tip then
      for _, c in ipairs(t.candidates) do
        for _, pr in ipairs(prs_for(c)) do
          local key = pr.head_oid and (pr.head_oid .. ' ' .. t.tip)
          if pr.state ~= 'OPEN' and key and M.ancestry[key] == nil and not seen[key] and #todo < 50 then
            seen[key] = true
            todo[#todo + 1] = { key = key, oid = pr.head_oid, tip = t.tip }
          end
        end
      end
    end
  end
  local fns = {}
  for i, p in ipairs(todo) do
    fns[i] = function()
      -- non-zero for "not an ancestor" and for a commit this clone has never seen
      return git.git({ 'merge-base', '--is-ancestor', p.oid, p.tip }, root) ~= nil
        or git.git({ 'merge-base', '--is-ancestor', p.tip, p.oid }, root) ~= nil
    end
  end
  for i, res in ipairs(git.all(fns)) do
    M.ancestry[todo[i].key] = res[1] and res[2] == true
  end
end

---Run one `gh api graphql` call (async inside git.async), with `forge.timeout`. `on_job` gets
---the vim.SystemObj (to kill it when the review closes). Returns data, or nil and a reason.
---@return table? data, string? err
function M.run_graphql(query, host, on_job)
  local o = opts()
  local cmd = { o.cmd, 'api', 'graphql' }
  if host and host ~= 'github.com' then
    vim.list_extend(cmd, { '--hostname', host })
  end
  vim.list_extend(cmd, { '-f', 'query=' .. query })
  local sysopts = { text = true, timeout = o.timeout, env = { GH_PROMPT_DISABLED = '1', GH_NO_UPDATE_NOTIFIER = '1' } }
  local co = coroutine.running()
  local res
  if co then
    local ok, obj = pcall(vim.system, cmd, sysopts, function(r)
      vim.schedule(function()
        git.resume(co, r)
      end)
    end)
    if not ok then
      return nil, ('%s could not run: %s'):format(o.cmd, tostring(obj))
    end
    if on_job then
      on_job(obj)
    end
    res = coroutine.yield()
  else
    local ok, obj = pcall(vim.system, cmd, sysopts)
    if not ok then
      return nil, ('%s could not run: %s'):format(o.cmd, tostring(obj))
    end
    res = obj:wait()
  end
  if res.code == 124 then
    return nil, ('%s timed out after %gs'):format(o.cmd, o.timeout / 1000)
  end
  local data, errs = M.decode(res.stdout)
  if res.code ~= 0 then
    local why = vim.trim(res.stderr or '')
    if why == '' then
      why = table.concat(errs, '; ')
    end
    if not data then
      return nil, ('%s exited %d: %s'):format(o.cmd, res.code, why)
    end
    log.write('forge', ('%s exited %d with partial data: %s'):format(o.cmd, res.code, why))
  elseif #errs > 0 then
    log.write('forge', 'graphql errors: ' .. table.concat(errs, '; '))
  end
  if not data then
    return nil, table.concat(errs, '; ')
  end
  return data
end

---Fetch PRs for targets unless the cache answers all of them (or `o.force`): one `gh api
---graphql` call per host (in practice one per refresh) for every (repo, branch) pair. Call
---inside git.async. `o.alive()` false after the call (the review closed, a newer lookup)
---drops the result: nothing is written. Returns true when it ran gh.
---@param targets table<any, revuey.ForgeTarget>
---@param o? {force?:boolean, alive?:fun():boolean, on_job?:fun(obj:vim.SystemObj)}
function M.fetch(targets, o)
  o = o or {}
  if not o.force and M.is_fresh(targets) then
    return false
  end
  local by_host, seen = {}, {}
  each_lookup(targets, function(repo, branch, c)
    local k = M.repo_key(repo) .. '\0' .. branch
    if not seen[k] then
      seen[k] = { repo = repo, branch = branch, parent = c.parent ~= false }
      by_host[repo.host] = by_host[repo.host] or {}
      table.insert(by_host[repo.host], seen[k])
    elseif c.parent ~= false then
      seen[k].parent = true
    end
  end)
  for host, list in pairs(by_host) do
    table.sort(list, function(a, b)
      return M.repo_key(a.repo) .. a.branch < M.repo_key(b.repo) .. b.branch
    end)
    local query, aliases = M.build_query(list)
    local data, err = M.run_graphql(query, host, o.on_job)
    if o.alive and not o.alive() then
      return true
    end
    local now = M.now()
    if not data then
      log.write('forge', 'PR lookup failed: ' .. tostring(err))
    end
    local touched = {}
    for _, p in ipairs(list) do
      local key = M.repo_key(p.repo)
      if not touched[key] then
        touched[key] = true
        local old = M.cache[key]
        -- results of other branches of this repo stay until their own TTL runs out; on failure
        -- the last good results stay too (shown as stale)
        M.cache[key] = { at = now, failed = not data and (err or 'failed') or nil, branches = old and old.branches or {} }
      end
    end
    for alias, p in pairs(data and aliases or {}) do
      local key = M.repo_key(p.repo)
      local repo = data[alias]
      local prs = {}
      if type(repo) == 'table' then
        for _, n in ipairs(nodes(repo.pullRequests)) do
          prs[#prs + 1] = M.normalize(n, key)
        end
        local parent = repo.parent
        if type(parent) == 'table' and type(parent.nameWithOwner) == 'string' then
          local pkey = (p.repo.host .. '/' .. parent.nameWithOwner):lower()
          for _, n in ipairs(nodes(parent.pullRequests)) do
            prs[#prs + 1] = M.normalize(n, pkey)
          end
        end
      end
      M.cache[key].branches[p.branch] = prs
    end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Review threads of open PRs
-- ---------------------------------------------------------------------------

---@class revuey.ForgeComment  one comment of a review thread
---@field id string            GraphQL node id (PullRequestReviewComment)
---@field database_id? integer REST id (replies through the REST API need it)
---@field url string
---@field body string
---@field author string        login ('ghost' for a deleted account)
---@field created_at string    ISO time
---@field edited_at? string
---@field state string         SUBMITTED, or PENDING (the viewer's own unsubmitted review)
---@field diff_hunk? string    the PR diff's hunk up to the commented line
---@field reply_to? string

---@class revuey.ForgeThread
---@field id string            GraphQL node id (PullRequestReviewThread)
---@field resolved boolean
---@field outdated boolean     GitHub: the commented lines changed since (line is then nil)
---@field resolved_by? string
---@field path string
---@field line? integer        end line on `side` in the PR's current diff (nil when outdated)
---@field start_line? integer  first line of a multi-line thread
---@field original_line? integer       the same in the commit it was made on
---@field original_start_line? integer
---@field side 'RIGHT'|'LEFT'
---@field start_side? 'RIGHT'|'LEFT'
---@field subject 'LINE'|'FILE'
---@field comments revuey.ForgeComment[]  oldest first
---@field total integer        comments GitHub has (more than `comments` only when truncated)

M.THREAD_PAGE = 50 -- threads per page
M.COMMENT_PAGE = 20 -- comments per thread in the first page (most threads are short)
M.COMMENT_MORE_PAGE = 100 -- comments per page when a thread has more
M.THREAD_ROUNDS = 10 -- pagination rounds per fetch (one gh call each) before giving up

local THREAD_FIELDS = [[
fragment thread on PullRequestReviewThread {
  id isResolved isOutdated path line startLine originalLine originalStartLine diffSide startDiffSide subjectType
  resolvedBy { login }
  comments(first: %d) { totalCount pageInfo { hasNextPage endCursor } nodes { ...comment } }
}]]
local COMMENT_FIELDS = [[
fragment comment on PullRequestReviewComment {
  id databaseId url body createdAt lastEditedAt state diffHunk
  author { login }
  replyTo { id }
}]]

---"host/owner/name" (a PR's `repo`) -> host, owner, name.
local function split_repo(key)
  local host, owner, name = (key or ''):match('^(.-)/([^/]+)/([^/]+)$')
  return host, owner, name
end

---Cache key of a PR's threads.
function M.thread_key(pr)
  return pr.repo .. '#' .. pr.number
end

---One query for several pages: `{kind = 'threads', repo, number, after?}` asks a PR's review
---threads (each with its first comments), `{kind = 'comments', thread, after}` the next comments
---of one thread (by node id). Returns the query and alias -> request.
---@return string query, table<string, table> aliases
function M.build_threads_query(reqs)
  local parts, aliases, threads = { 'query {' }, {}, false
  local function after(c)
    return c and (', after: ' .. lit(c)) or ''
  end
  for i, r in ipairs(reqs) do
    if r.kind == 'threads' then
      threads = true
      local alias = 't' .. i
      aliases[alias] = r
      parts[#parts + 1] = ('  %s: repository(owner: %s, name: %s) { pullRequest(number: %d) { headRefOid reviewThreads(first: %d%s) { pageInfo { hasNextPage endCursor } nodes { ...thread } } } }')
        :format(alias, lit(r.owner), lit(r.name), r.number, M.THREAD_PAGE, after(r.after))
    else
      local alias = 'c' .. i
      aliases[alias] = r
      parts[#parts + 1] = ('  %s: node(id: %s) { ... on PullRequestReviewThread { comments(first: %d%s) { pageInfo { hasNextPage endCursor } nodes { ...comment } } } }')
        :format(alias, lit(r.thread), M.COMMENT_MORE_PAGE, after(r.after))
    end
  end
  parts[#parts + 1] = '}'
  -- GraphQL refuses unused fragments: the thread fragment only when threads are asked
  if threads then
    parts[#parts + 1] = THREAD_FIELDS:format(M.COMMENT_PAGE)
  end
  parts[#parts + 1] = COMMENT_FIELDS
  return table.concat(parts, '\n'), aliases
end

local function int(v)
  return type(v) == 'number' and math.floor(v) or nil
end

local function page(conn)
  local p = type(conn) == 'table' and type(conn.pageInfo) == 'table' and conn.pageInfo
  if p and p.hasNextPage == true and type(p.endCursor) == 'string' then
    return p.endCursor
  end
end

---Map a PullRequestReviewComment node.
---@return revuey.ForgeComment?
function M.normalize_comment(n)
  if type(n) ~= 'table' or type(n.id) ~= 'string' then
    return nil
  end
  return {
    id = n.id,
    database_id = int(n.databaseId),
    url = str(n.url) or '',
    body = str(n.body) or '',
    author = type(n.author) == 'table' and str(n.author.login) or 'ghost',
    created_at = str(n.createdAt) or '',
    edited_at = str(n.lastEditedAt),
    state = str(n.state) or 'SUBMITTED',
    diff_hunk = str(n.diffHunk),
    reply_to = type(n.replyTo) == 'table' and str(n.replyTo.id) or nil,
  }
end

---Map a PullRequestReviewThread node (with its first page of comments). The second value is the
---cursor of the thread's next comments, when it has more.
---@return revuey.ForgeThread?, string?
function M.normalize_thread(n)
  if type(n) ~= 'table' or type(n.id) ~= 'string' or type(n.path) ~= 'string' then
    return nil
  end
  local t = {
    id = n.id,
    resolved = n.isResolved == true,
    outdated = n.isOutdated == true,
    resolved_by = type(n.resolvedBy) == 'table' and str(n.resolvedBy.login) or nil,
    path = n.path,
    line = int(n.line),
    start_line = int(n.startLine),
    original_line = int(n.originalLine),
    original_start_line = int(n.originalStartLine),
    side = n.diffSide == 'LEFT' and 'LEFT' or 'RIGHT',
    start_side = (n.startDiffSide == 'LEFT' or n.startDiffSide == 'RIGHT') and n.startDiffSide or nil,
    subject = n.subjectType == 'FILE' and 'FILE' or 'LINE',
    comments = {},
    total = 0,
  }
  for _, c in ipairs(nodes(n.comments)) do
    t.comments[#t.comments + 1] = M.normalize_comment(c)
  end
  t.total = type(n.comments) == 'table' and int(n.comments.totalCount) or #t.comments
  return t, page(n.comments)
end

---Threads of a PR per cache key: { at = ms, threads? = revuey.ForgeThread[], sig?, failed? =
---reason, truncated? }. A failure keeps the last good threads (shown as they were).
M.threads_cache = {}

---Are the threads of every PR in `prs` cached (or failed) within the TTL?
function M.threads_fresh(prs)
  local ttl = opts().ttl
  for _, pr in ipairs(prs) do
    local e = M.threads_cache[M.thread_key(pr)]
    if not e or (M.now() - e.at) >= ttl then
      return false
    end
  end
  return true
end

---Cached threads of a PR (oldest first, as GitHub lists them), or nil when never fetched; the
---second value is true when a later fetch failed (stale), the third when the pages were cut
---(THREAD_ROUNDS).
---@return revuey.ForgeThread[]?, boolean?, boolean?
function M.threads_for(pr)
  local e = pr and M.threads_cache[M.thread_key(pr)]
  if not e then
    return nil
  end
  return e.threads, e.failed ~= nil, e.truncated == true
end

---The head commit GitHub numbered a PR's cached threads against (`headRefOid` of the threads
---fetch, not of the PR lookup: the two are fetched and expire separately, and a failed threads
---refetch keeps older threads). nil when unknown or mixed.
---@return string?
function M.threads_head(pr)
  local e = pr and M.threads_cache[M.thread_key(pr)]
  return e and e.head_oid or nil
end

---Fetch the review threads of `prs` unless cached within the TTL (or `o.force`): one `gh api
---graphql` call per host per round, a round asking every PR's next page of threads and every
---long thread's next page of comments, until no page is left (at most THREAD_ROUNDS rounds;
---what was read is kept and the truncation logged). Call inside git.async. A failed round
---keeps each PR's last good threads; `o.alive()` false after a call drops everything. Returns
---true when it ran gh.
---@param prs revuey.PR[]
---@param o? {force?:boolean, alive?:fun():boolean, on_job?:fun(obj:vim.SystemObj)}
function M.fetch_threads(prs, o)
  o = o or {}
  local by_host, seen = {}, {}
  for _, pr in ipairs(prs) do
    local key = M.thread_key(pr)
    local e = M.threads_cache[key]
    local stale = not e or (M.now() - e.at) >= opts().ttl
    local host, owner, name = split_repo(pr.repo)
    if host and not seen[key] and (o.force or stale) then
      seen[key] = true
      by_host[host] = by_host[host] or {}
      table.insert(by_host[host], { key = key, owner = owner, name = name, number = pr.number, threads = {}, done = false })
    end
  end
  if not next(by_host) then
    return false
  end
  for host, list in pairs(by_host) do
    table.sort(list, function(a, b)
      return a.key < b.key
    end)
    local more = {} -- {thread, after}: threads with further comments
    local err
    for round = 1, M.THREAD_ROUNDS + 1 do
      local reqs = {}
      for _, p in ipairs(list) do
        if not p.done then
          reqs[#reqs + 1] = { kind = 'threads', owner = p.owner, name = p.name, number = p.number, after = p.after, p = p }
        end
      end
      for _, m in ipairs(more) do
        if not m.p.failed then
          reqs[#reqs + 1] = { kind = 'comments', thread = m.thread.id, after = m.after, t = m.thread, p = m.p }
        end
      end
      if #reqs == 0 then
        break
      end
      if round > M.THREAD_ROUNDS then
        for _, r in ipairs(reqs) do
          r.p.truncated = true
        end
        log.write('forge', ('review threads: stopped after %d pages; %d requests left'):format(M.THREAD_ROUNDS, #reqs))
        break
      end
      local query, aliases = M.build_threads_query(reqs)
      local data, e = M.run_graphql(query, host, o.on_job)
      if o.alive and not o.alive() then
        return true
      end
      if not data then
        err = e or 'failed'
        log.write('forge', 'review threads lookup failed: ' .. tostring(err))
        break
      end
      more = {}
      for alias, r in pairs(aliases) do
        local v = data[alias]
        local p = r.p
        if r.kind == 'threads' then
          local conn = type(v) == 'table' and type(v.pullRequest) == 'table' and type(v.pullRequest.reviewThreads) == 'table'
            and v.pullRequest.reviewThreads
          if not conn then
            -- a page came back null (partial data: a timeout, a resource limit, a transient
            -- NOT_FOUND; the PR lookup just found this PR open): not the PR's threads, so the
            -- PR keeps its last ones (a first-ever fetch keeps what it read, marked cut)
            p.failed, p.done = true, true
          else
            p.pages = (p.pages or 0) + 1
            -- the head commit GitHub numbered these pages against; pages from different
            -- heads (a push mid-fetch) leave the threads with no head to trust
            local oid = str(v.pullRequest.headRefOid)
            if p.pages == 1 then
              p.head_oid = oid or false
            elseif p.head_oid ~= oid then
              p.head_oid = false
            end
            for _, n in ipairs(nodes(conn)) do
              local t, cursor = M.normalize_thread(n)
              if t then
                p.threads[#p.threads + 1] = t
                if cursor then
                  more[#more + 1] = { thread = t, after = cursor, p = p }
                end
              end
            end
            p.after = page(conn)
            p.done = p.after == nil
          end
        else
          local conn = type(v) == 'table' and type(v.comments) == 'table' and v.comments
          if not conn then
            p.failed, p.done = true, true -- a thread's further comments came back null: as above
          else
            for _, n in ipairs(nodes(conn)) do
              r.t.comments[#r.t.comments + 1] = M.normalize_comment(n)
            end
            local cursor = page(conn)
            if cursor then
              more[#more + 1] = { thread = r.t, after = cursor, p = p }
            end
          end
        end
      end
      -- pairs() order is not stable: keep the threads' own order for the next round
      table.sort(more, function(a, b)
        return a.thread.id < b.thread.id
      end)
    end
    local now = M.now()
    -- PRs still waiting for comment pages when a round failed are not complete
    local pending = {}
    for _, m in ipairs(more) do
      pending[m.p] = true
    end
    for _, p in ipairs(list) do
      local old = M.threads_cache[p.key]
      -- a transport error in a later round spares PRs that were already complete
      local complete = p.done and not p.failed and not pending[p]
      if p.failed or (err and not complete) then
        if p.failed then
          log.write('forge', ('review threads of %s: a page came back empty; keeping the last threads'):format(p.key))
        end
        local keep = old and old.threads
        local partial = not keep and (p.pages or 0) > 0 and p.threads or nil
        M.threads_cache[p.key] = {
          at = now,
          failed = err or 'incomplete pages',
          threads = keep or partial,
          sig = keep and old.sig or (partial and vim.fn.sha256(vim.json.encode(partial)):sub(1, 16)) or nil,
          truncated = (keep and old.truncated) or (partial and true) or nil,
          -- kept threads keep the head they were numbered against
          head_oid = (keep and old.head_oid) or (partial and p.head_oid) or nil,
        }
      else
        M.threads_cache[p.key] = {
          at = now,
          threads = p.threads,
          truncated = p.truncated,
          head_oid = p.head_oid,
          sig = vim.fn.sha256(vim.json.encode(p.threads)):sub(1, 16),
        }
      end
    end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Display models (pure; panel.lua / forge_view.lua draw them)
-- ---------------------------------------------------------------------------

M.GLYPH_APPROVED, M.GLYPH_CHANGES, M.GLYPH_PENDING, M.GLYPH_NONE = '✓', '✗', '●', '○'

---Compact row model: `#123` plus a review glyph, or a dim state marker.
---@param pr revuey.PR
---@return {number:string, number_hl:string, glyph?:string, glyph_hl?:string, marker?:string, marker_hl?:string}
function M.row(pr)
  local m = { number = '#' .. pr.number, number_hl = 'RevueyForgeNumber' }
  if pr.state == 'MERGED' or pr.state == 'CLOSED' then
    m.number_hl = 'RevueyForgeDim'
    m.marker, m.marker_hl = pr.state == 'MERGED' and 'merged' or 'closed', pr.state == 'MERGED' and 'RevueyForgeMerged' or 'RevueyForgeClosed'
  elseif pr.draft then
    m.number_hl = 'RevueyForgeDim'
    m.marker, m.marker_hl = 'draft', 'RevueyForgeDraft'
  elseif pr.review_decision == 'APPROVED' then
    m.glyph, m.glyph_hl = M.GLYPH_APPROVED, 'RevueyForgeApproved'
  elseif pr.review_decision == 'CHANGES_REQUESTED' then
    m.glyph, m.glyph_hl = M.GLYPH_CHANGES, 'RevueyForgeChanges'
  elseif pr.review_decision == 'REVIEW_REQUIRED' then
    m.glyph, m.glyph_hl = M.GLYPH_PENDING, 'RevueyForgePending'
  else
    m.glyph, m.glyph_hl = M.GLYPH_NONE, 'RevueyForgeNone'
  end
  return m
end

local DECISION = {
  APPROVED = { 'approved', M.GLYPH_APPROVED, 'RevueyForgeApproved' },
  CHANGES_REQUESTED = { 'changes requested', M.GLYPH_CHANGES, 'RevueyForgeChanges' },
  REVIEW_REQUIRED = { 'review required', M.GLYPH_PENDING, 'RevueyForgePending' },
}
local REVIEW = {
  APPROVED = { 'approved', M.GLYPH_APPROVED, 'RevueyForgeApproved' },
  CHANGES_REQUESTED = { 'changes requested', M.GLYPH_CHANGES, 'RevueyForgeChanges' },
  COMMENTED = { 'commented', '○', 'RevueyForgePending' },
  DISMISSED = { 'dismissed', '○', 'RevueyForgeDim' },
  PENDING = { 'pending', '●', 'RevueyForgePending' },
}

---"12 passed, 1 failed, 2 pending" (empty parts left out; nil when there are no checks).
function M.checks_text(c)
  if not c or c.total == 0 then
    return nil
  end
  local parts = {}
  if c.success > 0 then
    parts[#parts + 1] = c.success .. ' passed'
  end
  if c.failure > 0 then
    parts[#parts + 1] = c.failure .. ' failed'
  end
  if c.pending > 0 then
    parts[#parts + 1] = c.pending .. ' pending'
  end
  return table.concat(parts, ', ')
end

---Detail model for the panel section: a list of `{label?, text, hl}` items, in display order.
---`parent` is the layer's parent in revuey's stack (a branch name as GitHub sees it), when
---there is a stack: a PR whose base differs gets a warning.
---`threads`: counts of the PR's review threads ({open, resolved, outdated}), when fetched.
---@param pr revuey.PR
---@param parent? string
---@param threads? {open:integer, resolved:integer, outdated:integer, truncated?:boolean, stale?:boolean}
---@return {kind:string, text:string, hl:string, glyph?:string}[]
function M.detail(pr, parent, threads)
  local out = {}
  local function add(kind, text, hl, glyph)
    out[#out + 1] = { kind = kind, text = text, hl = hl, glyph = glyph }
  end
  add('title', pr.title, 'RevueyForgeTitle')
  local state = pr.state == 'MERGED' and 'merged' or pr.state == 'CLOSED' and 'closed' or 'open'
  local meta = (pr.author and ('by ' .. pr.author .. ' · ') or '') .. state .. (pr.draft and ' · draft' or '')
  add('meta', meta, 'RevueyForgeDim')
  local d = DECISION[pr.review_decision or '']
  if d then
    add('decision', d[1], d[3], d[2])
  else
    add('decision', 'no review decision', 'RevueyForgeNone', M.GLYPH_NONE)
  end
  for _, r in ipairs(pr.reviews) do
    local v = REVIEW[r.state] or { r.state:lower(), '○', 'RevueyForgeDim' }
    add('review', r.author .. ' ' .. v[1], v[3], v[2])
  end
  for _, who in ipairs(pr.requested) do
    add('requested', who .. ' requested', 'RevueyForgePending', '○')
  end
  local checks = M.checks_text(pr.checks)
  if checks then
    local hl = pr.checks.failure > 0 and 'RevueyForgeChanges' or pr.checks.pending > 0 and 'RevueyForgePending' or 'RevueyForgeApproved'
    add('checks', 'checks: ' .. checks, hl)
  else
    add('checks', 'checks: none', 'RevueyForgeDim')
  end
  if threads and threads.open + threads.resolved > 0 then
    local parts = { threads.open .. ' open' }
    if threads.resolved > 0 then
      parts[#parts + 1] = threads.resolved .. ' resolved'
    end
    if threads.outdated > 0 then
      parts[#parts + 1] = threads.outdated .. ' outdated'
    end
    if threads.truncated then
      parts[#parts + 1] = 'more on GitHub'
    end
    add('threads', 'threads: ' .. table.concat(parts, ', ') .. (threads.stale and ' (stale)' or ''), threads.open > 0 and 'RevueyForgePending' or 'RevueyForgeDim')
  end
  if pr.state == 'OPEN' then
    local mg = pr.mergeable == 'MERGEABLE' and { 'mergeable', 'RevueyForgeDim' }
      or pr.mergeable == 'CONFLICTING' and { 'conflicts with base', 'RevueyForgeChanges' }
      or { 'mergeable: unknown', 'RevueyForgeDim' }
    add('mergeable', mg[1], mg[2])
  end
  add('base', 'base: ' .. pr.base, 'RevueyForgeDim')
  if parent and pr.state == 'OPEN' and pr.base ~= '' and pr.base ~= parent then
    add('base_mismatch', ('GitHub base %s, stack parent %s'):format(pr.base, parent), 'RevueyForgeWarn', '⚠')
  end
  return out
end

return M
