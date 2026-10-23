-- Stacks without local branches: remote-tracking branches (`origin/x`) as layers below HEAD, a
-- detached HEAD at a branch tip, state keys without the remote. Unit tests of the pure candidate
-- selection, then real git: someone else's stack pushed to a bare "upstream", reviewed from a
-- fresh clone (scripts/make-fixture.sh --remote-stack).
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')
local state_dir = h.tmpdir('stack-remote-state')
require('revuey').setup({ state_dir = state_dir, lsp_warmup = false })
local stack = require('revuey.stack')
local state = require('revuey.state')
local view = require('revuey.view')

-- ---------------------------------------------------------------------------
-- Unit: remote_layers()
-- ---------------------------------------------------------------------------

---Remote refs from {name = sha}; the remote is the part before the first `/`.
local function refs(t)
  local out = {}
  for name, sha in pairs(t) do
    local r, short = name:match('^([^/]+)/(.+)$')
    out[#out + 1] = { name = name, remote = r, short = short, sha = sha }
  end
  return out
end

-- main(T) ── a1 ── a2 ── b1 ── c1 ── c2 (HEAD)
local line = { a1 = true, a2 = true, b1 = true, c1 = true, c2 = true }

local function sel(o)
  return stack.remote_layers(vim.tbl_extend('keep', o, {
    line = line,
    head = 'c2',
    branches = { main = 'T', ['feat/c'] = 'c2' },
    trunk_names = { main = true, ['origin/main'] = true },
  }))
end

local function sorted_keys(t)
  local k = vim.tbl_keys(t)
  table.sort(k)
  return k
end

h.test('remote_layers: only refs on HEAD\'s line strictly below HEAD; never trunk, HEAD refs, other lines', function()
  local r = sel({
    refs = refs({
      ['origin/feat/a'] = 'a2', ['origin/feat/b'] = 'b1',
      ['origin/feat/c'] = 'c2', -- at HEAD (attached): not a layer
      ['origin/main'] = 'T', ['origin/HEAD'] = 'T',
      ['origin/other'] = 'X', -- another line
      ['origin/above'] = 'Z', -- above HEAD (not on the line)
    }),
  })
  h.eq({ 'origin/feat/a', 'origin/feat/b' }, sorted_keys(r.branches))
  h.eq({ ['origin/feat/a'] = 'feat/a', ['origin/feat/b'] = 'feat/b' }, r.keys)
  h.eq(nil, r.current)
end)

h.test('remote_layers: a local branch at the same commit, or a local copy on the line, wins', function()
  local r = sel({
    refs = refs({ ['origin/feat/a'] = 'a2', ['origin/pr-b'] = 'b1', ['origin/feat/b2'] = 'c1' }),
    branches = { main = 'T', ['feat/c'] = 'c2', mine = 'a2', ['feat/b'] = 'b1', local_b2 = 'X' },
    -- local_b2 tracks origin/feat/b2 but is off the line: the remote copy stays a layer
    upstream = { ['feat/b'] = 'origin/pr-b', local_b2 = 'origin/feat/b2' },
  })
  h.eq({ 'origin/feat/b2' }, sorted_keys(r.branches))
  -- origin/feat/a is at `mine`'s commit under another name: listed and noted
  h.eq({ a2 = { { name = 'origin/feat/a', note = true } } }, r.also)
  -- a local branch tracking it on the line (even at another commit) also wins
  local r2 = sel({
    refs = refs({ ['origin/feat/b'] = 'c1' }),
    branches = { main = 'T', ['feat/c'] = 'c2', ['feat/b'] = 'b1' },
    upstream = { ['feat/b'] = 'origin/feat/b' },
  })
  h.eq({}, r2.branches)
  -- HEAD's own upstream behind HEAD is never a layer below it
  local r3 = sel({
    refs = refs({ ['origin/feat/c'] = 'c1' }),
    upstream = { ['feat/c'] = 'origin/feat/c' },
  })
  h.eq({}, r3.branches)
end)

h.test('remote_layers: several remotes at one commit: tracked remote, then origin, then alphabetical', function()
  local at_b1 = refs({ ['upstream/feat/b'] = 'b1', ['origin/feat/b'] = 'b1', ['fork/feat/b'] = 'b1', ['aaa/feat/b'] = 'b1' })
  h.eq({ 'upstream/feat/b' }, sorted_keys(sel({ refs = at_b1, prefer = 'upstream' }).branches))
  local r = sel({ refs = at_b1 })
  h.eq({ 'origin/feat/b' }, sorted_keys(r.branches))
  h.eq({ 'aaa/feat/b', 'fork/feat/b', 'upstream/feat/b' }, vim.tbl_map(function(a)
    return a.name
  end, r.also.b1))
  -- same branch name on another remote: not a note
  h.eq({ false, false, false }, vim.tbl_map(function(a)
    return a.note
  end, r.also.b1))
  h.eq({ 'aaa/feat/b' }, sorted_keys(sel({ refs = refs({ ['fork/feat/b'] = 'b1', ['aaa/feat/b'] = 'b1' }) }).branches))
end)

h.test('remote_layers: keys drop the remote; the same name on two remotes keeps the less preferred apart', function()
  local r = sel({ refs = refs({ ['origin/x'] = 'a2', ['upstream/x'] = 'b1', ['upstream/y'] = 'c1' }) })
  h.eq({ ['origin/x'] = 'x', ['upstream/x'] = 'upstream/x', ['upstream/y'] = 'y' }, r.keys)
  local r2 = sel({ refs = refs({ ['origin/x'] = 'a2', ['upstream/x'] = 'b1' }), prefer = 'upstream' })
  h.eq({ ['origin/x'] = 'origin/x', ['upstream/x'] = 'x' }, r2.keys)
end)

h.test('remote_layers: the ignore list keeps a remote branch out of the stack', function()
  local r = sel({ refs = refs({ ['origin/feat/a'] = 'a2', ['origin/bot/b'] = 'b1' }), ignore = { 'bot/*' } })
  h.eq({ 'origin/feat/a' }, sorted_keys(r.branches))
end)

h.test('remote_layers: detached HEAD is named after a branch at it (local first), others listed', function()
  local o = {
    detached = true,
    branches = { main = 'T' },
    refs = refs({ ['origin/feat/c'] = 'c2', ['upstream/feat/c'] = 'c2', ['origin/feat/a'] = 'a2' }),
  }
  local r = sel(o)
  h.eq('origin/feat/c', r.current)
  h.eq({ 'upstream/feat/c' }, r.current_also)
  h.eq({ 'origin/feat/a', 'origin/feat/c' }, sorted_keys(r.branches))
  o.branches = { main = 'T', zed = 'c2', ['feat/c'] = 'c2' }
  r = sel(o)
  h.eq('feat/c', r.current)
  h.eq({ 'zed' }, r.current_also) -- its pushed copies aren't worth a mention
  -- nothing at HEAD: no name
  h.eq(nil, sel({ detached = true, branches = { main = 'T' }, refs = refs({ ['origin/feat/a'] = 'a2' }) }).current)
end)

h.test('remote_layers: aliases of the checked-out branch and PR refs are never layers', function()
  local r = sel({
    refs = refs({
      ['origin/pr/12'] = 'a2', ['origin/pull/7/head'] = 'a2', -- PR-head mirrors
      ['origin/dave/feat/c'] = 'b1', -- its push ref
      ['fork/x'] = 'b1', -- at the push ref's commit
      ['fork/feat/c'] = 'a1', -- named */feat/c
      ['origin/real'] = 'c1',
    }),
    aliases = { names = { ['origin/dave/feat/c'] = true }, shas = { b1 = true }, branch = 'feat/c' },
  })
  h.eq({ 'origin/real' }, sorted_keys(r.branches))
end)

h.test('remote_layers: explicit parents, then the previous choice, beat the alphabetical pick', function()
  local at = refs({ ['origin/aaa-backup'] = 'b1', ['origin/feat/b'] = 'b1' })
  h.eq({ 'origin/aaa-backup' }, sorted_keys(sel({ refs = at }).branches))
  h.eq({ 'origin/feat/b' }, sorted_keys(sel({ refs = at, previous = { ['origin/feat/b'] = true } }).branches))
  h.eq({ 'origin/feat/b' }, sorted_keys(sel({ refs = at, preferred = { ['feat/b'] = true }, previous = { ['origin/aaa-backup'] = true } }).branches))
end)

h.test('remote_layers: an unrelated local branch of the same name keeps the full key; a tracking one shares it', function()
  local o = { refs = refs({ ['origin/feat/a'] = 'a2' }), branches = { main = 'T', ['feat/c'] = 'c2', ['feat/a'] = 'X' } }
  h.eq({ ['origin/feat/a'] = 'origin/feat/a' }, sel(o).keys)
  o.upstream = { ['feat/a'] = 'origin/feat/a' }
  h.eq({ ['origin/feat/a'] = 'feat/a' }, sel(o).keys)
end)

h.test('resolve: remote layers key without the remote; children key their parent the same way', function()
  local graph = { a1 = '', a2 = 'a1', b1 = 'a2', c1 = 'b1', c2 = 'c1' }
  local loaded = {}
  for c in pairs(graph) do
    loaded[c] = true
  end
  local st = stack.resolve({
    trunk = 'origin/main', trunk_rev = 'T', trunk_names = { ['origin/main'] = true, main = true },
    current = 'origin/feat/c', detached = true, head = 'c2',
    branches = { ['origin/feat/a'] = 'a2', ['upstream/feat/b'] = 'b1', ['origin/feat/c'] = 'c2' },
    graph = graph, loaded = loaded,
    remote = { ['origin/feat/a'] = true, ['upstream/feat/b'] = true, ['origin/feat/c'] = true },
    keys = { ['origin/feat/a'] = 'feat/a', ['upstream/feat/b'] = 'feat/b', ['origin/feat/c'] = 'feat/c' },
    normalize = function(n)
      return state.normalize_base(n, { 'origin', 'upstream' })
    end,
  })
  h.eq({ 'origin/feat/a', 'upstream/feat/b', 'origin/feat/c' }, vim.tbl_map(function(l)
    return l.name
  end, st.layers))
  h.eq({ { 'feat/a', 'main' }, { 'feat/b', 'feat/a' }, { 'feat/c', 'feat/b' } }, vim.tbl_map(function(l)
    return { l.state_branch, l.state_base }
  end, st.layers))
  h.eq({ true, true, true }, vim.tbl_map(function(l)
    return l.remote
  end, st.layers))
  h.eq({ false, false, true }, vim.tbl_map(function(l)
    return l.detached == true
  end, st.layers))
  h.eq(true, st.layers[3].is_head)
  h.eq(3, st.current)
end)

-- ---------------------------------------------------------------------------
-- Integration: real git
-- ---------------------------------------------------------------------------

---Someone else's 3-PR stack in a bare upstream; `review` is a fresh clone detached at the top.
---Returns {root, review, someone, upstream}.
local function remote_fixture(name)
  local d = h.tmpdir(name)
  vim.fn.delete(d, 'rf')
  local res = vim.system({ h.root .. '/scripts/make-fixture.sh', '--remote-stack', d }, { text = true }):wait()
  assert(res.code == 0, res.stderr)
  return { root = d, review = d .. '/review', someone = d .. '/someone', upstream = d .. '/upstream.git' }
end

local function detect(dir, opts)
  local st, notes, from, ignored = stack.detect(dir, require('revuey.git').default_branch(dir), nil, opts)
  return st, notes, from, ignored
end

local function names(st)
  return vim.tbl_map(function(l)
    return l.name
  end, st.layers)
end

local function kinds(notes)
  return vim.tbl_map(function(n)
    return n.kind .. ':' .. n.branch
  end, notes or {})
end

h.test('fresh clone detached at the top PR: all 3 layers, the lower ones from origin/*', function()
  local f = remote_fixture('remote-detached')
  local st = detect(f.review)
  h.ok(st, 'stack detected')
  h.eq('origin/main', st.trunk)
  h.eq({ 'origin/stack/math', 'origin/stack/cart', 'origin/stack/ui' }, names(st))
  h.eq({ 'origin/main', 'origin/stack/math', 'origin/stack/cart' }, vim.tbl_map(function(l)
    return l.parent
  end, st.layers))
  h.eq({ 'stack/math', 'stack/cart', 'stack/ui' }, vim.tbl_map(function(l)
    return l.state_branch
  end, st.layers))
  h.eq({ 'main', 'stack/math', 'stack/cart' }, vim.tbl_map(function(l)
    return l.state_base
  end, st.layers))
  h.eq(3, st.current)
  h.eq(true, st.layers[3].is_head)
  h.eq(true, st.layers[3].detached)
  h.eq({ true, true, true }, vim.tbl_map(function(l)
    return l.remote == true
  end, st.layers))
  -- the detached note, and nothing about origin/other/docs
  h.eq({ 'detached:origin/stack/ui' }, kinds(st.notes))
  -- layer and full targets
  local t = stack.target(st, { kind = 'layer', index = 2 })
  h.eq({ 'origin/stack/cart', 'origin/stack/math', 'stack/cart', 'stack/math', true }, { t.branch, t.base, t.state_branch, t.state_base, t.committed_only })
  local full = stack.target(st, { kind = 'full' })
  h.eq({ 'stack/ui', 'main', nil }, { full.state_branch, full.state_base, full.to })
end)

h.test('creating a local branch for a lower layer later keeps its marks and comments', function()
  local f = remote_fixture('remote-carry')
  local s = h.open_review({ cwd = f.review, base = '' })
  h.eq({ 'origin/stack/math', 'origin/stack/cart', 'origin/stack/ui' }, names(s.review.stack))
  view.set_scope({ kind = 'layer', index = 2 })
  h.ok(vim.wait(10000, function()
    return not s.refreshing and not s.pending and not s.pending_scope and s.review.branch == 'origin/stack/cart'
  end, 10), 'layer 2 did not load')
  h.eq(true, s.review.mode_locked)
  h.ok(table.concat(vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false), '\n'):find('(remote, read-only)', 1, true))
  -- a reviewed mark and a comment on the remote layer
  local fi
  for i, file in ipairs(s.review.files) do
    if file.path == 'src/cart.ts' then
      fi = i
    end
  end
  view.toggle_reviewed(fi)
  h.eq(true, require('revuey.review').is_reviewed(s.review, s.review.files[fi]))
  local comments = require('revuey.comments')
  local path = comments.path_for(s.review.state._path)
  local store = comments.load(path)
  local c = comments.new(comments.file_anchor('src/cart.ts'), 'remote layer comment')
  comments.put(store, c)
  comments.save(store)
  local state_path = s.review.state._path
  view.close()
  -- the reviewer makes a local branch for that PR
  h.git(f.review, 'branch', '-q', '--track', 'stack/cart', 'origin/stack/cart')
  s = h.open_review({ cwd = f.review, base = '' })
  h.eq({ 'origin/stack/math', 'stack/cart', 'origin/stack/ui' }, names(s.review.stack))
  h.eq(nil, s.review.stack.layers[2].remote)
  view.set_scope({ kind = 'layer', index = 2 })
  h.ok(vim.wait(10000, function()
    return not s.refreshing and not s.pending and not s.pending_scope and s.review.branch == 'stack/cart'
  end, 10), 'layer 2 did not load')
  h.eq(state_path, s.review.state._path)
  for i, file in ipairs(s.review.files) do
    if file.path == 'src/cart.ts' then
      h.eq(true, require('revuey.review').is_reviewed(s.review, s.review.files[i]))
    end
  end
  h.eq('remote layer comment', comments.load(comments.path_for(s.review.state._path)).comments[c.id].body)
  view.close()
end)

h.test('layer switching, full stack and branch labels work with remote layers', function()
  local f = remote_fixture('remote-view')
  local s = h.open_review({ cwd = f.review, base = '' })
  h.eq({ kind = 'layer', index = 3 }, s.scope)
  h.eq('origin/stack/ui', s.review.branch)
  h.eq('origin/stack/cart', s.review.base)
  h.eq(false, s.review.mode_locked, 'detached HEAD layer has the working tree')
  view.set_scope({ kind = 'full' })
  h.ok(vim.wait(10000, function()
    return not s.refreshing and not s.pending and not s.pending_scope and s.scope.kind == 'full'
  end, 10))
  h.eq('origin/main', s.review.base)
  local labels = require('revuey.attribution').load(s.review)
  h.ok(labels, 'labels')
  local seen = {}
  for _, per_file in pairs(labels) do
    for _, ls in pairs(per_file) do
      for _, n in ipairs(ls) do
        seen[n] = true
      end
    end
  end
  h.eq({ 'origin/stack/cart', 'origin/stack/math', 'origin/stack/ui' }, sorted_keys(seen))
  -- :RevueyStackParent refuses a remote layer
  view.set_scope({ kind = 'layer', index = 1 })
  h.ok(vim.wait(10000, function()
    return not s.refreshing and not s.pending and not s.pending_scope and s.scope.index == 1
  end, 10))
  local msgs, restore = h.capture_notify()
  view.stack_parent('origin/main')
  restore()
  h.ok(msgs[1] and msgs[1].msg:find('read-only', 1, true), vim.inspect(msgs))
  view.close()
end)

h.test('unrelated remote branches (other lines, above HEAD, side branches) are not layers or notes', function()
  local f = remote_fixture('remote-unrelated')
  -- above HEAD: a branch on top of stack/ui; a side branch off stack/math; one off main
  h.git(f.someone, 'checkout', '-q', '-b', 'stack/next', 'stack/ui')
  h.write(f.someone, 'next.txt', 'next\n')
  h.git(f.someone, 'add', '-A')
  h.git(f.someone, 'commit', '-q', '-m', 'next')
  h.git(f.someone, 'checkout', '-q', '-b', 'side/math', 'stack/math')
  h.write(f.someone, 'side.txt', 'side\n')
  h.git(f.someone, 'add', '-A')
  h.git(f.someone, 'commit', '-q', '-m', 'side')
  h.git(f.someone, 'push', '-q', f.upstream, 'stack/next', 'side/math')
  h.git(f.review, 'fetch', '-q', 'origin')
  local st = detect(f.review)
  h.eq({ 'origin/stack/math', 'origin/stack/cart', 'origin/stack/ui' }, names(st))
  h.eq({ 'detached:origin/stack/ui' }, kinds(st.notes))
end)

h.test('a detached HEAD with no branch at it: no stack, and a note that says why', function()
  local f = remote_fixture('remote-nobranch')
  h.write(f.review, 'wip.txt', 'wip\n')
  h.git(f.review, 'add', '-A')
  h.git(f.review, 'commit', '-q', '-m', 'wip')
  local st, notes = detect(f.review)
  h.eq(nil, st)
  h.eq({ 'detached:HEAD' }, kinds(notes))
  h.ok(notes[1].text:find('no branch points at it', 1, true), notes[1].text)
  -- still keyed HEAD, as detached reviews always were
  local r = require('revuey.review').load({ cwd = f.review, base = 'origin/main', state_dir = state_dir })
  h.eq('HEAD', r.state.branch)
end)

h.test('a local branch under another name at a remote layer\'s commit wins; the remote copy is listed', function()
  local f = remote_fixture('remote-samecommit')
  h.git(f.review, 'branch', '-q', '--no-track', 'my-cart', 'origin/stack/cart')
  local st = detect(f.review)
  h.eq({ 'origin/stack/math', 'my-cart', 'origin/stack/ui' }, names(st))
  h.eq({ 'origin/stack/cart' }, st.layers[2].also)
  h.eq({ 'same_commit:origin/stack/cart', 'detached:origin/stack/ui' }, kinds(st.notes))
end)

h.test('squash-merged lower layers on the remote: landed, or skipped once the branch is deleted', function()
  local f = remote_fixture('remote-squash')
  -- someone squash-merges stack/math into main and pushes main
  h.git(f.someone, 'checkout', '-q', 'main')
  h.git(f.someone, 'merge', '-q', '--squash', 'stack/math')
  h.git(f.someone, 'commit', '-q', '-m', 'math (#1)')
  h.git(f.someone, 'push', '-q', f.upstream, 'main')
  h.git(f.review, 'fetch', '-q', 'origin')
  local st = detect(f.review)
  h.eq({ 'origin/stack/math', 'origin/stack/cart', 'origin/stack/ui' }, names(st))
  h.eq(true, st.layers[1].landed)
  -- the merged branch is deleted on the remote (and pruned here)
  h.git(f.someone, 'push', '-q', f.upstream, ':stack/math')
  h.git(f.review, 'fetch', '-q', '--prune', 'origin')
  st = detect(f.review)
  h.eq({ 'origin/stack/cart', 'origin/stack/ui' }, names(st))
  h.eq(1, st.layers[1].skipped)
  h.eq({ 'detached:origin/stack/ui', 'squashed:origin/stack/cart' }, kinds(st.notes))
end)

h.test('bin/revuey comments in a detached review: the live session\'s scope, else the same resolution', function()
  local f = remote_fixture('remote-cli')
  local s = h.open_review({ cwd = f.review, base = '' })
  h.eq('origin/stack/ui', s.review.branch)
  local cv, editor = require('revuey.comments_view'), require('revuey.comment_editor')
  local row
  for r, e in ipairs(s.layout.map) do
    if e.kind == 'add' then
      row = r
      break
    end
  end
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
  cv.add(s, row, row)
  vim.api.nvim_buf_set_lines(editor.current.buf, 0, -1, false, { 'hello from detached' })
  editor.save(editor.current)
  local function run()
    return vim.system({ h.root .. '/bin/revuey', 'comments' }, {
      cwd = f.review, env = { REVUEY_STATE_DIR = state_dir, REVUEY_NVIM = vim.v.progpath }, text = true,
    }):wait(20000)
  end
  local res = run()
  h.ok(res.stdout:find('hello from detached', 1, true), res.stdout .. res.stderr)
  view.close()
  res = run() -- no live session: resolved like the UI does
  h.ok(res.stdout:find('hello from detached', 1, true), res.stdout .. res.stderr)
end)

-- ---------------------------------------------------------------------------
-- Your own branch is never split into remote layers (review findings)
-- ---------------------------------------------------------------------------

local function cm(dir, file, text)
  local p = vim.fs.joinpath(dir, file)
  local old = vim.uv.fs_stat(p) and table.concat(vim.fn.readfile(p), '\n') .. '\n' or ''
  h.write(dir, file, old .. text .. '\n')
  h.git(dir, 'add', '-A')
  h.git(dir, 'commit', '-q', '-m', text)
end

---My own repo: `me` (main + my-feature with m1, m2) and a bare `up.git` as origin.
local function own_repo(name)
  local d = h.tmpdir(name)
  local me = d .. '/me'
  vim.fn.mkdir(me, 'p')
  h.git(me, 'init', '-q', '-b', 'main')
  cm(me, 'f0', 'base')
  h.git(d, 'clone', '-q', '--bare', me, 'up.git')
  h.git(me, 'remote', 'add', 'origin', d .. '/up.git')
  h.git(me, 'fetch', '-q', 'origin')
  h.git(me, 'remote', 'set-head', 'origin', 'main')
  h.git(me, 'switch', '-q', '--no-track', '-c', 'my-feature', 'origin/main')
  cm(me, 'fm', 'm1')
  cm(me, 'fm', 'm2')
  return me, d .. '/up.git'
end

---The plain review of my-feature: no stack, and no note about a remote branch.
local function plain(me)
  local st, notes = detect(me)
  h.eq(nil, st and names(st), 'no stack')
  for _, n in ipairs(notes or {}) do
    h.ok(n.kind ~= 'same_commit' and n.kind ~= 'detached', vim.inspect(n))
  end
  return notes
end

h.test('(c) PR refs fetched to origin/pr/*, committed after pushing: no remote layers, with or without -u', function()
  local me, up = own_repo('own-pr-refs')
  h.git(me, 'push', '-q', 'origin', 'my-feature')
  h.git(up, 'update-ref', 'refs/pull/12/head', 'refs/heads/my-feature')
  h.git(me, 'config', '--add', 'remote.origin.fetch', '+refs/pull/*/head:refs/remotes/origin/pr/*')
  h.git(me, 'fetch', '-q', 'origin')
  cm(me, 'fm', 'm3')
  plain(me)
  h.git(me, 'branch', '-q', '-u', 'origin/my-feature')
  local notes = plain(me)
  h.eq({ 'upstream:my-feature' }, kinds(notes), 'one commit ahead of origin/my-feature')
  -- pushed again, the PR ref not refetched: HEAD is its upstream, the stale PR ref is no layer
  h.git(me, 'push', '-q', 'origin', 'my-feature')
  h.git(me, 'fetch', '-q', 'origin', 'my-feature')
  plain(me)
end)

h.test('(d) pushed under another name (my-feature:dave/my-feature), then committed: no remote layers', function()
  local me = own_repo('own-other-name')
  h.git(me, 'push', '-q', 'origin', 'my-feature:dave/my-feature')
  h.git(me, 'fetch', '-q', 'origin')
  cm(me, 'fm', 'm3')
  plain(me)
  -- tracking it, nothing new: still one branch, keyed as before
  h.git(me, 'reset', '-q', '--hard', 'origin/dave/my-feature')
  h.git(me, 'branch', '-q', '-u', 'origin/dave/my-feature')
  plain(me)
  local r = require('revuey.review').load({ cwd = me, base = 'origin/main', state_dir = state_dir })
  h.eq({ 'my-feature', 'main' }, { r.state.branch, r.state.base })
end)

h.test('(e) fork workflow: stale origin/main as trunk, branch from upstream/main: no remote layers', function()
  local d = h.tmpdir('own-fork')
  local canon = d .. '/canon'
  vim.fn.mkdir(canon, 'p')
  h.git(canon, 'init', '-q', '-b', 'main')
  cm(canon, 'f0', 'base')
  h.git(d, 'clone', '-q', '--bare', canon, 'fork.git')
  cm(canon, 'fu', 'u1')
  h.git(canon, 'branch', 'release-1.0')
  h.git(canon, 'checkout', '-q', '-b', 'pr-x')
  cm(canon, 'fx', 'x1')
  h.git(canon, 'checkout', '-q', 'main')
  h.git(canon, 'merge', '-q', '--ff-only', 'pr-x')
  cm(canon, 'fu', 'u2')
  h.git(d, 'clone', '-q', '--bare', canon, 'canon.git')
  h.git(d, 'clone', '-q', 'fork.git', 'me')
  local me = d .. '/me'
  h.git(me, 'remote', 'add', 'upstream', d .. '/canon.git')
  h.git(me, 'fetch', '-q', 'upstream')
  h.git(me, 'switch', '-q', '-c', 'my-feat', 'upstream/main')
  cm(me, 'fm', 'm1')
  plain(me)
  -- even without tracking (any remote's trunk history is never a layer)
  h.git(me, 'branch', '-q', '--unset-upstream')
  plain(me)
end)

h.test('an unrelated local branch with a layer\'s name keeps its own key; a tracking one shares it', function()
  local f = remote_fixture('remote-key-collision')
  h.git(f.review, 'branch', '-q', '--no-track', 'stack/math', 'origin/main')
  local st = detect(f.review)
  h.eq({ 'origin/stack/math', 'origin/stack/cart', 'origin/stack/ui' }, names(st))
  h.eq({ 'origin/stack/math', 'stack/cart', 'stack/ui' }, vim.tbl_map(function(l)
    return l.state_branch
  end, st.layers))
  h.eq('origin/stack/math', st.layers[2].state_base)
end)

h.test('a branch tracking trunk gets no "ahead of origin/main" note', function()
  local f = remote_fixture('remote-track-trunk')
  h.git(f.review, 'switch', '-q', '-c', 'x', 'origin/main')
  cm(f.review, 'x.txt', 'x1')
  local _, notes = detect(f.review)
  h.eq({}, kinds(notes))
end)

h.test('a new remote branch at a layer\'s commit does not rename the layer across refreshes', function()
  local f = remote_fixture('remote-stable')
  local cache = {}
  local st = stack.detect(f.review, 'origin/main', cache)
  h.eq('origin/stack/cart', st.layers[2].name)
  h.git(f.someone, 'push', '-q', f.upstream, 'stack/cart:aaa-backup')
  h.git(f.review, 'fetch', '-q', 'origin')
  st = stack.detect(f.review, 'origin/main', cache)
  h.eq({ 'origin/stack/math', 'origin/stack/cart', 'origin/stack/ui' }, names(st))
  h.eq({ 'origin/aaa-backup' }, st.layers[2].also)
  -- reopened (no cache): the stored choice still wins over the alphabetical pick
  st = stack.detect(f.review, 'origin/main')
  h.eq({ 'origin/stack/math', 'origin/stack/cart', 'origin/stack/ui' }, names(st))
  h.eq('stack/cart', st.layers[2].state_branch)
  -- with no stored choice (another state dir), the rule picks alphabetically
  st = stack.detect(f.review, 'origin/main', nil, { state_dir = h.tmpdir('remote-stable-fresh') })
  h.eq('origin/aaa-backup', st.layers[2].name)
end)

h.test('PR refs (*/pr/*, */pull/*) are never layers and make no same-commit notes', function()
  local f = remote_fixture('remote-pr-refs')
  for i, b in ipairs({ 'stack/math', 'stack/cart', 'stack/ui' }) do
    h.git(f.upstream, 'update-ref', 'refs/pull/' .. i .. '/head', 'refs/heads/' .. b)
  end
  h.git(f.review, 'config', '--add', 'remote.origin.fetch', '+refs/pull/*/head:refs/remotes/origin/pr/*')
  h.git(f.review, 'fetch', '-q', 'origin')
  local st = detect(f.review)
  h.eq({ 'origin/stack/math', 'origin/stack/cart', 'origin/stack/ui' }, names(st))
  h.eq({ 'detached:origin/stack/ui' }, kinds(st.notes))
end)

h.test('detached on trunk: the note says HEAD is on trunk', function()
  local f = remote_fixture('remote-on-trunk')
  h.git(f.review, 'switch', '-q', '--detach', 'origin/main')
  local st, notes = detect(f.review)
  h.eq(nil, st)
  h.eq({ 'detached:HEAD' }, kinds(notes))
  h.ok(notes[1].text:find('on origin/main', 1, true) and not notes[1].text:find('no branch', 1, true), notes[1].text)
end)

h.test('on a local branch (attached), remote refs are never layers unless a parent setting names one', function()
  local f = remote_fixture('remote-tracking')
  h.git(f.review, 'switch', '-q', '-c', 'stack/ui', '--track', 'origin/stack/ui')
  local st, notes = detect(f.review)
  h.eq(nil, st, 'no remote layers while attached')
  h.eq({}, kinds(notes))
  -- an explicit parent naming a remote-tracking branch works while attached
  h.git(f.review, 'config', 'branch.stack/ui.revueyParent', 'origin/stack/cart')
  st = detect(f.review)
  h.eq({ 'origin/stack/cart', 'stack/ui' }, names(st))
  h.eq({ true, false }, vim.tbl_map(function(l)
    return l.remote == true
  end, st.layers))
  h.eq({ 'stack/cart', 'stack/cart' }, { st.layers[1].state_branch, st.layers[2].state_base })
  h.eq('config', st.layers[2].source)
  h.git(f.review, 'config', '--unset', 'branch.stack/ui.revueyParent')
  -- someone pushes a new commit to the top; after a fetch the local branch is behind its remote
  h.write(f.someone, 'src/extra.ts', 'export const extra = 1;\n')
  h.git(f.someone, 'checkout', '-q', 'stack/ui')
  h.git(f.someone, 'add', '-A')
  h.git(f.someone, 'commit', '-q', '-m', 'extra')
  h.git(f.someone, 'push', '-q', f.upstream, 'stack/ui')
  h.git(f.review, 'fetch', '-q', 'origin')
  st, notes = detect(f.review)
  h.eq(nil, st)
  h.eq({ 'upstream:stack/ui' }, kinds(notes))
  h.ok(notes[1].text:find('1 commit behind origin/stack/ui', 1, true), notes[1].text)
end)

h.test('right after a push, older remote refs on your line (backups, a colleague\'s start) never split it', function()
  local me = own_repo('own-just-pushed')
  -- a backup pushed earlier and a colleague's zero-commit branch at m1
  h.git(me, 'push', '-q', 'origin', 'my-feature~1:refs/heads/wip-backup')
  h.git(me, 'push', '-q', 'origin', 'my-feature~1:refs/heads/colleague-start')
  h.git(me, 'push', '-q', '-u', 'origin', 'my-feature')
  h.git(me, 'fetch', '-q', 'origin')
  plain(me)
  local r = require('revuey.review').load({ cwd = me, state_dir = state_dir })
  h.eq({ 'my-feature', 'main' }, { r.state.branch, r.state.base })
  h.eq(2, #vim.split(vim.trim(h.git(me, 'rev-list', r.merge_base .. '..HEAD')), '\n'), 'full diff: m1 and m2')
  cm(me, 'fm', 'm3')
  plain(me)
end)

h.test('performance: 3000 unrelated remote branches stay cheap', function()
  local f = remote_fixture('remote-perf')
  local t = vim.uv.hrtime()
  detect(f.review)
  local before = (vim.uv.hrtime() - t) / 1e6
  local main = vim.trim(h.git(f.review, 'rev-parse', 'origin/main'))
  local docs = vim.trim(h.git(f.review, 'rev-parse', 'origin/other/docs'))
  local cart = vim.trim(h.git(f.review, 'rev-parse', 'origin/stack/cart'))
  local lines = {}
  for i = 1, 3000 do
    -- most on trunk or another line; a few duplicates of a layer on other remotes
    local sha = (i % 300 == 0) and cart or (i % 2 == 0 and main or docs)
    local remote = (i % 300 == 0) and ('fork' .. i) or 'origin'
    lines[#lines + 1] = ('create refs/remotes/%s/bulk/branch-%04d %s'):format(remote, i, sha)
  end
  local res = vim.system({ 'git', 'update-ref', '--stdin' }, { cwd = f.review, stdin = table.concat(lines, '\n') .. '\n' }):wait()
  assert(res.code == 0, res.stderr)
  h.git(f.review, 'pack-refs', '--all')
  local t0 = vim.uv.hrtime()
  local st = detect(f.review)
  local ms = (vim.uv.hrtime() - t0) / 1e6
  io.write(('  perf: detect: %.0f ms with 3000 more remote branches (%.0f ms without)\n'):format(ms, before))
  h.eq({ 'origin/stack/math', 'origin/stack/cart', 'origin/stack/ui' }, names(st))
  h.eq(10, #(st.layers[2].also or {}))
  local t1 = vim.uv.hrtime()
  stack.fingerprint(f.review, 'origin/main')
  io.write(('  perf: fingerprint: %.0f ms\n'):format((vim.uv.hrtime() - t1) / 1e6))
  h.ok(ms < 3000, ('detect took %.0f ms'):format(ms))
end)

h.run()
