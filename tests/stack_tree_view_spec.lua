-- The stack tree in a review (stack_tree_view.lua, with forge_view, view and panel): a real
-- clone of a branching stack (tests/helpers.lua tree_repo) with the fake `gh` answering the tree
-- and `git fetch` reaching a local bare "GitHub" (tests/bin/fake-ssh). The tree comes with the PR
-- lookup in batched rounds; the stack is the default route; the panel marks other paths and
-- branches to fetch; the tree view moves, lights the path up, shows closed PRs, selects a path
-- and cancels; full scope and ]s/[s follow the chosen path; the fetch key; git detection when
-- GitHub fails.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')
local state_dir = h.tmpdir('tree-state')
local log_file = h.tmpdir('tree-log') .. '/revuey.log'
local function setup(extra)
  require('revuey').setup(vim.tbl_deep_extend('force', {
    state_dir = state_dir, lsp_warmup = false, log_file = log_file, panel_width = 30,
    forge = { threads = { enabled = false }, check = false, description = { enabled = false } },
  }, extra or {}))
end
setup()
local view = require('revuey.view')
local tv = require('revuey.stack_tree_view')
local api = vim.api

local function names(s)
  return vim.tbl_map(function(l)
    return l.name
  end, s.review.stack and s.review.stack.layers or {})
end

---Open a review of a fresh tree_repo and wait for the tree and the stack built from it.
local function open(name, scenario, o)
  o = o or {}
  local r = h.tree_repo(name)
  if o.prepare then
    o.prepare(r) -- the clone or the PRs changed before the review opens
  end
  local calls = h.tmpdir(name .. '-gh') .. '/calls.ndjson'
  h.use_fake_gh(calls, r.prs, scenario, o.threads)
  vim.env.REVUEY_FAKE_GH_TREE_SCENARIO = o.tree_scenario
  local ssh_log = h.tmpdir(name .. '-ssh') .. '/ssh.log'
  h.use_fake_ssh(r.bare, ssh_log)
  local s = h.open_review({ cwd = r.dir, base = '' })
  if o.until_ then
    h.ok(vim.wait(15000, function()
      return o.until_(s)
    end, 10), 'the review did not get there')
    return s, r, calls, ssh_log
  end
  h.ok(vim.wait(15000, function()
    local gt = s.gh_tree
    return (not tv.enabled() or (gt and gt.fetched and not gt.running and (gt.reason or (gt.tree and not gt.loading))))
      and s.forge and not s.forge.busy and not s.refreshing
  end, 20), 'the tree did not load')
  vim.wait(200, function()
    return false
  end)
  h.ok(vim.wait(5000, function()
    return not s.refreshing and not (s.forge and s.forge.busy)
  end, 20))
  return s, r, calls, ssh_log
end

local function tree_calls(calls)
  local out = {}
  for _, c in ipairs(h.read_calls(calls)) do
    local q = c.argv[5] or ''
    if q:find('fragment tnode', 1, true) then
      out[#out + 1] = q
    end
  end
  return out
end

local function wait_idle(s)
  return vim.wait(10000, function()
    return not s.refreshing and not s.pending and not (s.forge and s.forge.busy)
      and not (s.gh_tree and (s.gh_tree.fetching or s.gh_tree.running))
  end, 20)
end

h.test('open: the tree comes with the PR lookup, in batched rounds; the stack is the default route', function()
  local s, _, calls = open('tree-open')
  local all = h.read_calls(calls)
  local first = all[1].argv[5]
  h.ok(first:find('l1:', 1, true) and first:find('sd1:', 1, true), 'the first round rides on the PR lookup')
  local tq = tree_calls(calls)
  -- 1 shared + children of the chain (11, 12), then 13, then 15 (routes), then the closed 16
  -- and 14, then 17; plus the lookup of the new layers' PRs once the stack changed
  h.eq(6, #tq)
  for i = 2, #tq do
    h.ok(not tq[i]:find('fragment pr on', 1, true), 'tree rounds of their own')
    h.ok(not tq[i]:find('sd1:', 1, true), 'the chain came in the first call')
  end
  h.eq(#tq + 1, #all, 'one more PR lookup for the layers the tree added')
  h.eq({ 'origin/stack/a', 'stack/b', 'origin/stack/c' }, names(s))
  h.eq('github', s.review.stack.kind)
  h.eq({ kind = 'layer', index = 2 }, s.scope, 'HEAD\'s layer')
  local l = s.review.stack.layers
  h.eq({ 11, 12, 13 }, { l[1].pr, l[2].pr, l[3].pr })
  h.eq(true, l[2].is_head)
  h.eq('behind', l[3].fetch)
  h.eq(true, l[1].remote)
  local kinds = vim.tbl_map(function(n)
    return n.kind
  end, s.review.stack.notes)
  h.ok(vim.tbl_contains(kinds, 'not_fetched'), 'PR #15 is not in the clone')
  view.close()
end)

h.test('panel: other paths (⑂), branches to fetch (⇣), the hints under a layer, the help line', function()
  local s = open('tree-panel')
  local lines = api.nvim_buf_get_lines(s.panel_buf, 0, -1, false)
  local virt = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(s.panel_buf, -1, 0, -1, { details = true })) do
    if m[4].virt_text then
      local t = {}
      for _, v in ipairs(m[4].virt_text) do
        t[#t + 1] = v[1]
      end
      virt[m[2] + 1] = table.concat(t)
    end
  end
  local row = {}
  for r, i in pairs(s.panel_layers) do
    if i ~= 'full' then
      row[({ 'stack/a', 'stack/b', 'stack/c' })[i]] = r
    end
  end
  h.ok(virt[row['stack/a']]:find('^⑂2 ro #11'), virt[row['stack/a']])
  h.ok(virt[row['stack/b']]:find('^⑂2 #12'), virt[row['stack/b']])
  h.ok(virt[row['stack/c']]:find('^⇣ ro #13'), virt[row['stack/c']])
  h.ok(vim.tbl_contains(lines, ' gb stack tree  gF fetch'), 'help line')
  h.ok(vim.iter(lines):any(function(x)
    return x:find('⚠ PR #15 not fetched:', 1, true) ~= nil
  end), table.concat(lines, '\n'))
  local function hints_at(r)
    api.nvim_set_current_win(s.panel_win)
    api.nvim_win_set_cursor(s.panel_win, { r, 0 })
    require('revuey.panel').update_hint(s)
    local out = {}
    for _, m in ipairs(api.nvim_buf_get_extmarks(s.panel_buf, -1, 0, -1, { details = true })) do
      for _, vl in ipairs(m[4].virt_lines or {}) do
        out[#out + 1] = vim.trim(vl[1][1])
      end
    end
    return out
  end
  h.eq({ 'gS creates local branch stack/a', 'gb tree: 2 closed PRs here' }, hints_at(row['stack/a']))
  h.eq({ 'gb tree: 2 other paths here' }, hints_at(row['stack/b']))
  h.eq({ 'gS creates local branch stack/c', 'gF fetch: origin is behind GitHub' }, hints_at(row['stack/c']))
  view.close()
end)

---The tree view's PR rows (number -> row) and the PR under the cursor.
local function tree_rows(s)
  local v = s.gh_tree.view
  local rows = {}
  for r, n in pairs(v.row_pr) do
    rows[n] = r
  end
  return rows, v
end

local function path_hl(s)
  local v = s.gh_tree.view
  local out = { path = {}, route = {} }
  for _, m in ipairs(api.nvim_buf_get_extmarks(v.buf, -1, 0, -1, { details = true })) do
    local g = m[4].line_hl_group
    local n = v.row_pr[m[2] + 1]
    if g == 'RevueyTreePath' then
      out.path[#out.path + 1] = n
    elseif g == 'RevueyTreeRoute' then
      out.route[#out.route + 1] = n
    end
  end
  table.sort(out.path)
  table.sort(out.route)
  return out
end

h.test('tree view: rows, j/k between PRs with the path lit up, closed shown and hidden, q cancels', function()
  local s = open('tree-view')
  api.nvim_set_current_win(s.diff_win)
  api.nvim_feedkeys('gb', 'x', false)
  local v = s.gh_tree.view
  h.ok(v and api.nvim_win_is_valid(v.win), 'the tree view opened')
  h.eq(v.win, api.nvim_get_current_win())
  h.eq('win', api.nvim_win_get_config(v.win).relative, 'a float over the diff window')
  local lines = api.nvim_buf_get_lines(v.buf, 0, -1, false)
  h.eq(' Stack tree · 9 PRs on main', lines[1])
  h.eq(' j k move  <CR> review this path  C show closed (4)  gF fetch  q close', lines[2])
  local graph = {}
  for i = 4, #lines do
    graph[#graph + 1] = (lines[i]:match('^([│├─┘┴◉◯ ]*#?%d*)') or ''):gsub('%s+$', '')
  end
  h.eq({ '◉ #15', '◉ #13', '│ ◯ #19', '├─┘', '◉ #12', '◉ #11', '◯' }, graph)
  h.ok(lines[#lines]:find('◯ main', 1, true))
  local rows = tree_rows(s)
  h.eq(rows[12], api.nvim_win_get_cursor(v.win)[1], 'starts on the viewed layer\'s PR')
  h.eq({ path = { 11, 12 }, route = { 13, 15 } }, path_hl(s))
  -- k goes up a PR (connector rows are skipped)
  api.nvim_feedkeys('k', 'x', false)
  h.eq(rows[19], api.nvim_win_get_cursor(v.win)[1])
  h.eq({ path = { 11, 12, 19 }, route = {} }, path_hl(s), 'the fork\'s PR: the path through it')
  api.nvim_feedkeys('2k', 'x', false)
  h.eq(rows[15], api.nvim_win_get_cursor(v.win)[1])
  h.eq({ path = { 11, 12, 13, 15 }, route = {} }, path_hl(s))
  api.nvim_feedkeys('jjj', 'x', false)
  h.eq(rows[12], api.nvim_win_get_cursor(v.win)[1])
  -- closed PRs: shown, then hidden again; the cursor stays on its PR
  api.nvim_feedkeys('C', 'x', false)
  rows = tree_rows(s)
  h.ok(rows[10] and rows[14] and rows[16] and rows[17], 'closed PRs shown')
  h.eq(rows[12], api.nvim_win_get_cursor(v.win)[1])
  h.ok(api.nvim_buf_get_lines(v.buf, 1, 2, false)[1]:find('C hide closed (4)', 1, true))
  api.nvim_feedkeys('C', 'x', false)
  rows = tree_rows(s)
  h.eq(nil, rows[16])
  -- q: closed, nothing changed
  local stack = s.review.stack
  api.nvim_feedkeys('q', 'x', false)
  h.eq(nil, s.gh_tree.view)
  h.ok(not api.nvim_win_is_valid(v.win))
  h.eq(s.diff_win, api.nvim_get_current_win())
  wait_idle(s)
  h.eq(stack, s.review.stack, 'the stack is unchanged')
  -- <Esc> closes too
  api.nvim_feedkeys('gb', 'x', false)
  h.ok(s.gh_tree.view ~= nil)
  api.nvim_feedkeys(vim.keycode('<Esc>'), 'x', false)
  h.eq(nil, s.gh_tree.view)
  view.close()
end)

h.test('<CR>: the stack becomes the chosen path, viewing its PR; full scope and ]s/[s follow it', function()
  local s = open('tree-select')
  api.nvim_set_current_win(s.diff_win)
  api.nvim_feedkeys('gb', 'x', false)
  api.nvim_feedkeys('C', 'x', false)
  local rows, v = tree_rows(s)
  api.nvim_win_set_cursor(v.win, { rows[16], 0 })
  api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  h.eq(nil, s.gh_tree.view, 'the view closes')
  h.ok(wait_idle(s))
  h.eq(16, s.gh_tree.sel)
  -- #16 is closed: its own path (nothing open above it)
  h.eq({ 'origin/stack/a', 'origin/stack/old1' }, names(s))
  h.eq({ kind = 'layer', index = 2 }, s.scope, 'viewing #16')
  h.eq('origin/stack/old1', s.review.branch)
  h.eq({ 'src/legacy.ts' }, vim.tbl_map(function(f)
    return f.path
  end, s.review.files))
  -- [s / ]s and the full scope along the chosen path
  api.nvim_feedkeys('[s', 'x', false)
  h.ok(wait_idle(s))
  h.eq({ kind = 'layer', index = 1 }, s.scope)
  h.eq('origin/stack/a', s.review.branch)
  api.nvim_feedkeys(']s', 'x', false)
  h.ok(wait_idle(s))
  h.eq({ kind = 'layer', index = 2 }, s.scope)
  api.nvim_feedkeys('gs', 'x', false)
  h.ok(wait_idle(s))
  h.eq('full', s.scope.kind)
  h.eq({ 'src/legacy.ts', 'src/price.ts' }, vim.tbl_map(function(f)
    return f.path
  end, s.review.files))
  -- choosing HEAD's PR again: the default route
  api.nvim_feedkeys('gb', 'x', false)
  rows, v = tree_rows(s)
  api.nvim_win_set_cursor(v.win, { rows[13], 0 })
  api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  h.ok(wait_idle(s))
  h.eq({ 'origin/stack/a', 'stack/b', 'origin/stack/c' }, names(s))
  h.eq({ kind = 'layer', index = 3 }, s.scope)
  -- a refresh (git) keeps the chosen path
  local msgs, restore = h.capture_notify()
  s.gh_tree.sel = 16
  view.refresh({ force = true })
  h.ok(wait_idle(s))
  restore()
  h.eq('revuey: layer origin/stack/c is no longer in the stack; showing origin/stack/old1', msgs[1] and msgs[1].msg)
  h.eq({ 'origin/stack/a', 'origin/stack/old1' }, names(s))
  view.close()
end)

h.test('R: the tree is fetched again (and only then); the chosen path stays', function()
  local s, _, calls = open('tree-refetch')
  local before = #tree_calls(calls)
  view.refresh({ force = true })
  h.ok(wait_idle(s))
  h.eq(before, #tree_calls(calls), 'a refresh never refetches')
  s.gh_tree.sel = 16
  local _, restore = h.capture_notify()
  view.refresh({ force = true, forge = true })
  vim.wait(300, function()
    return false
  end)
  h.ok(vim.wait(15000, function()
    return #tree_calls(calls) >= 2 * before - 1 and not s.gh_tree.loading and not s.forge.busy and not s.refreshing
  end, 20))
  h.ok(wait_idle(s))
  restore()
  h.eq(16, s.gh_tree.sel)
  h.eq({ 'origin/stack/a', 'origin/stack/old1' }, names(s))
  view.close()
end)

h.test('the fetch key: git fetch of the stack\'s branches from the PRs\' remote, then the marks go', function()
  local s, r, calls, ssh_log = open('tree-fetch')
  local n_gh = #h.read_calls(calls)
  local msgs, restore = h.capture_notify()
  api.nvim_set_current_win(s.diff_win)
  api.nvim_feedkeys('gF', 'x', false)
  h.ok(vim.wait(15000, function()
    return not s.gh_tree.fetching and #names(s) == 4
  end, 20), 'fetched')
  h.ok(wait_idle(s))
  restore()
  -- no tree call, nothing but the PR lookup of the layer that appeared (stack/d): GitHub is only read
  h.eq(0, #vim.tbl_filter(function(c)
    local q = c.argv[5] or ''
    return not (q:match('^query=query {') and q:find('l1:', 1, true) and not q:find('sd1:', 1, true))
  end, vim.list_slice(h.read_calls(calls), n_gh + 1)))
  h.ok(vim.fn.readfile(ssh_log)[1]:find('git%-upload%-pack'), 'git fetch went through the fake ssh')
  h.eq(r.oid.c2, vim.trim(h.git(r.dir, 'rev-parse', 'origin/stack/c')))
  h.eq(r.oid.d, vim.trim(h.git(r.dir, 'rev-parse', 'origin/stack/d')))
  h.eq({ 'origin/stack/a', 'stack/b', 'origin/stack/c', 'origin/stack/d' }, names(s))
  for _, l in ipairs(s.review.stack.layers) do
    h.eq(nil, l.fetch, l.name)
  end
  h.eq({}, vim.tbl_filter(function(n)
    return n.kind == 'not_fetched'
  end, s.review.stack.notes))
  h.ok(vim.iter(msgs):any(function(m)
    return m.msg == 'revuey: fetched #13 #15 from origin'
  end), vim.inspect(msgs))
  -- again: nothing to fetch
  msgs, restore = h.capture_notify()
  require('revuey.stack_tree_view').fetch(s)
  h.ok(vim.wait(5000, function()
    return #msgs > 0
  end, 20))
  restore()
  h.eq('revuey: nothing to fetch: the stack is up to date with GitHub', msgs[1].msg)
  -- a fork's PR: chosen, it is missing; the fetch key in the tree fetches refs/pull/19/head
  -- (commits only, no ref) and it becomes a read-only layer that gS refuses
  msgs, restore = h.capture_notify()
  tv.select(s, 19)
  h.ok(wait_idle(s))
  h.ok(vim.wait(2000, function()
    return vim.iter(msgs):any(function(m)
      return m.msg:find('PR #19 is not in this clone yet; gF fetches it', 1, true) ~= nil
    end)
  end, 20), vim.inspect(msgs))
  h.eq({ 'origin/stack/a', 'stack/b' }, names(s))
  api.nvim_feedkeys('gb', 'x', false)
  local rows, v = tree_rows(s)
  api.nvim_win_set_cursor(v.win, { rows[19], 0 })
  api.nvim_feedkeys('gF', 'x', false)
  h.ok(vim.wait(15000, function()
    return not s.gh_tree.fetching and #names(s) == 3
  end, 20), 'fork fetched')
  h.ok(wait_idle(s))
  restore()
  h.eq({ 'origin/stack/a', 'stack/b', 'bob:fix-d' }, names(s))
  local f = s.review.stack.layers[3]
  h.eq({ true, true, r.oid.fork }, { f.fork_pr, f.remote, f.tip })
  h.eq('', h.git(r.dir, 'for-each-ref', 'refs/pull', 'refs/remotes/origin/pr'), 'no ref written for it')
  msgs, restore = h.capture_notify()
  view.switch_layer(3)
  restore()
  h.ok(msgs[1].msg:find('comes from a fork; check it out with `gh pr checkout 19`', 1, true), msgs[1].msg)
  if s.gh_tree.view then
    tv.close_view(s)
  end
  view.close()
end)

h.test('GitHub fails: git detection stays, the tree key says why', function()
  local s = open('tree-fail', 'fail')
  h.eq(nil, s.gh_tree.tree)
  h.eq(nil, s.review.stack, 'a lone local branch: the plain review, as without GitHub')
  local msgs, restore = h.capture_notify()
  api.nvim_set_current_win(s.diff_win)
  api.nvim_feedkeys('gb', 'x', false)
  restore()
  h.eq('revuey: no stack tree from GitHub: the GitHub lookup failed (see revuey.log) (the stack comes from git)', msgs[1].msg)
  -- quiet in the panel, like the PR lookup it shared its call with (decision 13)
  h.eq(false, vim.iter(api.nvim_buf_get_lines(s.panel_buf, 0, -1, false)):any(function(x)
    return x:find('stack tree', 1, true) ~= nil
  end))
  h.eq(nil, s.gh_tree.view)
  view.close()
end)

h.test('later tree rounds fail: the chain read so far is the stack, the failure is logged', function()
  local s = open('tree-fail-later', nil, { tree_scenario = 'fail' })
  vim.env.REVUEY_FAKE_GH_TREE_SCENARIO = nil
  h.ok(s.gh_tree.tree ~= nil)
  h.eq({ 'origin/stack/a', 'stack/b' }, names(s))
  h.ok(s.gh_tree.tree.cut ~= nil)
  local text = table.concat(vim.fn.readfile(log_file), '\n')
  h.ok(text:find('stack tree: ', 1, true), 'logged')
  h.ok(vim.iter(api.nvim_buf_get_lines(s.panel_buf, 0, -1, false)):any(function(x)
    return x:find('stack tree incomplete: R', 1, true) ~= nil
  end), 'the panel says so')
  view.close()
end)

h.test('stack.github = false: no tree query, git detection only', function()
  setup({ stack = { github = false } })
  local s, _, calls = open('tree-off')
  h.eq(0, #tree_calls(calls))
  h.eq(nil, s.review.stack)
  local msgs, restore = h.capture_notify()
  api.nvim_set_current_win(s.diff_win)
  api.nvim_feedkeys('gb', 'x', false)
  restore()
  h.ok(msgs[1].msg:find('the stack tree is off', 1, true), msgs[1].msg)
  view.close()
  setup()
end)

local function files(s)
  return vim.tbl_map(function(f)
    return f.path
  end, s.review.files or {})
end

local function note_kinds(s)
  return vim.tbl_map(function(n)
    return n.kind
  end, (s.review.stack and s.review.stack.notes) or s.review.notes or {})
end

local function fetch_and_wait(s, nums)
  local msgs, restore = h.capture_notify()
  tv.fetch(s, nums)
  h.ok(vim.wait(15000, function()
    return not s.gh_tree.fetching
  end, 20), 'fetched')
  h.ok(wait_idle(s))
  restore()
  return msgs
end

h.test('a closed PR of a moved branch: its own commit, never the local branch of the newer PR; its own PR in the forge', function()
  local s, r = open('tree-moved-local', nil, {
    prepare = function(r)
      h.git(r.dir, 'branch', 'stack/c', 'origin/stack/c') -- a local copy of #13's branch
    end,
  })
  tv.select(s, 10)
  h.ok(wait_idle(s))
  h.eq({ 'origin/stack/a' }, names(s), '#10\'s commit is not here: left out, not shown from stack/c')
  fetch_and_wait(s)
  h.eq({ 'origin/stack/a', 'origin/stack/c' }, names(s))
  local l = s.review.stack.layers[2]
  h.eq({ r.oid.c_old, 10, true }, { l.tip, l.pr, l.unfetched })
  h.eq({ kind = 'layer', index = 2 }, s.scope)
  h.eq({ 'src/coupon.ts' }, files(s), 'only #10\'s change')
  h.ok(vim.wait(10000, function()
    return not s.forge.busy and require('revuey.forge_view').pr(s, 'origin/stack/c') ~= nil
  end, 20))
  local fv = require('revuey.forge_view')
  h.eq(10, fv.pr(s, 'origin/stack/c').number, 'the layer\'s PR is #10, not the branch\'s open #13')
  h.eq({ 10 }, vim.tbl_map(function(p)
    return p.number
  end, (fv.scope_prs(s, true))), 'the change check asks #10')
  h.eq({}, require('revuey.forge_post_view').scope_targets(s), 'nothing to post to (#10 is closed), never #13')
  view.close()
end)

h.test('a local branch behind its open PR (not checked out): the layer is the PR\'s, with a note', function()
  local s, r = open('tree-local-behind', nil, {
    prepare = function(r)
      h.git(r.dir, 'branch', 'stack/a', 'main')
    end,
  })
  h.eq({ 'origin/stack/a', 'stack/b', 'origin/stack/c' }, names(s))
  local l = s.review.stack.layers[1]
  h.eq({ r.oid.a, 'other', 'local' }, { l.tip, l.local_differs, l.fetch })
  h.ok(vim.tbl_contains(note_kinds(s), 'local_differs'))
  view.set_scope({ kind = 'layer', index = 1 })
  h.ok(wait_idle(s))
  h.eq({ 'src/price.ts' }, files(s), '#11\'s change, not stack/b\'s')
  view.close()
end)

h.test('a fork\'s PR as a layer: threads, the description, posting and the change check are its own', function()
  setup({ forge = { threads = { enabled = true }, description = { enabled = true } } })
  local thread = {
    id = 'T19', isResolved = false, isOutdated = false, path = 'src/fix.ts', line = 1, startLine = vim.NIL,
    originalLine = 1, originalStartLine = vim.NIL, diffSide = 'RIGHT', startDiffSide = vim.NIL, subjectType = 'LINE',
    resolvedBy = vim.NIL,
    comments = { { id = 'C19', databaseId = 19, url = 'https://github.com/acme/shop/pull/19#c', body = 'Round down?',
      createdAt = '2026-01-04T00:00:00Z', lastEditedAt = vim.NIL, state = 'SUBMITTED', diffHunk = '', author = { login = 'carol' },
      replyTo = vim.NIL } },
  }
  local s, _, calls = open('tree-fork-forge', nil, {
    threads = { ['acme/shop#19'] = { thread } },
    prepare = function(r)
      r.prs['acme/shop:fix-d'][1].body = 'Rounding fix from a fork.'
    end,
  })
  tv.select(s, 19)
  h.ok(wait_idle(s))
  fetch_and_wait(s, { 19 })
  h.eq('bob:fix-d', s.review.stack.layers[s.scope.index].name)
  local fv = require('revuey.forge_view')
  h.ok(vim.wait(10000, function()
    return not s.forge.busy and fv.pr(s, 'bob:fix-d') ~= nil and #fv.thread_items(s) > 0
  end, 20), 'the fork PR\'s lookup and threads')
  h.eq(19, fv.pr(s, 'bob:fix-d').number)
  h.eq({ 19 }, vim.tbl_map(function(p)
    return p.number
  end, (fv.scope_prs(s))))
  h.eq(19, require('revuey.forge_post_view').scope_targets(s)[1].pr.number, 'a post goes to #19')
  h.eq('Rounding fix from a fork.', fv.descriptions(s)[1] and fv.descriptions(s)[1].md)
  h.ok(vim.iter(h.read_calls(calls)):any(function(c)
    return (c.argv[5] or ''):find('pullRequest(number: 19)', 1, true) ~= nil and c.argv[5]:find('reviewThreads', 1, true) ~= nil
  end), 'threads asked for #19')
  local n = #h.read_calls(calls)
  fv.check(s)
  h.ok(vim.wait(10000, function()
    return #h.read_calls(calls) > n and not s.forge.checking
  end, 20))
  local q = h.read_calls(calls)[n + 1].argv[5]
  h.ok(q:find('fragment check', 1, true) and q:find('pullRequest(number: 19)', 1, true), 'the change check asks #19')
  view.close()
  setup()
end)

h.test('HEAD on an unrelated branch: its own (first) fetch, git meanwhile; back again without a fetch', function()
  local s, r, calls = open('tree-head-moves')
  local before = #tree_calls(calls)
  h.git(r.dir, 'checkout', '-q', '-b', 'unrelated', 'main')
  h.write(r.dir, 'other.txt', 'x\n')
  h.git(r.dir, 'add', '-A')
  h.git(r.dir, 'commit', '-q', '-m', 'other')
  local _, restore = h.capture_notify()
  view.refresh({ force = true })
  h.ok(vim.wait(10000, function()
    return s.gh_tree.reason ~= nil and wait_idle(s)
  end, 20))
  restore()
  h.eq(nil, s.review.stack, 'git detection: a lone branch')
  h.eq({ 'other.txt' }, files(s))
  h.eq('no pull request for unrelated', s.gh_tree.reason)
  h.eq(before + 1, #tree_calls(calls), 'one first fetch for the new branch')
  h.ok(tree_calls(calls)[before + 1]:find('headRefName: "unrelated"', 1, true))
  h.git(r.dir, 'checkout', '-q', 'stack/b')
  view.refresh({ force = true })
  h.ok(wait_idle(s))
  h.eq({ 'origin/stack/a', 'stack/b', 'origin/stack/c' }, names(s), 'its tree again')
  h.eq(before + 1, #tree_calls(calls), 'kept from before: no fetch')
  view.close()
end)

h.test('HEAD on a branch of the tree (gS to a layer): the path stays, @ follows HEAD', function()
  local s, r = open('tree-head-layer')
  h.eq(12, s.gh_tree.head_pr)
  h.git(r.dir, 'checkout', '-q', '--track', 'origin/stack/a')
  view.refresh({ force = true })
  h.ok(wait_idle(s))
  h.eq({ 'stack/a', 'stack/b', 'origin/stack/c' }, names(s))
  h.eq(true, s.review.stack.layers[1].is_head)
  h.eq(false, s.review.stack.layers[2].is_head)
  h.eq(11, s.gh_tree.head_pr)
  h.eq({ kind = 'layer', index = 2 }, s.scope, 'the view stays on the layer it showed')
  view.close()
end)

h.test('only R refetches the tree: not the refetch after a post', function()
  local s, _, calls = open('tree-post-refetch')
  local n = #tree_calls(calls)
  local all = #h.read_calls(calls)
  require('revuey.forge_view').update(s, true)
  h.ok(vim.wait(10000, function()
    return #h.read_calls(calls) > all and wait_idle(s)
  end, 20))
  h.eq(n, #tree_calls(calls), 'the PRs, not the tree')
  view.refresh({ force = true, forge = true })
  vim.wait(300, function()
    return false
  end)
  h.ok(wait_idle(s))
  h.ok(#tree_calls(calls) > n, 'R')
  view.close()
end)

h.test('R keeps a chosen PR under a closed one, and the stack object when nothing changed', function()
  local s = open('tree-r-closed')
  tv.select(s, 16)
  h.ok(wait_idle(s))
  local stack = s.review.stack
  h.eq({ 'origin/stack/a', 'origin/stack/old1' }, names(s))
  local msgs, restore = h.capture_notify()
  view.refresh({ force = true, forge = true })
  vim.wait(300, function()
    return false
  end)
  h.ok(wait_idle(s))
  restore()
  h.eq(16, s.gh_tree.sel)
  h.eq(stack, s.review.stack, 'the same stack: nothing reloaded by the phases')
  h.eq({}, vim.tbl_filter(function(m)
    return m.msg:find('no longer in the stack', 1, true) ~= nil
  end, msgs))
  -- #17 (under closed #16, its commit not here)
  tv.select(s, 17)
  h.ok(wait_idle(s))
  view.refresh({ force = true, forge = true })
  vim.wait(300, function()
    return false
  end)
  h.ok(wait_idle(s))
  h.eq(17, s.gh_tree.sel)
  view.close()
end)

h.test('the tree\'s rounds run outside the PR lookup, and stop when the review closes', function()
  local s, _, calls = open('tree-slow', 'slow')
  vim.env.REVUEY_FAKE_GH_DELAY = '0.5'
  view.refresh({ force = true, forge = true })
  h.ok(vim.wait(10000, function()
    return s.gh_tree.running ~= nil and not s.forge.busy
  end, 10), 'the lookup is done while the tree\'s rounds run')
  local version, n = s.gh_tree.version, #h.read_calls(calls)
  view.close()
  vim.wait(2500, function()
    return false
  end)
  h.eq(version, s.gh_tree.version, 'nothing taken after close')
  h.ok(#h.read_calls(calls) <= n + 1, 'no round after close')
  vim.env.REVUEY_FAKE_GH_DELAY = nil
end)

h.test('gF: a branch gone on GitHub comes by its pull ref, the rest is fetched; no prompts', function()
  local s, r, _, ssh_log = open('tree-fetch-partial')
  h.git(r.bare, 'update-ref', '-d', 'refs/heads/stack/d')
  local msgs = fetch_and_wait(s)
  h.ok(vim.iter(msgs):any(function(m)
    return m.msg == 'revuey: fetched #13; #15 only by their pull refs (branch gone on GitHub) from origin'
  end), vim.inspect(msgs))
  h.eq(r.oid.c2, vim.trim(h.git(r.dir, 'rev-parse', 'origin/stack/c')))
  h.eq({ 'origin/stack/a', 'stack/b', 'origin/stack/c', 'origin/stack/d' }, names(s), '#15 from its commit')
  for _, line in ipairs(vim.fn.readfile(ssh_log)) do
    h.ok(line:find('prompt=0', 1, true), line)
  end
  view.close()
end)

h.test('git detection finds another stack: the tree overrides it, says where a parent setting disagrees', function()
  local git_stack
  local s, r = open('tree-over-git', nil, {
    prepare = function(r)
      h.git(r.dir, 'branch', 'stack/a', 'origin/stack/a')
      h.git(r.dir, 'branch', 'stack/old1', 'origin/stack/old1')
      h.git(r.dir, 'config', 'branch.stack/b.revueyParent', 'stack/old1')
      git_stack = require('revuey.stack').detect(r.dir, 'origin/main')
    end,
  })
  h.eq({ 'stack/a', 'stack/old1', 'stack/b' }, vim.tbl_map(function(l)
    return l.name
  end, git_stack.layers), 'git\'s own stack, from the parent setting')
  h.eq({ 'stack/a', 'stack/b', 'origin/stack/c' }, names(s))
  h.ok(vim.tbl_contains(note_kinds(s), 'github_parent'), vim.inspect(note_kinds(s)))
  -- a commit on stack/b: origin/stack/c is not based on it any more
  h.write(r.dir, 'src/tax.ts', 'export const tax = 0.25\n')
  h.git(r.dir, 'commit', '-q', '-am', 'tax')
  view.refresh({ force = true })
  h.ok(wait_idle(s))
  h.eq(true, s.review.stack.layers[3].diverged)
  h.ok(vim.tbl_contains(note_kinds(s), 'pr_not_restacked'), vim.inspect(note_kinds(s)))
  view.close()
end)

h.test('local branches above the top PR (no PR yet) stay on top', function()
  local s, r = open('tree-local-above')
  fetch_and_wait(s)
  h.git(r.dir, 'branch', 'stack/d', 'origin/stack/d')
  h.git(r.dir, 'branch', 'stack/e', 'stack/d')
  h.git(r.dir, 'checkout', '-q', 'stack/e')
  h.write(r.dir, 'src/e.ts', 'export const e = 1\n')
  h.git(r.dir, 'add', '-A')
  h.git(r.dir, 'commit', '-q', '-m', 'e')
  h.git(r.dir, 'checkout', '-q', 'stack/b')
  view.refresh({ force = true })
  h.ok(wait_idle(s))
  h.eq({ 'origin/stack/a', 'stack/b', 'origin/stack/c', 'stack/d', 'stack/e' }, names(s))
  h.eq(nil, s.review.stack.layers[5].pr)
  view.close()
end)

h.test('a lone PR stays a plain review until a path is chosen', function()
  local s = open('tree-lone', nil, {
    prepare = function(r)
      local a = r.prs['acme/shop:stack/a'][1]
      r.prs._tree['acme/shop'] = { a }
      h.git(r.dir, 'checkout', '-q', '--track', 'origin/stack/a')
      h.git(r.dir, 'branch', '-q', '-D', 'stack/b') -- else git finds a stack of its own
    end,
  })
  h.ok(s.gh_tree.tree ~= nil)
  h.eq(nil, s.review.stack)
  tv.select(s, 11)
  h.ok(wait_idle(s))
  h.eq({ 'stack/a' }, names(s))
  view.close()
end)

h.test('GitHub rejects the lookup with the tree in it: the PRs are looked up alone', function()
  local s = open('tree-reject', nil, { tree_scenario = 'reject' })
  vim.env.REVUEY_FAKE_GH_TREE_SCENARIO = nil
  h.eq(nil, s.gh_tree.tree)
  h.eq(12, require('revuey.forge_view').pr(s, '') and require('revuey.forge_view').pr(s, '').number)
  h.ok(table.concat(vim.fn.readfile(log_file), '\n'):find('retrying without it', 1, true))
  view.close()
end)

h.test('a PR chosen while closed PRs still load: the stack is rebuilt when they arrive', function()
  vim.env.REVUEY_FAKE_GH_DELAY = '0.4'
  local s = open('tree-phase-two', 'slow', {
    until_ = function(s)
      return s.gh_tree and s.gh_tree.loading == true and s.review.stack ~= nil and not s.refreshing
    end,
  })
  tv.select(s, 16) -- #16's children (closed #17) are not read yet
  h.ok(vim.wait(15000, function()
    return not s.gh_tree.loading and not s.gh_tree.running and wait_idle(s)
  end, 20))
  vim.env.REVUEY_FAKE_GH_DELAY = nil
  h.eq({ 'origin/stack/a', 'origin/stack/old1' }, names(s))
  h.eq(1, s.review.stack.layers[2].others, '⑂1: #17, read in phase two')
  view.close()
end)

h.test('R: a chosen PR GitHub no longer has is dropped, back to the default route', function()
  local s, r, calls = open('tree-sel-gone')
  tv.select(s, 16)
  h.ok(wait_idle(s))
  local prs = vim.deepcopy(r.prs)
  prs._tree['acme/shop'] = vim.tbl_filter(function(n)
    return n.number ~= 16 and n.number ~= 17
  end, prs._tree['acme/shop'])
  vim.fn.writefile({ vim.json.encode(prs) }, calls .. '.prs.json')
  local _, restore = h.capture_notify()
  view.refresh({ force = true, forge = true })
  vim.wait(300, function()
    return false
  end)
  h.ok(wait_idle(s))
  restore()
  h.eq(nil, s.gh_tree.sel)
  h.eq({ 'origin/stack/a', 'stack/b', 'origin/stack/c' }, names(s))
  view.close()
end)

h.test('the tree\'s own rounds fail with the chain unknown below HEAD\'s PR: git detection, and a note that R retries', function()
  local s = open('tree-fail-rounds', nil, {
    tree_scenario = 'fail',
    prepare = function(r)
      -- the chain below stack/b needs a round of its own: a flat lookup of stack/a answers
      -- stack/a's PRs nested, so cut it there by giving stack/a more PRs than a nested level lists
      for i = 1, 3 do
        table.insert(r.prs._tree['acme/shop'], {
          number = 30 + i, title = 'old ' .. i, url = 'https://github.com/acme/shop/pull/' .. (30 + i), state = 'CLOSED',
          isDraft = false, updatedAt = '2026-01-06T0' .. i .. ':00:00Z', headRefName = 'stack/a', baseRefName = 'main',
          headRefOid = r.oid.main, isCrossRepository = false, headRepositoryOwner = { login = 'acme' }, reviewDecision = vim.NIL,
        })
      end
    end,
  })
  vim.env.REVUEY_FAKE_GH_TREE_SCENARIO = nil
  h.eq({ 12 }, s.gh_tree.tree.chain, 'only HEAD\'s PR was read')
  h.eq(nil, s.review.stack, 'a lone PR: the plain review')
  h.ok(vim.wait(3000, function()
    return vim.iter(api.nvim_buf_get_lines(s.panel_buf, 0, -1, false)):any(function(x)
      return x:find('stack tree incomplete: R', 1, true) ~= nil
    end)
  end, 20), table.concat(api.nvim_buf_get_lines(s.panel_buf, 0, -1, false), '\n'))
  view.close()
end)

h.run()
