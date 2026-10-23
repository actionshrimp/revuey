-- Unit: edit from the review (edit.lua). Which rows can be edited for each row kind, layer and
-- mode (and the messages), and the row -> file line mapping, also after earlier edits.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
local diff = require('revuey.diff')
local layout = require('revuey.layout')
local edit = require('revuey.edit')

local function blob(c)
  return string.rep(c, 40)
end

local function difftext(files)
  local out = {}
  for _, f in ipairs(files) do
    out[#out + 1] = ('diff --git a/%s b/%s'):format(f.path, f.path)
    if f.binary then
      out[#out + 1] = 'index ' .. blob('a') .. '..' .. blob('b') .. ' 100644'
      out[#out + 1] = ('Binary files a/%s and b/%s differ'):format(f.path, f.path)
    elseif f.deleted then
      out[#out + 1] = 'deleted file mode 100644'
      out[#out + 1] = 'index ' .. blob('a') .. '..' .. string.rep('0', 40)
      out[#out + 1] = '--- a/' .. f.path
      out[#out + 1] = '+++ /dev/null'
      for _, hk in ipairs(f.hunks) do
        vim.list_extend(out, hk)
      end
    else
      out[#out + 1] = 'index ' .. blob('a') .. '..' .. blob('b') .. ' 100644'
      out[#out + 1] = '--- a/' .. f.path
      out[#out + 1] = '+++ b/' .. f.path
      for _, hk in ipairs(f.hunks) do
        vim.list_extend(out, hk)
      end
    end
  end
  return table.concat(out, '\n') .. '\n'
end

local function review(o)
  o = o or {}
  local files = diff.parse(difftext({
    { path = 'src/a.ts', hunks = {
      { '@@ -1,3 +1,3 @@', ' one', '-two', '+TWO', ' three' },
      { '@@ -10,2 +10,3 @@', ' ten', '+ten and a half', ' eleven' },
    } },
    { path = 'gone.ts', deleted = true, hunks = { { '@@ -1,1 +0,0 @@', '-x' } } },
    { path = 'logo.png', binary = true },
  }))
  for _, f in ipairs(files) do
    f.worktree = o.mode ~= 'committed' and f.status ~= 'D' or nil
  end
  local r = { files = files, mode = o.mode or 'worktree', stack = o.stack, scope = o.scope, layer_labels = o.labels }
  r.layout = layout.compose(files)
  return r
end

---Row of the first entry matching `pred` in the composed diff.
local function row(r, pred)
  for i, e in ipairs(r.layout.map) do
    if pred(e, r.layout.lines[i]) then
      return r.layout.map[i]
    end
  end
  error('no such row')
end

local function text_row(r, text, kind)
  return row(r, function(e, l)
    return l == text and (not kind or e.kind == kind)
  end)
end

local function stack(head_index, opts)
  opts = opts or {}
  local layers = {
    { name = 'stack/math', is_head = head_index == 1, remote = opts.remote },
    { name = 'stack/cart', is_head = head_index == 2 },
  }
  return { layers = layers, current = head_index or 2 }
end

h.test('row kinds: add, ctx and hunk headers edit; del opens nearby; prose, meta and blanks refuse', function()
  local r = review()
  local add = edit.decide(r, text_row(r, 'TWO', 'add'))
  h.eq({ true, 2 }, { add.ok, add.lnum })
  local ctx = edit.decide(r, text_row(r, 'three', 'ctx'))
  h.eq({ true, 3 }, { ctx.ok, ctx.lnum })
  local header = edit.decide(r, row(r, function(e, l)
    return e.meta == 'hunk' and l:find('-10,2', 1, true)
  end))
  h.eq({ true, 10, 2 }, { header.ok, header.lnum, header.hunk_idx })
  local del = edit.decide(r, text_row(r, 'two', 'del'))
  h.eq({ true, 2, true }, { del.ok, del.lnum, del.deleted })
  h.eq(edit.msg.deleted_line(), del.note)
  h.ok(del.note:find("deleted lines can't be edited", 1, true))
  for _, e in ipairs({
    row(r, function(e)
      return e.meta == 'file'
    end),
    row(r, function(e)
      return e.meta == 'blank'
    end),
    { kind = 'prose', role = 'overview' },
    { kind = 'prose', note = true, file_idx = 1, path = 'src/a.ts' },
    { kind = 'diagram' },
    { kind = 'meta', meta = 'section', section_idx = 1 },
    nil,
  }) do
    local d = edit.decide(r, e)
    h.eq(false, d.ok, vim.inspect(e))
    h.eq(edit.msg.row(), d.msg)
  end
  h.ok(edit.msg.row():find('ge', 1, true))
end)

h.test('files: deleted files and binaries refuse', function()
  local r = review()
  local d = edit.decide(r, text_row(r, 'x', 'del'))
  h.eq({ false, edit.msg.deleted_file() }, { d.ok, d.msg })
  local b = edit.decide(r, row(r, function(e)
    return e.meta == 'note'
  end))
  h.eq(false, b.ok)
  -- a guide header of a file without hunks
  local g = edit.decide(r, { kind = 'meta', meta = 'hunk', file_idx = 3, path = 'logo.png', path_len = 8 })
  h.eq({ false, edit.msg.no_text() }, { g.ok, g.msg })
end)

h.test('mode and layers: committed mode, a layer that is not @, a remote ro layer', function()
  local r = review({ mode = 'committed' })
  local d = edit.decide(r, text_row(r, 'TWO', 'add'))
  h.eq(false, d.ok)
  h.ok(d.msg:find('switch to working-tree mode (gu)', 1, true), d.msg)

  -- the checked-out layer, working tree: fine
  r = review({ stack = stack(2), scope = { kind = 'layer', index = 2 } })
  h.eq(true, edit.decide(r, text_row(r, 'TWO', 'add')).ok)
  -- the checked-out layer in committed mode: the mode message
  r = review({ mode = 'committed', stack = stack(2), scope = { kind = 'layer', index = 2 } })
  h.ok(edit.decide(r, text_row(r, 'TWO', 'add')).msg:find('(gu)', 1, true))
  -- a lower layer (committed-only, not @)
  r = review({ mode = 'committed', stack = stack(2), scope = { kind = 'layer', index = 1 } })
  d = edit.decide(r, text_row(r, 'TWO', 'add'))
  h.eq("revuey: stack/math isn't checked out; press gS to switch", d.msg)
  -- a remote read-only layer
  r = review({ mode = 'committed', stack = stack(2, { remote = true }), scope = { kind = 'layer', index = 1 } })
  d = edit.decide(r, text_row(r, 'TWO', 'add'))
  h.eq("revuey: stack/math isn't checked out; press gS to switch", d.msg)
  -- HEAD detached at a remote layer's tip: `@`, but nowhere to commit, so read-only too
  local detached = stack(2)
  detached.layers[2].remote, detached.layers[2].detached = true, true
  r = review({ stack = detached, scope = { kind = 'layer', index = 2 } })
  d = edit.decide(r, text_row(r, 'TWO', 'add'))
  h.eq(false, d.ok)
  h.eq("revuey: stack/cart is a remote branch (detached HEAD, read-only); press gS to check out a local branch", d.msg)
  r = review({ stack = detached, scope = { kind = 'full' }, labels = { { { 'stack/cart' } } } })
  h.eq(edit.msg.remote('stack/cart'), edit.decide(r, text_row(r, 'TWO', 'add')).msg)
  -- the row message wins over the layer message on prose
  h.eq(edit.msg.row(), edit.decide(r, { kind = 'prose' }).msg)
end)

h.test('full stack: only hunks of the checked-out top layer (attribution labels)', function()
  local st = stack(2)
  -- HEAD is not the top: committed-only full stack
  local r = review({ mode = 'committed', stack = stack(1), scope = { kind = 'full' } })
  h.eq("revuey: stack/cart isn't checked out; press gS to switch", edit.decide(r, text_row(r, 'TWO', 'add')).msg)
  -- HEAD is the top: hunks labelled only with it (or uncommitted work) are editable
  r = review({ stack = st, scope = { kind = 'full' }, labels = { { { 'stack/cart' }, { 'stack/cart', 'uncommitted' } } } })
  h.eq(true, edit.decide(r, text_row(r, 'TWO', 'add')).ok)
  h.eq(true, edit.decide(r, text_row(r, 'ten and a half', 'add')).ok)
  -- a hunk from a lower layer, or mixing one in: refused, naming it
  r = review({ stack = st, scope = { kind = 'full' }, labels = { { { 'stack/math' }, { 'stack/math', 'stack/cart' } } } })
  local d = edit.decide(r, text_row(r, 'TWO', 'add'))
  h.eq(false, d.ok)
  h.ok(d.msg:find("stack/math, which isn't checked out", 1, true) and d.msg:find('gS', 1, true), d.msg)
  h.eq(false, edit.decide(r, text_row(r, 'eleven', 'ctx')).ok, 'context lines of such a hunk too')
  -- no labels (unknown attribution): refused rather than guessed
  r = review({ stack = st, scope = { kind = 'full' } })
  h.eq(edit.msg.no_labels(), edit.decide(r, text_row(r, 'TWO', 'add')).msg)
  r = review({ stack = st, scope = { kind = 'full' }, labels = { {} } })
  h.eq(edit.msg.no_labels(), edit.decide(r, text_row(r, 'TWO', 'add')).msg)
end)

h.test('row -> file line: exact by diff, also after earlier edits in the same file', function()
  local snap = 'a\nb\nc\nd\ne\nf\n'
  h.eq(4, edit.map_line(snap, snap, 4))
  -- two lines inserted above (an earlier edit, saved or not): shifted
  h.eq(6, edit.map_line(snap, 'x\ny\na\nb\nc\nd\ne\nf\n', 4))
  -- a line removed above
  h.eq(3, edit.map_line(snap, 'a\nc\nd\ne\nf\n', 4))
  -- the line itself was changed: nearest unchanged line above, shifted by the distance
  h.eq(4, edit.map_line(snap, 'a\nb\nc\nD!\ne\nf\n', 4))
  h.eq(6, edit.map_line(snap, 'x\ny\na\nb\nc\nD!\ne\nf\n', 4))
  -- duplicated text elsewhere is never picked
  local dup = 'same\nx\nsame\ny\n'
  h.eq(5, edit.map_line(dup, 'new\nnew\nsame\nx\nsame\ny\n', 3))
  -- clamped to the file
  h.eq(2, edit.map_line(snap, 'a\nb\n', 6))
  h.eq(1, edit.map_line(snap, '', 3))
  -- CRLF files map like LF ones
  h.eq(2, edit.map_line('a\r\nb\r\n', 'z\r\na\r\nb\r\n', 1))
end)

h.test('hunk ranges and the unfolded window around them', function()
  local r = review()
  local f = r.files[1]
  h.eq({ 1, 3 }, { edit.hunk_range(f.hunks[1]) })
  h.eq({ 10, 12 }, { edit.hunk_range(f.hunks[2]) })
  local del = diff.parse(difftext({ { path = 'x', hunks = { { '@@ -4,2 +3,0 @@', '-p', '-q' } } } }))[1]
  h.eq({ 3, 3 }, { edit.hunk_range(del.hunks[1]) }, 'a pure deletion: the line it sits after')
  h.eq({ 1, 6 }, { edit.view_range(1, 3, 40) })
  h.eq({ 7, 15 }, { edit.view_range(10, 12, 40) })
  h.eq({ 7, 12 }, { edit.view_range(10, 12, 12) })
end)

h.run()
