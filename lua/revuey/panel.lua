-- File panel: list of changed files with status, +/- counts and reviewed checkmarks.
local review_mod = require('revuey.review')
local forge_view = require('revuey.forge_view')

local M = {}

local ns = vim.api.nvim_create_namespace('revuey.panel')
local ns_cur = vim.api.nvim_create_namespace('revuey.panel.current')
local ns_sec = vim.api.nvim_create_namespace('revuey.panel.section')
local ns_hint = vim.api.nvim_create_namespace('revuey.panel.hint')

local status_hl = {
  A = 'RevueyStatusAdded',
  D = 'RevueyStatusDeleted',
  M = 'RevueyStatusModified',
  R = 'RevueyStatusRenamed',
  T = 'RevueyStatusModified',
}
M.status_hl = status_hl

M.GLYPH_DONE, M.GLYPH_PARTIAL = '✓', '◐'

---Progress glyph: ✓ all reviewed, ◐ some, ' ' none.
function M.glyph(done, total)
  if total > 0 and done == total then
    return M.GLYPH_DONE
  end
  return done > 0 and M.GLYPH_PARTIAL or ' '
end

---Cut `str` to at most `width` display cells, ending in '…' when cut (from the left with
---`from_left`, keeping the tail). Works on display width, so wide (CJK) characters fit.
function M.truncate(str, width, from_left)
  if vim.fn.strdisplaywidth(str) <= width then
    return str
  end
  if width <= 1 then
    return width == 1 and '…' or ''
  end
  local n = vim.fn.strchars(str)
  local out, w = {}, 0
  for k = 0, n - 1 do
    local ch = vim.fn.strcharpart(str, from_left and (n - 1 - k) or k, 1)
    local cw = vim.fn.strdisplaywidth(ch)
    if w + cw > width - 1 then
      break
    end
    w = w + cw
    if from_left then
      table.insert(out, 1, ch)
    else
      out[#out + 1] = ch
    end
  end
  local body = table.concat(out)
  return from_left and ('…' .. body) or (body .. '…')
end

---Wrap `text` to `width` display cells (word boundaries), each line prefixed with `indent`. A
---word wider than a line (a long branch name, CJK text without spaces) is broken by display width.
local function wrap(text, width, indent)
  local out, line = {}, indent
  local room = math.max(width - vim.fn.strdisplaywidth(indent), 1)
  local function push()
    if line ~= indent then
      out[#out + 1] = line
    end
    line = indent
  end
  for word in text:gmatch('%S+') do
    if vim.fn.strdisplaywidth(word) > room then
      push()
      local cur, cw = '', 0
      for k = 0, vim.fn.strchars(word) - 1 do
        local ch = vim.fn.strcharpart(word, k, 1)
        local w = vim.fn.strdisplaywidth(ch)
        if cw + w > room and cur ~= '' then
          out[#out + 1] = indent .. cur
          cur, cw = '', 0
        end
        cur, cw = cur .. ch, cw + w
      end
      line = indent .. cur
    elseif line ~= indent and vim.fn.strdisplaywidth(line .. ' ' .. word) > width then
      push()
      line = indent .. word
    else
      line = line == indent and (indent .. word) or (line .. ' ' .. word)
    end
  end
  push()
  return out
end
M.wrap = wrap

---Stack section: trunk, then layers bottom to top, the full-stack row, forks/notes.
---Rows map to layer indexes (or 'full') in `s.panel_layers`.
local function render_stack(s, add, add_virt, width)
  local r = s.review
  local stack = r.stack
  s.panel_layers = {}
  local title = M.truncate((' Stack: %d layer%s on %s'):format(#stack.layers, #stack.layers == 1 and '' or 's', stack.trunk), width)
  add(title, { { 0, #title, 'RevueyPanelTitle' } })
  local scope = r.scope or {}
  local function stats_virt(st, live)
    if live then
      st = vim.tbl_extend('force', st or {}, live)
    end
    if not st or not st.files then
      return { { '…', 'Comment' } }
    end
    local virt = {}
    if st.commits then
      virt[#virt + 1] = { st.commits .. 'c ', 'Comment' }
    end
    virt[#virt + 1] = { st.files .. 'f ', 'Comment' }
    virt[#virt + 1] = {
      '✓' .. (st.reviewed or 0) .. '/' .. st.files,
      (st.files > 0 and st.reviewed == st.files) and 'RevueyReviewed' or 'Comment',
    }
    return virt
  end
  -- live numbers for the scope being reviewed (marks update immediately)
  local live_files, live_reviewed = #r.files, 0
  for _, f in ipairs(r.files) do
    if review_mod.is_reviewed(r, f) then
      live_reviewed = live_reviewed + 1
    end
  end
  local live = { files = live_files, reviewed = live_reviewed }
  for i, l in ipairs(stack.layers) do
    local selected = scope.kind == 'layer' and scope.index == i
    local sel = selected and '▶' or ' '
    local head = l.is_head and '@' or ' '
    local prefix = ' ' .. sel .. head .. ' '
    local name = l.name .. (l.title and ('  ' .. l.title) or '')
    local virt = stats_virt(l.stats, selected and live or nil)
    -- the layer's pull request: `#123 ✓ ` (nothing without one)
    local pr = forge_view.chunks(forge_view.pr(s, l.name))
    if pr then
      s.panel_forge_any = true
      for k = #pr, 1, -1 do
        table.insert(virt, 1, pr[k])
      end
    end
    if l.remote then
      table.insert(virt, 1, { 'ro ', 'RevueyStackRemote' }) -- remote-tracking: read-only
    end
    local function virt_width()
      local vw = 0
      for _, v in ipairs(virt) do
        vw = vw + vim.fn.strdisplaywidth(v[1])
      end
      return vw
    end
    local avail = width - vim.fn.strdisplaywidth(prefix) - virt_width() - 1
    if pr and avail < 8 then
      -- narrow panel: the commit count goes before the branch name gets unreadable
      for k, v in ipairs(virt) do
        if v[1]:match('^%d+c $') then
          table.remove(virt, k)
          break
        end
      end
      avail = width - vim.fn.strdisplaywidth(prefix) - virt_width() - 1
    end
    name = M.truncate(name, math.max(avail, 1))
    local text = prefix .. name
    local row = add(text, {
      { 1, 1 + #sel, 'RevueyMode' },
      -- `@` dimmed: HEAD is detached at this layer's tip (no branch checked out)
      { 1 + #sel, 1 + #sel + #head, l.detached and 'RevueyStackRemote' or 'RevueyUncommitted' },
      { #prefix, #text, (l.dimmed and 'Comment') or (l.remote and 'RevueyStackRemote') or (selected and 'RevueyPanelTitle' or 'Normal') },
    })
    s.panel_layers[row] = i
    add_virt(row, virt)
  end
  local full_sel = scope.kind == 'full'
  local text = ' ' .. (full_sel and '▶' or ' ') .. '  full stack'
  local row = add(text, { { 1, 1 + (full_sel and #'▶' or 1), 'RevueyMode' }, { #text - #'full stack', #text, full_sel and 'RevueyPanelTitle' or 'Comment' } })
  s.panel_layers[row] = 'full'
  add_virt(row, stats_virt(stack.full_stats, full_sel and live or nil))
  M.render_notes(s, add, width)
  add('')
end

---First key of a keymap option (nil when disabled).
local function first_key(name)
  local k = require('revuey.config').options.keymaps[name]
  if type(k) == 'table' then
    k = k[1]
  end
  return k or nil
end

---What `gS` would do on a layer, as a short hint (nil: it is checked out already).
---@param l revuey.Layer
function M.switch_hint(l)
  local key = first_key('switch_layer')
  if not key or (l.is_head and not l.detached) then
    return nil
  end
  if not l.remote then
    return ('%s check out %s here'):format(key, l.name)
  end
  local short = l.state_branch ~= l.name and l.state_branch or l.name:match('^[^/]+/(.+)$') or l.name
  if l.local_copy then
    return ('%s switch to %s (tracks it)'):format(key, l.local_copy)
  elseif l.state_branch == l.name then
    return ('%s: a local %s exists; asks first'):format(key, short)
  end
  return ('%s creates local branch %s'):format(key, short)
end

---The `gS` hint under the layer row the panel cursor is on, while the panel has focus.
function M.update_hint(s)
  local buf = s.panel_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns_hint, 0, -1)
  local win = s.panel_win
  if not (win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_win() == win) then
    return
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local idx = s.panel_layers and s.panel_layers[row]
  local layer = type(idx) == 'number' and s.review.stack and s.review.stack.layers[idx]
  local text = layer and M.switch_hint(layer)
  if text then
    vim.api.nvim_buf_set_extmark(buf, ns_hint, row - 1, 0, {
      virt_lines = { { { '     ' .. text, 'Comment' } } },
    })
  end
end

---Key that opens the stack notes float (first one when several are mapped).
function M.notes_key()
  local k = require('revuey.config').options.keymaps.stack_notes
  if type(k) == 'table' then
    k = k[1]
  end
  return k or nil
end

---Stack notes as a few short summary lines grouped by kind (details: the notes float). Lines
---wrap rather than being cut; warnings (the diff shown is affected) use RevueyStackWarn, the
---rest RevueyStackNote. Returns the number of lines added.
function M.render_notes(s, add, width)
  local notes_mod = require('revuey.stack_notes')
  local notes, ignored, ctx = notes_mod.of_review(s.review, M.notes_key())
  local n = 0
  for _, l in ipairs(notes_mod.summary(notes, ignored, ctx, 3)) do
    local hl = l.level == 'warn' and 'RevueyStackWarn' or 'RevueyStackNote'
    -- first line ' ⚠ text', continuation lines indented under the text
    local first = wrap(l.glyph .. ' ' .. l.text, width, ' ')
    local out = { first[1] }
    if #first > 1 then
      local rest = l.text:sub(#first[1] - #l.glyph - 1)
      vim.list_extend(out, wrap(rest, width, '   '))
    end
    for _, line in ipairs(out) do
      add(line, { { 0, #line, hl } })
      n = n + 1
    end
  end
  return n
end

---@param s revuey.Session
---What the panel cursor is on: a file, a stack row, a guide section or the PR heading.
local function row_item(s, row)
  if s.panel_files and s.panel_files[row] then
    return 'file', s.panel_files[row]
  elseif s.panel_layers and s.panel_layers[row] then
    return 'layer', s.panel_layers[row]
  elseif s.panel_sections and s.panel_sections[row] then
    return 'section', s.panel_sections[row]
  elseif s.panel_forge and s.panel_forge.heading == row then
    return 'forge', true
  end
end

local function find_item(s, kind, id)
  local maps = { file = s.panel_files, layer = s.panel_layers, section = s.panel_sections }
  if kind == 'forge' then
    return s.panel_forge and s.panel_forge.heading
  end
  for row, v in pairs(maps[kind] or {}) do
    if v == id then
      return row
    end
  end
end

---Draw the panel. `o.keep_view`: a redraw nobody asked for (a background lookup finished): the
---panel cursor stays on the item it was on (rows added above move it down with the view), and
---is not moved to the diff's current file.
---@param o? {keep_view?:boolean}
function M.render(s, o)
  local buf = s.panel_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local win = s.panel_win
  local keep
  if o and o.keep_view and win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
    local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    local kind, id = row_item(s, view.lnum)
    keep = { view = view, kind = kind, id = id }
  end
  local r = s.review
  local lines, marks = {}, {}
  local function add(text, hls)
    lines[#lines + 1] = text
    marks[#lines] = hls or {}
    return #lines
  end
  local width = (s.panel_win and vim.api.nvim_win_is_valid(s.panel_win)) and vim.api.nvim_win_get_width(s.panel_win)
    or require('revuey.config').options.panel_width
  local function add_virt(row, virt)
    marks[row].virt = virt
  end
  s.panel_forge_any = false
  if r.stack then
    render_stack(s, add, add_virt, width)
  else
    s.panel_layers = nil
    -- suggestions for a lone branch (e.g. it may be built on an old version of another branch)
    if M.render_notes(s, add, width) > 0 then
      add('')
    end
  end
  -- the viewed layer's pull request (title, reviews, checks, base), when it has one
  forge_view.render_detail(s, add, add_virt, width)
  require('revuey.guide_view').panel(s, add, add_virt, width)
  -- the latest AI review of this scope: verdict, findings to triage, summary
  require('revuey.ai_review_view').panel(s, add, add_virt, width)
  local total_add, total_del, reviewed = 0, 0, 0
  for _, f in ipairs(r.files) do
    total_add, total_del = total_add + f.added, total_del + f.removed
    if review_mod.is_reviewed(r, f) then
      reviewed = reviewed + 1
    end
  end
  -- a plain review's pull request sits on its title line
  local pr_virt = not r.stack and forge_view.chunks(forge_view.pr(s, '')) or nil
  local pr_w = 0
  for _, v in ipairs(pr_virt or {}) do
    pr_w = pr_w + vim.fn.strdisplaywidth(v[1])
  end
  local title = M.truncate(' ' .. r.branch .. ' → ' .. r.base, width - pr_w)
  local title_row = add(title, { { 0, #title, 'RevueyPanelTitle' } })
  if pr_virt then
    add_virt(title_row, pr_virt)
    s.panel_forge = s.panel_forge or { rows = {} }
    s.panel_forge.rows[title_row] = forge_view.pr(s, '')
  end
  local stats = string.format(' %d files  ', #r.files)
  local adds = '+' .. total_add
  local dels = ' −' .. total_del
  local rev = string.format('  ✓ %d/%d', reviewed, #r.files)
  add(stats .. adds .. dels .. rev, {
    { #stats, #stats + #adds, 'RevueyCountAdd' },
    { #stats + #adds, #stats + #adds + #dels, 'RevueyCountDelete' },
    { #stats + #adds + #dels, #stats + #adds + #dels + #rev, reviewed == #r.files and 'RevueyReviewed' or 'Comment' },
  })
  local mb = ' base ' .. r.merge_base:sub(1, 8) .. '  head ' .. r.head:sub(1, 8)
  add(mb, { { 0, #mb, 'Comment' } })
  if r.stack and r.scope then
    local sc = r.scope.kind == 'full' and (' full stack (%d layers)'):format(#r.stack.layers)
      or (' layer %d/%d'):format(r.scope.index, #r.stack.layers)
    local layer = r.scope.kind == 'layer' and r.stack.layers[r.scope.index]
    local extra = layer and layer.detached and '  @ detached HEAD' or ''
    add(sc .. extra, { { 0, #sc, 'RevueyMode' }, { #sc, #sc + #extra, 'Comment' } })
  end
  local layer = r.stack and r.scope and r.scope.kind == 'layer' and r.stack.layers[r.scope.index]
  if r.mode_locked then
    local m, why = ' committed only', (layer and layer.remote) and '  (remote, read-only)' or '  (not HEAD)'
    add(m .. why, { { 0, #m, 'RevueyMode' }, { #m, #m + #why, 'Comment' } })
  elseif r.mode == 'worktree' then
    local m, legend = ' working tree', '  ● uncommitted'
    add(m .. legend, { { 0, #m, 'RevueyMode' }, { #m, #m + #legend, 'Comment' } })
  else
    local m = ' committed only'
    add(m, { { 0, #m, 'RevueyMode' } })
  end
  if r.mode ~= 'worktree' and r.dirty then
    local d = ' uncommitted changes not shown'
    add(d, { { 0, #d, 'DiagnosticWarn' } })
  end
  add('')
  s.panel_rows = {}
  s.panel_files = {}
  for fi, f in ipairs(r.files) do
    local ndone, ntotal = review_mod.file_progress(r, fi)
    local done = ntotal > 0 and ndone == ntotal
    local check = M.glyph(ndone, ntotal)
    local name = vim.fs.basename(f.path)
    local dir = vim.fs.dirname(f.path)
    dir = dir == '.' and '' or dir
    local dot = f.uncommitted and '●' or ' '
    local prefix = ' ' .. check .. ' ' .. f.status .. dot .. ' '
    local partial = (not done and ndone > 0) and (ndone .. '/' .. ntotal .. ' ') or ''
    local ncom = require('revuey.comments_view').count(s, f.path)
    local com = ncom > 0 and ('✎' .. ncom .. ' ') or ''
    local counts_text = com .. partial .. (f.binary and 'bin' or ('+' .. f.added .. ' −' .. f.removed))
    -- fit name + dir before the right-aligned counts
    local avail = width - vim.fn.strdisplaywidth(prefix) - vim.fn.strdisplaywidth(counts_text) - 2
    if vim.fn.strdisplaywidth(name) > avail then
      name = M.truncate(name, math.max(avail, 1))
      dir = ''
    else
      local dir_avail = avail - vim.fn.strdisplaywidth(name) - 2
      if dir_avail < 4 then
        dir = ''
      else
        dir = M.truncate(dir, dir_avail, true)
      end
    end
    local text = prefix .. name .. (dir ~= '' and ('  ' .. dir) or '')
    local status_col = 1 + #check + 1
    local hls = {
      { 1, 1 + #check, check == M.GLYPH_PARTIAL and 'RevueyPartial' or 'RevueyReviewed' },
      { status_col, status_col + 1, status_hl[f.status] or 'Normal' },
      { status_col + 1, status_col + 1 + #dot, 'RevueyUncommitted' },
      { #prefix, #prefix + #name, done and 'RevueyUnreviewed' or 'Normal' },
    }
    if dir ~= '' then
      hls[#hls + 1] = { #prefix + #name, #text, 'RevueyPanelDir' }
    end
    local row = add(text, hls)
    local counts = partial ~= '' and { { partial, 'RevueyPartial' } } or {}
    if com ~= '' then
      table.insert(counts, 1, { com, 'RevueyCommentSign' })
    end
    if f.binary then
      counts[#counts + 1] = { 'bin', 'Comment' }
    else
      counts[#counts + 1] = { '+' .. f.added, 'RevueyCountAdd' }
      counts[#counts + 1] = { ' −' .. f.removed, 'RevueyCountDelete' }
    end
    marks[row].virt = counts
    s.panel_rows[fi] = row
    s.panel_files[row] = fi
  end
  local orphans = require('revuey.comments_view').orphans(s)
  if orphans > 0 then
    local t = (' ✎%d on files no longer in this review'):format(orphans)
    add(t, { { 0, #t, 'RevueyCommentOutdated' } })
  end
  add('')
  -- the keys as configured (keys.line: `{option}` is its key; a disabled one leaves its part out)
  local keys = require('revuey.keys')
  local help
  local function from_templates(list)
    local out = {}
    for _, t in ipairs(list) do
      out[#out + 1] = keys.line(t)
    end
    return out
  end
  if s.view_mode == 'guide' then
    help = from_templates({
      ' {next_section} {prev_section} section  {toggle_reviewed} reviewed',
      ' {next_hunk} {prev_hunk} hunk  {toggle_fold} fold  {focus_panel} diff',
      ' {definition} def  {hover} hover  {open_file#2} open  {refresh} refresh',
      ' {toggle_guide} diff view  {regenerate_guide} regenerate  {close} close',
    })
    -- the guide's line notes, when it has some
    local res = s.guide and s.guide.resolved
    if res and (res.notes or 0) > 0 then
      local parts = {}
      local nx, pk, nt = first_key('next_note'), first_key('prev_note'), first_key('toggle_notes')
      if nx or pk then
        parts[#parts + 1] = ((nx and pk) and (nx .. ' ' .. pk) or (nx or pk)) .. ' line note'
      end
      if nt then
        parts[#parts + 1] = nt .. ' show/collapse'
      end
      if #parts > 0 then
        help[#help + 1] = ' ' .. table.concat(parts, '  ')
      end
    end
  else
    help = from_templates({
      ' <CR> show  {toggle_reviewed} reviewed  {focus_panel} diff',
      ' {next_hunk} {prev_hunk} hunk  {next_file} {prev_file} file  {toggle_fold} fold',
      ' {definition} def  {hover} hover  {open_file#2} open  {refresh} refresh',
      ' {toggle_mode} committed/working tree  {close} close',
      ' {toggle_guide} AI guide',
    })
  end
  local nk = M.notes_key()
  local has_notes = nk and (#(r.stack and r.stack.notes or r.notes or {}) > 0 or #(r.stack and r.stack.ignored or r.notes_ignored or {}) > 0)
  if r.stack then
    help[#help + 1] = keys.line(' {next_layer} {prev_layer} layer  {toggle_stack} full stack' .. (has_notes and ('  ' .. nk .. ' notes') or ''))
    local sk = first_key('switch_layer')
    if sk then
      help[#help + 1] = ' ' .. sk .. ' check out layer'
    end
  elseif has_notes then
    help[#help + 1] = ' ' .. nk .. ' branch notes'
  end
  if s.panel_forge or s.panel_forge_any then
    local ok = require('revuey.config').options.keymaps.forge_open
    ok = type(ok) == 'table' and ok[1] or ok
    if ok then
      help[#help + 1] = ' ' .. ok .. ' PR in browser' .. (s.panel_forge and s.panel_forge.heading and '  <Tab> PR details' or '')
    end
  end
  -- any scope with threads (full stack, a collapsed PR section too)
  local tk = require('revuey.config').options.keymaps.forge_threads
  tk = type(tk) == 'table' and tk[1] or tk
  if tk and forge_view.has_threads(s) then
    help[#help + 1] = ' ' .. tk .. ' GitHub threads (all/open/none)'
  end
  -- posting to GitHub: whenever the scope has an open PR (a verdict alone needs no comment),
  -- with the comments added to the review
  local sk = require('revuey.config').options.keymaps.forge_submit
  sk = type(sk) == 'table' and sk[1] or sk
  local fpv = require('revuey.forge_post_view')
  if sk and forge_view.enabled() and #fpv.scope_targets(s) > 0 then
    local n_review = s.cm and s.cm.store and fpv.count(s.cm.store) or 0
    help[#help + 1] = (' %s submit review'):format(sk) .. (n_review > 0 and (' (%d in review)'):format(n_review) or '')
  end
  -- every other key: the g? float (the winbar names the keys of the comment under the cursor)
  help[#help + 1] = keys.line(' {help} all keys')
  for _, h in ipairs(help) do
    add(h, { { 0, #h, 'Comment' } })
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for row, hls in pairs(marks) do
    for _, h in ipairs(hls) do
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, row - 1, h[1], { end_col = h[2], hl_group = h[3] })
    end
    if hls.virt then
      vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, { virt_text = hls.virt, virt_text_pos = 'right_align' })
    end
  end
  if s.view_mode == 'guide' then
    M.set_current_section(s, s.current_section)
  else
    M.set_current(s, s.current_file or 1)
  end
  if keep then
    local view = keep.view
    local row = keep.kind and find_item(s, keep.kind, keep.id) or view.lnum
    row = math.max(1, math.min(row, vim.api.nvim_buf_line_count(buf)))
    view.topline = math.max(1, view.topline + (row - view.lnum))
    view.lnum = row
    s.syncing = true
    pcall(vim.api.nvim_win_call, win, function()
      vim.fn.winrestview(view)
    end)
    s.syncing = false
  end
  M.update_hint(s)
  if s.forge then
    s.forge.drawn = forge_view.signature(s)
  end
  -- the notes float follows the review (after an action, a refresh, a branch moved elsewhere)
  require('revuey.notes_float').update(s)
end

---Highlight the guide section the cursor is in (and move the panel cursor to it).
function M.set_current_section(s, si)
  s.current_section = si
  local buf = s.panel_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns_sec, 0, -1)
  for row, idx in pairs(s.panel_sections or {}) do
    if idx == si then
      vim.api.nvim_buf_set_extmark(buf, ns_sec, row - 1, 0, { line_hl_group = 'RevueyPanelCurrent', priority = 1 })
      if s.panel_win and vim.api.nvim_win_is_valid(s.panel_win) and vim.api.nvim_get_current_win() ~= s.panel_win then
        s.syncing = true
        pcall(vim.api.nvim_win_set_cursor, s.panel_win, { row, 0 })
        s.syncing = false
      end
    end
  end
end

---Highlight the file currently shown in the diff window.
function M.set_current(s, fi)
  s.current_file = fi
  local buf = s.panel_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns_cur, 0, -1)
  local row = s.panel_rows and s.panel_rows[fi]
  if row then
    vim.api.nvim_buf_set_extmark(buf, ns_cur, row - 1, 0, { line_hl_group = 'RevueyPanelCurrent', priority = 1 })
    if s.panel_win and vim.api.nvim_win_is_valid(s.panel_win) and vim.api.nvim_get_current_win() ~= s.panel_win then
      s.syncing = true
      pcall(vim.api.nvim_win_set_cursor, s.panel_win, { row, 0 })
      s.syncing = false
    end
  end
end

return M
