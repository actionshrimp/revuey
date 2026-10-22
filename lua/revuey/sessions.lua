-- The session registry and agent presence (pure data: JSON files, no window or buffer UI), shared
-- by the review UI (agent_link.lua) and `bin/revuey sessions|watch|...` (cli.lua).
--
--   * A base is a directory holding `sessions/` and `watchers/`. The first base is the
--     worktree's own git dir (`git rev-parse --absolute-git-dir`)/revuey, so an entry is tied to
--     its worktree and invisible to `git status`; the second is revuey's state dir, used when
--     the git dir is not writable (or there is no repo).
--   * Each running review writes `sessions/<nvim pid>.json` (worktree, git dir, branch, scope,
--     comments and events paths, pid, host, Neovim's RPC socket, started_at), rewrites it when
--     the scope changes, and removes it on exit. Listing removes entries whose process is gone.
--   * Each `bin/revuey watch` writes `watchers/<pid>.json` with the session it is attached to
--     (or none yet: then it counts for every session of its worktree) and a heartbeat it
--     rewrites every HEARTBEAT_MS. An agent is connected while a watcher's heartbeat is younger
--     than FRESH_MS and its process is alive.
local M = {}

M.VERSION = 1
M.FRESH_MS = 30000
M.HEARTBEAT_MS = 5000
M.FORGET_MS = 24 * 3600 * 1000 -- a watcher silent this long (its pid alive or reused) is removed

local HOST = vim.uv.os_gethostname() or 'localhost'
M.host = HOST

function M.now_ms()
  local s, us = vim.uv.gettimeofday()
  return s * 1000 + math.floor(us / 1000)
end

---Is the process of an entry alive? Entries of other hosts cannot be checked: they count as alive.
function M.alive(e)
  local pid = tonumber(e and e.pid)
  if not pid or pid <= 1 then
    return false
  end
  if e.host and e.host ~= HOST then
    return true
  end
  local ok, _, name = vim.uv.kill(pid, 0)
  return ok == 0 or name == 'EPERM'
end

local function git_out(args, cwd)
  local cmd = { 'git', '--no-pager' }
  vim.list_extend(cmd, args)
  local ok, res = pcall(function()
    return vim.system(cmd, { cwd = cwd, text = true }):wait(5000)
  end)
  if not ok or res.code ~= 0 then
    return nil
  end
  return vim.trim(res.stdout or '')
end

local function real(p)
  return p and (vim.uv.fs_realpath(p) or p) or nil
end
M.real = real

---The worktree's own git dir (a linked worktree's is under the common dir's `worktrees/`).
function M.git_dir(cwd)
  local gd = git_out({ 'rev-parse', '--absolute-git-dir' }, cwd)
  return gd and gd ~= '' and real(gd) or nil
end

---Bases for the worktree at `cwd`: its git dir's `revuey/`, then `state_dir`.
---@return string[]
function M.bases(cwd, state_dir)
  local out = {}
  local gd = M.git_dir(cwd)
  if gd then
    out[#out + 1] = vim.fs.joinpath(gd, 'revuey')
  end
  if state_dir and state_dir ~= '' then
    out[#out + 1] = state_dir
  end
  return out
end

---Bases of every worktree of the repo at `cwd` (the main one and each linked worktree), then
---`state_dir`.
function M.all_bases(cwd, state_dir)
  local out = {}
  local common = git_out({ 'rev-parse', '--path-format=absolute', '--git-common-dir' }, cwd)
  if common and common ~= '' then
    common = real(common)
    out[#out + 1] = vim.fs.joinpath(common, 'revuey')
    local wt = vim.fs.joinpath(common, 'worktrees')
    if vim.uv.fs_stat(wt) then
      for name, t in vim.fs.dir(wt) do
        if t == 'directory' then
          out[#out + 1] = vim.fs.joinpath(wt, name, 'revuey')
        end
      end
    end
  end
  if state_dir and state_dir ~= '' then
    out[#out + 1] = state_dir
  end
  return out
end

---Write `text` to `path` atomically (temp file + rename). Returns true, or nil + error.
local function write_atomic(path, text)
  local ok = pcall(vim.fn.mkdir, vim.fs.dirname(path), 'p')
  if not ok then
    return nil, 'cannot create ' .. vim.fs.dirname(path)
  end
  local tmp = ('%s.tmp.%d.%d'):format(path, vim.uv.os_getpid(), math.random(0, 0xffffff))
  local fd, err = io.open(tmp, 'w')
  if not fd then
    return nil, err
  end
  local wok, werr = fd:write(text)
  local cok, cerr = fd:close()
  if not wok or not cok then
    os.remove(tmp)
    return nil, werr or cerr
  end
  local rok, rerr = os.rename(tmp, path)
  if not rok then
    os.remove(tmp)
    return nil, rerr
  end
  return true
end

local function read_json(path)
  local fd = io.open(path, 'r')
  if not fd then
    return nil
  end
  local text = fd:read('*a')
  fd:close()
  local ok, data = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if ok and type(data) == 'table' then
    return data
  end
end

---Write `entry` as `<base>/<kind>/<id>.json` in the first base that takes it.
---@return string? path, string? err
local function put(bases, kind, entry)
  local id = tostring(entry.id or entry.pid)
  local rec = {}
  for k, v in pairs(entry) do
    if type(k) == 'string' and k:sub(1, 1) ~= '_' then
      rec[k] = v
    end
  end
  rec.id, rec.version, rec.host = id, M.VERSION, entry.host or HOST
  local text = vim.json.encode(rec)
  local last
  for _, base in ipairs(bases) do
    local path = vim.fs.joinpath(base, kind, id .. '.json')
    local ok, err = write_atomic(path, text)
    if ok then
      return path
    end
    last = err
  end
  return nil, last or 'no place for the session registry'
end

---Register (or update) a review session. `entry`: {pid, worktree, git_dir, branch, scope,
---scope_key, base, comments, events, state_dir, server, started_at, ...}; the id is the pid.
---@return string? path, string? err
function M.register(bases, entry)
  entry.updated_at = M.now_ms()
  return put(bases, 'sessions', entry)
end

function M.remove(path)
  if path then
    os.remove(path)
  end
end

---Live entries of `<base>/<kind>/` in every base (dead ones and unreadable files are removed).
local function scan(bases, kind, keep)
  local out, seen = {}, {}
  for _, base in ipairs(bases) do
    local dir = vim.fs.joinpath(base, kind)
    if not seen[dir] and vim.uv.fs_stat(dir) then
      seen[dir] = true
      for name, t in vim.fs.dir(dir) do
        if t == 'file' and name:match('%.json$') then
          local path = vim.fs.joinpath(dir, name)
          local e = read_json(path)
          if not e or not keep(e) then
            os.remove(path)
          else
            e._path = path
            e._base = base
            e.id = e.id and tostring(e.id) or name:gsub('%.json$', '')
            out[#out + 1] = e
          end
        end
      end
    end
  end
  return out
end

---Live review sessions in `bases`, oldest first. `opts.worktree`: only that worktree's.
---@param opts? {worktree?:string}
function M.list(bases, opts)
  opts = opts or {}
  local want = opts.worktree and real(opts.worktree)
  local out = {}
  for _, e in ipairs(scan(bases, 'sessions', M.alive)) do
    if not want or e.worktree == opts.worktree or real(e.worktree) == want then
      out[#out + 1] = e
    end
  end
  table.sort(out, function(a, b)
    if (a.started_at or 0) ~= (b.started_at or 0) then
      return (a.started_at or 0) < (b.started_at or 0)
    end
    return a.id < b.id
  end)
  return out
end

-- ---------------------------------------------------------------------------
-- Watchers and presence
-- ---------------------------------------------------------------------------

---Write (or refresh) a watcher record {pid, session?, worktree, started_at, heartbeat_at, mode}.
function M.write_watcher(bases, w)
  return put(bases, 'watchers', w)
end

---Watchers in `bases` (dead ones and ones silent for FORGET_MS are removed).
function M.watchers(bases, now)
  now = now or M.now_ms()
  return scan(bases, 'watchers', function(w)
    return M.alive(w) and type(w.heartbeat_at) == 'number' and now - w.heartbeat_at < M.FORGET_MS
  end)
end

---Is a watcher's heartbeat fresh (and its process alive)?
function M.fresh(w, now)
  now = now or M.now_ms()
  return type(w.heartbeat_at) == 'number' and now - w.heartbeat_at < M.FRESH_MS and M.alive(w)
end

---Is an agent watching `session` ({id, worktree})? A watcher attached to it, or attached to no
---session yet in the same worktree.
---@return boolean, table[] watchers
function M.connected(bases, session, now)
  now = now or M.now_ms()
  local hits = {}
  local wt = session.worktree and real(session.worktree)
  for _, w in ipairs(M.watchers(bases, now)) do
    if M.fresh(w, now) then
      local mine = w.session ~= nil and tostring(w.session) == tostring(session.id)
      local unattached = w.session == nil and wt and (w.worktree == session.worktree or real(w.worktree) == wt)
      if mine or unattached then
        hits[#hits + 1] = w
      end
    end
  end
  return #hits > 0, hits
end

---Short scope label of a session entry or an event's review info: "stack/cart", "full stack".
function M.scope_label(r)
  if not r then
    return '?'
  end
  if r.scope == 'full' or (type(r.scope) == 'table' and r.scope.kind == 'full') then
    return 'full stack'
  end
  return r.branch or r.state_branch or '?'
end

return M
