-- Posting a review to GitHub (UI glue over forge_post.lua and forge.lua). `:RevueySubmit` / the
-- forge_submit key runs, one submit at a time:
--   1. prepare: the scope's open PRs (forge_view), each PR's files (REST) and a preflight
--      (GraphQL: the PR's node id, head, author, the viewer's pending review and its comments),
--      then forge_post.plan routes and checks every comment added to the review (`in_review`);
--   2. add (`add_to_pending`): the planned comments and replies go into the viewer's pending
--      review on each PR (theirs when they have one, which GitHub allows only one of; else a new
--      one bound to the reviewed head), skipping those already there; each added comment is
--      recorded at once as "in pending review" (`forge_post.state = 'pending'`), so a later
--      submit never adds it twice. Nothing is visible to anyone else yet;
--   3. confirm: the verdict, per PR what revuey added and what the pending review already had
--      from elsewhere (submitted too), the commit it is bound to, and what was left out and why;
--      the body can be written here;
--   4. submit (`submit`): `submitPullRequestReview` per PR; its comments become `posted`, and
--      the threads are fetched again so they show as GitHub threads.
-- Cancelling at 3, or a failed submit, leaves the pending review on GitHub as it is (it is the
-- user's, visible in GitHub's UI and in other tools such as Graphite); nothing is ever deleted.
local api = vim.api
local comments = require('revuey.comments')
local forge = require('revuey.forge')
local post = require('revuey.forge_post')
local git = require('revuey.git')
local log = require('revuey.log')

local M = {}

---The running submit (one at a time, whatever review it came from): {s, phase}.
M.job = nil

---Ask with choices (vim.fn.confirm); tests replace this.
---@return integer choice (0: cancelled)
function M.ask(msg, choices, default)
  return vim.fn.confirm(msg, choices, default or 1)
end

---Pick a verdict (vim.ui.select); tests pass one instead.
function M.pick_verdict(cb)
  vim.ui.select(post.VERDICTS, {
    prompt = 'Review verdict',
    format_item = function(v)
      return post.VERDICT_TEXT[v]
    end,
  }, function(v)
    cb(v)
  end)
end

local function notify(msg, level)
  vim.notify('revuey: ' .. msg, level or vim.log.levels.INFO)
end

---Comments added to the review in this scope (not posted yet), and those revuey put into a
---pending review earlier (published by its submit whatever their toggle says now).
function M.included(store)
  local out = {}
  for _, c in ipairs(comments.list(store, { include_resolved = true, include_drafts = true })) do
    local st = post.state(c)
    if st ~= 'posted' and (c.in_review or st == 'pending' or st == 'unknown') then
      out[#out + 1] = c
    end
  end
  return out
end

---How many comments are added to the review and not posted (panel, messages).
function M.count(store)
  local n = 0
  for _, c in pairs(store and store.comments or {}) do
    if not c.deleted and c.in_review and post.state(c) ~= 'posted' then
      n = n + 1
    end
  end
  return n
end

---The open PRs of the scope with the commit the review shows for each (forge_view.scope_prs):
---the layer tip, or HEAD for a plain review.
---@return revuey.PostTarget[]
function M.scope_targets(s)
  local fv = require('revuey.forge_view')
  local f = s.forge
  if not f or not f.targets then
    return {}
  end
  local keys = {}
  local key = fv.current_key(s)
  if key then
    keys[1] = key
  elseif s.review.stack then
    for _, l in ipairs(s.review.stack.layers) do
      keys[#keys + 1] = l.name
    end
  end
  local out, seen = {}, {}
  for _, k in ipairs(keys) do
    local t = f.targets[k]
    local pr = forge.get(t)
    if pr and pr.state == 'OPEN' and not seen[pr.url] then
      seen[pr.url] = true
      out[#out + 1] = { pr = pr, key = k, tip = t.tip }
    end
  end
  return out
end

---The review's text and row kinds, for forge_post.plan.
local function review_access(s)
  local cv = require('revuey.comments_view')
  local ctx = cv.context(s)
  local U = require('revuey.review').units(s.review)
  return {
    file = function(path)
      local fi = U.by_path[path]
      return fi and s.review.files[fi] or nil
    end,
    line = function(path, side, l)
      return ctx.get_line(path, side, l)
    end,
    kind = function(path, side, l)
      local r = ctx.rows(path, side).by_lnum[l]
      local f = r and s.review.files[r.fi]
      local x = f and f.hunks[r.hi] and f.hunks[r.hi].lines[r.li]
      return x and x.kind or nil
    end,
  }, ctx
end

---Record where a comment is on GitHub (merged and saved like any change; no event).
local function record(store, id, fields)
  local cur = comments.get(store, id)
  if not cur then
    return
  end
  local c = vim.deepcopy(cur)
  c.forge_post = vim.tbl_extend('force', type(c.forge_post) == 'table' and c.forge_post or {}, fields)
  if fields.state == 'posted' then
    c.in_review = false
  end
  comments.put(store, c)
end

local function save(store)
  local ok, err = pcall(comments.save, store)
  if not ok then
    log.write('forge', 'saving posted comments failed: ' .. tostring(err))
  end
end

local function host_of(t)
  return (t.pr.repo or ''):match('^([^/]+)/') or 'github.com'
end

local function split(t)
  local _, owner, name = (t.pr.repo or ''):match('^(.-)/([^/]+)/([^/]+)$')
  return owner, name
end

---One line about a comment for the confirmation.
local function entry(c, extra)
  local where = comments.location(c)
  if c.forge_reply then
    where = where .. ' (reply in a GitHub thread)'
  end
  local first = comments.first_line(c.body)
  if #first > 50 then
    first = first:sub(1, 49) .. '…'
  end
  return where .. '  ' .. first .. (extra and (' ' .. extra) or '')
end

-- ---------------------------------------------------------------------------
-- 1. Prepare
-- ---------------------------------------------------------------------------

---Run the preflight for `targets` (one query per host) and read the rest of each pending
---review's comments. Sets `t.pf` per target, `r.viewer` and `r.reviews` (review id -> state,
---false when GitHub says it does not exist). Call inside git.async. Returns true, or false and
---why. A pending review whose comments could not all be read is marked `incomplete`.
function M.preflight(r, targets, review_ids)
  local by_host = {}
  for _, t in ipairs(targets) do
    local h = host_of(t)
    by_host[h] = by_host[h] or {}
    table.insert(by_host[h], t)
  end
  r.reviews = r.reviews or {}
  for host, list in pairs(by_host) do
    local prs = {}
    for i, t in ipairs(list) do
      local owner, name = split(t)
      prs[i] = { owner = owner, name = name, number = t.pr.number, t = t }
    end
    local query, aliases = forge.build_preflight_query(prs, review_ids)
    local data, err, errors = forge.run_graphql(query, host)
    if not data then
      return false, err
    end
    local viewer, pfs, reviews = forge.normalize_preflight(data, aliases, errors)
    r.viewer = r.viewer or viewer
    for _, p in ipairs(prs) do
      p.t.pf = nil
    end
    for alias, pf in pairs(pfs) do
      aliases[alias].t.pf = pf
    end
    for id, st in pairs(reviews) do
      r.reviews[id] = st
    end
    for _, t in ipairs(list) do
      local p = t.pf and t.pf.pending
      if p and p.cursor then
        local done, perr = forge.fetch_pending_comments(p, host)
        if not done then
          p.incomplete = true
          log.write('forge', ('PR #%d: reading the pending review failed: %s'):format(t.pr.number, tostring(perr)))
        end
      end
    end
  end
  return true
end

---Clear a comment's GitHub record (and with `untoggle`, its "add to review").
local function forget(store, c)
  local cur = comments.get(store, c.id)
  if not cur then
    return c
  end
  local copy = vim.deepcopy(cur)
  copy.forge_post = nil
  comments.put(store, copy)
  return copy
end

---Sort the comments of a submit by where they are with GitHub (after the preflight): recorded
---in the pending review and still there (by id: `t.already`, never planned again), in a review
---submitted meanwhile (posted), in a review or comment that is gone (forgotten; planned again
---only when still added to the review), unknown (planned, matched strictly in the add step),
---or new. Returns the comments to plan and those left out with the reason.
---@return revuey.Comment[] todo, {c:revuey.Comment, why:string}[] left
function M.classify(r, included)
  local store = r.store
  local todo, left = {}, {}
  local posted_elsewhere, dirty = 0, false
  for _, t in ipairs(r.targets) do
    t.already = {}
  end
  local function target_of(fp)
    for _, t in ipairs(r.targets) do
      if t.pr.number == fp.pr and (not fp.repo or fp.repo == t.pr.repo) then
        return t
      end
    end
  end
  for _, c in ipairs(included) do
    local st = post.state(c)
    local fp = c.forge_post
    local rst -- that review's state: a state, false (gone), nil (not asked, or unknown)
    if st == 'pending' or st == 'unknown' then
      rst = r.reviews[fp.review_id]
    end
    local t = fp and target_of(fp)
    local p = t and t.pf and t.pf.pending
    if (st == 'pending' or st == 'unknown') and rst == nil then
      -- GitHub did not say what became of that review (not a NOT_FOUND): never guess
      left[#left + 1] = { c = c, why = 'could not check your earlier pending review on GitHub; try again' }
    elseif st == 'pending' and rst ~= 'PENDING' and rst ~= false then
      -- submitted meanwhile (from GitHub or another tool): it is on GitHub now
      record(store, c.id, { state = 'posted', posted_at = comments.now_ms() })
      posted_elsewhere = posted_elsewhere + 1
    elseif st == 'unknown' and rst ~= 'PENDING' and rst ~= false then
      -- that review was published, maybe with it: never add it again unasked
      local copy = forget(store, c)
      copy.in_review = false
      comments.put(store, copy)
      dirty = true
      left[#left + 1] = { c = c, why = 'an earlier submit may have posted it (GitHub did not answer, and that review is published now): check on GitHub; ci adds it again' }
    elseif st == 'pending' and rst == 'PENDING' and not t then
      left[#left + 1] = { c = c, why = ('it is in your pending review on PR #%s, which is not an open PR of this scope'):format(tostring(fp.pr)) }
    elseif st == 'pending' and rst == 'PENDING' and p and p.id == fp.review_id and post.by_id(p, fp.comment_id) then
      local pc = post.by_id(p, fp.comment_id)
      r.claimed[pc.id] = true
      table.insert(t.already, { c = c, pc = pc })
    elseif st == 'pending' and rst == 'PENDING' and p and p.incomplete then
      left[#left + 1] = { c = c, why = 'could not read all of your pending review on GitHub; try again' }
    elseif st == 'pending' then
      -- the review or this comment is gone (discarded, deleted on GitHub): forget it, and add
      -- it again only when it is still added to the review
      c = forget(store, c)
      dirty = true
      if c.in_review then
        todo[#todo + 1] = c
      end
    elseif st == 'unknown' and rst == false then
      c = forget(store, c)
      dirty = true
      if c.in_review then
        todo[#todo + 1] = c
      end
    elseif st == 'unknown' then
      todo[#todo + 1] = c -- matched strictly against the pending review in the add step
    elseif c.in_review then
      todo[#todo + 1] = c
    end
  end
  if posted_elsewhere > 0 or dirty then
    save(store)
  end
  if posted_elsewhere > 0 then
    r.warnings = r.warnings or {}
    table.insert(r.warnings, ('%d comment%s revuey added earlier %s published meanwhile (the pending review was submitted elsewhere); marked posted.'):format(
      posted_elsewhere, posted_elsewhere == 1 and '' or 's', posted_elsewhere == 1 and 'was' or 'were'))
  end
  return todo, left
end

---Read GitHub (files, preflight) and plan. Call inside git.async. Returns the prepared run, or
---nil and a message.
function M.prepare(s, verdict)
  local store = require('revuey.comments_view').sync_store(s)
  local f = s.forge
  if not (f and f.ready) then
    return nil, 'the pull request lookup has not finished yet; try again in a moment'
  end
  local targets = M.scope_targets(s)
  if #targets == 0 then
    return nil, 'no open pull request for this review on GitHub'
  end
  local full = s.review.stack ~= nil and require('revuey.forge_view').current_key(s) == nil
  local included = M.included(store)
  if full and #included == 0 then
    return nil, 'nothing added to the review in the full stack (ci adds a comment); submit a verdict alone from a layer\'s scope'
  end
  local r = { s = s, store = store, verdict = verdict, targets = targets, full = full }
  -- every PR's files (only when a line or file comment may go to it), concurrently
  local need_files = false
  for _, c in ipairs(included) do
    need_files = need_files or not c.forge_reply
  end
  if need_files then
    local fns = {}
    for i, t in ipairs(targets) do
      fns[i] = function()
        return forge.fetch_pr_files(t.pr)
      end
    end
    for i, res in ipairs(git.all(fns)) do
      targets[i].files = res[1] and res[2] or nil
      targets[i].files_err = not res[1] and tostring(res[2]) or res[3]
      if not targets[i].files then
        log.write('forge', ('PR #%d files: %s'):format(targets[i].pr.number, tostring(targets[i].files_err)))
      end
    end
  end
  -- the preflight, per host (in practice one call), and the rest of each pending review
  local review_ids, seen = {}, {}
  for _, c in ipairs(included) do
    local st = post.state(c)
    local id = (st == 'pending' or st == 'unknown') and c.forge_post.review_id
    if id and not seen[id] then
      seen[id] = true
      review_ids[#review_ids + 1] = id
    end
  end
  local ok, err = M.preflight(r, targets, review_ids)
  if not ok then
    return nil, 'could not read the pull requests from GitHub: ' .. tostring(err)
  end
  r.claimed = {}
  local todo, left = M.classify(r, included)
  r.left_early = left
    local access, ctx = review_access(s)
  local cm = s.cm or {}
  r.plan = post.plan({
    comments = todo,
    place = function(c)
      return (cm.place and cm.place[c.id]) or comments.place(c, ctx)
    end,
    review = access,
    targets = targets,
    full = full,
    verdict = verdict,
    viewer = r.viewer,
  })
  for _, x in ipairs(left) do
    table.insert(r.plan.refused, x)
  end
  M.check_binding(r, access)
  if s.review.mode == 'worktree' and s.review.dirty then
    r.warnings = r.warnings or {}
    table.insert(r.warnings, 'This review shows uncommitted changes: they are not part of the pull request, and comments on them were left out.')
  end
  return r
end

---A pending review of the user's bound to another commit than the reviewed head: GitHub numbers
---its threads in that commit, so a line comment only goes in when its file there is the
---reviewed file (same blob); old-side comments never (the base may differ). Replies have no
---lines and always go in. Call inside git.async.
function M.check_binding(r, access)
  local keys, want = {}, {}
  for _, t in ipairs(r.targets) do
    local p = t.pf and t.pf.pending
    if p and p.commit and p.commit ~= t.tip and not t.refused then
      local keep = {}
      for _, x in ipairs(r.plan.items[t]) do
        local it = x.item
        local file = it.kind == 'thread' and access.file(it.path) or nil
        if it.kind == 'reply' then
          keep[#keep + 1] = x
        elseif it.side == 'LEFT' or not file or not file.new_blob then
          want[#want + 1] = { x = x, t = t }
        else
          local k = p.commit .. ':' .. it.path
          keys[#keys + 1] = k
          want[#want + 1] = { x = x, t = t, key = k, blob = file.new_blob }
        end
      end
      t.binding = keep
    end
  end
  if #want == 0 then
    return
  end
  local blobs = {}
  if #keys > 0 then
    local res = git.system({ 'git', 'cat-file', '--batch-check' }, { cwd = r.s.review.root, stdin = table.concat(keys, '\n') .. '\n' })
    local out = vim.split(res.stdout or '', '\n', { plain = true })
    for i, k in ipairs(keys) do
      local oid, kind = (out[i] or ''):match('^(%x+) (%a+)')
      if kind == 'blob' then
        blobs[k] = oid
      end
    end
  end
  for _, w in ipairs(want) do
    local t, x = w.t, w.x
    if w.key and blobs[w.key] == w.blob then
      table.insert(t.binding, x)
    else
      t.left_binding = (t.left_binding or 0) + 1
      table.insert(r.plan.refused, {
        c = x.c,
        why = ('your pending review on PR #%d is bound to commit %s, where %s'):format(
          t.pr.number,
          post.short(t.pf.pending.commit),
          w.key and (blobs[w.key] and 'this file differs from the reviewed one' or 'this file is missing there, or that commit is not in this clone')
            or 'the old side may be numbered differently'
        ),
      })
    end
  end
  for _, t in ipairs(r.targets) do
    if t.binding then
      r.plan.items[t], t.binding = t.binding, nil
    end
  end
end

-- ---------------------------------------------------------------------------
-- 2. Add to the pending review
-- ---------------------------------------------------------------------------

---The ids of a GitHub thread's comments (from the fetched threads, plus the one the local reply
---was made on): a reply in the pending review that answers one of them is in that thread.
local function thread_comments(t, c)
  local ids = {}
  local fr = c.forge_reply or {}
  if fr.comment_id then
    ids[fr.comment_id] = true
  end
  for _, th in ipairs(forge.threads_for(t.pr) or {}) do
    if th.id == fr.thread_id then
      for _, gc in ipairs(th.comments) do
        ids[gc.id] = true
      end
    end
  end
  return ids
end

---Read one PR's pending review again (after an add or create call whose answer was lost).
---Returns it (or false when there is none), or nil when GitHub could not be read.
local function reread(r, t)
  local probe = { reviews = {} }
  local saved = t.pf
  local ok = M.preflight(probe, { t }, {})
  local pf = t.pf
  t.pf = saved
  if not ok or not pf or (pf.pending and pf.pending.incomplete) then
    return nil
  end
  return pf.pending or false
end

local function pending_fields(t, review_id, it, gh)
  return {
    state = 'pending', pr = t.pr.number, repo = t.pr.repo, review_id = review_id,
    thread_id = (gh and gh.thread_id) or (it.kind == 'reply' and it.thread_id or nil),
    comment_id = gh and gh.comment_id, database_id = gh and gh.database_id, url = gh and gh.url,
  }
end

---Add the planned comments and replies of every PR to the viewer's pending review there
---(theirs, else a new one bound to the reviewed head), and record each one added as "in pending
---review" at once. Call inside git.async. Comments recorded there by id were sorted out before
---(M.classify: `t.already`). A comment whose earlier add answer was lost (`unknown`) is first
---matched strictly against the pending review (forge_post.match_lost). When a call's answer is
---lost now (no data: a timeout, GitHub may have applied it), the pending review is read again
---and the batch matched the same way; what still cannot be told is recorded `unknown` and the
---submit is blocked until a later prepare sorts it out (`r.blocked`). Fills per target:
---`review_id`, `added` ({c, gh}), `already` ({c, pc}), `failed` ({c, why}), `unknown` ({c}).
function M.add_to_pending(r)
  local store = r.store
  local claimed = r.claimed or {}
  for _, t in ipairs(r.targets) do
    t.added, t.failed, t.unknown = {}, {}, {}
    t.already = t.already or {}
    local items = r.plan.items[t] or {}
    local pending = t.pf and t.pf.pending
    t.review_id = pending and pending.id or nil
    local todo = {}
    for _, x in ipairs(items) do
      local pc = post.state(x.c) == 'unknown' and pending and x.c.forge_post.review_id == pending.id
        and post.match_lost(x.item, pending, claimed, thread_comments(t, x.c)) or nil
      if pc then
        table.insert(t.already, { c = x.c, pc = pc })
        record(store, x.c.id, pending_fields(t, pending.id, x.item, { comment_id = pc.id, database_id = pc.database_id, url = pc.url }))
      else
        todo[#todo + 1] = x
      end
    end
    if #todo > 0 and not t.review_id then
      -- GitHub allows one pending review per user and PR: only made when there is none
      local data, err, errors = forge.run_graphql(forge.build_pending_mutation(t.pf.id, t.tip), host_of(t))
      local rv = data and type(data.r) == 'table' and type(data.r.pullRequestReview) == 'table' and data.r.pullRequestReview
      local why = forge.alias_error(errors, 'r')
      if not (rv and type(rv.id) == 'string') and not why then
        -- no answer: it may have been made; look before trying anything else
        local again = reread(r, t)
        if again then
          rv = { id = again.id }
          t.pf.pending = again
        end
      end
      if rv and type(rv.id) == 'string' then
        t.review_id = rv.id
        t.created = true
      else
        why = why or err or 'no review came back'
        log.write('forge', ('PR #%d: creating the pending review failed: %s'):format(t.pr.number, why))
        for _, x in ipairs(todo) do
          table.insert(t.failed, { c = x.c, why = 'GitHub refused to start a review: ' .. why })
        end
        todo = {}
      end
    end
    -- in batches (one call each), recorded and saved after every batch; sized by the encoded
    -- bodies (the whole query is one argument)
    local i = 1
    while i <= #todo do
      local batch, bytes = {}, 0
      while i <= #todo and #batch < forge.POST_BATCH do
        local size = #vim.json.encode(todo[i].item.body) + 400
        if bytes > 0 and bytes + size > forge.POST_BATCH_BYTES then
          break
        end
        bytes = bytes + size
        batch[#batch + 1] = todo[i]
        i = i + 1
      end
      local mutation, aliases = forge.build_add_mutation(t.review_id, vim.tbl_map(function(x)
        return x.item
      end, batch))
      local data, err, errors = forge.run_graphql(mutation, host_of(t))
      local lost = {}
      for alias, it in pairs(aliases) do
        local x
        for _, b in ipairs(batch) do
          if b.item == it then
            x = b
          end
        end
        local gh = data and forge.added(data[alias])
        local why = forge.alias_error(errors, alias)
        if gh then
          claimed[gh.comment_id or ''] = true
          table.insert(t.added, { c = x.c, gh = gh })
          record(store, x.c.id, pending_fields(t, t.review_id, it, gh))
        elseif why then
          table.insert(t.failed, { c = x.c, why = 'GitHub refused it: ' .. why })
          log.write('forge', ('PR #%d: adding %s failed: %s'):format(t.pr.number, comments.location(x.c), why))
        else
          lost[#lost + 1] = x -- no answer: maybe added
        end
      end
      if #lost > 0 then
        log.write('forge', ('PR #%d: no answer for %d comment(s) (%s); reading the pending review again'):format(t.pr.number, #lost, tostring(err)))
        local again = reread(r, t)
        for _, x in ipairs(lost) do
          local pc = again and post.match_lost(x.item, again, claimed, thread_comments(t, x.c))
          if pc then
            table.insert(t.added, { c = x.c, gh = { comment_id = pc.id } })
            record(store, x.c.id, pending_fields(t, t.review_id, x.item, { comment_id = pc.id, database_id = pc.database_id, url = pc.url }))
          elseif again == nil then
            table.insert(t.unknown, { c = x.c })
            record(store, x.c.id, { state = 'unknown', pr = t.pr.number, repo = t.pr.repo, review_id = t.review_id })
            r.blocked = true
          else
            table.insert(t.failed, { c = x.c, why = 'GitHub did not add it (no answer: ' .. tostring(err or 'none') .. ')' })
          end
        end
      end
      save(store)
    end
  end
end

-- ---------------------------------------------------------------------------
-- 3. Confirm
-- ---------------------------------------------------------------------------

---What the review of each PR will publish, and what is left out (for forge_post.summary).
function M.result(r)
  local out = { verdict = r.verdict, body = r.body, prs = {}, left_out = {}, warnings = vim.deepcopy(r.warnings) }
  for _, x in ipairs(r.plan.refused) do
    out.left_out[#out.left_out + 1] = x
  end
  for _, t in ipairs(r.targets) do
    for _, x in ipairs(t.failed or {}) do
      out.left_out[#out.left_out + 1] = x
    end
    local p = t.pf and t.pf.pending
    local mine = {}
    local x = { target = t, threads = 0, replies = 0, entries = {}, others = {}, pending_total = 0 }
    local function count(c)
      if c.forge_reply then
        x.replies = x.replies + 1
      else
        x.threads = x.threads + 1
      end
    end
    for _, a in ipairs(t.already or {}) do
      mine[a.pc.id] = true
      count(a.c)
      if post.norm_body(a.c.body) ~= post.norm_body(a.pc.body) then
        -- edited here after it went in: GitHub publishes its own text
        local gh = comments.first_line(a.pc.body)
        x.entries[#x.entries + 1] = entry(a.c, ('(in your pending review, edited here since: GitHub has "%s")'):format(#gh > 40 and (gh:sub(1, 39) .. '…') or gh))
      else
        x.entries[#x.entries + 1] = entry(a.c, '(in your pending review already)')
      end
    end
    for _, a in ipairs(t.added or {}) do
      mine[a.gh.comment_id or ''] = true
      count(a.c)
      x.entries[#x.entries + 1] = entry(a.c)
    end
    for _, a in ipairs(t.unknown or {}) do
      x.entries[#x.entries + 1] = entry(a.c, '(GitHub did not answer: it may be in your pending review)')
    end
    if p then
      for _, pc in ipairs(p.comments) do
        if not mine[pc.id] then
          x.others[#x.others + 1] = post.pending_location(pc)
        end
      end
      x.pending_total = #x.others + math.max(0, (p.total or #p.comments) - #p.comments)
      if p.commit and p.commit ~= t.tip then
        x.commit_note = ('Your pending review is bound to commit %s, not the reviewed head %s; GitHub publishes it there.'):format(post.short(p.commit), post.short(t.tip))
      end
    end
    local ours = x.threads + x.replies > 0
    local has = ours or x.pending_total > 0
    if t.refused then
      -- nothing goes to this PR; say why once (its comments are listed with the reason)
      local listed = false
      for _, e in ipairs(out.left_out) do
        listed = listed or e.why == t.refused
      end
      if (has or not r.full) and not listed then
        out.warnings = out.warnings or {}
        table.insert(out.warnings, t.refused)
      end
    elseif not r.full or ours then
      out.prs[#out.prs + 1] = x
    elseif has then
      -- full stack: the verdict goes only where revuey's comments go
      out.warnings = out.warnings or {}
      table.insert(out.warnings, ('PR #%d: your pending review there (%d comment%s from elsewhere) is not submitted from the full stack; submit it from its layer\'s scope.'):format(
        t.pr.number, x.pending_total, x.pending_total == 1 and '' or 's'))
    end
  end
  return out
end

---Does a submit of `res` need a body first? A Comment review with nothing in it.
local function needs_body(res)
  if res.verdict ~= 'comment' or (res.body and res.body ~= '') then
    return false
  end
  for _, x in ipairs(res.prs) do
    if x.threads + x.replies + x.pending_total == 0 then
      return true
    end
  end
  return false
end

local function release(r)
  if M.job and M.job.r == r then
    M.job = nil
  end
end

---Say what stays in the pending review after a cancel (nothing is deleted).
local function left_pending_note(r)
  local n = 0
  for _, t in ipairs(r.targets) do
    n = n + #(t.added or {}) + #(t.already or {})
  end
  if n == 0 then
    return 'nothing submitted'
  end
  return ('nothing submitted; %d comment%s stay%s in your pending review on GitHub (only you see %s; revuey will not add %s again)'):format(
    n, n == 1 and '' or 's', n == 1 and 's' or '', n == 1 and 'it' or 'them', n == 1 and 'it' or 'them')
end

---The confirmation (on the main loop): Submit, write or edit the body, or cancel.
function M.confirm(r)
  local s = r.s
  if s.cleaned then
    release(r)
    return notify('the review closed before the confirmation: ' .. left_pending_note(r), vim.log.levels.WARN)
  end
  local res = M.result(r)
  if #res.prs == 0 then
    release(r)
    local lines = post.summary(res)
    table.remove(lines, 1)
    return notify('nothing to submit.' .. table.concat(lines, '\n'), vim.log.levels.WARN)
  end
  local text = table.concat(post.summary(res), '\n')
  if r.blocked then
    -- some adds got no answer and GitHub could not be read again: submitting now could
    -- publish them or not; a later submit checks them first
    M.ask(text .. '\n\nGitHub did not answer for some comments, so whether they are in your pending review is unknown: nothing can be submitted now. Submit again later; revuey checks them first.', '&Cancel', 1)
    release(r)
    return notify(left_pending_note(r))
  end
  local body_label = (r.body and r.body ~= '') and '&Edit body' or '&Write body'
  local nb = needs_body(res)
  if nb then
    text = text .. '\n\nA Comment review with no comments needs a body.'
  end
  local choices = nb and (body_label .. '\n&Cancel') or ('&Submit\n' .. body_label .. '\n&Cancel')
  local default = nb and 1 or (#res.left_out > 0 and 3 or 1)
  local choice = M.ask(text, choices, default)
  if nb then
    choice = choice == 1 and 2 or (choice == 2 and 3 or 0)
  end
  if choice == 1 then
    M.job.phase = 'submit'
    git.async(function()
      M.submit(r)
    end, function(err)
      release(r)
      log.write('forge', 'submit error: ' .. tostring(err))
      notify('submit failed: ' .. tostring(err), vim.log.levels.ERROR)
    end)
  elseif choice == 2 then
    M.write_body(r)
  else
    release(r)
    notify(left_pending_note(r))
  end
end

---Write or edit the review body in the comment editor, then back to the confirmation.
function M.write_body(r)
  local s = r.s
  if s.cleaned or not (s.diff_win and api.nvim_win_is_valid(s.diff_win)) then
    release(r)
    return notify(left_pending_note(r))
  end
  local went = false
  local back = function()
    if went then
      return
    end
    went = true
    vim.schedule(function()
      M.confirm(r)
    end)
  end
  local st = require('revuey.comment_editor').open({
    session = s,
    title = ('Review body · %s'):format(post.VERDICT_TEXT[r.verdict]),
    footer = ' <C-s> done  q back ',
    win = s.diff_win,
    return_win = s.diff_win,
    row = api.nvim_win_get_cursor(s.diff_win)[1],
    col = 2 * (s.numw or 3) + 4,
    text = r.body,
    startinsert = true,
    on_save = function(text)
      r.body = text
      back()
    end,
    on_draft = function(text)
      r.body = text
      back()
    end,
    on_cancel = back,
  })
  -- closed any other way with nothing to keep (`:q` on an unchanged body calls none of the
  -- above): back to the confirmation too, so the submit never stays held
  api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(st.win),
    once = true,
    callback = function()
      vim.schedule(back)
    end,
  })
end

-- ---------------------------------------------------------------------------
-- 4. Submit
-- ---------------------------------------------------------------------------

---Publish the review of each PR (`submitPullRequestReview`, or for a verdict alone
---`addPullRequestReview` with the event); its comments become `posted`. Call inside git.async.
function M.submit(r)
  local res = M.result(r)
  local store = r.store
  local done, failed = {}, {}
  local event = forge.EVENTS[r.verdict]
  for _, x in ipairs(res.prs) do
    local t = x.target
    local m = forge.build_submit_mutation({ review_id = t.review_id, pr_id = t.pf.id, commit = t.tip, event = event, body = r.body })
    local data, err, errors = forge.run_graphql(m, host_of(t))
    local rv = data and type(data.s) == 'table' and type(data.s.pullRequestReview) == 'table' and data.s.pullRequestReview
    if rv and type(rv.id) == 'string' then
      done[#done + 1] = t
      local now = comments.now_ms()
      for _, c in pairs(store.comments) do
        if not c.deleted and post.state(c) == 'pending' and c.forge_post.review_id == (t.review_id or rv.id) then
          record(store, c.id, { state = 'posted', posted_at = now, review_url = type(rv.url) == 'string' and rv.url or nil })
        end
      end
    else
      local why = forge.alias_error(errors, 's') or err or 'no review came back'
      failed[#failed + 1] = ('PR #%d: %s'):format(t.pr.number, why)
      log.write('forge', ('PR #%d: submit failed: %s'):format(t.pr.number, why))
    end
  end
  save(store)
  release(r)
  local s = r.s
  if #done > 0 then
    local nums = vim.tbl_map(function(t)
      return '#' .. t.pr.number
    end, done)
    notify(('%s review submitted to %s'):format(post.VERDICT_TEXT[r.verdict], table.concat(nums, ', ')))
  end
  if #failed > 0 then
    notify('submit failed (the pending review stays on GitHub as it is): ' .. table.concat(failed, '; '), vim.log.levels.ERROR)
  end
  if not s.cleaned then
    require('revuey.comments_view').refresh(s)
    -- the posted comments come back as GitHub threads
    require('revuey.forge_view').update(s, true)
  end
  return done, failed
end

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

---`:RevueySubmit [verdict]` / the forge_submit key: prepare, add, confirm, submit.
---@param verdict? string approve|comment|request_changes (asked when nil)
function M.start(s, verdict)
  if not s then
    return notify('no review open', vim.log.levels.WARN)
  end
  if M.job then
    return notify('a review is being submitted already; wait for it to finish', vim.log.levels.WARN)
  end
  if not require('revuey.forge_view').enabled() then
    return notify('the forge is disabled (forge.enabled = false)', vim.log.levels.WARN)
  end
  if verdict == nil then
    return M.pick_verdict(function(v)
      if v then
        M.start(s, v)
      end
    end)
  end
  local v = post.norm_verdict(verdict)
  if not v then
    return notify('unknown verdict ' .. tostring(verdict) .. ' (approve, comment or request-changes)', vim.log.levels.ERROR)
  end
  local r = { s = s }
  M.job = { r = r, phase = 'prepare' }
  notify('preparing the review on GitHub…')
  git.async(function()
    local p, err = M.prepare(s, v)
    if not p then
      release(r)
      return notify(err, vim.log.levels.WARN)
    end
    for k, val in pairs(p) do
      r[k] = val
    end
    M.job.phase = 'add'
    M.add_to_pending(r)
    vim.schedule(function()
      M.confirm(r)
    end)
  end, function(err)
    release(r)
    log.write('forge', 'submit error: ' .. tostring(err))
    notify('submit failed: ' .. tostring(err), vim.log.levels.ERROR)
  end)
end

return M
