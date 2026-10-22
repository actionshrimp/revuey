-- `bin/revuey <command>`: review comments and the agent link from the shell, for coding agents.
-- Runs as `nvim --clean --headless -l lua/revuey/cli.lua <command> [args]` without any UI.
--
--   sessions [--json] [--all]
--       live reviews of this worktree (--all: of every worktree of the repo), from the session
--       registry (sessions.lua), with whether an agent is watching each
--   watch [--messages] [--json] [--session <id>] [--since <event id>|all] [--all] [--scope ...]
--       attach to the worktree's review session and follow the comment event feed: first the
--       sent messages not yet acknowledged (catch-up), then new events as they happen, one line
--       each, flushed per line (Claude Code's Monitor tool treats each stdout line as an event).
--       --messages prints only messages sent to the agent, as one actionable line. Registers a
--       watcher with a heartbeat (presence in the review). Exits cleanly on SIGTERM (via
--       bin/revuey).
--   show <id>          one message in Markdown: location, review, code, comment, thread
--   reply <id> <text|->
--       add an agent reply to a comment's thread (`-` reads stdin); answers a sent message
--   ack <id>           mark a sent message handled without replying (no re-delivery)
--   inbox [--json]     sent messages not acknowledged yet, then exit (no Monitor needed)
--   comments [--json] [--all] [--scope current|all|<branch>]
--       the comments of the current repo and branch (Markdown, like :RevueyCommentsExport)
--   install-skill [--force] [--copy]
--       link (or copy) the Claude Code skill into ~/.claude/skills/revuey
--
-- Common: --state-dir <dir> (default $REVUEY_STATE_DIR, else stdpath('data')/revuey; the state
-- dirs of live sessions are searched too).
-- Scope: `current` (default) = review scopes of the checked-out branch (its plain review, its
-- stack layer, and full-stack reviews that include it); `all` = every review of the repo;
-- a branch name = review scopes of that branch. Messages (sent events) match by repo only.
local modname = ...
local plugin = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
vim.opt.rtp:prepend(plugin)

local comments = require('revuey.comments')
local export = require('revuey.comments_export')
local git = require('revuey.git')
local sessions = require('revuey.sessions')

local M = {}

local function out(s)
  local ok = io.stdout:write(s)
  if not ok then
    os.exit(0) -- the reader went away
  end
  io.stdout:flush()
end

local function err(s)
  io.stderr:write(s)
  io.stderr:flush()
end

local function die(msg, code)
  -- errors from the modules already say "revuey: "
  msg = tostring(msg):gsub('^revuey: ', '')
  err('revuey: ' .. msg .. '\n')
  os.exit(code or 1)
end

M.USAGE = [[
usage: revuey [base] [--stack] [--committed|--worktree]     open the review UI (Neovim)

For coding agents (no UI; run inside the reviewed worktree):
  revuey sessions [--json] [--all]
      live reviews of this worktree (--all: every worktree of the repo) and whether an agent
      is connected to each
  revuey watch --messages [--session <id>] [--json]
      attach to the review and print each message the user sends you, one line each:
        revuey message <id> <path>:<lines> (<side>) [<branch>]: <first line>  (revuey show <id> ...)
      Unacknowledged messages are printed first (catch-up), then new ones as they are sent.
      Lines are flushed one by one (fit for Claude Code's Monitor tool); SIGTERM exits 0.
      Without --messages every comment event is printed; --json prints full events.
      Several reviews in this worktree: pick one with --session <id> (see `revuey sessions`).
  revuey show <id>               the message in Markdown: file, lines, code, comment, thread
  revuey reply <id> <text|->     answer in the comment's thread (- reads stdin); marks it answered
  revuey ack <id>                mark it handled without replying (it is not delivered again)
  revuey inbox [--json]          messages not acknowledged yet, then exit (when Monitor is missing)
  revuey comments [--json] [--all] [--scope current|all|<branch>]
      all review comments of this branch (Markdown export)
  revuey watch [--json] [--since <event id>|all] [--all] [--scope ...]
      every comment event (created, edited, resolved, replied, sent...)
  revuey install-skill [--force] [--copy]
      install the Claude Code skill as ~/.claude/skills/revuey (a link to this checkout, or a copy)

Ids may be shortened to any unique part. Options: --state-dir <dir> (default $REVUEY_STATE_DIR,
else Neovim's data dir/revuey; live sessions' state dirs are searched too).]]

local VALUE_FLAGS = { ['--scope'] = 'scope', ['--since'] = 'since', ['--state-dir'] = 'state_dir', ['--session'] = 'session' }
local BOOL_FLAGS = { ['--json'] = 'json', ['--all'] = 'all', ['--messages'] = 'messages', ['--force'] = 'force', ['--copy'] = 'copy' }

---@return table opts, string[] positional
function M.parse(args)
  local o, pos = {}, {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == '--' then
      -- everything after `--` is positional
      vim.list_extend(pos, args, i + 1)
      break
    elseif #pos > 0 then
      -- options come before the positionals: the rest (a reply text such as "-- see above")
      -- is positional too
      vim.list_extend(pos, args, i)
      break
    elseif VALUE_FLAGS[a] then
      if not args[i + 1] then
        die(a .. ' needs a value\n' .. M.USAGE, 2)
      end
      o[VALUE_FLAGS[a]] = args[i + 1]
      i = i + 1
    elseif a:match('^%-%-[%w-]+=') then
      local k, v = a:match('^(%-%-[%w-]+)=(.*)$')
      if not VALUE_FLAGS[k] then
        die('unknown option ' .. k .. '\n' .. M.USAGE, 2)
      end
      o[VALUE_FLAGS[k]] = v
    elseif BOOL_FLAGS[a] then
      o[BOOL_FLAGS[a]] = true
    elseif a == '-h' or a == '--help' then
      out(M.USAGE .. '\n')
      os.exit(0)
    elseif a:sub(1, 2) == '--' then
      die('unknown option ' .. a .. '\n' .. M.USAGE, 2)
    else
      pos[#pos + 1] = a
    end
    i = i + 1
  end
  return o, pos
end

---How to call bin/revuey in hints (bin/revuey exports its own absolute path).
local function bin()
  local b = vim.env.REVUEY_BIN
  return (b and b ~= '') and b or 'revuey'
end

local function state_dir(o)
  if o.state_dir and o.state_dir ~= '' then
    return o.state_dir
  end
  if vim.env.REVUEY_STATE_DIR and vim.env.REVUEY_STATE_DIR ~= '' then
    return vim.env.REVUEY_STATE_DIR
  end
  return vim.fs.joinpath(vim.fn.stdpath('data'), 'revuey')
end

local function real(p)
  return p and (vim.uv.fs_realpath(p) or p) or nil
end

---The repo and branch of the current directory.
local function here()
  local root = git.root(vim.fn.getcwd())
  if not root then
    die('not inside a git repository')
  end
  return { root = root, real = real(root), branch = git.current_branch(root) or 'HEAD' }
end

---Live review sessions of the worktree.
local function live_sessions(o, ctx)
  return sessions.list(sessions.bases(ctx.root, state_dir(o)), { worktree = ctx.root })
end

---State dirs to search: --state-dir alone when given, else the default one and those of the
---worktree's live sessions (a review whose config sets another state_dir).
local function state_dirs(o, ctx)
  if o.state_dir and o.state_dir ~= '' then
    return { o.state_dir }
  end
  local dirs, seen = {}, {}
  local function add(d)
    if d and d ~= '' and not seen[real(d)] then
      seen[real(d)] = true
      dirs[#dirs + 1] = d
    end
  end
  add(state_dir(o))
  for _, e in ipairs(live_sessions(o, ctx)) do
    add(e.state_dir)
  end
  return dirs
end

---Does a review (info table from a comments file or an event) belong to the selected scope?
function M.matches(review, ctx, scope)
  if type(review) ~= 'table' or not review.repo then
    return false
  end
  if review.repo ~= ctx.root and real(review.repo) ~= ctx.real then
    return false
  end
  if scope == 'all' then
    return true
  end
  local b = (not scope or scope == 'current') and ctx.branch or scope
  return review.branch == b or review.state_branch == b or vim.tbl_contains(review.layers or {}, b)
end

---Comments files of the selected reviews in `dirs`: { {path, store}, ... } (sorted by branch, scope).
local function stores(dirs, ctx, scope, readonly)
  local list = {}
  for _, dir in ipairs(dirs) do
    if vim.uv.fs_stat(dir) then
      for name, t in vim.fs.dir(dir) do
        if t == 'file' and name:match('%.comments%.json$') then
          local path = vim.fs.joinpath(dir, name)
          local store = comments.load(path, readonly and { readonly = true } or nil)
          if M.matches(store.review, ctx, scope) then
            list[#list + 1] = { path = path, store = store }
          end
        end
      end
    end
  end
  table.sort(list, function(a, b)
    local ra, rb = a.store.review, b.store.review
    if (ra.scope == 'full') ~= (rb.scope == 'full') then
      return rb.scope == 'full'
    end
    if (ra.branch or '') ~= (rb.branch or '') then
      return (ra.branch or '') < (rb.branch or '')
    end
    return a.path < b.path
  end)
  return list
end

local function events_path(comments_path)
  return (comments_path:gsub('%.comments%.json$', '.events.jsonl'))
end

function M.comments(o)
  local ctx = here()
  local reviews = {}
  -- read-only: an unreadable file is reported, never moved aside
  for _, e in ipairs(stores(state_dirs(o, ctx), ctx, o.scope, true)) do
    local list = export.select(e.store, { all = o.all })
    if #list > 0 then
      reviews[#reviews + 1] = { review = e.store.review, comments = list }
    end
  end
  if #reviews == 0 then
    reviews[1] = { review = { repo = ctx.root, branch = ctx.branch }, comments = {} }
    if o.json then
      reviews = {}
    end
  end
  out(export.render(o.json and 'json' or 'markdown', reviews))
end

---The comment `id` (any unique part) in the repo's reviews: entry {path, store}, comment.
local function find_comment(o, id, readonly)
  local ctx = here()
  local found = {}
  for _, e in ipairs(stores(state_dirs(o, ctx), ctx, o.scope or 'all', readonly)) do
    local c = comments.find(e.store, id)
    if c then
      found[#found + 1] = { e = e, c = c }
    end
  end
  if #found == 0 then
    die('no comment ' .. id .. ' in this repository')
  elseif #found > 1 then
    die('comment id ' .. id .. ' is ambiguous (several reviews)')
  end
  return found[1].e, found[1].c
end

local function agent_author()
  return { kind = 'agent', name = (vim.env.REVUEY_AGENT_NAME ~= '' and vim.env.REVUEY_AGENT_NAME) or 'agent' }
end

local function save(store)
  local ok, e = pcall(comments.save, store)
  if not ok then
    die(tostring(e))
  end
end

function M.reply(o, pos)
  local id, text = pos[1], pos[2]
  if not id or not text then
    die('reply needs a comment id and a text (or - for stdin)\n' .. M.USAGE, 2)
  end
  if text == '-' then
    text = io.stdin:read('*a') or ''
  end
  text = vim.trim(text)
  if text == '' then
    die('empty reply')
  end
  local e, c = find_comment(o, id)
  local r = comments.reply(e.store, c.id, text, agent_author())
  if c.sent_at then
    comments.mark_answered(e.store, c.id) -- a message sent to the agent: answered
  end
  save(e.store)
  comments.append_event(events_path(e.path), comments.event('replied', comments.get(e.store, c.id), e.store.review, { reply = r }))
  out(('replied to %s (%s)\n'):format(c.id, comments.location(c)))
end

function M.ack(o, pos)
  local id = pos[1]
  if not id then
    die('ack needs a comment id\n' .. M.USAGE, 2)
  end
  local e, c = find_comment(o, id)
  local acked = comments.ack(e.store, c.id)
  save(e.store)
  comments.append_event(events_path(e.path), comments.event('acked', acked, e.store.review))
  out(('acknowledged %s (%s)%s\n'):format(c.id, comments.location(c), c.sent_at and '' or ' (it was never sent)'))
end

function M.show(o, pos)
  local id = pos[1]
  if not id then
    die('show needs a comment id\n' .. M.USAGE, 2)
  end
  local e, c = find_comment(o, id, true)
  out(export.message(c, e.store.review, bin()))
end

---Messages (sent events) not acknowledged yet in the repo's reviews, oldest first.
local function pending(dirs, ctx)
  local list = {}
  for _, e in ipairs(stores(dirs, ctx, 'all', true)) do
    for _, c in ipairs(comments.unacked(e.store)) do
      list[#list + 1] = comments.sent_event(c, e.store.review, { catchup = true })
    end
  end
  table.sort(list, function(a, b)
    if a.sent_at ~= b.sent_at then
      return a.sent_at < b.sent_at
    end
    return a.comment_id < b.comment_id
  end)
  return list
end

function M.inbox(o)
  local ctx = here()
  local list = pending(state_dirs(o, ctx), ctx)
  if o.json then
    out((#list > 0 and vim.json.encode(list) or '[]') .. '\n')
    return
  end
  if #list == 0 then
    out('no unacknowledged messages\n')
    return
  end
  for _, ev in ipairs(list) do
    out(comments.message_line(ev, bin()) .. '\n')
  end
end

local function ago(ms)
  local d = math.floor((sessions.now_ms() - (tonumber(ms) or 0)) / 1000)
  if d < 60 then
    return d .. 's ago'
  elseif d < 3600 then
    return math.floor(d / 60) .. ' min ago'
  elseif d < 86400 then
    return math.floor(d / 3600) .. ' h ago'
  end
  return math.floor(d / 86400) .. ' d ago'
end

local function scope_text(e)
  local sc = e.scope or {}
  if sc.kind == 'full' then
    return 'full stack'
  elseif sc.kind == 'layer' then
    return 'stack layer'
  end
  return 'branch'
end

function M.sessions(o)
  local ctx = here()
  local bases = o.all and sessions.all_bases(ctx.root, state_dir(o)) or sessions.bases(ctx.root, state_dir(o))
  local list = sessions.list(bases, { worktree = not o.all and ctx.root or nil })
  for _, e in ipairs(list) do
    local where = { e._base }
    if e.git_dir then
      where[#where + 1] = vim.fs.joinpath(e.git_dir, 'revuey')
    end
    where[#where + 1] = e.state_dir
    e.agent_connected = sessions.connected(where, e)
  end
  if o.json then
    local clean = vim.tbl_map(function(e)
      local c = {}
      for k, v in pairs(e) do
        if k:sub(1, 1) ~= '_' then
          c[k] = v
        end
      end
      return c
    end, list)
    out((#clean > 0 and vim.json.encode(clean) or '[]') .. '\n')
    return
  end
  if #list == 0 then
    out(('no revuey sessions for %s (start one with `%s` there)\n'):format(o.all and 'this repository' or ctx.root, bin()))
    return
  end
  for _, e in ipairs(list) do
    out(('%s  %s (%s)  %s  started %s  %s\n'):format(
      e.id,
      e.branch or '?',
      scope_text(e),
      e.worktree or '?',
      ago(e.started_at),
      e.agent_connected and '● agent connected' or '○ no agent'
    ))
  end
end

local function session_list_text(list)
  local t = {}
  for _, e in ipairs(list) do
    t[#t + 1] = ('  %s  %s (%s)  started %s'):format(e.id, e.branch or '?', scope_text(e), ago(e.started_at))
  end
  return table.concat(t, '\n')
end

---Follow the event feeds of the state dirs (new files included), printing matching events, after
---catching up on unacknowledged messages. Registers a watcher (presence) while it runs.
function M.watch(o)
  local ctx = here()
  local default_dir = state_dir(o)
  vim.fn.mkdir(default_dir, 'p')
  local bases = sessions.bases(ctx.root, default_dir)
  local since = o.since
  if since == 'all' or since == '0' then
    since = ''
  end
  local running = true
  pcall(vim.api.nvim_create_autocmd, 'Signal', {
    pattern = { 'SIGUSR1', 'SIGUSR2' },
    callback = function()
      running = false
    end,
  })
  local ppid = vim.uv.os_getppid()
  local owner = tonumber(vim.env.REVUEY_WATCH_OWNER or '')
  if owner and owner <= 1 then
    owner = nil
  end

  -- the session to attach to
  local attached
  local list = sessions.list(bases, { worktree = ctx.root })
  if o.session then
    for _, e in ipairs(list) do
      if e.id == o.session then
        attached = e
      end
    end
    if not attached then
      die(('no live revuey session %s in %s%s'):format(o.session, ctx.root, #list > 0 and (':\n' .. session_list_text(list)) or ''), 2)
    end
  elseif #list > 1 then
    die(('several revuey sessions in %s; pick one with --session <id>:\n%s'):format(ctx.root, session_list_text(list)), 2)
  else
    attached = list[1]
  end

  -- presence: a watcher record with a heartbeat, removed on exit
  local me = { pid = vim.uv.os_getpid(), worktree = ctx.root, started_at = sessions.now_ms(), mode = o.messages and 'messages' or 'events' }
  local watcher_path
  local function heartbeat()
    me.session = attached and attached.id or vim.NIL
    me.heartbeat_at = sessions.now_ms()
    watcher_path = sessions.write_watcher(bases, me) or watcher_path
  end
  heartbeat()

  local tracked = {} ---@type table<string, {fd:integer, ino:integer, offset:integer, partial:string}>
  local known_dirs = {}
  local seen = {} -- message keys already printed

  local function emit(ev)
    local is_msg = ev.kind == 'sent'
    if is_msg then
      if not M.matches(ev.review, ctx, 'all') then
        return
      end
      local key = comments.message_key(ev)
      if seen[key] then
        return
      end
      seen[key] = true
    else
      if o.messages or not M.matches(ev.review, ctx, o.scope) then
        return
      end
      if since and not (ev.id > since) then
        return
      end
      -- the agent's own replies (and acks) are not news to it
      if not o.all and ((ev.kind == 'replied' and ev.reply and ev.reply.author and ev.reply.author.kind == 'agent') or ev.kind == 'acked') then
        return
      end
    end
    local line
    if o.json then
      line = vim.json.encode(ev)
    elseif o.messages then
      line = comments.message_line(ev, bin())
    else
      line = comments.event_line(ev)
    end
    out(line .. '\n')
  end

  local function lines(t, data)
    local text = t.partial .. data
    local last = text:match('.*\n()') or 1
    t.partial = text:sub(last)
    for _, ev in ipairs(comments.decode_events(text:sub(1, last - 1))) do
      emit(ev)
    end
  end

  local function open(path, from_end)
    local fd = vim.uv.fs_open(path, 'r', 438)
    if not fd then
      return nil
    end
    local st = vim.uv.fs_fstat(fd)
    local t = { fd = fd, ino = st.ino, offset = from_end and st.size or 0, partial = '' }
    tracked[path] = t
    return t
  end

  local function drain(t)
    local st = vim.uv.fs_fstat(t.fd)
    while st and st.size > t.offset do
      local data = vim.uv.fs_read(t.fd, math.min(st.size - t.offset, 1024 * 1024), t.offset)
      if not data or data == '' then
        break
      end
      t.offset = t.offset + #data
      lines(t, data)
    end
  end

  local function read_whole(path)
    local fd = io.open(path, 'r')
    if fd then
      local t = { partial = '' }
      lines(t, fd:read('*a'))
      fd:close()
    end
  end

  local function dirs()
    local out_dirs = { default_dir }
    if attached and attached.state_dir and real(attached.state_dir) ~= real(default_dir) then
      out_dirs[#out_dirs + 1] = attached.state_dir
    end
    return out_dirs
  end

  local function catch_up()
    for _, ev in ipairs(pending(dirs(), ctx)) do
      emit(ev)
    end
  end

  ---Returns true when a directory was seen for the first time (its messages need a catch-up).
  local function poll()
    local fresh = false
    for _, dir in ipairs(dirs()) do
      local first = not known_dirs[dir]
      known_dirs[dir] = true
      fresh = fresh or first
      if vim.uv.fs_stat(dir) then
        for name, ty in vim.fs.dir(dir) do
          if ty == 'file' and name:match('%.events%.jsonl$') then
            local path = vim.fs.joinpath(dir, name)
            if not tracked[path] then
              if first and since then
                read_whole(path .. '.1') -- rotated events, for --since
              end
              -- files there when the dir is first seen: only what comes next (unless --since);
              -- new files: all of it
              open(path, first and not since)
            end
          end
        end
      end
    end
    for path, t in pairs(tracked) do
      drain(t)
      local st = vim.uv.fs_stat(path)
      if not st or st.ino ~= t.ino then
        -- rotated (or removed): the old file is drained; follow the new one from its start. If
        -- `.1` is not the file we followed, it rotated twice since the last poll: read that
        -- generation whole first.
        vim.uv.fs_close(t.fd)
        tracked[path] = nil
        local prev = vim.uv.fs_stat(path .. '.1')
        if st and prev and prev.ino ~= t.ino then
          read_whole(path .. '.1')
        end
        if st then
          local nt = open(path, false)
          if nt then
            drain(nt)
          end
        end
      end
    end
    return fresh
  end

  local function describe()
    if attached then
      return ('session %s (%s, %s)'):format(attached.id, attached.worktree or ctx.root, attached.branch or '?')
    end
    return 'no session yet'
  end

  -- feeds first (from their end), then the stored messages: a message sent in between is in
  -- both, and printed once
  poll()
  catch_up()
  if not attached then
    err(('revuey: no revuey session in %s yet; waiting for one (start `%s` there)\n'):format(ctx.root, bin()))
  end
  err(('revuey: watching %s for %s\n'):format(describe(), o.messages and 'messages sent to the agent' or ('comment events (' .. (o.scope or ('branch ' .. ctx.branch)) .. ')')))
  local last_beat, last_check = vim.uv.now(), vim.uv.now()
  local several_noted = false
  while running do
    vim.wait(250, function()
      return not running
    end, 25)
    if not running then
      break
    end
    local now = vim.uv.now()
    if now - last_check >= 1000 then
      last_check = now
      -- the session ended: wait for the next one (a review restarted in this worktree)
      if attached and not (attached._path and vim.uv.fs_stat(attached._path)) then
        err(('revuey: session %s ended; waiting for the next review in %s\n'):format(attached.id, ctx.root))
        attached = nil
        heartbeat()
      end
      if not attached then
        local l = sessions.list(bases, { worktree = ctx.root })
        if #l == 1 then
          attached = l[1]
          heartbeat()
          err(('revuey: attached to %s\n'):format(describe()))
        elseif #l > 1 and not several_noted then
          several_noted = true
          err(('revuey: several revuey sessions in %s; restart with --session <id>:\n%s\n'):format(ctx.root, session_list_text(l)))
        end
      else
        -- follow scope switches (the feed of another scope may live in another state dir)
        local cur = sessions.list(bases, { worktree = ctx.root })
        for _, e in ipairs(cur) do
          if e.id == attached.id then
            attached = e
          end
        end
      end
    end
    if poll() then
      catch_up()
    end
    if now - last_beat >= sessions.HEARTBEAT_MS then
      last_beat = now
      heartbeat()
    end
    if vim.uv.os_getppid() ~= ppid or (owner and vim.uv.kill(owner, 0) ~= 0) then
      break -- the launcher (bin/revuey) or whoever started it is gone
    end
  end
  sessions.remove(watcher_path)
  os.exit(0)
end

---`install-skill`: link (default) or copy skill/revuey into $HOME/.claude/skills/revuey.
function M.install_skill(o)
  local src = vim.fs.joinpath(plugin, 'skill', 'revuey')
  if not vim.uv.fs_stat(vim.fs.joinpath(src, 'SKILL.md')) then
    die('the skill is missing from ' .. src)
  end
  local home = vim.env.HOME
  if not home or home == '' then
    die('$HOME is not set')
  end
  local parent = vim.fs.joinpath(home, '.claude', 'skills')
  local dest = vim.fs.joinpath(parent, 'revuey')
  local st = vim.uv.fs_lstat(dest)
  if st then
    local link = st.type == 'link' and vim.uv.fs_readlink(dest) or nil
    if link == src and not o.copy then
      out(('the revuey skill is already installed: %s -> %s\n'):format(dest, src))
      return
    end
    if not o.force then
      local tty = vim.uv.guess_handle(0) == 'tty' or vim.env.REVUEY_ASSUME_TTY == '1'
      if not tty then
        die(dest .. ' already exists; use --force to replace it')
      end
      err(dest .. ' already exists. Replace it? [y/N] ')
      local answer = io.stdin:read('*l') or ''
      if not answer:match('^%s*[yY]') then
        die('left ' .. dest .. ' as it was')
      end
    end
    if st.type == 'directory' then
      vim.fn.delete(dest, 'rf')
    else
      os.remove(dest)
    end
  end
  vim.fn.mkdir(parent, 'p')
  if o.copy then
    local function copy_dir(from, to)
      vim.fn.mkdir(to, 'p')
      for name, t in vim.fs.dir(from) do
        local a, b = vim.fs.joinpath(from, name), vim.fs.joinpath(to, name)
        if t == 'directory' then
          copy_dir(a, b)
        else
          assert(vim.uv.fs_copyfile(a, b))
          local mode = vim.uv.fs_stat(a).mode
          vim.uv.fs_chmod(b, bit.band(mode, tonumber('777', 8)))
        end
      end
    end
    copy_dir(src, dest)
    -- a copy cannot find this checkout through its own path: remember where bin/revuey is
    local b = vim.env.REVUEY_BIN
    if not b or b == '' then
      b = vim.fs.joinpath(plugin, 'bin', 'revuey')
    end
    vim.fn.writefile({ b }, vim.fs.joinpath(dest, '.revuey-bin'))
    out(('installed a copy of the revuey skill in %s (using %s)\n'):format(dest, b))
  else
    local ok, e = vim.uv.fs_symlink(src, dest)
    if not ok then
      die('cannot link ' .. dest .. ': ' .. tostring(e))
    end
    out(('installed the revuey skill: %s -> %s\n'):format(dest, src))
  end
end

local COMMANDS = {
  comments = M.comments,
  reply = M.reply,
  watch = M.watch,
  sessions = M.sessions,
  show = M.show,
  ack = M.ack,
  inbox = M.inbox,
  ['install-skill'] = M.install_skill,
}

function M.main(args)
  local cmd = table.remove(args, 1)
  if cmd == 'help' or cmd == '-h' or cmd == '--help' then
    out(M.USAGE .. '\n')
    return
  end
  local fn = COMMANDS[cmd]
  if not fn then
    die('unknown command ' .. tostring(cmd) .. '\n' .. M.USAGE, 2)
  end
  local o, pos = M.parse(args)
  fn(o, pos)
end

-- run as a script (`nvim -l cli.lua ...`), not required as a module
if modname ~= 'revuey.cli' then
  M.main(vim.deepcopy(_G.arg or {}))
  os.exit(0)
end

return M
