-- `:Revuey pr <N|url>`: set up the PR's worktree with worktrunk (`wt switch pr:<N>`, so the
-- user's hooks install and build it), then open the review there in a new tab whose working
-- directory (`:tcd`) is the worktree. Glue over `pr.lua`: progress messages, cancel, the
-- approval terminal. The review (and so its LSP) only starts once `wt switch` has returned.
local pr = require('revuey.pr')
local config = require('revuey.config')
local git = require('revuey.git')

local api = vim.api
local M = {}

-- progress messages (`nvim_echo` kind=progress) use one id, so each update replaces the last
local PROGRESS_ID = 'revuey.pr'

---The one PR setup at a time: {number, job? (background run), term? {buf, job}, timer?}
---@type table?
M.current = nil

---Hook for tests: what to do once the worktree is ready (default: open the review there).
---@type fun(result:{path:string, branch?:string, action?:string}, opts:table)?
M.on_ready = nil

local function echo(n, status, text, history)
  pcall(api.nvim_echo, { { text } }, history or false, {
    kind = 'progress',
    id = PROGRESS_ID,
    source = 'revuey',
    title = 'PR #' .. n,
    status = status,
  })
end

local function stop_timer(c)
  if c and c.timer then
    c.timer:stop()
    c.timer:close()
    c.timer = nil
  end
end

---Status text while wt runs: elapsed time and wt's latest line.
function M.status_text(c)
  local secs = math.floor((vim.uv.hrtime() - c.started) / 1e9)
  local line = c.job and c.job.line or 'starting wt switch'
  if vim.fn.strdisplaywidth(line) > 70 then
    line = vim.fn.strcharpart(line, 0, 69) .. '…'
  end
  return ('worktrunk %ds  %s'):format(secs, line)
end

local function open_review(result, opts)
  if M.on_ready then
    return M.on_ready(result, opts)
  end
  require('revuey.view').open({ cwd = result.path, tcd = true, on_ready = opts.on_open })
end

local function ready(c, result, opts)
  M.current = nil
  echo(c.number, 'success', ('worktree %s%s'):format(result.path, result.action == 'existing' and ' (existing)' or ''), true)
  open_review(result, opts)
end

---Run `wt switch` in a terminal split, where wt can ask for approval (its own prompt, the
---user's answer); on success the review opens as after a background run. A failed run leaves
---the terminal open with wt's output.
---@param c table M.current
function M.run_in_terminal(c, opts)
  local out = vim.fn.tempname()
  vim.cmd('botright 15new')
  local buf = api.nvim_get_current_buf()
  local win = api.nvim_get_current_win()
  local cmd = config.options.worktrunk.cmd
  local ok, id = pcall(vim.fn.jobstart, pr.term_argv(cmd, c.number, out), {
    term = true,
    cwd = c.root,
    on_exit = function(_, code)
      vim.schedule(function()
        if M.current ~= c then
          return -- cancelled
        end
        local text = vim.uv.fs_stat(out) and table.concat(vim.fn.readfile(out), '\n') or ''
        vim.fn.delete(out)
        local result = code == 0 and pr.parse_result(text)
        if not result then
          M.current = nil
          echo(c.number, 'failed', ('wt switch pr:%d failed (exit %d)'):format(c.number, code), true)
          return vim.notify(
            ('revuey: wt switch pr:%d failed (exit %d); its output is in the terminal'):format(c.number, code),
            vim.log.levels.ERROR
          )
        end
        if api.nvim_win_is_valid(win) and #api.nvim_list_wins() > 1 then
          pcall(api.nvim_win_close, win, true)
        end
        if api.nvim_buf_is_valid(buf) then
          pcall(api.nvim_buf_delete, buf, { force = true })
        end
        ready(c, result, opts)
      end)
    end,
  })
  if not ok or id <= 0 then
    M.current = nil
    return vim.notify('revuey: could not start ' .. cmd .. ' in a terminal: ' .. tostring(id), vim.log.levels.ERROR)
  end
  c.term = { buf = buf, job = id }
  vim.cmd('startinsert')
end

local function failed(c, err, opts)
  stop_timer(c)
  if err.kind == 'cancelled' then
    M.current = nil
    echo(c.number, 'failed', 'cancelled', true)
    local msg = ('revuey: cancelled wt switch pr:%d'):format(c.number)
    if err.path then
      msg = msg .. ('; the worktree at %s may be half set up (`wt remove %s`)'):format(err.path, vim.fn.shellescape(err.path))
    end
    return vim.notify(msg, vim.log.levels.WARN)
  end
  echo(c.number, 'failed', err.kind == 'approval' and 'needs approval' or 'failed', true)
  if err.kind ~= 'approval' then
    M.current = nil
    return vim.notify(pr.failure_message(c.number, err), vim.log.levels.ERROR)
  end
  -- wt asks before running a repo's project hooks the first time, and refuses without a
  -- terminal. revuey never passes --yes: the user approves in wt's own prompt.
  c.job = nil
  local items = { 'Run wt switch in a terminal (it asks there)', 'Cancel' }
  local prompt = table.concat({
    ('worktrunk needs your approval to run this repo\'s project hooks for PR #%d:'):format(c.number),
    table.concat(vim.tbl_map(function(x)
      return '  ' .. x
    end, err.commands or {}), '\n'),
  }, '\n')
  vim.ui.select(items, { prompt = prompt }, function(_, idx)
    if M.current ~= c then
      return
    end
    if idx == 1 then
      return M.run_in_terminal(c, opts)
    end
    M.current = nil
    vim.notify(pr.failure_message(c.number, err), vim.log.levels.WARN)
  end)
end

---Stop the running setup (background wt or the terminal). Returns false when none runs.
function M.cancel()
  local c = M.current
  if not c then
    return false
  end
  stop_timer(c)
  if c.job then
    c.job:cancel() -- on_done reports it
  else
    M.current = nil
    if c.term then
      pcall(vim.fn.jobstop, c.term.job)
    end
    echo(c.number, 'failed', 'cancelled', true)
    vim.notify(('revuey: cancelled wt switch pr:%d'):format(c.number), vim.log.levels.WARN)
  end
  return true
end

---`:Revuey pr <N|url|cancel>` (and `require('revuey').pr`).
---@param arg? string
---@param opts? {cwd?:string, on_open?:fun(session)}
function M.command(arg, opts)
  opts = opts or {}
  if arg == 'cancel' then
    if not M.cancel() then
      vim.notify('revuey: no PR worktree is being set up', vim.log.levels.INFO)
    end
    return
  end
  if M.current then
    return vim.notify(
      ('revuey: PR #%d is still being set up (:Revuey pr cancel stops it)'):format(M.current.number),
      vim.log.levels.WARN
    )
  end
  local p, perr = pr.parse_arg(arg)
  if not p then
    return vim.notify('revuey: ' .. perr .. ' (:Revuey pr <number|url>, or :Revuey pr cancel)', vim.log.levels.ERROR)
  end
  local cmd = config.options.worktrunk.cmd
  if vim.fn.executable(cmd) ~= 1 then
    return vim.notify(
      ('revuey: `%s` (worktrunk) not found on PATH: install it (https://worktrunk.dev) or set worktrunk.cmd'):format(cmd),
      vim.log.levels.ERROR
    )
  end
  -- claimed before the first yield, so a second :Revuey pr meanwhile is refused
  local c = { number = p.number, started = vim.uv.hrtime() }
  M.current = c
  git.async(function()
    local root = git.root(opts.cwd or vim.fn.getcwd())
    local err
    if not root then
      err = 'not inside a git repository: run :Revuey pr from a clone of the PR\'s repo'
    elseif p.repo then
      local forge = require('revuey.forge')
      local hosts = config.options.forge.hosts
      local info = forge.remote_info(root, hosts)
      local base = forge.base_remote(git.default_branch(root), info)
      err = pr.check_repo(p, base and info.remotes[base].repo)
    end
    if err then
      M.current = nil
      return vim.notify('revuey: ' .. err, vim.log.levels.ERROR)
    end
    if M.current ~= c then
      return -- cancelled meanwhile
    end
    c.root = root
    echo(c.number, 'running', M.status_text(c))
    c.job = pr.run({
      cmd = cmd,
      number = p.number,
      cwd = root,
      on_line = function()
        if M.current == c then
          echo(c.number, 'running', M.status_text(c))
        end
      end,
      on_done = function(e, result)
        if M.current ~= c then
          return
        end
        stop_timer(c)
        if e then
          return failed(c, e, opts)
        end
        ready(c, result, opts)
      end,
    })
    if not c.job.done then
      c.timer = vim.uv.new_timer()
      c.timer:start(1000, 1000, vim.schedule_wrap(function()
        if M.current == c and c.timer then
          echo(c.number, 'running', M.status_text(c))
        end
      end))
    end
  end, function(e)
    if M.current == c then
      M.current = nil
    end
    vim.schedule(function()
      vim.notify('revuey: ' .. tostring(e), vim.log.levels.ERROR)
    end)
  end)
end

-- A progress UI's cancel (status = 'cancel' on our message) stops the run.
api.nvim_create_autocmd('Progress', {
  group = api.nvim_create_augroup('revuey_pr', { clear = true }),
  pattern = 'revuey',
  callback = function(ev)
    local d = ev.data or {}
    if d.id == PROGRESS_ID and d.status == 'cancel' then
      M.cancel()
    end
  end,
})

return M
