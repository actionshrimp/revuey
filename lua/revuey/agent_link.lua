-- The review's side of the link to a coding-agent session (UI glue over sessions.lua): it
-- registers the running review in the session registry (rewritten when the scope or branch
-- changes, removed on close and on exit), and polls the watchers for presence, shown in the
-- panel header ("● agent connected" / "○ no agent") and on sent comments. Sending itself is in
-- comments_view.lua (it saves the comment and appends a `sent` event to the feed).
local api = vim.api
local sessions = require('revuey.sessions')
local config = require('revuey.config')

local M = {}

M.POLL_MS = 2000

local live = {} -- registry path -> true, removed on exit
local group

local function on_exit()
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
    },
    review = info,
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
  local sig = vim.json.encode(e)
  if not refresh and sig == l.sig and l.path and vim.uv.fs_stat(l.path) then
    return
  end
  local path = sessions.register(l.bases, e)
  if path then
    if l.path and l.path ~= path then
      live[l.path] = nil
      sessions.remove(l.path)
    end
    l.path, l.sig = path, sig
    live[path] = true
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
  local ok, on = pcall(sessions.connected, l.bases, { id = l.id, worktree = s.review.root })
  on = ok and on or false
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
  end))
  M.poll(s)
end

---Stop polling and remove the registry entry.
function M.detach(s)
  local l = s and s.link
  if not l then
    return
  end
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
