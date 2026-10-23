-- GitHub pull request lookup for review branches and stack layers. No UI: remote parsing, the
-- batched GraphQL query, response mapping, a per-repo TTL cache, and the row/detail models the
-- panel draws (forge_view.lua). Shells out to the user's own `gh` (assumed authenticated; revuey
-- never reads credentials). Failures (gh missing, non-zero exit, bad JSON, offline, rate
-- limits) are never shown: the lookup yields nothing and the reason goes to revuey.log.
--
-- Reusable for later forge work (showing review threads, posting reviews): `remote_info`,
-- `parse_remote_url`, `targets` and `run_graphql` know nothing about the panel.
local git = require('revuey.git')
local stack_mod = require('revuey.stack')
local log = require('revuey.log')

local M = {}

---@class revuey.ForgeRepo
---@field host string     web host (github.com, or an enterprise host)
---@field owner string
---@field name string

---@class revuey.ForgeTarget  what to look up for one layer (or the plain review branch)
---@field branch string       head branch name on the remote (remote prefix stripped)
---@field head_owner? string  owner of the repo the branch lives in (filters fork PRs)
---@field repos revuey.ForgeRepo[] repos to search, most likely first (upstream, then the fork)
---@field remote? string      remote the branch comes from

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
---@field head_owner? string
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

---Remotes and branch upstream config of a repo, via plain git (`git remote`, `git remote
---get-url`, `git config --get-regexp`). In a coroutine (git.async) the calls do not block.
---@return {names:string[], remotes:table<string, {url:string, repo?:revuey.ForgeRepo}>, branches:table<string, {remote?:string, merge?:string}>}
function M.remote_info(root, hosts)
  local info = { names = git.remotes(root), remotes = {}, branches = {} }
  local fns = {}
  for i, name in ipairs(info.names) do
    fns[i] = function()
      return vim.trim(git.git({ 'remote', 'get-url', name }, root) or '')
    end
  end
  for i, res in ipairs(git.all(fns)) do
    local url = res[1] and res[2] or ''
    info.remotes[info.names[i]] = { url = url, repo = url ~= '' and M.parse_remote_url(url, hosts) or nil }
  end
  local cfg = git.git({ 'config', '--get-regexp', '^branch\\..*\\.(remote|merge)$' }, root) or ''
  for line in cfg:gmatch('[^\n]+') do
    local b, key, val = line:match('^branch%.(.+)%.(%a+) (.*)$')
    if b then
      info.branches[b] = info.branches[b] or {}
      info.branches[b][key] = val
    end
  end
  return info
end

---Remote a branch name belongs to: `origin/main` -> origin, a local branch -> its upstream's
---remote. nil when neither.
local function remote_of(name, info)
  local remote = stack_mod.split_remote(name, info.names)
  if remote and info.remotes[remote] then
    return remote, name:sub(#remote + 2)
  end
  local b = info.branches[name]
  if b and b.remote and b.remote ~= '.' and info.remotes[b.remote] then
    local merge = b.merge and b.merge:gsub('^refs/heads/', '') or name
    return b.remote, merge
  end
end

---The remote PRs are opened against: the trunk's remote, else `origin`, else the only GitHub
---remote. nil when there is no GitHub remote at all.
function M.base_remote(trunk, info)
  local r = trunk and remote_of(trunk, info)
  if r and info.remotes[r].repo then
    return r
  end
  if info.remotes.origin and info.remotes.origin.repo then
    return 'origin'
  end
  local gh = {}
  for _, n in ipairs(info.names) do
    if info.remotes[n].repo then
      gh[#gh + 1] = n
    end
  end
  return #gh == 1 and gh[1] or nil
end

---Lookup target for one branch (a layer name, `origin/x` for a remote layer).
---@param name string
---@param remote_layer? boolean the name is a remote-tracking branch
---@return revuey.ForgeTarget?
function M.target(name, remote_layer, base, info)
  if not base or name == '' or name == 'HEAD' then
    return nil
  end
  local base_repo = info.remotes[base].repo
  local remote, branch = remote_of(name, info)
  if remote_layer and not remote then
    remote, branch = stack_mod.split_remote(name, info.names)
  end
  if not remote then
    remote, branch = base, name
  end
  local own = info.remotes[remote] and info.remotes[remote].repo
  local repos = { base_repo }
  if own and M.repo_key(own) ~= M.repo_key(base_repo) then
    -- a fork: its PR is usually in the base repo (head owner = the fork's owner), else in the fork
    repos[2] = own
  end
  return { branch = branch, head_owner = (own or base_repo).owner, repos = repos, remote = remote }
end

---Targets for a review: one per stack layer (by layer name), or `['']` for a plain review.
---@return table<string, revuey.ForgeTarget>
function M.targets(review, info)
  local out = {}
  local trunk = review.stack and review.stack.trunk or review.base
  local base = M.base_remote(trunk, info)
  if not base then
    return out
  end
  if review.stack then
    for _, l in ipairs(review.stack.layers) do
      out[l.name] = M.target(l.name, l.remote, base, info)
    end
  else
    out[''] = M.target(review.branch, false, base, info)
  end
  return out
end

---Branch name of a stack parent as GitHub sees it (remote prefix stripped; a local branch
---tracking another name uses that name).
function M.branch_name(name, info)
  local _, branch = remote_of(name, info or { names = {}, remotes = {}, branches = {} })
  return branch or name
end

-- ---------------------------------------------------------------------------
-- Query and response
-- ---------------------------------------------------------------------------

local PR_FIELDS = [[
fragment pr on PullRequest {
  number title url state isDraft
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
---each. Returns the query and alias -> pair.
---@param pairs {repo:revuey.ForgeRepo, branch:string}[]
---@return string query, table<string, {repo:revuey.ForgeRepo, branch:string}> aliases
function M.build_query(pairs)
  local parts, aliases = { 'query {' }, {}
  for i, p in ipairs(pairs) do
    local alias = 'l' .. i
    aliases[alias] = p
    parts[#parts + 1] = ('  %s: repository(owner: %s, name: %s) { pullRequests(headRefName: %s, first: 10, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { ...pr } } }')
      :format(alias, lit(p.repo.owner), lit(p.repo.name), lit(p.branch))
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

---The PR for a branch among candidates (newest first): OPEN first, then the most recent
---MERGED/CLOSED. With `head_owner`, only PRs whose head repo has that owner (fork PRs of
---other people from a branch of the same name are not ours).
---@param prs revuey.PR[]
---@return revuey.PR?
function M.pick(prs, head_owner)
  local function ours(pr)
    return not head_owner or not pr.head_owner or pr.head_owner:lower() == head_owner:lower()
  end
  for _, pr in ipairs(prs) do
    if ours(pr) and pr.state == 'OPEN' then
      return pr
    end
  end
  for _, pr in ipairs(prs) do
    if ours(pr) then
      return pr
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

---Cache per repo key: { at = ms, failed? = reason, branches = { [branch] = revuey.PR[] } }.
M.cache = {}

---Clock in ms (tests replace it).
function M.now()
  return vim.uv.hrtime() / 1e6
end

local function opts()
  local o = require('revuey.config').options.forge or {}
  return { enabled = o.enabled ~= false, ttl = (o.ttl or 60) * 1000, cmd = o.cmd or 'gh', hosts = o.hosts or {} }
end
M.options = opts

local function fresh(entry, branch, ttl)
  return entry and (M.now() - entry.at) < ttl and (entry.failed or entry.branches[branch] ~= nil)
end

---Is every target answered by the cache (results or a recent failure) within the TTL?
---@param targets table<any, revuey.ForgeTarget>
function M.is_fresh(targets)
  local ttl = opts().ttl
  for _, t in pairs(targets) do
    for _, repo in ipairs(t.repos) do
      if not fresh(M.cache[M.repo_key(repo)], t.branch, ttl) then
        return false
      end
    end
  end
  return true
end

---The PR for a target from the cache, or nil (none, failed, not fetched yet).
---@return revuey.PR?
function M.get(t)
  if not t then
    return nil
  end
  local all = {}
  for _, repo in ipairs(t.repos) do
    local e = M.cache[M.repo_key(repo)]
    for _, pr in ipairs(e and e.branches[t.branch] or {}) do
      all[#all + 1] = pr
    end
  end
  return M.pick(all, t.head_owner)
end

---Run one `gh api graphql` call (async inside git.async). Returns data, or nil and a reason.
---@return table? data, string? err
function M.run_graphql(query, host)
  local o = opts()
  local cmd = { o.cmd, 'api', 'graphql' }
  if host and host ~= 'github.com' then
    vim.list_extend(cmd, { '--hostname', host })
  end
  vim.list_extend(cmd, { '-f', 'query=' .. query })
  local ok, res = pcall(git.system, cmd, { text = true, env = { GH_PROMPT_DISABLED = '1', GH_NO_UPDATE_NOTIFIER = '1' } })
  if not ok then
    return nil, ('%s could not run: %s'):format(o.cmd, tostring(res))
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

---Fetch PRs for targets unless the cache answers all of them: one `gh api graphql` call per
---host (in practice one per refresh) for every (repo, branch) pair. Call inside git.async.
---Returns true when it ran gh (whether or not it worked).
---@param targets table<any, revuey.ForgeTarget>
function M.fetch(targets, force)
  if not force and M.is_fresh(targets) then
    return false
  end
  local by_host, seen = {}, {}
  for _, t in pairs(targets) do
    for _, repo in ipairs(t.repos) do
      local k = M.repo_key(repo) .. '\0' .. t.branch
      if not seen[k] then
        seen[k] = true
        by_host[repo.host] = by_host[repo.host] or {}
        table.insert(by_host[repo.host], { repo = repo, branch = t.branch })
      end
    end
  end
  for host, list in pairs(by_host) do
    table.sort(list, function(a, b)
      return M.repo_key(a.repo) .. a.branch < M.repo_key(b.repo) .. b.branch
    end)
    local query, aliases = M.build_query(list)
    local data, err = M.run_graphql(query, host)
    local now = M.now()
    local touched = {}
    for _, p in ipairs(list) do
      local key = M.repo_key(p.repo)
      if not touched[key] then
        touched[key] = true
        -- results of other branches of this repo stay until their own TTL runs out
        local old = M.cache[key]
        M.cache[key] = { at = now, branches = (old and not old.failed) and old.branches or {} }
      end
    end
    if not data then
      log.write('forge', 'PR lookup failed: ' .. tostring(err))
      for key in pairs(touched) do
        M.cache[key] = { at = now, failed = err or 'failed', branches = {} }
      end
    else
      for alias, p in pairs(aliases) do
        local key = M.repo_key(p.repo)
        local repo = data[alias]
        local prs = {}
        for _, n in ipairs(type(repo) == 'table' and nodes(repo.pullRequests) or {}) do
          prs[#prs + 1] = M.normalize(n, key)
        end
        M.cache[key].branches[p.branch] = prs
      end
    end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Display models (pure; panel.lua / forge_view.lua draw them)
-- ---------------------------------------------------------------------------

M.GLYPH_APPROVED, M.GLYPH_CHANGES, M.GLYPH_PENDING = '✓', '✗', '●'

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
  else
    m.glyph, m.glyph_hl = M.GLYPH_PENDING, 'RevueyForgePending'
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
---@param pr revuey.PR
---@param parent? string
---@return {kind:string, text:string, hl:string, glyph?:string}[]
function M.detail(pr, parent)
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
    add('decision', 'no review required', 'RevueyForgeDim', M.GLYPH_PENDING)
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
