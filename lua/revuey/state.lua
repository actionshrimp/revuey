-- Persistent review state (reviewed marks). Pure data layer: JSON files, no UI calls.
--
-- One JSON file per review target, under `stdpath('data')/revuey/` by default, keyed by
-- repo root + branch + base. Each reviewed file stores the content key of its diff at the time it
-- was marked (the new blob hash, or the old blob hash for deletions); if the branch changes that
-- file, the key no longer matches and the mark is automatically treated as unreviewed.
--
-- Version 2 adds `units`: marks on review units (see units.lua), keyed by the unit's content
-- key, so editing one hunk resets only that hunk. File marks stay: a file without hunks is marked
-- as a whole, and a file whose every unit is reviewed also gets its file mark (layer stats count
-- those). `sections` (guide section marks by identity) is the version 1 format, only read and
-- converted to unit marks.
local M = {}

M.VERSION = 2

---@class revuey.State
---@field version integer
---@field repo string
---@field branch string
---@field base string
---@field files table<string, {key:string, reviewed_at:integer}>
---@field sections table<string, {reviewed_at:integer}> legacy guide section marks, by section identity
---@field units table<string, {path:string, reviewed_at:integer}> unit (and parent hunk) marks, by key
---@field _path string

function M.default_dir()
  return vim.fs.joinpath(vim.fn.stdpath('data'), 'revuey')
end

---Filename for a review target: readable slug + short hash of the full key.
function M.file_for(dir, repo, branch, base)
  local key = table.concat({ repo, branch, base }, '\0')
  local slug = (vim.fs.basename(repo) .. '-' .. branch .. '-' .. base):gsub('[^%w%-_.]', '_')
  return vim.fs.joinpath(dir, slug .. '-' .. vim.fn.sha256(key):sub(1, 12) .. '.json')
end

---Content key for a file diff: identifies the reviewed version of the file.
---With `with_old` the old side is part of the key too (stack layers above another layer: if the
---parent layer changes the file, the child's diff changes even though its new side did not).
---@param f {status:string, old_blob?:string, new_blob?:string, old_mode?:string, new_mode?:string}
---@param with_old? boolean
function M.content_key(f, with_old)
  if with_old then
    return M.content_key(f) .. '<' .. (f.old_blob or '-')
  end
  if f.new_blob then
    return f.new_blob .. (f.new_mode and (':' .. f.new_mode) or '')
  end
  if f.old_blob then
    return 'deleted:' .. f.old_blob
  end
  return 'empty:' .. (f.status or '?')
end

---Strip remote/ref prefixes so `origin/main`, `refs/remotes/origin/main` and `main` name the
---same review target.
---@param base string
---@param remotes string[] configured remote names
function M.normalize_base(base, remotes)
  base = base:gsub('^refs/heads/', ''):gsub('^refs/remotes/', '')
  for _, r in ipairs(remotes or {}) do
    if vim.startswith(base, r .. '/') then
      return base:sub(#r + 2)
    end
  end
  return base
end

local backup_seq = 0

---Read the files, sections and units tables from disk. Returns {} when missing; backs up
---undecodable files.
local function read_files(path)
  local fd = io.open(path, 'r')
  if not fd then
    return {}, {}, {}
  end
  local text = fd:read('*a')
  fd:close()
  local ok, data = pcall(vim.json.decode, text)
  if ok and type(data) == 'table' and type(data.files) == 'table' then
    local function tbl(v)
      return type(v) == 'table' and v or {}
    end
    return data.files, tbl(data.sections), tbl(data.units)
  end
  if text ~= '' then
    -- keep the unreadable file for inspection instead of silently overwriting it later
    backup_seq = backup_seq + 1
    local backup = ('%s.corrupt-%d-%d-%d'):format(path, os.time(), vim.fn.getpid(), backup_seq)
    os.rename(path, backup)
  end
  return {}, {}, {}
end

---@return revuey.State
function M.load(dir, repo, branch, base)
  local path = M.file_for(dir, repo, branch, base)
  local files, sections, units = read_files(path)
  return {
    version = M.VERSION,
    repo = repo,
    branch = branch,
    base = base,
    files = files,
    sections = sections,
    units = units,
    _path = path,
    _changes = {},
    _section_changes = {},
    _unit_changes = {},
  }
end

---Persist: re-read the file and apply only this instance's changes, so concurrent instances of
---the same review don't clobber each other. Marks are merged per path *and* content key: an
---unmark only removes the version this instance unmarked, never a newer mark from elsewhere.
---Every write step is checked; pending changes are kept until the rename succeeded.
---Refreshes `st.files` with the merged result. Errors on failure.
---@param st revuey.State
function M.save(st)
  local dir = vim.fs.dirname(st._path)
  vim.fn.mkdir(dir, 'p')
  -- read, merge and rename under a lock: two processes saving at once must not both start
  -- from the old file (the last rename would drop the other's change)
  return require('revuey.lock').with(st._path, function()
    return M._save_locked(st)
  end)
end

function M._save_locked(st)
  local files, sections, units = read_files(st._path)
  for path, ch in pairs(st._changes or {}) do
    if ch.entry then
      files[path] = ch.entry
    elseif files[path] and files[path].key == ch.key then
      files[path] = nil
    end
  end
  -- guide sections: keyed by content identity, so a plain set/unset merges safely
  for id, entry in pairs(st._section_changes or {}) do
    sections[id] = entry or nil
  end
  -- units: keyed by content, so a plain set/unset merges safely too
  for key, entry in pairs(st._unit_changes or {}) do
    units[key] = entry or nil
  end
  -- derived marks (units.lua: parent hunk keys, file marks of complete files) are computed from
  -- the merged result, so one instance's stale memory never decides them
  if st._finalize then
    st._finalize(files, units, st)
  end
  local data = {
    version = M.VERSION,
    repo = st.repo,
    branch = st.branch,
    base = st.base,
    files = files,
    sections = sections,
    units = units,
  }
  if next(data.files) == nil then
    data.files = vim.empty_dict()
  end
  if next(data.sections) == nil then
    data.sections = nil
  end
  if next(data.units) == nil then
    data.units = nil
  end
  local tmp = st._path .. '.tmp.' .. vim.fn.getpid()
  local fd, err = io.open(tmp, 'w')
  if not fd then
    error('revuey: cannot write review state: ' .. tostring(err))
  end
  local ok, werr = fd:write(vim.json.encode(data))
  local cok, cerr = fd:close()
  if not ok or not cok then
    os.remove(tmp)
    error('revuey: cannot write review state: ' .. tostring(werr or cerr))
  end
  local rok, rerr = os.rename(tmp, st._path)
  if not rok then
    os.remove(tmp)
    error('revuey: cannot write review state: ' .. tostring(rerr))
  end
  st._changes = {}
  st._section_changes = {}
  st._unit_changes = {}
  st.files = vim.deepcopy(files)
  st.sections = vim.deepcopy(sections)
  st.units = vim.deepcopy(units)
end

---@param st revuey.State
function M.is_reviewed(st, path, key)
  local e = st.files[path]
  return e ~= nil and e.key == key
end

---@param st revuey.State
function M.set_reviewed(st, path, key, value)
  local entry = value and { key = key, reviewed_at = os.time() } or nil
  st.files[path] = entry
  st._changes = st._changes or {}
  st._changes[path] = { key = key, entry = entry or false }
end

---Toggle and persist. Returns the new reviewed value, plus an error message if saving failed
---(the change stays pending in memory and is retried on the next save).
---@param st revuey.State
function M.toggle(st, path, key)
  local v = not M.is_reviewed(st, path, key)
  M.set_reviewed(st, path, key, v)
  local ok, err = pcall(M.save, st)
  if not ok then
    st.files[path] = v and { key = key, reviewed_at = os.time() } or nil
    return v, err
  end
  return v
end

---Unit (or parent hunk) mark by key (see units.lua). In memory only until `save`.
---@param st revuey.State
function M.unit_marked(st, key)
  return key ~= nil and (st.units or {})[key] ~= nil
end

---@param st revuey.State
---@param key string unit or hunk key
---@param path string file path (kept with the mark for readability and cleanup)
---An unmark is always recorded, even when this instance never saw the mark: another instance
---may have stored it since this one last read the file.
function M.set_unit(st, key, path, value)
  st.units = st.units or {}
  if value and st.units[key] ~= nil then
    return false
  end
  local entry = value and { path = path, reviewed_at = os.time() } or false
  st.units[key] = entry or nil
  st._unit_changes = st._unit_changes or {}
  st._unit_changes[key] = entry
  return true
end

---Forget a legacy section mark (after converting it to unit marks). In memory until `save`.
---@param st revuey.State
function M.drop_section(st, id)
  if st.sections and st.sections[id] ~= nil then
    st.sections[id] = nil
    st._section_changes = st._section_changes or {}
    st._section_changes[id] = false
    return true
  end
  return false
end

---Legacy guide section reviewed state (see guide.section_id), version 1 of the format.
---@param st revuey.State
function M.section_reviewed(st, id)
  return id ~= nil and (st.sections or {})[id] ~= nil
end

---Toggle and persist a section's reviewed state. Returns the new value (+ error on save failure).
---@param st revuey.State
function M.toggle_section(st, id)
  local v = not M.section_reviewed(st, id)
  local entry = v and { reviewed_at = os.time() } or false
  st.sections = st.sections or {}
  st.sections[id] = entry or nil
  st._section_changes = st._section_changes or {}
  st._section_changes[id] = entry
  local ok, err = pcall(M.save, st)
  if not ok then
    st.sections[id] = entry or nil
    return v, err
  end
  return v
end

return M
