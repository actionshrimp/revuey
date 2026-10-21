-- AI providers: run the user's own CLI (never read credentials) asynchronously and stream its
-- events. One provider today (`claude`); a provider is a table with
--   build(opts) -> argv, stdin          the command line and the prompt to write to stdin
--   stream()    -> parser               incremental NDJSON parser: parser:feed(chunk) -> events
-- so codex (`codex exec --json --output-schema`) can be added beside it.
--
-- Events handed to `on_event`: {type='init', session_id, model}, {type='progress', text},
-- {type='text', text}. The final structured output comes from the stream's `result` event.
local config = require('revuey.config')

local M = {}

-- ---------------------------------------------------------------------------
-- Claude Code (`claude -p`)
-- ---------------------------------------------------------------------------

-- Read-only, whatever the user's or the repo's settings say. Verified against Claude Code 2.1.302
-- (docs/ARCHITECTURE.md, decision 9):
--   --restricted   ignores user, project and local settings files, so their permission allow
--                  rules and hooks never apply (a user rule such as Bash(make:*) plus a prompt
--                  injection in the repo could otherwise run code under dontAsk); confines the
--                  file tools to the working directory; auth still works.
--   --safe-mode    also disables hooks from plugins, skills, CLAUDE.md and other customisations.
--   --tools        only Read, Grep, Glob and Bash exist (no Edit, Write, WebFetch...).
--   dontAsk        refuses every Bash command that no allow rule matches, including compound
--                  commands and redirects (`git diff > f`).
--   allow/deny     `Bash(git diff:*)` keeps its space; the deny rule's mid-pattern wildcard
--                  blocks `git diff --output=f` although the allow rule matches it.
M.CLAUDE_TOOLS = 'Read,Grep,Glob,Bash'
M.CLAUDE_ALLOWED = { 'Read', 'Grep', 'Glob', 'Bash(git diff:*)', 'Bash(git log:*)', 'Bash(git show:*)' }
M.CLAUDE_DENIED = { 'Bash(git * --out*)' }
M.CLAUDE_SHELL_GUIDANCE = 'Shell access is limited to read-only git commands (git diff, git log, git show), '
  .. 'and anything else is refused without a prompt. Run each command on its own: no &&, ||, ;, pipes, '
  .. 'redirects, $(...) or variables.'

local claude = {}
M.providers = { claude = claude }

---@param opts {schema?:string, model?:string, effort?:string, name?:string, prompt:string, cmd?:string, restricted?:boolean}
function claude.build(opts)
  local argv = {
    opts.cmd or 'claude', '-p',
    '--output-format', 'stream-json', '--verbose',
    '--permission-mode', 'dontAsk',
    '--tools', M.CLAUDE_TOOLS,
    '--allowedTools', table.concat(M.CLAUDE_ALLOWED, ','),
    '--disallowedTools', table.concat(M.CLAUDE_DENIED, ','),
    '--strict-mcp-config',
    '--append-system-prompt', M.CLAUDE_SHELL_GUIDANCE,
  }
  if opts.restricted == false then
    -- ai.restricted = false: the user's own settings load (login via env/apiKeyHelper, default
    -- model), and with them their permission allow rules and hooks; never the repo's settings
    vim.list_extend(argv, { '--setting-sources', 'user' })
  else
    -- no settings files (allow rules, hooks), no customisations
    vim.list_extend(argv, { '--restricted', '--safe-mode' })
  end
  if opts.schema then
    vim.list_extend(argv, { '--json-schema', opts.schema })
  end
  if opts.model and opts.model ~= '' then
    vim.list_extend(argv, { '--model', opts.model })
  end
  if opts.effort and opts.effort ~= '' then
    vim.list_extend(argv, { '--effort', opts.effort })
  end
  if opts.name then
    -- the session is kept (for asking follow-up questions later); name it for `claude --resume`
    vim.list_extend(argv, { '--name', opts.name })
  end
  return argv, opts.prompt
end

---Short progress line for a tool call, with paths relative to `root`.
function M.describe_tool(name, input, root)
  input = type(input) == 'table' and input or {}
  local function rel(p)
    if type(p) ~= 'string' then
      return ''
    end
    if root and p:sub(1, #root + 1) == root .. '/' then
      return p:sub(#root + 2)
    end
    return p
  end
  if name == 'Read' then
    return 'reading ' .. rel(input.file_path or input.path)
  elseif name == 'Grep' then
    return 'searching for ' .. tostring(input.pattern or '')
  elseif name == 'Glob' then
    return 'listing ' .. tostring(input.pattern or '')
  elseif name == 'Bash' then
    return 'running ' .. tostring(input.command or ''):gsub('\n.*', '')
  elseif name == 'StructuredOutput' then
    return 'writing the guide'
  end
  return 'using ' .. tostring(name)
end

---Incremental parser for `--output-format stream-json`. `feed(chunk)` returns the events in the
---complete lines so far; `finish()` flushes a final unterminated line. After the `result` line,
---`parser.result` holds {ok, output?, text?, error?, session_id, cost_usd, duration_ms, ...}.
function claude.stream(root)
  local p = { buf = '', result = nil, session_id = nil, model = nil, lines = 0, bad = 0 }
  local function line_events(line, out)
    if vim.trim(line) == '' then
      return
    end
    p.lines = p.lines + 1
    local ok, ev = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if not ok or type(ev) ~= 'table' then
      p.bad = p.bad + 1
      p.last_noise = line:sub(1, 300)
      return
    end
    if ev.session_id and not p.session_id then
      p.session_id = ev.session_id
    end
    if ev.type == 'system' and ev.subtype == 'init' then
      p.model = ev.model
      out[#out + 1] = { type = 'init', session_id = ev.session_id, model = ev.model }
    elseif ev.type == 'assistant' and type(ev.message) == 'table' then
      for _, part in ipairs(type(ev.message.content) == 'table' and ev.message.content or {}) do
        if type(part) == 'table' and part.type == 'tool_use' then
          out[#out + 1] = { type = 'progress', text = M.describe_tool(part.name, part.input, root), tool = part.name }
          if part.name == 'StructuredOutput' and type(part.input) == 'table' then
            p.tool_output = part.input -- fallback when the result event lacks structured_output
          end
        elseif type(part) == 'table' and part.type == 'text' and type(part.text) == 'string' then
          out[#out + 1] = { type = 'text', text = part.text }
        end
      end
    elseif ev.type == 'result' then
      local r = {
        session_id = ev.session_id or p.session_id,
        cost_usd = ev.total_cost_usd,
        duration_ms = ev.duration_ms,
        turns = ev.num_turns,
        subtype = ev.subtype,
      }
      if ev.is_error or (ev.subtype and ev.subtype ~= 'success') then
        r.ok = false
        r.error = type(ev.result) == 'string' and ev.result ~= '' and ev.result or ('claude failed (' .. tostring(ev.subtype) .. ')')
      else
        r.ok = true
        r.output = type(ev.structured_output) == 'table' and ev.structured_output or p.tool_output
        r.text = type(ev.result) == 'string' and ev.result or nil
      end
      p.result = r
      out[#out + 1] = { type = 'result', result = r }
    end
  end
  function p.feed(_, chunk)
    local out = {}
    p.buf = p.buf .. chunk
    while true do
      local nl = p.buf:find('\n', 1, true)
      if not nl then
        break
      end
      local line = p.buf:sub(1, nl - 1)
      p.buf = p.buf:sub(nl + 1)
      line_events(line, out)
    end
    return out
  end
  function p.finish(_)
    local out = {}
    if p.buf ~= '' then
      local line = p.buf
      p.buf = ''
      line_events(line, out)
    end
    return out
  end
  return p
end

---Turn a failed run into a message a user can act on.
function M.explain_error(msg, stderr)
  local text = (msg or '') .. '\n' .. (stderr or '')
  local lower = text:lower()
  if lower:find('not logged in', 1, true) or lower:find('/login', 1, true) or lower:find('invalid api key', 1, true)
    or lower:find('authentication', 1, true) or lower:find('oauth', 1, true)
  then
    return 'claude is not logged in: run `claude` in a terminal and use /login, then try again. '
      .. 'If you log in through settings (env, apiKeyHelper: Bedrock, Vertex, a proxy), revuey ignores '
      .. 'settings files by default; see ai.restricted in the README ('
      .. vim.trim(msg or stderr or ''):gsub('\n.*', '') .. ')'
  end
  return vim.trim(msg ~= '' and msg or (stderr or ''))
end

-- ---------------------------------------------------------------------------
-- Running a job
-- ---------------------------------------------------------------------------

---@class revuey.AiJob
---@field cancel fun(self)
---@field done boolean
---@field session_id? string
---@field model? string
---@field started integer  hrtime
---@field progress? string latest progress line
---@field argv string[]

-- CLI runs are spawned detached (`setsid`): each is the leader of its own process group, so a
-- signal to `-pid` reaches everything it started (tool subprocesses), not just the CLI.
-- `live` holds every process group that may still be running: a run stays here until its CLI
-- has exited and, if it was terminated, until the follow-up SIGKILL has gone to the group (its
-- children may outlive the CLI). Cancelling a run does not remove it.
---@type table<vim.SystemObj, true>
M.live = {}

---Signal the process group of `proc`; when that fails (no such group), signal the process.
function M.signal_group(proc, sig)
  if proc and proc.pid then
    -- vim.uv.kill returns 0, or nil + an error name (it does not throw)
    if vim.uv.kill(-proc.pid, sig) ~= 0 then
      pcall(proc.kill, proc, sig)
    end
  end
end

---SIGTERM to the process group, then SIGKILL after 2s (the CLI may be gone while children live).
function M.terminate(proc)
  if not proc then
    return
  end
  proc.revuey_terminating = true
  M.signal_group(proc, 'sigterm')
  vim.defer_fn(function()
    M.signal_group(proc, 'sigkill')
    M.live[proc] = nil
  end, 2000)
end

---Stop every process group that may still run, now and synchronously (VimLeavePre: timers no
---longer fire after exit, and detached processes would otherwise keep running, and spending).
function M.kill_all()
  local procs = vim.tbl_keys(M.live)
  if #procs == 0 then
    return
  end
  for _, p in ipairs(procs) do
    M.signal_group(p, 'sigterm')
  end
  vim.wait(300, function()
    for _, p in ipairs(procs) do
      if not p:is_closing() then
        return false
      end
    end
    return true
  end, 10)
  for _, p in ipairs(procs) do
    M.signal_group(p, 'sigkill')
  end
  M.live = {}
end

vim.api.nvim_create_autocmd('VimLeavePre', {
  group = vim.api.nvim_create_augroup('revuey_ai', { clear = true }),
  callback = function()
    M.kill_all()
  end,
})

---Run a provider asynchronously. `on_done(err, result)` is called once on the main loop:
---err is a message (cancelled, timeout, missing CLI, failure) or nil with
---result = {output?, text?, session_id, model, cost_usd, duration_ms}.
---@param opts {provider?:string, prompt:string, schema?:string, cwd:string, model?:string, effort?:string, name?:string, timeout_ms?:integer, on_event?:fun(ev:table), on_done:fun(err?:string, result?:table)}
---@return revuey.AiJob
function M.run(opts)
  local ai_cfg = config.options.ai or {}
  local name = opts.provider or ai_cfg.provider or 'claude'
  local provider = M.providers[name]
  local job = { done = false, started = vim.uv.hrtime() } ---@type revuey.AiJob
  local function finish(err, result)
    if job.done then
      return
    end
    job.done = true
    if job.timer then
      job.timer:stop()
      job.timer:close()
      job.timer = nil
    end
    vim.schedule(function()
      opts.on_done(err, result)
    end)
  end
  function job.cancel(_)
    if job.done then
      return
    end
    job.reason = 'cancelled'
    M.terminate(job.proc)
    finish('cancelled')
  end
  if not provider then
    finish('unknown AI provider: ' .. tostring(name))
    return job
  end
  local cmd = opts.cmd or ai_cfg.cmd or name
  local argv, stdin = provider.build({
    cmd = cmd,
    prompt = opts.prompt,
    schema = opts.schema,
    model = opts.model,
    effort = opts.effort,
    name = opts.name,
    restricted = (opts.restricted ~= nil) and opts.restricted or ai_cfg.restricted,
  })
  job.argv = argv
  if vim.fn.executable(argv[1]) ~= 1 then
    finish(('`%s` not found on PATH: install Claude Code (https://claude.com/claude-code) and log in, or set ai.cmd'):format(argv[1]))
    return job
  end
  local parser = provider.stream(opts.cwd)
  local stderr = {}
  local function handle(events)
    for _, ev in ipairs(events) do
      if ev.type == 'init' then
        job.session_id, job.model = ev.session_id, ev.model
      elseif ev.type == 'progress' then
        job.progress = ev.text
      end
      if ev.type == 'result' then
        job.session_id = ev.result.session_id or job.session_id
      end
      if opts.on_event then
        pcall(opts.on_event, ev)
      end
    end
  end
  local ok, proc = pcall(vim.system, argv, {
    cwd = opts.cwd,
    detach = true, -- own process group (see signal_group)
    stdin = stdin,
    text = true,
    stdout = function(_, data)
      if data then
        vim.schedule(function()
          if not job.done then
            handle(parser:feed(data))
          end
        end)
      end
    end,
    stderr = function(_, data)
      if data then
        stderr[#stderr + 1] = data
      end
    end,
  }, function(res)
    vim.schedule(function()
      -- exited: done with it, unless a terminate still owes its group a SIGKILL
      if job.proc and not job.proc.revuey_terminating then
        M.live[job.proc] = nil
      end
      if job.done then
        return
      end
      handle(parser:finish())
      local r = parser.result
      local err_text = table.concat(stderr)
      if r and r.ok then
        return finish(nil, {
          output = r.output,
          text = r.text,
          session_id = r.session_id or job.session_id,
          model = job.model,
          cost_usd = r.cost_usd,
          duration_ms = r.duration_ms,
        })
      end
      if r and not r.ok then
        return finish(M.explain_error(r.error, err_text))
      end
      local msg = ('%s exited with code %d'):format(argv[1], res.code)
      local detail = vim.trim(err_text ~= '' and err_text or (parser.last_noise or ''))
      finish(M.explain_error(detail ~= '' and (msg .. ': ' .. detail) or (msg .. ' and no result'), err_text))
    end)
  end)
  if not ok then
    finish('could not start ' .. argv[1] .. ': ' .. tostring(proc))
    return job
  end
  job.proc = proc
  M.live[proc] = true
  local timeout = opts.timeout_ms or ai_cfg.timeout_ms
  if timeout and timeout > 0 then
    job.timer = vim.uv.new_timer()
    job.timer:start(timeout, 0, function()
      vim.schedule(function()
        if job.done then
          return
        end
        job.reason = 'timeout'
        M.terminate(proc)
        finish(('timed out after %ds (ai.timeout_ms)'):format(math.floor(timeout / 1000)))
      end)
    end)
  end
  return job
end

---Seconds since the job started.
function M.elapsed(job)
  return math.floor((vim.uv.hrtime() - job.started) / 1e9)
end

return M
