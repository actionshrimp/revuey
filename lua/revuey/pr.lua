-- Remote PR review via worktrunk (`:Revuey pr <N|url>`, `bin/revuey pr`): the PR argument, the
-- `wt switch` command, its result and error texts (pure), and the background run (vim.system,
-- no UI; `pr_view.lua` is the glue).
--
-- `wt switch pr:<N> --no-cd --format json` creates the PR's worktree (or finds it), running the
-- user's worktrunk hooks: pre-switch, then pre-start (blocking: install, build), then post-start
-- and post-switch in the background. stdout is one JSON object `{action, branch, path, ...}`;
-- progress, approval prompts and hook output go to stderr. revuey never passes `--yes`: approving
-- a repo's project hooks stays the user's decision (see `failure`).
local M = {}

---@class revuey.PrArg
---@field number integer
---@field repo? {host:string, owner:string, name:string} from a URL (the repo it must be in)

---Parse the PR argument: `12`, `#12`, `pr:12`, or a pull request URL
---(`https://github.com/owner/name/pull/12`, with anything after the number).
---@param arg? string
---@return revuey.PrArg?, string? err
function M.parse_arg(arg)
  arg = vim.trim(arg or '')
  local n = arg:match('^#?(%d+)$') or arg:match('^pr:(%d+)$')
  if n then
    return { number = tonumber(n) }
  end
  local host, owner, name, num = arg:match('^https?://([^/]+)/([^/]+)/([^/]+)/pulls?/(%d+)')
  if host then
    return { number = tonumber(num), repo = { host = host:lower(), owner = owner, name = name } }
  end
  if arg == '' then
    return nil, 'which pull request? Give its number or URL'
  end
  return nil, ('not a pull request number or URL: %s'):format(arg)
end

---The repo `wt` looks PR numbers up in, as worktrunk 0.81 picks it (pure): gh's default repo
---(`gh repo set-default --view`, `default`: `owner/name`, empty when none is set), else the
---first remote with a GitHub URL in git config order (`remotes`: {name, url}, the
---`remote.<name>.url` entries as `git config --get-regexp` lists them; other forges and local
---paths are skipped, and `origin` is not preferred). Not `forge.base_remote`, which prefers `upstream` and the trunk's remote
---like gh's own PR lookups. nil when there is none.
---@param default? string
---@param remotes {name:string, url:string}[]
---@param hosts? string[] extra GitHub hosts (forge.hosts)
---@return revuey.ForgeRepo?
function M.pick_wt_repo(default, remotes, hosts)
  local forge = require('revuey.forge')
  local parsed = {}
  for _, r in ipairs(remotes) do
    local repo = forge.parse_remote_url(r.url, hosts)
    if repo then
      parsed[#parsed + 1] = repo
    end
  end
  local owner, name = vim.trim(default or ''):match('^([^/%s]+)/([^/%s]+)$')
  if owner then
    -- the host of a remote of that repo (gh prints no host), else github.com
    for _, repo in ipairs(parsed) do
      if (repo.owner .. '/' .. repo.name):lower() == (owner .. '/' .. name):lower() then
        return repo
      end
    end
    return { host = 'github.com', owner = owner, name = name }
  end
  return parsed[1]
end

---The repo `wt` would ask (pick_wt_repo), from `gh repo set-default --view` (offline: gh reads
---`remote.<name>.gh-resolved`) and the remotes in git config order. Runs gh and git: in a
---coroutine (git.async) the calls do not block.
---@param root string
---@param gh string the gh executable (forge.cmd)
---@param hosts? string[]
---@return revuey.ForgeRepo?
function M.wt_repo(root, gh, hosts)
  local git = require('revuey.git')
  local default
  if vim.fn.executable(gh) == 1 then
    local ok, res = pcall(git.system, { gh, 'repo', 'set-default', '--view' }, { cwd = root, text = true })
    if ok and res.code == 0 then
      default = res.stdout
    end
  end
  local remotes = {}
  for line in (git.git({ 'config', '--get-regexp', '^remote\\..*\\.url$' }, root) or ''):gmatch('[^\n]+') do
    local name, url = line:match('^remote%.(.-)%.url (.*)$')
    if name then
      remotes[#remotes + 1] = { name = name, url = url }
    end
  end
  return M.pick_wt_repo(default, remotes, hosts)
end

---A URL's repo must be the one `wt` looks PRs up in: wt ignores the URL's host, owner and name
---and asks the clone's own repo (`wt_repo`) for that number, so a URL from another repo
---would open some other PR. `base` is that repo, nil when the remote is not on GitHub.
---`hosts`: extra GitHub hosts (forge.hosts), to name the URL's host as `base.host` does.
---@param pr revuey.PrArg
---@param base? revuey.ForgeRepo
---@param hosts? string[]
---@return string? err
function M.check_repo(pr, base, hosts)
  if not pr.repo then
    return nil
  end
  local name = pr.repo.owner .. '/' .. pr.repo.name
  if not base then
    return ('this clone has no GitHub repo wt would use, so %s#%d cannot be opened here'):format(name, pr.number)
  end
  local host = require('revuey.forge').github_host(pr.repo.host, hosts) or pr.repo.host
  local have = base.owner .. '/' .. base.name
  if host:lower() ~= base.host:lower() then
    return ('PR #%d is on %s (%s), but this clone is on %s (%s): open it from a clone of %s/%s'):format(
      pr.number, host, name, base.host, have, host, name)
  end
  if name:lower() ~= have:lower() then
    return ('PR #%d is in %s, but this clone is %s: open it from a clone of %s'):format(pr.number, name, have, name)
  end
  return nil
end

---`wt switch` for PR `n`, never with `--yes`.
---@param cmd string the wt executable
---@param n integer
---@return string[]
function M.argv(cmd, n)
  return { cmd, 'switch', 'pr:' .. n, '--no-cd', '--format', 'json' }
end

---The same in a terminal, where wt can ask for approval: stdout (the JSON) goes to `out_file`,
---the prompt and the hooks' output to the terminal.
---@return string[]
function M.term_argv(cmd, n, out_file)
  return vim.list_extend({ 'sh', '-c', 'exec "$@" > "$0"', out_file }, M.argv(cmd, n))
end

---The JSON result `wt switch --format json` prints on stdout (the last line that is a JSON
---object with a `path`).
---@param stdout? string
---@return {path:string, branch?:string, action?:string}?
function M.parse_result(stdout)
  local found
  for line in (stdout or ''):gmatch('[^\n]+') do
    line = vim.trim(line)
    if line:sub(1, 1) == '{' then
      local ok, obj = pcall(vim.json.decode, line)
      if ok and type(obj) == 'table' and type(obj.path) == 'string' and obj.path ~= '' then
        found = {
          path = obj.path,
          branch = type(obj.branch) == 'string' and obj.branch or nil,
          action = type(obj.action) == 'string' and obj.action or nil,
        }
      end
    end
  end
  return found
end

-- wt's message prefixes (glyphs; also without colour when not on a terminal)
local GLYPHS = { '◎', '✓', '✗', '▲', '○', '↳', '❯', '⚠' }

---A stderr line as a terminal would leave it: ANSI codes gone, and of `\r`-separated
---progress updates (`50%\r100%`) only the last.
function M.plain(line)
  line = (line or ''):gsub('\27%[[%d;]*[A-Za-z]', ''):gsub('\r+$', '')
  return line:match('[^\r]*$')
end

---A stderr line without wt's leading glyph and ANSI codes (M.plain, trimmed).
function M.clean(line)
  line = vim.trim(M.plain(line))
  for _, g in ipairs(GLYPHS) do
    if vim.startswith(line, g) then
      return vim.trim(line:sub(#g + 1))
    end
  end
  return line
end

---The worktree wt's pre-start hooks ran in (`◎ Running pre-start project:build @ <path>`), if
---it got that far: the worktree exists then, even when the run failed or was cancelled.
---@param stderr string
---@return string?
function M.created_path(stderr)
  local path
  for line in stderr:gmatch('[^\n]+') do
    local p = M.clean(line):match('^Running pre%-start .- @ (.+)$')
    path = p and vim.trim(p) or path
  end
  return path
end

-- lines of a failing hook's output kept in the message (the end of it goes to revuey.log)
M.OUTPUT_LINES = 5

---Why `wt switch` failed, from its exit code and stderr. `kind`: 'approval' (project hooks
---need approval and wt cannot ask without a terminal), 'hook' (a pre-start hook failed; the
---worktree exists), or 'failed'. `text` is wt's own error (the `✗` line and what follows it),
---`output` the last few lines printed before it (M.OUTPUT_LINES).
---@param code integer
---@param stderr? string
---@param created? string the worktree the hooks ran in, when known (stderr may be only a tail)
---@return {kind:'approval'|'hook'|'failed', text:string, path?:string, commands?:string[], output?:string[]}
function M.failure(code, stderr, created)
  stderr = stderr or ''
  local lines, from = {}, nil
  for line in stderr:gmatch('[^\n]+') do
    lines[#lines + 1] = line
    -- the last `✗`: wt's own error comes last (a hook may print `✗` lines of its own)
    if vim.startswith(vim.trim(M.plain(line)), '✗') then
      from = #lines
    end
  end
  local text = {}
  for i = from or math.max(1, #lines - 2), #lines do
    local t = M.clean(lines[i])
    if t ~= '' then
      text[#text + 1] = t
    end
  end
  local msg = #text > 0 and table.concat(text, '\n') or ('wt exited with code %d'):format(code)
  -- the last lines the failing step printed before wt's `✗` (the compiler error, say): back to
  -- the step's `◎ Running ...` line, leaving out wt's echo of the command (the indented lines
  -- right after it)
  local output = {}
  if from then
    -- no `Running` line: wt's own error before any step ran (no hook output), unless the
    -- step's start is just not in the kept tail (`created` known)
    local start = created and 1 or from
    for i = from - 1, 1, -1 do
      local raw = vim.trim(M.plain(lines[i]))
      if vim.startswith(raw, '◎') and M.clean(lines[i]):match('^Running ') then
        start = i + 1
        while start < from and M.plain(lines[start]):match('^  %S') do
          start = start + 1
        end
        break
      end
    end
    for i = start, from - 1 do
      local t = M.clean(lines[i])
      if t ~= '' then
        output[#output + 1] = t
      end
    end
    while #output > M.OUTPUT_LINES do
      table.remove(output, 1)
    end
  end
  if stderr:find('Cannot prompt for approval', 1, true) then
    -- the commands wt listed (`○ pre-start install:` then the command, indented)
    local cmds = {}
    for i, line in ipairs(lines) do
      local hook = M.clean(line):match('^(pre%-%S+ [^:]+):$') or M.clean(line):match('^(post%-%S+ [^:]+):$')
      if hook and lines[i + 1] then
        cmds[#cmds + 1] = hook .. ': ' .. vim.trim(lines[i + 1])
      end
    end
    return { kind = 'approval', text = msg, commands = cmds }
  end
  local path = M.created_path(stderr) or created
  output = #output > 0 and output or nil
  if path and msg:find('pre%-start') then
    return { kind = 'hook', text = msg, path = path, output = output }
  end
  return { kind = 'failed', text = msg, path = path, output = output }
end

---What to tell the user about a failure (one message).
---@param n integer
---@param f {kind:string, text:string, path?:string, commands?:string[]}
function M.failure_message(n, f)
  if f.kind == 'approval' then
    local lines = {
      ('revuey: worktrunk needs your approval to run this repo\'s project hooks for PR #%d, and cannot ask in the background:'):format(n),
    }
    for _, c in ipairs(f.commands or {}) do
      lines[#lines + 1] = '  ' .. c
    end
    lines[#lines + 1] = 'Approve them in a terminal (`wt config approvals add`, or run `wt switch pr:' .. n .. '` once), then :Revuey pr ' .. n .. ' again.'
    return table.concat(lines, '\n')
  end
  local msg = ('revuey: wt switch pr:%d failed: %s'):format(n, f.text)
  if f.output then
    msg = msg .. '\n' .. table.concat(vim.tbl_map(function(l)
      return '  ' .. l
    end, f.output), '\n')
  end
  if f.log and f.output then
    msg = msg .. ('\n(the end of wt\'s output is in %s)'):format(f.log)
  end
  if f.path then
    msg = msg
      .. ('\nThe worktree was created at %s. :Revuey pr %d opens it as it is (pre-start does not run again; `wt -C %s hook pre-start` re-runs it), or remove it with `wt remove %s`.'):format(
        f.path,
        n,
        vim.fn.shellescape(f.path),
        vim.fn.shellescape(f.path)
      )
  end
  return msg
end

---@class revuey.PrJob
---@field number integer
---@field done boolean
---@field cancel fun(self)
---@field proc? vim.SystemObj
---@field line? string wt's latest non-empty stderr line (cleaned)
---@field created? string the worktree the pre-start hooks run in, once wt said so
---@field cancelling? boolean cancel sent; reported once wt exits (M.CANCEL_REPORT_MS at most)
---@field started integer hrtime

-- stderr kept for the failure message and the log: the latest this many bytes (npm install
-- can print a lot; wt's own lines that matter, approval listings and the `✗` error, are at
-- the start, before any hook ran, or at the end)
M.STDERR_MAX = 256 * 1024
-- an unfinished stderr line longer than this keeps only its end
M.PARTIAL_MAX = 4096
-- the end of a failed run's stderr written to revuey.log, one log entry per line
M.LOG_MAX = 4096
-- a cancelled run is reported when wt exits, or after this long (past ai.terminate's SIGKILL)
M.CANCEL_REPORT_MS = 3000

---Run `wt switch pr:<n>` in the background (stdin closed, so wt never waits for an answer; its
---own process group, so cancelling stops the hooks it started too). `on_line(line)` gets each
---cleaned non-empty stderr line; `on_done(err, result)` is called once on the main loop: err nil
---and result `{path, branch, action}`, or err `{kind, text, path?, commands?, output?}` (kind
---'cancelled' too). The end of a failure's stderr (M.LOG_MAX) goes to revuey.log, line by
---line, and `err.log` names that file.
---@param opts {cmd:string, number:integer, cwd:string, on_line?:fun(line:string), on_done:fun(err?:table, result?:table)}
---@return revuey.PrJob
function M.run(opts)
  local ai = require('revuey.ai') -- process-group helpers (and its VimLeavePre kill_all)
  local job = { number = opts.number, done = false, started = vim.uv.hrtime() } ---@type revuey.PrJob
  local chunks, size, partial = {}, 0, ''
  local function finish(err, result)
    if job.done then
      return
    end
    job.done = true
    vim.schedule(function()
      opts.on_done(err, result)
    end)
  end
  local function cancelled()
    finish({ kind = 'cancelled', text = 'cancelled', path = job.created })
  end
  -- Reported once wt has exited and its stderr is read to the end, not at the signal: the
  -- `Running pre-start ... @ <path>` line can be in the pipe, unread, when cancel comes. If
  -- the pipe never closes (a hook that left the group keeps it open), report after SIGKILL.
  function job.cancel(_)
    if job.done or job.cancelling then
      return
    end
    job.cancelling = true
    ai.terminate(job.proc)
    vim.defer_fn(cancelled, M.CANCEL_REPORT_MS)
  end
  local function on_stderr(data)
    chunks[#chunks + 1] = data
    size = size + #data
    while size > M.STDERR_MAX and #chunks > 1 do
      size = size - #table.remove(chunks, 1)
    end
    local text = partial .. data
    local last = 1
    -- `\r` ends a line too (progress bars redraw with it); `find` from the last end, so a long
    -- line without one is scanned once, not again from every position
    while true do
      local at = text:find('[\r\n]', last)
      if not at then
        break
      end
      local t = M.clean(text:sub(last, at - 1))
      last = at + 1
      if t ~= '' then
        job.line = t
        local p = t:match('^Running pre%-start .- @ (.+)$')
        job.created = p and vim.trim(p) or job.created
        if opts.on_line and not job.done and not job.cancelling then
          pcall(opts.on_line, t)
        end
      end
    end
    partial = text:sub(last)
    if #partial > M.PARTIAL_MAX then
      partial = partial:sub(-M.PARTIAL_MAX) -- output without any line end: keep its end
    end
  end
  local ok, proc = pcall(vim.system, M.argv(opts.cmd, opts.number), {
    cwd = opts.cwd,
    detach = true, -- own process group (ai.signal_group)
    text = true,
    stderr = function(_, data)
      if data then
        vim.schedule(function()
          on_stderr(data)
        end)
      end
    end,
  }, function(res)
    vim.schedule(function()
      if job.proc and not job.proc.revuey_terminating then
        ai.live[job.proc] = nil
      end
      if job.done then
        return
      end
      if job.cancelling then
        return cancelled() -- stderr's scheduled callbacks ran first: job.created is final
      end
      if res.code == 0 then
        local r = M.parse_result(res.stdout)
        if r then
          return finish(nil, r)
        end
        return finish({ kind = 'failed', text = 'wt printed no worktree path: ' .. vim.trim(res.stdout or '') })
      end
      local stderr = table.concat(chunks)
      local log = require('revuey.log')
      log.write('pr', ('wt switch pr:%d exited %d; the end of its stderr:'):format(opts.number, res.code))
      local tail = stderr:sub(-M.LOG_MAX)
      if #stderr > M.LOG_MAX then
        tail = tail:gsub('^[^\n]*\n', '') -- from a line start
      end
      for line in tail:gmatch('[^\n]+') do
        log.write('pr', '  ' .. M.plain(line))
      end
      local f = M.failure(res.code, stderr, job.created)
      f.log = log.path()
      finish(f)
    end)
  end)
  if not ok then
    finish({ kind = 'failed', text = 'could not start ' .. opts.cmd .. ': ' .. tostring(proc) })
    return job
  end
  job.proc = proc
  ai.live[proc] = true
  return job
end

return M
