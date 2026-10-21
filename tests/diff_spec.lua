local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
local diff = require('revuey.diff')

local Z = string.rep('0', 40)
local A1 = string.rep('a', 40)
local B1 = string.rep('b', 40)

local sample = table.concat({
  'diff --git a/src/math.ts b/src/math.ts',
  'index ' .. A1 .. '..' .. B1 .. ' 100644',
  '--- a/src/math.ts',
  '+++ b/src/math.ts',
  '@@ -1,4 +1,5 @@ export function add',
  ' line1',
  '-old2',
  '+new2',
  '+new3',
  ' line3',
  '',
  '@@ -10 +11,0 @@',
  '-gone',
  'diff --git a/new.ts b/new.ts',
  'new file mode 100644',
  'index ' .. Z .. '..' .. B1,
  '--- /dev/null',
  '+++ b/new.ts',
  '@@ -0,0 +1,2 @@',
  '+a',
  '+b',
  '\\ No newline at end of file',
  'diff --git a/old.ts b/old.ts',
  'deleted file mode 100644',
  'index ' .. A1 .. '..' .. Z,
  '--- a/old.ts',
  '+++ /dev/null',
  '@@ -1 +0,0 @@',
  '-x',
  'diff --git a/src/utils/s.ts b/src/t.ts',
  'similarity index 80%',
  'rename from src/utils/s.ts',
  'rename to src/t.ts',
  'index ' .. A1 .. '..' .. B1 .. ' 100644',
  '--- a/src/utils/s.ts',
  '+++ b/src/t.ts',
  '@@ -1 +1 @@',
  '-q',
  '+r',
  'diff --git a/a b.ts b/c d.ts',
  'similarity index 100%',
  'rename from a b.ts',
  'rename to c d.ts',
  'diff --git a/img.png b/img.png',
  'index ' .. A1 .. '..' .. B1 .. ' 100644',
  'Binary files a/img.png and b/img.png differ',
  'diff --git a/run.sh b/run.sh',
  'old mode 100644',
  'new mode 100755',
  'diff --git "a/caf\\303\\251.ts" "b/caf\\303\\251.ts"',
  'index ' .. A1 .. '..' .. B1 .. ' 100644',
  '--- "a/caf\\303\\251.ts"',
  '+++ "b/caf\\303\\251.ts"',
  '@@ -1 +1 @@',
  '--- a',
  '+++ b',
  '',
}, '\n')

h.test('parses modified file with line numbers', function()
  local files = diff.parse(sample)
  local f = files[1]
  h.eq('src/math.ts', f.path)
  h.eq('M', f.status)
  h.eq(A1, f.old_blob)
  h.eq(B1, f.new_blob)
  h.eq(2, #f.hunks)
  h.eq(2, f.added)
  h.eq(2, f.removed)
  local l = f.hunks[1].lines
  h.eq({ kind = 'ctx', text = 'line1', old_lnum = 1, new_lnum = 1 }, l[1])
  h.eq({ kind = 'del', text = 'old2', old_lnum = 2 }, l[2])
  h.eq({ kind = 'add', text = 'new2', new_lnum = 2 }, l[3])
  h.eq({ kind = 'add', text = 'new3', new_lnum = 3 }, l[4])
  h.eq({ kind = 'ctx', text = 'line3', old_lnum = 3, new_lnum = 4 }, l[5])
  -- empty context line (no leading space) is still context
  h.eq({ kind = 'ctx', text = '', old_lnum = 4, new_lnum = 5 }, l[6])
  h.eq({ kind = 'del', text = 'gone', old_lnum = 10 }, f.hunks[2].lines[1])
  h.eq('export function add', f.hunks[1].section)
end)

h.test('added and deleted files', function()
  local files = diff.parse(sample)
  h.eq('A', files[2].status)
  h.eq('new.ts', files[2].path)
  h.eq(nil, files[2].old_blob)
  h.eq(2, #files[2].hunks[1].lines)
  h.eq('D', files[3].status)
  h.eq('old.ts', files[3].path)
  h.eq(nil, files[3].new_blob)
  h.eq({ kind = 'del', text = 'x', old_lnum = 1 }, files[3].hunks[1].lines[1])
end)

h.test('renames, binary, mode change, quoted paths', function()
  local files = diff.parse(sample)
  h.eq('R', files[4].status)
  h.eq('src/utils/s.ts', files[4].old_path)
  h.eq('src/t.ts', files[4].path)
  h.eq(80, files[4].similarity)
  h.eq('R', files[5].status)
  h.eq('a b.ts', files[5].old_path)
  h.eq('c d.ts', files[5].path)
  h.eq(0, #files[5].hunks)
  h.eq(true, files[6].binary)
  h.eq('img.png', files[6].path)
  h.eq('M', files[7].status)
  h.eq('run.sh', files[7].path)
  h.eq('100755', files[7].new_mode)
  h.eq('café.ts', files[8].path)
  -- content lines that look like headers are content inside a hunk
  h.eq({ kind = 'del', text = '-- a', old_lnum = 1 }, files[8].hunks[1].lines[1])
  h.eq({ kind = 'add', text = '++ b', new_lnum = 1 }, files[8].hunks[1].lines[2])
  h.eq(8, #files)
end)

h.test('word diff finds changed tokens', function()
  local a, b = diff.word_diff('  return multiply(PI_ISH, r * r);', '  return multiply(PI_ISH, radius * radius);')
  h.ok(a and b, 'expected ranges')
  local old = '  return multiply(PI_ISH, r * r);'
  local new = '  return multiply(PI_ISH, radius * radius);'
  h.eq('r', old:sub(a[1][1] + 1, a[1][2]))
  h.eq('radius', new:sub(b[1][1] + 1, b[1][2]))
  h.eq(nil, diff.word_diff('completely', 'different!!'))
end)

h.test('pairs del/add runs', function()
  local lines = {
    { kind = 'ctx' },
    { kind = 'del' },
    { kind = 'del' },
    { kind = 'add' },
    { kind = 'ctx' },
    { kind = 'add' },
  }
  h.eq({ { 2, 4 } }, diff.pair_changes(lines))
end)

h.test('parses real git output from fixture', function()
  local git = require('revuey.git')
  local dir = h.fixture()
  local mb = git.merge_base('main', 'HEAD', dir)
  local text = assert(git.diff(mb, 'HEAD', dir, 3))
  local files = diff.parse(text)
  local by = {}
  for _, f in ipairs(files) do
    by[f.path] = f
  end
  h.eq('A', by['src/cart.ts'].status)
  h.eq('D', by['src/legacy.ts'].status)
  h.eq('R', by['src/text.ts'].status)
  h.eq('src/utils/strings.ts', by['src/text.ts'].old_path)
  h.eq('M', by['src/math.ts'].status)
  h.eq(true, by['assets/logo.png'].binary)
  h.eq('src/components/Total.tsx', by['src/components/Total.tsx'].path)
  -- every add/ctx line equals the HEAD file line
  for _, f in ipairs(files) do
    if f.new_blob and not f.binary then
      local src = vim.split(git.blob(f.new_blob, dir), '\n', { plain = true })
      for _, hk in ipairs(f.hunks) do
        for _, l in ipairs(hk.lines) do
          if l.new_lnum then
            h.eq(src[l.new_lnum], l.text, f.path .. ':' .. l.new_lnum)
          end
        end
      end
    end
  end
  h.eq('main', git.default_branch(dir))
end)

-- Regression (review finding 6): a type change is reported by git as a D + A pair for the same
-- path; it must become a single 'T' entry so it has one reviewed mark.
h.test('merges type-change D+A pair into one T entry', function()
  local text = table.concat({
    'diff --git a/link b/link',
    'deleted file mode 100644',
    'index ' .. A1 .. '..' .. Z,
    '--- a/link',
    '+++ /dev/null',
    '@@ -1 +0,0 @@',
    '-hi',
    'diff --git a/link b/link',
    'new file mode 120000',
    'index ' .. Z .. '..' .. B1,
    '--- /dev/null',
    '+++ b/link',
    '@@ -0,0 +1 @@',
    '+target',
    '\\ No newline at end of file',
    '',
  }, '\n')
  local files = diff.parse(text)
  h.eq(1, #files)
  local f = files[1]
  h.eq('T', f.status)
  h.eq('link', f.path)
  h.eq(A1, f.old_blob)
  h.eq(B1, f.new_blob)
  h.eq(2, #f.hunks)
  h.eq(1, f.added)
  h.eq(1, f.removed)
end)

-- Regression (finding 7): CR is stripped from line text and recorded, so CRLF-only changes are
-- detectable instead of showing two identical lines.
h.test('records CR line endings and missing EOF newline', function()
  local text = table.concat({
    'diff --git a/x.txt b/x.txt',
    'index ' .. A1 .. '..' .. B1 .. ' 100644',
    '--- a/x.txt',
    '+++ b/x.txt',
    '@@ -1,2 +1,2 @@',
    '-a',
    '-b',
    '\\ No newline at end of file',
    '+a\r',
    '+b\r',
    '',
  }, '\n')
  local l = diff.parse(text)[1].hunks[1].lines
  h.eq({ kind = 'del', text = 'a', old_lnum = 1 }, l[1])
  h.eq({ kind = 'del', text = 'b', old_lnum = 2, no_eol = true }, l[2])
  h.eq({ kind = 'add', text = 'a', new_lnum = 1, cr = true }, l[3])
  h.eq({ kind = 'add', text = 'b', new_lnum = 2, cr = true }, l[4])
  h.eq('line ending: LF → CRLF', diff.eol_change(l[1], l[3]))
  h.eq('line ending: no newline at EOF → CRLF', diff.eol_change(l[2], l[4]))
  h.eq(nil, diff.eol_change(l[1], { kind = 'add', text = 'z' }))
end)

h.test('git output keeps CR bytes (no text-mode conversion)', function()
  local d = h.repo('crlf', { ['x.txt'] = 'a\nb\n' }, { ['x.txt'] = 'a\r\nb\r\n' })
  local git = require('revuey.git')
  local files = diff.parse(assert(git.diff('main', 'HEAD', d, 3)))
  local l = files[1].hunks[1].lines
  h.eq(true, l[3].cr, vim.inspect(l))
  h.eq('a', l[3].text)
  h.eq('a\r\nb\r\n', git.blob(files[1].new_blob, d))
end)

h.test('user diff config (textconv) cannot change parser input', function()
  local d = h.repo('textconv', { ['.gitattributes'] = '*.txt diff=upper\n', ['x.txt'] = 'abc\n' }, { ['x.txt'] = 'abd\n' })
  h.git(d, 'config', 'diff.upper.textconv', 'tr a-z A-Z')
  local git = require('revuey.git')
  local files = diff.parse(assert(git.diff('main', 'HEAD', d, 3)))
  h.eq('abd', files[1].hunks[1].lines[2].text)
end)

h.test('real type change is one file', function()
  local d = h.repo('typechange', { link = 'hi\n', target = 'x\n' }, {})
  vim.fn.delete(d .. '/link')
  vim.uv.fs_symlink('target', d .. '/link')
  h.git(d, 'commit', '-q', '-am', 'symlink')
  local git = require('revuey.git')
  local files = diff.parse(assert(git.diff('main', 'HEAD', d, 3)))
  h.eq(1, #files)
  h.eq('T', files[1].status)
end)

h.test('word diff byte ranges with multibyte text and tabs', function()
  local function changed(a, b)
    local ra, rb = diff.word_diff(a, b)
    local oa, ob = {}, {}
    for _, r in ipairs(ra or {}) do
      oa[#oa + 1] = a:sub(r[1] + 1, r[2])
    end
    for _, r in ipairs(rb or {}) do
      ob[#ob + 1] = b:sub(r[1] + 1, r[2])
    end
    return ra and oa, rb and ob
  end
  local oa, ob = changed('\tconst é = "ü";', '\tconst é = "ü!";')
  h.eq({}, oa)
  h.eq({ '!' }, ob)
  oa, ob = changed('x = "日本"', 'x = "日本語"')
  h.eq({}, oa)
  h.eq({ '語' }, ob)
  oa, ob = changed('\t\tnaïve(café)', '\t\tnaïve(cafe)')
  h.eq({ 'café' }, oa)
  h.eq({ 'cafe' }, ob)
  oa, ob = changed('\treturn a', '\t\treturn a')
  h.eq({ '\t' }, oa)
  h.eq({ '\t\t' }, ob)
end)


h.test('untracked file becomes an added FileDiff', function()
  local f = diff.untracked_file('src/new.ts', 'a\r\nb\nc', B1)
  h.eq('A', f.status)
  h.eq('src/new.ts', f.path)
  h.eq('src/new.ts', f.old_path)
  h.eq(nil, f.old_blob)
  h.eq(B1, f.new_blob)
  h.eq(3, f.added)
  h.eq(0, f.removed)
  h.eq(true, f.untracked)
  local h1 = f.hunks[1]
  h.eq({ 0, 0, 1, 3 }, { h1.old_start, h1.old_count, h1.new_start, h1.new_count })
  h.eq('@@ -0,0 +1,3 @@', h1.header)
  h.eq({ kind = 'add', text = 'a', new_lnum = 1, cr = true }, h1.lines[1])
  h.eq({ kind = 'add', text = 'c', new_lnum = 3, no_eol = true }, h1.lines[3])
end)

h.test('untracked empty and binary files', function()
  local e = diff.untracked_file('empty.txt', '', B1)
  h.eq(0, #e.hunks)
  h.eq('A', e.status)
  local b = diff.untracked_file('img.png', 'PNG\0\1\2', B1)
  h.eq(true, b.binary)
  h.eq(0, #b.hunks)
end)

h.test('worktree diff marks deleted-on-disk and keeps worktree hashes', function()
  local d = h.repo('wt-unit', { ['a.txt'] = 'a\n', ['gone.txt'] = 'g\n' }, { ['a.txt'] = 'b\n' })
  h.write(d, 'a.txt', 'c\n')
  vim.fn.delete(d .. '/gone.txt')
  local git = require('revuey.git')
  local files = diff.parse(assert(git.diff('main', nil, d, 3)))
  local by = {}
  for _, f in ipairs(files) do
    by[f.path] = f
  end
  h.eq('D', by['gone.txt'].status)
  h.eq('c', by['a.txt'].hunks[1].lines[2].text)
  h.eq(git.hash_objects({ 'a.txt' }, d)[1], by['a.txt'].new_blob)
  h.eq({}, git.untracked(d))
  h.write(d, 'u dir/new file.txt', 'x\n')
  h.write(d, '.gitignore', 'ignored.txt\n')
  h.write(d, 'ignored.txt', 'i\n')
  h.eq({ '.gitignore', 'u dir/new file.txt' }, git.untracked(d))
end)

h.run()
