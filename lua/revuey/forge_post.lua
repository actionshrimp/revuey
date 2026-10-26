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

---Where a comment is with GitHub: nil, 'pending' (in the viewer's pending review, not yet
---submitted), 'unknown' (an add whose answer was lost: maybe in the pending review) or
---'posted'.
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
    -- one whose add answer was lost may be in the pending review: matched whatever its state now
    if not ok and M.state(c) ~= 'unknown' then
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

---After an add whose answer was lost (a timeout: GitHub may have applied it), the comment of
---the pending review that is this item, matched strictly: the same body and, for a thread, the
---same path, line and start line (a file comment: FILE), not a reply; for a reply, a reply to
---one of `thread_comments` (the ids of the thread's comments). A comment of the pending review
---is given to at most one local comment (`claimed`, updated). GitHub's review comments do not
---say which side they are on, so a LEFT and a RIGHT comment with the same text on the same line
---number would be taken for each other.
---@param pending revuey.ForgePending
---@param claimed table<string, true>
---@param thread_comments? table<string, true>
function M.match_lost(item, pending, claimed, thread_comments)
  local body = norm_body(item.body)
  for _, pc in ipairs(pending and pending.comments or {}) do
    if not claimed[pc.id] and norm_body(pc.body) == body then
      local ok
      if item.kind == 'reply' then
        ok = pc.reply_to ~= nil and (thread_comments or {})[pc.reply_to] == true
      elseif pc.reply_to == nil and pc.path == item.path then
        if item.subject == 'FILE' then
          ok = pc.subject == 'FILE'
        else
          ok = pc.subject ~= 'FILE' and pc.line == item.line and (pc.start_line or pc.line) == (item.start_line or item.line)
        end
      end
      if ok then
        claimed[pc.id] = true
        return pc
      end
    end
  end
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

---The confirmation text of a prepared submit (after the add step): the verdict and, per PR, what
---the review will publish: comments and replies revuey added (now and earlier), the pending
---review's own comments from elsewhere (they are submitted too), the commit it is bound to;
---then what is left out and why. `r`: the prepared result (forge_post_view.prepare).
---@return string[] lines
function M.summary(r)
  local L = {}
  L[#L + 1] = ('Submit a "%s" review to GitHub%s'):format(M.VERDICT_TEXT[r.verdict] or r.verdict, r.body and r.body ~= '' and ' with a body' or '')
  for _, x in ipairs(r.prs) do
    local t = x.target
    local parts = {}
    if x.threads > 0 then
      parts[#parts + 1] = count(x.threads, 'comment', 'comments')
    end
    if x.replies > 0 then
      parts[#parts + 1] = count(x.replies, 'reply', 'replies')
    end
    L[#L + 1] = ''
    L[#L + 1] = ('PR #%d (%s): %s from revuey'):format(t.pr.number, t.pr.repo:gsub('^[^/]+/', ''), #parts > 0 and table.concat(parts, ', ') or 'no comments')
    for _, e in ipairs(x.entries) do
      L[#L + 1] = '  + ' .. e
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
