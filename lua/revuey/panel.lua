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
  local total_add, total_del, reviewed = 0, 0, 0
  for _, f in ipairs(r.files) do
    total_add, total_del = total_add + f.added, total_del + f.removed
    if review_mod.is_reviewed(r, f) then
      reviewed = reviewed + 1
    end
  end
  local title = ' ' .. r.branch .. ' → ' .. r.base
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
  if r.mode == 'worktree' then
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
      name = vim.fn.strcharpart(name, 0, math.max(avail - 1, 1)) .. '…'
      dir = ''
    else
      local dir_avail = avail - vim.fn.strdisplaywidth(name) - 2
      if dir_avail < 4 then
        dir = ''
      elseif vim.fn.strdisplaywidth(dir) > dir_avail then
        local n = vim.fn.strchars(dir)
        dir = '…' .. vim.fn.strcharpart(dir, n - (dir_avail - 1))
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
