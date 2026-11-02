-- AI review glue: runs `:RevueyAIReview [skill]` in the background (one job per review scope, like
-- the guide's), imports the result as AI-authored comments (ai_review.lua), and draws the review's
-- block in the file panel (verdict, findings left to triage, summary). The findings themselves are
-- ordinary comments, drawn and triaged by comments_view.lua. The review can also be asked of the
-- connected agent (a `review` request, agent_request.lua): the job then waits for its
-- `import-review --request`.
local api = vim.api
local config = require('revuey.config')
local ai = require('revuey.ai')
local ai_review = require('revuey.ai_review')
local prompt = require('revuey.ai_review_prompt')
local comments = require('revuey.comments')
local git = require('revuey.git')
local agent_request = require('revuey.agent_request')

local M = {}

M.ns_status = api.nvim_create_namespace('revuey.ai_review.status')

---Jobs by comments file (one per review scope); they outlive scope switches and the review. A
---request to the connected agent has `agent` {id, path, name, delivered?, acked?, late?,
---adopted?} instead of `job`.
---@type table<string, {job?: revuey.AiJob, agent?: table, label: string, started: integer, progress?: string, skill?: string}>
M.jobs = {}
---A request no watch printed within this long is shown as not picked up (a fresh run offered).
M.AGENT_ACK_MS = 60000
---How often the review reads an open request's file while it waits.
M.AGENT_POLL_MS = 500
---Withdrawing a request: retried on a busy lock for this long, in these steps.
M.CANCEL_RETRY_MS = 3000
M.CANCEL_STEP_MS = 50
---How a review redraws when a request ends that no command of this Neovim started (adopted);
---view.lua sets it.
M.default_on_change = function() end
---What the shared request code (agent_request.lua) says about a review request.
M.req = {
  noun = 'review',
  imported = 'the review',
  cancel_cmd = ':RevueyAIReview cancel',
  expired_hint = 'run :RevueyAIReview again for a fresh session',
  refused = function(a, rec)
    local sk = rec.skill and (rec.skill.arg or rec.skill.name)
    return ('revuey: %s could not take the request: %s; run :RevueyAIReview%s again'):format(
      a.name, require('revuey.guide').one_line(rec.reason or '?'), sk and (' ' .. require('revuey.guide').one_line(sk)) or '')
  end,
  fresh_hint = function()
    return ':RevueyAIReview'
  end,
  ready = function(a, rec, secs)
    local res = rec.result or {}
    local n = tonumber(res.findings) or 0
    return ('revuey: AI review ready from %s (%s, %d finding%s, %ds)'):format(a.name,
      ai_review.VERDICT_LABEL[res.verdict] or tostring(res.verdict or '?'), n, n == 1 and '' or 's', secs)
  end,
}
---Last error per comments file (shown in the panel until the next run).
M.errors = {}

local SPINNER = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }

---The comments file of the session's scope: the key of its job, record and findings.
function M.key(s)
  return comments.path_for(s.review.state._path)
end

---The author of reviews revuey runs itself.
function M.author()
  return { kind = 'ai', name = (config.options.ai or {}).provider or 'claude' }
end

---The scope's latest review record (cached while the file is unchanged), or nil.
function M.record(s)
  local path = ai_review.record_path(M.key(s))
  local st = vim.uv.fs_stat(path)
  local c = s.ai_review_cache
  if not st then
    s.ai_review_cache = nil
    return nil
  end
  local sig = st.mtime.sec .. '.' .. st.mtime.nsec .. ':' .. st.size
  if not (c and c.path == path and c.sig == sig) then
    c = { path = path, sig = sig, rec = ai_review.read_record(path) }
    s.ai_review_cache = c
  end
  return c.rec
end

---Who wrote a review record: "claude (connected)" for the connected agent, else its author.
function M.who(rec)
  local gen = rec.generator or {}
  if gen.provider == 'agent' then
    return (require('revuey.requests').clean_name(gen.agent) or 'agent') .. ' (connected)'
  end
  return rec.author and rec.author.name or 'AI'
end

---"✗ request changes · claude" for a record.
function M.verdict_line(rec)
  return ('AI review: %s %s · %s'):format(ai_review.VERDICT_GLYPH[rec.verdict] or '●', ai_review.VERDICT_LABEL[rec.verdict] or rec.verdict, M.who(rec))
end

local ensure_ticker

---An open review request for this scope whose review is gone (Neovim quit or crashed while
---waiting) is waited for again, once per review and scope (agent_request.adopt).
local function adopt(s, key)
  if s.ai_review_adopt_checked == key then
    return
  end
  s.ai_review_adopt_checked = key
  if M.jobs[key] then
    return
  end
  local j = agent_request.adopt(s, 'review', function(rec)
    return rec.comments == key
  end, s.review.branch, function()
    M.default_on_change()
  end)
  if j then
    M.jobs[key] = j
    ensure_ticker()
  end
end

function M.job(s)
  local key = M.key(s)
  adopt(s, key)
  return M.jobs[key]
end

---Status line for a running review: spinner, elapsed time, latest progress.
function M.status_text(s)
  local j = M.job(s)
  if not j then
    return nil
  end
  local secs = math.floor((vim.uv.hrtime() - j.started) / 1e9)
  local frame = SPINNER[(math.floor(vim.uv.hrtime() / 1e8) % #SPINNER) + 1]
  if j.agent then
    return agent_request.status_text(j, frame, 'is reviewing', M.req.fresh_hint())
  end
  return ('%s reviewing %ds%s'):format(frame, secs, j.progress and ('  ' .. j.progress) or '')
end

local ticker

local function tick()
  local s = require('revuey.view').session
  agent_request.poll(M)
  if next(M.jobs) == nil then
    if ticker then
      ticker:stop()
      ticker:close()
      ticker = nil
    end
    return
  end
  if s and not s.cleaned then
    M.draw_status(s)
  end
end

---Draw the live status (spinner) into the panel without re-rendering it.
function M.draw_status(s)
  local buf, row = s.panel_buf, s.panel_ai_status_row
  if not buf or not row or not api.nvim_buf_is_valid(buf) or row > api.nvim_buf_line_count(buf) then
    return
  end
  api.nvim_buf_clear_namespace(buf, M.ns_status, row - 1, row)
  local text = M.status_text(s)
  if text then
    api.nvim_buf_set_extmark(buf, M.ns_status, row - 1, 0, { virt_text = { { ' ' .. text, 'RevueyGuideSpinner' } }, virt_text_pos = 'overlay' })
  end
end

ensure_ticker = function()
  if not ticker then
    ticker = vim.uv.new_timer()
    ticker:start(0, 100, vim.schedule_wrap(tick))
  end
end

---The run identity (ai_review.run_of) a new review imports under: a fresh run's, or with
---`agent` (a name) the connected agent's, as `import-review --request` records it when the
---agent imports with the `--name` its prompt gives (the request's agent).
function M.run_for(agent)
  if agent then
    return ai_review.run_of({ kind = 'ai', name = agent }, { provider = 'agent', agent = agent })
  end
  return ai_review.run_of(M.author(), { provider = (config.options.ai or {}).provider or 'claude' })
end

---Untouched findings the new run would replace (the import's own predicate, ai_review.untouched):
---`who` is its run (M.run_for; default a fresh run).
function M.replaceable(s, who)
  local store = require('revuey.comments_view').sync_store(s)
  local n = 0
  for _, c in pairs(store.comments) do
    if ai_review.untouched(c, who or M.run_for()) then
      n = n + 1
    end
  end
  return n
end

---The skill `skill_arg` names (a name or a path), read: {name, text, path, hash, origin,
---in_repo, arg} (ai_review.skill_origin); nil without one; false and an error when it cannot be
---found or read.
function M.resolve_skill(s, skill_arg)
  if not skill_arg or skill_arg == '' then
    return nil
  end
  local path, err = ai_review.find_skill(skill_arg, s.review.root)
  local skill
  if path then
    skill, err = ai_review.read_skill(path)
  end
  if not skill then
    return false, err
  end
  skill.origin, skill.in_repo = ai_review.skill_origin(path, s.review.root)
  skill.arg = skill_arg
  return skill
end

---The review's changed files that are the skill itself (ai_review.skill_touched).
function M.skill_touched(s, skill)
  local paths = {}
  for _, f in ipairs(s.review.files) do
    paths[#paths + 1] = f.path
    if f.old_path then
      paths[#paths + 1] = f.old_path
    end
  end
  return ai_review.skill_touched(skill.path, s.review.root, paths)
end

---The scope's hunks when a review can start (none running, some changes), else nil (said).
local function startable(s, key)
  if M.jobs[key] then
    local j = M.jobs[key]
    vim.notify(j.agent and ('revuey: %s was asked for this review already (:RevueyAIReview cancel withdraws it)'):format(j.agent.name)
      or 'revuey: an AI review is already running for this review (:RevueyAIReview cancel stops it)', vim.log.levels.INFO)
    return nil
  end
  -- the guide's hunks: the same ids, and in full-stack scope the branch labels for the prompt
  local g = require('revuey.guide_view').prepare(s)
  if #g.hunks == 0 then
    vim.notify('revuey: nothing to review (no changes)', vim.log.levels.INFO)
    return nil
  end
  return g
end

---Ask the connected agent to review the session's current scope into revuey: a `review` request
---(with the skill's name and path, when given) and its event in the feed (`watch --messages`
---prints it). The job waits for `import-review --request` (agent_request.poll).
---@return boolean asked
function M.request_agent(s, skill_arg, on_change)
  local key = M.key(s)
  local g = startable(s, key)
  if not g then
    return false
  end
  local skill, serr = M.resolve_skill(s, skill_arg)
  if skill == false then
    vim.notify('revuey: ' .. serr, vim.log.levels.ERROR)
    return false
  end
  local rec, name, path = agent_request.create(s, 'review', {
    key = require('revuey.guide').key(s.review.state),
    anchors = g.anchors,
    comments = key,
    -- where it comes from and a hash of its text: the CLI reads it again and checks both
    skill = skill and { name = skill.name, path = skill.path, origin = skill.origin, in_repo = skill.in_repo or nil, arg = skill.arg, hash = skill.hash } or nil,
  })
  if not rec then
    vim.notify('revuey: ' .. name, vim.log.levels.ERROR)
    return false
  end
  M.errors[key] = nil
  local j = agent_request.job(rec, path, name, s.review.branch, on_change)
  j.skill = skill and skill.name
  j.skill_arg = skill and skill.path
  M.jobs[key] = j
  ensure_ticker()
  on_change()
  vim.notify(('revuey: asked %s to review this%s (request %s)'):format(name, skill and (' with the skill ' .. skill.name) or '', rec.id), vim.log.levels.INFO)
  local touched = skill and M.skill_touched(s, skill) or {}
  if #touched > 0 then
    vim.notify(('revuey: this change modifies the skill %s itself (%s): its guidance comes from the code under review'):format(skill.name, table.concat(touched, ', ')), vim.log.levels.WARN)
  end
  return true
end

---Run an AI review of the session's current review scope (no-op when one runs for it). `skill`:
---a skill name or path whose SKILL.md is passed as guidance. `opts`: model and effort for this
---run (default: ai.model, ai.effort).
---@param s revuey.Session
---@param skill_arg? string
---@param on_change fun() called (on the main loop) when the job state or the findings changed
---@param opts? {model?: string, effort?: string}
function M.generate(s, skill_arg, on_change, opts)
  local r = s.review
  local key = M.key(s)
  local g = startable(s, key)
  if not g then
    return
  end
  local hunks = g.hunks
  local skill, serr = M.resolve_skill(s, skill_arg)
  if skill == false then
    return vim.notify('revuey: ' .. serr, vim.log.levels.ERROR)
  end
  opts = opts or {}
  local cfg = config.options.ai or {}
  local author = M.author()
  M.errors[key] = nil
  local entry = { label = r.branch, started = vim.uv.hrtime(), skill = skill and skill.name, on_change = on_change }
  M.jobs[key] = entry
  ensure_ticker()
  on_change()
  local function fail(err)
    M.errors[key] = err ~= 'cancelled' and err or nil
    vim.notify('revuey: AI review ' .. (err == 'cancelled' and 'cancelled' or ('failed: ' .. err)), err == 'cancelled' and vim.log.levels.INFO or vim.log.levels.ERROR)
    on_change()
  end
  git.async(function()
    local text, info = prompt.build(require('revuey.guide_view').prompt_context(r), hunks, { budget = cfg.max_prompt_chars, skill = skill })
    if M.jobs[key] ~= entry then
      return -- cancelled while gathering
    end
    if not text then
      M.jobs[key] = nil
      return fail(info --[[@as string]])
    end
    entry.prompt_level = info.level
    -- validation only accepts lines the prompt showed
    entry.shown = { level = info.level, abridged = info.abridged_ids }
    entry.job = ai.run({
      prompt = text,
      schema = prompt.schema_json(),
      cwd = r.root,
      model = opts.model or cfg.model,
      effort = opts.effort or cfg.effort,
      name = 'revuey review: ' .. r.branch,
      on_event = function(ev)
        if ev.type == 'progress' then
          entry.progress = ev.text
        end
      end,
      on_done = function(err, result)
        if M.jobs[key] ~= entry then
          return
        end
        M.jobs[key] = nil
        if err then
          return fail(err)
        end
        -- the findings go to this scope's comments, wherever the user is now: into the open
        -- review's store when it shows this scope, else straight to the file (its watcher reloads)
        local cur = require('revuey.view').session
        local store = cur and not cur.cleaned and cur.cm and cur.cm.path == key and cur.cm.store or comments.load(key)
        local ok, rec, ierr = pcall(ai_review.import, result.output or result.text or '', {
          review = r,
          hunks = hunks,
          store = store,
          events = comments.events_path_for(r.state._path),
          info = comments.review_info(r),
          author = author,
          record_path = ai_review.record_path(key),
          shown = entry.shown,
          generator = {
            provider = cfg.provider or 'claude',
            model = result.model or opts.model or cfg.model,
            session_id = result.session_id,
            head = r.head,
            merge_base = r.merge_base,
            mode = r.mode,
            duration_ms = result.duration_ms,
            cost_usd = result.cost_usd,
            prompt_level = entry.prompt_level,
            skill = skill and skill.name,
          },
        })
        if not ok or not rec then
          return fail(tostring(ok and ierr or rec))
        end
        local secs = math.floor((vim.uv.hrtime() - entry.started) / 1e9 + 0.5)
        local extra = {}
        local dropped = ai_review.dropped_text(rec.warnings)
        if dropped then
          extra[#extra + 1] = dropped
        end
        if rec.skipped > 0 then
          extra[#extra + 1] = rec.skipped .. ' already triaged'
        end
        if rec.record_error then
          extra[#extra + 1] = 'the review record was not saved: ' .. rec.record_error
        end
        vim.notify(('revuey: AI review ready (%s, %d finding%s%s, %ds)'):format(
          ai_review.VERDICT_LABEL[rec.verdict],
          rec.imported,
          rec.imported == 1 and '' or 's',
          #extra > 0 and ('; ' .. table.concat(extra, '; ')) or '',
          secs
        ), vim.log.levels.INFO)
        on_change()
      end,
    })
  end, function(e)
    M.jobs[key] = nil
    vim.schedule(function()
      fail(tostring(e))
    end)
  end)
end

---Cancel the run for the session's review scope, or withdraw the request to the agent
---(`after(ok)`: called once the withdrawal is done or failed).
function M.cancel(s, after)
  local key = M.key(s)
  local j = M.job(s)
  if not j then
    return false
  end
  if j.agent then
    if not j.agent.cancelling then
      agent_request.cancel(s, M, key, j, after)
    end
  elseif j.job and j.job.proc then
    j.job:cancel()
  else
    -- still gathering commits: forget it; the coroutine checks before spawning
    M.jobs[key] = nil
    vim.notify('revuey: AI review cancelled', vim.log.levels.INFO)
    if j.on_change then
      j.on_change() -- the panel drops the spinner
    end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Panel
-- ---------------------------------------------------------------------------

local VERDICT_HL = { approve = 'RevueyAiApprove', comment = 'RevueyAiComment', request_changes = 'RevueyAiChanges' }

---The AI review block of the file panel: heading with the verdict, a live status while it
---runs, the last error, findings left to triage, and the summary. Nothing without a review.
function M.panel(s, add, add_virt, width)
  s.panel_ai_status_row = nil
  local key = M.key(s)
  local job, err, rec = M.job(s), M.errors[key], M.record(s)
  if not (job or err or rec) then
    return
  end
  local title = ' AI review'
  local row = add(title, { { 0, #title, 'RevueyPanelTitle' } })
  if rec then
    local v = (ai_review.VERDICT_GLYPH[rec.verdict] or '●') .. ' ' .. (ai_review.VERDICT_LABEL[rec.verdict] or rec.verdict)
    add_virt(row, { { v, VERDICT_HL[rec.verdict] or 'Comment' } })
  end
  if job then
    s.panel_ai_status_row = add('')
  end
  if err then
    local t = require('revuey.panel').truncate(' ! failed: ' .. err:gsub('\n.*', ''), width)
    add(t, { { 0, #t, 'RevueyGuideBanner' } })
  end
  if rec then
    local pending = #ai_review.pending(require('revuey.comments_view').sync_store(s))
    local parts = { pending > 0 and (pending .. ' to triage') or 'all triaged' }
    if rec.dropped > 0 then
      parts[#parts + 1] = rec.dropped .. ' dropped'
    end
    if rec.skipped > 0 then
      parts[#parts + 1] = rec.skipped .. ' already triaged'
    end
    local t = ' ' .. table.concat(parts, ' · ')
    add(t, { { 0, #t, pending > 0 and 'Normal' or 'Comment' } })
    if (rec.generator or {}).provider == 'agent' then
      local by = require('revuey.panel').truncate(' by ' .. M.who(rec) .. (type(rec.generator.skill) == 'string' and (' · skill ' .. require('revuey.guide').one_line(rec.generator.skill)) or ''), width)
      add(by, { { 0, #by, 'Comment' } })
    end
    if rec.summary ~= '' then
      for _, l in ipairs(require('revuey.panel').wrap(rec.summary:gsub('%s+', ' '), width, ' ')) do
        add(l, { { 0, #l, 'Comment' } })
      end
    end
  end
  add('')
end

return M
