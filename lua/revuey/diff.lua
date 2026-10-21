-- Pure parsing of `git diff` output into a file/hunk model, plus intra-line (word) diffs.
-- No editor UI calls; only `vim.text.diff` and string helpers.
local M = {}

---@class revuey.DiffLine
---@field kind 'add'|'del'|'ctx'
---@field text string
---@field old_lnum? integer
---@field new_lnum? integer
---@field cr? boolean       the source line ended in CRLF (the CR is stripped from `text`)
---@field no_eol? boolean   last line of the file, without a trailing newline

---@class revuey.Hunk
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field header string   full "@@ ... @@ section" line
---@field lines revuey.DiffLine[]

---@class revuey.FileDiff
---@field path string        new path (old path for deletions)
---@field old_path string    old path (== path unless renamed)
---@field status 'A'|'D'|'M'|'R'|'T'
---@field binary boolean
---@field old_blob? string   full hash, nil when the file did not exist
---@field new_blob? string
---@field old_mode? string
---@field new_mode? string
---@field similarity? integer
---@field hunks revuey.Hunk[]
---@field added integer
---@field removed integer

local NULL_HASH = '^0+$'

local unescapes = { n = '\n', t = '\t', r = '\r', ['"'] = '"', ['\\'] = '\\', a = '\a', b = '\b', f = '\f', v = '\v' }

---Undo git's C-style path quoting ("a/f\303\266o" -> a/föo).
local function unquote(s)
  if s:sub(1, 1) ~= '"' then
    return s
  end
  s = s:sub(2, -2)
  s = s:gsub('\\(%d%d%d)', function(oct)
    return string.char(tonumber(oct, 8))
  end)
  s = s:gsub('\\(.)', function(c)
    return unescapes[c] or c
  end)
  return s
end

---Strip a/ or b/ prefix from a ---/+++ path. Returns nil for /dev/null.
local function strip_prefix(s)
  s = unquote(vim.trim(s:gsub('\t.*$', '')))
  if s == '/dev/null' then
    return nil
  end
  return (s:gsub('^[ab]/', ''))
end

---Best-effort split of "diff --git a/X b/Y" when no ---/+++ lines follow (binary, pure rename, mode change).
local function paths_from_git_header(rest)
  if rest:sub(1, 1) == '"' then
    local a, b = rest:match('^(".-[^\\]")%s+(.+)$')
    if a then
      return strip_prefix(a), strip_prefix(b)
    end
  end
  -- Unquoted: assume both halves have the same length when the path is unchanged.
  local n = #rest
  if n % 2 == 1 then
    local half = (n - 1) / 2
    local a, b = rest:sub(1, half), rest:sub(half + 2)
    if a:sub(3) == b:sub(3) then
      return a:sub(3), b:sub(3)
    end
  end
  local a, b = rest:match('^a/(.-) b/(.*)$')
  return a, b
end

---Parse unified diff text produced by `git diff --full-index`.
---@param text string
---@return revuey.FileDiff[]
function M.parse(text)
  local files = {} ---@type revuey.FileDiff[]
  local file ---@type revuey.FileDiff?
  local hunk ---@type revuey.Hunk?
  local old_l, new_l = 0, 0

  local function finish()
    if not file then
      return
    end
    if not file.path or file.path == '' then
      file.path = file.old_path
    end
    if not file.old_path or file.old_path == '' then
      file.old_path = file.path
    end
    if not file.status then
      if file.old_path ~= file.path then
        file.status = 'R'
      else
        file.status = 'M'
      end
    end
    files[#files + 1] = file
    file, hunk = nil, nil
  end

  local function mark_no_eol()
    local last = hunk and hunk.lines[#hunk.lines]
    if last then
      last.no_eol = true
    end
  end

  local lines = vim.split(text, '\n', { plain = true })
  if lines[#lines] == '' then
    lines[#lines] = nil
  end

  for _, line in ipairs(lines) do
    local in_hunk = hunk and (old_l < hunk.old_start + hunk.old_count or new_l < hunk.new_start + hunk.new_count)
    if in_hunk and hunk then
      local c = line:sub(1, 1)
      local body = line:sub(2)
      local cr
      if body:sub(-1) == '\r' then
        body, cr = body:sub(1, -2), true
      end
      local entry
      if c == ' ' or line == '' then
        entry = { kind = 'ctx', text = body, old_lnum = old_l, new_lnum = new_l }
        old_l, new_l = old_l + 1, new_l + 1
      elseif c == '-' then
        entry = { kind = 'del', text = body, old_lnum = old_l }
        old_l = old_l + 1
        file.removed = file.removed + 1
      elseif c == '+' then
        entry = { kind = 'add', text = body, new_lnum = new_l }
        new_l = new_l + 1
        file.added = file.added + 1
      elseif c == '\\' then
        mark_no_eol()
      else
        in_hunk = false
      end
      if entry then
        entry.cr = cr
        hunk.lines[#hunk.lines + 1] = entry
      end
    elseif hunk and line:sub(1, 1) == '\\' then
      -- "\ No newline at end of file" after the hunk's last line
      mark_no_eol()
      in_hunk = true -- consumed
    end
    if not in_hunk then
      local rest = line:match('^diff %-%-git (.*)$')
      if rest then
        finish()
        local a, b = paths_from_git_header(rest)
        file = { old_path = a, path = b, binary = false, hunks = {}, added = 0, removed = 0 }
      elseif file then
        local hs, hc, ns, nc, section = line:match('^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@(.*)$')
        if hs then
          hunk = {
            old_start = tonumber(hs),
            old_count = hc == '' and 1 or tonumber(hc),
            new_start = tonumber(ns),
            new_count = nc == '' and 1 or tonumber(nc),
            header = line,
            section = vim.trim(section or ''),
            lines = {},
          }
          -- A count of 0 means the range is empty and start refers to the line *before* it.
          old_l = hunk.old_count == 0 and hunk.old_start + 1 or hunk.old_start
          new_l = hunk.new_count == 0 and hunk.new_start + 1 or hunk.new_start
          if hunk.old_count == 0 then
            hunk.old_start = hunk.old_start + 1
          end
          if hunk.new_count == 0 then
            hunk.new_start = hunk.new_start + 1
          end
          file.hunks[#file.hunks + 1] = hunk
        elseif line:match('^new file mode ') then
          file.status = 'A'
          file.new_mode = line:match('(%d+)$')
        elseif line:match('^deleted file mode ') then
          file.status = 'D'
          file.old_mode = line:match('(%d+)$')
        elseif line:match('^old mode ') then
          file.old_mode = line:match('(%d+)$')
        elseif line:match('^new mode ') then
          file.new_mode = line:match('(%d+)$')
        elseif line:match('^similarity index ') then
          file.similarity = tonumber(line:match('(%d+)%%'))
        elseif line:match('^rename from ') then
          file.old_path = unquote(line:sub(#'rename from ' + 1))
          file.status = 'R'
        elseif line:match('^rename to ') then
          file.path = unquote(line:sub(#'rename to ' + 1))
          file.status = 'R'
        elseif line:match('^index ') then
          local o, n = line:match('^index (%x+)%.%.(%x+)')
          file.old_blob = (o and not o:match(NULL_HASH)) and o or nil
          file.new_blob = (n and not n:match(NULL_HASH)) and n or nil
        elseif line:match('^Binary files ') or line:match('^GIT binary patch') then
          file.binary = true
        elseif line:match('^%-%-%- ') then
          local p = strip_prefix(line:sub(5))
          if p then
            file.old_path = p
          end
        elseif line:match('^%+%+%+ ') then
          local p = strip_prefix(line:sub(5))
          if p then
            file.path = p
          end
        end
      end
    end
  end
  finish()
  -- git reports a type change (e.g. file -> symlink) as a deletion followed by an addition of the
  -- same path; merge them into one 'T' entry so the file has a single identity and reviewed mark.
  local merged = {}
  for _, f in ipairs(files) do
    local prev = merged[#merged]
    if prev and prev.status == 'D' and f.status == 'A' and prev.path == f.path then
      prev.status = 'T'
      prev.new_blob, prev.new_mode = f.new_blob, f.new_mode
      prev.binary = prev.binary or f.binary
      vim.list_extend(prev.hunks, f.hunks)
      prev.added = prev.added + f.added
    else
      merged[#merged + 1] = f
    end
  end
  return merged
end

---A FileDiff for an untracked file: every line added (CR stripped and recorded like `parse`).
---@param path string repo-relative
---@param content string file bytes
---@param hash string? blob hash of the content
---@param mode? string git file mode ('100644', '100755', '120000'), part of the reviewed-mark key
---@return revuey.FileDiff
function M.untracked_file(path, content, hash, mode)
  local f = {
    path = path,
    old_path = path,
    status = 'A',
    binary = content:sub(1, 8000):find('\0', 1, true) ~= nil,
    new_blob = hash,
    new_mode = mode,
    hunks = {},
    added = 0,
    removed = 0,
    untracked = true,
  }
  if f.binary or content == '' then
    return f
  end
  local lines = vim.split(content, '\n', { plain = true })
  local no_eol = lines[#lines] ~= ''
  if not no_eol then
    lines[#lines] = nil
  end
  local hk = { old_start = 0, old_count = 0, new_start = 1, new_count = #lines, section = '', lines = {} }
  hk.header = ('@@ -0,0 +1,%d @@'):format(#lines)
  for i, text in ipairs(lines) do
    local l = { kind = 'add', text = text, new_lnum = i }
    if text:sub(-1) == '\r' then
      l.text, l.cr = text:sub(1, -2), true
    end
    hk.lines[i] = l
  end
  if no_eol then
    hk.lines[#lines].no_eol = true
  end
  f.hunks[1] = hk
  f.added = #lines
  return f
end

---An untracked entry whose content isn't shown (too large, nested repository, special file).
---@return revuey.FileDiff
function M.placeholder(path, note, hash, mode)
  return {
    path = path,
    old_path = path,
    status = 'A',
    binary = false,
    new_blob = hash,
    new_mode = mode,
    hunks = {},
    added = 0,
    removed = 0,
    untracked = true,
    note = note,
  }
end

local function ending(l)
  if l.no_eol then
    return 'no newline at EOF'
  end
  return l.cr and 'CRLF' or 'LF'
end

---Describe a line-ending-only change between a paired deleted and added line, or nil.
---@param del revuey.DiffLine
---@param add revuey.DiffLine
---@return string?
function M.eol_change(del, add)
  if del.text ~= add.text then
    return nil
  end
  local a, b = ending(del), ending(add)
  if a == b then
    return nil
  end
  return 'line ending: ' .. a .. ' → ' .. b
end

-- ---------------------------------------------------------------------------
-- Intra-line diff
-- ---------------------------------------------------------------------------

---Split a line into tokens: identifier runs, whitespace runs, or single other chars.
---@return string[] tokens, integer[] starts (0-based byte offsets)
local function tokenize(s)
  local toks, starts = {}, {}
  local i, n = 1, #s
  while i <= n do
    local _, e = s:find('^[%w_]+', i)
    if not e then
      _, e = s:find('^%s+', i)
    end
    if not e then
      -- keep UTF-8 sequences together
      local b = s:byte(i)
      local len = b >= 0xF0 and 4 or b >= 0xE0 and 3 or b >= 0xC0 and 2 or 1
      e = math.min(n, i + len - 1)
    end
    toks[#toks + 1] = s:sub(i, e)
    starts[#starts + 1] = i - 1
    i = e + 1
  end
  return toks, starts
end

---Merge adjacent/overlapping ranges.
local function merge(ranges)
  table.sort(ranges, function(a, b)
    return a[1] < b[1]
  end)
  local out = {}
  for _, r in ipairs(ranges) do
    local last = out[#out]
    if last and r[1] <= last[2] then
      last[2] = math.max(last[2], r[2])
    else
      out[#out + 1] = { r[1], r[2] }
    end
  end
  return out
end

---Changed byte ranges between an old and a new line.
---Returns nil when the lines are too different for word highlighting to be useful.
---@param old string
---@param new string
---@return {[1]:integer,[2]:integer}[]? old_ranges 0-based [start, end)
---@return {[1]:integer,[2]:integer}[]? new_ranges
function M.word_diff(old, new)
  if old == new or old:match('^%s*$') or new:match('^%s*$') or #old > 1000 or #new > 1000 then
    return nil
  end
  local ta, sa = tokenize(old)
  local tb, sb = tokenize(new)
  local ok, hunks = pcall(vim.text.diff, table.concat(ta, '\n') .. '\n', table.concat(tb, '\n') .. '\n', {
    result_type = 'indices',
    algorithm = 'histogram',
  })
  if not ok or type(hunks) ~= 'table' then
    return nil
  end
  local ra, rb = {}, {}
  local changed_a, changed_b = 0, 0
  for _, h in ipairs(hunks) do
    local a_start, a_count, b_start, b_count = h[1], h[2], h[3], h[4]
    if a_start + a_count - 1 > #ta or b_start + b_count - 1 > #tb then
      return nil
    end
    if a_count > 0 then
      local s = sa[a_start]
      local e = sa[a_start + a_count - 1] + #ta[a_start + a_count - 1]
      ra[#ra + 1] = { s, e }
      changed_a = changed_a + (e - s)
    end
    if b_count > 0 then
      local s = sb[b_start]
      local e = sb[b_start + b_count - 1] + #tb[b_start + b_count - 1]
      rb[#rb + 1] = { s, e }
      changed_b = changed_b + (e - s)
    end
  end
  -- Ignore whitespace-only content when judging similarity.
  local len_a = #(old:gsub('%s', ''))
  local len_b = #(new:gsub('%s', ''))
  if len_a + len_b == 0 then
    return nil
  end
  if (changed_a + changed_b) > 0.6 * (#old + #new) then
    return nil
  end
  return merge(ra), merge(rb)
end

---Pair deleted and added lines inside a hunk for word diffs: each run of deletions followed directly
---by a run of additions is paired line by line.
---@param lines revuey.DiffLine[]
---@return {[1]:integer,[2]:integer}[] pairs of indices into `lines` (del index, add index)
function M.pair_changes(lines)
  local pairs_ = {}
  local i, n = 1, #lines
  while i <= n do
    if lines[i].kind == 'del' then
      local ds = i
      while i <= n and lines[i].kind == 'del' do
        i = i + 1
      end
      local de = i - 1
      local as = i
      while i <= n and lines[i].kind == 'add' do
        i = i + 1
      end
      local ae = i - 1
      for k = 0, math.min(de - ds, ae - as) do
        pairs_[#pairs_ + 1] = { ds + k, as + k }
      end
    else
      i = i + 1
    end
  end
  return pairs_
end

return M
