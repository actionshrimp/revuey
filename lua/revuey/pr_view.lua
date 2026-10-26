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

---The one PR setup at a time: {number, job? (background run), term? {buf, job, out}, timer?}
---@type table?
M.current = nil

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

local function ready(c, result, opts)
  M.current = nil
  echo(c.number, 'success', ('worktree %s%s'):format(result.path, result.action == 'existing' and ' (existing)' or ''), true)
  require('revuey.view').open({ cwd = result.path, tcd = true, on_ready = opts.on_open })
end

---Done with the approval terminal: its autocmds, its output file, and (`close`) its window and
---buffer; wiping a terminal buffer stops its job, so wt stops when it still runs (`close` is
---false only after wt exited, keeping its output on screen).
local function close_term(c, close)
  local t = c.term
  if not t then
    return
  end
  c.term = nil
  t.closing = true
  pcall(api.nvim_del_augroup_by_id, t.group)
  vim.fn.delete(t.out)
  if close then
    for _, w in ipairs(vim.fn.win_findbuf(t.buf)) do
      if #api.nvim_list_wins() > 1 then
        pcall(api.nvim_win_close, w, true)
      end
    end
    if api.nvim_buf_is_valid(t.buf) then
      pcall(api.nvim_buf_delete, t.buf, { force = true })
    end
  end
end

---Run `wt switch` in a terminal split, where wt can ask for approval (its own prompt, the
---user's answer); on success the review opens as after a background run. A failed run leaves
---the terminal open with wt's output. Closing the terminal while wt runs (`:q` on its last
---window, `:bd!`) stops wt: nobody could answer its prompt any more. Hiding it (another
---buffer in its window) does not; `:Revuey pr` shows it again (M.show_terminal).
---@param c table M.current
function M.run_in_terminal(c, opts)
  local out = vim.fn.tempname()
  vim.cmd('botright 15new')
  local buf = api.nvim_get_current_buf()
  local cmd = config.options.worktrunk.cmd
  local t = { buf = buf, out = out, group = api.nvim_create_augroup('revuey_pr_term_' .. buf, { clear = true }) }
  c.term = t
  local ok, id = pcall(vim.fn.jobstart, pr.term_argv(cmd, c.number, out), {
    term = true,
    cwd = c.root,
    on_exit = function(_, code)
      vim.schedule(function()
        if M.current ~= c or c.term ~= t then
          return -- cancelled, or its terminal was closed
        end
        local text = vim.uv.fs_stat(out) and table.concat(vim.fn.readfile(out), '\n') or ''
        local result = code == 0 and pr.parse_result(text)
        if not result then
          close_term(c, false)
          M.current = nil
          echo(c.number, 'failed', ('wt switch pr:%d failed (exit %d)'):format(c.number, code), true)
          return vim.notify(
            ('revuey: wt switch pr:%d failed (exit %d); its output is in the terminal'):format(c.number, code),
            vim.log.levels.ERROR
          )
        end
        close_term(c, true)
        ready(c, result, opts)
      end)
    end,
  })
  if not ok or id <= 0 then
    close_term(c, true)
    M.current = nil
    return vim.notify('revuey: could not start ' .. cmd .. ' in a terminal: ' .. tostring(id), vim.log.levels.ERROR)
  end
  t.job = id
  local function closed()
    if t.closing or M.current ~= c or c.term ~= t then
      return
    end
    vim.schedule(function()
      if M.current ~= c or c.term ~= t then
        return
      end
      close_term(c, true)
      M.current = nil
      echo(c.number, 'failed', 'terminal closed', true)
      vim.notify(
        ('revuey: stopped wt switch pr:%d: its terminal was closed (:Revuey pr %d starts again)'):format(c.number, c.number),
        vim.log.levels.WARN
      )
    end)
  end
  -- unloaded or wiped (`:bd!`), or its last window closed (`:q`): stop wt. Switching buffers
  -- in its window (`:e .config/wt.toml` to read the hooks first, `<C-^>`) only hides it, and
  -- wt keeps waiting; `:Revuey pr` shows it again.
  api.nvim_create_autocmd({ 'BufUnload', 'BufWipeout' }, { group = t.group, buffer = buf, callback = closed })
  api.nvim_create_autocmd('WinClosed', {
    group = t.group,
    callback = function(ev)
      local win = tonumber(ev.match)
      if not (win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf) then
        return
      end
      for _, w in ipairs(vim.fn.win_findbuf(buf)) do
        if w ~= win then
          return
        end
      end
      closed()
    end,
  })
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

---Show the approval terminal of the running setup again (in a split) when no window shows it.
---Returns true when there is one.
function M.show_terminal()
  local t = M.current and M.current.term
  if not (t and api.nvim_buf_is_valid(t.buf)) then
    return false
  end
  local wins = vim.fn.win_findbuf(t.buf)
  if #wins > 0 then
    api.nvim_set_current_win(wins[1])
  else
    vim.cmd('botright 15split')
    api.nvim_win_set_buf(0, t.buf)
  end
  vim.cmd('startinsert')
  return true
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
    close_term(c, true)
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
  if M.current and M.show_terminal() then
    return vim.notify(
      ('revuey: PR #%d waits for your answer in its terminal (:Revuey pr cancel stops it)'):format(M.current.number),
      vim.log.levels.INFO
    )
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
      local hosts = config.options.forge.hosts
      err = pr.check_repo(p, pr.wt_repo(root, config.options.forge.cmd, hosts), hosts)
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
