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

---A URL's repo must be the one `wt` looks PRs up in: wt ignores the URL's owner and name and
---asks the clone's own GitHub repo for that number, so a URL from another repo would open some
---other PR. `base` is the clone's base repo (forge.base_remote, resolved like gh), nil when it
---has no GitHub remote.
---@param pr revuey.PrArg
---@param base? revuey.ForgeRepo
---@return string? err
function M.check_repo(pr, base)
  if not pr.repo then
    return nil
  end
  local want = (pr.repo.owner .. '/' .. pr.repo.name):lower()
  if not base then
    return ('this clone has no GitHub remote, so %s#%d cannot be opened here'):format(pr.repo.owner .. '/' .. pr.repo.name, pr.number)
  end
  local have = (base.owner .. '/' .. base.name):lower()
  if want ~= have then
    return ('PR #%d is in %s/%s, but this clone is %s/%s: open it from a clone of %s/%s'):format(
      pr.number,
      pr.repo.owner,
      pr.repo.name,
      base.owner,
      base.name,
      pr.repo.owner,
      pr.repo.name
    )
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

---A stderr line without wt's leading glyph and ANSI codes.
function M.clean(line)
  line = (line or ''):gsub('\27%[[%d;]*[A-Za-z]', ''):gsub('\r', '')
  line = vim.trim(line)
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

---Why `wt switch` failed, from its exit code and stderr. `kind`: 'approval' (project hooks
---need approval and wt cannot ask without a terminal), 'hook' (a pre-start hook failed; the
---worktree exists), or 'failed'. `text` is wt's own error (the `✗` line and what follows it).
---@param code integer
---@param stderr? string
---@return {kind:'approval'|'hook'|'failed', text:string, path?:string, commands?:string[]}
function M.failure(code, stderr)
  stderr = stderr or ''
  local lines, from = {}, nil
  for line in stderr:gmatch('[^\n]+') do
    lines[#lines + 1] = line
    if not from and vim.startswith(vim.trim(line:gsub('\27%[[%d;]*[A-Za-z]', '')), '✗') then
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
  local path = M.created_path(stderr)
  if path and msg:find('pre%-start') then
    return { kind = 'hook', text = msg, path = path }
  end
  return { kind = 'failed', text = msg, path = path }
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
---@field stderr string everything wt wrote to stderr so far
---@field line? string its latest non-empty line (cleaned)
---@field started integer hrtime

---Run `wt switch pr:<n>` in the background (stdin closed, so wt never waits for an answer; its
---own process group, so cancelling stops the hooks it started too). `on_line(line)` gets each
---cleaned non-empty stderr line; `on_done(err, result)` is called once on the main loop: err nil
---and result `{path, branch, action}`, or err `{kind, text, path?, commands?}` (kind 'cancelled'
---too).
---@param opts {cmd:string, number:integer, cwd:string, on_line?:fun(line:string), on_done:fun(err?:table, result?:table)}
---@return revuey.PrJob
function M.run(opts)
  local ai = require('revuey.ai') -- process-group helpers (and its VimLeavePre kill_all)
  local job = { number = opts.number, done = false, stderr = '', started = vim.uv.hrtime() } ---@type revuey.PrJob
  local function finish(err, result)
    if job.done then
      return
    end
    job.done = true
    vim.schedule(function()
      opts.on_done(err, result)
    end)
  end
  function job.cancel(_)
    if job.done then
      return
    end
    ai.terminate(job.proc)
    finish({ kind = 'cancelled', text = 'cancelled', path = M.created_path(job.stderr) })
  end
  local partial = ''
  local ok, proc = pcall(vim.system, M.argv(opts.cmd, opts.number), {
    cwd = opts.cwd,
    detach = true, -- own process group (ai.signal_group)
    text = true,
    stderr = function(_, data)
      if not data then
        return
      end
      vim.schedule(function()
        job.stderr = job.stderr .. data
        partial = partial .. data
        for line in partial:gmatch('([^\n]*)\n') do
          local t = M.clean(line)
          if t ~= '' then
            job.line = t
            if opts.on_line and not job.done then
              pcall(opts.on_line, t)
            end
          end
        end
        partial = partial:match('[^\n]*$')
      end)
    end,
  }, function(res)
    vim.schedule(function()
      if job.proc and not job.proc.revuey_terminating then
        ai.live[job.proc] = nil
      end
      if res.code == 0 then
        local r = M.parse_result(res.stdout)
        if r then
          return finish(nil, r)
        end
        return finish({ kind = 'failed', text = 'wt printed no worktree path: ' .. vim.trim(res.stdout or '') })
      end
      finish(M.failure(res.code, job.stderr))
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
