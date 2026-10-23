-- Ignored branches for stack notes: glob patterns from the config (`stack.ignore_branches`) plus a
-- per-repo list persisted in the state dir (never in git config, so nothing is written to the
-- user's repo). Ignoring only hides notes about related branches outside the stack; it never
-- changes which local branches are layers (matching remote-tracking branches are never made
-- layers, see stack.remote_layers). Pure data layer: no UI calls.
local M = {}

---Lua pattern for a branch glob: `*` matches any characters (including `/`), `?` one character;
---everything else is literal.
function M.to_pattern(glob)
  local out = { '^' }
  for ch in glob:gmatch('.') do
    if ch == '*' then
      if out[#out] ~= '.*' then
        out[#out + 1] = '.*'
      end
    elseif ch == '?' then
      out[#out + 1] = '.'
    else
      out[#out + 1] = (ch:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]', '%%%0'))
    end
  end
  out[#out + 1] = '$'
  return table.concat(out)
end

---First pattern (in order) that matches `branch`, or nil.
---@param patterns string[]
---@param branch string
---@return string?
---Does one glob match? A `**/` may also match nothing (`**/x` matches `x`).
local function glob_match(p, branch)
  if p == branch or branch:match(M.to_pattern(p)) then
    return true
  end
  local i = p:find('**/', 1, true)
  return i ~= nil and glob_match(p:sub(1, i - 1) .. p:sub(i + 3), branch)
end

function M.match(patterns, branch)
  for _, p in ipairs(patterns or {}) do
    if glob_match(p, branch) then
      return p
    end
  end
end

---A glob covering a branch and its close siblings, never broader than the branch's own leaf
---prefix (never just `dave/*`): up to the leaf's first token with a digit, like a ticket number
---(`dave/abc-1058-apply-price-check` -> `dave/abc-1058-*`), else up to the leaf's last `-`
---(`a/b/c-d-e` -> `a/b/c-d-*`). A leaf without `-` is suggested as the exact name.
function M.suggest(branch)
  local dir, leaf = branch:match('^(.*/)([^/]*)$')
  dir, leaf = dir or '', leaf or branch
  local tokens = vim.split(leaf, '-', { plain = true })
  if #tokens < 2 or tokens[1] == '' then
    return branch
  end
  local keep = #tokens - 1
  for i = 1, #tokens - 1 do
    if tokens[i]:find('%d') then
      keep = i
      break
    end
  end
  return dir .. table.concat(vim.list_slice(tokens, 1, keep), '-') .. '-*'
end

---How many of `branches` a glob matches.
function M.count(pattern, branches)
  local n = 0
  for _, b in ipairs(branches) do
    if glob_match(pattern, b) then
      n = n + 1
    end
  end
  return n
end

---State file holding a repo's ignore list. `repo` is the git common dir (shared by worktrees).
function M.file_for(dir, repo)
  local name = vim.fs.basename(vim.fs.dirname(repo)) or 'repo'
  local slug = name:gsub('[^%w%-_.]', '_')
  return vim.fs.joinpath(dir, 'stack-ignore-' .. slug .. '-' .. vim.fn.sha256(repo):sub(1, 12) .. '.json')
end

local backup_seq = 0

---Persisted patterns for a repo ({} when missing). An unreadable file is moved aside to
---`<file>.corrupt-*` (like review state) rather than silently overwritten later.
---@return string[]
function M.read(dir, repo)
  local path = M.file_for(dir, repo)
  local fd = io.open(path, 'r')
  if not fd then
    return {}
  end
  local text = fd:read('*a')
  fd:close()
  local ok, data = pcall(vim.json.decode, text)
  local list = {}
  if ok and type(data) == 'table' and type(data.patterns) == 'table' then
    for _, p in ipairs(data.patterns) do
      if type(p) == 'string' and p ~= '' then
        list[#list + 1] = p
      end
    end
  elseif text ~= '' then
    backup_seq = backup_seq + 1
    os.rename(path, ('%s.corrupt-%d-%d-%d'):format(path, os.time(), vim.fn.getpid(), backup_seq))
  end
  return list
end

---Add and/or remove patterns. Re-reads the file and applies only these changes, so concurrent
---instances don't drop each other's patterns; writes a temp file and renames it.
---@param o {add?:string[], remove?:string[]}
---@return string[] patterns after the change
function M.update(dir, repo, o)
  vim.fn.mkdir(dir, 'p')
  return require('revuey.lock').with(M.file_for(dir, repo), function()
    return M._update_locked(dir, repo, o)
  end)
end

function M._update_locked(dir, repo, o)
  local remove = {}
  for _, p in ipairs(o.remove or {}) do
    remove[p] = true
  end
  local out, seen = {}, {}
  local function keep(p)
    if not seen[p] and not remove[p] then
      seen[p] = true
      out[#out + 1] = p
    end
  end
  for _, p in ipairs(M.read(dir, repo)) do
    keep(p)
  end
  for _, p in ipairs(o.add or {}) do
    keep(p)
  end
  vim.fn.mkdir(dir, 'p')
  local path = M.file_for(dir, repo)
  local tmp = path .. '.tmp.' .. vim.fn.getpid() .. '.' .. vim.uv.hrtime()
  local fd, err = io.open(tmp, 'w')
  if not fd then
    error('revuey: cannot write the ignore list: ' .. tostring(err))
  end
  local wok, werr = fd:write(vim.json.encode({ version = 1, repo = repo, patterns = out }))
  local cok, cerr = fd:close()
  if not wok or not cok then
    os.remove(tmp)
    error('revuey: cannot write the ignore list: ' .. tostring(werr or cerr))
  end
  local ok, rerr = os.rename(tmp, path)
  if not ok then
    os.remove(tmp)
    error('revuey: cannot write the ignore list: ' .. tostring(rerr))
  end
  return out
end

---Config patterns, then persisted ones (deduplicated), each with its source.
---@param config_patterns? string[]
---@param dir string state dir
---@param repo? string repo key (git common dir)
---@return {pattern:string, source:'config'|'repo'}[]
function M.effective(config_patterns, dir, repo)
  local out, seen = {}, {}
  for _, p in ipairs(config_patterns or {}) do
    if type(p) == 'string' and p ~= '' and not seen[p] then
      seen[p] = true
      out[#out + 1] = { pattern = p, source = 'config' }
    end
  end
  for _, p in ipairs(repo and M.read(dir, repo) or {}) do
    if not seen[p] then
      seen[p] = true
      out[#out + 1] = { pattern = p, source = 'repo' }
    end
  end
  return out
end

---Plain pattern list of `effective()` entries.
function M.patterns(entries)
  return vim.tbl_map(function(e)
    return e.pattern
  end, entries)
end

local common_dirs = {}

---Repo key for the ignore list: the git common dir of the repo at `root` (so all worktrees of a
---repo share it). Cached per root.
---@return string?
function M.repo_key(root)
  if not root then
    return nil
  end
  if common_dirs[root] == nil then
    local out = require('revuey.git').git({ 'rev-parse', '--path-format=absolute', '--git-common-dir' }, root)
    common_dirs[root] = out and vim.fs.normalize(vim.trim(out)) or false
  end
  return common_dirs[root] or nil
end

---The effective ignore list for the repo at `root`, using the plugin config and state dir.
---@param state_dir? string overrides the configured state dir
function M.for_root(root, state_dir)
  local config = require('revuey.config').options
  local dir = state_dir or config.state_dir or require('revuey.state').default_dir()
  return M.effective((config.stack or {}).ignore_branches, dir, M.repo_key(root)), dir, M.repo_key(root)
end

return M
