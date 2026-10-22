-- Unit: the guide's overview diagram. Schema validation (guide.validate_diagram and through
-- guide.validate), the layered layout and its Unicode rendering (golden output), the list form
-- fallback, highlight and node spans, and Mermaid text.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
local guide = require('revuey.guide')
local gp = require('revuey.guide_prompt')
local dg = require('revuey.diagram')

local function N(id, kind, label)
  return { id = id, label = label or id, kind = kind or 'changed' }
end

local function E(from, to, label)
  return { from = from, to = to, label = label }
end

local function render(d, width)
  return dg.render(guide.validate_diagram(d), width)
end

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------

h.test('validation: unknown nodes, duplicates, self loops, kinds, labels', function()
  local d = guide.validate_diagram({
    nodes = {
      N('a', 'new', 'Alpha\nmodule\t'),
      N('b', 'weird', ''),
      N('a', 'context', 'duplicate id'),
      { id = 7, label = 'numeric id', kind = 'context' },
      { label = 'no id' },
      'not a table',
      N('long', 'changed', string.rep('x', 40)),
      N('wide', 'new', string.rep('漢', 20)),
    },
    edges = {
      E('a', 'b', 'calls\nback'),
      E('a', 'b', 'duplicate pair'),
      E('b', 'a'),
      E('a', 'a', 'self'),
      E('a', 'ghost'),
      E('ghost', 'b'),
      E('7', 'long', string.rep('y', 30)),
      { from = 'a' },
      'nope',
    },
  })
  h.eq({ 'a', 'b', '7', 'long', 'wide' }, vim.tbl_map(function(n)
    return n.id
  end, d.nodes))
  h.eq('Alpha module', d.nodes[1].label, 'one line, trimmed')
  h.eq('b', d.nodes[2].label, 'empty label: the id')
  h.eq('changed', d.nodes[2].kind, 'unknown kind')
  h.eq(string.rep('x', guide.DIAGRAM_LABEL_MAX - 1) .. '…', d.nodes[4].label)
  h.eq(guide.DIAGRAM_LABEL_MAX - 1, vim.api.nvim_strwidth(d.nodes[5].label), 'multibyte labels truncate by cells (a 2-cell char does not fit)')
  h.eq(string.rep('漢', 13) .. '…', d.nodes[5].label)
  h.eq({
    { from = 'a', to = 'b', label = 'calls back' },
    { from = 'b', to = 'a' },
    { from = '7', to = 'long', label = string.rep('y', guide.DIAGRAM_EDGE_LABEL_MAX - 1) .. '…' },
  }, d.edges)
end)

h.test('validation: fewer than two nodes, caps, not a table', function()
  h.eq(nil, guide.validate_diagram(nil))
  h.eq(nil, guide.validate_diagram('diagram'))
  h.eq(nil, guide.validate_diagram({ nodes = { N('a') }, edges = {} }))
  h.eq(nil, guide.validate_diagram({ nodes = { N('a'), N('a') }, edges = {} }), 'duplicates do not count')
  local nodes, edges = {}, {}
  for i = 1, 20 do
    nodes[i] = N('n' .. i)
  end
  for i = 1, 12 do
    for j = 1, 12 do
      if i ~= j then
        edges[#edges + 1] = E('n' .. i, 'n' .. j)
      end
    end
  end
  local d = guide.validate_diagram({ nodes = nodes, edges = edges })
  h.eq(12, #d.nodes)
  h.eq(20, #d.edges)
  h.eq({ nodes = { N('a'), N('b') }, edges = {} }, guide.validate_diagram({ nodes = { N('a'), N('b') } }), 'edges optional')
end)

local hunks = {
  { id = 'h1', file_idx = 1, hunk_idx = 1, path = 'a.ts', hash = 'x1' },
  { id = 'h2', file_idx = 1, hunk_idx = 2, path = 'a.ts', hash = 'x2' },
  { id = 'h3', file_idx = 2, hunk_idx = 1, path = 'b.ts', hash = 'x3' },
}

h.test('validation in guide.validate: sections map to the surviving sections; record and reload', function()
  local raw = {
    title = 'T',
    summary = 'S',
    sections = {
      { title = 'Ghost', overview = '', hunks = { { id = 'h99' } } }, -- dropped: only unknown ids
      { title = 'Core', overview = '', hunks = { { id = 'h1' }, { id = 'h2' } } },
      { title = 'Wiring', overview = '', hunks = { { id = 'h3' } } },
    },
    unplaced = {},
    diagram = {
      nodes = {
        { id = 'a', label = 'a.ts', kind = 'new', section = 2 },
        { id = 'b', label = 'b.ts', kind = 'changed', section = 3 },
        { id = 'g', label = 'ghost', kind = 'context', section = 1 },
        { id = 't', label = 'by title', kind = 'context', section = 'wiring' },
        { id = 'x', label = 'out of range', kind = 'context', section = 9 },
      },
      edges = { E('a', 'b', 'calls'), E('a', 'zzz') },
    },
  }
  local v, w = guide.validate(raw, hunks)
  h.eq({ 'Core', 'Wiring' }, vim.tbl_map(function(s)
    return s.title
  end, v.sections))
  h.eq({ 1, 2, nil, 2, nil }, { v.diagram.nodes[1].section, v.diagram.nodes[2].section, v.diagram.nodes[3].section, v.diagram.nodes[4].section, v.diagram.nodes[5].section })
  h.eq({ E('a', 'b', 'calls') }, v.diagram.edges)
  h.eq(nil, w.diagram_dropped)
  -- stored with the record, resolved with the guide, re-validated on load
  local rec = guide.record(v, hunks, { key = { repo = 'r', branch = 'b', base = 'm' } })
  h.eq(v.diagram, rec.diagram)
  h.eq(v.diagram, guide.resolve(rec, hunks).diagram)
  rec.diagram.nodes[1].label = 'edited\non disk'
  rec.diagram.nodes[2].section = 7
  guide.sanitize(rec)
  h.eq('edited on disk', rec.diagram.nodes[1].label)
  h.eq(nil, rec.diagram.nodes[2].section, 'section out of range after an edit')
  -- no diagram, or a useless one
  raw.diagram = nil
  h.eq(nil, guide.validate(raw, hunks).diagram)
  raw.diagram = { nodes = { N('only') }, edges = {} }
  local v2, w2 = guide.validate(raw, hunks)
  h.eq(nil, v2.diagram)
  h.eq(true, w2.diagram_dropped)
end)

h.test('schema: optional diagram, capped, additionalProperties false', function()
  local d = gp.SCHEMA.properties.diagram
  h.ok(d and not vim.tbl_contains(gp.SCHEMA.required, 'diagram'), 'optional')
  h.eq(false, d.additionalProperties)
  h.eq(12, d.properties.nodes.maxItems)
  h.eq(20, d.properties.edges.maxItems)
  h.eq(false, d.properties.nodes.items.additionalProperties)
  h.eq(false, d.properties.edges.items.additionalProperties)
  h.eq({ 'new', 'changed', 'context' }, d.properties.nodes.items.properties.kind.enum)
  h.ok(gp.SYSTEM:find('### diagram (optional)', 1, true))
  h.ok(gp.SYSTEM:find('Leave the\nfield out for a small change', 1, true), 'skip for trivial changes')
end)

-- ---------------------------------------------------------------------------
-- Layout and rendering (golden)
-- ---------------------------------------------------------------------------

h.test('chain: straight lines, label next to the arrow, kinds coloured, node spans', function()
  local out = render({
    nodes = { N('parse', 'new', 'parser'), N('lay', 'changed', 'layout'), N('view', 'context') },
    edges = { E('parse', 'lay', 'feeds'), E('lay', 'view') },
  }, 60)
  h.eq('boxes', out.mode)
  h.eq({
    '╭────────╮',
    '│ parser │',
    '╰────┬───╯',
    '     │ feeds',
    '     ▼',
    '╭────────╮',
    '│ layout │',
    '╰────┬───╯',
    '     ▼',
    ' ╭──────╮',
    ' │ view │',
    ' ╰──────╯',
    '',
    '■ new  ■ changed  ■ context',
  }, out.lines)
  h.eq({
    { 1, 0, 30, 'RevueyDiagramNew' },
    { 2, 0, 14, 'RevueyDiagramNew' },
    { 3, 0, 30, 'RevueyDiagramNew' },
    { 4, 5, 8, 'RevueyDiagramEdge' },
    { 4, 9, 14, 'RevueyDiagramLabel' },
    { 5, 5, 8, 'RevueyDiagramEdge' },
    { 6, 0, 30, 'RevueyDiagramChanged' },
    { 7, 0, 14, 'RevueyDiagramChanged' },
    { 8, 0, 30, 'RevueyDiagramChanged' },
    { 9, 5, 8, 'RevueyDiagramEdge' },
    { 10, 1, 25, 'RevueyDiagramContext' },
    { 11, 1, 13, 'RevueyDiagramContext' },
    { 12, 1, 25, 'RevueyDiagramContext' },
    { 14, 0, 7, 'RevueyDiagramNew' },
    { 14, 9, 20, 'RevueyDiagramChanged' },
    { 14, 22, 33, 'RevueyDiagramContext' },
  }, out.hls)
  h.eq({ 2, 0, 14, 'parse' }, out.nodes[2], 'byte span of the label row')
  h.eq({ 11, 1, 13, 'view' }, out.nodes[8])
  -- deterministic
  h.eq(out, render({
    nodes = { N('parse', 'new', 'parser'), N('lay', 'changed', 'layout'), N('view', 'context') },
    edges = { E('parse', 'lay', 'feeds'), E('lay', 'view') },
  }, 60))
end)

h.test('fan-out: ports spread under the parent, which is centred over its children', function()
  local out = render({
    nodes = { N('core', 'new', 'guide.lua'), N('p', 'changed', 'prompt'), N('v', 'changed', 'view'), N('d', 'new', 'diagram') },
    edges = { E('core', 'p'), E('core', 'v', 'doc'), E('core', 'd') },
  }, 60)
  h.eq({
    '            ╭───────────╮',
    '            │ guide.lua │',
    '            ╰──┬──┬──┬──╯',
    '               │  │  │',
    '     ╭─────────╯  │  ╰─────────╮',
    '     │            │ doc        │',
    '     ▼            ▼            ▼',
    '╭────────╮    ╭──────╮    ╭─────────╮',
    '│ prompt │    │ view │    │ diagram │',
    '╰────────╯    ╰──────╯    ╰─────────╯',
    '',
    '■ new  ■ changed',
  }, out.lines)
end)

h.test('fan-in: lines merge into one box; a label without room at the arrow goes where the line leaves', function()
  local out = render({
    nodes = { N('a'), N('b'), N('c'), N('sink', 'new', 'state.json') },
    edges = { E('a', 'sink'), E('b', 'sink', 'writes'), E('c', 'sink') },
  }, 60)
  h.eq({
    '╭───╮    ╭───╮    ╭───╮',
    '│ a │    │ b │    │ c │',
    '╰─┬─╯    ╰─┬─╯    ╰─┬─╯',
    '  │        │ writes │',
    '  ╰────╮   │  ╭─────╯',
    '       ▼   ▼  ▼',
    '    ╭────────────╮',
    '    │ state.json │',
    '    ╰────────────╯',
    '',
    '■ new  ■ changed',
  }, out.lines)
  -- no room anywhere: listed under the diagram
  local crowded = render({
    nodes = { N('a'), N('b'), N('c'), N('sink', 'new', 'state.json') },
    edges = { E('a', 'sink'), E('b', 'sink', 'writes everything'), E('c', 'sink') },
  }, 60)
  h.eq({ 'b → state.json: writes everything', '', '■ new  ■ changed' }, vim.list_slice(crowded.lines, #crowded.lines - 2))
end)

h.test('cycle: the back edge is drawn upwards with its arrow at the top', function()
  local out = render({
    nodes = { N('a', 'changed', 'client'), N('b', 'new', 'server'), N('c', 'context', 'cache') },
    edges = { E('a', 'b'), E('b', 'c'), E('c', 'a', 'notify') },
  }, 60)
  h.eq({
    '    ╭────────╮',
    '    │ client │',
    '    ╰──┬─────╯',
    '       │  ▲',
    '     ╭─╯  ╰───╮',
    '     │        │ notify',
    '     ▼        │',
    '╭────────╮    │',
    '│ server │    │',
    '╰────┬───╯    │',
    '     │        │',
    '     ╰───╮  ╭─╯',
    '         ▼  │',
    '      ╭─────┴─╮',
    '      │ cache │',
    '      ╰───────╯',
    '',
    '■ new  ■ changed  ■ context',
  }, out.lines)
  -- a two-node cycle and a cycle with no source at all lay out too
  h.eq('boxes', render({ nodes = { N('x'), N('y') }, edges = { E('x', 'y'), E('y', 'x') } }, 40).mode)
end)

h.test('too wide for the window: the compact list form', function()
  local d = {
    nodes = { N('r', 'new', 'root'), N('x1', 'changed', 'alpha module'), N('x2', 'changed', 'beta module'), N('x3', 'changed', 'gamma module'), N('x4', 'changed', 'delta module'), N('lone', 'context', 'lonely') },
    edges = { E('r', 'x1'), E('r', 'x2'), E('r', 'x3', 'calls'), E('r', 'x4') },
  }
  local out = render(d, 50)
  h.eq('list', out.mode)
  h.eq({
    'root ───▶ alpha module',
    'root ───▶ beta module',
    'root ──calls──▶ gamma module',
    'root ───▶ delta module',
    '• lonely',
    '',
    '■ new  ■ changed  ■ context',
  }, out.lines)
  h.eq({ 3, 26, 38, 'x3' }, out.nodes[6])
  h.ok(vim.tbl_contains(out.hls, function(sp)
    return vim.deep_equal(sp, { 3, 4, 26, 'RevueyDiagramEdge' })
  end, { predicate = true }), vim.inspect(out.hls))
  -- a list line wider than the window breaks after the arrow
  h.eq({ 'root ──calls──▶', '    gamma module' }, vim.list_slice(render(d, 20).lines, 5, 6))
  -- the same graph fits in boxes at 80 columns
  h.eq('boxes', render(d, 80).mode)
end)

h.test('multibyte labels: wide characters take two cells; spans are bytes', function()
  local out = render({ nodes = { N('a', 'new', '漢字モジュール'), N('b', 'changed', 'café') }, edges = { E('a', 'b', '呼ぶ') } }, 60)
  h.eq({
    '╭────────────────╮',
    '│ 漢字モジュール │',
    '╰────────┬───────╯',
    '         │ 呼ぶ',
    '         ▼',
    '     ╭──────╮',
    '     │ café │',
    '     ╰──────╯',
    '',
    '■ new  ■ changed',
  }, out.lines)
  for _, l in ipairs(out.lines) do
    h.ok(vim.api.nvim_strwidth(l) <= 60)
  end
  h.eq({ 2, 0, 29, 'a' }, out.nodes[2])
  h.eq({ 7, 5, 18, 'b' }, out.nodes[5])
end)

h.test('every layout fits its width', function()
  local nodes, edges = {}, {}
  for i = 1, 12 do
    nodes[i] = N('n' .. i, ({ 'new', 'changed', 'context' })[i % 3 + 1], 'module ' .. i)
  end
  for i = 1, 11 do
    edges[#edges + 1] = E('n' .. i, 'n' .. (i + 1), i % 2 == 0 and 'uses' or nil)
    if i + 3 <= 12 then
      edges[#edges + 1] = E('n' .. i, 'n' .. (i + 3))
    end
  end
  local d = guide.validate_diagram({ nodes = nodes, edges = edges })
  for _, w in ipairs({ 30, 60, 80, 100 }) do
    local out = dg.render(d, w)
    for _, l in ipairs(out.lines) do
      h.ok(vim.api.nvim_strwidth(l) <= w, ('%d: %s'):format(w, l))
    end
  end
end)

h.test('mermaid: flowchart with escaped labels and kind classes', function()
  local d = guide.validate_diagram({
    nodes = { N('parse', 'new', 'parser "v2"'), N('lay', 'changed', 'a|b <c>'), N('view', 'context') },
    edges = { E('parse', 'lay', 'feeds'), E('lay', 'view') },
  })
  h.eq(table.concat({
    'flowchart TD',
    '  n1["parser #quot;v2#quot;"]',
    '  n2["a#124;b #lt;c#gt;"]',
    '  n3["view"]',
    '  n1 -->|"feeds"| n2',
    '  n2 --> n3',
    '  classDef new fill:#dafbe1,stroke:#1a7f37,color:#1f2328',
    '  class n1 new',
    '  classDef changed fill:#fff8c5,stroke:#9a6700,color:#1f2328',
    '  class n2 changed',
    '  classDef context fill:#f6f8fa,stroke:#8c959f,color:#57606a,stroke-dasharray:3 3',
    '  class n3 context',
  }, '\n') .. '\n', dg.mermaid(d))
end)

h.run()
