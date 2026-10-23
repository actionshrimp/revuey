-- Pull requests on GitHub (forge.lua, forge_view.lua): remote URL parsing, the batched GraphQL
-- query, response mapping to row and detail models, then real git fixtures with a fake `gh`
-- (tests/bin/gh) on PATH: stacks with mixed PR states, remote layers, fork PRs, failures, the
-- TTL cache, the open-in-browser key and the base-mismatch warning.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')
local state_dir = h.tmpdir('forge-state')
local log_file = h.tmpdir('forge-log') .. '/revuey.log'
local function setup(extra)
  require('revuey').setup(vim.tbl_deep_extend('force', { state_dir = state_dir, lsp_warmup = false, log_file = log_file }, extra or {}))
end
setup()
local forge = require('revuey.forge')
local view = require('revuey.view')
local log = require('revuey.log')

-- ---------------------------------------------------------------------------
-- Unit
-- ---------------------------------------------------------------------------

h.test('parse_remote_url: ssh, scp-like, https, ssh aliases, enterprise hosts; not local paths', function()
  local function p(url, hosts)
    local r = forge.parse_remote_url(url, hosts)
    return r and (r.host .. ' ' .. r.owner .. '/' .. r.name) or nil
  end
  h.eq('github.com acme/shop', p('git@github.com:acme/shop.git'))
  h.eq('github.com acme/shop', p('github.com:acme/shop'))
  h.eq('github.com acme/shop', p('https://github.com/acme/shop'))
  h.eq('github.com acme/shop', p('https://github.com/acme/shop.git/'))
  h.eq('github.com acme/shop', p('https://user:token@github.com/acme/shop.git'))
  h.eq('github.com acme/shop', p('ssh://git@github.com:22/acme/shop.git'))
  h.eq('github.com acme/shop', p('ssh://git@ssh.github.com:443/acme/shop.git'))
  h.eq('github.com acme/shop', p('git@github.com-work:acme/shop.git'), 'ssh config alias')
  h.eq('github.example.com acme/shop', p('https://github.example.com/acme/shop'))
  h.eq('git.corp.net team/app', p('git@git.corp.net:team/app.git', { 'git.corp.net' }))
  h.eq(nil, p('git@git.corp.net:team/app.git'))
  h.eq(nil, p('https://gitlab.com/acme/shop.git'))
  h.eq(nil, p('/tmp/x/upstream.git'))
  h.eq(nil, p('./upstream.git'))
  h.eq(nil, p('file:///tmp/x/upstream.git'))
  h.eq(nil, p('https://github.com/acme'))
end)

h.test('build_query: one aliased lookup per (repo, branch), literals escaped, all fields asked', function()
  local q, aliases = forge.build_query({
    { repo = { host = 'github.com', owner = 'acme', name = 'shop' }, branch = 'stack/math' },
    { repo = { host = 'github.com', owner = 'me', name = 'shop' }, branch = 'we"ird' },
  })
  h.ok(q:find('l1: repository(owner: "acme", name: "shop") { pullRequests(headRefName: "stack/math"', 1, true), q)
  h.ok(q:find('l2: repository(owner: "me", name: "shop") { pullRequests(headRefName: "we\\"ird"', 1, true), q)
  h.eq('stack/math', aliases.l1.branch)
  for _, field in ipairs({ 'number', 'title', 'url', 'state', 'isDraft', 'author', 'reviewDecision', 'latestReviews',
    'reviewRequests', 'statusCheckRollup', 'checkRunCountsByState', 'statusContextCountsByState', 'mergeable',
    'baseRefName', 'headRefName', 'headRepositoryOwner' }) do
    h.ok(q:find(field, 1, true), 'query asks for ' .. field)
  end
end)

---A PullRequest node as GitHub returns it.
local function node(o)
  return {
    number = o.number,
    title = o.title or ('PR ' .. o.number),
    url = 'https://github.com/' .. (o.repo or 'acme/shop') .. '/pull/' .. o.number,
    state = o.state or 'OPEN',
    isDraft = o.draft or false,
    author = { login = o.author or 'alice' },
    reviewDecision = o.decision or vim.NIL,
    latestReviews = { nodes = o.reviews or {} },
    reviewRequests = { nodes = vim.tbl_map(function(n)
      return { requestedReviewer = n:sub(1, 1) == '@' and { __typename = 'Team', slug = n:sub(2) } or { __typename = 'User', login = n } }
    end, o.requested or {}) },
    mergeable = o.mergeable or 'MERGEABLE',
    baseRefName = o.base or 'main',
    headRefName = o.head or 'x',
    headRepositoryOwner = o.head_owner == false and vim.NIL or { login = o.head_owner or 'acme' },
    headRefOid = o.oid or vim.NIL,
    updatedAt = o.updated or '2026-01-01T00:00:00Z',
    commits = { nodes = { { commit = { statusCheckRollup = o.checks and {
      state = 'PENDING',
      contexts = {
        checkRunCountsByState = {
          { state = 'SUCCESS', count = o.checks[1] }, { state = 'FAILURE', count = o.checks[2] },
          { state = 'IN_PROGRESS', count = o.checks[3] }, { state = 'SKIPPED', count = 0 },
        },
        statusContextCountsByState = { { state = 'SUCCESS', count = 0 }, { state = 'PENDING', count = 0 } },
      },
    } or vim.NIL } } } },
  }
end

local function decoded(n)
  -- through JSON, as from gh (vim.NIL -> nil)
  return forge.normalize(vim.json.decode(vim.json.encode(n), { luanil = { object = true, array = true } }), 'github.com/acme/shop')
end

h.test('normalize: reviews, requested reviewers (users and teams), check counts', function()
  local pr = decoded(node({
    number = 7, decision = 'CHANGES_REQUESTED', checks = { 12, 1, 2 }, requested = { 'bob', '@core' },
    reviews = { { author = { login = 'carol' }, state = 'CHANGES_REQUESTED' }, { author = vim.NIL, state = 'COMMENTED' } },
  }))
  h.eq(7, pr.number)
  h.eq('CHANGES_REQUESTED', pr.review_decision)
  h.eq({ { author = 'carol', state = 'CHANGES_REQUESTED' }, { author = 'ghost', state = 'COMMENTED' } }, pr.reviews)
  h.eq({ 'bob', 'core' }, pr.requested)
  h.eq({ success = 12, failure = 1, pending = 2, total = 15 }, pr.checks)
  h.eq('12 passed, 1 failed, 2 pending', forge.checks_text(pr.checks))
  local none = decoded(node({ number = 8 }))
  h.eq(nil, none.review_decision)
  h.eq(0, none.checks.total)
  h.eq(nil, forge.checks_text(none.checks))
end)

h.test('pick: OPEN first, else the newest MERGED/CLOSED; fork PRs of other owners ignored', function()
  local prs = vim.tbl_map(decoded, {
    node({ number = 2, state = 'MERGED', updated = '2026-01-02T00:00:00Z' }),
    node({ number = 5, state = 'OPEN', head_owner = 'someone', updated = '2026-01-05T00:00:00Z' }),
    node({ number = 4, state = 'OPEN', updated = '2026-01-04T00:00:00Z' }),
    node({ number = 9, state = 'CLOSED', updated = '2026-01-09T00:00:00Z' }), -- newest, from another repo
    node({ number = 6, state = 'OPEN', head_owner = false }), -- deleted fork: nobody's
  })
  h.eq(4, forge.pick(prs, 'acme').number)
  h.eq(5, forge.pick(prs, 'someone').number)
  h.eq(9, forge.pick({ prs[1], prs[4] }, 'acme').number, 'by updatedAt, not input order')
  h.eq(nil, forge.pick({ prs[2] }, 'acme'))
  h.eq(nil, forge.pick({ prs[5] }, 'acme'), 'a null head owner is not ours')
  h.eq(nil, forge.pick({}, 'acme'))
  -- closed/merged PRs only when `accept` vouches for their head commit; open ones by name
  h.eq(2, forge.pick({ prs[1], prs[4] }, 'acme', function(pr)
    return pr.number == 2
  end).number)
  h.eq(nil, forge.pick({ prs[1], prs[4] }, 'acme', function()
    return false
  end))
  h.eq(4, forge.pick({ prs[3], prs[4] }, 'acme', function()
    return false
  end).number)
end)

h.test('panel.wrap breaks words wider than the panel by display width (long names, CJK)', function()
  local wrap = require('revuey.panel').wrap
  local lines = wrap('base: dave/very-long-branch-name-for-the-cart-feature', 26, '   ')
  for _, l in ipairs(lines) do
    h.ok(vim.fn.strdisplaywidth(l) <= 26, l)
  end
  h.eq('base:dave/very-long-branch-name-for-the-cart-feature', (table.concat(lines, ''):gsub('%s', '')))
  local cjk = wrap('購物車合計と割引を追加するプルリクエストのタイトルです', 20, '   ')
  for _, l in ipairs(cjk) do
    h.ok(vim.fn.strdisplaywidth(l) <= 20, l)
  end
  h.ok(#cjk >= 3, vim.inspect(cjk))
end)

h.test('log: rotates revuey.log at its size limit, keeping one .1', function()
  local dir = h.tmpdir('forge-log-rotate')
  setup({ log_file = dir .. '/revuey.log' })
  local max = log.max_bytes
  log.max_bytes = 200
  for i = 1, 20 do
    log.write('forge', 'line ' .. i)
  end
  log.max_bytes = max
  h.ok(vim.uv.fs_stat(dir .. '/revuey.log.1'), 'rotated')
  h.ok(vim.uv.fs_stat(dir .. '/revuey.log').size <= 200 + 80, 'current file small')
  h.eq(nil, vim.uv.fs_stat(dir .. '/revuey.log.2'))
  h.ok(table.concat(vim.fn.readfile(dir .. '/revuey.log'), '\n'):find('line 20', 1, true))
  setup()
end)

h.test('row model: glyph by review decision; draft, merged and closed are dim with a marker', function()
  local function row(o)
    local m = forge.row(decoded(node(vim.tbl_extend('force', { number = 3 }, o))))
    return { m.number, m.number_hl, m.glyph, m.glyph_hl, m.marker, m.marker_hl }
  end
  h.eq({ '#3', 'RevueyForgeNumber', '✓', 'RevueyForgeApproved' }, row({ decision = 'APPROVED' }))
  h.eq({ '#3', 'RevueyForgeNumber', '✗', 'RevueyForgeChanges' }, row({ decision = 'CHANGES_REQUESTED' }))
  h.eq({ '#3', 'RevueyForgeNumber', '●', 'RevueyForgePending' }, row({ decision = 'REVIEW_REQUIRED' }))
  h.eq({ '#3', 'RevueyForgeNumber', '○', 'RevueyForgeNone' }, row({}), 'no review decision')
  h.eq({ '#3', 'RevueyForgeDim', nil, nil, 'draft', 'RevueyForgeDraft' }, row({ draft = true, decision = 'APPROVED' }))
  h.eq({ '#3', 'RevueyForgeDim', nil, nil, 'merged', 'RevueyForgeMerged' }, row({ state = 'MERGED', decision = 'APPROVED' }))
  h.eq({ '#3', 'RevueyForgeDim', nil, nil, 'closed', 'RevueyForgeClosed' }, row({ state = 'CLOSED' }))
end)

h.test('detail model: title, author/state, decision, reviewers, checks, mergeable, base and mismatch', function()
  local pr = decoded(node({
    number = 12, title = 'Cart totals', decision = 'APPROVED', checks = { 12, 1, 2 }, requested = { 'bob' },
    reviews = { { author = { login = 'carol' }, state = 'APPROVED' } }, base = 'stack/math', draft = true,
  }))
  local function texts(d)
    return vim.tbl_map(function(i)
      return (i.glyph and (i.glyph .. ' ') or '') .. i.text
    end, d)
  end
  h.eq({
    'Cart totals', 'by alice · open · draft', '✓ approved', '✓ carol approved', '○ bob requested',
    'checks: 12 passed, 1 failed, 2 pending', 'mergeable', 'base: stack/math',
  }, texts(forge.detail(pr, 'stack/math')))
  local d = forge.detail(pr, 'stack/cart')
  h.eq('⚠ GitHub base stack/math, stack parent stack/cart', texts(d)[#d])
  h.eq('RevueyForgeWarn', d[#d].hl)
  -- merged: no mergeable line, no mismatch warning (GitHub retargets merged PRs' children)
  local merged = decoded(node({ number = 3, state = 'MERGED', mergeable = 'UNKNOWN' }))
  h.eq({ 'PR 3', 'by alice · merged', '○ no review decision', 'checks: none', 'base: main' }, texts(forge.detail(merged, 'other')))
  local required = decoded(node({ number = 5, decision = 'REVIEW_REQUIRED' }))
  h.eq('● review required', texts(forge.detail(required))[3])
  local conflict = decoded(node({ number = 4, mergeable = 'CONFLICTING' }))
  h.eq('conflicts with base', texts(forge.detail(conflict))[5])
end)

h.test('decode: unparsable output and GraphQL errors', function()
  local data, errs = forge.decode('<html>')
  h.eq(nil, data)
  h.ok(errs[1]:find('unparsable', 1, true))
  data, errs = forge.decode('{"data":{"l1":null},"errors":[{"message":"Could not resolve to a Repository"}]}')
  h.eq({}, vim.tbl_keys(data))
  h.eq({ 'Could not resolve to a Repository' }, errs)
end)

-- ---------------------------------------------------------------------------
-- Integration (fake gh)
-- ---------------------------------------------------------------------------

local GH_URL = 'git@github.com:acme/shop.git'

local function stack_fixture(name)
  local d = h.tmpdir(name)
  vim.fn.delete(d, 'rf')
  local res = vim.system({ h.root .. '/scripts/make-fixture.sh', '--stack', d }, { text = true }):wait()
  assert(res.code == 0, res.stderr)
  h.git(d, 'remote', 'add', 'origin', GH_URL)
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

---Wait until refreshes and the PR lookup are done.
local function idle(s)
  assert(vim.wait(10000, function()
    return not s.refreshing and not s.pending and not s.pending_scope
      and (not require('revuey.forge_view').enabled() or (s.forge and s.forge.ready and not s.forge.busy and not s.forge.scheduled))
  end, 10), 'refresh / PR lookup did not finish')
  vim.wait(50) -- scheduled redraws
end

---Panel lines with their right-aligned virtual text appended after ` | `.
local function panel_lines(s)
  local lines = vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false)
  local ns = vim.api.nvim_get_namespaces()['revuey.panel']
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.panel_buf, ns, 0, -1, { details = true })) do
    if m[4].virt_text then
      local t = table.concat(vim.tbl_map(function(c)
        return c[1]
      end, m[4].virt_text))
      lines[m[2] + 1] = lines[m[2] + 1] .. ' | ' .. t
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

---Highlight group of the virt-text chunk `text` on panel row `row`.
local function virt_hl(s, row, text)
  local ns = vim.api.nvim_get_namespaces()['revuey.panel']
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.panel_buf, ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    for _, c in ipairs(m[4].virt_text or {}) do
      if c[1] == text then
        return c[2]
      end
    end
  end
end

local function reset()
  forge.cache = {}
  log.entries = {}
  forge.now = function()
    return vim.uv.hrtime() / 1e6
  end
end

-- the fixture's dates are fixed, so its commits are the same in every copy
local MATH_TIP = vim.trim(h.git(stack_fixture('forge-tip'), 'rev-parse', 'stack/math'))

local stack_prs = {
  -- merged: shown because its head commit is stack/math's tip
  ['acme/shop:stack/math'] = { node({ number = 11, state = 'MERGED', head = 'stack/math', title = 'Math helpers', oid = MATH_TIP }) },
  ['acme/shop:stack/cart'] = {
    node({
      number = 12, title = 'Cart totals with discounts and a rather long title that wraps', head = 'stack/cart',
      base = 'stack/math', decision = 'APPROVED', checks = { 12, 1, 2 }, requested = { 'bob' },
      reviews = { { author = { login = 'carol' }, state = 'APPROVED' } },
    }),
  },
  -- stack/ui: no PR
}

h.test('3-layer stack: one gh call; rows show #N with state; detail section of the viewed layer', function()
  reset()
  local calls = h.tmpdir('forge-gh-stack') .. '/calls.ndjson'
  h.use_fake_gh(calls, stack_prs)
  local d = stack_fixture('forge-stack')
  local s = open(d)
  idle(s)
  local c = h.read_calls(calls)
  h.eq(1, #c, 'one batched call')
  h.eq({ 'gh', 'api', 'graphql', '-f' }, vim.list_slice(c[1].argv, 1, 4))
  local q = c[1].argv[5]
  for _, b in ipairs({ 'stack/math', 'stack/cart', 'stack/ui' }) do
    h.ok(q:find('headRefName: "' .. b .. '"', 1, true), 'asks for ' .. b)
  end
  local lines = panel_lines(s)
  local r1, l1 = find(lines, 'stack/math')
  h.ok(l1:find('| #11 merged 1c', 1, true), l1)
  h.eq('RevueyForgeDim', virt_hl(s, r1, '#11'))
  h.eq('RevueyForgeMerged', virt_hl(s, r1, ' merged'))
  local r2, l2 = find(lines, '@ stack/cart')
  h.ok(l2:find('| #12 ✓ ', 1, true), l2)
  h.eq('RevueyForgeApproved', virt_hl(s, r2, ' ✓'))
  local _, l3 = find(lines, 'stack/ui')
  h.ok(not l3:find('#', 1, true), 'no PR for stack/ui: ' .. l3)
  -- the detail section of stack/cart (the viewed layer)
  local hr = find(lines, ' ▾ PR #12')
  h.ok(hr, table.concat(lines, '\n'))
  local detail = vim.list_slice(lines, hr, hr + 11)
  h.eq({
    ' ▾ PR #12 | ✓',
    '   Cart totals with discounts and a',
    '   rather long title that wraps',
    '   by alice · open',
    '   ✓ approved',
    '     ✓ carol approved',
    '     ○ bob requested',
    '   checks: 12 passed, 1 failed, 2',
    '   pending',
    '   mergeable',
    '   base: stack/math',
    '',
  }, detail)
  h.ok(find(lines, ' gx PR in browser  <Tab> PR details'), 'help line')
  -- <Tab> on the heading folds the details, again unfolds them
  vim.api.nvim_set_current_win(s.panel_win)
  vim.api.nvim_win_set_cursor(s.panel_win, { hr, 0 })
  vim.api.nvim_feedkeys(vim.keycode('<Tab>'), 'mtx', false)
  lines = panel_lines(s)
  h.eq(' ▸ PR #12 | ✓', lines[hr])
  h.eq('', lines[hr + 1])
  vim.api.nvim_feedkeys(vim.keycode('<Tab>'), 'mtx', false)
  h.eq(' ▾ PR #12 | ✓', panel_lines(s)[hr])
  -- the open key: a layer row opens its PR, anywhere else the viewed layer's
  local opened = {}
  local orig = vim.ui.open
  vim.ui.open = function(url)
    opened[#opened + 1] = url
  end
  vim.api.nvim_win_set_cursor(s.panel_win, { r1, 0 })
  vim.api.nvim_feedkeys('gx', 'mtx', false)
  vim.api.nvim_win_set_cursor(s.panel_win, { #lines - 1, 0 })
  vim.api.nvim_feedkeys('gx', 'mtx', false)
  local msgs, restore = h.capture_notify()
  local r3 = find(panel_lines(s), 'stack/ui')
  vim.api.nvim_win_set_cursor(s.panel_win, { r3, 0 })
  vim.api.nvim_feedkeys('gx', 'mtx', false)
  restore()
  vim.ui.open = orig
  h.eq({ 'https://github.com/acme/shop/pull/11', 'https://github.com/acme/shop/pull/12' }, opened)
  h.eq('revuey: no pull request found for stack/ui', msgs[1] and msgs[1].msg)
  h.eq(1, #h.read_calls(calls), 'still one call')
  -- no detail section for a layer without a PR, nor in full scope
  view.set_scope({ kind = 'layer', index = 3 })
  idle(s)
  h.ok(not find(panel_lines(s), 'PR #'), 'no detail for stack/ui')
  view.set_scope({ kind = 'full' })
  idle(s)
  lines = panel_lines(s)
  h.ok(not find(lines, ' ▾ PR #'), 'no detail in full scope')
  h.ok(find(lines, '| #12 ✓ '), 'rows keep their PRs')
  h.eq(1, #h.read_calls(calls), 'scope switches use the cache')
  view.close()
end)

h.test('base mismatch: the PR targets another base than the layer\'s parent in the stack', function()
  reset()
  local calls = h.tmpdir('forge-gh-mismatch') .. '/calls.ndjson'
  h.use_fake_gh(calls, {
    ['acme/shop:stack/ui'] = { node({ number = 13, head = 'stack/ui', base = 'main', draft = true }) },
    ['acme/shop:stack/cart'] = { node({ number = 12, head = 'stack/cart', base = 'stack/math' }) },
  })
  local d = stack_fixture('forge-mismatch')
  local s = open(d)
  idle(s)
  local lines = panel_lines(s)
  h.ok(find(lines, '   base: stack/math'), 'cart matches')
  h.ok(not find(lines, '⚠ GitHub base'), 'no warning for cart')
  local _, ui = find(lines, 'stack/ui')
  h.ok(ui:find('| #13 draft ', 1, true), ui)
  view.set_scope({ kind = 'layer', index = 3 })
  idle(s)
  lines = panel_lines(s)
  local w, wl = find(lines, '⚠ GitHub base main, stack parent')
  h.ok(w, table.concat(lines, '\n'))
  h.ok((wl .. lines[w + 1]):find('stack/cart', 1, true), wl)
  h.ok(find(lines, '   by alice · open · draft'), 'draft in detail')
  view.close()
end)

h.test('remote-layer stack: branch names on the remote, without the remote prefix', function()
  reset()
  local calls = h.tmpdir('forge-gh-remote') .. '/calls.ndjson'
  h.use_fake_gh(calls, {
    ['acme/shop:stack/math'] = { node({ number = 21, head = 'stack/math', decision = 'CHANGES_REQUESTED' }) },
    ['acme/shop:stack/cart'] = { node({ number = 22, head = 'stack/cart', base = 'stack/math', decision = 'REVIEW_REQUIRED' }) },
    ['acme/shop:stack/ui'] = { node({ number = 23, head = 'stack/ui', base = 'stack/cart' }) },
  })
  local d = h.tmpdir('forge-remote')
  vim.fn.delete(d, 'rf')
  assert(vim.system({ h.root .. '/scripts/make-fixture.sh', '--remote-stack', d }):wait().code == 0)
  h.git(d .. '/review', 'remote', 'set-url', 'origin', 'https://github.com/acme/shop.git')
  local s = open(d .. '/review')
  idle(s)
  local c = h.read_calls(calls)
  h.eq(1, #c)
  h.ok(not c[1].argv[5]:find('origin/', 1, true), 'no remote prefix in the query')
  local lines = panel_lines(s)
  local r1, l1 = find(lines, 'origin/stack/ma')
  h.ok(l1:find('| ro #21 ✗ ', 1, true), l1)
  h.eq('RevueyForgeChanges', virt_hl(s, r1, ' ✗'))
  local r2, l2 = find(lines, 'origin/stack/ca')
  h.ok(l2:find('| ro #22 ● ', 1, true), l2)
  h.eq('RevueyForgePending', virt_hl(s, r2, ' ●'))
  -- viewing the detached top layer: its PR's base matches its parent origin/stack/cart
  h.ok(find(lines, ' ▾ PR #23'), table.concat(lines, '\n'))
  h.ok(find(lines, '   base: stack/cart'), 'base')
  h.ok(not find(lines, '⚠ GitHub base'), 'remote prefix stripped from the parent')
  view.close()
end)

h.test('fork PR: the branch\'s upstream is a fork; its PR in the base repo is found by head owner', function()
  reset()
  local calls = h.tmpdir('forge-gh-fork') .. '/calls.ndjson'
  h.use_fake_gh(calls, {
    ['acme/shop:my-feat'] = {
      node({ number = 31, head = 'my-feat', head_owner = 'someone' }), -- same branch name, other fork
      node({ number = 30, head = 'my-feat', head_owner = 'me', decision = 'APPROVED', title = 'Fork work' }),
    },
  })
  local d = h.repo('forge-fork', { ['a.txt'] = 'a\n' }, { ['a.txt'] = 'b\n' })
  h.git(d, 'remote', 'add', 'origin', 'git@github.com:acme/shop.git')
  h.git(d, 'remote', 'add', 'fork', 'https://github.com/me/shop')
  h.git(d, 'config', 'branch.feat.remote', 'fork')
  h.git(d, 'config', 'branch.feat.merge', 'refs/heads/my-feat')
  local s = open(d, { base = 'main' })
  idle(s)
  local c = h.read_calls(calls)
  h.eq(1, #c, 'base repo and fork in one call')
  h.ok(c[1].argv[5]:find('owner: "acme", name: "shop") { pullRequests(headRefName: "my-feat"', 1, true), c[1].argv[5])
  h.ok(c[1].argv[5]:find('owner: "me", name: "shop") { pullRequests(headRefName: "my-feat"', 1, true), c[1].argv[5])
  local lines = panel_lines(s)
  -- a plain review: the PR is on the title line, and the detail section is shown
  h.ok(find(lines, ' feat → main | #30 ✓ '), table.concat(lines, '\n'))
  h.ok(find(lines, ' ▾ PR #30 | ✓'), 'detail')
  h.ok(find(lines, '   Fork work'), 'title')
  local opened
  local orig = vim.ui.open
  vim.ui.open = function(url)
    opened = url
  end
  vim.api.nvim_set_current_win(s.panel_win)
  vim.api.nvim_win_set_cursor(s.panel_win, { 1, 0 })
  vim.api.nvim_feedkeys('gx', 'mtx', false)
  vim.ui.open = orig
  h.eq('https://github.com/acme/shop/pull/30', opened)
  view.close()
end)

h.test('gh failing, missing, rate limited or unparsable: no UI change, a log entry', function()
  local d = stack_fixture('forge-fail')
  setup({ forge = { enabled = false } })
  reset()
  local s = open(d)
  idle(s)
  local baseline = panel_lines(s)
  h.eq(nil, s.forge, 'disabled: nothing at all')
  view.close()
  for _, case in ipairs({
    { scenario = 'fail', expect = 'exited 1: error connecting' },
    { scenario = 'garbage', expect = 'unparsable output' },
    { scenario = 'ratelimit', expect = 'API rate limit exceeded' },
    { scenario = 'errors', expect = 'Something went wrong' },
    { missing = true, expect = 'could not run' },
  }) do
    reset()
    local calls = h.tmpdir('forge-gh-fail-' .. (case.scenario or 'missing')) .. '/calls.ndjson'
    h.use_fake_gh(calls, stack_prs, case.scenario)
    setup(case.missing and { forge = { cmd = 'revuey-no-such-gh' } } or nil)
    local msgs, restore = h.capture_notify()
    s = open(d)
    idle(s)
    restore()
    local name = case.scenario or 'missing'
    h.eq(baseline, panel_lines(s), name .. ': panel unchanged')
    h.eq({}, vim.tbl_filter(function(m)
      return m.level and m.level >= vim.log.levels.WARN
    end, msgs), name .. ': no messages')
    local entry = log.entries[#log.entries]
    h.ok(entry and entry.scope == 'forge' and entry.msg:find(case.expect, 1, true), name .. ': ' .. vim.inspect(log.entries))
    h.eq(case.missing and 0 or 1, #h.read_calls(calls), name .. ': calls')
    view.close()
  end
  local file = table.concat(vim.fn.readfile(log_file), '\n')
  h.ok(file:find('[forge] PR lookup failed: ', 1, true), file)
  setup()
end)

h.test('no GitHub remote: no gh call, nothing shown', function()
  reset()
  local calls = h.tmpdir('forge-gh-noremote') .. '/calls.ndjson'
  h.use_fake_gh(calls, stack_prs)
  local d = h.repo('forge-noremote', { ['a.txt'] = 'a\n' }, { ['a.txt'] = 'b\n' })
  h.git(d, 'remote', 'add', 'origin', '/tmp/somewhere/upstream.git')
  local s = open(d, { base = 'main' })
  idle(s)
  h.eq(0, #h.read_calls(calls))
  h.eq({}, log.entries)
  h.ok(not find(panel_lines(s), 'PR #'), 'nothing shown')
  view.close()
end)

h.test('narrow panel: the branch name is cut before the PR chip (then the commit count goes)', function()
  reset()
  local calls = h.tmpdir('forge-gh-narrow') .. '/calls.ndjson'
  h.use_fake_gh(calls, stack_prs)
  setup({ panel_width = 26 })
  local d = stack_fixture('forge-narrow')
  local s = open(d)
  idle(s)
  local lines = panel_lines(s)
  local _, cart = find(lines, '@ stack')
  h.ok(cart:find('| #12 ✓ 2f ✓0/2', 1, true), 'chip kept, commit count dropped: ' .. cart)
  h.ok(cart:find('…', 1, true), 'name cut: ' .. cart)
  -- the detail section wraps to the panel
  local raw = vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false)
  local hr = find(raw, 'PR #12')
  for i = hr, hr + 10 do
    h.ok(vim.fn.strdisplaywidth(raw[i]) <= 26, 'fits: ' .. raw[i])
  end
  view.close()
  setup()
end)

---`R` in the diff window.
local function press_R(s)
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_feedkeys('R', 'mtx', false)
end

h.test('TTL cache: open, scope switches and redraws reuse it; R always refetches; lazy after the TTL', function()
  reset()
  local t = 1000000
  forge.now = function()
    return t
  end
  local calls = h.tmpdir('forge-gh-ttl') .. '/calls.ndjson'
  h.use_fake_gh(calls, stack_prs)
  setup({ forge = { ttl = 30 } })
  local d = stack_fixture('forge-ttl')
  local s = open(d)
  idle(s)
  h.eq(1, #h.read_calls(calls))
  view.refresh({ force = true }) -- an auto refresh that re-renders
  idle(s)
  view.set_scope({ kind = 'layer', index = 1 })
  idle(s)
  t = t + 29 * 1000
  require('revuey.panel').render(s)
  idle(s)
  h.eq(1, #h.read_calls(calls), 'within the TTL: cached')
  local _, restore = h.capture_notify()
  press_R(s)
  idle(s)
  h.eq(2, #h.read_calls(calls), 'R within the TTL: fetched again')
  -- R pressed repeatedly: the one in-flight lookup absorbs them (at most one follow-up)
  press_R(s)
  press_R(s)
  press_R(s)
  idle(s)
  restore()
  local n = #h.read_calls(calls)
  h.ok(n >= 3 and n <= 4, 'repeated R: ' .. n .. ' calls')
  h.ok(find(panel_lines(s), '| #12 ✓ '), 'still shown')
  -- lazily, when the panel is redrawn after the TTL (no polling)
  t = t + 31 * 1000
  require('revuey.panel').render(s)
  idle(s)
  h.eq(n + 1, #h.read_calls(calls), 'panel redraw after the TTL: fetched again')
  view.close()
  setup()
end)

h.test('R after gh was fixed shows the PR at once (a cached failure is skipped)', function()
  reset()
  local calls = h.tmpdir('forge-gh-fixed') .. '/calls.ndjson'
  h.use_fake_gh(calls, stack_prs, 'fail')
  local d = stack_fixture('forge-fixed')
  local s = open(d)
  idle(s)
  h.ok(not find(panel_lines(s), '#12'), 'nothing while gh fails')
  vim.env.REVUEY_FAKE_GH = nil -- e.g. after `gh auth login`
  view.refresh({ force = true }) -- not R: the failure stays cached
  idle(s)
  h.eq(1, #h.read_calls(calls))
  local _, restore = h.capture_notify()
  press_R(s)
  idle(s)
  restore()
  h.eq(2, #h.read_calls(calls))
  h.ok(find(panel_lines(s), '| #12 ✓ '), 'shown after R')
  view.close()
end)

h.test('a branch tracking another name (created from origin/main): looked up by its own name', function()
  reset()
  local calls = h.tmpdir('forge-gh-track') .. '/calls.ndjson'
  h.use_fake_gh(calls, {
    ['acme/shop:feat'] = { node({ number = 42, head = 'feat', decision = 'APPROVED' }) },
    ['acme/shop:main'] = { node({ number = 1, head = 'main', base = 'release' }) },
  })
  local d = h.repo('forge-track', { ['a.txt'] = 'a\n' }, { ['a.txt'] = 'b\n' })
  h.git(d, 'remote', 'add', 'origin', 'git@github.com:acme/shop.git')
  h.git(d, 'config', 'branch.feat.remote', 'origin')
  h.git(d, 'config', 'branch.feat.merge', 'refs/heads/main')
  local s = open(d, { base = 'main' })
  idle(s)
  local q = h.read_calls(calls)[1].argv[5]
  h.ok(q:find('headRefName: "feat"', 1, true), q)
  h.ok(not q:find('headRefName: "main"', 1, true), 'never the trunk it tracks: ' .. q)
  h.ok(find(panel_lines(s), ' feat → main | #42 ✓ '), table.concat(panel_lines(s), '\n'))
  view.close()
  local origin = { url = 'git@github.com:acme/shop.git', repo = forge.parse_remote_url('git@github.com:acme/shop.git') }
  local function branches(b)
    local ts = forge.targets({ stack = { trunk = 'main', layers = { { name = 'feat', tip = 'x' } } } }, {
      names = { 'origin' }, remotes = { origin = origin }, branches = { feat = b }, resolved = {},
    })
    return vim.tbl_map(function(c)
      return c.branch
    end, ts.feat.candidates)
  end
  -- upstream is the trunk: never used
  h.eq({ 'feat' }, branches({ up_remote = 'origin', up_ref = 'refs/heads/main' }))
  -- own name first, then the push name, a differently named upstream last
  h.eq({ 'feat', 'dave/feat', 'team/feat' }, branches({
    up_remote = 'origin', up_ref = 'refs/heads/team/feat', push_remote = 'origin', push_ref = 'refs/heads/dave/feat',
  }))
end)

---A repo whose `feat` and `main` track `<track>/`, with remotes { {name, url} }.
local function remotes_repo(name, remotes, track, extra)
  local d = h.repo(name, { ['a.txt'] = 'a\n' }, { ['a.txt'] = 'b\n' })
  for _, r in ipairs(remotes) do
    h.git(d, 'remote', 'add', r[1], r[2])
  end
  h.git(d, 'config', 'branch.feat.remote', track)
  h.git(d, 'config', 'branch.feat.merge', 'refs/heads/feat')
  h.git(d, 'config', 'branch.main.remote', track)
  h.git(d, 'config', 'branch.main.merge', 'refs/heads/main')
  for k, v in pairs(extra or {}) do
    h.git(d, 'config', k, v)
  end
  return d
end

local function lookups(calls)
  local out = {}
  local q = h.read_calls(calls)[1].argv[5]
  for o, n, b in q:gmatch('l%d+: repository%(owner: (%b""), name: (%b"")%) { pullRequests%(headRefName: (%b"")') do
    out[#out + 1] = vim.json.decode(o) .. '/' .. vim.json.decode(n) .. ':' .. vim.json.decode(b)
  end
  table.sort(out)
  return out
end

h.test('fork as origin, parent as upstream: the PR in the parent repo is found', function()
  reset()
  local calls = h.tmpdir('forge-gh-fork-up') .. '/calls.ndjson'
  h.use_fake_gh(calls, { ['acme/shop:feat'] = { node({ number = 50, head = 'feat', head_owner = 'me' }) } })
  local d = remotes_repo('forge-fork-up', { { 'origin', 'git@github.com:me/shop.git' }, { 'upstream', 'git@github.com:acme/shop.git' } }, 'origin')
  local s = open(d, { base = 'main' })
  idle(s)
  h.eq({ 'acme/shop:feat', 'me/shop:feat' }, lookups(calls))
  h.ok(not h.read_calls(calls)[1].argv[5]:find('parent {', 1, true), 'an explicit base: no parent lookups')
  h.ok(find(panel_lines(s), ' feat → main | #50 '), table.concat(panel_lines(s), '\n'))
  view.close()
end)

h.test('fork as origin, no upstream remote: the fork\'s parent is asked in the same request', function()
  reset()
  local calls = h.tmpdir('forge-gh-fork-parent') .. '/calls.ndjson'
  h.use_fake_gh(calls, {
    _parents = { ['me/shop'] = 'acme/shop' },
    ['acme/shop:feat'] = { node({ number = 51, head = 'feat', head_owner = 'me' }) },
  })
  local d = remotes_repo('forge-fork-parent', { { 'origin', 'git@github.com:me/shop.git' } }, 'origin')
  local s = open(d, { base = 'main' })
  idle(s)
  h.eq(1, #h.read_calls(calls))
  h.eq({ 'me/shop:feat' }, lookups(calls))
  h.ok(h.read_calls(calls)[1].argv[5]:find('parent { nameWithOwner pullRequests(headRefName: "feat"', 1, true), 'parent asked')
  h.ok(find(panel_lines(s), ' feat → main | #51 '), table.concat(panel_lines(s), '\n'))
  view.close()
end)

h.test('gh-resolved base remote (gh repo set-default) wins over upstream and origin', function()
  reset()
  local calls = h.tmpdir('forge-gh-resolved') .. '/calls.ndjson'
  h.use_fake_gh(calls, { ['corp/shop:feat'] = { node({ number = 52, head = 'feat', head_owner = 'me' }) } })
  local d = remotes_repo('forge-resolved', {
    { 'origin', 'git@github.com:me/shop.git' },
    { 'upstream', 'git@github.com:acme/shop.git' },
    { 'corp', 'git@github.com:corp/shop.git' },
  }, 'origin', { ['remote.corp.gh-resolved'] = 'base' })
  local s = open(d, { base = 'main' })
  idle(s)
  h.eq({ 'corp/shop:feat', 'me/shop:feat' }, lookups(calls))
  h.ok(not h.read_calls(calls)[1].argv[5]:find('parent {', 1, true), 'gh-resolved base: no parent lookups')
  h.ok(find(panel_lines(s), ' feat → main | #52 '), table.concat(panel_lines(s), '\n'))
  view.close()
end)

h.test('a reused branch name: an old merged PR whose head is not in the branch is not shown', function()
  reset()
  local calls = h.tmpdir('forge-gh-reused') .. '/calls.ndjson'
  local d = h.repo('forge-reused', { ['a.txt'] = 'a\n' }, { ['a.txt'] = 'b\n' })
  h.git(d, 'remote', 'add', 'origin', 'git@github.com:acme/shop.git')
  local base = vim.trim(h.git(d, 'rev-parse', 'main'))
  h.use_fake_gh(calls, { ['acme/shop:feat'] = {
    node({ number = 3, head = 'feat', state = 'MERGED', oid = string.rep('1', 40), updated = '2026-01-03T00:00:00Z' }),
    node({ number = 2, head = 'feat', state = 'CLOSED', oid = base, updated = '2026-01-02T00:00:00Z' }),
  } })
  local s = open(d, { base = 'main' })
  idle(s)
  -- #3's head is unknown here (another branch of the same name); #2's head is in feat's history
  h.ok(find(panel_lines(s), ' feat → main | #2 closed '), table.concat(panel_lines(s), '\n'))
  view.close()
  reset()
  h.use_fake_gh(calls, { ['acme/shop:feat'] = { node({ number = 3, head = 'feat', state = 'MERGED', oid = string.rep('1', 40) }) } })
  s = open(d, { base = 'main' })
  idle(s)
  h.ok(not find(panel_lines(s), '#3'), 'not shown')
  h.ok(not find(panel_lines(s), 'PR #'), 'no detail')
  view.close()
end)

h.test('a merged PR whose head is ahead of the local branch (commits made on GitHub) is shown', function()
  reset()
  local calls = h.tmpdir('forge-gh-behind') .. '/calls.ndjson'
  local d = h.repo('forge-behind', { ['a.txt'] = 'a\n' }, { ['a.txt'] = 'b\n' })
  h.git(d, 'remote', 'add', 'origin', 'git@github.com:acme/shop.git')
  -- GitHub's "Update branch": a commit on top of feat, fetched as origin/feat; feat stays behind
  h.write(d, 'a.txt', 'c\n')
  h.git(d, 'commit', '-q', '-am', 'suggestion')
  local head = vim.trim(h.git(d, 'rev-parse', 'HEAD'))
  h.git(d, 'update-ref', 'refs/remotes/origin/feat', head)
  h.git(d, 'reset', '-q', '--hard', 'HEAD~1')
  h.use_fake_gh(calls, { ['acme/shop:feat'] = { node({ number = 7, head = 'feat', state = 'MERGED', oid = head }) } })
  local s = open(d, { base = 'main' })
  idle(s)
  h.ok(find(panel_lines(s), ' feat → main | #7 merged '), table.concat(panel_lines(s), '\n'))
  view.close()
end)

h.test('partial data: a repo that does not resolve gives no PR there; the rest is shown, errors logged', function()
  reset()
  local calls = h.tmpdir('forge-gh-partial') .. '/calls.ndjson'
  h.use_fake_gh(calls, {
    _null = { 'me/shop' },
    ['acme/shop:feat'] = { node({ number = 53, head = 'feat', head_owner = 'me' }) },
  })
  local d = remotes_repo('forge-partial', { { 'origin', 'git@github.com:me/shop.git' }, { 'upstream', 'git@github.com:acme/shop.git' } }, 'origin')
  local s = open(d, { base = 'main' })
  idle(s)
  h.ok(find(panel_lines(s), ' feat → main | #53 '), table.concat(panel_lines(s), '\n'))
  local text = table.concat(vim.tbl_map(function(e)
    return e.msg
  end, log.entries), '\n')
  h.ok(text:find('Could not resolve to a Repository', 1, true), text)
  view.close()
end)

h.test('a transient failure keeps the PRs shown, marked stale', function()
  reset()
  local t = 1e6
  forge.now = function()
    return t
  end
  local calls = h.tmpdir('forge-gh-blip') .. '/calls.ndjson'
  h.use_fake_gh(calls, stack_prs)
  local d = stack_fixture('forge-blip')
  local s = open(d)
  idle(s)
  h.ok(find(panel_lines(s), ' ▾ PR #12 | ✓'), 'shown')
  vim.env.REVUEY_FAKE_GH = 'fail'
  t = t + 61000
  require('revuey.panel').render(s)
  idle(s)
  h.eq(2, #h.read_calls(calls))
  local lines = panel_lines(s)
  local _, cart = find(lines, '@ stack/cart')
  h.ok(cart:find('| #12 ✓? ', 1, true), cart)
  h.ok(find(lines, ' ▾ PR #12 | ✓ (stale)'), table.concat(lines, '\n'))
  h.ok(find(lines, '   base: stack/math'), 'details kept')
  vim.env.REVUEY_FAKE_GH = nil
  view.close()
end)

---Is the process alive?
local function alive(pid)
  return vim.uv.kill(tonumber(pid), 0) == 0
end

h.test('a hanging gh times out (forge.timeout): the lookup ends, logged, nothing shown', function()
  reset()
  local calls = h.tmpdir('forge-gh-hang') .. '/calls.ndjson'
  h.use_fake_gh(calls, stack_prs, 'hang')
  setup({ forge = { timeout = 1 } })
  local d = stack_fixture('forge-hang')
  local s = open(d)
  h.ok(vim.wait(5000, function()
    return s.forge and s.forge.ready and not s.forge.busy
  end, 20), 'lookup did not end')
  local entry = log.entries[#log.entries]
  h.ok(entry and entry.msg:find('timed out', 1, true), vim.inspect(log.entries))
  local pid = vim.fn.readfile(calls .. '.pid')[1]
  h.ok(vim.wait(2000, function()
    return not alive(pid)
  end, 20), 'gh still running')
  h.ok(not find(panel_lines(s), '#12'), 'nothing shown')
  view.close()
  vim.env.REVUEY_FAKE_GH = nil
  setup()
end)

h.test('closing the review mid-lookup stops gh; its late result never reaches the cache', function()
  reset()
  local calls = h.tmpdir('forge-gh-close') .. '/calls.ndjson'
  h.use_fake_gh(calls, stack_prs, 'hang')
  local d = stack_fixture('forge-close')
  local s = open(d)
  h.ok(vim.wait(5000, function()
    return vim.uv.fs_stat(calls .. '.pid') ~= nil and s.forge and s.forge.busy
  end, 20), 'gh did not start')
  local pid = vim.fn.readfile(calls .. '.pid')[1]
  local msgs, restore = h.capture_notify()
  view.close()
  h.ok(vim.wait(2000, function()
    return not alive(pid)
  end, 20), 'gh still running after close')
  vim.wait(300)
  restore()
  h.eq({}, forge.cache, 'nothing cached')
  h.eq({}, vim.tbl_filter(function(e)
    return e.msg:find('failed', 1, true) ~= nil
  end, log.entries), 'no failure recorded')
  h.eq({}, msgs)
  vim.env.REVUEY_FAKE_GH = nil
end)

h.test('a lookup that finds nothing to show does not redraw the panel (its cursor stays)', function()
  reset()
  local calls = h.tmpdir('forge-gh-quiet') .. '/calls.ndjson'
  h.use_fake_gh(calls, {})
  -- no remotes at all (the screen fixtures): the lookup ends with nothing, as in CI
  local d = h.repo('forge-quiet', { ['a.txt'] = 'a\n', ['b.txt'] = 'b\n' }, { ['a.txt'] = 'x\n', ['b.txt'] = 'y\n' })
  local s = open(d, { base = 'main' })
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_win_set_cursor(s.panel_win, { 1, 0 })
  idle(s)
  h.eq(1, vim.api.nvim_win_get_cursor(s.panel_win)[1], 'panel cursor moved by the lookup')
  view.close()
  -- a GitHub remote but no PR for the branch: the same
  d = h.repo('forge-quiet-remote', { ['a.txt'] = 'a\n' }, { ['a.txt'] = 'x\n' })
  h.git(d, 'remote', 'add', 'origin', GH_URL)
  h.use_fake_gh(calls, {}, 'slow')
  s = open(d, { base = 'main' })
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_win_set_cursor(s.panel_win, { 1, 0 })
  idle(s)
  h.eq(1, #h.read_calls(calls))
  h.eq(1, vim.api.nvim_win_get_cursor(s.panel_win)[1], 'panel cursor moved by the lookup')
  vim.env.REVUEY_FAKE_GH = nil
  view.close()
end)

h.test('a late lookup that adds the PR section keeps the panel cursor on the same row item', function()
  for _, focus in ipairs({ 'diff', 'panel' }) do
    reset()
    local calls = h.tmpdir('forge-gh-late-' .. focus) .. '/calls.ndjson'
    h.use_fake_gh(calls, stack_prs, 'slow')
    local d = stack_fixture('forge-late-' .. focus)
    local s = open(d)
    h.ok(s.forge and s.forge.busy, 'lookup still running')
    vim.api.nvim_set_current_win(focus == 'diff' and s.diff_win or s.panel_win)
    -- the cursor on the second file's row, the window scrolled by one line
    local row = s.panel_rows[2]
    vim.api.nvim_win_call(s.panel_win, function()
      vim.fn.winrestview({ lnum = row, col = 0, topline = 2 })
    end)
    idle(s)
    h.ok(find(panel_lines(s), ' ▾ PR #12'), focus .. ': the PR section arrived')
    local new = s.panel_rows[2]
    h.ok(new > row, 'rows were added above')
    h.eq(new, vim.api.nvim_win_get_cursor(s.panel_win)[1], focus .. ': cursor follows its file row')
    local top = vim.api.nvim_win_call(s.panel_win, function()
      return vim.fn.winsaveview().topline
    end)
    h.eq(2 + (new - row), top, focus .. ': view scrolled with it')
    vim.env.REVUEY_FAKE_GH = nil
    view.close()
  end
end)

h.run()
