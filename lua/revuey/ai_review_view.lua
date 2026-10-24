-- AI review glue: runs `:RevueyAIReview [skill]` in the background (one job per review scope, like
-- the guide's), imports the result as AI-authored comments (ai_review.lua), and draws the review's
-- block in the file panel (verdict, findings left to triage, summary). The findings themselves are
-- ordinary comments, drawn and triaged by comments_view.lua.
local api = vim.api
local config = require('revuey.config')
local ai = require('revuey.ai')
local ai_review = require('revuey.ai_review')
local prompt = require('revuey.ai_review_prompt')
local comments = require('revuey.comments')
local git = require('revuey.git')

local M = {}

M.ns_status = api.nvim_create_namespace('revuey.ai_review.status')

---Jobs by comments file (one per review scope); they outlive scope switches and the review.
---@type table<string, {job?: revuey.AiJob, label: string, started: integer, progress?: string, skill?: string}>
M.jobs = {}
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

---"✗ request changes · claude" for a record.
function M.verdict_line(rec)
  local who = rec.author and rec.author.name or 'AI'
  return ('AI review: %s %s · %s'):format(ai_review.VERDICT_GLYPH[rec.verdict] or '●', ai_review.VERDICT_LABEL[rec.verdict] or rec.verdict, who)
end

function M.job(s)
  return M.jobs[M.key(s)]
end

---Status line for a running review: spinner, elapsed time, latest progress.
function M.status_text(s)
  local j = M.job(s)
  if not j then
    return nil
  end
  local secs = math.floor((vim.uv.hrtime() - j.started) / 1e9)
  local frame = SPINNER[(math.floor(vim.uv.hrtime() / 1e8) % #SPINNER) + 1]
  return ('%s reviewing %ds%s'):format(frame, secs, j.progress and ('  ' .. j.progress) or '')
end

local ticker

local function tick()
  local s = require('revuey.view').session
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

local function ensure_ticker()
  if not ticker then
    ticker = vim.uv.new_timer()
    ticker:start(0, 100, vim.schedule_wrap(tick))
  end
end

---Untouched findings of the last review revuey ran here (what a new run replaces).
function M.replaceable(s)
  local store = require('revuey.comments_view').sync_store(s)
  local n = 0
  for _, c in pairs(store.comments) do
    if ai_review.untouched(c, M.author()) then
      n = n + 1
    end
  end
  return n
end

---Run an AI review of the session's current review scope (no-op when one runs for it). `skill`:
---a skill name or path whose SKILL.md is passed as guidance.
---@param s revuey.Session
---@param skill_arg? string
---@param on_change fun() called (on the main loop) when the job state or the findings changed
function M.generate(s, skill_arg, on_change)
  local r = s.review
  local key = M.key(s)
  if M.jobs[key] then
    return vim.notify('revuey: an AI review is already running for this review (:RevueyAIReview cancel stops it)', vim.log.levels.INFO)
  end
  -- the guide's hunks: the same ids, and in full-stack scope the branch labels for the prompt
  local hunks = require('revuey.guide_view').prepare(s).hunks
  if #hunks == 0 then
    return vim.notify('revuey: nothing to review (no changes)', vim.log.levels.INFO)
  end
  local skill
  if skill_arg and skill_arg ~= '' then
    local path, err = ai_review.find_skill(skill_arg, r.root)
    if path then
      skill, err = ai_review.read_skill(path)
    end
    if not skill then
      return vim.notify('revuey: ' .. err, vim.log.levels.ERROR)
    end
  end
  local cfg = config.options.ai or {}
  local author = M.author()
  M.errors[key] = nil
  local entry = { label = r.branch, started = vim.uv.hrtime(), skill = skill and skill.name }
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
    entry.job = ai.run({
      prompt = text,
      schema = prompt.schema_json(),
      cwd = r.root,
      model = cfg.model,
      effort = cfg.effort,
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
          generator = {
            provider = cfg.provider or 'claude',
            model = result.model or cfg.model,
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

---Cancel the run for the session's review scope.
function M.cancel(s)
  local key = M.key(s)
  local j = M.jobs[key]
  if not j then
    return false
  end
  if j.job and j.job.proc then
    j.job:cancel()
  else
    -- still gathering commits: forget it; the coroutine checks before spawning
    M.jobs[key] = nil
    vim.notify('revuey: AI review cancelled', vim.log.levels.INFO)
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
  local job, err, rec = M.jobs[key], M.errors[key], M.record(s)
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
    if rec.summary ~= '' then
      for _, l in ipairs(require('revuey.panel').wrap(rec.summary:gsub('%s+', ' '), width, ' ')) do
        add(l, { { 0, #l, 'Comment' } })
      end
    end
  end
  add('')
end

return M
