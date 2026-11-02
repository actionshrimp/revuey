-- A list over the diff window: the float the comments view (comments_list.lua) and the agent
-- reviews view (ai_reviews_view.lua) are drawn in. A float relative to the diff window, below its
-- winbar, its full size, so the diff or guide underneath keeps its cursor, folds and scroll.
--
-- A host gives a spec: {field (the session key holding the view, `s.clist`), last (where the
-- item under the cursor is remembered for the next open), name, filetype, ns, build(s, width) ->
-- lines (each {chunks, id?, start?, kind?}: `id` the item or group the line belongs to, `start`
-- its first line, `kind = 'group'` a group's header), after_render?(s, v, lines, extra),
-- keymaps(s, v)}. Only one list is open at a time: opening one closes another.
local api = vim.api

local M = {}

-- Above the stack tree (40, its footer 41), so a list opened from inside the tree shows; below
-- the comment editor and other floats (50 and up).
M.ZINDEX = 45

M.FIELDS = { 'clist', 'arlist' }

---The open view in `s[field]`, when its window and buffer are still there.
function M.valid(s, field)
  local v = s and s[field]
  return v and api.nvim_win_is_valid(v.win) and api.nvim_buf_is_valid(v.buf) and v or nil
end

---Where the view goes: the diff window's text area (a float relative to a window starts below
---its winbar).
local function geometry(s)
  local w, hgt = api.nvim_win_get_width(s.diff_win), api.nvim_win_get_height(s.diff_win)
  local info = vim.fn.getwininfo(s.diff_win)[1]
  hgt = hgt - ((info and info.winbar) or 0)
  return { relative = 'win', win = s.diff_win, row = 0, col = 0, width = w, height = math.max(hgt, 1) }
end

function M.redraw_winbar(s)
  if #api.nvim_list_uis() > 0 and s.diff_win and api.nvim_win_is_valid(s.diff_win) then
    pcall(api.nvim__redraw, { win = s.diff_win, winbar = true })
  end
end

---The item (or group header) under the view's cursor: its id, first and last rows, the row.
function M.at_cursor(v)
  local row = api.nvim_win_get_cursor(v.win)[1]
  local id = v.rows[row]
  if not id then
    return nil
  end
  local r = v.blocks[id]
  return id, r.first, r.last, row
end

---Draw `spec.build`'s lines into the view's buffer. The cursor stays on the item it was on, at
---the same line of it (the next item when it went).
function M.render(s, spec)
  local v = M.valid(s, spec.field)
  if not v or v.rendering then
    return
  end
  v.rendering = true
  local ok, err = pcall(function()
    local id, first, _, row = M.at_cursor(v)
    local keep = id and { id = id, off = row - first, index = v.order_index and v.order_index[id] }
    local width = api.nvim_win_get_width(v.win) - 1
    local lines, extra = spec.build(s, width, v)
    local texts, rows, blocks, order, order_index, groups = {}, {}, {}, {}, {}, {}
    local all = {}
    for i, l in ipairs(lines) do
      local t = {}
      for _, ch in ipairs(l.chunks) do
        t[#t + 1] = ch[1]
      end
      texts[i] = table.concat(t)
      if l.id then
        rows[i] = l.id
        if l.start then
          blocks[l.id] = { first = i, last = i, kind = l.kind }
          all[#all + 1] = l.id
          if l.kind == 'group' then
            groups[#groups + 1] = l.id
          else
            order[#order + 1] = l.id
          end
          order_index[l.id] = #all
        end
        blocks[l.id].last = i
      end
    end
    vim.bo[v.buf].modifiable = true
    api.nvim_buf_set_lines(v.buf, 0, -1, false, texts)
    vim.bo[v.buf].modifiable = false
    api.nvim_buf_clear_namespace(v.buf, spec.ns, 0, -1)
    for i, l in ipairs(lines) do
      local col = 0
      for _, ch in ipairs(l.chunks) do
        local len = #ch[1]
        local hl = ch[2]
        if len > 0 and hl then
          for pri, g in ipairs(type(hl) == 'table' and hl or { hl }) do
            pcall(api.nvim_buf_set_extmark, v.buf, spec.ns, i - 1, col, { end_col = col + len, hl_group = g, priority = 100 + pri })
          end
        end
        col = col + len
      end
    end
    v.rows, v.blocks, v.order, v.order_index, v.groups, v.all = rows, blocks, order, order_index, groups, all
    -- the cursor: same item and line of it, else the item now at its place, else the first
    local target
    if keep then
      local b = blocks[keep.id]
      if b then
        target = math.min(b.first + keep.off, b.last)
      elseif keep.index and #all > 0 then
        target = blocks[all[math.min(keep.index, #all)]].first
      end
    elseif v.want then
      local b = blocks[v.want]
      target = b and b.first
    end
    if not target and not keep then
      local firsts = order[1] or all[1]
      target = firsts and blocks[firsts].first
    end
    v.want = nil
    if target then
      pcall(api.nvim_win_set_cursor, v.win, { target, 0 })
    end
    if spec.after_render then
      spec.after_render(s, v, lines, extra)
    end
  end)
  v.rendering = false
  v.hint_id = (M.at_cursor(v))
  M.redraw_winbar(s)
  if not ok then
    error(err, 0)
  end
end

---The next or previous start of an item (`kind` 'item', default) or a group header ('group') in
---the view (takes a count). Inside one, backwards goes to its start first; past the last (before
---the first) nothing moves.
function M.next(s, field, dir, kind)
  local v = M.valid(s, field)
  local list = v and (kind == 'group' and v.groups or v.order)
  if not v or not list or #list == 0 then
    return
  end
  local row = api.nvim_win_get_cursor(v.win)[1]
  local target
  for _ = 1, vim.v.count1 do
    local t
    if dir > 0 then
      for _, x in ipairs(list) do
        if v.blocks[x].first > row then
          t = v.blocks[x].first
          break
        end
      end
    else
      for i = #list, 1, -1 do
        if v.blocks[list[i]].first < row then
          t = v.blocks[list[i]].first
          break
        end
      end
    end
    if not t then
      break
    end
    row, target = t, t
  end
  if target then
    api.nvim_win_set_cursor(v.win, { target, 0 })
  end
end

---Close the view; the diff (or guide) below is as it was. Focus goes back to the window it was
---opened from while that is still there (the panel, the stack tree's float), else to the diff.
---Remembers the item under the cursor for the next open.
---`quiet`: another list replaces it (no focus change, no panel render).
function M.close(s, spec, quiet)
  local v = s and s[spec.field]
  if not v then
    return
  end
  if api.nvim_win_is_valid(v.win) and api.nvim_buf_is_valid(v.buf) then
    s[spec.last] = M.at_cursor(v) or s[spec.last]
  end
  s[spec.field] = nil
  if v.group then
    pcall(api.nvim_del_augroup_by_id, v.group)
  end
  if api.nvim_win_is_valid(v.win) then
    pcall(api.nvim_win_close, v.win, true)
  end
  if api.nvim_buf_is_valid(v.buf) then
    pcall(api.nvim_buf_delete, v.buf, { force = true })
  end
  if not s.cleaned and not quiet then
    local back = v.from and v.from ~= v.win and api.nvim_win_is_valid(v.from) and v.from or s.diff_win
    if back and api.nvim_win_is_valid(back) then
      pcall(api.nvim_set_current_win, back)
    end
    require('revuey.panel').render(s)
    M.redraw_winbar(s)
  end
end

---Open the view over the diff window (focus it when open). Another open list is closed first,
---its focus target kept.
function M.open(s, spec)
  if not s then
    return vim.notify('revuey: no review open', vim.log.levels.WARN)
  end
  local v = M.valid(s, spec.field)
  if v then
    api.nvim_set_current_win(v.win)
    return v
  end
  if not (s.diff_win and api.nvim_win_is_valid(s.diff_win)) then
    return
  end
  local from = api.nvim_get_current_win()
  for _, f in ipairs(M.FIELDS) do
    local other = f ~= spec.field and M.valid(s, f)
    if other then
      if from == other.win then
        from = other.from
      end
      local host = f == 'clist' and require('revuey.comments_list') or require('revuey.ai_reviews_view')
      host.close(s, true)
    end
  end
  require('revuey.highlights').setup()
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = spec.filetype
  pcall(api.nvim_buf_set_name, buf, spec.name)
  local win = api.nvim_open_win(buf, true, vim.tbl_extend('force', geometry(s), { style = 'minimal', border = 'none', zindex = M.ZINDEX }))
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].scrolloff = 3
  vim.wo[win].winhighlight = 'NormalFloat:Normal'
  v = { buf = buf, win = win, from = from, rows = {}, blocks = {}, order = {}, order_index = {}, groups = {}, all = {}, cut = {}, want = s[spec.last] }
  s[spec.field] = v
  spec.keymaps(s, v)
  local group = api.nvim_create_augroup(spec.augroup .. buf, { clear = true })
  v.group = group
  api.nvim_create_autocmd('CursorMoved', {
    group = group,
    buffer = buf,
    callback = function()
      -- the hint follows the item under the cursor: redraw only when that changed (a render
      -- redraws it anyway)
      local id = M.at_cursor(v)
      if id ~= v.hint_id then
        v.hint_id = id
        M.redraw_winbar(s)
      end
    end,
  })
  -- the diff window resized (the screen, the panel): the view follows it, wrapped again
  api.nvim_create_autocmd({ 'VimResized', 'WinResized' }, {
    group = group,
    callback = function()
      local cur = M.valid(s, spec.field)
      if cur and cur.buf == buf and api.nvim_win_is_valid(s.diff_win) then
        local g = geometry(s)
        local wide = g.width ~= api.nvim_win_get_width(cur.win)
        api.nvim_win_set_config(cur.win, g)
        if wide then
          M.render(s, spec)
        end
      end
    end,
  })
  -- the diff window hidden below must never take the keys: entering it (the panel's focus key,
  -- a closed float) goes to the view
  api.nvim_create_autocmd('WinEnter', {
    group = group,
    callback = function()
      if api.nvim_get_current_win() == s.diff_win and M.valid(s, spec.field) and M.valid(s, spec.field).buf == buf then
        vim.schedule(function()
          if M.valid(s, spec.field) and M.valid(s, spec.field).buf == buf and api.nvim_get_current_win() == s.diff_win then
            api.nvim_set_current_win(win)
          end
        end)
      end
    end,
  })
  api.nvim_create_autocmd({ 'BufWipeout', 'WinClosed' }, {
    group = group,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if s[spec.field] == v then
          M.close(s, spec)
        end
      end)
    end,
  })
  M.render(s, spec)
  require('revuey.panel').render(s)
  return v
end

---The map helper of a view's keymaps: `lhs` a key or a list (nil: disabled).
function M.mapper(v)
  return function(lhs, fn, desc)
    if not lhs then
      return
    end
    for _, l in ipairs(type(lhs) == 'table' and lhs or { lhs }) do
      vim.keymap.set('n', l, fn, { buffer = v.buf, nowait = true, silent = true, desc = 'revuey: ' .. desc })
    end
  end
end

---The keys every list over the diff has: refresh, scope and layers, help, the panel.
function M.common_keys(s, map)
  local k = require('revuey.config').options.keymaps
  local view = require('revuey.view')
  map(k.refresh, function()
    view.refresh({ force = true, notify = true, forge = true })
  end, 'refresh review')
  map(k.toggle_stack, view.toggle_full, 'toggle full stack / layer scope')
  map(k.next_layer, function()
    view.next_layer(1)
  end, 'next stack layer')
  map(k.prev_layer, function()
    view.next_layer(-1)
  end, 'previous stack layer')
  map(k.help, require('revuey.key_help').toggle, 'all revuey keys (a float)')
  map(k.focus_panel, function()
    if api.nvim_win_is_valid(s.panel_win) then
      api.nvim_set_current_win(s.panel_win)
    end
  end, 'focus file panel')
end

---Close whichever list is open over the diff (the panel's `<CR>` on a file or section).
function M.close_any(s)
  require('revuey.comments_list').close(s)
  require('revuey.ai_reviews_view').close(s)
end

return M
