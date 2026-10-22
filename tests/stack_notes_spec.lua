-- Unit: stack note classification, grouping, panel summary lines, the details listing, and the
-- ignore list (glob matching, suggestions, persistence and merging).
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
local sn = require('revuey.stack_notes')
local ign = require('revuey.stack_ignore')

local ctx = { stack = true, trunk = 'main', key = '!' }

local function new(kind, fields)
  return sn.new(kind, fields, ctx)
end

h.test('classification: only notes that change the diff shown are warnings', function()
  local warn = {}
  for _, k in ipairs(sn.ORDER) do
    if sn.KINDS[k].level == 'warn' then
      warn[#warn + 1] = k
    end
  end
  h.eq({ 'not_restacked', 'squashed', 'stale_parent', 'unknown_parent', 'cycle', 'newer_copy', 'outside' }, warn)
  h.eq('info', sn.level(new('outdated_copy', { branch = 'x', layer = 'a' })))
  h.eq('warn', sn.level(new('not_restacked', { branch = 'b', parent = 'a', at = '1234abcd' })))
  -- only informational notes about branches outside the stack can be ignored, never warnings
  local ignorable = {}
  for _, k in ipairs(sn.ORDER) do
    if sn.ignorable({ kind = k }) then
      ignorable[#ignorable + 1] = k
    end
  end
  h.eq({ 'outdated_copy', 'other_copy', 'side', 'same_commit' }, ignorable)
  -- every kind has a plain text, an impact and a title
  for _, k in ipairs(sn.ORDER) do
    local n = new(k, { branch = 'b', layer = 'a', parent = 'a', at = 'abc', branches = { 'x', 'y' }, source = 'config', count = 2 })
    h.ok(type(n.text) == 'string' and #n.text > 10 and not n.text:find('rewritten', 1, true), k)
    h.ok(#sn.KINDS[k].impact({ n }, ctx) > 10, k)
  end
end)

h.test('wording: plain sentences, no jargon', function()
  local n = new('outdated_copy', { branch = 'dave/abc-1058-apply-price-check', layer = 'stack/a' })
  h.eq("dave/abc-1058-apply-price-check contains an older version of a commit that's now in your stack (it was amended or rebased since). It may be built on an outdated copy of your stack.", n.text)
  local lone = sn.new('outdated_copy', { branch = 'x', layer = 'b' }, { stack = false, trunk = 'main' })
  h.ok(lone.text:find('your branch', 1, true), lone.text)
end)

h.test('grouping: by kind, in display order, branches sorted', function()
  local notes = {
    new('outdated_copy', { branch = 'z', layer = 'a' }),
    new('landed', { branch = 'a' }),
    new('outdated_copy', { branch = 'm', layer = 'a' }),
    new('not_restacked', { branch = 'b', parent = 'a', at = '1' }),
  }
  local g = sn.groups(notes)
  h.eq({ 'not_restacked', 'outdated_copy', 'landed' }, vim.tbl_map(function(x)
    return x.kind
  end, g))
  h.eq({ 'm', 'z' }, vim.tbl_map(function(n)
    return n.branch
  end, g[2].notes))
end)

h.test('summary: 0, 1 and many notes; related kinds share a line; ignored count', function()
  h.eq({}, sn.summary({}, {}, ctx))
  h.eq({ { glyph = '⚠', text = 'stack/b not restacked on stack/a', level = 'warn' } },
    sn.summary({ new('not_restacked', { branch = 'stack/b', parent = 'stack/a', at = '1' }) }, {}, ctx))
  h.eq({ { glyph = '●', text = 'stack/a looks landed in main', level = 'info' } }, sn.summary({ new('landed', { branch = 'stack/a' }) }, {}, ctx))
  local related = {
    new('outdated_copy', { branch = 'x', layer = 'a' }),
    new('other_copy', { branch = 'y', layer = 'a' }),
    new('side', { branch = 'z', layer = 'a' }),
  }
  h.eq({ { glyph = '○', text = '3 related branches outside this stack (2 ignored)', level = 'info' } },
    sn.summary(related, { { branch = 'p', kind = 'side' }, { branch = 'q', kind = 'outdated_copy' } }, ctx))
  h.eq({ { glyph = '⚠', text = 'y shares commits with a', level = 'warn' } }, sn.summary({ new('outside', { branch = 'y', layer = 'a' }) }, {}, ctx))
  h.eq('1 related branch', sn.summary({ related[1] }, {}, { stack = false, trunk = 'main' })[1].text)
  -- many kinds: warnings first, capped at 3 lines with a pointer to the details
  local many = vim.list_extend({
    new('landed', { branch = 'stack/a' }),
    new('not_restacked', { branch = 'stack/b', parent = 'stack/a', at = '1' }),
    new('not_restacked', { branch = 'stack/c', parent = 'stack/b', at = '2' }),
    new('fork', { branch = 'stack/c', branches = { 'd', 'e' } }),
  }, related)
  h.eq({
    { glyph = '⚠', text = '2 layers not restacked', level = 'warn' },
    { glyph = '○', text = '3 related branches outside this stack', level = 'info' },
    { glyph = '…', text = '2 more: press ! for details', level = 'info' },
  }, sn.summary(many, {}, ctx))
  h.eq(4, #sn.summary(many, {}, ctx, 4))
end)

h.test('filter: the ignore list hides only related-branch notes', function()
  local notes = {
    new('outdated_copy', { branch = 'dave/old-1', layer = 'a' }),
    new('same_commit', { branch = 'dave/old-2', layer = 'a' }),
    new('landed', { branch = 'dave/old-3' }),
    new('outside', { branch = 'keep', layer = 'a' }),
    new('outside', { branch = 'dave/old-warn', layer = 'a' }),
    new('newer_copy', { branch = 'dave/old-newer', layer = 'a' }),
  }
  local shown, ignored = sn.filter(notes, { 'dave/old-*', 'keep' })
  h.eq({ 'dave/old-3', 'keep', 'dave/old-warn', 'dave/old-newer' }, vim.tbl_map(function(n)
    return n.branch
  end, shown))
  h.eq({ { branch = 'dave/old-1', kind = 'outdated_copy', pattern = 'dave/old-*' }, { branch = 'dave/old-2', kind = 'same_commit', pattern = 'dave/old-*' } }, ignored)
end)

h.test('actions per note kind', function()
  local function ids(n)
    return vim.tbl_map(function(a)
      return a.id
    end, sn.actions(n))
  end
  h.eq({ 'ignore', 'pattern' }, ids(new('outdated_copy', { branch = 'dave/abc-1058-x', layer = 'a' })))
  h.eq('dave/abc-1058-*', sn.actions(new('outdated_copy', { branch = 'dave/abc-1058-x', layer = 'a' }))[2].pattern)
  -- set as parent only where the setting would hold; warnings can't be ignored
  h.eq({}, ids(new('outside', { branch = 'old', layer = 'stack/a' })))
  local p = sn.actions(new('outside', { branch = 'old', layer = 'stack/a', parent_ok = true }))[1]
  h.eq({ 'parent', 'stack/a', 'old' }, { p.id, p.branch, p.parent })
  h.eq({}, ids(new('newer_copy', { branch = 'x', layer = 'a' })))
  h.eq({ 'ignore', 'pattern' }, ids(new('other_copy', { branch = 'x', layer = 'a' })))
  h.eq({ 'clear' }, ids(new('stale_parent', { branch = 'b', parent = 'a', source = 'config' })))
  h.eq({}, ids(new('stale_parent', { branch = 'b', parent = 'a', source = 'graphite' })))
  h.eq({}, ids(new('not_restacked', { branch = 'b', parent = 'a', at = '1' })))
  h.eq({}, ids(new('landed', { branch = 'a' })))
end)

h.test('details: every note in full, wrapped to the width, grouped, with branch rows', function()
  local notes = {
    new('outdated_copy', { branch = 'dave/abc-1058-apply-price-check', layer = 'stack/a' }),
    new('outdated_copy', { branch = 'dave/abc-1061-cleanup', layer = 'stack/a' }),
    new('not_restacked', { branch = 'stack/b', parent = 'stack/a', at = '1234abcd' }),
    new('fork', { branch = 'stack/c', branches = { 'd', 'e' } }),
  }
  local m = sn.details(notes, { { branch = 'dave/x', kind = 'outside', pattern = 'dave/x*' } },
    { { pattern = 'dave/x*', source = 'repo' }, { pattern = 'old/*', source = 'config' } }, ctx, 50)
  for _, l in ipairs(m.lines) do
    h.ok(vim.fn.strdisplaywidth(l) <= 50, l)
  end
  local text = table.concat(m.lines, '\n')
  h.ok(text:find('⚠ Not restacked', 1, true), text)
  h.ok(text:find('Affects this review', 1, true), text)
  h.ok(text:find("Doesn't affect this review", 1, true), text)
  h.ok(text:find('○ Built on an outdated copy of your stack', 1, true), text)
  h.ok(text:find('These branches contain older versions', 1, true), text)
  h.ok(text:find('Ignored branches', 1, true), text)
  -- branch rows: the two old branches (with ignore actions), the stack/b row, fork children, patterns
  -- (a detail too long for the branch's line wraps below it; those lines act on the same entry)
  local rows, seen = {}, {}
  for row = 1, #m.lines do
    local e = m.rows[row]
    if e and not seen[e] then
      seen[e] = true
      rows[#rows + 1] = { row, e.branch or e.pattern_entry.pattern, #e.actions }
    end
  end
  h.eq({ 'stack/b', 'dave/abc-1058-apply-price-check', 'dave/abc-1061-cleanup', 'd', 'e', 'dave/x*', 'old/*' }, vim.tbl_map(function(r)
    return r[2]
  end, rows))
  h.eq({ 0, 2, 2, 0, 0, 1, 0 }, vim.tbl_map(function(r)
    return r[3]
  end, rows))
  h.eq('x ignore  X pattern', m.hints[rows[2][1]])
  h.eq({ ' No notes about this stack.' }, sn.details({}, {}, {}, ctx, 50).lines)
  -- a branch name longer than the width wraps instead of being cut off
  local long = 'dävé/ブランチ-' .. string.rep('x', 70)
  local w = sn.details({ new('outdated_copy', { branch = long, layer = 'a' }) }, {}, {}, ctx, 40)
  local joined, entry_rows = '', 0
  for row, l in ipairs(w.lines) do
    h.ok(vim.fn.strdisplaywidth(l) <= 40, l)
    if w.rows[row] then
      entry_rows = entry_rows + 1
      joined = joined .. vim.trim(l)
    end
  end
  h.ok(joined:find(long, 1, true), vim.inspect(w.lines))
  h.ok(entry_rows >= 3, 'every wrapped line acts on the branch')
end)

h.test('ignore globs: matching and suggestions', function()
  h.eq('dave/old-*', ign.match({ 'x', 'dave/old-*' }, 'dave/old-thing'))
  h.eq('**/x', ign.match({ '**/x' }, 'x'))
  h.eq('**/x', ign.match({ '**/x' }, 'a/b/x'))
  h.eq(nil, ign.match({ '**/x' }, 'ax'))
  h.eq('dave/*', ign.match({ 'dave/*' }, 'dave/a/b'), '* crosses /')
  h.eq(nil, ign.match({ 'dave/old-*' }, 'dave/new-thing'))
  h.eq(nil, ign.match({ 'dave/old' }, 'dave/old-thing'), 'anchored')
  h.eq('a.b', ign.match({ 'a.b' }, 'a.b'))
  h.eq(nil, ign.match({ 'a.b' }, 'axb'), 'dots are literal')
  h.eq('fix-?', ign.match({ 'fix-?' }, 'fix-1'))
  h.eq('feat/(x)%', ign.match({ 'feat/(x)%' }, 'feat/(x)%'))
  h.eq('dave/abc-1058-*', ign.suggest('dave/abc-1058-apply-price-check'))
  h.eq('dave/old-*', ign.suggest('dave/old-thing'))
  -- never as broad as `<user>/*`, and no broader than the last separator without a ticket number
  h.eq('dave/x', ign.suggest('dave/x'))
  h.eq('feature', ign.suggest('feature'))
  h.eq('a/b/c-d-*', ign.suggest('a/b/c-d-e'))
  h.eq('dave/old-*', ign.suggest('dave/old-'))
  h.eq(2, ign.count('dave/*', { 'dave/a', 'dave/b/c', 'x' })) -- shown in the X prompt when over 3
end)

h.test('ignore list: persisted per repo, merged with concurrent changes and the config', function()
  local dir = h.tmpdir('ignore-state')
  local repo = '/tmp/some/repo/.git'
  h.eq({}, ign.read(dir, repo))
  ign.update(dir, repo, { add = { 'a/*' } })
  -- another instance adds a pattern in between: both survive
  ign.update(dir, repo, { add = { 'b/*' } })
  ign.update(dir, repo, { add = { 'a/*' } })
  h.eq({ 'a/*', 'b/*' }, ign.read(dir, repo))
  ign.update(dir, repo, { remove = { 'a/*' } })
  h.eq({ 'b/*' }, ign.read(dir, repo))
  -- per repo
  h.eq({}, ign.read(dir, '/tmp/other/.git'))
  -- config first, then the repo's, deduplicated
  h.eq({ { pattern = 'b/*', source = 'config' }, { pattern = 'c', source = 'config' } }, ign.effective({ 'b/*', 'c' }, dir, repo))
  ign.update(dir, repo, { add = { 'd' } })
  h.eq({ 'c', 'b/*', 'd' }, ign.patterns(ign.effective({ 'c' }, dir, repo)))
  -- unreadable file: kept as a backup, empty list, and the next update starts afresh
  h.write(vim.fs.dirname(ign.file_for(dir, repo)), vim.fs.basename(ign.file_for(dir, repo)), '{not json')
  h.eq({}, ign.read(dir, repo))
  h.eq(1, #vim.fn.glob(ign.file_for(dir, repo) .. '.corrupt-*', false, true))
  h.eq({ 'e' }, ign.update(dir, repo, { add = { 'e' } }))
  h.eq('stack-ignore-repo-', vim.fs.basename(ign.file_for(dir, repo)):sub(1, 18))
end)

h.run()
