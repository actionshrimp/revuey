-- Projected tree-sitter highlighting (ARCHITECTURE decision 2).
--
-- The old and new versions of each file are fetched by blob hash, parsed whole with
-- `vim.treesitter.get_string_parser`, and their highlight captures bucketed per source row. A
-- decoration provider then projects captures onto composed rows lazily (only visible rows), using
-- the old side for `del` rows and the new side for `add`/`ctx` rows. Because composed buffer text is
-- byte-identical to source text, columns map 1:1. Files without a parser/query get no syntax.
local git = require('revuey.git')

local M = {}

M.ns = vim.api.nvim_create_namespace('revuey.syntax')

---@type table<integer, {review: revuey.Review, layout: revuey.Layout}>
M.views = {}

---Cache keyed by blob hash + language + rows: {status, rows, waiters}
local cache = {}

local MAX_BYTES = 2 * 1024 * 1024

local ft_lang_fallback = { typescriptreact = 'tsx', javascriptreact = 'javascript', sh = 'bash' }

local function has_parser(lang)
  local ok, res = pcall(vim.treesitter.language.add, lang)
  return ok and res == true
end

---Tree-sitter language for a path, or nil when no parser + highlights query is available.
---@return string?
function M.lang_for_path(path)
  local ft = vim.filetype.match({ filename = path })
  if not ft then
    return nil
  end
  local candidates = { vim.treesitter.language.get_lang(ft) or ft, ft_lang_fallback[ft] }
  for _, lang in ipairs(candidates) do
    if lang and has_parser(lang) then
      local ok, q = pcall(vim.treesitter.query.get, lang, 'highlights')
      if ok and q then
        return lang
      end
    end
  end
  return nil
end

---0-based, end-exclusive row ranges covered by a file's hunks on one side, merged and sorted.
---@param f revuey.FileDiff
---@param side 'old'|'new'
---@return {[1]:integer,[2]:integer}[]
function M.hunk_ranges(f, side)
  local out = {}
  for _, hk in ipairs(f.hunks) do
    local start = side == 'old' and hk.old_start or hk.new_start
    local count = side == 'old' and hk.old_count or hk.new_count
    if count > 0 then
      local r = { start - 1, start - 1 + count }
      local last = out[#out]
      if last and r[1] <= last[2] then
        last[2] = math.max(last[2], r[2])
      else
        out[#out + 1] = r
      end
    end
  end
  return out
end

-- Work budget per main-loop turn for capture collection (ms); between slices control returns to
-- the event loop so typing/scrolling stays responsive.
local SLICE_MS = 8

---Collect highlight spans for `ranges` from an already parsed language tree. Calls `pause()`
---every few hundred steps; the async driver yields there when the time slice is used up.
local function collect_impl(parser, text, ranges, pause, source)
  source = source or text
  local rows = {}
  local starts = { [0] = 1 } -- byte offset (1-based) of each row, for multi-line captures
  do
    local r, pos = 0, 1
    while true do
      local nl = text:find('\n', pos, true)
      if not nl then
        break
      end
      r, pos = r + 1, nl + 1
      starts[r] = pos
      if r % 2000 == 0 then
        pause()
      end
    end
  end
  local function line_len(r)
    local s0, s1 = starts[r], starts[r + 1]
    if not s0 then
      return 0
    end
    return (s1 and s1 - 1 or #text + 1) - s0
  end
  local trees = {}
  parser:for_each_tree(function(tstree, ltree)
    trees[#trees + 1] = { tstree, ltree }
  end)
  local steps = 0
  for _, t in ipairs(trees) do
    local tstree, ltree = t[1], t[2]
    local l = ltree:lang()
    local ok, q = pcall(vim.treesitter.query.get, l, 'highlights')
    if ok and q then
      local injected = ltree ~= parser
      -- ranges are disjoint and sorted; clamping rows to the current range is enough (no rescans)
      for _, rg in ipairs(ranges) do
        for id, node, metadata in q:iter_captures(tstree:root(), source, rg[1], rg[2]) do
          steps = steps + 1
          if steps % 25 == 0 then
            pause()
          end
          local name = q.captures[id]
          if name and name ~= 'spell' and name ~= 'nospell' and name:sub(1, 1) ~= '_' and name ~= 'conceal' then
            local sr, sc, er, ec = node:range()
            local prio = tonumber(metadata.priority or (metadata[id] and metadata[id].priority))
              or vim.hl.priorities.treesitter
            if injected then
              prio = prio + 1 -- injected trees (jsdoc, regex) sit above their host
            end
            local hl = '@' .. name .. '.' .. l
            for r = math.max(sr, rg[1]), math.min(er, rg[2] - 1) do
              local s0 = r == sr and sc or 0
              local e0 = r == er and ec or line_len(r)
              if e0 > s0 then
                local b = rows[r]
                if not b then
                  b = {}
                  rows[r] = b
                end
                b[#b + 1] = { s0, e0, hl, prio }
              end
            end
          end
        end
      end
    end
  end
  return rows
end

---Synchronous collection (tests, small inputs).
function M.collect(parser, text, ranges)
  return collect_impl(parser, text, ranges, function() end)
end

local gen = 0 -- bumped by clear_cache(); in-flight work from an older generation is abandoned
local parse_sliced -- defined below

---Collect in time slices: a coroutine yields when SLICE_MS is used up and resumes on the next
---main-loop turn. `cb(rows)` or `cb(nil, err)`; `cb` is not called if the cache was cleared.
local function collect_async(parser, text, ranges, source, cb, my_gen)
  local slice_start
  local co = coroutine.create(function()
    return collect_impl(parser, text, ranges, function()
      if (vim.uv.hrtime() - slice_start) / 1e6 > SLICE_MS then
        coroutine.yield()
      end
    end, source)
  end)
  local function step()
    if gen ~= my_gen then
      return cb(nil, 'abandoned', true)
    end
    slice_start = vim.uv.hrtime()
    local ok, res = coroutine.resume(co)
    if not ok then
      return cb(nil, res)
    end
    if coroutine.status(co) == 'dead' then
      return cb(res)
    end
    -- a timer, not vim.schedule: callbacks scheduled from a scheduled callback run in the same
    -- event-loop turn, which would starve input and timers just like a synchronous loop
    vim.defer_fn(step, 0)
  end
  step()
end

---Incremental parse driven by timers. Core's `parse(range, on_parse)` re-queues its steps with
---vim.schedule, and a chain of scheduled callbacks runs within one event-loop turn, so input and
---timers starve until the whole parse is done. We drive the same resumable `_parse` coroutine
---(3ms per step, as core does) but yield to the event loop between steps via a 0ms timer.
---Falls back to the public async API if the internal one changes.
parse_sliced = function(parser, range, my_gen, cb)
  if type(parser._parse) ~= 'function' then
    return parser:parse(range, function(err)
      cb(err)
    end)
  end
  local parse = coroutine.wrap(parser._parse)
  local state = {}
  local function step()
    if gen ~= my_gen then
      return cb('abandoned')
    end
    state.timeout = 3 * 1000000
    local ok, _, finished = pcall(parse, parser, range, state)
    if not ok then
      return cb(_)
    end
    if finished then
      return cb(nil)
    end
    vim.defer_fn(step, 0)
  end
  step()
end

---Parse `text` asynchronously and collect highlight spans only for `ranges` (0-based,
---end-exclusive, disjoint, sorted), both in time slices so the UI keeps running.
---The text is parsed from a hidden scratch buffer: buffer parsers honour tree-sitter's per-step
---timeout, string parsers do not (a 20k-line string parse blocks for >100ms in one go).
---Calls `cb(rows)` (or `cb(nil, err)`) when done; not at all if the cache is cleared meanwhile.
---Parse one text from a hidden scratch buffer and collect spans. `ranges` is either a range list
---or a `plan(parser)` function called after parsing that returns the ranges to collect (plus an
---extra value handed to `cb`), or nil to reject the parse (`cb(nil, 'retry')`).
local function highlight_one(text, lang, ranges, cb)
  local my_gen = gen
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].undolevels = -1
  local lines = vim.split(text, '\n', { plain = true })
  if lines[#lines] == '' then
    lines[#lines] = nil
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local extra
  local function done(rows, err, abandoned)
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    if not abandoned and gen == my_gen then
      cb(rows, err, extra)
    end
  end
  local ok, parser = pcall(vim.treesitter.get_parser, buf, lang, { error = false })
  if not ok or not parser then
    return done(nil, parser or 'no parser')
  end
  parse_sliced(parser, true, my_gen, function(err)
    if gen ~= my_gen then
      return done(nil, nil, true)
    end
    if err then
      return done(nil, err)
    end
    local want = ranges
    if type(ranges) == 'function' then
      want, extra = ranges(parser)
      if not want then
        return done(nil, 'retry')
      end
    end
    collect_async(parser, text, want, buf, done, my_gen)
  end)
end

-- Files longer than this are parsed in chunks: tree-sitter's end-of-parse tree balancing can't be
-- interrupted and costs ~80ms for a 20k-line file, which would freeze the UI.
local CHUNK_ROWS = 1000
-- Rows parsed past a chunk's nominal end, so constructs crossing it are complete in its text.
local CHUNK_TRAIL = 300

---Intersect sorted disjoint ranges with [lo, hi) and shift them by -lo.
local function clip(ranges, lo, hi)
  local out = {}
  for _, rg in ipairs(ranges) do
    local a, b = math.max(rg[1], lo), math.min(rg[2], hi)
    if a < b then
      out[#out + 1] = { a - lo, b - lo }
    end
  end
  return out
end

---Parse `text` asynchronously and collect highlight spans only for `ranges` (0-based,
---end-exclusive, disjoint, sorted). Everything runs in time slices so the UI stays responsive.
---
---Long files are parsed in chunks that always start at a top-level node boundary, so every
---chunk begins in the same lexical state as a whole-file parse (never inside a comment, string
---or template literal). Starting at row 0, a chunk of CHUNK_ROWS (+ CHUNK_TRAIL rows of trailing
---context) is parsed; the next chunk starts at the first row of the top-level node that contains
---the chunk's nominal end. Only rows before that boundary are kept: they belong to complete
---top-level nodes, so their captures equal a whole-file parse. If a kept node has errors (the
---truncation confused error recovery) or one node spans the whole chunk, the chunk is retried
---twice as large, up to the rest of the file.
---Calls `cb(rows)` (or `cb(nil, err)`); not called if the cache is cleared meanwhile.
function M.highlight_async(text, lang, ranges, cb)
  local lines = vim.split(text, '\n', { plain = true })
  if lines[#lines] == '' then
    lines[#lines] = nil
  end
  local nlines = #lines
  if nlines <= CHUNK_ROWS + CHUNK_TRAIL or #ranges == 0 then
    return highlight_one(text, lang, ranges, cb)
  end
  local my_gen = gen
  local last = ranges[#ranges][2]
  local rows = {}
  local start, size = 0, CHUNK_ROWS
  local step
  step = function()
    if gen ~= my_gen then
      return
    end
    if start >= last or start >= nlines then
      return cb(rows)
    end
    local nominal = start + size -- absolute
    local stop = math.min(nominal + CHUNK_TRAIL, nlines)
    local to_end = stop >= nlines
    local sub = table.concat(lines, '\n', start + 1, stop) .. '\n'
    local chunk_start = start
    local function plan(parser)
      local root = parser:trees()[1]:root()
      local b -- boundary, relative to chunk_start
      if to_end then
        b = stop - chunk_start
      else
        local brow = nominal - chunk_start
        for child in root:iter_children() do
          local sr, _, er = child:range()
          if er >= brow then
            b = math.min(sr, brow)
            break
          end
        end
        b = b or brow
        if b <= 0 then
          return nil -- one top-level node spans the whole chunk
        end
        for child in root:iter_children() do
          local sr = child:range()
          if sr >= b then
            break
          end
          if child:has_error() then
            return nil -- truncation (or genuinely broken code) affects kept rows; grow
          end
        end
      end
      return clip(ranges, chunk_start, chunk_start + b), b
    end
    highlight_one(sub, lang, plan, function(r, err, b)
      if err == 'retry' or not b then
        if err and err ~= 'retry' then
          return cb(nil, err)
        end
        size = size * 2
      else
        for row, spans in pairs(r or {}) do
          rows[row + chunk_start] = spans
        end
        start, size = chunk_start + b, CHUNK_ROWS
      end
      vim.defer_fn(step, 0)
    end)
  end
  step()
end

local function redraw(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  -- Nothing to show without a UI, and a headless redraw has been seen to crash Neovim. Screen
  -- tests read the grid of a UI-less child (mini.test redraws it) and opt in.
  if #vim.api.nvim_list_uis() == 0 and not vim.g.revuey_headless_redraw then
    return
  end
  local ok = pcall(vim.api.nvim__redraw, { buf = buf, valid = false })
  if not ok then
    vim.cmd('redraw!')
  end
end

---Get (and lazily start loading) highlight data for one side of a file. Cached by blob hash +
---language + requested rows; the cache is dropped when the last review closes.
---@param root string
---@param f revuey.FileDiff
---@param side 'old'|'new'
---@param on_ready? fun()
local lang_memo = {}

---Cache key, language and row ranges for one side of a file (memoised on the file table).
local function key_for(f, side)
  f._syntax = f._syntax or {}
  local k = f._syntax[side]
  if k == nil then
    k = false
    local hash = side == 'old' and f.old_blob or f.new_blob
    local path = side == 'old' and f.old_path or f.path
    if hash and not f.binary then
      local lang = lang_memo[path]
      if lang == nil then
        lang = M.lang_for_path(path) or false
        lang_memo[path] = lang
      end
      if lang then
        local ranges = M.hunk_ranges(f, side)
        local parts = {}
        for _, rg in ipairs(ranges) do
          parts[#parts + 1] = rg[1] .. '-' .. rg[2]
        end
        k = { key = hash .. ':' .. lang .. ':' .. table.concat(parts, ','), hash = hash, lang = lang, ranges = ranges }
      end
    end
    f._syntax[side] = k
  end
  return k or nil
end

---@param waiter_key? any identifies the waiter (e.g. the buffer); repeated calls with the same key
---  while loading replace rather than add, so redraws don't pile up callbacks
function M.get(root, f, side, on_ready, waiter_key)
  local k = key_for(f, side)
  if not k then
    return nil
  end
  local key, hash, lang, ranges = k.key, k.hash, k.lang, k.ranges
  local c = cache[key]
  if c then
    if c.status == 'loading' and on_ready then
      c.waiters[waiter_key or (#c.waiters + 1)] = on_ready
    end
    return c
  end
  c = { status = 'loading', waiters = {} }
  if on_ready then
    c.waiters[waiter_key or 1] = on_ready
  end
  cache[key] = c
  local function finish(rows, err)
    c.rows, c.err = rows, err
    c.status = rows and 'ready' or 'none'
    local waiters = c.waiters
    c.waiters = nil
    for _, w in pairs(waiters) do
      pcall(w)
    end
  end
  local my_gen = gen
  git.async(function()
    local text
    if side == 'new' and f.worktree then
      -- working-tree mode: the new side is the file on disk (not necessarily in the object db)
      text = f.new_text or git.read_file(vim.fs.joinpath(root, f.path))
    else
      text = git.blob(hash, root)
    end
    if gen ~= my_gen then
      return
    end
    if not text or #text > MAX_BYTES or text:find('\0', 1, true) then
      return finish(nil)
    end
    text = text:gsub('\r\n', '\n') -- composed lines have CR stripped
    M.highlight_async(text, lang, ranges, finish)
  end, function(err)
    finish(nil, err)
  end)
  return c
end

local function side_of(entry)
  if entry.kind == 'del' then
    return 'old', entry.old_lnum
  elseif entry.kind == 'add' or entry.kind == 'ctx' then
    return 'new', entry.new_lnum
  end
end

---Synchronously ensure highlights for a file side are loaded (tests).
function M.load_sync(root, f, side, timeout)
  local c = M.get(root, f, side)
  if c then
    vim.wait(timeout or 5000, function()
      return c.status ~= 'loading'
    end, 10)
  end
  return c
end

---Spans for one composed row (0-based), or nil when not available (yet).
function M.spans_for_row(view, row)
  local e = view.layout.map[row + 1]
  if not e then
    return nil
  end
  local side, lnum = side_of(e)
  if not side then
    return nil -- meta and guide prose rows
  end
  local f = view.review.files[e.file_idx]
  local k = key_for(f, side)
  local c = k and cache[k.key] -- peek only: loading is started from on_win, never on_line
  if not c or c.status ~= 'ready' then
    return nil
  end
  return c.rows[lnum - 1]
end

local function draw(buf, row, spans)
  for _, sp in ipairs(spans) do
    pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, row, sp[1], {
      end_row = row,
      end_col = sp[2],
      hl_group = sp[3],
      priority = sp[4],
      ephemeral = true,
    })
  end
end

---Start loading highlight data for file sides visible in `win`, skipping closed folds so
---collapsed (reviewed or large) files are never fetched or parsed. Runs outside the redraw.
local function request_visible(view, buf, win, top, bot)
  if M.views[buf] ~= view or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local wanted = {}
  vim.api.nvim_win_call(win, function()
    local row = top -- 0-based
    while row <= bot do
      local fold_end = vim.fn.foldclosedend(row + 1)
      if fold_end ~= -1 then
        row = fold_end -- skip the whole closed fold (next row is fold_end + 1 in 1-based)
      else
        local e = view.layout.map[row + 1]
        if e and side_of(e) then
          wanted[e.file_idx .. (side_of(e))] = { e.file_idx, (side_of(e)) }
        end
        row = row + 1
      end
    end
  end)
  for _, w in pairs(wanted) do
    M.get(view.review.root, view.review.files[w[1]], w[2], function()
      redraw(buf)
    end, buf)
  end
end

local scheduled = {} ---@type table<string, boolean>

vim.api.nvim_set_decoration_provider(M.ns, {
  on_win = function(_, win, buf, top, bot)
    local view = M.views[buf]
    if not view then
      return false
    end
    -- never do work during redraw: schedule one visibility check per window
    local key = buf .. ':' .. win
    if not scheduled[key] then
      scheduled[key] = true
      vim.schedule(function()
        scheduled[key] = nil
        request_visible(view, buf, win, top, bot)
      end)
    end
    return true
  end,
  on_line = function(_, _, buf, row)
    local view = M.views[buf]
    if not view then
      return
    end
    local spans = M.spans_for_row(view, row)
    if spans then
      draw(buf, row, spans)
    end
    -- lazy intra-line (word) diff, provided by the view
    local words = view.word_spans and view.word_spans(row)
    if words then
      draw(buf, row, words)
    end
  end,
})

function M.attach(buf, view)
  M.views[buf] = view
end

function M.detach(buf)
  M.views[buf] = nil
end

function M.clear_cache()
  cache = {}
  lang_memo = {}
  gen = gen + 1
end

function M.cache_size()
  return vim.tbl_count(cache)
end

---Number of file sides still loading/parsing.
function M.pending()
  local n = 0
  for _, c in pairs(cache) do
    if c.status == 'loading' then
      n = n + 1
    end
  end
  return n
end

return M
