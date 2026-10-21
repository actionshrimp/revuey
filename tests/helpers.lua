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

---Skip a whole spec file before any test runs (call at top level); exits the process.
function M.skip_spec(reason)
  local file = vim.fn.fnamemodify(debug.getinfo(2, 'S').source:sub(2), ':t')
  skip_line(file, '(all tests)', reason)
  io.flush()
  os.exit(0)
end

local function on_error(err)
  if type(err) == 'table' and err.revuey_skip then
    return err
  end
  return debug.traceback(tostring(err), 2)
end

function M.run()
  local file = vim.fn.fnamemodify(debug.getinfo(2, 'S').source:sub(2), ':t')
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
  io.flush()
  -- os.exit skips VimLeavePre: stop any AI CLI a test left running
  local ai = package.loaded['revuey.ai']
  if ai then
    ai.kill_all()
  end
  os.exit(failures == 0 and 0 or 1)
end

return M
