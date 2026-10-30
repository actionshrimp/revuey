-- Minimal test harness for `nvim --headless --clean -l tests/<name>_spec.lua`.
local M = {}

M.root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(M.root)

-- Hermetic git for everything spawned by tests (helpers, fixture script, revuey itself, child
-- Neovims, tmux): no user/system config, fixed identity and dates.
vim.env.GIT_CONFIG_GLOBAL = '/dev/null'
vim.env.GIT_CONFIG_NOSYSTEM = '1'
vim.env.GIT_AUTHOR_NAME, vim.env.GIT_AUTHOR_EMAIL = 'revuey', 'revuey@example.com'
vim.env.GIT_COMMITTER_NAME, vim.env.GIT_COMMITTER_EMAIL = 'revuey', 'revuey@example.com'
vim.env.GIT_AUTHOR_DATE, vim.env.GIT_COMMITTER_DATE = '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'

-- Never reach the user's terminal multiplexers (their live tmux, herdr, zellij or cmux session):
-- drop every variable that points at one, give tmux a private socket dir (so even a plain
-- `tmux` talks to a server of the tests' own), and put blockers for the others first on PATH;
-- a blocked call is logged to M.mux_blocked and fails with exit 97. tests/guard_spec.lua checks it.
for name in pairs(vim.fn.environ()) do
  if name:match('^HERDR_') or name:match('^TMUX') or name:match('^ZELLIJ') or name:match('^CMUX_') then
    vim.env[name] = nil
  end
end
-- short: a tmux socket path must fit in ~100 bytes
M.mux_dir = '/tmp/revuey-mux-' .. vim.uv.os_getpid()
vim.fn.delete(M.mux_dir, 'rf')
vim.fn.mkdir(M.mux_dir .. '/bin', 'p')
vim.env.TMUX_TMPDIR = M.mux_dir
M.mux_blocked = M.mux_dir .. '/blocked.log'
for _, tool in ipairs({ 'herdr', 'zellij', 'cmux' }) do
  local p = M.mux_dir .. '/bin/' .. tool
  vim.fn.writefile({
    '#!/bin/sh',
    ('echo "%s $*" >> %s'):format(tool, vim.fn.shellescape(M.mux_blocked)),
    ('echo "%s is blocked in revuey tests" >&2'):format(tool),
    'exit 97',
  }, p)
  vim.uv.fs_chmod(p, tonumber('755', 8))
end
-- the real `gh` and `wt` are never reached either (gh would call GitHub with the developer's
-- login; wt would too, and run the developer's worktrunk hooks and approvals): specs that need
-- them use the fakes (M.use_fake_gh, M.use_fake_wt)
for tool, fake in pairs({ gh = 'h.use_fake_gh', wt = 'h.use_fake_wt' }) do
  local p = M.mux_dir .. '/bin/' .. tool
  vim.fn.writefile({
    '#!/bin/sh',
    ('echo "%s $*" >> %s'):format(tool, vim.fn.shellescape(M.mux_blocked)),
    ('echo "%s is blocked in revuey tests (use %s)" >&2'):format(tool, fake),
    'exit 97',
  }, p)
  vim.uv.fs_chmod(p, tonumber('755', 8))
end
vim.env.PATH = M.mux_dir .. '/bin:' .. vim.env.PATH

-- Headless specs (no UI attached) must never grow the screen: Neovim 0.12.4 keeps the headless
-- grid at its startup size (80x24), so a larger 'columns'/'lines' makes the next redraw (the tab
-- line first) write past it, a heap overrun that crashes intermittently and far from the cause
-- (see docs/TESTING.md). Growing either is undone at once and fails the spec; shrinking is
-- harmless. Specs that need a bigger screen use a mini.test child (screen_spec.lua).
M.size_violations = {}
if #vim.api.nvim_list_uis() == 0 then
  local startup = { lines = vim.o.lines, columns = vim.o.columns }
  vim.api.nvim_create_autocmd('OptionSet', {
    pattern = { 'lines', 'columns' },
    callback = function(ev)
      local name = ev.match
      local new = tonumber(vim.v.option_new) or 0
      if new > startup[name] then
        vim.o[name] = startup[name]
        local msg = ("headless spec set '%s' to %d (the screen stays %d): use a child Neovim with a UI"):format(
          name,
          new,
          startup[name]
        )
        M.size_violations[#M.size_violations + 1] = msg
        if not M.size_quiet then
          error(msg)
        end
      end
    end,
  })
end

---Expose the user's installed tree-sitter *parsers* only (never their query overrides), via a temp
---runtime dir whose only entry is a `parser` symlink. Highlight queries come from Neovim's bundled
---runtime; tests must skip clearly when a language has none there.
function M.add_parsers_rtp()
  local parser_dir = vim.fn.expand('~/.local/share/nvim/site/parser')
  if not vim.uv.fs_stat(parser_dir) then
    return false
  end
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, 'p')
  vim.uv.fs_symlink(parser_dir, d .. '/parser')
  vim.opt.rtp:append(d)
  return true
end

---Put the fake `claude` (tests/bin/claude) first on PATH; it appends each call to `log`.
function M.use_fake_claude(log)
  vim.env.PATH = M.root .. '/tests/bin:' .. vim.env.PATH
  vim.env.REVUEY_FAKE_NVIM = vim.v.progpath
  vim.env.REVUEY_FAKE_CLAUDE_LOG = log
  vim.env.REVUEY_FAKE_CLAUDE = nil
end

---Put the fake `gh` (tests/bin/gh) first on PATH: it appends each call to `log` and answers
---GraphQL PR lookups from `prs` ({ ["owner/name:branch"] = { PullRequest nodes } }), written to
---a JSON file. `scenario` (REVUEY_FAKE_GH) picks a failure mode. `threads` ({ ["owner/name#N"] =
---{ review thread nodes } }) answers review-thread queries (none when nil). `post` (see
---tests/bin/fake_gh.lua: viewer, prs, files, reviews, fail) answers the posting preflight, the PR
---files and the review mutations, which are recorded to `log .. '.mutations.ndjson'`.
function M.use_fake_gh(log, prs, scenario, threads, post)
  vim.env.PATH = M.root .. '/tests/bin:' .. vim.env.PATH
  vim.env.REVUEY_FAKE_NVIM = vim.v.progpath
  vim.env.REVUEY_FAKE_GH_LOG = log
  vim.env.REVUEY_FAKE_GH = scenario
  vim.env.REVUEY_FAKE_GH_THREADS_SCENARIO = nil
  vim.env.REVUEY_FAKE_GH_CHECK_SCENARIO = nil
  vim.env.REVUEY_FAKE_GH_CHECK_DELAY = nil
  local file = log .. '.prs.json'
  vim.fn.writefile({ vim.json.encode(prs or vim.empty_dict()) }, file)
  vim.env.REVUEY_FAKE_GH_PRS = file
  local tfile = log .. '.threads.json'
  vim.fn.writefile({ vim.json.encode(threads or vim.empty_dict()) }, tfile)
  vim.env.REVUEY_FAKE_GH_THREADS = tfile
  local pfile = log .. '.post.json'
  vim.fn.writefile({ vim.json.encode(post or vim.empty_dict()) }, pfile)
  vim.env.REVUEY_FAKE_GH_POST = pfile
  vim.env.REVUEY_FAKE_GH_MUTATIONS = log .. '.mutations.ndjson'
end

---Put the fake `wt` (tests/bin/wt) first on PATH: it appends each call to `log` and handles
---`wt switch pr:<N>` with `scenario` (REVUEY_FAKE_WT), creating `<repo>.<branch>` worktrees for
---`branch` (REVUEY_FAKE_WT_BRANCH).
function M.use_fake_wt(log, scenario, branch)
  vim.env.PATH = M.root .. '/tests/bin:' .. vim.env.PATH
  vim.env.REVUEY_FAKE_WT_LOG = log
  vim.env.REVUEY_FAKE_WT = scenario
  vim.env.REVUEY_FAKE_WT_BRANCH = branch
  vim.env.REVUEY_FAKE_WT_HOOK = nil
end

---Calls recorded by a fake CLI's log (one JSON object per line).
function M.read_calls(log)
  local calls = {}
  for _, line in ipairs(vim.uv.fs_stat(log) and vim.fn.readfile(log) or {}) do
    if line ~= '' then
      calls[#calls + 1] = vim.json.decode(line)
    end
  end
  return calls
end

function M.tmpdir(name)
  local base = os.getenv('REVUEY_TEST_TMP') or vim.fn.tempname()
  local d = vim.fs.joinpath(base, name)
  vim.fn.delete(d, 'rf')
  vim.fn.mkdir(d, 'p')
  return d
end

---Create the TS fixture repo; returns its path.
function M.fixture()
  local d = M.tmpdir('fixture')
  vim.fn.delete(d, 'rf')
  local res = vim.system({ M.root .. '/scripts/make-fixture.sh', d }, { text = true }):wait()
  assert(res.code == 0, 'make-fixture failed: ' .. (res.stderr or ''))
  return d
end

---Run git in `dir` with a fixed identity/date; errors on failure.
function M.git(dir, ...)
  local cmd = { 'git', '-c', 'user.name=t', '-c', 'user.email=t@example.com', '-c', 'commit.gpgsign=false',
    '-c', 'init.defaultBranch=main', ... }
  local res = vim.system(cmd, { cwd = dir, text = true }):wait()
  assert(res.code == 0, table.concat(cmd, ' ') .. ': ' .. (res.stderr or ''))
  return res.stdout
end

---Write a file (raw bytes) under dir, creating parent directories.
function M.write(dir, path, content)
  local full = vim.fs.joinpath(dir, path)
  vim.fn.mkdir(vim.fs.dirname(full), 'p')
  local fd = assert(io.open(full, 'wb'))
  fd:write(content)
  fd:close()
end

---Create a repo: `base` files committed on main, then branch `feat` with `changes` committed.
---A value of false deletes the file.
function M.repo(name, base, changes)
  local d = M.tmpdir(name)
  M.git(d, 'init', '-q')
  for p, c in pairs(base) do
    M.write(d, p, c)
  end
  M.git(d, 'add', '-A')
  M.git(d, 'commit', '-q', '--allow-empty', '-m', 'base')
  M.git(d, 'checkout', '-q', '-b', 'feat')
  for p, c in pairs(changes or {}) do
    if c == false then
      vim.fn.delete(vim.fs.joinpath(d, p))
    else
      M.write(d, p, c)
    end
  end
  M.git(d, 'add', '-A')
  M.git(d, 'commit', '-q', '--allow-empty', '-m', 'feat')
  return d
end

---The stack-notes case from a real repo: old local branches built on an earlier version of the
---stack's bottom layer, which was amended since.
---  main ── a1 ── a2' (stack/a) ── b1 (stack/b, checked out) ── c1 (stack/c)
---              └─ a2 (pre-amend) ── one commit each on dave/abc-1058-apply-price-check,
---                                   dave/abc-1058-report-flow, dave/abc-1061-cleanup
---Dates are fixed (the amend one day later), so hashes are reproducible.
function M.old_branches_repo(name)
  local d = M.tmpdir(name)
  local saved = { vim.env.GIT_AUTHOR_DATE, vim.env.GIT_COMMITTER_DATE }
  vim.env.GIT_AUTHOR_DATE, vim.env.GIT_COMMITTER_DATE = '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'
  local function commit(file, text)
    M.write(d, file, text)
    M.git(d, 'add', '-A')
    M.git(d, 'commit', '-q', '-m', file)
  end
  M.git(d, 'init', '-q', '-b', 'main')
  commit('base.txt', 'base\n')
  M.git(d, 'checkout', '-q', '-b', 'stack/a')
  commit('a1.txt', 'a1\n')
  commit('a2.txt', 'a2\n')
  for _, b in ipairs({ 'dave/abc-1058-apply-price-check', 'dave/abc-1058-report-flow', 'dave/abc-1061-cleanup' }) do
    M.git(d, 'checkout', '-q', '-b', b, 'stack/a')
    commit(b:gsub('[^%w]', '_') .. '.txt', b .. '\n')
  end
  M.git(d, 'checkout', '-q', 'stack/a')
  vim.env.GIT_COMMITTER_DATE = '2026-01-02T00:00:00Z'
  M.write(d, 'a2.txt', 'a2 amended\n')
  M.git(d, 'commit', '-q', '-a', '--amend', '--no-edit')
  M.git(d, 'checkout', '-q', '-b', 'stack/b')
  commit('b.txt', 'b\n')
  M.git(d, 'checkout', '-q', '-b', 'stack/c')
  commit('c.txt', 'c\n')
  M.git(d, 'checkout', '-q', 'stack/b')
  vim.env.GIT_AUTHOR_DATE, vim.env.GIT_COMMITTER_DATE = saved[1], saved[2]
  return d
end

---A stack that branches on GitHub (the stack tree, stack_tree.lua), small but with the shapes of
---real ones: a chain, a fork with an open and a closed child, a closed two-PR chain off the
---middle, a branch moved to a new base with its old PR closed, and a fork's PR.
---
---  main ← #11 stack/a ← #12 stack/b ← #13 stack/c ← #15 stack/d (draft)
---                     │             ├ #14 stack/x (closed)
---                     │             └ #19 bob:fix-d (a fork's PR, open)
---                     ├ #16 stack/old1 (closed) ← #17 stack/old2 (closed, branch deleted)
---                     └ #10 stack/c (closed: stack/c's old PR, before it moved onto stack/b)
---
---`origin.git` is GitHub's side (every branch, `refs/pull/N/head`). `review` is a clone made
---before stack/c got a second commit and stack/d was pushed, on local branch stack/b: its
---origin/stack/c is behind GitHub's head, origin/stack/d and the commits of #10, #17 and #19 are
---missing. Its origin URL is GitHub's (`git@github.com:acme/shop.git`); fetches reach
---`origin.git` through tests/bin/fake-ssh (`M.use_fake_ssh`). Returns {dir, bare, author, oid =
---{name -> commit}, prs = PR file for M.use_fake_gh (`_tree` and per-branch lookups)}.
function M.tree_repo(name)
  local root = M.tmpdir(name)
  local bare, author, review = root .. '/origin.git', root .. '/author', root .. '/review'
  M.git(root, 'init', '--bare', '-q', '-b', 'main', bare)
  vim.fn.mkdir(author, 'p')
  M.git(author, 'init', '-q', '-b', 'main')
  M.git(author, 'remote', 'add', 'origin', bare)
  local oid = {}
  local function commit(key, file, text)
    M.write(author, file, text)
    M.git(author, 'add', '-A')
    M.git(author, 'commit', '-q', '-m', key)
    oid[key] = vim.trim(M.git(author, 'rev-parse', 'HEAD'))
  end
  local function co(...)
    M.git(author, 'checkout', '-q', ...)
  end
  commit('main', 'src/cart.ts', 'export const total = 0\n')
  co('-b', 'stack/a')
  commit('a', 'src/price.ts', 'export const price = 1\n')
  co('-b', 'old-c')
  commit('c_old', 'src/coupon.ts', 'export const coupon = "old"\n')
  co('stack/a')
  co('-b', 'stack/old1')
  commit('old1', 'src/legacy.ts', 'export const legacy = 1\n')
  co('-b', 'stack/old2')
  commit('old2', 'src/legacy2.ts', 'export const legacy2 = 2\n')
  co('stack/a')
  co('-b', 'stack/b')
  commit('b', 'src/tax.ts', 'export const tax = 0.2\n')
  co('-b', 'stack/x')
  commit('x', 'src/experiment.ts', 'export const x = true\n')
  co('stack/b')
  co('-b', 'fix-d')
  commit('fork', 'src/fix.ts', 'export const fix = 1\n')
  co('stack/b')
  co('-b', 'stack/c')
  commit('c1', 'src/coupon.ts', 'export const coupon = "new"\n')
  M.git(author, 'push', '-q', 'origin', 'main', 'stack/a', 'stack/b', 'stack/c', 'stack/x', 'stack/old1')
  M.git(root, 'clone', '-q', bare, review)
  M.git(review, 'checkout', '-q', 'stack/b')
  M.git(review, 'remote', 'set-url', 'origin', 'git@github.com:acme/shop.git')
  -- after the clone: GitHub moves on
  commit('c2', 'src/coupon.ts', 'export const coupon = "new"\nexport const max = 3\n')
  co('-b', 'stack/d')
  commit('d', 'src/discount.ts', 'export const discount = 5\n')
  M.git(author, 'push', '-q', 'origin', 'stack/c', 'stack/d', 'old-c:refs/pull/10/head', 'stack/a:refs/pull/11/head',
    'stack/b:refs/pull/12/head', 'stack/c:refs/pull/13/head', 'stack/x:refs/pull/14/head', 'stack/d:refs/pull/15/head',
    'stack/old1:refs/pull/16/head', 'stack/old2:refs/pull/17/head', 'fix-d:refs/pull/19/head')
  local function pr(number, head, base, state, commit_key, updated, extra)
    return vim.tbl_extend('force', {
      number = number,
      title = ({
        [10] = 'Coupons (first try)', [11] = 'Prices per item', [12] = 'Tax on the cart total', [13] = 'Coupon codes',
        [14] = 'Experiment: free shipping', [15] = 'Discounts for members', [16] = 'Legacy price rules',
        [17] = 'Legacy price rules, part 2', [19] = 'Fix the discount rounding',
      })[number],
      url = 'https://github.com/acme/shop/pull/' .. number,
      state = state,
      isDraft = false,
      updatedAt = updated,
      headRefName = head,
      baseRefName = base,
      headRefOid = oid[commit_key],
      isCrossRepository = false,
      headRepositoryOwner = { login = 'acme' },
      reviewDecision = state == 'OPEN' and 'REVIEW_REQUIRED' or vim.NIL,
    }, extra or {})
  end
  local nodes = {
    pr(10, 'stack/c', 'stack/a', 'CLOSED', 'c_old', '2026-01-02T00:00:00Z'),
    pr(11, 'stack/a', 'main', 'OPEN', 'a', '2026-01-05T00:00:00Z', { reviewDecision = 'APPROVED' }),
    pr(12, 'stack/b', 'stack/a', 'OPEN', 'b', '2026-01-05T01:00:00Z'),
    pr(13, 'stack/c', 'stack/b', 'OPEN', 'c2', '2026-01-05T02:00:00Z', { reviewDecision = 'CHANGES_REQUESTED' }),
    pr(14, 'stack/x', 'stack/b', 'CLOSED', 'x', '2026-01-03T00:00:00Z'),
    pr(15, 'stack/d', 'stack/c', 'OPEN', 'd', '2026-01-05T03:00:00Z', { isDraft = true }),
    pr(16, 'stack/old1', 'stack/a', 'CLOSED', 'old1', '2026-01-01T10:00:00Z'),
    pr(17, 'stack/old2', 'stack/old1', 'CLOSED', 'old2', '2026-01-01T11:00:00Z', { headRef = vim.NIL }),
    pr(19, 'fix-d', 'stack/b', 'OPEN', 'fork', '2026-01-04T00:00:00Z',
      { isCrossRepository = true, headRepositoryOwner = { login = 'bob' } }),
  }
  local prs = { _tree = { ['acme/shop'] = nodes } }
  for _, n in ipairs(nodes) do
    if not n.isCrossRepository then
      local k = 'acme/shop:' .. n.headRefName
      prs[k] = prs[k] or {}
      table.insert(prs[k], n)
    end
  end
  for _, list in pairs(prs) do
    if list[1] and list[1].updatedAt then
      table.sort(list, function(a, b)
        return a.updatedAt > b.updatedAt
      end)
    end
  end
  return { dir = review, bare = bare, author = author, oid = oid, prs = prs }
end

---`git fetch` from a `git@github.com:...` remote reaches `bare` (tests/bin/fake-ssh), never the
---network.
function M.use_fake_ssh(bare, log)
  vim.env.GIT_SSH_COMMAND = M.root .. '/tests/bin/fake-ssh'
  vim.env.REVUEY_FAKE_SSH_REPO = bare
  vim.env.REVUEY_FAKE_SSH_LOG = log
end

---Open a review and wait until it is shown. Returns the session.
function M.open_review(opts)
  local session
  opts = vim.tbl_extend('force', { base = 'main' }, opts)
  opts.on_ready = function(s)
    session = s
  end
  require('revuey').open(opts)
  vim.wait(10000, function()
    return session ~= nil
  end, 10)
  assert(session, 'review did not open')
  return session
end

---Capture vim.notify messages while running fn (restored afterwards).
function M.capture_notify()
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(msg, level)
    msgs[#msgs + 1] = { msg = msg, level = level }
  end
  return msgs, function()
    vim.notify = orig
  end
end

local tests, failures = {}, 0

function M.test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

local teardowns = {}

---Run `fn` after the spec's tests (in M.run, last registered first), whatever they did: stop
---child Neovims, tmux servers and other processes a spec started. Tests only run inside M.run,
---so cleanup written after the test definitions would run before them.
function M.teardown(fn)
  teardowns[#teardowns + 1] = fn
end

---A mini.test child Neovim, stopped after the spec's tests (M.teardown).
function M.child()
  local MiniTest = dofile(M.root .. '/tests/vendor/mini/test.lua')
  local child = MiniTest.new_child_neovim()
  M.teardown(function()
    child.stop()
  end)
  return child
end

function M.eq(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    error(
      (msg and (msg .. '\n') or '') .. 'expected: ' .. vim.inspect(expected) .. '\n  actual: ' .. vim.inspect(actual),
      2
    )
  end
end

function M.ok(cond, msg)
  if not cond then
    error(msg or 'assertion failed', 2)
  end
end

-- Skips are printed as `  skip <spec> :: <test> — <reason>` (CI's job summary matches this form).
local function skip_line(file, name, reason)
  io.write('  skip ' .. file .. ' :: ' .. name .. ' — ' .. reason .. '\n')
end

---Skip the current test (call inside h.test).
function M.skip(reason)
  error({ revuey_skip = reason }, 0)
end

---Exit this Neovim with `code`. os.exit skips Neovim's own exit, which removes its server
---socket and its temp dir ($TMPDIR/nvim.<user>/XXXXXX): every spec (and every fake CLI) would
---leave both behind, so they are removed here first.
function M.exit(code)
  io.flush()
  pcall(vim.fn.serverstop, vim.v.servername)
  pcall(vim.fn.delete, vim.fn.fnamemodify(vim.fn.tempname(), ':h'), 'rf')
  vim.fn.delete(M.mux_dir, 'rf')
  os.exit(code)
end

local function spec_file(level)
  return vim.fn.fnamemodify(debug.getinfo(level + 1, 'S').source:sub(2), ':t')
end

---Skip a whole spec file before any test runs (call at top level); exits the process.
function M.skip_spec(reason)
  skip_line(spec_file(2), '(all tests)', reason)
  M.exit(0)
end

-- CI runs every test: a missing prerequisite there fails instead of skipping.
local function on_ci()
  local ci = os.getenv('CI')
  return ci ~= nil and ci ~= '' and ci ~= 'false' and ci ~= '0'
end

local function frame(msg)
  local body = vim.json.encode(msg)
  return ('Content-Length: %d\r\n\r\n%s'):format(#body, body)
end

---Start typescript-language-server in an empty dir and initialize it (which is where it looks for
---tsserver and fails when it finds none), then shut it down. Returns why it is unusable, or nil.
---(~0.1s either way; a server that fails at initialize would otherwise cost each LSP test its
---whole 20s wait.)
local function probe_ts_ls()
  if vim.fn.executable('typescript-language-server') ~= 1 then
    return 'typescript-language-server not on PATH'
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local buf, msgs = '', {}
  local started, proc = pcall(vim.system, { 'typescript-language-server', '--stdio' }, {
    cwd = dir,
    env = { TMPDIR = dir }, -- (where it makes a dir for each tsserver it starts, and leaves it)
    stdin = true,
    stdout = function(_, data)
      buf = buf .. (data or '')
      while true do
        local head_end = buf:find('\r\n\r\n', 1, true)
        local len = head_end and tonumber(buf:sub(1, head_end):match('Content%-Length: (%d+)'))
        if not len or #buf < head_end + 3 + len then
          break
        end
        local ok, msg = pcall(vim.json.decode, buf:sub(head_end + 4, head_end + 3 + len))
        msgs[#msgs + 1] = ok and msg or {}
        buf = buf:sub(head_end + 4 + len)
      end
    end,
  })
  if not started then
    vim.fn.delete(dir, 'rf')
    return 'typescript-language-server does not start: ' .. tostring(proc)
  end
  local function answer(id, ms)
    local found
    vim.wait(ms, function()
      for _, m in ipairs(msgs) do
        if m.id == id then
          found = m
          return true
        end
      end
      return false
    end, 10)
    return found
  end
  proc:write(frame({
    jsonrpc = '2.0',
    id = 1,
    method = 'initialize',
    params = { processId = vim.uv.os_getpid(), rootUri = vim.uri_from_fname(dir), capabilities = vim.empty_dict() },
  }))
  local init = answer(1, 15000)
  if init and init.result then
    proc:write(frame({ jsonrpc = '2.0', id = 2, method = 'shutdown' }))
    answer(2, 5000)
    proc:write(frame({ jsonrpc = '2.0', method = 'exit' }))
  end
  proc:write(nil)
  proc:wait(5000) -- (killed when it outlives that)
  vim.fn.delete(dir, 'rf')
  if not init then
    return 'typescript-language-server did not answer initialize within 15s'
  elseif init.error then
    -- (its first sentence: "Could not find a valid TypeScript installation" with no tsserver)
    local why = tostring(init.error.message):gsub('^Request initialize failed with message: ', '')
    return 'typescript-language-server cannot start: ' .. (why:match('^(.-)%.%s') or why)
  end
end

local ts_ls_problem
---Why typescript-language-server cannot serve the LSP tests here, or nil when it can. Probed once
---per `make test` run (cached in $REVUEY_TEST_RUN), else once per spec.
function M.ts_ls_problem()
  if ts_ls_problem == nil then
    local run = os.getenv('REVUEY_TEST_RUN')
    local cache = run and run ~= '' and vim.fs.joinpath(run, 'ts_ls-probe')
    if cache and vim.uv.fs_stat(cache) then
      ts_ls_problem = vim.fn.readfile(cache)[1] or ''
    else
      ts_ls_problem = probe_ts_ls() or ''
      if cache then
        vim.fn.writefile({ ts_ls_problem }, cache .. '.' .. vim.uv.os_getpid())
        vim.uv.fs_rename(cache .. '.' .. vim.uv.os_getpid(), cache)
      end
    end
  end
  return ts_ls_problem ~= '' and ts_ls_problem or nil
end

---Register and enable `ts_ls` (typescript-language-server for the fixture's TypeScript).
function M.enable_ts_ls()
  vim.lsp.config('ts_ls', {
    cmd = { 'typescript-language-server', '--stdio' },
    -- it leaves a dir in $TMPDIR for each tsserver it starts: keep them with the spec's files
    cmd_env = { TMPDIR = M.tmpdir('ts_ls-tmp-' .. vim.uv.os_getpid()) },
    filetypes = { 'typescript', 'typescriptreact' },
    root_markers = { 'tsconfig.json' },
  })
  vim.lsp.enable('ts_ls')
end

---Inside a test that needs a working typescript-language-server: skip it when there is none
---(fail on CI, which must run it), else enable `ts_ls`.
function M.need_ts_ls()
  local why = M.ts_ls_problem()
  if why and on_ci() then
    error('CI must run the LSP tests: ' .. why, 2)
  elseif why then
    M.skip(why)
  end
  M.enable_ts_ls()
end

---At the top of a spec that needs a working typescript-language-server: skip the whole spec when
---there is none (fail it on CI), else enable `ts_ls`.
function M.need_ts_ls_spec()
  local why = M.ts_ls_problem()
  if why and on_ci() then
    io.write('  FAIL ' .. spec_file(2) .. ' :: (all tests) — CI must run the LSP tests: ' .. why .. '\n')
    M.exit(1)
  elseif why then
    skip_line(spec_file(2), '(all tests)', why)
    M.exit(0)
  end
  M.enable_ts_ls()
end

local function on_error(err)
  if type(err) == 'table' and err.revuey_skip then
    return err
  end
  return debug.traceback(tostring(err), 2)
end

function M.run()
  local file = spec_file(2)
  for _, t in ipairs(tests) do
    local ok, err = xpcall(t.fn, on_error)
    if ok then
      io.write('  ok   ' .. file .. ' :: ' .. t.name .. '\n')
    elseif type(err) == 'table' and err.revuey_skip then
      skip_line(file, t.name, err.revuey_skip)
    else
      failures = failures + 1
      io.write('  FAIL ' .. file .. ' :: ' .. t.name .. '\n' .. tostring(err) .. '\n')
    end
  end
  for _, msg in ipairs(M.size_violations) do
    failures = failures + 1
    io.write('  FAIL ' .. file .. ' :: ' .. msg .. '\n')
  end
  io.flush()
  for i = #teardowns, 1, -1 do
    local ok, err = pcall(teardowns[i])
    if not ok then
      failures = failures + 1
      io.write('  FAIL teardown: ' .. tostring(err) .. '\n')
    end
  end
  io.flush()
  -- os.exit skips VimLeavePre: stop any AI CLI a test left running
  local ai = package.loaded['revuey.ai']
  if ai then
    ai.kill_all()
  end
  -- a private tmux server a spec started is gone with its socket dir
  pcall(function()
    vim.system({ 'tmux', 'kill-server' }):wait(2000)
  end)
  M.exit(failures == 0 and 0 or 1)
end

return M
