-- File panel: list of changed files with status, +/- counts and reviewed checkmarks.
local review_mod = require('revuey.review')

local M = {}

local ns = vim.api.nvim_create_namespace('revuey.panel')
local ns_cur = vim.api.nvim_create_namespace('revuey.panel.current')

local status_hl = {
  A = 'RevueyStatusAdded',
  D = 'RevueyStatusDeleted',
  M = 'RevueyStatusModified',
  R = 'RevueyStatusRenamed',
  T = 'RevueyStatusModified',
}
M.status_hl = status_hl

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

---Wrap `text` to `width` display cells (word boundaries), each line prefixed with `indent`.
local function wrap(text, width, indent)
  local out, line = {}, indent
  for word in text:gmatch('%S+') do
    if line ~= indent and vim.fn.strdisplaywidth(line .. ' ' .. word) > width then
      out[#out + 1] = line
      line = indent .. word
    else
      line = line == indent and (indent .. word) or (line .. ' ' .. word)
    end
  end
  if line ~= indent then
    out[#out + 1] = line
  end
  return out
end

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
    local vw = 0
    for _, v in ipairs(virt) do
      vw = vw + vim.fn.strdisplaywidth(v[1])
    end
    local avail = width - vim.fn.strdisplaywidth(prefix) - vw - 1
    name = M.truncate(name, math.max(avail, 1))
    local text = prefix .. name
    local row = add(text, {
      { 1, 1 + #sel, 'RevueyMode' },
      { 1 + #sel, 1 + #sel + #head, 'RevueyUncommitted' },
      { #prefix, #text, l.dimmed and 'Comment' or (selected and 'RevueyPanelTitle' or 'Normal') },
    })
    s.panel_layers[row] = i
    add_virt(row, virt)
  end
  local full_sel = scope.kind == 'full'
  local text = ' ' .. (full_sel and '▶' or ' ') .. '  full stack'
  local row = add(text, { { 1, 1 + (full_sel and #'▶' or 1), 'RevueyMode' }, { #text - #'full stack', #text, full_sel and 'RevueyPanelTitle' or 'Comment' } })
  s.panel_layers[row] = 'full'
  add_virt(row, stats_virt(stack.full_stats, full_sel and live or nil))
  local notes = stack.notes or {}
  local max_notes = 4
  for k, n in ipairs(notes) do
    if k > max_notes then
      local more = ('   … %d more note%s'):format(#notes - max_notes, #notes - max_notes == 1 and '' or 's')
      add(more, { { 0, #more, 'DiagnosticWarn' } })
      break
    end
    local lines = wrap(n, width - 1, '   ')
    for li, line in ipairs(lines) do
      if li > 3 then
        break -- very long notes stay short; names are capped already
      end
      line = M.truncate(line, width - 1)
      add(line, { { 0, #line, 'DiagnosticWarn' } })
    end
  end
  add('')
end

---@param s revuey.Session
function M.render(s)
  local buf = s.panel_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
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
  if r.stack then
    render_stack(s, add, add_virt, width)
  else
    s.panel_layers = nil
    -- suggestions for a lone branch (e.g. it may be built on an old version of another branch)
    for _, n in ipairs(r.notes or {}) do
      for li, line in ipairs(wrap(n, width - 1, ' ')) do
        if li <= 4 then
          line = M.truncate(line, width - 1)
          add(line, { { 0, #line, 'DiagnosticWarn' } })
        end
      end
    end
    if r.notes and #r.notes > 0 then
      add('')
    end
  end
  local total_add, total_del, reviewed = 0, 0, 0
  for _, f in ipairs(r.files) do
    total_add, total_del = total_add + f.added, total_del + f.removed
    if review_mod.is_reviewed(r, f) then
      reviewed = reviewed + 1
    end
  end
  local title = M.truncate(' ' .. r.branch .. ' → ' .. r.base, width)
  add(title, { { 0, #title, 'RevueyPanelTitle' } })
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
    add(sc, { { 0, #sc, 'RevueyMode' } })
  end
  if r.mode_locked then
    local m, why = ' committed only', '  (not HEAD)'
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
    local done = review_mod.is_reviewed(r, f)
    local check = done and '✓' or ' '
    local name = vim.fs.basename(f.path)
    local dir = vim.fs.dirname(f.path)
    dir = dir == '.' and '' or dir
    local dot = f.uncommitted and '●' or ' '
    local prefix = ' ' .. check .. ' ' .. f.status .. dot .. ' '
    local counts_text = f.binary and 'bin' or ('+' .. f.added .. ' −' .. f.removed)
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
      { 1, 1 + #check, 'RevueyReviewed' },
      { status_col, status_col + 1, status_hl[f.status] or 'Normal' },
      { status_col + 1, status_col + 1 + #dot, 'RevueyUncommitted' },
      { #prefix, #prefix + #name, done and 'RevueyUnreviewed' or 'Normal' },
    }
    if dir ~= '' then
      hls[#hls + 1] = { #prefix + #name, #text, 'RevueyPanelDir' }
    end
    local row = add(text, hls)
    local counts
    if f.binary then
      counts = { { 'bin', 'Comment' } }
    else
      counts = { { '+' .. f.added, 'RevueyCountAdd' }, { ' −' .. f.removed, 'RevueyCountDelete' } }
    end
    marks[row].virt = counts
    s.panel_rows[fi] = row
    s.panel_files[row] = fi
  end
  add('')
  local help = {
    ' <CR> show  mr reviewed  gp diff',
    ' ]c [c hunk  ]f [f file  za fold',
    ' gd def  K hover  go open  R refresh',
    ' gu committed/working tree  q close',
  }
  if r.stack then
    help[#help + 1] = ' ]s [s layer  gs full stack'
  end
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
  M.set_current(s, s.current_file or 1)
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
