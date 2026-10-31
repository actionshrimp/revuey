-- Integration: `:RevueyAIReview` on a real git repo with a fake `claude` (tests/bin/claude) first
-- on PATH. The read-only invocation (flags, schema, cwd, numbered hunks on stdin), findings shown
-- as AI comments where a selection of their rows would put them, bad anchors dropped and
-- reported, the panel block (verdict, to triage, summary), triage (`ca` accept, `cn` dismiss and
-- restore), follow-up through the agent link (`cs`), re-running (asks, replaces only untouched
-- findings), a skill's SKILL.md in the prompt, failures, cancel, and no process left behind.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')
local msgs = {}
vim.notify = function(msg, level)
  msgs[#msgs + 1] = { msg = msg, level = level }
end

local log = h.tmpdir('fake-claude-review') .. '/calls.ndjson'
h.use_fake_claude(log)

local state_dir = h.tmpdir('ai-review-view-state')
require('revuey').setup({ state_dir = state_dir, lsp_warmup = false })
local view = require('revuey.view')
local arv = require('revuey.ai_review_view')
local ai = require('revuey.ai')
local comments = require('revuey.comments')
local cv = require('revuey.comments_view')
local review_mod = require('revuey.review')

local lines = {}
for i = 1, 40 do
  lines[#lines + 1] = 'line ' .. i
end
local long = table.concat(lines, '\n') .. '\n'
-- the repo's own skill is committed on main, so it is not part of the diff
local repo = h.repo('ai-review-view', {
  ['m.txt'] = long,
  ['.claude/skills/strict/SKILL.md'] = '---\nname: strict\ndescription: d\n---\nBe strict about naming.\n',
}, {
  ['m.txt'] = (long:gsub('line 20\n', 'twenty\n')),
  ['new.txt'] = 'brand new file\nwith two lines\n',
})

local s

local function idle()
  assert(vim.wait(10000, function()
    return not s.refreshing and not s.pending and not s.pending_scope
  end, 10), 'refresh did not finish')
end

local function wait_job()
  assert(vim.wait(20000, function()
    return next(arv.jobs) == nil
  end, 20), 'the AI review did not finish')
  idle()
end

local function keys(k)
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_feedkeys(vim.keycode(k), 'mtx', false)
  idle()
end

local function answer_select(choice)
  local orig = vim.ui.select
  vim.ui.select = function(items, _, cb)
    vim.ui.select = orig
    cb(choice and vim.tbl_contains(items, choice) and choice or nil)
  end
end

local function arg_value(argv, flag)
  for i, a in ipairs(argv) do
    if a == flag then
      return argv[i + 1]
    end
  end
end

local function panel()
  local out = {}
  local buf = s.panel_buf
  local ns = vim.api.nvim_get_namespaces()['revuey.panel']
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local virt = {}
    for _, m in ipairs(ns and vim.api.nvim_buf_get_extmarks(buf, ns, { i - 1, 0 }, { i - 1, -1 }, { details = true }) or {}) do
      for _, ch in ipairs(m[4].virt_text or {}) do
        virt[#virt + 1] = ch[1]
      end
    end
    out[#out + 1] = l .. (#virt > 0 and ('  ' .. table.concat(virt)) or '')
  end
  return table.concat(out, '\n')
end

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

local function row_of(kind, lnum, path)
  for row, e in ipairs(s.layout.map) do
    if e.path == (path or 'm.txt') and e.kind == kind and (kind == 'del' and e.old_lnum or e.new_lnum) == lnum then
      return row
    end
  end
  error(('no %s row %d'):format(kind, lnum))
end

local function hunk_for(path)
  for _, hk in ipairs(review_mod.units(s.review).hunks) do
    if hk.path == path then
      return hk
    end
  end
end

local function line_in(hk, text)
  for i, l in ipairs(hk.text) do
    if l == text then
      return i
    end
  end
end

local function findings()
  local out = {}
  for _, c in pairs(s.cm.store.comments) do
    if not c.deleted and c.ai then
      out[c.ai.title] = c
    end
  end
  return out
end

local function told(pat)
  for _, m in ipairs(msgs) do
    if m.msg:find(pat, 1, true) then
      return m
    end
  end
end

---Write a review document for the fake claude to return.
local function output(doc)
  local file = h.tmpdir('ai-review-out') .. '/review.json'
  vim.fn.writefile({ vim.json.encode(doc) }, file)
  vim.env.REVUEY_FAKE_CLAUDE_OUTPUT = file
end

h.test(':RevueyAIReview runs claude read-only with the review schema; findings land as AI comments', function()
  s = h.open_review({ cwd = repo, base = '' })
  local m, n = hunk_for('m.txt'), hunk_for('new.txt')
  output({
    summary = 'Renames line 20 and adds a file.',
    verdict = 'request_changes',
    findings = {
      { hunk = m.id, line = line_in(m, '+twenty'), severity = 'major', title = 'Twenty is spelled out', body = 'Use `20` like the others.', suggestion = 'line 20' },
      { hunk = m.id, line = line_in(m, '-line 20'), severity = 'minor', title = 'Old line dropped', body = 'Was it used?' },
      { hunk = n.id, severity = 'nit', title = 'New file needed?', body = 'Explain it.' },
      { hunk = 'h99', line = 1, severity = 'minor', title = 'Ghost', body = 'x' },
      { hunk = m.id, line = 999, severity = 'minor', title = 'Past the end', body = 'x' },
    },
  })
  vim.fn.delete(log)
  msgs = {}
  vim.cmd('RevueyAIReview')
  h.ok(panel():find(' AI review', 1, true), panel())
  wait_job()
  local calls = h.read_calls(log)
  h.eq(1, #calls)
  local argv = calls[1].argv
  h.eq(vim.uv.fs_realpath(repo), vim.uv.fs_realpath(calls[1].cwd))
  -- exactly the guide's read-only invocation, with the review schema and name
  local want = ai.providers.claude.build({ cmd = 'claude', prompt = '', schema = arg_value(argv, '--json-schema'), name = 'revuey review: feat', restricted = true })
  h.eq(want, argv)
  h.eq('dontAsk', arg_value(argv, '--permission-mode'))
  h.ok(vim.tbl_contains(argv, '--restricted') and vim.tbl_contains(argv, '--safe-mode'))
  local schema = vim.json.decode(arg_value(argv, '--json-schema'))
  h.ok(schema.properties.findings and schema.properties.verdict, 'the review schema')
  local stdin = calls[1].stdin
  h.ok(stdin:find('# Code Reviewer', 1, true))
  h.ok(stdin:find('\n@@ ' .. m.id .. ' m.txt @@\n', 1, true))
  h.ok(stdin:find(('\n%d|+twenty\n'):format(line_in(m, '+twenty')), 1, true), 'numbered lines')
  -- imported: three findings, two dropped and reported
  local f = findings()
  h.eq(3, vim.tbl_count(f))
  local m1 = told('AI review ready')
  h.ok(m1 and m1.msg:find('request changes, 3 findings; 2 dropped (1 unknown hunk, 1 line outside its hunk)', 1, true), vim.inspect(msgs))
  local twenty = f['Twenty is spelled out']
  h.eq({ kind = 'ai', name = 'claude' }, twenty.author)
  h.eq({ 'new', 20 }, { twenty.anchor.side, twenty.anchor.start_line })
  h.eq({ 'old', 20 }, { f['Old line dropped'].anchor.side, f['Old line dropped'].anchor.start_line })
  h.eq(true, f['New file needed?'].file_level)
  -- drawn where a comment on those rows is, labelled as the AI's, with severity and the triage keys
  local t = vlines(row_of('add', 20))
  h.ok(t:find('╭─ claude (ai)', 1, true), t)
  h.ok(t:find('major', 1, true) and t:find('ca accept · cn dismiss', 1, true), t)
  h.ok(t:find('Twenty is spelled out', 1, true) and t:find('Suggested change:', 1, true), t)
  h.ok(vlines(row_of('del', 20)):find('Old line dropped', 1, true), vlines(row_of('del', 20)))
  -- the panel: verdict, to triage, dropped, summary
  local p = panel()
  h.ok(p:find(' AI review  ✗ request changes', 1, true), p)
  h.ok(p:find(' 3 to triage · 2 dropped', 1, true), p)
  h.ok(p:find('Renames line 20 and adds a file.', 1, true), p)
  -- the comments list starts with the review
  local list = cv.list_lines(s)
  h.eq('AI review: ✗ request changes · claude', list[1].text)
  local found
  for _, l in ipairs(list) do
    if l.text:find('Twenty is spelled out', 1, true) then
      found = l.text
    end
  end
  h.ok(found and found:find('[major, to triage, by claude (ai)]', 1, true) and not found:find('**', 1, true), tostring(found))
  h.eq({}, vim.tbl_keys(ai.live), 'no claude left running')
end)

h.test('ca accepts a finding (it becomes your comment); cn dismisses and restores', function()
  local f = findings()
  local twenty, old = f['Twenty is spelled out'], f['Old line dropped']
  vim.api.nvim_win_set_cursor(s.diff_win, { row_of('add', 20), 0 })
  keys('ca')
  local c = comments.get(s.cm.store, twenty.id)
  h.eq({ { kind = 'user' }, 'accepted' }, { c.author, c.status })
  h.ok(vlines(row_of('add', 20)):find('╭─ You', 1, true), vlines(row_of('add', 20)))
  h.ok(vlines(row_of('add', 20)):find('accepted from AI review', 1, true))
  -- on disk, with an event
  local disk = comments.get(comments.load(s.cm.path, { readonly = true }), twenty.id)
  h.eq('accepted', disk.status)
  h.ok(panel():find(' 2 to triage', 1, true), panel())
  msgs = {}
  keys('ca')
  h.ok(told('already accepted'), vim.inspect(msgs))
  -- resolving and reopening an accepted finding keeps it accepted
  keys('cx')
  h.eq('resolved', comments.get(s.cm.store, twenty.id).status)
  msgs = {}
  keys('cn')
  h.ok(told('resolved: reopen it first'), vim.inspect(msgs))
  keys('cx')
  h.eq('accepted', comments.get(s.cm.store, twenty.id).status)
  h.ok(vlines(row_of('add', 20)):find('accepted from AI review', 1, true), vlines(row_of('add', 20)))
  -- dismiss: kept, collapsed, not counted
  vim.api.nvim_win_set_cursor(s.diff_win, { row_of('del', 20), 0 })
  keys('cn')
  h.eq('dismissed', comments.get(s.cm.store, old.id).status)
  h.ok(vlines(row_of('del', 20)):find('dismissed', 1, true), vlines(row_of('del', 20)))
  h.ok(not vlines(row_of('del', 20)):find('Was it used?', 1, true), 'collapsed to one line')
  h.ok(panel():find(' 1 to triage', 1, true), panel())
  keys('cn')
  h.eq('saved', comments.get(s.cm.store, old.id).status, 'restored')
  keys('cn')
  local fd = assert(io.open(comments.events_path_for(s.review.state._path)))
  local kinds = {}
  for _, ev in ipairs(comments.decode_events(fd:read('*a'))) do
    kinds[#kinds + 1] = ev.kind
  end
  fd:close()
  h.ok(vim.tbl_contains(kinds, 'accepted') and vim.tbl_contains(kinds, 'dismissed'), table.concat(kinds, ' '))
  -- a line without a finding
  vim.api.nvim_win_set_cursor(s.diff_win, { row_of('ctx', 17), 0 })
  msgs = {}
  keys('ca')
  h.ok(told('no AI review finding or agent comment on this line'), vim.inspect(msgs))
end)

h.test('cs sends a finding to the agent session (follow-up); a re-run asks, then replaces only untouched findings', function()
  local f = findings()
  local file = f['New file needed?']
  vim.api.nvim_win_set_cursor(s.diff_win, { s.cm.jump[file.id], 0 })
  keys('cs')
  h.ok(comments.get(s.cm.store, file.id).sent_at, 'sent')
  -- nothing left untouched (accepted, dismissed, sent): runs without asking
  local asked = false
  local orig = vim.ui.select
  vim.ui.select = function(_, _, cb)
    asked = true
    cb(nil)
  end
  local m = hunk_for('m.txt')
  output({
    summary = 'Second pass.',
    verdict = 'comment',
    findings = {
      { hunk = m.id, line = line_in(m, '+twenty'), severity = 'major', title = 'Twenty is spelled out', body = 'again' }, -- accepted: skipped
      { hunk = m.id, line = 1, severity = 'nit', title = 'Fresh one', body = 'x' },
    },
  })
  vim.cmd('RevueyAIReview')
  wait_job()
  vim.ui.select = orig
  h.eq(false, asked)
  f = findings()
  h.ok(f['Fresh one'] and f['New file needed?'] and f['Old line dropped'], vim.inspect(vim.tbl_keys(f)))
  h.ok(panel():find('1 already triaged', 1, true), panel())
  h.ok(panel():find(' AI review  ● comment', 1, true), panel())
  -- now one untouched finding (Fresh one): asks; declining runs nothing
  local before = #h.read_calls(log)
  answer_select(nil)
  vim.cmd('RevueyAIReview')
  h.eq(before, #h.read_calls(log))
  output({ summary = 'Third.', verdict = 'approve', findings = {} })
  answer_select('Run a new AI review')
  vim.cmd('RevueyAIReview')
  wait_job()
  f = findings()
  h.eq(nil, f['Fresh one'], 'the untouched finding was replaced')
  h.ok(f['Old line dropped'] and f['New file needed?'] and f['Twenty is spelled out'], 'triaged and sent ones stay')
  h.ok(panel():find(' AI review  ✓ approve', 1, true), panel())
end)

h.test('a skill: its SKILL.md is in the prompt; an unknown skill runs nothing', function()
  vim.env.REVUEY_FAKE_CLAUDE_OUTPUT = nil
  vim.fn.delete(log)
  vim.cmd('RevueyAIReview! strict')
  wait_job()
  local calls = h.read_calls(log)
  h.eq(1, #calls)
  h.ok(calls[1].stdin:find('Review guidance from the skill `strict`', 1, true))
  h.ok(calls[1].stdin:find('Be strict about naming.', 1, true) and not calls[1].stdin:find('description: d', 1, true))
  -- the default fake review: one finding on an unknown hunk dropped
  h.ok(panel():find('1 dropped', 1, true), panel())
  msgs = {}
  vim.cmd('RevueyAIReview! nosuchskill')
  h.eq(1, #h.read_calls(log))
  h.ok(told('no skill nosuchskill'), vim.inspect(msgs))
  h.eq(nil, next(arv.jobs))
end)

h.test('failures: an API error and invalid output keep the last review; the panel says why', function()
  for _, sc in ipairs({ 'error', 'invalid' }) do
    vim.env.REVUEY_FAKE_CLAUDE = sc
    msgs = {}
    vim.cmd('RevueyAIReview!')
    wait_job()
    h.ok(told('AI review failed'), sc .. vim.inspect(msgs))
    h.ok(panel():find(' ! failed:', 1, true), panel())
    h.ok(panel():find(' AI review  ', 1, true), 'the last record is still shown')
  end
  vim.env.REVUEY_FAKE_CLAUDE = nil
end)

h.test('cancel stops claude and its children; nothing is imported', function()
  vim.env.REVUEY_FAKE_CLAUDE = 'kids'
  vim.fn.delete(log .. '.kids')
  local n = vim.tbl_count(findings())
  vim.cmd('RevueyAIReview!')
  assert(vim.wait(10000, function()
    local j = arv.job(s)
    return j and j.job and j.job.proc and vim.uv.fs_stat(log .. '.kids') ~= nil
  end, 20), 'claude did not start')
  assert(vim.wait(5000, function()
    return (arv.job(s) or {}).progress ~= nil
  end, 20), 'no progress')
  h.ok(arv.status_text(s):find('reviewing %d+s'), arv.status_text(s))
  msgs = {}
  vim.cmd('RevueyAIReview cancel')
  wait_job()
  h.ok(told('AI review cancelled'), vim.inspect(msgs))
  local pids = vim.split(vim.trim(vim.fn.readfile(log .. '.kids')[1]), ' ')
  h.ok(vim.wait(5000, function()
    return vim.uv.kill(tonumber(pids[1]), 0) ~= 0 and vim.uv.kill(tonumber(pids[2]), 0) ~= 0
  end, 50), 'claude and its child are gone')
  h.ok(vim.wait(3000, function()
    return next(ai.live) == nil
  end, 50), 'no live process group')
  h.eq(n, vim.tbl_count(findings()))
  h.ok(not panel():find('! failed', 1, true), 'a cancel is not a failure')
  -- cancelled while still gathering the prompt (before claude starts): the spinner goes too,
  -- for AI reviews and for the guide
  local gv = require('revuey.guide_view')
  local orig = gv.prompt_context
  gv.prompt_context = function(r)
    require('revuey.git').system({ 'sleep', '0.5' })
    return orig(r)
  end
  vim.cmd('RevueyAIReview!')
  h.ok(s.panel_ai_status_row, 'a status row while it runs')
  vim.cmd('RevueyAIReview cancel')
  h.eq(nil, s.panel_ai_status_row, 'the panel was redrawn without it')
  view.guide_command(true)
  h.ok(s.panel_status_row, 'the guide status row')
  view.guide_command(false, 'cancel')
  h.eq(nil, s.panel_status_row, 'the guide panel was redrawn too')
  assert(vim.wait(3000, function()
    return next(arv.jobs) == nil and next(gv.jobs) == nil
  end, 20))
  vim.wait(700) -- the gathering coroutines finish and spawn nothing
  gv.prompt_context = orig
  h.eq({}, vim.tbl_keys(ai.live))
  view.set_view('diff')
  msgs = {}
  vim.cmd('RevueyAIReview cancel')
  h.ok(told('no AI review is running'), vim.inspect(msgs))
  vim.env.REVUEY_FAKE_CLAUDE = nil
end)

h.test('a run outlives its review: closing it, then reopening shows the findings and the verdict', function()
  vim.env.REVUEY_FAKE_CLAUDE = 'slow'
  vim.env.REVUEY_FAKE_CLAUDE_OUTPUT = nil
  local key = arv.key(s)
  vim.cmd('RevueyAIReview!')
  view.close()
  assert(vim.wait(20000, function()
    return next(arv.jobs) == nil
  end, 20), 'did not finish')
  local rec = require('revuey.ai_review').read_record(require('revuey.ai_review').record_path(key))
  h.ok(rec and rec.summary == 'A fake review summary.', vim.inspect(rec))
  local found = false
  for _, c in pairs(comments.load(key, { readonly = true }).comments) do
    found = found or (not c.deleted and c.ai and c.ai.title == 'First line looks wrong')
  end
  h.ok(found, 'written to the scope\'s comments file')
  s = h.open_review({ cwd = repo, base = '' })
  h.ok(panel():find('A fake review summary.', 1, true), panel())
  h.ok(findings()['First line looks wrong'], 'shown')
  vim.env.REVUEY_FAKE_CLAUDE = nil
  view.close()
end)

h.test('stack: a full-stack review tags hunks with their branch; a run finishes for its own layer after ]s', function()
  local d = h.tmpdir('ai-review-stack')
  vim.fn.delete(d, 'rf')
  assert(h.make_fixture('--stack', d).code == 0)
  s = h.open_review({ cwd = d, base = '' })
  h.eq({ kind = 'layer', index = 2 }, s.scope)
  keys('gs')
  h.eq({ kind = 'full' }, s.scope)
  vim.fn.delete(log)
  vim.cmd('RevueyAIReview!')
  wait_job()
  local stdin = h.read_calls(log)[1].stdin
  h.ok(stdin:find('This review covers a whole stack of 3 branches', 1, true), stdin)
  h.ok(stdin:find('@@ h1 [^\n]* @@ %[stack/'), 'branch tags on hunk markers')
  local full_key = arv.key(s)
  h.ok(next(findings()), 'full-stack findings')
  -- back to layer 2: its own (empty) review
  keys('gs')
  h.ok(arv.key(s) ~= full_key)
  h.eq(nil, next(findings()), 'the layer has no findings yet')
  h.ok(not panel():find(' AI review', 1, true), panel())
  -- start on layer 2, move to layer 3 while it runs
  vim.env.REVUEY_FAKE_CLAUDE = 'slow'
  local layer2 = arv.key(s)
  vim.cmd('RevueyAIReview!')
  keys(']s')
  h.eq(3, s.scope.index)
  wait_job()
  h.eq(nil, next(findings()), 'layer 3 got nothing')
  h.ok(not panel():find(' AI review', 1, true), panel())
  keys('[s')
  h.eq(layer2, arv.key(s))
  h.ok(findings()['First line looks wrong'], 'layer 2 got its findings')
  h.ok(panel():find(' AI review', 1, true), panel())
  vim.env.REVUEY_FAKE_CLAUDE = nil
  view.close()
end)

h.run()
