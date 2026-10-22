-- Thin git wrapper. No UI calls, so it can be exercised with `nvim --headless -l`.
--
-- Every function works in two modes:
--   * inside a coroutine started with `M.async()` the git process runs with `vim.system` and the
--     coroutine yields until it finishes, so the editor never blocks;
--   * outside a coroutine (tests, scripts) it simply waits for the process.
local M = {}

---Run `fn` in a coroutine; errors are reported through `on_error` (default: vim.notify).
---@param fn fun()
---@param on_error? fun(err: string)
local error_handlers = setmetatable({}, { __mode = 'k' }) ---@type table<thread, fun(err: string)>

function M.async(fn, on_error)
  local co = coroutine.create(fn)
  error_handlers[co] = on_error
  local function step(...)
    local ok, err = coroutine.resume(co, ...)
    if not ok then
      err = debug.traceback(co, err)
      if on_error then
        on_error(err)
      else
        vim.schedule(function()
          vim.notify('revuey: ' .. tostring(err):gsub('^revuey: ', ''), vim.log.levels.ERROR)
        end)
      end
    end
  end
  step()
end

---@param cmd string[]
---@param opts? table vim.system options
---@return vim.SystemCompleted
function M.system(cmd, opts)
  -- text=false: keep bytes exactly (text mode would turn CRLF into LF and hide EOL changes)
  opts = vim.tbl_extend('force', { text = false }, opts or {})
  local co = coroutine.running()
  if not co then
    return vim.system(cmd, opts):wait()
  end
  vim.system(cmd, opts, function(res)
    vim.schedule(function()
      M.resume(co, res)
    end)
  end)
  return coroutine.yield()
end

---Resume a coroutine started by M.async; errors raised after a yield go to its error handler
---(so callers' cleanup always runs), or are reported.
function M.resume(co, ...)
  local ok, err = coroutine.resume(co, ...)
  if not ok then
    local handler = error_handlers[co]
    err = debug.traceback(co, err)
    if handler then
      handler(err)
    else
      vim.notify('revuey: ' .. tostring(err):gsub('^revuey: ', ''), vim.log.levels.ERROR)
    end
  end
end

---Run functions concurrently (each in its own coroutine) and wait for all of them. Returns a list
---of `{ok, ...results}` per function (ok=false plus the error when it raised). Outside a
---coroutine the functions simply run one after another.
---@param fns (fun(): any)[]
---@return table[]
function M.all(fns)
  local results = {}
  local co = coroutine.running()
  if not co then
    for i, fn in ipairs(fns) do
      results[i] = { pcall(fn) }
    end
    return results
  end
  local pending = #fns
  if pending == 0 then
    return results
  end
  local function done()
    pending = pending - 1
    if pending == 0 then
      vim.schedule(function()
        M.resume(co)
      end)
    end
  end
  for i, fn in ipairs(fns) do
    M.async(function()
      results[i] = { true, fn() }
      done()
    end, function(err)
      results[i] = { false, err }
      done()
    end)
  end
  coroutine.yield()
  return results
end

---Run git in `cwd`. Returns stdout on success, or nil + stderr.
---@param args string[]
---@param cwd string
---@return string?, string?
function M.git(args, cwd)
  local cmd = { 'git', '-c', 'core.quotepath=false', '--no-pager' }
  vim.list_extend(cmd, args)
  local res = M.system(cmd, { cwd = cwd })
  if res.code ~= 0 then
    return nil, vim.trim(res.stderr or '')
  end
  return res.stdout or ''
end

local function trim1(s)
  return s and vim.trim(s) or nil
end

---@param cwd string
---@return string? root
function M.root(cwd)
  return trim1(M.git({ 'rev-parse', '--show-toplevel' }, cwd))
end

---@return string? branch name, or nil when detached
function M.current_branch(cwd)
  local out = trim1(M.git({ 'symbolic-ref', '--quiet', '--short', 'HEAD' }, cwd))
  if out == '' then
    return nil
  end
  return out
end

function M.rev_parse(rev, cwd)
  return trim1(M.git({ 'rev-parse', '--verify', '--quiet', rev .. '^{commit}' }, cwd))
end

---Detect the default branch: origin/HEAD, else main, master, develop (local, then origin/).
---@return string?
function M.default_branch(cwd)
  local head = trim1(M.git({ 'symbolic-ref', '--quiet', 'refs/remotes/origin/HEAD' }, cwd))
  if head and head ~= '' then
    return (head:gsub('^refs/remotes/', ''))
  end
  for _, name in ipairs({ 'main', 'master', 'develop' }) do
    if M.rev_parse(name, cwd) then
      return name
    end
    if M.rev_parse('origin/' .. name, cwd) then
      return 'origin/' .. name
    end
  end
  return nil
end

---Is `a` an ancestor of (or equal to) `b`?
function M.is_ancestor(a, b, cwd)
  local res = M.system({ 'git', 'merge-base', '--is-ancestor', a, b }, { cwd = cwd })
  return res.code == 0
end

function M.merge_base(a, b, cwd)
  return trim1(M.git({ 'merge-base', a, b }, cwd))
end

---Unified diff between two commits, with full blob hashes and rename detection.
---Flags pin down everything user config could change about the output we parse: explicit
---prefixes (diff.noprefix / diff.mnemonicPrefix), no external diff or textconv filters, no colour,
---short submodule lines, and C-quoted paths only for control characters (core.quotepath=false).
---@param from string
---@param to string? nil = the working tree (tracked files: committed, staged and unstaged changes)
---@param context integer
function M.diff(from, to, cwd, context)
  local args = {
    'diff',
    '--no-color',
    '--no-ext-diff',
    '--no-textconv',
    '--submodule=short',
    '--no-relative',
    '--full-index',
    '--find-renames',
    '--src-prefix=a/',
    '--dst-prefix=b/',
    '-U' .. tostring(context or 3),
    from,
  }
  if to then
    args[#args + 1] = to
  end
  args[#args + 1] = '--'
  return M.git(args, cwd)
end

local function split0(out)
  local t = vim.split(out or '', '\0', { plain = true })
  if t[#t] == '' then
    t[#t] = nil
  end
  return t
end

---Untracked, non-ignored files (repo-relative paths, sorted).
---@return string[]
function M.untracked(cwd)
  local t = split0(M.git({ 'ls-files', '-z', '--others', '--exclude-standard' }, cwd))
  table.sort(t)
  return t
end

---Paths whose working-tree content differs from HEAD (staged, unstaged; not untracked).
---@return table<string, true>
function M.changed_vs_head(cwd)
  local set = {}
  for _, p in ipairs(split0(M.git({ 'diff', '--name-only', '-z', '--no-renames', '--no-ext-diff', '--no-textconv', 'HEAD', '--' }, cwd))) do
    set[p] = true
  end
  return set
end

---Blob hashes of working-tree *regular* files (without writing objects), in the order given.
---One batch process; if it fails (a path vanished or became unreadable), each path is hashed on
---its own so one bad path never blanks the rest. Entries that can't be hashed are nil.
---@param paths string[] repo-relative
---@return (string?)[]
function M.hash_objects(paths, cwd)
  if #paths == 0 then
    return {}
  end
  local out = M.system(
    { 'git', '-c', 'core.quotepath=false', 'hash-object', '--stdin-paths' },
    { cwd = cwd, stdin = table.concat(paths, '\n') .. '\n' }
  )
  if out.code == 0 then
    local t = vim.split(vim.trim(out.stdout or ''), '\n', { plain = true })
    if #t == #paths then
      return t
    end
  end
  local res = {}
  for i, p in ipairs(paths) do
    local one = M.system({ 'git', 'hash-object', '--', p }, { cwd = cwd })
    res[i] = one.code == 0 and vim.trim(one.stdout or '') or nil
  end
  return res
end

---Paths that git transforms on the way into the repo (a `filter` driver such as git-lfs, or
---`ident`), so their working-tree bytes differ from what `git diff` shows.
---@param paths string[]
---@return table<string, true>
function M.filtered_paths(paths, cwd)
  local set = {}
  if #paths == 0 then
    return set
  end
  local out = M.system(
    { 'git', '-c', 'core.quotepath=false', 'check-attr', '-z', '--stdin', 'filter', 'ident' },
    { cwd = cwd, stdin = table.concat(paths, '\0') .. '\0' }
  )
  if out.code ~= 0 then
    return set
  end
  local t = vim.split(out.stdout or '', '\0', { plain = true })
  for i = 1, #t - 2, 3 do
    local path, value = t[i], t[i + 2]
    if value ~= 'unspecified' and value ~= 'unset' and value ~= '' then
      set[path] = true
    end
  end
  return set
end

---Blob hash of a string (e.g. a symlink's target text, which is what git stores for links).
function M.hash_text(text, cwd)
  local out = M.system({ 'git', 'hash-object', '--stdin' }, { cwd = cwd, stdin = text })
  return out.code == 0 and vim.trim(out.stdout or '') or nil
end

---Read a file's bytes, or nil. Inside an M.async coroutine the read is asynchronous (libuv), so
---large reads never block the main loop.
function M.read_file(abs)
  local co = coroutine.running()
  if not co then
    local fd = io.open(abs, 'rb')
    if not fd then
      return nil
    end
    local data = fd:read('*a')
    fd:close()
    return data
  end
  local uv = vim.uv
  local function await(fn, ...)
    local args = { ... }
    args[#args + 1] = function(err, res)
      vim.schedule(function()
        M.resume(co, err, res)
      end)
    end
    fn(unpack(args))
    return coroutine.yield()
  end
  local err, fd = await(uv.fs_open, abs, 'r', 438)
  if err or not fd then
    return nil
  end
  local serr, st = await(uv.fs_fstat, fd)
  local data
  if not serr and st then
    local rerr, d = await(uv.fs_read, fd, st.size, 0)
    data = not rerr and d or nil
  end
  await(uv.fs_close, fd)
  return data
end

---Contents of a blob by hash (nil for the null hash).
---@return string?
function M.blob(hash, cwd)
  if not hash or hash:match('^0+$') then
    return nil
  end
  return M.git({ 'cat-file', 'blob', hash }, cwd)
end

---Absolute path of a file inside the git dir (handles worktrees / .git files).
function M.git_path(name, cwd)
  local out = trim1(M.git({ 'rev-parse', '--path-format=absolute', '--git-path', name }, cwd))
  return out ~= '' and out or nil
end

---Configured remote names.
---@return string[]
function M.remotes(cwd)
  local out = M.git({ 'remote' }, cwd) or ''
  return vim.split(vim.trim(out), '\n', { trimempty = true })
end

---Has the working tree got uncommitted changes to tracked files?
function M.is_dirty(cwd)
  local out = M.git({ 'status', '--porcelain', '--untracked-files=no' }, cwd)
  return out ~= nil and out ~= ''
end

return M
