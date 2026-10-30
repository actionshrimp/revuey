-- Review comments: the data model, anchoring and re-anchoring, storage with merge-on-save, and
-- the event feed. Pure data (JSON files, no window or buffer UI), so it runs headless (tests and
-- the `bin/revuey comments|watch|reply` CLI).
--
--   * A comment is anchored to a line range on one side of a file's diff (`new` for added and
--     context lines, `old` for deleted ones), or to a whole file (`file_level`). The anchor keeps
--     the review unit and parent hunk it was made in (units.lua) with the offset of its first
--     line there, plus `context_hash`: a hash of the commented lines and two lines either side.
--   * Placement (`place`), on every render: the same unit (content identical, so only shifted)
--     or the same hunk puts the comment at the same offset; otherwise the nearest window of the
--     same file and side whose hash matches; then (within TEXT_RADIUS lines) the nearest window
--     with the same lines when only their context changed (lines with a few word characters);
--     otherwise the comment is `outdated` and keeps its last known lines and the code snippet
--     stored when it was made.
--   * Storage: one `<state file>.comments.json` per review scope, next to the reviewed marks.
--     Saves re-read the file and merge per comment: last writer wins by `updated_at`, deletes
--     are tombstones (so a delete and an older edit elsewhere resolve to the delete), and thread
--     replies merge by reply id (an agent's reply survives a concurrent edit of the body).
--     Comments are never pruned.
--   * Events: one JSON line per change in `<state file>.events.jsonl` (rotated to `.1` past
--     EVENTS_MAX bytes), for `bin/revuey watch`.
local M = {}
local event_queue -- path -> encoded event lines not yet appended (the lock was busy)

M.VERSION = 1
M.EVENTS_MAX = 1024 * 1024
M.EVENT_SNIPPET_MAX = 200 -- snippet lines in an event (the comment keeps all of them)
M.CONTEXT = 2 -- lines of context either side in context_hash
M.EVENT_KINDS = {
  created = true, updated = true, deleted = true, resolved = true, replied = true, sent = true, acked = true,
  accepted = true, dismissed = true, -- AI findings, agent comments: triage (dismissed with status saved: restored)
}
-- Not about a comment (M.switch_event): the worktree was switched to another stack layer while an
-- agent was connected. Delivered like a message by `watch --messages`, never caught up.
M.SWITCHED = 'switched'

---@class revuey.CommentAnchor
---@field path string
---@field side 'new'|'old'
---@field start_line? integer       nil for a file-level comment
---@field end_line? integer
---@field unit_key? string          review unit the range was made in (units.lua)
---@field unit_line? integer        offset of the first commented line in that unit (0-based)
---@field hunk_key? string          its parent hunk
---@field hunk_line? integer        index of the first commented line in the hunk's lines
---@field context_hash? string
---@field text_hash? string        the commented lines alone (to spot repeated copies)
---@field context_lines? string[]   short hashes of the context lines (before, after; '' trivial),
---                                 only when the lines hold distinctive words (text tier allowed)
---@field snippet? string[]         the commented diff rows when made, with +/-/space markers

---@class revuey.CommentReply
---@field id string
---@field author {kind:'user'|'ai'|'agent', name?:string}
---@field body string
---@field created_at integer        ms since the epoch
---@field updated_at integer
---@field deleted? boolean

---@class revuey.Comment
---@field id string                 sortable (creation time first), unique
---@field anchor revuey.CommentAnchor
---@field body string               markdown
---@field author {kind:'user'|'ai'|'agent', name?:string}
---@field status 'draft'|'saved'|'resolved'|'dismissed'|'accepted'
---@field in_review boolean         "add to review": posted by the next review submit (`ci`)
---@field thread revuey.CommentReply[]
---@field created_at integer        ms since the epoch
---@field updated_at integer
---@field file_level boolean
---@field outdated boolean          derived: could not be placed in the current review
---@field draft? string             unsaved edit of a saved comment (editor closed by accident)
---@field deleted? boolean          tombstone
---@field sent_at? integer          last sent to an agent session (ms); see M.delivery
---@field sent_reply? string        the thread reply that was sent (a follow-up), else the body
---@field sent_session? string      the review session (nvim pid) that sent it: watchers attached
---                                 to another live session leave it alone
---@field delivered_at? integer     a `watch` printed it to an agent (not printed again on catch-up)
---@field acked_at? integer         the agent acknowledged it (`bin/revuey ack`, or a reply)
---@field answered_at? integer      the agent replied (`bin/revuey reply`)
---@field forge_reply? table        a local reply to a GitHub review thread (`cr` on one):
---                                 {thread_id, pr, repo, url, comment_id, database_id}; a review
---                                 submit posts it as a reply in that thread
---@field forge_post? table         where it is on GitHub once a submit sent it (forge_post_view,
---                                 its state machine): {state = 'sending'|'unknown'|'pending'|
---                                 'posted', pr, repo, review_id? | ledger?, payload (what was
---                                 sent), before?, sent_at, thread_id?, comment_id?, database_id?,
---                                 url?, posted_at?}
---@field ai? table                 an AI review finding (ai_review.lua): {review, severity, title,
---                                 suggestion?, hunk, line?, end_line?, author? (once accepted),
---                                 accepted_at?, dismissed_at?}
---@field agent? table              a coding agent's comment the user triaged (`ca`/`cn`):
---                                 {author (the agent), accepted_at?, dismissed_at?}; accepted,
---                                 `author` is the user's

---Milliseconds since the epoch.
function M.now_ms()
  local s, us = vim.uv.gettimeofday()
  return s * 1000 + math.floor(us / 1000)
end

local seeded = false
local last_ms, last_suffix = -1, 0
local SUFFIX_MAX = 0xfffff
---A sortable unique id: 11 hex digits of milliseconds, then 5 more. The first id of a
---millisecond gets a random suffix (seeded with the pid, so other processes are unlikely to
---collide); later ones in the same (or an earlier) millisecond count up from the last id, carrying
---into the milliseconds, so ids from one process are strictly increasing and never repeat.
function M.new_id(ms)
  if not seeded then
    seeded = true
    math.randomseed((vim.uv.hrtime() + vim.uv.os_getpid() * 7919) % 2147483647)
  end
  ms = ms or M.now_ms()
  local suffix
  if ms <= last_ms then
    ms, suffix = last_ms, last_suffix + 1
    if suffix > SUFFIX_MAX then
      ms, suffix = ms + 1, 0
    end
  else
    -- leave room to count up within the millisecond
    suffix = math.random(0, 0x7ffff)
  end
  last_ms, last_suffix = ms, suffix
  return ('%011x%05x'):format(ms, suffix)
end

-- ---------------------------------------------------------------------------
-- Anchors
-- ---------------------------------------------------------------------------

local MARK = { add = '+', del = '-', ctx = ' ' }

---Where line `li` of a hunk sits in new-side order: its new line, or for a deleted line just
---before the next new-side line of the hunk (n - 0.5), so comments sort as the diff shows them.
local function sort_line(hk, li)
  local l = hk.lines[li]
  if l.new_lnum then
    return l.new_lnum
  end
  for k = li + 1, #hk.lines do
    if hk.lines[k].new_lnum then
      return hk.lines[k].new_lnum - 0.5
    end
  end
  for k = li - 1, 1, -1 do
    if hk.lines[k].new_lnum then
      return hk.lines[k].new_lnum + 0.5
    end
  end
  return math.max(hk.new_start, 1) - 0.5
end
M.sort_line = sort_line

---The side a line kind belongs to and its line number there.
local function side_lnum(l, side)
  if side == 'new' then
    return l.kind ~= 'del' and l.new_lnum or nil
  end
  return l.kind ~= 'add' and l.old_lnum or nil
end
M.side_lnum = side_lnum

---Hash of lines `first..last` of a side and CONTEXT lines either side. `get_line(lnum)` returns
---the text or nil (outside the file).
function M.window_hash(get_line, first, last)
  local parts = {}
  for l = first - M.CONTEXT, last + M.CONTEXT do
    local t = get_line(l)
    parts[#parts + 1] = t or '\1'
  end
  return vim.fn.sha256(table.concat(parts, '\n')):sub(1, 16)
end

---Hash of lines `first..last` alone (no context), for the last re-anchoring tier.
function M.text_hash(get_line, first, last)
  local parts = {}
  for l = first, last do
    parts[#parts + 1] = get_line(l) or '\1'
  end
  return vim.fn.sha256(table.concat(parts, '\n')):sub(1, 16)
end

M.TEXT_RADIUS = 100 -- the text-only tier only looks this many lines either side

-- Words that say nothing about where a line is (keywords and fillers of common languages).
local BOILERPLATE = {}
for w in ([[and break do else elseif end false for function if in local nil not or repeat return
  then true until while const let var new this self class def import from export default public
  private protected static void int string bool boolean null undefined async await try catch
  finally throw throws switch case break continue pub fn mut use struct enum impl type interface
  package func range yield lambda with as is elif pass none module require val get set]]):gmatch('%S+') do
  BOILERPLATE[w] = true
end

---Distinct words of at least three letters that are not boilerplate, in `lines`.
function M.distinctive_words(lines)
  local seen, n = {}, 0
  for _, l in ipairs(lines) do
    for w in (l or ''):gmatch('[%a_][%w_]*') do
      local lw = w:lower()
      if #w >= 3 and not BOILERPLATE[lw] and not seen[lw] then
        seen[lw] = true
        n = n + 1
      end
    end
  end
  return n
end

M.MIN_WORDS = 2 -- distinctive words the commented lines need for the text tier

local function line_hash(t)
  if not t or not t:find('%w') then
    return '' -- missing or trivial (`}`, blank): never counts as a context match
  end
  return vim.fn.sha256(t):sub(1, 8)
end

---Hashes of the CONTEXT lines either side of `first..last` (before, then after), '' for lines that
---are missing or trivial.
function M.context_lines(get_line, first, last)
  local out = {}
  for l = first - M.CONTEXT, first - 1 do
    out[#out + 1] = line_hash(get_line(l))
  end
  for l = last + 1, last + M.CONTEXT do
    out[#out + 1] = line_hash(get_line(l))
  end
  return out
end

---How many of the stored context lines match around `first..last`.
local function context_matches(stored, get_line, first, last)
  local now = M.context_lines(get_line, first, last)
  local n = 0
  for i, hsh in ipairs(stored or {}) do
    if hsh ~= '' and hsh == now[i] then
      n = n + 1
    end
  end
  return n
end

---Anchor for diff rows of one file (side-table entries of kind add/del/ctx, in order). The side
---is `new` when any row has a new-side line (deleted rows between them stay in the snippet),
---`old` when all rows are deleted lines.
---@param files revuey.FileDiff[]
---@param U revuey.Units
---@param entries revuey.LineEntry[]
---@param get_line fun(path:string, side:string, lnum:integer):string?
---@return revuey.CommentAnchor?
function M.anchor_from_rows(files, U, entries, get_line)
  local code = {}
  for _, e in ipairs(entries) do
    if (e.kind == 'add' or e.kind == 'del' or e.kind == 'ctx') and e.file_idx and e.hunk_idx then
      if not code[1] or code[1].file_idx == e.file_idx then
        code[#code + 1] = e
      end
    end
  end
  if #code == 0 then
    return nil
  end
  local fi = code[1].file_idx
  local f = files[fi]
  local side = 'old'
  for _, e in ipairs(code) do
    if e.kind ~= 'del' then
      side = 'new'
      break
    end
  end
  local first_e, last_e, lo, hi
  local snippet = {}
  for _, e in ipairs(code) do
    local l = f.hunks[e.hunk_idx].lines[e.line_idx]
    snippet[#snippet + 1] = MARK[l.kind] .. l.text
    local n = side_lnum(l, side)
    if n then
      first_e = first_e or e
      last_e = e
      lo = math.min(lo or n, n)
      hi = math.max(hi or n, n)
    end
  end
  local a = { path = f.path, side = side, start_line = lo, end_line = hi, snippet = snippet }
  a.sort_line = sort_line(f.hunks[first_e.hunk_idx], first_e.line_idx)
  local u = require('revuey.units').at_line(U, fi, first_e.hunk_idx, first_e.line_idx)
  if u then
    a.unit_key, a.hunk_key = u.key, u.hunk
    if last_e.hunk_idx == first_e.hunk_idx then
      a.hunk_line = first_e.line_idx
      if u.whole_file or last_e.line_idx <= u.last then
        a.unit_line = first_e.line_idx - (u.first or 1)
      end
    end
  end
  local function get(l)
    return get_line(f.path, side, l)
  end
  a.context_hash = M.window_hash(get, lo, hi)
  -- lines that say something distinctive (not `end`, `return nil` or `}`): the text alone, with
  -- part of its old context, can re-anchor them
  local texts = {}
  for l = lo, hi do
    texts[#texts + 1] = get(l)
  end
  a.text_hash = M.text_hash(get, lo, hi)
  if M.distinctive_words(texts) >= M.MIN_WORDS then
    a.context_lines = M.context_lines(get, lo, hi)
  end
  return a
end

M.MAX_RANGE = 200 -- lines a comment from the shell may span

---Line ranges a side of a file's hunks shows: { {first, last}, ... } in file order.
function M.hunk_ranges(f, side)
  local out = {}
  for _, hk in ipairs(f and f.hunks or {}) do
    local lo, hi
    for _, l in ipairs(hk.lines) do
      local n = side_lnum(l, side)
      if n then
        lo, hi = math.min(lo or n, n), math.max(hi or n, n)
      end
    end
    if lo then
      out[#out + 1] = { lo, hi }
    end
  end
  return out
end

---The changed files of a review that `path` is not one of, as a message listing a few of them.
local function not_changed(files, path)
  local paths = {}
  for _, f in ipairs(files) do
    if f.old_path == path and f.path ~= path then
      return ('%s was renamed to %s in this review: use --path %s (with --side old for its old lines)'):format(path, f.path, f.path)
    end
    paths[#paths + 1] = f.path
  end
  if #paths == 0 then
    return ('%s is not a changed file in this review (the review has no changes)'):format(path)
  end
  local shown = vim.list_slice(paths, 1, 8)
  local more = #paths > #shown and ('\n  ... and %d more'):format(#paths - #shown) or ''
  return ('%s is not a changed file in this review; changed files:\n  %s%s'):format(path, table.concat(shown, '\n  '), more)
end

---"Nearest hunks" message for lines `first..last` of a side that the diff does not show.
local function not_in_diff(f, side, first, last)
  local loc = first == last and ('%s:%d'):format(f.path, first) or ('%s:%d-%d'):format(f.path, first, last)
  local ranges = M.hunk_ranges(f, side)
  if #ranges == 0 then
    local why = #f.hunks == 0 and 'the file has no text diff (binary, too large, a rename or a mode change)'
      or ('the diff has no %s side for it (%s)'):format(side, side == 'old' and 'an added file' or 'a deleted file')
    return ('%s (%s) is not in the diff: %s. Comment on the whole file with --file'):format(loc, side, why)
  end
  local function dist(r)
    if last < r[1] then
      return r[1] - last
    elseif first > r[2] then
      return first - r[2]
    end
    return 0
  end
  local near = vim.deepcopy(ranges)
  table.sort(near, function(x, y)
    local dx, dy = dist(x), dist(y)
    if dx ~= dy then
      return dx < dy
    end
    return x[1] < y[1]
  end)
  near = vim.list_slice(near, 1, 3)
  table.sort(near, function(x, y)
    return x[1] < y[1]
  end)
  local txt = vim.tbl_map(function(r)
    return r[1] == r[2] and tostring(r[1]) or (r[1] .. '-' .. r[2])
  end, near)
  return ('%s (%s) is not in the diff: every line must be inside a hunk on that side. Nearest hunk%s: %s %s. Pick lines inside a hunk (--side old for deleted lines), or comment on the whole file with --file'):format(
    loc,
    side,
    #near == 1 and '' or 's',
    side,
    table.concat(txt, ', ')
  )
end

---Anchor for lines given by number (`bin/revuey comment`), from the review's diff, without a UI:
---the same hashes, snippet and order as a selection of those rows in the UI. The unit and hunk
---are left for the UI's placement to fill in (it re-anchors by `context_hash` and stores them,
---see apply_placement). Every line must be shown on that side (inside a hunk); without
---`start_line` the anchor is file level. Returns nil and a message for a path that is not in the
---review or lines outside the hunks.
---@param files revuey.FileDiff[]
---@param U revuey.Units
---@param want {path:string, side?:'new'|'old', start_line?:integer, end_line?:integer}
---@param get_line fun(path:string, side:string, lnum:integer):string?
---@return revuey.CommentAnchor?, string? err
function M.anchor_for_lines(files, U, want, get_line)
  local path = want.path
  local fi = U.by_path[path]
  if not fi then
    return nil, not_changed(files, path)
  end
  if not want.start_line then
    return M.file_anchor(path)
  end
  local f = files[fi]
  local side = want.side or 'new'
  local first, last = want.start_line, want.end_line or want.start_line
  local at = {} -- lnum -> the row showing it on that side
  for hi, hk in ipairs(f.hunks) do
    for li, l in ipairs(hk.lines) do
      local n = side_lnum(l, side)
      if n and n >= first and n <= last and not at[n] then
        at[n] = { hi = hi, li = li }
      end
    end
  end
  for n = first, last do
    if not at[n] then
      return nil, not_in_diff(f, side, first, last)
    end
  end
  local a1, a2 = at[first], at[last]
  local snippet = {}
  if a1.hi == a2.hi then
    -- every row from the first line to the last, like a selection (other-side rows included)
    local hk = f.hunks[a1.hi]
    for li = a1.li, a2.li do
      local l = hk.lines[li]
      snippet[#snippet + 1] = MARK[l.kind] .. l.text
    end
  else
    for n = first, last do
      local l = f.hunks[at[n].hi].lines[at[n].li]
      snippet[#snippet + 1] = MARK[l.kind] .. l.text
    end
  end
  local a = { path = path, side = side, start_line = first, end_line = last, snippet = snippet }
  a.sort_line = sort_line(f.hunks[a1.hi], a1.li)
  local function get(l)
    return get_line(path, side, l)
  end
  a.context_hash = M.window_hash(get, first, last)
  local texts = {}
  for l = first, last do
    texts[#texts + 1] = get(l)
  end
  a.text_hash = M.text_hash(get, first, last)
  if M.distinctive_words(texts) >= M.MIN_WORDS then
    a.context_lines = M.context_lines(get, first, last)
  end
  return a
end

---Anchor for a whole file.
function M.file_anchor(path)
  return { path = path, side = 'new' }
end

---New comment (not stored yet).
---@param anchor revuey.CommentAnchor
---@param body string
---@param opts? {author?:table, status?:string, now?:integer, id?:string}
---@return revuey.Comment
function M.new(anchor, body, opts)
  opts = opts or {}
  local now = opts.now or M.now_ms()
  return {
    id = opts.id or M.new_id(now),
    anchor = anchor,
    body = body,
    author = opts.author or { kind = 'user' },
    status = opts.status or 'saved',
    in_review = false,
    thread = {},
    created_at = now,
    updated_at = now,
    file_level = anchor.start_line == nil,
    outdated = false,
  }
end

---"src/cart.ts:12-14", "src/cart.ts:12" or "src/cart.ts" (file level).
function M.location(c)
  local a = c.anchor
  if c.file_level or not a.start_line then
    return a.path
  end
  if a.end_line and a.end_line ~= a.start_line then
    return ('%s:%d-%d'):format(a.path, a.start_line, a.end_line)
  end
  return ('%s:%d'):format(a.path, a.start_line)
end

-- ---------------------------------------------------------------------------
-- Placement (re-anchoring)
-- ---------------------------------------------------------------------------

---@class revuey.CommentPlacement
---@field start_line? integer
---@field end_line? integer
---@field outdated boolean
---@field how 'file'|'unit'|'hunk'|'hash'|'outdated'|'missing'
---@field unit? revuey.Unit         unit holding the first line (when placed)
---@field hunk_line? integer

---Placement context for a review: its files and units, and full side texts when available.
---@param files revuey.FileDiff[]
---@param U revuey.Units
---@param get_text? fun(path:string, side:string):string?  full text of a side (nil: shown lines only)
function M.context(files, U, get_text)
  local ctx = { files = files, U = U, shown = {}, lines = {} }
  ---lnum -> {fi, hi, li} of the rows shown on a side, built lazily per path and side
  function ctx.rows(path, side)
    local key = path .. '\0' .. side
    if ctx.shown[key] then
      return ctx.shown[key]
    end
    local t = { by_lnum = {}, sorted = {} }
    local fi = U.by_path[path]
    local f = fi and files[fi]
    for hi, hk in ipairs(f and f.hunks or {}) do
      for li, l in ipairs(hk.lines) do
        local n = side_lnum(l, side)
        if n and not t.by_lnum[n] then
          t.by_lnum[n] = { fi = fi, hi = hi, li = li, text = l.text }
          t.sorted[#t.sorted + 1] = n
        end
      end
    end
    table.sort(t.sorted)
    ctx.shown[key] = t
    return t
  end
  function ctx.get_line(path, side, lnum)
    local key = path .. '\0' .. side
    local lines = ctx.lines[key]
    if lines == nil then
      local text = get_text and get_text(path, side)
      lines = text and vim.split((text:gsub('\r\n', '\n'):gsub('\n$', '')), '\n', { plain = true }) or false
      ctx.lines[key] = lines
    end
    if lines then
      return lines[lnum]
    end
    local r = ctx.rows(path, side).by_lnum[lnum]
    return r and r.text or nil
  end
  return ctx
end

local function at_offset(ctx, u, li, a)
  local f = ctx.files[u.file_idx]
  local hk = f and u.hunk_idx and f.hunks[u.hunk_idx]
  local l = hk and hk.lines[li]
  local n = l and side_lnum(l, a.side)
  if not n then
    return nil
  end
  local first = n
  return {
    start_line = first,
    end_line = first + (a.end_line - a.start_line),
    outdated = false,
    unit = u,
    hunk_line = li,
    sort_line = sort_line(hk, li),
  }
end

---Where comment `c` goes in the review described by `ctx` (see M.context).
---@param c revuey.Comment
---@return revuey.CommentPlacement
function M.place(c, ctx)
  local a = c.anchor
  local U = ctx.U
  -- a file renamed since: follow it
  local path = a.path
  if not U.by_path[path] then
    for _, f in ipairs(ctx.files) do
      if f.old_path == path and f.path ~= path and f.status == 'R' then
        path = f.path
        break
      end
    end
  end
  local fi = U.by_path[path]
  if c.file_level or not a.start_line then
    return { outdated = fi == nil, how = fi and 'file' or 'missing', path = path ~= a.path and path or nil }
  end
  local out = { start_line = a.start_line, end_line = a.end_line, outdated = true, how = fi and 'outdated' or 'missing' }
  if not fi then
    return out
  end
  -- 1. the same unit (identical content, maybe shifted), then the same hunk
  local u = a.unit_key and U.by_key[a.unit_key]
  if u and u.path == path and a.unit_line and not u.whole_file then
    local p = at_offset(ctx, u, (u.first or 1) + a.unit_line, a)
    if p then
      p.how = 'unit'
      p.path = path ~= a.path and path or nil
      return p
    end
  end
  local hunk_units = a.hunk_key and U.by_hunk[a.hunk_key]
  if hunk_units and hunk_units[1] and hunk_units[1].path == path and a.hunk_line and not hunk_units[1].whole_file then
    local p = at_offset(ctx, hunk_units[1], a.hunk_line, a)
    if p then
      p.unit = require('revuey.units').at_line(U, p.unit.file_idx, p.unit.hunk_idx, a.hunk_line) or p.unit
      p.how = 'hunk'
      p.path = path ~= a.path and path or nil
      return p
    end
  end
  -- 2. the nearest window of shown lines with the same context hash; 3. the nearest one (not too
  -- far) with the same lines, when only the context around them changed
  local rows = ctx.rows(path, a.side)
  local n = a.end_line - a.start_line
  local function get(l)
    return ctx.get_line(path, a.side, l)
  end
  ---All shown windows whose hash matches (within `radius` of the last known line), nearest first.
  local function search(hash, fn, radius)
    local hits = {}
    for _, p in ipairs(rows.sorted) do
      local d = math.abs(p - a.start_line)
      if rows.by_lnum[p + n] and (not radius or d <= radius) then
        local all = true
        for l = p + 1, p + n - 1 do
          if not rows.by_lnum[l] then
            all = false
            break
          end
        end
        if all and fn(get, p, p + n) == hash then
          hits[#hits + 1] = p
        end
      end
    end
    table.sort(hits, function(x, y)
      local dx, dy = math.abs(x - a.start_line), math.abs(y - a.start_line)
      if dx ~= dy then
        return dx < dy
      end
      return x < y
    end)
    return hits
  end
  -- every copy of the commented lines (whatever their context), nearest first
  local copies = a.text_hash and search(a.text_hash, M.text_hash) or nil
  for _, tier in ipairs({
    { hash = a.context_hash, fn = M.window_hash, how = 'hash' },
    { hash = a.context_lines and a.text_hash, fn = M.text_hash, how = 'text', radius = M.TEXT_RADIUS },
  }) do
    local hits = tier.hash and search(tier.hash, tier.fn, tier.radius) or {}
    local best = hits[1]
    if best and tier.how == 'hash' and copies and #copies > 1 and copies[1] ~= best then
      -- the lines are repeated, and the window with the old context is not the nearest copy:
      -- the comment's own copy changed around it, and this is another one (when in doubt the
      -- comment is outdated, never misplaced)
      return out
    end
    if tier.how == 'text' then
      -- the lines alone are weaker evidence: they must be the only copy around, and keep some of
      -- their old neighbours
      if #hits ~= 1 or context_matches(a.context_lines, get, best, best + n) == 0 then
        best = nil
      end
    end
    if best then
      local r = rows.by_lnum[best]
      local unit = require('revuey.units').at_line(U, r.fi, r.hi, r.li)
      local r2 = rows.by_lnum[best + n]
      return {
        -- the hunk line of the last commented line, when in the same hunk (apply_placement)
        end_hunk_line = r2 and r2.fi == r.fi and r2.hi == r.hi and r2.li or nil,
        start_line = best,
        end_line = best + n,
        outdated = false,
        how = tier.how,
        unit = unit,
        hunk_line = r.li,
        sort_line = sort_line(ctx.files[r.fi].hunks[r.hi], r.li),
        path = path ~= a.path and path or nil,
      }
    end
  end
  return out
end

---A line comment whose anchor has no unit or hunk yet (made by `bin/revuey comment`): the UI
---stores the ones its placement finds, even on a live reload (once: then they are set).
function M.unresolved(c)
  local a = c and c.anchor
  return a ~= nil and not c.file_level and a.start_line ~= nil and a.unit_key == nil and a.hunk_key == nil
end

---Update a comment's stored anchor from its placement ("last known" lines, unit and hunk; the
---outdated flag). Returns true when anything changed. `updated_at` is left alone: this is
---derived state, and every instance derives the same.
function M.apply_placement(c, p)
  local changed = false
  local function set(t, k, v)
    if t[k] ~= v then
      t[k] = v
      changed = true
    end
  end
  set(c, 'outdated', p.outdated and true or false)
  if p.path and not p.outdated then
    set(c.anchor, 'path', p.path) -- the file was renamed
  end
  if not p.outdated and p.start_line then
    local a = c.anchor
    set(a, 'start_line', p.start_line)
    set(a, 'end_line', p.end_line)
    if p.sort_line then
      set(a, 'sort_line', p.sort_line)
    end
    if p.unit then
      -- an anchor made without the UI (`bin/revuey comment`) has no unit yet: this placement
      -- gives it one, with the offsets a selection of the same rows would have had
      local fresh = M.unresolved(c)
      set(a, 'unit_key', p.unit.key)
      set(a, 'hunk_key', p.unit.hunk)
      if fresh and p.hunk_line then
        set(a, 'hunk_line', p.hunk_line)
        if p.unit.whole_file or (p.end_hunk_line and p.end_hunk_line <= (p.unit.last or p.end_hunk_line)) then
          set(a, 'unit_line', p.hunk_line - (p.unit.first or 1))
        end
      elseif a.hunk_line ~= nil or a.unit_line ~= nil then
        set(a, 'hunk_line', p.hunk_line)
        set(a, 'unit_line', p.hunk_line - (p.unit.first or 1))
      end
    end
  end
  return changed
end

-- ---------------------------------------------------------------------------
-- Merging
-- ---------------------------------------------------------------------------

local function newer(a, b, prefer_a)
  local ta, tb = a.updated_at or 0, b.updated_at or 0
  if ta ~= tb then
    return ta > tb
  end
  return prefer_a
end

---Merge two versions of one comment (either may be nil): last writer wins by `updated_at`
---(ties: `a` when `prefer_a`), a tombstone wins over older versions, thread replies are
---merged by id (each reply last writer wins too).
---@return revuey.Comment?
function M.merge(a, b, prefer_a)
  if not a then
    return b
  end
  if not b then
    return a
  end
  local win, lose
  if newer(a, b, prefer_a) then
    win, lose = a, b
  else
    win, lose = b, a
  end
  if win.deleted then
    return win
  end
  local out = vim.deepcopy(win)
  -- delivery timestamps only move forward: an ack from the CLI survives a concurrent edit in the
  -- UI, and the newest send (with the reply it sent) wins
  if not lose.deleted then
    if (lose.sent_at or 0) > (out.sent_at or 0) then
      out.sent_at, out.sent_reply, out.sent_session = lose.sent_at, lose.sent_reply, lose.sent_session
    end
    for _, k in ipairs({ 'delivered_at', 'acked_at', 'answered_at' }) do
      if (lose[k] or 0) > (out[k] or 0) then
        out[k] = lose[k]
      end
    end
  end
  if not lose.deleted and (lose.thread and #lose.thread > 0) then
    local by = {}
    local order = {}
    for _, src in ipairs({ { t = win.thread or {}, pref = true }, { t = lose.thread, pref = false } }) do
      for _, r in ipairs(src.t) do
        local cur = by[r.id]
        if not cur then
          order[#order + 1] = r.id
          by[r.id] = r
        elseif newer(r, cur, false) then
          by[r.id] = r
        end
      end
    end
    out.thread = {}
    for _, id in ipairs(order) do
      out.thread[#out.thread + 1] = vim.deepcopy(by[id])
    end
    table.sort(out.thread, function(x, y)
      if (x.created_at or 0) ~= (y.created_at or 0) then
        return (x.created_at or 0) < (y.created_at or 0)
      end
      return x.id < y.id
    end)
    -- a reply newer than the winning body still counts as the latest change
    for _, r in ipairs(out.thread) do
      out.updated_at = math.max(out.updated_at or 0, r.updated_at or 0)
    end
  end
  return out
end

---Merge two id -> comment maps. `prefer` (set of ids, or true for all) breaks ties toward `a`.
function M.merge_all(a, b, prefer)
  local out = {}
  for id, c in pairs(b) do
    out[id] = c
  end
  for id, c in pairs(a) do
    out[id] = M.merge(c, out[id], prefer == true or (type(prefer) == 'table' and prefer[id]) or false)
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------

---What the comments file and events record about a loaded review (review.lua; `stack` and
---`scope` set when it is a stack scope): export headers, CLI filters.
function M.review_info(r)
  local info = {
    repo = r.state.repo,
    branch = r.branch,
    base = r.base,
    state_branch = r.state.branch,
    state_base = r.state.base,
    head = r.head,
    merge_base = r.merge_base,
    mode = r.mode,
    scope = 'branch',
  }
  if r.stack and r.scope then
    if r.scope.kind == 'full' then
      info.scope = 'full'
      info.layers = vim.tbl_map(function(l)
        return l.name
      end, r.stack.layers)
    else
      info.scope = 'layer'
    end
  end
  return info
end

---Comments file of a review scope: next to its reviewed-marks file (state.file_for).
function M.path_for(state_path)
  return (state_path:gsub('%.json$', '')) .. '.comments.json'
end

---Events file of a review scope.
function M.events_path_for(state_path)
  return (state_path:gsub('%.json$', '')) .. '.events.jsonl'
end

local backup_seq = 0

---Decoded comments file, or nil (missing; an undecodable file is moved aside, or with `readonly`
---only reported on stderr).
function M.read(path, readonly)
  local fd = io.open(path, 'r')
  if not fd then
    return nil
  end
  local text = fd:read('*a')
  fd:close()
  local ok, data = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if ok and type(data) == 'table' and type(data.comments) == 'table' then
    -- an empty object may come back as a list
    if vim.islist(data.comments) and #data.comments == 0 then
      data.comments = {}
    end
    for _, c in pairs(data.comments) do
      if type(c) == 'table' and not c.deleted then
        c.thread = type(c.thread) == 'table' and c.thread or {}
        c.anchor = type(c.anchor) == 'table' and c.anchor or { path = '?', side = 'new' }
      end
    end
    return data
  end
  if text ~= '' then
    if readonly then
      io.stderr:write('revuey: cannot read ' .. path .. ' (not valid JSON); skipped\n')
      return nil
    end
    backup_seq = backup_seq + 1
    os.rename(path, ('%s.corrupt-%d-%d-%d'):format(path, os.time(), vim.uv.os_getpid(), backup_seq))
  end
  return nil
end

---@class revuey.CommentStore
---@field path string
---@field review table              review info (repo, branch, base, scope...) as last saved
---@field comments table<string, revuey.Comment>  includes tombstones
---@field _dirty table<string, boolean>

---@return revuey.CommentStore
---@param opts? {readonly?:boolean}
function M.load(path, opts)
  local data = M.read(path, opts and opts.readonly) or {}
  local store = { path = path, review = data.review or {}, comments = data.comments or {}, _dirty = {} }
  M.recover(store, opts and opts.readonly)
  return store
end

---Merge recovery files (comments an instance could not save before it quit, lock.lua): last
---writer wins as usual. Saves and removes them, unless `readonly`.
function M.recover(store, readonly)
  local lock = require('revuey.lock')
  local found = lock.recovery_files(store.path)
  if #found == 0 then
    return
  end
  for _, f in ipairs(found) do
    local fd = io.open(f, 'r')
    if fd then
      local ok, data = pcall(vim.json.decode, fd:read('*a'), { luanil = { object = true, array = true } })
      fd:close()
      if ok and type(data) == 'table' and type(data.comments) == 'table' then
        for id, c in pairs(data.comments) do
          if type(c) == 'table' then
            if not c.deleted then
              c.thread = type(c.thread) == 'table' and c.thread or {}
            end
            local merged = M.merge(c, store.comments[id], true)
            if merged ~= store.comments[id] then
              store.comments[id] = merged
              store._dirty[id] = true
            end
          end
        end
      end
    end
  end
  if not readonly and pcall(M.save, store) and not lock.pending(store.path) then
    for _, f in ipairs(found) do
      os.remove(f)
    end
  end
end

local function encode(store)
  local comments = next(store.comments) and store.comments or vim.empty_dict()
  return vim.json.encode({ version = M.VERSION, review = store.review, comments = comments })
end

---Persist: re-read the file, merge (this instance's changed comments win ties), write a temp
---file and rename it. Pending changes are kept on failure. Errors on failure.
---@param store revuey.CommentStore
---@param review? table review info to record (repo, branch, base, scope...)
function M.save(store, review)
  vim.fn.mkdir(vim.fs.dirname(store.path), 'p')
  -- read, merge and rename under a lock: two processes (two Neovims, the CLI) saving at once
  -- must not both start from the old file. In the UI a busy lock defers the save to a timer
  -- (lock.save); the changes stay dirty in memory meanwhile.
  local lock = require('revuey.lock')
  return lock.save(store.path, function()
    return lock.with(store.path, function()
      return M._save_locked(store, review)
    end)
  end, function()
    -- still blocked at quit: the dirty comments go to a recovery file (merged on the next load)
    local dirty = {}
    for id in pairs(store._dirty) do
      dirty[id] = store.comments[id]
    end
    if next(dirty) then
      lock.write_file(lock.recovery_path(store.path), vim.json.encode({ comments = dirty }))
    end
  end)
end

function M._save_locked(store, review)
  local disk = M.read(store.path) or {}
  local merged = M.merge_all(store.comments, disk.comments or {}, store._dirty)
  -- tombstones are kept forever (one small file per scope), so an instance idle for any length of
  -- time can never resurrect a deleted comment
  local out = { path = store.path, review = review or store.review or disk.review or {}, comments = merged }
  if not review and disk.review and next(disk.review) then
    out.review = vim.tbl_extend('keep', store.review or {}, disk.review)
  end
  local tmp = ('%s.tmp.%d.%d'):format(store.path, vim.uv.os_getpid(), math.random(0, 0xffffff))
  local fd, err = io.open(tmp, 'w')
  if not fd then
    error('revuey: cannot write comments: ' .. tostring(err))
  end
  local ok, werr = fd:write(encode(out))
  local cok, cerr = fd:close()
  if not ok or not cok then
    os.remove(tmp)
    error('revuey: cannot write comments: ' .. tostring(werr or cerr))
  end
  local rok, rerr = os.rename(tmp, store.path)
  if not rok then
    os.remove(tmp)
    error('revuey: cannot write comments: ' .. tostring(rerr))
  end
  store.comments = merged
  store.review = out.review
  store._dirty = {}
end

---Merge the file into memory (another instance or the CLI changed it). Pending local changes win
---ties. Returns true when anything visible changed.
---@param store revuey.CommentStore
function M.reload(store)
  local disk = M.read(store.path)
  if not disk then
    return false
  end
  local merged = M.merge_all(store.comments, disk.comments or {}, store._dirty)
  local changed = not vim.deep_equal(merged, store.comments)
  store.comments = merged
  if disk.review and next(disk.review) then
    store.review = store.review and next(store.review) and store.review or disk.review
  end
  return changed
end

local function touch(store, c, now)
  now = now or M.now_ms()
  local prev = store.comments[c.id]
  c.updated_at = math.max(now, ((prev and prev.updated_at) or 0) + 1, (c.updated_at or 0))
  store.comments[c.id] = c
  store._dirty[c.id] = true
  return c
end

---Add or replace a comment (bumps updated_at). In memory until `save`.
function M.put(store, c, now)
  return touch(store, c, now)
end

---Get a live (not deleted) comment.
function M.get(store, id)
  local c = store.comments[id]
  if c and not c.deleted then
    return c
  end
end

---Delete: a tombstone that wins over older versions elsewhere.
function M.delete(store, id, now)
  local c = store.comments[id]
  if not c or c.deleted then
    return nil
  end
  local t = { id = id, deleted = true, deleted_at = now or M.now_ms(), updated_at = c.updated_at }
  if type(c.ai) == 'table' then
    -- an AI review finding the user deleted: where it was, so a later review does not add it again
    local a = c.anchor or {}
    t.ai = { title = c.ai.title, anchor = { path = a.path, side = a.side, start_line = a.start_line, end_line = a.end_line } }
  end
  touch(store, t, now)
  return c
end

---Append a reply to a comment's thread.
---@return revuey.CommentReply?
function M.reply(store, id, body, author, now)
  local c = M.get(store, id)
  if not c then
    return nil
  end
  now = now or M.now_ms()
  local r = { id = M.new_id(now), author = author or { kind = 'user' }, body = body, created_at = now, updated_at = now }
  c = vim.deepcopy(c)
  c.thread[#c.thread + 1] = r
  touch(store, c, now)
  return r
end

---Live comments, ordered by file, line (file-level first), side and creation.
---@param opts? {include_resolved?:boolean, include_drafts?:boolean}
---@return revuey.Comment[]
function M.list(store, opts)
  opts = opts or {}
  local out = {}
  for _, c in pairs(store.comments) do
    if not c.deleted then
      local hide = (c.status == 'resolved' or c.status == 'dismissed') and not opts.include_resolved
      hide = hide or (c.status == 'draft' and not opts.include_drafts)
      if not hide then
        out[#out + 1] = c
      end
    end
  end
  return M.sort(out)
end

function M.sort(list)
  -- files in the diff's order: folder order with `panel_folders` (review.load), else by path
  local less = require('revuey.config').options.panel_folders and require('revuey.folders').less
  table.sort(list, function(x, y)
    local ax, ay = x.anchor, y.anchor
    if ax.path ~= ay.path then
      if less then
        return less(ax.path, ay.path)
      end
      return ax.path < ay.path
    end
    -- new-side order (deleted lines where their hunk puts them); file-level comments first
    local lx, ly = ax.sort_line or ax.start_line or 0, ay.sort_line or ay.start_line or 0
    if lx ~= ly then
      return lx < ly
    end
    if ax.side ~= ay.side then
      return ax.side == 'old'
    end
    return x.id < y.id
  end)
  return list
end

---Find a comment by full id, unique prefix or unique substring.
---@return revuey.Comment? c, string? err
function M.find(store, query)
  local exact = M.get(store, query)
  if exact then
    return exact
  end
  local hits = {}
  for id, c in pairs(store.comments) do
    if not c.deleted and id:find(query, 1, true) then
      hits[#hits + 1] = c
    end
  end
  if #hits == 1 then
    return hits[1]
  end
  return nil, #hits == 0 and ('no comment ' .. query) or ('ambiguous comment id ' .. query)
end

-- ---------------------------------------------------------------------------
-- Sending to an agent session
-- ---------------------------------------------------------------------------
-- A sent comment keeps `status` (saved, resolved, and later an AI review's dismissed/accepted)
-- and its `in_review` flag: delivery is separate, as timestamps that only move forward (merge).

---Delivery state of a comment sent to an agent: nil (never sent), 'sent' (no agent has seen it
---yet: queued), 'delivered' (a `watch` printed it; not acknowledged yet), 'seen' (acknowledged
---without a reply) or 'answered' (an agent replied after the last send).
---@return nil|'sent'|'delivered'|'seen'|'answered'
function M.delivery(c)
  if not c or c.deleted or not c.sent_at then
    return nil
  end
  local sent = c.sent_at
  if (c.answered_at or 0) >= sent then
    return 'answered'
  end
  for _, r in ipairs(c.thread or {}) do
    if not r.deleted and r.author and r.author.kind == 'agent' and (r.created_at or 0) >= sent then
      return 'answered'
    end
  end
  if (c.acked_at or 0) >= sent then
    return 'seen'
  end
  if (c.delivered_at or 0) >= sent then
    return 'delivered'
  end
  return 'sent'
end

---Mark a comment sent (again). `opts.reply_id`: the thread reply being sent as a follow-up.
---`opts.session`: the sending review session's id (routing between several reviews).
---@param opts? {now?:integer, reply_id?:string, session?:string}
---@return revuey.Comment?
function M.mark_sent(store, id, opts)
  opts = opts or {}
  local cur = M.get(store, id)
  if not cur then
    return nil
  end
  local now = opts.now or M.now_ms()
  local c = vim.deepcopy(cur)
  -- strictly after anything that would count as handling an earlier send
  local after = math.max(c.sent_at or 0, c.delivered_at or 0, c.acked_at or 0, c.answered_at or 0)
  for _, r in ipairs(c.thread or {}) do
    if r.author and r.author.kind == 'agent' then
      after = math.max(after, r.created_at or 0)
    end
  end
  c.sent_at = math.max(now, after + 1)
  c.sent_reply = opts.reply_id
  c.sent_session = opts.session
  return M.put(store, c, now)
end

local function stamp(store, id, keys, now)
  local cur = M.get(store, id)
  if not cur then
    return nil
  end
  now = now or M.now_ms()
  local c = vim.deepcopy(cur)
  for _, k in ipairs(keys) do
    c[k] = math.max(now, c.sent_at or 0)
  end
  return M.put(store, c, now)
end

---A `watch` printed the message to an agent: catch-up does not print it again.
function M.mark_delivered(store, id, now)
  return stamp(store, id, { 'delivered_at' }, now)
end

---The agent acknowledged the comment (`bin/revuey ack`): it is not delivered again.
function M.ack(store, id, now)
  return stamp(store, id, { 'acked_at' }, now)
end

---The agent answered (`bin/revuey reply`): acknowledged and answered.
function M.mark_answered(store, id, now)
  return stamp(store, id, { 'acked_at', 'answered_at' }, now)
end

---What was sent: the follow-up reply when one was sent, else the comment's body.
function M.message_text(c)
  if c.sent_reply then
    for _, r in ipairs(c.thread or {}) do
      if r.id == c.sent_reply and not r.deleted then
        return r.body
      end
    end
  end
  return c.body
end

local function by_delivery(store, states)
  local out = {}
  for _, c in pairs(store.comments) do
    if not c.deleted and states[M.delivery(c) or ''] then
      out[#out + 1] = c
    end
  end
  table.sort(out, function(a, b)
    if a.sent_at ~= b.sent_at then
      return a.sent_at < b.sent_at
    end
    return a.id < b.id
  end)
  return out
end

---Sent comments the agent has not acknowledged yet, delivered or not, oldest send first (inbox).
---@return revuey.Comment[]
function M.unacked(store)
  return by_delivery(store, { sent = true, delivered = true })
end

---Sent comments no agent has been shown yet (watch's catch-up), oldest send first.
---@return revuey.Comment[]
function M.undelivered(store)
  return by_delivery(store, { sent = true })
end

---The `sent` event of a comment: the usual event (full anchor, snippet, body, review) plus the
---message (body or follow-up reply), its kind and sent_at. `extra`: session id etc.
function M.sent_event(c, review, extra, now)
  local ev = M.event('sent', c, review, nil, now)
  ev.message = M.message_text(c)
  ev.message_kind = c.sent_reply and 'reply' or 'comment'
  ev.sent_at = c.sent_at
  ev.session = c.sent_session
  for k, v in pairs(extra or {}) do
    ev[k] = v
  end
  return ev
end

---Identity of one send (a comment sent again is a new message): "<comment id>:<sent_at>".
function M.message_key(x)
  return tostring(x.comment_id or x.id) .. ':' .. tostring(x.sent_at)
end

---The `switched` event: the review's worktree was switched to another stack layer (`gS`,
---`:RevueySwitch`, `]s`/`[s` with switch_on_navigate) while an agent was connected.
---@param review table review info (repo, for watch's matching)
---@param info {session?:string, from?:string, to:string, layer:string, index?:integer, count?:integer, worktree?:string, pr?:{number:integer, url?:string, title?:string}}
---  `from`: the branch checked out before (nil: detached HEAD); `to`: the branch now checked out;
---  `layer`: the stack layer's name (`origin/x` for a remote layer); `index`/`count`: its position
function M.switch_event(review, info, now)
  now = now or M.now_ms()
  local pr = info.pr and { number = info.pr.number, url = info.pr.url, title = info.pr.title } or nil
  return {
    id = M.new_id(now),
    kind = M.SWITCHED,
    at = now,
    session = info.session,
    review = review or {},
    worktree = info.worktree,
    from = info.from,
    to = info.to,
    layer = info.layer,
    layer_index = info.index,
    layer_count = info.count,
    pr = pr,
  }
end

---What a `switched` event says: `stack/cart -> stack/math (layer 1 of 3, PR #12 <url>)`.
local function switch_summary(ev, with_url)
  local parts = {}
  if ev.layer_index and ev.layer_count then
    parts[#parts + 1] = ('layer %d of %d'):format(ev.layer_index, ev.layer_count)
  end
  if ev.layer and ev.layer ~= ev.to then
    parts[#parts + 1] = ev.layer
  end
  if ev.pr and ev.pr.number then
    parts[#parts + 1] = ('PR #%d'):format(ev.pr.number) .. ((with_url and ev.pr.url) and (' ' .. ev.pr.url) or '')
  end
  return ('%s -> %s%s'):format(
    ev.from or 'a detached HEAD',
    tostring(ev.to),
    #parts > 0 and (' (' .. table.concat(parts, ', ') .. ')') or ''
  )
end

---One line for agents: `revuey message <id> src/cart.ts:12-14 (new) [stack/cart]: <first
---line>  (<bin> show <id> for full context)`. A `switched` event: `revuey switched <from> ->
---<to> (layer i of n, PR #N <url>): <what it means>`.
function M.message_line(ev, bin)
  if ev.kind == M.SWITCHED then
    return ('revuey switched %s: the worktree has %s checked out now and the review shows that layer; files on disk changed, so re-read them, and focus on this layer from now on'):format(
      switch_summary(ev, true),
      tostring(ev.to)
    )
  end
  local r = ev.review or {}
  local scope = r.scope == 'full' and 'full stack' or (r.branch or r.state_branch or '?')
  local side = ev.file_level and 'file' or (ev.anchor and ev.anchor.side or 'new')
  local loc = ev.location or (ev.anchor and ev.anchor.path) or '?'
  local tag = ev.message_kind == 'reply' and ' follow-up' or ''
  if ev.outdated then
    tag = tag .. ' [outdated]'
  end
  return ('revuey message %s %s (%s) [%s]%s: %s  (%s show %s for full context)'):format(
    ev.comment_id,
    loc,
    side,
    scope,
    tag,
    M.first_line(ev.message or ev.body),
    bin or 'revuey',
    ev.comment_id
  )
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

---One event line: the comment's full anchor, snippet and body, plus the reply for `replied`.
---@param kind string one of M.EVENT_KINDS
---@param c revuey.Comment
---@param review table review info
---@param extra? table merged in (e.g. reply = {...})
function M.event(kind, c, review, extra, now)
  assert(M.EVENT_KINDS[kind], 'unknown comment event ' .. tostring(kind))
  now = now or M.now_ms()
  -- a huge selection must not make huge event lines: the snippet is capped
  local anchor, snippet = c.anchor, c.anchor and c.anchor.snippet or {}
  if #snippet > M.EVENT_SNIPPET_MAX then
    local cut = vim.list_slice(snippet, 1, M.EVENT_SNIPPET_MAX)
    cut[#cut + 1] = ('… (%d more lines)'):format(#snippet - M.EVENT_SNIPPET_MAX)
    snippet = cut
    anchor = vim.tbl_extend('force', anchor, { snippet = cut })
  end
  local ev = {
    id = M.new_id(now),
    kind = kind,
    at = now,
    comment_id = c.id,
    review = review or {},
    location = M.location(c),
    anchor = anchor,
    snippet = snippet,
    body = c.body,
    author = c.author,
    status = c.status,
    file_level = c.file_level or false,
    outdated = c.outdated or false,
  }
  for k, v in pairs(extra or {}) do
    ev[k] = v
  end
  return ev
end

---Append an event (rotating the file to `.1` past EVENTS_MAX bytes).
function M.append_event(path, ev)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  -- rotation and append under the lock: a rename between another writer's size check and its
  -- append would otherwise put its event into the rotated file or lose a generation. Events
  -- wait in a queue (in order) while the lock is busy in the UI.
  local lock = require('revuey.lock')
  local queue = event_queue[path] or {}
  event_queue[path] = queue
  queue[#queue + 1] = vim.json.encode(ev) .. '\n'
  local ok, res, err = pcall(lock.save, path, function()
    return lock.with(path, function()
      return M._flush_events(path)
    end)
  end, function()
    -- still blocked at quit: the queued lines go to a recovery file (appended first next time)
    local q = event_queue[path] or {}
    if #q > 0 then
      lock.write_file(lock.recovery_path(path), table.concat(q))
      event_queue[path] = {}
    end
  end)
  if not ok then
    return false, res
  end
  if res == nil and #queue > 0 then
    return true -- deferred
  end
  return res, err
end

event_queue = {}

function M._flush_events(path)
  local queue = event_queue[path] or {}
  -- lines an instance could not append before it quit come first
  local recovered = require('revuey.lock').recovery_files(path)
  for i = #recovered, 1, -1 do
    local fd = io.open(recovered[i], 'r')
    if fd then
      table.insert(queue, 1, fd:read('*a'))
      fd:close()
    end
  end
  if #queue == 0 then
    return true
  end
  local st = vim.uv.fs_stat(path)
  if st and st.size > M.EVENTS_MAX then
    os.rename(path, path .. '.1')
  end
  local fd, err = io.open(path, 'a')
  if not fd then
    return false, err
  end
  fd:write(table.concat(queue))
  fd:close()
  event_queue[path] = {}
  for _, f in ipairs(recovered) do
    os.remove(f)
  end
  return true
end

---Decode event lines (bad lines skipped).
function M.decode_events(text)
  local out = {}
  for line in text:gmatch('[^\n]+') do
    local ok, ev = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(ev) == 'table' and ev.id then
      out[#out + 1] = ev
    end
  end
  return out
end

---The first line of a text, trimmed (for one-line summaries).
function M.first_line(text)
  local l = vim.trim((text or ''):match('^%s*([^\n]*)') or '')
  return l
end

local VERB = {
  created = 'comment', updated = 'edit', deleted = 'delete', resolved = 'resolve', replied = 'reply', sent = 'send', acked = 'ack',
  accepted = 'accept', dismissed = 'dismiss',
}

---One-line human summary of an event: `comment src/cart.ts:12-14 (new): first line  #id`.
function M.event_line(ev)
  if ev.kind == M.SWITCHED then
    return 'switch ' .. switch_summary(ev, false) .. '  #' .. tostring(ev.id)
  end
  local verb = VERB[ev.kind] or ev.kind
  if ev.kind == 'resolved' and ev.status ~= 'resolved' then
    verb = 'reopen'
  elseif ev.kind == 'dismissed' and ev.status ~= 'dismissed' then
    verb = 'restore'
  end
  local loc = ev.location or (ev.anchor and ev.anchor.path) or '?'
  local side = ev.file_level and 'file' or (ev.anchor and ev.anchor.side or 'new')
  local text = ev.body
  local who = ''
  if ev.kind == 'replied' and ev.reply then
    text = ev.reply.body
    local a = ev.reply.author or {}
    who = ' from ' .. (a.name or a.kind or 'user')
  end
  local out = ('%s %s (%s)%s: %s'):format(verb, loc, side, who, M.first_line(text))
  if ev.outdated then
    out = out .. ' [outdated]'
  end
  return out .. '  #' .. tostring(ev.comment_id)
end

return M
