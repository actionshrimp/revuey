-- Review units: the atomic reviewable pieces of a review, and their reviewed marks. Pure data
-- (no window or buffer UI).
--
-- Today a unit is one diff hunk. A planned feature will cut large hunks into several units at
-- tree-sitter or blank-line boundaries (`h7a`, `h7b`), so nothing outside this module may assume
-- one unit = one hunk: marks, progress and the guide's hunk references all go through here.
--
--   * Keys. A unit's key is the content hash of its lines (path, +/-/space prefixes, text and
--     line-ending flags; not line numbers), exactly the guide's hunk anchor hash, so a guide hunk
--     id maps 1:1 to a unit key today. Identical content in one review is told apart by
--     `@old_start,new_start`, like the guide does. A piece of a split hunk is keyed by its own
--     lines the same way.
--   * Parent hunk. Every unit records the key of the hunk it belongs to (its own key when the
--     hunk is not split). A mark on the hunk key covers all of its pieces, so changing how hunks
--     are split never loses review work; marking every piece of a hunk stores the hunk key too.
--   * Files without hunks (binary, placeholders, pure renames, mode-only changes) have one
--     whole-file unit whose mark is the file-level mark, keyed by the file's content key as before.
--   * Coverage. A unit is reviewed when its own key, its parent hunk's key, or a matching file
--     mark is set. A file whose units are all reviewed gets its file mark too (so layer stats,
--     which only see `git diff --raw` content keys, can count complete files), and unmarking
--     anything inside a covered file or hunk first spells the coverage out as unit marks.
--   * Derived state: a file or guide section is reviewed when all of its units are.
local guide = require('revuey.guide')
local state = require('revuey.state')

local M = {}

---@class revuey.Unit
---@field key string          content key (stored in the state's `units`)
---@field hunk string         parent hunk key (the guide hunk hash)
---@field file_idx integer
---@field hunk_idx? integer   nil for a whole-file unit
---@field path string
---@field file_key string     the file's content key (state.content_key, per scope)
---@field whole_file boolean  a file without hunks: the mark is the file mark
---@field first? integer      first hunk line covered (hunk units)
---@field last? integer       last hunk line covered

---@class revuey.Units
---@field list revuey.Unit[]                       diff order
---@field by_file table<integer, revuey.Unit[]>
---@field by_hunk table<string, revuey.Unit[]>     by parent hunk key
---@field by_key table<string, revuey.Unit>        by unit key
---@field by_path table<string, integer>           path -> file index
---@field hunk_key table<integer, table<integer, string>> [file_idx][hunk_idx or 0] = hunk key
---@field hunks revuey.GuideHunk[]                 the guide's hunk entries (ids, anchors)

---Derive the units of a review's files.
---@param files revuey.FileDiff[]
---@param opts? {key_old?:boolean, split?:fun(f:revuey.FileDiff, h:revuey.Hunk, hunk_idx:integer):({first:integer, last:integer}[])?}
---  `key_old`: file content keys include the old side (stack layers above a layer).
---  `split`: cut a hunk into pieces (line ranges covering it in order); nil or one piece = whole.
---@return revuey.Units
function M.derive(files, opts)
  opts = opts or {}
  local hunks = guide.hunks(files)
  local U = { list = {}, by_file = {}, by_hunk = {}, by_key = {}, by_path = {}, hunk_key = {}, hunks = hunks }
  local file_keys = {}
  for fi, f in ipairs(files) do
    file_keys[fi] = state.content_key(f, opts.key_old)
    U.by_file[fi] = {}
    U.by_path[f.path] = fi
    U.hunk_key[fi] = {}
  end
  local count = {}
  local function add(u)
    U.list[#U.list + 1] = u
    table.insert(U.by_file[u.file_idx], u)
    U.by_hunk[u.hunk] = U.by_hunk[u.hunk] or {}
    table.insert(U.by_hunk[u.hunk], u)
    count[u.key] = (count[u.key] or 0) + 1
  end
  local pieces = {}
  for _, gh in ipairs(hunks) do
    local fi = gh.file_idx
    local f = files[fi]
    U.hunk_key[fi][gh.hunk_idx or 0] = gh.hash
    local base = { hunk = gh.hash, file_idx = fi, hunk_idx = gh.hunk_idx, path = f.path, file_key = file_keys[fi], whole_file = false }
    if not gh.hunk_idx then
      base.key, base.whole_file = gh.hash, true
      add(base)
    else
      local hk = f.hunks[gh.hunk_idx]
      local cuts = opts.split and opts.split(f, hk, gh.hunk_idx)
      if not cuts or #cuts <= 1 then
        base.key, base.first, base.last = gh.hash, 1, #hk.lines
        add(base)
      else
        for _, c in ipairs(cuts) do
          local raw = {}
          for li = c.first, c.last do
            raw[#raw + 1] = guide.raw_line(hk.lines[li])
          end
          local u = vim.deepcopy(base)
          u.key = guide.sha(f.path .. '\0' .. table.concat(raw, '\n'))
          u.first, u.last = c.first, c.last
          add(u)
          pieces[#pieces + 1] = { u = u, hk = hk }
        end
      end
    end
  end
  -- identical pieces: told apart by where they start (whole hunks already are, by the guide)
  for _, p in ipairs(pieces) do
    if count[p.u.key] > 1 then
      local l = p.hk.lines[p.u.first]
      p.u.key = p.u.key .. '@' .. (l.old_lnum or '-') .. ',' .. (l.new_lnum or '-')
    end
  end
  for _, u in ipairs(U.list) do
    U.by_key[u.key] = u
  end
  return U
end

---The unit covering line `li` of hunk `hi` of file `fi` (nil when there is none).
---@param U revuey.Units
function M.at_line(U, fi, hi, li)
  local key = U.hunk_key[fi] and U.hunk_key[fi][hi or 0]
  for _, u in ipairs(key and U.by_hunk[key] or {}) do
    if u.whole_file or (li >= u.first and li <= u.last) then
      return u
    end
  end
end

---Units of a hunk by file and hunk index (hi nil or 0: a file without hunks).
---@param U revuey.Units
function M.of_hunk(U, fi, hi)
  local key = U.hunk_key[fi] and U.hunk_key[fi][hi or 0]
  return key and U.by_hunk[key] or {}
end

---Units shown by a resolved guide section (its items' hunks).
---@param U revuey.Units
---@param sec {items: {hunk: revuey.GuideHunk}[]}
function M.section_units(U, sec)
  local out = {}
  for _, item in ipairs(sec.items or {}) do
    vim.list_extend(out, U.by_hunk[item.hunk.hash] or {})
  end
  return out
end

---@param st revuey.State
---@param u revuey.Unit
function M.reviewed(st, u)
  local fm = st.files[u.path]
  if fm and fm.key == u.file_key then
    return true
  end
  if u.whole_file then
    return false
  end
  return state.unit_marked(st, u.key) or state.unit_marked(st, u.hunk)
end

---Reviewed and total counts over a list of units.
---@return integer done, integer total
function M.progress(st, list)
  local done = 0
  for _, u in ipairs(list) do
    if M.reviewed(st, u) then
      done = done + 1
    end
  end
  return done, #list
end

function M.file_progress(st, U, fi)
  return M.progress(st, U.by_file[fi] or {})
end

---A file is reviewed when all of its units are (every file has at least one unit).
function M.file_reviewed(st, U, fi)
  local done, total = M.file_progress(st, U, fi)
  return total > 0 and done == total
end

function M.all_reviewed(st, list)
  local done, total = M.progress(st, list)
  return total > 0 and done == total
end

---Derived coverage marks, computed by `state.save` on the merged tables (after re-reading the
---file and applying this instance's changes), so two instances never decide them from stale
---memory: the parent hunk key of a split hunk whose pieces are all marked, and the file mark (at
---the current content key) of a file whose units are all marked; a file mark over a file that is
---not complete is removed. A matching file mark with no unit marks behind it at all, and not
---just unmarked here, is a legacy mark: its units are marked first.
M.PRUNE_AFTER = 30 * 86400
M.SEEN_EVERY = 86400

local function finalizer(U)
  return function(files, umarks, st)
    local unmarked = {}
    for k, e in pairs(st._unit_changes or {}) do
      if e == false then
        unmarked[k] = true
      end
    end
    local now = os.time()
    -- prune marks of content this scope no longer shows and has not shown for PRUNE_AFTER
    -- (worktree and committed mode share the file, so marks of the other mode must survive)
    for k, e in pairs(umarks) do
      local last = type(e) == 'table' and (e.seen_at or e.reviewed_at) or 0
      if U.by_hunk[k] or U.by_key[k] then
        if now - last > M.SEEN_EVERY then
          e.seen_at = now
        end
      elseif now - last > M.PRUNE_AFTER then
        umarks[k] = nil
      end
    end
    for _, list in pairs(U.by_file) do
      local first = list[1]
      if first and not first.whole_file then
        local path = first.path
        local function marked(u)
          return umarks[u.key] ~= nil or umarks[u.hunk] ~= nil
        end
        local fm = files[path]
        local current = fm ~= nil and fm.key == first.file_key
        if current then
          local any, explicit = false, false
          for _, u in ipairs(list) do
            any = any or marked(u)
            explicit = explicit or unmarked[u.key] or unmarked[u.hunk] or false
          end
          if not any and not explicit then
            for _, u in ipairs(list) do
              umarks[u.key] = { path = path, reviewed_at = fm.reviewed_at or now }
            end
          end
        end
        local all, seen = true, {}
        for _, u in ipairs(list) do
          if not seen[u.hunk] then
            seen[u.hunk] = true
            local pieces = U.by_hunk[u.hunk]
            if #pieces > 1 and umarks[u.hunk] == nil and not unmarked[u.hunk] then
              local complete = true
              for _, piece in ipairs(pieces) do
                complete = complete and umarks[piece.key] ~= nil
              end
              if complete then
                umarks[u.hunk] = { path = path, reviewed_at = now }
              end
            end
          end
          all = all and marked(u)
        end
        if all and not current then
          files[path] = { key = first.file_key, reviewed_at = now }
        elseif not all and current then
          files[path] = nil
        end
      end
    end
  end
end

---Apply marks in memory (no save). Returns the set of affected file indexes.
local function apply(st, U, targets, value)
  local fis = {}
  for _, u in ipairs(targets) do
    fis[u.file_idx] = true
  end
  if value then
    for _, u in ipairs(targets) do
      if not M.reviewed(st, u) then
        if u.whole_file then
          state.set_reviewed(st, u.path, u.file_key, true)
        else
          state.set_unit(st, u.key, u.path, true)
        end
      end
    end
  else
    local target = {}
    for _, u in ipairs(targets) do
      target[u] = true
    end
    -- the units that stay reviewed, however they are covered now
    local keep = {}
    for fi in pairs(fis) do
      for _, u in ipairs(U.by_file[fi] or {}) do
        if not target[u] and M.reviewed(st, u) then
          keep[#keep + 1] = u
        end
      end
    end
    -- removals are recorded even when this instance never saw the mark (another instance may
    -- have stored it): the file mark at the current content key and the parent hunk keys
    for fi in pairs(fis) do
      local first = (U.by_file[fi] or {})[1]
      if first then
        state.set_reviewed(st, first.path, first.file_key, false)
      end
    end
    for _, u in ipairs(targets) do
      if not u.whole_file then
        state.set_unit(st, u.key, u.path, false)
        state.set_unit(st, u.hunk, u.path, false)
      end
    end
    -- spell out the coverage that was removed for everything else
    for _, u in ipairs(keep) do
      if not M.reviewed(st, u) then
        if u.whole_file then
          state.set_reviewed(st, u.path, u.file_key, true)
        else
          state.set_unit(st, u.key, u.path, true)
        end
      end
    end
  end
  return fis
end

local function save(st, U)
  st._finalize = finalizer(U)
  local ok, err = pcall(state.save, st)
  st._finalize = nil
  if not ok then
    return false, err
  end
  return true
end

---Mark (`value` true) or unmark units and persist (merge-on-save, atomic write).
---@param st revuey.State
---@param U revuey.Units
---@param targets revuey.Unit[]
---@return boolean ok, string? err  on a failed save the change stays pending in memory
function M.set(st, U, targets, value)
  apply(st, U, targets, value)
  return save(st, U)
end

---Toggle a group (a file, a hunk, a section, a selection): if any unit is unreviewed mark them
---all, else unmark them all. Returns the new value, plus an error message if saving failed.
---@return boolean value, string? err
function M.toggle(st, U, targets)
  local value = not M.all_reviewed(st, targets)
  local ok, err = M.set(st, U, targets, value)
  return value, (not ok) and err or nil
end

---Legacy file marks (state version 1, or any file mark without unit marks behind it): a
---matching file mark counts as all of the file's units reviewed. Convert it into unit marks so
---that a later edit of one hunk only resets that hunk. Saves when anything changed.
---@return boolean changed, string? err
function M.migrate(st, U)
  local changed = false
  for _, list in pairs(U.by_file) do
    local first = list[1]
    local fm = first and st.files[first.path]
    if fm and fm.key == first.file_key then
      for _, u in ipairs(list) do
        if not u.whole_file and not state.unit_marked(st, u.key) then
          -- each piece by its own key (an edit to one piece keeps the others), and the hunk
          state.set_unit(st, u.key, u.path, true)
          if #U.by_hunk[u.hunk] > 1 then
            state.set_unit(st, u.hunk, u.path, true)
          end
          changed = true
        end
      end
    end
  end
  if changed then
    local ok, err = save(st, U)
    return ok, err
  end
  return false
end

---The review shows these units: refresh `seen_at` of their marks (unit and parent hunk keys) so
---pruning keeps them. Saves at most once per SEEN_EVERY per scope: only when a shown mark was last
---seen longer ago than that. Called when a review renders.
---@return boolean saved, string? err
function M.touch(st, U)
  local now = os.time()
  local stale = false
  for _, u in ipairs(U.list) do
    for _, k in ipairs({ u.key, u.hunk }) do
      local e = st.units and st.units[k]
      if type(e) == 'table' and now - (e.seen_at or e.reviewed_at or 0) > M.SEEN_EVERY then
        stale = true
        break
      end
    end
    if stale then
      break
    end
  end
  if not stale then
    return false
  end
  local ok, err = save(st, U) -- the finalizer refreshes seen_at of every shown key
  return ok, err
end

---Legacy guide section marks (keyed by section identity): mark the section's units reviewed and
---drop the section mark. Saves when anything changed.
---@param sections {id?:string, items:table}[] resolved guide sections
---@return boolean changed, string? err
function M.migrate_sections(st, U, sections)
  if not st.sections or next(st.sections) == nil then
    return false
  end
  local changed = false
  for _, sec in ipairs(sections) do
    if sec.id and st.sections[sec.id] ~= nil then
      apply(st, U, M.section_units(U, sec), true)
      state.drop_section(st, sec.id)
      changed = true
    end
  end
  if changed then
    local ok, err = save(st, U)
    return ok, err
  end
  return false
end

return M
