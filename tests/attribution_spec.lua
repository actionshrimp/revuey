-- Unit: which stack layer introduced each hunk of a full-stack review (attribution.lua), on a
-- synthetic 3-layer stack built with git: adjacent edits from two layers in one hunk, a pure
-- deletion, a file added in one layer and renamed and edited in a later one, and uncommitted
-- changes (tracked and untracked).
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
local attribution = require('revuey.attribution')
local diff = require('revuey.diff')
local git = require('revuey.git')
local guide = require('revuey.guide')
local gp = require('revuey.guide_prompt')

local function lines(prefix, n, edits)
  local t = {}
  for i = 1, n do
    t[i] = (edits and edits[i]) or (prefix .. i)
  end
  return table.concat(t, '\n') .. '\n'
end

local d = h.tmpdir('attribution')
h.git(d, 'init', '-q')
h.write(d, 'a.txt', lines('L', 40))
h.write(d, 'b.txt', lines('B', 5))
h.git(d, 'add', '-A')
h.git(d, 'commit', '-q', '-m', 'main')
local main = vim.trim(h.git(d, 'rev-parse', 'HEAD'))
-- layer 1: edits line 2, adds f.txt
h.git(d, 'checkout', '-q', '-b', 'base')
h.write(d, 'a.txt', lines('L', 40, { [2] = 'L2 base' }))
h.write(d, 'f.txt', 'f1\nf2\nf3\n')
h.git(d, 'add', '-A')
h.git(d, 'commit', '-q', '-m', 'base')
local base = vim.trim(h.git(d, 'rev-parse', 'HEAD'))
-- layer 2: edits line 3 (next to layer 1's line 2) and line 30, deletes b.txt line 3
h.git(d, 'checkout', '-q', '-b', 'cart')
h.write(d, 'a.txt', lines('L', 40, { [2] = 'L2 base', [3] = 'L3 cart', [30] = 'L30 cart' }))
h.write(d, 'b.txt', 'B1\nB2\nB4\nB5\n')
h.git(d, 'commit', '-q', '-am', 'cart')
local cart = vim.trim(h.git(d, 'rev-parse', 'HEAD'))
-- layer 3: renames f.txt to g.txt and edits its last line, adds ui.txt
h.git(d, 'checkout', '-q', '-b', 'ui')
h.git(d, 'mv', 'f.txt', 'g.txt')
h.write(d, 'g.txt', 'f1\nf2\nf3 ui\n')
h.write(d, 'ui.txt', 'ui\n')
h.git(d, 'add', '-A')
h.git(d, 'commit', '-q', '-m', 'ui')
local ui = vim.trim(h.git(d, 'rev-parse', 'HEAD'))
-- uncommitted: line 20 of a.txt, an untracked file
h.write(d, 'a.txt', lines('L', 40, { [2] = 'L2 base', [3] = 'L3 cart', [20] = 'L20 wip', [30] = 'L30 cart' }))
h.write(d, 'u.txt', 'untracked\n')

local function full_review(mode)
  local files = diff.parse(git.diff(main, mode == 'committed' and ui or nil, d, 3))
  if mode ~= 'committed' then
    files[#files + 1] = diff.untracked_file('u.txt', 'untracked\n', nil, '100644')
  end
  return {
    root = d,
    mode = mode,
    files = files,
    stack = {
      trunk = 'main',
      layers = {
        { name = 'base', tip = base, parent = 'main', parent_rev = main },
        { name = 'cart', tip = cart, parent = 'base', parent_rev = base },
        { name = 'ui', tip = ui, parent = 'cart', parent_rev = cart, is_head = true },
      },
    },
    scope = { kind = 'full' },
  }
end

---{ "path#hunk" = "names" } for readable assertions.
local function flat(r, labels)
  local out = {}
  for fi, f in ipairs(r.files) do
    for hi, names in pairs(labels[fi] or {}) do
      out[f.path .. '#' .. hi] = table.concat(names, ',')
    end
  end
  return out
end

h.test('full stack with uncommitted work: one or more layers per hunk', function()
  local r = full_review('worktree')
  local labels = attribution.load(r)
  h.eq({
    ['a.txt#1'] = 'base,cart', -- lines 2 and 3: one hunk, two layers
    ['a.txt#2'] = 'uncommitted', -- line 20
    ['a.txt#3'] = 'cart', -- line 30
    ['b.txt#1'] = 'cart', -- a pure deletion
    ['g.txt#1'] = 'base,ui', -- added by base as f.txt, renamed and edited by ui
    ['ui.txt#1'] = 'ui',
    ['u.txt#1'] = 'uncommitted', -- untracked
  }, flat(r, labels))
end)

h.test('committed only: no uncommitted layer', function()
  local r = full_review('committed')
  local labels = attribution.load(r)
  h.eq({
    ['a.txt#1'] = 'base,cart',
    ['a.txt#2'] = 'cart',
    ['b.txt#1'] = 'cart',
    ['g.txt#1'] = 'base,ui',
    ['ui.txt#1'] = 'ui',
  }, flat(r, labels))
end)

h.test('a layer-scope review gets no labels', function()
  local r = full_review('committed')
  r.scope = { kind = 'layer', index = 2 }
  h.eq(nil, attribution.load(r))
  r.stack, r.scope = nil, nil
  h.eq(nil, attribution.load(r))
end)

h.test('a line rewritten by a later layer belongs to that layer only', function()
  -- pure: layer x adds lines 1-3, layer y rewrites line 2
  local function parse(text)
    return diff.parse(text)
  end
  local x = parse('diff --git a/n.txt b/n.txt\nnew file mode 100644\n--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1,3 @@\n+a\n+b\n+c\n')
  local y = parse('diff --git a/n.txt b/n.txt\n--- a/n.txt\n+++ b/n.txt\n@@ -2 +2 @@\n-b\n+B\n')
  local full = parse('diff --git a/n.txt b/n.txt\nnew file mode 100644\n--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1,3 @@\n+a\n+B\n+c\n')
  h.eq({ { [1] = { 'x', 'y' } } }, attribution.attribute(full, { { name = 'x', files = x }, { name = 'y', files = y } }))
  -- a full-scope hunk that only y changed (x's lines are elsewhere)
  local y2 = parse('diff --git a/n.txt b/n.txt\n--- a/n.txt\n+++ b/n.txt\n@@ -3,0 +4 @@\n+d\n')
  local full2 = parse('diff --git a/n.txt b/n.txt\n--- a/n.txt\n+++ b/n.txt\n@@ -3,0 +4 @@\n+d\n')
  h.eq({ { [1] = { 'y' } } }, attribution.attribute(full2, { { name = 'x', files = {} }, { name = 'y', files = y2 } }))
end)

h.test('prompt: full-stack hunk markers carry their layers', function()
  local r = full_review('worktree')
  local labels = attribution.load(r)
  local hunks = guide.hunks(r.files)
  for _, hk in ipairs(hunks) do
    hk.layers = labels[hk.file_idx][hk.hunk_idx or 0]
  end
  local ctx = {
    repo = 'r',
    branch = 'ui',
    base = 'main',
    stack = { kind = 'full', trunk = 'main', layers = { { name = 'base', parent = 'main' }, { name = 'cart', parent = 'base' }, { name = 'ui', parent = 'cart' } } },
  }
  local text = gp.user_message(ctx, hunks)
  h.ok(text:find('\n@@ h1 a.txt @@ [base, cart]\n', 1, true), text)
  h.ok(text:find(' a.txt @@ [uncommitted]\n', 1, true), text)
  h.ok(text:find('Each hunk marker below ends with the branch that introduced the hunk', 1, true))
  -- without labels (layer scope): no tags, no explanation
  for _, hk in ipairs(hunks) do
    hk.layers = nil
  end
  text = gp.user_message(ctx, hunks)
  h.ok(text:find('\n@@ h1 a.txt @@\n', 1, true))
  h.ok(not text:find('Each hunk marker below', 1, true))
end)

h.run()
