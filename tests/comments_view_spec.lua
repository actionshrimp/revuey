-- Integration: comments in the review UI. `gc` in normal and visual mode in the diff and guide
-- views (add, del and ctx lines, a file header), the editor (save, :w, cancel, drafts, send),
-- edit, reply, resolve, delete, navigation, visibility, long comments, the list, export to a
-- register, re-anchoring after a working-tree edit (moved, then outdated), live reload of the
-- comments file and two Neovim instances merging their comments.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')
local msgs = {}
vim.notify = function(m, level)
  msgs[#msgs + 1] = { msg = m, level = level }
end

local log = h.tmpdir('cv-fake-claude') .. '/calls.ndjson'
h.use_fake_claude(log)
vim.o.columns, vim.o.lines = 160, 50

local state_dir = h.tmpdir('cv-state')
require('revuey').setup({ state_dir = state_dir, lsp_warmup = false })
local view = require('revuey.view')
local review_mod = require('revuey.review')
local comments = require('revuey.comments')
local cv = require('revuey.comments_view')
local editor = require('revuey.comment_editor')
local gv = require('revuey.guide_view')

local function numbered(n)
  local t = {}
  for i = 1, n do
    t[#t + 1] = 'line ' .. i
  end
  return table.concat(t, '\n') .. '\n'
end

local function edit(text, map)
  for from, to in pairs(map) do
    text = text:gsub('line ' .. from .. '\n', to .. '\n', 1)
  end
  return text
end

local long = numbered(40)
local repo = h.repo('cv', { ['m.txt'] = long }, {
  ['a.txt'] = 'new\nfile\n',
  ['m.txt'] = edit(long, { [20] = 'twenty', [35] = 'thirty-five' }),
})

local function idle(s)
  assert(vim.wait(10000, function()
    return not s.refreshing and not s.pending and not s.pending_scope
  end, 10), 'refresh did not finish')
end

local function keys(s, k)
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_feedkeys(vim.keycode(k), 'mtx', false)
  idle(s)
end

local s = h.open_review({ cwd = repo })

---Row of a code line: kind and its line number on that side.
local function row_of(path, kind, lnum)
  for row, e in ipairs(s.layout.map) do
    if e.path == path and e.kind == kind and (kind == 'del' and e.old_lnum or e.new_lnum) == lnum then
      return row
    end
  end
  error(('no %s row %s:%d'):format(kind, path, lnum))
end

local function file_row(path)
  for row, e in ipairs(s.layout.map) do
    if e.path == path and e.meta == 'file' then
      return row
    end
  end
end

---All virtual-line text attached to `row`.
local function vlines(row)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.diff_buf, cv.ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    for _, l in ipairs(m[4].virt_lines or {}) do
      local t = {}
      for _, c in ipairs(l) do
        t[#t + 1] = c[1]
      end
      out[#out + 1] = table.concat(t)
    end
  end
  return table.concat(out, '\n')
end

local function store()
  return s.cm.store
end

local function live()
  return comments.list(store(), { include_resolved = true, include_drafts = true })
end

local function events()
  local fd = io.open(s.cm.events)
  if not fd then
    return {}
  end
  local evs = comments.decode_events(fd:read('*a'))
  fd:close()
  return evs
end

---Comment on `row` with `gc` (visual when `last` is given), type `text` and save with <C-s>.
local function add(row, text, last, how)
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
  if last then
    vim.api.nvim_feedkeys('V', 'nx', false)
    vim.api.nvim_win_set_cursor(s.diff_win, { last, 0 })
  end
  keys(s, 'gc')
  local st = editor.current
  assert(st and vim.api.nvim_get_current_win() == st.win, 'editor did not open')
  vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, vim.split(text, '\n'))
  if how == ':w' then
    vim.cmd('stopinsert')
    vim.cmd('write')
    vim.wait(1000, function()
      return st.done
    end, 10)
  else
    vim.api.nvim_feedkeys(vim.keycode('<C-s>'), 'mtx', false)
  end
  assert(st.done, 'editor still open')
  return st
end

local function by_body(body)
  for _, c in ipairs(live()) do
    if c.body == body then
      return c
    end
  end
end

h.test('gc on an added line: editor titled with the anchor, saved comment, thread, sign, count, event', function()
  local row = row_of('m.txt', 'add', 20)
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
  keys(s, 'gc')
  local st = editor.current
  h.ok(st, 'editor open')
  h.eq('markdown', vim.bo[st.buf].filetype)
  h.eq('acwrite', vim.bo[st.buf].buftype)
  local cfg = vim.api.nvim_win_get_config(st.win)
  h.eq('m.txt:20 (new)', vim.trim(cfg.title[1][1]))
  vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, { 'Why **twenty**?' })
  vim.api.nvim_feedkeys(vim.keycode('<C-s>'), 'mtx', false)
  h.ok(st.done)
  h.eq(s.diff_win, vim.api.nvim_get_current_win(), 'back in the review')
  local c = by_body('Why **twenty**?')
  h.ok(c, vim.inspect(live()))
  h.eq({ 'm.txt', 'new', 20, 20 }, { c.anchor.path, c.anchor.side, c.anchor.start_line, c.anchor.end_line })
  h.eq({ '+twenty' }, c.anchor.snippet)
  h.eq('saved', c.status)
  h.eq({ kind = 'user' }, c.author)
  local v = vlines(row)
  h.ok(v:find('You · just now', 1, true), v)
  h.ok(v:find('Why twenty?', 1, true), 'markdown-lite: markers removed\n' .. v)
  h.eq('RevueyCommentSign', cv.sign(s, row))
  vim.g.statusline_winid = s.diff_win
  h.eq('RevueyCommentSign', cv.sign(s, row))
  -- the buffer text and side table are untouched
  h.eq('twenty', vim.api.nvim_buf_get_lines(s.diff_buf, row - 1, row, false)[1])
  h.eq('add', s.layout.map[row].kind)
  local pline = vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false)
  local pns = vim.api.nvim_get_namespaces()['revuey.panel']
  local prow = s.panel_rows[2]
  local pv = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.panel_buf, pns, { prow - 1, 0 }, { prow - 1, -1 }, { details = true })) do
    for _, ch in ipairs(m[4].virt_text or {}) do
      pv[#pv + 1] = ch[1]
    end
  end
  h.ok(table.concat(pv):find('✎1', 1, true), table.concat(pv) .. vim.inspect(pline))
  local ev = events()
  h.eq('created', ev[#ev].kind)
  h.eq(c.id, ev[#ev].comment_id)
  h.eq({ '+twenty' }, ev[#ev].snippet)
end)

h.test('gc on a deleted line uses the old side; on a context line the new side; :w saves', function()
  add(row_of('m.txt', 'del', 20), 'old side', nil, ':w')
  local c = by_body('old side')
  h.eq({ 'old', 20 }, { c.anchor.side, c.anchor.start_line })
  h.eq({ '-line 20' }, c.anchor.snippet)
  add(row_of('m.txt', 'ctx', 18), 'context line')
  local c2 = by_body('context line')
  h.eq({ 'new', 18 }, { c2.anchor.side, c2.anchor.start_line })
  h.eq({ ' line 18' }, c2.anchor.snippet)
end)

h.test('visual gc: a range with the diff markers of every selected row', function()
  add(row_of('m.txt', 'ctx', 19), 'a range', row_of('m.txt', 'ctx', 21))
  local c = by_body('a range')
  h.eq({ 'new', 19, 21 }, { c.anchor.side, c.anchor.start_line, c.anchor.end_line })
  h.eq({ ' line 19', '-line 20', '+twenty', ' line 21' }, c.anchor.snippet)
  h.eq('n', vim.api.nvim_get_mode().mode)
  h.ok(vlines(row_of('m.txt', 'ctx', 21)):find('a range', 1, true))
end)

h.test('gc on a file header: a file-level comment shown under the header', function()
  add(file_row('a.txt'), 'whole file')
  local c = by_body('whole file')
  h.eq(true, c.file_level)
  h.eq('a.txt', c.anchor.path)
  h.ok(vlines(file_row('a.txt')):find('whole file', 1, true))
  h.ok(vlines(file_row('a.txt')):find('· file', 1, true))
end)

h.test('ce edits, cr replies, cx resolves and reopens, cd deletes (after confirming)', function()
  local row = row_of('m.txt', 'ctx', 18)
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
  keys(s, 'ce')
  local st = editor.current
  h.eq({ 'context line' }, vim.api.nvim_buf_get_lines(st.buf, 0, -1, false))
  vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, { 'context line, edited' })
  vim.api.nvim_feedkeys(vim.keycode('<C-s>'), 'mtx', false)
  local c = by_body('context line, edited')
  h.ok(c)
  h.eq('updated', events()[#events()].kind)
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
  keys(s, 'cr')
  st = editor.current
  h.ok(vim.trim(vim.api.nvim_win_get_config(st.win).title[1][1]):find('^Reply'))
  vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, { 'a reply' })
  vim.api.nvim_feedkeys(vim.keycode('<C-s>'), 'mtx', false)
  c = comments.get(store(), c.id)
  h.eq('a reply', c.thread[1].body)
  h.eq('replied', events()[#events()].kind)
  h.eq('a reply', events()[#events()].reply.body)
  h.ok(vlines(row):find('↳ You', 1, true), vlines(row))
  keys(s, 'cx')
  h.eq('resolved', comments.get(store(), c.id).status)
  h.eq('resolved', events()[#events()].kind)
  h.ok(vlines(row):find('resolved', 1, true))
  h.eq('RevueyCommentResolved', cv.sign(s, row))
  keys(s, 'cx')
  h.eq('saved', comments.get(store(), c.id).status)
  -- delete: refused, then confirmed
  local orig = cv.confirm_delete
  cv.confirm_delete = function()
    return false
  end
  keys(s, 'cd')
  h.ok(comments.get(store(), c.id))
  cv.confirm_delete = function()
    return true
  end
  keys(s, 'cd')
  cv.confirm_delete = orig
  h.eq(nil, comments.get(store(), c.id))
  h.eq(true, store().comments[c.id].deleted, 'a tombstone')
  h.eq('deleted', events()[#events()].kind)
  h.eq('', vlines(row))
  h.eq(nil, cv.sign(s, row))
end)

h.test('editor: q asks before discarding typed text; closing it otherwise keeps a draft', function()
  local row = row_of('m.txt', 'ctx', 37)
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
  keys(s, 'gc')
  local st = editor.current
  vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, { 'typed' })
  vim.cmd('stopinsert')
  local orig = editor.confirm
  editor.confirm = function()
    return false
  end
  vim.api.nvim_feedkeys('q', 'mtx', false)
  h.eq(false, st.done, 'kept editing')
  editor.confirm = function()
    return true
  end
  vim.api.nvim_feedkeys('q', 'mtx', false)
  h.eq(true, st.done)
  h.eq(nil, by_body('typed'), 'discarded')
  -- an accidental close (:q) keeps the text as a draft
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
  keys(s, 'gc')
  st = editor.current
  vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, { 'half a thought' })
  vim.cmd('stopinsert')
  vim.cmd('quit')
  vim.wait(500, function()
    return by_body('half a thought') ~= nil
  end, 10)
  editor.confirm = orig
  local d = by_body('half a thought')
  h.ok(d, 'draft stored')
  h.eq('draft', d.status)
  h.ok(vlines(row):find('draft', 1, true))
  h.eq('RevueyCommentDraft', cv.sign(s, row))
  local before = #events()
  -- ce continues the draft; saving it is its creation
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
  keys(s, 'ce')
  st = editor.current
  h.eq({ 'half a thought' }, vim.api.nvim_buf_get_lines(st.buf, 0, -1, false))
  vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, { 'a whole thought' })
  vim.api.nvim_feedkeys(vim.keycode('<C-s>'), 'mtx', false)
  local c = by_body('a whole thought')
  h.eq('saved', c.status)
  h.eq(before + 1, #events())
  h.eq('created', events()[#events()].kind)
end)

-- Regression (review): WinClosed ran before the scheduled BufWriteCmd save, so :wq and :x
-- stored a draft instead of the comment.
h.test('editor: :wq and :x save the comment (not a draft)', function()
  for _, cmd in ipairs({ 'wq', 'x' }) do
    local row = row_of('m.txt', 'ctx', 38)
    vim.api.nvim_set_current_win(s.diff_win)
    vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
    keys(s, 'gc')
    local st = editor.current
    vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, { 'saved with :' .. cmd })
    vim.cmd('stopinsert')
    vim.cmd(cmd)
    vim.wait(300)
    local c = by_body('saved with :' .. cmd)
    h.ok(c, ':' .. cmd .. ' lost the text')
    h.eq('saved', c.status, ':' .. cmd)
    h.eq('created', events()[#events()].kind)
    h.eq(c.id, events()[#events()].comment_id)
    h.eq(s.diff_win, vim.api.nvim_get_current_win())
  end
end)

h.test('editor: the send key is reserved (not yet available), and pluggable', function()
  local row = row_of('m.txt', 'ctx', 37)
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
  keys(s, 'gc')
  local st = editor.current
  vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, { 'to the agent' })
  msgs = {}
  vim.api.nvim_feedkeys(vim.keycode('<C-a>'), 'mtx', false)
  h.eq(false, st.done)
  h.ok(msgs[#msgs] and msgs[#msgs].msg:find('not available yet', 1, true), vim.inspect(msgs))
  local got
  local orig = cv.actions.send
  cv.actions.send = function(ctx)
    got = ctx
    return true
  end
  vim.api.nvim_feedkeys(vim.keycode('<C-a>'), 'mtx', false)
  cv.actions.send = orig
  h.eq(true, st.done)
  h.eq('to the agent', got.text)
  h.eq('comment', got.kind)
  h.eq(37, got.anchor.start_line)
  h.eq(nil, by_body('to the agent'), 'sending does not save')
end)

h.test(']m and [m move between comments; gC hides and shows the threads', function()
  -- a.txt's header (row 1) has a file-level comment
  vim.api.nvim_win_set_cursor(s.diff_win, { 1, 0 })
  keys(s, ']m')
  h.eq(row_of('m.txt', 'ctx', 19), vim.api.nvim_win_get_cursor(s.diff_win)[1])
  keys(s, '[m')
  h.eq(file_row('a.txt'), vim.api.nvim_win_get_cursor(s.diff_win)[1])
  keys(s, ']m')
  h.eq(row_of('m.txt', 'ctx', 19), vim.api.nvim_win_get_cursor(s.diff_win)[1])
  keys(s, '2]m')
  local r2 = vim.api.nvim_win_get_cursor(s.diff_win)[1]
  h.ok(r2 > row_of('m.txt', 'ctx', 19), r2)
  keys(s, '[m')
  h.ok(vim.api.nvim_win_get_cursor(s.diff_win)[1] < r2)
  local row = row_of('m.txt', 'add', 20)
  h.ok(vlines(row) ~= '')
  keys(s, 'gC')
  h.eq('', vlines(row))
  h.eq('RevueyCommentSign', cv.sign(s, row), 'signs stay')
  keys(s, 'gC')
  h.ok(vlines(row) ~= '')
end)

h.test('long comments are cut with … and expand on demand (cz)', function()
  local body = {}
  for i = 1, 12 do
    body[#body + 1] = '- point ' .. i
  end
  local row = row_of('m.txt', 'ctx', 22)
  add(row, table.concat(body, '\n'))
  local v = vlines(row)
  h.ok(v:find('point 6', 1, true), v)
  h.ok(not v:find('point 7', 1, true), v)
  h.ok(v:find('… 6 more lines (cz expands)', 1, true), v)
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
  keys(s, 'cz')
  v = vlines(row)
  h.ok(v:find('point 12', 1, true), v)
  keys(s, 'cz')
  h.ok(not vlines(row):find('point 12', 1, true))
end)

h.test('threads wrap to the window width', function()
  local row = row_of('m.txt', 'ctx', 23)
  add(row, string.rep('word ', 60))
  local w = vim.api.nvim_win_get_width(s.diff_win) - (2 * s.numw + 4)
  for _, l in ipairs(vim.split(vlines(row), '\n')) do
    h.ok(vim.api.nvim_strwidth(l) <= w, ('%d > %d: %s'):format(vim.api.nvim_strwidth(l), w, l))
  end
end)

h.test('the comments list shows every comment; <CR> jumps to one', function()
  local st = cv.open_list(s)
  local lines = vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)
  local text = table.concat(lines, '\n')
  h.ok(text:find('a.txt', 1, true), text)
  h.ok(text:find('20 (old)  old side', 1, true), text)
  h.ok(text:find('19-21 (new)  a range', 1, true), text)
  local target
  for i, l in ipairs(st.lines) do
    if l.id and l.text:find('old side', 1, true) then
      target = i
    end
  end
  vim.api.nvim_win_set_cursor(st.win, { target, 0 })
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'mtx', false)
  h.eq(false, vim.api.nvim_win_is_valid(st.win))
  h.eq(row_of('m.txt', 'del', 20), vim.api.nvim_win_get_cursor(s.diff_win)[1])
  -- also from :RevueyComments
  vim.cmd('RevueyComments')
  h.ok(vim.api.nvim_win_is_valid(cv.list_state.win))
  vim.api.nvim_feedkeys('q', 'mtx', false)
  h.eq(false, vim.api.nvim_win_is_valid(cv.list_state.win))
end)

h.test(':RevueyCommentsExport to a register: markdown by default, json, --all', function()
  vim.cmd('RevueyCommentsExport a')
  local md = vim.fn.getreg('a')
  h.ok(md:find('^# Review comments: feat → main'), md)
  h.ok(md:find('## %d+%. m%.txt:20 %(old%)'), md)
  h.ok(md:find('```diff\n-line 20\n```', 1, true), md)
  h.ok(md:find('a.txt (whole file)', 1, true), md)
  vim.cmd('RevueyCommentsExport json --all b')
  local data = vim.json.decode(vim.fn.getreg('b'))
  h.eq('feat', data.reviews[1].review.branch)
  h.eq(#comments.list(store(), { include_resolved = true, include_drafts = true }), #data.reviews[1].comments)
  local file = h.tmpdir('cv-export') .. '/out.md'
  vim.cmd('RevueyCommentsExport markdown ' .. file)
  h.eq(md, table.concat(vim.fn.readfile(file), '\n') .. '\n')
end)

h.test('guide view: comments from the diff show on the same lines; gc in the guide shows in the diff', function()
  local out = h.tmpdir('cv-guide') .. '/guide.json'
  local hs = review_mod.units(s.review).hunks
  local ids = {}
  for _, hk in ipairs(hs) do
    ids[#ids + 1] = { id = hk.id }
  end
  local fd = assert(io.open(out, 'w'))
  fd:write(vim.json.encode({ title = 'G', summary = 'S.', sections = { { title = 'All', overview = 'O.', hunks = ids } }, unplaced = {} }))
  fd:close()
  vim.env.REVUEY_FAKE_CLAUDE_OUTPUT = out
  view.guide_command(true)
  assert(vim.wait(20000, function()
    return next(gv.jobs) == nil and s.guide and s.guide.resolved ~= nil
  end, 20), 'guide generation did not finish')
  idle(s)
  h.eq('guide', s.view_mode)
  local row = row_of('m.txt', 'add', 20)
  h.ok(vlines(row):find('Why twenty?', 1, true), vlines(row))
  h.ok(vlines(row_of('m.txt', 'del', 20)):find('old side', 1, true))
  h.eq('RevueyCommentSign', cv.sign(s, row))
  -- gc on a deleted line and (visual) a context range in the guide
  add(row_of('m.txt', 'del', 35), 'from the guide')
  local c = by_body('from the guide')
  h.eq({ 'old', 35 }, { c.anchor.side, c.anchor.start_line })
  add(row_of('m.txt', 'ctx', 33), 'guide range', row_of('m.txt', 'ctx', 34))
  h.eq({ 33, 34 }, { by_body('guide range').anchor.start_line, by_body('guide range').anchor.end_line })
  -- a hunk header in the guide names the file: a file-level comment
  local hdr
  for r, e in ipairs(s.layout.map) do
    if e.meta == 'hunk' and e.path == 'a.txt' then
      hdr = r
    end
  end
  add(hdr, 'file from guide')
  h.eq(true, by_body('file from guide').file_level)
  view.set_view('diff')
  h.eq('diff', s.view_mode)
  h.ok(vlines(row_of('m.txt', 'del', 35)):find('from the guide', 1, true))
  h.ok(vlines(file_row('a.txt')):find('file from guide', 1, true))
end)

h.test('working-tree edit: comments move with their lines, then become outdated when they change', function()
  local c = by_body('Why **twenty**?')
  local old = by_body('old side')
  -- three lines inserted at the top of m.txt shift everything below
  h.write(repo, 'm.txt', 'top 1\ntop 2\ntop 3\n' .. edit(long, { [20] = 'twenty', [35] = 'thirty-five' }))
  view.refresh({ force = true })
  idle(s)
  local row = row_of('m.txt', 'add', 23)
  h.ok(vlines(row):find('Why twenty?', 1, true), vlines(row))
  h.eq({ 23, 23 }, { comments.get(store(), c.id).anchor.start_line, comments.get(store(), c.id).anchor.end_line })
  h.eq(false, comments.get(store(), c.id).outdated)
  -- persisted: the "last known" line is in the file
  h.eq(23, comments.read(s.cm.path).comments[c.id].anchor.start_line)
  -- the old side does not move
  h.ok(vlines(row_of('m.txt', 'del', 20)):find('old side', 1, true))
  h.eq(20, comments.get(store(), old.id).anchor.start_line)
  -- the commented line changes: outdated, shown at its last known line, snippet kept
  h.write(repo, 'm.txt', 'top 1\ntop 2\ntop 3\n' .. edit(long, { [20] = 'TWENTY!', [35] = 'thirty-five' }))
  view.refresh({ force = true })
  idle(s)
  local cc = comments.get(store(), c.id)
  h.eq(true, cc.outdated)
  h.eq({ '+twenty' }, cc.anchor.snippet)
  local v = vlines(row_of('m.txt', 'add', 23))
  h.ok(v:find('outdated · was m.txt:23', 1, true), v)
  h.eq('RevueyCommentOutdated', cv.sign(s, row_of('m.txt', 'add', 23)))
  -- the line is gone from the diff altogether (edit reverted to base): the "Outdated comments"
  -- group at the end of the file
  h.write(repo, 'm.txt', edit(long, { [35] = 'thirty-five' }))
  view.refresh({ force = true })
  idle(s)
  local last = 0
  for r, e in ipairs(s.layout.map) do
    if e.path == 'm.txt' and e.meta ~= 'blank' then
      last = r
    end
  end
  v = vlines(last)
  h.ok(v:find('Outdated comments', 1, true), v)
  h.ok(v:find('Why twenty?', 1, true), v)
  local md = cv.export(s, { 'x' })
  h.ok(md:find('m.txt:23 (new) (outdated', 1, true), md)
  -- put the change back: the comment re-anchors
  h.write(repo, 'm.txt', edit(long, { [20] = 'twenty', [35] = 'thirty-five' }))
  view.refresh({ force = true })
  idle(s)
  h.eq(false, comments.get(store(), c.id).outdated)
  h.eq(20, comments.get(store(), c.id).anchor.start_line)
end)

h.test('live reload: a reply written to the comments file elsewhere shows in the thread', function()
  local c = by_body('Why **twenty**?')
  local other = comments.load(s.cm.path)
  comments.reply(other, c.id, 'agent says hi', { kind = 'agent', name = 'claude' })
  comments.save(other)
  local row = row_of('m.txt', 'add', 20)
  h.ok(vim.wait(3000, function()
    return vlines(row):find('agent says hi', 1, true) ~= nil
  end, 20), vlines(row))
  h.ok(vlines(row):find('↳ claude', 1, true))
end)

-- Two Neovim instances on the same review: each adds a comment; both end up with both, and a
-- delete in one wins over the other's older copy.
h.test('two instances: comments made in each are merged, live', function()
  local MiniTest = dofile(h.root .. '/tests/vendor/mini/test.lua')
  local child = MiniTest.new_child_neovim()
  child.restart({ '-u', 'NONE' })
  child.lua(
    [[
    local root, dir, state = ...
    vim.opt.rtp:prepend(root)
    vim.cmd('runtime plugin/revuey.lua')
    vim.notify = function() end
    vim.cmd('cd ' .. vim.fn.fnameescape(dir))
    require('revuey').setup({ state_dir = state, lsp_warmup = false })
    local done = false
    require('revuey').open({ base = 'main', on_ready = function() done = true end })
    vim.wait(10000, function() return done end, 10)
    assert(done)
  ]],
    { h.root, repo, state_dir }
  )
  -- the child comments on m.txt:35 (new) through the same code path as gc
  child.lua([[
    local s = require('revuey.view').session
    local cv = require('revuey.comments_view')
    for row, e in ipairs(s.layout.map) do
      if e.path == 'm.txt' and e.kind == 'add' and e.new_lnum == 35 then
        vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
        cv.add(s, row, row)
      end
    end
    local st = require('revuey.comment_editor').current
    vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, { 'from the child' })
    require('revuey.comment_editor').save(st)
  ]])
  add(row_of('m.txt', 'ctx', 32), 'from the parent')
  h.ok(vim.wait(3000, function()
    return by_body('from the child') ~= nil
  end, 20), 'parent sees the child comment')
  h.ok(vim.wait(3000, function()
    return child.lua_get([[(function()
      for _, c in pairs(require('revuey.view').session.cm.store.comments) do
        if c.body == 'from the parent' then return true end
      end
      return false
    end)()]])
  end, 50), 'child sees the parent comment')
  -- the parent deletes the child's comment; the child's copy is older: the delete wins there too
  local cc = by_body('from the child')
  comments.delete(store(), cc.id)
  comments.save(store())
  h.ok(vim.wait(3000, function()
    return child.lua_get(('require("revuey.view").session.cm.store.comments[%q].deleted == true'):format(cc.id))
  end, 50), 'delete reached the child')
  child.stop()
  local disk = comments.read(s.cm.path)
  h.eq(true, disk.comments[cc.id].deleted)
  h.ok(by_body('from the parent'))
end)

-- Regression (review): comments on a file that left the review vanished from both views.
h.test('comments on files no longer in the review: a group at the end, ]m, panel count, list', function()
  local whole = by_body('whole file')
  h.ok(whole, 'a.txt has a file-level comment')
  -- a.txt was added on the branch; removing it from the working tree takes it out of the review
  vim.fn.delete(repo .. '/a.txt')
  view.refresh({ force = true })
  idle(s)
  h.eq(nil, file_row('a.txt'))
  local last = #s.layout.lines
  local v = vlines(last)
  h.ok(v:find('Comments on files no longer in this review', 1, true), v)
  h.ok(v:find('a.txt', 1, true), v)
  h.ok(v:find('whole file', 1, true), v)
  -- ]m reaches it
  vim.api.nvim_win_set_cursor(s.diff_win, { last - 1, 0 })
  keys(s, ']m')
  h.eq(last, vim.api.nvim_win_get_cursor(s.diff_win)[1])
  -- the panel counts them
  local panel = table.concat(vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false), '\n')
  h.ok(panel:find('on files no longer in this review', 1, true), panel)
  -- the list shows them, and <CR> jumps to the group
  local st = cv.open_list(s)
  local target
  for i, l in ipairs(st.lines) do
    if l.id == whole.id then
      target = i
    end
  end
  h.ok(target, 'listed')
  h.ok(st.lines[target].text:find('not in this review', 1, true), st.lines[target].text)
  vim.api.nvim_win_set_cursor(st.win, { 1, 0 })
  vim.api.nvim_win_set_cursor(st.win, { target, 0 })
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'mtx', false)
  h.eq(last, vim.api.nvim_win_get_cursor(s.diff_win)[1])
  -- in the guide too
  view.set_view('guide')
  h.ok(vlines(#s.layout.lines):find('whole file', 1, true))
  view.set_view('diff')
  -- back in the review: back on its file
  h.git(repo, 'checkout', '--', 'a.txt')
  view.refresh({ force = true })
  idle(s)
  h.ok(vlines(file_row('a.txt')):find('whole file', 1, true))
end)

h.run()
