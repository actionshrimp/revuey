-- Posting a review to GitHub (UI glue over forge_post.lua and forge.lua). `:RevueySubmit` / the
-- forge_submit key, one submit at a time:
--   1. prepare (reads only): the scope's open PRs (forge_view), each PR's files (REST) and a
--      preflight (GraphQL: the PR's node id, head and author, the viewer's pending review, the
--      PR's latest reviews and every review revuey sent comments to, all read whole);
--      reconcile: what became of every comment revuey sent before (its write-ahead record
--      against those reads); then forge_post.plan routes and checks what is to be added.
--   2. confirm: exactly what each PR's review will publish, what is already pending, what is
--      left out and why, PRs that are blocked; nothing has been sent yet. Cancel: GitHub is
--      untouched.
--   3. execute: per PR, with no pending review of the user's and nothing but line comments, one
--      `addPullRequestReview` with the event and all threads (created and submitted at once);
--      else the pending flow: the user's pending review (or a new one), threads and replies in
--      batches, then `submitPullRequestReview` only when every add was answered. Every mutation
--      is written ahead: the comment's record (`sending`, the exact payload) is saved before the
--      call, so a lost answer or a crash leaves a record the next prepare reconciles.
--
-- A comment's record (`forge_post`) and its states:
--   nil      -> sending   written ahead of the mutation that adds it
--   sending  -> pending   answered, in a pending review (ids recorded)
--   sending  -> posted    answered, in a submitted review (created and submitted at once)
--   sending  -> nil       GitHub refused it (reported), or a later reconcile proves it absent
--   sending  -> unknown   a later reconcile cannot tell (its PR is blocked until it can)
--   unknown  -> pending / posted / nil   a later reconcile decides; or `:RevueySubmit forget`
--   pending  -> posted    its review was submitted (here, or elsewhere)
--   pending  -> nil       its review is gone (NOT_FOUND) or a complete read lacks it
-- Nothing is ever deleted on GitHub.
local api = vim.api
local comments = require('revuey.comments')
local forge = require('revuey.forge')
local post = require('revuey.forge_post')
local git = require('revuey.git')
local log = require('revuey.log')

local M = {}

---The running submit (one at a time per Neovim, whatever review it came from): {r, phase}.
---Two Neovims on one review do not see each other's: see README.
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

local SENT = { sending = true, unknown = true, pending = true }

---Comments added to the review in this scope (not posted yet), and every comment revuey sent
---and has not seen posted (reconciled whatever their toggle says now).
function M.included(store)
  local out = {}
  for _, c in ipairs(comments.list(store, { include_resolved = true, include_drafts = true })) do
    local st = post.state(c)
    if st ~= 'posted' and (c.in_review or SENT[st]) then
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

---Set a comment's record (nil: forget it). `posted` takes it out of the review.
local function set_record(store, id, fp)
  local cur = comments.get(store, id)
  if not cur then
    return nil
  end
  local c = vim.deepcopy(cur)
  c.forge_post = fp
  if fp and fp.state == 'posted' then
    c.in_review = false
  end
  comments.put(store, c)
  return c
end

---Update fields of a comment's record.
local function update_record(store, id, fields)
  local cur = comments.get(store, id)
  local fp = vim.tbl_extend('force', cur and type(cur.forge_post) == 'table' and cur.forge_post or {}, fields)
  return set_record(store, id, fp)
end

local function save(store)
  local ok, err = pcall(comments.save, store)
  if not ok then
    log.write('forge', 'saving posted comments failed: ' .. tostring(err))
  end
end

---Save and make sure it is on disk now (a busy lock defers saves in the UI): write-ahead records
---must be durable before their mutation is sent.
local function durable_save(store)
  local ok, err = pcall(comments.save, store)
  if not ok then
    return false, tostring(err)
  end
  if require('revuey.lock').pending(store.path) then
    return false, 'the comments file is locked by another process'
  end
  return true
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
-- Write-ahead ledger of reviews created and submitted at once
-- ---------------------------------------------------------------------------
-- A comment's write-ahead record lives on the comment; a review made in one step (with a verdict
-- and maybe no comment at all) needs one of its own: `<state>.forge.json` next to the comments
-- file, {reviews = {[id] = {id, pr, repo, commit, event, body, started_at}}}.

function M.ledger_path(store)
  return (store.path:gsub('%.comments%.json$', '')) .. '.forge.json'
end

function M.ledger_read(store)
  local fd = io.open(M.ledger_path(store), 'r')
  if not fd then
    return { reviews = {} }
  end
  local ok, data = pcall(vim.json.decode, fd:read('*a'), { luanil = { object = true, array = true } })
  fd:close()
  if not ok or type(data) ~= 'table' or type(data.reviews) ~= 'table' then
    return { reviews = {} }
  end
  if vim.islist(data.reviews) then
    data.reviews = {}
  end
  return data
end

---Write the ledger (temp file and rename). Returns true, or false and why.
function M.ledger_write(store, data)
  local path = M.ledger_path(store)
  local tmp = ('%s.tmp.%d'):format(path, vim.uv.os_getpid())
  local fd, err = io.open(tmp, 'w')
  if not fd then
    return false, tostring(err)
  end
  fd:write(vim.json.encode({ reviews = next(data.reviews) and data.reviews or vim.empty_dict() }))
  fd:close()
  local ok, rerr = os.rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return false, tostring(rerr)
  end
  return true
end

local function ledger_set(store, id, e)
  local data = M.ledger_read(store)
  data.reviews[id] = e
  return M.ledger_write(store, data)
end

-- ---------------------------------------------------------------------------
-- 1. Prepare (reads only)
-- ---------------------------------------------------------------------------

---Run the preflight for `targets` (one query per host) and read every review it returns whole
---(the pending review, the reviews revuey sent comments to). Sets `t.pf` per target, `r.viewer`
---and `r.reviews` (review id -> review, false when GitHub says it does not exist). A review
---whose comments could not all be read keeps its `cursor` (incomplete). Call inside git.async.
---Returns true, or false and why.
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
    local to_read = {}
    for id, rv in pairs(reviews) do
      r.reviews[id] = rv
      if rv then
        to_read[#to_read + 1] = rv
      end
    end
    for _, t in ipairs(list) do
      if t.pf and t.pf.pending then
        to_read[#to_read + 1] = t.pf.pending
      end
    end
    for _, rv in ipairs(to_read) do
      if rv.cursor then
        local done, perr = forge.fetch_pending_comments(rv, host)
        if not done then
          log.write('forge', ('reading review %s failed: %s'):format(rv.id, tostring(perr)))
        end
      end
    end
  end
  return true
end

---The ids of a GitHub thread's comments (from the fetched threads, plus the one the local reply
---was made on): a reply that answers one of them is in that thread.
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

local function id_set(list)
  local out = {}
  for _, id in ipairs(list or {}) do
    out[id] = true
  end
  return out
end

local function posted_fields(fp, rv, pc)
  local out = vim.deepcopy(fp or {})
  out.state, out.review_id, out.posted_at, out.ledger, out.before = 'posted', rv and rv.id or out.review_id, comments.now_ms(), nil, nil
  out.comment_id = pc and pc.id or nil
  out.database_id = pc and pc.database_id or nil
  out.url = pc and pc.url or nil
  return out
end

---What became of every comment revuey sent before, from the reads of the preflight: its record's
---payload (or recorded id) against the review it went to (forge_post.reconcile; a review made in
---one step: found through the ledger, forge_post.find_atomic). Records found are updated
---(pending, posted), records proven absent are forgotten (and the comment planned again while it
---is still added to the review), anything else makes the record `unknown` and blocks its PR
---(`t.blocked`). A pending review that could not be read whole blocks its PR too. Returns the
---comments to plan and those left out with the reason.
---@return revuey.Comment[] todo, {c:revuey.Comment, why:string}[] left
function M.reconcile(r, included)
  local store = r.store
  local by_pr = {}
  for _, t in ipairs(r.targets) do
    by_pr[t.pr.repo .. '#' .. t.pr.number] = t
    t.already, t.unknown = {}, {}
    if t.pf and t.pf.pending and t.pf.pending.cursor then
      t.blocked = 'your pending review on GitHub could not be read whole'
    end
  end
  local todo, left = {}, {}
  local ledger = M.ledger_read(store)
  local lres, ledger_dirty = {}, false
  r.warnings = r.warnings or {}
  for id, e in pairs(ledger.reviews) do
    local t = by_pr[(e.repo or '') .. '#' .. tostring(e.pr)]
    if t then
      local x = post.find_atomic(e, t.pf)
      lres[id] = x
      if x.unknown then
        t.blocked = t.blocked or ('a review sent earlier got no answer, and ' .. x.unknown)
      else
        if x.found then
          t.found_review = true
          table.insert(r.warnings, ('PR #%d: the %s review sent earlier without an answer was made after all.'):format(t.pr.number, post.VERDICT_TEXT[(e.event or ''):lower()] or e.event))
        end
        ledger.reviews[id] = nil
        ledger_dirty = true
      end
    end
  end
  local entries, owners = {}, {}
  local dirty = false
  local function unknown(c, t, why)
    if post.state(c) ~= 'pending' then
      update_record(store, c.id, { state = 'unknown' })
      dirty = true
    end
    t.blocked = t.blocked or why
    table.insert(t.unknown, c)
  end
  for _, c in ipairs(included) do
    local fp, st = c.forge_post, post.state(c)
    local t = SENT[st] and by_pr[(fp.repo or '') .. '#' .. tostring(fp.pr)] or nil
    if not SENT[st] then
      if c.in_review then
        todo[#todo + 1] = c
      end
    elseif not t then
      left[#left + 1] = { c = c, why = ('revuey sent it to PR #%s, which is not an open PR of this scope'):format(tostring(fp.pr)) }
    elseif st ~= 'pending' and type(fp.payload) ~= 'table' then
      unknown(c, t, 'revuey has no record of what it sent')
    elseif fp.ledger then
      local x = lres[fp.ledger]
      if not x then
        unknown(c, t, 'the record of the review it went with is missing')
      elseif x.found then
        entries[#entries + 1] = { key = c, payload = fp.payload, pool = x.found.comments, complete = x.found.cursor == nil }
        owners[c] = { t = t, review = x.found, atomic = true }
      elseif x.absent then
        set_record(store, c.id, nil)
        dirty = true
        if c.in_review then
          todo[#todo + 1] = comments.get(store, c.id)
        end
      else
        unknown(c, t, 'a review sent earlier got no answer, and ' .. x.unknown)
      end
    else
      local rv
      if t.pf and t.pf.pending and t.pf.pending.id == fp.review_id then
        rv = t.pf.pending
      else
        rv = r.reviews[fp.review_id]
      end
      entries[#entries + 1] = {
        key = c,
        id = st == 'pending' and fp.comment_id or nil,
        payload = fp.payload,
        pool = rv and rv.comments or nil,
        complete = rv and rv.cursor == nil or false,
        gone = rv == false,
        before = id_set(fp.before),
        thread_comments = fp.payload and fp.payload.kind == 'reply' and thread_comments(t, c) or nil,
      }
      owners[c] = { t = t, review = rv }
    end
  end
  local res = post.reconcile(entries)
  for _, e in ipairs(entries) do
    local c, o, x = e.key, owners[e.key], res[e.key]
    local fp = c.forge_post
    if o.atomic then
      -- that review exists, so all its threads do: with ids when told apart
      set_record(store, c.id, posted_fields(fp, o.review, x.found))
      dirty = true
    elseif x.found and o.review.state == 'PENDING' then
      if post.state(c) ~= 'pending' or fp.comment_id ~= x.found.id then
        update_record(store, c.id, { state = 'pending', review_id = o.review.id, comment_id = x.found.id, database_id = x.found.database_id, url = x.found.url })
        dirty = true
      end
      table.insert(o.t.already, { c = comments.get(store, c.id), pc = x.found })
    elseif x.found then
      set_record(store, c.id, posted_fields(fp, o.review, x.found))
      dirty = true
    elseif x.absent then
      set_record(store, c.id, nil)
      dirty = true
      local cur = comments.get(store, c.id)
      if cur and cur.in_review then
        todo[#todo + 1] = cur
      end
    else
      unknown(c, o.t, x.unknown)
    end
  end
  if dirty then
    save(store)
  end
  if ledger_dirty then
    M.ledger_write(store, ledger)
  end
  return todo, left
end

---Read GitHub (files, preflight), reconcile and plan. Sends nothing. Call inside git.async.
---Returns the prepared run, or nil and a message.
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
  local r = { s = s, store = store, verdict = verdict, targets = targets, full = full, warnings = {} }
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
  local review_ids, seen = {}, {}
  for _, c in ipairs(included) do
    local id = SENT[post.state(c)] and c.forge_post.review_id
    if id and not seen[id] then
      seen[id] = true
      review_ids[#review_ids + 1] = id
    end
  end
  local ok, err = M.preflight(r, targets, review_ids)
  if not ok then
    return nil, 'could not read the pull requests from GitHub: ' .. tostring(err)
  end
  local todo, left = M.reconcile(r, included)
  if full and #todo == 0 then
    local any = false
    for _, t in ipairs(targets) do
      any = any or #t.already > 0 or #t.unknown > 0
    end
    if not any then
      return nil, 'nothing added to the review in the full stack (ci adds a comment); submit a verdict alone from a layer\'s scope'
    end
  end
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
  for _, t in ipairs(targets) do
    local items = r.plan.items[t] or {}
    local p = t.pf and t.pf.pending
    if p then
      t.mode = #items > 0 and 'existing' or 'submit'
    else
      local needs_pending = false
      for _, x in ipairs(items) do
        needs_pending = needs_pending or x.item.kind == 'reply' or x.item.subject == 'FILE'
      end
      t.mode = needs_pending and 'new_pending' or 'atomic'
    end
    -- the pending review's comments with the same text as an item: never that item
    for _, x in ipairs(items) do
      local before = {}
      for _, pc in ipairs(p and p.comments or {}) do
        if post.norm_body(pc.body) == post.norm_body(x.item.body) then
          before[#before + 1] = pc.id
        end
      end
      x.before = before
    end
  end
  if s.review.mode == 'worktree' and s.review.dirty then
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
-- 2. Confirm
-- ---------------------------------------------------------------------------

---What each PR's review will publish, and what is left out (for forge_post.summary). Each PR
---entry has `go` when it will be submitted.
function M.result(r)
  local out = { verdict = r.verdict, body = r.body, prs = {}, left_out = {}, warnings = vim.deepcopy(r.warnings or {}) }
  for _, x in ipairs(r.plan.refused) do
    out.left_out[#out.left_out + 1] = x
  end
  for _, t in ipairs(r.targets) do
    for _, x in ipairs(t.failed or {}) do
      out.left_out[#out.left_out + 1] = x
    end
    local p = t.pf and t.pf.pending
    local mine = {}
    local x = { target = t, threads = 0, replies = 0, entries = {}, already = {}, unknown = {}, others = {}, pending_total = 0, mode = t.mode, blocked = t.blocked }
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
        x.already[#x.already + 1] = entry(a.c, ('(in your pending review, edited here since: GitHub has "%s")'):format(#gh > 40 and (gh:sub(1, 39) .. '…') or gh))
      else
        x.already[#x.already + 1] = entry(a.c, '(in your pending review already)')
      end
    end
    for _, it in ipairs(r.plan.items[t] or {}) do
      count(it.c)
      x.entries[#x.entries + 1] = entry(it.c)
    end
    for _, c in ipairs(t.unknown or {}) do
      x.unknown[#x.unknown + 1] = entry(c, '(sent earlier, GitHub did not answer: it may be there)')
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
    local ours = x.threads + x.replies + #x.unknown > 0
    if t.refused then
      -- nothing goes to this PR; say why once (its comments are listed with the reason)
      local listed = false
      for _, e in ipairs(out.left_out) do
        listed = listed or e.why == t.refused
      end
      if (ours or x.pending_total > 0 or not r.full) and not listed then
        table.insert(out.warnings, t.refused)
      end
      if r.full then
        x.nothing = true
        out.prs[#out.prs + 1] = x
      end
    elseif t.found_review and not ours and x.pending_total == 0 then
      -- the review sent earlier without an answer was made: never a second one unasked
      x.nothing = true
      out.prs[#out.prs + 1] = x
    elseif not r.full or ours then
      x.go = not x.blocked
      out.prs[#out.prs + 1] = x
    else
      -- full stack: the verdict goes only where revuey's comments go; every PR is named
      x.nothing = true
      out.prs[#out.prs + 1] = x
      if x.pending_total > 0 then
        table.insert(out.warnings, ('PR #%d: your pending review there (%d comment%s from elsewhere) is not submitted from the full stack; submit it from its layer\'s scope.'):format(
          t.pr.number, x.pending_total, x.pending_total == 1 and '' or 's'))
      end
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
    if x.go and x.threads + x.replies + x.pending_total == 0 then
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

local function confirm(r)
  local s = r.s
  if s.cleaned then
    release(r)
    return notify('the review closed before the confirmation: nothing was sent', vim.log.levels.WARN)
  end
  local res = M.result(r)
  local go = 0
  for _, x in ipairs(res.prs) do
    go = go + (x.go and 1 or 0)
  end
  local text = table.concat(post.summary(res), '\n')
  if go == 0 then
    if #res.prs == 0 or not vim.iter(res.prs):any(function(x)
      return x.blocked ~= nil
    end) then
      release(r)
      local lines = post.summary(res)
      table.remove(lines, 1)
      return notify('nothing to submit.' .. table.concat(lines, '\n'), vim.log.levels.WARN)
    end
    M.ask(text .. '\n\nNothing can be submitted now (nothing has been sent).', '&Cancel', 1)
    release(r)
    return notify('nothing sent')
  end
  local body_label = (r.body and r.body ~= '') and '&Edit body' or '&Write body'
  local nb = needs_body(res)
  if nb then
    text = text .. '\n\nA Comment review with no comments needs a body.'
  end
  local choices = nb and (body_label .. '\n&Cancel') or ('&Submit\n' .. body_label .. '\n&Cancel')
  local default = nb and 1 or ((#res.left_out > 0 or go < #vim.tbl_filter(function(x)
    return not x.nothing
  end, res.prs)) and 3 or 1)
  local choice = M.ask(text, choices, default)
  if nb then
    choice = choice == 1 and 2 or (choice == 2 and 3 or 0)
  end
  if choice == 1 then
    M.job.phase = 'send'
    git.async(function()
      M.execute(r, res)
    end, function(err)
      release(r)
      log.write('forge', 'submit error: ' .. tostring(err))
      notify('submit failed: ' .. tostring(err), vim.log.levels.ERROR)
    end)
  elseif choice == 2 then
    M.write_body(r)
  else
    release(r)
    notify('nothing sent')
  end
end

---The confirmation (on the main loop): Submit, write or edit the body, or cancel. An error here
---releases the submit.
function M.confirm(r)
  local ok, err = pcall(confirm, r)
  if not ok then
    release(r)
    log.write('forge', 'confirmation error: ' .. tostring(err))
    notify('submit stopped: ' .. tostring(err), vim.log.levels.ERROR)
  end
end

local function write_body(r)
  local s = r.s
  if s.cleaned or not (s.diff_win and api.nvim_win_is_valid(s.diff_win)) then
    release(r)
    return notify('nothing sent')
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

---Write or edit the review body in the comment editor, then back to the confirmation. An error
---here releases the submit.
function M.write_body(r)
  local ok, err = pcall(write_body, r)
  if not ok then
    release(r)
    log.write('forge', 'body editor error: ' .. tostring(err))
    notify('submit stopped: ' .. tostring(err), vim.log.levels.ERROR)
  end
end

-- ---------------------------------------------------------------------------
-- 3. Execute (after the confirmation)
-- ---------------------------------------------------------------------------

local function payload_of(item)
  return {
    kind = item.kind, path = item.path, line = item.line, start_line = item.start_line, side = item.side,
    start_side = item.start_side, subject = item.subject, thread_id = item.thread_id, body = item.body,
  }
end

---A review created and submitted in one step: written ahead (the ledger entry and every
---comment's record), then one `addPullRequestReview` with the event and the threads.
---@return string status ok|failed|lost, string? why
local function run_atomic(r, t, items, event)
  local store = r.store
  local lid = comments.new_id()
  local entry_ = { id = lid, pr = t.pr.number, repo = t.pr.repo, commit = t.tip, event = event, body = r.body or '', started_at = os.time() }
  local ok, err = ledger_set(store, lid, entry_)
  if not ok then
    return 'failed', 'could not write the local record first: ' .. tostring(err)
  end
  local now = comments.now_ms()
  for _, x in ipairs(items) do
    set_record(store, x.c.id, { state = 'sending', pr = t.pr.number, repo = t.pr.repo, ledger = lid, payload = payload_of(x.item), sent_at = now })
  end
  local dok, derr = durable_save(store)
  if not dok then
    return 'failed', 'could not save the local records first: ' .. tostring(derr)
  end
  local m = forge.build_atomic_mutation({ pr_id = t.pf.id, commit = t.tip, event = event, body = r.body,
    threads = vim.tbl_map(function(x)
      return x.item
    end, items) })
  local data, gerr, errors = forge.run_graphql(m, host_of(t))
  local rv = data and type(data.s) == 'table' and forge.normalize_review(data.s.pullRequestReview)
  local why = forge.alias_error(errors, 's')
  if rv then
    local entries = {}
    for _, x in ipairs(items) do
      entries[#entries + 1] = { key = x, payload = payload_of(x.item), pool = rv.comments, complete = rv.cursor == nil }
    end
    local res = post.reconcile(entries)
    for _, x in ipairs(items) do
      local cur = comments.get(store, x.c.id)
      if cur then
        set_record(store, x.c.id, posted_fields(cur.forge_post or {}, rv, res[x].found))
      end
    end
    local data_ = M.ledger_read(store)
    data_.reviews[lid] = nil
    M.ledger_write(store, data_)
    save(store)
    return 'ok'
  elseif why then
    -- refused: nothing was made
    for _, x in ipairs(items) do
      set_record(store, x.c.id, nil)
    end
    local data_ = M.ledger_read(store)
    data_.reviews[lid] = nil
    M.ledger_write(store, data_)
    save(store)
    return 'failed', why
  end
  return 'lost', gerr or 'no answer'
end

---The pending flow: the user's pending review (or a new one), the threads and replies in
---batches, each written ahead, then the submit only when every add was answered.
---@return string status ok|failed|lost, string? why
local function run_pending(r, t, items, event)
  local store = r.store
  local review_id = t.pf.pending and t.pf.pending.id or nil
  if not review_id and #items > 0 then
    -- GitHub allows one pending review per user and PR: a lost answer here is found (and
    -- reused) by the next prepare, never made twice
    local data, err, errors = forge.run_graphql(forge.build_pending_mutation(t.pf.id, t.tip), host_of(t))
    local rv = data and type(data.r) == 'table' and type(data.r.pullRequestReview) == 'table' and data.r.pullRequestReview
    if rv and type(rv.id) == 'string' then
      review_id = rv.id
    else
      local why = forge.alias_error(errors, 'r')
      if why then
        return 'failed', 'GitHub refused to start a review: ' .. why
      end
      return 'lost', 'GitHub did not answer when the pending review was started (' .. tostring(err or 'no answer')
        .. '); nothing was added to it. The next submit finds it if it was made'
    end
  end
  local failed, lost = 0, nil
  local added_bodies = {}
  local i = 1
  while i <= #items and not lost do
    local batch, bytes = {}, 0
    while i <= #items and #batch < forge.POST_BATCH do
      local size = #vim.json.encode(items[i].item.body) + 400
      if bytes > 0 and bytes + size > forge.POST_BATCH_BYTES then
        break
      end
      bytes = bytes + size
      batch[#batch + 1] = items[i]
      i = i + 1
    end
    -- written ahead: what is sent, where, and which same-text comments were there before
    local now = comments.now_ms()
    for _, x in ipairs(batch) do
      local before = vim.deepcopy(x.before or {})
      vim.list_extend(before, added_bodies[post.norm_body(x.item.body)] or {})
      set_record(store, x.c.id, { state = 'sending', pr = t.pr.number, repo = t.pr.repo, review_id = review_id, payload = payload_of(x.item), before = before, sent_at = now })
    end
    local dok, derr = durable_save(store)
    if not dok then
      for _, x in ipairs(batch) do
        set_record(store, x.c.id, nil)
      end
      return 'failed', 'could not save the local records first: ' .. tostring(derr)
    end
    local mutation, aliases = forge.build_add_mutation(review_id, vim.tbl_map(function(x)
      return x.item
    end, batch))
    local data, err, errors = forge.run_graphql(mutation, host_of(t))
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
        update_record(store, x.c.id, { state = 'pending', thread_id = gh.thread_id or it.thread_id, comment_id = gh.comment_id, database_id = gh.database_id, url = gh.url })
        local k = post.norm_body(it.body)
        added_bodies[k] = added_bodies[k] or {}
        table.insert(added_bodies[k], gh.comment_id)
      elseif why then
        set_record(store, x.c.id, nil)
        failed = failed + 1
        t.failed = t.failed or {}
        table.insert(t.failed, { c = x.c, why = 'GitHub refused it: ' .. why })
        log.write('forge', ('PR #%d: adding %s failed: %s'):format(t.pr.number, comments.location(x.c), why))
      else
        lost = err or 'no answer' -- stays `sending`: the next prepare reconciles it
      end
    end
    save(store)
  end
  if lost then
    return 'lost', 'GitHub did not answer while adding comments (' .. lost .. '); not submitted. The next submit checks what went in'
  end
  if failed > 0 then
    return 'failed', ('%d comment%s refused by GitHub; not submitted (what went in stays in your pending review)'):format(failed, failed == 1 and ' was' or 's were')
  end
  local m = forge.build_submit_mutation({ review_id = review_id, pr_id = t.pf.id, commit = t.tip, event = event, body = r.body })
  local data, err, errors = forge.run_graphql(m, host_of(t))
  local rv = data and type(data.s) == 'table' and type(data.s.pullRequestReview) == 'table' and data.s.pullRequestReview
  if not (rv and type(rv.id) == 'string') then
    local why = forge.alias_error(errors, 's')
    return why and 'failed' or 'lost', why or ('no answer to the submit (' .. tostring(err) .. '); the next submit checks it')
  end
  local now = comments.now_ms()
  for _, c in pairs(store.comments) do
    if not c.deleted and post.state(c) == 'pending' and c.forge_post.review_id == rv.id then
      update_record(store, c.id, { state = 'posted', posted_at = now, review_url = type(rv.url) == 'string' and rv.url or nil })
    end
  end
  save(store)
  return 'ok'
end

---Send what the confirmation showed, PR by PR (`res`: M.result). Call inside git.async.
function M.execute(r, res)
  local event = forge.EVENTS[r.verdict]
  local done, bad = {}, {}
  for _, x in ipairs(res.prs) do
    if x.go then
      local t = x.target
      local items = r.plan.items[t] or {}
      local status, why
      if t.mode == 'atomic' then
        status, why = run_atomic(r, t, items, event)
      else
        status, why = run_pending(r, t, items, event)
      end
      if status == 'ok' then
        done[#done + 1] = '#' .. t.pr.number
      else
        bad[#bad + 1] = ('PR #%d: %s'):format(t.pr.number, why or status)
        log.write('forge', bad[#bad])
      end
    end
  end
  release(r)
  if #done > 0 then
    notify(('%s review submitted to %s'):format(post.VERDICT_TEXT[r.verdict], table.concat(done, ', ')))
  end
  if #bad > 0 then
    notify('not submitted: ' .. table.concat(bad, '; '), vim.log.levels.ERROR)
  end
  local s = r.s
  if not s.cleaned then
    require('revuey.comments_view').refresh(s)
    -- the posted comments come back as GitHub threads
    require('revuey.forge_view').update(s, true)
  end
  return done, bad
end

-- ---------------------------------------------------------------------------
-- Entry points
-- ---------------------------------------------------------------------------

---`:RevueySubmit forget`: drop revuey's record of the comment on this line when GitHub never
---answered for it (`sending`, `unknown`), so its PR is no longer blocked. It may exist on
---GitHub: a later submit can post it a second time.
function M.forget(s)
  if not s then
    return notify('no review open', vim.log.levels.WARN)
  end
  if M.job then
    return notify('a review is being submitted; wait for it to finish', vim.log.levels.WARN)
  end
  require('revuey.comments_view').with_comment(s, function(c)
    local st = post.state(c)
    if c.forge then
      return notify('this is a GitHub thread, not a comment revuey sent')
    elseif st ~= 'sending' and st ~= 'unknown' then
      return notify(st == 'pending' and 'this comment is in your pending review on GitHub; delete it there' or 'revuey has no unanswered record of this comment')
    end
    local store = require('revuey.comments_view').sync_store(s)
    set_record(store, c.id, nil)
    save(store)
    notify(('forgot revuey\'s record of %s: it may exist on GitHub (check PR #%s); a later submit may post it again'):format(
      comments.location(c), tostring(c.forge_post.pr)), vim.log.levels.WARN)
    require('revuey.comments_view').refresh(s)
  end, nil, true)
end

---`:RevueySubmit [verdict]` / the forge_submit key: prepare (reads), confirm, then send.
---@param verdict? string approve|comment|request_changes (asked when nil), or `forget`
function M.start(s, verdict)
  if verdict == 'forget' then
    return M.forget(s)
  end
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
    return notify('unknown verdict ' .. tostring(verdict) .. ' (approve, comment or request-changes; or forget)', vim.log.levels.ERROR)
  end
  local r = { s = s }
  M.job = { r = r, phase = 'prepare' }
  notify('reading the pull request on GitHub…')
  git.async(function()
    local p, err = M.prepare(s, v)
    if not p then
      release(r)
      return notify(err, vim.log.levels.WARN)
    end
    for k, val in pairs(p) do
      r[k] = val
    end
    M.job.phase = 'confirm'
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
