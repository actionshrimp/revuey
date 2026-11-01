-- Requests from a running review to the connected coding agent (pure data: JSON files and event
-- shapes, no window or buffer UI), shared by the review (guide_view.lua) and `bin/revuey`
-- (cli.lua). A request asks the agent to produce something revuey would otherwise make with a
-- fresh `claude -p` run: `guide` (the guide of the review shown) today; `review` (an AI review)
-- can use the same records, events and lines later.
--
--   * One file per request: `<state_dir>/requests/<id>.json` {version, id, kind, at, status,
--     session, worktree, review (comments.review_info), scope_key, label, agent, key, anchors,
--     guide_dir, delivered_at?, acked_at?, done_at?, cancelled_at?, result?}. Written atomically;
--     changed under the file's lock (`update`), so the review cancelling and the CLI taking it
--     never lose each other's change.
--   * Status: `pending` (asked) -> `acked` (the agent printed its prompt) -> `done` (imported);
--     `cancelled` (by the user) at any point before `done`. Open: pending or acked, and younger
--     than TTL_MS.
--   * The review appends a `request` event to its feed (`comments.REQUEST`) when it asks and when
--     it cancels; `watch --messages` prints one line for each, and catches up on open requests no
--     watch printed yet (`delivered_at`), like messages.
local M = {}

M.VERSION = 1
M.KINDS = { guide = true }
M.TTL_MS = 6 * 3600 * 1000 -- an open request older than this is forgotten
M.EVENT = 'request'

local function now_ms()
  local s, us = vim.uv.gettimeofday()
  return s * 1000 + math.floor(us / 1000)
end
M.now_ms = now_ms

function M.dir(state_dir)
  return vim.fs.joinpath(state_dir, 'requests')
end

function M.path(dir, id)
  return vim.fs.joinpath(dir, tostring(id) .. '.json')
end

local function write_atomic(path, rec)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local tmp = ('%s.tmp.%d.%d'):format(path, vim.uv.os_getpid(), math.random(0, 0xffffff))
  local fd, err = io.open(tmp, 'w')
  if not fd then
    return nil, err
  end
  local wok, werr = fd:write(vim.json.encode(rec))
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

---The request at `path`, or nil.
function M.read(path)
  local fd = io.open(path, 'r')
  if not fd then
    return nil
  end
  local text = fd:read('*a')
  fd:close()
  local ok, rec = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if ok and type(rec) == 'table' and rec.id and M.KINDS[rec.kind] then
    rec._path = path
    rec.agent = M.clean_name(rec.agent)
    rec.label = type(rec.label) == 'string' and require('revuey.guide').one_line(rec.label) or nil
    return rec
  end
end

local function clean(rec)
  local c = {}
  for k, v in pairs(rec) do
    if type(k) == 'string' and k:sub(1, 1) ~= '_' then
      c[k] = v
    end
  end
  return c
end

---A new request (not written yet). `info`: session, worktree, review, scope_key, label, agent,
---key, anchors, guide_dir.
function M.new(kind, info, now)
  assert(M.KINDS[kind], 'unknown request kind ' .. tostring(kind))
  now = now or now_ms()
  local rec = { version = M.VERSION, id = require('revuey.comments').new_id(now), kind = kind, at = now, status = 'pending' }
  for k, v in pairs(info or {}) do
    rec[k] = v
  end
  return rec
end

---Write a new request into `dir`. Returns its path, or nil and an error.
function M.create(dir, rec)
  local path = M.path(dir, rec.id)
  local ok, err = write_atomic(path, clean(rec))
  if not ok then
    return nil, err
  end
  rec._path = path
  return path
end

---Change the request at `path` under its lock: `fn(rec)` edits it in place (return false to
---leave the file alone; false and a message to fail with that message, the file untouched). Work
---done inside `fn` (saving a guide) happens under the lock too. Returns the request as written,
---or nil and an error.
function M.update(path, fn)
  local ok, res, err = pcall(require('revuey.lock').with, path, function()
    local rec = M.read(path)
    if not rec then
      return nil, 'no request at ' .. path
    end
    local keep, ferr = fn(rec)
    if keep == false then
      if ferr then
        return nil, ferr
      end
      return rec
    end
    local wok, werr = write_atomic(path, clean(rec))
    if not wok then
      return nil, werr
    end
    return rec
  end)
  if not ok then
    return nil, tostring(type(res) == 'table' and res.msg or res)
  end
  return res, err
end

M.NAME_MAX = 40

---An agent's name as shown and stored: one line, no control characters, at most NAME_MAX
---characters; nil when nothing is left. Used where names come in (`watch --name`, `import-guide
-----name`) and where they are read (watcher records, requests, guide generators).
function M.clean_name(v)
  local n = require('revuey.guide').one_line(v)
  if vim.fn.strchars(n) > M.NAME_MAX then
    n = vim.trim(vim.fn.strcharpart(n, 0, M.NAME_MAX))
  end
  return n ~= '' and n or nil
end

function M.is_open(rec, now)
  return rec and (rec.status == 'pending' or rec.status == 'acked') and (now or now_ms()) - (tonumber(rec.at) or 0) < M.TTL_MS
end

---Requests in the `dirs` (each a state dir), oldest first. `opts.open`: open ones only;
---`opts.repo` (a path and its real path): only requests of reviews of that repo.
function M.list(dirs, opts)
  opts = opts or {}
  local out, seen, now = {}, {}, now_ms()
  for _, sd in ipairs(dirs) do
    local dir = M.dir(sd)
    local real = vim.uv.fs_realpath(dir) or dir
    if not seen[real] and vim.uv.fs_stat(dir) then
      seen[real] = true
      for name, t in vim.fs.dir(dir) do
        if t == 'file' and name:match('%.json$') then
          local rec = M.read(vim.fs.joinpath(dir, name))
          local repo = rec and type(rec.review) == 'table' and rec.review.repo
          local repo_ok = not opts.repo or (repo and (repo == opts.repo[1] or (vim.uv.fs_realpath(repo) or repo) == opts.repo[2]))
          if rec and repo_ok and (not opts.open or M.is_open(rec, now)) then
            out[#out + 1] = rec
          end
        end
      end
    end
  end
  table.sort(out, function(a, b)
    return tostring(a.id) < tostring(b.id)
  end)
  return out
end

---The request `id` (or a unique part of it) in `dirs`: rec, or nil and an error.
function M.find(dirs, id, opts)
  local all = M.list(dirs, opts)
  for _, r in ipairs(all) do
    if r.id == id then
      return r
    end
  end
  local found = {}
  for _, r in ipairs(all) do
    if tostring(r.id):find(id, 1, true) then
      found[#found + 1] = r
    end
  end
  if #found == 1 then
    return found[1]
  elseif #found > 1 then
    return nil, ('request id %s is ambiguous (%s)'):format(id, table.concat(vim.tbl_map(function(r)
      return r.id
    end, found), ', '))
  end
  return nil, 'no request ' .. id .. ' in this repository'
end

---The feed event of a request: asked (`status` pending) or cancelled.
function M.event(rec, now)
  now = now or now_ms()
  return {
    id = require('revuey.comments').new_id(now),
    kind = M.EVENT,
    at = now,
    request_id = rec.id,
    request_kind = rec.kind,
    status = rec.status,
    session = rec.session,
    worktree = rec.worktree,
    review = rec.review or {},
    label = rec.label,
    path = rec._path,
  }
end

---Identity of a request line (printed once per status).
function M.key(ev)
  return 'request:' .. tostring(ev.request_id) .. ':' .. (ev.status == 'cancelled' and 'cancelled' or 'open')
end

-- What each kind asks for, and the command that starts the agent on it.
M.TEXTS = {
  guide = { ask = 'the user asked you to write the guide for this review', cmd = 'guide --prompt --request %s' },
}

---One line for agents: `revuey request <id> guide [stack/math]: the user asked you to write the
---guide for this review (<bin> guide --prompt --request <id>)`; a cancelled one says so.
function M.line(ev, bin)
  bin = bin or 'revuey'
  local scope = ev.label or (ev.review and (ev.review.scope == 'full' and 'full stack' or ev.review.branch)) or '?'
  local id, kind = tostring(ev.request_id), tostring(ev.request_kind)
  if ev.status == 'cancelled' then
    return ('revuey request %s cancelled [%s]: the user withdrew the %s request; stop working on it and import nothing'):format(id, scope, kind)
  end
  local t = M.TEXTS[kind] or { ask = 'the user asked you for a ' .. kind, cmd = kind .. ' --request %s' }
  return ('revuey request %s %s [%s]: %s (%s %s)'):format(id, kind, scope, t.ask, bin, t.cmd:format(id))
end

return M
