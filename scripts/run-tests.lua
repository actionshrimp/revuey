-- The spec runner behind `make test`:
--   nvim --clean --headless -l scripts/run-tests.lua <run dir> <jobs> <spec>... [--alone <spec>...]
-- Runs every spec in its own `nvim --headless --clean -l`, up to <jobs> at a time, in the order
-- given (longest first, so the slowest do not start last), then the specs after --alone one at a
-- time with nothing else running (screen_spec's main-loop gap check measures timing). Each spec
-- gets a dir of its own, <run dir>/<spec>/ (REVUEY_TEST_TMP, and its TMPDIR under it), and
-- REVUEY_TEST_RUN=<run dir> (shared: scripts/check-leaks.sh finds what any spec left running).
-- A spec's output is printed as one block when it ends, then a summary with each spec's time.
-- Exits 1 when any spec failed.
local run, jobs = arg[1], tonumber(arg[2])
assert(run and jobs and jobs >= 1, 'usage: run-tests.lua <run dir> <jobs> <spec>... [--alone <spec>...]')
local uv = vim.uv
local nvim = vim.v.progpath

local parallel, alone = {}, {}
do
  local list = parallel
  for i = 3, #arg do
    if arg[i] == '--alone' then
      list = alone
    else
      list[#list + 1] = arg[i]
    end
  end
end

-- the specs' environment: ours, without what this Neovim set for itself (as make ran them)
local base_env = {}
for k, v in pairs(uv.os_environ()) do
  if k ~= 'VIM' and k ~= 'VIMRUNTIME' and k ~= 'MYVIMRC' and k ~= 'NVIM' and k ~= 'TMPDIR'
    and k ~= 'REVUEY_TEST_RUN' and k ~= 'REVUEY_TEST_TMP' then
    base_env[#base_env + 1] = k .. '=' .. v
  end
end

local results = {} -- spec -> { code, secs, out }
local running = 0
local printed = 0
local total = #parallel + #alone

local function read(path)
  local fd = io.open(path, 'rb')
  if not fd then
    return ''
  end
  local s = fd:read('*a')
  fd:close()
  return s
end

local function start(spec)
  local name = vim.fs.basename(spec):gsub('%.lua$', '')
  local dir = vim.fs.joinpath(run, name)
  vim.fn.mkdir(dir .. '/tmp', 'p')
  local out_path = dir .. '/output.txt'
  local fd = assert(uv.fs_open(out_path, 'w', tonumber('644', 8)))
  local env = vim.list_extend({
    'TMPDIR=' .. dir .. '/tmp',
    'REVUEY_TEST_RUN=' .. run,
    'REVUEY_TEST_TMP=' .. dir,
  }, base_env)
  local t0 = uv.hrtime()
  running = running + 1
  local handle, err
  handle, err = uv.spawn(nvim, {
    args = { '--headless', '--clean', '-l', spec },
    env = env,
    stdio = { nil, fd, fd },
  }, function(code, signal)
    uv.fs_close(fd)
    if handle then
      handle:close()
    end
    running = running - 1
    local secs = (uv.hrtime() - t0) / 1e9
    local out = read(out_path)
    if signal ~= 0 then
      out = out .. ('  FAIL %s :: (spec) killed by signal %d\n'):format(vim.fs.basename(spec), signal)
      code = code ~= 0 and code or 1
    end
    results[spec] = { code = code, secs = secs, out = out }
    printed = printed + 1
    io.stdout:write(("== %s  %.1fs%s  [%d/%d]\n"):format(vim.fs.basename(spec), secs, code == 0 and '' or '  FAILED',
      printed, total))
    io.stdout:write(out)
    io.stdout:flush()
  end)
  if not handle then
    uv.fs_close(fd)
    running = running - 1
    results[spec] = { code = 1, secs = 0, out = '  FAIL ' .. spec .. ' :: (spec) could not start: ' .. tostring(err) .. '\n' }
    io.stdout:write(results[spec].out)
  end
end

local t_start = uv.hrtime()
local queue = vim.list_extend({}, parallel)
while #queue > 0 or running > 0 do
  while running < jobs and #queue > 0 do
    start(table.remove(queue, 1))
  end
  vim.wait(60000, function()
    return running < jobs and #queue > 0 or (#queue == 0 and running == 0)
  end, 20)
end
for _, spec in ipairs(alone) do
  start(spec)
  vim.wait(24 * 3600 * 1000, function()
    return running == 0
  end, 20)
end
local wall = (uv.hrtime() - t_start) / 1e9

-- summary: every spec's time, slowest first, and the result counts
local all = vim.list_extend(vim.list_extend({}, parallel), alone)
table.sort(all, function(a, b)
  return results[a].secs > results[b].secs
end)
local counts = { ok = 0, FAIL = 0, skip = 0 }
local sum, failed = 0, {}
io.stdout:write(('\n== summary: %d specs, %d at a time%s\n'):format(#all, jobs,
  #alone > 0 and (', then alone: ' .. table.concat(vim.tbl_map(vim.fs.basename, alone), ' ')) or ''))
for _, spec in ipairs(all) do
  local r = results[spec]
  sum = sum + r.secs
  for line in r.out:gmatch('[^\n]+') do
    local kind = line:match('^  (%a+) +%S+_spec%.lua :: ')
    if counts[kind] then
      counts[kind] = counts[kind] + 1
    end
  end
  if r.code ~= 0 then
    failed[#failed + 1] = vim.fs.basename(spec)
  end
  io.stdout:write(('%7.1fs  %s%s\n'):format(r.secs, vim.fs.basename(spec), r.code == 0 and '' or '  FAILED'))
end
io.stdout:write(('wall %.1fs (spec time %.1fs); %d ok, %d FAIL, %d skip%s\n'):format(wall, sum, counts.ok,
  counts.FAIL, counts.skip, #failed > 0 and ('; failed: ' .. table.concat(failed, ' ')) or ''))
io.stdout:flush()

-- os.exit skips Neovim's own exit, which removes its server socket and temp dir
pcall(vim.fn.serverstop, vim.v.servername)
pcall(vim.fn.delete, vim.fn.fnamemodify(vim.fn.tempname(), ':h'), 'rf')
os.exit(#failed == 0 and 0 or 1)
