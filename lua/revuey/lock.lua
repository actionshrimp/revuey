-- A cross-process lock around read-merge-rename of revuey's JSON files (and appends to the event
-- feed). Pure (no UI). The lock is a directory `<path>.lock`: mkdir is atomic on every local
-- filesystem, and a directory needs no cleanup of its contents. Waiting retries with a short
-- backoff; a lock older than STALE_MS belonged to a writer that died and is broken. The critical
-- sections are a read, a merge and a write of small files, so waits are milliseconds.
local M = {}

M.TIMEOUT_MS = 5000 -- give up (error) after waiting this long
M.STALE_MS = 15000 -- a lock this old is from a crashed writer

local function now_ms()
  return vim.uv.hrtime() / 1e6
end

---Run `fn` holding the lock of `path`; returns what `fn` returns, re-raises its error. The lock
---is always released.
---@param path string the file being protected
---@param fn fun(): any
function M.with(path, fn)
  local lock = path .. '.lock'
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local start = now_ms()
  local delay = 1
  while true do
    local ok, err, name = vim.uv.fs_mkdir(lock, 448)
    if ok then
      break
    end
    if name ~= 'EEXIST' then
      error('revuey: cannot lock ' .. path .. ': ' .. tostring(err), 0)
    end
    local st = vim.uv.fs_stat(lock)
    if st and (os.time() - st.mtime.sec) * 1000 > M.STALE_MS then
      vim.uv.fs_rmdir(lock) -- the next attempt takes it (or loses the race to someone else)
    elseif now_ms() - start > M.TIMEOUT_MS then
      error('revuey: timed out waiting for the lock ' .. lock, 0)
    else
      vim.uv.sleep(delay + math.random(0, delay))
      delay = math.min(delay * 2, 40)
    end
  end
  local res = { pcall(fn) }
  vim.uv.fs_rmdir(lock)
  if not res[1] then
    error(res[2], 0)
  end
  return unpack(res, 2, table.maxn(res))
end

return M
