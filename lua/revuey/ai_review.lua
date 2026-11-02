-- AI reviews: the pure model (no window/buffer UI, no processes), shared by the UI
-- (ai_review_view.lua) and `bin/revuey import-review`.
--
--   * validation of a review document (summary, verdict, findings anchored to hunk ids plus
--     line numbers within the hunk), against the hunks it was made for (instructed, not trusted):
--     findings with bad anchors are dropped and counted;
--   * import: each finding becomes an AI-authored local comment (comments.lua) whose anchor is
--     exactly what a selection of the same diff rows would store, so it re-anchors like any
--     comment. Untouched findings of the previous run by the same reviewer and skill are
--     replaced; findings the user already triaged are not imported again;
--   * triage: accept (the comment becomes the user's own), dismiss / restore; the same for a
--     coding agent's comments (`bin/revuey comment`), which are drafts for the user too;
--   * the scope's runs (each run's summary, verdict, counts, generator) next to the comments
--     file, and the findings grouped by run (the agent reviews view, `bin/revuey findings`);
--   * skills: a SKILL.md read by revuey and passed to the model as guidance.
-- Prompt text and schema live in ai_review_prompt.lua; the CLI call in ai.lua.
local guide = require('revuey.guide')
local comments = require('revuey.comments')
local prompt = require('revuey.ai_review_prompt')

local M = {}

M.VERSION = 1
M.MAX_FINDINGS = 50 -- kept after validation (the schema asks for at most 30)

M.VERDICT_LABEL = { approve = 'approve', comment = 'comment', request_changes = 'request changes' }
M.VERDICT_GLYPH = { approve = '✓', comment = '●', request_changes = '✗' }

local SEVERITY = {}
for _, v in ipairs(prompt.SEVERITIES) do
  SEVERITY[v] = true
end
-- words models (and other tools) use for the same levels
local SEVERITY_ALIAS = {
  blocker = 'critical', high = 'major', medium = 'minor', low = 'nit', info = 'nit', style = 'nit',
  error = 'major', warning = 'minor', suggestion = 'nit',
}

---"approve", "Request changes", "REQUEST_CHANGES", "changes_requested" -> the schema's value;
---unknown -> 'comment' and false.
---@return string verdict, boolean known
function M.norm_verdict(v)
  if type(v) ~= 'string' then
    return 'comment', false
  end
  local k = vim.trim(v):lower():gsub('[%s%-]+', '_')
  if k == 'approve' or k == 'approved' or k == 'lgtm' then
    return 'approve', true
  elseif k == 'request_changes' or k == 'changes_requested' or k == 'reject' then
    return 'request_changes', true
  elseif k == 'comment' or k == 'commented' then
    return 'comment', true
  end
  return 'comment', false
end

---@return string severity, boolean known
function M.norm_severity(v)
  if type(v) ~= 'string' then
    return 'minor', false
  end
  local k = vim.trim(v):lower()
  if SEVERITY[k] then
    return k, true
  end
  if SEVERITY_ALIAS[k] then
    return SEVERITY_ALIAS[k], true
  end
  return 'minor', false
end

---A suggested change: newlines and indentation kept, other control characters and trailing
---newlines dropped. nil when empty.
function M.clean_code(v)
  if type(v) ~= 'string' then
    return nil
  end
  local t = v:gsub('\r\n', '\n'):gsub('[%z\1-\8\11-\31\127]', ''):gsub('\n+$', '')
  return t:find('%S') and t or nil
end

---@class revuey.AiFinding
---@field hunk string          h1..hn
---@field line? integer        1-based line of the hunk (nil: the whole file)
---@field end_line? integer
---@field severity string
---@field title string
---@field body string
---@field suggestion? string

---Hold a review document to the schema, against the hunks it was made for. Anything that is not
---a review (no summary or verdict, findings that are not a list, a top-level array, prose around
---some other JSON object) is an error, so it can never replace the last review. Findings whose
---anchor is bad (unknown hunk id, a line the hunk does not have or the prompt did not show, an
---end before the start) are dropped and counted; a finding without a line (or on a file without a
---text diff, or when the prompt showed no hunk bodies) is about the whole file. Exact duplicates
---are dropped, and findings past MAX_FINDINGS.
---`shown`: what the prompt showed (prompt.build's info): `level` ('full'|'abridged'|'files') and
---`abridged` (set of hunk ids shown as a preview of PREVIEW_LINES lines). nil: every line.
---@param raw table|string decoded output, or text to repair
---@param hunks revuey.GuideHunk[]
---@param shown? {level?: string, abridged?: table<string, boolean>}
---@return {summary:string, verdict:string, findings:revuey.AiFinding[], diff?:string}? doc
---@return string|table err_or_warnings error message, or on success {dropped, unknown_hunk, bad_line, empty, duplicates, extra, verdict_unknown?}
function M.validate(raw, hunks, shown)
  if type(raw) == 'string' then
    raw = guide.repair_json(raw)
    if not raw then
      return nil, 'the review is not valid JSON'
    end
  end
  if type(raw) ~= 'table' or (vim.islist(raw) and #raw > 0) then
    return nil, 'the review is not a JSON object'
  end
  if type(raw.findings) ~= 'table' or not (vim.islist(raw.findings) or next(raw.findings) == nil) then
    return nil, raw.findings == nil and 'the review has no findings array (use [] for none)' or 'findings must be an array'
  end
  if type(raw.summary) ~= 'string' then
    return nil, 'the review has no summary'
  end
  if type(raw.verdict) ~= 'string' then
    return nil, 'the review has no verdict'
  end
  local by_id = {}
  for _, h in ipairs(hunks) do
    by_id[h.id] = h
  end
  local w = { dropped = 0, unknown_hunk = 0, bad_line = 0, empty = 0, duplicates = 0, extra = 0 }
  local findings, seen = {}, {}
  for _, f in ipairs(raw.findings) do
    local reason
    local out
    if type(f) ~= 'table' then
      reason = 'empty'
    else
      local id = guide.norm_id(f.hunk or f.id)
      local h = id and by_id[id]
      local title = guide.one_line(f.title)
      local body = guide.clean_text(f.body)
      if not h then
        reason = 'unknown_hunk'
      elseif title == '' and body == '' then
        reason = 'empty'
      else
        -- no lines: the whole file; a comment spans at most MAX_RANGE lines (as one from the shell)
        local line, last
        line, last, reason = guide.hunk_range(h, f.line, f.end_line, shown, comments.MAX_RANGE)
        if not reason then
          local severity = M.norm_severity(f.severity)
          if title == '' then
            title = guide.one_line(comments.first_line(body))
          end
          out = {
            hunk = id,
            line = line,
            end_line = line and last or nil,
            severity = severity,
            title = title,
            body = body,
            suggestion = line and M.clean_code(f.suggestion) or nil,
          }
        end
      end
    end
    if out then
      local key = table.concat({ out.hunk, tostring(out.line), tostring(out.end_line), out.title:lower() }, '\0')
      if seen[key] then
        reason, out = 'duplicates', nil
      else
        seen[key] = true
      end
    end
    if out and #findings >= M.MAX_FINDINGS then
      reason, out = 'extra', nil
    end
    if out then
      findings[#findings + 1] = out
    else
      w[reason] = w[reason] + 1
      w.dropped = w.dropped + 1
    end
  end
  local verdict, known = M.norm_verdict(raw.verdict)
  if raw.verdict ~= nil and not known then
    w.verdict_unknown = true
  end
  return {
    summary = guide.clean_text(raw.summary),
    verdict = verdict,
    findings = findings,
    diff = type(raw.diff) == 'string' and vim.trim(raw.diff) or nil,
  }, w
end

---"2 dropped (1 unknown hunk, 1 line outside its hunk)" for warnings with drops, else nil.
M.dropped_text = guide.dropped_text

-- ---------------------------------------------------------------------------
-- Findings as comments
-- ---------------------------------------------------------------------------

local function fence_for(text)
  local longest = 2
  for run in text:gmatch('`+') do
    longest = math.max(longest, #run)
  end
  return string.rep('`', longest + 1)
end

---Comment body of a finding: the title in bold, the explanation, the suggested change.
---@param f revuey.AiFinding
function M.body(f)
  local out = { '**' .. f.title .. '**' }
  if f.body ~= '' and f.body ~= f.title then
    out[#out + 1] = ''
    out[#out + 1] = f.body
  end
  if f.suggestion then
    local fence = fence_for(f.suggestion)
    vim.list_extend(out, { '', 'Suggested change:', '', fence, f.suggestion, fence })
  end
  return table.concat(out, '\n')
end

---Anchor of a finding: the rows `line..end_line` of its hunk, exactly as a selection of those
---rows in the UI would anchor them (side, unit, hunk offsets, hashes, snippet); a whole-file
---anchor without a line.
---@param files revuey.FileDiff[]
---@param U revuey.Units
---@param h revuey.GuideHunk
---@param f revuey.AiFinding
---@param get_line fun(path:string, side:string, lnum:integer):string?
---@return revuey.CommentAnchor?
function M.anchor(files, U, h, f, get_line)
  if not h.hunk_idx or not f.line then
    return comments.file_anchor(h.path)
  end
  local hk = files[h.file_idx] and files[h.file_idx].hunks[h.hunk_idx]
  if not hk then
    return nil
  end
  local entries = {}
  for li = f.line, f.end_line or f.line do
    local l = hk.lines[li]
    if not l then
      return nil
    end
    entries[#entries + 1] = { kind = l.kind, file_idx = h.file_idx, hunk_idx = h.hunk_idx, line_idx = li }
  end
  return comments.anchor_from_rows(files, U, entries, get_line)
end

---Is `c` an untriaged AI finding (shown for accept or dismiss)?
function M.untriaged(c)
  return c ~= nil and not c.deleted and c.ai ~= nil and c.author and c.author.kind == 'ai' and c.status == 'saved'
end

---Which run made something, as the finding keeps it (`ai.run`): {name?, provider?, model?,
---agent?, skill?, request?}, from the reviewer (`author`) and the import's generator.
function M.run_of(author, generator)
  local gen = generator or {}
  return {
    name = author and author.name or nil,
    provider = gen.provider,
    model = gen.model,
    agent = gen.agent,
    skill = gen.skill,
    request = gen.request,
  }
end

---The reviewer identity of a run, for replacing: the connected agent by its name (provider
---`agent`), any other reviewer (a fresh run, an import without a request) by its name, and the
---skill it ran with. So the agent and a fresh run never replace each other's findings, whatever
---the agent is called, and runs with different skills stay side by side.
function M.run_key(run)
  run = run or {}
  local skill = '\0' .. tostring(run.skill or '')
  if run.provider == 'agent' then
    return 'agent\0' .. tostring(run.agent or run.name or '') .. skill
  end
  return 'name\0' .. tostring(run.name or '') .. skill
end

---The run of finding `c` (findings imported before `ai.run` existed: their author's name).
function M.finding_run(c)
  if type(c.ai) == 'table' and type(c.ai.run) == 'table' then
    return c.ai.run
  end
  local a = type(c.ai) == 'table' and type(c.ai.author) == 'table' and c.ai.author or c.author
  return { name = a and a.name or nil }
end
local finding_run = M.finding_run

---Untouched by the user: untriaged, no reply, never sent to an agent, no unsaved edit, no tag
---set or removed since it was made. A new review by the same reviewer (`who`: a run, M.run_of;
---compared with M.run_key) replaces these.
function M.untouched(c, who)
  if not M.untriaged(c) or M.run_key(finding_run(c)) ~= M.run_key(who) then
    return false
  end
  if c.sent_at or c.draft or c.reply_draft or require('revuey.tags').touched(c) then
    return false
  end
  for _, r in ipairs(c.thread or {}) do
    if not r.deleted then
      return false
    end
  end
  return true
end

---Identity of a finding where it sits (path, side, lines, title), to recognise one the user
---triaged when a later review finds it again.
local function finding_key(anchor, title)
  return table.concat({
    anchor.path or '',
    anchor.start_line and (anchor.side or 'new') or 'file',
    tostring(anchor.start_line or ''),
    tostring(anchor.end_line or ''),
    (title or ''):lower(),
  }, '\0')
end

---Untriaged AI findings of a store, sorted like comments.
function M.pending(store)
  local out = {}
  for _, c in pairs(store.comments) do
    if M.untriaged(c) then
      out[#out + 1] = c
    end
  end
  return comments.sort(out)
end

---@class revuey.AiImport
---@field review revuey.Review    the review the hunks were taken from (anchors use its texts)
---@field hunks revuey.GuideHunk[] its hunks (guide.hunks: the ids the document uses)
---@field store revuey.CommentStore
---@field events string           events file
---@field info table              review info (comments.review_info)
---@field author {kind:'ai', name?:string}
---@field generator? table        provider, model, session_id, skill, agent, request, duration_ms...
---@field record_path string
---@field shown? {level?: string, abridged?: table<string, boolean>} what the prompt showed (validate)
---@field tags? string[]          tags every new finding gets (cleaned: tags.clean_list)
---@field started_at? integer     when the run started (ms; default: now - generator.duration_ms)
---@field now? integer

---Import a review document: validate it, replace the author's untouched findings of the last
---review, add a comment per finding (findings the user already triaged are skipped), save the
---comments and the review record, append the events. A `diff` hash in the document must match
---the hunks (`bin/revuey hunks` printed it for them). Errors on a failed save.
---@param raw table|string
---@param o revuey.AiImport
---@return table? record {id, summary, verdict, imported, dropped, skipped, replaced, warnings, ...}
---@return string? err
function M.import(raw, o)
  local doc, w = M.validate(raw, o.hunks, o.shown)
  if not doc then
    return nil, w --[[@as string]]
  end
  local anchors = guide.anchors_hash(o.hunks)
  if doc.diff and doc.diff ~= anchors then
    return nil, ('the review was made for another diff (%s; this review is %s): the code changed since. Run `revuey hunks` again and review that'):format(doc.diff, anchors)
  end
  local r = o.review
  local review_mod = require('revuey.review')
  local U = review_mod.units(r)
  local cache = {}
  local ctx = comments.context(r.files, U, function(path, side)
    local fi = U.by_path[path]
    return fi and review_mod.side_text(r, r.files[fi], side, cache) or nil
  end)
  local by_id = {}
  for _, h in ipairs(o.hunks) do
    by_id[h.id] = h
  end
  local now = o.now or comments.now_ms()
  local store = o.store
  -- what is untouched is decided on the file as it is now: another instance (or the CLI) may
  -- have accepted, dismissed or answered a finding since this store was loaded
  pcall(comments.reload, store)
  local id = comments.new_id(now)
  -- which run makes these findings (kept on each, and on the run's record), and whose
  -- untouched findings it replaces
  local run = M.run_of(o.author, o.generator)
  local replaced, triaged = {}, {}
  for cid, c in pairs(store.comments) do
    if M.untouched(c, run) then
      replaced[#replaced + 1] = cid
    elseif c.ai and not c.deleted then
      triaged[finding_key(c.anchor, c.ai.title)] = true
    elseif c.deleted and type(c.ai) == 'table' and type(c.ai.anchor) == 'table' then
      -- deleted by the user (comments.delete keeps where it was): not imported again
      triaged[finding_key(c.ai.anchor, c.ai.title)] = true
    end
  end
  table.sort(replaced)
  local created, skipped = {}, 0
  for _, f in ipairs(doc.findings) do
    local h = by_id[f.hunk]
    local a = M.anchor(r.files, U, h, f, ctx.get_line)
    if not a then
      w.bad_line, w.dropped = w.bad_line + 1, w.dropped + 1
    elseif triaged[finding_key(a, f.title)] then
      skipped = skipped + 1
    else
      local c = comments.new(a, M.body(f), { author = vim.deepcopy(o.author), now = now })
      c.ai = {
        review = id,
        severity = f.severity,
        title = f.title,
        suggestion = f.suggestion,
        hunk = f.hunk,
        line = f.line,
        end_line = f.end_line,
        run = vim.deepcopy(run),
      }
      if o.tags and #o.tags > 0 then
        c = require('revuey.tags').apply(c, o.tags, true, now) or c
      end
      comments.put(store, c, now)
      created[#created + 1] = c
    end
  end
  local gone = {}
  for _, cid in ipairs(replaced) do
    -- a tombstone just newer than the version seen: any change made meanwhile elsewhere (an
    -- accept, a dismiss, a reply) is newer still and wins the merge, and the finding stays
    local prev = store.comments[cid]
    store.comments[cid] = { id = cid, deleted = true, deleted_at = now, updated_at = (prev.updated_at or 0) + 1 }
    store._dirty[cid] = true
    gone[#gone + 1] = prev
  end
  comments.save(store, o.info)
  -- only what the merge really deleted: a tombstone that lost to a change made elsewhere
  -- meanwhile (an accept, a reply) was not a replacement
  local n_replaced = 0
  for _, c in ipairs(gone) do
    local cur = store.comments[c.id]
    if cur and cur.deleted then
      n_replaced = n_replaced + 1
      comments.append_event(o.events, comments.event('deleted', c, o.info, nil, now))
    end
  end
  for _, c in ipairs(created) do
    comments.append_event(o.events, comments.event('created', comments.get(store, c.id) or c, o.info, nil, now))
  end
  local gen = vim.tbl_extend('keep', o.generator or {}, { generated_at = math.floor(now / 1000) })
  local rec = {
    kind = 'revuey-ai-review',
    version = M.VERSION,
    id = id,
    author = o.author,
    run = run,
    started_at = o.started_at or (tonumber(gen.duration_ms) and (now - math.floor(gen.duration_ms))) or nil,
    finished_at = now,
    summary = doc.summary,
    verdict = doc.verdict,
    findings = #doc.findings,
    imported = #created,
    dropped = w.dropped,
    skipped = skipped,
    replaced = n_replaced,
    warnings = w,
    anchors = anchors,
    review = o.info,
    tags = o.tags and #o.tags > 0 and o.tags or nil,
    generator = gen,
  }
  -- the findings are saved: a record that cannot be written is reported, never undoes them
  local ok, serr = pcall(M.add_run, o.record_path, rec, M.live_runs(store))
  if not ok then
    rec.record_error = tostring(serr)
  end
  return rec
end

-- ---------------------------------------------------------------------------
-- Triage
-- ---------------------------------------------------------------------------

---Is `c` a coding agent's own comment (`bin/revuey comment`, author `agent`), not yet triaged:
---a draft for the user to accept (it becomes theirs) or dismiss. Never an AI finding (those have
---`ai`), and never counted with them (`untriaged`, `pending`, re-runs replace only those).
function M.agent_untriaged(c)
  return c ~= nil and not c.deleted and c.ai == nil and c.author ~= nil and c.author.kind == 'agent' and c.status == 'saved'
end

---What `ca`/`cn` act on: 'ai' (an AI finding), 'agent' (an agent's comment, untriaged, dismissed
---or accepted: `agent` records it), or nil. Agent replies are thread entries, not comments, so
---they are never here.
function M.origin(c)
  if not c or c.deleted then
    return nil
  end
  if c.ai then
    return 'ai'
  end
  if type(c.agent) == 'table' or (c.author and c.author.kind == 'agent') then
    return 'agent'
  end
end

---Was `c` accepted from an AI review or an agent (it is the user's comment since)? 'ai',
---'agent' or nil.
function M.accepted_from(c)
  if c and c.ai and c.ai.accepted_at then
    return 'ai'
  elseif c and type(c.agent) == 'table' and c.agent.accepted_at then
    return 'agent'
  end
end

---Can `c` be accepted (`ca`)? true, or false and why. The rule M.accept applies (the key hint
---asks it too).
---@return boolean ok, string? why
function M.can_accept(c)
  if not M.origin(c) then
    return false, 'not an AI finding or an agent\'s comment'
  end
  if c.status == 'accepted' then
    return false, 'already accepted'
  elseif c.status == 'resolved' then
    return false, 'resolved: reopen it first (cx)'
  elseif c.status == 'draft' then
    return false, 'save the draft first'
  end
  return true
end

---Can `c` be dismissed or restored (`cn`)? true, or false and why (M.toggle_dismiss's rule).
---@return boolean ok, string? why
function M.can_dismiss(c)
  if not M.origin(c) then
    return false, 'not an AI finding or an agent\'s comment'
  end
  if c.status == 'accepted' then
    return false, 'already accepted: it is your comment now (resolve or delete it instead)'
  elseif c.status == 'resolved' then
    return false, 'resolved: reopen it first (cx)'
  elseif c.status ~= 'saved' and c.status ~= 'dismissed' then
    return false, 'not a finding to dismiss (' .. tostring(c.status) .. ')'
  end
  return true
end

---Accept a finding or an agent's comment: it becomes the user's own comment (status
---`accepted`; the original author is kept in `ai.author` / `agent.author`). Returns the updated
---comment, or nil and a message.
function M.accept(store, id, now)
  local cur = comments.get(store, id)
  local ok, why = M.can_accept(cur)
  if not ok then
    return nil, why
  end
  local origin = M.origin(cur)
  now = now or comments.now_ms()
  local c = vim.deepcopy(cur)
  local rec = origin == 'ai' and c.ai or (type(c.agent) == 'table' and c.agent or {})
  rec.author = rec.author or c.author
  rec.accepted_at = now
  rec.dismissed_at = nil
  if origin == 'agent' then
    c.agent = rec
  end
  c.author = { kind = 'user' }
  c.status = 'accepted'
  return comments.put(store, c, now)
end

---Dismiss a finding or an agent's comment (kept, hidden like a resolved comment), or restore a
---dismissed one.
function M.toggle_dismiss(store, id, now)
  local cur = comments.get(store, id)
  local ok, why = M.can_dismiss(cur)
  if not ok then
    return nil, why
  end
  local origin = M.origin(cur)
  now = now or comments.now_ms()
  local c = vim.deepcopy(cur)
  local rec
  if origin == 'ai' then
    rec = c.ai
  else
    c.agent = type(c.agent) == 'table' and c.agent or { author = c.author }
    rec = c.agent
  end
  if c.status == 'dismissed' then
    c.status = 'saved'
    rec.dismissed_at = nil
  else
    c.status = 'dismissed'
    rec.dismissed_at = now
  end
  return comments.put(store, c, now)
end

-- ---------------------------------------------------------------------------
-- Review runs: <state file>.ai-review.json, next to the comments file. Every run of the scope
-- (fresh sessions, the connected agent, imports), oldest first, each with its summary, verdict
-- and counts; its findings point at it (`ai.review` = the run's id). Version 1 held one record
-- (the latest review): it is read as a list of that one run.
-- ---------------------------------------------------------------------------

M.RUNS_KIND = 'revuey-ai-reviews'
M.RUNS_VERSION = 2
M.MAX_RUNS = 30

function M.record_path(comments_path)
  return (comments_path:gsub('%.comments%.json$', '')) .. '.ai-review.json'
end

---Write a JSON value atomically (temp file + rename). Errors on failure.
function M.save_record(path, rec)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local tmp = ('%s.tmp.%d.%d'):format(path, vim.uv.os_getpid(), math.random(0, 0xffffff))
  local fd, err = io.open(tmp, 'w')
  if not fd then
    error('revuey: cannot write the AI review: ' .. tostring(err))
  end
  local ok, werr = fd:write(vim.json.encode(rec))
  local cok, cerr = fd:close()
  if not ok or not cok then
    os.remove(tmp)
    error('revuey: cannot write the AI review: ' .. tostring(werr or cerr))
  end
  local rok, rerr = os.rename(tmp, path)
  if not rok then
    os.remove(tmp)
    error('revuey: cannot write the AI review: ' .. tostring(rerr))
  end
end

---One run record, sanitised (nil when it is not one).
local function clean_run(rec)
  if type(rec) ~= 'table' or type(rec.id) ~= 'string' then
    return nil
  end
  rec.summary = guide.clean_text(rec.summary)
  rec.verdict = M.norm_verdict(rec.verdict)
  rec.generator = type(rec.generator) == 'table' and rec.generator or {}
  rec.author = type(rec.author) == 'table' and rec.author or { kind = 'ai' }
  for _, k in ipairs({ 'findings', 'imported', 'dropped', 'skipped', 'replaced' }) do
    rec[k] = tonumber(rec[k]) or 0
  end
  if type(rec.run) ~= 'table' then
    -- a version 1 record: its run from its author and generator
    rec.run = M.run_of(rec.author, rec.generator)
  end
  rec.finished_at = tonumber(rec.finished_at) or ((tonumber(rec.generator.generated_at) or 0) * 1000)
  rec.started_at = tonumber(rec.started_at)
  rec.tags = type(rec.tags) == 'table' and require('revuey.tags').clean_list(rec.tags) or nil
  return rec
end

---The runs stored at `path`, oldest first ({} without any). A version 1 file is one run, marked
---`migrated` (findings without `ai.run` belong to it).
---@return table[] runs
function M.read_runs(path)
  local fd = io.open(path, 'r')
  if not fd then
    return {}
  end
  local text = fd:read('*a')
  fd:close()
  local ok, data = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok or type(data) ~= 'table' then
    return {}
  end
  local list = {}
  if data.kind == 'revuey-ai-review' then
    local rec = clean_run(data)
    if rec then
      rec.migrated = true
      list[1] = rec
    end
  elseif data.kind == M.RUNS_KIND and type(data.runs) == 'table' then
    for _, r in ipairs(data.runs) do
      local rec = clean_run(r)
      if rec then
        list[#list + 1] = rec
      end
    end
  end
  table.sort(list, function(a, b)
    if a.finished_at ~= b.finished_at then
      return a.finished_at < b.finished_at
    end
    return a.id < b.id
  end)
  return list
end

---The latest run at `path`, or nil.
function M.read_record(path)
  local list = M.read_runs(path)
  return list[#list]
end

---The run ids live comments of `store` point at (`ai.review`), and whether any live finding has
---no `ai.run` (from before runs: it belongs to a migrated record).
---@return table<string, true> ids
function M.live_runs(store)
  local ids = {}
  for _, c in pairs(store.comments) do
    if not c.deleted and type(c.ai) == 'table' then
      if c.ai.review then
        ids[c.ai.review] = true
      end
      if type(c.ai.run) ~= 'table' then
        ids['\0legacy'] = true
      end
    end
  end
  return ids
end

---Keep what is worth keeping: a run is dropped when a later run of the same identity (run_key)
---exists and no live finding points at it any more (its findings were all replaced or deleted);
---then the oldest past MAX_RUNS.
function M.prune_runs(list, live)
  local latest = {}
  for i, r in ipairs(list) do
    latest[M.run_key(r.run)] = i
  end
  local out = {}
  for i, r in ipairs(list) do
    local used = live[r.id] or (r.migrated and live['\0legacy'])
    if used or latest[M.run_key(r.run)] == i then
      out[#out + 1] = r
    end
  end
  while #out > M.MAX_RUNS do
    table.remove(out, 1)
  end
  return out
end

local queued = {} ---@type table<string, fun(list: table[]): table[]>[] changes waiting for a busy lock

---Change the runs at `path` under its lock: `fn(list)` returns the new list. In the UI a busy
---lock queues the change for a retry (every queued change is applied, in order).
local function change_runs(path, fn)
  local lock = require('revuey.lock')
  queued[path] = queued[path] or {}
  table.insert(queued[path], fn)
  return lock.save(path, function()
    return lock.with(path, function()
      local list = M.read_runs(path)
      local fns = queued[path] or {}
      queued[path] = nil
      for _, f in ipairs(fns) do
        list = f(list)
      end
      for _, r in ipairs(list) do
        r.migrated = nil
      end
      M.save_record(path, { kind = M.RUNS_KIND, version = M.RUNS_VERSION, runs = list })
    end)
  end)
end

---Add run `rec` to the scope's runs (replacing one with its id) and prune (`live`: M.live_runs).
---Errors on a failed write (the UI defers it on a busy lock).
function M.add_run(path, rec, live)
  return change_runs(path, function(list)
    local out = {}
    for _, r in ipairs(list) do
      if r.id ~= rec.id then
        out[#out + 1] = r
      end
    end
    out[#out + 1] = vim.deepcopy(rec)
    return M.prune_runs(out, live or {})
  end)
end

---Remove run `id` from the scope's runs.
function M.remove_run(path, id)
  return change_runs(path, function(list)
    return vim.tbl_filter(function(r)
      return r.id ~= id
    end, list)
  end)
end

-- ---------------------------------------------------------------------------
-- Findings by run: the agent reviews view and `bin/revuey findings`
-- ---------------------------------------------------------------------------

---Where a finding or agent comment stands: 'untriaged', 'accepted' (also accepted and resolved
---since), 'dismissed', 'resolved' (resolved before it was triaged).
function M.triage_status(c)
  if c.status == 'dismissed' then
    return 'dismissed'
  elseif M.accepted_from(c) or c.status == 'accepted' then
    return 'accepted'
  elseif c.status == 'resolved' then
    return 'resolved'
  end
  return 'untriaged'
end

M.STATUSES = { 'untriaged', 'accepted', 'dismissed', 'resolved' }

---Who ran a run, for people: "claude (connected)" for the connected agent, "claude · opus" for a
---fresh session with its model, an import's reviewer name.
function M.run_who(run)
  run = run or {}
  local clean = require('revuey.requests').clean_name
  if run.provider == 'agent' then
    return (clean(run.agent or run.name) or 'agent') .. ' (connected)'
  end
  local name = clean(run.name) or clean(run.provider) or 'AI'
  if run.model and run.model ~= '' then
    return name .. ' · ' .. guide.one_line(run.model)
  end
  return name
end

---The groups of findings by run, newest run first: {id, run (the record, or one made from the
---findings), record?, findings, counts}. Findings whose run record is gone are grouped by their
---`ai.review` under a record made from their `ai.run`; findings from before runs go to the
---migrated record when there is one; a coding agent's comments are a group per agent.
---@param runs table[] M.read_runs
---@param list table[] live comments
function M.groups(runs, list)
  local by_id, order = {}, {}
  local migrated
  for _, r in ipairs(runs) do
    by_id[r.id] = { id = r.id, record = r, run = r.run, findings = {}, at = r.finished_at or 0 }
    if r.migrated then
      migrated = by_id[r.id]
    end
  end
  for _, c in ipairs(list) do
    local origin = M.origin(c)
    local g
    if origin == 'ai' then
      local rid = c.ai.review
      g = rid and by_id[rid]
      if not g and type(c.ai.run) ~= 'table' and migrated then
        g = migrated
      end
      if not g then
        local key = rid or ('\0' .. M.run_key(finding_run(c)))
        g = by_id[key]
        if not g then
          g = { id = key, run = finding_run(c), findings = {}, at = 0, orphan = true }
          by_id[key] = g
        end
      end
    elseif origin == 'agent' then
      local a = (type(c.agent) == 'table' and c.agent.author) or c.author or {}
      local key = 'agent:' .. tostring(a.name or 'agent')
      g = by_id[key]
      if not g then
        g = { id = key, run = { name = a.name or 'agent', provider = 'comments' }, findings = {}, at = 0, comments = true }
        by_id[key] = g
      end
    end
    if g then
      g.findings[#g.findings + 1] = c
      g.at = math.max(g.at, c.created_at or 0)
    end
  end
  for _, g in pairs(by_id) do
    if g.record or #g.findings > 0 then
      g.counts = { untriaged = 0, accepted = 0, dismissed = 0, resolved = 0 }
      for _, c in ipairs(g.findings) do
        local st = M.triage_status(c)
        g.counts[st] = g.counts[st] + 1
      end
      order[#order + 1] = g
    end
  end
  table.sort(order, function(a, b)
    if (a.comments or false) ~= (b.comments or false) then
      return not a.comments -- the agent's comments after the reviews
    end
    if a.at ~= b.at then
      return a.at > b.at
    end
    return a.id < b.id
  end)
  return order
end

-- ---------------------------------------------------------------------------
-- Skills: `:RevueyAIReview <skill>` reads its SKILL.md and passes it to the model as guidance
-- (the restricted run loads no skills itself).
-- ---------------------------------------------------------------------------

---Directories holding skills, most trusted first: the user's, then the repo's.
function M.skill_dirs(root, home)
  home = home or vim.env.HOME
  local out = {}
  if home and home ~= '' then
    out[#out + 1] = vim.fs.joinpath(home, '.claude', 'skills')
  end
  if root then
    out[#out + 1] = vim.fs.joinpath(root, '.claude', 'skills')
  end
  return out
end

---Does `arg` name a skill by path (find_skill takes it literally) rather than by name?
function M.is_skill_path(arg)
  arg = vim.trim(arg or '')
  return arg:find('/', 1, true) ~= nil or arg:match('%.md$') ~= nil or arg:sub(1, 1) == '~'
end

---The SKILL.md for `arg`: a skill name (looked up in skill_dirs), or a path to a skill
---directory or a Markdown file (relative to `root`).
---@return string? path, string? err
function M.find_skill(arg, root, home)
  arg = vim.trim(arg or '')
  if arg == '' then
    return nil, 'no skill given'
  end
  if M.is_skill_path(arg) then
    -- taken literally: only a leading ~ means the home directory (no %, # or wildcards)
    local p = arg
    if arg == '~' or arg:sub(1, 2) == '~/' then
      p = (home or vim.env.HOME or '~') .. arg:sub(2)
    end
    if p:sub(1, 1) ~= '/' and root then
      p = vim.fs.joinpath(root, p)
    end
    local st = vim.uv.fs_stat(p)
    if st and st.type == 'directory' then
      p = vim.fs.joinpath(p, 'SKILL.md')
      st = vim.uv.fs_stat(p)
    end
    if st and st.type == 'file' then
      return p
    end
    return nil, 'no skill at ' .. arg .. ' (a directory with a SKILL.md, or a Markdown file)'
  end
  local looked = {}
  for _, d in ipairs(M.skill_dirs(root, home)) do
    local p = vim.fs.joinpath(d, arg, 'SKILL.md')
    if vim.uv.fs_stat(p) then
      return p
    end
    looked[#looked + 1] = vim.fn.fnamemodify(d, ':~')
  end
  return nil, ('no skill %s (looked for %s/SKILL.md in %s)'):format(arg, arg, table.concat(looked, ', '))
end

local function real(p)
  return p and (vim.uv.fs_realpath(p) or vim.fs.normalize(p)) or nil
end

local function under(p, dir)
  return p ~= nil and dir ~= nil and (p == dir or p:sub(1, #dir + 1) == dir .. '/')
end

---Where a skill file comes from: 'user' (`~/.claude/skills/<name>/SKILL.md`), 'repo' (the
---repo's `.claude/skills/<name>/SKILL.md`: content of the code under review) or 'path' (a path
---the user gave); and whether the file is inside the worktree `root` (repo content either way).
---@return 'user'|'repo'|'path' origin, boolean in_repo
function M.skill_origin(path, root, home)
  local p = real(path)
  local dirs = M.skill_dirs(root, home)
  home = home or vim.env.HOME
  local in_repo = root ~= nil and under(p, real(root))
  for _, d in ipairs(dirs) do
    local rd = real(d)
    if under(p, rd) and vim.fs.basename(p) == 'SKILL.md' and real(vim.fs.dirname(vim.fs.dirname(p))) == rd then
      local is_user = home and home ~= '' and rd == real(vim.fs.joinpath(home, '.claude', 'skills'))
      return is_user and not in_repo and 'user' or 'repo', in_repo
    end
  end
  return 'path', in_repo
end

---The changed files (repo-relative `paths`) that are the skill itself: its directory for a
---SKILL.md (it may read files next to it), else the file. Empty when it is outside `root`.
function M.skill_touched(skill_path, root, paths)
  local p, r = real(skill_path), real(root)
  local out = {}
  if not (p and r and under(p, r)) then
    return out
  end
  local rel = p:sub(#r + 2)
  local dir = vim.fs.basename(rel) == 'SKILL.md' and vim.fs.dirname(rel) or nil
  local seen = {}
  for _, q in ipairs(paths) do
    if not seen[q] and (q == rel or (dir and dir ~= '.' and under(q, dir))) then
      seen[q] = true
      out[#out + 1] = q
    end
  end
  table.sort(out)
  return out
end

---Skill names in skill_dirs (for completion), sorted and unique.
function M.skill_names(root, home)
  local names, seen = {}, {}
  for _, d in ipairs(M.skill_dirs(root, home)) do
    if vim.uv.fs_stat(d) then
      for name in vim.fs.dir(d) do
        if not seen[name] and vim.uv.fs_stat(vim.fs.joinpath(d, name, 'SKILL.md')) then
          seen[name] = true
          names[#names + 1] = name
        end
      end
    end
  end
  table.sort(names)
  return names
end

---Read a skill file: its name (the directory's, or the file's without .md) and its text without
---the YAML front matter. Refuses empty and oversized files.
---@return {name:string, text:string, path:string}? skill, string? err
function M.read_skill(path)
  local st = vim.uv.fs_stat(path)
  -- the cap is on the text without front matter; anything far over it is not read at all
  if st and st.size > prompt.SKILL_MAX_CHARS + 4096 then
    return nil, ('%s is too large (%d bytes, at most %d characters)'):format(path, st.size, prompt.SKILL_MAX_CHARS)
  end
  local fd = io.open(path, 'r')
  if not fd then
    return nil, 'cannot read ' .. path
  end
  local text = fd:read('*a') or ''
  fd:close()
  text = text:gsub('\r\n', '\n')
  text = text:gsub('^%-%-%-\n.-\n%-%-%-\n', '', 1)
  text = vim.trim(text)
  if text == '' then
    return nil, path .. ' is empty'
  end
  if #text > prompt.SKILL_MAX_CHARS then
    return nil, ('%s is too large (%d characters, at most %d)'):format(path, #text, prompt.SKILL_MAX_CHARS)
  end
  local base = vim.fs.basename(path)
  local name = base == 'SKILL.md' and vim.fs.basename(vim.fs.dirname(path)) or base:gsub('%.md$', '')
  return { name = name, text = text, path = path, hash = vim.fn.sha256(text) }
end

return M
