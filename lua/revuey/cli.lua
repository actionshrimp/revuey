-- `bin/revuey comments|watch|reply`: review comments from the shell, for coding agents. Runs as
-- `nvim --clean --headless -l lua/revuey/cli.lua <command> [args]` without any UI.
--
--   comments [--json] [--all] [--scope current|all|<branch>]
--       the comments of the current repo and branch (Markdown, like :RevueyCommentsExport)
--   watch [--json] [--since <event id>|all] [--all] [--scope ...]
--       follow the event feed: one line per event, flushed per line (Claude Code's Monitor tool
--       treats each stdout line as an event); exits cleanly on SIGTERM (via bin/revuey)
--   reply <comment id> <text|->
--       add an agent reply to a comment's thread (`-` reads the text from stdin)
--
-- Common: --state-dir <dir> (default $REVUEY_STATE_DIR, else stdpath('data')/revuey).
-- Scope: `current` (default) = review scopes of the checked-out branch (its plain review, its
-- stack layer, and full-stack reviews that include it); `all` = every review of the repo;
-- a branch name = review scopes of that branch.
local modname = ...
local plugin = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
vim.opt.rtp:prepend(plugin)

local comments = require('revuey.comments')
local export = require('revuey.comments_export')
local git = require('revuey.git')

local M = {}

local function out(s)
  local ok = io.stdout:write(s)
  if not ok then
    os.exit(0) -- the reader went away
  end
  io.stdout:flush()
end

local function die(msg, code)
  io.stderr:write('revuey: ' .. msg .. '\n')
  io.stderr:flush()
  os.exit(code or 1)
end

local USAGE = [[
usage: revuey comments [--json] [--all] [--scope current|all|<branch>]
       revuey watch [--json] [--since <event id>|all] [--all] [--scope current|all|<branch>]
       revuey reply <comment id> <text|->
options: --state-dir <dir> (default $REVUEY_STATE_DIR, else Neovim's data dir/revuey)]]

local VALUE_FLAGS = { ['--scope'] = 'scope', ['--since'] = 'since', ['--state-dir'] = 'state_dir' }
local BOOL_FLAGS = { ['--json'] = 'json', ['--all'] = 'all' }

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
        die(a .. ' needs a value\n' .. USAGE, 2)
      end
      o[VALUE_FLAGS[a]] = args[i + 1]
      i = i + 1
    elseif a:match('^%-%-[%w-]+=') then
      local k, v = a:match('^(%-%-[%w-]+)=(.*)$')
      if not VALUE_FLAGS[k] then
        die('unknown option ' .. k .. '\n' .. USAGE, 2)
      end
      o[VALUE_FLAGS[k]] = v
    elseif BOOL_FLAGS[a] then
      o[BOOL_FLAGS[a]] = true
    elseif a == '-h' or a == '--help' then
      out(USAGE .. '\n')
      os.exit(0)
    elseif a:sub(1, 2) == '--' then
      die('unknown option ' .. a .. '\n' .. USAGE, 2)
    else
      pos[#pos + 1] = a
    end
    i = i + 1
  end
  return o, pos
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

---Comments files of the selected reviews: { {path, store}, ... } (sorted by branch, scope).
local function stores(dir, ctx, scope, readonly)
  local list = {}
  if not vim.uv.fs_stat(dir) then
    return list
  end
  for name, t in vim.fs.dir(dir) do
    if t == 'file' and name:match('%.comments%.json$') then
      local path = vim.fs.joinpath(dir, name)
      local store = comments.load(path, readonly and { readonly = true } or nil)
      if M.matches(store.review, ctx, scope) then
        list[#list + 1] = { path = path, store = store }
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

function M.comments(o)
  local ctx = here()
  local reviews = {}
  -- read-only: an unreadable file is reported, never moved aside
  for _, e in ipairs(stores(state_dir(o), ctx, o.scope, true)) do
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

function M.reply(o, pos)
  local id, text = pos[1], pos[2]
  if not id or not text then
    die('reply needs a comment id and a text (or - for stdin)\n' .. USAGE, 2)
  end
  if text == '-' then
    text = io.stdin:read('*a') or ''
  end
  text = vim.trim(text)
  if text == '' then
    die('empty reply')
  end
  local ctx = here()
  local found = {}
  for _, e in ipairs(stores(state_dir(o), ctx, o.scope or 'all')) do
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
  local e, c = found[1].e, found[1].c
  local author = { kind = 'agent', name = (vim.env.REVUEY_AGENT_NAME ~= '' and vim.env.REVUEY_AGENT_NAME) or 'agent' }
  local r = comments.reply(e.store, c.id, text, author)
  local ok, err = pcall(comments.save, e.store)
  if not ok then
    die(tostring(err))
  end
  local events = e.path:gsub('%.comments%.json$', '.events.jsonl')
  comments.append_event(events, comments.event('replied', comments.get(e.store, c.id), e.store.review, { reply = r }))
  out(('replied to %s (%s)\n'):format(c.id, comments.location(c)))
end

---Follow every events file of the state dir (new files included), printing matching events.
function M.watch(o)
  local ctx = here()
  local dir = state_dir(o)
  vim.fn.mkdir(dir, 'p')
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
  local tracked = {} ---@type table<string, {fd:integer, ino:integer, offset:integer, partial:string}>

  local function emit(ev)
    if not M.matches(ev.review, ctx, o.scope) then
      return
    end
    if since and not (ev.id > since) then
      return
    end
    -- the agent's own replies are not news to it
    if not o.all and ev.kind == 'replied' and ev.reply and ev.reply.author and ev.reply.author.kind == 'agent' then
      return
    end
    out((o.json and vim.json.encode(ev) or comments.event_line(ev)) .. '\n')
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

  local function poll(initial)
    for name, ty in vim.fs.dir(dir) do
      if ty == 'file' and name:match('%.events%.jsonl$') then
        local path = vim.fs.joinpath(dir, name)
        if not tracked[path] then
          if initial and since then
            read_whole(path .. '.1') -- rotated events, for --since
          end
          -- files there at start: only what comes next (unless --since); new files: all of it
          open(path, initial and not since)
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
  end

  poll(true)
  io.stderr:write(('revuey: watching %s for comment events (%s)\n'):format(dir, o.scope or ('branch ' .. ctx.branch)))
  io.stderr:flush()
  while running do
    vim.wait(250, function()
      return not running
    end, 25)
    if not running then
      break
    end
    poll(false)
    if vim.uv.os_getppid() ~= ppid or (owner and vim.uv.kill(owner, 0) ~= 0) then
      break -- the launcher (bin/revuey) or whoever started it is gone
    end
  end
  os.exit(0)
end

function M.main(args)
  local cmd = table.remove(args, 1)
  local o, pos = M.parse(args)
  if cmd == 'comments' then
    M.comments(o)
  elseif cmd == 'reply' then
    M.reply(o, pos)
  elseif cmd == 'watch' then
    M.watch(o)
  else
    die('unknown command ' .. tostring(cmd) .. '\n' .. USAGE, 2)
  end
end

-- run as a script (`nvim -l cli.lua ...`), not required as a module
if modname ~= 'revuey.cli' then
  M.main(vim.deepcopy(_G.arg or {}))
  os.exit(0)
end

return M
