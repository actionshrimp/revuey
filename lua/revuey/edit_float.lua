-- The edit float: the real working-tree file in a floating window over the review, folded to the
-- hunk plus a little context. It is the file's one buffer, the same one `:edit` gives (revuey's
-- hidden LSP buffer handed over to the user when it had loaded it), so undo, LSP, completion,
-- formatters, swap files, the user's autocmds and `:checktime` behave as anywhere else. Saving
-- goes through the normal BufWritePost, which the review's working-tree auto-refresh picks up.
--
-- Nothing leaks into the user's other windows: folds are manual and local to the float, and the
-- float's window options and folds are reset before it closes (Neovim copies a closing window's
-- options and folds to the next window that shows the buffer). The close keys are buffer-local
-- (Neovim has no window-local mappings) but only act in the float; elsewhere they fall through,
-- and they are removed (and any mapping they shadowed restored) when the float closes.
local api = vim.api
local edit = require('revuey.edit')
local lsp = require('revuey.lsp')

local M = {}

---@class revuey.EditFloat
---@field win integer
---@field buf integer
---@field path string repo-relative path
---@field session table
---@field seq integer undo sequence when opened (discard goes back to it)
---@field was_modified boolean
---@field saved_maps table[]
---@field group integer

---@type revuey.EditFloat?
M.current = nil

---Question with choices (a hook so tests can answer it): returns 1 save, 2 discard, else cancel.
function M.ask(msg)
  return vim.fn.confirm(msg, '&Save\n&Discard\n&Cancel', 1, 'Question')
end

-- window options the float sets (put back to the window's own values before it closes)
local WIN_OPTS = {
  foldmethod = 'manual',
  foldenable = true,
  foldlevel = 0,
  foldcolumn = '0',
  number = true,
  relativenumber = false,
  cursorline = true,
  signcolumn = 'auto',
  wrap = false,
  winfixbuf = false,
}

-- window options the review sets on its diff window (see view.show)
local REVIEW_OPTS = {
  'statuscolumn', 'winbar', 'foldexpr', 'foldtext', 'foldmethod', 'foldlevel', 'foldminlines', 'foldcolumn',
  'fillchars', 'list', 'spell', 'conceallevel', 'cursorline', 'wrap', 'number', 'relativenumber', 'signcolumn',
}

local MAPS = {
  { 'n', 'q', 'close' },
  { 'n', '<C-s>', 'save' }, -- normal mode only: insert-mode <C-s> is signature help
}
local DESC = 'revuey: edit float '

---Is the buffer-local mapping of `lhs` in `mode` one the float made?
local function ours(buf, mode, lhs)
  local d = api.nvim_buf_call(buf, function()
    return vim.fn.maparg(lhs, mode, false, true)
  end)
  return type(d) == 'table' and d.buffer == 1 and type(d.desc) == 'string' and d.desc:sub(1, #DESC) == DESC
end

local function valid(st)
  return st and api.nvim_win_is_valid(st.win) and api.nvim_buf_is_valid(st.buf)
end

---Undo the float's own changes (not edits the buffer already had when it opened).
local function discard(st)
  api.nvim_buf_call(st.buf, function()
    pcall(vim.cmd, 'silent undo ' .. st.seq)
    if not st.was_modified and vim.bo[st.buf].modified then
      pcall(vim.cmd, 'silent edit!')
    end
  end)
end

---Write the buffer (as `:w` would). Returns false when the write failed.
local function write(st)
  local ok, err = pcall(api.nvim_buf_call, st.buf, function()
    vim.cmd('write')
  end)
  if not ok then
    vim.notify('revuey: ' .. tostring(err):gsub('^Vim:', ''), vim.log.levels.ERROR)
  end
  return ok and not vim.bo[st.buf].modified
end

---Restore what the float changed: its window options and folds (so the next window showing the
---buffer doesn't inherit them), the shadowed buffer mappings, its autocmds.
local function teardown(st)
  if st.torn then
    return
  end
  st.torn = true
  if api.nvim_win_is_valid(st.win) then
    api.nvim_win_call(st.win, function()
      pcall(vim.cmd, 'normal! zE')
      for name in pairs(WIN_OPTS) do
        local v = (st.saved_opts or {})[name]
        if v == nil then
          v = api.nvim_get_option_value(name, { scope = 'global' })
        end
        pcall(api.nvim_set_option_value, name, v, { scope = 'local', win = st.win })
      end
    end)
  end
  if api.nvim_buf_is_valid(st.buf) then
    -- only the float's own mappings (one set since by the user or an LspAttach handler stays)
    local removed = {}
    for _, m in ipairs(MAPS) do
      if ours(st.buf, m[1], m[2]) then
        pcall(vim.keymap.del, m[1], m[2], { buffer = st.buf })
        removed[m[1] .. m[2]] = true
      end
    end
    -- and the mappings ours shadowed come back (where ours was still the one in place)
    for _, saved in ipairs(st.saved_maps) do
      if removed[saved.mode_key] then
        api.nvim_buf_call(st.buf, function()
          pcall(vim.fn.mapset, saved.dict)
        end)
      end
    end
  end
  pcall(api.nvim_del_augroup_by_id, st.group)
  if M.current == st then
    M.current = nil
  end
end

---Close the float. With unsaved changes, asks first: save, discard or cancel (`force` skips the
---question and keeps the changes in the buffer, as `:q` would with 'hidden').
---@return boolean closed
function M.close(o)
  o = o or {}
  local st = M.current
  if not valid(st) then
    if st then
      teardown(st)
    end
    return true
  end
  if not o.force and vim.bo[st.buf].modified then
    local choice = M.ask(('Save changes to %s?'):format(st.path))
    if choice == 1 then
      if not write(st) then
        return false
      end
    elseif choice == 2 then
      discard(st)
    else
      return false
    end
  end
  local s = st.session
  teardown(st)
  pcall(api.nvim_win_close, st.win, true)
  if s and s.diff_win and api.nvim_win_is_valid(s.diff_win) then
    api.nvim_set_current_win(s.diff_win)
  end
  return true
end

---The review `s` is going away: close its float without asking (unsaved changes stay in the
---buffer, as with `:q` and 'hidden').
function M.detach(s)
  local st = M.current
  if st and st.session == s then
    teardown(st)
    pcall(api.nvim_win_close, st.win, true)
  end
end

local function remember_maps(buf)
  local saved = {}
  for _, m in ipairs(MAPS) do
    for _, km in ipairs(api.nvim_buf_get_keymap(buf, m[1])) do
      if km.lhs == vim.keycode(m[2]) or km.lhs == m[2] then
        local d = api.nvim_buf_call(buf, function()
          return vim.fn.maparg(m[2], m[1], false, true)
        end)
        if type(d) == 'table' and d.buffer == 1 then
          saved[#saved + 1] = { mode_key = m[1] .. m[2], dict = d }
        end
      end
    end
  end
  return saved
end

local function set_maps(st)
  for _, m in ipairs(MAPS) do
    local mode, lhs, what = m[1], m[2], m[3]
    vim.keymap.set(mode, lhs, function()
      if not (M.current == st and api.nvim_get_current_win() == st.win) then
        return vim.keycode(lhs) -- another window showing this buffer: the key as usual
      end
      vim.schedule(function()
        if what == 'close' then
          M.close()
        elseif valid(st) then
          write(st)
        end
      end)
      return '<Ignore>'
    end, { buffer = st.buf, expr = true, nowait = true, silent = true, desc = DESC .. what })
  end
end

---Size and place the float near the diff window's cursor: below it when there is room, else
---above it.
local function geometry(s, wanted)
  local win = s.diff_win
  local wh, ww = api.nvim_win_get_height(win), api.nvim_win_get_width(win)
  local width = math.max(20, math.min(ww - 2, 120))
  local crow = api.nvim_win_call(win, function()
    return vim.fn.winline()
  end)
  -- room for the text (the border takes two rows) below and above the cursor line
  local below, above = wh - crow - 2, crow - 3
  local height = math.max(3, math.min(wanted, math.floor(wh * 0.6)))
  local row
  if height <= below then
    row = crow -- the line below the cursor
  elseif height <= above then
    row = crow - height - 3
  elseif below >= above and below >= 3 then
    row, height = crow, below
  elseif above >= 3 then
    row, height = 0, above
  else
    row = 0 -- a tiny window: cover the cursor line
  end
  return { relative = 'win', win = win, row = row, col = 0, width = width, height = height }
end

---Open the float on `opts.abs` at the snapshot line `opts.lnum`, folded to the snapshot hunk
---range `opts.lo`..`opts.hi` (all mapped through edits made since the review was loaded).
---@param s table review session
---@param opts {abs:string, path:string, snapshot?:string, lnum:integer, lo:integer, hi:integer, col?:integer, note?:string}
---@return integer? win
function M.open(s, opts)
  if M.current and not M.close() then
    return nil
  end
  if not vim.uv.fs_stat(opts.abs) then
    vim.notify('revuey: not in the working tree: ' .. opts.path, vim.log.levels.WARN)
    return nil
  end
  -- the file's one buffer: an open one (by exact name or resolved path), else revuey's hidden
  -- LSP buffer, else a new one; never a second buffer for the same file
  local buf = lsp.buffer_for(opts.abs)
  local fresh = buf == nil
  buf = buf or vim.fn.bufadd(opts.abs)
  if not api.nvim_buf_is_loaded(buf) then
    -- another Neovim editing the file: E325 (an error without a UI to ask on)
    local ok, err = pcall(vim.fn.bufload, buf)
    if not ok then
      if fresh or not vim.bo[buf].buflisted then
        pcall(api.nvim_buf_delete, buf, { force = true })
      else
        pcall(api.nvim_buf_delete, buf, { force = true, unload = true })
      end
      local swap = tostring(err):find('E325', 1, true)
      vim.notify(
        swap and ('revuey: another Neovim is editing %s (it has a swap file); not opening it'):format(opts.path)
          or ('revuey: cannot open %s: %s'):format(opts.path, tostring(err)),
        vim.log.levels.WARN
      )
      return nil
    end
  end
  if vim.bo[buf].filetype == '' then
    local ft = vim.filetype.match({ buf = buf, filename = opts.abs })
    if ft then
      vim.bo[buf].filetype = ft -- FileType: the user's LSP config attaches
    end
  end
  lsp.adopt(buf)
  local current = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n') .. '\n'
  local count = api.nvim_buf_line_count(buf)
  local lnum = edit.map_line(opts.snapshot, current, opts.lnum)
  local lo = edit.map_line(opts.snapshot, current, opts.lo)
  local hi = math.max(lo, edit.map_line(opts.snapshot, current, opts.hi))
  local top, bottom = edit.view_range(lo, hi, count)
  local folds = (top > 1 and 1 or 0) + (bottom < count and 1 or 0)
  local cfg = geometry(s, bottom - top + 1 + folds)
  cfg.border = 'rounded'
  cfg.title = { { (' %s:%d-%d '):format(opts.path, lo, hi), 'FloatTitle' } }
  cfg.title_pos = 'left'
  cfg.footer = { { ' :w save · q close ', 'FloatFooter' } } -- (<C-s> saves too)
  cfg.footer_pos = 'right'
  local st = {
    buf = buf,
    path = opts.path,
    session = s,
    was_modified = vim.bo[buf].modified,
    seq = api.nvim_buf_call(buf, function()
      return vim.fn.changenr()
    end),
    saved_maps = remember_maps(buf),
    lo = lo,
    hi = hi,
  }
  st.win = api.nvim_open_win(buf, true, cfg)
  M.current = st
  -- A new window copies the current window's options unless the buffer brings its own, so a
  -- buffer never shown before would get the review's (statuscolumn, winbar, foldexpr...), and
  -- keep them in the next window after the float: those are put back to the global values.
  for _, name in ipairs(REVIEW_OPTS) do
    local mine = api.nvim_get_option_value(name, { scope = 'local', win = st.win })
    local global = api.nvim_get_option_value(name, { scope = 'global' })
    if mine ~= global and mine == api.nvim_get_option_value(name, { scope = 'local', win = s.diff_win }) then
      api.nvim_set_option_value(name, global, { scope = 'local', win = st.win })
    end
  end
  -- what the window got from the buffer (its last window's options), put back on close
  st.saved_opts = {}
  for name, value in pairs(WIN_OPTS) do
    st.saved_opts[name] = api.nvim_get_option_value(name, { scope = 'local', win = st.win })
    api.nvim_set_option_value(name, value, { scope = 'local', win = st.win })
  end
  api.nvim_win_call(st.win, function()
    vim.cmd('normal! zE')
    if bottom < count then
      vim.cmd(('%d,%dfold'):format(bottom + 1, count))
    end
    if top > 1 then
      vim.cmd(('1,%dfold'):format(top - 1))
    end
    api.nvim_win_set_cursor(st.win, { lnum, opts.col or 0 })
    vim.fn.winrestview({ topline = top > 1 and top - 1 or 1 })
  end)
  set_maps(st)
  st.group = api.nvim_create_augroup('revuey_edit_float_' .. st.win, { clear = true })
  -- `:q`, `<C-w>c` and friends: tidy up as the window goes (it is still valid here)
  api.nvim_create_autocmd('WinClosed', {
    group = st.group,
    pattern = tostring(st.win),
    callback = function()
      teardown(st)
    end,
  })
  -- after a save, the review refresh puts its cursor on the hunk being edited
  api.nvim_create_autocmd('BufWritePost', {
    group = st.group,
    buffer = buf,
    callback = function()
      if valid(st) then
        s.edit_focus = { path = opts.path, lnum = api.nvim_win_get_cursor(st.win)[1] }
      end
    end,
  })
  if opts.note then
    vim.notify(opts.note, vim.log.levels.INFO)
  end
  return st.win
end

return M
