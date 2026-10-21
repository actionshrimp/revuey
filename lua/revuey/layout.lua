-- Pure composition of a review into buffer lines + a per-line side table (ARCHITECTURE decision 1).
--
-- Design choice: ONE continuous buffer for all files (GitHub "Files changed" style) rather than one
-- buffer per file. Reasons:
--   * reviewing is reading top to bottom; `]c`, `/search`, `n`, scrolling and visual selections flow
--     across file boundaries without buffer switching;
--   * per-file collapse (reviewed files fold closed) gives the "one file at a time" feel on demand;
--   * syntax and diff decoration are applied lazily per visible line (decoration provider) and the
--     side table is a flat array, so buffer size is not a rendering cost;
--   * the guide view (decision 4) needs prose between hunks of different files in one buffer anyway,
--     so the renderer is built for multi-file documents from day one.
-- The cost is that buffer-local state (folds, extmarks) must be indexed by row ranges per file,
-- which `files[i].start_row/end_row` provide.
local M = {}

---@class revuey.LineEntry
---@field kind 'add'|'del'|'ctx'|'meta'
---@field meta? 'file'|'hunk'|'blank'|'note'
---@field file_idx integer
---@field path string
---@field old_lnum? integer
---@field new_lnum? integer
---@field anchor_lnum? integer  nearest new-side line (for del/meta rows), used to open the real file
---@field hunk_id? string
---@field hunk_idx? integer index into file.hunks
---@field line_idx? integer index into hunk.lines

---@class revuey.FileRange
---@field start_row integer   1-based row of the file header
---@field end_row integer     1-based last row belonging to the file (separator included)
---@field hunk_rows integer[] rows of hunk headers

---@class revuey.Layout
---@field lines string[]
---@field map revuey.LineEntry[]
---@field files revuey.FileRange[]
---@field hunks {row:integer, file_idx:integer, first_change:integer}[]

---@param f revuey.FileDiff
function M.file_title(f)
  if f.status == 'R' and f.old_path ~= f.path then
    return f.old_path .. ' → ' .. f.path
  end
  return f.path
end

---@param files revuey.FileDiff[]
---@return revuey.Layout
function M.compose(files)
  local lines, map, ranges, hunks = {}, {}, {}, {}
  local function push(text, entry)
    lines[#lines + 1] = text
    map[#map + 1] = entry
    return #lines
  end

  for fi, f in ipairs(files) do
    local range = { hunk_rows = {} }
    range.start_row = push(M.file_title(f), { kind = 'meta', meta = 'file', file_idx = fi, path = f.path, anchor_lnum = 1 })
    if f.note then
      push(f.note, { kind = 'meta', meta = 'note', file_idx = fi, path = f.path })
    elseif f.binary then
      push('Binary file not shown', { kind = 'meta', meta = 'note', file_idx = fi, path = f.path })
    elseif #f.hunks == 0 then
      local note = (f.status == 'R' and 'Renamed without changes')
        or ((f.old_mode and f.new_mode) and ('Mode changed ' .. f.old_mode .. ' → ' .. f.new_mode))
        or (f.status == 'A' and 'Empty file added')
        or (f.status == 'D' and 'Empty file deleted')
        or 'No content changes'
      push(note, { kind = 'meta', meta = 'note', file_idx = fi, path = f.path })
    end
    for hi, h in ipairs(f.hunks) do
      local hunk_id = f.path .. '#' .. hi
      local header_row = push(h.header, {
        kind = 'meta',
        meta = 'hunk',
        file_idx = fi,
        path = f.path,
        hunk_id = hunk_id,
        anchor_lnum = math.max(h.new_start, 1),
      })
      range.hunk_rows[#range.hunk_rows + 1] = header_row
      local first_change
      -- anchor for deletions: the new-side line where the deletion "sits"
      local next_new = h.new_start
      local pending = {}
      for li, l in ipairs(h.lines) do
        local row = push(l.text, {
          kind = l.kind,
          file_idx = fi,
          path = f.path,
          old_lnum = l.old_lnum,
          new_lnum = l.new_lnum,
          hunk_id = hunk_id,
          hunk_idx = hi,
          line_idx = li,
        })
        if l.kind ~= 'ctx' and not first_change then
          first_change = row
        end
        if l.new_lnum then
          next_new = l.new_lnum + 1
          for _, p in ipairs(pending) do
            map[p].anchor_lnum = l.new_lnum
          end
          pending = {}
          map[row].anchor_lnum = l.new_lnum
        else
          pending[#pending + 1] = row
        end
      end
      for _, p in ipairs(pending) do
        map[p].anchor_lnum = math.max(next_new - 1, 1)
      end
      hunks[#hunks + 1] = { row = header_row, file_idx = fi, first_change = first_change or header_row + 1 }
    end
    range.end_row = push('', { kind = 'meta', meta = 'blank', file_idx = fi, path = f.path })
    ranges[fi] = range
  end
  return { lines = lines, map = map, files = ranges, hunks = hunks }
end

---Find the composed row for a new-side (path, lnum), only for add/ctx rows. Returns nil if not shown.
---@param layout revuey.Layout
---@param files revuey.FileDiff[]
function M.find_new_row(layout, files, path, lnum)
  for fi, f in ipairs(files) do
    if f.path == path then
      local r = layout.files[fi]
      for row = r.start_row, r.end_row do
        local e = layout.map[row]
        if e.new_lnum == lnum and (e.kind == 'add' or e.kind == 'ctx') then
          return row
        end
      end
      return nil
    end
  end
end

---Fold levels for 'foldexpr': each file is a level-1 fold starting at its header; runs of
---more than `ctx_threshold` context lines get a level-2 fold over their middle (keeping `keep`
---lines visible at each end).
---@param layout revuey.Layout
---@param ctx_threshold integer
---@param keep integer
---@return string[] foldexpr values per row
function M.fold_levels(layout, ctx_threshold, keep)
  local levels = {}
  for _, r in ipairs(layout.files) do
    levels[r.start_row] = '>1'
    for row = r.start_row + 1, r.end_row do
      levels[row] = '1'
    end
  end
  local map = layout.map
  local row, n = 1, #map
  while row <= n do
    if map[row].kind == 'ctx' then
      local s = row
      while row <= n and map[row].kind == 'ctx' do
        row = row + 1
      end
      local e = row - 1
      local len = e - s + 1
      if len > ctx_threshold then
        local fs, fe = s + keep, e - keep
        -- first/last hunk lines of a file: don't keep context on the open end
        if map[s - 1] and map[s - 1].meta == 'hunk' then
          fs = s
        end
        if not map[e + 1] or map[e + 1].kind == 'meta' then
          fe = e
        end
        if fe - fs + 1 >= 4 then
          levels[fs] = '>2'
          for r2 = fs + 1, fe do
            levels[r2] = '2'
          end
        end
      end
    else
      row = row + 1
    end
  end
  return levels
end

return M
