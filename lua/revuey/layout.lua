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
---@field kind 'add'|'del'|'ctx'|'meta'|'prose'|'diagram'  prose/diagram: guide rows, skipped by all diff features
---@field meta? 'file'|'hunk'|'blank'|'note'|'section'
---@field section_idx? integer  guide: the section the row belongs to
---@field guide_id? string      guide: engine hunk id (h1...) on hunk rows
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
---@field kind 'diff'|'guide'
---@field lines string[]
---@field map revuey.LineEntry[]
---@field files revuey.FileRange[]
---@field hunks {row:integer, file_idx:integer, first_change:integer}[]
---@field hunk_base table<integer, table<integer, integer>> [file_idx][hunk_idx] = row such that
---  line k of the hunk is at row + k
---@field blocks {start_row:integer, end_row:integer}[] one per hunk (header to last row): level-2 folds
---@field sections? {start_row:integer, end_row:integer, section_idx:integer}[] guide only
---@field file_rows? table<integer, integer> guide only: first row showing each file
---@field diagram? {start_row:integer, end_row:integer} guide only: overview diagram (heading first)

---@param f revuey.FileDiff
function M.file_title(f)
  if f.status == 'R' and f.old_path ~= f.path then
    return f.old_path .. ' → ' .. f.path
  end
  return f.path
end

---Push one hunk's rows (header + lines) through `push`; shared by the diff and the guide layouts so
---both get identical side-table entries (and so identical syntax, word diff, LSP and folding).
---@param push fun(text:string, entry:table):integer
---@param map revuey.LineEntry[]
---@param header_text string text of the header row
---@param extra? table fields merged into every entry (e.g. section_idx in the guide)
---@return integer header_row, integer first_change
local function push_hunk(push, map, f, fi, hi, h, header_text, extra)
  local hunk_id = f.path .. '#' .. hi
  local function entry(e)
    if extra then
      for k, v in pairs(extra) do
        e[k] = v
      end
    end
    return e
  end
  local header_row = push(header_text, entry({
    kind = 'meta',
    meta = 'hunk',
    file_idx = fi,
    path = f.path,
    hunk_id = hunk_id,
    anchor_lnum = math.max(h.new_start, 1),
  }))
  local first_change
  -- anchor for deletions: the new-side line where the deletion "sits"
  local next_new = h.new_start
  local pending = {}
  for li, l in ipairs(h.lines) do
    local row = push(l.text, entry({
      kind = l.kind,
      file_idx = fi,
      path = f.path,
      old_lnum = l.old_lnum,
      new_lnum = l.new_lnum,
      hunk_id = hunk_id,
      hunk_idx = hi,
      line_idx = li,
    }))
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
  return header_row, first_change or header_row + 1
end

---Note shown instead of hunks for a file without a text diff (binary, rename, mode change...).
---@param f revuey.FileDiff
---@return string?
function M.file_note(f)
  if f.note then
    return f.note
  elseif f.binary then
    return 'Binary file not shown'
  elseif #f.hunks == 0 then
    return (f.status == 'R' and 'Renamed without changes')
      or ((f.old_mode and f.new_mode) and ('Mode changed ' .. f.old_mode .. ' → ' .. f.new_mode))
      or (f.status == 'A' and 'Empty file added')
      or (f.status == 'D' and 'Empty file deleted')
      or 'No content changes'
  end
end

local function pusher(lines, map)
  return function(text, entry)
    lines[#lines + 1] = text
    map[#map + 1] = entry
    return #lines
  end
end

---@param files revuey.FileDiff[]
---@return revuey.Layout
function M.compose(files)
  local lines, map, ranges, hunks, base, blocks = {}, {}, {}, {}, {}, {}
  local push = pusher(lines, map)

  for fi, f in ipairs(files) do
    local range = { hunk_rows = {} }
    base[fi] = {}
    range.start_row = push(M.file_title(f), { kind = 'meta', meta = 'file', file_idx = fi, path = f.path, anchor_lnum = 1 })
    local note = M.file_note(f)
    if note then
      push(note, { kind = 'meta', meta = 'note', file_idx = fi, path = f.path })
    end
    for hi, h in ipairs(f.hunks) do
      local header_row, first_change = push_hunk(push, map, f, fi, hi, h, h.header)
      range.hunk_rows[#range.hunk_rows + 1] = header_row
      base[fi][hi] = header_row
      hunks[#hunks + 1] = { row = header_row, file_idx = fi, first_change = first_change }
      blocks[#blocks + 1] = { start_row = header_row, end_row = #lines }
    end
    range.end_row = push('', { kind = 'meta', meta = 'blank', file_idx = fi, path = f.path })
    ranges[fi] = range
  end
  return { kind = 'diff', lines = lines, map = map, files = ranges, hunks = hunks, hunk_base = base, blocks = blocks }
end

---@class revuey.GuideDocItem
---@field kind 'prose'|'section'|'hunk'|'diagram'
---@field text? string            prose/section: the line text
---@field hls? table              prose: {{start_col, end_col, group}, ...}
---@field role? string            prose: title|summary|overview|note|banner|meta|blank|placeholder
---@field section_idx? integer
---@field file_idx? integer       hunk
---@field hunk_idx? integer       hunk (nil: a file without a text diff, shown as a note)
---@field header? string          hunk: header row text
---@field path_len? integer       hunk: bytes of the path prefix in `header`
---@field guide_id? string        hunk: engine hunk id (h1...)
---@field note? revuey.GuideDocItem[] hunk: prose rows shown under the header
---@field layers? string[]        hunk: stack layers that introduced it (full-stack guides)
---@field heading? boolean        diagram: the heading row
---@field nodes? table            diagram: {start byte, end byte, node} spans on the row

---Compose the guide view: prose rows (kind = 'prose', ignored by every diff feature) around hunks
---rendered exactly as in the diff layout. Each section is a range of rows for folding.
---@param files revuey.FileDiff[]
---@param doc revuey.GuideDocItem[]
---@return revuey.Layout
function M.compose_guide(files, doc)
  local lines, map, hunks, base, sections, first_row, blocks = {}, {}, {}, {}, {}, {}, {}
  local push = pusher(lines, map)
  local cur
  -- a buffer line can never hold a newline (model text is sanitised; this is the last guard)
  local raw_push = push
  push = function(text, entry)
    return raw_push(text:find('[\n\r]') and text:gsub('[\n\r]', ' ') or text, entry)
  end
  local function prose(item)
    return push(item.text or '', {
      kind = 'prose',
      role = item.role,
      hls = item.hls,
      section_idx = item.section_idx,
      block = item.block,
      para = item.para,
      off = item.off,
      pre = item.pre,
    })
  end
  local diagram
  for _, item in ipairs(doc) do
    if item.kind == 'diagram' then
      local row = push(item.text or '', { kind = 'diagram', heading = item.heading, hls = item.hls, nodes = item.nodes })
      diagram = diagram or { start_row = row }
      diagram.end_row = row
    elseif item.kind == 'section' then
      if cur then
        cur.end_row = #lines
      end
      local row = push(item.text, { kind = 'meta', meta = 'section', section_idx = item.section_idx })
      cur = { start_row = row, section_idx = item.section_idx }
      sections[#sections + 1] = cur
    elseif item.kind == 'hunk' then
      local fi, hi = item.file_idx, item.hunk_idx
      local f = files[fi]
      local extra = { section_idx = item.section_idx, guide_id = item.guide_id, path_len = item.path_len, layers = item.layers }
      local h = hi and f.hunks[hi]
      local header_row
      if h then
        -- the header row comes first, then the note, then the hunk lines: line k of the hunk is at
        -- hunk_base + k, so the note rows sit between header and base
        -- render the hunk into a scratch list, then splice the note rows in after its header
        local tmp_lines, tmp_map = {}, {}
        local _, fc = push_hunk(pusher(tmp_lines, tmp_map), tmp_map, f, fi, hi, h, item.header or h.header, extra)
        header_row = push(tmp_lines[1], tmp_map[1])
        map[header_row].hunk_idx = hi -- for the header's per-hunk counts
        for _, n in ipairs(item.note or {}) do
          local r = prose(n)
          map[r].file_idx, map[r].path, map[r].anchor_lnum = fi, f.path, tmp_map[1].anchor_lnum
          map[r].note = true
        end
        local offset = #lines - 1 -- tmp row k (k >= 2) lands at offset + k
        for k = 2, #tmp_lines do
          push(tmp_lines[k], tmp_map[k])
        end
        base[fi] = base[fi] or {}
        base[fi][hi] = offset + 1
        hunks[#hunks + 1] = { row = header_row, file_idx = fi, first_change = offset + fc }
      else
        header_row = push(item.header or M.file_title(f), vim.tbl_extend('force', {
          kind = 'meta',
          meta = 'hunk',
          file_idx = fi,
          path = f.path,
          anchor_lnum = 1,
        }, extra))
        for _, n in ipairs(item.note or {}) do
          local r = prose(n)
          map[r].file_idx, map[r].path, map[r].note = fi, f.path, true
        end
        push(M.file_note(f) or '', { kind = 'meta', meta = 'note', file_idx = fi, path = f.path, section_idx = item.section_idx })
      end
      blocks[#blocks + 1] = { start_row = header_row, end_row = #lines }
      first_row[fi] = first_row[fi] or header_row
    else
      prose(item)
    end
  end
  if cur then
    cur.end_row = #lines
  end
  return {
    kind = 'guide',
    lines = lines,
    map = map,
    files = {},
    hunks = hunks,
    hunk_base = base,
    blocks = blocks,
    sections = sections,
    file_rows = first_row,
    diagram = diagram,
  }
end

---Find the composed row for a new-side (path, lnum), only for add/ctx rows. Returns nil if not shown.
---@param layout revuey.Layout
---@param files revuey.FileDiff[]
function M.find_new_row(layout, files, path, lnum)
  if layout.kind == 'guide' then
    -- hunks of one file can be spread over several sections
    for row, e in ipairs(layout.map) do
      if e.path == path and e.new_lnum == lnum and (e.kind == 'add' or e.kind == 'ctx') then
        return row
      end
    end
    return nil
  end
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

---Fold levels for 'foldexpr': each file (guide: each section) is a level-1 fold starting at its
---header; each hunk block is a level-2 fold starting at its header row; runs of more than
---`ctx_threshold` context lines get a level-3 fold over their middle (keeping `keep` lines visible
---at each end). The window's 'foldlevel' is 2, so only the context folds start closed.
---@param layout revuey.Layout
---@param ctx_threshold integer
---@param keep integer
---@return string[] foldexpr values per row
function M.fold_levels(layout, ctx_threshold, keep)
  local levels = {}
  -- diff: one fold per file; guide: one per section (title and summary stay unfolded)
  local ranges = layout.kind == 'guide' and vim.list_extend({ layout.diagram }, layout.sections) or layout.files
  for _, r in ipairs(ranges) do
    levels[r.start_row] = '>1'
    for row = r.start_row + 1, r.end_row do
      levels[row] = '1'
    end
  end
  for _, b in ipairs(layout.blocks or {}) do
    levels[b.start_row] = '>2'
    for row = b.start_row + 1, b.end_row do
      levels[row] = '2'
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
        if not map[e + 1] or map[e + 1].kind == 'meta' or map[e + 1].kind == 'prose' or map[e + 1].kind == 'diagram' then
          fe = e
        end
        if fe - fs + 1 >= 4 then
          levels[fs] = '>3'
          for r2 = fs + 1, fe do
            levels[r2] = '3'
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
