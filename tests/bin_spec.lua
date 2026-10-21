-- Smoke test for bin/revuey in a real terminal via tmux capture-pane (skipped without tmux).
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
if vim.fn.executable('tmux') ~= 1 then
  h.skip_spec('tmux not installed')
end

local socket = 'revuey-test-' .. vim.fn.getpid()
local function tmux(...)
  return vim.system({ 'tmux', '-L', socket, ... }, { text = true }):wait()
end
local function capture()
  return tmux('capture-pane', '-p', '-t', 'smoke').stdout or ''
end
local function wait_for(pattern, ms)
  local out = ''
  vim.wait(ms or 10000, function()
    out = capture()
    return out:find(pattern, 1, true) ~= nil
  end, 100)
  return out
end

local fixture = h.fixture()
local home = h.tmpdir('bin-home') -- empty XDG dirs: no user config, isolated state

-- Regression (finding 1): inside :terminal/jobs Neovim sets $NVIM to its server socket; the
-- wrapper must not try to execute it.
h.test('bin/revuey opens the review, ignoring $NVIM, and q quits', function()
  local cmd = table.concat({
    'env',
    'NVIM=/nonexistent/nvim.sock',
    'XDG_CONFIG_HOME=' .. home .. '/config',
    'XDG_DATA_HOME=' .. home .. '/data',
    'XDG_STATE_HOME=' .. home .. '/state',
    'XDG_CACHE_HOME=' .. home .. '/cache',
    vim.fn.shellescape(h.root .. '/bin/revuey'),
    '; echo REVUEY_EXIT=$?; sleep 30',
  }, ' ')
  local res = tmux('new-session', '-d', '-s', 'smoke', '-x', '120', '-y', '30', '-c', fixture, cmd)
  h.eq(0, res.code, res.stderr)
  local out = wait_for('feature/cart → main')
  h.ok(out:find('feature/cart → main', 1, true), out)
  h.ok(out:find('src/cart.ts', 1, true), out)
  h.ok(out:find('+ import { multiply, sum } from "./math";', 1, true), out)
  tmux('send-keys', '-t', 'smoke', 'q')
  out = wait_for('REVUEY_EXIT=')
  h.ok(out:find('REVUEY_EXIT=0', 1, true), out)
end)

h.test('bin/revuey outside a git repo fails cleanly', function()
  local res = vim.system({ h.root .. '/bin/revuey' }, { cwd = home, text = true }):wait()
  h.eq(1, res.code)
  h.ok(res.stderr:find('not inside a git repository', 1, true), res.stderr)
end)

-- Regression (re-review 1): with 'noautoread', refreshing must not raise the blocking W11
-- prompt for revuey's hidden LSP buffers (a real terminal UI is needed to see it).
h.test('noautoread: refresh after an outside change shows no W11 prompt', function()
  local repo = h.repo('w11', { ['a.lua'] = 'local x = 1\n' }, { ['a.lua'] = 'local x = 2\n' })
  local init = home .. '/w11-init.lua'
  vim.fn.writefile({
    'vim.o.autoread = false',
    ('vim.opt.rtp:prepend(%q)'):format(h.root),
    'vim.cmd("runtime plugin/revuey.lua")',
    ('require("revuey").setup({ lsp_warmup = true, state_dir = %q })'):format(home .. '/w11-state'),
  }, init)
  local cmd = ('%s --clean -u %s -c Revuey'):format(vim.fn.shellescape(vim.v.progpath), vim.fn.shellescape(init))
  h.eq(0, tmux('new-session', '-d', '-s', 'w11', '-x', '120', '-y', '30', '-c', repo, cmd).code)
  local function cap()
    return tmux('capture-pane', '-p', '-t', 'w11').stdout or ''
  end
  vim.wait(10000, function()
    return cap():find('local x = 2', 1, true) ~= nil
  end, 100)
  vim.wait(500) -- let the LSP warm-up load the hidden buffer
  vim.uv.sleep(1100)
  h.write(repo, 'a.lua', 'local x = 3\n')
  tmux('send-keys', '-t', 'w11', ':lua require("revuey.view").refresh()', 'Enter')
  local out
  vim.wait(5000, function()
    out = cap()
    return out:find('local x = 3', 1, true) ~= nil or out:find('W11', 1, true) ~= nil
  end, 100)
  vim.wait(500)
  out = cap()
  tmux('kill-session', '-t', 'w11')
  h.ok(not out:find('W11', 1, true) and not out:find('[O]K', 1, true), out)
  h.ok(out:find('local x = 3', 1, true), out)
end)

tmux('kill-server')
h.run()
