-- The review's side of the link to a coding-agent session (UI glue over sessions.lua): it
-- registers the running review in the session registry (rewritten when the scope or branch
-- changes, removed on close and on exit), and polls the watchers for presence, shown in the
-- panel header ("● agent connected" / "○ no agent") and on sent comments. Sending itself is in
-- comments_view.lua (it saves the comment and appends a `sent` event to the feed). A switch of
-- the worktree to another stack layer is told to a connected agent here (`tell_switch`: a
-- `switched` event in the feed). Beside the entry it publishes the PR threads and discussion
-- (conversation comments, review summaries) the review fetched (`discussion`), for `bin/revuey
-- threads`, rewritten when their content changes.
local api = vim.api
local sessions = require('revuey.sessions')
local config = require('revuey.config')
local log = require('revuey.log')

local M = {}

M.POLL_MS = 2000

local live = {} -- registry path -> true, removed on exit
local linked = {} -- session -> true while attached (a switch still waiting is sent on exit)
local group
local flush

local function on_exit()
  for s in pairs(linked) do
    flush(s.link)
  end
  linked = {}
  for path in pairs(live) do
    sessions.remove(path)
  end
  live = {}
end

local function checked_out(r)
  for _, l in ipairs(r.stack and r.stack.layers or {}) do
    if l.is_head then
      return not l.detached and l.name or nil
    end
  end
  return r.branch ~= 'HEAD' and not r.target and r.branch or nil
end

---The stack of the review, for `bin/revuey stack`: its layers bottom first, each with its parent,
---the revs its own diff is taken from (`parent_rev`, `tip`; the CLI floors the base at trunk as
---review.merge_base_for does) and its PR as the review last looked it up (forge_view.pr: cached
---only, never fetched); the layer the review shows (nil in full-stack scope) and the stack's
---notes. Nil for a review that is not a stack's.
function M.stack_info(s)
  local r = s.review
  local st = r.stack
  if not (st and st.layers and r.scope) then
    return nil
  end
  local layers, notes = {}, {}
  for _, n in ipairs(st.notes or {}) do
    notes[#notes + 1] = { kind = n.kind, branch = n.branch, text = n.text }
  end
  for i, l in ipairs(st.layers) do
    local ok, pr = pcall(require('revuey.forge_view').pr, s, l.name)
    pr = ok and type(pr) == 'table' and pr or nil
    layers[i] = {
      name = l.name,
      parent = l.parent,
      parent_rev = l.parent_rev,
      tip = l.tip,
      is_head = l.is_head or nil,
      title = l.title,
      landed = l.landed or nil,
      remote = (l.remote or l.unfetched) or nil,
      pr = pr and { number = pr.number, title = pr.title, url = pr.url, state = pr.state, draft = pr.draft or nil } or nil,
    }
  end
  return {
    kind = st.kind,
    trunk = st.trunk,
    viewed = r.scope.kind == 'layer' and r.scope.index or nil,
    trunk_rev = st.trunk_rev,
    layers = layers,
    notes = notes,
  }
end

-- ---------------------------------------------------------------------------
-- The PR discussion, for `bin/revuey threads`
-- ---------------------------------------------------------------------------

M.BODY_MAX = 8000 -- characters of a comment kept in the threads file (the CLI cuts further)

---The review's PRs (stack order; the plain review's alone) that are shown (forge_view.scope_prs)
---or have threads cached: `{key, pr, cache, shown}`.
local function discussion_prs(s)
  local fv = require('revuey.forge_view')
  local forge = require('revuey.forge')
  local f, r = s.forge, s.review
  if not (f and f.targets) then
    return {}
  end
  local shown = {}
  for _, pr in ipairs(fv.scope_prs(s, true)) do
    shown[pr.url] = true
  end
  local keys = {}
  if r.stack and r.stack.layers then
    for _, l in ipairs(r.stack.layers) do
      keys[#keys + 1] = l.name
    end
  else
    keys[1] = ''
  end
  local out, seen = {}, {}
  for _, k in ipairs(keys) do
    local pr = f.targets[k] and forge.get(f.targets[k])
    if pr and not seen[pr.url] then
      seen[pr.url] = true
      local e = forge.threads_cache[forge.thread_key(pr)]
      if shown[pr.url] or e then
        out[#out + 1] = { key = k, pr = pr, cache = e, shown = shown[pr.url] or false }
      end
    end
  end
  return out
end

---Is the review still looking its PRs or threads up (or has not yet)?
local function discussion_pending(s)
  local f = s.forge
  return not f or not f.ready or f.busy or false
end

---What the threads file says, from the content hashes the fetch keeps (forge: the threads'
---`sig`, the `discussion_sig`), not when it was fetched: the file is rewritten when this changes,
---so a refetch that brings nothing new rewrites nothing.
local function discussion_sig(s)
  local fv = require('revuey.forge_view')
  local r = s.review
  local parts = { r.branch or '', r.scope and r.scope.kind or '', tostring(fv.threads_enabled()) }
  for _, x in ipairs(discussion_prs(s)) do
    local e = x.cache or {}
    parts[#parts + 1] = table.concat({ x.key, x.pr.url, tostring(x.pr.number), x.pr.state or '', x.pr.title or '', tostring(x.shown),
      tostring(e.threads ~= nil), e.sig or '', tostring(e.failed ~= nil), tostring(e.truncated == true), e.discussion_sig or '',
      tostring(e.discussion_failed == true) }, '\0')
  end
  return table.concat(parts, '\n')
end

local function cut(body)
  body = type(body) == 'string' and body or ''
  if vim.fn.strchars(body) > M.BODY_MAX then
    return vim.fn.strcharpart(body, 0, M.BODY_MAX), true
  end
  return body, nil
end

---The PR review threads and discussion the review fetched (forge.threads_cache, never fetched for
---this): the branch and scope shown, and per PR its number, title, url, state, layer, whether the
---scope shows it, whether its threads were fetched (`fetched`; closed and merged PRs' never
---are), stale (a later fetch failed), cut (`truncated`), the threads (path, lines, side,
---resolved, outdated, comments: author, time, body, `minimized` when GitHub hides it), the
---latest conversation comments and review summaries (`discussion_stale`: their last read
---failed; `discussion` false: never read). Text as GitHub has it, bodies cut at BODY_MAX:
---`bin/revuey threads` cleans it. Whether a lookup still runs is in the registry entry
---(`threads_pending`), not here.
function M.discussion(s)
  local fv = require('revuey.forge_view')
  local r = s.review
  local d = {
    branch = r.branch,
    scope = r.scope and r.scope.kind or 'branch',
    enabled = fv.threads_enabled() and true or false,
    prs = {},
  }
  for _, x in ipairs(discussion_prs(s)) do
    local pr, e = x.pr, x.cache
    local p = {
      layer = x.key ~= '' and x.key or nil,
      number = pr.number,
      title = pr.title,
      url = pr.url,
      state = pr.state,
      shown = x.shown,
      fetched = e ~= nil and e.threads ~= nil,
      stale = (e and e.failed) and true or nil,
      truncated = (e and e.truncated) and true or nil,
      threads = {},
      discussion = (e and e.discussion) and true or false,
      discussion_stale = (e and e.discussion and e.discussion_failed) and true or nil,
      conversation = {},
      conversation_total = e and e.discussion and e.discussion.conversation_total or nil,
      reviews = {},
    }
    for _, t in ipairs(e and e.threads or {}) do
      local th = {
        path = t.path,
        line = t.line,
        start_line = t.start_line,
        original_line = t.original_line,
        original_start_line = t.original_start_line,
        side = t.side,
        start_side = t.start_side,
        subject = t.subject,
        resolved = t.resolved,
        resolved_by = t.resolved_by,
        outdated = t.outdated,
        total = t.total,
        comments = {},
      }
      for _, c in ipairs(t.comments or {}) do
        local body, was_cut = cut(c.body)
        th.comments[#th.comments + 1] = {
          author = c.author,
          created_at = c.created_at,
          body = body,
          cut = was_cut,
          pending = c.state == 'PENDING' or nil,
          minimized = c.minimized,
        }
      end
      p.threads[#p.threads + 1] = th
    end
    local disc = e and e.discussion or {}
    for _, c in ipairs(disc.conversation or {}) do
      local body, was_cut = cut(c.body)
      p.conversation[#p.conversation + 1] = { author = c.author, created_at = c.created_at, body = body, cut = was_cut, minimized = c.minimized }
    end
    for _, rv in ipairs(disc.reviews or {}) do
      local body, was_cut = cut(rv.body)
      p.reviews[#p.reviews + 1] = { author = rv.author, state = rv.state, created_at = rv.submitted_at, body = body, cut = was_cut, minimized = rv.minimized }
    end
    d.prs[#d.prs + 1] = p
  end
  return d
end

---Rewrite the threads file beside the registry entry when what it says changed (or the entry
---moved). A failure is logged and tried again on the next poll.
local function publish_discussion(s)
  local l = s.link
  if not l.path then
    return
  end
  local sig = discussion_sig(s)
  if sig == l.threads_sig and l.threads_for == l.path and vim.uv.fs_stat(sessions.threads_path(l.path)) then
    return
  end
  local ok, res, werr = pcall(sessions.write_threads, l.path, M.discussion(s))
  if ok and res then
    l.threads_sig, l.threads_for = sig, l.path
  else
    log.write('agent', 'could not write the PR threads for bin/revuey threads: ' .. tostring(ok and werr or res))
  end
end

---Registry entry for the session's current review scope.
local function entry(s)
  local r = s.review
  local c = s.cm or {}
  local info = require('revuey.comments_view').review_info(s)
  local key = r.state and r.state._path and vim.fs.basename(r.state._path):gsub('%.json$', '') or nil
  return {
    pid = vim.uv.os_getpid(),
    worktree = r.root,
    git_dir = s.link.git_dir,
    common_dir = s.link.common_dir,
    branch = r.branch,
    -- the branch checked out in the worktree (nil: detached), which may differ from the layer
    -- being viewed; `gS` changes it
    checked_out = checked_out(r),
    -- what git had checked out when the review last loaded ('' detached), even when no layer is
    -- HEAD (a GitHub stack opened from the tree): `bin/revuey stack` tells a lagging review by it
    git_checked_out = r.head_branch or '',
    base = r.base,
    mode = r.mode,
    scope = { kind = info.scope, branch = r.branch, layers = info.layers },
    scope_key = key,
    comments = c.path,
    events = c.events,
    state_dir = c.path and vim.fs.dirname(c.path) or nil,
    server = vim.v.servername ~= '' and vim.v.servername or nil,
    started_at = s.link.started_at,
    -- what `bin/revuey comment` needs to load this exact review headlessly (review.load): the
    -- stack target or the plain base, the diff's old side, and the options that shape hunks
    load = {
      base = r.base,
      from = r.merge_base,
      target = r.target,
      mode = r.mode,
      context_lines = config.options.context_lines,
      max_file_bytes = config.options.max_file_bytes,
      panel_folders = config.options.panel_folders, -- the file order (review.load)
    },
    review = info,
    stack = M.stack_info(s),
    -- the PR lookup or threads fetch still runs (or has not yet): `bin/revuey threads` waits
    threads_pending = discussion_pending(s) or nil,
  }
end

---How the next `revuey` in this worktree opens (sessions.write_last): what this review was
---opened with, resolved against the config.
local function last_review(s)
  local r, o = s.review, s.opts or {}
  local explicit = o.base and o.base ~= '' and o.base or nil
  return {
    worktree = r.root,
    trunk = (r.stack and r.stack.trunk) or (not r.target and r.base) or explicit or config.options.default_branch,
    base = explicit,
    stack = o.scope == 'full' or not explicit,
    scope = o.scope == 'full' and 'full' or 'layer',
    mode = s.link.open_mode,
    state_dir = o.state_dir or config.options.state_dir or require('revuey.state').default_dir(),
    context_lines = config.options.context_lines,
    max_file_bytes = config.options.max_file_bytes,
    panel_folders = config.options.panel_folders,
  }
end

---Write the registry entry when it changed (a scope switch, another branch checked out), or
---with `refresh` anyway: its `updated_at` tells listers this review is still alive.
function M.update(s, refresh)
  local l = s and s.link
  if not l or s.cleaned then
    return
  end
  local last = last_review(s)
  local lsig = vim.json.encode(last)
  if lsig ~= l.last_sig then
    l.last_sig = lsig
    pcall(sessions.write_last, l.bases, last)
  end
  local e = entry(s)
  -- the stack (with PRs that land whenever a lookup answers) and whether a lookup runs are not
  -- review state: they neither
  -- bumps `changed_at` nor counts as a change, or it would end `caught_up`'s wait early
  local st, tp = e.stack, e.threads_pending
  e.stack, e.threads_pending = nil, nil
  local sig = vim.json.encode(e)
  e.stack, e.threads_pending = st, tp
  local full = vim.json.encode(e)
  if not refresh and sig == l.sig and full == l.full_sig and l.path and vim.uv.fs_stat(l.path) then
    publish_discussion(s)
    return
  end
  -- when the entry last said something new (not a refresh): `bin/revuey` waits for a review
  -- that has not followed a switch yet (cli.lua caught_up)
  if sig ~= l.sig or not l.changed_at then
    l.changed_at = sessions.now_ms()
  end
  e.changed_at = l.changed_at
  -- the threads first: an entry that says the lookup is over never comes before them
  publish_discussion(s)
  local path = sessions.register(l.bases, e)
  if path then
    if l.path and l.path ~= path then
      live[l.path] = nil
      sessions.remove(l.path)
    end
    l.path, l.sig, l.full_sig = path, sig, full
    live[path] = true
    publish_discussion(s)
  end
end

---Header text of the file panel (a winbar): " Files" and the agent indicator.
function M.winbar(s)
  local on = s and s.link and s.link.connected
  local ind = on and '%#RevueyAgentOn#● agent connected%*' or '%#RevueyAgentOff#○ no agent%*'
  return ' Files%=' .. ind .. ' '
end

---Check the watchers; on a change redraw the panel header and the comment markers.
---@return boolean connected
function M.poll(s)
  local l = s and s.link
  if not l or s.cleaned then
    return false
  end
  local ok, on, hits = pcall(sessions.connected, l.bases, { id = l.id, worktree = s.review.root })
  on = ok and on or false
  -- an agent that acts on what it is sent: a `watch --messages` (a plain `watch` only prints
  -- events), and its name (`watch --name`), for "Ask <name> (connected)"
  local clean_name = require('revuey.requests').clean_name
  l.agent_name, l.agent_listens = nil, false
  for _, w in ipairs(ok and hits or {}) do
    if w.mode == 'messages' then
      l.agent_listens = true
      l.agent_name = l.agent_name or clean_name(w.name)
    end
  end
  -- keep the registry entry fresh (and write it again if it was removed)
  M.update(s, true)
  if on ~= l.connected then
    l.connected = on
    if s.panel_win and api.nvim_win_is_valid(s.panel_win) then
      vim.wo[s.panel_win].winbar = M.winbar(s)
    end
    if s.layout and s.diff_buf and api.nvim_buf_is_valid(s.diff_buf) then
      pcall(require('revuey.comments_view').render, s)
    end
  end
  return on
end

---The connected agent's name (from its watcher, `watch --name`, cleaned), else "agent".
function M.agent_name(s)
  local n = s and s.link and s.link.agent_name
  return (type(n) == 'string' and n ~= '') and n or 'agent'
end

---Can the review ask the agent for something (a guide)? A `watch --messages` is attached (as of
---the last poll).
function M.listening(s)
  return s and s.link and s.link.connected and s.link.agent_listens or false
end

---Is an agent connected to this review (as of the last poll)?
function M.connected(s)
  return s and s.link and s.link.connected or false
end

---Register the review and start polling for presence.
function M.attach(s)
  if s.link then
    return
  end
  local state_dir = s.opts.state_dir or config.options.state_dir or require('revuey.state').default_dir()
  local gd = sessions.git_dir(s.review.root)
  local common = sessions.common_dir(s.review.root)
  local bases = {}
  if gd then
    bases[#bases + 1] = vim.fs.joinpath(gd, 'revuey')
  end
  bases[#bases + 1] = state_dir
  s.link = {
    id = tostring(vim.uv.os_getpid()),
    git_dir = gd,
    common_dir = common,
    bases = bases,
    started_at = sessions.now_ms(),
    connected = false,
    -- the mode the review was opened in (later `gu` toggles do not change how revuey opens)
    open_mode = s.opts.mode or (config.options.uncommitted and 'worktree' or 'committed'),
  }
  M.update(s)
  linked[s] = true
  if not group then
    group = api.nvim_create_augroup('revuey_agent_link', { clear = true })
    api.nvim_create_autocmd('VimLeavePre', { group = group, callback = on_exit })
  end
  local timer = vim.uv.new_timer()
  s.link.timer = timer
  timer:start(M.POLL_MS, M.POLL_MS, vim.schedule_wrap(function()
    if s.cleaned then
      return
    end
    M.poll(s)
    -- a guide imported from outside (`bin/revuey import-guide`) shows without a request too
    pcall(require('revuey.guide_view').notice_saved, s)
  end))
  M.poll(s)
end

-- ---------------------------------------------------------------------------
-- Telling the agent about a switch
-- ---------------------------------------------------------------------------

-- `]s`/`[s` switches (stack.switch_on_navigate) less than this apart become one message: the
-- agent hears where the user stopped, not every layer passed on the way.
M.SWITCH_COALESCE_MS = 1500

---Append the `switched` event; a failure is logged, never raised.
---@return boolean ok
local function deliver(p)
  local comments = require('revuey.comments')
  local ok, res, err = pcall(function()
    return comments.append_event(p.events, comments.switch_event(p.review, p.info))
  end)
  if ok and res ~= false then
    return true
  end
  log.write('agent', ('could not tell the agent about the switch to %s: %s'):format(p.info.to, tostring(ok and err or res)))
  return false
end

local function take_pending(l)
  local p = l.switch_pending
  l.switch_pending = nil
  if p and p.timer then
    pcall(function()
      p.timer:stop()
      p.timer:close()
    end)
    p.timer = nil
  end
  return p
end

---Send a coalesced switch now.
flush = function(l)
  local p = l and take_pending(l)
  if p then
    deliver(p)
  end
end

---Tell the connected agent that the worktree now has another layer checked out: a `switched`
---event (comments.switch_event) in the review's feed, which `bin/revuey watch --messages`
---prints. Nothing is sent without a connected agent. With `coalesce` (`]s`/`[s`) it waits
---SWITCH_COALESCE_MS for another switch, which takes its place (keeping the first `from`); any
---switch sends a waiting one along with it, as one message. Ending where the agent last heard of
---sends nothing. A review closed while the switch ran (detached) uses the presence last seen,
---and sends at once.
---@param info {from?:string, to:string, layer:string, index?:integer, count?:integer, pr?:table}
---@param o? {coalesce?:boolean}
---@return 'told'|'later'|'failed'|'unchanged'|nil what happened (nil: no agent connected)
function M.tell_switch(s, info, o)
  local l = s and s.link
  if not l then
    return nil
  end
  local waiting = take_pending(l)
  if waiting then
    info.from = waiting.info.from -- the branch the agent last heard of
  end
  local on
  if s.cleaned then
    on = l.connected -- closed during the switch: no more polls, the last one counts
  else
    on = M.poll(s)
  end
  if not on then
    return nil
  end
  if info.from == info.to then
    return 'unchanged'
  end
  info.session, info.worktree = l.id, s.review.root
  local comments = require('revuey.comments')
  local p = {
    info = info,
    review = comments.review_info(s.review),
    events = (s.cm and s.cm.events) or comments.events_path_for(s.review.state._path),
  }
  if o and o.coalesce and not s.cleaned then
    local timer = vim.uv.new_timer()
    p.timer = timer
    l.switch_pending = p
    timer:start(M.SWITCH_COALESCE_MS, 0, vim.schedule_wrap(function()
      if l.switch_pending == p then
        flush(l)
      end
    end))
    return 'later'
  end
  return deliver(p) and 'told' or 'failed'
end

---Stop polling and remove the registry entry (a switch waiting to be told is sent first).
function M.detach(s)
  local l = s and s.link
  if not l then
    return
  end
  flush(l)
  linked[s] = nil
  if l.timer then
    pcall(function()
      l.timer:stop()
      l.timer:close()
    end)
    l.timer = nil
  end
  if l.path then
    live[l.path] = nil
    sessions.remove(l.path)
    l.path = nil
  end
end

return M
