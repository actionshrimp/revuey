-- Guard: nothing in the suite can reach the user's own terminal multiplexer (their live tmux or
-- herdr session). helpers.lua drops the variables that point at one, gives tmux a private socket
-- dir and blocks herdr/zellij/cmux on PATH; this checks it from a subprocess, checks that every
-- spec talks to tmux through a private socket, and drives skill/revuey/launch.sh against fake
-- multiplexers only: it needs an explicit target, verifies it, and refuses otherwise.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')

local LAUNCH = h.root .. '/skill/revuey/launch.sh'

local function sh(script, env, cwd)
  return vim.system({ 'sh', '-c', script }, { env = env, cwd = cwd, text = true }):wait(30000)
end

local function blocked()
  local fd = io.open(h.mux_blocked)
  if not fd then
    return ''
  end
  local t = fd:read('*a')
  fd:close()
  return t
end

h.test('subprocesses see no multiplexer: no TMUX/HERDR variables, private tmux sockets, blocked herdr', function()
  local r = sh('env')
  h.eq(0, r.code)
  for line in r.stdout:gmatch('[^\n]+') do
    local name = line:match('^([%w_]+)=')
    if name and name ~= 'TMUX_TMPDIR' then
      h.ok(not (name:match('^TMUX') or name:match('^HERDR_') or name:match('^ZELLIJ') or name:match('^CMUX_')), line)
    end
  end
  h.ok(r.stdout:find('TMUX_TMPDIR=' .. h.mux_dir, 1, true), 'private tmux socket dir')
  for _, tool in ipairs({ 'herdr', 'zellij', 'cmux' }) do
    h.eq(h.mux_dir .. '/bin/' .. tool, vim.trim(sh('command -v ' .. tool).stdout))
    h.eq(97, sh(tool .. ' pane list').code)
  end
  if vim.fn.executable('tmux') == 1 then
    -- even a plain `tmux` talks to a server of our own (there is none)
    local t = sh('tmux list-sessions')
    h.ok(t.code ~= 0, t.stdout)
  end
end)

h.test('every spec talks to tmux through its own -L socket', function()
  for _, f in ipairs(vim.fn.glob(h.root .. '/tests/*_spec.lua', false, true)) do
    for n, line in ipairs(vim.fn.readfile(f)) do
      if line:find("{ 'tmux',", 1, true) and not f:find('guard_spec', 1, true) then
        h.ok(line:find("'-L'", 1, true), ('%s:%d uses tmux without -L: %s'):format(vim.fs.basename(f), n, line))
      end
    end
  end
end)

-- fake multiplexers: they log their arguments and never start anything
local fake = h.tmpdir('fake-mux')
local log = fake .. '/calls.log'
vim.fn.mkdir(fake .. '/bin', 'p')
vim.fn.writefile({
  '#!/bin/sh',
  'echo "tmux $*" >> ' .. vim.fn.shellescape(log),
  'case "$1" in',
  '  display-message) echo "$TMUX_PANE" ;;',
  '  split-window) echo "%42" ;;',
  'esac',
}, fake .. '/bin/tmux')
vim.fn.writefile({
  '#!/bin/sh',
  'echo "herdr $*" >> ' .. vim.fn.shellescape(log),
  'case "$2" in',
  '  get) echo \'{"result":{"pane":{"pane_id":"\'"$3"\'"}}}\' ;;',
  '  split) echo \'{"result":{"pane":{"pane_id":"p-new"}}}\' ;;',
  'esac',
}, fake .. '/bin/herdr')
vim.uv.fs_chmod(fake .. '/bin/tmux', tonumber('755', 8))
vim.uv.fs_chmod(fake .. '/bin/herdr', tonumber('755', 8))

local repo = h.repo('launch', { ['a.txt'] = 'a\n' }, { ['a.txt'] = 'b\n' })
local state = h.tmpdir('launch-state')

local function launch(args, env)
  vim.fn.delete(log)
  local cmd = { LAUNCH }
  vim.list_extend(cmd, args)
  local e = vim.tbl_extend('force', {
    PATH = fake .. '/bin:' .. vim.env.PATH,
    REVUEY_STATE_DIR = state,
    REVUEY_NVIM = vim.v.progpath,
    REVUEY_LAUNCH_TIMEOUT = '1',
  }, env or {})
  local r = vim.system(cmd, { cwd = repo, env = e, text = true }):wait(30000)
  local fd = io.open(log)
  r.calls = fd and fd:read('*a') or ''
  if fd then
    fd:close()
  end
  return r
end

h.test('launch.sh needs an explicit target and refuses one it cannot verify', function()
  local before = blocked()
  -- no target: refused, nothing called
  local r = launch({ repo })
  h.eq(2, r.code, r.stdout .. r.stderr)
  h.ok(r.stderr:find('--in tmux', 1, true), r.stderr)
  h.eq('', r.calls)
  -- tmux without a tmux pane to split
  r = launch({ '--in', 'tmux', repo })
  h.eq(2, r.code, r.stderr)
  h.eq('', r.calls)
  -- a pane the tmux server does not know
  r = launch({ '--in', 'tmux', repo }, { TMUX = '/nonexistent,1,0', TMUX_PANE = '%7', PATH = vim.env.PATH })
  h.eq(2, r.code, r.stderr)
  -- herdr without its environment, or a herdr that does not answer (the blocker)
  r = launch({ '--in', 'herdr', repo })
  h.eq(2, r.code, r.stderr)
  r = launch({ '--in', 'herdr', repo }, { HERDR_ENV = '1', HERDR_PANE_ID = 'p1', PATH = vim.env.PATH })
  h.eq(2, r.code, r.stderr)
  h.ok(blocked() ~= before, 'only the blocker was reached')
  -- not a repository
  r = launch({ '--in', 'tmux', h.tmpdir('launch-norepo') }, { TMUX = 'x', TMUX_PANE = '%7' })
  h.eq(1, r.code, r.stderr)
  h.eq('', r.calls)
end)

h.test('launch.sh splits the verified tmux pane, runs revuey from a script, fails on timeout', function()
  local r = launch({ '--in', 'tmux', repo, '--', '--stack', "it's" }, { TMUX = 'fake', TMUX_PANE = '%7' })
  h.eq(5, r.code, r.stdout .. r.stderr)
  h.ok(r.calls:find('tmux display-message -p -t %7', 1, true), r.calls)
  h.ok(r.calls:find('split-window -h -t %7', 1, true), r.calls)
  local script = r.calls:match('bash (/%S+revuey%-launch%.%w+)')
  h.ok(script, r.calls)
  local text = table.concat(vim.fn.readfile(script), '\n')
  os.remove(script)
  h.ok(text:find("cd '" .. repo .. "'", 1, true), text)
  h.ok(text:find("'--stack' 'it'\\''s'", 1, true), text)
  h.ok(r.stdout:find('has not registered', 1, true), r.stdout)
end)

h.test('launch.sh in herdr: the pane gets one plain command, whatever its shell', function()
  local r = launch({ '--in', 'herdr', repo }, { HERDR_ENV = '1', HERDR_PANE_ID = 'p1' })
  h.eq(5, r.code, r.stdout .. r.stderr)
  h.ok(r.calls:find('herdr pane get p1', 1, true), r.calls)
  h.ok(r.calls:find('herdr pane split p1 --direction right', 1, true), r.calls)
  local run = r.calls:match('herdr pane run p%-new ([^\n]+)')
  h.ok(run and run:match('^bash /[%w/._-]+; exit$'), tostring(run))
  os.remove(run:match('bash (%S+);'))
end)

h.test('launch.sh --in none prints a quoted command for the user; a running review is not launched twice', function()
  local r = launch({ '--in', 'none', repo, '--', 'main' })
  h.eq(3, r.code)
  h.ok(r.stdout:find("cd '" .. repo .. "' && '", 1, true), r.stdout)
  h.ok(r.stdout:find("' 'main'", 1, true), r.stdout)
  -- a review of this repo is running (this Neovim): exit 4, nothing split
  vim.cmd('runtime plugin/revuey.lua')
  require('revuey').setup({ state_dir = state, lsp_warmup = false })
  h.open_review({ cwd = repo })
  r = launch({ '--in', 'tmux', repo }, { TMUX = 'fake', TMUX_PANE = '%7' })
  h.eq(4, r.code, r.stdout .. r.stderr)
  h.eq(nil, r.calls:find('split-window', 1, true), r.calls)
end)

h.run()
