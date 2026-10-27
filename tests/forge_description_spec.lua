-- The PR description at the top of the diff view (forge_description.lua, forge_view, view):
-- cleaning GitHub Markdown (template comments, images, HTML, entities, code left alone), rows
-- and the collapsed fold; then real git stacks with a fake `gh` (tests/bin/gh) on PATH: shown
-- for an open PR with a body, absent without one, arriving late without moving the cursor or
-- breaking rows (comments, `]m`, marks, folds), <Tab>/zo expanding it, `R`, failures, scopes and
-- the guide view.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')
local state_dir = h.tmpdir('fd-state')
local log_file = h.tmpdir('fd-log') .. '/revuey.log'
local function setup(extra)
  require('revuey').setup(vim.tbl_deep_extend('force', { state_dir = state_dir, lsp_warmup = false, log_file = log_file }, extra or {}))
end
setup()
local fd = require('revuey.forge_description')
local forge = require('revuey.forge')
local fv = require('revuey.forge_view')
local view = require('revuey.view')
local log = require('revuey.log')
local comments = require('revuey.comments')
local cv = require('revuey.comments_view')
local review_mod = require('revuey.review')

local function texts(rows)
  return vim.tbl_map(function(r)
    return r.text
  end, rows)
end

-- ---------------------------------------------------------------------------
-- Unit: cleaning
-- ---------------------------------------------------------------------------

h.test('clean: HTML comments go (one line, several lines, inline, unterminated); nothing left is empty', function()
  h.eq('', fd.clean(nil))
  h.eq('', fd.clean(''))
  h.eq('', fd.clean('  \n\t\n  '))
  local template = table.concat({
    '<!-- Thanks for contributing!',
    '     Describe the change and link the issue. -->',
    '',
    '<!-- Checklist: tests, docs -->',
    '',
  }, '\n')
  h.eq('', fd.clean(template), 'only a template')
  h.eq('', fd.clean('<!-- never closed\nso the rest is hidden too'), 'GitHub hides the rest too')
  h.eq('', fd.clean('```\n```'), 'an empty fence is nothing')
  h.eq('Real text', fd.clean(template .. '\r\nReal text\r\n'))
  h.eq('before  after', fd.clean('before <!-- note --> after'), 'prose joins the words')
  h.eq('a\n\nb', fd.clean('a\n<!-- c -->\n\n<!-- d -->\n\n\nb'), 'a comment line leaves no blank run')
  h.eq('kept\nend', fd.clean('kept <!-- start\nmiddle\nstill --> \nend'))
end)

h.test('clean: images and HTML as text, entities, task lists, setext headings, rules; unknown tags stay', function()
  h.eq('(image: diagram) and (image)', fd.clean('![diagram](https://x/a.png "t") and ![](b.png)'))
  h.eq('(image: Before) (image)', fd.clean('<img src="a.png" alt="Before"> <img src=\'b.png\' width=300>'))
  h.eq('[(image: CI)](https://ci)', fd.clean('[![CI](https://badge.svg)](https://ci)'), 'a linked image keeps its link')
  h.eq('(video)', fd.clean('<video src="https://x/v.mp4"></video>'))
  h.eq('See [the docs](https://d) and https://example.com', fd.clean('See [the docs](https://d) and <https://example.com>'))
  h.eq('Vec<String> & <T> stays; a < b > c', fd.clean('Vec<String> &amp; <T> stays; a &lt; b &gt; c'))
  h.eq("it's — “q” é", fd.clean('it&#39;s &mdash; &#x201C;q&#x201D; &eacute;'):gsub('&eacute;', 'é'))
  h.eq('**bold** *it* `code` link', fd.clean('<b>bold</b> <em>it</em> <code>code</code> <a href="https://x">link</a>'))
  h.eq('one\ntwo', fd.clean('one<br>two'))
  h.eq('▸ Logs\n\ninside', fd.clean('<details>\n<summary>Logs</summary>\n\ninside\n</details>'))
  h.eq('## Title\n\ntext', fd.clean('<h2>Title</h2>\n\ntext'))
  h.eq('- ☑ done\n- ☐ todo\n* ☑ X', fd.clean('- [x] done\n- [ ] todo\n* [X] X'))
  h.eq('# Big\n## Small', fd.clean('Big\n===\nSmall\n---'))
  h.eq('a\n\n---\n\nb\n---', fd.clean('a\n\n***\n\nb\n\n- - -'):gsub('\n\n%-%-%-$', '\n---'))
  h.eq('- item\n---', fd.clean('- item\n---'), 'a list item is no setext heading')
end)

h.test('clean: code is left alone (fences, ~~~ fences, inline code), comments and tags inside it too', function()
  local body = table.concat({
    'Run `<b>x</b>` and ``a `<i>` b``:',
    '```html',
    '<!-- kept -->',
    '<img src="x" alt="y">',
    '```',
    '~~~',
    '![not an image](x)',
    '~~~',
  }, '\n')
  h.eq(table.concat({
    'Run `<b>x</b>` and ``a `<i>` b``:',
    '```',
    '<!-- kept -->',
    '<img src="x" alt="y">',
    '```',
    '```',
    '![not an image](x)',
    '```',
  }, '\n'), fd.clean(body))
  h.eq('```\nopen fence\n```', fd.clean('```\nopen fence'), 'an unclosed fence is closed')
end)

-- ---------------------------------------------------------------------------
-- Unit: rows
-- ---------------------------------------------------------------------------

h.test('render_body: prose (headings, lists, code), table rows and rules on rows of their own', function()
  local md = fd.clean(table.concat({
    '## Summary', '', 'Adds **totals**.', '', '- one', '- two', '', '| a | b |', '|---|:-:|', '| `1` | 2 |', '', '***', '',
    '```', 'code line', '```',
  }, '\n'))
  local rows = fd.render_body(md, 40)
  h.eq({ 'Summary', '', 'Adds totals.', '', '• one', '• two', '', '| a | b |', '─────────', '| 1 | 2 |', '',
    ('─'):rep(40), '', '  code line' }, texts(rows))
  local function has(row, group)
    for _, hl in ipairs(rows[row].hls) do
      if hl[3] == group then
        return true
      end
    end
  end
  h.ok(has(1, 'RevueyGuideHeading'), 'heading')
  h.ok(has(3, 'RevueyGuideBold'), 'bold')
  h.ok(has(5, 'RevueyGuideListMarker'), 'list marker')
  h.ok(has(9, 'RevueyForgeDescriptionRule') and has(12, 'RevueyForgeDescriptionRule'), 'rules')
  h.ok(has(10, 'RevueyGuideCode'), 'code in a table cell')
  h.ok(has(14, 'RevueyGuideCode'), 'fenced code')
  -- wrapped to the width, by display width
  for _, r in ipairs(fd.render_body(fd.clean(('購物車 word '):rep(30)), 30)) do
    h.ok(vim.api.nvim_strwidth(r.text) <= 30, r.text)
  end
end)

h.test('render: title row, indented body, a blank row; past max_lines + 1 rows the rest is a fold', function()
  local pr = { number = 12, title = 'Cart totals' }
  local function body(n)
    local t = {}
    for i = 1, n do
      t[i] = '- item ' .. i
    end
    return table.concat(t, '\n')
  end
  local r = fd.render(pr, body(3), 60, { max_lines = 3 })
  h.eq({ 'PR #12 · Cart totals', '  • item 1', '  • item 2', '  • item 3', '' }, texts(r.rows))
  h.eq(nil, r.fold)
  h.eq({ { 0, #'PR #12 · Cart totals', 'RevueyForgeDescriptionTitle' }, { 0, 6, 'RevueyForgeNumber' } }, r.rows[1].hls)
  h.eq({ 2, 2 + #'•', 'RevueyGuideListMarker' }, r.rows[2].hls[1], 'body highlights follow the indent')
  h.eq(nil, fd.render(pr, body(4), 60, { max_lines = 3 }).fold, 'one more row: not worth a fold')
  r = fd.render(pr, body(9), 60, { max_lines = 3 })
  h.eq({ 5, 10 }, r.fold, 'rows past the title and 3 body rows, up to the last body row')
  h.eq(6, r.more)
  h.eq('', r.rows[#r.rows].text)
  h.eq(fd.MAX_LINES, 6)
  h.eq({ 1 + 6 + 1, 1 + 9 }, fd.render(pr, body(9), 60).fold, 'default max_lines')
  r = fd.render({ number = 3, title = 'WIP\nnext', draft = true }, 'x', 60)
  h.eq('PR #3 · WIP next · draft', r.rows[1].text)
  h.eq('RevueyForgeDraft', r.rows[1].hls[3][3])
end)

h.test('the PR lookup asks for the body; normalize keeps it', function()
  local q = forge.build_query({ { repo = { host = 'github.com', owner = 'acme', name = 'shop' }, branch = 'x' } })
  h.ok(q:match('fragment pr on PullRequest {[^}]-%f[%w]body%f[%W]'), q)
  local pr = forge.normalize({ number = 1, body = 'Hi\r\nthere' }, 'github.com/acme/shop')
  h.eq('Hi\r\nthere', pr.body)
  h.eq('', forge.normalize({ number = 1, body = vim.NIL }, 'k').body)
  h.eq('', forge.normalize({ number = 1 }, 'k').body)
end)

-- ---------------------------------------------------------------------------
-- Integration: a stack with PRs, fake gh
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

local function idle(s)
  assert(vim.wait(15000, function()
    return not s.refreshing and not s.pending and not s.pending_scope
      and s.forge and s.forge.ready and not s.forge.busy and not s.forge.scheduled
  end, 10), 'refresh / PR lookup did not finish')
  vim.wait(50)
end

local function reset()
  forge.cache = {}
  forge.threads_cache = {}
  log.entries = {}
  forge.now = function()
    return vim.uv.hrtime() / 1e6
  end
end

local LONG = table.concat({
  '<!-- Describe your change. Link the issue. -->',
  '## Why',
  '',
  'Totals ignored **discounts**; see [#7](https://github.com/acme/shop/issues/7).',
  '',
  '![screenshot](https://user-images.githubusercontent.com/1/x.png)',
  '',
  '- [x] tests',
  '- [ ] docs',
  '',
  '```ts',
  'cart.total() // 42',
  '```',
  '',
  'Last line of the description.',
}, '\n')

local function pr(o)
  return {
    number = o.number, title = o.title or ('PR ' .. o.number), url = 'https://github.com/acme/shop/pull/' .. o.number,
    state = o.state or 'OPEN', isDraft = false, author = { login = 'alice' }, latestReviews = { nodes = {} },
    reviewRequests = { nodes = {} }, mergeable = 'MERGEABLE', baseRefName = o.base or 'main', headRefName = o.head,
    headRepositoryOwner = { login = 'acme' }, headRefOid = o.oid or vim.NIL, updatedAt = '2026-01-01T00:00:00Z',
    commits = { nodes = {} }, body = o.body,
  }
end

local function prs(bodies)
  return {
    ['acme/shop:stack/math'] = { pr({ number = 11, head = 'stack/math', body = bodies.math }) },
    ['acme/shop:stack/cart'] = { pr({ number = 12, title = 'Cart totals', head = 'stack/cart', base = 'stack/math', body = bodies.cart }) },
    ['acme/shop:stack/ui'] = { pr({ number = 13, head = 'stack/ui', base = 'stack/cart', body = bodies.ui }) },
  }
end

local function lines(s)
  return vim.api.nvim_buf_get_lines(s.diff_buf, 0, -1, false)
end

local function row_of(s, path, kind, lnum)
  for row, e in ipairs(s.layout.map) do
    if e.path == path and e.kind == kind and (kind == 'del' and e.old_lnum or e.new_lnum) == lnum then
      return row
    end
  end
  error(('no %s row %s:%d'):format(kind, path, lnum))
end

local function file_row(s, path)
  for row, e in ipairs(s.layout.map) do
    if e.path == path and e.meta == 'file' then
      return row
    end
  end
end

local function keys(s, k, row)
  vim.api.nvim_set_current_win(s.diff_win)
  if row then
    vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
  end
  vim.api.nvim_feedkeys(vim.keycode(k), 'mtx', false)
end

---`R`, and wait for it (its "refreshed" message kept out of the output).
local function refresh(s)
  local _, restore = h.capture_notify()
  keys(s, 'R')
  idle(s)
  restore()
end

local function cursor(s)
  return vim.api.nvim_win_get_cursor(s.diff_win)[1]
end

local function closed(s, row)
  return vim.api.nvim_win_call(s.diff_win, function()
    return vim.fn.foldclosed(row)
  end)
end

local function desc_rows(s)
  return s.layout.description and s.layout.description.end_row or 0
end

---The buffer, the layout and the side table agree, and every description row is a prose row
---above the first file.
local function consistent(s)
  h.eq(s.layout.lines, lines(s), 'buffer = layout')
  h.eq(#s.layout.lines, #s.layout.map)
  local n = desc_rows(s)
  for row = 1, n do
    h.eq('description', s.layout.map[row].role, 'row ' .. row)
    h.eq('prose', s.layout.map[row].kind)
  end
  h.eq(n + 1, s.layout.files[1].start_row, 'the first file right after the description')
end

local function add_comment(s, path, line, text)
  local store = cv.sync_store(s)
  local anchor = comments.anchor_for_lines(s.review.files, review_mod.units(s.review),
    { path = path, side = 'new', start_line = line, end_line = line }, cv.context(s).get_line)
  local c = comments.new(anchor, text)
  comments.put(store, c)
  cv.refresh(s)
  return c
end

local function vlines(s, row)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.diff_buf, cv.ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    for _, l in ipairs(m[4].virt_lines or {}) do
      for _, ch in ipairs(l) do
        out[#out + 1] = ch[1]
      end
    end
  end
  return table.concat(out)
end

h.test('an open PR with a body: its description above the first file, collapsed, every diff key intact', function()
  reset()
  local calls = h.tmpdir('fd-gh-basic') .. '/calls.ndjson'
  h.use_fake_gh(calls, prs({ cart = LONG }))
  local s = open(stack_fixture('fd-basic'))
  idle(s)
  local all = h.read_calls(calls)
  h.ok(all[1].argv[5]:find('headRefOid body', 1, true), 'the lookup asks for the body')
  h.eq(1, #vim.tbl_filter(function(x)
    return (x.argv[5] or ''):find('pullRequests', 1, true) ~= nil
  end, all), 'no extra call for it')
  consistent(s)
  local l = lines(s)
  h.eq('PR #12 · Cart totals', l[1])
  h.eq('  Why', l[2])
  h.ok(not table.concat(l, '\n'):find('Describe your change', 1, true), 'template comment gone')
  h.ok(table.concat(l, '\n'):find('(image: screenshot)', 1, true), 'image as text')
  h.ok(table.concat(l, '\n'):find('Last line of the', 1, true))
  local b = s.layout.description.blocks[1]
  h.eq({ 'https://github.com/acme/shop/pull/12', 12 }, { b.url, b.number })
  -- collapsed: the rows past the preview are one closed fold, with a hint
  h.ok(b.fold, 'long enough to fold')
  h.eq(b.fold[1], closed(s, b.fold[1]))
  h.eq(b.fold[1], closed(s, b.fold[2]))
  local ft = vim.api.nvim_win_call(s.diff_win, function()
    vim.v.foldstart, vim.v.foldend = b.fold[1], b.fold[2]
    return view.foldtext()
  end)
  h.eq({ { ('  … %d more lines (<Tab> expands)'):format(b.fold[2] - b.fold[1] + 1), 'RevueyForgeDescriptionMore' } }, ft)
  h.eq(-1, closed(s, 1), 'the title and preview are not folded')
  h.eq(-1, closed(s, b.end_row), 'nor the blank row')
  -- the file folds still work (and are separate)
  h.eq(-1, closed(s, file_row(s, 'src/cart.ts')))
  -- highlights on the title (prose rows get theirs from decorate)
  local marks = vim.api.nvim_buf_get_extmarks(s.diff_buf, -1, { 0, 0 }, { 0, -1 }, { details = true })
  local groups = {}
  for _, m in ipairs(marks) do
    groups[m[4].hl_group or ''] = true
  end
  h.ok(groups.RevueyForgeDescriptionTitle and groups.RevueyForgeNumber, vim.inspect(groups))
  -- diff keys on description rows refuse quietly; on code they work as before
  local msgs, restore = h.capture_notify()
  keys(s, 'gc', 2)
  keys(s, 'mr', 2)
  keys(s, 'ge', 2)
  restore()
  h.eq(0, #vim.tbl_filter(function(m)
    return (m.level or 0) >= vim.log.levels.WARN
  end, msgs), vim.inspect(msgs))
  h.ok(msgs[1].msg:find('move to a diff line', 1, true), vim.inspect(msgs))
  h.eq({}, comments.list(s.cm.store, { include_resolved = true, include_drafts = true }))
  keys(s, ']c', 1)
  h.eq(s.layout.hunks[1].first_change, cursor(s), ']c from the description reaches the first hunk')
  keys(s, ']f', 1)
  h.eq(file_row(s, 'src/cart.ts'), cursor(s), ']f reaches the first file')
  -- the winbar names the PR on description rows
  vim.api.nvim_win_call(s.diff_win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  local wb = vim.api.nvim_win_call(s.diff_win, function()
    vim.g.statusline_winid = s.diff_win
    return view.winbar()
  end)
  h.ok(wb:find('PR #12', 1, true) and wb:find('Cart totals', 1, true), wb)
  view.close()
end)

h.test('no description: no PR, an empty body, a template-only body, a merged PR, or turned off', function()
  local d = stack_fixture('fd-none')
  local template = '<!-- What does this change? -->\r\n\r\n<!-- Screenshots -->\r\n'
  for _, case in ipairs({ 'no pr', 'nil', 'empty', 'template', 'merged', 'off', 'forge off' }) do
    reset()
    local calls = h.tmpdir('fd-gh-none-' .. case:gsub(' ', '-')) .. '/calls.ndjson'
    local list = prs({ cart = case == 'empty' and '   \n' or case == 'template' and template or (case ~= 'nil' and LONG or nil) })
    if case == 'no pr' then
      list = {}
    elseif case == 'merged' then
      list['acme/shop:stack/cart'][1].state = 'MERGED'
      list['acme/shop:stack/cart'][1].headRefOid = vim.trim(h.git(d, 'rev-parse', 'stack/cart'))
    end
    h.use_fake_gh(calls, list)
    if case == 'off' then
      setup({ forge = { description = false } })
    elseif case == 'forge off' then
      setup({ forge = { enabled = false } })
    end
    local s = open(d)
    if case == 'forge off' then
      vim.wait(200)
    else
      idle(s)
    end
    h.eq(nil, s.layout.description, case)
    h.eq(1, s.layout.files[1].start_row, case)
    h.ok(lines(s)[1]:find('src/', 1, true), case .. ': ' .. lines(s)[1])
    if case == 'merged' then
      h.ok(fv.pr(s, 'stack/cart'), 'the merged PR is found (shown in the panel)')
    end
    view.close()
    setup()
  end
end)

h.test('arriving late: the view and cursor stay on the code; comments, ]m, marks and rows follow', function()
  reset()
  local calls = h.tmpdir('fd-gh-late') .. '/calls.ndjson'
  h.use_fake_gh(calls, prs({ cart = LONG }), 'slow')
  vim.env.REVUEY_FAKE_GH_DELAY = '1'
  local s = open(stack_fixture('fd-late'))
  h.ok(s.forge and s.forge.busy, 'the lookup is still running')
  h.eq(nil, s.layout.description, 'not there yet')
  -- the user reads cart.ts line 13 (a few lines into the window), with a comment on line 18, an
  -- opened unchanged-line fold... and a reviewed hunk elsewhere
  local c18 = add_comment(s, 'src/cart.ts', 18, 'Round to cents?')
  local r13 = row_of(s, 'src/cart.ts', 'add', 13)
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_win_call(s.diff_win, function()
    vim.fn.winrestview({ topline = r13 - 4, lnum = r13, col = 2 })
  end)
  local before = vim.api.nvim_win_call(s.diff_win, function()
    return { winline = vim.fn.winline(), col = vim.fn.col('.'), topline = vim.fn.line('w0') }
  end)
  idle(s)
  vim.env.REVUEY_FAKE_GH_DELAY = nil
  h.ok(s.layout.description, 'arrived')
  local n = desc_rows(s)
  consistent(s)
  -- the same code line under the cursor, at the same place in the window
  local e = s.layout.map[cursor(s)]
  h.eq({ 'src/cart.ts', 'add', 13 }, { e.path, e.kind, e.new_lnum })
  h.eq(r13 + n, cursor(s))
  local after = vim.api.nvim_win_call(s.diff_win, function()
    return { winline = vim.fn.winline(), col = vim.fn.col('.'), topline = vim.fn.line('w0') }
  end)
  h.eq(before.winline, after.winline, 'the cursor did not move on screen')
  h.eq(before.col, after.col)
  h.eq(before.topline + n, after.topline, 'the view scrolled with the rows inserted above')
  -- the comment moved with its line: drawn there, ]m reaches it
  local r18 = row_of(s, 'src/cart.ts', 'add', 18)
  h.ok(vlines(s, r18):find('Round to cents?', 1, true), vlines(s, r18))
  h.eq(r18, s.cm.jump[c18.id])
  keys(s, ']m', file_row(s, 'src/cart.ts'))
  h.eq(r18, cursor(s))
  keys(s, '[m', s.layout.files[2].start_row)
  h.eq(r18, cursor(s))
  -- marks: mr on a hunk line marks that hunk, at its new rows
  keys(s, 'mr', row_of(s, 'src/cart.ts', 'add', 3))
  h.eq(1, select(1, require('revuey.units').progress(s.review.state, review_mod.units(s.review).by_file[1])))
  consistent(s)
  -- the winbar's hint: with the first file at the top, the description is just above
  vim.api.nvim_win_call(s.diff_win, function()
    vim.fn.winrestview({ topline = n + 1, lnum = n + 1 })
  end)
  local wb = vim.api.nvim_win_call(s.diff_win, function()
    vim.g.statusline_winid = s.diff_win
    return view.winbar()
  end)
  h.ok(wb:find('↑ PR description', 1, true), wb)
  view.close()
end)

h.test('a plain review: its branch\'s PR; an unchanged-line fold the user opened stays open when it arrives', function()
  reset()
  setup({ context_lines = 25 })
  local base, changed = {}, {}
  for i = 1, 40 do
    base[i] = 'line ' .. i
    changed[i] = (i == 2 or i == 39) and ('changed ' .. i) or base[i]
  end
  local d = h.repo('fd-plain', { ['a.txt'] = table.concat(base, '\n') .. '\n' }, { ['a.txt'] = table.concat(changed, '\n') .. '\n' })
  h.git(d, 'remote', 'add', 'origin', GH_URL)
  local calls = h.tmpdir('fd-gh-plain') .. '/calls.ndjson'
  h.use_fake_gh(calls, { ['acme/shop:feat'] = { pr({ number = 5, title = 'Feat', head = 'feat', body = LONG }) } }, 'slow')
  vim.env.REVUEY_FAKE_GH_DELAY = '1'
  local s = open(d, { base = 'main' })
  -- the long unchanged run is folded; the user opens it while the lookup runs
  local r10 = row_of(s, 'a.txt', 'ctx', 10)
  local fold = closed(s, r10)
  h.ok(fold ~= -1, 'context folded')
  keys(s, 'zo', r10)
  h.eq(-1, closed(s, r10))
  idle(s)
  vim.env.REVUEY_FAKE_GH_DELAY = nil
  h.eq(5, s.layout.description.blocks[1].number, 'the plain review\'s PR')
  consistent(s)
  local n = desc_rows(s)
  h.eq(r10 + n, row_of(s, 'a.txt', 'ctx', 10))
  h.eq(-1, closed(s, r10 + n), 'still open')
  h.eq({ 'a.txt', 10 }, { s.layout.map[cursor(s)].path, s.layout.map[cursor(s)].new_lnum })
  view.close()
  setup()
end)

h.test('arriving late in Visual or Insert mode, or with the comment editor open: drawn after', function()
  reset()
  local calls = h.tmpdir('fd-gh-mode') .. '/calls.ndjson'
  h.use_fake_gh(calls, prs({ cart = LONG }))
  local s = open(stack_fixture('fd-mode'))
  idle(s)
  h.ok(s.layout.description)
  -- the body changes; the next lookup finds it while the user is selecting
  reset()
  h.use_fake_gh(calls, prs({ cart = 'Rewritten.' }))
  local get_mode = vim.api.nvim_get_mode
  vim.api.nvim_get_mode = function()
    return { mode = 'v', blocking = false }
  end
  local ok, err = pcall(function()
    fv.update(s, true)
    idle(s)
  end)
  vim.api.nvim_get_mode = get_mode
  assert(ok, err)
  h.ok(table.concat(lines(s), '\n'):find('Last line of the', 1, true), 'not redrawn in Visual mode')
  h.ok(s.forge.desc_wait, 'waiting for the mode to change')
  vim.api.nvim_exec_autocmds('ModeChanged', {})
  vim.wait(200, function()
    return not s.forge.desc_wait and lines(s)[2] == '  Rewritten.'
  end, 10)
  h.eq({ 'PR #12 · Cart totals', '  Rewritten.', '' }, vim.list_slice(lines(s), 1, 3))
  consistent(s)
  -- the comment editor (a float at a buffer row) is open: once it is closed
  reset()
  h.use_fake_gh(calls, prs({ cart = 'Again.' }))
  local editor = require('revuey.comment_editor')
  editor.current = { done = false }
  fv.update(s, true)
  idle(s)
  h.eq('  Rewritten.', lines(s)[2], 'not while the editor is open')
  editor.current = nil
  h.ok(vim.wait(2000, function()
    return lines(s)[2] == '  Again.'
  end, 10), 'drawn after it closed')
  consistent(s)
  view.close()
end)

h.test('<Tab> and zo/zc expand and collapse it; the choice survives a refresh; expanded = true', function()
  reset()
  local calls = h.tmpdir('fd-gh-fold') .. '/calls.ndjson'
  h.use_fake_gh(calls, prs({ cart = LONG }))
  local d = stack_fixture('fd-fold')
  local s = open(d)
  idle(s)
  local b = s.layout.description.blocks[1]
  h.eq(b.fold[1], closed(s, b.fold[1]))
  keys(s, '<Tab>', 1)
  h.eq(-1, closed(s, b.fold[1]), 'expanded from the title')
  keys(s, '<Tab>', b.fold[2])
  h.eq(b.fold[1], closed(s, b.fold[1]), 'collapsed from inside it')
  keys(s, '<Tab>', b.fold[1])
  h.eq(-1, closed(s, b.fold[1]), 'expanded from the fold line')
  -- <Tab> on code is still <C-i> or a file/hunk toggle
  local fr = file_row(s, 'src/cart.ts')
  keys(s, '<Tab>', fr)
  h.eq(fr, closed(s, fr), 'the file folds')
  keys(s, '<Tab>', fr)
  -- zc closes it like any fold, and R keeps what the user chose
  keys(s, 'zc', b.fold[1] + 1)
  h.eq(b.fold[1], closed(s, b.fold[1]))
  keys(s, '<Tab>', 1)
  refresh(s)
  h.eq(-1, closed(s, s.layout.description.blocks[1].fold[1]), 'still expanded after R')
  view.close()
  -- configured to start expanded, and a shorter preview
  reset()
  setup({ forge = { description = { expanded = true, max_lines = 2 } } })
  s = open(d)
  idle(s)
  b = s.layout.description.blocks[1]
  h.eq(1 + 2 + 1, b.fold[1], 'title + 2 preview rows')
  h.eq(-1, closed(s, b.fold[1]))
  view.close()
  setup()
end)

h.test('R fetches again: an edited description is updated in place, the cursor stays on its code line', function()
  reset()
  local calls = h.tmpdir('fd-gh-refresh') .. '/calls.ndjson'
  h.use_fake_gh(calls, prs({ cart = 'Short.' }))
  local s = open(stack_fixture('fd-refresh'))
  idle(s)
  h.eq({ 'PR #12 · Cart totals', '  Short.', '' }, vim.list_slice(lines(s), 1, 3))
  h.eq(nil, s.layout.description.blocks[1].fold)
  local r = row_of(s, 'src/index.ts', 'add', 8)
  vim.api.nvim_win_call(s.diff_win, function()
    vim.fn.winrestview({ topline = r - 3, lnum = r })
  end)
  local winline = vim.api.nvim_win_call(s.diff_win, vim.fn.winline)
  -- edited on GitHub: longer now
  h.use_fake_gh(calls, prs({ cart = 'Short.\n\nAnd a second paragraph.' }))
  refresh(s)
  consistent(s)
  h.eq({ 'PR #12 · Cart totals', '  Short.', '', '  And a second paragraph.', '' }, vim.list_slice(lines(s), 1, 5))
  local e = s.layout.map[cursor(s)]
  h.eq({ 'src/index.ts', 8 }, { e.path, e.new_lnum })
  h.eq(winline, vim.api.nvim_win_call(s.diff_win, vim.fn.winline))
  -- the body emptied (a template left): it goes, same way
  h.use_fake_gh(calls, prs({ cart = '<!-- template -->' }))
  refresh(s)
  h.eq(nil, s.layout.description)
  consistent(s)
  e = s.layout.map[cursor(s)]
  h.eq({ 'src/index.ts', 8 }, { e.path, e.new_lnum })
  -- within the TTL a re-render uses the cache (no call)
  local n = #h.read_calls(calls)
  view.rerender(s)
  idle(s)
  h.eq(n, #h.read_calls(calls))
  view.close()
end)

h.test('gh failures: nothing shown, nothing breaks, logged; a failed refetch keeps the description', function()
  local d = stack_fixture('fd-fail')
  for _, case in ipairs({ 'fail', 'garbage', 'errors', 'ratelimit', 'missing' }) do
    reset()
    local calls = h.tmpdir('fd-gh-fail-' .. case) .. '/calls.ndjson'
    h.use_fake_gh(calls, prs({ cart = LONG }), case ~= 'missing' and case or nil)
    if case == 'missing' then
      setup({ forge = { cmd = 'revuey-no-such-gh' } })
    end
    local msgs, restore = h.capture_notify()
    local s = open(d)
    idle(s)
    restore()
    h.eq({}, vim.tbl_filter(function(m)
      return (m.level or 0) >= vim.log.levels.WARN
    end, msgs), case .. ': no warnings')
    h.eq(nil, s.layout.description, case)
    h.ok(#s.layout.lines > 10, case .. ': the review is shown')
    h.ok(#log.entries > 0, case .. ': logged')
    view.close()
    setup()
  end
  reset()
  local calls = h.tmpdir('fd-gh-fail-later') .. '/calls.ndjson'
  h.use_fake_gh(calls, prs({ cart = LONG }))
  local s = open(d)
  idle(s)
  h.ok(s.layout.description)
  h.use_fake_gh(calls, prs({ cart = LONG }), 'fail')
  refresh(s)
  h.ok(s.layout.description, 'what was shown stays')
  consistent(s)
  view.close()
end)

h.test('scopes: the viewed layer\'s PR; full stack: each open layer\'s PR, bottom first, each collapsed', function()
  reset()
  local calls = h.tmpdir('fd-gh-scope') .. '/calls.ndjson'
  local list = prs({ math = 'Math helpers.', cart = LONG, ui = LONG:gsub('Last line', 'UI last line') })
  h.use_fake_gh(calls, list)
  local s = open(stack_fixture('fd-scope'))
  idle(s)
  h.eq(1, #s.layout.description.blocks)
  h.eq(12, s.layout.description.blocks[1].number)
  -- full stack: every layer's
  keys(s, 'gs')
  idle(s)
  local blocks = s.layout.description.blocks
  h.eq({ 11, 12, 13 }, vim.tbl_map(function(b)
    return b.number
  end, blocks))
  consistent(s)
  h.eq(nil, blocks[1].fold, 'a short one has nothing to fold')
  for i = 2, 3 do
    h.eq(blocks[i].fold[1], closed(s, blocks[i].fold[1]), 'collapsed ' .. i)
  end
  h.eq('PR #11 · PR 11', lines(s)[blocks[1].start_row])
  h.eq('PR #13 · PR 13', lines(s)[blocks[3].start_row])
  -- expanding one leaves the other collapsed
  keys(s, '<Tab>', blocks[2].start_row)
  h.eq(-1, closed(s, blocks[2].fold[1]))
  h.eq(blocks[3].fold[1], closed(s, blocks[3].fold[1]))
  -- back to the layer, then the top layer alone
  keys(s, 'gs')
  idle(s)
  h.eq({ 12 }, vim.tbl_map(function(b)
    return b.number
  end, s.layout.description.blocks))
  keys(s, ']s')
  idle(s)
  h.eq({ 13 }, vim.tbl_map(function(b)
    return b.number
  end, s.layout.description.blocks))
  consistent(s)
  view.close()
end)

h.test('the guide view has none; back in the diff view it is there', function()
  reset()
  local calls = h.tmpdir('fd-gh-guide') .. '/calls.ndjson'
  h.use_fake_gh(calls, prs({ cart = LONG }))
  local s = open(stack_fixture('fd-guide'))
  idle(s)
  h.ok(s.layout.description)
  local _, restore = h.capture_notify()
  view.set_view('guide')
  restore()
  h.eq('guide', s.view_mode)
  h.eq(nil, s.layout.description)
  for _, e in ipairs(s.layout.map) do
    h.ok(e.role ~= 'description', 'no description rows in the guide')
  end
  -- a lookup while in the guide view does not draw it there
  fv.update(s, true)
  idle(s)
  h.eq(nil, s.layout.description)
  view.set_view('diff')
  h.ok(s.layout.description)
  consistent(s)
  view.close()
end)

h.test('closing the review while the description loads: nothing is drawn afterwards', function()
  reset()
  local calls = h.tmpdir('fd-gh-close') .. '/calls.ndjson'
  h.use_fake_gh(calls, prs({ cart = LONG }), 'slow')
  vim.env.REVUEY_FAKE_GH_DELAY = '1'
  local s = open(stack_fixture('fd-close'))
  view.close()
  vim.wait(1500)
  vim.env.REVUEY_FAKE_GH_DELAY = nil
  h.ok(s.cleaned)
  h.eq(nil, s.layout.description)
  h.eq(nil, view.session)
end)

h.run()
