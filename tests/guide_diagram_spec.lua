-- Integration: the guide's overview diagram (fake `claude` scenario "diagram") and the branch
-- labels of full-stack guides, on fixture repos.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')
vim.notify = function() end

local log = h.tmpdir('fake-claude-diagram') .. '/calls.ndjson'
h.use_fake_claude(log)

local state_dir = h.tmpdir('guide-diagram-state')
require('revuey').setup({ state_dir = state_dir, lsp_warmup = false })
local view = require('revuey.view')
local gv = require('revuey.guide_view')
local ns = vim.api.nvim_get_namespaces()['revuey.diff']

local function open(dir, opts)
  if view.session then
    view.close()
  end
  return h.open_review(vim.tbl_extend('force', { cwd = dir }, opts or {}))
end

local function idle(s)
  assert(vim.wait(10000, function()
    return not s.refreshing and not s.pending and not s.pending_scope
  end, 10), 'refresh did not finish')
end

local function generate(s)
  view.guide_command(true)
  assert(vim.wait(20000, function()
    return next(gv.jobs) == nil and s.guide and s.guide.resolved ~= nil
  end, 20), 'guide generation did not finish')
  idle(s)
end

local function lines(s)
  return vim.api.nvim_buf_get_lines(s.diff_buf, 0, -1, false)
end

local function find(s, needle, kind)
  for row, l in ipairs(lines(s)) do
    local e = s.layout.map[row]
    if l:find(needle, 1, true) and (not kind or e.kind == kind or e.meta == kind) then
      return row, l:find(needle, 1, true) - 1
    end
  end
end

local function keys(s, k)
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_feedkeys(vim.keycode(k), 'mtx', false)
  idle(s)
end

local function last_stdin()
  local out
  for l in io.lines(log) do
    out = vim.json.decode(l).stdin
  end
  return out
end

---Virtual text of extmarks on a row, concatenated.
local function virt(s, row)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.diff_buf, ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    for _, chunk in ipairs(m[4].virt_text or {}) do
      out[#out + 1] = chunk[1]
    end
  end
  return table.concat(out)
end

local function hl_at(s, row, col)
  local groups = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.diff_buf, ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    local d = m[4]
    if d.hl_group and m[3] <= col and (d.end_col or 0) > col then
      groups[#groups + 1] = d.hl_group
    end
  end
  return groups
end

h.test('a guide with a diagram renders it under the summary; <CR> on a node jumps to its section', function()
  vim.env.REVUEY_FAKE_CLAUDE = 'diagram'
  local s = open(h.fixture())
  generate(s)
  h.eq('guide', s.view_mode)
  local res = s.guide.resolved
  h.eq(5, #res.diagram.nodes)
  h.eq(4, #res.diagram.edges, 'the edge to an unknown node was dropped')
  h.eq(true, res.diagram.nodes[3].section == 1 and res.diagram.nodes[2].section == 2)
  -- heading below the summary, before the first section; rows are of kind 'diagram'
  local summary = find(s, 'A fake summary for tests.', 'prose')
  local heading = find(s, 'Overview', 'diagram')
  h.ok(summary and heading and heading > summary and heading < s.layout.sections[1].start_row)
  h.eq(true, s.layout.map[heading].heading)
  h.eq({ start_row = heading, end_row = s.layout.diagram.end_row }, s.layout.diagram)
  for row = s.layout.diagram.start_row, s.layout.diagram.end_row do
    h.eq('diagram', s.layout.map[row].kind)
  end
  local text = table.concat(vim.list_slice(lines(s), heading, s.layout.diagram.end_row), '\n')
  h.ok(text:find('│ cart.ts │', 1, true) and text:find('╭', 1, true) and text:find('▼', 1, true), text)
  -- diff features skip diagram rows
  local syntax = require('revuey.syntax')
  for row = heading, s.layout.diagram.end_row do
    h.eq(nil, syntax.spans_for_row({ layout = s.layout, review = s.review }, row - 1))
    h.eq(nil, s.word_spans(row - 1))
  end
  -- nodes are coloured by kind
  local crow, ccol = find(s, 'cart.ts', 'diagram')
  h.ok(vim.tbl_contains(hl_at(s, crow, ccol), 'RevueyDiagramNew'), vim.inspect(hl_at(s, crow, ccol)))
  local frow, fcol = find(s, 'format.ts', 'diagram')
  h.ok(vim.tbl_contains(hl_at(s, frow, fcol), 'RevueyDiagramContext'))
  -- <CR> on a node with a section jumps there
  vim.api.nvim_win_set_cursor(s.diff_win, { crow, ccol })
  keys(s, '<CR>')
  h.eq(s.layout.sections[1].start_row, vim.api.nvim_win_get_cursor(s.diff_win)[1])
  local trow, tcol = find(s, 'Total.tsx', 'diagram')
  vim.api.nvim_win_set_cursor(s.diff_win, { trow, tcol + 2 })
  keys(s, '<CR>')
  h.eq(s.layout.sections[2].start_row, vim.api.nvim_win_get_cursor(s.diff_win)[1])
  -- a node without a section, and a line between nodes: the cursor stays
  local irow, icol = find(s, 'index.ts', 'diagram')
  vim.api.nvim_win_set_cursor(s.diff_win, { irow, icol })
  keys(s, '<CR>')
  h.eq({ irow, icol }, vim.api.nvim_win_get_cursor(s.diff_win))
  -- <CR> on the heading folds the diagram, and again unfolds it
  vim.api.nvim_win_set_cursor(s.diff_win, { heading, 0 })
  keys(s, '<CR>')
  h.eq(heading, vim.fn.foldclosed(heading))
  h.eq(s.layout.diagram.end_row, vim.fn.foldclosedend(heading))
  keys(s, '<CR>')
  h.eq(-1, vim.fn.foldclosed(heading))
end)

h.test('the diagram re-renders on resize and keeps its fold', function()
  local s = view.session
  local function resize(width)
    vim.api.nvim_win_set_width(s.diff_win, width)
    vim.cmd('doautocmd WinResized')
  end
  resize(120)
  local heading = s.layout.diagram.start_row
  h.ok(find(s, '╭', 'diagram'), 'boxes')
  local renders = s.render_count
  -- the fold survives re-rendering
  vim.api.nvim_win_set_cursor(s.diff_win, { heading, 0 })
  keys(s, '<CR>')
  resize(45)
  h.ok(s.render_count > renders, 're-rendered')
  h.ok(s.diagram_width < 40)
  h.eq(s.layout.diagram.start_row, vim.fn.foldclosed(s.layout.diagram.start_row), 'still folded')
  keys(s, '<CR>')
  for row = s.layout.diagram.start_row, s.layout.diagram.end_row do
    h.ok(vim.api.nvim_strwidth(lines(s)[row]) <= s.diagram_width, lines(s)[row])
  end
  -- <CR> on a node in the list form jumps too
  local crow, ccol = find(s, 'cart.ts', 'diagram')
  vim.api.nvim_win_set_cursor(s.diff_win, { crow, ccol })
  keys(s, '<CR>')
  h.eq(s.layout.sections[1].start_row, vim.api.nvim_win_get_cursor(s.diff_win)[1])
  vim.cmd('wincmd =')
  vim.cmd('doautocmd WinResized')
end)

h.test('the cursor on a diagram row stays on that row after a refresh and a re-wrap', function()
  local s = view.session
  local function resize(width)
    vim.api.nvim_win_set_width(s.diff_win, width)
    vim.cmd('doautocmd WinResized')
  end
  local crow, ccol = find(s, 'cart.ts', 'diagram')
  local rel = crow - s.layout.diagram.start_row
  h.ok(rel > 2, 'a row well inside the diagram')
  vim.api.nvim_win_set_cursor(s.diff_win, { crow, ccol })
  view.refresh({ force = true })
  idle(s)
  h.eq({ crow, ccol }, vim.api.nvim_win_get_cursor(s.diff_win), 'refresh')
  resize(70)
  local cur = vim.api.nvim_win_get_cursor(s.diff_win)
  h.eq(s.layout.diagram.start_row + rel, cur[1], 're-wrap: same row of the diagram')
  h.ok(cur[2] < math.max(#lines(s)[cur[1]], 1), 'column clamped to the line')
  -- the last row of a taller layout clamps to the shorter one
  vim.api.nvim_win_set_cursor(s.diff_win, { s.layout.diagram.end_row, 0 })
  view.refresh({ force = true })
  idle(s)
  h.eq(s.layout.diagram.end_row, vim.api.nvim_win_get_cursor(s.diff_win)[1])
  vim.cmd('wincmd =')
  vim.cmd('doautocmd WinResized')
end)

-- (that the diagram uses the full window width, beyond the 100-column prose cap, needs a wider
-- screen than headless specs may have: screen_spec.lua checks it in its 130-column child)
h.test('reopening after the diagram tests', function()
  view.close()
  local s
  s = open(h.fixture())
  view.guide_command(false)
  idle(s)
end)

h.test('<Tab> on the diagram heading folds it; <S-Tab> includes it; the fold survives a refresh', function()
  local s = view.session
  local function closed(row)
    return vim.api.nvim_win_call(s.diff_win, function()
      return vim.fn.foldclosed(row) ~= -1
    end)
  end
  local heading = s.layout.diagram.start_row
  vim.api.nvim_win_set_cursor(s.diff_win, { heading, 0 })
  keys(s, '<Tab>')
  h.eq(true, closed(heading))
  keys(s, '<Tab>')
  h.eq(false, closed(heading))
  -- elsewhere in the diagram <Tab> stays jump-forward: no fold toggles
  local crow, ccol = find(s, 'cart.ts', 'diagram')
  vim.api.nvim_win_set_cursor(s.diff_win, { crow, ccol })
  keys(s, '<Tab>')
  h.eq(false, closed(heading))
  -- <S-Tab>: the diagram and every section collapse, then all expand
  keys(s, '<S-Tab>')
  h.eq(true, closed(s.layout.diagram.start_row))
  for _, r in ipairs(s.layout.sections) do
    h.eq(true, closed(r.start_row))
  end
  keys(s, '<S-Tab>')
  h.eq(false, closed(s.layout.diagram.start_row))
  for _, r in ipairs(s.layout.sections) do
    h.eq(false, closed(r.start_row))
  end
  -- only the diagram collapsed: a forced refresh keeps it collapsed and the sections open
  vim.api.nvim_win_set_cursor(s.diff_win, { s.layout.diagram.start_row, 0 })
  keys(s, '<Tab>')
  local renders = s.render_count
  view.refresh({ force = true })
  idle(s)
  h.ok(s.render_count > renders, 're-rendered')
  h.eq(true, closed(s.layout.diagram.start_row))
  h.eq(false, closed(s.layout.sections[1].start_row))
  -- and across a trip to the diff view and back
  keys(s, 'gG')
  keys(s, 'gG')
  h.eq('guide', s.view_mode)
  h.eq(true, closed(s.layout.diagram.start_row))
  vim.api.nvim_win_set_cursor(s.diff_win, { s.layout.diagram.start_row, 0 })
  keys(s, '<Tab>')
  h.eq(false, closed(s.layout.diagram.start_row))
end)

h.test(':RevueyGuideDiagram mermaid copies Mermaid text to a register', function()
  vim.fn.setreg('a', '')
  vim.cmd('RevueyGuideDiagram mermaid a')
  local text = vim.fn.getreg('a')
  h.ok(vim.startswith(text, 'flowchart TD\n  n1["index.ts"]\n'), text)
  h.ok(text:find('n1 -->|"new Cart"| n3', 1, true), text)
  h.ok(text:find('class n2,n3 new', 1, true), text)
  -- the default register: + with a clipboard, else the unnamed one (no clipboard here: tests
  -- must not write to the real one)
  local has = vim.fn.has
  vim.fn.has = function(f)
    return f == 'clipboard' and 0 or has(f)
  end
  vim.fn.setreg('"', '')
  local out = view.guide_diagram('mermaid')
  vim.fn.has = has
  h.eq(out, vim.fn.getreg('"'))
  -- a guide without a diagram
  local s = view.session
  s.guide.resolved.diagram = nil
  h.eq(nil, view.guide_diagram('mermaid'))
  s.guide.reload = true
end)

-- a full stack with uncommitted work at the top: stack/ui checked out, src/index.ts edited
local stack_dir = h.tmpdir('guide-diagram-stack')
vim.fn.delete(stack_dir, 'rf')
assert(vim.system({ h.root .. '/scripts/make-fixture.sh', '--stack', stack_dir }):wait().code == 0)
h.git(stack_dir, 'checkout', '-q', 'stack/ui')
do
  local path = stack_dir .. '/src/index.ts'
  local src = table.concat(vim.fn.readfile(path), '\n') .. '\n'
  vim.fn.writefile(vim.split((src:gsub('add%(2, 3%)', 'add(2, 4)')), '\n', { plain = true }), path, 'b')
end

local function header_row(s, path)
  for row, e in ipairs(s.layout.map) do
    if e.meta == 'hunk' and e.path == path then
      return row
    end
  end
end

h.test('full-stack guide: hunk headers name the branches that introduced them; so does the prompt', function()
  vim.env.REVUEY_FAKE_CLAUDE = 'good'
  local s = open(stack_dir, { base = '', scope = 'full' })
  h.eq({ kind = 'full' }, s.scope)
  h.ok(s.review.layer_labels, 'labels computed for the full scope')
  -- the full-scope diff view shows them on hunk headers
  h.ok(virt(s, header_row(s, 'src/math.ts')):find('[stack/math]', 1, true), virt(s, header_row(s, 'src/math.ts')))
  h.ok(virt(s, header_row(s, 'src/cart.ts')):find('[stack/cart, stack/ui]', 1, true))
  h.ok(virt(s, header_row(s, 'src/index.ts')):find('[stack/cart, uncommitted]', 1, true), virt(s, header_row(s, 'src/index.ts')))
  h.ok(virt(s, header_row(s, 'src/components/Total.tsx')):find('[stack/ui]', 1, true))
  generate(s)
  h.ok(virt(s, header_row(s, 'src/cart.ts')):find('[stack/cart, stack/ui]', 1, true), virt(s, header_row(s, 'src/cart.ts')))
  h.ok(virt(s, header_row(s, 'src/math.ts')):find('[stack/math]', 1, true))
  h.ok(virt(s, header_row(s, 'src/index.ts')):find('[stack/cart, uncommitted]', 1, true))
  local stdin = last_stdin()
  h.ok(stdin:find(' src/cart.ts @@ [stack/cart, stack/ui]\n', 1, true), stdin)
  h.ok(stdin:find(' src/index.ts @@ [stack/cart, uncommitted]\n', 1, true), stdin)
  h.ok(stdin:find('Each hunk marker below ends with the branch that introduced the hunk', 1, true))
end)

h.test('layer-scope guide: no branch labels', function()
  local s = view.session
  keys(s, 'gs')
  h.eq('layer', s.scope.kind)
  h.eq(nil, s.review.layer_labels)
  generate(s)
  for row, e in ipairs(s.layout.map) do
    if e.meta == 'hunk' then
      h.ok(not virt(s, row):find('[stack/', 1, true), virt(s, row))
    end
  end
  local stdin = last_stdin()
  h.ok(not stdin:find('@@ %[stack/'), 'no tags in the prompt')
  h.ok(not stdin:find('Each hunk marker below', 1, true))
  view.close()
end)

h.run()
