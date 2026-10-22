-- Unit: the cross-process lock (lock.lua). Owner records, dead holders broken at once, the age
-- fallback for other hosts, atomic breaking (one holder at a time even with several breakers),
-- the short interactive wait with retries from a timer, and error messages.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
local lock = require('revuey.lock')

local host = vim.uv.os_gethostname()

---A pid that has just exited (its process is gone).
local function dead_pid()
  local p = vim.system({ 'true' })
  p:wait()
  return p.pid
end

local function write_lock(path, pid, hostname)
  local fd = assert(io.open(path .. '.lock', 'w'))
  fd:write(('%d %s %d\n'):format(pid, hostname, os.time()))
  fd:close()
end

local function ms(fn)
  local t = vim.uv.hrtime()
  local res = { pcall(fn) }
  return (vim.uv.hrtime() - t) / 1e6, unpack(res)
end

h.test('with: runs, records the owner while held, releases (also after an error)', function()
  local path = h.tmpdir('lock-basic') .. '/f.json'
  h.eq(42, lock.with(path, function()
    local text = table.concat(vim.fn.readfile(path .. '.lock'), '\n')
    h.ok(text:find('^' .. vim.uv.os_getpid() .. ' ' .. vim.pesc(host) .. ' '), text)
    return 42
  end))
  h.eq(nil, vim.uv.fs_stat(path .. '.lock'))
  h.eq(false, (pcall(lock.with, path, function()
    error('boom')
  end)))
  h.eq(nil, vim.uv.fs_stat(path .. '.lock'))
end)

h.test('a lock whose holder died on this host is broken at once', function()
  local path = h.tmpdir('lock-dead') .. '/f.json'
  write_lock(path, dead_pid(), host)
  local t, ok, v = ms(function()
    return lock.with(path, function()
      return 'mine'
    end)
  end)
  h.eq({ true, 'mine' }, { ok, v })
  h.ok(t < 200, ('took %dms'):format(t))
  -- a lock from before owner records (empty) or another host is judged by age only
  for _, other in ipairs({ 'elsewhere.example', '' }) do
    if other == '' then
      vim.fn.writefile({}, path .. '.lock')
    else
      write_lock(path, vim.uv.os_getpid(), other)
    end
    local saved = lock.TIMEOUT_MS
    lock.TIMEOUT_MS = 150
    local ok2, err = pcall(lock.with, path, function() end)
    lock.TIMEOUT_MS = saved
    h.eq(false, ok2, other)
    h.ok(lock.is_busy(err), tostring(err))
    local old = os.time() - 3600
    vim.uv.fs_utime(path .. '.lock', old, old)
    h.eq('ran', lock.with(path, function()
      return 'ran'
    end))
  end
end)

h.test('a live holder is waited for; the error says who holds it, with one prefix', function()
  local path = h.tmpdir('lock-live') .. '/f.json'
  write_lock(path, vim.uv.os_getpid(), host)
  local saved = lock.TIMEOUT_MS
  lock.TIMEOUT_MS = 150
  local t, ok, err = ms(function()
    return lock.with(path, function() end)
  end)
  lock.TIMEOUT_MS = saved
  h.eq(false, ok)
  h.ok(t >= 140 and t < 1000, t)
  local msg = tostring(err)
  h.ok(msg:find('^revuey: ') and not msg:find('revuey: revuey:'), msg)
  h.ok(msg:find('pid ' .. vim.uv.os_getpid(), 1, true), msg)
  os.remove(path .. '.lock')
end)

-- Breaking a stale lock is atomic: of several processes that find the same dead lock, one
-- breaks it, and holders never overlap.
h.test('several concurrent breakers of a dead lock: one holder at a time', function()
  local d = h.tmpdir('lock-breakers')
  local path = d .. '/f.json'
  local log = d .. '/log'
  local script = d .. '/hold.lua'
  vim.fn.writefile({
    ('vim.opt.rtp:prepend(%q)'):format(h.root),
    'local lock = require("revuey.lock")',
    ('local path, log = %q, %q'):format(path, log),
    'local function note(s) local f = io.open(log, "a"); f:write(s .. "\\n"); f:close() end',
    'lock.with(path, function()',
    '  note("enter " .. vim.uv.os_getpid())',
    '  vim.uv.sleep(150)',
    '  note("exit " .. vim.uv.os_getpid())',
    'end)',
  }, script)
  for _ = 1, 3 do
    write_lock(path, dead_pid(), host)
    vim.fn.delete(log)
    local procs = {}
    for i = 1, 6 do
      procs[i] = vim.system({ vim.v.progpath, '--clean', '--headless', '-l', script })
    end
    for i = 1, 6 do
      h.eq(0, procs[i]:wait(30000).code)
    end
    local lines = vim.fn.readfile(log)
    h.eq(12, #lines, table.concat(lines, '\n'))
    for i = 1, #lines, 2 do
      local who = lines[i]:match('^enter (%d+)$')
      h.ok(who, 'overlap: ' .. table.concat(lines, '\n'))
      h.eq('exit ' .. who, lines[i + 1], table.concat(lines, '\n'))
    end
    h.eq(nil, vim.uv.fs_stat(path .. '.lock'))
  end
end)

h.test('interactive: a busy lock fails fast; the deferred save runs once it is free', function()
  local path = h.tmpdir('lock-ui') .. '/f.json'
  write_lock(path, vim.uv.os_getpid(), host)
  lock.interactive = true
  local t, ok, err = ms(function()
    return lock.with(path, function() end)
  end)
  h.eq(false, ok)
  h.ok(lock.is_busy(err), tostring(err))
  h.ok(t < 150, ('blocked %dms'):format(t))
  local ran = 0
  local function attempt()
    local aok, aerr = pcall(lock.with, path, function()
      ran = ran + 1
    end)
    if not aok and lock.is_busy(aerr) then
      lock.defer(path, attempt)
    end
  end
  attempt()
  vim.wait(300)
  h.eq(0, ran, 'still held')
  h.eq(true, lock.pending(path))
  os.remove(path .. '.lock')
  h.ok(vim.wait(5000, function()
    return ran == 1
  end, 10), 'the deferred save ran')
  h.eq(false, lock.pending(path))
  lock.interactive = false
end)

h.run()
