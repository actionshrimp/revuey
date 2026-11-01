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
local units = require('revuey.units')
local review_mod = require('revuey.review')

local M = {}

M.ns_status = api.nvim_create_namespace('revuey.guide.status')
M.ns_notes = api.nvim_create_namespace('revuey.guide.notes')

---Jobs by review key string; they outlive scope switches (each scope has its own guide). A job
---for the connected agent has `agent` {id, path, name, acked?, late?} instead of `job` (a request,
---requests.lua: the agent writes the guide and imports it).
---@type table<string, {job?: revuey.AiJob, agent?: table, label: string, progress?: string}>
M.jobs = {}
local adopt -- (an open request of a review that is gone: below)
---A request no agent took (`guide --prompt --request`) within this long is shown as not picked
---up, with the fresh run offered.
M.AGENT_ACK_MS = 60000
---How often the review reads an open request's file while it waits.
M.AGENT_POLL_MS = 500
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
    -- the units' hunk entries: guide hunk ids and unit keys come from the same hashes
    hunks = review_mod.units(r).hunks
    anchors = guide.anchors_hash(hunks)
    -- full-stack reviews: the layers that introduced each hunk (labels and prompt tags)
    local labels = r.layer_labels
    if labels then
      for _, h in ipairs(hunks) do
        h.layers = labels[h.file_idx] and labels[h.file_idx][h.hunk_idx or 0] or nil
      end
    end
  end
  local rec, file_sig
  if not force and g and g.ks == ks and g.anchors == anchors and not g.reload then
    rec, file_sig = g.record, g.file_sig
  else
    -- what the guides directory looked like when it was read (notice_saved)
    s.guide_dir_sig = M.dir_sig(s)
    rec = guide.load(guide.dir(state_dir(s)), key, anchors)
  end
  local fresh = not (g and g.review == r and g.ks == ks)
  s.guide = {
    review = r,
    key = key,
    ks = ks,
    hunks = hunks,
    anchors = anchors,
    record = rec,
    resolved = rec and guide.resolve(rec, hunks) or nil,
    file_sig = file_sig or M.file_sig(rec),
  }
  if fresh then
    adopt(s, s.guide)
  end
  if s.guide.resolved then
    -- section marks of the old format become unit marks
    local _, err = units.migrate_sections(r.state, review_mod.units(r), s.guide.resolved.sections)
    if err then
      vim.notify(tostring(err), vim.log.levels.ERROR)
    end
  end
  return s.guide
end

function M.job(s)
  local g = s.guide or M.prepare(s)
  return M.jobs[g.ks]
end

---Units shown by a resolved section.
function M.section_units(s, sec)
  return units.section_units(review_mod.units(s.review), sec)
end

---Reviewed and total units of a section.
---@return integer done, integer total
function M.section_progress(s, sec)
  return units.progress(s.review.state, M.section_units(s, sec))
end

---A section is reviewed when all of its units are (sections showing no hunks never are).
function M.section_reviewed(s, sec)
  return units.all_reviewed(s.review.state, M.section_units(s, sec))
end

---Fully reviewed sections over sections that can be reviewed (those showing hunks).
function M.progress(s)
  local g = s.guide
  local res = g and g.resolved
  if not res then
    return 0, 0
  end
  local done, total = 0, 0
  for _, sec in ipairs(res.sections) do
    if #sec.items > 0 then
      total = total + 1
      if M.section_reviewed(s, sec) then
        done = done + 1
      end
    end
  end
  return done, total
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

---Status line for a running job: spinner, elapsed time, latest progress (for the connected
---agent: waiting for it, it is writing, or it has not picked the request up).
function M.status_text(s)
  local j = M.job(s)
  if not j then
    return nil
  end
  local secs = math.floor((vim.uv.hrtime() - j.started) / 1e9)
  local frame = SPINNER[(math.floor(vim.uv.hrtime() / 1e8) % #SPINNER) + 1]
  local a = j.agent
  if a then
    if a.acked then
      return ('%s %s is writing the guide %ds'):format(frame, a.name, secs)
    elseif a.delivered then
      return ('%s %s has the request %ds'):format(frame, a.name, secs)
    elseif a.late then
      local k = config.options.keymaps.regenerate_guide
      return ('! %s has not picked it up (%ds): %s for a fresh session'):format(a.name, secs, type(k) == 'string' and k or ':RevueyGuide!')
    end
    return ('%s waiting for %s %ds'):format(frame, a.name, secs)
  end
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
  local job = M.jobs[g.ks]
  if job and job.agent then
    -- plain text, never markdown: the name is the agent's
    local plain = ('Asked %s, the connected agent, to write a guide for %s. It shows here when %s imports it.'):format(job.agent.name, plural(#g.hunks, 'hunk'), job.agent.name)
    for _, l in ipairs(prose.wrap(plain, {}, width)) do
      doc[#doc + 1] = { kind = 'prose', text = l.text, hls = l.hls, role = 'placeholder', block = 'agent', para = 1, off = l.off, pre = l.pre }
    end
    s.guide_status_line = #doc + 1
    line(doc, '', nil, 'status')
    line(doc, '', nil, 'blank')
    add_prose(doc, ('Keep reviewing meanwhile: `%s` shows the diff. `:RevueyGuide cancel` withdraws the request, `%s` offers a fresh session instead.'):format(back, regen), width, 'placeholder', nil, 'RevueyGuideMeta')
    return
  end
  if job then
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

---The guide's meta line ("2 sections · 1/2 reviewed · model · when"), wrapped like prose (no
---markdown in it). Also used to update it in place after `mr`.
function M.meta_rows(s, width)
  local res = s.guide.resolved
  local gen = res.generator or {}
  local done, total = M.progress(s)
  local meta = { plural(#res.sections, 'section'), ('%d/%d reviewed'):format(done, total) }
  if gen.provider == 'agent' then
    meta[#meta + 1] = (require('revuey.requests').clean_name(gen.agent) or 'agent') .. ' (connected)'
  elseif gen.model then
    meta[#meta + 1] = gen.model
  end
  if gen.generated_at then
    meta[#meta + 1] = ago(gen.generated_at)
  end
  local plain = table.concat(meta, ' · ')
  local out = {}
  for _, l in ipairs(prose.wrap(plain, { { 0, #plain, 'RevueyGuideMeta' } }, width)) do
    out[#out + 1] = { kind = 'prose', text = l.text, hls = l.hls, role = 'meta', block = 'meta', para = 1, off = l.off, pre = l.pre }
  end
  return out
end

---Document for layout.compose_guide (see revuey.GuideDocItem).
---@param width integer prose wrap width
---@param diagram_width? integer overview diagram width (default: `width`)
function M.doc(s, width, diagram_width)
  local g = s.guide or M.prepare(s)
  local doc = {}
  s.guide_status_line = nil
  local res = g.resolved
  if not res then
    placeholder(s, doc, width)
    return doc
  end
  add_prose(doc, res.title, width, 'title', nil, 'RevueyGuideTitle')
  vim.list_extend(doc, M.meta_rows(s, width))
  if M.jobs[g.ks] then
    s.guide_status_line = #doc + 1
    line(doc, '', nil, 'status')
  end
  if s.review.layer_labels_note then
    add_prose(doc, '_' .. s.review.layer_labels_note:gsub('^%l', string.upper) .. '._', width, 'meta', nil, 'RevueyGuideMeta', 'labels-note')
  end
  if res.stale then
    local parts = {}
    if res.outdated > 0 then
      parts[#parts + 1] = plural(res.outdated, 'section') .. ' outdated'
    end
    if res.new > 0 then
      parts[#parts + 1] = plural(res.new, 'new hunk')
    end
    if (res.edited or 0) > 0 then
      parts[#parts + 1] = plural(res.edited, 'hunk') .. ' edited'
    end
    if (res.notes_lost or 0) > 0 then
      parts[#parts + 1] = plural(res.notes_lost, 'line note') .. ' lost'
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
    M.add_diagram(doc, res.diagram, diagram_width or width)
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
        edited = item.edited,
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
-- Line notes: the guide's notes on specific lines, drawn above them (guide view only)
-- ---------------------------------------------------------------------------

---Line notes of the resolved guide with their rows in the current guide layout, in row order:
---{first, last, text, side, section_idx}.
function M.note_rows(s)
  local g = s.guide
  local res = g and g.resolved
  local L = s.layout
  local out = {}
  if not res or not L or L.kind ~= 'guide' then
    return out
  end
  for si, sec in ipairs(res.sections) do
    for _, item in ipairs(sec.items) do
      local h = item.hunk
      local base = h.hunk_idx and L.hunk_base[h.file_idx] and L.hunk_base[h.file_idx][h.hunk_idx]
      if base then
        for _, n in ipairs(item.line_notes or {}) do
          out[#out + 1] = { first = base + n.line, last = base + n.end_line, text = n.text, side = n.side, section_idx = si }
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if a.first ~= b.first then
      return a.first < b.first
    end
    return a.last < b.last
  end)
  return out
end

---Text width for a note: the diff window minus the gutter, at most the prose width (and never
---wider than the window, however narrow).
local function note_width(s)
  local w = (s.diff_win and api.nvim_win_is_valid(s.diff_win)) and api.nvim_win_get_width(s.diff_win) or 100
  return math.max(1, math.min(w - (2 * (s.numw or 3) + 4) - 1, s.prose_width or 100))
end

M.NOTE_LABEL = ' ▼ guide '

---Cut virtual text chunks to `width` cells (a word or the label wider than a narrow window).
local function fit(line, width)
  local out, used = {}, 0
  for _, ch in ipairs(line) do
    local w = api.nvim_strwidth(ch[1])
    if used + w <= width then
      out[#out + 1] = ch
      used = used + w
    else
      local text = ch[1]
      while text ~= '' and used + api.nvim_strwidth(text) > width do
        text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
      end
      if text ~= '' then
        out[#out + 1] = { text, ch[2] }
      end
      break
    end
  end
  return out
end

local function chunks(line, base)
  return require('revuey.comments_view').chunks(line, base)
end

---Draw the line notes (guide view): above the first line of each note, a band with a `guide`
---label and the text (wrapped); with notes collapsed (`gN`), a `◆ guide` marker at the end of
---that line instead. Notes on one row stack in order. Rows are kept for `]n`/`[n`.
function M.draw_notes(s)
  local buf = s.diff_buf
  if not buf or not api.nvim_buf_is_valid(buf) then
    return
  end
  api.nvim_buf_clear_namespace(buf, M.ns_notes, 0, -1)
  s.guide_note_rows = {}
  s.guide_note_cover = {} -- rows a note is on (the winbar's key hint)
  if s.view_mode ~= 'guide' then
    return require('revuey.key_help').update(s)
  end
  local notes = M.note_rows(s)
  local width = note_width(s)
  local by_row, order = {}, {}
  for _, n in ipairs(notes) do
    if not by_row[n.first] then
      by_row[n.first] = {}
      order[#order + 1] = n.first
      s.guide_note_rows[#s.guide_note_rows + 1] = n.first
    end
    table.insert(by_row[n.first], n)
    for r = n.first, n.last do
      s.guide_note_cover[r] = true
    end
  end
  for _, row in ipairs(order) do
    local list = by_row[row]
    if s.guide_notes_collapsed then
      local label = #list > 1 and (' ◆ guide ×' .. #list) or ' ◆ guide'
      pcall(api.nvim_buf_set_extmark, buf, M.ns_notes, row - 1, 0, {
        virt_text = { { '  ' }, { label, 'RevueyGuideLineNoteMarker' } },
        virt_text_pos = 'eol',
        hl_mode = 'combine',
        priority = 25,
      })
    else
      local vl = {}
      for _, n in ipairs(list) do
        local label = M.NOTE_LABEL
        if n.last > n.first then
          label = label .. '· ' .. (n.last - n.first + 1) .. ' lines '
        end
        local lw = api.nvim_strwidth(label)
        -- inline markdown only (backticks, bold): no blocks, so "```lua" or "> [!WARNING]" stay
        -- plain text; the raw text when the markup leaves nothing. The band fills the width.
        local plain, spans = prose.inline(n.text)
        if not plain:find('%S') then
          plain, spans = n.text, {}
        end
        local rendered = prose.wrap(plain, spans, math.max(width - lw - 2, 1))
        for i, l in ipairs(rendered) do
          local line = { { i == 1 and label or string.rep(' ', lw), 'RevueyGuideLineNoteLabel' }, { ' ', 'RevueyGuideLineNote' } }
          vim.list_extend(line, chunks(l, 'RevueyGuideLineNote'))
          local used = lw + 1 + api.nvim_strwidth(l.text)
          line[#line + 1] = { string.rep(' ', math.max(width - used, 0)), 'RevueyGuideLineNote' }
          vl[#vl + 1] = fit(line, width)
        end
      end
      pcall(api.nvim_buf_set_extmark, buf, M.ns_notes, row - 1, 0, {
        virt_lines = vl,
        virt_lines_above = true,
        priority = 25,
      })
    end
  end
  require('revuey.key_help').update(s)
end

---`gN` (guide view): show the line notes in full, or collapse them to a marker at the end of
---their line.
function M.toggle_notes(s)
  if not s then
    return
  end
  if s.view_mode ~= 'guide' then
    return vim.notify('revuey: line notes are part of the guide view (' .. (config.options.keymaps.toggle_guide or ':RevueyGuide') .. ')', vim.log.levels.INFO)
  end
  s.guide_notes_collapsed = not s.guide_notes_collapsed or nil
  M.draw_notes(s)
  vim.notify('revuey: guide line notes ' .. (s.guide_notes_collapsed and 'collapsed' or 'shown'), vim.log.levels.INFO)
end

---`]n` / `[n` (guide view): the next or previous line note (takes a count).
function M.next_note(s, dir)
  if not s then
    return
  end
  if s.view_mode ~= 'guide' then
    return vim.notify('revuey: line notes are part of the guide view (' .. (config.options.keymaps.toggle_guide or ':RevueyGuide') .. ')', vim.log.levels.INFO)
  end
  local rows = s.guide_note_rows or {}
  if #rows == 0 then
    return vim.notify('revuey: this guide has no line notes', vim.log.levels.INFO)
  end
  local row = api.nvim_win_get_cursor(s.diff_win)[1]
  local target
  for _ = 1, vim.v.count1 do
    local t
    if dir > 0 then
      for _, r in ipairs(rows) do
        if r > row then
          t = r
          break
        end
      end
    else
      for i = #rows, 1, -1 do
        if rows[i] < row then
          t = rows[i]
          break
        end
      end
    end
    if not t then
      break
    end
    row, target = t, t
  end
  if not target then
    return vim.notify('revuey: no more line notes ' .. (dir > 0 and 'below' or 'above'), vim.log.levels.INFO)
  end
  api.nvim_set_current_win(s.diff_win)
  api.nvim_win_call(s.diff_win, function()
    vim.cmd("normal! m'")
    api.nvim_win_set_cursor(0, { target, 0 })
    vim.cmd('normal! zv')
    local top, bot = vim.fn.line('w0'), vim.fn.line('w$')
    if target <= top or target >= bot - 1 then
      vim.cmd('normal! zz')
    end
  end)
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

---Context of the user message (revuey.GuideContext) for a review: repo, scope wording, commit
---subjects, whether some changes are uncommitted. Runs git (call inside git.async). Shared with
---AI reviews (ai_review_view.lua).
---@return revuey.GuideContext
function M.prompt_context(r)
  local log = git.git({ 'log', '--format=%s', '--no-merges', '-n', '50', r.merge_base .. '..' .. r.head }, r.root) or ''
  return {
    repo = vim.fs.basename(r.root),
    branch = r.branch,
    base = r.base,
    stack = stack_context(r),
    uncommitted = vim.iter(r.files):any(function(f)
      return f.uncommitted == true
    end),
    commits = vim.split(vim.trim(log), '\n', { trimempty = true }),
    diff_cmd = 'git diff ' .. r.merge_base .. (r.mode == 'worktree' and '' or (' ' .. r.head)),
  }
end

local ticker
local poll_requests

local function tick()
  local view = require('revuey.view')
  local s = view.session
  poll_requests()
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

-- ---------------------------------------------------------------------------
-- The connected agent writes the guide (a request, requests.lua)
-- ---------------------------------------------------------------------------

---Read the files of the agent jobs (every AGENT_POLL_MS): delivered (a watch printed it),
---taken (acked), done (the guide was imported: reload it), cancelled elsewhere or gone, or past
---requests.TTL_MS (expired: the CLI no longer lists it). Not delivered within AGENT_ACK_MS: said
---once (a delivered request is fine however long the agent takes to start).
poll_requests = function()
  local requests = require('revuey.requests')
  local now = vim.uv.hrtime()
  for ks, j in pairs(M.jobs) do
    local a = j.agent
    if a and now - (a.checked or 0) >= M.AGENT_POLL_MS * 1e6 then
      a.checked = now
      local st = vim.uv.fs_stat(a.path)
      local sig = st and (st.mtime.sec .. '.' .. st.mtime.nsec .. ':' .. st.size) or 'gone'
      local expired = now - j.started >= requests.TTL_MS * 1e6
      if sig ~= a.sig or expired then
        a.sig = sig
        local rec = st and requests.read(a.path)
        if not rec or rec.status == 'cancelled' or rec.status == 'done' or expired then
          M.jobs[ks] = nil
          if rec and rec.status == 'done' then
            local secs = math.floor((now - j.started) / 1e9 + 0.5)
            vim.notify(('revuey: guide ready from %s (%s, %ds)'):format(a.name, plural(rec.result and rec.result.sections or 0, 'section'), secs), vim.log.levels.INFO)
          elseif expired and rec then
            vim.notify(('revuey: the guide request to %s expired; generate again for a fresh session'):format(a.name), vim.log.levels.WARN)
          else
            vim.notify(('revuey: the guide request to %s was %s'):format(a.name, rec and 'cancelled' or 'removed'), vim.log.levels.INFO)
          end
          j.on_change()
        else
          a.acked = rec.status == 'acked'
          a.delivered = a.acked or rec.delivered_at ~= nil
        end
      end
      if M.jobs[ks] == j and not a.delivered and not a.late and now - j.started >= M.AGENT_ACK_MS * 1e6 then
        a.late = true
        local k = config.options.keymaps.regenerate_guide
        vim.notify(('revuey: %s has not picked up the guide request yet; %s offers a fresh session instead (or keep waiting)'):format(
          a.name, type(k) == 'string' and k or ':RevueyGuide!'), vim.log.levels.WARN)
      end
    end
  end
end

---How a review re-renders when a guide job (or an outside import) changes; view.lua sets it.
M.default_on_change = function() end

---An open guide request for this review made by a review that is gone (Neovim quit or crashed
---while waiting): the reopened review waits for it again, as if it had asked. Requests of
---another live review are left to it.
adopt = function(s, g)
  if M.jobs[g.ks] or not s.review then
    return
  end
  local requests = require('revuey.requests')
  local sessions = require('revuey.sessions')
  local mine = tostring(vim.uv.os_getpid())
  for _, rec in ipairs(requests.list({ state_dir(s) }, { open = true })) do
    local k = rec.key or {}
    local sid = rec.session and tostring(rec.session)
    -- the requesting Neovim is this one (the job was lost) or has exited; one this Neovim
    -- tried to withdraw is never taken back
    local owner_gone = not sid or sid == mine or not sessions.alive({ pid = tonumber(sid) })
    if rec.kind == 'guide' and owner_gone and not M.cancel_tried[rec.id] and k.repo == g.key.repo and k.branch == g.key.branch and k.base == g.key.base then
      local age_ns = math.max(0, requests.now_ms() - (tonumber(rec.at) or 0)) * 1e6
      M.jobs[g.ks] = {
        label = s.review.branch,
        started = vim.uv.hrtime() - age_ns,
        on_change = function()
          M.default_on_change()
        end,
        agent = {
          id = rec.id,
          path = rec._path,
          name = rec.agent or 'agent',
          acked = rec.status == 'acked',
          delivered = rec.status == 'acked' or rec.delivered_at ~= nil,
          adopted = true,
        },
      }
      ensure_ticker()
      return
    end
  end
end
M._adopt = adopt

---The guides directory's mtime (a stat).
function M.dir_sig(s)
  local st = vim.uv.fs_stat(guide.dir(state_dir(s)))
  return st and (st.mtime.sec .. '.' .. st.mtime.nsec) or 'none'
end

---Which file a loaded guide record came from, and its mtime and size.
---Taken when guide.load read the file, never later: a re-save after the read must differ.
function M.file_sig(rec)
  return rec and rec._file_sig or 'none'
end

---Every couple of seconds (agent_link's poll): a guide saved for this review from outside
---(`bin/revuey import-guide` without a request, or a re-import) is loaded. The guides
---directory is shared by every repo and scope, so its mtime (one stat) only says something was
---written there; then `guide.load` for this review's key says whether this review's guide is
---another file now, and only that re-renders, in the guide view. In the diff view the record is
---just marked for reloading by the next render.
function M.notice_saved(s)
  if not s or s.cleaned or not s.guide then
    return
  end
  local sig = M.dir_sig(s)
  if s.guide_dir_sig == nil then
    s.guide_dir_sig = sig
    return
  end
  if sig == s.guide_dir_sig then
    return
  end
  s.guide_dir_sig = sig
  local g = s.guide
  local rec = guide.load(guide.dir(state_dir(s)), g.key, g.anchors)
  if M.file_sig(rec) == g.file_sig then
    return
  end
  g.reload = true
  if s.view_mode == 'guide' then
    M.default_on_change()
  end
end

---Ask the connected agent to write the guide of the session's current review: a request file
---and a `request` event in the review's feed (`watch --messages` prints it). The job waits for
---the agent to import the guide (poll_requests), with the spinner of a fresh run.
---@return boolean asked
function M.request_agent(s, on_change)
  local g = M.prepare(s)
  local ks = g.ks
  if M.jobs[ks] then
    vim.notify('revuey: a guide is already being generated for this review', vim.log.levels.INFO)
    return false
  end
  if #g.hunks == 0 then
    vim.notify('revuey: nothing to guide (no changes)', vim.log.levels.INFO)
    return false
  end
  local requests = require('revuey.requests')
  local comments = require('revuey.comments')
  local link = require('revuey.agent_link')
  local r = s.review
  local info = comments.review_info(r)
  local name = link.agent_name(s)
  local rec = requests.new('guide', {
    session = s.link and s.link.id or nil,
    worktree = r.root,
    review = info,
    scope_key = r.state._path and vim.fs.basename(r.state._path):gsub('%.json$', '') or nil,
    label = require('revuey.sessions').scope_label(info),
    agent = name,
    key = g.key,
    anchors = g.anchors,
    guide_dir = guide.dir(state_dir(s)),
  })
  local path, werr = requests.create(requests.dir(state_dir(s)), rec)
  if not path then
    vim.notify('revuey: could not ask ' .. name .. ': ' .. tostring(werr), vim.log.levels.ERROR)
    return false
  end
  local events = (s.cm and s.cm.events) or comments.events_path_for(r.state._path)
  local ok, res, aerr = pcall(comments.append_event, events, requests.event(rec))
  if not ok or res == false then
    os.remove(path)
    vim.notify('revuey: could not ask ' .. name .. ': ' .. tostring(ok and aerr or res), vim.log.levels.ERROR)
    return false
  end
  M.errors[ks] = nil
  M.jobs[ks] = {
    label = r.branch,
    started = vim.uv.hrtime(),
    on_change = on_change,
    agent = { id = rec.id, path = path, name = name, checked = vim.uv.hrtime() },
  }
  ensure_ticker()
  on_change()
  vim.notify(('revuey: asked %s to write the guide (request %s)'):format(name, rec.id), vim.log.levels.INFO)
  return true
end

---Withdraw a request to the agent: the file says cancelled (import-guide refuses it) and the feed
---tells the agent.
---How long a withdrawal keeps trying while the request's lock is busy (an import holds it
---only for the moment it saves), in steps of CANCEL_STEP_MS, never blocking the main loop.
M.CANCEL_RETRY_MS = 3000
M.CANCEL_STEP_MS = 50
---Requests this Neovim tried to withdraw: never adopted again, whatever their file says.
M.cancel_tried = {}

local function cancel_request(s, ks, j, after)
  local requests = require('revuey.requests')
  local comments = require('revuey.comments')
  local a = j.agent
  M.cancel_tried[a.id] = true
  a.cancelling = true
  local deadline = vim.uv.now() + M.CANCEL_RETRY_MS
  local function finish(drop, msg, level, ok)
    a.cancelling = nil
    if drop and M.jobs[ks] == j then
      M.jobs[ks] = nil
    end
    vim.notify(msg, level)
    if drop then
      j.on_change()
    end
    if after then
      after(ok)
    end
  end
  local function attempt()
    local rec, uerr = requests.update(a.path, function(x)
      if x.status == 'done' or x.status == 'cancelled' then
        return false
      end
      x.status, x.cancelled_at = 'cancelled', requests.now_ms()
    end)
    if not rec and not vim.uv.fs_stat(a.path) then
      return finish(true, ('revuey: the guide request to %s is gone'):format(a.name), vim.log.levels.INFO, true)
    elseif not rec then
      if vim.uv.now() < deadline then
        return vim.defer_fn(attempt, M.CANCEL_STEP_MS)
      end
      require('revuey.log').write('agent', 'could not cancel request ' .. a.id .. ': ' .. tostring(uerr))
      return finish(false, ('revuey: could not withdraw the guide request to %s (%s); still waiting: try :RevueyGuide cancel again'):format(
        a.name, tostring(uerr)), vim.log.levels.ERROR, false)
    elseif rec.status == 'done' then
      return finish(true, ('revuey: %s had already imported the guide; it is shown'):format(a.name), vim.log.levels.INFO, true)
    end
    local events = (s.cm and s.cm.events) or comments.events_path_for(s.review.state._path)
    pcall(comments.append_event, events, requests.event(rec))
    finish(true, ('revuey: guide request to %s cancelled'):format(a.name), vim.log.levels.INFO, true)
  end
  attempt()
end

---Start generating a guide for the session's current review (no-op if one is running for it).
---`opts`: model and effort for this run (default: ai.model, ai.effort).
---@param s revuey.Session
---@param on_change fun() called (on the main loop) when the guide or the job state changed
---@param opts? {model?: string, effort?: string}
function M.generate(s, on_change, opts)
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
  local entry = { label = r.branch, started = vim.uv.hrtime(), on_change = on_change }
  M.jobs[ks] = entry
  ensure_ticker()
  on_change()
  git.async(function()
    local text, info = prompt.build(M.prompt_context(r), hunks, { budget = cfg.max_prompt_chars })
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
    entry.shown = { level = info.level, abridged = info.abridged_ids }
    entry.job = ai.run({
      prompt = text,
      schema = prompt.schema_json(),
      cwd = r.root,
      model = opts and opts.model or cfg.model,
      effort = opts and opts.effort or cfg.effort,
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
          local valid, w = guide.validate(result.output or result.text or '', hunks, entry.shown)
          if not valid then
            err = w --[[@as string]]
          else
            rec = guide.record(valid, hunks, {
              key = key,
              generator = {
                provider = cfg.provider or 'claude',
                model = result.model or (opts and opts.model) or cfg.model,
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
          local nw = rec.generator.warnings and rec.generator.warnings.notes
          local dropped = guide.dropped_text(nw)
          vim.notify(('revuey: guide ready (%d sections, %ds)%s%s'):format(#rec.sections, secs,
            dropped and ('; line notes: ' .. dropped) or '',
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
---`after(ok)` (a request to the agent only): called once the withdrawal is done or failed.
function M.cancel(s, after)
  local g = M.prepare(s)
  local j = M.jobs[g.ks]
  if not j then
    return false
  end
  if j.agent then
    if j.agent.cancelling then
      return true
    end
    cancel_request(s, g.ks, j, after)
  elseif j.job and j.job.proc then
    j.job:cancel()
  else
    -- still gathering commits: forget it; the coroutine checks before spawning
    M.jobs[g.ks] = nil
    vim.notify('revuey: guide generation cancelled', vim.log.levels.INFO)
    if j.on_change then
      j.on_change() -- the guide view and the panel drop the spinner
    end
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
      local ndone, ntotal = M.section_progress(s, sec)
      local reviewed = ntotal > 0 and ndone == ntotal
      local check = require('revuey.panel').glyph(ndone, ntotal)
      local num = tostring(si)
      local prefix = ' ' .. check .. ' ' .. num .. ' '
      local info = (sec.outdated and '!' or '') .. ((ndone > 0 and not reviewed) and (ndone .. '/' .. ntotal) or tostring(#sec.items))
      local avail = width - vim.fn.strdisplaywidth(prefix) - #info - 2
      local name = require('revuey.panel').truncate(sec.title, math.max(avail, 1))
      local text = prefix .. name
      local r = add(text, {
        { 1, 1 + #check, (ndone > 0 and not reviewed) and 'RevueyPartial' or 'RevueyReviewed' },
        { 1 + #check + 1, 1 + #check + 1 + #num, 'RevueyGuideSectionNumber' },
        { #prefix, #text, reviewed and 'RevueyUnreviewed' or (sec.kind ~= 'section' and 'Comment' or 'Normal') },
      })
      add_virt(r, { { info, sec.outdated and 'RevueyGuideOutdated' or ((ndone > 0 and not reviewed) and 'RevueyPartial' or 'Comment') } })
      s.panel_sections[r] = si
    end
  elseif not res and s.view_mode == 'guide' and not job then
    local t = ' no guide yet'
    add(t, { { 0, #t, 'Comment' } })
  end
  add('')
end

return M
