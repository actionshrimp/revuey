-- Unit: AI reviews (ai_review.lua, ai_review_prompt.lua). The schema, the prompt (numbered hunk
-- lines, review wording, the skill's guidance, the budget), validation of review documents (bad
-- anchors dropped and counted, verdicts and severities normalised, strings sanitised, JSON
-- repaired), anchors identical to a UI selection of the same rows (new side, deleted lines,
-- ranges, whole files), import into a comments store (replacing untouched findings of the same
-- author, keeping triaged ones and not importing them again, the diff hash), triage, the record
-- and skill lookup. Reviews are loaded headless from real git repos (review.load).
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
local ai_review = require('revuey.ai_review')
local prompt = require('revuey.ai_review_prompt')
local comments = require('revuey.comments')
local guide = require('revuey.guide')
local review_mod = require('revuey.review')

local state_dir = h.tmpdir('ai-review-state')

local function numbered(n, edits)
  local t = {}
  for i = 1, n do
    t[i] = (edits and edits[i]) or ('line ' .. i)
  end
  return table.concat(t, '\n') .. '\n'
end

local base = numbered(40)
-- m.txt: line 5 replaced, line 30 deleted; new.txt added; bin.dat binary
local repo = h.repo('ai-review', { ['m.txt'] = base, ['bin.dat'] = 'a\0b' }, {
  ['m.txt'] = (numbered(40, { [5] = 'five' }):gsub('line 30\n', '')),
  ['new.txt'] = 'brand new\nsecond line\n',
  ['bin.dat'] = 'a\0c',
})

local function load()
  local r = assert(review_mod.load({ cwd = repo, base = 'main', mode = 'committed', state_dir = state_dir }))
  return r, review_mod.units(r).hunks
end

local r, hunks = load()

---The hunk (guide id) of a path, nth of its file.
local function hunk_of(path, nth)
  local k = 0
  for _, hk in ipairs(hunks) do
    if hk.path == path then
      k = k + 1
      if k == (nth or 1) then
        return hk
      end
    end
  end
  error('no hunk for ' .. path)
end

---The 1-based index in hunk `hk` of the line with this text (and kind).
local function line_of(hk, text)
  for i, l in ipairs(hk.text) do
    if l == text then
      return i
    end
  end
  error('no line ' .. text .. ' in ' .. hk.id)
end

-- ---------------------------------------------------------------------------
-- Schema and prompt
-- ---------------------------------------------------------------------------

h.test('schema: summary, verdict enum, findings anchored to hunk ids; strict objects', function()
  local s = vim.json.decode(prompt.schema_json())
  h.eq(false, s.additionalProperties)
  h.eq({ 'summary', 'verdict', 'findings' }, s.required)
  h.eq({ 'approve', 'comment', 'request_changes' }, s.properties.verdict.enum)
  local item = s.properties.findings.items
  h.eq(false, item.additionalProperties)
  h.eq({ 'hunk', 'severity', 'title', 'body' }, item.required)
  h.eq('^h[0-9]+$', item.properties.hunk.pattern)
  h.eq({ 'critical', 'major', 'minor', 'nit' }, item.properties.severity.enum)
  for _, k in ipairs({ 'line', 'end_line', 'suggestion' }) do
    h.ok(item.properties[k], k)
  end
end)

h.test('prompt: hunk ids with numbered lines, review wording, the skill, the budget', function()
  local ctx = { repo = 'r', branch = 'feat', base = 'main', commits = { 'feat: five' } }
  local text, info = prompt.build(ctx, hunks, { budget = 150000 })
  h.ok(text, info)
  h.eq('full', info.level)
  h.ok(text:find('# Code Reviewer', 1, true), 'methodology first')
  h.ok(text:find('Review the following code changes.', 1, true))
  h.ok(not text:find('guided review', 1, true), 'no guide wording')
  local m = hunk_of('m.txt')
  h.ok(text:find('\n@@ ' .. m.id .. ' m.txt @@\n' .. m.header .. '\n1| line 2\n', 1, true), text)
  h.ok(text:find(('\n%d|-line 5\n%d|+five\n'):format(line_of(m, '-line 5'), line_of(m, '+five')), 1, true), text)
  h.ok(text:find(('Hunk ids: h1 to h%d. Each finding names one of them'):format(#hunks), 1, true))
  h.ok(text:find('\n@@ ' .. hunk_of('bin.dat').id .. ' bin.dat @@\n(Binary file not shown)\n', 1, true), 'a binary file: its note, no numbers')
  h.ok(not text:find('Review guidance from the skill', 1, true))
  -- the skill's text goes between the methodology and the diff
  local with = prompt.build(ctx, hunks, { budget = 150000, skill = { name = 'security', text = 'Look for SQL injection first.' } })
  local g, d = with:find('Review guidance from the skill `security`', 1, true), with:find('Review the following', 1, true)
  h.ok(g and d and g < d, 'guidance before the diff')
  h.ok(with:find('Look for SQL injection first.', 1, true))
  -- the guide's prompt is unchanged: no numbers
  local gtext = require('revuey.guide_prompt').build(ctx, hunks, { budget = 150000 })
  h.ok(gtext:find('\n@@ ' .. m.id .. ' m.txt @@\n' .. m.header .. '\n line 2\n', 1, true), 'guide lines are not numbered')
  -- over the budget the largest hunks are abridged with numbered preview lines, then refused
  local big = {}
  for i = 1, 400 do
    local t = {}
    for k = 1, 30 do
      t[k] = '+line ' .. k .. ' of hunk ' .. i
    end
    big[i] = { id = 'h' .. i, file_idx = i, hunk_idx = 1, path = 'f' .. i, old_path = 'f' .. i, status = 'M', header = '@@ -1 +1,30 @@', added = 30, removed = 0, text = t }
  end
  local short, sinfo = prompt.build(ctx, big, { budget = 150000 })
  h.ok(#short <= 150000)
  h.eq('abridged', sinfo.level)
  h.ok(short:find('\n1|+line 1 of hunk', 1, true), 'abridged previews keep their numbers')
  local none, err = prompt.build(ctx, big, { budget = 3000 })
  h.eq(nil, none)
  h.ok(err:find('too large for one AI review', 1, true), err)
end)

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------

h.test('validate: good findings kept; bad anchors dropped and counted by reason', function()
  local m = hunk_of('m.txt')
  local bin = hunk_of('bin.dat')
  local five = line_of(m, '+five')
  local doc, w = ai_review.validate({
    summary = '  Looks risky.\r\n',
    verdict = 'request_changes',
    findings = {
      { hunk = m.id, line = five, severity = 'major', title = 'Five', body = 'Why?' },
      { hunk = m.id:upper(), line = five, end_line = five + 1, severity = 'High', title = 'Range', body = 'b', suggestion = '  five\n  six\n\n' },
      { hunk = m.id, severity = 'nit', title = 'Whole file', body = 'b' },
      { hunk = bin.id, line = 3, severity = 'minor', title = 'Binary', body = 'b' }, -- no text diff: whole file
      { hunk = 'h999', line = 1, severity = 'minor', title = 'Ghost', body = 'b' },
      { hunk = m.id, line = #m.text + 1, severity = 'minor', title = 'Past the end', body = 'b' },
      { hunk = m.id, line = 3, end_line = 2, severity = 'minor', title = 'Backwards', body = 'b' },
      { hunk = m.id, line = 0, severity = 'minor', title = 'Zero', body = 'b' },
      { hunk = m.id, line = 1.5, severity = 'minor', title = 'Fraction', body = 'b' },
      { hunk = m.id, end_line = 2, severity = 'minor', title = 'End only', body = 'b' },
      { hunk = m.id, line = five, severity = 'major', title = 'Five', body = 'again' }, -- duplicate
      { hunk = m.id, line = 1, severity = 'minor', title = '', body = '' }, -- empty
      'not a table',
    },
  }, hunks)
  h.ok(doc, vim.inspect(w))
  h.eq('Looks risky.', doc.summary)
  h.eq('request_changes', doc.verdict)
  h.eq(4, #doc.findings)
  h.eq({ m.id, five, five, 'major', 'Five', 'Why?' }, { doc.findings[1].hunk, doc.findings[1].line, doc.findings[1].end_line, doc.findings[1].severity, doc.findings[1].title, doc.findings[1].body })
  h.eq({ m.id, five + 1, 'major', '  five\n  six' }, { doc.findings[2].hunk, doc.findings[2].end_line, doc.findings[2].severity, doc.findings[2].suggestion })
  h.eq({ nil, nil }, { doc.findings[3].line, doc.findings[3].end_line })
  h.eq({ bin.id, nil }, { doc.findings[4].hunk, doc.findings[4].line })
  h.eq({ dropped = 9, unknown_hunk = 1, bad_line = 5, empty = 2, duplicates = 1, extra = 0 }, w)
  h.eq('9 dropped (1 unknown hunk, 5 lines outside their hunks, 2 empty, 1 duplicate)', ai_review.dropped_text(w))
  h.eq(nil, ai_review.dropped_text({ dropped = 0 }))
end)

h.test('validate: verdicts and severities normalised, strings sanitised, JSON repaired, limits', function()
  local m = hunk_of('m.txt')
  for v, want in pairs({ approve = 'approve', ['Request changes'] = 'request_changes', CHANGES_REQUESTED = 'request_changes', comment = 'comment' }) do
    h.eq(want, ai_review.norm_verdict(v), v)
  end
  local doc, w = ai_review.validate({ summary = 'x', verdict = 'maybe', findings = {} }, hunks)
  h.eq('comment', doc.verdict)
  h.eq(true, w.verdict_unknown)
  h.eq({ 'critical', 'nit', 'minor' }, { ai_review.norm_severity('blocker'), ai_review.norm_severity('low'), (ai_review.norm_severity('weird')) })
  -- titles become one line; a missing title comes from the body; a suggestion needs a line
  doc = ai_review.validate({
    summary = 's',
    verdict = 'approve',
    findings = {
      { hunk = m.id, line = 1, severity = 'minor', title = 'Two\nlines\0', body = 'Body\n\nmore' },
      { hunk = m.id, line = 2, severity = 'minor', body = 'From the body\nsecond' },
      { hunk = m.id, severity = 'minor', title = 'No line', body = 'b', suggestion = 'x' },
    },
  }, hunks)
  h.eq('Two lines', doc.findings[1].title)
  h.eq('Body\n\nmore', doc.findings[1].body)
  h.eq('From the body', doc.findings[2].title)
  h.eq(nil, doc.findings[3].suggestion)
  -- fenced text is repaired; garbage is an error; findings must be an array
  local fenced = 'Here:\n```json\n' .. vim.json.encode({ summary = 's', verdict = 'approve', findings = {} }) .. '\n```'
  h.ok(ai_review.validate(fenced, hunks))
  h.eq({ nil, 'the review is not valid JSON' }, { ai_review.validate('no json here', hunks) })
  h.eq({ nil, 'findings must be an array' }, { ai_review.validate({ summary = 's', verdict = 'approve', findings = 'x' }, hunks) })
  -- no findings is a fine review
  doc = ai_review.validate({ summary = 'Clean.', verdict = 'approve', findings = {} }, hunks)
  h.eq({}, doc.findings)
  -- at most MAX_FINDINGS
  local many = {}
  for i = 1, ai_review.MAX_FINDINGS + 3 do
    many[i] = { hunk = m.id, line = 1, severity = 'nit', title = 'n' .. i, body = 'b' }
  end
  local _, w2 = ai_review.validate({ summary = 's', verdict = 'comment', findings = many }, hunks)
  h.eq(3, w2.extra)
end)

-- ---------------------------------------------------------------------------
-- Anchors
-- ---------------------------------------------------------------------------

h.test('anchor: the same anchor a UI selection of those rows stores (new side, deleted lines, ranges, files)', function()
  local U = review_mod.units(r)
  local ctx = comments.context(r.files, U, function(path, side)
    return review_mod.side_text(r, r.files[U.by_path[path]], side)
  end)
  local m = hunk_of('m.txt')
  local function rows(first, last)
    local out = {}
    local hk = r.files[m.file_idx].hunks[m.hunk_idx]
    for li = first, last do
      out[#out + 1] = { kind = hk.lines[li].kind, file_idx = m.file_idx, hunk_idx = m.hunk_idx, line_idx = li }
    end
    return out
  end
  local five = line_of(m, '+five')
  local del5 = line_of(m, '-line 5')
  for _, case in ipairs({ { five, five }, { del5, del5 }, { del5, five }, { 1, #m.text } }) do
    local a = ai_review.anchor(r.files, U, m, { line = case[1], end_line = case[2] }, ctx.get_line)
    h.eq(comments.anchor_from_rows(r.files, U, rows(case[1], case[2]), ctx.get_line), a, vim.inspect(case))
  end
  local a = ai_review.anchor(r.files, U, m, { line = five, end_line = five }, ctx.get_line)
  h.eq({ 'new', 5, 5, { '+five' } }, { a.side, a.start_line, a.end_line, a.snippet })
  h.ok(a.unit_key and a.hunk_key and a.hunk_line == five, vim.inspect(a))
  a = ai_review.anchor(r.files, U, m, { line = del5, end_line = del5 }, ctx.get_line)
  h.eq({ 'old', 5 }, { a.side, a.start_line })
  h.eq({ path = 'm.txt', side = 'new' }, ai_review.anchor(r.files, U, m, {}, ctx.get_line))
  h.eq({ path = 'bin.dat', side = 'new' }, ai_review.anchor(r.files, U, hunk_of('bin.dat'), { line = 1 }, ctx.get_line))
end)

-- ---------------------------------------------------------------------------
-- Import and triage
-- ---------------------------------------------------------------------------

local CLAUDE = { kind = 'ai', name = 'claude' }

local function import(doc, store, o)
  local cpath = comments.path_for(r.state._path)
  return ai_review.import(doc, vim.tbl_extend('force', {
    review = r,
    hunks = hunks,
    store = store,
    events = comments.events_path_for(r.state._path),
    info = comments.review_info(r),
    author = CLAUDE,
    record_path = ai_review.record_path(cpath),
  }, o or {}))
end

local function findings_of(store)
  local out = {}
  for _, c in pairs(store.comments) do
    if not c.deleted and c.ai then
      out[#out + 1] = c
    end
  end
  table.sort(out, function(a, b)
    return a.ai.title < b.ai.title
  end)
  return out
end

h.test('import: findings become AI comments; the record, the events; bad anchors counted', function()
  local m = hunk_of('m.txt')
  local five = line_of(m, '+five')
  local cpath = comments.path_for(r.state._path)
  local store = comments.load(cpath)
  local rec = assert(import({
    summary = 'Needs work.',
    verdict = 'request changes',
    findings = {
      { hunk = m.id, line = five, severity = 'major', title = 'A: five', body = 'Why `five`?', suggestion = 'line 5' },
      { hunk = hunk_of('new.txt').id, severity = 'nit', title = 'B: new file', body = 'Needed?' },
      { hunk = 'h77', line = 1, severity = 'minor', title = 'C: ghost', body = 'x' },
    },
  }, store))
  h.eq({ 'request_changes', 2, 2, 1, 0, 0 }, { rec.verdict, rec.findings, rec.imported, rec.dropped, rec.skipped, rec.replaced })
  local list = findings_of(comments.load(cpath, { readonly = true }))
  h.eq(2, #list)
  local a = list[1]
  h.eq(CLAUDE, a.author)
  h.eq('saved', a.status)
  h.eq(false, a.in_review)
  h.eq({ 'm.txt', 'new', 5 }, { a.anchor.path, a.anchor.side, a.anchor.start_line })
  h.eq({ 'major', 'A: five', 'line 5', m.id, five, rec.id }, { a.ai.severity, a.ai.title, a.ai.suggestion, a.ai.hunk, a.ai.line, a.ai.review })
  h.eq('**A: five**\n\nWhy `five`?\n\nSuggested change:\n\n```\nline 5\n```', a.body)
  h.ok(ai_review.untriaged(a))
  h.eq(true, list[2].file_level)
  -- the record next to the comments file
  local stored = ai_review.read_record(ai_review.record_path(cpath))
  h.eq({ 'Needs work.', 'request_changes', 2, 1 }, { stored.summary, stored.verdict, stored.imported, stored.dropped })
  h.eq(guide.anchors_hash(hunks), stored.anchors)
  -- one created event per finding, by the AI
  local fd = assert(io.open(comments.events_path_for(r.state._path)))
  local evs = comments.decode_events(fd:read('*a'))
  fd:close()
  local created = vim.tbl_filter(function(ev)
    return ev.kind == 'created'
  end, evs)
  h.eq(2, #created)
  h.eq('ai', created[1].author.kind)
  -- exports and agent messages say what it is
  local export = require('revuey.comments_export')
  local md = export.markdown({ { review = comments.review_info(r), comments = { a } } })
  h.ok(md:find('(by claude (AI review); major, not triaged yet)', 1, true), md)
  local msg = export.message(a, comments.review_info(r))
  h.ok(msg:find('## Comment (claude, an AI review finding the user sent you to follow up)', 1, true), msg)
end)

h.test('re-import: untouched findings of the same author are replaced; triaged ones stay and are not imported again', function()
  local cpath = comments.path_for(r.state._path)
  local store = comments.load(cpath)
  local list = findings_of(store)
  -- the user accepts A (it becomes theirs) and dismisses nothing yet; B stays untouched
  local accepted = assert(ai_review.accept(store, list[1].id))
  h.eq({ { kind = 'user' }, 'accepted', CLAUDE }, { accepted.author, accepted.status, accepted.ai.author })
  h.eq({ nil, 'already accepted' }, { ai_review.accept(store, list[1].id) })
  h.ok(not select(1, ai_review.toggle_dismiss(store, list[1].id)), 'an accepted finding is not dismissed')
  comments.save(store)
  local m = hunk_of('m.txt')
  local five = line_of(m, '+five')
  local doc = {
    summary = 'Second look.',
    verdict = 'comment',
    findings = {
      { hunk = m.id, line = five, severity = 'major', title = 'A: five', body = 'Found again' }, -- accepted: skipped
      { hunk = m.id, line = 1, severity = 'minor', title = 'D: new one', body = 'x' },
    },
  }
  local rec = assert(import(doc, store))
  h.eq({ 1, 1, 1 }, { rec.imported, rec.skipped, rec.replaced })
  list = findings_of(comments.load(cpath, { readonly = true }))
  h.eq({ 'A: five', 'D: new one' }, vim.tbl_map(function(c)
    return c.ai.title
  end, list))
  -- dismissed findings are kept (hidden), and not imported again either; restoring works
  local d = list[2]
  local dismissed = assert(ai_review.toggle_dismiss(store, d.id))
  h.eq('dismissed', dismissed.status)
  h.eq(false, ai_review.untriaged(dismissed))
  h.eq(0, #comments.list(store) - #vim.tbl_filter(function(c)
    return c.status ~= 'dismissed'
  end, comments.list(store)), 'comments.list hides dismissed')
  rec = assert(import(doc, store))
  h.eq({ 0, 2, 0 }, { rec.imported, rec.skipped, rec.replaced })
  h.eq('saved', ai_review.toggle_dismiss(store, d.id).status, 'restored')
  -- a finding with a reply, or sent to an agent, is touched: not replaced
  comments.reply(store, d.id, 'hm', { kind = 'user' })
  rec = assert(import({ summary = '', verdict = 'approve', findings = {} }, store))
  h.eq(0, rec.replaced)
  -- another author's findings are left alone
  local other = assert(import({ summary = '', verdict = 'approve', findings = { { hunk = m.id, line = 2, severity = 'nit', title = 'E: other', body = 'x' } } }, store, { author = { kind = 'ai', name = 'other' } }))
  h.eq(1, other.imported)
  rec = assert(import({ summary = '', verdict = 'approve', findings = {} }, store))
  h.eq(0, rec.replaced, 'claude does not replace the other reviewer')
  rec = assert(import({ summary = '', verdict = 'approve', findings = {} }, store, { author = { kind = 'ai', name = 'other' } }))
  h.eq(1, rec.replaced)
end)

h.test('import: a diff hash for another diff is refused; nothing is stored', function()
  local cpath = comments.path_for(r.state._path)
  local store = comments.load(cpath)
  local before = vim.deepcopy(store.comments)
  local rec, err = import({ summary = 's', verdict = 'approve', diff = 'deadbeef', findings = { { hunk = 'h1', line = 1, severity = 'nit', title = 't', body = 'b' } } }, store)
  h.eq(nil, rec)
  h.ok(err:find('made for another diff', 1, true), err)
  h.eq(before, store.comments)
  h.ok(import({ summary = 's', verdict = 'approve', diff = guide.anchors_hash(hunks), findings = {} }, store), 'the right hash')
  h.eq({ nil, 'the review is not valid JSON' }, { import('{{{', store) })
end)

-- ---------------------------------------------------------------------------
-- Skills
-- ---------------------------------------------------------------------------

h.test('skills: by name (yours first, then the repo\'s), by path; front matter stripped; errors', function()
  local home = h.tmpdir('ai-review-home')
  h.write(home, '.claude/skills/sec/SKILL.md', '---\nname: sec\ndescription: d\n---\n\n# Security\nCheck inputs.\n')
  h.write(repo, '.claude/skills/sec/SKILL.md', 'repo version\n')
  h.write(repo, '.claude/skills/style/SKILL.md', 'Style rules.\n')
  h.write(repo, 'docs/review.md', 'Review like this.\n')
  h.write(home, '.claude/skills/empty/SKILL.md', '---\nname: empty\n---\n')
  h.eq(home .. '/.claude/skills/sec/SKILL.md', ai_review.find_skill('sec', repo, home))
  h.eq(repo .. '/.claude/skills/style/SKILL.md', ai_review.find_skill('style', repo, home))
  h.eq(repo .. '/docs/review.md', ai_review.find_skill('docs/review.md', repo, home))
  h.eq(repo .. '/.claude/skills/style/SKILL.md', ai_review.find_skill(repo .. '/.claude/skills/style', repo, home))
  local p, err = ai_review.find_skill('nope', repo, home)
  h.eq(nil, p)
  h.ok(err:find('no skill nope', 1, true), err)
  h.eq(nil, (ai_review.find_skill('./missing.md', repo, home)))
  h.eq({ 'empty', 'sec', 'style' }, ai_review.skill_names(repo, home))
  local sk = ai_review.read_skill(ai_review.find_skill('sec', repo, home))
  h.eq({ 'sec', '# Security\nCheck inputs.' }, { sk.name, sk.text })
  h.eq('review', ai_review.read_skill(repo .. '/docs/review.md').name)
  local none, e2 = ai_review.read_skill(home .. '/.claude/skills/empty/SKILL.md')
  h.eq(nil, none)
  h.ok(e2:find('is empty', 1, true), e2)
  h.write(home, '.claude/skills/huge/SKILL.md', string.rep('x', prompt.SKILL_MAX_CHARS + 1))
  none, e2 = ai_review.read_skill(home .. '/.claude/skills/huge/SKILL.md')
  h.ok(not none and e2:find('too large', 1, true), tostring(e2))
end)

-- ---------------------------------------------------------------------------
-- Review fixes: invalid documents, concurrent triage, abridged hunks, deleted findings
-- ---------------------------------------------------------------------------

h.test('validate: only a review document is accepted (prose with a stray object, {}, a guide, a findings map, an array)', function()
  local m = hunk_of('m.txt')
  local bad = {
    'Looks good. Example config: {"retries": 3}',
    '{}',
    '[]',
    vim.json.encode({ title = 'Guide', summary = 's', sections = {}, unplaced = {} }),
    vim.json.encode({ summary = 's', verdict = 'approve', findings = { a = { hunk = m.id, line = 1, severity = 'nit', title = 't', body = 'b' } } }),
    vim.json.encode({ { summary = 's', verdict = 'approve', findings = {} } }),
    vim.json.encode({ verdict = 'approve', findings = {} }),
    vim.json.encode({ summary = 's', findings = {} }),
  }
  for _, text in ipairs(bad) do
    local doc, err = ai_review.validate(text, hunks)
    h.eq(nil, doc, text)
    h.ok(type(err) == 'string' and err ~= '', text)
  end
  -- decoded tables too
  h.eq(nil, (ai_review.validate({}, hunks)))
  h.eq(nil, (ai_review.validate({ summary = 's', verdict = 'approve', findings = 'x' }, hunks)))
  -- still fine: no findings (an empty list) and an empty summary
  h.ok(ai_review.validate({ summary = '', verdict = 'approve', findings = {} }, hunks))
  h.ok(ai_review.validate('{"summary": "Clean.", "verdict": "approve", "findings": []}', hunks))
end)

h.test('import: invalid output leaves the last review and its untouched findings alone', function()
  local d = h.repo('ai-review-invalid', { ['a.txt'] = 'a\nb\nc\n' }, { ['a.txt'] = 'a\nB\nc\n' })
  local rr = assert(review_mod.load({ cwd = d, base = 'main', mode = 'committed', state_dir = state_dir }))
  local hh = review_mod.units(rr).hunks
  local cpath = comments.path_for(rr.state._path)
  local function imp(doc)
    return ai_review.import(doc, { review = rr, hunks = hh, store = comments.load(cpath), events = comments.events_path_for(rr.state._path),
      info = comments.review_info(rr), author = CLAUDE, record_path = ai_review.record_path(cpath) })
  end
  assert(imp({ summary = 'First.', verdict = 'comment', findings = { { hunk = 'h1', line = 2, severity = 'nit', title = 'Keep me', body = 'b' } } }))
  local rec, err = imp('I could not do it. Example: {"retries": 3}')
  h.eq(nil, rec)
  h.ok(err, 'an error')
  h.eq(1, #findings_of(comments.load(cpath, { readonly = true })), 'the untouched finding is still there')
  h.eq('First.', ai_review.read_record(ai_review.record_path(cpath)).summary)
end)

h.test('import: a concurrent accept in another instance is never deleted by a re-run', function()
  local d = h.repo('ai-review-race', { ['a.txt'] = 'a\nb\nc\n' }, { ['a.txt'] = 'a\nB\nc\n' })
  local rr = assert(review_mod.load({ cwd = d, base = 'main', mode = 'committed', state_dir = state_dir }))
  local hh = review_mod.units(rr).hunks
  local cpath = comments.path_for(rr.state._path)
  local function imp(doc, store, now)
    return ai_review.import(doc, { review = rr, hunks = hh, store = store, events = comments.events_path_for(rr.state._path),
      info = comments.review_info(rr), author = CLAUDE, record_path = ai_review.record_path(cpath), now = now })
  end
  local one = { summary = '', verdict = 'comment', findings = { { hunk = 'h1', line = 2, severity = 'nit', title = 'X', body = 'b' } } }
  local none = { summary = '', verdict = 'comment', findings = {} }
  assert(imp(one, comments.load(cpath)))
  local function x_of(store, title)
    for id, c in pairs(store.comments) do
      if c.ai and c.ai.title == (title or 'X') and not c.deleted then
        return id
      end
    end
  end
  -- 1. A's store is stale: B accepted and saved before A's re-run
  local A, B = comments.load(cpath), comments.load(cpath)
  local id = x_of(B)
  assert(ai_review.accept(B, id))
  comments.save(B)
  assert(imp(none, A))
  local c = comments.load(cpath, { readonly = true }).comments[id]
  h.eq({ nil, 'accepted' }, { c.deleted, c.status }, 'reloaded first: the accepted finding is not replaced')
  -- 2. B accepts in memory before A's re-run, and saves only after it: the accept still wins
  local two = { summary = '', verdict = 'comment', findings = { { hunk = 'h1', line = 1, severity = 'nit', title = 'Y', body = 'b' } } }
  assert(imp(two, comments.load(cpath)))
  B = comments.load(cpath)
  local id2 = x_of(B, 'Y')
  h.ok(id2, 'Y imported')
  local t0 = comments.now_ms()
  assert(ai_review.accept(B, id2, t0))
  assert(imp(none, comments.load(cpath), t0 + 60000))
  comments.save(B)
  c = comments.load(cpath, { readonly = true }).comments[id2]
  h.eq({ nil, 'accepted' }, { c.deleted, c.status }, 'the replacement tombstone loses to the concurrent accept')
end)

h.test('validate: lines past an abridged hunk\'s preview are dropped; with no hunk bodies findings are whole-file', function()
  local big = {}
  for k = 1, 20 do
    big[k] = '+line ' .. k
  end
  local hs = { { id = 'h1', file_idx = 1, hunk_idx = 1, path = 'f', old_path = 'f', status = 'M', header = '@@ -1 +1,20 @@', added = 20, removed = 0, text = big } }
  local doc = { summary = 's', verdict = 'comment', findings = {
    { hunk = 'h1', line = 3, severity = 'nit', title = 'shown', body = 'b' },
    { hunk = 'h1', line = 15, severity = 'nit', title = 'not shown', body = 'b' },
    { hunk = 'h1', line = 5, end_line = 12, severity = 'nit', title = 'runs past the preview', body = 'b' },
  } }
  local v, w = ai_review.validate(doc, hs, { level = 'abridged', abridged = { h1 = true } })
  h.eq({ 'shown' }, vim.tbl_map(function(f)
    return f.title
  end, v.findings))
  h.eq(2, w.bad_line)
  -- not abridged: every line counts
  v = ai_review.validate(doc, hs, { level = 'abridged', abridged = {} })
  h.eq(3, #v.findings)
  -- `files` level: the model saw no numbered lines
  v = ai_review.validate(doc, hs, { level = 'files' })
  h.eq({ nil, nil, nil }, { v.findings[1].line, v.findings[2].line, v.findings[3].line })
  -- the prompt reports which hunks it abridged
  local many = {}
  for i = 1, 400 do
    local t = {}
    for k = 1, 30 do
      t[k] = '+line ' .. k .. ' of hunk ' .. i
    end
    many[i] = { id = 'h' .. i, file_idx = i, hunk_idx = 1, path = 'f' .. i, old_path = 'f' .. i, status = 'M', header = '@@ -1 +1,30 @@', added = 30, removed = 0, text = t }
  end
  local _, info = prompt.build({ repo = 'r', branch = 'b', base = 'main' }, many, { budget = 150000 })
  h.eq('abridged', info.level)
  h.eq(info.abridged, vim.tbl_count(info.abridged_ids))
end)

h.test('a finding the user deleted is not imported again; one a re-run replaced is', function()
  local d = h.repo('ai-review-deleted', { ['a.txt'] = 'a\nb\nc\nd\ne\n' }, { ['a.txt'] = 'a\nB\nc\nD\ne\n' })
  local rr = assert(review_mod.load({ cwd = d, base = 'main', mode = 'committed', state_dir = state_dir }))
  local hh = review_mod.units(rr).hunks
  local cpath = comments.path_for(rr.state._path)
  local function imp(doc)
    return ai_review.import(doc, { review = rr, hunks = hh, store = comments.load(cpath), events = comments.events_path_for(rr.state._path),
      info = comments.review_info(rr), author = CLAUDE, record_path = ai_review.record_path(cpath) })
  end
  local doc = { summary = '', verdict = 'comment', findings = {
    { hunk = 'h1', line = 2, severity = 'nit', title = 'Deleted by you', body = 'b' },
    { hunk = 'h1', line = 4, severity = 'nit', title = 'Replaced', body = 'b' },
  } }
  assert(imp(doc))
  local store = comments.load(cpath)
  for id, c in pairs(store.comments) do
    if c.ai and c.ai.title == 'Deleted by you' then
      comments.delete(store, id)
    end
  end
  comments.save(store)
  local rec = assert(imp(doc))
  h.eq({ 1, 1, 1 }, { rec.imported, rec.skipped, rec.replaced })
  local titles = vim.tbl_map(function(c)
    return c.ai.title
  end, findings_of(comments.load(cpath, { readonly = true })))
  h.eq({ 'Replaced' }, titles)
end)

h.test('import: findings on a deleted file (old side) and a renamed file (new path) are placed', function()
  local function num(n, ed)
    local t = {}
    for i = 1, n do
      t[i] = (ed and ed[i]) or ('line ' .. i)
    end
    return table.concat(t, '\n') .. '\n'
  end
  local d = h.repo('ai-review-moves', { ['gone.txt'] = 'g1\ng2\n', ['old.txt'] = num(20) }, { ['gone.txt'] = false })
  h.git(d, 'mv', 'old.txt', 'renamed.txt')
  h.write(d, 'renamed.txt', num(20, { [10] = 'ten' }))
  h.git(d, 'commit', '-qam', 'mv')
  local rr = assert(review_mod.load({ cwd = d, base = 'main', mode = 'committed', state_dir = state_dir }))
  local hh = review_mod.units(rr).hunks
  local fs = {}
  for _, x in ipairs(hh) do
    fs[#fs + 1] = { hunk = x.id, line = 1, end_line = #x.text, severity = 'nit', title = 'all of ' .. x.path, body = 'b' }
  end
  local cpath = comments.path_for(rr.state._path)
  local store = comments.load(cpath)
  local rec = assert(ai_review.import({ summary = '', verdict = 'comment', findings = fs }, { review = rr, hunks = hh, store = store,
    events = comments.events_path_for(rr.state._path), info = comments.review_info(rr), author = CLAUDE, record_path = ai_review.record_path(cpath) }))
  h.eq({ 2, 0 }, { rec.imported, rec.dropped })
  local U = review_mod.units(rr)
  local ctx = comments.context(rr.files, U, function(path, side)
    return review_mod.side_text(rr, rr.files[U.by_path[path]], side)
  end)
  local got = {}
  for _, c in ipairs(findings_of(store)) do
    local p = comments.place(c, ctx)
    got[c.anchor.path] = { c.anchor.side, p.start_line, p.end_line, p.outdated }
  end
  h.eq({ 'old', 1, 2, false }, got['gone.txt'])
  h.eq({ 'new', 7, 13, false }, got['renamed.txt'])
end)

h.test('skills: paths are taken literally (no %, # or wildcard expansion); ~ is your home', function()
  h.write(repo, '#notes/review.md', 'Hash dir.\n')
  h.write(repo, 'a*b/review.md', 'Star dir.\n')
  h.eq(repo .. '/#notes/review.md', ai_review.find_skill('#notes/review.md', repo))
  h.eq(repo .. '/a*b/review.md', ai_review.find_skill('a*b/review.md', repo))
  local home = h.tmpdir('ai-review-home2')
  h.write(home, 'my/review.md', 'Mine.\n')
  local saved = vim.env.HOME
  vim.env.HOME = home
  local p = ai_review.find_skill('~/my/review.md', repo)
  vim.env.HOME = saved
  h.eq(home .. '/my/review.md', p)
end)

h.run()
