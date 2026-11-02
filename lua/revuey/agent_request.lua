-- The review's side of a request to the connected agent (requests.lua), shared by the guide
-- (guide_view.lua, kind `guide`) and AI reviews (ai_review_view.lua, kind `review`): asking (the
-- request file and its feed event), the wait (a job with `agent` and no `job`, its file read on
-- a poll), withdrawing it (with retries on a busy lock), and adopting an open request whose
-- review is gone.
--
-- Each caller passes its `host`: the module that owns the jobs, with
--   jobs                      jobs by key (the job with `agent` is the request's)
--   AGENT_ACK_MS, AGENT_POLL_MS, CANCEL_RETRY_MS, CANCEL_STEP_MS
--   req = {
--     noun,                   'guide' / 'review': "the guide request to <name>"
--     fresh_hint(),           the key or command that offers a fresh session instead
--     cancel_cmd,             the command that withdraws it (":RevueyGuide cancel")
--     imported,               what an import shows ("the guide")
--     ready(a, rec, secs),    the notification when the agent imported it
--   }
local config = require('revuey.config')

local M = {}

---Requests this Neovim tried to withdraw (any kind): never adopted again, whatever their file says.
M.cancel_tried = {}

local function state_dir(s)
  return s.opts.state_dir or config.options.state_dir or require('revuey.state').default_dir()
end
M.state_dir = state_dir

---Ask the connected agent: write a request of `kind` for the session's current review (`extra`:
---the kind's own fields, merged into the record) and append its event to the review's feed.
---@return table? rec, string|nil name_or_err, string? path
function M.create(s, kind, extra)
  local requests = require('revuey.requests')
  local comments = require('revuey.comments')
  local link = require('revuey.agent_link')
  local r = s.review
  local info = comments.review_info(r)
  local name = link.agent_name(s)
  local fields = {
    session = s.link and s.link.id or nil,
    worktree = r.root,
    review = info,
    scope_key = r.state._path and vim.fs.basename(r.state._path):gsub('%.json$', '') or nil,
    label = require('revuey.sessions').scope_label(info),
    agent = name,
  }
  for k, v in pairs(extra or {}) do
    fields[k] = v
  end
  local rec = requests.new(kind, fields)
  local path, werr = requests.create(requests.dir(state_dir(s)), rec)
  if not path then
    return nil, 'could not ask ' .. name .. ': ' .. tostring(werr)
  end
  local events = (s.cm and s.cm.events) or comments.events_path_for(r.state._path)
  local ok, res, aerr = pcall(comments.append_event, events, requests.event(rec))
  if not ok or res == false then
    os.remove(path)
    return nil, 'could not ask ' .. name .. ': ' .. tostring(ok and aerr or res)
  end
  return rec, name, path
end

---The job of a request: {label, started, on_change, agent = {id, path, name, ...}}.
function M.job(rec, path, name, label, on_change)
  return {
    label = label,
    started = vim.uv.hrtime(),
    on_change = on_change,
    agent = { id = rec.id, path = path, name = name, checked = vim.uv.hrtime() },
  }
end

---Status words of a request job, or nil when `j` is not one: `acked` (e.g. "is writing the
---guide"), else "has the request", "has not picked it up", "waiting for".
function M.status_text(j, frame, acked_words, fresh_hint)
  local a = j and j.agent
  if not a then
    return nil
  end
  local secs = math.floor((vim.uv.hrtime() - j.started) / 1e9)
  if a.acked then
    return ('%s %s %s %ds'):format(frame, a.name, acked_words, secs)
  elseif a.delivered then
    return ('%s %s has the request %ds'):format(frame, a.name, secs)
  elseif a.late then
    return ('! %s has not picked it up (%ds): %s for a fresh session'):format(a.name, secs, fresh_hint)
  end
  return ('%s waiting for %s %ds'):format(frame, a.name, secs)
end

---Read the files of the host's request jobs (every AGENT_POLL_MS: a stat, and a read only when
---it changed): delivered (a watch printed it), taken (acked), done (imported: the job ends and
---`on_change` shows it), cancelled elsewhere or gone, or past requests.TTL_MS (expired: the CLI
---no longer lists it). Not delivered within AGENT_ACK_MS: said once (a delivered request is fine
---however long the agent takes to start).
function M.poll(host)
  local requests = require('revuey.requests')
  local q = host.req
  local now = vim.uv.hrtime()
  for ks, j in pairs(host.jobs) do
    local a = j.agent
    if a and now - (a.checked or 0) >= host.AGENT_POLL_MS * 1e6 then
      a.checked = now
      local st = vim.uv.fs_stat(a.path)
      local sig = st and (st.mtime.sec .. '.' .. st.mtime.nsec .. ':' .. st.size) or 'gone'
      local expired = now - j.started >= requests.TTL_MS * 1e6
      if sig ~= a.sig or expired then
        a.sig = sig
        local rec = st and requests.read(a.path)
        if not rec or rec.status == 'cancelled' or rec.status == 'done' or expired then
          host.jobs[ks] = nil
          if rec and rec.status == 'done' then
            local secs = math.floor((now - j.started) / 1e9 + 0.5)
            vim.notify(q.ready(a, rec, secs), vim.log.levels.INFO)
          elseif expired and rec then
            vim.notify(('revuey: the %s request to %s expired; %s'):format(q.noun, a.name, q.expired_hint), vim.log.levels.WARN)
          else
            vim.notify(('revuey: the %s request to %s was %s'):format(q.noun, a.name, rec and 'cancelled' or 'removed'), vim.log.levels.INFO)
          end
          j.on_change()
        else
          a.acked = rec.status == 'acked'
          a.delivered = a.acked or rec.delivered_at ~= nil
        end
      end
      if host.jobs[ks] == j and not a.delivered and not a.late and now - j.started >= host.AGENT_ACK_MS * 1e6 then
        a.late = true
        vim.notify(('revuey: %s has not picked up the %s request yet; %s offers a fresh session instead (or keep waiting)'):format(
          a.name, q.noun, q.fresh_hint()), vim.log.levels.WARN)
      end
    end
  end
end

---Withdraw the request of job `j` (host.jobs[ks]): the file says cancelled (the import refuses
---it) and the feed tells the agent. A busy lock (an import saving) is retried every
---CANCEL_STEP_MS for CANCEL_RETRY_MS, never blocking; the job ends only once the file says so.
---`after(ok)`: called once the withdrawal is done or failed.
function M.cancel(s, host, ks, j, after)
  local requests = require('revuey.requests')
  local comments = require('revuey.comments')
  local q = host.req
  local a = j.agent
  M.cancel_tried[a.id] = true
  a.cancelling = true
  local deadline = vim.uv.now() + host.CANCEL_RETRY_MS
  local function finish(drop, msg, level, ok)
    a.cancelling = nil
    if drop and host.jobs[ks] == j then
      host.jobs[ks] = nil
    end
    vim.notify(msg, level)
    if drop then
      j.on_change()
    end
    if after then
      after(ok)
    end
  end
  local function attempt()
    local rec, uerr = requests.update(a.path, function(x)
      if x.status == 'done' or x.status == 'cancelled' then
        return false
      end
      x.status, x.cancelled_at = 'cancelled', requests.now_ms()
    end)
    if not rec and not vim.uv.fs_stat(a.path) then
      return finish(true, ('revuey: the %s request to %s is gone'):format(q.noun, a.name), vim.log.levels.INFO, true)
    elseif not rec then
      if vim.uv.now() < deadline then
        return vim.defer_fn(attempt, host.CANCEL_STEP_MS)
      end
      require('revuey.log').write('agent', 'could not cancel request ' .. a.id .. ': ' .. tostring(uerr))
      return finish(false, ('revuey: could not withdraw the %s request to %s (%s); still waiting: try %s again'):format(
        q.noun, a.name, tostring(uerr), q.cancel_cmd), vim.log.levels.ERROR, false)
    elseif rec.status == 'done' then
      return finish(true, ('revuey: %s had already imported %s; it is shown'):format(a.name, q.imported), vim.log.levels.INFO, true)
    end
    local events = (s.cm and s.cm.events) or comments.events_path_for(s.review.state._path)
    pcall(comments.append_event, events, requests.event(rec))
    finish(true, ('revuey: %s request to %s cancelled'):format(q.noun, a.name), vim.log.levels.INFO, true)
  end
  attempt()
end

---An open request of `kind` for this review (`matches(rec)`) made by a review that is gone
---(Neovim quit or crashed while waiting, or this Neovim lost the job): its job, waiting as if this
---review had asked (the age counts from the request's `at`), or nil. Requests of another live
---review are left to it, and one this Neovim tried to withdraw is never taken back.
function M.adopt(s, kind, matches, label, on_change)
  local requests = require('revuey.requests')
  local sessions = require('revuey.sessions')
  local mine = tostring(vim.uv.os_getpid())
  for _, rec in ipairs(requests.list({ state_dir(s) }, { open = true })) do
    local sid = rec.session and tostring(rec.session)
    local owner_gone = not sid or sid == mine or not sessions.alive({ pid = tonumber(sid) })
    if rec.kind == kind and owner_gone and not M.cancel_tried[rec.id] and matches(rec) then
      local age_ns = math.max(0, requests.now_ms() - (tonumber(rec.at) or 0)) * 1e6
      return {
        label = label,
        started = vim.uv.hrtime() - age_ns,
        on_change = on_change,
        skill = rec.skill and rec.skill.name or nil,
        skill_arg = rec.skill and rec.skill.path or nil,
        agent = {
          id = rec.id,
          path = rec._path,
          name = rec.agent or 'agent',
          acked = rec.status == 'acked',
          delivered = rec.status == 'acked' or rec.delivered_at ~= nil,
          adopted = true,
        },
      }
    end
  end
end

return M
