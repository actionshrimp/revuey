-- Unit: the comment model (comments.lua), re-anchoring, merge with tombstones, storage, export
-- formats (golden) and event serialisation. Pure data: diffs are parsed from text.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
local comments = require('revuey.comments')
local export = require('revuey.comments_export')
local diff = require('revuey.diff')
local units = require('revuey.units')

---Parse a diff of `a` -> `b` for one path (3 lines of context, like git).
local function parse(path, a, b)
  local d = vim.text.diff(a, b, { ctxlen = 3 })
  return diff.parse(('diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n'):format(path, path, path, path) .. d)
end

local function lines(n, edits)
  local t = {}
  for i = 1, n do
    t[i] = (edits and edits[i]) or ('line ' .. i)
  end
  return table.concat(t, '\n') .. '\n'
end

---A review of a -> b: files, units, placement context (full texts) and helpers.
local function review(a, b, path)
  path = path or 'f.txt'
  local files = parse(path, a, b)
  local U = units.derive(files)
  local ctx = comments.context(files, U, function(_, side)
    return side == 'new' and b or a
  end)
  ---side-table-like entries of the rows showing side lnums (first match)
  local function rows(side, first, last)
    local out = {}
    for hi, hk in ipairs(files[1].hunks) do
      for li, l in ipairs(hk.lines) do
        local n = comments.side_lnum(l, side)
        if n and n >= first and n <= last then
          out[#out + 1] = { kind = l.kind, file_idx = 1, hunk_idx = hi, line_idx = li, old_lnum = l.old_lnum, new_lnum = l.new_lnum }
        end
      end
    end
    return out
  end
  local function anchor(side, first, last)
    return comments.anchor_from_rows(files, U, rows(side, first, last), ctx.get_line)
  end
  return { files = files, U = U, ctx = ctx, rows = rows, anchor = anchor }
end

local base = lines(40)

h.test('new: fields, sortable unique ids, location', function()
  local c = comments.new({ path = 'a.ts', side = 'new', start_line = 3, end_line = 5 }, 'Body', { now = 1000 })
  h.eq('saved', c.status)
  h.eq({ kind = 'user' }, c.author)
  h.eq(false, c.in_review)
  h.eq(false, c.file_level)
  h.eq(false, c.outdated)
  h.eq({}, c.thread)
  h.eq(1000, c.created_at)
  h.eq('a.ts:3-5', comments.location(c))
  h.eq('a.ts', comments.location(comments.new(comments.file_anchor('a.ts'), 'x')))
  h.eq(true, comments.new(comments.file_anchor('a.ts'), 'x').file_level)
  local ids = {}
  for i = 1, 200 do
    ids[i] = comments.new_id(1000 + math.floor(i / 50))
  end
  local seen = {}
  for i, id in ipairs(ids) do
    h.eq(16, #id)
    h.ok(not seen[id], 'unique')
    seen[id] = true
    if i > 1 then
      h.ok(id > ids[i - 1], 'strictly increasing, also within one millisecond')
    end
  end
end)

h.test('new_id: 10k ids in one millisecond, no duplicates, still increasing (suffix carries over)', function()
  local seen, prev = {}, nil
  for _ = 1, 10000 do
    local id = comments.new_id(5000)
    h.eq(16, #id)
    h.ok(not seen[id], 'duplicate ' .. id)
    seen[id] = true
    h.ok(not prev or id > prev, 'not increasing: ' .. tostring(prev) .. ' ' .. id)
    prev = id
  end
  -- past the suffix range: carries into the milliseconds, never wraps
  local a = comments.new_id(5000)
  for _ = 1, 0x100000 - 10000 do
    comments.new_id(5000)
  end
  h.ok(comments.new_id(5000) > a, 'carry keeps order')
end)

h.test('anchor: new side for a range with a deletion inside, snippet with markers, unit and hunk', function()
  local R = review(base, lines(40, { [20] = 'twenty' }))
  -- rows 19 (ctx), the deleted 20, the added 20, 21 (ctx): side new 19..21
  local rows = R.rows('new', 19, 21)
  table.insert(rows, 2, R.rows('old', 20, 20)[1])
  local a = comments.anchor_from_rows(R.files, R.U, rows, R.ctx.get_line)
  h.eq('new', a.side)
  h.eq(19, a.start_line)
  h.eq(21, a.end_line)
  h.eq({ ' line 19', '-line 20', '+twenty', ' line 21' }, a.snippet)
  h.eq(R.U.list[1].key, a.unit_key)
  h.eq(R.U.list[1].hunk, a.hunk_key)
  h.eq(16, #a.context_hash)
  h.ok(a.hunk_line and a.unit_line, 'offsets kept')
end)

h.test('anchor: only deleted lines use the old side', function()
  local R = review(base, lines(40, { [20] = 'twenty' }))
  local a = R.anchor('old', 20, 20)
  h.eq('old', a.side)
  h.eq(20, a.start_line)
  h.eq({ '-line 20' }, a.snippet)
end)

h.test('anchor_for_lines (CLI): new-side added line; hashes like the UI, no unit or hunk keys', function()
  local R = review(base, lines(40, { [20] = 'twenty' }))
  local a, err = comments.anchor_for_lines(R.files, R.U, { path = 'f.txt', side = 'new', start_line = 20, end_line = 20 }, R.ctx.get_line)
  h.eq(nil, err)
  local ui = R.anchor('new', 20, 20)
  h.eq('new', a.side)
  h.eq({ 20, 20 }, { a.start_line, a.end_line })
  h.eq(ui.context_hash, a.context_hash)
  h.eq(ui.text_hash, a.text_hash)
  h.eq(ui.sort_line, a.sort_line)
  h.eq({ '+twenty' }, a.snippet)
  h.eq(nil, a.unit_key)
  h.eq(nil, a.hunk_key)
  h.eq(nil, a.unit_line)
  h.eq(nil, a.hunk_line)
end)

h.test('anchor_for_lines (CLI): old-side deleted line, context lines on either side, ranges', function()
  local R = review(base, lines(40, { [20] = 'twenty' }))
  local a = comments.anchor_for_lines(R.files, R.U, { path = 'f.txt', side = 'old', start_line = 20, end_line = 20 }, R.ctx.get_line)
  h.eq('old', a.side)
  h.eq({ '-line 20' }, a.snippet)
  h.eq(R.anchor('old', 20, 20).context_hash, a.context_hash)
  local c = comments.anchor_for_lines(R.files, R.U, { path = 'f.txt', side = 'new', start_line = 18, end_line = 18 }, R.ctx.get_line)
  h.eq({ ' line 18' }, c.snippet)
  h.eq(R.anchor('new', 18, 18).context_hash, c.context_hash)
  -- a new-side range keeps the deleted rows between its lines in the snippet, like a selection
  local r = comments.anchor_for_lines(R.files, R.U, { path = 'f.txt', side = 'new', start_line = 19, end_line = 21 }, R.ctx.get_line)
  h.eq({ ' line 19', '-line 20', '+twenty', ' line 21' }, r.snippet)
  -- a context line given on the old side stays on the old side
  local o = comments.anchor_for_lines(R.files, R.U, { path = 'f.txt', side = 'old', start_line = 18, end_line = 18 }, R.ctx.get_line)
  h.eq('old', o.side)
  -- file level
  local f = comments.anchor_for_lines(R.files, R.U, { path = 'f.txt' }, R.ctx.get_line)
  h.eq({ path = 'f.txt', side = 'new' }, f)
end)

h.test('anchor_for_lines (CLI): lines outside the hunks name the nearest hunks; unknown paths list changed ones', function()
  local R = review(base, lines(40, { [5] = 'five', [30] = 'thirty' }))
  local a, err = comments.anchor_for_lines(R.files, R.U, { path = 'f.txt', side = 'new', start_line = 15, end_line = 15 }, R.ctx.get_line)
  h.eq(nil, a)
  h.ok(err:find('f.txt:15 (new) is not in the diff', 1, true), err)
  h.ok(err:find('2-8', 1, true) and err:find('27-33', 1, true), err)
  h.ok(err:find('--file', 1, true), err)
  -- a range that leaves its hunk
  local _, e2 = comments.anchor_for_lines(R.files, R.U, { path = 'f.txt', side = 'new', start_line = 7, end_line = 10 }, R.ctx.get_line)
  h.ok(e2 and e2:find('f.txt:7-10 (new)', 1, true), e2)
  -- an added line on the old side
  local R2 = review(base, lines(40, { [20] = 'twenty' }))
  local _, e3 = comments.anchor_for_lines(R2.files, R2.U, { path = 'f.txt', side = 'old', start_line = 25, end_line = 25 }, R2.ctx.get_line)
  h.ok(e3 and e3:find('old 17-23', 1, true), e3)
  local _, e4 = comments.anchor_for_lines(R.files, R.U, { path = 'nope.txt', side = 'new', start_line = 1, end_line = 1 }, R.ctx.get_line)
  h.ok(e4 and e4:find('nope.txt is not a changed file in this review', 1, true) and e4:find('f.txt', 1, true), e4)
  local _, e5 = comments.anchor_for_lines(R.files, R.U, { path = 'nope.txt' }, R.ctx.get_line)
  h.ok(e5 and e5:find('not a changed file', 1, true), e5)
end)

h.test('apply_placement fills the unit and hunk of a CLI anchor (none recorded), once', function()
  local R = review(base, lines(40, { [20] = 'twenty' }))
  local a = comments.anchor_for_lines(R.files, R.U, { path = 'f.txt', side = 'new', start_line = 19, end_line = 20 }, R.ctx.get_line)
  local c = comments.new(a, 'from the agent', { author = { kind = 'agent', name = 'agent' } })
  local p = comments.place(c, R.ctx)
  h.eq('hash', p.how)
  h.eq(true, comments.apply_placement(c, p))
  local ui = R.anchor('new', 19, 20)
  h.eq(ui.unit_key, c.anchor.unit_key)
  h.eq(ui.hunk_key, c.anchor.hunk_key)
  h.eq(ui.hunk_line, c.anchor.hunk_line)
  h.eq(ui.unit_line, c.anchor.unit_line)
  h.eq('unit', comments.place(c, R.ctx).how, 'next time by unit')
  h.eq(false, comments.apply_placement(c, comments.place(c, R.ctx)))
end)

h.test('place: the same unit shifted by an edit above it (exact unit match)', function()
  local b1 = lines(40, { [20] = 'twenty' })
  local R1 = review(base, b1)
  local c = comments.new(R1.anchor('new', 20, 21), 'x')
  h.eq('unit', comments.place(c, R1.ctx).how)
  -- two lines inserted at the top of the new side: a separate hunk; the commented hunk is the same
  local b2 = 'new a\nnew b\n' .. b1
  local R2 = review(base, b2)
  local p = comments.place(c, R2.ctx)
  h.eq('unit', p.how)
  h.eq({ 22, 23, false }, { p.start_line, p.end_line, p.outdated })
  h.eq(true, comments.apply_placement(c, p))
  h.eq({ 22, 23 }, { c.anchor.start_line, c.anchor.end_line })
  h.eq(false, comments.apply_placement(c, comments.place(c, R2.ctx)), 'stable')
end)

h.test('place: moved by a change elsewhere in its hunk (context hash)', function()
  local R1 = review(base, lines(40, { [20] = 'twenty' }))
  local c = comments.new(R1.anchor('new', 20, 20), 'x')
  -- line 23 changes too: the hunk (and unit) key changes; the commented line and its context stay
  local R2 = review(base, lines(40, { [20] = 'twenty', [24] = 'twenty-four' }))
  local p = comments.place(c, R2.ctx)
  h.eq('hash', p.how)
  h.eq({ 20, 20, false }, { p.start_line, p.end_line, p.outdated })
  -- and shifted by a line inserted above inside the same hunk
  local b3 = lines(40, { [20] = 'twenty', [16] = 'line 16\ninserted' })
  local p3 = comments.place(c, review(base, b3).ctx)
  h.eq('hash', p3.how)
  h.eq(21, p3.start_line)
end)

h.test('place: outdated when the commented lines change; keeps last known lines and snippet', function()
  local R1 = review(base, lines(40, { [20] = 'twenty' }))
  local c = comments.new(R1.anchor('new', 20, 20), 'x')
  local R2 = review(base, lines(40, { [20] = 'TWENTY' }))
  local p = comments.place(c, R2.ctx)
  h.eq('outdated', p.how)
  h.eq({ 20, 20, true }, { p.start_line, p.end_line, p.outdated })
  comments.apply_placement(c, p)
  h.eq(true, c.outdated)
  h.eq({ '+twenty' }, c.anchor.snippet)
  -- a file no longer in the review
  local R3 = review(base, lines(40, { [20] = 'twenty' }), 'other.txt')
  h.eq('missing', comments.place(c, R3.ctx).how)
end)

h.test('place: deleted lines on the old side survive new-side edits', function()
  local R1 = review(base, lines(40, { [20] = 'twenty' }))
  local c = comments.new(R1.anchor('old', 20, 20), 'x')
  local b2 = 'top\n' .. lines(40, { [20] = 'twenty', [22] = 'twenty-two' })
  local p = comments.place(c, review(base, b2).ctx)
  h.eq(false, p.outdated)
  h.eq(20, p.start_line, 'the old side does not move')
end)

h.test('place: identical code at two places goes to the nearest window with the same context', function()
  -- the same three lines at 10..12 and 30..32, with different surroundings
  local a = lines(40, { [10] = 'dup a', [11] = 'dup b', [12] = 'dup c', [30] = 'dup a', [31] = 'dup b', [32] = 'dup c' })
  local b = lines(40, { [10] = 'dup a', [11] = 'DUP', [12] = 'dup c', [30] = 'dup a', [31] = 'DUP', [32] = 'dup c' })
  local R1 = review(a, b)
  local c1 = comments.new(R1.anchor('new', 30, 32), 'second')
  local c0 = comments.new(R1.anchor('new', 10, 12), 'first')
  -- an edit inside each hunk changes both hunk keys: placement is by hash
  local b2 = lines(40, { [9] = 'nine', [10] = 'dup a', [11] = 'DUP', [12] = 'dup c', [29] = 'x29', [30] = 'dup a', [31] = 'DUP', [32] = 'dup c' })
  local R2 = review(a, b2)
  -- the contexts differ (line 9 / line 29 changed): no context hash matches; the lines alone
  -- match at both places, which is ambiguous: outdated rather than possibly wrong
  local q1, q0 = comments.place(c1, R2.ctx), comments.place(c0, R2.ctx)
  h.eq({ 'outdated', 30, true }, { q1.how, q1.start_line, q1.outdated })
  h.eq({ 'outdated', 10, true }, { q0.how, q0.start_line, q0.outdated })
  -- same surroundings at both places: the window nearest to the last known line wins
  local same = lines(40, { [11] = 'DUP', [31] = 'DUP' })
  local a2 = lines(40)
  local R3 = review(a2, same)
  local d1 = comments.new(R3.anchor('new', 31, 31), 'second')
  local d0 = comments.new(R3.anchor('new', 11, 11), 'first')
  h.eq(d0.anchor.context_hash ~= d1.anchor.context_hash, true, 'line numbers 10/30 differ in context')
  -- make the contexts identical: duplicate the whole neighbourhood
  local blk = 'p\nq\nDUP\nr\ns\n'
  local nb = 'h1\n' .. blk .. 'mid1\nmid2\nmid3\nmid4\nmid5\nmid6\nmid7\nmid8\n' .. blk .. 'tail\n'
  local na = 'h1\np\nq\nold\nr\ns\nmid1\nmid2\nmid3\nmid4\nmid5\nmid6\nmid7\nmid8\np\nq\nold\nr\ns\ntail\n'
  local R4 = review(na, nb)
  local e1 = comments.new(R4.anchor('new', 17, 17), 'lower')
  local e0 = comments.new(R4.anchor('new', 4, 4), 'upper')
  h.eq(e0.anchor.context_hash, e1.anchor.context_hash)
  -- shift everything by one line and change both hunks' keys (edit next to each block)
  local nb2 = 'h0\nh1\n' .. blk .. 'MID\nmid2\nmid3\nmid4\nmid5\nmid6\nmid7\nMID8\n' .. blk .. 'tail\n'
  local R5 = review(na, nb2)
  local p1, p0 = comments.place(e1, R5.ctx), comments.place(e0, R5.ctx)
  h.eq({ 'hash', 18 }, { p1.how, p1.start_line })
  h.eq({ 'hash', 5 }, { p0.how, p0.start_line })
  h.ok(c0 and c1)
end)

h.test('place: lines at the top of an added file survive lines inserted above them (text tier)', function()
  local body = 'import { formatCurrency } from "./format";\nimport { b } from "b";\n\nexport const x = 1;\n}\n'
  local R1 = review('', body)
  local c = comments.new(R1.anchor('new', 1, 1), 'import')
  local brace = comments.new(R1.anchor('new', 5, 5), 'brace')
  h.ok(c.anchor.context_lines, 'lines with distinctive words may use the text tier')
  h.eq(nil, brace.anchor.context_lines, 'a lone brace may not')
  -- three lines prepended: one hunk (new key), and line 1's context was the file start
  local R2 = review('', '// header\n// more\n\n' .. body)
  local p = comments.place(c, R2.ctx)
  h.eq({ 'text', 4 }, { p.how, p.start_line })
  -- the brace's context (lines 3..7) is unchanged apart from the shift: the context hash finds it
  h.eq({ 'hash', 8 }, { comments.place(brace, R2.ctx).how, comments.place(brace, R2.ctx).start_line })
  -- too far away for the text tier
  local far = {}
  for i = 1, comments.TEXT_RADIUS + 5 do
    far[#far + 1] = '// filler ' .. i
  end
  local R3 = review('', table.concat(far, '\n') .. '\n' .. body)
  h.eq(true, comments.place(c, R3.ctx).outdated)
end)

-- Regression (review): the text tier anchored `end` and `return nil` to another function.
local LUA = {
  'local M = {}', 'function M.alpha(x)', '  if x then', '    return nil', '  end', '  return x', 'end', '',
  'function M.beta(y)', '  if y then', '    return nil', '  end', '  return y + 1', 'end', '', 'return M', '',
}

h.test('place: boilerplate lines (end, return nil) never use the text tier; they go outdated', function()
  local R1 = review('', table.concat(LUA, '\n'))
  local c_end = comments.new(R1.anchor('new', 7, 7), 'end of alpha')
  local c_ret = comments.new(R1.anchor('new', 4, 4), 'return nil in alpha')
  h.eq(nil, c_end.anchor.context_lines, 'no text tier for `end`')
  h.eq(nil, c_ret.anchor.context_lines, 'keywords are not distinctive words')
  -- alpha is removed: beta has the same lines
  local without = { 'local M = {}', '' }
  for i = 9, #LUA do
    without[#without + 1] = LUA[i]
  end
  local R2 = review('', table.concat(without, '\n'))
  for _, c in ipairs({ c_end, c_ret }) do
    local p = comments.place(c, R2.ctx)
    h.eq(true, p.outdated, c.body .. ' -> ' .. tostring(p.how) .. ' ' .. tostring(p.start_line))
    local before = c.anchor.start_line
    comments.apply_placement(c, p)
    h.eq({ before, true }, { c.anchor.start_line, c.outdated }, 'last known line kept')
  end
end)

h.test('place: a distinctive line repeated within the radius is ambiguous (outdated); unique, it moves', function()
  local function file(top, copies)
    local t = vim.deepcopy(top)
    for i = 1, 30 do
      t[#t + 1] = (i % 2 == 0) and '}' or '  call()'
      if copies[i] then
        t[#t + 1] = 'log.debug("checkpoint reached")'
      end
    end
    return table.concat(t, '\n') .. '\n'
  end
  local base = file({}, {})
  local R1 = review(base, file({}, { [5] = true, [25] = true }))
  local c = comments.new(R1.anchor('new', 27, 27), 'second copy')
  h.ok(c.anchor.context_lines, 'distinctive')
  -- an edit right above the second copy changes its context and its hunk
  local edited = vim.split(file({}, { [5] = true, [25] = true }), '\n')
  edited[25] = '  call(changed)'
  local R2 = review(base, table.concat(edited, '\n'))
  local p = comments.place(c, R2.ctx)
  h.eq(true, p.outdated, "two copies within the radius: ambiguous " .. tostring(p.how))
  -- a single copy: the same edit re-anchors it (text tier, with part of the context matching)
  local R3 = review(base, file({}, { [25] = true }))
  local one = comments.new(R3.anchor('new', 26, 26), 'only copy')
  local e3 = vim.split(file({}, { [25] = true }), '\n')
  e3[25] = '  call(changed)'
  table.insert(e3, 1, 'inserted at the top')
  local p3 = comments.place(one, review(base, table.concat(e3, '\n')).ctx)
  h.eq({ 'text', 27, false }, { p3.how, p3.start_line, p3.outdated })
end)

h.test('place: the text tier needs part of the old context around the new place', function()
  local R1 = review('', 'alpha\nbravo\nconst totalPrice = items.sum();\ncharlie\ndelta\n')
  local c = comments.new(R1.anchor('new', 3, 3), 'x')
  h.ok(c.anchor.context_lines)
  -- the line moved somewhere with entirely new surroundings
  local R2 = review('', 'one\ntwo\nthree\nfour\nfive\nsix\nconst totalPrice = items.sum();\nseven\neight\n')
  h.eq(true, comments.place(c, R2.ctx).outdated)
  -- one neighbour kept
  local R3 = review('', 'one\nbravo\nconst totalPrice = items.sum();\nnew\nother\n')
  h.eq({ 'text', 3 }, { comments.place(c, R3.ctx).how, comments.place(c, R3.ctx).start_line })
end)

h.test('place: a comment follows its file when it is renamed', function()
  local b1 = lines(40, { [20] = 'twenty' })
  local R1 = review(base, b1, 'f.txt')
  local c = comments.new(R1.anchor('new', 20, 20), 'x')
  local b2 = lines(40, { [20] = 'twenty', [30] = 'thirty' })
  local d = vim.text.diff(base, b2, { ctxlen = 3 })
  local files = diff.parse('diff --git a/f.txt b/g.txt\nsimilarity index 90%\nrename from f.txt\nrename to g.txt\n--- a/f.txt\n+++ b/g.txt\n' .. d)
  h.eq({ 'R', 'g.txt', 'f.txt' }, { files[1].status, files[1].path, files[1].old_path })
  local U = units.derive(files)
  local ctx = comments.context(files, U, function(_, side)
    return side == 'new' and b2 or base
  end)
  local p = comments.place(c, ctx)
  h.eq({ false, 20, 'g.txt' }, { p.outdated, p.start_line, p.path })
  comments.apply_placement(c, p)
  h.eq('g.txt', c.anchor.path)
end)

h.test('order: by file, then new-side position; deleted lines sit where their hunk puts them', function()
  -- line 30 deleted, two lines added at 25..26 instead (new side shifts by -4 after line 25)
  local a = lines(40)
  local t = vim.split(a, '\n')
  for i = 26, 30 do
    t[i] = nil
  end
  local b = {}
  for i = 1, 40 do
    if t[i] then
      b[#b + 1] = t[i]
    end
  end
  local R = review(a, table.concat(b, '\n') .. '\n')
  local old30 = comments.new(R.anchor('old', 30, 30), 'deleted 30')
  local new20 = comments.new(R.anchor('new', 25, 25), 'new 25')
  local new26 = comments.new(R.anchor('new', 26, 26), 'new 26 (was 31)')
  local S = { comments = {}, _dirty = {} }
  for _, c in ipairs({ old30, new26, new20 }) do
    comments.put(S, c)
  end
  h.eq({ 'new 25', 'deleted 30', 'new 26 (was 31)' }, vim.tbl_map(function(c)
    return c.body
  end, comments.list(S)))
  -- and after re-anchoring (the position is kept up to date)
  local p = comments.place(old30, R.ctx)
  comments.apply_placement(old30, p)
  h.eq(old30.anchor.sort_line, comments.place(old30, R.ctx).sort_line)
end)

h.test('events: snippets are capped (with a marker)', function()
  local big = {}
  for i = 1, 500 do
    big[i] = '+line ' .. i
  end
  local c = comments.new({ path = 'a', side = 'new', start_line = 1, end_line = 500, snippet = big }, 'x')
  local ev = comments.event('created', c, {})
  h.eq(comments.EVENT_SNIPPET_MAX + 1, #ev.snippet)
  h.ok(ev.snippet[#ev.snippet]:find('300 more lines', 1, true), ev.snippet[#ev.snippet])
  h.eq(comments.EVENT_SNIPPET_MAX + 1, #ev.anchor.snippet)
  h.eq(500, #c.anchor.snippet, 'the comment itself keeps all of it')
end)

h.test('merge: last writer wins per comment; replies merge by id; tombstones beat older edits', function()
  local c = comments.new({ path = 'a', side = 'new', start_line = 1, end_line = 1 }, 'v1', { now = 100, id = 'c1' })
  local a = vim.deepcopy(c)
  a.body, a.updated_at = 'edited in A', 200
  local b = vim.deepcopy(c)
  b.body, b.updated_at = 'edited in B', 300
  h.eq('edited in B', comments.merge(a, b).body)
  h.eq('edited in B', comments.merge(b, a).body)
  -- a reply in A (older) survives B's later body edit
  a.thread = { { id = 'r1', author = { kind = 'agent' }, body = 'reply', created_at = 150, updated_at = 150 } }
  local m = comments.merge(a, b)
  h.eq('edited in B', m.body)
  h.eq({ 'r1' }, vim.tbl_map(function(r)
    return r.id
  end, m.thread))
  -- delete (newer) vs edit (older): the tombstone wins
  local t = { id = 'c1', deleted = true, updated_at = 400 }
  h.eq(true, comments.merge(t, b).deleted)
  h.eq(true, comments.merge(b, t).deleted)
  -- edit newer than the delete: the edit wins
  local late = vim.deepcopy(b)
  late.updated_at = 500
  h.eq('edited in B', comments.merge(t, late).body)
  -- ties: the preferred side
  local x, y = vim.deepcopy(c), vim.deepcopy(c)
  x.body, y.body = 'x', 'y'
  h.eq('x', comments.merge(x, y, true).body)
  h.eq('y', comments.merge(x, y, false).body)
end)

h.test('storage: two instances editing different comments, and edit versus delete, merge on save', function()
  local dir = h.tmpdir('comments-store')
  local path = comments.path_for(dir .. '/repo-feat-main-abc.json')
  h.eq(dir .. '/repo-feat-main-abc.comments.json', path)
  local A = comments.load(path)
  local c1 = comments.new({ path = 'a', side = 'new', start_line = 1, end_line = 1 }, 'one')
  comments.put(A, c1)
  comments.save(A, { repo = '/r', branch = 'feat', base = 'main' })
  local B = comments.load(path)
  h.eq('one', comments.get(B, c1.id).body)
  -- A adds c2, B adds c3: both survive
  local c2 = comments.new({ path = 'a', side = 'new', start_line = 2, end_line = 2 }, 'two')
  local c3 = comments.new({ path = 'b', side = 'old', start_line = 3, end_line = 3 }, 'three')
  comments.put(A, c2)
  comments.put(B, c3)
  comments.save(A)
  comments.save(B)
  comments.save(A)
  h.eq(3, #comments.list(A))
  h.eq(3, #comments.list(B))
  h.eq('/r', A.review.repo, 'the review info is kept')
  -- B deletes c1 after A edits it: the delete wins everywhere
  local e = vim.deepcopy(comments.get(A, c1.id))
  e.body = 'one, edited'
  comments.put(A, e, comments.now_ms())
  comments.save(A)
  comments.delete(B, c1.id, comments.now_ms() + 10)
  comments.save(B)
  comments.save(A)
  h.eq(nil, comments.get(A, c1.id))
  h.eq(true, A.comments[c1.id].deleted, 'a tombstone stays')
  -- reload picks up another instance's change
  local r = comments.reply(B, c2.id, 'agent reply', { kind = 'agent', name = 'claude' })
  h.ok(r)
  comments.save(B)
  h.eq(true, comments.reload(A))
  h.eq('agent reply', comments.get(A, c2.id).thread[1].body)
  h.eq(false, comments.reload(A), 'nothing new')
  -- a corrupt file is moved aside, not overwritten silently
  local fd = assert(io.open(path, 'w'))
  fd:write('{nope')
  fd:close()
  h.eq(nil, comments.read(path))
  h.eq(1, #vim.fn.glob(path .. '.corrupt-*', false, true))
end)

h.test('find: full id, unique prefix or substring', function()
  local S = { comments = {}, _dirty = {} }
  local c1 = comments.new({ path = 'a', side = 'new', start_line = 1, end_line = 1 }, 'x', { id = '0000000000aabbb1' })
  local c2 = comments.new({ path = 'a', side = 'new', start_line = 1, end_line = 1 }, 'y', { id = '0000000000aaccc2' })
  comments.put(S, c1)
  comments.put(S, c2)
  h.eq(c1, (comments.find(S, '0000000000aabbb1')))
  h.eq(c2, (comments.find(S, 'ccc2')))
  local none, err = comments.find(S, 'aa')
  h.eq(nil, none)
  h.ok(err:find('ambiguous'), err)
end)

-- export -------------------------------------------------------------------------------------

local function sample()
  local S = { comments = {}, _dirty = {}, path = '' }
  local review = { repo = '/home/u/shop', branch = 'feature/cart', base = 'main', scope = 'branch', merge_base = '1f2ed75d0123456789' }
  local c1 = comments.new({
    path = 'src/cart.ts',
    side = 'new',
    start_line = 12,
    end_line = 14,
    snippet = { ' export function total(items: Item[]) {', '-  return sum(items);', '+  return sum(items.map(price));', '+  // TODO: tax' },
  }, 'Should this round to cents?\n\nAlso `price` may be undefined.', { id = '00000000001000001', now = 1 })
  c1.thread = { { id = 'r1', author = { kind = 'agent', name = 'claude' }, body = 'Good catch, will fix.', created_at = 2, updated_at = 2 } }
  local c2 = comments.new({ path = 'src/math.ts', side = 'old', start_line = 3, end_line = 3, snippet = { '-  return a + b; // ```' } }, 'Why remove this?', { id = '00000000002000002', now = 2 })
  c2.outdated = true
  local c3 = comments.new(comments.file_anchor('README.md'), 'Docs need an update.', { id = '00000000003000003', now = 3 })
  local c4 = comments.new({ path = 'src/a.ts', side = 'new', start_line = 1, end_line = 1, snippet = { '+x' } }, 'Done', { id = '00000000004000004', now = 4 })
  c4.status = 'resolved'
  for _, c in ipairs({ c1, c2, c3, c4 }) do
    comments.put(S, c)
  end
  return S, review
end

h.test('export markdown (golden): header, ordered comments, code with markers, replies, outdated', function()
  local S, review = sample()
  local md = export.markdown({ { review = review, comments = export.select(S) } })
  local want = [[
# Review comments: feature/cart → main

- Repo: shop (/home/u/shop)
- Branch: feature/cart
- Scope: branch
- Base: main (merge-base 1f2ed75d)

3 comments, ordered by file and line. Each gives the file, the line range and side (new: the code after the change, old: the code before it), the diff lines it is about, and the reviewer's note.

## 1. README.md (whole file)

Docs need an update.

## 2. src/cart.ts:12-14 (new)

```diff
 export function total(items: Item[]) {
-  return sum(items);
+  return sum(items.map(price));
+  // TODO: tax
```

Should this round to cents?

Also `price` may be undefined.

Replies:
- **claude**: Good catch, will fix.

## 3. src/math.ts:3 (old) (outdated: the code changed since this comment was made)

````diff
-  return a + b; // ```
````

Why remove this?
]]
  h.eq(want, md)
end)

h.test('export markdown: resolved comments only with all; stack scope wording; no comments', function()
  local S, review = sample()
  local md = export.markdown({ { review = review, comments = export.select(S, { all = true }) } })
  h.ok(md:find('## 2. src/a.ts:1 (new) (resolved)', 1, true), md)
  h.ok(md:find('4 comments', 1, true), md)
  review.scope, review.layers = 'full', { 'stack/math', 'stack/cart' }
  h.ok(export.markdown({ { review = review, comments = {} } }):find('- Scope: full stack (stack/math, stack/cart)\n- Base: main (merge-base 1f2ed75d)\n\nNo comments.', 1, true))
  review.scope, review.branch, review.parent = 'layer', 'stack/cart', 'stack/math'
  h.ok(export.markdown({ { review = review, comments = {} } }):find('- Scope: stack layer stack/cart on stack/math', 1, true))
end)

h.test('export json: the full data, decodable', function()
  local S, review = sample()
  local out = export.json({ { review = review, comments = export.select(S, { all = true }) } })
  local data = vim.json.decode(out)
  h.eq(1, data.version)
  h.eq('feature/cart', data.reviews[1].review.branch)
  h.eq(4, #data.reviews[1].comments)
  local c = data.reviews[1].comments[3]
  h.eq('src/cart.ts', c.anchor.path)
  h.eq('claude', c.thread[1].author.name)
  h.eq(false, c.in_review)
  h.eq('saved', c.status)
  h.eq(true, data.reviews[1].comments[4].outdated)
  h.eq('resolved', data.reviews[1].comments[2].status)
end)

h.test('events: serialisation, one-line summaries, rotation', function()
  local S, review = sample()
  local c1 = comments.get(S, '00000000001000001')
  local ev = comments.event('created', c1, review, nil, 5000)
  local back = vim.json.decode(vim.json.encode(ev))
  h.eq('created', back.kind)
  h.eq(c1.id, back.comment_id)
  h.eq(12, back.anchor.start_line)
  h.eq(c1.anchor.snippet, back.snippet)
  h.eq(c1.body, back.body)
  h.eq('feature/cart', back.review.branch)
  h.eq('comment src/cart.ts:12-14 (new): Should this round to cents?  #00000000001000001', comments.event_line(ev))
  local rep = comments.event('replied', c1, review, { reply = c1.thread[1] })
  h.eq('reply src/cart.ts:12-14 (new) from claude: Good catch, will fix.  #00000000001000001', comments.event_line(rep))
  local c3 = comments.get(S, '00000000003000003')
  h.eq('delete README.md (file): Docs need an update.  #00000000003000003', comments.event_line(comments.event('deleted', c3, review)))
  h.ok(not pcall(comments.event, 'bogus', c1, review))
  -- append, decode, rotate
  local dir = h.tmpdir('comments-events')
  local path = dir .. '/x.events.jsonl'
  local saved = comments.EVENTS_MAX
  comments.EVENTS_MAX = 2000
  for i = 1, 6 do
    h.ok(comments.append_event(path, comments.event('updated', c1, review, nil, 6000 + i)))
  end
  comments.EVENTS_MAX = saved
  h.ok(vim.uv.fs_stat(path .. '.1'), 'rotated')
  local fd = assert(io.open(path))
  local evs = comments.decode_events(fd:read('*a'))
  fd:close()
  h.ok(#evs >= 1 and #evs < 6, #evs)
  h.eq('updated', evs[1].kind)
end)

h.run()
