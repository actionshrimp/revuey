-- Lua half of tests/bin/claude: records the call and replays canned stream-json (NDJSON).
local stdin_file = arg[1]
local argv = { 'claude' }
for i = 2, #arg do
  argv[#argv + 1] = arg[i]
end
local fd = io.open(stdin_file, 'r')
local stdin = fd and fd:read('*a') or ''
if fd then
  fd:close()
end
os.remove(stdin_file)

local log = os.getenv('REVUEY_FAKE_CLAUDE_LOG')
if log and log ~= '' then
  local out = assert(io.open(log, 'a'))
  out:write(vim.json.encode({ argv = argv, stdin = stdin, cwd = vim.uv.cwd() }), '\n')
  out:close()
end

local scenario = os.getenv('REVUEY_FAKE_CLAUDE') or 'good'
local function emit(ev)
  io.stdout:write(vim.json.encode(ev), '\n')
  io.stdout:flush()
end

local ids, paths = {}, {}
for id, path in stdin:gmatch('\n@@ (h%d+) (.-) @@') do
  ids[#ids + 1] = id
  paths[id] = path
end
-- numbered lines (`3|+text`) the prompt showed per hunk id
local shown_lines, cur = {}, nil
for l in (stdin .. '\n'):gmatch('(.-)\n') do
  local id = l:match('^@@ (h%d+) .- @@')
  if id then
    cur = id
    shown_lines[id] = 0
  elseif cur and l:match('^%d+|') then
    shown_lines[cur] = shown_lines[cur] + 1
  end
end

-- an AI review run (its schema has findings) answers with a review instead of a guide
local review_mode = false
for i, a in ipairs(argv) do
  if a == '--json-schema' and (argv[i + 1] or ''):find('"findings"', 1, true) then
    review_mode = true
  end
end

---Default review: a major finding on line 1 of the first hunk, a nit on the second hunk's file,
---and one finding on an unknown hunk (revuey drops it).
local function review()
  local findings = {
    { hunk = ids[1], line = 1, severity = 'major', title = 'First line looks wrong', body = 'The first changed line of `' .. tostring(paths[ids[1]]) .. '` needs a look.' },
    { hunk = 'h999', line = 1, severity = 'minor', title = 'Ghost', body = 'An id the diff does not have.' },
  }
  if ids[2] then
    table.insert(findings, 2, { hunk = ids[2], severity = 'nit', title = 'File-level nit', body = 'About the whole file.' })
  end
  return { summary = 'A fake review summary.', verdict = 'request_changes', findings = findings }
end

local function guide()
  local file = os.getenv('REVUEY_FAKE_CLAUDE_OUTPUT')
  if file and file ~= '' then
    local f = assert(io.open(file, 'r'))
    local g = vim.json.decode(f:read('*a'))
    f:close()
    return g
  end
  -- odd ids form the core section, even ids the follow-up section
  local core, rest = {}, {}
  for i, id in ipairs(ids) do
    local ref = { id = id }
    if i == 1 then
      ref.note = 'Introduces the new `total` helper.'
    end
    table.insert(i % 2 == 1 and core or rest, ref)
  end
  local sections = {
    {
      title = 'Core change',
      overview = 'The heart of the change: **totals** move into `cart.ts`.\n\n> [!IMPORTANT] Callers now get rounded totals.',
      hunks = core,
    },
  }
  if #rest > 0 then
    sections[2] = { title = 'Follow-up wiring', overview = 'Call sites and glue.\n\n- one\n- two', hunks = rest }
  end
  return { title = 'Fake guide title', summary = 'A fake summary for tests.', sections = sections, unplaced = {} }
end

local session = 'fake-session-1'
local function init()
  emit({ type = 'system', subtype = 'init', session_id = session, model = 'claude-fake-1', cwd = vim.uv.cwd(), tools = { 'Read', 'Grep', 'Glob', 'Bash', 'StructuredOutput' } })
end
local function tool(name, input)
  emit({ type = 'assistant', session_id = session, message = { role = 'assistant', content = { { type = 'tool_use', id = 'toolu_' .. name, name = name, input = input } } } })
end
local function result(output, text)
  emit({
    type = 'result', subtype = 'success', is_error = false, session_id = session, duration_ms = 1234, num_turns = 2,
    total_cost_usd = 0.01, result = text or vim.json.encode(output or {}), structured_output = output,
  })
end
local function fail(msg)
  emit({ type = 'result', subtype = 'success', is_error = true, session_id = session, result = msg })
  os.exit(1)
end

if scenario == 'crash' then
  io.stderr:write('fake claude: something broke\n')
  os.exit(3)
end
init()
if scenario == 'stubborn' then
  -- ignores SIGTERM, and so does its child: only SIGKILL to the process group stops them
  local sig = vim.uv.new_signal()
  sig:start('sigterm', function() end)
  local child = vim.uv.spawn('sh', { args = { '-c', 'trap "" TERM; exec sleep 300' } }, function() end)
  local f = assert(io.open((log or '/dev/null') .. '.kids', 'a'))
  f:write(vim.uv.os_getpid(), ' ', child and child:get_pid() or -1, '\n')
  f:close()
  scenario = 'hang'
end
if scenario == 'kids' then
  -- a grandchild of revuey: only a process-group kill reaches it
  local child = vim.uv.spawn('sleep', { args = { '300' } }, function() end)
  local f = assert(io.open((log or '/dev/null') .. '.kids', 'a'))
  f:write(vim.uv.os_getpid(), ' ', child and child:get_pid() or -1, '\n')
  f:close()
  scenario = 'hang'
end
if scenario == 'hang' then
  tool('Read', { file_path = vim.uv.cwd() .. '/src/cart.ts' })
  while true do
    vim.wait(1000) -- (not uv.sleep: SIGTERM must be handled)
  end
end
if scenario == 'slow' then
  for _, p in ipairs({ 'src/cart.ts', 'src/math.ts' }) do
    tool('Read', { file_path = vim.uv.cwd() .. '/' .. p })
    vim.wait(300)
  end
end
tool('Grep', { pattern = 'total' })
if scenario == 'error' then
  fail('API Error: 500 {"type":"error","error":{"type":"api_error","message":"Internal server error"}}')
elseif scenario == 'notloggedin' then
  fail('Invalid API key · Please run /login')
elseif scenario == 'invalid' then
  result(nil, 'I could not produce JSON, sorry.')
elseif scenario == 'fenced' then
  result(nil, 'Here you go:\n```json\n' .. vim.json.encode(guide()) .. '\n```\n')
elseif scenario == 'newlines' then
  local g = guide()
  g.title = 'Title\nsecond line'
  g.sections[1].title = 'Core\nchange\0'
  g.sections[1].hunks[1].note = 'note\nwith newline'
  tool('StructuredOutput', g)
  result(g)
elseif scenario == 'missing' then
  local g = guide()
  g.sections = { { title = 'Only one', overview = 'Just the first hunk.', hunks = { { id = ids[1] } } } }
  tool('StructuredOutput', g)
  result(g)
elseif scenario == 'unknown' then
  local g = guide()
  table.insert(g.sections[1].hunks, { id = 'h999' })
  table.insert(g.sections[1].hunks, { id = ids[1] }) -- duplicate
  g.sections[#g.sections + 1] = { title = 'Ghost', overview = 'Only unknown ids.', hunks = { { id = 'h998' } } }
  tool('StructuredOutput', g)
  result(g)
elseif scenario == 'notes' then
  -- line notes: two on the first core hunk with 3+ numbered lines (one a range), one on the
  -- first follow-up hunk with lines, and three bad anchors revuey drops (unknown hunk, a line the
  -- hunk does not have, a hunk without numbered lines)
  local g = guide()
  local core, rest, bare
  for i, id in ipairs(ids) do
    local n = shown_lines[id] or 0
    if i % 2 == 1 and n >= 3 and not core then
      core = id
    elseif i % 2 == 0 and n >= 1 and not rest then
      rest = id
    elseif n == 0 and not bare then
      bare = id
    end
  end
  g.sections[1].line_notes = {
    { hunk = core, line = 2, end_line = 3, text = 'Note the `sum` call: totals are built here.' },
    { hunk = core, line = 1, text = 'The new module starts here.' },
    { hunk = 'h999', line = 1, text = 'A hunk the diff does not have.' },
    { hunk = core, line = 999, text = 'A line the hunk does not have.' },
  }
  if bare then
    table.insert(g.sections[1].line_notes, { hunk = bare, line = 1, text = 'A file without lines.' })
  end
  if g.sections[2] and rest then
    g.sections[2].line_notes = { { hunk = rest, line = 1, text = 'Wired in here.' } }
  end
  tool('StructuredOutput', g)
  result(g)
elseif scenario == 'diagram' then
  -- a guide with an overview diagram of the fixture's modules (both fixtures have these files)
  local g = guide()
  g.diagram = {
    nodes = {
      { id = 'index', label = 'index.ts', kind = 'changed' },
      { id = 'ui', label = 'Total.tsx', kind = 'new', section = 2 },
      { id = 'cart', label = 'cart.ts', kind = 'new', section = 1 },
      { id = 'math', label = 'math.ts', kind = 'changed' },
      { id = 'format', label = 'format.ts', kind = 'context' },
    },
    edges = {
      { from = 'index', to = 'cart', label = 'new Cart' },
      { from = 'ui', to = 'cart', label = 'total()' },
      { from = 'cart', to = 'math', label = 'sum' },
      { from = 'ui', to = 'format' },
      { from = 'ghost', to = 'cart' }, -- unknown node: dropped by validation
    },
  }
  tool('StructuredOutput', g)
  result(g)
else
  local out = os.getenv('REVUEY_FAKE_CLAUDE_OUTPUT')
  local g = (review_mode and (out or '') == '') and review() or guide()
  tool('StructuredOutput', g)
  result(g)
end
