-- Quiet diagnostics: things worth knowing when debugging but never worth a message (the PR
-- lookup failing because `gh` is missing, offline or rate limited). Appended to a log file
-- (`config.log_file`, default stdpath('log')/revuey.log) and kept in memory (`M.entries`, the
-- last 200, for tests and :RevueyLog). No UI.
local M = {}

M.entries = {}
local MAX = 200
-- the file is moved to `<file>.1` (replacing an older one) when it reaches this size
M.max_bytes = 256 * 1024

---Path of the log file.
function M.path()
  local ok, cfg = pcall(require, 'revuey.config')
  local p = ok and cfg.options.log_file or nil
  return p or vim.fs.joinpath(vim.fn.stdpath('log'), 'revuey.log')
end

---Record a line: `scope` names the subsystem ('forge'), `msg` says what happened.
function M.write(scope, msg)
  local line = ('%s [%s] %s'):format(os.date('!%Y-%m-%dT%H:%M:%SZ'), scope, (tostring(msg):gsub('\n', ' ')))
  M.entries[#M.entries + 1] = { scope = scope, msg = msg, line = line }
  if #M.entries > MAX then
    table.remove(M.entries, 1)
  end
  pcall(function()
    local p = M.path()
    vim.fn.mkdir(vim.fs.dirname(p), 'p')
    local st = vim.uv.fs_stat(p)
    if st and st.size >= M.max_bytes then
      os.rename(p, p .. '.1')
    end
    local fd = io.open(p, 'a')
    if fd then
      fd:write(line, '\n')
      fd:close()
    end
  end)
end

return M
