-- Lua half of tests/bin/gh: records the call and answers `gh api graphql` from canned PRs.
-- os.exit skips Neovim's own exit, which removes its server socket and temp dir
-- ($TMPDIR/nvim.<user>/XXXXXX): remove them first, or every call leaves both behind.
local os_exit = os.exit
os.exit = function(...)
  pcall(vim.fn.serverstop, vim.v.servername)
  pcall(vim.fn.delete, vim.fn.fnamemodify(vim.fn.tempname(), ':h'), 'rf')
  return os_exit(...)
end
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

-- ---------------------------------------------------------------------------
-- Posting reviews (forge_post_view.lua): `REVUEY_FAKE_GH_POST` is a JSON file that is both the
-- canned GitHub side and its state, rewritten by every mutation:
--   viewer = "login"
--   prs = { ["owner/name#N"] = { id, headRefOid, state?, author?,
--           pending? = { id, commit, comments = [{id, databaseId, path, line, startLine?, body, replyTo?}] },
--           history? = [ submitted reviews: {id, state, commit, body, createdAt, author?, comments} ] } }
--   files = { ["owner/name#N"] = [ REST file objects: filename, status, sha, patch, ... ] }
--   reviews = { [review id] = state }   (node(id:) answers: PENDING, COMMENTED, ...; absent: null)
--   fail = { add = ["body substring", ...] (those threads/replies are refused),
--            create = true (addPullRequestReview without an event fails),
--            submit = ["owner/name#N", ...], files = true, preflight = true,
--            lost = ["body substring", ...], lost_create = true (applied, then no answer),
--            lost_unapplied = ["body substring", ...] (no answer, not applied),
--            down_after_lost = true (every later read fails), review_null = [review ids]
--            (a null that is not NOT_FOUND), pages = true (later comment pages fail),
--            pr_null = true (the PR comes back null, not NOT_FOUND), add_side = ["LEFT"|"RIGHT"]
--            (threads on that side are refused) }
-- Every mutation alias is appended to `REVUEY_FAKE_GH_MUTATIONS` as {op, alias, input} (the
-- input object parsed), so tests can assert on exactly what would be posted. Threads added go
-- into the REVUEY_FAKE_GH_THREADS file as PENDING (SUBMITTED once their review is submitted), so
-- a refetch shows them.
local post_file = os.getenv('REVUEY_FAKE_GH_POST')
local function read_json(path)
  local fd = path and path ~= '' and io.open(path, 'r')
  if not fd then
    return nil
  end
  local t = vim.json.decode(fd:read('*a'))
  fd:close()
  return t
end
local function write_json(path, t)
  local fd = assert(io.open(path .. '.tmp', 'w'))
  fd:write(vim.json.encode(t))
  fd:close()
  assert(os.rename(path .. '.tmp', path))
end
local P = read_json(post_file)

-- REST: GET repos/<o>/<n>/pulls/<N>/files?per_page=&page=
local rest = argv[3] == '--hostname' and argv[5] or argv[3]
if argv[2] == 'api' and rest and rest:match('^repos/') then
  for i = 3, #argv do
    if argv[i] == '-f' or argv[i] == '-F' or argv[i] == '-X' or argv[i] == '--method' then
      io.stderr:write('fake gh: REST writes are not allowed\n')
      os.exit(3)
    end
  end
  local o, n, num, q = rest:match('^repos/([^/]+)/([^/]+)/pulls/(%d+)/files%??(.*)$')
  if not o then
    io.stderr:write('fake gh: unsupported REST path ' .. rest .. '\n')
    os.exit(2)
  end
  if P and P.fail and P.fail.files then
    io.stdout:write(vim.json.encode({ message = 'Server Error' }), '\n')
    io.stderr:write('gh: Server Error (HTTP 500)\n')
    os.exit(1)
  end
  local list = P and P.files and P.files[o .. '/' .. n .. '#' .. num]
  if not list then
    io.stdout:write(vim.json.encode({ message = 'Not Found' }), '\n')
    io.stderr:write('gh: Not Found (HTTP 404)\n')
    os.exit(1)
  end
  local per = tonumber(q:match('per_page=(%d+)') or '30')
  local page = tonumber(('&' .. q):match('&page=(%d+)') or '1')
  local out = {}
  for i = (page - 1) * per + 1, math.min(#list, page * per) do
    out[#out + 1] = list[i]
  end
  io.stdout:write(vim.json.encode(out), '\n')
  os.exit(0)
end

local function query_arg()
  for i = 4, #argv do
    local q = argv[i]:match('^query=(.*)$')
    if q then
      return q
    end
  end
end

---Parse a GraphQL input value at `i` of `text` (strings as JSON literals, numbers, enums,
---objects, lists): returns the value and the position after it.
local parse_value
local function skip(text, i)
  return text:match('^[%s,]*()', i)
end
parse_value = function(text, i)
  i = skip(text, i)
  local ch = text:sub(i, i)
  if ch == '"' then
    local j = i + 1
    while j <= #text do
      local cj = text:sub(j, j)
      if cj == '\\' then
        j = j + 2
      elseif cj == '"' then
        break
      else
        j = j + 1
      end
    end
    return vim.json.decode(text:sub(i, j)), j + 1
  elseif ch == '{' then
    local out = {}
    i = i + 1
    while true do
      i = skip(text, i)
      if text:sub(i, i) == '}' then
        return out, i + 1
      end
      local key, after = text:match('^([%w_]+)%s*:%s*()', i)
      local v
      v, i = parse_value(text, after)
      out[key] = v
    end
  elseif ch == '[' then
    local out = {}
    i = i + 1
    while true do
      i = skip(text, i)
      if text:sub(i, i) == ']' then
        return out, i + 1
      end
      local v
      v, i = parse_value(text, i)
      out[#out + 1] = v
    end
  end
  local tok, nxt = text:match('^([%w_%-%.]+)()', i)
  return tonumber(tok) or tok, nxt
end

local query0 = query_arg()
local function now_iso()
  return os.date('!%Y-%m-%dT%H:%M:%SZ')
end
local STATE = { APPROVE = 'APPROVED', COMMENT = 'COMMENTED', REQUEST_CHANGES = 'CHANGES_REQUESTED' }

---Every review of the fake (pending ones and `history`), by id: review, PR key, PR.
local function find_review(id)
  for k, pr in pairs((P or {}).prs or {}) do
    if pr.pending and pr.pending.id == id then
      return pr.pending, k, pr
    end
    for _, rv in ipairs(pr.history or {}) do
      if rv.id == id then
        return rv, k, pr
      end
    end
  end
end

---A page of a review's comments (`first`, `after` = index cursor), as GraphQL has it.
local function comments_page(rv, first, after)
  local list = rv.comments or {}
  local from = (tonumber(after) or 0) + 1
  local cs = {}
  for i = from, math.min(#list, from + first - 1) do
    local c = list[i]
    cs[#cs + 1] = { id = c.id, fullDatabaseId = c.databaseId and tostring(c.databaseId) or vim.NIL, url = c.url or vim.NIL,
      path = c.path or vim.NIL, line = c.line or vim.NIL, startLine = c.startLine or vim.NIL,
      -- the lines it was made on (`line` follows the head: tests move it, or null it when outdated)
      originalLine = c.originalLine or c.line or vim.NIL, originalStartLine = c.originalStartLine or c.startLine or vim.NIL,
      subjectType = c.subjectType or 'LINE', body = c.body, replyTo = c.replyTo or vim.NIL }
  end
  local last = from + #cs - 1
  return { totalCount = #list, pageInfo = { hasNextPage = last < #list, endCursor = #cs > 0 and tostring(last) or vim.NIL }, nodes = cs }
end

---A review node (the `review` fragment).
local function review_node(rv, first)
  return { id = rv.id, state = rv.state or 'PENDING', viewerDidAuthor = rv.author == nil or rv.author == (P.viewer or 'me'),
    createdAt = rv.createdAt or '2026-01-01T00:00:00Z', body = rv.body or '', commit = { oid = rv.commit },
    comments = comments_page(rv, first, nil) }
end

if argv[2] == 'api' and argv[3] == 'graphql' and query0 and query0:match('^mutation') then
  local mlog = os.getenv('REVUEY_FAKE_GH_MUTATIONS')
  local threads_file = os.getenv('REVUEY_FAKE_GH_THREADS')
  local T = read_json(threads_file) or {}
  P = P or {}
  P.prs = P.prs or {}
  P.reviews = P.reviews or {}
  P.seq = (P.seq or 0)
  local fail = P.fail or {}
  local data, errors = {}, {}
  local function key_of_pr(id)
    for k, pr in pairs(P.prs) do
      if pr.id == id then
        return k, pr
      end
    end
  end
  local function next_id(prefix)
    P.seq = P.seq + 1
    return prefix .. P.seq
  end
  local function err(alias, msg)
    data[alias] = vim.NIL
    errors[#errors + 1] = { type = 'UNPROCESSABLE', path = { alias }, message = msg }
  end
  local function refused_body(inp)
    for _, sub in ipairs(fail.add or {}) do
      if type(inp.body) == 'string' and inp.body:find(sub, 1, true) then
        return true
      end
    end
    return vim.tbl_contains(fail.add_side or {}, inp.side)
  end
  ---Add a thread (a comment of review `rv`, PR key `k`) and its node in the threads file.
  local function new_thread(k, rv, th, state)
    local cid = next_id('PRRC_')
    local dbid = 5000 + P.seq
    local url = 'https://github.com/' .. k:gsub('#', '/pull/') .. '#discussion_r' .. dbid
    local cnode = { id = cid, databaseId = dbid, url = url, body = th.body, createdAt = now_iso(), lastEditedAt = vim.NIL, state = state,
      diffHunk = vim.NIL, author = { login = P.viewer or 'me' }, replyTo = vim.NIL }
    local tid = next_id('PRRT_')
    rv.comments = rv.comments or {}
    table.insert(rv.comments, { id = cid, databaseId = dbid, url = url, path = th.path, line = th.line, startLine = th.startLine,
      subjectType = th.subjectType or 'LINE', body = th.body })
    T[k] = T[k] or {}
    table.insert(T[k], { id = tid, isResolved = false, isOutdated = false, path = th.path, line = th.line or vim.NIL,
      startLine = th.startLine or vim.NIL, originalLine = th.line or vim.NIL, originalStartLine = th.startLine or vim.NIL,
      diffSide = th.side or 'RIGHT', startDiffSide = th.startSide or vim.NIL, subjectType = th.subjectType or 'LINE',
      resolvedBy = vim.NIL, comments = { cnode } })
    return tid, cid, dbid, url
  end
  for alias, op, at in query0:gmatch('\n%s*(%w+): (%w+)%(input: ()') do
    local inp = parse_value(query0, at)
    if mlog and mlog ~= '' then
      local fd = assert(io.open(mlog, 'a'))
      fd:write(vim.json.encode({ op = op, alias = alias, input = inp }), '\n')
      fd:close()
    end
    if op == 'addPullRequestReview' then
      local k, pr = key_of_pr(inp.pullRequestId)
      if not pr then
        err(alias, 'Could not resolve to a node with the global id of ' .. tostring(inp.pullRequestId))
      elseif inp.event then
        local bad = vim.tbl_contains(fail.submit or {}, k)
        for _, th in ipairs(inp.threads or {}) do
          bad = bad or refused_body(th)
        end
        if bad then
          err(alias, 'Review cannot be submitted')
        elseif pr.pending then
          err(alias, 'User can only have one pending review per pull request')
        else
          -- created and submitted at once, with its threads
          local id = next_id('PRR_')
          local rv = { id = id, state = STATE[inp.event], commit = inp.commitOID, body = inp.body or '', createdAt = now_iso(), comments = {} }
          for _, th in ipairs(inp.threads or {}) do
            new_thread(k, rv, th, 'SUBMITTED')
          end
          pr.history = pr.history or {}
          table.insert(pr.history, rv)
          P.reviews[id] = rv.state
          local node = review_node(rv, 100)
          node.url = 'https://github.com/' .. k:gsub('#', '/pull/') .. '#pullrequestreview-' .. P.seq
          data[alias] = { pullRequestReview = node }
        end
      elseif fail.create then
        err(alias, 'Something went wrong while executing your query.')
      elseif pr.pending then
        err(alias, 'User can only have one pending review per pull request')
      else
        local id = next_id('PRR_')
        pr.pending = { id = id, commit = inp.commitOID, comments = {}, createdAt = now_iso() }
        P.reviews[id] = 'PENDING'
        data[alias] = { pullRequestReview = { id = id, commit = { oid = inp.commitOID } } }
      end
    elseif op == 'addPullRequestReviewThread' or op == 'addPullRequestReviewThreadReply' then
      local rv, k, pr = find_review(inp.pullRequestReviewId)
      if not rv or rv ~= pr.pending then
        err(alias, 'Could not resolve to a node with the global id of ' .. tostring(inp.pullRequestReviewId))
      elseif refused_body(inp) then
        err(alias, 'pull_request_review_thread.line must be part of the diff')
      elseif op == 'addPullRequestReviewThread' then
        local tid, cid, dbid, url = new_thread(k, rv, inp, 'PENDING')
        data[alias] = { thread = { id = tid, comments = { nodes = { { id = cid, fullDatabaseId = tostring(dbid), url = url } } } } }
      else
        local found
        for _, list in pairs(T) do
          if type(list) == 'table' and vim.islist(list) then
            for _, t in ipairs(list) do
              if t.id == inp.pullRequestReviewThreadId then
                found = t
              end
            end
          end
        end
        if not found then
          err(alias, 'Could not resolve to a node with the global id of ' .. tostring(inp.pullRequestReviewThreadId))
        else
          local cid = next_id('PRRC_')
          local dbid = 5000 + P.seq
          local url = 'https://github.com/' .. k:gsub('#', '/pull/') .. '#discussion_r' .. dbid
          table.insert(found.comments, { id = cid, databaseId = dbid, url = url, body = inp.body, createdAt = now_iso(), lastEditedAt = vim.NIL,
            state = 'PENDING', diffHunk = vim.NIL, author = { login = P.viewer or 'me' }, replyTo = { id = found.comments[1].id } })
          table.insert(rv.comments, { id = cid, databaseId = dbid, url = url, path = found.path, line = found.line,
            body = inp.body, replyTo = { id = found.comments[1].id } })
          data[alias] = { comment = { id = cid, fullDatabaseId = tostring(dbid), url = url } }
        end
      end
    elseif op == 'submitPullRequestReview' then
      local rv, k, pr = find_review(inp.pullRequestReviewId)
      if not rv or rv ~= pr.pending then
        err(alias, 'Could not resolve to a node with the global id of ' .. tostring(inp.pullRequestReviewId))
      elseif vim.tbl_contains(fail.submit or {}, k) then
        err(alias, 'Review cannot be submitted')
      else
        rv.state = STATE[inp.event]
        rv.body = inp.body or ''
        P.reviews[rv.id] = rv.state
        local ids = {}
        for _, pc in ipairs(rv.comments) do
          ids[pc.id] = true
        end
        for _, t in ipairs(T[k] or {}) do
          for _, c in ipairs(t.comments or {}) do
            if ids[c.id] then
              c.state = 'SUBMITTED'
            end
          end
        end
        pr.pending = nil
        pr.history = pr.history or {}
        table.insert(pr.history, rv)
        data[alias] = { pullRequestReview = { id = rv.id, state = rv.state, url = 'https://github.com/' .. k:gsub('#', '/pull/') .. '#pullrequestreview-1' } }
      end
    else
      err(alias, 'fake gh: unsupported mutation ' .. op)
    end
  end
  -- `fail.lost`: a mutation whose text contains one of these (or `fail.lost_create` for a pending
  -- review) is applied, then the call answers nothing, as when gh is stopped by revuey's timeout
  -- after GitHub did the work; `fail.down_after_lost` then makes every later read fail too;
  -- `fail.lost_unapplied`: the same, but GitHub did not apply it
  local lost, unapplied = false, false
  for _, sub in ipairs(fail.lost or {}) do
    lost = lost or query0:find(sub, 1, true) ~= nil
  end
  for _, sub in ipairs(fail.lost_unapplied or {}) do
    unapplied = unapplied or query0:find(sub, 1, true) ~= nil
  end
  lost = lost or (fail.lost_create and query0:find('addPullRequestReview(input: {pullRequestId', 1, true) ~= nil and not query0:find('event:', 1, true))
  if (lost or unapplied) and fail.down_after_lost then
    P.down = true
  end
  if unapplied then
    if P.down then
      local cur = read_json(post_file) or {}
      cur.down = true
      write_json(post_file, cur)
    end
    io.stderr:write('gh timed out\n')
    os.exit(124)
  end
  write_json(post_file, P)
  if threads_file and threads_file ~= '' then
    write_json(threads_file, next(T) and T or vim.empty_dict())
  end
  if lost then
    io.stderr:write('gh timed out\n')
    os.exit(124)
  end
  io.stdout:write(vim.json.encode({ data = data, errors = #errors > 0 and errors or nil }), '\n')
  if #errors > 0 then
    io.stderr:write('gh: ' .. errors[1].message .. '\n')
    os.exit(1)
  end
  os.exit(0)
end

-- the next comments of a review (forge.build_pending_page_query)
if argv[2] == 'api' and argv[3] == 'graphql' and query0 and query0:find('... on PullRequestReview { comments(', 1, true) then
  P = P or {}
  if P.down or (P.fail or {}).pages then
    io.stderr:write('error connecting to api.github.com\n')
    os.exit(1)
  end
  local id, first, after = query0:match('q: node%(id: (%b"")%) { %.%.%. on PullRequestReview { comments%(first: (%d+), after: (%b"")')
  id, after = vim.json.decode(id), vim.json.decode(after)
  local found = find_review(id)
  io.stdout:write(vim.json.encode({ data = { q = found and { comments = comments_page(found, tonumber(first), after) } or vim.NIL } }), '\n')
  os.exit(0)
end

-- the posting preflight (forge.build_preflight_query)
if argv[2] == 'api' and argv[3] == 'graphql' and query0 and query0:find('viewer { login }', 1, true) then
  P = P or {}
  if (P.fail and P.fail.preflight) or P.down then
    io.stderr:write('error connecting to api.github.com\n')
    os.exit(1)
  end
  local first = tonumber(query0:match('fragment review on PullRequestReview {.-comments%(first: (%d+)%)') or '100')
  local data, errors = { viewer = { login = P.viewer or 'me' } }, {}
  for alias, id in query0:gmatch('(r%d+): node%(id: (%b"")%)') do
    id = vim.json.decode(id)
    local rv = find_review(id)
    if vim.tbl_contains((P.fail or {}).review_null or {}, id) then
      -- null for another reason than NOT_FOUND (a timeout, a permission)
      data[alias] = vim.NIL
      errors[#errors + 1] = { type = 'FORBIDDEN', path = { alias }, message = 'Resource not accessible' }
    elseif rv then
      data[alias] = review_node(rv, first)
    else
      data[alias] = vim.NIL
      errors[#errors + 1] = { type = 'NOT_FOUND', path = { alias }, message = 'Could not resolve to a node with the global id of \'' .. id .. '\'' }
    end
  end
  for alias, owner, name, number, last in query0:gmatch('(p%d+): repository%(owner: (%b""), name: (%b"")%) { pullRequest%(number: (%d+)%).-recent: reviews%(last: (%d+)%)') do
    local key = vim.json.decode(owner) .. '/' .. vim.json.decode(name) .. '#' .. number
    local pr = (P.prs or {})[key]
    if not pr or (P.fail or {}).pr_null then
      data[alias] = { pullRequest = vim.NIL }
      errors[#errors + 1] = { type = (pr and 'TIMEOUT' or 'NOT_FOUND'), path = { alias, 'pullRequest' }, message = 'Could not resolve to a PullRequest with the number of ' .. number .. '.' }
    else
      local pending = {}
      if pr.pending then
        pending[1] = review_node(pr.pending, first)
      end
      if pr.pending_extra then
        -- a second pending review of the viewer's (GitHub should not allow it)
        pending[#pending + 1] = review_node(pr.pending_extra, first)
      end
      local all = vim.deepcopy(pr.history or {})
      if pr.pending then
        all[#all + 1] = pr.pending
      end
      local recent = {}
      for i = math.max(1, #all - tonumber(last) + 1), #all do
        recent[#recent + 1] = review_node(all[i], first)
      end
      data[alias] = { pullRequest = {
        id = pr.id, number = tonumber(number), url = 'https://github.com/' .. key:gsub('#', '/pull/'), state = pr.state or 'OPEN',
        isDraft = false, headRefOid = pr.headRefOid or vim.NIL, author = { login = pr.author or 'alice' },
        reviews = { nodes = pending }, recent = { totalCount = #all, nodes = recent },
      } }
    end
  end
  io.stdout:write(vim.json.encode({ data = data, errors = #errors > 0 and errors or nil }), '\n')
  if #errors > 0 then
    io.stderr:write('gh: ' .. errors[1].message .. '\n')
    os.exit(1)
  end
  os.exit(0)
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
-- the change check (forge.check): `kN: repository { pM: pullRequest(number) { ...check } }`,
-- answered from the same files as the lookup and the threads, so a test changes a PR's signals
-- by rewriting them: the PR node as canned (no body) plus `reviewThreads` (totalCount, the first
-- N threads' isResolved and comment counts). A number not in the PRs file answers null (with a
-- NOT_FOUND error, exit 1). `REVUEY_FAKE_GH_CHECK_SCENARIO=fail` fails check queries only;
-- `REVUEY_FAKE_GH_CHECK_DELAY` (seconds) makes them slow.
if query and query:find('fragment check on PullRequest', 1, true) then
  if (os.getenv('REVUEY_FAKE_GH_CHECK_SCENARIO') or '') == 'fail' then
    io.stderr:write('error connecting to api.github.com\n')
    os.exit(1)
  end
  -- `REVUEY_FAKE_GH_CHECK_DELAY` seconds before answering (a slow check, to race it)
  local delay = tonumber(os.getenv('REVUEY_FAKE_GH_CHECK_DELAY') or '')
  if delay then
    vim.uv.sleep(math.floor(delay * 1000))
  end
  local function load(env)
    local f = os.getenv(env)
    if not f or f == '' then
      return {}
    end
    local fd = assert(io.open(f, 'r'))
    local t = vim.json.decode(fd:read('*a'))
    fd:close()
    return t
  end
  local prs, threads = load('REVUEY_FAKE_GH_PRS'), load('REVUEY_FAKE_GH_THREADS')
  local first = tonumber(query:match('reviewThreads%(first: (%d+)%)') or '0')
  local data, errors = {}, {}
  for ralias, owner, name, body in query:gmatch('(k%d+): repository%(owner: (%b""), name: (%b"")%) (%b{})') do
    local repo = vim.json.decode(owner) .. '/' .. vim.json.decode(name)
    data[ralias] = {}
    for palias, num in body:gmatch('(p%d+): pullRequest%(number: (%d+)%)') do
      local node
      for key, list in pairs(prs) do
        if key:sub(1, #repo + 1) == repo .. ':' and type(list) == 'table' then
          for _, n in ipairs(list) do
            if n.number == tonumber(num) then
              node = vim.deepcopy(n)
            end
          end
        end
      end
      if node then
        node.body = nil
        if first > 0 then
          local list = threads[repo .. '#' .. num] or {}
          local out = {}
          for i = 1, math.min(#list, first) do
            out[i] = { isResolved = list[i].isResolved == true, comments = { totalCount = #(list[i].comments or {}) } }
          end
          node.reviewThreads = { totalCount = #list, nodes = out }
        end
        data[ralias][palias] = node
      else
        data[ralias][palias] = vim.NIL
        errors[#errors + 1] = { type = 'NOT_FOUND', path = { ralias, palias }, message = 'Could not resolve to a PullRequest with the number of ' .. num .. '.' }
      end
    end
  end
  io.stdout:write(vim.json.encode({ data = data, errors = #errors > 0 and errors or nil }), '\n')
  os.exit(#errors > 0 and 1 or 0)
end

-- review threads (forge.fetch_threads): `REVUEY_FAKE_GH_THREADS` is a JSON file
-- { ["owner/name#N"] = { PullRequestReviewThread nodes, with `comments` a plain list of
-- PullRequestReviewComment nodes } }, `_null` = PRs that resolve to null; pages are cut by the
-- query's `first`/`after` (cursors are indices). `REVUEY_FAKE_GH_THREADS_SCENARIO` = fail |
-- errors | fail_after (only queries for later pages fail) applies to thread queries only (the
-- PR lookup still answers). `_heads` = { ["owner/name#N"] = oid } is the PR's headRefOid there (`_heads_later`: on
-- pages after the first, a push mid-fetch).
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
  local tpat = '(t%d+): repository%(owner: (%b""), name: (%b"")%) { pullRequest%(number: (%d+)%) {[^(]-reviewThreads%(first: (%d+)([^)]*)%)'
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
      local head = (after and (all._heads_later or {})[key]) or (all._heads or {})[key]
      data[alias] = { pullRequest = { headRefOid = head or vim.NIL, reviewThreads = { pageInfo = info, nodes = out } } }
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
-- a PR's `body` (its description) only when the query's PR fragment asks for it, as GitHub does
local wants_body = ((query or ''):match('fragment pr on PullRequest(.*)$') or ''):find('%f[%w]body%f[%W]') ~= nil
local function answer(list)
  if wants_body then
    return list or {}
  end
  local out = {}
  for i, n in ipairs(list or {}) do
    out[i] = vim.deepcopy(n)
    out[i].body = nil
  end
  return out
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
      parent = { nameWithOwner = parents[repo], pullRequests = { nodes = answer(prs[parents[repo] .. ':' .. branch]) } }
    end
    data[alias] = { nameWithOwner = repo, pullRequests = { nodes = answer(prs[repo .. ':' .. branch]) }, parent = parent }
  end
end
-- the stack tree (stack_tree.lua): `_tree` = { ["owner/name"] = [PullRequest nodes as GitHub has
-- them: number, title, url, state, isDraft, updatedAt, headRefName, baseRefName, headRefOid,
-- isCrossRepository, headRepositoryOwner, headRef (null: the branch was deleted; default: present),
-- reviewDecision] }, `_default_branch` = { ["owner/name"] = "main" } (default "main"). Answers
-- `sdN` (a head branch's PRs, each with its base's PRs nested as deep as the query asks through
-- `baseRef { associatedPullRequests }`) and `skN` (PRs based on a branch), newest first, cut at
-- the query's `first` with the real `totalCount`. `REVUEY_FAKE_GH_TREE_SCENARIO=fail` fails the
-- tree's own rounds (the first one, inside the PR lookup, still answers).
local tree_all = prs._tree or {}
-- `REVUEY_FAKE_GH_TREE_SCENARIO=reject`: GitHub rejects a PR lookup carrying the tree's aliases
-- (errors, no data) and answers the same lookup without them
if query and query:find('fragment tnode on PullRequest', 1, true) and query:find('fragment pr on PullRequest', 1, true)
  and (os.getenv('REVUEY_FAKE_GH_TREE_SCENARIO') or '') == 'reject' then
  io.stdout:write(vim.json.encode({ data = vim.NIL, errors = { {
    message = 'Field \'associatedPullRequests\' doesn\'t exist', locations = { { line = 3, column = 40 } },
  } } }), '\n')
  io.stderr:write('gh: Field \'associatedPullRequests\' doesn\'t exist\n')
  os.exit(1)
end
if query and query:find('fragment tnode on PullRequest', 1, true) and not query:find('fragment pr on PullRequest', 1, true)
  and (os.getenv('REVUEY_FAKE_GH_TREE_SCENARIO') or '') == 'fail' then
  io.stderr:write('error connecting to api.github.com\n')
  os.exit(1)
end
local function tree_node(n)
  local out = vim.deepcopy(n)
  if out.headRef == nil then
    out.headRef = { name = n.headRefName }
  end
  out.headRepositoryOwner = out.headRepositoryOwner or { login = 'acme' }
  out.isCrossRepository = out.isCrossRepository == true
  out.isDraft = out.isDraft == true
  return out
end
local function newest_first(list)
  table.sort(list, function(a, b)
    if a.updatedAt ~= b.updatedAt then
      return (a.updatedAt or '') > (b.updatedAt or '')
    end
    return a.number > b.number
  end)
  return list
end
local function tree_conn(list, first, fn)
  local out = {}
  for i = 1, math.min(#list, first) do
    out[i] = fn and fn(list[i]) or tree_node(list[i])
  end
  return { totalCount = #list, nodes = out }
end
for line in (query or ''):gmatch('[^\n]+') do
  local alias, owner, name, rest = line:match('^%s*(s[dk]%d+): repository%(owner: (%b""), name: (%b"")%) { (.*)$')
  if alias then
    local repo = vim.json.decode(owner) .. '/' .. vim.json.decode(name)
    local all = tree_all[repo] or {}
    -- `pullRequests(headRefName:)` lists forks' PRs of that head name too; a Ref's
    -- `associatedPullRequests` only the repository's own
    local function heads(b, forks)
      local l = {}
      for _, n in ipairs(all) do
        if n.headRefName == b and (forks or not n.isCrossRepository) then
          l[#l + 1] = n
        end
      end
      return newest_first(l)
    end
    if alias:sub(2, 2) == 'd' then
      local b, first = rest:match('pullRequests%(headRefName: (%b""), first: (%d+)')
      b = vim.json.decode(b)
      local _, depth = line:gsub('associatedPullRequests%(', '')
      local nfirst = tonumber(line:match('associatedPullRequests%(first: (%d+)') or '2')
      local function nest(level)
        return function(n)
          local out = tree_node(n)
          if level > 0 then
            out.baseRef = { name = n.baseRefName, associatedPullRequests = tree_conn(heads(n.baseRefName), nfirst, nest(level - 1)) }
          end
          return out
        end
      end
      local answer = { pullRequests = tree_conn(heads(b, true), tonumber(first), nest(depth)) }
      if rest:find('defaultBranchRef', 1, true) then
        answer.defaultBranchRef = { name = (prs._default_branch or {})[repo] or 'main' }
      end
      data[alias] = answer
    else
      local b, first = rest:match('pullRequests%(baseRefName: (%b""), first: (%d+)')
      b = vim.json.decode(b)
      local l = {}
      for _, n in ipairs(all) do
        if n.baseRefName == b then
          l[#l + 1] = n
        end
      end
      data[alias] = { pullRequests = tree_conn(newest_first(l), tonumber(first)) }
    end
  end
end
io.stdout:write(vim.json.encode({ data = data, errors = #errors > 0 and errors or nil }), '\n')
if #errors > 0 then
  io.stderr:write('gh: ' .. errors[1].message .. '\n')
  os.exit(1)
end
