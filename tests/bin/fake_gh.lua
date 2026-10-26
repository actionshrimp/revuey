-- Lua half of tests/bin/gh: records the call and answers `gh api graphql` from canned PRs.
local argv = { 'gh' }
for i = 1, #arg do
  argv[#argv + 1] = arg[i]
end
local log = os.getenv('REVUEY_FAKE_GH_LOG')
if log and log ~= '' then
  local out = assert(io.open(log, 'a'))
  out:write(vim.json.encode({ argv = argv, cwd = vim.uv.cwd() }), '\n')
  out:close()
end

-- `gh repo set-default --view`: offline, from `remote.<name>.gh-resolved` as gh reads it
-- (`base` names that remote's repo; any other value is the repo itself)
if argv[2] == 'repo' and argv[3] == 'set-default' and argv[4] == '--view' then
  local out = vim.system({ 'git', 'config', '--get-regexp', '^remote\\..*\\.gh-resolved$' }, { text = true }):wait().stdout or ''
  for line in out:gmatch('[^\n]+') do
    local remote, val = line:match('^remote%.(.-)%.gh%-resolved (.*)$')
    if val == 'base' then
      local url = vim.trim(vim.system({ 'git', 'remote', 'get-url', remote }, { text = true }):wait().stdout or '')
      val = url:gsub('%.git$', ''):match('([^/:]+/[^/:]+)$')
    end
    if val and val ~= '' then
      io.stdout:write(val, '\n')
      os.exit(0)
    end
  end
  io.stderr:write('no default repository has been set; use `gh repo set-default` to select one\n')
  os.exit(0)
end

local scenario = os.getenv('REVUEY_FAKE_GH') or 'ok'
if scenario == 'slow' then
  scenario = 'ok'
end
if log and log ~= '' then
  -- this process's pid (the shell script execs nvim), so tests can check it was stopped
  local fd = assert(io.open(log .. '.pid', 'w'))
  fd:write(tostring(vim.uv.os_getpid()))
  fd:close()
end
if scenario == 'fail' then
  io.stderr:write('error connecting to api.github.com\n')
  os.exit(1)
elseif scenario == 'garbage' then
  io.stdout:write('<html>not json</html>\n')
  os.exit(0)
elseif scenario == 'ratelimit' then
  io.stdout:write(vim.json.encode({ errors = { { type = 'RATE_LIMITED', message = 'API rate limit exceeded' } } }), '\n')
  io.stderr:write('gh: API rate limit exceeded\n')
  os.exit(1)
elseif scenario == 'errors' then
  io.stdout:write(vim.json.encode({ data = vim.NIL, errors = { { message = 'Something went wrong' } } }), '\n')
  os.exit(1)
end

if argv[2] ~= 'api' or argv[3] ~= 'graphql' then
  io.stderr:write('fake gh: unsupported command\n')
  os.exit(2)
end
local query
for i = 4, #argv do
  local q = argv[i]:match('^query=(.*)$')
  if q then
    query = q
  end
end
-- review threads (forge.fetch_threads): `REVUEY_FAKE_GH_THREADS` is a JSON file
-- { ["owner/name#N"] = { PullRequestReviewThread nodes, with `comments` a plain list of
-- PullRequestReviewComment nodes } }, `_null` = PRs that resolve to null; pages are cut by the
-- query's `first`/`after` (cursors are indices). `REVUEY_FAKE_GH_THREADS_SCENARIO` = fail |
-- errors | fail_after (only queries for later pages fail) applies to thread queries only (the
-- PR lookup still answers).
if query and (query:find('reviewThreads(', 1, true) or query:find(': node(id: ', 1, true)) then
  local tscen = os.getenv('REVUEY_FAKE_GH_THREADS_SCENARIO') or ''
  if tscen == 'fail' then
    io.stderr:write('error connecting to api.github.com\n')
    os.exit(1)
  elseif tscen == 'fail_after' and query:find('after: ', 1, true) then
    -- the first round answers; any later page fails (a dropped connection mid-pagination)
    io.stderr:write('error connecting to api.github.com\n')
    os.exit(1)
  elseif tscen == 'errors' then
    io.stdout:write(vim.json.encode({ data = vim.NIL, errors = { { message = 'Something went wrong' } } }), '\n')
    os.exit(1)
  end
  local all = {}
  local tfile = os.getenv('REVUEY_FAKE_GH_THREADS')
  if tfile and tfile ~= '' then
    local fd = assert(io.open(tfile, 'r'))
    all = vim.json.decode(fd:read('*a'))
    fd:close()
  end
  local tnull, tnull_after = {}, {}
  for _, k in ipairs(all._null or {}) do
    tnull[k] = true
  end
  -- `_null_after`: PRs whose pages after the first come back null (a timeout or resource
  -- limit on GitHub's side: partial data, exit 1)
  for _, k in ipairs(all._null_after or {}) do
    tnull_after[k] = true
  end
  local first_comments = tonumber(query:match('fragment thread on PullRequestReviewThread {.-comments%(first: (%d+)%)') or '100')
  local function cut(list, first, after)
    local from = (tonumber(after) or 0) + 1
    local out = {}
    for i = from, math.min(#list, from + first - 1) do
      out[#out + 1] = list[i]
    end
    local last = from + #out - 1
    return out, { hasNextPage = last < #list, endCursor = #out > 0 and tostring(last) or vim.NIL }
  end
  local function comments_conn(t, first, after)
    local list, info = cut(t.comments or {}, first, after)
    return { totalCount = #(t.comments or {}), pageInfo = info, nodes = list }
  end
  local data, errors = {}, {}
  local tpat = '(t%d+): repository%(owner: (%b""), name: (%b"")%) { pullRequest%(number: (%d+)%) { reviewThreads%(first: (%d+)([^)]*)%)'
  for alias, owner, name, number, first, rest in query:gmatch(tpat) do
    local key = vim.json.decode(owner) .. '/' .. vim.json.decode(name) .. '#' .. number
    local after = rest:match('after: (%b"")')
    after = after and vim.json.decode(after)
    if tnull_after[key] and after then
      data[alias] = vim.NIL
      errors[#errors + 1] = { type = 'TIMEOUT', message = 'Timeout on validation of query' }
    elseif tnull[key] then
      data[alias] = { pullRequest = vim.NIL }
      errors[#errors + 1] = { type = 'NOT_FOUND', message = 'Could not resolve to a PullRequest with the number of ' .. number .. '.' }
    else
      local list, info = cut(all[key] or {}, tonumber(first), after)
      local out = {}
      for _, t in ipairs(list) do
        local n = vim.deepcopy(t)
        n.comments = comments_conn(t, first_comments)
        out[#out + 1] = n
      end
      data[alias] = { pullRequest = { reviewThreads = { pageInfo = info, nodes = out } } }
    end
  end
  local cpat = '(c%d+): node%(id: (%b"")%) { %.%.%. on PullRequestReviewThread { comments%(first: (%d+)([^)]*)%)'
  for alias, id, first, rest in query:gmatch(cpat) do
    id = vim.json.decode(id)
    local after = rest:match('after: (%b"")')
    after = after and vim.json.decode(after)
    local found = vim.NIL
    for k, list in pairs(all) do
      if k:sub(1, 1) ~= '_' then
        for _, t in ipairs(list) do
          if t.id == id then
            found = { comments = comments_conn(t, tonumber(first), after) }
          end
        end
      end
    end
    data[alias] = found
  end
  io.stdout:write(vim.json.encode({ data = data, errors = #errors > 0 and errors or nil }), '\n')
  if #errors > 0 then
    io.stderr:write('gh: ' .. errors[1].message .. '\n')
    os.exit(1)
  end
  os.exit(0)
end

local prs = {}
local file = os.getenv('REVUEY_FAKE_GH_PRS')
if file and file ~= '' then
  local fd = assert(io.open(file, 'r'))
  prs = vim.json.decode(fd:read('*a'))
  fd:close()
end
-- `_parents`: { ["me/shop"] = "acme/shop" } (forks); `_null`: repos that resolve to null (with a
-- GraphQL error and exit 1, as gh does for partial data)
local parents, null = prs._parents or {}, {}
for _, r in ipairs(prs._null or {}) do
  null[r] = true
end
local data, errors = {}, {}
local pat = '(l%d+): repository%(owner: (%b""), name: (%b"")%) { pullRequests%(headRefName: (%b"")'
for alias, owner, name, branch in (query or ''):gmatch(pat) do
  local repo = vim.json.decode(owner) .. '/' .. vim.json.decode(name)
  branch = vim.json.decode(branch)
  if null[repo] then
    data[alias] = vim.NIL
    errors[#errors + 1] = { type = 'NOT_FOUND', message = 'Could not resolve to a Repository with the name \'' .. repo .. '\'.' }
  else
    local parent = vim.NIL
    if parents[repo] then
      parent = { nameWithOwner = parents[repo], pullRequests = { nodes = prs[parents[repo] .. ':' .. branch] or {} } }
    end
    data[alias] = { nameWithOwner = repo, pullRequests = { nodes = prs[repo .. ':' .. branch] or {} }, parent = parent }
  end
end
io.stdout:write(vim.json.encode({ data = data, errors = #errors > 0 and errors or nil }), '\n')
if #errors > 0 then
  io.stderr:write('gh: ' .. errors[1].message .. '\n')
  os.exit(1)
end
