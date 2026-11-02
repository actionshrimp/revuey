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
--       --messages prints only messages sent to the agent, as one actionable line, and switches
--       of the worktree to another stack layer (`revuey switched ...`). Registers a
--       watcher with a heartbeat (presence in the review). Exits cleanly on SIGTERM (via
--       bin/revuey).
--   show <id>          one message in Markdown: location, review, code, comment, thread
--   reply <id> <text|->
--       add an agent reply to a comment's thread (`-` reads stdin); answers a sent message
--   comment --path <path> (--line N [--end M] [--side new|old] | --file) [--session <id>] <text|->
--       leave a new comment (author agent) on lines of the review's diff or on a whole changed
--       file, in the review the session (or, with none running, the CLI's scope) shows
--   hunks [--json] [--prompt [--request <id>] | --stat | --path <p>...] [--session <id>]
--       the review's hunks with their ids and numbered lines (what an AI review sees), and the
--       diff hash; --prompt: the whole prompt revuey's own AI review sends (--request: taking
--       review request <id>, adapted for the connected agent, with its skill); --stat: the changed
--       files with +/- counts and hunk ids; --path (repeatable): those files' hunks only. Right
--       after a `switched` event (`comment` and `import-review` too) it waits for the running
--       review to show the new layer (caught_up)
--   import-review [--request <id>] [--name <n>] [--session <id>] <file|->   |   --schema
--       import an AI review document (ai_review_prompt.SCHEMA): its findings become AI comments
--       to triage in the review, its summary and verdict the review's record; --request marks
--       the request done
--   guide [--json] [--session <id>]   |   guide --prompt [--request <id>]
--       the guide the review shows (title, summary, sections with their hunk ids, prose and
--       line notes, whether it is stale); --prompt: the instructions, diff and schema for the
--       connected agent to write one (taking request <id>: requests.lua)
--   import-guide [--request <id>] [--name <n>] [--session <id>] <file|->   |   --schema
--       validate and save a guide the agent wrote (as revuey's own runs are), marking the
--       request done; the running review shows it
--   ack <id>           mark a sent message handled without replying (no re-delivery)
--   inbox [--json]     sent messages not acknowledged yet and open requests, then exit
--   comments [--json] [--all] [--scope current|all|<branch>]
--       the comments of the current repo and branch (Markdown, like :RevueyCommentsExport)
--   install-skill [--force] [--copy]
--       link (or copy) the Claude Code skill into ~/.claude/skills/revuey
--   pr-target <number|url>, pr-path   (used by `bin/revuey pr`)
--       the `wt switch` target for a PR (`pr:<N>`; a URL must name this clone's GitHub repo),
--       and the worktree path from `wt switch --format json` on stdin
--
-- Common: --state-dir <dir> (default $REVUEY_STATE_DIR, else stdpath('data')/revuey; the state
-- dirs of live sessions are searched too).
-- Scope: `current` (default) = review scopes of the checked-out branch (its plain review, its
-- stack layer, and full-stack reviews that include it); `all` = every review of the repo;
-- a branch name = review scopes of that branch. Messages (sent events) match by repo only.
local modname = ...
local plugin = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')

if modname ~= 'revuey.cli' then
  -- run as a script: os.exit skips Neovim's own exit, which removes its server socket and temp
  -- dir ($XDG_RUNTIME_DIR or $TMPDIR/nvim.<user>/...), so remove them first, or every command
  -- leaves both behind
  local os_exit = os.exit
  os.exit = function(...)
    pcall(vim.fn.serverstop, vim.v.servername)
    pcall(vim.fn.delete, vim.fn.fnamemodify(vim.fn.tempname(), ':h'), 'rf')
    return os_exit(...)
  end
end
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
       revuey pr <number|url>     set the PR's worktree up with worktrunk (wt switch pr:<N>,
                                  your hooks), then open the review UI there

For coding agents (no UI; run inside the reviewed worktree):
  revuey sessions [--json] [--all]
      live reviews of this worktree (--all: every worktree of the repo) and whether an agent
      is connected to each
  revuey watch --messages [--session <id>] [--name <your name>] [--json] [--replay]
      attach to the review and print each message the user sends you, one line each:
        revuey message <id> <path>:<lines> (<side>) [<branch>]: <first line>  (revuey show <id> ...)
      Messages no watch has printed yet come first (catch-up), then new ones as they are sent.
      A printed message is not printed again by the next watch (--replay: print every message
      not yet answered or acknowledged). Messages of another running review (even a suspended
      one) are left to it; a review that ended is replaced by the next one of its scope.
      When the user asks you to write the guide of the review (instead of a fresh claude run):
        revuey request <id> guide [<branch>]: the user asked you to write the guide ... (revuey guide --prompt --request <id>)
      When the user asks you to review the changes into revuey (instead of a fresh claude run):
        revuey request <id> review [<branch>] (skill: <name>): the user asked you to review this into revuey (revuey hunks --prompt --request <id>)
      and when they withdraw either: revuey request <id> cancelled [<branch>]: ...
      --name <your name> is shown in the review ("Ask <name> (connected)").
      When the user checks out another stack layer in the review, a line says so:
        revuey switched <from> -> <to> (layer <i> of <n>, PR #<N> <url>): ...
      (live only: a watch started later does not print earlier switches).
      Lines are flushed one by one (fit for Claude Code's Monitor tool); SIGTERM exits 0.
      Without --messages every comment event is printed; --json prints full events.
      Several reviews in this worktree: pick one with --session <id> (see `revuey sessions`).
  revuey show <id>               the message in Markdown: file, lines, code, comment, thread
  revuey reply <id> <text|->     answer in the comment's thread (- reads stdin); marks it answered
  revuey comment --path <path> --line N [--end M] [--side new|old] [--tag <tag>]... [--session <id>] <text|->
  revuey comment --path <path> --file [--tag <tag>]... [--session <id>] <text|->
      leave a new comment in the review (local only, never posted anywhere): on lines of the
      diff (new: the code after the change, the default; old: deleted lines), which must be
      inside a hunk on that side, or on a whole changed file (--file). Prints the comment id
      and where it went. Same review as watch: the only live one, else --session <id>; with
      none running, the review `revuey` would open here.
      --tag <tag> (repeatable) tags it on creation.
  revuey findings [--run <id>] [--tag <tag>]... [--status untriaged|accepted|dismissed|resolved]
                  [--json] [--session <id>]
      the AI review findings and agents' comments in the review, by run (newest first): each run's
      id, who ran it (with which skill), verdict, counts, and each finding's id, status,
      severity, location, title and tags. Same review as comment.
  revuey tag <comment-id> <tag>... [--remove] [--session <id>]
      add tags to a finding or comment (--remove: take them off), to group or label them; tags
      are lower case letters, digits, . _ - (a finding is tagged by its skill or run already)
  revuey hunks [--json] [--prompt | --stat | --path <path>...] [--session <id>]
      the review's hunks, each under its id (`@@ h7 path @@`) with its lines numbered within
      the hunk (`3|+code`), and the diff hash; --prompt prints the whole prompt revuey's own
      AI review uses (instructions, then the diff); --stat only the changed files (+/- and
      hunk ids); --path (repeatable) only those files' hunks, with the whole review's ids and
      hash. Same review as comment. When the user just checked out another layer in revuey
      (a `revuey switched` line under 10 s old), hunks, comment and import-review first wait
      for the review to show it; a branch checked out outside revuey is not waited for.
  revuey hunks --prompt --request <id> [--session <id>]
      take the user's review request: the instructions (adapted for you, with the text of the
      skill the request names), the diff and its hash; the review shows that you started
  revuey import-review [--request <id>] [--name <reviewer>] [--tag <tag>]... [--session <id>] <file|->
      import a review (JSON: summary, verdict, findings anchored to a hunk id and line numbers
      of that hunk; `--schema` prints the JSON schema; an optional "diff" must match the hash
      `hunks` printed, and is required with --request). Each finding becomes an AI comment for
      the user to accept or dismiss (local only, never posted). Findings with bad anchors are
      dropped and counted; untouched findings of the reviewer's previous import are replaced.
      --request marks the request done and the running review shows the findings. Each import
      is a run (its id is printed); --tag (repeatable) tags every finding of it.
  revuey guide [--json] [--session <id>]
      the guide the review shows now, in Markdown: title, summary, each section's prose, hunk ids
      (as `hunks` prints them), hunk and line notes, who generated it and whether the diff changed
      since (stale); "no guide for this review" when there is none. Same review as comment.
  revuey guide --prompt [--request <id>] [--session <id>]
      the instructions, the diff (hunk ids, numbered lines) and the Diff: hash to write the guide
      yourself; --request takes the user's request (they see that you started)
  revuey import-guide [--request <id>] [--name <your name>] [--session <id>] <file|->
      import a guide you wrote (JSON; `--schema` prints the schema; "diff" must match the hash
      `guide --prompt` printed). Validated like revuey's own guides: every hunk id exactly once,
      line notes on numbered lines; a problem is reported and nothing is saved, so fix it and
      import again. The request is marked done and the running review shows the guide.
  revuey ack <id>                mark it handled without replying (it is not delivered again)
  revuey inbox [--session <id>] [--json]
      messages not answered or acknowledged yet, and open requests, then exit (also when Monitor
      is missing); printed ones say "(delivered, not handled)". Same review and routing as watch.
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
  ['--request'] = 'request',
  ['--tag'] = 'tag',
  ['--run'] = 'run',
  ['--status'] = 'status',
}
-- value flags that may be repeated: every value is kept, in order (o.<name>s)
local LIST_FLAGS = { ['--path'] = 'paths', ['--tag'] = 'tags' }
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
  ['--stat'] = 'stat',
  ['--remove'] = 'remove',
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
      if LIST_FLAGS[a] then
        o[LIST_FLAGS[a]] = o[LIST_FLAGS[a]] or {}
        table.insert(o[LIST_FLAGS[a]], args[i + 1])
      end
      i = i + 1
    elseif a:match('^%-%-[%w-]+=') then
      local k, v = a:match('^(%-%-[%w-]+)=(.*)$')
      if not VALUE_FLAGS[k] then
        die('unknown option ' .. k .. '\n' .. M.USAGE, 2)
      end
      o[VALUE_FLAGS[k]] = v
      if LIST_FLAGS[k] then
        o[LIST_FLAGS[k]] = o[LIST_FLAGS[k]] or {}
        table.insert(o[LIST_FLAGS[k]], v)
      end
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

---The `--tag` values, cleaned (tags.lua), or exit 2 on one that cleans to nothing.
local function option_tags(o)
  local tags = require('revuey.tags')
  local list, bad = tags.clean_list(o.tags or {})
  if #bad > 0 then
    die(('not a tag: %s (letters, digits, . _ -; at most %d characters)'):format(table.concat(bad, ' '), tags.MAX_LEN), 2)
  end
  return list
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

---Open requests of the repo's reviews in `dirs` as `request` events (oldest first), each
---knowing whether a watch printed it (`delivered`) or the agent started on it (`acked`).
local function open_requests(dirs, ctx, undelivered_only)
  local requests = require('revuey.requests')
  local list = {}
  for _, rec in ipairs(requests.list(dirs, { open = true, repo = { ctx.root, ctx.real } })) do
    if not (undelivered_only and rec.delivered_at) then
      local ev = requests.event(rec, rec.at)
      ev.delivered = rec.delivered_at ~= nil
      ev.acked = rec.status == 'acked'
      list[#list + 1] = ev
    end
  end
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
  -- then the open requests (a guide the user asked for), routed the same way
  for _, ev in ipairs(open_requests(state_dirs(o, ctx), ctx)) do
    if M.routed(ev, attached, live_ids) then
      list[#list + 1] = ev
    end
  end
  if o.json then
    out((#list > 0 and vim.json.encode(list) or '[]') .. '\n')
    return
  end
  if #list == 0 then
    out('no unacknowledged messages\n') -- (and no open requests)
    return
  end
  for _, ev in ipairs(list) do
    local note = ev.delivered and '  (delivered, not handled)' or ''
    if ev.kind == comments.REQUEST and ev.acked then
      note = '  (started, not imported yet)'
    end
    out(comments.message_line(ev, bin()) .. note .. '\n')
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
  local watch_started = comments.now_ms()
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
  local agent_name = o.name or vim.env.REVUEY_AGENT_NAME
  local me = {
    pid = vim.uv.os_getpid(),
    worktree = ctx.root,
    started_at = sessions.now_ms(),
    mode = o.messages and 'messages' or 'events',
    -- shown in the review ("Ask <name> (connected)") and recorded on what the agent makes
    name = require('revuey.requests').clean_name(agent_name),
  }
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

  ---Record that the agent was shown an open request (catch-up skips it from now on).
  local function stamp_request(ev)
    if not o.messages or not ev.path or ev.status == 'cancelled' then
      return
    end
    local requests = require('revuey.requests')
    local _, e = requests.update(ev.path, function(x)
      if x.delivered_at then
        return false
      end
      x.delivered_at = requests.now_ms()
    end)
    if e then
      err('revuey: could not record the delivery of request ' .. tostring(ev.request_id) .. ': ' .. tostring(e) .. '\n')
    end
  end

  local lost -- the session that ended (its last events are still its own)
  local function emit(ev, file)
    -- a switch of the worktree to another layer is for the agent like a message (printed once),
    -- but live only: one from before this watch started (--since, a rotated feed read again) is
    -- old news, and it goes to its own review's watchers only (never to the next review's)
    local is_switch = ev.kind == comments.SWITCHED
    if is_switch then
      local sid = ev.session and tostring(ev.session)
      local own = sid and ((attached and sid == attached.id) or (lost and sid == lost.id))
      if not own or (tonumber(ev.at) or 0) < watch_started then
        return
      end
    end
    -- a request (the user asked the agent for a guide) is delivered like a message, caught up
    -- while open; its cancellation is live only, and one done or cancelled meanwhile is not news
    local is_request = ev.kind == comments.REQUEST
    if is_request then
      if ev.status == 'cancelled' then
        if (tonumber(ev.at) or 0) < watch_started then
          return
        end
      else
        local rec = ev.path and require('revuey.requests').read(ev.path)
        if rec and not require('revuey.requests').is_open(rec) then
          return
        end
      end
    end
    local is_msg = ev.kind == 'sent' or is_switch or is_request
    if is_msg then
      if not M.matches(ev.review, ctx, 'all') or not (is_switch or for_me(ev)) then
        return
      end
      local key = ev.kind == 'sent' and comments.message_key(ev)
        or (is_request and require('revuey.requests').key(ev))
        or ('switched:' .. tostring(ev.id))
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
    if ev.kind == 'sent' then
      stamp_delivered(file, ev)
    elseif is_request then
      stamp_request(ev)
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
    for _, ev in ipairs(open_requests(dirs(), ctx, not o.replay)) do
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
  local waiting_noted -- whether we said we are waiting for a new review
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

---The newest `switched` event of session `e` in its feed (the file's last 256 KB), or nil.
local function last_switch(e)
  local fd = e.events and io.open(e.events, 'r')
  if not fd then
    return nil
  end
  local size = fd:seek('end') or 0
  fd:seek('set', math.max(0, size - 262144))
  local text = fd:read('*a') or ''
  fd:close()
  local last
  for _, ev in ipairs(comments.decode_events(text)) do
    if ev.kind == comments.SWITCHED and tostring(ev.session) == e.id and (not last or (tonumber(ev.at) or 0) >= (tonumber(last.at) or 0)) then
      last = ev
    end
  end
  return last
end

---A registry entry without what a mere refresh changes.
local function entry_sig(e)
  local c = {}
  for k, v in pairs(e) do
    if k:sub(1, 1) ~= '_' and k ~= 'updated_at' then
      c[k] = v
    end
  end
  return vim.inspect(c)
end

---The attached session once its review follows a switch. The `switched` line is sent before the
---review has loaded the new layer, so for a moment its registry entry still names the old one,
---and `hunks`, `comment` and `import-review` would use the old layer's diff. Waits only when the
---session's newest `switched` event is to the branch checked out now, the entry has not changed
---since, and the event is under REVUEY_CATCH_UP_MS (10 s) old; stops when the entry changes in
---any way or goes (the review closed: nil). A switch made outside revuey sends no event, so it
---never waits for one.
local function caught_up(o, ctx, attached)
  local want = ctx.branch
  if not attached or want == attached.checked_out then
    return attached
  end
  local sw = last_switch(attached)
  local at = sw and tonumber(sw.at) or 0
  local deadline = at + (tonumber(os.getenv('REVUEY_CATCH_UP_MS')) or 10000)
  if not (sw and sw.to == want and at >= (tonumber(attached.changed_at) or 0) and sessions.now_ms() < deadline) then
    return attached
  end
  err(('revuey: waiting for the review to show %s (it was just checked out)\n'):format(want))
  local sig = entry_sig(attached)
  while sessions.now_ms() < deadline do
    vim.wait(100)
    local now
    for _, e in ipairs(live_sessions(o, ctx)) do
      if e.id == attached.id then
        now = e
      end
    end
    if not now then
      err('revuey: the review closed; using what revuey opens here\n')
      return nil
    elseif entry_sig(now) ~= sig then
      return now
    end
  end
  err(('revuey: the review still shows %s, not %s; using what it shows\n'):format(tostring(attached.checked_out or attached.branch), want))
  return attached
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
    if type(spec.panel_folders) == 'boolean' then
      config.options.panel_folders = spec.panel_folders
    end
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
    if type(last.panel_folders) == 'boolean' then
      config.options.panel_folders = last.panel_folders
    end
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
  local attached = caught_up(o, ctx, pick_session(o, ctx, live_sessions(o, ctx)))
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
  local tag_list = option_tags(o)
  if #tag_list > 0 then
    local tagged, terr = require('revuey.tags').apply(c, tag_list, true, c.created_at)
    if not tagged then
      die(terr, 2)
    end
    c = tagged
  end
  local store = comments.load(cpath)
  comments.put(store, c)
  local ok, serr = pcall(comments.save, store, info)
  if not ok then
    die(tostring(serr))
  end
  comments.append_event(epath, comments.event('created', comments.get(store, c.id) or c, info))
  out(('%s\ncommented on %s (%s) in %s\n'):format(c.id, comments.location(c), c.file_level and 'file' or anchor.side, where_text(info, attached)))
  if #tag_list > 0 then
    out('tagged ' .. require('revuey.tags').text(tag_list) .. '\n')
  end
end

-- ---------------------------------------------------------------------------
-- Tags and findings: the AI findings and agent comments of the review, by run (ai_review.lua),
-- and their tags (tags.lua)
-- ---------------------------------------------------------------------------

---The comments file of the review `comment` would use: the attached session's (its current
---scope), else the review `revuey` would open here (loaded).
local function review_comments_path(o, ctx)
  local attached = pick_session(o, ctx, live_sessions(o, ctx))
  if attached and type(attached.comments) == 'string' and attached.comments ~= '' then
    return attached.comments, attached
  end
  local _, _, cpath = comment_review(o, ctx, attached)
  return cpath, attached
end

function M.tag(o, pos)
  local usage = 'usage: revuey tag <comment-id> <tag>... [--remove] [--session <id>]'
  local id = pos[1]
  if not id or #pos < 2 then
    die('tag needs a comment id and at least one tag\n' .. usage, 2)
  end
  local tags = require('revuey.tags')
  local list, bad = tags.clean_list(vim.list_slice(pos, 2))
  if #bad > 0 then
    die(('not a tag: %s (letters, digits, . _ -; at most %d characters)'):format(table.concat(bad, ' '), tags.MAX_LEN), 2)
  end
  local e, c
  if o.session then
    local ctx = here(o)
    local cpath = review_comments_path(o, ctx)
    local store = comments.load(cpath)
    c = comments.get(store, id)
    if not c then
      local found = {}
      for cid, x in pairs(store.comments) do
        if not x.deleted and cid:find(id, 1, true) then
          found[#found + 1] = x
        end
      end
      if #found ~= 1 then
        die(#found == 0 and ('no comment %s in session %s\'s review'):format(id, o.session) or ('comment id %s is ambiguous'):format(id))
      end
      c = found[1]
    end
    e = { path = cpath, store = store }
  else
    e, c = find_comment(o, id)
  end
  local now = comments.now_ms()
  local updated, changed = tags.apply(c, list, not o.remove, now)
  if not updated then
    die(changed)
  end
  if changed then
    -- tags only: no bump of updated_at (comments.put_tags), so an accept or dismiss saved
    -- meanwhile by the UI still wins the comment, and the tag merges in per tag
    comments.put_tags(e.store, updated)
    save(e.store)
    local cur = comments.get(e.store, c.id) or updated
    comments.append_event(events_path(e.path), comments.event('tagged', cur, e.store.review, { tags = tags.of(cur) }))
    c = cur
  end
  local shown = tags.of(c)
  out(('%s %s: %s\n'):format(c.id, changed and 'tagged' or 'unchanged', #shown > 0 and tags.text(shown) or '(no tags)'))
end

---One finding for `findings --json`.
local function finding_json(c)
  local ai_review = require('revuey.ai_review')
  local a = c.anchor or {}
  return {
    id = c.id,
    status = ai_review.triage_status(c),
    severity = c.ai and c.ai.severity or nil,
    title = c.ai and c.ai.title or comments.first_line(c.body),
    path = a.path,
    side = not c.file_level and a.side or nil,
    start_line = a.start_line,
    end_line = a.end_line,
    file_level = c.file_level or false,
    tags = require('revuey.tags').of(c),
    author = c.author,
    body = c.body,
  }
end

function M.findings(o)
  local ai_review = require('revuey.ai_review')
  local tags = require('revuey.tags')
  if o.status and not vim.tbl_contains(ai_review.STATUSES, o.status) then
    die(('--status is one of %s, not %s'):format(table.concat(ai_review.STATUSES, ', '), o.status), 2)
  end
  local tag_list = option_tags(o)
  local ctx = here(o)
  local cpath = review_comments_path(o, ctx)
  local store = comments.load(cpath, { readonly = true })
  local live = {}
  for _, c in ipairs(comments.list(store, { include_resolved = true, include_drafts = true })) do
    if ai_review.origin(c) then
      live[#live + 1] = c
    end
  end
  local groups = ai_review.groups(ai_review.read_runs(ai_review.record_path(cpath)), live)
  if o.run then
    local hits = vim.tbl_filter(function(g)
      return g.id == o.run or g.id:find(o.run, 1, true) ~= nil
    end, groups)
    if #hits == 0 then
      die(('no run %s in this review (%d run%s)'):format(o.run, #groups, #groups == 1 and '' or 's'))
    elseif #hits > 1 then
      die(('run id %s is ambiguous: %s'):format(o.run, table.concat(vim.tbl_map(function(g)
        return g.id
      end, hits), ', ')))
    end
    groups = hits
  end
  local function keep(c)
    if o.status and ai_review.triage_status(c) ~= o.status then
      return false
    end
    for _, t in ipairs(tag_list) do
      if not tags.has(c, t) then
        return false
      end
    end
    return true
  end
  local result = {}
  for _, g in ipairs(groups) do
    local list = vim.tbl_filter(keep, g.findings)
    if #list > 0 or (not o.status and #tag_list == 0) then
      result[#result + 1] = { g = g, list = list }
    end
  end
  if o.json then
    local runs = {}
    for _, x in ipairs(result) do
      local g, rec, run = x.g, x.g.record or {}, x.g.run or {}
      runs[#runs + 1] = {
        id = g.id,
        kind = g.comments and 'comments' or 'review',
        who = g.comments and ((run.name or 'agent') .. ' (agent comments)') or ai_review.run_who(run),
        name = run.name, provider = run.provider, agent = run.agent, model = run.model, skill = run.skill, request = run.request,
        started_at = rec.started_at, finished_at = rec.finished_at,
        summary = rec.summary, verdict = rec.verdict,
        counts = g.counts,
        findings = vim.tbl_map(finding_json, x.list),
      }
    end
    out(vim.json.encode({ comments = cpath, runs = runs }) .. '\n')
    return
  end
  if #result == 0 then
    out(#groups == 0 and 'no AI review findings or agent comments in this review\n' or 'no finding matches\n')
    return
  end
  local lines = {}
  for i, x in ipairs(result) do
    local g, rec, run = x.g, x.g.record, x.g.run or {}
    if i > 1 then
      lines[#lines + 1] = ''
    end
    local who = g.comments and ((require('revuey.requests').clean_name(run.name) or 'agent') .. ' (agent comments)') or ai_review.run_who(run)
    local parts = { 'run ' .. g.id, who }
    if run.skill then
      parts[#parts + 1] = 'skill ' .. require('revuey.guide').one_line(run.skill)
    end
    if rec then
      parts[#parts + 1] = ai_review.VERDICT_LABEL[rec.verdict] or rec.verdict
      if rec.finished_at and rec.finished_at > 0 then
        parts[#parts + 1] = os.date('%Y-%m-%d %H:%M', math.floor(rec.finished_at / 1000))
      end
    end
    local n = g.counts
    parts[#parts + 1] = ('%d untriaged, %d accepted, %d dismissed'):format(n.untriaged, n.accepted, n.dismissed)
    lines[#lines + 1] = table.concat(parts, ' · ')
    if rec and rec.summary ~= '' then
      lines[#lines + 1] = '  ' .. comments.first_line(rec.summary)
    end
    for _, c in ipairs(x.list) do
      local tg = tags.text(tags.of(c))
      lines[#lines + 1] = ('  %s  %-9s %-8s %s  %s%s'):format(c.id, ai_review.triage_status(c), c.ai and c.ai.severity or 'comment',
        comments.location(c), require('revuey.guide').one_line(c.ai and c.ai.title or comments.first_line(c.body)), tg ~= '' and ('  ' .. tg) or '')
    end
  end
  out(table.concat(lines, '\n') .. '\n')
end

---The stack of a review loaded from a session's `load` record (which has the diff, not the stack
---object): detected again, for the prompt's scope wording and branch tags.
local function restore_stack(o, ctx, r, info, attached)
  if r.stack or info.scope == 'branch' then
    return
  end
  -- the state dir comment_review loaded the review with (its stack ignore list is the UI's)
  local dir = (attached and attached.state_dir) or state_dir(o)
  if o.state_dir and o.state_dir ~= '' then
    dir = o.state_dir
  end
  local last = sessions.read_last(sessions.bases(ctx.root, dir), ctx.root) or {}
  local trunk = (type(last.trunk) == 'string' and last.trunk ~= '' and git.rev_parse(last.trunk, ctx.root) and last.trunk)
    or git.default_branch(ctx.root)
  local ok, st = pcall(require('revuey.stack').detect, ctx.root, trunk, nil, { state_dir = dir })
  if not (ok and st) then
    return
  end
  if info.scope == 'full' then
    r.stack, r.scope = st, { kind = 'full' }
    return
  end
  for i, l in ipairs(st.layers) do
    if l.name == r.branch then
      r.stack, r.scope = st, { kind = 'layer', index = i }
      break
    end
  end
end

-- ---------------------------------------------------------------------------
-- Requests to the agent (requests.lua): taking one, checking it, finishing it
-- ---------------------------------------------------------------------------

---The request `id` of this repo (any unique part), or exit 1.
local function find_request(o, ctx, id)
  local requests = require('revuey.requests')
  local rec, ferr = requests.find(state_dirs(o, ctx), id, { repo = { ctx.root, ctx.real } })
  if not rec then
    die(ferr)
  end
  return rec
end

---A request that names another review than the one loaded: what it was for, or nil when it fits.
local function request_mismatch(req, r)
  local key = require('revuey.guide').key(r.state)
  local k = req.key or {}
  if k.repo == key.repo and k.branch == key.branch and k.base == key.base then
    return nil
  end
  return ('request %s was for %s (vs %s), but the review shows %s vs %s now'):format(req.id, req.label or k.branch or '?', k.base or '?', key.branch, key.base)
end

---The open request of `kind` for this review (key), newest first, or nil.
local function open_request(o, ctx, r, kind)
  local requests = require('revuey.requests')
  local key = require('revuey.guide').key(r.state)
  local list = requests.list(state_dirs(o, ctx), { open = true, repo = { ctx.root, ctx.real } })
  for i = #list, 1, -1 do
    local k = list[i].key or {}
    if list[i].kind == kind and k.repo == key.repo and k.branch == key.branch and k.base == key.base then
      return list[i]
    end
  end
end

---Who writes: `--name`, else the agent the request was made for (the name the review counts
---replaced findings with), else $REVUEY_AGENT_NAME.
local function writer_name(o, req)
  local requests = require('revuey.requests')
  return requests.clean_name(o.name) or (req and req.agent) or requests.clean_name(vim.env.REVUEY_AGENT_NAME) or 'agent'
end

---May `writer` import (again) into request `x`? An open request: yes. A done one: only its own
---writer, replacing the guide (or review) it imported (after fixing dropped notes, say); anyone
---else would silently replace another agent's work.
local function may_reimport(x, writer)
  return x.status ~= 'done' or (x.result ~= nil and x.result.agent == writer)
end

---The request of `kind` (guide, review) `--request` names, checked (exit 1 when it is of another
---kind or was cancelled, or done: with `reimport`, a done request is open to its own writer's
---import). Its review is the one to load when no --session is given and it still runs.
local function take_request(o, ctx, kind, what, reimport)
  local req = find_request(o, ctx, o.request)
  if req.kind ~= kind then
    die(('request %s asks for a %s, not a %s'):format(req.id, req.kind, kind))
  elseif req.status == 'cancelled' then
    die(('request %s was cancelled by the user: %s'):format(req.id, what))
  elseif req.status == 'refused' then
    die(('request %s was refused (%s): %s; the user was told to ask again'):format(req.id, tostring(req.reason or '?'), what))
  elseif req.status == 'done' and not (reimport and may_reimport(req, writer_name(o, req))) then
    die(('request %s is done already (the %s %s imported is shown): %s; ask the user before writing another%s'):format(
      req.id, kind, tostring(req.result and req.result.agent or 'an agent'), what,
      reimport and ' (its writer may import again with the same --request and --name to replace it)' or ''))
  end
  if not o.session and req.session then
    for _, e in ipairs(live_sessions(o, ctx)) do
      if e.id == tostring(req.session) then
        o.session = e.id
      end
    end
  end
  return req
end

---Record that the agent took request `req` (its prompt was printed): the review says so.
local function mark_acked(req)
  local requests = require('revuey.requests')
  if req and req.status == 'pending' then
    local _, uerr = requests.update(req._path, function(x)
      if x.status ~= 'pending' then
        return false
      end
      x.status, x.acked_at = 'acked', requests.now_ms()
    end)
    if uerr then
      err('revuey: could not record that you took request ' .. req.id .. ': ' .. tostring(uerr) .. '\n')
    end
  end
end

---Test hook: hold an import here (after its checks, before the request's lock) until the gate
---file exists.
local function test_gate()
  local gate = vim.env.REVUEY_TEST_IMPORT_GATE
  if gate and gate ~= '' then
    vim.fn.writefile({}, gate .. '.waiting')
    vim.wait(10000, function()
      return vim.uv.fs_stat(gate) ~= nil
    end, 20)
  end
end

---The hunks of the review `comment` would use, with the AI review's ids (guide.hunks) and, in
---the full-stack scope, the branch that introduced each one (as the UI tags them).
local function review_hunks(o)
  local ctx = here(o)
  local attached = caught_up(o, ctx, pick_session(o, ctx, live_sessions(o, ctx)))
  local r, info, cpath, epath = comment_review(o, ctx, attached)
  restore_stack(o, ctx, r, info, attached)
  local hunks = require('revuey.review').units(r).hunks
  local labels = require('revuey.attribution').load(r)
  if labels then
    for _, h in ipairs(hunks) do
      h.layers = labels[h.file_idx] and labels[h.file_idx][h.hunk_idx or 0] or nil
    end
  end
  return r, hunks, info, cpath, epath, attached
end

---The skill a review request names, read again and checked, or exit 1: its path must be a
---Markdown file where its origin says (`<skill dir>/<name>/SKILL.md` for a user or repo skill,
---what the user's own path resolves to for `path`), and its text the one hashed when the user
---asked. Returns {name, text, path, origin, in_repo, touched}.
local function request_skill(req, r, hunks)
  if not req or not req.skill then
    return nil
  end
  local ai_review = require('revuey.ai_review')
  local k = req.skill
  -- refused: the request says why (the review shows it and stops waiting), and the agent tells
  -- the user the same
  local function refuse(why, short)
    local requests = require('revuey.requests')
    local reason = short or why
    requests.update(req._path, function(x)
      if x.status ~= 'pending' and x.status ~= 'acked' then
        return false
      end
      x.status, x.refused_at, x.reason = 'refused', requests.now_ms(), reason
    end)
    die(('request %s asks you to follow the skill %s, but %s. Review nothing; tell the user: "%s could not take the request: %s; run :RevueyAIReview %s again"'):format(
      req.id, k.name, why, req.agent or 'the agent', reason, k.arg or k.name))
  end
  if k.bad then
    refuse('its record is not valid (' .. k.bad .. ')', 'the request\'s skill record is not valid')
  end
  local real = function(p)
    return vim.uv.fs_realpath(p) or p
  end
  -- what the user typed resolves the same way again: a path as that path (whatever origin it
  -- was classified as), a name by name
  local want = ai_review.find_skill(k.arg, r.root)
  local moved = ('the skill %s is no longer the file you picked'):format(k.name)
  if not want or real(want) ~= real(k.path) then
    refuse(('%s is not where %s is found now (%s)'):format(k.path, k.arg, tostring(want or 'none')), moved)
  end
  local origin, in_repo = ai_review.skill_origin(k.path, r.root)
  if origin ~= k.origin then
    refuse(('it was a %s skill when asked and is a %s one now'):format(k.origin, origin), moved)
  end
  local skill, serr = ai_review.read_skill(k.path)
  if not skill then
    refuse('it cannot be read (' .. tostring(serr) .. ')', ('the skill %s cannot be read'):format(k.name))
  end
  if skill.hash ~= k.hash then
    refuse('its text changed since the user asked (' .. k.path .. ')', 'the skill changed since you asked')
  end
  if not require('revuey.ai_review_prompt').agent_skill(vim.tbl_extend('force', skill, { origin = k.origin })) then
    refuse('its text contains the delimiter revuey puts around it', ('the skill %s cannot be passed safely'):format(k.name))
  end
  local paths = {}
  for _, h in ipairs(hunks) do
    paths[#paths + 1] = h.path
    if h.old_path then
      paths[#paths + 1] = h.old_path
    end
  end
  skill.origin, skill.in_repo = k.origin, in_repo or k.origin == 'repo'
  skill.touched = ai_review.skill_touched(k.path, r.root, paths)
  return skill
end

function M.hunks(o)
  if o.prompt and (o.stat or o.paths) then
    die('--prompt is the whole review; it takes neither --stat nor --path', 2)
  end
  if o.request and not o.prompt then
    die('--request goes with --prompt (`hunks --prompt --request <id>`)', 2)
  end
  local req = o.request and take_request(o, here(o), 'review', 'nothing to do') or nil
  local r, hunks, info = review_hunks(o)
  if req then
    local mm = request_mismatch(req, r)
    if mm then
      die(mm .. '; tell the user, and review nothing')
    end
  end
  local skill = request_skill(req, r, hunks)
  -- the hash of the whole diff, whatever is shown (import-review checks against it)
  local diff = require('revuey.guide').anchors_hash(hunks)
  local total = #hunks
  if o.paths then
    local want, found = {}, {}
    for _, p in ipairs(o.paths) do
      want[M.repo_path(r.root, vim.fn.getcwd(), p)] = p
    end
    local shown = {}
    for _, h in ipairs(hunks) do
      local key = want[h.path] and h.path or (h.old_path and want[h.old_path] and h.old_path)
      if key then
        found[key] = true
        shown[#shown + 1] = h
      end
    end
    for path, given in pairs(want) do
      if not found[path] then
        die(('%s is not a changed file in this review (`%s hunks --stat` lists them)'):format(given, bin()))
      end
    end
    hunks = shown
  end
  local mode = info.mode == 'committed' and 'committed' or 'working tree'
  local count = o.paths and ('%d of %d'):format(#hunks, total) or tostring(total)
  if o.stat then
    local files, by = {}, {}
    for _, h in ipairs(hunks) do
      local f = by[h.file_idx]
      if not f then
        f = { path = h.path, old_path = h.old_path, status = h.status, added = 0, removed = 0, hunks = {} }
        by[h.file_idx] = f
        files[#files + 1] = f
      end
      f.added, f.removed = f.added + (h.added or 0), f.removed + (h.removed or 0)
      f.hunks[#f.hunks + 1] = h.id
    end
    if o.json then
      out(vim.json.encode({ diff = diff, review = info, files = files }) .. '\n')
      return
    end
    out(('# Files of %s vs %s (%s): %d, hunks: %s\n'):format(sessions.scope_label(info), info.base or '?', mode, #files, count))
    out(('Diff: %s\n\n'):format(diff))
    for _, f in ipairs(files) do
      local name = (f.old_path and f.old_path ~= f.path) and (f.old_path .. ' -> ' .. f.path) or f.path
      local status = ({ A = ' [added]', D = ' [deleted]', R = ' [renamed]' })[f.status] or ''
      out(('%s%s (+%d -%d): %s\n'):format(name, status, f.added, f.removed, table.concat(f.hunks, ' ')))
    end
    return
  end
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
    -- for a request: the connected agent's methodology, and the skill the user asked for
    text, perr = prompt.build(pctx, hunks, { budget = math.huge, agent = req ~= nil, skill = skill })
  else
    text, perr = prompt.user_message(pctx, hunks, {
      budget = math.huge,
      -- a part of the diff: its ids and line numbers are the whole review's
      ids = o.paths and 'Only the hunks of the files asked for (--path); their ids and line numbers are those of the whole review.' or nil,
    })
  end
  if not text then
    die(perr)
  end
  mark_acked(req)
  out(('# Hunks of %s vs %s (%s): %s%s%s\n'):format(sessions.scope_label(info), info.base or '?', mode, count,
    req and (', request ' .. req.id) or '', skill and (', skill ' .. skill.name) or ''))
  out(('Diff: %s (give it as "diff" in the review, so import-review can tell when the code changed)\n\n'):format(diff))
  out(text)
  if req then
    local name = req.agent or 'agent'
    out(('\n---\nWrite the review as one JSON document (schema: `%s import-review --schema`) with "diff": "%s", and import it with `%s import-review --request %s --name %s -` (the JSON on stdin; keep that name: the review replaces the untouched findings of your earlier review under it). '
      .. 'Findings with bad anchors are dropped and reported: fix them and import again with the same --request and --name.\n'):format(
      bin(), diff, bin(), req.id, name:match('^[%w._-]+$') and name or vim.fn.shellescape(name)))
  elseif o.prompt then
    out(('\n---\nWrite the review as one JSON document (schema: `%s import-review --schema`) with "diff": "%s", and import it with `%s import-review <file>`.\n'):format(bin(), diff, bin()))
  end
end

function M.import_review(o, pos)
  local prompt = require('revuey.ai_review_prompt')
  if o.schema then
    out(prompt.schema_json() .. '\n')
    return
  end
  local usage = 'usage: revuey import-review [--request <id>] [--name <reviewer>] [--session <id>] <file|->  (--schema prints the schema)'
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
  local requests = require('revuey.requests')
  local guide = require('revuey.guide')
  local tag_list = option_tags(o)
  local req = o.request and take_request(o, here(o), 'review', 'nothing imported', true) or nil
  local r, hunks, info, cpath, epath, attached = review_hunks(o)
  local source = pos[1] == '-' and 'stdin' or pos[1]
  local name, generator
  if req then
    local mm = request_mismatch(req, r)
    if mm then
      die(mm .. '; nothing imported')
    end
    -- the diff hash is required for a request: findings for code that changed since would pass
    local doc = guide.repair_json(text)
    local diff = guide.anchors_hash(hunks)
    if type(doc) == 'table' and (type(doc.diff) ~= 'string' or doc.diff == '') then
      die(('the review has no "diff": give the Diff: hash `%s hunks --prompt` printed (%s now), so a review of code that changed meanwhile is refused; nothing imported'):format(bin(), diff))
    end
    name = writer_name(o, req)
    generator = {
      provider = 'agent', agent = name, request = req.id, skill = req.skill and req.skill.name or nil, source = source,
      head = r.head, merge_base = r.merge_base, mode = r.mode, prompt_level = 'full',
    }
  else
    name = o.name or vim.env.REVUEY_AGENT_NAME
    name = (name and name ~= '') and name or nil
    generator = { provider = 'import', source = source, head = r.head, merge_base = r.merge_base, mode = r.mode }
  end
  local function import()
    return pcall(ai_review.import, text, {
      review = r,
      hunks = hunks,
      store = comments.load(cpath),
      events = epath,
      info = info,
      author = { kind = 'ai', name = name },
      record_path = ai_review.record_path(cpath),
      generator = generator,
      tags = tag_list,
      started_at = req and tonumber(req.acked_at or req.at) or nil,
    })
  end
  local ok, rec, ierr
  if req then
    test_gate()
    -- the status again, under the request's lock, and the findings imported under it: a cancel
    -- (or another writer's import) that came in since the first check wins, nothing is written
    local _, uerr = requests.update(req._path, function(x)
      if x.status == 'cancelled' then
        return false, ('request %s was cancelled by the user meanwhile: nothing imported'):format(req.id)
      elseif not may_reimport(x, name) then
        return false, ('request %s was done meanwhile (by %s): nothing imported'):format(req.id, tostring(x.result and x.result.agent or '?'))
      end
      ok, rec, ierr = import()
      if not ok or not rec then
        return false, tostring(ok and ierr or rec)
      end
      x.status, x.done_at = 'done', requests.now_ms()
      x.result = { agent = name, verdict = rec.verdict, findings = rec.imported, review = rec.id }
    end)
    if uerr then
      die(uerr)
    end
  else
    ok, rec, ierr = import()
  end
  if not ok then
    die(tostring(rec))
  elseif not rec then
    die(ierr)
  end
  out(('imported %d finding%s (verdict: %s) into %s%s\n'):format(
    rec.imported,
    rec.imported == 1 and '' or 's',
    ai_review.VERDICT_LABEL[rec.verdict],
    where_text(info, attached),
    req and attached and '; the running review shows them within a few seconds' or ''
  ))
  local dropped = ai_review.dropped_text(rec.warnings)
  if dropped then
    out(dropped .. (req and (' (fix them and import again with the same --request ' .. req.id .. ' and --name ' .. name .. ')') or '') .. '\n')
  end
  if rec.skipped > 0 then
    out(('%d skipped: the user already triaged them\n'):format(rec.skipped))
  end
  if rec.replaced > 0 then
    out(('%d untriaged finding%s of the previous review replaced\n'):format(rec.replaced, rec.replaced == 1 and '' or 's'))
  end
  out(('run %s%s: list its findings with `%s findings --run %s`\n'):format(rec.id,
    #tag_list > 0 and (', tagged ' .. require('revuey.tags').text(tag_list)) or '', bin(), rec.id))
  if rec.record_error then
    err(('revuey: the findings were imported, but the review record (summary, verdict) was not saved: %s\n'):format(rec.record_error))
  end
end

-- ---------------------------------------------------------------------------
-- Guides: reading the review's guide, and writing one for a request (requests.lua)
-- ---------------------------------------------------------------------------

---Who made a guide (its generator), for people: "claude (connected)", a model, or "claude".
function M.generator_label(gen)
  gen = gen or {}
  if gen.provider == 'agent' then
    return (require('revuey.requests').clean_name(gen.agent) or 'agent') .. ' (connected)'
  end
  return gen.model or gen.provider or '?'
end

local function guide_prompt_out(o, req, r, hunks, info, attached)
  local requests = require('revuey.requests')
  local guide = require('revuey.guide')
  if req then
    local mm = request_mismatch(req, r)
    if mm then
      die(mm .. '; tell the user, and write nothing')
    end
  end
  local diff = guide.anchors_hash(hunks)
  local text, perr = require('revuey.guide_prompt').build(require('revuey.guide_view').prompt_context(r), hunks, { budget = math.huge, agent = true })
  if not text then
    die(perr)
  end
  mark_acked(req)
  local mode = info.mode == 'committed' and 'committed' or 'working tree'
  out(('# Guide prompt for %s vs %s (%s): %d hunks%s\n'):format(sessions.scope_label(info), info.base or '?', mode, #hunks, req and (', request ' .. req.id) or ''))
  out(('Diff: %s\n\n'):format(diff))
  out(text)
  local name = '--name <your name> '
  out(('\n---\nWrite the guide as one JSON document (schema: `%s import-guide --schema`) with "diff": "%s", and import it with `%s import-guide %s%s-` (the JSON on stdin). '
    .. 'It is validated like revuey\'s own guides: every hunk id exactly once (in a section or "unplaced"), line notes on lines this prompt numbered. '
    .. 'If it reports a problem, fix the document and import it again.\n'):format(
    bin(), diff, bin(), req and ('--request ' .. req.id .. ' ') or '', name))
  return attached
end

---`guide [--json]`: the guide the review shows now, in Markdown (or JSON); `--prompt [--request
---<id>]`: the prompt to write one (instructions for the connected agent, the diff, the schema).
function M.guide(o)
  local ctx = here(o)
  if o.request and not o.prompt then
    die('--request goes with --prompt (`guide --prompt --request <id>`)', 2)
  end
  local req = o.request and take_request(o, ctx, 'guide', 'nothing to do') or nil
  local r, hunks, info, _, _, attached = review_hunks(o)
  if o.prompt then
    return guide_prompt_out(o, req, r, hunks, info, attached)
  end
  local guide = require('revuey.guide')
  local diff = guide.anchors_hash(hunks)
  local rec = guide.load(guide.dir(vim.fs.dirname(r.state._path)), guide.key(r.state), diff)
  local mode = info.mode == 'committed' and 'committed' or 'working tree'
  local where = ('%s vs %s (%s)%s'):format(sessions.scope_label(info), info.base or '?', mode, attached and (', session ' .. attached.id) or ', no review running')
  req = open_request(o, ctx, r, 'guide')
  if not rec then
    if o.json then
      out(vim.json.encode({ diff = diff, review = info, guide = vim.NIL, request = req and req.id or nil }) .. '\n')
      return
    end
    out(('no guide for this review (%s)\n'):format(where))
    if req then
      out(('The user asked you to write one: request %s (`%s guide --prompt --request %s`).\n'):format(req.id, bin(), req.id))
    end
    return
  end
  local res = guide.resolve(rec, hunks)
  local gen = res.generator or {}
  local sections = {}
  for _, sec in ipairs(res.sections) do
    local items, notes = {}, {}
    for _, item in ipairs(sec.items) do
      items[#items + 1] = { id = item.hunk.id, path = item.hunk.path, note = item.note, edited = item.edited or nil }
      for _, n in ipairs(item.line_notes or {}) do
        notes[#notes + 1] = { hunk = item.hunk.id, line = n.line, end_line = n.end_line, side = n.side, text = n.text }
      end
    end
    sections[#sections + 1] = {
      title = sec.title,
      overview = sec.overview,
      kind = sec.kind,
      outdated = sec.outdated or nil,
      missing = sec.missing > 0 and sec.missing or nil,
      hunks = items,
      line_notes = notes,
    }
  end
  if o.json then
    out(vim.json.encode({
      diff = diff,
      review = info,
      stale = res.stale,
      title = res.title,
      summary = res.summary,
      generated_by = M.generator_label(gen),
      generator = gen,
      sections = sections,
      request = req and req.id or nil,
    }) .. '\n')
    return
  end
  local o_ = {}
  local function add(l)
    o_[#o_ + 1] = l
  end
  add('# Guide: ' .. res.title)
  add('')
  add(('Review: %s'):format(where))
  add(('Generated by %s%s'):format(M.generator_label(gen), gen.generated_at and (', ' .. os.date('%Y-%m-%d %H:%M', gen.generated_at)) or ''))
  if res.stale then
    local parts = {}
    if res.outdated > 0 then
      parts[#parts + 1] = res.outdated .. ' section(s) outdated'
    end
    if res.new > 0 then
      parts[#parts + 1] = res.new .. ' new hunk(s), in "Not in guide"'
    end
    if (res.edited or 0) > 0 then
      parts[#parts + 1] = res.edited .. ' hunk(s) edited'
    end
    if (res.notes_lost or 0) > 0 then
      parts[#parts + 1] = res.notes_lost .. ' line note(s) lost'
    end
    add(('Stale: the diff changed since this guide was generated (%s). The text may describe code that is gone.'):format(table.concat(parts, ', ')))
  else
    add('Up to date: generated for the diff the review shows.')
  end
  add(('Diff: %s (hunk ids as `%s hunks` prints them)'):format(diff, bin()))
  if req then
    add(('A newer guide was requested from you: request %s.'):format(req.id))
  end
  if res.summary ~= '' then
    add('')
    add(res.summary)
  end
  for si, sec in ipairs(sections) do
    add('')
    add(('## %d. %s%s'):format(si, sec.title, sec.outdated and ' (outdated: ' .. sec.missing .. ' hunk(s) changed or gone)' or ''))
    if sec.overview ~= '' then
      add('')
      add(sec.overview)
    end
    add('')
    local hs = {}
    for _, it in ipairs(sec.hunks) do
      hs[#hs + 1] = it.id .. ' ' .. it.path .. (it.edited and ' (edited since)' or '')
    end
    add('Hunks: ' .. (#hs > 0 and table.concat(hs, ', ') or 'none'))
    for _, it in ipairs(sec.hunks) do
      if it.note then
        add(('- %s: %s'):format(it.id, it.note))
      end
    end
    if #sec.line_notes > 0 then
      add('Line notes:')
      for _, n in ipairs(sec.line_notes) do
        local lines = n.end_line and n.end_line ~= n.line and (n.line .. '-' .. n.end_line) or tostring(n.line)
        add(('- %s:%s (%s): %s'):format(n.hunk, lines, n.side or 'new', n.text))
      end
    end
  end
  out(table.concat(o_, '\n') .. '\n')
end

---The schema of an imported guide: the guide's (guide_prompt.SCHEMA) with an optional `diff`.
local function import_guide_schema()
  local sc = vim.deepcopy(require('revuey.guide_prompt').SCHEMA)
  sc.properties.diff = { type = 'string', description = 'the Diff: hash `guide --prompt` printed' }
  return sc
end

---`import-guide [--request <id>] [--name <n>] [--session <id>] <file|->`: validate a guide written
---by the agent like revuey's own (guide.validate), save it where the review keeps its guides,
---and mark the request done; the running review shows it.
function M.import_guide(o, pos)
  if o.schema then
    out(vim.json.encode(import_guide_schema()) .. '\n')
    return
  end
  local usage = 'usage: revuey import-guide [--request <id>] [--name <n>] [--session <id>] <file|->  (--schema prints the schema)'
  if #pos ~= 1 then
    die((#pos == 0 and 'import-guide needs a file (or - for stdin)\n' or 'import-guide takes one file\n') .. usage, 2)
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
    die('empty guide')
  end
  local guide = require('revuey.guide')
  local requests = require('revuey.requests')
  local doc = guide.repair_json(text)
  if type(doc) ~= 'table' or type(doc.sections) ~= 'table' then
    die(('not a guide: expected one JSON object with "title", "summary" and "sections" (`%s import-guide --schema`)'):format(bin()))
  end
  local ctx = here(o)
  local req = o.request and take_request(o, ctx, 'guide', 'nothing imported', true) or nil
  local r, hunks, info, _, _, attached = review_hunks(o)
  if req then
    local mm = request_mismatch(req, r)
    if mm then
      die(mm .. '; nothing imported')
    end
  end
  local diff = guide.anchors_hash(hunks)
  if type(doc.diff) ~= 'string' or doc.diff == '' then
    die(('the guide has no "diff": give the Diff: hash `%s guide --prompt` printed (%s now), so a guide written for code that changed meanwhile is refused; nothing imported'):format(bin(), diff))
  end
  if doc.diff ~= diff then
    die(('the guide was made for another diff (%s; the review shows %s now): the code changed since `guide --prompt`. Run `%s guide --prompt%s` again and rewrite the parts that changed; nothing imported'):format(
      tostring(doc.diff), diff, bin(), req and (' --request ' .. req.id) or ''))
  end
  doc.diff = nil
  local valid, w = guide.validate(doc, hunks, { level = 'full', abridged = {} })
  if not valid then
    die(tostring(w) .. '; nothing imported')
  end
  -- coverage problems are the writer's to fix (revuey's own runs put the rest in "Other changes")
  local problems = {}
  if w.unknown > 0 then
    problems[#problems + 1] = w.unknown .. ' unknown hunk id(s)'
  end
  if w.duplicates > 0 then
    problems[#problems + 1] = w.duplicates .. ' hunk id(s) listed twice'
  end
  if w.missed > 0 then
    local missing = {}
    for _, sec in ipairs(valid.sections) do
      if sec.other then
        for _, ref in ipairs(sec.hunks) do
          missing[#missing + 1] = ref.id
        end
      end
    end
    problems[#problems + 1] = ('%d hunk id(s) in no section and not in "unplaced" (%s)'):format(w.missed, table.concat(missing, ' '))
  end
  if #problems > 0 then
    die(('the guide does not cover the diff: %s. Every id h1 to h%d must appear exactly once, in a section or in "unplaced"; fix it and import again (nothing imported)'):format(
      table.concat(problems, ', '), #hunks))
  end
  local name = writer_name(o, req)
  local rec = guide.record(valid, hunks, {
    key = guide.key(r.state),
    generator = {
      provider = 'agent',
      agent = name,
      request = req and req.id or nil,
      source = pos[1] == '-' and 'stdin' or pos[1],
      generated_at = os.time(),
      head = r.head,
      merge_base = r.merge_base,
      mode = r.mode,
      prompt_level = 'full',
      warnings = w,
    },
  })
  local dir = (req and req.guide_dir) or guide.dir(vim.fs.dirname(r.state._path))
  test_gate()
  if req then
    -- the status again, under the request's lock, and the guide saved under it: a cancel (or
    -- another import) that came in since the first check wins, and nothing is written
    local _, uerr = requests.update(req._path, function(x)
      if x.status == 'cancelled' then
        return false, ('request %s was cancelled by the user meanwhile: nothing imported'):format(req.id)
      elseif not may_reimport(x, name) then
        return false, ('request %s was done meanwhile (by %s): nothing imported'):format(req.id, tostring(x.result and x.result.agent or '?'))
      end
      local ok, serr = pcall(guide.save, dir, rec)
      if not ok then
        return false, tostring(serr)
      end
      x.status, x.done_at = 'done', requests.now_ms()
      x.result = { sections = #rec.sections, agent = name }
    end)
    if uerr then
      die(uerr)
    end
  else
    local ok, serr = pcall(guide.save, dir, rec)
    if not ok then
      die(tostring(serr))
    end
  end
  local n_notes = 0
  for _, sec in ipairs(rec.sections) do
    for _, a in ipairs(sec.hunks) do
      n_notes = n_notes + #(a.line_notes or {})
    end
  end
  out(('imported the guide (%d section%s, %d line note%s) into %s%s\n'):format(
    #rec.sections, #rec.sections == 1 and '' or 's', n_notes, n_notes == 1 and '' or 's',
    where_text(info, attached), attached and '; the running review shows it within a few seconds' or ''))
  local dropped = guide.dropped_text(w.notes)
  if dropped then
    out(('line notes dropped: %s (fix them and import again%s to replace this guide)\n'):format(dropped,
      req and (' with the same --request ' .. req.id .. ' and --name ' .. name) or ''))
  end
  if w.diagram_dropped then
    out('the diagram was dropped (fewer than two valid nodes)\n')
  end
end

---`install-skill`: link (default) or copy skill/revuey into $HOME/.claude/skills/revuey.
---`pr-target <number|url>`: print `pr:<N>` for `wt switch` (bin/revuey pr). A URL must be in
---this clone's GitHub repo: wt looks the number up there whatever the URL says.
function M.pr_target(_, pos)
  local pr = require('revuey.pr')
  if #pos > 1 then
    die('usage: revuey pr <number|url>', 2)
  end
  local p, perr = pr.parse_arg(pos[1])
  if not p then
    die(perr .. '\nusage: revuey pr <number|url>', 2)
  end
  if p.repo then
    local root = git.root(vim.uv.cwd()) or die('not inside a git repository')
    local fcfg = require('revuey.config').options.forge or {}
    local e = pr.check_repo(p, pr.wt_repo(root, fcfg.cmd or 'gh', fcfg.hosts), fcfg.hosts)
    if e then
      die(e, 2)
    end
  end
  out('pr:' .. p.number .. '\n')
end

---`pr-path`: the worktree path from `wt switch --format json` (stdin).
function M.pr_path()
  local r = require('revuey.pr').parse_result(io.stdin:read('*a'))
  if not r then
    die('wt switch printed no worktree path')
  end
  out(r.path .. '\n')
end

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
  tag = M.tag,
  findings = M.findings,
  watch = M.watch,
  sessions = M.sessions,
  show = M.show,
  ack = M.ack,
  inbox = M.inbox,
  hunks = M.hunks,
  ['import-review'] = M.import_review,
  guide = M.guide,
  ['import-guide'] = M.import_guide,
  ['install-skill'] = M.install_skill,
  ['pr-target'] = M.pr_target,
  ['pr-path'] = M.pr_path,
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
