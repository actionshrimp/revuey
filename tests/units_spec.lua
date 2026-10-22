-- Unit: review units (units.lua). Derivation and keys, derived file/section state, nested marks
-- (unit, parent hunk, file), legacy file and section marks, and a synthetic unit split so the
-- planned hunk-splitting feature is covered before it exists. No UI.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
local diff = require('revuey.diff')
local guide = require('revuey.guide')
local state = require('revuey.state')
local units = require('revuey.units')

local function blob(c)
  return string.rep(c, 40)
end

---Build `git diff` text: files = { {path, hunks = { {header, lines...} }, binary?, old?, new?, raw?} }
local function difftext(files)
  local out = {}
  for _, f in ipairs(files) do
    if f.raw then
      vim.list_extend(out, f.raw)
    else
      out[#out + 1] = ('diff --git a/%s b/%s'):format(f.path, f.path)
      if f.binary then
        out[#out + 1] = 'index ' .. blob('a') .. '..' .. blob('b') .. ' 100644'
        out[#out + 1] = ('Binary files a/%s and b/%s differ'):format(f.path, f.path)
      else
        out[#out + 1] = 'index ' .. (f.old or blob('a')) .. '..' .. (f.new or blob('b')) .. ' 100644'
        out[#out + 1] = '--- a/' .. f.path
        out[#out + 1] = '+++ b/' .. f.path
        for _, hk in ipairs(f.hunks) do
          vim.list_extend(out, hk)
        end
      end
    end
  end
  return table.concat(out, '\n') .. '\n'
end

local A1 = { '@@ -1,3 +1,3 @@ function a', ' one', '-two', '+TWO', ' three' }
local A2 = { '@@ -10,2 +10,3 @@', ' ten', '+ten and a half', ' eleven' }
local A3 = { '@@ -20,1 +21,1 @@', '-x', '+y' }

local function base_files()
  return diff.parse(difftext({
    { path = 'src/a.ts', new = blob('1'), hunks = { A1, A2, A3 } },
    { path = 'src/b.ts', new = blob('2'), hunks = { { '@@ -1,1 +1,1 @@', '-x', '+y' } } },
    { path = 'logo.png', binary = true },
    { raw = {
      'diff --git a/old.ts b/new.ts',
      'similarity index 100%',
      'rename from old.ts',
      'rename to new.ts',
    } },
    { raw = {
      'diff --git a/run.sh b/run.sh',
      'old mode 100644',
      'new mode 100755',
    } },
    { raw = {
      'diff --git a/moved.ts b/moved2.ts',
      'similarity index 80%',
      'rename from moved.ts',
      'rename to moved2.ts',
      'index ' .. blob('c') .. '..' .. blob('d') .. ' 100644',
      '--- a/moved.ts',
      '+++ b/moved2.ts',
      '@@ -1,1 +1,1 @@',
      '-p',
      '+q',
    } },
  }))
end

local function keys_of(list)
  return vim.tbl_map(function(u)
    return u.key
  end, list)
end

local seq = 0
local function fresh_state(name)
  seq = seq + 1
  return state.load(h.tmpdir('units-' .. name .. seq), '/repo', 'feat', 'main')
end

h.test('derive: one unit per hunk, keyed like the guide hunk ids; files without hunks get a file unit', function()
  local files = base_files()
  h.eq({ 'src/a.ts', 'src/b.ts', 'logo.png', 'new.ts', 'run.sh', 'moved2.ts' }, vim.tbl_map(function(f)
    return f.path
  end, files))
  files[#files + 1] = diff.placeholder('big.bin', 'File too large (2 MB), not shown', blob('e'))
  local U = units.derive(files)
  local hs = guide.hunks(files)
  h.eq(#hs, #U.list, 'today one unit per guide hunk entry')
  for i, gh in ipairs(hs) do
    local u = U.list[i]
    h.eq(gh.hash, u.key, 'unit key = guide hunk hash')
    h.eq(gh.hash, u.hunk, 'parent hunk key')
    h.eq({ u }, U.by_hunk[gh.hash])
    h.eq(gh.file_idx, u.file_idx)
    h.eq(files[gh.file_idx].path, u.path)
  end
  h.eq(3, #U.by_file[1])
  h.eq({ false, false, false }, vim.tbl_map(function(u)
    return u.whole_file
  end, U.by_file[1]))
  -- binary, pure rename, mode-only change and a placeholder: one whole-file unit each
  for _, p in ipairs({ 'logo.png', 'new.ts', 'run.sh', 'big.bin' }) do
    local fi = U.by_path[p]
    h.eq(1, #U.by_file[fi], p)
    h.eq(true, U.by_file[fi][1].whole_file, p)
  end
  -- a rename with changes: hunk units under the new path; the key has the path in it
  local mv = U.by_file[U.by_path['moved2.ts']]
  h.eq(1, #mv)
  h.eq(false, mv[1].whole_file)
  h.eq('moved2.ts', mv[1].path)
  -- the file content key is recorded for file-level marks (old side too with key_old)
  h.eq(state.content_key(files[1]), U.by_file[1][1].file_key)
  local Uo = units.derive(files, { key_old = true })
  h.eq(state.content_key(files[1], true), Uo.by_file[1][1].file_key)
  h.eq(keys_of(U.list), keys_of(Uo.list), 'unit keys do not depend on the scope')
  -- lookups by file and hunk index
  h.eq(U.by_file[1][2].key, U.hunk_key[1][2])
  h.eq(U.by_file[3][1].key, U.hunk_key[3][0])
end)

h.test('derive: identical hunks get distinct keys; shifting a unique hunk keeps its key', function()
  local d = { { path = 'x.ts', hunks = {
    { '@@ -1,1 +1,1 @@', '-a', '+b' },
    { '@@ -9,1 +9,1 @@', '-a', '+b' },
    { '@@ -20,1 +20,1 @@', '-c', '+d' },
  } } }
  local U = units.derive(diff.parse(difftext(d)))
  local k = keys_of(U.list)
  h.ok(k[1] ~= k[2])
  h.ok(k[1]:find('@1,1$'), k[1])
  h.ok(not k[3]:find('@', 1, true))
  d[1].hunks[3] = { '@@ -22,1 +22,1 @@', '-c', '+d' }
  h.eq(k[3], units.derive(diff.parse(difftext(d))).list[3].key)
end)

h.test('derived state: units, file progress, file and section reviewed', function()
  local files = base_files()
  local U = units.derive(files)
  local st = fresh_state('derived')
  local a = U.by_file[1]
  h.eq({ 0, 3 }, { units.progress(st, a) })
  h.eq(false, units.file_reviewed(st, U, 1))
  assert(units.set(st, U, { a[1] }, true))
  h.eq({ 1, 3 }, { units.file_progress(st, U, 1) })
  h.eq(false, units.file_reviewed(st, U, 1))
  h.eq(false, state.is_reviewed(st, 'src/a.ts', state.content_key(files[1])), 'no file mark while partial')
  assert(units.set(st, U, { a[2], a[3] }, true))
  h.eq(true, units.file_reviewed(st, U, 1))
  -- a complete file also gets a file-level mark (layer stats read those from `git diff --raw`)
  h.eq(true, state.is_reviewed(st, 'src/a.ts', state.content_key(files[1])))
  -- a section is reviewed when all its units are: section = a[3] + b.ts
  local sec = { items = { { hunk = U.hunks[3] }, { hunk = U.hunks[4] } } }
  h.eq({ 1, 2 }, { units.progress(st, units.section_units(U, sec)) })
  assert(units.set(st, U, units.section_units(U, sec), true))
  h.eq({ 2, 2 }, { units.progress(st, units.section_units(U, sec)) })
  h.eq(true, units.file_reviewed(st, U, 2))
  -- persisted
  local again = state.load(vim.fs.dirname(st._path), '/repo', 'feat', 'main')
  h.eq(true, units.file_reviewed(again, U, 1))
  h.eq(true, units.file_reviewed(again, U, 2))
  -- unmarking one unit of a complete file drops the file mark, keeps the others
  assert(units.set(again, U, { a[2] }, false))
  h.eq({ 2, 3 }, { units.file_progress(again, U, 1) })
  h.eq(false, state.is_reviewed(again, 'src/a.ts', state.content_key(files[1])))
  -- whole-file units are file marks, as before
  local bin = U.by_file[3][1]
  assert(units.set(again, U, { bin }, true))
  h.eq(true, state.is_reviewed(again, 'logo.png', state.content_key(files[3])))
  h.eq(nil, again.units[bin.key], 'no unit mark for a whole-file unit')
  assert(units.set(again, U, { bin }, false))
  h.eq(false, units.file_reviewed(again, U, 3))
end)

h.test('toggle: any unreviewed unit marks all; all reviewed unmarks all', function()
  local U = units.derive(base_files())
  local st = fresh_state('toggle')
  local a = U.by_file[1]
  assert(units.set(st, U, { a[1] }, true))
  h.eq(true, (units.toggle(st, U, a)))
  h.eq({ 3, 3 }, { units.progress(st, a) })
  h.eq(false, (units.toggle(st, U, a)))
  h.eq({ 0, 3 }, { units.progress(st, a) })
end)

h.test('editing one hunk invalidates only that unit', function()
  local files = base_files()
  local U = units.derive(files)
  local st = fresh_state('edit')
  assert(units.set(st, U, U.by_file[1], true))
  h.eq(true, units.file_reviewed(st, U, 1))
  local edited = diff.parse(difftext({
    { path = 'src/a.ts', new = blob('9'), hunks = { A1, { '@@ -10,2 +10,3 @@', ' ten', '+ten and three quarters', ' eleven' }, A3 } },
  }))
  local U2 = units.derive(edited)
  local st2 = state.load(vim.fs.dirname(st._path), '/repo', 'feat', 'main')
  h.eq({ true, false, true }, vim.tbl_map(function(u)
    return units.reviewed(st2, u)
  end, U2.by_file[1]))
  h.eq({ 2, 3 }, { units.file_progress(st2, U2, 1) })
end)

h.test('concurrent instances merge unit marks on save', function()
  local U = units.derive(base_files())
  local st = fresh_state('merge')
  local dir = vim.fs.dirname(st._path)
  local a = U.by_file[1]
  local other = state.load(dir, '/repo', 'feat', 'main')
  assert(units.set(st, U, { a[1] }, true))
  assert(units.set(other, U, { a[2] }, true))
  local c = state.load(dir, '/repo', 'feat', 'main')
  h.eq({ true, true, false }, vim.tbl_map(function(u)
    return units.reviewed(c, u)
  end, a))
  assert(units.set(st, U, { a[1] }, false))
  c = state.load(dir, '/repo', 'feat', 'main')
  h.eq({ false, true, false }, vim.tbl_map(function(u)
    return units.reviewed(c, u)
  end, a), "unmark in one instance keeps the other's mark")
end)

-- The state file format before units: file marks by content key, guide sections by identity.
-- `KEY_A` is the content key of src/a.ts in base_files(); `SEC` is the identity of a section
-- holding src/a.ts's third hunk and src/b.ts's hunk (guide.section_id of their hashes).
local LEGACY = [[
{"version":1,"repo":"/repo","branch":"feat","base":"main",
 "files":{"src/a.ts":{"key":"1111111111111111111111111111111111111111","reviewed_at":1700000000},
          "logo.png":{"key":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","reviewed_at":1700000000}},
 "sections":{"%s":{"reviewed_at":1700000000}}}
]]

local function legacy_state(name, sec_id)
  local st = fresh_state(name)
  vim.fn.mkdir(vim.fs.dirname(st._path), 'p')
  local fd = assert(io.open(st._path, 'w'))
  fd:write(LEGACY:format(sec_id or 'snone'))
  fd:close()
  return state.load(vim.fs.dirname(st._path), '/repo', 'feat', 'main')
end

h.test('legacy file marks: honoured as all units, converted to unit marks, survive a one-hunk edit', function()
  local files = base_files()
  local U = units.derive(files)
  local st = legacy_state('legacy-files')
  h.eq(true, units.file_reviewed(st, U, 1), 'old file mark counts as every unit reviewed')
  h.eq(true, units.file_reviewed(st, U, 3), 'binary file mark as before')
  h.eq(false, units.file_reviewed(st, U, 2))
  h.eq(true, units.migrate(st, U), 'conversion needed')
  h.eq(false, units.migrate(st, U), 'idempotent')
  local raw = vim.json.decode(table.concat(vim.fn.readfile(st._path), '\n'))
  for _, u in ipairs(U.by_file[1]) do
    h.ok(raw.units[u.key], 'unit mark written for ' .. u.key)
  end
  h.ok(raw.files['src/a.ts'], 'the file mark stays (complete file)')
  -- now an edit to one hunk only resets that hunk
  local edited = diff.parse(difftext({
    { path = 'src/a.ts', new = blob('9'), hunks = { A1, A2, { '@@ -20,1 +21,1 @@', '-x', '+z' } } },
  }))
  local U2 = units.derive(edited)
  local st2 = state.load(vim.fs.dirname(st._path), '/repo', 'feat', 'main')
  h.eq({ 2, 3 }, { units.file_progress(st2, U2, 1) })
end)

h.test('legacy file mark with a stale content key counts for nothing', function()
  local files = diff.parse(difftext({ { path = 'src/a.ts', new = blob('7'), hunks = { A1, A2, A3 } } }))
  local U = units.derive(files)
  local st = legacy_state('legacy-stale')
  h.eq(false, units.file_reviewed(st, U, 1))
  h.eq(false, units.migrate(st, U))
end)

h.test('legacy guide section marks become unit marks', function()
  local files = base_files()
  local U = units.derive(files)
  local sec_id = guide.section_id({ U.hunks[3].hash, U.hunks[4].hash })
  local st = legacy_state('legacy-sections', sec_id)
  local res = { sections = {
    { id = sec_id, items = { { hunk = U.hunks[3] }, { hunk = U.hunks[4] } } },
    { id = guide.section_id({ U.hunks[8].hash }), items = { { hunk = U.hunks[8] } } },
  } }
  h.eq(true, units.migrate_sections(st, U, res.sections))
  h.eq(false, units.migrate_sections(st, U, res.sections), 'section mark consumed')
  h.eq(true, units.file_reviewed(st, U, 2), 'b.ts: its only unit was in the section')
  local again = state.load(vim.fs.dirname(st._path), '/repo', 'feat', 'main')
  h.eq(nil, again.sections and again.sections[sec_id], 'converted section mark removed')
  h.eq({ 2, 2 }, { units.progress(again, units.section_units(U, res.sections[1])) })
  h.eq({ 0, 1 }, { units.progress(again, units.section_units(U, res.sections[2])) })
  -- unmarking a unit afterwards is not undone by a later conversion
  assert(units.set(again, U, { U.by_file[2][1] }, false))
  units.migrate_sections(again, U, res.sections)
  h.eq(false, units.reviewed(again, U.by_file[2][1]))
end)

-- Synthetic split: cut every hunk of src/a.ts into single-line pieces (what the planned splitting
-- feature will do at tree-sitter or blank-line boundaries).
local function split_lines(_, hk)
  if #hk.lines < 2 then
    return nil
  end
  local cuts = {}
  for i = 1, #hk.lines, 2 do
    cuts[#cuts + 1] = { first = i, last = math.min(i + 1, #hk.lines) }
  end
  return cuts
end

h.test('split units: pieces keyed by content, a whole-hunk mark covers every piece across re-splits', function()
  local files = base_files()
  local U = units.derive(files, { split = split_lines })
  local gh = U.hunks[1] -- A1: 4 lines -> 2 pieces
  local pieces = U.by_hunk[gh.hash]
  h.eq(2, #pieces)
  h.eq({ gh.hash, gh.hash }, { pieces[1].hunk, pieces[2].hunk })
  h.ok(pieces[1].key ~= pieces[2].key and pieces[1].key ~= gh.hash)
  h.eq({ 1, 2, 3, 4 }, { pieces[1].first, pieces[1].last, pieces[2].first, pieces[2].last })
  h.eq(pieces[2], units.at_line(U, 1, 1, 3))
  local st = fresh_state('split')
  -- one piece: the hunk is partly reviewed
  assert(units.set(st, U, { pieces[1] }, true))
  h.eq({ 1, 2 }, { units.progress(st, pieces) })
  h.eq(nil, st.units[gh.hash])
  -- the last piece completes the hunk: the parent hunk key is stored too
  assert(units.set(st, U, { pieces[2] }, true))
  h.ok(st.units[gh.hash], 'hunk-level mark')
  -- a different split of the same hunk keeps it reviewed (and so does no split at all)
  local U2 = units.derive(files, { split = function(_, hk)
    return #hk.lines >= 2 and { { first = 1, last = 1 }, { first = 2, last = #hk.lines } } or nil
  end })
  h.eq({ 2, 2 }, { units.progress(st, U2.by_hunk[gh.hash]) })
  h.eq({ 1, 1 }, { units.progress(st, units.derive(files).by_hunk[gh.hash]) })
  -- unmarking one piece under a hunk mark keeps its sibling
  assert(units.set(st, U2, { U2.by_hunk[gh.hash][1] }, false))
  h.eq(nil, st.units[gh.hash])
  h.eq({ false, true }, vim.tbl_map(function(u)
    return units.reviewed(st, u)
  end, U2.by_hunk[gh.hash]))
  -- editing one piece invalidates only that piece
  local edited = diff.parse(difftext({
    { path = 'src/a.ts', new = blob('9'), hunks = { { '@@ -1,3 +1,3 @@ function a', ' one', '-two', '+TWO!', ' three' }, A2, A3 } },
  }))
  local Ue = units.derive(edited, { split = split_lines })
  local st2 = fresh_state('split-edit')
  assert(units.set(st2, U, U.by_file[1], true))
  local reviewed = vim.tbl_map(function(u)
    return units.reviewed(st2, u)
  end, Ue.by_file[1])
  -- A1's first piece (" one", "-two") is unchanged; its second ("+TWO!", " three") changed
  h.eq(true, reviewed[1])
  h.eq(false, reviewed[2])
end)

h.test('marking a file with split hunks stores hunk-level marks', function()
  local files = base_files()
  local U = units.derive(files, { split = split_lines })
  local st = fresh_state('split-file')
  assert(units.set(st, U, U.by_file[1], true))
  for _, gh in ipairs(U.hunks) do
    if gh.file_idx == 1 then
      h.ok(st.units[gh.hash], 'hunk mark for ' .. gh.id)
    end
  end
end)

-- Two instances of the same review (two Neovims): marks merge per key on save, and the coverage
-- marks (parent hunk key, file mark) are derived from the merged result, never from one
-- instance's stale memory.
local function reviewed_list(st, list)
  return vim.tbl_map(function(u)
    return units.reviewed(st, u)
  end, list)
end

local function two(name)
  local dir = vim.fs.dirname(fresh_state(name)._path)
  return function()
    return state.load(dir, '/repo', 'feat', 'main')
  end
end

h.test("two instances: an unmark is not undone by the other instance's file mark", function()
  local U = units.derive(base_files())
  local a = U.by_file[1]
  local ld = two('two-s1')
  local A, B = ld(), ld()
  assert(units.set(B, U, { a[1] }, true))
  assert(units.set(A, U, { a[2] }, true)) -- A's save reads B's mark
  assert(units.set(A, U, { a[3] }, true)) -- A completes the file: file mark stored
  h.eq(true, units.file_reviewed(ld(), U, 1))
  assert(units.set(B, U, { a[1] }, false)) -- B never saw the file mark
  h.eq({ false, true, true }, reviewed_list(ld(), a))
  h.eq(false, units.migrate(ld(), U), 'nothing for migration to bring back')
  h.eq({ false, true, true }, reviewed_list(ld(), a))
end)

h.test("two instances: a stale completion never stores a file mark over the other's unmark", function()
  local U = units.derive(base_files())
  local a = U.by_file[1]
  local ld = two('two-s2')
  local A = ld()
  assert(units.set(A, U, a, true))
  local B = ld()
  assert(units.set(A, U, { a[2] }, false))
  assert(units.set(B, U, { a[3] }, false))
  assert(units.set(B, U, { a[3] }, true)) -- B still thinks a[2] is reviewed
  h.eq({ true, false, true }, reviewed_list(ld(), a))
  h.eq(false, state.is_reviewed(ld(), 'src/a.ts', a[1].file_key))
end)

h.test('two instances: each marking part of a file completes it, with its file mark', function()
  local U = units.derive(base_files())
  local a = U.by_file[1]
  local ld = two('two-s3')
  local A, B = ld(), ld()
  assert(units.set(A, U, { a[1], a[2] }, true))
  assert(units.set(B, U, { a[3] }, true))
  local c = ld()
  h.eq(true, units.file_reviewed(c, U, 1))
  h.eq(true, state.is_reviewed(c, 'src/a.ts', a[1].file_key), 'file mark for layer stats')
  h.eq(true, state.is_reviewed(B, 'src/a.ts', a[1].file_key), 'the saving instance sees it too')
end)

h.test('marks of content not shown for 30 days are pruned on save; recent ones are kept', function()
  local U = units.derive(base_files())
  local a = U.by_file[1]
  local st = fresh_state('prune')
  local old = os.time() - 40 * 86400
  st.units = {
    stale = { path = 'gone.ts', reviewed_at = old },
    recent = { path = 'other-mode.ts', reviewed_at = os.time() - 86400 },
    [a[2].key] = { path = 'src/a.ts', reviewed_at = old },
  }
  st._unit_changes = vim.deepcopy(st.units)
  state.save(st)
  st = state.load(vim.fs.dirname(st._path), '/repo', 'feat', 'main')
  assert(units.set(st, U, { a[1] }, true))
  local raw = vim.json.decode(table.concat(vim.fn.readfile(st._path), '\n')).units
  h.eq(nil, raw.stale, 'not shown for 40 days: pruned')
  h.ok(raw.recent, 'another mode or scope, shown recently: kept')
  h.ok(raw[a[2].key].seen_at >= os.time() - 5, 'shown now: kept, seen_at refreshed')
  h.eq(true, units.reviewed(st, a[2]))
end)

-- Regression (r11): working-tree and committed mode share a state file. A hunk reviewed long ago
-- but shown recently must keep its mark when the other mode (where an edit changed that hunk)
-- marks something: showing a review refreshes `seen_at`, not just marking.
h.test('showing a review keeps its old marks from being pruned by the other mode', function()
  local function mk(new, l)
    return diff.parse(difftext({ { path = 'a.ts', new = new, hunks = {
      { '@@ -1,1 +1,1 @@', '-x', '+' .. l },
      { '@@ -9,1 +9,1 @@', '-y', '+Y' },
    } } }))
  end
  local committed = units.derive(mk(blob('1'), 'X'))
  local worktree = units.derive(mk(blob('2'), 'X-edited'))
  local st = fresh_state('r11')
  local dir = vim.fs.dirname(st._path)
  assert(units.set(st, committed, committed.list, true))
  local raw = vim.json.decode(table.concat(vim.fn.readfile(st._path), '\n'))
  for _, e in pairs(raw.units) do
    e.reviewed_at = e.reviewed_at - 40 * 86400
  end
  vim.fn.writefile({ vim.json.encode(raw) }, st._path)
  -- the committed-mode review is shown (rendered): its marks are seen now, saved once
  local c = state.load(dir, '/repo', 'feat', 'main')
  h.eq(true, (units.touch(c, committed)))
  h.eq(false, (units.touch(c, committed)), 'at most one save per day')
  -- the working tree (hunk 1 edited) marks something: the committed mark of hunk 1 survives
  local w = state.load(dir, '/repo', 'feat', 'main')
  assert(units.set(w, worktree, { worktree.list[1] }, true))
  local back = state.load(dir, '/repo', 'feat', 'main')
  h.eq({ true, true }, reviewed_list(back, committed.list))
end)

h.test('migrating a legacy file mark over split hunks stores each piece too', function()
  local files = base_files()
  local U = units.derive(files, { split = split_lines })
  local st = legacy_state('legacy-split')
  assert(units.migrate(st, U))
  local again = state.load(vim.fs.dirname(st._path), '/repo', 'feat', 'main')
  for _, u in ipairs(U.by_file[1]) do
    h.ok(again.units[u.key], 'piece ' .. u.key)
    h.ok(again.units[u.hunk], 'hunk ' .. u.hunk)
  end
  -- editing one piece keeps the other pieces of that hunk
  local edited = diff.parse(difftext({
    { path = 'src/a.ts', new = blob('9'), hunks = { { '@@ -1,3 +1,3 @@ function a', ' one', '-two', '+TWO!', ' three' }, A2, A3 } },
  }))
  local Ue = units.derive(edited, { split = split_lines })
  h.eq({ true, false }, reviewed_list(again, Ue.by_hunk[Ue.hunks[1].hash]))
end)

h.run()
