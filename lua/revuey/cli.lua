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
--   comment --path <path> (--line N [--end M] [--side new|old] | --file) [--session <id>] <text|->
--       leave a new comment (author agent) on lines of the review's diff or on a whole changed
--       file, in the review the session (or, with none running, the CLI's scope) shows
--   hunks [--json] [--prompt] [--session <id>]
--       the review's hunks with their ids and numbered lines (what an AI review sees), and the
--       diff hash; --prompt: the whole prompt revuey's own AI review sends
--   import-review [--name <n>] [--session <id>] <file|->   |   import-review --schema
--       import an AI review document (ai_review_prompt.SCHEMA): its findings become AI comments
--       to triage in the review, its summary and verdict the review's record
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
  revuey watch --messages [--session <id>] [--json] [--replay]
      attach to the review and print each message the user sends you, one line each:
        revuey message <id> <path>:<lines> (<side>) [<branch>]: <first line>  (revuey show <id> ...)
      Messages no watch has printed yet come first (catch-up), then new ones as they are sent.
      A printed message is not printed again by the next watch (--replay: print every message
      not yet answered or acknowledged). Messages of another running review (even a suspended
      one) are left to it; a review that ended is replaced by the next one of its scope.
      Lines are flushed one by one (fit for Claude Code's Monitor tool); SIGTERM exits 0.
      Without --messages every comment event is printed; --json prints full events.
      Several reviews in this worktree: pick one with --session <id> (see `revuey sessions`).
  revuey show <id>               the message in Markdown: file, lines, code, comment, thread
  revuey reply <id> <text|->     answer in the comment's thread (- reads stdin); marks it answered
  revuey comment --path <path> --line N [--end M] [--side new|old] [--session <id>] <text|->
  revuey comment --path <path> --file [--session <id>] <text|->
      leave a new comment in the review (local only, never posted anywhere): on lines of the
      diff (new: the code after the change, the default; old: deleted lines), which must be
      inside a hunk on that side, or on a whole changed file (--file). Prints the comment id
      and where it went. Same review as watch: the only live one, else --session <id>; with
      none running, the review `revuey` would open here.
  revuey hunks [--json] [--prompt] [--session <id>]
      the review's hunks, each under its id (`@@ h7 path @@`) with its lines numbered within
      the hunk (`3|+code`), and the diff hash; --prompt prints the whole prompt revuey's own
      AI review uses (instructions, then the diff). Same review as comment.
  revuey import-review [--name <reviewer>] [--session <id>] <file|->
      import a review (JSON: summary, verdict, findings anchored to a hunk id and line numbers
      of that hunk; `--schema` prints the JSON schema; an optional "diff" must match the hash
      `hunks` printed). Each finding becomes an AI comment for the user to accept or dismiss
      (local only, never posted). Findings with bad anchors are dropped and counted; untouched
      findings of the reviewer's previous import are replaced.
  revuey ack <id>                mark it handled without replying (it is not delivered again)
  revuey inbox [--session <id>] [--json]
      messages not answered or acknowledged yet, then exit (also when Monitor is missing);
      printed ones say "(delivered, not handled)". Same review and routing as watch.
  revuey comments [--json] [--all] [--scope current|all|<branch>]
      all review comments of this branch (Markdown export)
  revuey watch [--json] [--since <event id>|all] [--all] [--scope ...]
      every comment event (created, edited, resolved, replied, sent...)
  revuey install-skill [--force] [--copy]
      install the Claude Code skill as ~/.claude/skills/revuey (a link to this checkout, or a copy)

Ids may be shortened to any unique part. Options: --state-dir <dir> (default $REVUEY_STATE_DIR,
else Neovim's data dir/revuey; live sessions' state dirs are searched too).]]

local VALUE_FLAGS = {
  ['--scope'] = 'scope',
  ['--since'] = 'since',
  ['--state-dir'] = 'state_dir',
  ['--session'] = 'session',
  ['--path'] = 'path',
  ['--line'] = 'line',
  ['--end'] = 'end_line',
  ['--side'] = 'side',
  ['--name'] = 'name',
}
local BOOL_FLAGS = {
  ['--json'] = 'json',
  ['--all'] = 'all',
  ['--messages'] = 'messages',
  ['--force'] = 'force',
  ['--copy'] = 'copy',
  ['--replay'] = 'replay',
  ['--file'] = 'file',
  ['--schema'] = 'schema',
  ['--prompt'] = 'prompt',
}

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
    elseif a:sub(1, 2) == '--' and not a:find('%s') then
      -- (an option never holds a space: "-- see above" is a text)
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

---The branch a detached HEAD is reviewed as: the newest live review session of the worktree,
---else the UI's stack detection (a branch at HEAD names its layer), else nil.
local function detached_branch(o, root)
  local live = sessions.list(sessions.bases(root, state_dir(o)), { worktree = root })
  if #live > 0 then
    return live[#live].branch
  end
  local trunk = git.default_branch(root)
  if not trunk then
    return nil
  end
  local ok, st = pcall(require('revuey.stack').detect, root, trunk, nil, { state_dir = state_dir(o) })
  return ok and st and st.layers[st.current] and st.layers[st.current].name or nil
end

---The repo and branch of the current directory.
local function here(o)
  local root = git.root(vim.fn.getcwd())
  if not root then
    die('not inside a git repository')
  end
  local branch = git.current_branch(root) or detached_branch(o or {}, root) or 'HEAD'
  return { root = root, real = real(root), branch = branch }
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
  local ctx = here(o)
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
  local ctx = here(o)
  local found = {}
  for _, e in ipairs(stores(state_dirs(o, ctx), ctx, o.scope or 'all', readonly)) do
    local exact = comments.get(e.store, id)
    if exact then
      return e, exact
    end
    for cid, c in pairs(e.store.comments) do
      if not c.deleted and cid:find(id, 1, true) then
        found[#found + 1] = { e = e, c = c }
      end
    end
  end
  if #found == 0 then
    die('no comment ' .. id .. ' in this repository')
  elseif #found > 1 then
    local lines = {}
    table.sort(found, function(a, b)
      return a.c.id < b.c.id
    end)
    for _, f in ipairs(found) do
      lines[#lines + 1] = ('  %s  %s: %s'):format(f.c.id, comments.location(f.c), comments.first_line(f.c.body))
    end
    die(('comment id %s is ambiguous; it matches:\n%s'):format(id, table.concat(lines, '\n')))
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
  if not c.sent_at then
    die(('comment %s (%s) was never sent to an agent: nothing to acknowledge'):format(c.id, comments.location(c)))
  end
  local acked = comments.ack(e.store, c.id)
  save(e.store)
  comments.append_event(events_path(e.path), comments.event('acked', acked, e.store.review))
  out(('acknowledged %s (%s)\n'):format(c.id, comments.location(c)))
end

function M.show(o, pos)
  local id = pos[1]
  if not id then
    die('show needs a comment id\n' .. M.USAGE, 2)
  end
  local e, c = find_comment(o, id, true)
  out(export.message(c, e.store.review, bin()))
end

---Messages (sent events) of the repo's reviews, oldest first: not acknowledged yet, or with
---`undelivered_only` not printed by any watch yet. Each event knows its comments file (`_file`)
---and whether it was delivered.
local function pending(dirs, ctx, undelivered_only)
  local list = {}
  for _, e in ipairs(stores(dirs, ctx, 'all', true)) do
    for _, c in ipairs(undelivered_only and comments.undelivered(e.store) or comments.unacked(e.store)) do
      local ev = comments.sent_event(c, e.store.review, { catchup = true })
      ev.delivered = comments.delivery(c) == 'delivered'
      ev._file = e.path
      list[#list + 1] = ev
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

local session_list_text

---The review session a watch or inbox works for: --session, else the worktree's only live one
---(nil when none runs). Several and no --session: exit 2 with the list.
local function pick_session(o, ctx, list)
  if o.session then
    for _, e in ipairs(list) do
      if e.id == o.session then
        return e
      end
    end
    die(('no live revuey session %s in %s%s'):format(o.session, ctx.root, #list > 0 and (':\n' .. session_list_text(list)) or ''), 2)
  elseif #list > 1 then
    die(('several revuey sessions in %s; pick one with --session <id>:\n%s'):format(ctx.root, session_list_text(list)), 2)
  end
  return list[1]
end

---Is a message for the agent of review `attached`? Its own messages, messages without a sender,
---and those of a review confirmed dead (not in `live`, the worktree's live session ids).
function M.routed(ev, attached, live)
  local sender = ev.session and tostring(ev.session)
  if not sender or (attached and sender == attached.id) then
    return true
  end
  return not live[sender]
end

local function id_set(list)
  local set = {}
  for _, e in ipairs(list) do
    set[e.id] = true
  end
  return set
end

function M.inbox(o)
  local ctx = here(o)
  local live = sessions.list(sessions.bases(ctx.root, state_dir(o)), { worktree = ctx.root })
  local attached = pick_session(o, ctx, live)
  local live_ids = id_set(live)
  local list = {}
  for _, ev in ipairs(pending(state_dirs(o, ctx), ctx)) do
    if M.routed(ev, attached, live_ids) then
      ev._file = nil
      list[#list + 1] = ev
    end
  end
  if o.json then
    out((#list > 0 and vim.json.encode(list) or '[]') .. '\n')
    return
  end
  if #list == 0 then
    out('no unacknowledged messages\n')
    return
  end
  for _, ev in ipairs(list) do
    out(comments.message_line(ev, bin()) .. (ev.delivered and '  (delivered, not handled)' or '') .. '\n')
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
  local t = 'branch'
  if sc.kind == 'full' then
    t = 'full stack'
  elseif sc.kind == 'layer' then
    t = 'stack layer'
  end
  -- the worktree's branch, when the review shows another layer (`gS` changes it)
  if e.checked_out and e.checked_out ~= e.branch then
    t = t .. ', checked out: ' .. e.checked_out
  end
  return t
end

function M.sessions(o)
  local ctx = here(o)
  local bases = o.all and sessions.all_bases(ctx.root, state_dir(o)) or sessions.bases(ctx.root, state_dir(o))
  local list = sessions.list(bases, {
    worktree = not o.all and ctx.root or nil,
    -- the fallback state dir is shared by every repo: --all means this repo's worktrees
    common_dir = o.all and sessions.common_dir(ctx.root) or nil,
  })
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

function session_list_text(list)
  local t = {}
  for _, e in ipairs(list) do
    t[#t + 1] = ('  %s  %s (%s)  started %s'):format(e.id, e.branch or '?', scope_text(e), ago(e.started_at))
  end
  return table.concat(t, '\n')
end

---Follow the event feeds of the state dirs (new files included), printing matching events, after
---catching up on unacknowledged messages. Registers a watcher (presence) while it runs.
function M.watch(o)
  local ctx = here(o)
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
  local list = sessions.list(bases, { worktree = ctx.root })
  local attached = pick_session(o, ctx, list)

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

  -- live sessions of the worktree (refreshed every second): a message sent by one of them goes
  -- to its own watchers only; one whose review is gone goes to whoever watches
  local live_ids = {}
  local function refresh_live(list_now)
    live_ids = id_set(list_now)
  end
  refresh_live(list)
  local function for_me(ev)
    return M.routed(ev, attached, live_ids)
  end

  ---Record that an agent was shown the message (agent mode): catch-up skips it from now on.
  local function stamp_delivered(file, ev)
    if not o.messages or not file then
      return
    end
    local store = comments.load(file)
    local c = comments.get(store, ev.comment_id)
    if c and c.sent_at == ev.sent_at and comments.delivery(c) == 'sent' then
      comments.mark_delivered(store, c.id)
      local ok, e = pcall(comments.save, store)
      if not ok then
        err('revuey: could not record the delivery of ' .. c.id .. ': ' .. tostring(e) .. '\n')
      end
    end
  end

  local function emit(ev, file)
    local is_msg = ev.kind == 'sent'
    if is_msg then
      if not M.matches(ev.review, ctx, 'all') or not for_me(ev) then
        return
      end
      local key = comments.message_key(ev)
      if seen[key] then
        return
      end
      seen[key] = true
      ev._file = nil
    else
      if o.messages or not M.matches(ev.review, ctx, o.scope) then
        return
      end
      if since and not (ev.id > since) then
        return
      end
      -- the agent's own replies and comments (and acks) are not news to it
      local own = (ev.kind == 'replied' and ev.reply and ev.reply.author and ev.reply.author.kind == 'agent')
        or (ev.kind == 'created' and ev.author and ev.author.kind == 'agent')
      if not o.all and (own or ev.kind == 'acked') then
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
    if is_msg then
      stamp_delivered(file, ev)
    end
  end

  ---The comments file next to an events file (or its rotated `.1`).
  local function comments_file(events_file)
    return (events_file:gsub('%.1$', ''):gsub('%.events%.jsonl$', '.comments.json'))
  end

  local function lines(t, data)
    local text = t.partial .. data
    local last = text:match('.*\n()') or 1
    t.partial = text:sub(last)
    for _, ev in ipairs(comments.decode_events(text:sub(1, last - 1))) do
      emit(ev, t.path and comments_file(t.path))
    end
  end

  local function open(path, from_end)
    local fd = vim.uv.fs_open(path, 'r', 438)
    if not fd then
      return nil
    end
    local st = vim.uv.fs_fstat(fd)
    local t = { fd = fd, ino = st.ino, offset = from_end and st.size or 0, partial = '', path = path }
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
      local t = { partial = '', path = path }
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
    for _, ev in ipairs(pending(dirs(), ctx, not o.replay)) do
      emit(ev, ev._file)
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
  local lost, waiting_noted -- the session that ended, and whether we said we are waiting
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
      local l = sessions.list(bases, { worktree = ctx.root })
      local function ids()
        local k = vim.tbl_keys(live_ids)
        table.sort(k)
        return table.concat(k, ',')
      end
      local before = ids()
      refresh_live(l)
      local live_changed = before ~= ids()
      -- the session ended (or crashed): wait for the review that replaces it (same worktree and
      -- scope), or, when none was attached yet, for the worktree's only one
      if attached and not live_ids[attached.id] then
        err(('revuey: session %s ended; waiting for a new review of %s in %s\n'):format(attached.id, attached.branch or '?', ctx.root))
        lost, waiting_noted = attached, false
        attached = nil
        heartbeat()
      end
      if live_changed then
        -- messages of a review that is gone are now anyone's
        catch_up()
      end
      if not attached then
        local pick
        if lost then
          local same = {}
          for _, e in ipairs(l) do
            if e.scope_key == lost.scope_key then
              same[#same + 1] = e
            end
          end
          if #same == 1 then
            pick = same[1]
          elseif #l > 0 and not waiting_noted then
            waiting_noted = true
            err(('revuey: still waiting: %d review(s) run in %s, %s; restart with --session <id> to watch one:\n%s\n'):format(
              #l,
              ctx.root,
              #same == 0 and ('none of ' .. (lost.branch or '?') .. ' (the scope of session ' .. lost.id .. ')') or 'several of that scope',
              session_list_text(l)
            ))
          end
        elseif #l == 1 then
          pick = l[1]
        elseif #l > 1 and not several_noted then
          several_noted = true
          err(('revuey: several revuey sessions in %s; restart with --session <id>:\n%s\n'):format(ctx.root, session_list_text(l)))
        end
        if pick then
          attached, lost = pick, nil
          heartbeat()
          err(('revuey: attached to %s\n'):format(describe()))
          catch_up()
        end
      else
        -- follow scope switches (the feed of another scope may live in another state dir)
        for _, e in ipairs(l) do
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

---Arguments of `comment`, checked: {path, side, start_line?, end_line?, text} (text may be `-`),
---or nil and a message.
function M.comment_args(o, pos)
  local usage = 'usage: revuey comment --path <path> (--line N [--end M] [--side new|old] | --file) <text|->'
  if not o.path or o.path == '' then
    return nil, 'comment needs --path <repo-relative path>\n' .. usage
  end
  if o.file and (o.line or o.end_line or o.side) then
    return nil, '--file comments on the whole file: leave out --line, --end and --side\n' .. usage
  end
  if not o.file and not o.line then
    return nil, 'comment needs --line N (lines of the diff) or --file (the whole file)\n' .. usage
  end
  if #pos == 0 then
    return nil, 'comment needs a text (or - to read it from stdin)\n' .. usage
  elseif #pos > 1 then
    return nil, 'comment takes one text, after the options: quote it (or use - and stdin)\n' .. usage
  end
  local a = { path = o.path, text = pos[1] }
  if o.file then
    return a
  end
  local function int(v, name)
    local n = tostring(v):match('^%s*(%d+)%s*$')
    n = n and tonumber(n)
    if not n or n < 1 then
      return nil, ('%s needs a line number (1 or more), not %s'):format(name, tostring(v))
    end
    return n
  end
  local err
  a.start_line, err = int(o.line, '--line')
  if not a.start_line then
    return nil, err
  end
  a.end_line = a.start_line
  if o.end_line then
    a.end_line, err = int(o.end_line, '--end')
    if not a.end_line then
      return nil, err
    end
    if a.end_line < a.start_line then
      return nil, ('--end %d is before --line %d'):format(a.end_line, a.start_line)
    end
  end
  if a.end_line - a.start_line + 1 > comments.MAX_RANGE then
    return nil, ('%d lines is too large a range (at most %d); comment on fewer lines, or on the whole file with --file'):format(
      a.end_line - a.start_line + 1,
      comments.MAX_RANGE
    )
  end
  a.side = o.side or 'new'
  if a.side ~= 'new' and a.side ~= 'old' then
    return nil, ('--side is new (the code after the change) or old (deleted lines), not %s'):format(a.side)
  end
  return a
end

---A path as given on the command line, made relative to the repo root (`./x`, absolute paths
---inside the worktree, a path relative to a subdirectory of it).
function M.repo_path(root, cwd, p)
  local abs = p:sub(1, 1) == '/' and p or vim.fs.joinpath(cwd, p)
  abs = vim.fs.normalize(abs)
  local roots = { root, real(root) }
  local rdir = real(vim.fs.dirname(abs))
  local cands = { abs }
  if rdir then
    cands[#cands + 1] = rdir .. '/' .. vim.fs.basename(abs)
  end
  for _, x in ipairs(cands) do
    for _, r in ipairs(roots) do
      r = r:gsub('/$', '') .. '/'
      if x:sub(1, #r) == r then
        return x:sub(#r + 1)
      end
    end
  end
  return (p:gsub('^%./', ''))
end

---Load the review a new comment goes into, headlessly: the attached session's own review when
---it recorded how (`load` in its registry entry), else what `revuey` would open here: the stack
---layer of HEAD (a detached HEAD too), or the plain branch review against the default branch.
---@return revuey.Review review, table info, string comments_path, string events_path
local function comment_review(o, ctx, attached)
  local config = require('revuey.config')
  local review_mod = require('revuey.review')
  local spec = attached and type(attached.load) == 'table' and attached.load or nil
  local dir = (attached and attached.state_dir) or state_dir(o)
  if o.state_dir and o.state_dir ~= '' then
    dir = o.state_dir
  end
  local r, lerr
  if spec then
    config.options.context_lines = tonumber(spec.context_lines) or config.options.context_lines
    config.options.max_file_bytes = tonumber(spec.max_file_bytes) or config.options.max_file_bytes
    r, lerr = review_mod.load({
      cwd = ctx.root,
      base = spec.base,
      from = spec.from,
      target = type(spec.target) == 'table' and spec.target or nil,
      mode = spec.mode,
      state_dir = dir,
    })
  else
    -- no live review (or one too old to say how it loaded): open what `revuey` opens here, with
    -- the settings the last review of this worktree recorded (the CLI runs with --clean, so it
    -- cannot read the user's default_branch, uncommitted, state_dir or context_lines)
    local last = sessions.read_last(sessions.bases(ctx.root, state_dir(o)), ctx.root) or {}
    if not (o.state_dir and o.state_dir ~= '') and not attached and type(last.state_dir) == 'string' and last.state_dir ~= '' then
      dir = last.state_dir
    end
    config.options.context_lines = tonumber(last.context_lines) or config.options.context_lines
    config.options.max_file_bytes = tonumber(last.max_file_bytes) or config.options.max_file_bytes
    local trunk = (type(last.trunk) == 'string' and last.trunk ~= '' and git.rev_parse(last.trunk, ctx.root) and last.trunk)
      or git.default_branch(ctx.root)
    if not trunk then
      die('could not detect the default branch (origin/HEAD, main, master or develop); open the review in revuey first, then comment')
    end
    local stack_mod = require('revuey.stack')
    local stack, from, scope
    if last.stack ~= false then
      local ok, st, _, f = pcall(stack_mod.detect, ctx.root, trunk, nil, { state_dir = dir })
      if ok then
        stack, from = st, f
      end
      scope = stack and (last.scope == 'full' and { kind = 'full' } or { kind = 'layer', index = stack.current }) or nil
    end
    r, lerr = review_mod.load({
      cwd = ctx.root,
      base = not stack and trunk or nil,
      from = from,
      target = stack and stack_mod.target(stack, scope) or nil,
      mode = (attached and attached.mode) or last.mode or nil,
      state_dir = dir,
    })
    if r then
      r.stack, r.scope = stack, scope
    end
  end
  if not r then
    die('cannot load the review: ' .. tostring(lerr))
  end
  local info = comments.review_info(r)
  if spec and type(attached.review) == 'table' then
    info.scope, info.layers = attached.review.scope or info.scope, attached.review.layers
  end
  local cpath = comments.path_for(r.state._path)
  local epath = comments.events_path_for(r.state._path)
  if spec and attached.comments then
    -- the file the running review watches
    cpath, epath = attached.comments, attached.events or events_path(attached.comments)
  end
  return r, info, cpath, epath
end

---"feat vs main, working tree, session 123" (or that no review is running).
local function where_text(info, attached)
  return ('%s vs %s, %s%s'):format(
    sessions.scope_label(info),
    info.base or '?',
    info.mode == 'committed' and 'committed' or 'working tree',
    attached and (', session ' .. attached.id) or ' (no review running: it shows when the review is opened)'
  )
end

function M.comment(o, pos)
  local a, aerr = M.comment_args(o, pos)
  if not a then
    die(aerr, 2)
  end
  local text = a.text
  if text == '-' then
    text = io.stdin:read('*a') or ''
  end
  text = vim.trim(text)
  if text == '' then
    die('empty comment')
  end
  local ctx = here(o)
  local attached = pick_session(o, ctx, live_sessions(o, ctx))
  a.path = M.repo_path(ctx.root, vim.fn.getcwd(), a.path)
  local r, info, cpath, epath = comment_review(o, ctx, attached)
  local review_mod = require('revuey.review')
  local U = review_mod.units(r)
  local cache = {}
  local pctx = comments.context(r.files, U, function(path, side)
    local fi = U.by_path[path]
    return fi and review_mod.side_text(r, r.files[fi], side, cache) or nil
  end)
  local anchor, err = comments.anchor_for_lines(r.files, U, a, pctx.get_line)
  if not anchor then
    die(err)
  end
  local c = comments.new(anchor, text, { author = agent_author() })
  local store = comments.load(cpath)
  comments.put(store, c)
  local ok, serr = pcall(comments.save, store, info)
  if not ok then
    die(tostring(serr))
  end
  comments.append_event(epath, comments.event('created', comments.get(store, c.id) or c, info))
  out(('%s\ncommented on %s (%s) in %s\n'):format(c.id, comments.location(c), c.file_level and 'file' or anchor.side, where_text(info, attached)))
end

---The hunks of the review `comment` would use, with the AI review's ids (guide.hunks).
local function review_hunks(o)
  local ctx = here(o)
  local attached = pick_session(o, ctx, live_sessions(o, ctx))
  local r, info, cpath, epath = comment_review(o, ctx, attached)
  return r, require('revuey.review').units(r).hunks, info, cpath, epath, attached
end

function M.hunks(o)
  local r, hunks, info = review_hunks(o)
  local diff = require('revuey.guide').anchors_hash(hunks)
  if o.json then
    local list = {}
    for _, h in ipairs(hunks) do
      list[#list + 1] = {
        id = h.id,
        path = h.path,
        old_path = h.old_path,
        status = h.status,
        header = h.header,
        lines = h.hunk_idx and h.text or {},
      }
    end
    out(vim.json.encode({ diff = diff, review = info, hunks = list }) .. '\n')
    return
  end
  local prompt = require('revuey.ai_review_prompt')
  local pctx = require('revuey.guide_view').prompt_context(r)
  local text, perr
  if o.prompt then
    text, perr = prompt.build(pctx, hunks, { budget = math.huge })
  else
    text, perr = prompt.user_message(pctx, hunks, { budget = math.huge })
  end
  if not text then
    die(perr)
  end
  out(('# Hunks of %s vs %s (%s): %d\n'):format(info.branch or '?', info.base or '?', info.mode == 'committed' and 'committed' or 'working tree', #hunks))
  out(('Diff: %s (give it as "diff" in the review, so import-review can tell when the code changed)\n\n'):format(diff))
  out(text)
  if o.prompt then
    out(('\n---\nWrite the review as one JSON document (schema: `%s import-review --schema`) with "diff": "%s", and import it with `%s import-review <file>`.\n'):format(bin(), diff, bin()))
  end
end

function M.import_review(o, pos)
  local prompt = require('revuey.ai_review_prompt')
  if o.schema then
    out(prompt.schema_json() .. '\n')
    return
  end
  local usage = 'usage: revuey import-review [--name <reviewer>] [--session <id>] <file|->  (--schema prints the schema)'
  if #pos ~= 1 then
    die((#pos == 0 and 'import-review needs a file (or - for stdin)\n' or 'import-review takes one file\n') .. usage, 2)
  end
  local text
  if pos[1] == '-' then
    text = io.stdin:read('*a') or ''
  else
    local fd, ferr = io.open(pos[1], 'r')
    if not fd then
      die('cannot read ' .. pos[1] .. ': ' .. tostring(ferr))
    end
    text = fd:read('*a') or ''
    fd:close()
  end
  if vim.trim(text) == '' then
    die('empty review')
  end
  local ai_review = require('revuey.ai_review')
  local r, hunks, info, cpath, epath, attached = review_hunks(o)
  local name = o.name or vim.env.REVUEY_AGENT_NAME
  local ok, rec, ierr = pcall(ai_review.import, text, {
    review = r,
    hunks = hunks,
    store = comments.load(cpath),
    events = epath,
    info = info,
    author = { kind = 'ai', name = (name and name ~= '') and name or nil },
    record_path = ai_review.record_path(cpath),
    generator = { provider = 'import', source = pos[1] == '-' and 'stdin' or pos[1], head = r.head, merge_base = r.merge_base, mode = r.mode },
  })
  if not ok then
    die(tostring(rec))
  elseif not rec then
    die(ierr)
  end
  out(('imported %d finding%s (verdict: %s) into %s\n'):format(
    rec.imported,
    rec.imported == 1 and '' or 's',
    ai_review.VERDICT_LABEL[rec.verdict],
    where_text(info, attached)
  ))
  local dropped = ai_review.dropped_text(rec.warnings)
  if dropped then
    out(dropped .. '\n')
  end
  if rec.skipped > 0 then
    out(('%d skipped: the user already triaged them\n'):format(rec.skipped))
  end
  if rec.replaced > 0 then
    out(('%d untriaged finding%s of the previous review replaced\n'):format(rec.replaced, rec.replaced == 1 and '' or 's'))
  end
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
  -- a link (or a copy's .revuey-bin) into a checkout that will be removed dangles: say so
  local real_src = real(src)
  for _, p in ipairs({ src, real_src }) do
    if p:find('/.claude/worktrees/', 1, true) or p:match('^/tmp/') or p:match('^/private/tmp/') or p:match('^/var/folders/') then
      err(('revuey: warning: %s looks temporary (a worktree or temp dir); the installed skill stops working when it is removed. Install from your main checkout instead.\n'):format(src))
      break
    end
  end
  local st = vim.uv.fs_lstat(dest)
  if st then
    -- the same checkout, whatever path leads to it, is the same install
    local same = st.type == 'link' and real(dest) == real_src
    if same and not o.copy then
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
    if st.type == 'link' then
      os.remove(dest) -- only a link: nothing of the user's is lost
    else
      -- the user's own skill directory (or file) is kept aside, never deleted, and outside
      -- skills/ (Claude Code would load a copy there as a second "revuey" skill)
      local backups = vim.fs.joinpath(home, '.claude', 'revuey-skill-backups')
      local stamp = os.date('%Y%m%d-%H%M%S')
      local slot = vim.fs.joinpath(backups, stamp)
      local n = 1
      while vim.uv.fs_lstat(slot) do
        n = n + 1
        slot = vim.fs.joinpath(backups, stamp .. '-' .. n)
      end
      vim.fn.mkdir(slot, 'p')
      local bak = vim.fs.joinpath(slot, 'revuey')
      local ok, e = os.rename(dest, bak)
      if not ok then
        die('cannot move ' .. dest .. ' aside: ' .. tostring(e))
      end
      err(('revuey: moved the existing %s to %s\n'):format(dest, bak))
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
  comment = M.comment,
  watch = M.watch,
  sessions = M.sessions,
  show = M.show,
  ack = M.ack,
  inbox = M.inbox,
  hunks = M.hunks,
  ['import-review'] = M.import_review,
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
