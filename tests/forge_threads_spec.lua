-- GitHub review threads (forge.fetch_threads, forge_threads.lua, forge_view, comments_view):
-- the paginated GraphQL query and its mapping, placement against the composed diff (line,
-- moved, outdated, other side, file level, files not in the review), then real git stacks with
-- a fake `gh` (tests/bin/gh) on PATH: threads drawn inline next to local comments, resolved and
-- outdated ones collapsed, the show/hide key, read-only actions, local replies, the comments
-- list, the panel's counts, scopes (layer, full stack), the cache and R, pagination, and
-- failures that never break the review.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')
local state_dir = h.tmpdir('ft-state')
local log_file = h.tmpdir('ft-log') .. '/revuey.log'
local function setup(extra)
  require('revuey').setup(vim.tbl_deep_extend('force', { state_dir = state_dir, lsp_warmup = false, log_file = log_file }, extra or {}))
end
setup()
local forge = require('revuey.forge')
local ft = require('revuey.forge_threads')
local view = require('revuey.view')
local log = require('revuey.log')
local comments = require('revuey.comments')
local cv = require('revuey.comments_view')
local diff = require('revuey.diff')
local units = require('revuey.units')

-- ---------------------------------------------------------------------------
-- Unit
-- ---------------------------------------------------------------------------

h.test('build_threads_query: threads per PR and comments per thread, cursors, fragments only when used', function()
  local q, aliases = forge.build_threads_query({
    { kind = 'threads', owner = 'acme', name = 'shop', number = 12 },
    { kind = 'threads', owner = 'acme', name = 'shop', number = 13, after = 'Y3Vy"' },
    { kind = 'comments', thread = 'PRRT_1', after = '20' },
  })
  h.ok(q:find('t1: repository(owner: "acme", name: "shop") { pullRequest(number: 12) { reviewThreads(first: 50) {', 1, true), q)
  h.ok(q:find('t2: repository(owner: "acme", name: "shop") { pullRequest(number: 13) { reviewThreads(first: 50, after: "Y3Vy\\"") {', 1, true), q)
  h.ok(q:find('c3: node(id: "PRRT_1") { ... on PullRequestReviewThread { comments(first: 100, after: "20") {', 1, true), q)
  h.eq(13, aliases.t2.number)
  h.eq('PRRT_1', aliases.c3.thread)
  for _, field in ipairs({ 'isResolved', 'isOutdated', 'path', 'line', 'startLine', 'originalLine', 'originalStartLine',
    'diffSide', 'startDiffSide', 'subjectType', 'resolvedBy', 'totalCount', 'hasNextPage', 'endCursor', 'databaseId',
    'url', 'body', 'createdAt', 'lastEditedAt', 'state', 'diffHunk', 'author { login }', 'replyTo' }) do
    h.ok(q:find(field, 1, true), 'query asks for ' .. field)
  end
  h.ok(q:find('fragment thread on PullRequestReviewThread', 1, true) and q:find('comments(first: 20)', 1, true), 'first comments in the thread fragment')
  -- only comment pages: GraphQL refuses an unused fragment
  local q2 = forge.build_threads_query({ { kind = 'comments', thread = 'PRRT_1', after = '1' } })
  h.ok(not q2:find('fragment thread', 1, true), q2)
  h.ok(q2:find('fragment comment on PullRequestReviewComment', 1, true), q2)
end)

h.test('normalize_thread: fields, sides, file threads, ghost authors, the next comments cursor', function()
  local t, cursor = forge.normalize_thread({
    id = 'T1', isResolved = true, isOutdated = false, path = 'src/a.ts', line = 9, startLine = 7,
    originalLine = 8, originalStartLine = 6, diffSide = 'LEFT', startDiffSide = 'LEFT', subjectType = 'LINE',
    resolvedBy = { login = 'carol' },
    comments = {
      totalCount = 3, pageInfo = { hasNextPage = true, endCursor = 'C2' },
      nodes = {
        { id = 'C1', databaseId = 101, url = 'u1', body = 'Hi', createdAt = '2026-01-01T00:00:00Z', state = 'SUBMITTED', author = { login = 'bob' }, diffHunk = '@@ -1 +1 @@\n-a' },
        { id = 'C2', databaseId = 102, url = 'u2', body = 'Yo', createdAt = '2026-01-02T00:00:00Z', state = 'PENDING', author = vim.NIL, replyTo = { id = 'C1' } },
      },
    },
  })
  h.eq('C2', cursor)
  h.eq({ 'T1', true, false, 'carol', 'src/a.ts', 9, 7, 8, 6, 'LEFT', 'LEFT', 'LINE', 3 },
    { t.id, t.resolved, t.outdated, t.resolved_by, t.path, t.line, t.start_line, t.original_line, t.original_start_line, t.side, t.start_side, t.subject, t.total })
  h.eq({ 'bob', 101, 'ghost', 'PENDING', 'C1' }, { t.comments[1].author, t.comments[1].database_id, t.comments[2].author, t.comments[2].state, t.comments[2].reply_to })
  local f = forge.normalize_thread({ id = 'T2', path = 'x', subjectType = 'FILE', line = vim.NIL, comments = { nodes = {} } })
  h.eq({ 'FILE', 'RIGHT', nil }, { f.subject, f.side, f.line })
  h.eq(nil, forge.normalize_thread({ id = 'T3' }), 'no path')
  h.eq(nil, forge.normalize_thread('x'))
end)

h.test('iso_ms and expected(): times with offsets; the commented lines from a diff hunk', function()
  h.eq(0, ft.iso_ms('1970-01-01T00:00:00Z'))
  h.eq(1767225600000, ft.iso_ms('2026-01-01T00:00:00Z'))
  h.eq(1767225600000, ft.iso_ms('2026-01-01T02:00:00+02:00'))
  h.eq(1767225600500 - 500, ft.iso_ms('2026-01-01T00:00:00.123Z'))
  h.eq(0, ft.iso_ms(nil))
  local hunk = '@@ -1,4 +1,5 @@ ctx\n a\n-b\n+B\n+C\n c\n\\ No newline at end of file\n'
  h.eq({ 'C', 'c' }, ft.expected(hunk, 'new', 2))
  h.eq({ 'a', 'B', 'C', 'c' }, ft.expected(hunk, 'new', 9), 'a shorter hunk: what it has')
  h.eq({ 'b', 'c' }, ft.expected(hunk, 'old', 2))
  h.eq({ 'x' }, ft.expected('@@ -1 +1 @@\r\n+x\r\n', 'new', 1), 'CRLF')
  h.eq({}, ft.expected(nil, 'new', 1))
end)

local function parse(path, a, b)
  local d = vim.text.diff(a, b, { ctxlen = 3 })
  return diff.parse(('diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n'):format(path, path, path, path) .. d)
end

local function numbered(n, edits)
  local t = {}
  for i = 1, n do
    t[i] = (edits and edits[i]) or ('line ' .. i)
  end
  return table.concat(t, '\n') .. '\n'
end

local function ctx_for(a, b, path)
  local files = parse(path or 'f.txt', a, b)
  return comments.context(files, units.derive(files), function(_, side)
    return side == 'new' and b or a
  end), files
end

---A thread on `side` lines first..last whose hunk ends with `text` (a list).
local function thread(o)
  local prefix = o.side == 'LEFT' and '-' or '+'
  local body = {}
  for _, l in ipairs(o.text or {}) do
    body[#body + 1] = prefix .. l
  end
  return {
    id = o.id or 'T', path = o.path or 'f.txt', line = o.line, start_line = o.start_line,
    original_line = o.original_line, original_start_line = o.original_start_line,
    side = o.side or 'RIGHT', subject = o.subject or 'LINE', outdated = o.outdated or false, resolved = false,
    comments = { { id = 'C', author = 'bob', body = 'b', created_at = '2026-01-01T00:00:00Z', state = 'SUBMITTED', url = 'u',
      diff_hunk = o.text and ('@@ -1 +1 @@\n' .. table.concat(body, '\n')) or nil } },
    total = 1,
  }
end

h.test('place: at GitHub\'s line when its text matches; moved (unique copy); outside; other side; file; missing', function()
  local a = numbered(40)
  local b = numbered(40, { [20] = 'twenty changed', [21] = 'twenty-one changed' })
  local ctx = ctx_for(a, b)
  local p = ft.place(thread({ line = 21, start_line = 20, text = { 'twenty changed', 'twenty-one changed' } }), ctx)
  h.eq({ 'line', 'new', 20, 21 }, { p.how, p.side, p.start_line, p.end_line })
  -- GitHub's line is elsewhere locally (the review has commits or edits GitHub hasn't): moved
  p = ft.place(thread({ line = 25, text = { 'twenty changed' } }), ctx)
  h.eq({ 'moved', 20, 20 }, { p.how, p.start_line, p.end_line })
  -- the text is nowhere shown: outside, at GitHub's numbers
  p = ft.place(thread({ line = 20, text = { 'something else' } }), ctx)
  h.eq({ 'outside', 20 }, { p.how, p.start_line })
  -- shown lines but no hunk text to check: trusted
  p = ft.place(thread({ line = 19 }), ctx)
  h.eq('line', p.how)
  -- a line outside the hunks
  p = ft.place(thread({ line = 2, text = { 'line 2' } }), ctx)
  h.eq('outside', p.how)
  -- LEFT: the old side
  p = ft.place(thread({ line = 21, side = 'LEFT', text = { 'line 21' } }), ctx)
  h.eq({ 'line', 'old', 21 }, { p.how, p.side, p.start_line })
  -- outdated on GitHub: found by its original line's text, else outside
  p = ft.place(thread({ outdated = true, original_line = 30, text = { 'twenty-one changed' } }), ctx)
  h.eq({ 'moved', 21 }, { p.how, p.start_line })
  p = ft.place(thread({ outdated = true, original_line = 21, text = { 'gone' } }), ctx)
  h.eq('outside', p.how)
  h.eq('file', ft.place(thread({ subject = 'FILE' }), ctx).how)
  h.eq('missing', ft.place(thread({ path = 'other.txt', line = 1 }), ctx).how)
end)

h.test('place: repeated or trivial lines are never guessed', function()
  local a = numbered(40)
  local b = numbered(40, { [10] = '}', [12] = 'dup line', [16] = 'dup line', [18] = 'x' })
  local ctx = ctx_for(a, b)
  -- two copies within reach: not moved
  h.eq('outside', ft.place(thread({ line = 30, text = { 'dup line' } }), ctx).how)
  -- at GitHub's own line the text decides, copies or not
  h.eq({ 'line', 16 }, (function()
    local p = ft.place(thread({ line = 16, text = { 'dup line' } }), ctx)
    return { p.how, p.start_line }
  end)())
  -- too little text to search for
  h.eq('outside', ft.place(thread({ line = 11, text = { '}' } }), ctx).how)
  h.eq('outside', ft.place(thread({ line = 17, text = { 'x' } }), ctx).how)
end)

h.test('item: a comment-like record with GitHub ids, authors, replies, pending and hidden counts', function()
  local t = thread({ line = 3, start_line = 2, text = { 'a', 'b' } })
  t.resolved, t.resolved_by, t.total = true, 'carol', 5
  t.comments[2] = { id = 'C2', database_id = 9, author = 'alice', body = 'reply', created_at = '2026-01-02T00:00:00Z', state = 'PENDING', url = 'u2' }
  local it = ft.item(t, { number = 12, url = 'https://github.com/acme/shop/pull/12', repo = 'github.com/acme/shop' })
  h.eq('gh:T', it.id)
  h.eq({ kind = 'forge', name = 'bob' }, it.author)
  h.eq('resolved', it.status)
  h.eq({ path = 'f.txt', side = 'new', start_line = 2, end_line = 3 }, it.anchor)
  h.eq({ thread_id = 'T', pr = 12, pr_url = 'https://github.com/acme/shop/pull/12', repo = 'github.com/acme/shop', url = 'u',
    resolved = true, resolved_by = 'carol', outdated = false, pending = true, hidden = 3, comment_id = 'C2', database_id = 9 }, it.forge)
  h.eq(1, #it.thread)
  h.eq({ 'alice', true }, { it.thread[1].author.name, it.thread[1].pending })
  h.eq({ open = 0, resolved = 1, outdated = 0 }, ft.summary({ t }))
end)

-- ---------------------------------------------------------------------------
-- Integration: a stack with PRs and threads, fake gh
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

local PAGES = { forge.THREAD_PAGE, forge.COMMENT_PAGE, forge.COMMENT_MORE_PAGE, forge.THREAD_ROUNDS }
local function reset()
  forge.THREAD_PAGE, forge.COMMENT_PAGE, forge.COMMENT_MORE_PAGE, forge.THREAD_ROUNDS = PAGES[1], PAGES[2], PAGES[3], PAGES[4]
  forge.cache = {}
  forge.threads_cache = {}
  log.entries = {}
  forge.now = function()
    return vim.uv.hrtime() / 1e6
  end
end

local function pr(o)
  return {
    number = o.number, title = 'PR ' .. o.number, url = 'https://github.com/acme/shop/pull/' .. o.number,
    state = o.state or 'OPEN', isDraft = false, author = { login = 'alice' }, latestReviews = { nodes = {} },
    reviewRequests = { nodes = {} }, mergeable = 'MERGEABLE', baseRefName = o.base or 'main', headRefName = o.head,
    headRepositoryOwner = { login = 'acme' }, headRefOid = o.oid or vim.NIL, updatedAt = '2026-01-01T00:00:00Z',
    commits = { nodes = {} },
  }
end

local PRS = {
  ['acme/shop:stack/cart'] = { pr({ number = 12, head = 'stack/cart', base = 'stack/math' }) },
  ['acme/shop:stack/ui'] = { pr({ number = 13, head = 'stack/ui', base = 'stack/cart' }) },
}

local CART = {
  'import { multiply, sum } from "./math";', '', 'export interface LineItem {', '  name: string;', '  price: number;',
  '  quantity: number;', '}', '', 'export class Cart {', '  private items: LineItem[] = [];', '', '  addItem(item: LineItem): this {',
  '    this.items.push(item);', '    return this;', '  }', '', '  total(): number {',
  '    return sum(this.items.map((i) => multiply(i.price, i.quantity)));', '  }', '}',
}

---The diff hunk GitHub stores for a thread on new cart.ts (a new file) ending at line `n`.
local function cart_hunk(n)
  local out = { '@@ -0,0 +1,20 @@' }
  for i = 1, n do
    out[#out + 1] = '+' .. CART[i]
  end
  return table.concat(out, '\n')
end

local INDEX_HUNK = table.concat({
  '@@ -2,10 +2,11 @@ import { add, circleArea } from "./math";',
  ' import { formatCurrency } from "./format";',
  ' import { capitalize } from "./utils/strings";',
  ' import { oldTotal } from "./legacy";',
  '+import { Cart } from "./cart";',
  ' ',
  ' export function main(): void {',
  '-  const total = oldTotal([1, 2, 3]);',
}, '\n')

local seq = 0
local function c(author, body, o)
  seq = seq + 1
  o = o or {}
  return {
    id = 'PRRC_' .. seq, databaseId = 1000 + seq, url = 'https://github.com/acme/shop/pull/' .. (o.pr or 12) .. '#discussion_r' .. (1000 + seq),
    body = body, createdAt = o.at or ('2026-01-0' .. math.min(9, seq % 9 + 1) .. 'T00:00:00Z'), lastEditedAt = vim.NIL,
    state = o.state or 'SUBMITTED', diffHunk = o.hunk or vim.NIL, author = author and { login = author } or vim.NIL,
    replyTo = vim.NIL,
  }
end

local function t(o)
  return {
    id = o.id, isResolved = o.resolved or false, isOutdated = o.outdated or false, path = o.path or 'src/cart.ts',
    line = o.line or vim.NIL, startLine = o.start_line or vim.NIL, originalLine = o.original_line or o.line or vim.NIL,
    originalStartLine = o.start_line or vim.NIL, diffSide = o.side or 'RIGHT', startDiffSide = o.start_line and (o.side or 'RIGHT') or vim.NIL,
    subjectType = o.subject or 'LINE', resolvedBy = o.resolved_by and { login = o.resolved_by } or vim.NIL,
    comments = o.comments,
  }
end

local THREADS = {
  ['acme/shop#12'] = {
    t({ id = 'T_round', line = 18, comments = {
      c('carol', 'Should the total be rounded?', { hunk = cart_hunk(18), at = '2026-01-01T00:00:00Z' }),
      c('alice', 'Good point, will do.', { at = '2026-01-02T00:00:00Z' }),
    } }),
    t({ id = 'T_add', line = 13, start_line = 12, resolved = true, resolved_by = 'alice', comments = {
      c('dan', 'Return a copy instead?', { hunk = cart_hunk(13), at = '2026-01-01T01:00:00Z' }),
      c('alice', 'Chaining is the point.', { at = '2026-01-01T02:00:00Z' }),
      c('dan', 'Fair.', { at = '2026-01-01T03:00:00Z' }),
    } }),
    t({ id = 'T_old', outdated = true, original_line = 5, comments = {
      c('carol', 'Use a Money type here.', { hunk = '@@ -0,0 +1,5 @@\n+x\n+  oldPrice: number;', at = '2026-01-01T04:00:00Z' }),
    } }),
    t({ id = 'T_left', path = 'src/index.ts', line = 7, side = 'LEFT', comments = {
      c('carol', 'Why does oldTotal go?', { hunk = INDEX_HUNK, at = '2026-01-01T05:00:00Z' }),
    } }),
    t({ id = 'T_file', subject = 'FILE', comments = { c('erin', 'Needs tests.', { at = '2026-01-01T06:00:00Z' }) } }),
  },
}

---All virtual-line text attached to `row` of the diff buffer.
local function vlines(s, row)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.diff_buf, cv.ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    for _, l in ipairs(m[4].virt_lines or {}) do
      local x = {}
      for _, ch in ipairs(l) do
        x[#x + 1] = ch[1]
      end
      out[#out + 1] = table.concat(x)
    end
  end
  return table.concat(out, '\n')
end

local function all_vlines(s)
  local out = {}
  for row = 1, vim.api.nvim_buf_line_count(s.diff_buf) do
    local v = vlines(s, row)
    if v ~= '' then
      out[#out + 1] = row .. ': ' .. v
    end
  end
  return table.concat(out, '\n')
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

local function panel_text(s)
  return table.concat(vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false), '\n')
end

local function thread_calls(calls)
  local n = 0
  for _, x in ipairs(h.read_calls(calls)) do
    if (x.argv[5] or ''):find('reviewThreads', 1, true) or (x.argv[5] or ''):find(': node(id:', 1, true) then
      n = n + 1
    end
  end
  return n
end

h.test('threads of the viewed layer\'s PR: inline, collapsed when resolved or outdated, other side, file level', function()
  reset()
  local calls = h.tmpdir('ft-gh-basic') .. '/calls.ndjson'
  h.use_fake_gh(calls, PRS, nil, THREADS)
  local d = stack_fixture('ft-basic')
  local s = open(d)
  idle(s)
  local all = h.read_calls(calls)
  h.eq(2, #all, 'the PR lookup, then one threads call')
  h.ok(all[2].argv[5]:find('pullRequest(number: 12)', 1, true), all[2].argv[5])
  -- open thread on its line, with its reply
  local r18 = row_of(s, 'src/cart.ts', 'add', 18)
  local v = vlines(s, r18)
  h.ok(v:find('╭─ carol · ', 1, true) and v:find(' · GitHub #12', 1, true), v)
  h.ok(v:find('│ Should the total be', 1, true), v)
  h.ok(v:find('│ ↳ alice · ', 1, true) and v:find('Good point, will do.', 1, true), v)
  h.eq('RevueyForgeSign', s.cm.signs[r18])
  -- a resolved two-line thread: under its last line, collapsed to its first line
  local r13 = row_of(s, 'src/cart.ts', 'add', 13)
  v = vlines(s, r13)
  h.ok(v:find('resolved by alice', 1, true), v)
  h.ok(v:find('│ Return a copy instead?', 1, true), v)
  h.ok(v:find('more lines', 1, true) and not v:find('Fair.', 1, true), v)
  h.eq('RevueyCommentResolved', s.cm.signs[row_of(s, 'src/cart.ts', 'add', 12)])
  -- `cz` expands it
  keys(s, 'cz', r13)
  v = vlines(s, r13)
  h.ok(v:find('Fair.', 1, true), v)
  -- the LEFT thread on the deleted line
  v = vlines(s, row_of(s, 'src/index.ts', 'del', 7))
  h.ok(v:find('Why does oldTotal go?', 1, true), v)
  -- the file-level thread under the file header
  v = vlines(s, file_row(s, 'src/cart.ts'))
  h.ok(v:find('erin', 1, true) and v:find('· file', 1, true) and v:find('Needs tests.', 1, true), v)
  -- the outdated one (its text is gone) in a group at the end of the file
  local text = all_vlines(s)
  h.ok(text:find('GitHub threads on lines not shown here', 1, true), text)
  h.ok(text:find('Use a Money type here.', 1, true) and text:find('· outdated', 1, true), text)
  -- nothing went into the comments file
  h.eq({}, comments.list(s.cm.store, { include_resolved = true, include_drafts = true }))
  h.ok(not vim.uv.fs_stat(s.cm.path) or not table.concat(vim.fn.readfile(s.cm.path)):find('gh:', 1, true), 'never stored')
  -- panel: counts and the key
  local p = panel_text(s):gsub('\n   ', ' ')
  h.ok(p:find('threads: 4 open, 1 resolved, 1 outdated', 1, true), p)
  h.ok(p:find('gH GitHub threads', 1, true), p)
  view.close()
end)

h.test('gH cycles all / open only / none; ]m reaches threads; the list shows them; gx opens one', function()
  reset()
  local calls = h.tmpdir('ft-gh-keys') .. '/calls.ndjson'
  h.use_fake_gh(calls, PRS, nil, THREADS)
  local d = stack_fixture('ft-keys')
  local s = open(d)
  idle(s)
  local msgs, restore = h.capture_notify()
  local r13 = row_of(s, 'src/cart.ts', 'add', 13)
  keys(s, 'gH')
  h.ok(not vlines(s, r13):find('Return a copy', 1, true), 'resolved hidden')
  h.ok(vlines(s, row_of(s, 'src/cart.ts', 'add', 18)):find('rounded', 1, true), 'open ones stay')
  keys(s, 'gH')
  h.ok(not all_vlines(s):find('GitHub', 1, true), 'none')
  h.eq(nil, s.cm.signs[row_of(s, 'src/cart.ts', 'add', 18)])
  keys(s, 'gH')
  h.ok(vlines(s, r13):find('Return a copy', 1, true), 'all again')
  restore()
  h.eq('revuey: GitHub threads: open only (resolved hidden)', msgs[1].msg)
  h.eq('revuey: GitHub threads: hidden', msgs[2].msg)
  -- ]m from the top of the file stops at the threads
  local first = file_row(s, 'src/cart.ts')
  keys(s, ']m', first)
  h.eq(row_of(s, 'src/cart.ts', 'add', 12), vim.api.nvim_win_get_cursor(s.diff_win)[1])
  -- the comments list
  local lines = vim.tbl_map(function(l)
    return l.text
  end, cv.list_lines(s))
  local text = table.concat(lines, '\n')
  h.ok(text:find('GitHub threads', 1, true), text)
  h.ok(text:find('  18 (new)  Should the total be rounded?  [GitHub #12, by carol, 1 reply]', 1, true), text)
  h.ok(text:find('  12-13 (new)  Return a copy instead?  [GitHub #12, by dan, ✓ resolved, 2 replies]', 1, true), text)
  h.ok(text:find('  5 (new)  Use a Money type here.  [GitHub #12, by carol, outdated, not on a shown line]', 1, true), text)
  -- gx on a thread row opens it; elsewhere it is the usual gx
  local opened = {}
  local orig = vim.ui.open
  vim.ui.open = function(url)
    opened[#opened + 1] = url
  end
  keys(s, 'gx', row_of(s, 'src/cart.ts', 'add', 18))
  vim.ui.open = orig
  h.eq(1, #opened)
  h.ok(opened[1]:find('/pull/12#discussion_r', 1, true), opened[1])
  -- elsewhere: the global gx (Neovim's default, or the user's)
  local global = 0
  vim.keymap.set('n', 'gx', function()
    global = global + 1
  end)
  keys(s, 'gx', row_of(s, 'src/cart.ts', 'add', 3))
  h.eq(1, global, 'the global gx ran')
  h.eq(1, #opened, 'no thread opened')
  view.close()
end)

h.test('read-only: edit, resolve, delete and send refuse; cr adds a local reply linked to the thread', function()
  reset()
  local calls = h.tmpdir('ft-gh-reply') .. '/calls.ndjson'
  h.use_fake_gh(calls, PRS, nil, THREADS)
  local d = stack_fixture('ft-reply')
  local s = open(d)
  idle(s)
  local r18 = row_of(s, 'src/cart.ts', 'add', 18)
  local msgs, restore = h.capture_notify()
  for _, k in ipairs({ 'ce', 'cx', 'cd', 'cs' }) do
    keys(s, k, r18)
  end
  restore()
  h.eq(4, #msgs)
  for _, m in ipairs(msgs) do
    h.ok(m.msg:find('GitHub threads are read-only here', 1, true) and m.msg:find('gx opens it', 1, true), m.msg)
  end
  h.eq({}, comments.list(s.cm.store, { include_resolved = true, include_drafts = true }))
  -- cr: the editor; saving makes a local comment on the thread's line
  keys(s, 'cr', r18)
  local ed = require('revuey.comment_editor').current
  h.ok(ed and not ed.done, 'editor open')
  vim.api.nvim_buf_set_lines(ed.buf, 0, -1, false, { 'Rounding belongs in formatCurrency.' })
  vim.cmd('stopinsert')
  require('revuey.comment_editor').save()
  vim.wait(200)
  local list = comments.list(s.cm.store, { include_resolved = true, include_drafts = true })
  h.eq(1, #list)
  local cmt = list[1]
  h.eq({ 'src/cart.ts', 'new', 18, 18 }, { cmt.anchor.path, cmt.anchor.side, cmt.anchor.start_line, cmt.anchor.end_line })
  h.eq('T_round', cmt.forge_reply.thread_id)
  h.eq(12, cmt.forge_reply.pr)
  h.ok(cmt.forge_reply.comment_id ~= nil and cmt.forge_reply.database_id ~= nil, vim.inspect(cmt.forge_reply))
  local v = vlines(s, r18)
  h.ok(v:find('local reply to GitHub #12 thread', 1, true) and v:find('Rounding belongs', 1, true), v)
  -- stored in the comments file (it is the user's comment), the thread is not
  local saved = table.concat(vim.fn.readfile(s.cm.path), '\n')
  h.ok(saved:find('forge_reply', 1, true) and not saved:find('"gh:', 1, true), saved)
  h.eq(thread_calls(calls), 1, 'nothing posted: still the one threads query')
  -- the Markdown export says what it answers
  local md = require('revuey.comments_export').render('markdown', { { review = cv.review_info(s), comments = list } })
  h.ok(md:find('a reply to GitHub #12 thread https://github.com/acme/shop/pull/12#discussion_r', 1, true), md)
  -- a thread not on a shown line: refused
  msgs, restore = h.capture_notify()
  local orow = s.cm.forge_rows['gh:T_old'].last
  h.eq('gh_outside', s.cm.forge_rows['gh:T_old'].group)
  keys(s, 'cr', orow)
  restore()
  h.ok(msgs[1] and msgs[1].msg:find('not on a line shown here', 1, true), vim.inspect(msgs))
  view.close()
end)

h.test('full stack: every layer\'s open PR, moved lines found by text; layer scopes use the cache', function()
  reset()
  local calls = h.tmpdir('ft-gh-full') .. '/calls.ndjson'
  local threads = vim.deepcopy(THREADS)
  threads['acme/shop#13'] = {
    t({ id = 'T_ui', line = 23, comments = { c('frank', 'Join with a comma and a space?', {
      pr = 13, at = '2026-01-01T07:00:00Z',
      hunk = '@@ -17,4 +18,8 @@ export class Cart {\n   total(): number {\n     return sum(this.items.map((i) => multiply(i.price, i.quantity)));\n   }\n+\n+  names(): string {\n+    return this.items.map((i) => capitalize(i.name)).join(", ");',
    }) } }),
  }
  h.use_fake_gh(calls, PRS, nil, threads)
  local d = stack_fixture('ft-full')
  local s = open(d)
  idle(s)
  view.set_scope({ kind = 'full' })
  idle(s)
  local q = h.read_calls(calls)[3].argv[5]
  h.ok(q:find('pullRequest(number: 13)', 1, true) and not q:find('pullRequest(number: 12)', 1, true), 'only #13 is new: ' .. q)
  -- #12's line 18 is line 19 at the top of the stack (stack/ui added an import above)
  local v = vlines(s, row_of(s, 'src/cart.ts', 'add', 19))
  h.ok(v:find('Should the total be', 1, true) and v:find('GitHub line 18', 1, true), v)
  v = vlines(s, row_of(s, 'src/cart.ts', 'add', 23))
  h.ok(v:find('frank', 1, true) and v:find('GitHub #13', 1, true), v)
  -- layer scope stack/ui: #13's only
  view.set_scope({ kind = 'layer', index = 3 })
  idle(s)
  local all = all_vlines(s)
  h.ok(all:find('frank', 1, true) and not all:find('carol', 1, true), all)
  h.eq(3, #h.read_calls(calls), 'scope switches use the cache')
  view.close()
end)

h.test('cache: refreshes reuse it within the TTL; R fetches again; lazily after the TTL', function()
  reset()
  local now = 1000000
  forge.now = function()
    return now
  end
  local calls = h.tmpdir('ft-gh-ttl') .. '/calls.ndjson'
  h.use_fake_gh(calls, PRS, nil, THREADS)
  setup({ forge = { ttl = 30 } })
  local d = stack_fixture('ft-ttl')
  local s = open(d)
  idle(s)
  h.eq(1, thread_calls(calls))
  view.refresh({ force = true })
  idle(s)
  h.eq(1, thread_calls(calls), 'cached')
  local _, restore = h.capture_notify()
  keys(s, 'R')
  idle(s)
  restore()
  h.eq(2, thread_calls(calls), 'R')
  now = now + 31 * 1000
  require('revuey.panel').render(s)
  idle(s)
  h.eq(3, thread_calls(calls), 'after the TTL')
  view.close()
  setup()
end)

h.test('pagination: every page of threads and of long threads\' comments, in order; a round cap', function()
  reset()
  forge.THREAD_PAGE, forge.COMMENT_PAGE, forge.COMMENT_MORE_PAGE = 2, 1, 2
  local list = {}
  for i = 1, 5 do
    local cs = { c('u' .. i, 'thread ' .. i, { hunk = cart_hunk(18) }) }
    for j = 1, (i == 2 and 6 or (i == 5 and 3 or 0)) do
      cs[#cs + 1] = c('r' .. j, ('reply %d.%d'):format(i, j))
    end
    list[i] = t({ id = 'TP' .. i, line = 18, comments = cs })
  end
  local calls = h.tmpdir('ft-gh-pages') .. '/calls.ndjson'
  h.use_fake_gh(calls, PRS, nil, { ['acme/shop#12'] = list })
  local d = stack_fixture('ft-pages')
  local s = open(d)
  idle(s)
  local got = forge.threads_for(forge.get(s.forge.targets['stack/cart']))
  h.eq({ 'TP1', 'TP2', 'TP3', 'TP4', 'TP5' }, vim.tbl_map(function(x)
    return x.id
  end, got))
  h.eq(7, #got[2].comments)
  h.eq({ 'thread 2', 'reply 2.1', 'reply 2.2', 'reply 2.3', 'reply 2.4', 'reply 2.5', 'reply 2.6' }, vim.tbl_map(function(x)
    return x.body
  end, got[2].comments))
  h.eq(4, #got[5].comments)
  -- rounds: threads 1-2 (TP2 has more), 3-4 + TP2 2-3, 5 + TP2 4-5 (TP5 has more),
  -- TP2 6-7 + TP5 2-3, TP5 4: 5 calls
  h.eq(5, thread_calls(calls))
  local v = vlines(s, row_of(s, 'src/cart.ts', 'add', 18))
  h.ok(v:find('reply 2.6', 1, true) or v:find('more lines', 1, true), v)
  view.close()
  -- capped: what was read is kept, the rest counted as "more on GitHub", logged
  reset()
  forge.THREAD_PAGE, forge.COMMENT_PAGE, forge.COMMENT_MORE_PAGE, forge.THREAD_ROUNDS = 2, 1, 2, 1
  calls = h.tmpdir('ft-gh-cap') .. '/calls.ndjson'
  h.use_fake_gh(calls, PRS, nil, { ['acme/shop#12'] = list })
  s = open(d)
  idle(s)
  got = forge.threads_for(forge.get(s.forge.targets['stack/cart']))
  h.eq(2, #got)
  h.eq(1, thread_calls(calls))
  local found = false
  for _, e in ipairs(log.entries) do
    found = found or tostring(e.msg):find('stopped after 1 pages', 1, true) ~= nil
  end
  h.ok(found, vim.inspect(log.entries))
  s.cm.expanded['gh:TP2'] = true
  cv.render(s)
  h.ok(all_vlines(s):find('│ … 6 more on GitHub', 1, true), all_vlines(s))
  view.close()
  reset()
end)

h.test('failures never break the review: no gh, gh failing, GraphQL errors, a PR that does not resolve', function()
  local d = stack_fixture('ft-fail')
  for _, case in ipairs({ 'fail', 'errors', 'null', 'missing' }) do
    reset()
    local calls = h.tmpdir('ft-gh-fail-' .. case) .. '/calls.ndjson'
    local threads = case == 'null' and { _null = { 'acme/shop#12' } } or THREADS
    h.use_fake_gh(calls, PRS, nil, threads)
    if case == 'fail' or case == 'errors' then
      vim.env.REVUEY_FAKE_GH_THREADS_SCENARIO = case
    end
    if case == 'missing' then
      -- a gh that cannot run: the PR lookup and the threads both find nothing
      setup({ forge = { cmd = 'revuey-no-such-gh' } })
    end
    local msgs, restore = h.capture_notify()
    local s = open(d)
    idle(s)
    restore()
    h.eq({}, vim.tbl_filter(function(m)
      return (m.level or 0) >= vim.log.levels.WARN
    end, msgs), case .. ': no warnings')
    h.ok(not all_vlines(s):find('GitHub', 1, true), case .. ': no threads drawn')
    h.ok(#s.layout.lines > 10, case .. ': the review is shown')
    if case ~= 'missing' then
      h.ok(panel_text(s):find('PR #12', 1, true), case .. ': the PR is still shown')
      h.ok(#log.entries > 0, case .. ': logged')
    end
    view.close()
    vim.env.REVUEY_FAKE_GH_THREADS_SCENARIO = nil
    setup()
  end
end)

h.test('a failed refetch keeps the threads shown', function()
  reset()
  local calls = h.tmpdir('ft-gh-stale') .. '/calls.ndjson'
  h.use_fake_gh(calls, PRS, nil, THREADS)
  local d = stack_fixture('ft-stale')
  local s = open(d)
  idle(s)
  vim.env.REVUEY_FAKE_GH_THREADS_SCENARIO = 'fail'
  local _, restore = h.capture_notify()
  keys(s, 'R')
  idle(s)
  restore()
  vim.env.REVUEY_FAKE_GH_THREADS_SCENARIO = nil
  h.eq(2, thread_calls(calls))
  h.ok(vlines(s, row_of(s, 'src/cart.ts', 'add', 18)):find('rounded', 1, true), 'still shown')
  view.close()
end)

h.test('a working-tree edit: threads follow moved lines; an edited line goes to "not shown here"', function()
  reset()
  local calls = h.tmpdir('ft-gh-edit') .. '/calls.ndjson'
  h.use_fake_gh(calls, PRS, nil, THREADS)
  local d = stack_fixture('ft-edit')
  local s = open(d)
  idle(s)
  local lines = vim.deepcopy(CART)
  table.insert(lines, 1, '// a header comment')
  table.insert(lines, 2, '// and another')
  h.write(d, 'src/cart.ts', table.concat(lines, '\n') .. '\n')
  view.refresh({ force = true })
  idle(s)
  local v = vlines(s, row_of(s, 'src/cart.ts', 'add', 20))
  h.ok(v:find('rounded', 1, true) and v:find('GitHub line 18', 1, true), v)
  lines[20] = '    return Math.round(sum(this.items.map((i) => multiply(i.price, i.quantity))));'
  h.write(d, 'src/cart.ts', table.concat(lines, '\n') .. '\n')
  view.refresh({ force = true })
  idle(s)
  local all = all_vlines(s)
  h.ok(not vlines(s, row_of(s, 'src/cart.ts', 'add', 20)):find('rounded', 1, true), 'not on the edited line')
  h.ok(all:find('GitHub threads on lines not shown here', 1, true) and all:find('rounded', 1, true), all)
  h.eq(1, thread_calls(calls), 'edits never refetch')
  view.close()
end)

local function alive(pid)
  return pid and vim.uv.kill(pid, 0) == 0
end

h.test('closing the review while threads load: gh is stopped and its result never cached', function()
  reset()
  local calls = h.tmpdir('ft-gh-close') .. '/calls.ndjson'
  h.use_fake_gh(calls, PRS, 'slow', THREADS)
  vim.env.REVUEY_FAKE_GH_DELAY = '1'
  local d = stack_fixture('ft-close')
  local s = open(d)
  -- the PR lookup has answered; the threads call is running
  assert(vim.wait(15000, function()
    return s.forge and s.forge.ready and s.forge.busy and s.forge.job ~= nil
  end, 10), 'threads call did not start')
  local job = s.forge.job
  view.close()
  assert(vim.wait(5000, function()
    return job:is_closing()
  end, 20), 'gh not stopped')
  vim.wait(1500)
  h.eq({}, forge.threads_cache)
  local pidf = calls .. '.pid'
  local pid = vim.uv.fs_stat(pidf) and tonumber(vim.fn.readfile(pidf)[1])
  h.ok(not alive(pid), 'no fake gh left')
  vim.env.REVUEY_FAKE_GH_DELAY = nil
end)

h.teardown(function()
  if view.session then
    view.close()
  end
end)

h.run()
