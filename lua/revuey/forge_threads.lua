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
---hunk ends at the thread's last line: on GitHub the hunk's last line on the thread's side is
---always `originalLine`). Fewer when the hunk is shorter; {} without a hunk. The second value is
---up to CONTEXT lines of that side just above them (the hunk's own context), for checking that
---a match is the thread's code and not another copy.
---@return string[] lines, string[] before
function M.expected(diff_hunk, side, n)
  if type(diff_hunk) ~= 'string' or diff_hunk == '' then
    return {}, {}
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
  local from = math.max(1, #lines - n + 1)
  return vim.list_slice(lines, from, #lines), vim.list_slice(lines, math.max(1, from - M.CONTEXT), from - 1)
end

M.CONTEXT = 3 -- hunk lines above the thread compared with the review's text

---Too little text to identify a place by itself (`end`, `}`, `return err`, blank lines)?
function M.weak(lines)
  return comments.distinctive_words(lines) < comments.MIN_WORDS
end

---The thread's lines on its side: `line`/`startLine`, or for an outdated thread (no `line`)
---`originalLine`/`originalStartLine`. A range across both sides is anchored on its last line
---(the start is a line number on the other side). GitHub can report a `startLine` past `line`
---(seen on real PRs once the range moved): the start is then `line` minus the original span.
---@return integer first, integer last
function M.range(t)
  local last = t.line or t.original_line
  local first
  if t.line then
    first = t.start_line
  else
    first = t.original_start_line
  end
  first = first or last
  if t.start_side and t.start_side ~= t.side then
    first = last
  end
  if first > last then
    local span = (t.original_line and t.original_start_line) and (t.original_line - t.original_start_line) or 0
    first = math.max(1, last - math.max(0, span))
  end
  return first, last
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
---`o.head_blob`: the blob of the thread's file at the PR's head commit (forge_view looks it up).
---When the review's new side of the file is that blob, the review shows exactly the text GitHub
---numbers the thread against, so a text match at GitHub's line is trusted as is (weak or
---repeated lines too; the hunk's context may be from an older push).
---@param t revuey.ForgeThread
---@param o? {head_blob?:string}
---@return revuey.ForgeThreadPlacement
function M.place(t, ctx, o)
  local U = ctx.U
  local path = t.path
  if not U.by_path[path] then
    for _, f in ipairs(ctx.files) do
      if f.old_path == path and f.path ~= path and f.status == 'R' then
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
  local first, last = M.range(t)
  local n = last - first
  local file = ctx.files[U.by_path[path]]
  local at_head = side == 'new' and o and o.head_blob ~= nil and file and file.new_blob == o.head_blob
  local first_comment = t.comments[1]
  local want, before = M.expected(first_comment and first_comment.diff_hunk, side, n + 1)
  local weak = M.weak(want)
  local rows = ctx.rows(path, side)
  local out = { path = path, side = side, start_line = first, end_line = last, how = 'outside' }
  local function get(l)
    local x = ctx.get_line(path, side, l)
    return x and (x:gsub('\r$', ''))
  end
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
      if get(p + off + i - 1) ~= w then
        return false
      end
    end
    return true
  end
  ---The hunk's lines above the range against the review's: all of them for weak text, else at
  ---least one with some text (when the hunk has any).
  local function context_ok(p)
    local any, ok = false, false
    for i, b in ipairs(before) do
      local same = get(p - #before + i - 1) == b
      if weak and not same then
        return false
      end
      if b:find('%w') then
        any = true
        ok = ok or same
      end
    end
    return weak or not any or ok
  end
  ---Is `p` the only window within RADIUS with these lines (copies off the diff counted)?
  local function unique_near(p)
    for q = math.max(1, p - M.RADIUS), p + M.RADIUS do
      if q ~= p and matches(q) then
        return false
      end
    end
    return true
  end
  -- at GitHub's line: the text matches, and the review is the PR's head for this file, or the
  -- hunk's context matches, or the text is strong and has no other copy nearby (the context is
  -- from the push the comment was made on; a later push may have edited the lines above)
  if t.line and shown(first) and matches(first)
    and (at_head or context_ok(first) or (not weak and #want > 0 and unique_near(first))) then
    out.how = 'line'
    return out
  end
  -- moved: the same lines and context, one copy in the side's text within RADIUS (copies on
  -- lines the diff does not show count too), shown. Weak text needs context to go on.
  -- (a line with hardly any text, such as `}`, only with its whole context matching)
  -- Weak text still at GitHub's line has not moved: only its context changed (a later push or
  -- a local edit above it), and another copy of the old block nearby (the same `}` or `return
  -- err` in the next function) would be a wrong place. Listed apart instead.
  local unmoved = weak and t.line ~= nil and matches(first)
  local has_context = table.concat(before, ' '):find('%w') ~= nil
  if not unmoved and #want > 0 and (table.concat(want, ' '):find('%w.-%w.-%w') or has_context)
    and not (weak and not has_context) then
    local hits = {}
    for p = math.max(1, first - M.RADIUS), first + M.RADIUS do
      if matches(p) and context_ok(p) then
        hits[#hits + 1] = p
      end
    end
    if #hits == 1 and shown(hits[1]) then
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
  local first_line, last_line
  if not file_level then
    first_line, last_line = M.range(t)
  end
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
      root_id = c1.id, -- GitHub's replyTo for a reply in this thread
    },
    anchor = {
      path = t.path,
      side = side,
      start_line = first_line,
      end_line = last_line,
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
