-- AI guided review: the pure model (no window/buffer UI, no processes).
--
--   * hunk ids and anchors: every hunk of the review gets a short id (h1..hn, diff order) for the
--     model to reference, and an anchor {path, old_start, new_start, header, hash} that survives
--     line shifts (the hash covers the path and the hunk's +/-/context lines, not line numbers);
--   * validation and repair of the model's output (instructed, not trusted), including line notes
--     anchored to a hunk id plus line numbers within the hunk (the same check as AI review findings);
--   * the persisted guide record, and resolving it against the current hunks (staleness);
--   * section identity (hash of the section's hunk hashes) for reviewed state;
--   * storage under <state_dir>/guides/.
-- Prompt text and schema live in guide_prompt.lua; the CLI call in ai.lua.
local layout = require('revuey.layout')
local diagram_mod = require('revuey.diagram')
local prompt = require('revuey.guide_prompt')

local M = {}

-- 2: sections' hunk anchors may carry `line_notes` (version 1 records simply have none)
M.VERSION = 2

M.NOTE_MAX_SECTION = prompt.MAX_NOTES_PER_SECTION
M.NOTE_MAX = prompt.MAX_NOTES
M.NOTE_MAX_RANGE = prompt.MAX_NOTE_LINES
M.NOTE_MAX_CHARS = 200

local function int(v)
  v = tonumber(v)
  if v and v == math.floor(v) then
    return v
  end
end

---Note text: one line, at most NOTE_MAX_CHARS characters.
local function note_text(v)
  local t = M.one_line(v)
  if vim.fn.strchars(t) > M.NOTE_MAX_CHARS then
    t = vim.fn.strcharpart(t, 0, M.NOTE_MAX_CHARS - 1) .. '…'
  end
  return t
end


---@class revuey.GuideHunk
---@field id string          h1..hn
---@field file_idx integer
---@field hunk_idx? integer  nil: a file without a text diff (binary, pure rename, placeholder)
---@field path string
---@field old_path string
---@field status string
---@field header string      "@@ -a,b +c,d @@ ..." (or the file note)
---@field old_start integer
---@field new_start integer
---@field added integer
---@field removed integer
---@field hash string        content hash (unique within the review)
---@field text string[]      hunk lines with +/-/space prefixes (for the prompt)

local function sha(s)
  return vim.fn.sha256(s):sub(1, 20)
end

---A hunk line as hashed for anchors and unit keys: +/-/space prefix, text, and its line-ending
---flags (line-ending changes are changes too).
---@param l revuey.DiffLine
function M.raw_line(l)
  local mark = l.kind == 'add' and '+' or l.kind == 'del' and '-' or ' '
  return mark .. l.text .. (l.cr and '\r' or '') .. (l.no_eol and '\0noeol' or '')
end

M.sha = sha

---Assign ids and anchors to every hunk of a review's files, in diff order. Files without a text
---diff get one entry each so the guide can place them too.
---@param files revuey.FileDiff[]
---@return revuey.GuideHunk[]
function M.hunks(files)
  local out, count = {}, {}
  local function add(e, content)
    e.hash = sha(content)
    count[e.hash] = (count[e.hash] or 0) + 1
    e.id = 'h' .. (#out + 1)
    out[#out + 1] = e
  end
  for fi, f in ipairs(files) do
    if #f.hunks == 0 then
      local note = layout.file_note(f) or ''
      add({
        file_idx = fi,
        path = f.path,
        old_path = f.old_path or f.path,
        status = f.status,
        header = note,
        old_start = 0,
        new_start = 0,
        added = f.added or 0,
        removed = f.removed or 0,
        text = { '(' .. note .. ')' },
      }, table.concat({ f.path, f.old_path or '', f.status or '', f.old_blob or '', f.new_blob or '', note }, '\0'))
    end
    for hi, h in ipairs(f.hunks) do
      local text, raw, added, removed = {}, {}, 0, 0
      for _, l in ipairs(h.lines) do
        local mark = l.kind == 'add' and '+' or l.kind == 'del' and '-' or ' '
        added = added + (l.kind == 'add' and 1 or 0)
        removed = removed + (l.kind == 'del' and 1 or 0)
        text[#text + 1] = mark .. l.text
        raw[#raw + 1] = M.raw_line(l)
      end
      add({
        file_idx = fi,
        hunk_idx = hi,
        path = f.path,
        old_path = f.old_path or f.path,
        status = f.status,
        header = h.header,
        old_start = h.old_start,
        new_start = h.new_start,
        added = added,
        removed = removed,
        text = text,
      }, f.path .. '\0' .. table.concat(raw, '\n'))
    end
  end
  -- Identical hunks (the same edit in two places of a file) are told apart by where they are, so
  -- an identity never moves from one of them to another. The cost: such hunks count as changed
  -- when lines above them shift. Unique hunks stay shift-invariant.
  for _, e in ipairs(out) do
    if count[e.hash] > 1 then
      e.hash = e.hash .. '@' .. e.old_start .. ',' .. e.new_start
    end
  end
  return out
end

---@param h revuey.GuideHunk
function M.anchor(h)
  return { path = h.path, old_start = h.old_start, new_start = h.new_start, header = h.header, hash = h.hash }
end

---Hash of the whole anchor set (identifies "this exact diff" for a guide file name).
---@param hunks revuey.GuideHunk[]
function M.anchors_hash(hunks)
  local parts = {}
  for _, h in ipairs(hunks) do
    parts[#parts + 1] = h.hash
  end
  return sha(table.concat(parts, '\n'))
end

---Identity of a section for reviewed state: the hash of its sorted hunk hashes. The same hunks
---grouped the same way after regeneration keep the state; any changed hunk gives a new id.
---@param hashes string[]
---@return string?
function M.section_id(hashes)
  if #hashes == 0 then
    return nil
  end
  local sorted = vim.deepcopy(hashes)
  table.sort(sorted)
  return 's' .. sha(table.concat(sorted, '\n'))
end

-- ---------------------------------------------------------------------------
-- Model output: repair and validation
-- ---------------------------------------------------------------------------

---Mechanical JSON repair: strip code fences, then slice from the first `{` to the last `}`.
---@param text string
---@return table? decoded
function M.repair_json(text)
  if type(text) ~= 'string' then
    return nil
  end
  local function try(t)
    local ok, v = pcall(vim.json.decode, t, { luanil = { object = true, array = true } })
    if ok and type(v) == 'table' then
      return v
    end
  end
  local v = try(text)
  if v then
    return v
  end
  local stripped = text:gsub('```[%w_-]*', '')
  local a, b = stripped:find('{', 1, true), nil
  for i = #stripped, 1, -1 do
    if stripped:sub(i, i) == '}' then
      b = i
      break
    end
  end
  if a and b and b > a then
    return try(stripped:sub(a, b))
  end
end

---Text for a single buffer line (titles, notes): no newlines or control characters.
function M.one_line(v)
  if type(v) ~= 'string' then
    return ''
  end
  return vim.trim((v:gsub('[%c]+', ' '):gsub('  +', ' ')))
end

---Multi-line markdown (summary, overviews): keeps newlines and tabs, drops other control chars.
function M.clean_text(v)
  if type(v) ~= 'string' then
    return ''
  end
  return vim.trim((v:gsub('\r\n', '\n'):gsub('[%z\1-\8\11-\31\127]', '')))
end

---Stored line notes of one hunk anchor (records on disk may be edited by hand): integer lines,
---an end at or after the start within NOTE_MAX_RANGE, one-line text, a known side, the snippet
---as strings; anything else is dropped. nil when none are left. Version 1 records have none.
function M.sanitize_notes(list)
  if type(list) ~= 'table' then
    return nil
  end
  local out = {}
  for _, n in ipairs(list) do
    if type(n) == 'table' and #out < M.NOTE_MAX then
      local line, last = int(n.line), int(n.end_line or n.line)
      local text = note_text(n.text)
      local snippet = {}
      for _, l in ipairs(type(n.lines) == 'table' and n.lines or {}) do
        if type(l) == 'string' then
          snippet[#snippet + 1] = l
        end
      end
      if line and last and line >= 1 and last >= line and last - line < M.NOTE_MAX_RANGE and text ~= '' then
        out[#out + 1] = {
          line = line,
          end_line = last,
          side = n.side == 'old' and 'old' or 'new',
          text = text,
          lines = #snippet == last - line + 1 and snippet or nil,
        }
      end
    end
  end
  return #out > 0 and out or nil
end

---Clean every model-provided string of a stored record (records on disk may predate a fix, or
---have been edited by hand).
function M.sanitize(rec)
  rec.title = M.one_line(rec.title)
  rec.summary = M.clean_text(rec.summary)
  local sections = {}
  for _, s in ipairs(type(rec.sections) == 'table' and rec.sections or {}) do
    if type(s) == 'table' then
      local hunks = {}
      for _, a in ipairs(type(s.hunks) == 'table' and s.hunks or {}) do
        if type(a) == 'table' and type(a.hash) == 'string' then
          local note = M.one_line(a.note)
          a.note = note ~= '' and note or nil
          a.line_notes = M.sanitize_notes(a.line_notes)
          hunks[#hunks + 1] = a
        end
      end
      local title = M.one_line(s.title)
      sections[#sections + 1] = {
        title = title ~= '' and title or 'Untitled section',
        overview = M.clean_text(s.overview),
        hunks = hunks,
        other = s.other == true or nil,
      }
    end
  end
  rec.sections = sections
  rec.diagram = M.validate_diagram(rec.diagram, function(v)
    v = tonumber(v)
    return v and v == math.floor(v) and v >= 1 and v <= #sections and v or nil
  end)
  if type(rec.generator) ~= 'table' then
    rec.generator = {}
  end
  return rec
end

---Normalise a hunk reference: "h7", "H7", " h7 " or 7 -> "h7".
local function norm_id(v)
  if type(v) == 'table' then
    v = v.id
  end
  if type(v) == 'number' then
    return 'h' .. math.floor(v)
  end
  if type(v) ~= 'string' then
    return nil
  end
  local n = vim.trim(v):lower():match('^h?(%d+)$')
  return n and ('h' .. tonumber(n)) or nil
end
M.norm_id = norm_id

---Check a line anchor within a hunk (AI review findings and guide line notes): `line_v` and
---`end_v` are 1-based numbers of the hunk's lines as the prompt numbered them. `shown` is what the
---prompt showed (guide_prompt.user_message's info): `level` ('full'|'abridged'|'files') and
---`abridged` (set of ids shown as a preview of PREVIEW_LINES lines); nil: every line.
---Returns the range (clamped to `max_range` lines), or no lines when the anchor is the whole
---file (no line given, a file without a text diff, or no hunk bodies shown), or a reason:
---'bad_line' (not an integer, outside the lines shown, an end before its start or without one).
---@param h revuey.GuideHunk
---@return integer? line, integer? last, string? reason
function M.hunk_range(h, line_v, end_v, shown, max_range)
  local line, last = int(line_v), int(end_v)
  if line_v ~= nil and not line or end_v ~= nil and not last then
    return nil, nil, 'bad_line'
  end
  if not h.hunk_idx or (shown and shown.level) == 'files' then
    return nil, nil -- the whole file
  end
  if not line then
    if last then
      return nil, nil, 'bad_line' -- an end without a start
    end
    return nil, nil
  end
  last = last or line
  -- an abridged hunk only showed (and numbered) its first lines
  local max = (shown and shown.abridged and shown.abridged[h.id]) and math.min(#h.text, prompt.PREVIEW_LINES) or #h.text
  if line < 1 or line > max or last < line or last > max then
    return nil, nil, 'bad_line'
  end
  if max_range then
    last = math.min(last, line + max_range - 1)
  end
  return line, last
end

---"2 dropped (1 unknown hunk, 1 line outside its hunk)" for warnings with drops, else nil
---(AI review findings and guide line notes count their drops the same way).
function M.dropped_text(w)
  if type(w) ~= 'table' or (w.dropped or 0) == 0 then
    return nil
  end
  local parts = {}
  local names = {
    { 'unknown_hunk', 'unknown hunk', 'unknown hunks' },
    { 'bad_line', 'line outside its hunk', 'lines outside their hunks' },
    { 'empty', 'empty', 'empty' },
    { 'duplicates', 'duplicate', 'duplicates' },
    { 'extra', 'over the limit', 'over the limit' },
  }
  for _, n in ipairs(names) do
    local k = w[n[1]] or 0
    if k > 0 then
      parts[#parts + 1] = k .. ' ' .. (k == 1 and n[2] or n[3])
    end
  end
  return ('%d dropped (%s)'):format(w.dropped, table.concat(parts, ', '))
end

---Side of a hunk line ('old' for a deleted line, else 'new') from its +/-/space marker.
local function line_side(h, line)
  return (h.text[line] or ''):sub(1, 1) == '-' and 'old' or 'new'
end

---Validate the model's line notes (each section's `line_notes`) once the hunks are placed. A note
---is kept on the hunk reference it points into, whichever section shows that hunk (so caps count
---per section shown): an unknown or unplaced hunk, a line the prompt did not number, no line or
---no text drop it, as do exact duplicates and notes past NOTE_MAX_SECTION per section or NOTE_MAX
---in all. Never guessed: a bad anchor is dropped and counted, not moved.
---@param raw_sections table[] the model's sections
---@param refs table<string, {ref: table, si: integer}> placed hunk id -> its reference and section
---@return table? warnings {kept, dropped, unknown_hunk, bad_line, empty, duplicates, extra}; nil when the model wrote none
local function validate_notes(raw_sections, refs, by_id, shown)
  local w = { kept = 0, dropped = 0, unknown_hunk = 0, bad_line = 0, empty = 0, duplicates = 0, extra = 0 }
  local any = false
  local per_section, seen = {}, {}
  for _, s in ipairs(raw_sections) do
    local list = type(s) == 'table' and s.line_notes
    for _, n in ipairs(type(list) == 'table' and list or {}) do
      any = true
      local reason, note, at
      if type(n) ~= 'table' then
        reason = 'empty'
      else
        local id = norm_id(n.hunk or n.id)
        local h = id and by_id[id]
        at = id and refs[id]
        local text = note_text(n.text or n.note)
        if not h or not at then
          reason = 'unknown_hunk'
        elseif text == '' then
          reason = 'empty'
        else
          local line, last, why = M.hunk_range(h, n.line, n.end_line, shown, M.NOTE_MAX_RANGE)
          if why or not line then
            reason = 'bad_line' -- a note points at a line: no line (or no numbered lines) is no anchor
          else
            note = { line = line, end_line = last, side = line_side(h, line), text = text }
            local key = table.concat({ id, line, last, text:lower() }, '\0')
            if seen[key] then
              reason, note = 'duplicates', nil
            else
              seen[key] = true
            end
          end
        end
      end
      if note and ((per_section[at.si] or 0) >= M.NOTE_MAX_SECTION or w.kept >= M.NOTE_MAX) then
        reason, note = 'extra', nil
      end
      if note then
        per_section[at.si] = (per_section[at.si] or 0) + 1
        w.kept = w.kept + 1
        at.ref.line_notes = at.ref.line_notes or {}
        table.insert(at.ref.line_notes, note)
      else
        w[reason] = w[reason] + 1
        w.dropped = w.dropped + 1
      end
    end
  end
  for _, at in pairs(refs) do
    if at.ref.line_notes then
      table.sort(at.ref.line_notes, function(a, b)
        if a.line ~= b.line then
          return a.line < b.line
        end
        return a.end_line < b.end_line
      end)
    end
  end
  return any and w or nil
end

M.OTHER_TITLE = 'Other changes'

M.DIAGRAM_MAX_NODES, M.DIAGRAM_MAX_EDGES = 12, 20
M.DIAGRAM_LABEL_MAX, M.DIAGRAM_EDGE_LABEL_MAX = 28, 20
local KINDS = { new = true, changed = true, context = true }

local function diagram_id(v)
  if type(v) == 'number' then
    v = tostring(v)
  end
  return type(v) == 'string' and M.one_line(v) or ''
end

---Hold the optional overview diagram to its schema: nodes with unique ids (first wins, at most
---12), labels on one line and truncated, unknown kinds as "changed", sections mapped by
---`section_of` (nil when unknown); edges between known nodes only, no self loops, deduplicated
---(first wins, at most 20). A diagram with fewer than two nodes is omitted (nil).
---@param raw any
---@param section_of? fun(v:any):integer?
---@return {nodes:{id:string, label:string, kind:string, section?:integer}[], edges:{from:string, to:string, label?:string}[]}?
function M.validate_diagram(raw, section_of)
  if type(raw) ~= 'table' then
    return nil
  end
  local nodes, seen = {}, {}
  for _, n in ipairs(type(raw.nodes) == 'table' and raw.nodes or {}) do
    if #nodes >= M.DIAGRAM_MAX_NODES then
      break
    end
    local id = type(n) == 'table' and diagram_id(n.id) or ''
    if id ~= '' and not seen[id] then
      seen[id] = true
      local label = M.one_line(n.label)
      nodes[#nodes + 1] = {
        id = id,
        label = diagram_mod.truncate(label ~= '' and label or id, M.DIAGRAM_LABEL_MAX),
        kind = KINDS[n.kind] and n.kind or 'changed',
        section = section_of and n.section ~= nil and section_of(n.section) or nil,
      }
    end
  end
  if #nodes < 2 then
    return nil
  end
  local edges, pairs_seen = {}, {}
  for _, e in ipairs(type(raw.edges) == 'table' and raw.edges or {}) do
    if #edges >= M.DIAGRAM_MAX_EDGES then
      break
    end
    if type(e) == 'table' then
      local from, to = diagram_id(e.from), diagram_id(e.to)
      local key = from .. '\0' .. to
      if seen[from] and seen[to] and from ~= to and not pairs_seen[key] then
        pairs_seen[key] = true
        local label = M.one_line(e.label)
        edges[#edges + 1] = {
          from = from,
          to = to,
          label = label ~= '' and diagram_mod.truncate(label, M.DIAGRAM_EDGE_LABEL_MAX) or nil,
        }
      end
    end
  end
  return { nodes = nodes, edges = edges }
end

---Hold model output to the schema and the coverage rule, against the launch-time hunks.
---Unknown ids and duplicates are dropped (first placement wins), empty sections dropped, missed and
---unplaced hunks go to a final "Other changes" section. Zero valid sections is a failure. Line
---notes are checked against what the prompt showed (`shown`, as for AI reviews; nil: every line)
---and kept on the hunk they point into (validate_notes).
---@param raw table|string decoded output, or text to repair
---@param hunks revuey.GuideHunk[]
---@param shown? {level?: string, abridged?: table<string, boolean>}
---@return table? guide {title, summary, sections = {{title, overview, hunks = {{id, note?, line_notes?}}, other?}}}
---@return string|table err_or_warnings error message, or on success {unknown, duplicates, missed, unplaced, notes?}
function M.validate(raw, hunks, shown)
  if type(raw) == 'string' then
    raw = M.repair_json(raw)
    if not raw then
      return nil, 'Claude returned output that is not valid JSON'
    end
  end
  if type(raw) ~= 'table' then
    return nil, 'Claude returned no structured output'
  end
  local by_id = {}
  for _, h in ipairs(hunks) do
    by_id[h.id] = h
  end
  local placed = {}
  local warnings = { unknown = 0, duplicates = 0, missed = 0, unplaced = 0 }
  local sections = {}
  local sec_map, sec_titles = {}, {} -- model section index / title -> validated index
  local refs_by_id = {} -- placed id -> {ref, si}
  local raw_sections = type(raw.sections) == 'table' and raw.sections or {}
  for ri, s in ipairs(raw_sections) do
    if type(s) == 'table' then
      local refs = {}
      for _, r in ipairs(type(s.hunks) == 'table' and s.hunks or {}) do
        local id = norm_id(r)
        if not id or not by_id[id] then
          warnings.unknown = warnings.unknown + 1
        elseif placed[id] then
          warnings.duplicates = warnings.duplicates + 1
        else
          placed[id] = true
          local note = type(r) == 'table' and M.one_line(r.note) or ''
          refs[#refs + 1] = { id = id, note = note ~= '' and note or nil }
          refs_by_id[id] = { ref = refs[#refs], si = #sections + 1 }
        end
      end
      if #refs > 0 then
        local title = M.one_line(s.title)
        sections[#sections + 1] = {
          title = title ~= '' and title or 'Untitled section',
          overview = M.clean_text(s.overview),
          hunks = refs,
        }
        sec_map[ri] = #sections
        if title ~= '' then
          sec_titles[title:lower()] = sec_titles[title:lower()] or #sections
        end
      end
    end
  end
  if #sections == 0 then
    if warnings.unknown > 0 then
      return nil, ('no sections survived validation (%d unknown hunk id%s)'):format(warnings.unknown, warnings.unknown == 1 and '' or 's')
    end
    return nil, 'no sections survived validation'
  end
  local unplaced = {}
  for _, v in ipairs(type(raw.unplaced) == 'table' and raw.unplaced or {}) do
    local id = norm_id(v)
    if id and by_id[id] and not placed[id] and not unplaced[id] then
      unplaced[id] = true
      warnings.unplaced = warnings.unplaced + 1
    end
  end
  local rest = {}
  for _, h in ipairs(hunks) do
    if not placed[h.id] then
      if not unplaced[h.id] then
        warnings.missed = warnings.missed + 1
      end
      rest[#rest + 1] = { id = h.id }
      refs_by_id[h.id] = { ref = rest[#rest], si = #sections + 1 }
    end
  end
  if #rest > 0 then
    sections[#sections + 1] = {
      title = M.OTHER_TITLE,
      overview = warnings.missed > 0 and 'Changes the guide did not place in a section.'
        or 'Low-signal changes that are not part of the story above.',
      hunks = rest,
      other = true,
    }
  end
  local title = M.one_line(raw.title)
  local diagram = M.validate_diagram(raw.diagram, function(v)
    if type(v) == 'string' then
      local t = vim.trim(v):lower()
      return sec_titles[t] or sec_map[tonumber(t:match('^#?(%d+)$') or '')]
    end
    return type(v) == 'number' and sec_map[v] or nil
  end)
  if raw.diagram ~= nil and not diagram then
    warnings.diagram_dropped = true
  end
  warnings.notes = validate_notes(raw_sections, refs_by_id, by_id, shown)
  return {
    title = title ~= '' and title or 'Guided review',
    summary = M.clean_text(raw.summary),
    sections = sections,
    diagram = diagram,
  }, warnings
end

-- ---------------------------------------------------------------------------
-- Persisted record and resolution against the current diff
-- ---------------------------------------------------------------------------

---Persisted form of a validated guide: hunk references become anchors (ids are per-diff only).
---@param guide table validated guide
---@param hunks revuey.GuideHunk[] launch-time hunks
---@param meta table key, generator, ...
function M.record(guide, hunks, meta)
  local by_id = {}
  for _, h in ipairs(hunks) do
    by_id[h.id] = h
  end
  local sections = {}
  for _, s in ipairs(guide.sections) do
    local refs = {}
    for _, r in ipairs(s.hunks) do
      local h = by_id[r.id]
      local a = M.anchor(h)
      a.note = r.note
      if r.line_notes then
        -- with the lines they point at, so a re-anchored (edited) hunk can find them again
        a.line_notes = {}
        for _, n in ipairs(r.line_notes) do
          a.line_notes[#a.line_notes + 1] = {
            line = n.line,
            end_line = n.end_line,
            side = n.side,
            text = n.text,
            lines = vim.list_slice(h.text, n.line, n.end_line),
          }
        end
      end
      refs[#refs + 1] = a
    end
    sections[#sections + 1] = { title = s.title, overview = s.overview, hunks = refs, other = s.other or nil }
  end
  return {
    kind = 'revuey-guide',
    version = M.VERSION,
    key = meta.key,
    anchors = M.anchors_hash(hunks),
    hunk_count = #hunks,
    title = guide.title,
    summary = guide.summary,
    sections = sections,
    diagram = guide.diagram,
    generator = meta.generator or {},
  }
end

---@class revuey.ResolvedSection
---@field title string
---@field overview string
---@field items {hunk: revuey.GuideHunk, note?: string, edited?: boolean, line_notes?: {line: integer, end_line: integer, side: string, text: string}[]}[]
---@field missing integer   hunks of the guide no longer in the diff (changed or gone)
---@field outdated boolean
---@field kind 'section'|'other'|'new'
---@field id? string        reviewed-state identity (nil when the section shows no hunks)

---Line ranges and function context of a hunk header ("@@ -a,b +c,d @@ ctx"). An empty range
---(count 0: git names the line before it) is the point between that line and the next.
---@return {old:number[], new:number[], ctx:string}?
local function header_span(header)
  if type(header) ~= 'string' then
    return nil
  end
  local os_, oc, ns_, nc, rest = header:match('^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@ ?(.*)$')
  if not os_ then
    return nil
  end
  local function range(s, c)
    s, c = tonumber(s), c == '' and 1 or tonumber(c)
    if c == 0 then
      return { s + 0.5, s + 0.5 }
    end
    return { s, s + c - 1 }
  end
  return { old = range(os_, oc), new = range(ns_, nc), ctx = vim.trim(rest or '') }
end

local function overlaps(a, b)
  return a[1] <= b[2] and b[1] <= a[2]
end

---Re-anchoring by overlap (as comments re-anchor by position and context): a guide hunk whose
---content hash no longer matches is matched to a current hunk nobody matched by hash, in the same
---file, whose old-side or new-side line range overlaps the guide hunk's, when their function
---context (the text after `@@ ... @@`) does not disagree. Conservative: a guide hunk with
---several candidates (an edit split it), or a candidate claimed by guide hunks of different
---sections (an edit joined them), matches nothing. Claimants in one section share the hunk:
---the first shows it, the others were merged into it.
---@param anchors {a:table, si:integer}[] unmatched guide anchors with their section index
---@param free revuey.GuideHunk[] current hunks not matched by hash
---@return table<table, revuey.GuideHunk|false> anchor -> hunk (false: merged into another)
local function reanchor(anchors, free)
  local spans = {}
  for _, h in ipairs(free) do
    spans[h] = h.hunk_idx and header_span(h.header) or nil
  end
  local cands, claims = {}, {}
  for _, x in ipairs(anchors) do
    local sa = header_span(x.a.header)
    -- the old side first: edits in the working tree leave it where it was, while new-side
    -- ranges shift with every line added above; the new side only when the old finds nothing
    local by_old, by_new = {}, {}
    for _, h in ipairs(free) do
      local sh = spans[h]
      if sa and sh and h.path == x.a.path and (sa.ctx == '' or sh.ctx == '' or sa.ctx == sh.ctx) then
        if overlaps(sa.old, sh.old) then
          by_old[#by_old + 1] = h
        elseif overlaps(sa.new, sh.new) then
          by_new[#by_new + 1] = h
        end
      end
    end
    local list = #by_old > 0 and by_old or by_new
    cands[x] = list
    for _, h in ipairs(list) do
      claims[h] = claims[h] or {}
      table.insert(claims[h], x)
    end
  end
  local out, given = {}, {}
  for _, x in ipairs(anchors) do
    local list = cands[x]
    if #list == 1 then
      local h = list[1]
      local ok = true
      for _, y in ipairs(claims[h]) do
        if #cands[y] ~= 1 or y.si ~= x.si then
          ok = false
        end
      end
      if ok then
        out[x.a] = not given[h] and h or false
        given[h] = true
      end
    end
  end
  return out
end

---Line notes of a guide hunk on the hunk shown in its place. Unchanged hunks (same hash) keep
---them where they were; on a hunk re-anchored by overlap (edited) a note stays only where its
---lines are found again, unchanged and in one place (at the stored line, else a unique match);
---the rest are lost (counted), never guessed.
---@return {line:integer, end_line:integer, side:string, text:string}[]? notes, integer lost
local function place_notes(notes, h, edited)
  if not notes or not h.hunk_idx then
    return nil, notes and #notes or 0
  end
  local out, lost = {}, 0
  local function matches(at, lines)
    for k, l in ipairs(lines) do
      if h.text[at + k - 1] ~= l then
        return false
      end
    end
    return true
  end
  for _, n in ipairs(notes) do
    local at
    local lines = n.lines
    local span = n.end_line - n.line + 1
    if not edited then
      at = n.end_line <= #h.text and n.line or nil
    elseif lines and #lines == span then
      if matches(n.line, lines) then
        at = n.line
      else
        local found = 0
        for i = 1, #h.text - span + 1 do
          if matches(i, lines) then
            found, at = found + 1, i
          end
        end
        at = found == 1 and at or nil
      end
    end
    if at then
      out[#out + 1] = { line = at, end_line = at + span - 1, side = n.side, text = n.text }
    else
      lost = lost + 1
    end
  end
  return #out > 0 and out or nil, lost
end

---Resolve a guide record against the current hunks. Sections render their hunks that still
---exist (by content hash); a hunk that changed in place (an edit) is re-anchored by overlap and
---stays in its section marked `edited`; sections that lost hunks are outdated; hunks the guide
---doesn't know go to a final "Not in guide" section.
---@param rec table guide record
---@param hunks revuey.GuideHunk[] current hunks
---@return {title:string, summary:string, sections:revuey.ResolvedSection[], stale:boolean, outdated:integer, new:integer, edited:integer, generator:table}
function M.resolve(rec, hunks)
  local by_hash = {}
  for _, h in ipairs(hunks) do
    by_hash[h.hash] = h
  end
  -- hash matches first (unchanged hunks, wherever they moved), then overlap for the rest
  local used, unmatched = {}, {}
  for si, s in ipairs(rec.sections or {}) do
    for _, a in ipairs(s.hunks or {}) do
      local h = by_hash[a.hash]
      if h and not used[h.hash] then
        used[h.hash] = a
      else
        unmatched[#unmatched + 1] = { a = a, si = si }
      end
    end
  end
  local moved = {}
  if #unmatched > 0 then
    local free = {}
    for _, h in ipairs(hunks) do
      if not used[h.hash] then
        free[#free + 1] = h
      end
    end
    moved = reanchor(unmatched, free)
    for _, h in pairs(moved) do
      if h then
        used[h.hash] = true
      end
    end
  end
  local sections, outdated, edited_total, notes_total, notes_lost = {}, 0, 0, 0, 0
  for _, s in ipairs(rec.sections or {}) do
    local items, missing, hashes, edited = {}, 0, {}, 0
    for _, a in ipairs(s.hunks or {}) do
      local h = by_hash[a.hash]
      local item
      if h and used[h.hash] == a then
        item = { hunk = h, note = a.note }
        hashes[#hashes + 1] = h.hash
      elseif moved[a] then
        item = { hunk = moved[a], note = a.note, edited = true }
        hashes[#hashes + 1] = moved[a].hash
        edited = edited + 1
      elseif moved[a] == nil then
        missing = missing + 1
      end
      if item then
        local lost
        item.line_notes, lost = place_notes(a.line_notes, item.hunk, item.edited)
        notes_total = notes_total + (item.line_notes and #item.line_notes or 0)
        notes_lost = notes_lost + lost
        items[#items + 1] = item
      end
    end
    if missing > 0 then
      outdated = outdated + 1
    end
    edited_total = edited_total + edited
    sections[#sections + 1] = {
      title = s.title,
      overview = s.overview or '',
      items = items,
      missing = missing,
      edited = edited,
      outdated = missing > 0,
      kind = s.other and 'other' or 'section',
      id = M.section_id(hashes),
    }
  end
  local new = {}
  for _, h in ipairs(hunks) do
    if not used[h.hash] then
      new[#new + 1] = { hunk = h }
    end
  end
  if #new > 0 then
    local hashes = vim.tbl_map(function(i)
      return i.hunk.hash
    end, new)
    sections[#sections + 1] = {
      title = 'Not in guide',
      overview = 'Changes made after the guide was generated.',
      items = new,
      missing = 0,
      outdated = false,
      kind = 'new',
      id = M.section_id(hashes),
    }
  end
  return {
    title = (rec.title and rec.title ~= '') and rec.title or 'Guided review',
    summary = rec.summary or '',
    sections = sections,
    stale = outdated > 0 or #new > 0 or edited_total > 0,
    outdated = outdated,
    new = #new,
    edited = edited_total,
    notes = notes_total,
    notes_lost = notes_lost,
    diagram = rec.diagram,
    generator = rec.generator or {},
  }
end

-- ---------------------------------------------------------------------------
-- Storage: <state_dir>/guides/<slug>-<key hash>-<generated_at>-<anchors hash>.json
-- The file name carries the time and the anchor set, so finding the newest guide (or the guide
-- for this exact diff) never decodes more than one file.
-- ---------------------------------------------------------------------------

---Review identity of a guide: the reviewed-state key (repo, branch or layer, base or parent).
---@param st {repo:string, branch:string, base:string}
function M.key(st)
  return { repo = st.repo, branch = st.branch, base = st.base }
end

local function key_prefix(key)
  local slug = (vim.fs.basename(key.repo) .. '-' .. key.branch .. '-' .. key.base):gsub('[^%w%-_.]', '_')
  return slug .. '-' .. vim.fn.sha256(table.concat({ key.repo, key.branch, key.base }, '\0')):sub(1, 12)
end

function M.dir(state_dir)
  return vim.fs.joinpath(state_dir, 'guides')
end

function M.path(dir, key, anchors, generated_at)
  return vim.fs.joinpath(dir, ('%s-%012d-%s.json'):format(key_prefix(key), math.floor(tonumber(generated_at) or 0), anchors))
end

---Guide files of a review key, newest first: {path, time, anchors}.
local function list(dir, key)
  local prefix = key_prefix(key) .. '-'
  local out = {}
  for name, kind in vim.fs.dir(dir) do
    if kind == 'file' and name:sub(1, #prefix) == prefix then
      local t, anchors = name:sub(#prefix + 1):match('^(%d+)-([%w]+)%.json$')
      if t then
        out[#out + 1] = { path = vim.fs.joinpath(dir, name), time = tonumber(t), anchors = anchors }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.time ~= b.time then
      return a.time > b.time
    end
    return a.path > b.path
  end)
  return out
end

---Write a record atomically, checking every step (errors on failure), then keep only the newest
---`keep` guides of its review key.
function M.save(dir, rec, keep)
  vim.fn.mkdir(dir, 'p')
  local path = M.path(dir, rec.key, rec.anchors, rec.generator and rec.generator.generated_at)
  local tmp = path .. '.tmp.' .. vim.fn.getpid()
  local fd, err = io.open(tmp, 'w')
  if not fd then
    error('revuey: cannot write guide: ' .. tostring(err))
  end
  local ok, werr = fd:write(vim.json.encode(rec))
  local cok, cerr = fd:close()
  if not ok or not cok then
    os.remove(tmp)
    error('revuey: cannot write guide: ' .. tostring(werr or cerr))
  end
  local rok, rerr = os.rename(tmp, path)
  if not rok then
    os.remove(tmp)
    error('revuey: cannot write guide: ' .. tostring(rerr))
  end
  keep = keep or 5
  for i, f in ipairs(list(dir, rec.key)) do
    if i > keep and f.path ~= path then
      os.remove(f.path)
    end
  end
  return path
end

local function read(path)
  local fd = io.open(path, 'r')
  if not fd then
    return nil
  end
  local text = fd:read('*a')
  fd:close()
  local ok, rec = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if ok and type(rec) == 'table' and rec.kind == 'revuey-guide' then
    return M.sanitize(rec)
  end
end

---The newest guide for this exact diff if there is one, else the newest guide for the review key.
---@return table? record
function M.load(dir, key, anchors)
  if not vim.uv.fs_stat(dir) then
    return nil
  end
  local files = list(dir, key)
  for _, f in ipairs(files) do
    if f.anchors == anchors then
      local rec = read(f.path)
      if rec then
        return rec
      end
    end
  end
  for _, f in ipairs(files) do
    local rec = read(f.path)
    if rec then
      return rec
    end
  end
end

return M
