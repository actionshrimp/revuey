-- Remote PR review via worktrunk (`:Revuey pr <N|url>`, `bin/revuey pr`; pr.lua, pr_view.lua):
-- argument parsing, the wt command line, wt's JSON result and error output (unit, with stderr
-- captured from the real wt 0.81), then real git repositories with a fake `wt` (tests/bin/wt)
-- on PATH: the review opening in the PR's worktree, the stack there, progress, errors, cancel,
-- the approval terminal and bin/revuey pr. Never the real wt, gh or GitHub.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')

local state_dir = h.tmpdir('pr-state')
-- failures are logged: to a log of the spec's own, never the developer's revuey.log
local log_file = h.tmpdir('pr-log') .. '/revuey.log'
require('revuey').setup({ state_dir = state_dir, lsp_warmup = false, log_file = log_file })
local pr = require('revuey.pr')
local pr_view = require('revuey.pr_view')
local view = require('revuey.view')

local log = h.tmpdir('pr-wt') .. '/calls.jsonl'
h.use_fake_wt(log)
-- `gh repo set-default --view` (offline) for the URL check; nothing else calls gh here
h.use_fake_gh(h.tmpdir('pr-gh') .. '/calls.jsonl')

-- progress messages (nvim_echo kind=progress) as the Progress event reports them; not shown
-- in the test output
local progress = {}
vim.api.nvim_create_autocmd('Progress', {
  pattern = 'revuey',
  callback = function(ev)
    local text = type(ev.data.text) == 'table' and table.concat(ev.data.text, '') or ev.data.text
    progress[#progress + 1] = { status = ev.data.status, text = text, title = ev.data.title }
  end,
})
vim.o.messagesopt = 'hit-enter,history:500,progress:'

-- ---------------------------------------------------------------------------
-- Unit
-- ---------------------------------------------------------------------------

h.test('parse_arg: a number, #N, pr:N or a pull request URL; anything else is refused', function()
  h.eq({ number = 12 }, pr.parse_arg('12'))
  h.eq({ number = 12 }, pr.parse_arg(' #12 '))
  h.eq({ number = 12 }, pr.parse_arg('pr:12'))
  local repo = { host = 'github.com', owner = 'Acme', name = 'shop' }
  h.eq({ number = 7, repo = repo }, pr.parse_arg('https://github.com/Acme/shop/pull/7'))
  h.eq({ number = 7, repo = repo }, pr.parse_arg('https://GitHub.com/Acme/shop/pull/7/files#diff-1'))
  h.eq({ number = 7, repo = { host = 'github.example.com', owner = 'a', name = 'b' } }, pr.parse_arg('https://github.example.com/a/b/pull/7'))
  local p, err = pr.parse_arg('feature/x')
  h.eq(nil, p)
  h.eq('not a pull request number or URL: feature/x', err)
  h.eq('which pull request? Give its number or URL', select(2, pr.parse_arg(nil)))
  h.eq(nil, (pr.parse_arg('https://github.com/acme/shop/issues/7')))
  h.eq(nil, (pr.parse_arg('12abc')))
end)

h.test('check_repo: a URL must name the clone\'s GitHub repo, host included (wt looks the number up there)', function()
  local base = { host = 'github.com', owner = 'acme', name = 'shop' }
  h.eq(nil, pr.check_repo({ number = 7 }, nil), 'a bare number is left to wt')
  h.eq(nil, pr.check_repo({ number = 7, repo = { host = 'github.com', owner = 'ACME', name = 'Shop' } }, base))
  h.eq(nil, pr.check_repo({ number = 7, repo = { host = 'www.github.com', owner = 'acme', name = 'shop' } }, base))
  h.eq(
    'PR #7 is in other/thing, but this clone is acme/shop: open it from a clone of other/thing',
    pr.check_repo({ number = 7, repo = { host = 'github.com', owner = 'other', name = 'thing' } }, base)
  )
  h.eq(
    'this clone has no GitHub repo wt would use, so other/thing#7 cannot be opened here',
    pr.check_repo({ number = 7, repo = { host = 'github.com', owner = 'other', name = 'thing' } }, nil)
  )
  -- a GitHub Enterprise clone and a github.com URL of the same owner/name
  local ghe = { host = 'git.corp.net', owner = 'acme', name = 'shop' }
  h.eq(
    'PR #7 is on github.com (acme/shop), but this clone is on git.corp.net (acme/shop): open it from a clone of github.com/acme/shop',
    pr.check_repo({ number = 7, repo = { host = 'github.com', owner = 'acme', name = 'shop' } }, ghe, { 'git.corp.net' })
  )
  h.eq(nil, pr.check_repo({ number = 7, repo = { host = 'git.corp.net', owner = 'acme', name = 'shop' } }, ghe, { 'git.corp.net' }))
end)

h.test('pick_wt_repo: as wt picks it (gh\'s default repo, else the first GitHub remote in config order)', function()
  local function key(r)
    return r and (r.host .. '/' .. r.owner .. '/' .. r.name) or nil
  end
  local fork = {
    { name = 'upstream', url = 'git@github.com:acme/shop.git' },
    { name = 'origin', url = 'git@github.com:me/shop.git' },
  }
  h.eq('github.com/acme/shop', key(pr.pick_wt_repo(nil, fork)), 'config order, no origin preference')
  h.eq('github.com/acme/shop', key(pr.pick_wt_repo('', fork)))
  h.eq('github.com/me/shop', key(pr.pick_wt_repo('me/shop\n', fork)), 'gh\'s default wins')
  h.eq('github.com/other/thing', key(pr.pick_wt_repo('other/thing', fork)), 'a default naming no remote')
  local gitlab = {
    { name = 'origin', url = 'git@gitlab.com:acme/shop.git' },
    { name = 'local', url = '/srv/git/shop.git' },
    { name = 'gh', url = 'https://github.com/acme/shop.git' },
  }
  h.eq('github.com/acme/shop', key(pr.pick_wt_repo(nil, gitlab)), 'other forges and paths skipped')
  local ghe = { { name = 'origin', url = 'git@git.corp.net:acme/shop.git' } }
  h.eq('git.corp.net/acme/shop', key(pr.pick_wt_repo('acme/shop', ghe, { 'git.corp.net' })), 'the default\'s host from its remote')
  h.eq(nil, pr.pick_wt_repo(nil, {}))
end)

h.test('argv: wt switch pr:N --no-cd --format json, never --yes; the terminal form sends stdout to a file', function()
  local argv = pr.argv('wt', 42)
  h.eq({ 'wt', 'switch', 'pr:42', '--no-cd', '--format', 'json' }, argv)
  h.ok(not vim.tbl_contains(argv, '--yes') and not vim.tbl_contains(argv, '-y'))
  h.eq({ 'sh', '-c', 'exec "$@" > "$0"', '/tmp/out', 'wt', 'switch', 'pr:42', '--no-cd', '--format', 'json' }, pr.term_argv('wt', 42, '/tmp/out'))
  -- the shell form really splits stdout from stderr
  local out = vim.fn.tempname()
  local res = vim.system({ 'sh', '-c', 'exec "$@" > "$0"', out, 'sh', '-c', 'echo json; echo progress >&2' }, { text = true }):wait()
  h.eq('progress\n', res.stderr)
  h.eq({ 'json' }, vim.fn.readfile(out))
end)

h.test('parse_result: the JSON line of wt switch --format json (created or existing)', function()
  h.eq(
    { path = '/w/shop.feat', branch = 'feat', action = 'created' },
    pr.parse_result('{"action":"created","branch":"feat","path":"/w/shop.feat","created_branch":false,"from_remote":"origin/feat"}\n')
  )
  h.eq({ path = '/w/a b', branch = 'x', action = 'existing' }, pr.parse_result('noise\n{"action":"existing","branch":"x","path":"/w/a b"}\n'))
  h.eq(nil, pr.parse_result(''))
  h.eq(nil, pr.parse_result('{"action":"created"}'))
  h.eq(nil, pr.parse_result('{not json'))
end)

-- stderr of the real wt 0.81 (non-interactive: no colours), for the failure cases
local REAL = {
  approval = table.concat({
    '◎ Fetching PR #7...',
    '  T (#7)',
    '  by @bob · open · prhead · https://github.com/acme/shop/pull/7',
    '◎ Fetching prhead from origin...',
    '▲ shop needs approval to execute 2 commands:',
    '○ pre-start install:',
    '  npm ci',
    '○ pre-start build:',
    '  npm run build',
    '✗ Cannot prompt for approval in non-interactive environment',
    '↳ To skip prompts in CI/CD, add --yes; to pre-approve commands, run wt config approvals add --yes',
    '',
  }, '\n'),
  hook = table.concat({
    '◎ Running pre-start project:install @ /w/repo.feat2',
    '  echo installing',
    'installing',
    '◎ Running pre-start project:build @ /w/repo.feat2',
    '  npm run build',
    'building',
    '✗ pre-start project:build failed (exit code 3)',
    '↳ To skip pre-start hooks, re-run with --no-hooks',
    '',
  }, '\n'),
  nogh = '◎ Fetching PR #5...\n✗ GitHub CLI (gh) not installed; install from https://cli.github.com/\n',
  notgithub = '◎ Fetching PR #5...\n✗ No GitHub remote configured\n',
  unknown = '◎ Fetching PR #5...\n✗ gh api failed for PR #5\n  HTTP 404: Not Found (https://api.github.com/repos/acme/shop/pulls/5)\n',
}

h.test('failure: approval needed (with the commands), a failed pre-start hook (worktree left), plain errors', function()
  local f = pr.failure(1, REAL.approval)
  h.eq('approval', f.kind)
  h.eq({ 'pre-start install: npm ci', 'pre-start build: npm run build' }, f.commands)
  local msg = pr.failure_message(7, f)
  h.ok(msg:find('worktrunk needs your approval', 1, true), msg)
  h.ok(msg:find('  pre-start build: npm run build', 1, true), msg)
  h.ok(msg:find('`wt config approvals add`', 1, true), msg)
  h.ok(not msg:find('add --yes', 1, true), 'revuey does not suggest --yes: ' .. msg)

  f = pr.failure(3, REAL.hook)
  h.eq({
    kind = 'hook',
    path = '/w/repo.feat2',
    text = 'pre-start project:build failed (exit code 3)\nTo skip pre-start hooks, re-run with --no-hooks',
    output = { 'building' },
  }, f)
  f.log = '/state/revuey.log'
  msg = pr.failure_message(9, f)
  h.ok(msg:find('--no-hooks\n  building\n', 1, true), 'the hook\'s last lines, not wt\'s echo of the command: ' .. msg)
  h.ok(msg:find("(the end of wt's output is in /state/revuey.log)", 1, true), msg)
  h.ok(msg:find('wt switch pr:9 failed: pre-start project:build failed (exit code 3)', 1, true), msg)
  h.ok(msg:find("The worktree was created at /w/repo.feat2", 1, true), msg)
  h.ok(msg:find("`wt remove '/w/repo.feat2'`", 1, true), msg)
  h.ok(msg:find("`wt -C '/w/repo.feat2' hook pre-start` re-runs it", 1, true), msg)

  h.eq({ kind = 'failed', text = 'GitHub CLI (gh) not installed; install from https://cli.github.com/' }, pr.failure(1, REAL.nogh))
  h.eq({ kind = 'failed', text = 'No GitHub remote configured' }, pr.failure(1, REAL.notgithub))
  h.eq('gh api failed for PR #5\nHTTP 404: Not Found (https://api.github.com/repos/acme/shop/pulls/5)', pr.failure(1, REAL.unknown).text)
  h.eq({ kind = 'failed', text = 'wt exited with code 2' }, pr.failure(2, ''))
  h.eq('last words', pr.failure(1, 'a\nb\nlast words\n').text:match('last words'))
  -- only the last few lines before the error, never wt's earlier steps
  local long = { '◎ Running pre-start project:build @ /w/x' }
  for i = 1, 20 do
    long[#long + 1] = 'line ' .. i
  end
  long[#long + 1] = '✗ pre-start project:build failed (exit code 1)'
  h.eq({ 'line 16', 'line 17', 'line 18', 'line 19', 'line 20' }, pr.failure(1, table.concat(long, '\n')).output)
  -- progress redrawn with \r, a hook's own ✗ line, wt's multi-line command echo
  f = pr.failure(1, table.concat({
    '◎ Running pre-start project:build @ /w/x',
    '  npm ci &&',
    '  npm run build',
    'fetch 10%\rfetch 50%\rfetch 100%\r',
    '✗ 2 tests failed',
    'see above',
    '✗ pre-start project:build failed (exit code 1)',
    '',
  }, '\n'))
  h.eq('pre-start project:build failed (exit code 1)', f.text, 'wt\'s own (last) ✗ line')
  h.eq({ 'fetch 100%', '2 tests failed', 'see above' }, f.output)
  h.eq('fetch 100%', pr.plain('fetch 10%\rfetch 100%\r\r'))
end)

h.test('clean: wt glyphs and ANSI codes go; created_path finds the worktree the hooks ran in', function()
  h.eq('Running pre-start project:x @ /w', pr.clean('\27[36m◎\27[39m \27[36mRunning pre-start \27[1mproject:x\27[22m @ /w\27[39m\r'))
  h.eq('Created worktree', pr.clean('✓ Created worktree'))
  h.eq('plain output', pr.clean('  plain output  '))
  h.eq('/w/repo.feat2', pr.created_path(REAL.hook))
  h.eq(nil, pr.created_path(REAL.nogh))
end)

-- ---------------------------------------------------------------------------
-- Integration: real repositories, the fake wt
-- ---------------------------------------------------------------------------

---A clone with a GitHub origin (config only: nothing fetches) and the PR's branch `feat`
---(main <- feat), with main checked out.
local function clone(name, stacked)
  local d = h.repo(name, { ['base.txt'] = 'base\n' }, { ['feat.txt'] = 'feature work\n' })
  if stacked then
    h.git(d, 'checkout', '-q', '-b', 'feat-top')
    h.write(d, 'top.txt', 'on top\n')
    h.git(d, 'add', '-A')
    h.git(d, 'commit', '-q', '-m', 'top')
  end
  h.git(d, 'checkout', '-q', 'main')
  h.git(d, 'remote', 'add', 'origin', 'git@github.com:acme/shop.git')
  return d
end

local function reset(scenario, branch)
  if pr_view.current then
    pr_view.cancel()
  end
  view.close()
  for _, f in ipairs({ log, log .. '.pid', log .. '.kids' }) do
    vim.fn.delete(f)
  end
  progress = {}
  h.use_fake_wt(log, scenario, branch)
end

---Run `:Revuey pr <arg>` from `cwd` and wait for the review to open (or `ms` to pass).
local function open_pr(arg, cwd, ms)
  local session
  require('revuey').pr(arg, {
    cwd = cwd,
    on_open = function(s)
      session = s
    end,
  })
  vim.wait(ms or 10000, function()
    return session ~= nil
  end, 10)
  return session
end

local function real(p)
  return vim.uv.fs_realpath(p) or p
end

h.test(':Revuey pr 7 runs wt switch pr:7 in the clone and opens the review in the new worktree (:tcd there)', function()
  local d = clone('pr-open')
  reset('ok', 'feat')
  local cwd = vim.fn.getcwd()
  local s = open_pr('7', d)
  h.ok(s, 'review opened')
  local wt_path = d .. '.feat'
  h.eq(real(wt_path), real(s.review.root))
  h.eq('feat', s.review.branch)
  h.eq('main', s.review.base)
  h.eq({ 'feat.txt' }, vim.tbl_map(function(f)
    return f.path
  end, s.review.files))
  -- the review's tab works in the worktree; the other tabs keep their directory
  h.eq(real(wt_path), real(vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(s.tab))))
  h.eq(1, vim.fn.haslocaldir(-1, vim.api.nvim_tabpage_get_number(s.tab)), ':tcd, not :cd')
  h.eq(cwd, vim.fn.getcwd(-1, -1), 'the global cwd is unchanged')
  local calls = h.read_calls(log)
  h.eq(1, #calls)
  h.eq({ 'wt', 'switch', 'pr:7', '--no-cd', '--format', 'json' }, calls[1].argv)
  h.eq(real(d), real(calls[1].cwd))
  h.eq(false, calls[1].tty, 'background run: no terminal, so wt cannot wait for an answer')
  h.eq('success', progress[#progress].status)
  h.eq('PR #7', progress[#progress].title)
  h.ok(progress[#progress].text:find(wt_path, 1, true), progress[#progress].text)
  h.eq(nil, pr_view.current)
  -- closing the review closes its tab and its directory with it
  view.close()
  h.eq(cwd, vim.fn.getcwd())
end)

h.test('again: the existing worktree is reused; a URL of the same repo works too', function()
  local d = clone('pr-again')
  reset('ok', 'feat')
  h.ok(open_pr('7', d), 'first')
  view.close()
  local s = open_pr('https://github.com/acme/shop/pull/7', d)
  h.ok(s, 'second')
  h.eq(real(d .. '.feat'), real(s.review.root))
  h.ok(progress[#progress].text:find('(existing)', 1, true), progress[#progress].text)
  h.eq({ 'wt', 'switch', 'pr:7', '--no-cd', '--format', 'json' }, h.read_calls(log)[2].argv, 'the URL becomes pr:7')
end)

h.test('the stack in the PR worktree is detected as for any branch (local branches below)', function()
  local d = clone('pr-stack', true)
  reset('ok', 'feat-top')
  local s = open_pr('8', d)
  h.ok(s, 'review opened')
  h.ok(s.review.stack, 'a stack')
  h.eq({ 'feat', 'feat-top' }, vim.tbl_map(function(l)
    return l.name
  end, s.review.stack.layers))
  h.eq('feat-top', s.review.stack.layers[s.review.stack.current].name)
  h.eq({ 'top.txt' }, vim.tbl_map(function(f)
    return f.path
  end, s.review.files), 'the layer shows only its own change')
end)

h.test('progress while wt runs; the review (and its LSP buffers) only start once wt switch returns, hooks done', function()
  local d = clone('pr-slow')
  reset('slow', 'feat')
  vim.env.REVUEY_FAKE_WT_DELAY = '1'
  vim.env.REVUEY_FAKE_WT_HOOK = 'mkdir -p dist && echo built > dist/index.d.ts'
  local session
  require('revuey').pr('7', { cwd = d, on_open = function(s)
    session = s
  end })
  local wt_path = d .. '.feat'
  -- wt is inside its pre-start hook: the worktree exists, nothing is open there yet
  vim.wait(5000, function()
    return #progress > 0 and progress[#progress].text:find('Running pre-start', 1, true) ~= nil
  end, 10)
  h.ok(progress[#progress].text:find('Running pre-start project:build', 1, true), vim.inspect(progress))
  h.eq('running', progress[#progress].status)
  h.eq(nil, session)
  h.eq(nil, view.session)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    h.ok(not vim.startswith(vim.api.nvim_buf_get_name(b), real(wt_path)), 'no buffer in the worktree yet')
  end
  -- a second request meanwhile is refused
  local msgs, restore = h.capture_notify()
  require('revuey').pr('9', { cwd = d })
  restore()
  h.ok(msgs[1].msg:find('PR #7 is still being set up', 1, true), vim.inspect(msgs))
  vim.wait(10000, function()
    return session ~= nil
  end, 10)
  h.ok(session, 'opened after wt returned')
  h.eq({ 'built' }, vim.fn.readfile(wt_path .. '/dist/index.d.ts'), 'the pre-start build finished first')
  h.eq(1, #h.read_calls(log), 'the refused request never ran wt')
  vim.env.REVUEY_FAKE_WT_HOOK = nil
end)

h.test('errors: no wt, not a repo, a URL of another repo, a bad argument, and wt\'s own (no gh, no GitHub remote, unknown PR)', function()
  local d = clone('pr-errors')
  local function run(arg, cwd, scenario, cfg)
    reset(scenario, 'feat')
    if cfg then
      require('revuey').setup(vim.tbl_extend('force', { state_dir = state_dir, lsp_warmup = false, log_file = log_file }, cfg))
    end
    local msgs, restore = h.capture_notify()
    local s = open_pr(arg, cwd, 3000)
    vim.wait(3000, function()
      return #msgs > 0 and pr_view.current == nil
    end, 10)
    restore()
    require('revuey').setup({ state_dir = state_dir, lsp_warmup = false, log_file = log_file })
    h.eq(nil, s, 'no review')
    h.eq(nil, pr_view.current)
    return msgs[#msgs] or {}, h.read_calls(log)
  end
  local m, calls = run('7', d, 'ok', { worktrunk = { cmd = 'wt-missing' } })
  h.eq('revuey: `wt-missing` (worktrunk) not found on PATH: install it (https://worktrunk.dev) or set worktrunk.cmd', m.msg)
  h.eq(0, #calls)
  m = run('7', h.tmpdir('pr-norepo'))
  h.ok(m.msg:find('not inside a git repository', 1, true), m.msg)
  m, calls = run('https://github.com/other/thing/pull/7', d)
  h.eq('revuey: PR #7 is in other/thing, but this clone is acme/shop: open it from a clone of other/thing', m.msg)
  h.eq(0, #calls, 'refused before wt runs')
  m = run('feature/x', d)
  h.eq('revuey: not a pull request number or URL: feature/x (:Revuey pr <number|url>, or :Revuey pr cancel)', m.msg)
  m = run('7', d, 'nogh')
  h.eq('revuey: wt switch pr:7 failed: GitHub CLI (gh) not installed; install from https://cli.github.com/', m.msg)
  h.eq(vim.log.levels.ERROR, m.level)
  m = run('7', d, 'notgithub')
  h.eq('revuey: wt switch pr:7 failed: No GitHub remote configured', m.msg)
  m = run('5', d, 'unknown')
  h.eq('revuey: wt switch pr:5 failed: gh api failed for PR #5\nHTTP 404: Not Found (https://api.github.com/repos/acme/shop/pulls/5)', m.msg)
  h.eq('failed', progress[#progress].status)
end)

h.test('a failed pre-start hook: no review; the message names the worktree left behind and wt remove', function()
  local d = clone('pr-hookfail')
  reset('hookfail', 'feat')
  local msgs, restore = h.capture_notify()
  local s = open_pr('7', d, 3000)
  restore()
  h.eq(nil, s)
  local msg = msgs[#msgs].msg
  h.ok(msg:find('wt switch pr:7 failed: pre-start project:build failed (exit code 3)', 1, true), msg)
  h.ok(msg:find('The worktree was created at ' .. d .. '.feat', 1, true), msg)
  h.ok(msg:find('wt remove', 1, true), msg)
  h.ok(msg:find("error TS2307: Cannot find module './gone'", 1, true), 'the hook\'s output: ' .. msg)
  h.ok(msg:find('hook pre-start` re-runs it', 1, true), msg)
  h.eq(1, vim.fn.isdirectory(d .. '.feat'), 'left for the user (wt remove)')
  local log_path = require('revuey.log').path()
  h.ok(msg:find("(the end of wt's output is in " .. log_path .. ')', 1, true), msg)
  local logged = vim.tbl_map(function(e)
    return e.msg
  end, vim.tbl_filter(function(e)
    return e.scope == 'pr'
  end, require('revuey.log').entries))
  h.ok(vim.tbl_contains(logged, '  ◎ Fetching PR #7...'), vim.inspect(logged))
  h.ok(vim.tbl_contains(logged, "  error TS2307: Cannot find module './gone'"), 'one log entry per line: ' .. vim.inspect(logged))
end)

h.test('long hook output: a bounded stderr tail, the created worktree tracked as lines arrive', function()
  local d = clone('pr-noisy')
  reset('ok', 'feat')
  -- 2MB of output from a failing pre-start hook, in small writes
  vim.env.REVUEY_FAKE_WT_HOOK = 'i=0; while [ $i -lt 20000 ]; do echo "compiling module $i of a large monorepo ......................................................................"; i=$((i+1)); done; exit 1'
  local msgs, restore = h.capture_notify()
  local s = open_pr('7', d, 20000)
  vim.wait(20000, function()
    return #msgs > 0
  end, 20)
  restore()
  vim.env.REVUEY_FAKE_WT_HOOK = nil
  h.eq(nil, s)
  local msg = msgs[#msgs].msg
  h.ok(msg:find('compiling module 19999', 1, true), msg)
  h.ok(msg:find('The worktree was created at ' .. d .. '.feat', 1, true), msg)
  -- the log gets the end only, a line per entry, so it does not rotate earlier diagnostics away
  local log = require('revuey.log')
  local n, bytes = 0, 0
  for _, e in ipairs(log.entries) do
    if e.scope == 'pr' and e.msg:find('compiling module', 1, true) then
      n, bytes = n + 1, bytes + #e.msg
      h.ok(#e.msg < 200, e.msg)
    end
  end
  h.ok(n > 10 and bytes <= pr.LOG_MAX, ('%d lines, %d bytes logged'):format(n, bytes))
  h.ok(vim.uv.fs_stat(log.path()).size < log.max_bytes, 'the log file was not rotated')
end)

h.test('progress redrawn with \\r only (no newlines): the latest update shows; a line without any end stays bounded', function()
  local d = clone('pr-cr')
  reset('ok', 'feat')
  -- 1MB without a line end, then a \r progress bar, then a pause so the last update can show
  vim.env.REVUEY_FAKE_WT_HOOK = [[i=0; while [ $i -lt 4000 ]; do printf '%0256d' 0; i=$((i+1)); done; ]]
    .. [[for p in 10 50 100; do printf '\rinstalling %d%%' $p; done; sleep 1]]
  local seen
  local t0 = vim.uv.hrtime()
  local s = open_pr('7', d, 30000)
  vim.env.REVUEY_FAKE_WT_HOOK = nil
  h.ok(s, 'opened')
  for _, p in ipairs(progress) do
    if p.text:find('installing 100%', 1, true) then
      seen = p.text
    end
  end
  h.ok(seen, 'the \\r update showed: ' .. vim.inspect(vim.tbl_map(function(p)
    return p.text
  end, progress)))
  h.ok((vim.uv.hrtime() - t0) / 1e9 < 15, 'no quadratic rescans')
end)

h.test('URLs are checked against the repo wt asks: gh\'s default, else the first GitHub remote in config order', function()
  local function layout(name, remotes, resolved)
    local d = clone(name)
    h.git(d, 'remote', 'remove', 'origin')
    for _, r in ipairs(remotes) do
      h.git(d, 'remote', 'add', r[1], r[2])
    end
    for remote, val in pairs(resolved or {}) do
      h.git(d, 'config', 'remote.' .. remote .. '.gh-resolved', val)
    end
    return d
  end
  local function try(d, url)
    reset('ok', 'feat')
    local msgs, restore = h.capture_notify()
    local s = open_pr(url, d, 3000)
    restore()
    view.close()
    return s ~= nil, msgs[#msgs] and msgs[#msgs].msg, #h.read_calls(log)
  end
  local ACME, ME = 'https://github.com/acme/shop/pull/12', 'https://github.com/me/shop/pull/12'
  -- after `gh repo fork` in an existing clone: origin renamed to upstream (first in the config),
  -- the fork added as origin; main tracks upstream
  local d = clone('pr-ghfork')
  h.git(d, 'remote', 'rename', 'origin', 'upstream')
  h.git(d, 'remote', 'add', 'origin', 'git@github.com:me/shop.git')
  local ok, m, calls = try(d, ME)
  h.eq(false, ok)
  h.eq('revuey: PR #12 is in me/shop, but this clone is acme/shop: open it from a clone of me/shop', m)
  h.eq(0, calls, 'wt (which would ask acme/shop for #12) never ran')
  h.ok((try(d, ACME)), 'the parent\'s URL is the one wt opens')
  local res = vim.system({ h.root .. '/bin/revuey', 'pr', ME }, { cwd = d, text = true }):wait(20000)
  h.eq(2, res.code)
  h.ok(res.stderr:find('this clone is acme/shop', 1, true), 'bin/revuey checks the same way: ' .. res.stderr)
  -- a remote added before origin is first
  d = layout('pr-before-origin', { { 'zfork', 'git@github.com:me/shop.git' }, { 'origin', 'git@github.com:acme/shop.git' } })
  h.ok((try(d, ME)), 'zfork (first in the config), not origin')
  h.eq(false, (try(d, ACME)))
  -- gh repo set-default: `base` on a remote, or an owner/name value
  d = layout('pr-resolved-base', { { 'origin', 'git@github.com:me/shop.git' }, { 'upstream', 'git@github.com:acme/shop.git' } }, { upstream = 'base' })
  h.ok((try(d, ACME)), 'gh-resolved = base')
  d = layout('pr-resolved-name', { { 'origin', 'git@github.com:me/shop.git' }, { 'upstream', 'git@github.com:acme/shop.git' } }, { origin = 'acme/shop' })
  h.ok((try(d, ACME)), 'gh-resolved = owner/name')
  h.eq(false, (try(d, ME)))
  -- a GitLab origin is skipped
  d = layout('pr-gitlab', { { 'origin', 'git@gitlab.com:acme/shop.git' }, { 'hub', 'git@github.com:acme/shop.git' } })
  h.ok((try(d, ACME)), 'the first GitHub remote')
end)

h.test(':Revuey pr cancel stops wt and the hook it runs (process group); the half-made worktree is named', function()
  local d = clone('pr-cancel')
  reset('hang', 'feat')
  require('revuey').pr('7', { cwd = d })
  vim.wait(5000, function()
    return pr_view.current and pr_view.current.job ~= nil
  end, 10)
  -- wt writes .kids after its `Running pre-start ... @ <path>` line. Wait for it without running
  -- the event loop, so that line is still unread in the pipe when cancel comes (as it can be
  -- for a user): the message must name the worktree all the same.
  local deadline = vim.uv.hrtime() + 5e9
  while not (vim.uv.fs_stat(log .. '.kids') and #vim.fn.readfile(log .. '.kids') > 0) and vim.uv.hrtime() < deadline do
    vim.uv.sleep(10)
  end
  local wt_pid = tonumber(vim.fn.readfile(log .. '.pid')[1])
  local kid = tonumber(vim.fn.readfile(log .. '.kids')[1])
  h.ok(wt_pid and kid, 'running')
  local msgs, restore = h.capture_notify()
  vim.cmd('Revuey pr cancel')
  vim.wait(5000, function()
    return #msgs > 0 and vim.uv.kill(wt_pid, 0) ~= 0 and vim.uv.kill(kid, 0) ~= 0
  end, 20)
  restore()
  h.ok(vim.uv.kill(wt_pid, 0) ~= 0, 'wt stopped')
  h.ok(vim.uv.kill(kid, 0) ~= 0, 'its hook stopped')
  h.ok(msgs[1].msg:find('cancelled wt switch pr:7; the worktree at ' .. d .. '.feat may be half set up', 1, true), vim.inspect(msgs))
  h.eq(nil, pr_view.current)
  h.eq(nil, view.session)
  msgs, restore = h.capture_notify()
  vim.cmd('Revuey pr cancel')
  restore()
  h.eq('revuey: no PR worktree is being set up', msgs[1].msg)
end)

h.test('a progress UI cancelling the message (status cancel) stops the run', function()
  local d = clone('pr-uicancel')
  reset('hang', 'feat')
  require('revuey').pr('7', { cwd = d })
  vim.wait(5000, function()
    return vim.uv.fs_stat(log .. '.kids') ~= nil and #vim.fn.readfile(log .. '.kids') > 0
  end, 10)
  local kid = tonumber(vim.fn.readfile(log .. '.kids')[1])
  local msgs, restore = h.capture_notify()
  vim.api.nvim_echo({ { 'cancel' } }, false, { kind = 'progress', id = 'revuey.pr', source = 'revuey', status = 'cancel' })
  vim.wait(5000, function()
    return pr_view.current == nil and vim.uv.kill(kid, 0) ~= 0
  end, 20)
  restore()
  h.eq(nil, pr_view.current)
  h.ok(vim.uv.kill(kid, 0) ~= 0, 'hook stopped')
  h.ok(msgs[1] and msgs[1].msg:find('cancelled', 1, true), vim.inspect(msgs))
end)

---Stub vim.ui.select: answer with item `idx`, recording the prompt.
local function answer(idx)
  local seen = {}
  local orig = vim.ui.select
  vim.ui.select = function(items, o, cb)
    seen[#seen + 1] = { items = items, prompt = o.prompt }
    vim.schedule(function()
      cb(items[idx], idx)
    end)
  end
  return seen, function()
    vim.ui.select = orig
  end
end

h.test('approval needed: offered in a terminal, where wt asks and the user answers; then the review opens', function()
  local d = clone('pr-approve')
  reset('approval', 'feat')
  local seen, restore = answer(1)
  local session
  require('revuey').pr('7', { cwd = d, on_open = function(s)
    session = s
  end })
  local term
  vim.wait(5000, function()
    term = pr_view.current and pr_view.current.term
    return term ~= nil
  end, 10)
  restore()
  h.ok(term, 'a terminal runs wt')
  h.ok(seen[1].prompt:find('worktrunk needs your approval', 1, true), seen[1].prompt)
  h.ok(seen[1].prompt:find('pre-start build: npm run build', 1, true), seen[1].prompt)
  h.eq('terminal', vim.bo[term.buf].buftype)
  -- wt's own prompt, answered by the user
  vim.wait(5000, function()
    return table.concat(vim.api.nvim_buf_get_lines(term.buf, 0, -1, false), '\n'):find('Allow and remember', 1, true) ~= nil
  end, 20)
  vim.api.nvim_chan_send(term.job, 'y\r')
  vim.wait(10000, function()
    return session ~= nil
  end, 10)
  h.ok(session, 'review opened')
  h.eq(real(d .. '.feat'), real(session.review.root))
  h.ok(not vim.api.nvim_buf_is_valid(term.buf), 'terminal gone')
  local calls = h.read_calls(log)
  h.eq(2, #calls)
  h.eq(false, calls[1].tty)
  h.eq(true, calls[2].tty, 'the second run has a terminal')
  h.eq({ 'wt', 'switch', 'pr:7', '--no-cd', '--format', 'json' }, calls[2].argv, 'still no --yes')
  vim.cmd('stopinsert')
end)

h.test('approval needed, declined in revuey: no terminal, the message says how to approve', function()
  local d = clone('pr-noapprove')
  reset('approval', 'feat')
  local _, restore = answer(2)
  local msgs, restore_n = h.capture_notify()
  require('revuey').pr('7', { cwd = d })
  vim.wait(5000, function()
    return #msgs > 0
  end, 10)
  restore()
  restore_n()
  h.eq(nil, pr_view.current)
  h.ok(msgs[1].msg:find('`wt config approvals add`', 1, true), msgs[1].msg)
  h.eq(1, #h.read_calls(log))
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    h.ok(vim.bo[b].buftype ~= 'terminal', 'no terminal')
  end
end)

h.test('a failing run in the approval terminal keeps the terminal (wt\'s output) and says so', function()
  local d = clone('pr-termfail')
  reset('approval', 'nope') -- no such branch: wt fails after the prompt
  local _, restore = answer(1)
  local msgs, restore_n = h.capture_notify()
  require('revuey').pr('7', { cwd = d })
  local term
  vim.wait(5000, function()
    term = pr_view.current and pr_view.current.term
    return term and table.concat(vim.api.nvim_buf_get_lines(term.buf, 0, -1, false), '\n'):find('Allow and remember', 1, true) ~= nil
  end, 20)
  restore()
  vim.api.nvim_chan_send(term.job, 'y\r')
  vim.wait(5000, function()
    return pr_view.current == nil
  end, 10)
  restore_n()
  h.eq('revuey: wt switch pr:7 failed (exit 1); its output is in the terminal', msgs[#msgs].msg)
  h.ok(vim.api.nvim_buf_is_valid(term.buf), 'terminal kept')
  vim.cmd('stopinsert')
  pcall(vim.api.nvim_buf_delete, term.buf, { force = true })
end)

h.test('leaving Neovim (ai.kill_all, as on VimLeavePre) stops a running wt and its hook', function()
  local d = clone('pr-killall')
  reset('hang', 'feat')
  require('revuey').pr('7', { cwd = d })
  vim.wait(5000, function()
    return vim.uv.fs_stat(log .. '.kids') ~= nil and #vim.fn.readfile(log .. '.kids') > 0
  end, 10)
  local wt_pid = tonumber(vim.fn.readfile(log .. '.pid')[1])
  local kid = tonumber(vim.fn.readfile(log .. '.kids')[1])
  h.ok(vim.uv.kill(wt_pid, 0) == 0 and vim.uv.kill(kid, 0) == 0, 'running')
  require('revuey.ai').kill_all()
  vim.wait(3000, function()
    return vim.uv.kill(wt_pid, 0) ~= 0 and vim.uv.kill(kid, 0) ~= 0
  end, 20)
  h.ok(vim.uv.kill(wt_pid, 0) ~= 0, 'wt stopped')
  h.ok(vim.uv.kill(kid, 0) ~= 0, 'its hook stopped')
  local msgs, restore = h.capture_notify()
  vim.wait(3000, function()
    return pr_view.current == nil
  end, 10)
  restore()
  h.eq(nil, pr_view.current)
  h.eq(nil, view.session)
end)

---Start `:Revuey pr 7` with approval needed, accept the terminal, and wait for wt's prompt.
---Returns the terminal, wt's pid and its output file.
local function approval_terminal(name)
  local d = clone(name)
  reset('approval', 'feat')
  local _, restore = answer(1)
  require('revuey').pr('7', { cwd = d })
  local term
  vim.wait(5000, function()
    term = pr_view.current and pr_view.current.term
    return term and table.concat(vim.api.nvim_buf_get_lines(term.buf, 0, -1, false), '\n'):find('Allow and remember', 1, true) ~= nil
  end, 20)
  restore()
  h.ok(term, 'terminal with the prompt')
  vim.cmd('stopinsert')
  return term, tonumber(vim.fn.readfile(log .. '.pid')[1]), term.out
end

local function no_term_left(term, pid, out)
  h.eq(nil, pr_view.current)
  h.ok(not vim.api.nvim_buf_is_valid(term.buf), 'terminal buffer gone')
  vim.wait(3000, function()
    return vim.uv.kill(pid, 0) ~= 0
  end, 20)
  h.ok(vim.uv.kill(pid, 0) ~= 0, 'wt stopped')
  h.eq(nil, vim.uv.fs_stat(out), 'output file removed')
end

h.test(':Revuey pr cancel while the approval terminal waits: wt stopped, terminal closed, nothing left', function()
  local term, pid, out = approval_terminal('pr-termcancel')
  local msgs, restore = h.capture_notify()
  vim.cmd('Revuey pr cancel')
  restore()
  h.eq('revuey: cancelled wt switch pr:7', msgs[1].msg)
  no_term_left(term, pid, out)
end)

h.test('the approval terminal closed by the user (:bd!, or :q on its window): wt stopped, and the message says so', function()
  for _, how in ipairs({ 'bd', 'q' }) do
    local term, pid, out = approval_terminal('pr-termclose-' .. how)
    local msgs, restore = h.capture_notify()
    if how == 'bd' then
      vim.cmd('bdelete! ' .. term.buf)
    else
      vim.api.nvim_set_current_win(vim.fn.win_findbuf(term.buf)[1])
      vim.cmd('quit')
    end
    vim.wait(3000, function()
      return #msgs > 0
    end, 10)
    restore()
    h.eq('revuey: stopped wt switch pr:7: its terminal was closed (:Revuey pr 7 starts again)', msgs[1] and msgs[1].msg, how)
    h.eq(1, #msgs, how)
    no_term_left(term, pid, out)
  end
end)

h.test('switching buffers in the approval terminal\'s window keeps wt waiting; :Revuey pr shows it again', function()
  local term, pid = approval_terminal('pr-termhide')
  local win = vim.fn.win_findbuf(term.buf)[1]
  vim.api.nvim_set_current_win(win)
  local msgs, restore = h.capture_notify()
  vim.cmd('enew') -- e.g. to read .config/wt.toml before approving
  vim.cmd('buffer #')
  vim.cmd('enew')
  vim.wait(300)
  h.eq({}, vim.fn.win_findbuf(term.buf), 'hidden')
  h.ok(pr_view.current and pr_view.current.term == term, 'still running')
  h.eq(0, vim.uv.kill(pid, 0), 'wt alive')
  h.eq(0, #msgs, vim.inspect(msgs))
  require('revuey').pr('7')
  restore()
  h.ok(msgs[1].msg:find('PR #7 waits for your answer in its terminal', 1, true), vim.inspect(msgs))
  h.eq(1, #vim.fn.win_findbuf(term.buf), 'shown again')
  vim.cmd('stopinsert')
  local session
  vim.api.nvim_chan_send(term.job, 'y\r')
  vim.wait(10000, function()
    session = view.session
    return session ~= nil
  end, 10)
  h.ok(session, 'opened after the answer')
end)

h.test('the approval terminal\'s output file goes after a successful run too', function()
  local term, _, out = approval_terminal('pr-termok')
  local session
  vim.api.nvim_chan_send(term.job, 'y\r')
  vim.wait(10000, function()
    session = view.session
    return session ~= nil
  end, 10)
  h.ok(session, 'opened')
  h.eq(nil, vim.uv.fs_stat(out))
end)

h.test(':Revuey completes pr, and cancel after it; a branch named pr is listed once', function()
  h.ok(vim.tbl_contains(vim.fn.getcompletion('Revuey p', 'cmdline'), 'pr'))
  h.eq({ 'cancel' }, vim.fn.getcompletion('Revuey pr ', 'cmdline'))
  local d = clone('pr-branch-pr')
  h.git(d, 'branch', 'pr')
  local cwd = vim.fn.getcwd()
  vim.cmd.cd(d)
  local list = vim.fn.getcompletion('Revuey p', 'cmdline')
  vim.cmd.cd(cwd)
  h.eq(1, #vim.tbl_filter(function(x)
    return x == 'pr'
  end, list), vim.inspect(list))
end)

-- ---------------------------------------------------------------------------
-- bin/revuey pr
-- ---------------------------------------------------------------------------

-- REVUEY_NVIM stand-in: the headless CLI runs for real; the UI launch records where it started
local fake_nvim = h.tmpdir('pr-bin') .. '/nvim'
vim.fn.writefile({
  '#!/bin/sh',
  'for a in "$@"; do [ "$a" = --headless ] && exec ' .. vim.fn.shellescape(vim.v.progpath) .. ' "$@"; done',
  'printf "%s\\n%s\\n" "$(pwd)" "$REVUEY_ARGS" > "$REVUEY_FAKE_UI"',
}, fake_nvim)
vim.uv.fs_chmod(fake_nvim, tonumber('755', 8))

local function bin(args, cwd, scenario)
  vim.fn.delete(log)
  local ui = h.tmpdir('pr-bin-ui') .. '/ui.txt'
  local env = { REVUEY_NVIM = fake_nvim, REVUEY_FAKE_UI = ui, REVUEY_FAKE_WT = scenario or 'ok', REVUEY_FAKE_WT_BRANCH = 'feat' }
  local res = vim.system(vim.list_extend({ h.root .. '/bin/revuey' }, args), { cwd = cwd, env = env, text = true }):wait(20000)
  return res, vim.uv.fs_stat(ui) and vim.fn.readfile(ui) or nil
end

h.test('bin/revuey pr 7: wt switch in the terminal, then the review UI starts in the worktree', function()
  local d = clone('pr-bin-ok')
  local res, ui = bin({ 'pr', '7' }, d)
  h.eq(0, res.code, res.stderr)
  h.ok(ui, 'the UI started')
  h.eq(real(d .. '.feat'), real(ui[1]))
  h.eq('', ui[2], 'the plain review (stack detection) in the worktree')
  h.ok(res.stderr:find('Running pre-start', 1, true), 'wt\'s progress shows: ' .. res.stderr)
  local calls = h.read_calls(log)
  h.eq({ 'wt', 'switch', 'pr:7', '--no-cd', '--format', 'json' }, calls[1].argv)
end)

h.test('bin/revuey pr: a URL of another repo, no argument and wt failures stop before the UI', function()
  local d = clone('pr-bin-errors')
  local res, ui = bin({ 'pr', 'https://github.com/other/thing/pull/7' }, d)
  h.eq(2, res.code)
  h.ok(res.stderr:find('PR #7 is in other/thing, but this clone is acme/shop', 1, true), res.stderr)
  h.eq(nil, ui)
  h.eq(0, #h.read_calls(log))
  res, ui = bin({ 'pr' }, d)
  h.eq(2, res.code)
  h.ok(res.stderr:find('which pull request?', 1, true), res.stderr)
  h.eq(nil, ui)
  res, ui = bin({ 'pr', '7' }, d, 'hookfail')
  h.eq(3, res.code)
  h.ok(res.stderr:find('pre-start project:build failed (exit code 3)', 1, true), res.stderr)
  h.ok(res.stderr:find('revuey: wt switch pr:7 failed (exit 3)', 1, true), res.stderr)
  h.eq(nil, ui)
end)

-- ---------------------------------------------------------------------------
-- LSP in the PR worktree (typescript-language-server, as lsp_spec.lua)
-- ---------------------------------------------------------------------------

h.test('gd in the PR review goes to the worktree\'s files (LSP root is the worktree)', function()
  h.need_ts_ls()
  local fixture = h.fixture()
  h.git(fixture, 'checkout', '-q', 'main')
  reset('ok', 'feature/cart')
  local s = open_pr('42', fixture)
  h.ok(s, 'review opened')
  local wt_path = real(fixture .. '.feature-cart')
  h.eq(wt_path, real(s.review.root))
  local row, col
  for r, e in ipairs(s.layout.map) do
    local f = s.review.files[e.file_idx or 0]
    if f and f.path == 'src/cart.ts' and (e.kind == 'add' or e.kind == 'ctx') then
      local c = s.layout.lines[r]:find('formatCurrency(this', 1, true)
      if c then
        row, col = r, c - 1
        break
      end
    end
  end
  h.ok(row, 'call found')
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_win_set_cursor(s.diff_win, { row, col })
  view.definition()
  local name
  vim.wait(20000, function()
    name = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
    return name:find('format', 1, true) ~= nil
  end, 50)
  h.ok(vim.startswith(real(name), wt_path .. '/'), 'opened in the worktree: ' .. name)
  for _, c in ipairs(vim.lsp.get_clients({ name = 'ts_ls' })) do
    h.eq(wt_path, real(c.root_dir), 'tsserver runs for the worktree')
  end
end)

h.teardown(function()
  if pr_view.current then
    pr_view.cancel()
  end
  for _, c in ipairs(vim.lsp.get_clients()) do
    c:stop(true)
  end
end)

h.run()
