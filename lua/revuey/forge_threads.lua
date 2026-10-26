-- Review threads of a pull request in the composed diff (pure: no UI). Where a GitHub thread
-- goes in the review being shown (its path, side and lines, checked against the text of its
-- `diffHunk`), and the comment-like item comments_view draws for it. The threads themselves
-- come from forge.fetch_threads; comments_view renders the items next to local comments.
--
-- Threads are read-only here: they are never stored in the comments file, and keep their
-- GitHub ids (`forge.thread_id`, each comment's id and database id) for replies posted later.
local comments = require('revuey.comments')

local M = {}

M.RADIUS = 100 -- a thread whose lines moved is looked for this many lines either side
M.ID_PREFIX = 'gh:' -- item ids: never a local comment id (those are hex)

---@class revuey.ForgeThreadPlacement
---@field path string           the file in the review (a renamed file's new path)
---@field side? 'new'|'old'
---@field start_line? integer
---@field end_line? integer
---@field how 'line'|'moved'|'file'|'outside'|'missing'
---  line: at GitHub's line, whose text matches; moved: the same text, unique within RADIUS lines;
---  file: a file-level thread; outside: the file is in the review but the lines are not shown
---  (outdated on GitHub, changed locally, or outside this diff's hunks); missing: the file is
---  not in the review

local function days_from_civil(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

---ISO 8601 time from GitHub (`2026-01-02T03:04:05Z`, or with an offset) -> ms since the epoch.
function M.iso_ms(s)
  local y, mo, d, h, mi, sec, rest = (s or ''):match('^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)%.?%d*(.*)$')
  if not y then
    return 0
  end
  local t = days_from_civil(tonumber(y), tonumber(mo), tonumber(d)) * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec)
  local sign, oh, om = rest:match('^([+-])(%d%d):?(%d%d)$')
  if sign then
    local off = tonumber(oh) * 3600 + tonumber(om) * 60
    t = sign == '+' and t - off or t + off
  end
  return t * 1000
end

---The commented lines as the thread's diff hunk shows them: the last `n` lines of `side` (the
---hunk ends at the thread's last line). Fewer when the hunk is shorter; {} without a hunk.
---@return string[]
function M.expected(diff_hunk, side, n)
  if type(diff_hunk) ~= 'string' or diff_hunk == '' then
    return {}
  end
  local keep = side == 'old' and '-' or '+'
  local lines = {}
  local text = diff_hunk:gsub('\r\n', '\n'):gsub('\n$', '')
  for l in (text .. '\n'):gmatch('(.-)\n') do
    local c = l:sub(1, 1)
    if c == ' ' or c == keep then
      lines[#lines + 1] = (l:sub(2):gsub('\r$', ''))
    end
  end
  return vim.list_slice(lines, math.max(1, #lines - n + 1), #lines)
end

---Is the thread on the whole file (no line on either commit)?
function M.file_level(t)
  return t.subject == 'FILE' or (t.line == nil and t.original_line == nil)
end

---Where thread `t` goes in the review described by `ctx` (comments.context: files, units, side
---texts). GitHub's lines are those of the PR's head (base for LEFT); the review may show other
---text there (local commits, uncommitted edits, a full-stack scope, an older or newer fetch),
---so a line is only used when the text there is what the thread's diff hunk shows. Otherwise the
---same lines are looked for nearby (unique copy only); when in doubt the thread is `outside`,
---never misplaced. Outdated threads (no current line) are looked for by their original line.
---@param t revuey.ForgeThread
---@return revuey.ForgeThreadPlacement
function M.place(t, ctx)
  local U = ctx.U
  local path = t.path
  if not U.by_path[path] then
    for _, f in ipairs(ctx.files) do
      if f.old_path == path and f.path ~= path then
        path = f.path
        break
      end
    end
  end
  if not U.by_path[path] then
    return { path = t.path, how = 'missing' }
  end
  if M.file_level(t) then
    return { path = path, how = 'file' }
  end
  local side = t.side == 'LEFT' and 'old' or 'new'
  local last = t.line or t.original_line
  local first = (t.line and t.start_line) or (not t.line and t.original_start_line) or last
  if t.start_side and t.start_side ~= t.side then
    first = last -- a range across both sides: anchored on its last line only
  end
  if first > last then
    first, last = last, first
  end
  local n = last - first
  local first_comment = t.comments[1]
  local want = M.expected(first_comment and first_comment.diff_hunk, side, n + 1)
  local rows = ctx.rows(path, side)
  local out = { path = path, side = side, start_line = first, end_line = last, how = 'outside' }
  local function shown(p)
    for l = p, p + n do
      if not rows.by_lnum[l] then
        return false
      end
    end
    return true
  end
  local function matches(p)
    local off = (n + 1) - #want
    for i, w in ipairs(want) do
      local got = ctx.get_line(path, side, p + off + i - 1)
      if got == nil or (got:gsub('\r$', '')) ~= w then
        return false
      end
    end
    return true
  end
  if t.line and shown(first) and matches(first) then
    out.how = 'line'
    return out
  end
  -- moved: the same lines (with enough text to mean something), one copy within RADIUS
  if #want > 0 and table.concat(want, ' '):find('%w.-%w.-%w') then
    local hits = {}
    for _, p in ipairs(rows.sorted) do
      if math.abs(p - first) <= M.RADIUS and shown(p) and matches(p) then
        hits[#hits + 1] = p
      end
    end
    if #hits == 1 then
      out.start_line, out.end_line, out.how = hits[1], hits[1] + n, 'moved'
      return out
    end
  end
  return out
end

---The comment-like item comments_view draws for a thread: `{id, forge, anchor, author, body,
---thread, status, created_at, updated_at, file_level}`, with `forge` holding the GitHub side
---({thread_id, pr, pr_url, repo, url, resolved, resolved_by, outdated, pending, hidden,
---comment_id, database_id}). Authors are `{kind = 'forge', name = login}`.
---@param t revuey.ForgeThread
---@param pr revuey.PR
function M.item(t, pr)
  local c1 = t.comments[1] or { author = 'ghost', body = '', created_at = '', state = 'SUBMITTED' }
  local last = t.comments[#t.comments] or c1
  local replies = {}
  local pending = false
  for i, c in ipairs(t.comments) do
    pending = pending or c.state == 'PENDING'
    if i > 1 then
      replies[#replies + 1] = {
        id = c.id,
        author = { kind = 'forge', name = c.author },
        body = c.body,
        created_at = M.iso_ms(c.created_at),
        updated_at = M.iso_ms(c.edited_at or c.created_at),
        pending = c.state == 'PENDING' or nil,
      }
    end
  end
  local file_level = M.file_level(t)
  local side = t.side == 'LEFT' and 'old' or 'new'
  local last_line = t.line or t.original_line
  local first_line = (t.line and t.start_line) or (not t.line and t.original_start_line) or last_line
  return {
    id = M.ID_PREFIX .. t.id,
    forge = {
      thread_id = t.id,
      pr = pr.number,
      pr_url = pr.url,
      repo = pr.repo,
      url = c1.url ~= '' and c1.url or pr.url,
      resolved = t.resolved,
      resolved_by = t.resolved_by,
      outdated = t.outdated,
      pending = pending,
      hidden = math.max(0, (t.total or 0) - #t.comments),
      comment_id = last.id,
      database_id = last.database_id,
    },
    anchor = {
      path = t.path,
      side = side,
      start_line = not file_level and math.min(first_line, last_line) or nil,
      end_line = not file_level and math.max(first_line, last_line) or nil,
    },
    author = { kind = 'forge', name = c1.author },
    body = c1.body,
    thread = replies,
    status = t.resolved and 'resolved' or 'saved',
    created_at = M.iso_ms(c1.created_at),
    updated_at = M.iso_ms(c1.edited_at or c1.created_at),
    file_level = file_level,
  }
end

---Counts for the panel: open and resolved threads, and how many are outdated on GitHub.
---@param threads revuey.ForgeThread[]
function M.summary(threads)
  local s = { open = 0, resolved = 0, outdated = 0 }
  for _, t in ipairs(threads or {}) do
    if t.resolved then
      s.resolved = s.resolved + 1
    else
      s.open = s.open + 1
    end
    if t.outdated then
      s.outdated = s.outdated + 1
    end
  end
  return s
end

---"src/cart.ts:12" for an item (as comments.location).
function M.location(item)
  return comments.location(item)
end

return M
