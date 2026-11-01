-- Integration: the comments view (comments_list.lua). A stack with PRs and review threads from
-- the fake `gh`, plus your comments, an agent's comment and an AI finding: every thread in one
-- list with its status and authors, grouped by file in diff order; `<CR>` shows the comment in
-- the diff (in the guide when it came from there); the comment keys on the thread under the
-- cursor (a local reply to a GitHub thread, resolve, add to review) with the view re-rendered
-- in place; `q` back to the diff or guide as they were; layer and full-stack scope; live
-- redraws when comments change elsewhere.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')
local state_dir = h.tmpdir('cl-state')
h.use_fake_claude(h.tmpdir('cl-claude') .. '/calls.ndjson')
require('revuey').setup({ state_dir = state_dir, lsp_warmup = false, log_file = h.tmpdir('cl-log') .. '/revuey.log' })
local forge = require('revuey.forge')
local view = require('revuey.view')
local comments = require('revuey.comments')
local cv = require('revuey.comments_view')
local cl = require('revuey.comments_list')
local editor = require('revuey.comment_editor')
local gv = require('revuey.guide_view')

local CART = {
  'import { multiply, sum } from "./math";', '', 'export interface LineItem {', '  name: string;', '  price: number;',
  '  quantity: number;', '}', '', 'export class Cart {', '  private items: LineItem[] = [];', '', '  addItem(item: LineItem): this {',
  '    this.items.push(item);', '    return this;', '  }', '', '  total(): number {',
  '    return sum(this.items.map((i) => multiply(i.price, i.quantity)));', '  }', '}',
}

local function cart_hunk(n)
  local out = { '@@ -0,0 +1,20 @@' }
  for i = 1, n do
    out[#out + 1] = '+' .. CART[i]
  end
  return table.concat(out, '\n')
end

local seq = 0
local function c(author, body, o)
  seq = seq + 1
  o = o or {}
  return {
    id = 'PRRC_' .. seq, databaseId = 2000 + seq, url = 'https://github.com/acme/shop/pull/' .. (o.pr or 12) .. '#discussion_r' .. (2000 + seq),
    body = body, createdAt = o.at or '2026-01-01T00:00:00Z', lastEditedAt = vim.NIL,
    state = 'SUBMITTED', diffHunk = o.hunk or vim.NIL, author = { login = author }, replyTo = vim.NIL,
  }
end

local function t(o)
  return {
    id = o.id, isResolved = o.resolved or false, isOutdated = o.outdated or false, path = o.path or 'src/cart.ts',
    line = o.line or vim.NIL, startLine = o.start_line or vim.NIL, originalLine = o.original_line or o.line or vim.NIL,
    originalStartLine = o.start_line or vim.NIL, diffSide = o.side or 'RIGHT', startDiffSide = o.start_line and 'RIGHT' or vim.NIL,
    subjectType = o.subject or 'LINE', resolvedBy = o.resolved and { login = 'alice' } or vim.NIL, comments = o.comments,
  }
end

local THREADS = {
  ['acme/shop#12'] = {
    t({ id = 'T_round', line = 18, comments = {
      c('carol', 'Should the total be rounded?', { hunk = cart_hunk(18), at = '2026-01-01T00:00:00Z' }),
      c('alice', 'Good point, will do.', { at = '2026-01-02T00:00:00Z' }),
    } }),
    t({ id = 'T_add', line = 13, start_line = 12, resolved = true, comments = {
      c('dan', 'Return a copy instead?', { hunk = cart_hunk(13), at = '2026-01-01T01:00:00Z' }),
      c('alice', 'Chaining is the point.', { at = '2026-01-01T02:00:00Z' }),
    } }),
    t({ id = 'T_old', outdated = true, original_line = 5, comments = {
      c('carol', 'Use a Money type here.', { hunk = '@@ -0,0 +1,5 @@\n+x\n+  oldPrice: number;', at = '2026-01-01T04:00:00Z' }),
    } }),
    t({ id = 'T_file', subject = 'FILE', comments = { c('erin', 'Needs tests.', { at = '2026-01-01T06:00:00Z' }) } }),
  },
  ['acme/shop#13'] = {
    t({ id = 'T_ui', path = 'src/components/Total.tsx', line = 5, comments = {
      c('frank', 'A test id on the total?', { pr = 13, at = '2026-01-01T07:00:00Z' }),
    } }),
  },
}

local function pr(o)
  return {
    number = o.number, title = 'PR ' .. o.number, url = 'https://github.com/acme/shop/pull/' .. o.number,
    state = 'OPEN', isDraft = false, author = { login = 'alice' }, latestReviews = { nodes = {} },
    reviewRequests = { nodes = {} }, mergeable = 'MERGEABLE', baseRefName = o.base, headRefName = o.head,
    headRepositoryOwner = { login = 'acme' }, headRefOid = vim.NIL, updatedAt = '2026-01-01T00:00:00Z',
    commits = { nodes = {} },
  }
end

local PRS = {
  ['acme/shop:stack/cart'] = { pr({ number = 12, head = 'stack/cart', base = 'stack/math' }) },
  ['acme/shop:stack/ui'] = { pr({ number = 13, head = 'stack/ui', base = 'stack/cart' }) },
}

local function idle(s)
  assert(h.settle(function()
    return not s.refreshing and not s.pending and not s.pending_scope
      and s.forge and s.forge.ready and not s.forge.busy and not s.forge.scheduled
  end, 15000), 'refresh / PR lookup did not finish')
end

local n_fixture = 0
local function open()
  if view.session then
    view.close()
  end
  forge.cache, forge.threads_cache = {}, {}
  n_fixture = n_fixture + 1
  local d = h.tmpdir('cl-repo-' .. n_fixture)
  vim.fn.delete(d, 'rf')
  assert(h.make_fixture('--stack', d).code == 0)
  h.git(d, 'remote', 'add', 'origin', 'git@github.com:acme/shop.git')
  h.use_fake_gh(h.tmpdir('cl-gh-' .. n_fixture) .. '/calls.ndjson', PRS, nil, THREADS)
  local s
  require('revuey').open({ cwd = d, on_ready = function(x)
    s = x
  end })
  assert(vim.wait(10000, function()
    return s ~= nil
  end, 10), 'review did not open')
  idle(s)
  assert(s.cm.forge_items and s.cm.forge_items['gh:T_round'], 'threads did not load')
  return s
end

local function row_of(s, path, kind, lnum)
  for row, e in ipairs(s.layout.map) do
    if e.path == path and e.kind == kind and (kind == 'del' and e.old_lnum or e.new_lnum) == lnum then
      return row
    end
  end
  error(('no %s row %s:%d'):format(kind, path, lnum))
end

---A comment on new-side lines of a file of the review, put into the store.
local function put(s, path, l1, body, extra)
  local anchor = l1 and comments.anchor_for_lines(s.review.files, require('revuey.review').units(s.review),
    { path = path, side = 'new', start_line = l1, end_line = l1 }, cv.context(s).get_line) or comments.file_anchor(path)
  local cmt = comments.new(anchor, body, { author = extra and extra.author })
  for k, v in pairs(extra or {}) do
    if k ~= 'author' then
      cmt[k] = v
    end
  end
  comments.put(cv.sync_store(s), cmt)
  comments.save(cv.sync_store(s))
  cv.refresh(s)
  return cmt
end

local function lines(s)
  return vim.api.nvim_buf_get_lines(s.clist.buf, 0, -1, false)
end

local function text(s)
  return table.concat(lines(s), '\n')
end

---Row of the view whose text contains `needle`.
local function vrow(s, needle)
  for i, l in ipairs(lines(s)) do
    if l:find(needle, 1, true) then
      return i
    end
  end
  error('not in the view: ' .. needle .. '\n' .. text(s))
end

local function feed(k)
  vim.api.nvim_feedkeys(vim.keycode(k), 'mtx', false)
end

---Keys in the view, the cursor first on the row holding `needle` (when given).
local function vkeys(s, k, needle)
  vim.api.nvim_set_current_win(s.clist.win)
  if needle then
    vim.api.nvim_win_set_cursor(s.clist.win, { vrow(s, needle), 0 })
  end
  feed(k)
end

local function cursor_text(s)
  return lines(s)[vim.api.nvim_win_get_cursor(s.clist.win)[1]]
end

---Headless specs keep the 80-column screen: narrow the panel so the view has room.
local function roomy(s)
  vim.api.nvim_win_set_width(s.panel_win, 4)
end

local function seed(s)
  roomy(s)
  local mine = put(s, 'src/cart.ts', 10, 'Readonly array?')
  local agent = put(s, 'src/cart.ts', 3, 'Why an interface here?', { author = { kind = 'agent', name = 'claude' } })
  comments.reply(cv.sync_store(s), mine.id, 'Yes, it is never reassigned.', { kind = 'agent', name = 'claude' })
  local ai = put(s, 'src/index.ts', 5, 'Unused import of `Cart`?', {
    author = { kind = 'ai', name = 'claude' },
    ai = { review = 'r1', severity = 'major', title = 'Unused import' },
  })
  comments.save(cv.sync_store(s))
  cv.refresh(s)
  return mine, agent, ai
end

h.test('cl: every thread with its status and authors, grouped by file in diff order', function()
  local s = open()
  local mine, agent, ai = seed(s)
  local diff_row = row_of(s, 'src/cart.ts', 'add', 14)
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_win_set_cursor(s.diff_win, { diff_row, 0 })
  feed('cl')
  h.ok(cl.active(s), 'the view is open')
  h.eq(s.clist.win, vim.api.nvim_get_current_win())
  -- over the whole diff window, below its winbar
  h.eq(vim.api.nvim_win_get_width(s.diff_win), vim.api.nvim_win_get_width(s.clist.win))
  local all = text(s)
  -- the header: counts, the GitHub threads filter
  h.ok(lines(s)[1]:find('6 open · 1 resolved · 1 of yours not in the review', 1, true), lines(s)[1])
  h.ok(all:find('GitHub threads: all (gH cycles)', 1, true), all)
  -- statuses, authors, replies with their authors
  h.ok(all:find('  file  open', 1, true) and all:find('erin', 1, true) and all:find('Needs tests.', 1, true), all)
  h.ok(cursor_text(s) and true)
  local function block(needle)
    local r = vrow(s, needle)
    local id = s.clist.rows[r]
    local b = s.clist.blocks[id]
    return table.concat(vim.list_slice(lines(s), b.first, b.last), '\n'), id
  end
  local b, id = block('Should the total be rounded?')
  h.eq('gh:T_round', id)
  h.ok(b:find('  18  open  │ return sum(this.items.map', 1, true), b)
  h.ok(b:find('╭─ carol · ', 1, true) and b:find('GitHub #12', 1, true), b)
  h.ok(b:find('│ ↳ alice · ', 1, true) and b:find('Good point, will do.', 1, true), b)
  -- a resolved thread: one line, its author, first line and replies
  b = block('Return a copy instead?')
  h.eq(1, #vim.split(b, '\n'), b)
  h.ok(b:find('  12-13  resolved  dan: Return a copy instead? · 1 reply', 1, true), b)
  -- outdated on GitHub, not on a shown line
  b = block('Use a Money type here.')
  h.ok(b:find('  5  outdated · not on a shown line  carol:', 1, true), b)
  -- yours, with the agent's reply
  b, id = block('Readonly array?')
  h.eq(mine.id, id)
  h.ok(b:find('  10  open  │ private items: LineItem[] = [];', 1, true), b)
  h.ok(b:find('╭─ You · ', 1, true) and b:find('↳ claude (agent)', 1, true), b)
  -- the agent's comment and the AI finding: drafts until accepted
  b, id = block('Why an interface here?')
  h.eq(agent.id, id)
  h.ok(b:find('  3  draft', 1, true) and b:find('claude (agent)', 1, true) and b:find('ca accept · cn dismiss', 1, true), b)
  b, id = block('Unused import')
  h.eq(ai.id, id)
  h.ok(b:find('  5  draft', 1, true) and b:find('major', 1, true) and b:find('claude (ai)', 1, true), b)
  -- the order: file by file in diff order, file-level first, then by line
  local order = {}
  for _, x in ipairs(s.clist.order) do
    order[#order + 1] = x
  end
  h.eq({ 'gh:T_file', agent.id, 'gh:T_old', mine.id, 'gh:T_add', 'gh:T_round', ai.id }, order)
  h.ok(vrow(s, ' src/cart.ts') < vrow(s, ' src/index.ts'), all)
  -- ]c / [c between threads
  vim.api.nvim_win_set_cursor(s.clist.win, { s.clist.blocks['gh:T_file'].first, 0 })
  vkeys(s, ']c')
  h.eq(s.clist.blocks[agent.id].first, vim.api.nvim_win_get_cursor(s.clist.win)[1])
  vkeys(s, '2]c')
  h.eq(s.clist.blocks[mine.id].first, vim.api.nvim_win_get_cursor(s.clist.win)[1])
  vkeys(s, '[c')
  h.eq(s.clist.blocks['gh:T_old'].first, vim.api.nvim_win_get_cursor(s.clist.win)[1])
  -- the panel shows it, with the view's keys
  local panel = table.concat(vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false), '\n')
  h.ok(panel:find(' Comments', 1, true) and panel:find('<CR> show  ]c [c thread  q back', 1, true), panel)
  h.ok(panel:find('cr reply  ce edit  cx resolve', 1, true), panel)
  -- the winbar says so, with the keys of the thread under the cursor
  vim.api.nvim_win_set_cursor(s.clist.win, { s.clist.blocks['gh:T_round'].first, 0 })
  vim.g.statusline_winid = s.diff_win
  local bar = view.winbar()
  h.ok(bar:find('Comments · layer stack/cart', 1, true), bar)
  h.ok(bar:find('cr', 1, true) and bar:find('gx', 1, true), bar)
  -- q: back to the diff, cursor where it was
  vkeys(s, 'q')
  h.eq(false, cl.active(s))
  h.eq(s.diff_win, vim.api.nvim_get_current_win())
  h.eq(diff_row, vim.api.nvim_win_get_cursor(s.diff_win)[1])
  panel = table.concat(vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false), '\n')
  h.ok(not panel:find('q back', 1, true), panel)
  -- cl again: back on the thread it was on; cl closes it too
  feed('cl')
  h.eq('gh:T_round', s.clist.rows[vim.api.nvim_win_get_cursor(s.clist.win)[1]])
  vkeys(s, 'cl')
  h.eq(false, cl.active(s))
  h.eq(diff_row, vim.api.nvim_win_get_cursor(s.diff_win)[1])
  -- :RevueyComments opens it
  vim.cmd('RevueyComments')
  h.ok(cl.active(s))
  vkeys(s, 'q')
end)

h.test('<CR> shows the comment in the diff; from the guide, in the guide', function()
  local s = open()
  local mine = seed(s)
  feed('cl')
  vkeys(s, '<CR>', 'Good point, will do.')
  h.eq(false, cl.active(s))
  h.eq(s.diff_win, vim.api.nvim_get_current_win())
  h.eq(row_of(s, 'src/cart.ts', 'add', 18), vim.api.nvim_win_get_cursor(s.diff_win)[1])
  -- any line of a thread: a LEFT-less file thread lands on the file header
  feed('cl')
  vkeys(s, '<CR>', 'Needs tests.')
  local e = s.layout.map[vim.api.nvim_win_get_cursor(s.diff_win)[1]]
  h.eq({ 'src/cart.ts', 'file' }, { e.path, e.meta })
  -- from the guide: the guide's row
  view.guide_command(true)
  assert(vim.wait(20000, function()
    return next(gv.jobs) == nil and s.guide and s.guide.resolved ~= nil
  end, 20), 'guide generation did not finish')
  idle(s)
  h.eq('guide', s.view_mode)
  local guide_row = vim.api.nvim_win_get_cursor(s.diff_win)[1]
  feed('cl')
  h.ok(cl.active(s))
  -- q: the guide as it was
  vkeys(s, 'q')
  h.eq({ 'guide', guide_row }, { s.view_mode, vim.api.nvim_win_get_cursor(s.diff_win)[1] })
  feed('cl')
  vkeys(s, '<CR>', 'Readonly array?')
  h.eq('guide', s.view_mode)
  h.eq(s.cm.jump[mine.id], vim.api.nvim_win_get_cursor(s.diff_win)[1])
  local m = s.layout.map[s.cm.jump[mine.id]]
  h.eq({ 'src/cart.ts', 10 }, { m.path, m.new_lnum })
  view.set_view('diff')
end)

h.test('cr on a GitHub thread: a local reply; cx resolves, ci toggles, the cursor stays on the thread', function()
  local s = open()
  local mine = seed(s)
  feed('cl')
  -- cr on any line of a GitHub thread: the editor under it, in the view
  vkeys(s, 'cr', 'Good point, will do.')
  local ed = editor.current
  h.ok(ed and not ed.done, 'editor open')
  h.eq(s.clist.win, vim.api.nvim_win_get_config(ed.win).win)
  vim.api.nvim_buf_set_lines(ed.buf, 0, -1, false, { 'Rounding belongs in formatCurrency.' })
  vim.cmd('stopinsert')
  editor.save()
  h.flush()
  local reply
  for _, x in ipairs(comments.list(s.cm.store, { include_resolved = true, include_drafts = true })) do
    if x.forge_reply then
      reply = x
    end
  end
  h.ok(reply, 'a local reply')
  h.eq({ 'T_round', 12, 'src/cart.ts', 18 }, { reply.forge_reply.thread_id, reply.forge_reply.pr, reply.anchor.path, reply.anchor.start_line })
  h.eq(s.clist.win, vim.api.nvim_get_current_win())
  local all = text(s)
  h.ok(all:find('local reply to GitHub #12 thread', 1, true) and all:find('Rounding belongs', 1, true), all)
  -- the view re-rendered with the cursor still on the GitHub thread
  h.eq('gh:T_round', s.clist.rows[vim.api.nvim_win_get_cursor(s.clist.win)[1]])
  -- ci on your comment: in the review, and out again
  local _, restore = h.capture_notify()
  vkeys(s, 'ci', 'Readonly array?')
  local row = vim.api.nvim_win_get_cursor(s.clist.win)[1]
  h.eq(true, comments.get(s.cm.store, mine.id).in_review)
  h.ok(lines(s)[s.clist.blocks[mine.id].first]:find('  10  in review', 1, true), text(s))
  h.eq(mine.id, s.clist.rows[row])
  h.ok(cursor_text(s):find('Readonly array?', 1, true), cursor_text(s))
  vkeys(s, 'ci')
  h.eq(false, comments.get(s.cm.store, mine.id).in_review)
  -- cx resolves: the thread collapses to one line and the cursor stays on it
  vkeys(s, 'cx')
  h.eq('resolved', comments.get(s.cm.store, mine.id).status)
  local b = s.clist.blocks[mine.id]
  h.eq(b.first, b.last)
  h.ok(lines(s)[b.first]:find('  10  resolved  You: Readonly array? · 1 reply', 1, true), lines(s)[b.first])
  h.eq(b.first, vim.api.nvim_win_get_cursor(s.clist.win)[1])
  -- cz expands it in place; again collapses it
  vkeys(s, 'cz')
  b = s.clist.blocks[mine.id]
  h.ok(b.last > b.first, 'expanded')
  vkeys(s, 'cz')
  b = s.clist.blocks[mine.id]
  h.eq(b.first, b.last)
  -- cx again reopens
  vkeys(s, 'cx')
  h.eq('saved', comments.get(s.cm.store, mine.id).status)
  -- a GitHub thread refuses cx with the diff's message
  local msgs
  msgs, restore = h.capture_notify()
  vkeys(s, 'cx', 'Should the total be rounded?')
  restore()
  h.ok(msgs[1] and msgs[1].msg:find('GitHub threads are read-only here', 1, true), vim.inspect(msgs))
  -- ca accepts the agent's comment
  vkeys(s, 'ca', 'Why an interface here?')
  local id = s.clist.rows[vim.api.nvim_win_get_cursor(s.clist.win)[1]]
  local head = lines(s)[s.clist.blocks[id].first]
  h.ok(head:find('  3  open', 1, true), head)
  h.ok(text(s):find('accepted from agent', 1, true), text(s))
  -- gx opens a GitHub thread
  local opened = {}
  local orig = vim.ui.open
  vim.ui.open = function(url)
    opened[#opened + 1] = url
  end
  vkeys(s, 'gx', 'Needs tests.')
  vim.ui.open = orig
  h.eq(1, #opened)
  h.ok(opened[1]:find('/pull/12#discussion_r', 1, true), opened[1])
  restore()
  vkeys(s, 'q')
end)

h.test('live: a comment written elsewhere and gH redraw the view in place', function()
  local s = open()
  seed(s)
  feed('cl')
  vim.api.nvim_win_set_cursor(s.clist.win, { vrow(s, 'Readonly array?'), 0 })
  local store = cv.sync_store(s)
  -- another instance (or bin/revuey comment) writes the comments file
  local other = comments.load(store.path)
  local anchor = comments.anchor_for_lines(s.review.files, require('revuey.review').units(s.review),
    { path = 'src/cart.ts', side = 'new', start_line = 4, end_line = 4 }, cv.context(s).get_line)
  comments.put(other, comments.new(anchor, 'From the agent, later.', { author = { kind = 'agent', name = 'claude' } }))
  comments.save(other)
  h.ok(vim.wait(3000, function()
    return text(s):find('From the agent, later.', 1, true) ~= nil
  end, 20), 'the view shows it')
  h.ok(cursor_text(s):find('Readonly array?', 1, true), cursor_text(s))
  -- gH: open threads only (the resolved one leaves the list), then none
  local _, restore = h.capture_notify()
  vkeys(s, 'gH')
  h.ok(not text(s):find('Return a copy', 1, true) and text(s):find('GitHub threads: open only', 1, true), text(s))
  vkeys(s, 'gH')
  h.ok(not text(s):find('carol', 1, true), text(s))
  vkeys(s, 'gH')
  restore()
  h.ok(text(s):find('Return a copy', 1, true), text(s))
  vkeys(s, 'q')
end)

h.test('scope: the viewed layer\'s threads; full stack: every layer, grouped by layer', function()
  local s = open()
  seed(s)
  feed('cl')
  h.ok(not text(s):find('A test id on the total?', 1, true), 'not #13 in the stack/cart layer')
  -- gs in the view: full stack; the view follows
  vkeys(s, 'gs')
  idle(s)
  assert(h.settle(function()
    return s.cm.forge_items and s.cm.forge_items['gh:T_ui'] ~= nil and cl.active(s)
  end), 'full-stack threads')
  h.eq('full', s.review.scope.kind)
  local all = text(s)
  h.ok(all:find(' stack/cart  GitHub #12', 1, true) and all:find(' stack/ui  GitHub #13', 1, true), all)
  h.ok(vrow(s, ' stack/cart  GitHub #12') < vrow(s, 'Should the total be rounded?'), all)
  h.ok(vrow(s, ' stack/ui  GitHub #13') < vrow(s, 'A test id on the total?'), all)
  h.ok(vrow(s, 'Should the total be rounded?') < vrow(s, ' stack/ui  GitHub #13'), all)
  -- your comments in the full scope go with the layer that changed their lines
  assert(h.settle(function()
    return s.review.layer_labels ~= nil
  end), 'branch labels')
  put(s, 'src/cart.ts', 23, 'Join with a comma?')
  put(s, 'src/math.ts', 11, 'Negative results?')
  all = text(s)
  h.ok(vrow(s, ' stack/math') < vrow(s, 'Negative results?') and vrow(s, 'Negative results?') < vrow(s, ' stack/cart  GitHub #12'), all)
  h.ok(vrow(s, ' stack/ui  GitHub #13') < vrow(s, 'Join with a comma?'), all)
  vim.g.statusline_winid = s.diff_win
  h.ok(view.winbar():find('Comments · full stack', 1, true), view.winbar())
  -- back to the layer
  vkeys(s, 'gs')
  idle(s)
  assert(h.settle(function()
    return s.review.scope.kind == 'layer' and not text(s):find('A test id on the total?', 1, true)
  end), 'layer scope again')
  vkeys(s, 'q')
end)

h.run()
