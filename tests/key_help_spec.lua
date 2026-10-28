-- Finding the keys: the winbar's hint of the keys that work on the cursor row (per item kind and
-- state, rebinds and disabled keys, the truncation), the `g?` float, the panel's help lines from
-- the keymap config, and the README's Keymaps tables generated from keys.lua.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')
local state_dir = h.tmpdir('kh-state')
local function setup(keymaps)
  require('revuey').setup({ state_dir = state_dir, lsp_warmup = false, keymaps = keymaps })
end
setup()
local config = require('revuey.config')
local keys = require('revuey.keys')
local kh = require('revuey.key_help')
local comments = require('revuey.comments')
local cv = require('revuey.comments_view')
local view = require('revuey.view')

---The hint as text: "ce edit · cr reply".
local function text(items)
  return table.concat(vim.tbl_map(function(it)
    return it.key .. ' ' .. it.label
  end, items), ' · ')
end

-- ---------------------------------------------------------------------------
-- Unit: keys.lua
-- ---------------------------------------------------------------------------

h.test('keys.lua lists every keymap option once, and only those', function()
  local listed = {}
  for _, g in ipairs(keys.GROUPS) do
    for _, e in ipairs(g) do
      for _, n in ipairs(e.names or {}) do
        h.eq(nil, listed[n], n .. ' listed twice')
        listed[n] = true
        h.ok(config.defaults.keymaps[n] ~= nil, n .. ' is not a keymap option')
      end
    end
  end
  for n in pairs(config.defaults.keymaps) do
    h.ok(listed[n], n .. ' is missing from keys.lua (and so from g? and the README)')
  end
  h.eq('g?', config.defaults.keymaps.help)
end)

h.test('the README Keymaps tables are the ones keys.lua makes (scripts/readme-keys.lua)', function()
  local readme = table.concat(vim.fn.readfile(h.root .. '/README.md'), '\n')
  local body = readme:match('<!%-%- keys:begin %-%->\n(.-)\n<!%-%- keys:end %-%->')
  h.ok(body, 'README.md has no keys:begin / keys:end markers')
  h.eq(keys.markdown(), body, 'README is out of date: nvim --headless --clean -l scripts/readme-keys.lua')
end)

h.test('keys.line: panel help from the config; a rebound key shows, a disabled one leaves its part out', function()
  h.eq(' ]c [c hunk  ]f [f file  <Tab> fold', keys.line(' {next_hunk} {prev_hunk} hunk  {next_file} {prev_file} file  {toggle_fold} fold'))
  h.eq(' gd def  K hover  go open  R refresh', keys.line(' {definition} def  {hover} hover  {open_file#2} open  {refresh} refresh'))
  setup({ next_file = 'J', toggle_fold = false, open_file = '<CR>', help = '<F1>' })
  h.eq(' ]c [c hunk  J [f file', keys.line(' {next_hunk} {prev_hunk} hunk  {next_file} {prev_file} file  {toggle_fold} fold'))
  h.eq(' gd def  K hover  <CR> open  R refresh', keys.line(' {definition} def  {hover} hover  {open_file#2} open  {refresh} refresh'))
  h.eq(' <F1> all keys', keys.line(' {help} all keys'))
  setup({ help = false })
  h.eq(nil, keys.line(' {help} all keys'))
  setup()
end)

-- ---------------------------------------------------------------------------
-- Unit: the hint per item kind and state (a session table with a comments store)
-- ---------------------------------------------------------------------------

local function fake_session(list, o)
  o = o or {}
  local store = comments.load(h.tmpdir('kh-store') .. '/x.comments.json')
  local s = { view_mode = o.view_mode or 'diff', cm = { store = store, cover = { [3] = {} }, expanded = {}, cut = {},
    forge_items = {}, forge_rows = {}, forge_place = {} } }
  for _, c in ipairs(list) do
    if c.forge then
      s.cm.forge_items[c.id] = c
      s.cm.forge_rows[c.id] = { first = 3, last = 3, group = c.group }
      s.cm.forge_place[c.id] = { how = 'line' }
    else
      comments.put(store, c)
    end
    table.insert(s.cm.cover[3], c.id)
  end
  return s
end

local function mk(o)
  local c = comments.new(comments.file_anchor('a.txt'), 'body')
  for k, v in pairs(o or {}) do
    c[k] = v
  end
  return c
end

local function hint(list, o)
  local s = fake_session(list, o)
  if o and o.prep then
    o.prep(s, list)
  end
  return text(kh.items(s, 3))
end

h.test('hint: your own comment, by state (added, posted, pending, resolved, draft, cut, expanded)', function()
  h.eq('ce edit · cr reply · ci add to review · cx resolve · cd delete', hint({ mk() }))
  h.eq('ce edit · cr reply · ci remove from review · cx resolve · cd delete', hint({ mk({ in_review = true }) }))
  h.eq('ce edit · cr reply · cx resolve · cd delete', hint({ mk({ forge_post = { state = 'posted', pr = 12 } }) }), 'posted: no ci')
  h.eq('ce edit · cr reply · ci remove from review · cx resolve · cd delete',
    hint({ mk({ in_review = true, forge_post = { state = 'pending', pr = 12 } }) }), 'pending: it can be taken out')
  h.eq('ce edit · cr reply · cx reopen · cd delete', hint({ mk({ status = 'resolved' }) }))
  h.eq('ce edit · cr reply · cd delete', hint({ mk({ status = 'draft' }) }), 'a draft: no ci, no cx')
  h.eq('ce edit · cr reply · ci add to review · cx resolve · cz expand · cd delete', hint({ mk() }, {
    prep = function(s, l)
      s.cm.cut[l[1].id] = true
    end,
  }))
  h.eq('ce edit · cr reply · ci add to review · cx resolve · cz collapse · cd delete', hint({ mk() }, {
    prep = function(s, l)
      s.cm.expanded[l[1].id] = true
    end,
  }))
  -- an accepted finding is yours
  h.eq('ce edit · cr reply · ci add to review · cx resolve · cd delete',
    hint({ mk({ status = 'accepted', ai = { severity = 'major', accepted_at = 1, author = { kind = 'ai' } } }) }))
  -- a local reply to a GitHub thread
  h.eq('ce edit · cr reply · ci add to review · cx resolve · cd delete', hint({ mk({ forge_reply = { pr = 12, thread_id = 'T1' } }) }))
end)

h.test('hint: AI findings and agent drafts (untriaged, dismissed, resolved)', function()
  local finding = { author = { kind = 'ai', name = 'claude' }, ai = { severity = 'major', title = 't' } }
  h.eq('ca accept · cn dismiss · cs ask agent', hint({ mk(finding) }))
  h.eq('ca accept · cn dismiss · cs ask agent', hint({ mk({ author = { kind = 'agent', name = 'claude' } }) }), 'an agent draft')
  h.eq('ca accept · cn restore · cs ask agent',
    hint({ mk({ author = { kind = 'agent', name = 'claude' }, agent = { dismissed_at = 1 }, status = 'dismissed' }) }))
  h.eq('cx reopen · cs ask agent', hint({ mk(vim.tbl_extend('force', finding, { status = 'resolved' })) }))
end)

h.test('hint: a GitHub thread; one not on a shown line; several items on a row', function()
  local function thread(o)
    return vim.tbl_extend('force', { id = 'gh:T1', author = { kind = 'forge', name = 'carol' }, body = 'x',
      forge = { pr = 12, url = 'https://github.com/acme/shop/pull/12', thread_id = 'T1', hidden = 0 } }, o or {})
  end
  h.eq('cr reply · gx open', hint({ thread() }))
  h.eq('gx open', hint({ thread({ group = 'gh_outside' }) }), 'outside the shown lines: no local reply')
  h.eq('cr reply · gx open · cz expand', hint({ thread() }, {
    prep = function(s)
      s.cm.cut['gh:T1'] = true
    end,
  }))
  -- your comment and a finding on one row: every key that works on either, the first item's label
  h.eq('ce edit · cr reply · ci add to review · cx resolve · cd delete · ca accept · cn dismiss · cs ask agent',
    hint({ mk(), mk({ author = { kind = 'ai', name = 'claude' }, ai = { severity = 'nit' } }) }))
  h.eq('', hint({}))
end)

h.test('hint: rebound keys show, disabled ones are left out', function()
  setup({ comment_edit = 'E', comment_delete = false, comment_include = { 'I', 'ci' }, comment_dismiss = false })
  h.eq('E edit · cr reply · I add to review · cx resolve', hint({ mk() }))
  h.eq('ca accept · cs ask agent', hint({ mk({ author = { kind = 'agent', name = 'claude' } }) }))
  setup()
end)

h.test('hint: a guide line note (next / previous where there is one, show or hide)', function()
  local function note(row, o)
    local s = { view_mode = o.view_mode or 'guide', guide_note_rows = o.rows, guide_note_cover = o.cover,
      guide_notes_collapsed = o.collapsed }
    return text(kh.items(s, row))
  end
  local cover = { [2] = true, [5] = true, [6] = true, [9] = true }
  h.eq(']n/[n next/prev · gN hide notes', note(5, { rows = { 2, 5, 9 }, cover = cover }))
  h.eq(']n/[n next/prev · gN hide notes', note(6, { rows = { 2, 5, 9 }, cover = cover }), 'the second line of a note')
  h.eq(']n next · gN hide notes', note(2, { rows = { 2, 5, 9 }, cover = cover }))
  h.eq('[n prev · gN show notes', note(9, { rows = { 2, 5, 9 }, cover = cover, collapsed = true }))
  h.eq('gN hide notes', note(2, { rows = { 2 }, cover = { [2] = true } }))
  h.eq('', note(3, { rows = { 2, 5, 9 }, cover = cover }), 'no note on the row')
  h.eq('', note(5, { rows = { 2, 5, 9 }, cover = cover, view_mode = 'diff' }))
  setup({ next_note = false, toggle_notes = 'N' })
  h.eq('[n prev · N hide notes', note(5, { rows = { 2, 5, 9 }, cover = cover }))
  setup()
end)

h.test('compose: the hint keeps its first keys and the name at the left is cut first', function()
  local items = { { key = 'ce', label = 'edit' }, { key = 'cr', label = 'reply' }, { key = 'ci', label = 'add to review' },
    { key = 'cx', label = 'resolve' }, { key = 'cd', label = 'delete' } }
  local function render(left, width)
    local win = vim.api.nvim_get_current_win()
    local str = kh.compose(left, '', items, width)
    return vim.api.nvim_eval_statusline(str, { winid = win, maxwidth = width }).str
  end
  local wide = render(' M %<src/some/long/path/cart.ts +3 −1', 120)
  h.ok(wide:find('src/some/long/path/cart.ts +3 −1', 1, true), wide)
  h.ok(vim.endswith(wide, 'ce edit · cr reply · ci add to review · cx resolve · cd delete '), wide)
  -- 79 cells (the diff window next to the panel at 120 columns): a short name stays whole, the
  -- last key goes; a long name is cut at its start (the status letter and the counts stay)
  local mid = render(' A %<src/cart.ts +27 −0', 79)
  h.ok(vim.startswith(mid, ' A src/cart.ts +27 −0 '), mid)
  h.ok(vim.endswith(mid, ' ce edit · cr reply · ci add to review · cx resolve '), mid)
  mid = render(' M %<src/some/long/path/cart.ts +3 −1', 79)
  h.eq(79, vim.api.nvim_strwidth(mid), mid)
  h.ok(vim.startswith(mid, ' M <'), mid)
  h.ok(mid:find('cart.ts +3 −1 ', 1, true), mid)
  h.ok(vim.endswith(mid, ' cx resolve '), mid)
  -- 50 cells: the last keys go, the first stay whole
  local narrow = render(' M %<src/some/long/path/cart.ts +3 −1', 50)
  h.ok(vim.endswith(narrow, ' ce edit · cr reply '), narrow)
  h.ok(vim.startswith(narrow, ' M <'), narrow)
  h.ok(vim.api.nvim_strwidth(narrow) <= 50, narrow)
end)

-- ---------------------------------------------------------------------------
-- Unit: the g? sheet
-- ---------------------------------------------------------------------------

h.test('g? sheet: grouped, from the config (rebinds, disabled keys)', function()
  local function sheet()
    return table.concat(vim.tbl_map(function(l)
      return l.text
    end, kh.sheet_lines()), '\n')
  end
  local t = sheet()
  local last = 0
  for _, g in ipairs({ 'Comments', 'Review and posting', 'Navigation', 'Layers and switching', 'GitHub', 'Guide', 'Files and folds', 'Other' }) do
    local at = t:find('\n ' .. g .. '\n', 1, true) or (t:sub(1, #g + 2) == ' ' .. g .. '\n' and 0)
    h.ok(at and at >= last, g .. ' heading, in order\n' .. t)
    last = at
  end
  h.ok(t:find('\n   ce +edit the comment on this line\n'), t)
  h.ok(t:find('\n   ]c %[c +next / previous hunk'), t)
  h.ok(t:find('\n   <CR> go +open the file at this line'), t)
  h.ok(t:find('\n   g%? +this list of keys'), t)
  setup({ comment_edit = 'E', comment_delete = false, next_hunk = 'J' })
  t = sheet()
  h.ok(t:find('\n   E +edit the comment on this line\n'), t)
  h.ok(not t:find('delete the comment', 1, true), 'a disabled key is left out')
  h.ok(t:find('\n   J %[c +next / previous hunk'), t)
  setup()
end)

-- ---------------------------------------------------------------------------
-- Integration: a review with comments, a finding, an agent draft and a GitHub thread
-- ---------------------------------------------------------------------------

local function stack_fixture(name)
  local d = h.tmpdir(name)
  vim.fn.delete(d, 'rf')
  local res = vim.system({ h.root .. '/scripts/make-fixture.sh', '--stack', d }, { text = true }):wait()
  assert(res.code == 0, res.stderr)
  h.git(d, 'remote', 'add', 'origin', 'git@github.com:acme/shop.git')
  return d
end

local function open(dir)
  if view.session then
    view.close()
  end
  local session
  require('revuey').open({ cwd = dir, on_ready = function(s)
    session = s
  end })
  assert(vim.wait(10000, function()
    return session ~= nil
  end, 10), 'review did not open')
  assert(vim.wait(15000, function()
    local s = session
    return not s.refreshing and not s.pending and s.forge and s.forge.ready and not s.forge.busy and not s.forge.scheduled
  end, 10), 'PR lookup did not finish')
  return session
end

local function row_of(s, path, kind, lnum)
  for row, e in ipairs(s.layout.map) do
    if e.path == path and e.kind == kind and e.new_lnum == lnum then
      return row
    end
  end
  error(('no %s row %s:%d'):format(kind, path, lnum))
end

local function put(s, lnum, body, extra)
  local rows = { s.layout.map[row_of(s, 'src/cart.ts', 'add', lnum)] }
  local a = comments.anchor_from_rows(s.review.files, require('revuey.review').units(s.review), rows, cv.context(s).get_line)
  local c = comments.new(a, body)
  for k, v in pairs(extra or {}) do
    c[k] = v
  end
  comments.put(s.cm.store, c)
  comments.save(s.cm.store)
  cv.refresh(s)
  return c
end

---The winbar as drawn (text) after moving the cursor to `row` (CursorMoved runs).
local function winbar_at(s, row)
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = s.diff_buf })
  vim.g.statusline_winid = s.diff_win
  return vim.api.nvim_eval_statusline(view.winbar(), { winid = s.diff_win, use_winbar = true }).str
end

local d = stack_fixture('kh-review')
local cart, ui = vim.trim(h.git(d, 'rev-parse', 'stack/cart')), vim.trim(h.git(d, 'rev-parse', 'stack/ui'))
local function pr(n, head, base, oid)
  return { number = n, title = 'PR ' .. n, url = 'https://github.com/acme/shop/pull/' .. n, state = 'OPEN', isDraft = false,
    author = { login = 'alice' }, latestReviews = { nodes = {} }, reviewRequests = { nodes = {} }, mergeable = 'MERGEABLE',
    baseRefName = base, headRefName = head, headRepositoryOwner = { login = 'acme' }, headRefOid = oid,
    updatedAt = '2026-01-01T00:00:00Z', commits = { nodes = {} } }
end
h.use_fake_gh(h.tmpdir('kh-gh') .. '/calls.ndjson', {
  ['acme/shop:stack/cart'] = { pr(12, 'stack/cart', 'stack/math', cart) },
  ['acme/shop:stack/ui'] = { pr(13, 'stack/ui', 'stack/cart', ui) },
}, nil, {
  ['acme/shop#12'] = { {
    id = 'T1', isResolved = false, isOutdated = false, path = 'src/cart.ts', line = 20, startLine = vim.NIL, originalLine = 20,
    originalStartLine = vim.NIL, diffSide = 'RIGHT', startDiffSide = vim.NIL, subjectType = 'LINE', resolvedBy = vim.NIL,
    comments = { { id = 'C1', databaseId = 1, url = 'https://github.com/acme/shop/pull/12#discussion_r1', body = 'Round to cents?',
      createdAt = '2026-01-01T00:00:00Z', lastEditedAt = vim.NIL, state = 'SUBMITTED', diffHunk = vim.NIL,
      author = { login = 'carol' }, replyTo = vim.NIL } },
  } },
})

h.test('moving the cursor over a comment, a finding, an agent draft and a GitHub thread updates the winbar', function()
  local s = open(d)
  assert(vim.wait(10000, function()
    return s.cm and s.cm.forge_items and next(s.cm.forge_items) ~= nil
  end, 10), 'the GitHub thread did not load')
  -- headless, the screen is 80 columns: a narrow panel leaves the diff window 78 cells
  vim.api.nvim_win_set_width(s.panel_win, 1)
  local own = put(s, 4, 'Is this tested?')
  put(s, 8, 'Two imports drift.', { author = { kind = 'ai', name = 'claude' }, ai = { severity = 'major', title = 'Imports' } })
  put(s, 12, 'Readonly array?', { author = { kind = 'agent', name = 'claude' } })
  local plain = winbar_at(s, row_of(s, 'src/cart.ts', 'add', 2))
  h.ok(plain:find('%d+/%d+ $'), 'no comment: the file count\n' .. plain)
  local wb = winbar_at(s, row_of(s, 'src/cart.ts', 'add', 4))
  -- 78 cells: the file stays whole on the left, the hint's last key (cd delete) is left out
  h.ok(vim.endswith(wb, ' ce edit · cr reply · ci add to review · cx resolve '), wb)
  h.ok(vim.startswith(wb, ' A src/cart.ts +20 −0 '), wb)
  h.ok(not wb:find('%d+/%d+ $'), 'the hint takes the right side\n' .. wb)
  h.eq('ce edit · cr reply · ci add to review · cx resolve · cd delete', text(s.key_hint.items), 'CursorMoved kept it')
  -- ci: the label follows the state without moving the cursor
  local msgs, restore = h.capture_notify()
  vim.api.nvim_feedkeys('ci', 'mtx', false)
  restore()
  h.eq(true, comments.get(s.cm.store, own.id).in_review, vim.inspect(msgs))
  h.eq('ce edit · cr reply · ci remove from review · cx resolve · cd delete', text(s.key_hint.items))
  vim.g.statusline_winid = s.diff_win
  h.ok(vim.api.nvim_eval_statusline(view.winbar(), { winid = s.diff_win, use_winbar = true }).str:find('ci remove from review', 1, true))
  h.ok(vim.endswith(winbar_at(s, row_of(s, 'src/cart.ts', 'add', 8)), 'ca accept · cn dismiss · cs ask agent '), 'a finding')
  h.ok(vim.endswith(winbar_at(s, row_of(s, 'src/cart.ts', 'add', 12)), 'ca accept · cn dismiss · cs ask agent '), 'an agent draft')
  wb = winbar_at(s, row_of(s, 'src/cart.ts', 'add', 20))
  h.ok(vim.endswith(wb, 'cr reply · gx open '), 'a GitHub thread\n' .. wb)
  -- moving off clears it
  h.ok(winbar_at(s, row_of(s, 'src/cart.ts', 'add', 2)):find('%d+/%d+ $'))
  h.eq({}, s.key_hint.items)
  -- only while the diff window is the current one (the keys act there)
  vim.api.nvim_win_set_cursor(s.diff_win, { row_of(s, 'src/cart.ts', 'add', 4), 0 })
  vim.cmd('wincmd p')
  h.ok(vim.api.nvim_get_current_win() ~= s.diff_win)
  vim.g.statusline_winid = s.diff_win
  h.ok(not view.winbar():find('ce', 1, true), view.winbar())
  vim.api.nvim_set_current_win(s.diff_win)
end)

h.test('g? opens the key list (rebinds shown), closes with g?, q and <Esc>; also from the panel', function()
  setup({ comment_edit = 'E' })
  local s = open(d)
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_feedkeys('g?', 'mtx', false)
  local st = kh.state
  h.ok(st and vim.api.nvim_win_is_valid(st.win), 'the float is open')
  h.eq(st.win, vim.api.nvim_get_current_win())
  local t = table.concat(vim.api.nvim_buf_get_lines(st.buf, 0, -1, false), '\n')
  h.ok(t:find('\n   E +edit the comment on this line'), t)
  h.ok(t:find(' Comments\n', 1, true), t)
  vim.api.nvim_feedkeys('g?', 'mtx', false)
  h.ok(not vim.api.nvim_win_is_valid(st.win), 'g? closes it')
  for _, k in ipairs({ 'q', '<Esc>' }) do
    vim.api.nvim_feedkeys('g?', 'mtx', false)
    local w = kh.state.win
    vim.api.nvim_feedkeys(vim.keycode(k), 'mtx', false)
    h.ok(not vim.api.nvim_win_is_valid(w), k .. ' closes it')
  end
  vim.api.nvim_set_current_win(s.panel_win)
  vim.api.nvim_feedkeys('g?', 'mtx', false)
  h.ok(kh.state and vim.api.nvim_win_is_valid(kh.state.win), 'from the panel')
  vim.api.nvim_feedkeys('q', 'mtx', false)
  h.eq(s.panel_win, vim.api.nvim_get_current_win())
  setup()
end)

h.test('the panel: one help line g? all keys (rebound; gone when disabled); its lines follow the config', function()
  local s = open(d)
  local function panel()
    return vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false)
  end
  local lines = panel()
  h.eq(' g? all keys', lines[#lines])
  for _, l in ipairs(lines) do
    h.ok(vim.api.nvim_strwidth(l) <= 40 or not l:find('^ %S'), 'fits the panel: ' .. l)
  end
  setup({ help = '<F1>', next_hunk = 'J' })
  s = open(d)
  lines = panel()
  h.eq(' <F1> all keys', lines[#lines])
  h.ok(vim.tbl_contains(lines, ' J [c hunk  ]f [f file  <Tab> fold'), table.concat(lines, '\n'))
  setup({ help = false })
  s = open(d)
  lines = panel()
  h.ok(not table.concat(lines, '\n'):find('all keys', 1, true))
  setup()
  view.close()
end)

h.run()
