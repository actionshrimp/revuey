-- Guide view glue: turns a resolved guide into a document for layout.compose_guide, runs and
-- tracks generation jobs (one per review key, in the background), and draws the guide's part of
-- the file panel. The diff buffer, keymaps and rendering stay in view.lua (one renderer, two hosts).
local api = vim.api
local config = require('revuey.config')
local guide = require('revuey.guide')
local prompt = require('revuey.guide_prompt')
local prose = require('revuey.prose')
local diagram = require('revuey.diagram')
local ai = require('revuey.ai')
local git = require('revuey.git')
local state_mod = require('revuey.state')

local M = {}

M.ns_status = api.nvim_create_namespace('revuey.guide.status')

---Jobs by review key string; they outlive scope switches (each scope has its own guide).
---@type table<string, {job: revuey.AiJob, label: string, progress?: string}>
M.jobs = {}
---Last error per review key (shown in the guide view until the next attempt).
M.errors = {}

local SPINNER = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }

local function key_str(key)
  return table.concat({ key.repo, key.branch, key.base }, '\0')
end

local function state_dir(s)
  return s.opts.state_dir or config.options.state_dir or state_mod.default_dir()
end

---Current hunks, guide record and its resolution for the session's review (cached per diff).
function M.prepare(s, force)
  local r = s.review
  local key = guide.key(r.state)
  local ks = key_str(key)
  local g = s.guide
  if not force and g and g.review == r and not g.reload then
    return g
  end
  local hunks, anchors
  if g and g.review == r then
    hunks, anchors = g.hunks, g.anchors
  else
    hunks = guide.hunks(r.files)
    anchors = guide.anchors_hash(hunks)
    -- full-stack reviews: the layers that introduced each hunk (labels and prompt tags)
    local labels = r.layer_labels
    if labels then
      for _, h in ipairs(hunks) do
        h.layers = labels[h.file_idx] and labels[h.file_idx][h.hunk_idx or 0] or nil
      end
    end
  end
  local rec
  if not force and g and g.ks == ks and g.anchors == anchors and not g.reload then
    rec = g.record
  else
    rec = guide.load(guide.dir(state_dir(s)), key, anchors)
  end
  s.guide = {
    review = r,
    key = key,
    ks = ks,
    hunks = hunks,
    anchors = anchors,
    record = rec,
    resolved = rec and guide.resolve(rec, hunks) or nil,
  }
  return s.guide
end

function M.job(s)
  local g = s.guide or M.prepare(s)
  return M.jobs[g.ks]
end

---Reviewed count over sections that can be reviewed (those showing hunks).
function M.progress(s)
  local g = s.guide
  local res = g and g.resolved
  if not res then
    return 0, 0
  end
  local done, total = 0, 0
  for _, sec in ipairs(res.sections) do
    if sec.id then
      total = total + 1
      if state_mod.section_reviewed(s.review.state, sec.id) then
        done = done + 1
      end
    end
  end
  return done, total
end

function M.section_reviewed(s, sec)
  return sec.id ~= nil and state_mod.section_reviewed(s.review.state, sec.id)
end

local function ago(t)
  local d = os.time() - (tonumber(t) or os.time())
  if d < 90 then
    return 'just now'
  elseif d < 3600 then
    return math.floor(d / 60 + 0.5) .. ' min ago'
  elseif d < 86400 * 2 then
    return math.floor(d / 3600 + 0.5) .. ' h ago'
  end
  return os.date('%Y-%m-%d', t)
end

---Status line for a running job: spinner, elapsed time, latest progress.
function M.status_text(s)
  local j = M.job(s)
  if not j then
    return nil
  end
  local secs = math.floor((vim.uv.hrtime() - j.started) / 1e9)
  local frame = SPINNER[(math.floor(vim.uv.hrtime() / 1e8) % #SPINNER) + 1]
  return ('%s generating %ds%s'):format(frame, secs, j.progress and ('  ' .. j.progress) or '')
end

-- ---------------------------------------------------------------------------
-- Document
-- ---------------------------------------------------------------------------

---Prose rows carry an anchor (block, paragraph, byte offset into the paragraph, prefix bytes) so a
---re-wrap can put the cursor back on the same text.
local function add_prose(doc, md, width, role, si, base_hl, block)
  block = block or (role .. ':' .. (si or 0))
  for _, l in ipairs(prose.render(md, width, { base_hl = base_hl })) do
    doc[#doc + 1] = {
      kind = 'prose', text = l.text, hls = l.hls, role = role, section_idx = si,
      block = block, para = l.para, off = l.off, pre = l.pre,
    }
  end
end

local function line(doc, text, hl, role, si)
  doc[#doc + 1] = { kind = 'prose', text = text, hls = hl and #text > 0 and { { 0, #text, hl } } or nil, role = role, section_idx = si }
end

local function plural(n, word)
  return n .. ' ' .. word .. (n == 1 and '' or 's')
end

local function placeholder(s, doc, width)
  local g = s.guide
  local k = config.options.keymaps
  local regen = type(k.regenerate_guide) == 'string' and k.regenerate_guide or ':RevueyGuide!'
  local back = type(k.toggle_guide) == 'string' and k.toggle_guide or ':RevueyGuide'
  line(doc, 'AI guide', 'RevueyGuideTitle', 'title')
  line(doc, '', nil, 'blank')
  if #g.hunks == 0 then
    line(doc, 'Nothing to guide: this review has no changes.', 'RevueyGuideMeta', 'placeholder')
    return
  end
  if M.jobs[g.ks] then
    line(doc, 'Generating a guide for ' .. plural(#g.hunks, 'hunk') .. ' with ' .. (config.options.ai.provider or 'claude') .. '.', nil, 'placeholder')
    s.guide_status_line = #doc + 1
    line(doc, '', nil, 'status')
    line(doc, '', nil, 'blank')
    add_prose(doc, ('Keep reviewing meanwhile: `%s` shows the diff. `:RevueyGuide cancel` stops the run.'):format(back), width, 'placeholder', nil, 'RevueyGuideMeta')
    return
  end
  local err = M.errors[g.ks]
  if err then
    add_prose(doc, '> [!WARNING] Guide generation failed: ' .. err:gsub('\n', ' '), width, 'banner')
    line(doc, '', nil, 'blank')
  end
  add_prose(doc, 'No guide for this review yet.', width, 'placeholder')
  line(doc, '', nil, 'blank')
  add_prose(doc, ('Press `%s` to generate one. It runs your `claude` CLI in `%s` with read-only tools, and takes a minute or two. `%s` returns to the diff.'):format(
    regen,
    vim.fn.fnamemodify(s.review.root, ':~'),
    back
  ), width, 'placeholder', nil, 'RevueyGuideMeta')
end

---Document for layout.compose_guide (see revuey.GuideDocItem).
---@param width integer prose wrap width
function M.doc(s, width)
  local g = s.guide or M.prepare(s)
  local doc = {}
  s.guide_status_line = nil
  local res = g.resolved
  if not res then
    placeholder(s, doc, width)
    return doc
  end
  add_prose(doc, res.title, width, 'title', nil, 'RevueyGuideTitle')
  local gen = res.generator or {}
  local done, total = M.progress(s)
  local meta = { plural(#res.sections, 'section'), ('%d/%d reviewed'):format(done, total) }
  if gen.model then
    meta[#meta + 1] = gen.model
  end
  if gen.generated_at then
    meta[#meta + 1] = ago(gen.generated_at)
  end
  -- (wrapped like prose; no markdown in it)
  local plain = table.concat(meta, ' · ')
  for _, l in ipairs(prose.wrap(plain, { { 0, #plain, 'RevueyGuideMeta' } }, width)) do
    doc[#doc + 1] = { kind = 'prose', text = l.text, hls = l.hls, role = 'meta', block = 'meta', para = 1, off = l.off, pre = l.pre }
  end
  if M.jobs[g.ks] then
    s.guide_status_line = #doc + 1
    line(doc, '', nil, 'status')
  end
  if res.stale then
    local parts = {}
    if res.outdated > 0 then
      parts[#parts + 1] = plural(res.outdated, 'section') .. ' outdated'
    end
    if res.new > 0 then
      parts[#parts + 1] = plural(res.new, 'new hunk')
    end
    local key = config.options.keymaps.regenerate_guide
    line(doc, '', nil, 'blank')
    add_prose(doc, ('> [!WARNING] The diff changed since this guide was generated (%s). Press `%s` to regenerate.'):format(
      table.concat(parts, ', '),
      type(key) == 'string' and key or ':RevueyGuide!'
    ), width, 'banner')
  end
  if res.summary ~= '' then
    line(doc, '', nil, 'blank')
    add_prose(doc, res.summary, width, 'summary')
  end
  if res.diagram then
    line(doc, '', nil, 'blank')
    M.add_diagram(doc, res.diagram, width)
  end
  for si, sec in ipairs(res.sections) do
    line(doc, '', nil, 'blank')
    doc[#doc + 1] = { kind = 'section', text = si .. '. ' .. sec.title, section_idx = si }
    if sec.overview ~= '' then
      add_prose(doc, sec.overview, width, 'overview', si)
    end
    if sec.outdated then
      add_prose(doc, ('_%s of this section changed since the guide was generated and %s not shown._'):format(
        plural(sec.missing, 'hunk'),
        sec.missing == 1 and 'is' or 'are'
      ), width, 'overview', si, 'RevueyGuideOutdated', 'outdated:' .. si)
    end
    for _, item in ipairs(sec.items) do
      local h = item.hunk
      local f = s.review.files[h.file_idx]
      local title = require('revuey.layout').file_title(f)
      local note
      if item.note then
        note = {}
        for _, l in ipairs(prose.render(item.note, width - 2, { base_hl = 'RevueyGuideHunkNote' })) do
          note[#note + 1] = { kind = 'prose', text = '  ' .. l.text, hls = vim.tbl_map(function(sp)
            return { sp[1] + 2, sp[2] + 2, sp[3] }
          end, l.hls), role = 'note', section_idx = si, block = 'note:' .. h.hash, para = l.para, off = l.off, pre = (l.pre or 0) + 2 }
        end
      end
      line(doc, '', nil, 'blank', si)
      doc[#doc + 1] = {
        kind = 'hunk',
        file_idx = h.file_idx,
        hunk_idx = h.hunk_idx,
        header = h.hunk_idx and (title .. '  ' .. h.header) or title,
        path_len = #title,
        guide_id = h.id,
        note = note,
        section_idx = si,
        layers = h.layers,
      }
    end
  end
  return doc
end

---Overview diagram rows: a heading, then the drawing (boxes, or the list form when the boxes do
---not fit `width`). Node spans carry the node's section for `<CR>`.
function M.add_diagram(doc, d, width)
  local heading = 'Overview'
  doc[#doc + 1] = { kind = 'diagram', heading = true, text = heading, hls = { { 0, #heading, 'RevueyGuideHeading' } } }
  local out = diagram.render(d, width)
  local section = {}
  for _, n in ipairs(d.nodes) do
    section[n.id] = n.section
  end
  local rows = {}
  for i, l in ipairs(out.lines) do
    rows[i] = { kind = 'diagram', text = l, hls = {}, nodes = {} }
  end
  for _, sp in ipairs(out.hls) do
    table.insert(rows[sp[1]].hls, { sp[2], sp[3], sp[4] })
  end
  for _, sp in ipairs(out.nodes) do
    table.insert(rows[sp[1]].nodes, { sp[2], sp[3], id = sp[4], section = section[sp[4]] })
  end
  vim.list_extend(doc, rows)
  return out
end

-- ---------------------------------------------------------------------------
-- Generation
-- ---------------------------------------------------------------------------

---Short scope name for the guide's title area ("layer stack/cart", "full stack"), or nil when
---the review is not part of a stack.
function M.scope_title(r)
  local st = r.stack
  if st and r.scope then
    if r.scope.kind == 'full' then
      return 'full stack'
    end
    local l = st.layers[r.scope.index]
    return l and ('layer ' .. l.name) or nil
  end
end

---Stack context for the prompt (revuey.GuideStackContext). Runs git (call inside git.async):
---the full scope lists each layer's commit subjects, so the model can say which branch
---introduced what.
local function stack_context(r)
  local st = r.stack
  if not (st and r.scope) then
    return nil
  end
  local full = r.scope.kind == 'full'
  local layers = {}
  for i, l in ipairs(st.layers) do
    local commits, count
    if full then
      local range = l.parent_rev .. '..' .. l.tip
      local log = git.git({ 'log', '--format=%s', '--no-merges', '-n', tostring(prompt.MAX_LAYER_COMMITS), range }, r.root) or ''
      commits = vim.split(vim.trim(log), '\n', { trimempty = true })
      count = tonumber(vim.trim(git.git({ 'rev-list', '--count', '--no-merges', range }, r.root) or '')) or #commits
    end
    layers[i] = { name = l.name, parent = l.parent, commits = commits, commit_count = count }
  end
  return { kind = full and 'full' or 'layer', index = not full and r.scope.index or nil, trunk = st.trunk, layers = layers }
end

local ticker

local function tick()
  local view = require('revuey.view')
  local s = view.session
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

---Draw the live status (spinner) into the panel and the guide view, without re-rendering.
function M.draw_status(s)
  local text = M.status_text(s)
  local function put(buf, row, indent)
    if not row or not api.nvim_buf_is_valid(buf) or row > api.nvim_buf_line_count(buf) then
      return
    end
    api.nvim_buf_clear_namespace(buf, M.ns_status, row - 1, row)
    if text then
      api.nvim_buf_set_extmark(buf, M.ns_status, row - 1, 0, {
        virt_text = { { indent .. text, 'RevueyGuideSpinner' } },
        virt_text_pos = 'overlay',
      })
    end
  end
  put(s.panel_buf, s.panel_status_row, ' ')
  if s.view_mode == 'guide' then
    put(s.diff_buf, s.guide_status_line, '')
  end
end

local function ensure_ticker()
  if ticker then
    return
  end
  ticker = vim.uv.new_timer()
  ticker:start(0, 100, vim.schedule_wrap(tick))
end

---Start generating a guide for the session's current review (no-op if one is running for it).
---@param s revuey.Session
---@param on_change fun() called (on the main loop) when the guide or the job state changed
function M.generate(s, on_change)
  local g = M.prepare(s)
  local ks = g.ks
  if M.jobs[ks] then
    return vim.notify('revuey: a guide is already being generated for this review', vim.log.levels.INFO)
  end
  if #g.hunks == 0 then
    return vim.notify('revuey: nothing to guide (no changes)', vim.log.levels.INFO)
  end
  local r = s.review
  local hunks, key = g.hunks, g.key
  local dir = guide.dir(state_dir(s))
  local cfg = config.options.ai or {}
  M.errors[ks] = nil
  local entry = { label = r.branch, started = vim.uv.hrtime() }
  M.jobs[ks] = entry
  ensure_ticker()
  on_change()
  git.async(function()
    local log = git.git({ 'log', '--format=%s', '--no-merges', '-n', '50', r.merge_base .. '..' .. r.head }, r.root) or ''
    local commits = vim.split(vim.trim(log), '\n', { trimempty = true })
    local text, info = prompt.build({
      repo = vim.fs.basename(r.root),
      branch = r.branch,
      base = r.base,
      stack = stack_context(r),
      uncommitted = vim.iter(r.files):any(function(f)
        return f.uncommitted == true
      end),
      commits = commits,
      diff_cmd = 'git diff ' .. r.merge_base .. (r.mode == 'worktree' and '' or (' ' .. r.head)),
    }, hunks, { budget = cfg.max_prompt_chars })
    if M.jobs[ks] ~= entry then
      return -- cancelled while gathering
    end
    if not text then
      M.jobs[ks] = nil
      M.errors[ks] = info --[[@as string]]
      vim.notify('revuey: guide not generated: ' .. info, vim.log.levels.ERROR)
      return on_change()
    end
    entry.abridged = info.abridged
    entry.prompt_level = info.level
    entry.job = ai.run({
      prompt = text,
      schema = prompt.schema_json(),
      cwd = r.root,
      model = cfg.model,
      effort = cfg.effort,
      name = 'revuey guide: ' .. r.branch,
      on_event = function(ev)
        if ev.type == 'progress' then
          entry.progress = ev.text
        end
      end,
      on_done = function(err, result)
        if M.jobs[ks] ~= entry then
          return
        end
        M.jobs[ks] = nil
        local rec
        if not err then
          local valid, w = guide.validate(result.output or result.text or '', hunks)
          if not valid then
            err = w --[[@as string]]
          else
            rec = guide.record(valid, hunks, {
              key = key,
              generator = {
                provider = cfg.provider or 'claude',
                model = result.model or cfg.model,
                session_id = result.session_id,
                generated_at = os.time(),
                head = r.head,
                merge_base = r.merge_base,
                mode = r.mode,
                duration_ms = result.duration_ms,
                cost_usd = result.cost_usd,
                abridged = entry.abridged,
                prompt_level = entry.prompt_level,
                warnings = w,
              },
            })
            local ok, serr = pcall(guide.save, dir, rec, cfg.keep_guides)
            if not ok then
              err = tostring(serr)
            end
          end
        end
        if err then
          M.errors[ks] = err ~= 'cancelled' and err or nil
          vim.notify('revuey: guide ' .. (err == 'cancelled' and 'generation cancelled' or ('generation failed: ' .. err)),
            err == 'cancelled' and vim.log.levels.INFO or vim.log.levels.ERROR)
        else
          local secs = math.floor((vim.uv.hrtime() - entry.started) / 1e9 + 0.5)
          local cur = require('revuey.view').session
          local here = cur and cur.guide and cur.guide.ks == ks and cur.view_mode == 'guide'
          vim.notify(('revuey: guide ready (%d sections, %ds)%s'):format(#rec.sections, secs,
            here and '' or ('; ' .. (config.options.keymaps.toggle_guide or ':RevueyGuide') .. ' to open')), vim.log.levels.INFO)
        end
        on_change()
      end,
    })
  end, function(e)
    M.jobs[ks] = nil
    M.errors[ks] = tostring(e)
    vim.schedule(on_change)
  end)
end

---Cancel the run for the session's review.
function M.cancel(s)
  local g = M.prepare(s)
  local j = M.jobs[g.ks]
  if not j then
    return false
  end
  if j.job and j.job.proc then
    j.job:cancel()
  else
    -- still gathering commits: forget it; the coroutine checks before spawning
    M.jobs[g.ks] = nil
    vim.notify('revuey: guide generation cancelled', vim.log.levels.INFO)
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Panel
-- ---------------------------------------------------------------------------

---Guide block in the file panel: header with progress, live status, and (in the guide view) the
---section list. Rows map to section indexes in `s.panel_sections`.
function M.panel(s, add, add_virt, width)
  local g = s.guide or M.prepare(s)
  s.panel_sections = {}
  s.panel_status_row = nil
  local job = M.jobs[g.ks]
  local res = g.resolved
  if s.view_mode ~= 'guide' and not res and not job then
    return
  end
  local done, total = M.progress(s)
  local title = ' Guide'
  local hls = { { 0, #title, 'RevueyPanelTitle' } }
  local virt
  if res then
    virt = { { ('%d/%d reviewed'):format(done, total), (total > 0 and done == total) and 'RevueyReviewed' or 'Comment' } }
  end
  local row = add(title, hls)
  if virt then
    add_virt(row, virt)
  end
  if job then
    s.panel_status_row = add('')
  end
  if res and res.stale then
    local t = ' ! diff changed since generated'
    add(t, { { 0, #t, 'RevueyGuideBanner' } })
  end
  if s.view_mode == 'guide' and res then
    for si, sec in ipairs(res.sections) do
      local reviewed = M.section_reviewed(s, sec)
      local check = reviewed and '✓' or ' '
      local num = tostring(si)
      local prefix = ' ' .. check .. ' ' .. num .. ' '
      local info = sec.outdated and '!' or tostring(#sec.items)
      local avail = width - vim.fn.strdisplaywidth(prefix) - #info - 2
      local name = require('revuey.panel').truncate(sec.title, math.max(avail, 1))
      local text = prefix .. name
      local r = add(text, {
        { 1, 1 + #check, 'RevueyReviewed' },
        { 1 + #check + 1, 1 + #check + 1 + #num, 'RevueyGuideSectionNumber' },
        { #prefix, #text, reviewed and 'RevueyUnreviewed' or (sec.kind ~= 'section' and 'Comment' or 'Normal') },
      })
      add_virt(r, { { info, sec.outdated and 'RevueyGuideOutdated' or 'Comment' } })
      s.panel_sections[r] = si
    end
  elseif not res and s.view_mode == 'guide' and not job then
    local t = ' no guide yet'
    add(t, { { 0, #t, 'Comment' } })
  end
  add('')
end

return M
