-- Builds the review model (git + diff + state). No window/buffer UI.
local git = require('revuey.git')
local diff = require('revuey.diff')
local state = require('revuey.state')
local config = require('revuey.config')

local M = {}
local cap_large -- defined below

---@class revuey.Review
---@field root string
---@field branch string        current branch name (or "HEAD" when detached)
---@field base string          base ref as given/detected (e.g. "main", "origin/main")
---@field merge_base string
---@field head string          HEAD commit
---@field files revuey.FileDiff[]
---@field state revuey.State
---@field dirty boolean        working tree has uncommitted changes to tracked files
---@field mode 'worktree'|'committed'
---@field signature string     changes whenever the review content would change (refresh skips if equal)

---Replace a file's hunks with a placeholder when its diff is larger than `cap` bytes.
cap_large = function(f, cap)
  local bytes = 0
  for _, hk in ipairs(f.hunks) do
    for _, l in ipairs(hk.lines) do
      bytes = bytes + #l.text + 1
    end
  end
  if bytes > cap then
    f.hunks = {}
    f.note = ('Large diff (%d KB), not shown'):format(math.floor(bytes / 1024))
  end
end

local function stat_sig(st)
  return st and table.concat({ st.type, st.size, st.mtime.sec, st.mtime.nsec, st.ino, st.mode }, ':') or '-'
end

local function file_mode(st)
  if st.type == 'link' then
    return '120000'
  end
  return (st.mode % 512 >= 64 and math.floor(st.mode / 64) % 2 == 1) and '100755' or '100644'
end

---Working-tree side of a review: snapshot tracked files' new side, and build entries for
---untracked files. `cache` (kept per review session) holds per-path stat signatures, so
---unchanged files are neither re-read nor re-hashed on refresh.
---@return revuey.FileDiff[] extra untracked entries
---@return string signature
---@return boolean retry snapshot disagrees with the diff (file saved meanwhile)
function M.load_worktree(root, files, cache, cap, mb)
  cache.snap = cache.snap or {}
  cache.untracked = cache.untracked or {}
  local changed = git.changed_vs_head(root)
  -- files git filters on the way in (lfs, ident, custom clean filters): disk bytes differ from
  -- the diff's new side, so their snapshot comes from git, not from disk
  local candidates = {}
  for _, f in ipairs(files) do
    if f.status ~= 'D' and #f.hunks > 0 then
      candidates[#candidates + 1] = f.path
    end
  end
  local filtered = git.filtered_paths(candidates, root)
  local keep_snap = {}
  local need, need_set = {}, {}
  local function want_hash(path, setter)
    need[#need + 1] = path
    need_set[#need] = setter
  end
  local retry = false
  for _, f in ipairs(files) do
    f.uncommitted = changed[f.path] or (f.old_path and changed[f.old_path]) or nil
    if f.status ~= 'D' then
      f.worktree = true
      local abs = vim.fs.joinpath(root, f.path)
      local st = vim.uv.fs_lstat(abs)
      if st and st.type == 'file' and st.size > cap then
        f.hunks = {}
        f.note = f.note or ('Large file (%d KB), not shown'):format(math.floor(st.size / 1024))
      elseif st and not f.binary and #f.hunks > 0 then
        -- Snapshot the reviewed new side: highlighting and LSP mapping must use the displayed
        -- text even if the file changes before the next refresh.
        local sig = stat_sig(st)
        local c = cache.snap[f.path]
        keep_snap[f.path] = true
        if not (c and c.sig == sig) then
          local text
          if filtered[f.path] then
            text = M.full_new_side(root, mb, f.path)
          else
            text = st.type == 'link' and (vim.uv.fs_readlink(abs) or '') or git.read_file(abs)
          end
          c = { sig = sig, text = text }
          cache.snap[f.path] = c
        end
        f.new_text = c.text
        -- the hunks must agree with the snapshot; otherwise it was saved in between
        if c.text and not filtered[f.path] then
          local lines = vim.split(c.text:gsub('\r\n', '\n'), '\n', { plain = true })
          for _, hk in ipairs(f.hunks) do
            for _, l in ipairs(hk.lines) do
              if l.new_lnum and lines[l.new_lnum] ~= l.text then
                retry = true
              end
            end
          end
        end
      end
      if not f.new_blob and st and st.type == 'file' then
        want_hash(f.path, function(hsh)
          f.new_blob = hsh
        end)
      end
    end
  end

  local extra, sig_parts = {}, {}
  local fresh = {}
  local untracked = git.untracked(root)
  cache.untracked_list = table.concat(untracked, '\0')
  for _, path in ipairs(untracked) do
    local abs = vim.fs.joinpath(root, path)
    local st = vim.uv.fs_lstat(abs)
    local sig = stat_sig(st)
    local c = cache.untracked[path]
    local f
    if c and c.sig == sig then
      f = vim.deepcopy(c.file)
    elseif path:sub(-1) == '/' then
      f = diff.placeholder(path:sub(1, -2), 'Nested git repository, not shown', nil, nil)
    elseif not st then
      f = nil -- vanished since ls-files
    elseif st.type == 'link' then
      local target = vim.uv.fs_readlink(abs) or ''
      f = diff.untracked_file(path, target, git.hash_text(target, root), '120000')
    elseif st.type ~= 'file' then
      f = diff.placeholder(path, 'Special file, not shown', nil, nil)
    elseif st.size > cap then
      f = diff.placeholder(path, ('Large file (%d KB), not shown'):format(math.floor(st.size / 1024)), nil, file_mode(st))
      fresh[#fresh + 1] = { path = path, sig = sig, file = f }
      want_hash(path, function(hsh)
        f.new_blob = hsh
      end)
    else
      f = diff.untracked_file(path, git.read_file(abs) or '', nil, file_mode(st))
      fresh[#fresh + 1] = { path = path, sig = sig, file = f }
      want_hash(path, function(hsh)
        f.new_blob = hsh
      end)
    end
    if f then
      if not fresh[#fresh] or fresh[#fresh].file ~= f then
        cache.untracked[path] = { sig = sig, file = vim.deepcopy(f) }
      end
      f.worktree, f.uncommitted = true, true
      if not f.binary and not f.note and #f.hunks > 0 then
        -- untracked content is the snapshot itself
        local t = {}
        for _, l in ipairs(f.hunks[1].lines) do
          t[#t + 1] = l.text .. (l.cr and '\r' or '')
        end
        f.new_text = table.concat(t, '\n') .. ((f.hunks[1].lines[#t].no_eol and '') or '\n')
      end
      extra[#extra + 1] = f
      sig_parts[#sig_parts + 1] = path .. '=' .. sig
    end
  end
  local hashes = git.hash_objects(need, root)
  for i, setter in ipairs(need_set) do
    setter(hashes[i])
  end
  for _, fr in ipairs(fresh) do
    cache.untracked[fr.path] = { sig = fr.sig, file = vim.deepcopy(fr.file) }
  end
  -- prune entries for paths that left the review
  local listed = {}
  for _, p in ipairs(untracked) do
    listed[p] = true
  end
  for p in pairs(cache.untracked) do
    if not listed[p] then
      cache.untracked[p] = nil
    end
  end
  for p in pairs(cache.snap) do
    if not keep_snap[p] then
      cache.snap[p] = nil
    end
  end
  return extra, table.concat(sig_parts, '\0'), retry
end

---The complete new side of a file as `git diff` sees it (after clean filters), rebuilt from a
---whole-file-context diff. Used for filtered files, whose disk bytes differ from the diff.
---@return string?
function M.full_new_side(root, mb, path)
  local out = git.git({
    'diff', '--no-color', '--no-ext-diff', '--no-textconv', '--no-renames', '--full-index',
    '--src-prefix=a/', '--dst-prefix=b/', '-U100000000', mb, '--', path,
  }, root)
  local parsed = out and diff.parse(out)[1]
  if not parsed or not parsed.hunks[1] then
    return nil
  end
  local t, no_eol = {}, false
  for _, hk in ipairs(parsed.hunks) do
    for _, l in ipairs(hk.lines) do
      if l.new_lnum then
        t[l.new_lnum] = l.text .. (l.cr and '\r' or '')
        no_eol = l.no_eol or false
      end
    end
  end
  return table.concat(t, '\n') .. (no_eol and '' or '\n')
end

---Load a review of the current branch against `base` (or the configured/detected default).
---Must run inside `git.async()` for non-blocking use; works synchronously otherwise.
---Modes:
---  worktree  (default) merge-base..working tree: committed, staged and unstaged changes to tracked
---            files, plus untracked non-ignored files as additions. New-side content is on disk.
---  committed merge-base..HEAD only.
---@param opts {cwd?:string, base?:string, state_dir?:string, context_lines?:integer, mode?:'worktree'|'committed', cache?:table}
---@return revuey.Review?, string? err
function M.load(opts)
  local cwd = opts.cwd or vim.fn.getcwd()
  local root = git.root(cwd)
  if not root then
    return nil, 'not inside a git repository: ' .. cwd
  end
  local base = opts.base
  if not base or base == '' then
    base = config.options.default_branch or git.default_branch(root)
  end
  if not base then
    return nil, 'could not detect a default branch; pass one with :Revuey <base>'
  end
  if not git.rev_parse(base, root) then
    return nil, 'unknown base revision: ' .. base
  end
  local head = git.rev_parse('HEAD', root)
  if not head then
    return nil, 'the current branch has no commits yet'
  end
  local mb = git.merge_base(base, 'HEAD', root)
  if not mb then
    return nil, ('no common ancestor between %s and HEAD (unrelated histories?); pass another base: :Revuey <base>'):format(base)
  end
  local mode = opts.mode or (config.options.uncommitted and 'worktree' or 'committed')
  local worktree = mode == 'worktree'
  local text, derr = git.diff(mb, not worktree and head or nil, root, opts.context_lines or config.options.context_lines)
  if not text then
    return nil, 'git diff failed: ' .. tostring(derr)
  end
  local cache = opts.cache or {}
  local files
  -- re-parse only when the diff text changed (no-op refreshes are cheap)
  if cache.diff_text == text and cache.diff_files then
    files = vim.deepcopy(cache.diff_files)
  else
    files = diff.parse(text)
    cache.diff_text, cache.diff_files = text, vim.deepcopy(files)
  end
  local cap = config.options.max_file_bytes
  for _, f in ipairs(files) do
    cap_large(f, cap)
  end
  local signature = { mode, head, text }
  if worktree then
    local extra, sig, retry = M.load_worktree(root, files, cache, cap, mb)
    if retry and not opts._retried then
      -- a file was saved between `git diff` and reading its snapshot: load again once
      return M.load(vim.tbl_extend('force', opts, { _retried = true }))
    end
    vim.list_extend(files, extra)
    signature[#signature + 1] = sig
    table.sort(files, function(a, b)
      return a.path < b.path
    end)
  end
  local branch = git.current_branch(root) or 'HEAD'
  -- `origin/main` and `main` are the same review target for reviewed marks
  local state_base = state.normalize_base(base, git.remotes(root))
  local st = state.load(opts.state_dir or config.options.state_dir or state.default_dir(), root, branch, state_base)
  return {
    root = root,
    branch = branch,
    base = base,
    merge_base = mb,
    head = head,
    files = files,
    state = st,
    dirty = git.is_dirty(root),
    mode = mode,
    index_path = git.git_path('index', root),
    signature = table.concat(signature, '\0'),
    untracked_list = worktree and cache.untracked_list or nil,
  }
end

---@param review revuey.Review
---@param f revuey.FileDiff
function M.is_reviewed(review, f)
  return state.is_reviewed(review.state, f.path, state.content_key(f))
end

---@param review revuey.Review
---@param f revuey.FileDiff
function M.toggle_reviewed(review, f)
  local v, err = state.toggle(review.state, f.path, state.content_key(f))
  if err then
    vim.notify(tostring(err), vim.log.levels.ERROR)
  end
  return v
end

return M
