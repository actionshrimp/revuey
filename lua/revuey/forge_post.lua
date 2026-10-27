-- Posting a review to GitHub, the pure half (no UI, no processes): which local comments may be
-- added to a review ("add to review", `in_review`), where each one goes on GitHub (the PR, path,
-- line, startLine and side), the plan of one submit and its confirmation text. The GitHub calls
-- are in forge.lua; forge_post_view.lua runs the steps.
--
-- Where a comment goes. GitHub numbers a thread's lines in the file at the PR head (RIGHT) or at
-- the PR's base (LEFT), and only accepts lines inside the PR diff's hunks. revuey's own line
-- numbers are those of the review, which may show other text (uncommitted or unpushed changes, a
-- full-stack scope, a PR that moved). So a comment is only posted where the review's text IS
-- GitHub's text, checked against the PR's files as GitHub lists them (REST `pulls/N/files`: each
-- file's blob at the head and its diff hunks):
--   * RIGHT (new side): the review's file is the head's blob (the same bytes, so every line
--     number is the same line), and every commented line is inside one hunk of the PR's patch.
--   * LEFT (old side): every commented line is inside one hunk of the patch, and every old-side
--     line of that hunk has the review's old-side text at the same number.
--   * Lines the review shows as added (deleted) must be added (deleted) by this PR: in a
--     full-stack scope that is the layer that introduced them, never a later one that only shows
--     them as context.
--   * A file comment: the file is in the PR's diff, with the head's blob.
-- Anything else is refused with the reason, never moved: a comment lands on the line it was
-- written on, or nowhere.
local M = {}

M.MAX_BODY = 60000 -- bytes of a comment body (GitHub allows 65,536 characters)

M.VERDICTS = { 'comment', 'approve', 'request_changes' }
M.VERDICT_TEXT = { comment = 'Comment', approve = 'Approve', request_changes = 'Request changes' }

---Normalise a verdict argument (`approve`, `request-changes`, `changes`...), or nil.
function M.norm_verdict(v)
  v = (v or ''):lower():gsub('[%s%-]', '_')
  local alias = { approve = 'approve', approved = 'approve', comment = 'comment', request_changes = 'request_changes',
    changes = 'request_changes', request = 'request_changes', changes_requested = 'request_changes' }
  return alias[v]
end

local function short(oid)
  return oid and oid:sub(1, 7) or '?'
end
M.short = short

---Where a comment is with GitHub (forge_post_view: the state machine): nil, 'sending' (written
---ahead of a mutation, no answer yet), 'unknown' (no answer, and a reconcile could not tell),
---'pending' (in the viewer's pending review), 'posted'.
function M.state(c)
  return c and type(c.forge_post) == 'table' and c.forge_post.state or nil
end

---Can this comment be added to a review? Only the user's own saved comments (an AI review
---finding once accepted with `ca` is the user's), not drafts, resolved or dismissed ones, and
---not what is already on GitHub. Returns true, or false and why.
---@return boolean ok, string? why
function M.includable(c)
  if not c then
    return false, 'no comment here'
  end
  if c.forge then
    return false, 'this is a GitHub thread already (cr adds a local reply that can be posted)'
  end
  if M.state(c) == 'posted' then
    return false, ('already posted to GitHub #%s'):format(tostring(c.forge_post.pr))
  end
  local kind = c.author and c.author.kind or 'user'
  if kind == 'ai' then
    return false, 'an AI review finding: accept it first (it becomes your comment)'
  elseif kind ~= 'user' then
    return false, 'only your own comments are posted (this one is by ' .. (c.author.name or kind) .. ')'
  end
  if c.status == 'draft' then
    return false, 'save the draft first'
  elseif c.status == 'resolved' or c.status == 'dismissed' then
    return false, 'it is ' .. c.status .. ': reopen it first'
  end
  return true
end

-- ---------------------------------------------------------------------------
-- GitHub's diff of a file
-- ---------------------------------------------------------------------------

---Parse a PR file's `patch` (unified diff hunks, no file header): per side, line number ->
---{hunk, kind ('+'|'-'|' '), text}, and per hunk its old-side lines.
---@return {new:table<integer, table>, old:table<integer, table>, hunks:table[]}
function M.parse_patch(patch)
  local out = { new = {}, old = {}, hunks = {} }
  if type(patch) ~= 'string' then
    return out
  end
  local hk, o, n
  for line in (patch:gsub('\r\n', '\n') .. '\n'):gmatch('(.-)\n') do
    local os_, ns_ = line:match('^@@ %-(%d+),?%d* %+(%d+),?%d* @@')
    if os_ then
      hk = { old = {} }
      out.hunks[#out.hunks + 1] = hk
      o, n = tonumber(os_), tonumber(ns_)
    elseif hk then
      local c, text = line:sub(1, 1), line:sub(2):gsub('\r$', '')
      local idx = #out.hunks
      if c == ' ' then
        out.new[n] = { hunk = idx, kind = ' ', text = text }
        out.old[o] = { hunk = idx, kind = ' ', text = text }
        hk.old[o] = text
        o, n = o + 1, n + 1
      elseif c == '+' then
        out.new[n] = { hunk = idx, kind = '+', text = text }
        n = n + 1
      elseif c == '-' then
        out.old[o] = { hunk = idx, kind = '-', text = text }
        hk.old[o] = text
        o = o + 1
      end
      -- `\ No newline at end of file` and anything else: nothing on either side
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- One comment against one PR
-- ---------------------------------------------------------------------------

---@class revuey.PostWant  what a local comment covers in the review
---@field path string
---@field side 'new'|'old'
---@field first? integer       nil: a file comment
---@field last? integer
---@field file revuey.FileDiff  the review's file
---@field line fun(side:string, l:integer):string?   the review's text of a line
---@field kind fun(side:string, l:integer):string?   the review's row kind there (add|del|ctx)
---@field full? boolean        a full-stack scope (earlier layers' changes are in the diff)

---Where `want` goes in PR `n`'s diff (`pf`: the PR's file, nil when the PR does not change it;
---`parsed`: cache for parsed patches). Returns the thread item `{kind = 'thread', path, line,
---side, start_line?, start_side?}` / `{kind = 'thread', path, subject = 'FILE'}`, or nil and
---why not (a sentence about PR #n), plus true when the reason is about the lines (the file
---itself is the PR's).
---@param want revuey.PostWant
---@param pf? revuey.ForgeFile
---@return table? item, string? why, boolean? file_ok
function M.locate(want, pf, n, parsed)
  local f = want.file
  if not pf then
    return nil, ('%s is not changed in PR #%d'):format(want.path, n)
  end
  local deleted = f.status == 'D'
  local same_file
  if deleted then
    same_file = pf.status == 'removed'
  else
    same_file = pf.status ~= 'removed' and pf.sha ~= nil and pf.sha == f.new_blob
  end
  if not want.first then
    if not same_file then
      return nil, ('%s here is not the file at PR #%d\'s head (changed by uncommitted or unpushed work, a later layer, or the PR moved)'):format(want.path, n)
    end
    return { kind = 'thread', path = pf.path, subject = 'FILE' }
  end
  if want.side == 'new' and not same_file then
    return nil, ('%s here is not the file at PR #%d\'s head (changed by uncommitted or unpushed work, a later layer, or the PR moved)'):format(want.path, n)
  end
  if not pf.patch then
    return nil, ('GitHub shows no diff for %s in PR #%d (binary or too large); a file comment works'):format(want.path, n), true
  end
  parsed = parsed or {}
  local key = pf.path .. '\0' .. n
  parsed[key] = parsed[key] or M.parse_patch(pf.patch)
  local P = parsed[key]
  local by = want.side == 'new' and P.new or P.old
  local loc = want.first == want.last and ('%s:%d'):format(want.path, want.first) or ('%s:%d-%d'):format(want.path, want.first, want.last)
  local hunk
  for l = want.first, want.last do
    local x = by[l]
    if not x then
      local k = want.kind(want.side, l)
      if k == 'add' or k == 'del' then
        -- changed in this review but not by this PR: uncommitted work, or (full stack) an
        -- earlier layer
        local verb = k == 'add' and 'added' or 'deleted'
        if want.full and f.uncommitted then
          return nil, ('%s was %s by an earlier layer or by uncommitted work, not by PR #%d'):format(loc, verb, n), true
        elseif want.full then
          return nil, ('%s was %s by an earlier layer, not by PR #%d: post it from that layer\'s scope'):format(loc, verb, n), true
        elseif f.uncommitted then
          return nil, ('%s was %s by uncommitted work, which is not part of PR #%d'):format(loc, verb, n), true
        end
        return nil, ('%s was %s here but not in PR #%d\'s diff (GitHub\'s base differs from this review\'s)'):format(loc, verb, n), true
      end
      return nil, ('%s (%s) is not in PR #%d\'s diff (GitHub only takes lines inside its hunks)'):format(loc, want.side, n), true
    end
    if hunk and x.hunk ~= hunk then
      return nil, ('%s spans two hunks of PR #%d\'s diff; GitHub needs a range inside one'):format(loc, n), true
    end
    hunk = x.hunk
    local mine = want.line(want.side, l)
    if mine == nil or (mine:gsub('\r$', '')) ~= x.text then
      return nil, ('%s (%s) does not have the text PR #%d\'s diff has there'):format(loc, want.side, n), true
    end
    local k = want.kind(want.side, l)
    if (k == 'add' and x.kind ~= '+') or (k == 'del' and x.kind ~= '-') then
      -- (the new side here is the head's file, so this is never uncommitted work)
      return nil, ('%s was %s by an earlier layer, not by PR #%d: post it from that layer\'s scope'):format(loc, k == 'add' and 'added' or 'deleted', n), true
    end
  end
  if want.side == 'old' then
    -- LEFT is numbered in the PR's base: the whole hunk must read as the review's old side
    for l, text in pairs(P.hunks[hunk].old) do
      local mine = want.line('old', l)
      if mine == nil or (mine:gsub('\r$', '')) ~= text then
        return nil, ('%s (old): PR #%d\'s base is not the old side shown here'):format(loc, n), true
      end
    end
  end
  local gh_side = want.side == 'new' and 'RIGHT' or 'LEFT'
  local item = { kind = 'thread', path = pf.path, line = want.last, side = gh_side }
  if want.first ~= want.last then
    item.start_line, item.start_side = want.first, gh_side
  end
  return item
end

-- ---------------------------------------------------------------------------
-- The plan of one submit
-- ---------------------------------------------------------------------------

---@class revuey.PostTarget  an open PR of the scope, with what the posting needs to know
---@field pr revuey.PR
---@field key string           layer name ('' for a plain review)
---@field tip? string          the commit the review shows for it (the layer tip, HEAD)
---@field files? revuey.ForgeFile[]
---@field files_err? string
---@field pf? revuey.ForgePreflight  nil: did not resolve
---@field refused? string      nothing can go to this PR, and why

---@class revuey.PostPlan
---@field verdict string
---@field targets revuey.PostTarget[]   in scope order
---@field items table<revuey.PostTarget, {c:revuey.Comment, item:table}[]>
---@field refused {c:revuey.Comment, why:string}[]
---@field full boolean

local function body_of(c)
  return vim.trim(c.body or '')
end

---Refusals that apply to a whole PR (checked before its comments): not found, not open, the
---head on GitHub is not the commit the review shows, or a verdict GitHub refuses to its author.
function M.target_refusal(t, viewer, verdict)
  local n = t.pr.number
  if not t.pf then
    return ('PR #%d could not be read from GitHub'):format(n)
  end
  if t.pf.state ~= 'OPEN' then
    return ('PR #%d is %s'):format(n, t.pf.state:lower())
  end
  if not t.pf.head_oid or not t.tip or t.pf.head_oid ~= t.tip then
    return ('PR #%d\'s head on GitHub is %s, but this review shows %s (%s): fetch or push, then refresh (R)'):format(
      n,
      short(t.pf.head_oid),
      short(t.tip),
      t.pf.head_oid and t.tip and 'the PR moved, or unpushed commits' or 'unknown'
    )
  end
  if (verdict == 'approve' or verdict == 'request_changes') and viewer and t.pf.author and viewer:lower() == t.pf.author:lower() then
    return ('PR #%d is yours: GitHub does not let its author %s; submit a Comment review'):format(n, verdict == 'approve' and 'approve it' or 'request changes')
  end
end

---Plan a submit: route each included comment to one PR and check it there. Pure.
---@param o {comments:revuey.Comment[], place:fun(c):table, review:{file:fun(path):revuey.FileDiff?, line:fun(path, side, l):string?, kind:fun(path, side, l):string?}, targets:revuey.PostTarget[], full:boolean, verdict:string, viewer?:string}
---@return revuey.PostPlan
function M.plan(o)
  local plan = { verdict = o.verdict, targets = o.targets, items = {}, refused = {}, full = o.full }
  for _, t in ipairs(o.targets) do
    plan.items[t] = {}
    t.refused = M.target_refusal(t, o.viewer, o.verdict)
    if t.pf and t.pf.pending_other then
      t.refused = t.refused or ('PR #%d has more than one pending review of yours; submit or discard them on GitHub first'):format(t.pr.number)
    end
    t.by_path = {}
    for _, f in ipairs(t.files or {}) do
      t.by_path[f.path] = f
    end
  end
  local parsed = {}
  local function refuse(c, why)
    plan.refused[#plan.refused + 1] = { c = c, why = why }
  end
  local function add(t, c, item)
    if t.refused then
      return refuse(c, t.refused)
    end
    item.body = body_of(c)
    table.insert(plan.items[t], { c = c, item = item })
  end
  for _, c in ipairs(o.comments) do
    local ok, why = M.includable(c)
    local body = body_of(c)
    if not ok then
      refuse(c, why)
    elseif body == '' then
      refuse(c, 'the comment is empty')
    elseif #body > M.MAX_BODY then
      refuse(c, ('the comment is longer than GitHub takes (%d bytes)'):format(#body))
    elseif c.forge_reply then
      -- a reply in a GitHub thread: its PR, whatever the lines
      local fr, target = c.forge_reply, nil
      for _, t in ipairs(o.targets) do
        if t.pr.number == fr.pr and (not fr.repo or fr.repo == t.pr.repo) then
          target = t
        end
      end
      if not target then
        refuse(c, ('a reply to PR #%s, which is not an open PR of this scope'):format(tostring(fr.pr)))
      elseif not fr.thread_id then
        refuse(c, 'the GitHub thread it answers is unknown')
      else
        add(target, c, { kind = 'reply', thread_id = fr.thread_id })
      end
    else
      local p = o.place(c) or {}
      local a = c.anchor
      local path = p.path or a.path
      local file = o.review.file(path)
      if p.how == 'missing' or not file then
        refuse(c, ('%s is not in this review'):format(path))
      elseif p.outdated then
        refuse(c, 'outdated: the lines it was written on changed since')
      else
        local want = {
          full = o.full,
          path = path,
          side = a.side or 'new',
          first = (not c.file_level) and (p.start_line or a.start_line) or nil,
          last = (not c.file_level) and (p.end_line or a.end_line or p.start_line or a.start_line) or nil,
          file = file,
          line = function(side, l)
            return o.review.line(path, side, l)
          end,
          kind = function(side, l)
            return o.review.kind(path, side, l)
          end,
        }
        if #o.targets == 0 then
          refuse(c, 'no open pull request for this review')
        elseif not o.full then
          local t = o.targets[1]
          if t.refused then
            refuse(c, t.refused)
          elseif not t.files then
            refuse(c, ('could not read PR #%d\'s files from GitHub: %s'):format(t.pr.number, t.files_err or 'failed'))
          else
            local item, w = M.locate(want, t.by_path[path], t.pr.number, parsed)
            if item then
              add(t, c, item)
            else
              refuse(c, w)
            end
          end
        else
          -- full stack: the one open PR whose diff has these lines as the review shows them
          local hits, best, unread = {}, nil, nil
          for _, t in ipairs(o.targets) do
            if not t.files then
              unread = unread or t
            else
              local item, w, file_ok = M.locate(want, t.by_path[path], t.pr.number, parsed)
              if item then
                hits[#hits + 1] = { t = t, item = item }
              elseif file_ok and not best then
                best = w
              end
            end
          end
          if #hits == 1 then
            add(hits[1].t, c, hits[1].item)
          elseif #hits > 1 then
            local ns = vim.tbl_map(function(x)
              return '#' .. x.t.pr.number
            end, hits)
            refuse(c, ('%s fits several PRs of the stack (%s): post it from a layer\'s scope'):format(path, table.concat(ns, ', ')))
          elseif best then
            refuse(c, best)
          elseif unread then
            refuse(c, ('could not read PR #%d\'s files from GitHub: %s'):format(unread.pr.number, unread.files_err or 'failed'))
          else
            refuse(c, ('no open PR of the stack has %s as shown here (changed by uncommitted or unpushed work or a later layer, or its layer has no open PR)'):format(path))
          end
        end
      end
    end
  end
  return plan
end

local function norm_body(t)
  return vim.trim((t or ''):gsub('\r\n', '\n'))
end
M.norm_body = norm_body

---A comment of the pending review recorded by id (`forge_post.comment_id`), or nil.
---@param pending revuey.ForgePending
function M.by_id(pending, id)
  for _, pc in ipairs(pending and id and pending.comments or {}) do
    if pc.id == id then
      return pc
    end
  end
end

---Does a review comment match a stored payload (exactly what was sent)? The same body and, for
---a thread, the same path, line and start line (a file comment: FILE), not a reply; for a reply,
---a reply to a comment of the same thread (`thread_comments`: the ids of its comments). GitHub's
---review comments do not say their side, so a LEFT and a RIGHT payload with the same text on
---the same number both match one comment: reconcile then calls both unknown.
function M.payload_matches(pc, p, thread_comments)
  if norm_body(pc.body) ~= norm_body(p.body) then
    return false
  end
  if p.kind == 'reply' then
    return pc.reply_to ~= nil and (thread_comments or {})[pc.reply_to] == true
  end
  if pc.reply_to ~= nil or pc.path ~= p.path then
    return false
  end
  if p.subject == 'FILE' then
    return pc.subject == 'FILE'
  end
  -- the lines it was made on (`original*`): `line` follows the PR head, moves after a push and is
  -- null once outdated
  local line = pc.original_line or pc.line
  local start = pc.original_start_line or pc.start_line or line
  return pc.subject ~= 'FILE' and line == p.line and start == (p.start_line or p.line)
end

---Does the pool have a comment with this payload's body and path (whatever its lines)? Then a
---miss is never proof of absence.
local function similar(pool, p, claimed, before)
  for _, pc in ipairs(pool or {}) do
    if not claimed[pc.id] and not (before or {})[pc.id] and norm_body(pc.body) == norm_body(p.body)
      and (p.kind == 'reply' and pc.reply_to ~= nil or (p.kind ~= 'reply' and pc.path == p.path)) then
      return true
    end
  end
  return false
end

---@class revuey.ReconcileEntry
---@field key any
---@field id? string            a recorded GitHub comment id (checked by id only)
---@field payload? table        else what was sent (matched by payload_matches)
---@field pool? table[]         the comments of the review it went to; nil: could not be read
---@field complete? boolean     `pool` is all of them
---@field gone? boolean         the review does not exist (NOT_FOUND)
---@field before? table<string, true> ids that were there before it was sent (never it)
---@field thread_comments? table<string, true>

---Decide what became of comments sent to GitHub (pure). Results per key: `{found = pc}`,
---`{absent = true}` (GitHub definitely does not have it: the review is gone, or a complete read
---of it has no such comment) or `{unknown = why}` (anything else: a partial or failed read,
---several candidates, a candidate another entry also matches, or one that was there before).
---Recorded ids are settled first and claim their comments.
---@param entries revuey.ReconcileEntry[]
---@return table<any, table>
function M.reconcile(entries)
  local out, claimed = {}, {}
  for _, e in ipairs(entries) do
    if e.id then
      local hit
      for _, pc in ipairs(e.pool or {}) do
        if pc.id == e.id then
          hit = pc
        end
      end
      if hit then
        claimed[hit.id] = true
        out[e.key] = { found = hit }
      elseif e.gone or (e.pool and e.complete) then
        out[e.key] = { absent = true }
      else
        out[e.key] = { unknown = 'its review could not be read whole' }
      end
    end
  end
  local cands, users = {}, {}
  for _, e in ipairs(entries) do
    if not e.id then
      local list, taken = {}, false
      for _, pc in ipairs(e.pool or {}) do
        if M.payload_matches(pc, e.payload, e.thread_comments) then
          if claimed[pc.id] or (e.before or {})[pc.id] then
            taken = true
          else
            list[#list + 1] = pc
            users[pc.id] = (users[pc.id] or 0) + 1
          end
        end
      end
      cands[e.key] = { list = list, taken = taken }
    end
  end
  for _, e in ipairs(entries) do
    if not e.id then
      local c = cands[e.key]
      if e.gone then
        out[e.key] = { absent = true }
      elseif not e.pool then
        out[e.key] = { unknown = 'GitHub could not be read' }
      elseif #c.list == 1 and users[c.list[1].id] == 1 and not c.taken then
        out[e.key] = { found = c.list[1] }
      elseif #c.list == 0 and not c.taken and e.complete and not similar(e.pool, e.payload, claimed, e.before) then
        out[e.key] = { absent = true }
      elseif #c.list == 0 and not c.taken then
        out[e.key] = { unknown = 'its review could not be read whole' }
      else
        out[e.key] = { unknown = 'GitHub has comments it cannot be told apart from' }
      end
    end
  end
  return out
end

M.EVENT_STATE = { APPROVE = 'APPROVED', COMMENT = 'COMMENTED', REQUEST_CHANGES = 'CHANGES_REQUESTED' }
M.SKEW = 600 -- seconds of clock difference allowed between this machine and GitHub

---"2026-01-02T03:04:05Z" for seconds since the epoch.
function M.iso(t)
  return os.date('!%Y-%m-%dT%H:%M:%SZ', t)
end

---What became of a review created and submitted at once whose answer was lost (`entry`: {commit,
---event, body, started_at}), from the PR's latest reviews (forge.normalize_preflight): `{found =
---review}` when exactly one of the viewer's reviews has that commit, verdict and body and was made
---after it was sent; `{absent = true}` when there is none and the reviews read go back past that
---time; else `{unknown = why}`.
function M.find_atomic(entry, pf)
  if not pf or not pf.recent_read then
    return { unknown = 'GitHub could not be read' }
  end
  local since = M.iso(entry.started_at - M.SKEW)
  local hits, unsure = {}, false
  for _, rv in ipairs(pf.recent) do
    if rv.mine and rv.commit == entry.commit and rv.state == M.EVENT_STATE[entry.event]
      and norm_body(rv.body) == norm_body(entry.body) and rv.created_at >= since then
      -- with threads, it is ours only when every one sent is in it (read whole): an empty
      -- review of the same verdict made elsewhere is not
      local ok = true
      if entry.threads and #entry.threads > 0 then
        if rv.cursor then
          unsure, ok = true, false
        else
          local used = {}
          for _, p in ipairs(entry.threads) do
            local hit
            for _, pc in ipairs(rv.comments) do
              if not used[pc.id] and M.payload_matches(pc, p) then
                hit = pc
                break
              end
            end
            if not hit then
              ok = false
              break
            end
            used[hit.id] = true
          end
        end
      end
      if ok then
        hits[#hits + 1] = rv
      end
    end
  end
  if #hits == 1 then
    return { found = hits[1] }
  elseif #hits > 1 then
    return { unknown = 'several reviews of yours could be it' }
  elseif unsure then
    return { unknown = 'a review that could be it could not be read whole' }
  end
  if pf.recent_all or (pf.recent_since and pf.recent_since < since) then
    return { absent = true }
  end
  return { unknown = 'not all of the PR\'s recent reviews could be read' }
end

---"src/a.ts:12" for a comment of a pending review.
function M.pending_location(pc)
  local where = pc.path or '?'
  local l = pc.line or pc.original_line
  if pc.subject == 'FILE' then
    return where .. ' (file)'
  end
  if l then
    where = where .. ':' .. ((pc.start_line and pc.start_line ~= l) and (pc.start_line .. '-' .. l) or l)
  end
  return where .. (pc.reply_to and ' (reply)' or '')
end

-- ---------------------------------------------------------------------------
-- Confirmation
-- ---------------------------------------------------------------------------

local function location(c)
  return require('revuey.comments').location(c)
end

local function count(n, one, many)
  return ('%d %s'):format(n, n == 1 and one or many)
end

---How a PR's review is made, for the confirmation.
local MODE_TEXT = {
  atomic = 'a new review, created and submitted in one step',
  existing = 'added to your pending review on GitHub, then submitted',
  new_pending = 'a new pending review, filled, then submitted',
  submit = 'your pending review on GitHub, submitted',
}

---The confirmation text of a prepared submit (nothing has been sent yet): the verdict and, per
---PR, how its review is made and what it will publish: the comments and replies revuey will add
---(`+`), revuey's comments already in the pending review (`=`), the pending review's comments
---from elsewhere (submitted too), the commit it is bound to; a PR that is blocked and why; in a
---full stack, every PR of the stack. Then what is left out and why.
---@param r table forge_post_view.result
---@return string[] lines
function M.summary(r)
  local L = {}
  L[#L + 1] = ('Submit a "%s" review to GitHub%s'):format(M.VERDICT_TEXT[r.verdict] or r.verdict, r.body and r.body ~= '' and ' with a body' or '')
  for _, x in ipairs(r.prs) do
    local t = x.target
    L[#L + 1] = ''
    if x.nothing then
      L[#L + 1] = ('PR #%d: nothing to post, no review'):format(t.pr.number)
    else
      local parts = {}
      if x.threads > 0 then
        parts[#parts + 1] = count(x.threads, 'comment', 'comments')
      end
      if x.replies > 0 then
        parts[#parts + 1] = count(x.replies, 'reply', 'replies')
      end
      L[#L + 1] = ('PR #%d (%s): %s from revuey'):format(t.pr.number, t.pr.repo:gsub('^[^/]+/', ''), #parts > 0 and table.concat(parts, ', ') or 'no comments')
      if x.blocked then
        L[#L + 1] = '  BLOCKED, not submitted: ' .. x.blocked
        L[#L + 1] = '  Check the PR on GitHub; `:RevueySubmit forget` on a comment drops revuey\'s record of it (it may exist on GitHub).'
      elseif x.mode then
        L[#L + 1] = '  ' .. MODE_TEXT[x.mode]
      end
      for _, e in ipairs(x.already) do
        L[#L + 1] = '  = ' .. e
      end
      for _, e in ipairs(x.entries) do
        L[#L + 1] = '  + ' .. e
      end
      for _, e in ipairs(x.unknown or {}) do
        L[#L + 1] = '  ? ' .. e
      end
      if #x.others > 0 then
        L[#L + 1] = ('  Your pending review on GitHub already has %s from elsewhere; they are submitted too:'):format(count(x.pending_total, 'comment', 'comments'))
        for _, e in ipairs(x.others) do
          L[#L + 1] = '    ' .. e
        end
        if x.pending_total > #x.others then
          L[#L + 1] = ('    … %d more'):format(x.pending_total - #x.others)
        end
      end
      if x.commit_note then
        L[#L + 1] = '  ' .. x.commit_note
      end
    end
  end
  if #r.left_out > 0 then
    L[#L + 1] = ''
    L[#L + 1] = ('Not posted (%d):'):format(#r.left_out)
    for _, e in ipairs(r.left_out) do
      L[#L + 1] = ('  - %s: %s'):format(location(e.c), e.why)
    end
  end
  for _, w in ipairs(r.warnings or {}) do
    L[#L + 1] = ''
    L[#L + 1] = w
  end
  return L
end

return M
