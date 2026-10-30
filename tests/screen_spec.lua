-- End-to-end screen tests: a child Neovim (driven over RPC by vendored mini.test) renders the
-- review, and its screen grid (text + highlight attributes) is compared with reference
-- screenshots in tests/screenshots/. Regenerate deliberately with:
--   REVUEY_UPDATE_SCREENSHOTS=1 make test
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
local MiniTest = dofile(h.root .. '/tests/vendor/mini/test.lua')

local UPDATE = os.getenv('REVUEY_UPDATE_SCREENSHOTS') == '1'
local SHOTS = h.root .. '/tests/screenshots'

local child = MiniTest.new_child_neovim()
h.teardown(function()
  child.stop() -- tests run inside h.run(): stop the child after them
end)

local function screenshot(name)
  -- reference_screenshot() records notes on the current case; we run outside MiniTest.run().
  MiniTest.current.case = { exec = {} }
  MiniTest.expect.reference_screenshot(child.get_screenshot(), SHOTS .. '/' .. name, { force = UPDATE })
end

---Start a clean child with revuey on the runtimepath, open a review of `dir`.
local function start(dir, base, lines, columns, extra)
  child.restart({ '-u', 'NONE' })
  child.o.lines, child.o.columns = lines or 30, columns or 120
  child.lua(
    [[
    local root, dir, state, base, extra = ...
    vim.opt.rtp:prepend(root)
    -- this child has no UI; its grid is read with screenstring() after mini.test's :redraw,
    -- so let revuey redraw when highlights arrive
    vim.g.revuey_headless_redraw = true
    vim.cmd('runtime plugin/revuey.lua')
    vim.cmd('cd ' .. vim.fn.fnameescape(dir))
    require('revuey').setup(vim.tbl_extend('force', { state_dir = state, lsp_warmup = false }, (extra ~= vim.NIL and extra) or {}))
    -- main-loop responsiveness probe: largest gap between 5ms timer ticks
    _G.revuey_maxgap = 0
    local last = vim.uv.hrtime()
    _G.revuey_probe = vim.uv.new_timer()
    _G.revuey_probe:start(5, 5, function()
      local now = vim.uv.hrtime()
      _G.revuey_maxgap = math.max(_G.revuey_maxgap, (now - last) / 1e6)
      last = now
    end)
    local done = false
    require('revuey').open({ base = base ~= '' and base or nil, on_ready = function() done = true end })
    vim.wait(10000, function() return done end, 10)
    assert(done, 'review did not open')
    -- the PR lookup runs in the background: let it settle, so screenshots never race it
    local fv = require('revuey.forge_view')
    assert(vim.wait(10000, function()
      local s = require('revuey.view').session
      return not fv.enabled() or (s.forge and s.forge.ready and not s.forge.busy and not s.forge.scheduled)
    end, 10), 'PR lookup did not settle')
  ]],
    { h.root, dir, h.tmpdir('screen-state-' .. vim.fn.fnamemodify(dir, ':t')), base or 'main', extra or vim.NIL }
  )
end

---Wait in the child until visible syntax has loaded: at least `n` cache entries, none pending.
local function wait_syntax(n)
  return child.lua(
    [[
    local n = ...
    local syntax = require('revuey.syntax')
    vim.cmd('redraw')
    return vim.wait(10000, function()
      return syntax.cache_size() >= n and syntax.pending() == 0
    end, 10)
  ]],
    { n }
  )
end

local function big_lua(n)
  local parts = {}
  for i = 1, n do
    parts[#parts + 1] = ('local function f%d(a) return "x%d" .. tostring(a) end'):format(i, i)
  end
  return table.concat(parts, '\n') .. '\n'
end

local fixture = h.fixture()

h.test('initial fixture layout', function()
  start(fixture)
  screenshot('initial-layout')
end)

h.test('after ]f and ]c navigation', function()
  child.type_keys(']f')
  screenshot('after-next-file')
  child.type_keys(']c')
  screenshot('after-next-hunk')
end)

h.test('after mr: file folds and panel shows checkmark', function()
  child.type_keys('mr')
  screenshot('after-mark-reviewed')
  -- back to the reviewed file: it is a single folded line with the reviewed marker
  child.type_keys('[f')
  screenshot('reviewed-file-folded')
end)

h.test('working-tree mode: mode header and ● uncommitted markers', function()
  local d = h.tmpdir('screen-wt')
  vim.fn.delete(d, 'rf')
  assert(vim.system({ h.root .. '/scripts/make-fixture.sh', d }):wait().code == 0)
  local l = vim.fn.readfile(d .. '/src/math.ts')
  l[#l + 1] = '// unstaged edit'
  vim.fn.writefile(l, d .. '/src/math.ts')
  h.write(d, 'src/extra.ts', 'export const extra = 1;\n')
  start(d)
  screenshot('worktree-uncommitted')
end)

h.test('committed-only mode via gu', function()
  child.type_keys('gu')
  child.lua([[vim.wait(5000, function() return not require('revuey.view').session.refreshing end, 10)]])
  screenshot('committed-mode')
end)

h.test('empty review', function()
  start(fixture, 'HEAD', 12, 100)
  screenshot('empty-review')
end)

-- Exercises the decoration provider's real drawing path (ephemeral extmarks): syntax from the
-- bundled Lua parser and lazy word-diff highlights must show up as distinct screen attributes.
h.test('decoration provider draws syntax and word-diff attrs', function()
  local repo = h.repo('screen-lua', { ['a.lua'] = 'local answer = 42\nreturn answer\n' }, {
    ['a.lua'] = 'local answer = 43\nreturn answer\n',
  })
  start(repo, 'main', 14, 80)
  -- syntax loads asynchronously after the first draw (old + new side of a.lua)
  h.ok(wait_syntax(2), 'syntax did not load')
  local shot = child.get_screenshot()
  local function find(text)
    for r, line in ipairs(shot.text) do
      local s = table.concat(line)
      local c = s:find(text, 1, true)
      if c then
        -- convert byte offset to cell index (all ASCII before the match in these rows except gutter)
        return r, vim.fn.strchars(s:sub(1, c - 1)) + 1
      end
    end
  end
  local r, c = find('local answer = 43')
  h.ok(r, tostring(shot))
  local attr = shot.attr[r]
  local kw, ident, num = attr[c], attr[c + 6], attr[c + 15]
  h.ok(kw ~= ident, 'keyword and identifier should differ (syntax drawn)\n' .. tostring(shot))
  h.ok(num ~= ident, 'changed number should differ (word diff drawn)\n' .. tostring(shot))
  local r2, c2 = find('local answer = 42')
  h.ok(shot.attr[r2][c2 + 15] ~= shot.attr[r2][c2 + 6], 'deleted word highlighted')
end)

-- Regression (review 2, high 1): highlighting a large visible file must not freeze the UI.
h.test('large visible file: main loop never blocked beyond the gap budget', function()
  local repo = h.repo('screen-big', { ['a.lua'] = 'local x = 1\n' }, { ['a.lua'] = 'local x = 2\n', ['big.lua'] = big_lua(20000) })
  start(repo, 'main', 30, 120, { collapse_large_files = 1000000, max_file_bytes = 10 * 1024 * 1024 })
  h.ok(wait_syntax(3), 'big.lua highlights did not load')
  local gap = child.lua_get('_G.revuey_maxgap')
  -- Shared CI runners are slower and noisier; CI raises the budget via REVUEY_TEST_MAX_GAP_MS.
  local max_gap = tonumber(os.getenv('REVUEY_TEST_MAX_GAP_MS')) or 50
  io.write(('    (largest main-loop gap: %.0fms, budget %dms)\n'):format(gap, max_gap))
  h.ok(gap < max_gap, ('main loop blocked for %.0fms'):format(gap))
end)

-- Regression (review 2, high 1): collapsed files are never fetched or parsed.
h.test('folded large file is not parsed', function()
  local repo = h.repo('screen-folded', { ['a.lua'] = 'local x = 1\n' }, { ['a.lua'] = 'local x = 2\n', ['big.lua'] = big_lua(20000) })
  -- above the line-count collapse threshold but below the byte cap, so it is shown folded
  start(repo, 'main', 30, 120, { max_file_bytes = 10 * 1024 * 1024 })
  h.ok(wait_syntax(2), 'a.lua highlights did not load')
  child.lua('vim.cmd("redraw") vim.wait(200)')
  h.eq(true, child.lua_get([[vim.fn.foldclosed(vim.fn.search('^big.lua', 'n')) ~= -1]]), 'big.lua should start folded')
  h.eq(2, child.lua_get([[require('revuey.syntax').cache_size()]]), 'only a.lua (old+new) may be loaded')
  local gap = child.lua_get('_G.revuey_maxgap')
  h.ok(gap < 50, ('main loop blocked for %.0fms'):format(gap))
end)

-- Regression (re-review 1): refreshing must never raise the W11 "file has changed" prompt for
-- hidden LSP buffers when the user has 'noautoread', and must not touch buffers they opened.
h.test('noautoread: refresh reloads hidden buffers silently, leaves user buffers alone', function()
  local repo = h.repo('screen-noautoread', { ['a.lua'] = 'local x = 1\n', ['b.lua'] = 'local y = 1\n' }, {
    ['a.lua'] = 'local x = 2\n',
    ['b.lua'] = 'local y = 2\n',
  })
  start(repo, 'main', 20, 100, { lsp_warmup = true })
  child.lua([[
    vim.o.autoread = false
    local root = ...
    local lsp = require('revuey.lsp')
    _G.hidden = lsp.file_buffer(root .. '/a.lua')
    -- a buffer the user opened and modified
    _G.user = lsp.file_buffer(root .. '/b.lua')
    vim.bo[_G.user].buflisted = true
    vim.api.nvim_buf_set_lines(_G.user, 0, -1, false, { 'user edit' })
  ]], { repo })
  vim.uv.sleep(1100) -- make sure mtimes differ
  h.write(repo, 'a.lua', 'local x = 3\n')
  h.write(repo, 'b.lua', 'local y = 3\n')
  child.lua([[
    require('revuey.view').refresh()
    vim.wait(3000, function() return not require('revuey.view').session.refreshing end, 10)
  ]])
  h.eq(false, child.is_blocked(), 'Neovim is blocked by a prompt')
  local text = table.concat(vim.tbl_map(table.concat, child.get_screenshot().text), '\n')
  h.ok(not text:find('W11', 1, true) and not text:find('has changed', 1, true), text)
  h.eq({ 'local x = 3' }, child.lua_get('vim.api.nvim_buf_get_lines(_G.hidden, 0, -1, false)'))
  h.eq({ 'user edit' }, child.lua_get('vim.api.nvim_buf_get_lines(_G.user, 0, -1, false)'))
end)

h.test('stack: panel stack section at the HEAD layer, then full scope', function()
  local d = h.tmpdir('screen-stack')
  vim.fn.delete(d, 'rf')
  assert(vim.system({ h.root .. '/scripts/make-fixture.sh', '--stack', d }):wait().code == 0)
  start(d, '') -- no base: detect the stack
  local function stats_loaded()
    return child.lua([[
      return vim.wait(5000, function()
        local s = require('revuey.view').session
        return s and not s.refreshing and s.review.stack and s.review.stack.full_stats ~= nil
      end, 10)
    ]])
  end
  h.ok(stats_loaded(), 'stack stats did not load')
  screenshot('stack-layer')
  child.type_keys('gs')
  h.ok(stats_loaded(), 'stack stats did not load')
  screenshot('stack-full')
end)

-- Someone else's stack from a fresh clone: a local branch for the bottom PR, the middle one only
-- as origin/stack/cart (dimmed, read-only), HEAD detached at origin/stack/ui (dimmed `@`).
h.test('stack: mixed local and remote-tracking layers, detached HEAD', function()
  local d = h.tmpdir('screen-stack-remote')
  vim.fn.delete(d, 'rf')
  assert(vim.system({ h.root .. '/scripts/make-fixture.sh', '--remote-stack', d }):wait().code == 0)
  h.git(d .. '/review', 'branch', '-q', '--track', 'stack/math', 'origin/stack/math')
  start(d .. '/review', '')
  local function stats_loaded()
    return child.lua([[
      return vim.wait(5000, function()
        local s = require('revuey.view').session
        return s and not s.refreshing and not s.pending_scope and s.review.stack and s.review.stack.full_stats ~= nil
      end, 10)
    ]])
  end
  h.ok(stats_loaded(), 'stack stats did not load')
  screenshot('stack-remote')
  child.type_keys('[s')
  h.ok(stats_loaded(), 'stack stats did not load')
  screenshot('stack-remote-layer')
end)

-- gS on a lower layer row of the panel: the hint under the row, then the worktree on that
-- branch, with `@` moved to it (the scope stays on it, now in working-tree mode).
h.test('stack: gS checks out a lower layer, and @ moves', function()
  local d = h.tmpdir('screen-stack-switch')
  vim.fn.delete(d, 'rf')
  assert(vim.system({ h.root .. '/scripts/make-fixture.sh', '--stack', d }):wait().code == 0)
  start(d, '')
  local function settled(head)
    return child.lua([[
      local head = ...
      return vim.wait(5000, function()
        local s = require('revuey.view').session
        if not (s and not s.refreshing and not s.pending and not s.pending_scope and s.review.stack and s.review.stack.full_stats) then
          return false
        end
        for _, l in ipairs(s.review.stack.layers) do
          if l.is_head then
            return l.name == head
          end
        end
      end, 10)
    ]], { head })
  end
  h.ok(settled('stack/cart'), 'stack did not load')
  child.lua([[
    local s = require('revuey.view').session
    vim.api.nvim_set_current_win(s.panel_win)
    for row, i in pairs(s.panel_layers) do
      if i == 1 then
        vim.api.nvim_win_set_cursor(s.panel_win, { row, 0 })
      end
    end
    require('revuey.panel').update_hint(s)
  ]])
  screenshot('stack-switch-before')
  child.type_keys('gS')
  h.ok(settled('stack/math'), 'switch did not finish')
  h.eq('stack/math', vim.trim(h.git(d, 'branch', '--show-current')))
  child.lua('vim.cmd("echo") vim.api.nvim_set_current_win(require("revuey.view").session.diff_win)')
  screenshot('stack-switch-after')
end)

-- The stack tree from GitHub (fake `gh`, tests/helpers.lua tree_repo): the panel's markers on
-- the default route (⑂ other paths, ⇣ to fetch, the not-fetched note), then the tree view over
-- the diff with closed PRs hidden and shown.
h.test('stack tree from GitHub: panel markers, the tree view with closed PRs hidden and shown', function()
  local r = h.tree_repo('screen-tree')
  h.use_fake_gh(h.tmpdir('screen-tree-gh') .. '/calls.ndjson', r.prs)
  h.use_fake_ssh(r.bare)
  start(r.dir, '', 30, 120, { forge = { check = false, threads = { enabled = false }, description = { enabled = false } } })
  h.ok(child.lua([[
    return vim.wait(15000, function()
      local s = require('revuey.view').session
      local gt = s and s.gh_tree
      return gt and gt.tree and not gt.loading and not gt.running and not s.refreshing and not s.pending and s.review.stack
        and s.review.stack.kind == 'github' and s.review.stack.full_stats ~= nil and s.forge and not s.forge.busy
    end, 10)
  ]]), 'the tree did not load')
  child.lua([[
    local s = require('revuey.view').session
    vim.api.nvim_set_current_win(s.panel_win)
    vim.api.nvim_win_set_cursor(s.panel_win, { 3, 0 })
    require('revuey.panel').update_hint(s)
    vim.fn.winrestview({ topline = 1, lnum = 3 })
  ]])
  screenshot('stack-tree-panel')
  child.lua('vim.api.nvim_set_current_win(require("revuey.view").session.diff_win)')
  child.type_keys('gb')
  h.ok(child.lua([[
    return vim.wait(5000, function()
      local v = require('revuey.view').session.gh_tree.view
      return v and v.facts ~= nil
    end, 10)
  ]]), 'the tree view did not open')
  child.lua('vim.wait(50)')
  screenshot('stack-tree')
  -- closed PRs shown, and `l` across to #12's other branch: the path through it lit
  child.type_keys('C')
  child.type_keys('l')
  screenshot('stack-tree-closed')
  child.type_keys('q')
end)

-- A long, nested tree (helpers tree_extend): a 19-PR open path, a 4-PR closed chain with a 3-PR
-- fork off it, two more branches off #12; closed PRs shown, the cursor moved up to #13, across
-- into the closed chain, up it and across into the fork; the footer's path shortened.
h.test('stack tree from GitHub: a long, nested tree, scrolled', function()
  local r = h.tree_extend(h.tree_repo('screen-tree-long'))
  h.use_fake_gh(h.tmpdir('screen-tree-long-gh') .. '/calls.ndjson', r.prs)
  h.use_fake_ssh(r.bare)
  start(r.dir, '', 30, 120, { forge = { check = false, threads = { enabled = false }, description = { enabled = false } } })
  h.ok(child.lua([[
    return vim.wait(20000, function()
      local s = require('revuey.view').session
      local gt = s and s.gh_tree
      return gt and gt.tree and not gt.loading and not gt.running and not s.refreshing and not s.pending and s.review.stack
        and s.review.stack.kind == 'github' and s.forge and not s.forge.busy
    end, 10)
  ]]), 'the tree did not load')
  child.lua('vim.api.nvim_set_current_win(require("revuey.view").session.diff_win)')
  child.type_keys('gb')
  h.ok(child.lua([[
    return vim.wait(5000, function()
      local v = require('revuey.view').session.gh_tree.view
      return v and v.facts ~= nil
    end, 10)
  ]]), 'the tree view did not open')
  child.type_keys('C', 'k', 'l', 'k', 'l')
  child.lua('vim.wait(50)')
  screenshot('stack-tree-long')
  child.type_keys('q')
end)

-- Pull requests from a fake `gh`: `#N` and the review state on each layer row, and the detail
-- section of the viewed layer (stack/cart) under the stack.
h.test('stack with pull requests: PR rows and the detail section', function()
  local d = h.tmpdir('screen-forge')
  vim.fn.delete(d, 'rf')
  assert(vim.system({ h.root .. '/scripts/make-fixture.sh', '--stack', d }):wait().code == 0)
  h.git(d, 'remote', 'add', 'origin', 'git@github.com:acme/shop.git')
  local function pr(o)
    return vim.tbl_extend('keep', o, {
      url = 'https://github.com/acme/shop/pull/' .. o.number, state = 'OPEN', isDraft = false,
      author = { login = 'alice' }, latestReviews = { nodes = {} }, reviewRequests = { nodes = {} },
      mergeable = 'MERGEABLE', headRepositoryOwner = { login = 'acme' }, commits = { nodes = {} },
    })
  end
  h.use_fake_gh(h.tmpdir('screen-forge-gh') .. '/calls.ndjson', {
    -- merged PRs are shown when their head commit is in the branch
    ['acme/shop:stack/math'] = { pr({
      number = 41, title = 'Math helpers', state = 'MERGED', baseRefName = 'main', headRefName = 'stack/math',
      headRefOid = vim.trim(h.git(d, 'rev-parse', 'stack/math')),
    }) },
    ['acme/shop:stack/cart'] = { pr({
      number = 42, title = 'Cart totals with discounts', baseRefName = 'stack/math', headRefName = 'stack/cart',
      reviewDecision = 'CHANGES_REQUESTED',
      latestReviews = { nodes = { { author = { login = 'carol' }, state = 'CHANGES_REQUESTED' }, { author = { login = 'dan' }, state = 'APPROVED' } } },
      reviewRequests = { nodes = { { requestedReviewer = { login = 'bob' } } } },
      commits = { nodes = { { commit = { statusCheckRollup = { state = 'FAILURE', contexts = {
        checkRunCountsByState = { { state = 'SUCCESS', count = 12 }, { state = 'FAILURE', count = 1 }, { state = 'QUEUED', count = 2 } },
        statusContextCountsByState = {},
      } } } } } },
    }) },
    ['acme/shop:stack/ui'] = { pr({ number = 43, title = 'Cart UI', isDraft = true, baseRefName = 'stack/cart', headRefName = 'stack/ui' }) },
  })
  start(d, '', 40, 120)
  h.ok(child.lua([[
    return vim.wait(10000, function()
      local s = require('revuey.view').session
      return s and not s.refreshing and s.review.stack and s.review.stack.full_stats ~= nil
        and s.forge and s.forge.ready and not s.forge.busy and s.panel_forge ~= nil
    end, 10)
  ]]), 'PRs did not load')
  screenshot('forge-stack')
end)

-- GitHub review threads of the viewed layer's PR (fake `gh`), inline next to a local comment: an
-- open thread with a reply, a resolved one collapsed, a file-level one; the panel's counts.
h.test('stack with pull requests: GitHub review threads inline', function()
  local d = h.tmpdir('screen-forge-threads')
  vim.fn.delete(d, 'rf')
  assert(vim.system({ h.root .. '/scripts/make-fixture.sh', '--stack', d }):wait().code == 0)
  h.git(d, 'remote', 'add', 'origin', 'git@github.com:acme/shop.git')
  local cart = vim.split(h.git(d, 'show', 'stack/cart:src/cart.ts'), '\n')
  local function hunk(n)
    local out = { '@@ -0,0 +1,20 @@' }
    for i = 1, n do
      out[#out + 1] = '+' .. cart[i]
    end
    return table.concat(out, '\n')
  end
  local function comment(id, who, body, at, diff_hunk)
    return {
      id = id, databaseId = 1, url = 'https://github.com/acme/shop/pull/42#discussion_r1', body = body,
      createdAt = at, lastEditedAt = vim.NIL, state = 'SUBMITTED', diffHunk = diff_hunk or vim.NIL,
      author = { login = who }, replyTo = vim.NIL,
    }
  end
  local function thread(o)
    return {
      id = o.id, isResolved = o.resolved or false, isOutdated = false, path = 'src/cart.ts', line = o.line or vim.NIL,
      startLine = o.start_line or vim.NIL, originalLine = o.line or vim.NIL, originalStartLine = o.start_line or vim.NIL,
      diffSide = 'RIGHT', startDiffSide = o.start_line and 'RIGHT' or vim.NIL, subjectType = o.file and 'FILE' or 'LINE',
      resolvedBy = o.resolved and { login = 'alice' } or vim.NIL, comments = o.comments,
    }
  end
  h.use_fake_gh(h.tmpdir('screen-forge-threads-gh') .. '/calls.ndjson', {
    ['acme/shop:stack/cart'] = { {
      number = 42, title = 'Cart totals', url = 'https://github.com/acme/shop/pull/42', state = 'OPEN', isDraft = false,
      author = { login = 'alice' }, latestReviews = { nodes = {} }, reviewRequests = { nodes = {} }, mergeable = 'MERGEABLE',
      baseRefName = 'stack/math', headRefName = 'stack/cart', headRepositoryOwner = { login = 'acme' }, commits = { nodes = {} },
      updatedAt = '2026-01-01T00:00:00Z',
    } },
  }, nil, {
    ['acme/shop#42'] = {
      thread({ id = 'T1', file = true, comments = { comment('C1', 'erin', 'Needs a test for an empty cart.', '2026-01-01T00:00:00Z') } }),
      thread({ id = 'T2', line = 13, start_line = 12, resolved = true, comments = {
        comment('C2', 'dan', 'Return a copy instead?', '2026-01-02T00:00:00Z', hunk(13)),
        comment('C3', 'alice', 'Chaining is the point here.', '2026-01-02T01:00:00Z'),
      } }),
      thread({ id = 'T3', line = 18, comments = {
        comment('C4', 'carol', 'Should the **total** be rounded to cents?', '2026-01-03T00:00:00Z', hunk(18)),
        comment('C5', 'alice', 'Good point, will do.', '2026-01-03T01:00:00Z'),
      } }),
    },
  })
  start(d, '', 44, 120)
  h.ok(child.lua([[
    local s = require('revuey.view').session
    local ok = vim.wait(10000, function()
      return s and not s.refreshing and s.review.stack and s.review.stack.full_stats ~= nil
        and s.forge and s.forge.ready and not s.forge.busy and s.cm and s.cm.forge_items and next(s.cm.forge_items) ~= nil
    end, 10)
    -- a local comment on the same file, for contrast
    local comments = require('revuey.comments')
    local store = require('revuey.comments_view').sync_store(s)
    local cv = require('revuey.comments_view')
    local anchor = comments.anchor_for_lines(s.review.files, require('revuey.review').units(s.review),
      { path = 'src/cart.ts', side = 'new', start_line = 10, end_line = 10 }, cv.context(s).get_line)
    local c = comments.new(anchor, 'Readonly array?')
    comments.put(store, c)
    require('revuey.comments_view').refresh(s)
    vim.cmd('redraw')
    return ok
  ]]), 'threads did not load')
  screenshot('forge-threads')
end)

h.test('posting a review: comments added to the review, one in the pending review, the panel hint', function()
  local d = h.tmpdir('screen-forge-post')
  vim.fn.delete(d, 'rf')
  assert(vim.system({ h.root .. '/scripts/make-fixture.sh', '--stack', d }):wait().code == 0)
  h.git(d, 'remote', 'add', 'origin', 'git@github.com:acme/shop.git')
  h.use_fake_gh(h.tmpdir('screen-forge-post-gh') .. '/calls.ndjson', {
    ['acme/shop:stack/cart'] = { {
      number = 42, title = 'Cart totals', url = 'https://github.com/acme/shop/pull/42', state = 'OPEN', isDraft = false,
      author = { login = 'alice' }, latestReviews = { nodes = {} }, reviewRequests = { nodes = {} }, mergeable = 'MERGEABLE',
      baseRefName = 'stack/math', headRefName = 'stack/cart', headRepositoryOwner = { login = 'acme' }, commits = { nodes = {} },
      updatedAt = '2026-01-01T00:00:00Z',
    } },
  }, nil, {})
  start(d, '', 40, 120)
  h.ok(child.lua([[
    local s = require('revuey.view').session
    local ok = vim.wait(10000, function()
      return s and not s.refreshing and s.forge and s.forge.ready and not s.forge.busy
    end, 10)
    local comments = require('revuey.comments')
    local cv = require('revuey.comments_view')
    local store = cv.sync_store(s)
    local function add(l1, l2, body, extra)
      local anchor = comments.anchor_for_lines(s.review.files, require('revuey.review').units(s.review),
        { path = 'src/cart.ts', side = 'new', start_line = l1, end_line = l2 }, cv.context(s).get_line)
      local c = comments.new(anchor, body)
      for k, v in pairs(extra) do
        c[k] = v
      end
      comments.put(store, c)
    end
    add(10, 10, 'Readonly array?', { in_review = true })
    add(12, 14, 'Return a copy instead of `this`?', { in_review = true, forge_post = { state = 'pending', pr = 42, review_id = 'PRR_1', comment_id = 'C9' } })
    add(18, 18, 'Not for GitHub: check the rounding.', {})
    cv.refresh(s)
    vim.cmd('redraw')
    return ok
  ]]), 'review did not load')
  screenshot('forge-post')
end)

-- The open PR's description (fake `gh`): it arrives after the review is drawn, so it goes above
-- the first file without moving the view (the winbar says it is just above); `gg` shows it
-- collapsed, <Tab> expands it.
h.test('stack with pull requests: the PR description above the diff, collapsed and expanded', function()
  local d = h.tmpdir('screen-forge-desc')
  vim.fn.delete(d, 'rf')
  assert(vim.system({ h.root .. '/scripts/make-fixture.sh', '--stack', d }):wait().code == 0)
  h.git(d, 'remote', 'add', 'origin', 'git@github.com:acme/shop.git')
  local body = table.concat({
    '<!-- Describe the change. Link the issue it fixes. -->',
    '## Why',
    'Totals ignored **discounts**; fixes [#7](https://github.com/acme/shop/issues/7).',
    '',
    '## What',
    '- `Cart.total()` sums each line with `multiply`',
    '- [x] tests',
    '- [ ] docs',
    '',
    '![before and after](https://github.com/user-attachments/assets/1)',
    '',
    '<details>',
    '<summary>How to try it</summary>',
    '',
    '```sh',
    'npm test -- cart',
    '```',
    '</details>',
  }, '\r\n')
  h.use_fake_gh(h.tmpdir('screen-forge-desc-gh') .. '/calls.ndjson', {
    ['acme/shop:stack/cart'] = { {
      number = 42, title = 'Cart totals with discounts', url = 'https://github.com/acme/shop/pull/42', state = 'OPEN',
      isDraft = false, author = { login = 'alice' }, latestReviews = { nodes = {} }, reviewRequests = { nodes = {} },
      mergeable = 'MERGEABLE', baseRefName = 'stack/math', headRefName = 'stack/cart', headRepositoryOwner = { login = 'acme' },
      commits = { nodes = {} }, updatedAt = '2026-01-01T00:00:00Z', body = body,
    } },
  }, nil, {})
  start(d, '', 34, 120)
  h.ok(child.lua([[
    local s = require('revuey.view').session
    return vim.wait(10000, function()
      return s and not s.refreshing and s.forge and s.forge.ready and not s.forge.busy and s.layout.description ~= nil
    end, 10)
  ]]), 'the description did not arrive')
  screenshot('forge-description-late')
  child.type_keys('gg')
  screenshot('forge-description')
  child.type_keys('<Tab>')
  screenshot('forge-description-expanded')
end)

-- Old branches built on a pre-amend version of the bottom layer: one dim summary line in the
-- panel, and `!` opens the details float.
h.test('stack notes: panel summary line and the details float', function()
  local d = h.old_branches_repo('screen-stack-notes')
  start(d, '', 32, 110)
  h.ok(child.lua([[
    return vim.wait(5000, function()
      local s = require('revuey.view').session
      return s and not s.refreshing and s.review.stack and s.review.stack.full_stats ~= nil
    end, 10)
  ]]), 'stack stats did not load')
  screenshot('stack-notes-summary')
  child.lua([[vim.api.nvim_set_current_win(require('revuey.view').session.panel_win)]])
  child.type_keys('!')
  screenshot('stack-notes-float')
  child.type_keys('q')
end)

-- AI guide view (fake `claude` from tests/bin): title, meta, prose, numbered sections with
-- checkboxes, hunks rendered by the shared renderer, and the panel's section list.
h.test('guide view and the panel section list', function()
  h.use_fake_claude(h.tmpdir('screen-fake-claude') .. '/calls.ndjson')
  local d = h.tmpdir('screen-guide')
  vim.fn.delete(d, 'rf')
  assert(vim.system({ h.root .. '/scripts/make-fixture.sh', d }):wait().code == 0)
  start(d, 'main', 40, 130)
  local function generate()
    return child.lua([[
      vim.notify = function() end
      require('revuey.view').guide_command(true)
      return vim.wait(20000, function()
        local s = require('revuey.view').session
        return next(require('revuey.guide_view').jobs) == nil and s.guide.resolved ~= nil and not s.refreshing
      end, 20)
    ]])
  end
  h.ok(generate(), 'guide did not generate')
  child.lua('vim.cmd("redraw")')
  screenshot('guide-view')
  -- ]] to the first section, mr: it folds with a check, the cursor moves on, the panel counts
  child.type_keys(']]', 'mr')
  screenshot('guide-section-reviewed')
  -- a narrower window re-wraps the prose (WinResized)
  child.o.columns = 100
  child.lua('vim.cmd("redraw") vim.wait(200)')
  child.type_keys('gg')
  screenshot('guide-narrow')
end)

local function generate_guide()
  return child.lua([[
    vim.notify = function() end
    require('revuey.view').guide_command(true)
    return vim.wait(20000, function()
      local s = require('revuey.view').session
      return next(require('revuey.guide_view').jobs) == nil and s.guide.resolved ~= nil and not s.refreshing
    end, 20)
  ]])
end

-- The overview diagram under the summary: boxes coloured by kind, routed edges, labels.
h.test('guide with an overview diagram', function()
  h.use_fake_claude(h.tmpdir('screen-fake-claude-diagram') .. '/calls.ndjson')
  vim.env.REVUEY_FAKE_CLAUDE = 'diagram'
  local d = h.tmpdir('screen-guide-diagram')
  vim.fn.delete(d, 'rf')
  assert(vim.system({ h.root .. '/scripts/make-fixture.sh', d }):wait().code == 0)
  start(d, 'main', 40, 130)
  h.ok(generate_guide(), 'guide did not generate')
  child.lua('vim.cmd("redraw")')
  screenshot('guide-diagram')
  -- the diagram uses the full window width, not the 100-column prose cap (this child has a UI,
  -- so it may be resized)
  local w = child.lua([[
    vim.o.columns = 180
    vim.cmd('redraw')
    vim.cmd('doautocmd WinResized')
    local s = require('revuey.view').session
    vim.wait(2000, function() return s.prose_width == 100 end, 10)
    local out = { s.diagram_width, s.prose_width }
    vim.o.columns = 130
    return out
  ]])
  h.ok(w[1] > w[2], vim.inspect(w))
  vim.env.REVUEY_FAKE_CLAUDE = nil
end)

-- Line notes from the guide: a violet band above the lines they point at (a range says how many
-- lines), unlike comment boxes below their lines; `gN` collapses them to a marker.
h.test('guide line notes above their lines, collapsed with gN', function()
  h.use_fake_claude(h.tmpdir('screen-fake-claude-notes') .. '/calls.ndjson')
  vim.env.REVUEY_FAKE_CLAUDE = 'notes'
  local d = h.tmpdir('screen-guide-notes')
  vim.fn.delete(d, 'rf')
  assert(vim.system({ h.root .. '/scripts/make-fixture.sh', d }):wait().code == 0)
  start(d, 'main', 40, 130)
  h.ok(generate_guide(), 'guide did not generate')
  child.lua('vim.cmd("redraw")')
  -- ]n to the first note: the hunk and its notes on screen
  child.type_keys(']n', 'zt', '<C-y><C-y><C-y><C-y>')
  child.lua('vim.cmd("redraw")')
  screenshot('guide-line-notes')
  child.type_keys('gN')
  child.lua('vim.cmd("redraw")')
  screenshot('guide-line-notes-collapsed')
  vim.env.REVUEY_FAKE_CLAUDE = nil
end)

-- A full-stack guide: each hunk header names the branch (or branches) that introduced it.
h.test('full-stack guide with branch labels', function()
  h.use_fake_claude(h.tmpdir('screen-fake-claude-stack') .. '/calls.ndjson')
  local d = h.tmpdir('screen-guide-stack')
  vim.fn.delete(d, 'rf')
  assert(vim.system({ h.root .. '/scripts/make-fixture.sh', '--stack', d }):wait().code == 0)
  start(d, '', 40, 130)
  child.type_keys('gs')
  child.lua([[
    vim.wait(5000, function()
      local s = require('revuey.view').session
      return s.scope.kind == 'full' and not s.refreshing and not s.pending_scope
    end, 10)
  ]])
  h.ok(generate_guide(), 'guide did not generate')
  child.type_keys(']]', ']]') -- section 2: two files, two layers
  child.lua('vim.cmd("redraw")')
  screenshot('guide-stack-labels')
end)

-- Nested marks: one hunk of a three-hunk file marked in the diff (it folds with "✓ reviewed",
-- the file header and the panel show "◐ 1/3"), then the guide: the section holding that hunk
-- shows partial progress on its heading and in the panel's section list.
h.test('partial progress: a reviewed hunk in the diff, then in the guide', function()
  h.use_fake_claude(h.tmpdir('screen-fake-claude-partial') .. '/calls.ndjson')
  local t = {}
  for i = 1, 40 do
    t[#t + 1] = 'line ' .. i
  end
  local long = table.concat(t, '\n') .. '\n'
  local changed = long:gsub('line 3\n', 'line three\n'):gsub('line 20\n', 'line twenty\n'):gsub('line 35\n', 'line thirty-five\n')
  local d = h.repo('screen-partial', { ['m.txt'] = long }, { ['a.txt'] = 'new\nfile\n', ['m.txt'] = changed })
  start(d, 'main', 40, 120)
  child.type_keys(']f', ']c', 'mr')
  screenshot('hunk-reviewed')
  h.ok(generate_guide(), 'guide did not generate')
  child.type_keys('gg')
  child.lua('vim.cmd("redraw")')
  screenshot('guide-partial')
end)

-- Edit from the review: `ge` on a hunk line opens the real file in a float over the diff, folded
-- to the hunk plus context; after an edit and :w the guide keeps the hunk in its section with an
-- "edited since guide" marker.
h.test('edit float over the diff, then the guide with an edited hunk', function()
  h.use_fake_claude(h.tmpdir('screen-fake-claude-edit') .. '/calls.ndjson')
  local t = {}
  for i = 1, 40 do
    t[#t + 1] = 'line ' .. i
  end
  local long = table.concat(t, '\n') .. '\n'
  local changed = long:gsub('line 3\n', 'line three\n'):gsub('line 20\n', 'line twenty\n'):gsub('line 35\n', 'line thirty-five\n')
  local d = h.repo('screen-edit', { ['m.txt'] = long }, { ['a.txt'] = 'new\nfile\n', ['m.txt'] = changed })
  start(d, 'main', 40, 120)
  h.ok(generate_guide(), 'guide did not generate')
  child.type_keys('gG', 'gg', ']f', ']c', ']c')
  -- the tab line names the current window's file by its (temporary, per-run) path: hide it
  child.lua('vim.o.showtabline = 0')
  child.type_keys('ge')
  child.lua('vim.cmd("redraw")')
  screenshot('edit-float')
  child.lua('vim.o.showtabline = 1')
  child.lua([[
    vim.api.nvim_set_current_line('line twenty, edited')
    local s = require('revuey.view').session
    local n = s.render_count
    vim.cmd('silent write')
    vim.wait(5000, function() return s.render_count > n and not s.refreshing end, 10)
  ]])
  child.type_keys('q', 'gG', 'gg')
  child.lua('vim.cmd("redraw")')
  screenshot('guide-edited')
end)

-- Comments: an inline thread (with a reply) under a commented range with gutter bars, the
-- editor float opened by `gc`, and the comments list.
h.test('comments: inline thread, editor float, comments list', function()
  start(fixture, 'main', 34, 120)
  child.lua([[
    local s = require('revuey.view').session
    local cv = require('revuey.comments_view')
    local ed = require('revuey.comment_editor')
    local comments = require('revuey.comments')
    local function row_of(path, kind, lnum)
      for row, e in ipairs(s.layout.map) do
        if e.path == path and e.kind == kind and e.new_lnum == lnum then
          return row
        end
      end
    end
    local first, last = row_of('src/cart.ts', 'add', 1), row_of('src/cart.ts', 'add', 2)
    vim.api.nvim_win_set_cursor(s.diff_win, { first, 0 })
    cv.add(s, first, last)
    vim.api.nvim_buf_set_lines(ed.current.buf, 0, -1, false, { 'Is `multiply` still needed here? **Check** the callers.' })
    ed.save(ed.current)
    local c = comments.list(s.cm.store)[1]
    comments.reply(s.cm.store, c.id, 'Yes: totals use it.', { kind = 'agent', name = 'claude' })
    comments.save(s.cm.store)
    cv.refresh(s)
    vim.api.nvim_win_set_cursor(s.diff_win, { first, 0 })
    vim.cmd('normal! zt')
  ]])
  screenshot('comment-thread')
  child.type_keys('j', 'j', 'gc')
  child.type_keys('Looks off by one.')
  child.type_keys('<Esc>')
  screenshot('comment-editor')
  child.type_keys('<C-s>', 'cl')
  screenshot('comment-list')
  child.type_keys('q')
end)

-- The agent link: "● agent connected" in the panel header (a watcher with a fresh heartbeat),
-- a comment sent and waiting for the agent, and one the agent answered.
h.test('agent link: connected indicator, sent and answered markers', function()
  start(fixture, 'main', 34, 120)
  child.lua([[
    local s = require('revuey.view').session
    local comments = require('revuey.comments')
    local sessions = require('revuey.sessions')
    local link = require('revuey.agent_link')
    local function row_of(path, kind, lnum)
      for row, e in ipairs(s.layout.map) do
        if e.path == path and e.kind == kind and e.new_lnum == lnum then
          return row
        end
      end
    end
    local cv = require('revuey.comments_view')
    local ed = require('revuey.comment_editor')
    local store = cv.sync_store(s)
    local function add(lnum, text)
      local row = row_of('src/cart.ts', 'add', lnum)
      cv.add(s, row, row)
      vim.api.nvim_buf_set_lines(ed.current.buf, 0, -1, false, { text })
      ed.save(ed.current)
      for _, c in pairs(store.comments) do
        if c.body == text then
          return c
        end
      end
    end
    local a = add(1, 'Why import both?')
    comments.mark_sent(store, a.id)
    comments.mark_delivered(store, a.id) -- a watch printed it
    local b = add(4, 'Is this tested?')
    comments.mark_sent(store, b.id)
    comments.reply(store, b.id, 'Yes, in cart.test.ts.', { kind = 'agent', name = 'claude' })
    comments.save(store)
    -- an agent watching this review
    sessions.write_watcher(s.link.bases, { pid = vim.fn.getpid(), session = s.link.id, worktree = s.review.root,
      started_at = sessions.now_ms(), heartbeat_at = sessions.now_ms() })
    link.poll(s)
    require('revuey.comments_view').refresh(s)
    vim.api.nvim_win_set_cursor(s.diff_win, { row_of('src/cart.ts', 'add', 1), 0 })
    vim.cmd('normal! zt')
  ]])
  screenshot('agent-link')
end)

-- An AI review: the panel's block (verdict, findings to triage, summary) and a finding's thread
-- (AI author, severity, the accept / dismiss keys, a suggested change).
h.test('AI review: panel block and an untriaged finding', function()
  start(fixture, 'main', 34, 120)
  child.lua([[
    local s = require('revuey.view').session
    local comments = require('revuey.comments')
    local ai_review = require('revuey.ai_review')
    local cv = require('revuey.comments_view')
    local hunks = require('revuey.review').units(s.review).hunks
    local cart
    for _, hk in ipairs(hunks) do
      if hk.path == 'src/cart.ts' and not cart then
        cart = hk
      end
    end
    local first_add
    for i, l in ipairs(cart.text) do
      if l:sub(1, 1) == '+' and not first_add then
        first_add = i
      end
    end
    local store = cv.sync_store(s)
    assert(ai_review.import({
      summary = 'The cart total moves into its own module. Rounding is the main risk.',
      verdict = 'request_changes',
      findings = {
        { hunk = cart.id, line = first_add, severity = 'major', title = 'Import both helpers from one place',
          body = 'Two imports of the same module drift apart.', suggestion = "import { sum, round } from './math';" },
        { hunk = 'h999', line = 1, severity = 'minor', title = 'Ghost', body = 'dropped' },
      },
    }, {
      review = s.review, hunks = hunks, store = store,
      events = comments.events_path_for(s.review.state._path), info = comments.review_info(s.review),
      author = { kind = 'ai', name = 'claude' }, record_path = ai_review.record_path(store.path), now = 1767225600000,
    }))
    cv.refresh(s)
    for row, e in ipairs(s.layout.map) do
      if e.path == 'src/cart.ts' and e.hunk_idx == cart.hunk_idx and e.line_idx == first_add then
        vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
      end
    end
    vim.cmd('normal! zt')
  ]])
  screenshot('ai-review')
end)

-- Finding the keys: the winbar names the keys of the comment under the cursor (your comment,
-- added to the review), `g?` lists every key; moving over comments stays within the main-loop
-- budget (the hint reads the row's cached cover lists).
h.test('keys: the winbar hint on a comment, the g? float, the cost of the hint', function()
  start(fixture, 'main', 34, 120)
  local cost = child.lua([[
    local s = require('revuey.view').session
    local cv = require('revuey.comments_view')
    local comments = require('revuey.comments')
    local units = require('revuey.review').units(s.review)
    local function row_of(path, lnum)
      for row, e in ipairs(s.layout.map) do
        if e.path == path and e.kind == 'add' and e.new_lnum == lnum then
          return row
        end
      end
    end
    local store = cv.sync_store(s)
    -- a comment on every other line of src/cart.ts, then one added to the review
    local mine
    for l = 1, 25, 2 do
      local a = comments.anchor_from_rows(s.review.files, units, { s.layout.map[row_of('src/cart.ts', l)] }, cv.context(s).get_line)
      local c = comments.new(a, 'Note ' .. l)
      if l == 5 then
        c.in_review, mine = true, c
      end
      comments.put(store, c)
    end
    comments.save(store)
    cv.refresh(s)
    -- the hint's cost per cursor row (no git, no network: the row's cover list)
    local kh = require('revuey.key_help')
    local n, t0 = 2000, vim.uv.hrtime()
    for i = 1, n do
      vim.api.nvim_win_set_cursor(s.diff_win, { row_of('src/cart.ts', (i % 25) + 1), 0 })
      kh.update(s)
    end
    local per = (vim.uv.hrtime() - t0) / n / 1e3
    vim.api.nvim_win_set_cursor(s.diff_win, { row_of('src/cart.ts', 1), 0 })
    vim.cmd('normal! zt')
    _G.revuey_maxgap = 0
    return per
  ]])
  io.write(('    (key hint: %.1fus per cursor row)\n'):format(cost))
  -- holding j over the comments: the main loop stays responsive
  for _ = 1, 30 do
    child.type_keys('j')
  end
  local gap = child.lua_get('_G.revuey_maxgap')
  local max_gap = tonumber(os.getenv('REVUEY_TEST_MAX_GAP_MS')) or 50
  io.write(('    (largest main-loop gap moving over comments: %.0fms, budget %dms)\n'):format(gap, max_gap))
  h.ok(gap < max_gap, ('main loop blocked for %.0fms'):format(gap))
  child.lua([[
    local s = require('revuey.view').session
    for row, e in ipairs(s.layout.map) do
      if e.path == 'src/cart.ts' and e.kind == 'add' and e.new_lnum == 5 then
        vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
      end
    end
  ]])
  screenshot('key-hint')
  child.type_keys('g?')
  screenshot('key-help')
  child.type_keys('q')
end)

-- Folders: a monorepo's files under a header per folder in a narrow panel, the long headers
-- abbreviated fish style; on a header the diff's winbar names <CR> and the folder's full path.
h.test('panel folders: nested folders in a narrow panel, the hint on a header', function()
  local d = h.repo('screen-folders', {
    ['README.md'] = 'readme\n',
    ['services/billing/src/handlers/invoices/create.ts'] = 'export const a = 1;\n',
    ['services/billing/test/create.test.ts'] = 'test("a", () => {});\n',
  }, {
    ['README.md'] = 'readme, updated\n',
    ['services/billing/src/handlers/invoices/create.ts'] = 'export const a = 2;\n',
    ['services/billing/src/handlers/invoices/refund.ts'] = 'export const r = 1;\n',
    ['services/billing/src/index.ts'] = 'export * from "./handlers/invoices/create";\n',
    ['services/billing/test/create.test.ts'] = 'test("a", () => { expect(1).toBe(1); });\n',
    ['packages/ui/components/Button.tsx'] = 'export const Button = () => null;\n',
  })
  start(d, 'main', 24, 90, { panel_width = 26 })
  child.lua([[
    local s = require('revuey.view').session
    for row, g in pairs(s.panel_dirs) do
      if g.dir == 'services/billing/src/handlers/invoices' then
        vim.api.nvim_set_current_win(s.panel_win)
        vim.api.nvim_win_set_cursor(s.panel_win, { row, 0 })
        vim.api.nvim_exec_autocmds('CursorMoved', { buffer = s.panel_buf })
      end
    end
    vim.cmd('redraw!')
  ]])
  screenshot('panel-folders-narrow')
end)

h.run()
