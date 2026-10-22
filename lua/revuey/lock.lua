-- A cross-process lock around read-merge-rename of revuey's JSON files (and appends to the event
-- feed). No window or buffer UI.
--
--   * The lock is a file `<path>.lock` created with O_EXCL, holding "<pid> <host> <time> <token>".
--   * A lock whose holder is dead (same host, pid gone) is broken at once; one without a readable
--     owner, or from another host, only when older than STALE_MS.
--   * Breaking is atomic: breakers serialise on `<path>.lock.break` (O_EXCL), re-read the lock
--     under it and remove it only if it is still the one judged stale. Then the acquire is
--     retried. (Renaming aside was not enough: a second breaker could rename away the fresh lock
--     the first had just taken.)
--   * Release removes the lock only when it still holds this holder's token.
--   * Waiting: the CLI and tests wait up to TIMEOUT_MS. The UI (`interactive`, set by view.lua)
--     waits at most INTERACTIVE_MS and gets a "busy" error instead; savers then keep their
--     changes in memory and `defer` the save to a timer with backoff, so the editor never freezes.
local M = {}

M.TIMEOUT_MS = tonumber(vim.env.REVUEY_LOCK_TIMEOUT_MS or '') or 10000
M.INTERACTIVE_MS = 100
M.STALE_MS = 15000 -- other hosts, or a record that cannot be read
M.SAME_HOST_STALE_MS = 60000 -- this host: a live pid may have been reused; holders keep locks for ms
M.EXIT_WAIT_MS = 2000 -- on quit, how long a pending save may still wait before its recovery file
M.WARN_AFTER_MS = 30000 -- deferred saves still failing after this: one quiet message
M.interactive = false

local HOST = vim.uv.os_gethostname() or 'localhost'

local Busy = {
  __tostring = function(e)
    return e.msg
  end,
}

---Is `err` the "lock is busy" error (another process holds it)?
function M.is_busy(err)
  return type(err) == 'table' and getmetatable(err) == Busy
end

local function now_ms()
  return vim.uv.hrtime() / 1e6
end

local function read(p)
  local fd = io.open(p, 'r')
  if not fd then
    return nil
  end
  local t = fd:read('*a')
  fd:close()
  return t
end

local function owner(text)
  local pid, host = (text or ''):match('^(%d+) (%S+)')
  return tonumber(pid), host
end

local function alive(pid)
  local ok, _, name = vim.uv.kill(pid, 0)
  return ok == 0 or name == 'EPERM'
end

local function is_stale(lockp, text)
  local pid, host = owner(text)
  local st = vim.uv.fs_stat(lockp)
  local age = st and (os.time() - st.mtime.sec) * 1000 or 0
  if pid and host == HOST then
    -- a dead holder at once; a live pid only for SAME_HOST_STALE_MS (it may be a reused pid)
    return not alive(pid) or age > M.SAME_HOST_STALE_MS
  end
  return st ~= nil and age > M.STALE_MS
end

---Break the lock judged stale (its content was `judged`). Breakers take a second lock,
---`<lock>.break`, so only one breaks at a time; under it the lock is re-read and removed only
---if it is still the judged one. Nothing but a breaker (or its dead holder) removes a lock, so
---it cannot be replaced between that check and the removal.
local function break_lock(lockp, judged)
  local bp = lockp .. '.break'
  local fd = vim.uv.fs_open(bp, 'wx', 420)
  if not fd then
    -- another breaker is at it (or died at it: clear its marker for the next attempt). Clearing
    -- reads and then removes, so two waiters could both judge a dead breaker's marker and the
    -- second remove a marker the first had just re-created. That needs a breaker to die inside
    -- these few microseconds of its own, and the worst outcome is two breakers removing the
    -- same stale lock (each still checks it is the judged one), not two holders: acceptable.
    local t = read(bp)
    if t and is_stale(bp, t) then
      vim.uv.fs_unlink(bp)
    end
    return
  end
  vim.uv.fs_write(fd, ('%d %s %d\n'):format(vim.uv.os_getpid(), HOST, os.time()))
  vim.uv.fs_close(fd)
  if read(lockp) == judged then
    vim.uv.fs_unlink(lockp)
  end
  vim.uv.fs_unlink(bp)
end

---One attempt. Returns true, or false plus the holder's record.
local function try_once(lockp, token, again)
  local fd, err, name = vim.uv.fs_open(lockp, 'wx', 420)
  if fd then
    vim.uv.fs_write(fd, token)
    vim.uv.fs_close(fd)
    return true
  end
  if name ~= 'EEXIST' then
    error('revuey: cannot lock ' .. lockp .. ': ' .. tostring(err), 0)
  end
  local text = read(lockp)
  if text and not again and is_stale(lockp, text) then
    break_lock(lockp, text)
    return try_once(lockp, token, true)
  end
  return false, text
end

local function holder(text)
  local pid, host = owner(text)
  if not pid then
    return 'another process'
  end
  return host == HOST and ('pid ' .. pid) or ('pid ' .. pid .. ' on ' .. host)
end

---Run `fn` holding the lock of `path`; returns what `fn` returns, re-raises its error. The lock
---is always released. Raises a busy error (`is_busy`) when it cannot be had in time.
---@param path string the file being protected
---@param fn fun(): any
function M.with(path, fn)
  local lockp = path .. '.lock'
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local token = ('%d %s %d %06x\n'):format(vim.uv.os_getpid(), HOST, os.time(), math.random(0, 0xffffff))
  local limit = M.interactive and M.INTERACTIVE_MS or M.TIMEOUT_MS
  local start = now_ms()
  local delay = 1
  while true do
    local ok, text = try_once(lockp, token)
    if ok then
      break
    end
    local waited = now_ms() - start
    if waited >= limit then
      error(setmetatable({
        path = path,
        msg = ('revuey: %s is locked by %s (waited %dms)'):format(vim.fs.basename(path), holder(text), waited),
      }, Busy), 0)
    end
    vim.uv.sleep(math.min(delay + math.random(0, delay), math.max(1, math.floor(limit - waited))))
    delay = math.min(delay * 2, M.interactive and 20 or 50)
  end
  local res = { pcall(fn) }
  if read(lockp) == token then
    vim.uv.fs_unlink(lockp)
  end
  if not res[1] then
    error(res[2], 0)
  end
  return unpack(res, 2, table.maxn(res))
end

-- ---------------------------------------------------------------------------
-- Deferred saves (UI): retried from a timer with backoff while the lock is busy
-- ---------------------------------------------------------------------------

local pending = {} ---@type table<string, {fn:fun(), delay:number, since:number, due:number, warned?:boolean}>
local timer

local function tick()
  local now = now_ms()
  for key, p in pairs(pending) do
    if now >= p.due then
      pending[key] = nil
      local ok, err = pcall(p.fn)
      if not ok then
        vim.notify(tostring(err), vim.log.levels.ERROR)
      end
      local again = pending[key]
      if again then
        -- still busy (the attempt deferred itself again): back off
        again.since, again.warned = p.since, p.warned
        again.delay = math.min(p.delay * 2, 2000)
        again.due = now_ms() + again.delay
        if not again.warned and now_ms() - again.since > M.WARN_AFTER_MS then
          again.warned = true
          vim.notify('revuey: ' .. vim.fs.basename(key) .. ' is still locked by another process; changes are kept and saved once it is free', vim.log.levels.INFO)
        end
      elseif p.warned then
        vim.notify('revuey: ' .. vim.fs.basename(key) .. ' saved', vim.log.levels.INFO)
      end
    end
  end
  if next(pending) == nil and timer then
    timer:stop()
  end
end

---Retry `fn` (a save that found the lock busy) from a timer until it no longer defers itself.
---The latest `fn` for a key wins.
function M.defer(key, fn, recover)
  local p = pending[key]
  if p then
    p.fn, p.recover = fn, recover or p.recover
  else
    pending[key] = { fn = fn, recover = recover, delay = 50, since = now_ms(), due = now_ms() + 50 }
  end
  if not timer then
    timer = vim.uv.new_timer()
    -- on the way out, wait a little longer for each pending save rather than lose it
    pcall(vim.api.nvim_create_autocmd, 'VimLeavePre', {
      callback = function()
        M.flush_at_exit()
      end,
    })
  end
  if not timer:is_active() then
    timer:start(25, 25, vim.schedule_wrap(tick))
  end
end

---On quit: give each pending save a last, longer try (EXIT_WAIT_MS); one whose lock is still
---held is written to its recovery file (`recover`), which the next load merges.
function M.flush_at_exit()
  local saved_i, saved_t = M.interactive, M.TIMEOUT_MS
  M.interactive, M.TIMEOUT_MS = false, M.EXIT_WAIT_MS
  for k, q in pairs(pending) do
    pending[k] = nil
    local ok, err = pcall(q.fn)
    if not ok then
      if q.recover then
        local rok, rerr = pcall(q.recover)
        if not rok then
          io.stderr:write('revuey: lost a pending save of ' .. k .. ': ' .. tostring(rerr) .. '\n')
        end
      else
        io.stderr:write(tostring(err) .. '\n')
      end
    end
  end
  M.interactive, M.TIMEOUT_MS = saved_i, saved_t
end

---Recovery file of `path` for this process: `<name>.pending-<pid><ext>` next to it.
function M.recovery_path(path)
  local base, ext = path:match('^(.*)(%.[^./]+)$')
  return ('%s.pending-%d%s'):format(base or path, vim.uv.os_getpid(), ext or '')
end

---Recovery files of `path` left by any process (sorted).
function M.recovery_files(path)
  local base, ext = path:match('^(.*)(%.[^./]+)$')
  local list = vim.fn.glob(vim.fn.escape(base or path, '[]*?') .. '.pending-*' .. (ext or ''), false, true)
  table.sort(list)
  return list
end

---Write `text` to `path` (temp + rename).
function M.write_file(path, text)
  local tmp = path .. '.tmp.' .. vim.uv.os_getpid()
  local fd = assert(io.open(tmp, 'w'))
  fd:write(text)
  fd:close()
  assert(os.rename(tmp, path))
end

---Is a save of `key` waiting for the lock?
function M.pending(key)
  return pending[key] ~= nil
end

---Run a save; when the lock is busy in the UI, keep the changes (the caller's job) and retry it
---later instead of failing. Returns what `fn` returns, or nothing when deferred.
---@param key string the protected file
---@param fn fun(): any the whole save (it takes the lock itself)
---`recover` (optional) writes the pending changes to a recovery file if the save is still
---blocked when Neovim quits.
function M.save(key, fn, recover)
  local res = { pcall(fn) }
  if res[1] then
    return unpack(res, 2, table.maxn(res))
  end
  if M.interactive and M.is_busy(res[2]) then
    M.defer(key, function()
      M.save(key, fn, recover)
    end, recover)
    return
  end
  error(res[2], 0)
end

return M
