-- When GitHub data is fetched, and the change check (forge.check, forge_view's timer): PRs,
-- threads and descriptions are fetched the first time a review needs them and on `R`, never by
-- a redraw, a refresh, a resize or the clock; the change check asks only signals and marks PRs
-- with news (row chip, detail heading, threads line, description title, winbar) without
-- replacing what is shown; `R` clears the marks; focus, visibility, failures, the timer's life
-- and `forge.check = false`. Through the fake `gh` (tests/bin/gh) with a clock the tests set.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')
local state_dir = h.tmpdir('fc-state')
local log_file = h.tmpdir('fc-log') .. '/revuey.log'
local function setup(extra)
  require('revuey').setup(vim.tbl_deep_extend('force', { state_dir = state_dir, lsp_warmup = false, log_file = log_file }, extra or {}))
end
setup()
local forge = require('revuey.forge')
local fv = require('revuey.forge_view')
local view = require('revuey.view')
local log = require('revuey.log')

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

---A PullRequest node as GitHub returns it (the lookup's fields and the check's).
local function pr(o)
  return {
    number = o.number, title = o.title or ('PR ' .. o.number), url = 'https://github.com/acme/shop/pull/' .. o.number,
    state = o.state or 'OPEN', isDraft = o.draft or false, author = { login = 'alice' }, latestReviews = { nodes = {} },
    reviews = { totalCount = o.reviews or 0 },
    reviewRequests = { totalCount = o.requested or 0, nodes = {} }, mergeable = 'MERGEABLE', baseRefName = o.base or 'main',
    headRefName = o.head, headRepositoryOwner = { login = 'acme' }, headRefOid = o.oid or ('a' .. o.number),
    updatedAt = '2026-01-01T00:00:00Z', lastEditedAt = o.edited or vim.NIL, reviewDecision = o.decision or vim.NIL,
    body = o.body or ('Why: layer ' .. o.number .. '.'),
    commits = { nodes = { { commit = { statusCheckRollup = { state = o.checks or 'SUCCESS', contexts = {
      checkRunCountsByState = { { state = 'SUCCESS', count = 1 } }, statusContextCountsByState = {},
    } } } } } },
  }
end

local function base_prs()
  return {
    ['acme/shop:stack/math'] = { pr({ number = 11, head = 'stack/math' }) },
    ['acme/shop:stack/cart'] = { pr({ number = 12, head = 'stack/cart', base = 'stack/math', title = 'Cart totals' }) },
    ['acme/shop:stack/ui'] = { pr({ number = 13, head = 'stack/ui', base = 'stack/cart' }) },
  }
end

local seq = 0
local function c(body)
  seq = seq + 1
  return {
    id = 'C' .. seq, databaseId = seq, url = 'https://github.com/acme/shop/pull/12#r' .. seq, body = body,
    createdAt = '2026-01-01T00:00:00Z', lastEditedAt = vim.NIL, state = 'SUBMITTED', diffHunk = vim.NIL,
    author = { login = 'carol' }, replyTo = vim.NIL,
  }
end

local function t(id, resolved, comments)
  return {
    id = id, isResolved = resolved, isOutdated = false, path = 'src/cart.ts', line = vim.NIL, startLine = vim.NIL,
    originalLine = vim.NIL, originalStartLine = vim.NIL, diffSide = 'RIGHT', startDiffSide = vim.NIL,
    subjectType = 'FILE', resolvedBy = vim.NIL, comments = comments,
  }
end

local function base_threads()
  return {
    ['acme/shop#12'] = { t('T1', false, { c('Round it?') }), t('T2', true, { c('Copy?'), c('No.') }) },
    ['acme/shop#11'] = { t('T3', false, { c('Name?') }) },
    ['acme/shop#13'] = { t('T4', false, { c('Spacing?') }) },
  }
end

local function stack_fixture(name)
  local d = h.tmpdir(name)
  vim.fn.delete(d, 'rf')
  local res = vim.system({ h.root .. '/scripts/make-fixture.sh', '--stack', d }, { text = true }):wait()
  assert(res.code == 0, res.stderr)
  h.git(d, 'remote', 'add', 'origin', 'git@github.com:acme/shop.git')
  return d
end

local function open(dir, opts)
  if view.session then
    view.close()
  end
  local session
  require('revuey').open(vim.tbl_extend('force', { cwd = dir }, opts or {}, {
    on_ready = function(s)
      session = s
    end,
  }))
  assert(vim.wait(10000, function()
    return session ~= nil
  end, 10), 'review did not open')
  return session
end

local function idle(s)
  assert(vim.wait(15000, function()
    return not s.refreshing and not s.pending and not s.pending_scope
      and s.forge and s.forge.ready and not s.forge.busy and not s.forge.checking
  end, 10), 'refresh / PR lookup / check did not finish')
  vim.wait(50) -- scheduled redraws (description rows)
end

local now = 1e6
local function reset()
  forge.cache, forge.threads_cache, forge.changed = {}, {}, {}
  log.entries = {}
  now = 1e6
  forge.now = function()
    return now
  end
end

---The calls the fake gh got, by kind: lookup (PRs), threads, check.
local function kinds(calls)
  local out = { lookup = 0, threads = 0, check = 0, queries = {} }
  for _, x in ipairs(h.read_calls(calls)) do
    local q = x.argv[5] or ''
    local k = q:find('fragment check on', 1, true) and 'check' or q:find('fragment thread on', 1, true) and 'threads'
      or q:find('fragment comment on', 1, true) and 'threads' or 'lookup'
    out[k] = out[k] + 1
    out.queries[#out.queries + 1] = { kind = k, q = q }
  end
  return out
end

local function last_check(calls)
  local k = kinds(calls)
  for i = #k.queries, 1, -1 do
    if k.queries[i].kind == 'check' then
      return k.queries[i].q
    end
  end
end

---Panel lines with right-aligned virtual text after ` | `.
local function panel_lines(s)
  local lines = vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false)
  local ns = vim.api.nvim_get_namespaces()['revuey.panel']
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.panel_buf, ns, 0, -1, { details = true })) do
    if m[4].virt_text then
      lines[m[2] + 1] = lines[m[2] + 1] .. ' | ' .. table.concat(vim.tbl_map(function(x)
        return x[1]
      end, m[4].virt_text))
    end
  end
  return lines
end

local function find(lines, pat)
  for i, l in ipairs(lines) do
    if l:find(pat, 1, true) then
      return i, l
    end
  end
end

local function panel_has(s, pat)
  return find(panel_lines(s), pat) ~= nil
end

local function write_prs(calls, prs)
  vim.fn.writefile({ vim.json.encode(prs) }, calls .. '.prs.json')
end

local function write_threads(calls, threads)
  vim.fn.writefile({ vim.json.encode(threads) }, calls .. '.threads.json')
end

---Run the change check as the timer would once it is due, and wait for it.
local function check_now(s)
  now = now + forge.options().interval
  h.ok(fv.maybe_check(s), 'check did not start')
  idle(s)
end

local function press(s, k)
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_feedkeys(vim.keycode(k), 'mtx', false)
end

local function press_R(s)
  local _, restore = h.capture_notify()
  press(s, 'R')
  idle(s)
  restore()
end

local function first_line(s)
  return vim.api.nvim_buf_get_lines(s.diff_buf, 0, 1, false)[1]
end

local function winbar_top(s)
  vim.api.nvim_win_call(s.diff_win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  vim.g.statusline_winid = s.diff_win
  return view.winbar()
end

-- ---------------------------------------------------------------------------
-- Unit
-- ---------------------------------------------------------------------------

local function decode(n)
  return vim.json.decode(vim.json.encode(n), { luanil = { object = true, array = true } })
end

h.test('signals and compare: each signal on its own; threads by count, resolved and comments', function()
  local base = decode(pr({ number = 12, head = 'x' }))
  local shown = forge.normalize(base, 'github.com/acme/shop')
  h.eq({ head = 'a12', state = 'OPEN', draft = 'false', title = 'PR 12', body = '', decision = '', reviews = '0',
    requested = '0', checks = 'SUCCESS' }, shown.signals)
  h.eq({}, forge.compare(shown, base, false), 'nothing changed')
  for name, change in pairs({
    head = { headRefOid = 'b12' }, state = { state = 'MERGED' }, draft = { isDraft = true }, title = { title = 'New' },
    body = { lastEditedAt = '2026-02-01T00:00:00Z' }, decision = { reviewDecision = 'APPROVED' },
    reviews = { reviews = { totalCount = 1 } }, requested = { reviewRequests = { totalCount = 1 } },
    checks = { commits = { nodes = { { commit = { statusCheckRollup = { state = 'FAILURE' } } } } } },
  }) do
    h.eq({ [name] = true }, forge.compare(shown, vim.tbl_extend('force', base, change), false), name)
  end
  -- a description body change alone does not move any signal: lastEditedAt does
  h.eq({}, forge.compare(shown, vim.tbl_extend('force', base, { body = 'other' }), false))
  -- threads: against the cached threads of the PR
  forge.threads_cache = {}
  h.eq({}, forge.compare(shown, vim.tbl_extend('force', base, { reviewThreads = { totalCount = 3, nodes = {} } }), true),
    'threads never fetched: nothing to compare')
  forge.threads_cache[forge.thread_key(shown)] = { at = 0, threads = {
    { resolved = false, total = 1, comments = {} }, { resolved = true, total = 2, comments = {} },
  } }
  local function conn(list)
    local nodes = {}
    for i, x in ipairs(list) do
      nodes[i] = { isResolved = x[1], comments = { totalCount = x[2] } }
    end
    return vim.tbl_extend('force', base, { reviewThreads = { totalCount = #list, nodes = nodes } })
  end
  h.eq({}, forge.compare(shown, conn({ { false, 1 }, { true, 2 } }), true))
  h.eq({ resolved = true }, forge.compare(shown, conn({ { true, 1 }, { true, 2 } }), true))
  h.eq({ comments = true }, forge.compare(shown, conn({ { false, 2 }, { true, 2 } }), true))
  h.eq({ threads = true, comments = true }, forge.compare(shown, conn({ { false, 1 }, { true, 2 }, { false, 1 } }), true))
  -- a PR shown merged or closed shows no threads: they are not compared
  local merged = vim.tbl_extend('force', shown, { state = 'MERGED', signals = vim.tbl_extend('force', shown.signals, { state = 'MERGED' }) })
  h.eq({}, forge.compare(merged, vim.tbl_extend('force', conn({ { true, 1 }, { true, 2 } }), { state = 'MERGED' }), true))
  -- a failed threads fetch (already stale) is not compared
  forge.threads_cache[forge.thread_key(shown)].failed = 'x'
  h.eq({}, forge.compare(shown, conn({ { true, 1 } }), true))
  forge.threads_cache = {}
end)

h.test('forge.ttl: the check interval, at least 60s (an old ttl = 0 must not check nonstop)', function()
  setup({ forge = { ttl = 0 } })
  h.eq(60000, forge.options().interval)
  setup({ forge = { ttl = 5 } })
  h.eq(60000, forge.options().interval)
  setup({ forge = { ttl = 600 } })
  h.eq(600000, forge.options().interval)
  setup()
  h.eq(180000, forge.options().interval, 'default')
end)

h.test('build_check_query: one repository per repo, an alias per PR, signals only (no body, no thread content)', function()
  local function p(repo, n)
    return { repo = 'github.com/' .. repo, number = n }
  end
  local q, aliases = forge.build_check_query({ p('acme/shop', 11), p('acme/shop', 12), p('me/shop', 3) }, true)
  h.ok(q:find('k1: repository(owner: "acme", name: "shop") { p1: pullRequest(number: 11) { ...check } p2: pullRequest(number: 12) { ...check } }', 1, true), q)
  h.ok(q:find('k2: repository(owner: "me", name: "shop") { p1: pullRequest(number: 3) { ...check } }', 1, true), q)
  h.eq(12, aliases.k1.p2.number)
  h.ok(q:find('reviewThreads(first: 100) { totalCount nodes { isResolved comments { totalCount } } }', 1, true), q)
  for _, field in ipairs({ 'body', 'bodyText', 'author', 'path', 'diffHunk', 'latestReviews', 'nodes { ...comment' }) do
    h.ok(not q:find('%f[%w]' .. vim.pesc(field) .. '%f[%W]'), 'asks no ' .. field .. ': ' .. q)
  end
  local nt = forge.build_check_query({ p('acme/shop', 11) }, false)
  h.ok(not nt:find('reviewThreads', 1, true), nt)
end)

-- ---------------------------------------------------------------------------
-- Integration: when GitHub is read
-- ---------------------------------------------------------------------------

h.test('no fetch without R: redraws, local refreshes, resizes, focus, fetched scopes, hours later', function()
  reset()
  setup({ forge = { check = false } })
  local calls = h.tmpdir('fc-gh-nofetch') .. '/calls.ndjson'
  h.use_fake_gh(calls, base_prs(), nil, base_threads())
  local d = stack_fixture('fc-nofetch')
  local s = open(d)
  idle(s)
  h.eq({ 1, 1 }, { kinds(calls).lookup, kinds(calls).threads }, 'open: one lookup (every layer), the threads of the viewed PR')
  now = now + 10 * 3600 * 1000 -- far past any interval
  require('revuey.panel').render(s)
  view.refresh({ force = true }) -- a refresh that re-renders (file save, git change)
  idle(s)
  vim.api.nvim_win_set_width(s.panel_win, 36) -- a resize
  vim.cmd('doautocmd FocusGained')
  idle(s)
  vim.fn.writefile({ 'changed on disk' }, d .. '/README.local')
  view.refresh()
  idle(s)
  h.eq({ 1, 1 }, { kinds(calls).lookup, kinds(calls).threads }, 'nothing fetched')
  -- a layer shown for the first time: its PR was looked up on open; only its threads are new
  view.set_scope({ kind = 'layer', index = 3 })
  idle(s)
  h.eq({ 1, 2 }, { kinds(calls).lookup, kinds(calls).threads }, 'stack/ui: its threads, once')
  h.ok(kinds(calls).queries[3].q:find('pullRequest(number: 13)', 1, true), kinds(calls).queries[3].q)
  -- back to fetched layers (]s / [s), the full stack: only the never-fetched #11's threads
  press(s, '[s')
  idle(s)
  view.set_scope({ kind = 'full' })
  idle(s)
  local k = kinds(calls)
  h.eq({ 1, 3 }, { k.lookup, k.threads }, 'full stack: #11 only')
  h.ok(k.queries[4].q:find('number: 11', 1, true) and not k.queries[4].q:find('number: 12', 1, true), k.queries[4].q)
  view.set_scope({ kind = 'layer', index = 2 })
  idle(s)
  h.eq({ 1, 3 }, { kinds(calls).lookup, kinds(calls).threads }, 'every scope fetched: nothing')
  -- R: everything for the scope
  press_R(s)
  h.eq({ 2, 4 }, { kinds(calls).lookup, kinds(calls).threads }, 'R')
  h.eq(0, kinds(calls).check, 'forge.check = false: no check')
  view.close()
  -- a new review fetches again (first time in this review)
  s = open(d)
  idle(s)
  h.eq({ 3, 5 }, { kinds(calls).lookup, kinds(calls).threads }, 'a new review')
  view.close()
  setup()
end)

-- ---------------------------------------------------------------------------
-- Integration: the change check
-- ---------------------------------------------------------------------------

h.test('check: nothing changed, no mark, no redraw; not before the interval', function()
  reset()
  local calls = h.tmpdir('fc-gh-quiet') .. '/calls.ndjson'
  h.use_fake_gh(calls, base_prs(), nil, base_threads())
  local d = stack_fixture('fc-quiet')
  local s = open(d)
  idle(s)
  now = now + forge.options().interval - 1
  h.ok(not fv.maybe_check(s), 'not due yet')
  local panel = require('revuey.panel')
  local orig, renders, replaced = panel.render, 0, s.desc_replaced or 0
  panel.render = function(...)
    renders = renders + 1
    return orig(...)
  end
  local ok, err = pcall(function()
    check_now(s)
  end)
  panel.render = orig
  assert(ok, err)
  local k = kinds(calls)
  h.eq({ 1, 1, 1 }, { k.lookup, k.threads, k.check })
  h.ok(last_check(calls):find('pullRequest(number: 12)', 1, true), 'the viewed layer\'s PR only')
  h.ok(not last_check(calls):find('number: 11', 1, true), last_check(calls))
  h.eq(0, renders, 'no panel redraw')
  h.eq(replaced, s.desc_replaced or 0, 'description rows untouched')
  h.eq({}, forge.changed)
  h.ok(not panel_has(s, '↻') and not panel_has(s, 'new on GitHub'), table.concat(panel_lines(s), '\n'))
  h.ok(not fv.maybe_check(s), 'just checked: not due')
  view.close()
end)

h.test('check: news are marked everywhere they show; what is shown stays until R, which clears them', function()
  reset()
  local calls = h.tmpdir('fc-gh-marks') .. '/calls.ndjson'
  h.use_fake_gh(calls, base_prs(), nil, base_threads())
  local d = stack_fixture('fc-marks')
  local s = open(d)
  idle(s)
  h.ok(panel_has(s, '@ stack/cart | #12 ○ '), table.concat(panel_lines(s), '\n'))
  h.ok(panel_has(s, '   threads: 1 open, 1 resolved'), table.concat(panel_lines(s), '\n'))
  h.eq('PR #12 · Cart totals', first_line(s))
  -- on GitHub: the title edited and a thread resolved
  local prs, threads = base_prs(), base_threads()
  prs['acme/shop:stack/cart'][1].title = 'Cart totals, rounded'
  threads['acme/shop#12'][1].isResolved = true
  write_prs(calls, prs)
  write_threads(calls, threads)
  check_now(s)
  h.eq({ ['github.com/acme/shop#12'] = { title = true, resolved = true } }, forge.changed)
  local lines = panel_lines(s)
  h.ok(find(lines, '@ stack/cart | #12 ○↻ '), 'row chip: ' .. table.concat(lines, '\n'))
  h.ok(find(lines, ' ▾ PR #12 | ○ (new on GitHub · R)'), 'detail heading: ' .. table.concat(lines, '\n'))
  h.ok(find(lines, '   threads: 1 open, 1 resolved (new)'), 'threads line, counts as fetched: ' .. table.concat(lines, '\n'))
  h.ok(find(lines, '   Cart totals'), 'detail title as fetched')
  h.ok(not find(lines, 'rounded'), 'nothing replaced')
  h.eq('PR #12 · Cart totals · new on GitHub · R to refresh', first_line(s), 'description title, title as fetched')
  local wb = winbar_top(s)
  h.ok(wb:find('new on GitHub · R', 1, true) and wb:find('Cart totals', 1, true), wb)
  -- the marks' colour
  local ns = vim.api.nvim_get_namespaces()['revuey.panel']
  local hl
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.panel_buf, ns, 0, -1, { details = true })) do
    for _, ch in ipairs(m[4].virt_text or {}) do
      if ch[1] == '↻' then
        hl = ch[2]
      end
    end
  end
  h.eq('RevueyForgeChanged', hl)
  -- redraws, refreshes and resizes keep the marks and the data
  view.refresh({ force = true })
  idle(s)
  h.ok(panel_has(s, '#12 ○↻ ') and not panel_has(s, 'rounded'), table.concat(panel_lines(s), '\n'))
  -- R: the news shown, the marks gone
  press_R(s)
  lines = panel_lines(s)
  h.ok(find(lines, '@ stack/cart | #12 ○ '), table.concat(lines, '\n'))
  h.ok(find(lines, '   Cart totals, rounded'), table.concat(lines, '\n'))
  h.ok(find(lines, '   threads: 0 open, 2 resolved'), table.concat(lines, '\n'))
  h.ok(not find(lines, 'new on GitHub') and not find(lines, '↻'), table.concat(lines, '\n'))
  h.eq('PR #12 · Cart totals, rounded', first_line(s))
  h.eq({}, forge.changed)
  wb = winbar_top(s)
  h.ok(not wb:find('new on GitHub', 1, true), wb)
  view.close()
end)

h.test('check: each signal marks only its PR; full-stack scope checks every layer in one query', function()
  reset()
  local calls = h.tmpdir('fc-gh-each') .. '/calls.ndjson'
  h.use_fake_gh(calls, base_prs(), nil, base_threads())
  local d = stack_fixture('fc-each')
  local s = open(d)
  idle(s)
  view.set_scope({ kind = 'full' })
  idle(s)
  local cases = {
    { 'stack/math', 'head', function(p) p.headRefOid = 'pushed' end },
    { 'stack/ui', 'state', function(p) p.state = 'CLOSED' end },
    { 'stack/cart', 'draft', function(p) p.isDraft = true end },
    { 'stack/cart', 'body', function(p) p.lastEditedAt = '2026-03-01T00:00:00Z' end },
    { 'stack/ui', 'decision', function(p) p.reviewDecision = 'CHANGES_REQUESTED' end },
    { 'stack/math', 'reviews', function(p) p.reviews.totalCount = 2 end },
    { 'stack/cart', 'requested', function(p) p.reviewRequests.totalCount = 1 end },
    { 'stack/ui', 'checks', function(p) p.commits.nodes[1].commit.statusCheckRollup.state = 'PENDING' end },
  }
  local numbers = { ['stack/math'] = 11, ['stack/cart'] = 12, ['stack/ui'] = 13 }
  for _, case in ipairs(cases) do
    forge.changed = {}
    local prs = base_prs()
    case[3](prs['acme/shop:' .. case[1]][1])
    write_prs(calls, prs)
    check_now(s)
    h.eq({ ['github.com/acme/shop#' .. numbers[case[1]]] = { [case[2]] = true } }, forge.changed, case[2])
    local q = last_check(calls)
    h.ok(q:find('number: 11', 1, true) and q:find('number: 12', 1, true) and q:find('number: 13', 1, true), 'every layer: ' .. q)
  end
  write_prs(calls, base_prs())
  -- threads: a reply, a new thread
  for _, case in ipairs({
    { 'comments', function(th) table.insert(th['acme/shop#13'][1].comments, c('Fixed.')) end, 13 },
    { 'threads', function(th) table.insert(th['acme/shop#11'], t('T9', false, { c('And here?') })) end, 11 },
  }) do
    forge.changed = {}
    local th = base_threads()
    case[2](th)
    write_threads(calls, th)
    check_now(s)
    local want = { [case[1]] = true }
    if case[1] == 'threads' then
      want.comments = true -- a new thread brings its comment
    end
    h.eq({ ['github.com/acme/shop#' .. case[3]] = want }, forge.changed, case[1])
  end
  local k = kinds(calls)
  h.eq(#cases + 2, k.check, 'one call per check')
  h.eq(1, k.lookup, 'checks never fetch')
  view.close()
end)

h.test('check: a failed R keeps the data, marked stale and still new; R that works clears both', function()
  reset()
  local calls = h.tmpdir('fc-gh-failr') .. '/calls.ndjson'
  h.use_fake_gh(calls, base_prs(), nil, base_threads())
  local d = stack_fixture('fc-failr')
  local s = open(d)
  idle(s)
  local prs = base_prs()
  prs['acme/shop:stack/cart'][1].title = 'Renamed'
  write_prs(calls, prs)
  check_now(s)
  vim.env.REVUEY_FAKE_GH = 'fail'
  press_R(s)
  local lines = panel_lines(s)
  h.ok(find(lines, '@ stack/cart | #12 ○↻? '), table.concat(lines, '\n'))
  h.ok(find(lines, ' ▾ PR #12 | ○ (new on GitHub · R) (stale)'), table.concat(lines, '\n'))
  h.ok(find(lines, '   threads: 1 open, 1 resolved (stale)'), table.concat(lines, '\n'))
  h.ok(find(lines, '   Cart totals'), 'data kept')
  h.eq('PR #12 · Cart totals · new on GitHub · R to refresh', first_line(s))
  -- a failure alone: the description says stale
  forge.changed = {}
  fv.redraw_marks(s)
  vim.wait(50)
  h.eq('PR #12 · Cart totals · stale', first_line(s))
  h.ok(winbar_top(s):find('stale', 1, true), winbar_top(s))
  vim.env.REVUEY_FAKE_GH = nil
  press_R(s)
  lines = panel_lines(s)
  h.ok(find(lines, '@ stack/cart | #12 ○ ') and find(lines, '   Renamed'), table.concat(lines, '\n'))
  h.ok(not find(lines, '(stale)') and not find(lines, '↻'), table.concat(lines, '\n'))
  h.eq('PR #12 · Renamed', first_line(s))
  view.close()
end)

h.test('check: a PR merged on GitHub with a thread resolved: R clears every mark', function()
  reset()
  local calls = h.tmpdir('fc-gh-merged') .. '/calls.ndjson'
  h.use_fake_gh(calls, base_prs(), nil, base_threads())
  local d = stack_fixture('fc-merged')
  local s = open(d)
  idle(s)
  local prs, threads = base_prs(), base_threads()
  prs['acme/shop:stack/cart'][1].state = 'MERGED'
  threads['acme/shop#12'][1].isResolved = true
  write_prs(calls, prs)
  write_threads(calls, threads)
  check_now(s)
  h.eq({ ['github.com/acme/shop#12'] = { state = true, resolved = true } }, forge.changed)
  press_R(s)
  h.eq({}, forge.changed, 'a merged PR\'s threads are never fetched again: its thread marks go with the lookup')
  h.ok(not panel_has(s, '↻') and not panel_has(s, 'new on GitHub'), table.concat(panel_lines(s), '\n'))
  view.close()
end)

h.test('check: R in a layer clears the thread marks a full-stack check left on other layers', function()
  reset()
  local calls = h.tmpdir('fc-gh-otherlayer') .. '/calls.ndjson'
  h.use_fake_gh(calls, base_prs(), nil, base_threads())
  local d = stack_fixture('fc-otherlayer')
  local s = open(d)
  idle(s)
  view.set_scope({ kind = 'full' })
  idle(s)
  local threads = base_threads()
  threads['acme/shop#11'][1].isResolved = true
  write_threads(calls, threads)
  check_now(s)
  h.eq({ ['github.com/acme/shop#11'] = { resolved = true } }, forge.changed)
  view.set_scope({ kind = 'layer', index = 2 })
  idle(s)
  h.ok(panel_has(s, 'stack/math | #11 ○↻ '), table.concat(panel_lines(s), '\n'))
  press_R(s)
  h.eq({}, forge.changed)
  h.ok(panel_has(s, 'stack/math | #11 ○ '), table.concat(panel_lines(s), '\n'))
  view.close()
end)

h.test('check: a check in flight when R starts is dropped (its marks would outlive the news)', function()
  reset()
  local calls = h.tmpdir('fc-gh-race') .. '/calls.ndjson'
  h.use_fake_gh(calls, base_prs(), nil, base_threads())
  local d = stack_fixture('fc-race')
  local s = open(d)
  idle(s)
  local prs = base_prs()
  prs['acme/shop:stack/cart'][1].title = 'Renamed'
  write_prs(calls, prs)
  vim.env.REVUEY_FAKE_GH_CHECK_DELAY = '2'
  now = now + forge.options().interval
  h.ok(fv.maybe_check(s), 'check started')
  h.ok(vim.wait(5000, function()
    return s.forge.check_job ~= nil
  end, 10), 'check running')
  press_R(s) -- shows "Renamed" at once
  vim.wait(2500) -- past the slow check's answer
  idle(s)
  vim.env.REVUEY_FAKE_GH_CHECK_DELAY = nil
  h.eq({}, forge.changed)
  h.ok(panel_has(s, '   Renamed') and not panel_has(s, '↻'), table.concat(panel_lines(s), '\n'))
  view.close()
end)

h.test('check: the detail heading keeps PR #N and its state visible in a narrow panel', function()
  reset()
  local calls = h.tmpdir('fc-gh-narrow') .. '/calls.ndjson'
  local prs = base_prs()
  prs['acme/shop:stack/cart'][1].isDraft = true
  h.use_fake_gh(calls, prs, nil, base_threads())
  local d = stack_fixture('fc-narrow')
  for _, width in ipairs({ 40, 34, 26 }) do
    setup({ panel_width = width })
    reset()
    write_prs(calls, prs)
    local s = open(d)
    idle(s)
    local changed = vim.deepcopy(prs)
    changed['acme/shop:stack/cart'][1].title = 'Renamed'
    write_prs(calls, changed)
    check_now(s)
    vim.env.REVUEY_FAKE_GH = 'fail'
    press_R(s)
    vim.env.REVUEY_FAKE_GH = nil
    local raw = vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false)
    local row = find(raw, ' PR #12')
    h.ok(row, table.concat(raw, '\n'))
    local ns = vim.api.nvim_get_namespaces()['revuey.panel']
    local virt = ''
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.panel_buf, ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
      for _, ch in ipairs(m[4].virt_text or {}) do
        virt = virt .. ch[1]
      end
    end
    local win = vim.api.nvim_win_get_width(s.panel_win)
    h.ok(vim.fn.strdisplaywidth(raw[row]) + vim.fn.strdisplaywidth(virt) < win,
      ('width %d: %q beside %q in %d cells'):format(width, virt, raw[row], win))
    h.ok(virt:find('draft', 1, true), 'state shown: ' .. virt)
    h.ok(virt:find('↻', 1, true) or virt:find('new on GitHub', 1, true), 'news shown: ' .. virt)
    view.close()
  end
  setup()
end)

h.test('stale per branch: a first lookup of a new target neither clears nor sets the others\' stale', function()
  reset()
  setup({ forge = { threads = { enabled = false } } })
  local calls = h.tmpdir('fc-gh-perbranch') .. '/calls.ndjson'
  h.use_fake_gh(calls, base_prs(), nil, base_threads())
  local d = stack_fixture('fc-perbranch')
  local s = open(d)
  idle(s)
  vim.env.REVUEY_FAKE_GH = 'fail'
  press_R(s)
  vim.env.REVUEY_FAKE_GH = nil
  h.ok(panel_has(s, 'stack/cart | #12 ○? '), table.concat(panel_lines(s), '\n'))
  local before = kinds(calls).lookup
  -- `git push -u`-like: stack/ui now tracks another name: a new target, looked up once
  h.git(d, 'config', 'branch.stack/ui.remote', 'origin')
  h.git(d, 'config', 'branch.stack/ui.merge', 'refs/heads/ui-elsewhere')
  view.refresh({ force = true })
  idle(s)
  h.eq(before + 1, kinds(calls).lookup, 'the new target, once')
  local q = kinds(calls).queries[#kinds(calls).queries].q
  h.ok(q:find('ui-elsewhere', 1, true) and not q:find('stack/cart', 1, true), q)
  h.ok(panel_has(s, 'stack/cart | #12 ○? '), 'still stale: ' .. table.concat(panel_lines(s), '\n'))
  h.ok(panel_has(s, 'stack/ui | #13 ○ '), 'fetched fresh: ' .. table.concat(panel_lines(s), '\n'))
  view.close()
  setup()
end)

h.test('check: a failing check is quiet (logged, nothing marked) and waits for the next interval', function()
  reset()
  local calls = h.tmpdir('fc-gh-cfail') .. '/calls.ndjson'
  h.use_fake_gh(calls, base_prs(), nil, base_threads())
  local d = stack_fixture('fc-cfail')
  local s = open(d)
  idle(s)
  local prs = base_prs()
  prs['acme/shop:stack/cart'][1].title = 'Renamed'
  write_prs(calls, prs)
  vim.env.REVUEY_FAKE_GH_CHECK_SCENARIO = 'fail'
  local msgs, restore = h.capture_notify()
  check_now(s)
  restore()
  h.eq({}, msgs, 'no message')
  h.eq({}, forge.changed)
  h.ok(not panel_has(s, '(stale)') and not panel_has(s, '?'), 'a failed check marks nothing')
  local e = log.entries[#log.entries]
  h.ok(e and e.msg:find('change check failed', 1, true), vim.inspect(log.entries))
  h.ok(not fv.maybe_check(s), 'not retried at once')
  vim.env.REVUEY_FAKE_GH_CHECK_SCENARIO = nil
  check_now(s)
  h.eq({ ['github.com/acme/shop#12'] = { title = true } }, forge.changed)
  view.close()
end)

h.test('check: not while unfocused or hidden; at once on FocusGained or coming back when due', function()
  reset()
  local calls = h.tmpdir('fc-gh-focus') .. '/calls.ndjson'
  h.use_fake_gh(calls, base_prs(), nil, base_threads())
  local d = stack_fixture('fc-focus')
  local s = open(d)
  idle(s)
  vim.cmd('doautocmd FocusLost')
  now = now + 10 * forge.options().interval
  h.ok(not fv.maybe_check(s), 'unfocused')
  h.eq(0, kinds(calls).check)
  vim.cmd('doautocmd FocusGained')
  idle(s)
  h.eq(1, kinds(calls).check, 'FocusGained: due, checked at once')
  vim.cmd('doautocmd FocusGained')
  idle(s)
  h.eq(1, kinds(calls).check, 'FocusGained again: not due')
  -- hidden: another tab page
  vim.cmd('tabnew')
  now = now + forge.options().interval
  h.ok(not fv.maybe_check(s), 'hidden')
  vim.cmd('tabprevious')
  vim.wait(50)
  idle(s)
  h.eq(2, kinds(calls).check, 'back on the review: checked')
  vim.cmd('tabnext')
  vim.cmd('tabclose')
  view.close()
end)

h.test('check: the timer runs checks on its own and stops when the review closes', function()
  reset()
  forge.now = function()
    return vim.uv.hrtime() / 1e6
  end
  forge.MIN_INTERVAL = 0 -- the real clock, a short interval (users get at least 60s)
  setup({ forge = { ttl = 0.2 } })
  local calls = h.tmpdir('fc-gh-timer') .. '/calls.ndjson'
  h.use_fake_gh(calls, base_prs(), nil, base_threads())
  local d = stack_fixture('fc-timer')
  local s = open(d)
  idle(s)
  h.ok(s.forge.timer ~= nil, 'timer running')
  h.ok(vim.wait(5000, function()
    return kinds(calls).check >= 1
  end, 20), 'no check from the timer')
  local f = s.forge
  local timer = f.timer
  view.close()
  h.eq(nil, f.timer, 'timer stopped')
  h.ok(not timer:is_active() and timer:is_closing(), 'the timer handle stopped and closed')
  vim.wait(300)
  local n = kinds(calls).check
  vim.wait(800)
  h.eq(n, kinds(calls).check, 'no check after close')
  forge.MIN_INTERVAL = 60 * 1000
  setup()
end)

h.test('forge.check = false: no timer, no check on focus', function()
  reset()
  setup({ forge = { check = false } })
  local calls = h.tmpdir('fc-gh-off') .. '/calls.ndjson'
  h.use_fake_gh(calls, base_prs(), nil, base_threads())
  local d = stack_fixture('fc-off')
  local s = open(d)
  idle(s)
  h.eq(nil, s.forge.timer)
  now = now + 10 * forge.options().interval
  h.ok(not fv.maybe_check(s))
  vim.cmd('doautocmd FocusGained')
  idle(s)
  h.eq(0, kinds(calls).check)
  view.close()
  setup()
end)

h.run()
