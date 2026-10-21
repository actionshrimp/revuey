-- Working-tree mode edge cases: odd untracked files, size caps, refresh races, cursor restore.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')
require('revuey').setup({ state_dir = h.tmpdir('edge-state'), lsp_warmup = false })
local view = require('revuey.view')
local review_mod = require('revuey.review')
local state = require('revuey.state')
local git = require('revuey.git')

local function sh(cmd, cwd)
  local r = vim.system({ 'sh', '-c', cmd }, { cwd = cwd, text = true }):wait()
  assert(r.code == 0, cmd .. ': ' .. (r.stderr or ''))
  return r.stdout
end

local function by_path(review)
  local t = {}
  for _, f in ipairs(review.files) do
    t[f.path] = f
  end
  return t
end

local function load(d, extra)
  return assert(review_mod.load(vim.tbl_extend('force', { cwd = d, base = 'main' }, extra or {})))
end

local function row_of(s, path, needle)
  for row, e in ipairs(s.layout.map) do
    local f = s.review.files[e.file_idx]
    if f and f.path == path and e.kind ~= 'meta' and s.layout.lines[row]:find(needle, 1, true) then
      return row
    end
  end
end

local function idle(s)
  vim.wait(5000, function()
    return not s.refreshing and not s.pending
  end, 10)
  vim.wait(50)
  vim.wait(5000, function()
    return not s.refreshing and not s.pending
  end, 10)
end

-- ---------------------------------------------------------------------------
-- Untracked files of every kind (review items 1, 5, 7 and the requested coverage)
-- ---------------------------------------------------------------------------

local odd = h.repo('odd', { ['a.txt'] = 'a\n', ['target.txt'] = 'target content\n' }, {})
h.write(odd, 'b.txt', 'hello\n')
h.write(odd, 'run.sh', '#!/bin/sh\n')
vim.uv.fs_chmod(odd .. '/run.sh', tonumber('755', 8))
h.write(odd, 'dir with space/ünï.txt', 'u\n')
h.write(odd, 'bin.dat', 'PNG\0\1\2')
h.write(odd, '.gitignore', '*.log\n')
h.write(odd, 'ign.log', 'ignored\n')
sh('ln -s nowhere dead && ln -s target.txt link && mkdir sub && cd sub && git init -q && echo hi > f', odd)

h.test('untracked: dangling symlink and nested repo do not break hashing of the rest', function()
  local f = by_path(load(odd))
  for _, p in ipairs({ 'b.txt', 'run.sh', 'dir with space/ünï.txt', 'bin.dat', '.gitignore' }) do
    h.ok(f[p], 'missing ' .. p)
    h.eq(git.hash_objects({ p }, odd)[1], f[p].new_blob, p)
  end
  h.eq(nil, f['ign.log'], 'ignored files are not shown')
  h.ok(f['sub/'] or f['sub'], 'nested repo listed')
  local nested = f['sub/'] or f['sub']
  h.eq(0, #nested.hunks)
  h.ok(nested.note and nested.note:find('repository', 1, true), tostring(nested.note))
  h.eq(true, f['bin.dat'].binary)
  h.eq('u', f['dir with space/ünï.txt'].hunks[1].lines[1].text)
end)

h.test('untracked symlinks show and hash the link text, like git', function()
  local f = by_path(load(odd))
  h.eq('target.txt', f.link.hunks[1].lines[1].text)
  h.eq(true, f.link.hunks[1].lines[1].no_eol)
  h.eq(vim.trim(sh('printf target.txt | git hash-object --stdin', odd)), f.link.new_blob)
  h.eq(vim.trim(sh('printf nowhere | git hash-object --stdin', odd)), f.dead.new_blob)
  h.eq('120000', f.link.new_mode)
end)

h.test('untracked modes: regular, executable, symlink; marks survive git add', function()
  local f = by_path(load(odd))
  h.eq('100644', f['b.txt'].new_mode)
  h.eq('100755', f['run.sh'].new_mode)
  local r = load(odd)
  review_mod.toggle_reviewed(r, by_path(r)['b.txt'])
  sh('git add b.txt', odd)
  local r2 = load(odd)
  h.eq(true, review_mod.is_reviewed(r2, by_path(r2)['b.txt']), 'mark kept after git add')
  sh('git reset -q b.txt', odd)
end)

h.test('untracked mark invalidates on edit even with a dangling symlink around', function()
  local r = load(odd)
  local b = by_path(r)['b.txt']
  h.ok(state.content_key(b):find(b.new_blob, 1, true), state.content_key(b))
  if not review_mod.is_reviewed(r, b) then
    review_mod.toggle_reviewed(r, b)
  end
  h.write(odd, 'b.txt', 'CHANGED totally\n')
  local r2 = load(odd)
  h.eq(false, review_mod.is_reviewed(r2, by_path(r2)['b.txt']))
end)

-- ---------------------------------------------------------------------------
-- Size cap and no-op refreshes (item 4)
-- ---------------------------------------------------------------------------

h.test('files over the size cap are shown as a placeholder without reading them', function()
  local d = h.repo('big', { ['t.txt'] = 'small\n' }, {})
  local big = string.rep('0123456789abcdef\n', 80000) -- ~1.3MB
  h.write(d, 'big.log.txt', big)
  h.write(d, 't.txt', big)
  local reads = 0
  local orig = git.read_file
  git.read_file = function(p, ...)
    reads = reads + 1
    return orig(p, ...)
  end
  local f = by_path(load(d))
  git.read_file = orig
  for _, p in ipairs({ 'big.log.txt', 't.txt' }) do
    h.eq(0, #f[p].hunks, p)
    h.ok(f[p].note and f[p].note:find('not shown', 1, true), tostring(f[p].note))
    h.eq(nil, f[p].new_text)
    h.ok(f[p].new_blob, 'still hashed for reviewed marks')
  end
  h.eq(0, reads, 'large files are never read')
end)

h.test('no-op refresh re-reads and re-hashes nothing', function()
  local d = h.repo('many', { ['a.txt'] = 'a\n' }, {})
  for i = 1, 300 do
    h.write(d, ('u/f%03d.txt'):format(i), 'x' .. i .. '\n')
  end
  local cache = {}
  load(d, { cache = cache })
  local reads, hashes = 0, 0
  local o1, o2 = git.read_file, git.hash_objects
  git.read_file = function(...)
    reads = reads + 1
    return o1(...)
  end
  git.hash_objects = function(p, ...)
    hashes = hashes + #p
    return o2(p, ...)
  end
  local r = load(d, { cache = cache })
  h.eq(0, reads)
  h.eq(0, hashes)
  h.write(d, 'u/f007.txt', 'changed\n')
  r = load(d, { cache = cache })
  git.read_file, git.hash_objects = o1, o2
  h.eq(1, reads, 'only the changed file is read')
  h.eq(1, hashes)
  h.eq('changed', by_path(r)['u/f007.txt'].hunks[1].lines[1].text)
end)

-- Regression (re-review 2): clean filters (lfs, ident, custom) make disk differ from the diff.
h.test('clean-filtered files: one load, snapshot equals the diff new side', function()
  local d = h.repo('filter', { ['a.txt'] = 'hello\n', ['plain.md'] = 'p\n' }, {})
  sh('git config filter.up.clean "tr a-z A-Z" && git config filter.up.smudge cat', d)
  h.write(d, '.gitattributes', '*.txt filter=up\n')
  sh('git add .gitattributes && git commit -qm attrs', d)
  h.write(d, 'a.txt', 'hello\nworld\n')
  h.write(d, 'plain.md', 'p\nq\n')
  local loads = 0
  local orig = review_mod.load
  review_mod.load = function(...)
    loads = loads + 1
    return orig(...)
  end
  local f = by_path(load(d))
  review_mod.load = orig
  h.eq(1, loads, 'no reload-once retry for filtered files')
  local shown = {}
  for _, l in ipairs(f['a.txt'].hunks[1].lines) do
    shown[#shown + 1] = l.text
  end
  h.eq('HELLO\nWORLD\n', f['a.txt'].new_text, vim.inspect(shown))
  h.eq('p\nq\n', f['plain.md'].new_text, 'unfiltered files still snapshot from disk')
end)

-- Regression (re-review 3): caches don't keep entries for paths that left the review.
h.test('load cache is pruned of paths no longer in the review', function()
  local d = h.repo('prune', { ['a.txt'] = 'a\n' }, {})
  h.write(d, 'a.txt', 'a\nb\n')
  h.write(d, 'u.txt', 'u\n')
  local cache = {}
  load(d, { cache = cache })
  h.ok(cache.snap['a.txt'] and cache.untracked['u.txt'], vim.inspect(vim.tbl_keys(cache)))
  h.write(d, 'a.txt', 'a\n') -- back to committed content: leaves the review
  vim.fn.delete(d .. '/u.txt')
  load(d, { cache = cache })
  h.eq(nil, cache.snap['a.txt'])
  h.eq(nil, cache.untracked['u.txt'])
end)

h.test('no merge-base gives a clear error', function()
  local d = h.repo('orphan', { a = 'a\n' }, {})
  sh('git checkout -q --orphan lonely && git commit -qm o', d)
  local r, err = review_mod.load({ cwd = d, base = 'main' })
  h.eq(nil, r)
  h.ok(err:find('no common ancestor', 1, true) and not err:find('nil', 1, true), err)
end)

-- ---------------------------------------------------------------------------
-- Refresh races (items 2, 6) and cursor restore (items 3, 9)
-- ---------------------------------------------------------------------------

local d = h.repo('race', { ['a.txt'] = 'a\n', ['m.txt'] = 'm\n', ['z.txt'] = 'z\n' }, {})
h.write(d, 'm2.txt', 'u1\nu2\nu3\n')
local s = h.open_review({ cwd = d })

h.test('an error mid-refresh is reported and does not wedge auto-refresh', function()
  local orig = git.changed_vs_head
  git.changed_vs_head = function()
    error('boom')
  end
  local msgs, restore = h.capture_notify()
  view.refresh()
  vim.wait(2000, function()
    return not s.refreshing
  end, 10)
  restore()
  git.changed_vs_head = orig
  h.eq(false, s.refreshing == true, 'refreshing flag cleared')
  local found = false
  for _, m in ipairs(msgs) do
    found = found or (m.msg:find('boom', 1, true) ~= nil)
  end
  h.ok(found, vim.inspect(msgs))
  h.write(d, 'z.txt', 'z\nAFTER ERROR\n')
  view.refresh()
  idle(s)
  h.ok(row_of(s, 'z.txt', 'AFTER ERROR'), 'later refresh works')
end)

h.test('coalescing: requests during a refresh produce exactly one more load', function()
  local loads = 0
  local orig = review_mod.load
  review_mod.load = function(...)
    loads = loads + 1
    return orig(...)
  end
  view.refresh()
  for _ = 1, 5 do
    view.refresh()
  end
  vim.api.nvim_exec_autocmds('FocusGained', {})
  idle(s)
  review_mod.load = orig
  h.eq(2, loads)
end)

h.test('gu twice during an in-flight refresh ends in the original mode', function()
  local orig = git.untracked
  git.untracked = function(c)
    git.system({ 'sleep', '0.2' })
    return orig(c)
  end
  view.refresh()
  view.toggle_mode()
  view.toggle_mode()
  idle(s)
  git.untracked = orig
  h.eq('worktree', s.review.mode)
end)

h.test('a save during an in-flight refresh is picked up', function()
  local orig = git.untracked
  git.untracked = function(c)
    git.system({ 'sleep', '0.2' })
    return orig(c)
  end
  view.refresh()
  h.write(d, 'z.txt', 'z\nSAVED DURING REFRESH\n')
  vim.api.nvim_exec_autocmds('FocusGained', {})
  idle(s)
  git.untracked = orig
  h.ok(row_of(s, 'z.txt', 'SAVED DURING REFRESH'))
end)

h.test('inserting lines above the cursor keeps it on the same content', function()
  local lines = {}
  for i = 1, 40 do
    lines[i] = 'line ' .. i
  end
  h.write(d, 'm.txt', table.concat(lines, '\n') .. '\n')
  view.refresh()
  idle(s)
  vim.api.nvim_set_current_win(s.diff_win)
  local row = row_of(s, 'm.txt', 'line 32')
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 2 })
  table.insert(lines, 28, 'INS1')
  table.insert(lines, 28, 'INS2')
  h.write(d, 'm.txt', table.concat(lines, '\n') .. '\n')
  view.refresh()
  idle(s)
  local cur = vim.api.nvim_win_get_cursor(s.diff_win)
  h.eq('line 32', s.layout.lines[cur[1]])
  h.eq(2, cur[2])
end)

h.test('when the cursor file disappears, the cursor moves to the next file', function()
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_win_set_cursor(s.diff_win, { row_of(s, 'm2.txt', 'u3'), 0 })
  vim.fn.delete(d .. '/m2.txt')
  view.refresh()
  idle(s)
  local r = vim.api.nvim_win_get_cursor(s.diff_win)[1]
  local e = s.layout.map[r]
  h.eq('z.txt', s.review.files[e.file_idx].path)
  h.eq('file', e.meta)
end)

h.test('re-entering the diff notices new untracked files', function()
  local n = s.render_count
  h.write(d, 'new/deep/x.txt', 'x\n')
  vim.cmd('split')
  vim.cmd('enew')
  vim.cmd('close')
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_exec_autocmds('BufEnter', { buffer = s.diff_buf })
  vim.wait(3000, function()
    return s.render_count > n
  end, 10)
  idle(s)
  h.ok(row_of(s, 'new/deep/x.txt', 'x'), 'new file shown')
end)

h.test('closing during a refresh is clean', function()
  local orig = git.untracked
  git.untracked = function(c)
    git.system({ 'sleep', '0.2' })
    return orig(c)
  end
  local msgs, restore = h.capture_notify()
  view.refresh()
  view.close()
  vim.wait(600)
  restore()
  git.untracked = orig
  h.eq({}, msgs)
  h.eq(nil, view.session)
end)

h.run()
