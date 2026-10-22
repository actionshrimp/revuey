-- AI guided review: the pure model (no window/buffer UI, no processes).
--
--   * hunk ids and anchors: every hunk of the review gets a short id (h1..hn, diff order) for the
--     model to reference, and an anchor {path, old_start, new_start, header, hash} that survives
--     line shifts (the hash covers the path and the hunk's +/-/context lines, not line numbers);
--   * validation and repair of the model's output (instructed, not trusted);
--   * the persisted guide record, and resolving it against the current hunks (staleness);
--   * section identity (hash of the section's hunk hashes) for reviewed state;
--   * storage under <state_dir>/guides/.
-- Prompt text and schema live in guide_prompt.lua; the CLI call in ai.lua.
local layout = require('revuey.layout')
local diagram_mod = require('revuey.diagram')

local M = {}

M.VERSION = 1

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
---unplaced hunks go to a final "Other changes" section. Zero valid sections is a failure.
---@param raw table|string decoded output, or text to repair
---@param hunks revuey.GuideHunk[]
---@return table? guide {title, summary, sections = {{title, overview, hunks = {{id, note?}}, other?}}}
---@return string|table err_or_warnings error message, or on success {unknown, duplicates, missed, unplaced}
function M.validate(raw, hunks)
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
  for ri, s in ipairs(type(raw.sections) == 'table' and raw.sections or {}) do
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
      local a = M.anchor(by_id[r.id])
      a.note = r.note
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
---@field items {hunk: revuey.GuideHunk, note?: string}[]
---@field missing integer   hunks of the guide no longer in the diff (changed or gone)
---@field outdated boolean
---@field kind 'section'|'other'|'new'
---@field id? string        reviewed-state identity (nil when the section shows no hunks)

---Resolve a guide record against the current hunks. Sections render their hunks that still
---exist (by content hash); sections that lost hunks are outdated; hunks the guide doesn't know
---go to a final "Not in guide" section.
---@param rec table guide record
---@param hunks revuey.GuideHunk[] current hunks
---@return {title:string, summary:string, sections:revuey.ResolvedSection[], stale:boolean, outdated:integer, new:integer, generator:table}
function M.resolve(rec, hunks)
  local by_hash = {}
  for _, h in ipairs(hunks) do
    by_hash[h.hash] = h
  end
  local used = {}
  local sections, outdated = {}, 0
  for _, s in ipairs(rec.sections or {}) do
    local items, missing, hashes = {}, 0, {}
    for _, a in ipairs(s.hunks or {}) do
      local h = by_hash[a.hash]
      if h and not used[h.hash] then
        used[h.hash] = true
        items[#items + 1] = { hunk = h, note = a.note }
        hashes[#hashes + 1] = h.hash
      else
        missing = missing + 1
      end
    end
    if missing > 0 then
      outdated = outdated + 1
    end
    sections[#sections + 1] = {
      title = s.title,
      overview = s.overview or '',
      items = items,
      missing = missing,
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
    stale = outdated > 0 or #new > 0,
    outdated = outdated,
    new = #new,
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
