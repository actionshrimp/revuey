-- Unit: AI guide model (hunk ids/anchors, prompt, NDJSON parsing, validation/repair, section
-- identity, staleness, storage), prose rendering and the guide layout. No processes, no UI.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
local diff = require('revuey.diff')
local guide = require('revuey.guide')
local gp = require('revuey.guide_prompt')
local ai = require('revuey.ai')
local prose = require('revuey.prose')
local layout = require('revuey.layout')
local state = require('revuey.state')

local Z = string.rep('0', 40)
local function blob(c)
  return string.rep(c, 40)
end

---Build `git diff` text: files = { {path, hunks = { {header, lines...} }, status?} }
local function difftext(files)
  local out = {}
  for _, f in ipairs(files) do
    out[#out + 1] = ('diff --git a/%s b/%s'):format(f.path, f.path)
    if f.binary then
      out[#out + 1] = 'index ' .. blob('a') .. '..' .. blob('b') .. ' 100644'
      out[#out + 1] = ('Binary files a/%s and b/%s differ'):format(f.path, f.path)
    else
      out[#out + 1] = 'index ' .. (f.old or blob('a')) .. '..' .. (f.new or blob('b')) .. ' 100644'
      out[#out + 1] = '--- a/' .. f.path
      out[#out + 1] = '+++ b/' .. f.path
      for _, hk in ipairs(f.hunks) do
        vim.list_extend(out, hk)
      end
    end
  end
  return table.concat(out, '\n') .. '\n'
end

local base_diff = {
  { path = 'src/a.ts', hunks = {
    { '@@ -1,3 +1,3 @@ function a', ' one', '-two', '+TWO', ' three' },
    { '@@ -10,2 +10,3 @@', ' ten', '+ten and a half', ' eleven' },
  } },
  { path = 'src/b.ts', hunks = { { '@@ -1,1 +1,1 @@', '-x', '+y' } } },
  { path = 'logo.png', binary = true },
}

h.test('hunk ids in diff order, anchors and content hashes', function()
  local files = diff.parse(difftext(base_diff))
  local hs = guide.hunks(files)
  h.eq({ 'h1', 'h2', 'h3', 'h4' }, vim.tbl_map(function(x)
    return x.id
  end, hs))
  h.eq({ 'src/a.ts', 'src/a.ts', 'src/b.ts', 'logo.png' }, vim.tbl_map(function(x)
    return x.path
  end, hs))
  h.eq({ path = 'src/a.ts', old_start = 10, new_start = 10, header = '@@ -10,2 +10,3 @@', hash = hs[2].hash }, guide.anchor(hs[2]))
  h.eq({ 1, 1 }, { hs[1].added, hs[1].removed })
  h.eq(nil, hs[4].hunk_idx, 'binary file: one file-level entry')
  h.eq({ ' one', '-two', '+TWO', ' three' }, hs[1].text)
  -- hashes ignore line numbers: shifting the hunk keeps it, changing a line changes it
  local shifted = vim.deepcopy(base_diff)
  shifted[1].hunks[2] = { '@@ -12,2 +14,3 @@', ' ten', '+ten and a half', ' eleven' }
  local hs2 = guide.hunks(diff.parse(difftext(shifted)))
  h.eq(hs[2].hash, hs2[2].hash)
  local edited = vim.deepcopy(base_diff)
  edited[1].hunks[2] = { '@@ -10,2 +10,3 @@', ' ten', '+ten and three quarters', ' eleven' }
  local hs3 = guide.hunks(diff.parse(difftext(edited)))
  h.ok(hs[2].hash ~= hs3[2].hash)
  h.eq(hs[1].hash, hs3[1].hash)
  h.ok(guide.anchors_hash(hs) ~= guide.anchors_hash(hs3))
  -- same content in another file: different hash (path is part of it)
  local moved = { { path = 'src/c.ts', hunks = { base_diff[2].hunks[1] } } }
  h.ok(guide.hunks(diff.parse(difftext(moved)))[1].hash ~= hs[3].hash)
end)

h.test('identical hunks are told apart by location, not by order', function()
  local d = { { path = 'x.ts', hunks = {
    { '@@ -1,1 +1,1 @@', '-a', '+b' },
    { '@@ -9,1 +9,1 @@', '-a', '+b' },
    { '@@ -20,1 +20,1 @@', '-c', '+d' },
  } } }
  local hs = guide.hunks(diff.parse(difftext(d)))
  h.ok(hs[1].hash ~= hs[2].hash)
  h.ok(hs[1].hash:find('@1,1$'), hs[1].hash)
  h.ok(hs[2].hash:find('@9,9$'), hs[2].hash)
  h.ok(not hs[3].hash:find('@', 1, true), 'unique hunks stay shift-invariant')
  -- a new identical hunk elsewhere never hands one hunk's identity to another
  table.insert(d[1].hunks, 1, { '@@ -0,0 +0,1 @@', '+zzz' })
  local hs2 = guide.hunks(diff.parse(difftext(d)))
  h.eq(hs[1].hash, hs2[2].hash)
  h.eq(hs[2].hash, hs2[3].hash)
end)

h.test('model strings are sanitised: one-line titles and notes, no control characters', function()
  local hs = guide.hunks(diff.parse(difftext(base_diff)))
  local g = assert(guide.validate({
    title = 'Title\nwith newline\0 and \27[31mescape',
    summary = 'Line one\nline two\0\7',
    sections = {
      { title = 'Sec\r\ntion\tone', overview = 'Over\0view\nkept lines', hunks = { { id = 'h1', note = 'a\nb\0c' } } },
    },
    unplaced = {},
  }, hs))
  h.eq('Title with newline and [31mescape', g.title)
  h.eq('Line one\nline two', g.summary)
  h.eq('Sec tion one', g.sections[1].title)
  h.eq('Overview\nkept lines', g.sections[1].overview)
  h.eq('a b c', g.sections[1].hunks[1].note)
  -- a bad guide already on disk is cleaned when loaded
  local dir = h.tmpdir('guide-bad')
  local key = { repo = '/r', branch = 'b', base = 'main' }
  guide.save(dir, { kind = 'revuey-guide', version = 1, key = key, anchors = 'x', title = 'T\nU',
    sections = { { title = 'A\nB', overview = 'o', hunks = { { hash = 'h', note = 'n\no' } } } }, generator = { generated_at = 1 } })
  local rec = guide.load(dir, key, 'x')
  h.eq('T U', rec.title)
  h.eq('A B', rec.sections[1].title)
  h.eq('n o', rec.sections[1].hunks[1].note)
  -- non-string junk in a stored record does not crash resolve
  local fd = assert(io.open(guide.path(dir, key, 'y', 2), 'w'))
  fd:write(vim.json.encode({ kind = 'revuey-guide', key = key, anchors = 'y', title = 5, sections = { { title = { 'x' }, hunks = 'no' }, 'junk' }, generator = { generated_at = 2 } }))
  fd:close()
  local res = guide.resolve(guide.load(dir, key, 'y'), hs)
  h.eq('Guided review', res.title)
  h.eq('Untitled section', res.sections[1].title)
end)

h.test('line-ending-only changes change the hash', function()
  local lf = { { path = 'x.ts', hunks = { { '@@ -1,1 +1,1 @@', '-a', '+b' } } } }
  local crlf = { { path = 'x.ts', hunks = { { '@@ -1,1 +1,1 @@', '-a', '+b\r' } } } }
  h.ok(guide.hunks(diff.parse(difftext(lf)))[1].hash ~= guide.hunks(diff.parse(difftext(crlf)))[1].hash)
end)

h.test('prompt: file list, id markers, methodology and schema', function()
  local hs = guide.hunks(diff.parse(difftext(base_diff)))
  local text, info = gp.build({ repo = 'r', branch = 'feat', base = 'main', uncommitted = true, commits = { 'Add a', 'Fix b' } }, hs)
  h.eq(0, info.abridged)
  h.ok(text:find('# Guided Review Organizer', 1, true))
  h.ok(text:find('Changes: feat compared with main', 1, true))
  h.ok(text:find('Some of these changes are uncommitted work in the working tree.', 1, true))
  h.ok(text:find('- Add a\n- Fix b', 1, true))
  h.ok(text:find('src/a.ts (+2 -1): h1 h2', 1, true), 'file list with counts and ids')
  h.ok(text:find('logo.png (+0 -0): h4', 1, true))
  -- lines numbered within the hunk, for line notes (as AI review findings)
  h.ok(text:find('\n@@ h1 src/a.ts @@\n@@ -1,3 +1,3 @@ function a\n1| one\n2|-two\n3|+TWO\n4| three\n', 1, true), text)
  h.ok(text:find('\n@@ h4 logo.png @@\n(Binary file not shown)\n', 1, true))
  h.ok(text:find('Line notes use the `n|` numbers of their hunk.', 1, true))
  h.ok(text:find('**line_notes** (optional)', 1, true), 'the methodology explains line notes')
  h.ok(text:find('A line note is NOT a review comment.', 1, true))
  -- the caps the prompt states are the ones the import enforces
  h.ok(text:find(('never\n  more than %d per section or %d in the whole guide'):format(gp.MAX_NOTES_PER_SECTION, gp.MAX_NOTES), 1, true))
  h.ok(text:find(('(at most %d)'):format(gp.MAX_NOTE_LINES), 1, true))
  h.ok(text:find('Hunk ids: h1 to h4', 1, true))
  h.ok(not text:find('[abridged', 1, true) and not text:find('marked [abridged]', 1, true))
  h.ok(not text:find('—', 1, true), 'no em-dashes in our own prompt')
  -- schema: additionalProperties false at every object level
  local function check(node, path)
    if type(node) ~= 'table' then
      return
    end
    if node.type == 'object' then
      h.eq(false, node.additionalProperties, path)
    end
    for k, v in pairs(node) do
      check(v, path .. '.' .. tostring(k))
    end
  end
  check(gp.SCHEMA, 'schema')
  h.eq(gp.SCHEMA, vim.json.decode(gp.schema_json()))
end)

local stack_layers = {
  { name = 'stack/math', parent = 'main', commits = { 'Add sum' } },
  { name = 'stack/cart', parent = 'stack/math', commits = { 'Cart totals', 'Add cart' } },
  { name = 'stack/ui', parent = 'stack/cart', commits = { 'Total component' } },
}

h.test('prompt: layer scope says the review is one branch, not the stack', function()
  local hs = guide.hunks(diff.parse(difftext(base_diff)))
  local text = gp.build({ repo = 'r', branch = 'stack/cart', base = 'stack/math', commits = { 'Cart totals', 'Add cart' },
    stack = { kind = 'layer', index = 2, trunk = 'main', layers = stack_layers } }, hs)
  h.ok(text:find('Changes: branch stack/cart compared with its parent branch stack/math\n', 1, true), text)
  h.ok(text:find('This review covers only the branch `stack/cart`: its own changes on top of its parent branch `stack/math`.', 1, true), text)
  h.ok(text:find('layer 2 of a stack of 3 branches (main <- stack/math <- stack/cart <- stack/ui)', 1, true), text)
  h.ok(text:find('Call it "this branch" or "this change", never "this stack".', 1, true), text)
  h.ok(text:find('Mention the surrounding stack only when it is needed', 1, true), text)
  h.ok(text:find('Commits (newest first):\n- Cart totals\n- Add cart\n', 1, true), 'flat commit list for one branch')
  h.ok(not text:find('Commits by branch', 1, true))
  h.ok(not text:find('—', 1, true), 'no em-dashes in our own prompt')
end)

h.test('prompt: full scope lists the stack in order and asks which branch introduced what', function()
  local hs = guide.hunks(diff.parse(difftext(base_diff)))
  local text = gp.build({ repo = 'r', branch = 'stack/ui', base = 'main',
    commits = { 'Total component', 'Cart totals', 'Add cart', 'Add sum' },
    stack = { kind = 'full', trunk = 'main', layers = stack_layers } }, hs)
  h.ok(text:find('Changes: the whole stack from main up to stack/ui\n', 1, true), text)
  h.ok(text:find('This review covers a whole stack of 3 branches, each built on the one before it, bottom first:\n'
    .. '1. stack/math (on main)\n2. stack/cart (on stack/math)\n3. stack/ui (on stack/cart)\n', 1, true), text)
  h.ok(text:find('Call it "this stack".', 1, true), text)
  h.ok(text:find('say which branch introduced', 1, true), text)
  -- commits grouped by branch, so the model can tell which branch introduced what
  h.ok(text:find('Commits by branch (bottom first, newest first within each):\n- stack/math:\n  - Add sum\n'
    .. '- stack/cart:\n  - Cart totals\n  - Add cart\n- stack/ui:\n  - Total component\n', 1, true), text)
  h.ok(not text:find('Commits (newest first):', 1, true))
  h.ok(not text:find('—', 1, true), 'no em-dashes in our own prompt')
end)

h.test('prompt: full scope says how many commits of a branch are not listed', function()
  local hs = guide.hunks(diff.parse(difftext(base_diff)))
  local many = {}
  for i = 1, 15 do
    many[i] = 'commit ' .. i
  end
  local layers = {
    { name = 'a', parent = 'main', commits = many, commit_count = 40 },
    { name = 'b', parent = 'a', commits = { 'only one' }, commit_count = 1 },
  }
  local text = gp.build({ repo = 'r', branch = 'b', base = 'main', stack = { kind = 'full', trunk = 'main', layers = layers } }, hs)
  h.ok(text:find('  - commit 15\n  - ... and 25 more\n- b:\n  - only one\n', 1, true), text)
  h.ok(not text:find('and 0 more', 1, true))
end)

h.test('prompt: a plain branch review has no stack wording', function()
  local hs = guide.hunks(diff.parse(difftext(base_diff)))
  local text = gp.build({ repo = 'r', branch = 'feat', base = 'main' }, hs)
  local msg = text:sub((text:find('\n---\n', 1, true)))
  h.ok(msg:find('Changes: feat compared with main\n', 1, true), msg)
  h.ok(not msg:find('stack', 1, true), 'no mention of a stack')
end)

h.test('prompt: size budget sends the largest hunks as an index', function()
  local big = { '@@ -1,0 +1,200 @@ big' }
  for i = 1, 200 do
    big[#big + 1] = '+line ' .. i .. ' ' .. string.rep('x', 40)
  end
  local d = vim.deepcopy(base_diff)
  d[#d + 1] = { path = 'src/big.ts', hunks = { big } }
  local hs = guide.hunks(diff.parse(difftext(d)))
  local text, info = gp.build({ repo = 'r', branch = 'b', base = 'main' }, hs, { budget = 2000 + #gp.SYSTEM })
  h.eq(1, info.abridged)
  h.ok(#text <= 2000 + #gp.SYSTEM)
  h.ok(text:find('so 1 hunk is marked [abridged]', 1, true))
  h.ok(text:find('The files are in the current directory', 1, true))
  h.ok(text:find('@@ -1,0 +1,200 @@ big  [abridged: +200 -0, 200 lines]', 1, true))
  h.ok(text:find('6|+line 6 ', 1, true) and not text:find('+line 7 ', 1, true), 'first lines only, numbered')
  h.ok(text:find('[... 194 more lines]', 1, true))
  -- small hunks stay in full
  h.ok(text:find('\n@@ h1 src/a.ts @@\n@@ -1,3 +1,3 @@ function a\n1| one\n', 1, true))
  -- generous budget: nothing abridged
  local _, info2 = gp.build({ repo = 'r', branch = 'b', base = 'main' }, hs, { budget = 1e6 })
  h.eq(0, info2.abridged)
  h.eq('full', info2.level)
end)

local function many_hunks(n, lines_per)
  local hs = {}
  for i = 1, n do
    local text = {}
    for k = 1, lines_per do
      text[k] = '+line ' .. k .. ' of a small hunk number ' .. i
    end
    hs[i] = { id = 'h' .. i, file_idx = i, hunk_idx = 1, path = 'src/dir/file' .. i .. '.ts', old_path = 'src/dir/file' .. i .. '.ts',
      status = 'M', header = '@@ -1,10 +1,10 @@', added = lines_per, removed = 0, text = text }
  end
  return hs
end

h.test('prompt: the whole message fits the budget, or the request is refused', function()
  local ctx = { repo = 'r', branch = 'b', base = 'main', diff_cmd = 'git diff abc123' }
  -- many small hunks: abridging alone cannot fit, so the diff collapses to per-file entries
  local hs = many_hunks(2000, 10)
  local msg, info = gp.user_message(ctx, hs, { budget = 150000 })
  h.ok(msg, info)
  h.ok(#msg <= 150000, #msg)
  h.eq('files', info.level)
  h.ok(msg:find('src/dir/file1999.ts (+10 -0): h1999', 1, true))
  h.ok(msg:find('git diff abc123 -- <path>', 1, true), 'tells the model how to read a file diff')
  h.ok(not msg:find('\n@@ h1 ', 1, true), 'no hunk bodies')
  -- abridging is enough for fewer hunks
  msg, info = gp.user_message(ctx, many_hunks(400, 30), { budget = 150000 })
  h.ok(#msg <= 150000, #msg)
  h.eq('abridged', info.level)
  h.ok(info.abridged > 0)
  -- so many files that even the file list does not fit: refused with advice
  local none, err = gp.user_message(ctx, many_hunks(5000, 10), { budget = 150000 })
  h.eq(nil, none)
  h.ok(err:find('too large for one guide', 1, true) and err:find('layer', 1, true), err)
  -- build() counts the methodology too
  local full = gp.build(ctx, many_hunks(400, 30), { budget = 150000 })
  h.ok(#full <= 150000, #full)
end)

h.test('claude args: restricted, read-only, schema, model, stdin prompt', function()
  local argv, stdin = ai.providers.claude.build({ prompt = 'P', schema = '{"type":"object"}', model = 'opus', name = 'revuey guide: x' })
  h.eq('P', stdin)
  local s = table.concat(argv, ' ')
  for _, flag in ipairs({ '-p', '--output-format stream-json', '--verbose', '--permission-mode dontAsk', '--tools Read,Grep,Glob,Bash',
    '--restricted', '--safe-mode', '--strict-mcp-config',
    '--json-schema {"type":"object"}', '--model opus', '--name revuey guide: x' }) do
    h.ok(s:find(flag, 1, true), 'missing ' .. flag)
  end
  local function value(flag)
    for i, a in ipairs(argv) do
      if a == flag then
        return argv[i + 1]
      end
    end
  end
  -- exactly what was verified against the real CLI (docs/ARCHITECTURE.md, decision 9)
  h.eq('Read,Grep,Glob,Bash(git diff:*),Bash(git log:*),Bash(git show:*)', value('--allowedTools'))
  h.eq('Bash(git * --out*)', value('--disallowedTools'))
  -- settings files (their allow rules and hooks) must not apply: no --setting-sources at all
  h.eq(nil, value('--setting-sources'))
  h.ok(not s:find('--no-session-persistence', 1, true), 'session kept for follow-up questions')
  local argv2 = ai.providers.claude.build({ prompt = 'P' })
  h.ok(not vim.tbl_contains(argv2, '--model'), 'no model flag by default')
  -- escape hatch: ai.restricted = false loads the user's settings (login via env/apiKeyHelper),
  -- never the repo's
  local open_argv = ai.providers.claude.build({ prompt = 'P', restricted = false })
  h.ok(not vim.tbl_contains(open_argv, '--restricted') and not vim.tbl_contains(open_argv, '--safe-mode'))
  local i = assert(vim.iter(ipairs(open_argv)):find(function(_, a)
    return a == '--setting-sources'
  end))
  h.eq('user', open_argv[i + 1])
  h.eq('Bash(git * --out*)', open_argv[vim.iter(ipairs(open_argv)):find(function(_, a)
    return a == '--disallowedTools'
  end) + 1], 'same tool rules either way')
  -- the login error points at the setting
  local msg = ai.explain_error('Invalid API key · Please run /login')
  h.ok(msg:find('not logged in', 1, true) and msg:find('ai.restricted', 1, true), msg)
end)

h.test('NDJSON stream parser: progress, partial lines, result', function()
  local p = ai.providers.claude.stream('/repo')
  local lines = {
    vim.json.encode({ type = 'system', subtype = 'hook_started', session_id = 'S' }),
    vim.json.encode({ type = 'system', subtype = 'init', session_id = 'S', model = 'claude-x' }),
    vim.json.encode({ type = 'assistant', message = { content = { { type = 'tool_use', name = 'Read', input = { file_path = '/repo/src/cart.ts' } } } } }),
    vim.json.encode({ type = 'assistant', message = { content = { { type = 'tool_use', name = 'Grep', input = { pattern = 'total' } } } } }),
    'not json',
    vim.json.encode({ type = 'result', subtype = 'success', is_error = false, session_id = 'S', structured_output = { title = 'T' }, total_cost_usd = 0.5 }),
  }
  local all = table.concat(lines, '\n') .. '\n'
  local evs = {}
  -- feed in awkward chunks
  for i = 1, #all, 7 do
    vim.list_extend(evs, p:feed(all:sub(i, i + 6)))
  end
  vim.list_extend(evs, p:finish())
  h.eq({ 'init', 'progress', 'progress', 'result' }, vim.tbl_map(function(e)
    return e.type
  end, evs))
  h.eq('claude-x', evs[1].model)
  h.eq('reading src/cart.ts', evs[2].text)
  h.eq('searching for total', evs[3].text)
  h.eq(true, p.result.ok)
  h.eq({ title = 'T' }, p.result.output)
  h.eq('S', p.result.session_id)
  h.eq(1, p.bad)
  -- error result, unterminated last line
  local p2 = ai.providers.claude.stream()
  p2:feed(vim.json.encode({ type = 'result', is_error = true, result = 'Invalid API key · Please run /login' }))
  p2:finish()
  h.eq(false, p2.result.ok)
  h.ok(ai.explain_error(p2.result.error):find('not logged in', 1, true))
  -- structured output only in the StructuredOutput tool call
  local p3 = ai.providers.claude.stream()
  p3:feed(vim.json.encode({ type = 'assistant', message = { content = { { type = 'tool_use', name = 'StructuredOutput', input = { title = 'X' } } } } }) .. '\n')
  p3:feed(vim.json.encode({ type = 'result', subtype = 'success', is_error = false, result = '' }) .. '\n')
  h.eq({ title = 'X' }, p3.result.output)
end)

h.test('validation: unknown ids, duplicates, empty sections, missed hunks', function()
  local hs = guide.hunks(diff.parse(difftext(base_diff)))
  local g, w = guide.validate({
    title = 'T\nsecond line',
    summary = 'S',
    sections = {
      { title = 'A', overview = 'o', hunks = { { id = 'h2', note = '  a\n note ' }, { id = 'h999' }, { id = 'H2' } } },
      { title = '', overview = 'o', hunks = { { id = 'h3' } } },
      { title = 'Empty', overview = 'o', hunks = { { id = 'h42' } } },
      'garbage',
    },
    unplaced = { 'h4', 'h2', 'h77' },
  }, hs)
  h.eq('T second line', g.title)
  h.eq({ 'A', 'Untitled section', guide.OTHER_TITLE }, vim.tbl_map(function(x)
    return x.title
  end, g.sections))
  h.eq({ { id = 'h2', note = 'a note' } }, g.sections[1].hunks)
  h.eq({ { id = 'h1' }, { id = 'h4' } }, g.sections[3].hunks, 'missed + unplaced go to Other changes, in diff order')
  h.eq(true, g.sections[3].other)
  h.eq({ unknown = 2, duplicates = 1, missed = 1, unplaced = 1 }, w)
end)

h.test('validation: failures and JSON repair', function()
  local hs = guide.hunks(diff.parse(difftext(base_diff)))
  local g, err = guide.validate({ title = 'T', sections = { { title = 'x', hunks = { { id = 'h99' } } } } }, hs)
  h.eq(nil, g)
  h.ok(err:find('no sections survived validation %(1 unknown hunk id%)'), err)
  g, err = guide.validate('sorry, no json', hs)
  h.eq(nil, g)
  h.ok(err:find('not valid JSON'))
  g, err = guide.validate({ title = 'T', sections = {} }, hs)
  h.eq(nil, g)
  -- fenced and chatty output is repaired
  local text = 'Sure!\n```json\n' .. vim.json.encode({ title = 'R', summary = '', sections = { { title = 'A', overview = '', hunks = { { id = 'h1' } } } }, unplaced = {} }) .. '\n```\nDone.'
  g = guide.validate(text, hs)
  h.eq('R', g.title)
  h.eq({ 'A', guide.OTHER_TITLE }, vim.tbl_map(function(x)
    return x.title
  end, g.sections))
  h.eq(nil, guide.repair_json('{"a": '))
  h.eq({ a = 1 }, guide.repair_json('x {"a": 1} y'))
end)

h.test('section identity: order-independent, changes with any hunk', function()
  h.eq(guide.section_id({ 'a', 'b' }), guide.section_id({ 'b', 'a' }))
  h.ok(guide.section_id({ 'a', 'b' }) ~= guide.section_id({ 'a', 'c' }))
  h.eq(nil, guide.section_id({}))
end)

h.test('staleness: outdated sections, missing hunks omitted, new hunks at the end', function()
  local hs = guide.hunks(diff.parse(difftext(base_diff)))
  local g = assert(guide.validate({
    title = 'T', summary = 'S',
    sections = {
      { title = 'A', overview = 'o', hunks = { { id = 'h1' }, { id = 'h2', note = 'n' } } },
      { title = 'B', overview = 'o', hunks = { { id = 'h3' } } },
    },
    unplaced = { 'h4' },
  }, hs))
  local rec = guide.record(g, hs, { key = { repo = '/r', branch = 'b', base = 'main' }, generator = { model = 'm' } })
  h.eq(3, #rec.sections)
  h.eq('n', rec.sections[1].hunks[2].note)
  h.eq(nil, rec.sections[1].hunks[1].id, 'records store anchors, not ids')
  -- unchanged diff: fresh
  local fresh = guide.resolve(rec, hs)
  h.eq(false, fresh.stale)
  h.eq({ 2, 1, 1 }, vim.tbl_map(function(s)
    return #s.items
  end, fresh.sections))
  h.eq('n', fresh.sections[1].items[2].note)
  local id_a = fresh.sections[1].id
  h.eq(guide.section_id({ hs[1].hash, hs[2].hash }), id_a)
  -- replace hunk h2 by a change elsewhere in the file (nothing overlaps it) and add a new file
  local edited = vim.deepcopy(base_diff)
  edited[1].hunks[2] = { '@@ -30,2 +30,3 @@', ' thirty', '+thirty and a half', ' thirty-one' }
  edited[#edited + 1] = { path = 'src/new.ts', hunks = { { '@@ -0,0 +1,1 @@', '+new' } } }
  local hs2 = guide.hunks(diff.parse(difftext(edited)))
  local res = guide.resolve(rec, hs2)
  h.eq(true, res.stale)
  h.eq(1, res.outdated)
  h.eq(2, res.new)
  h.eq({ 'A', 'B', guide.OTHER_TITLE, 'Not in guide' }, vim.tbl_map(function(s)
    return s.title
  end, res.sections))
  h.eq(true, res.sections[1].outdated)
  h.eq(1, res.sections[1].missing)
  h.eq({ 'h1' }, vim.tbl_map(function(i)
    return i.hunk.id
  end, res.sections[1].items), 'the changed hunk is omitted')
  h.ok(res.sections[1].id ~= id_a, 'a section whose hunks changed has a new identity (un-reviewed)')
  h.eq(fresh.sections[2].id, res.sections[2].id, 'untouched sections keep their identity')
  h.eq({ 'h2', 'h5' }, vim.tbl_map(function(i)
    return i.hunk.id
  end, res.sections[4].items))
  h.eq('new', res.sections[4].kind)
end)

local function reanchor_rec(diff_spec, sections)
  local hs = guide.hunks(diff.parse(difftext(diff_spec)))
  local g = assert(guide.validate({ title = 'T', summary = 'S', sections = sections }, hs))
  return guide.record(g, hs, { key = { repo = '/r', branch = 'b', base = 'main' } }), hs
end

local function titles_of(res)
  return vim.tbl_map(function(s)
    return { s.title, vim.tbl_map(function(i)
      return i.hunk.id .. (i.edited and '*' or '')
    end, s.items) }
  end, res.sections)
end

h.test('re-anchoring: an edited hunk stays in its section, marked edited', function()
  local rec, hs = reanchor_rec(base_diff, {
    { title = 'A', overview = 'o', hunks = { { id = 'h1' }, { id = 'h2', note = 'n' } } },
    { title = 'B', overview = 'o', hunks = { { id = 'h3' }, { id = 'h4' } } },
  })
  -- unchanged hunks: exactly as before (no edited marks, not stale, same identities)
  local fresh = guide.resolve(rec, hs)
  h.eq(false, fresh.stale)
  h.eq(0, fresh.edited)
  h.eq({ { 'A', { 'h1', 'h2' } }, { 'B', { 'h3', 'h4' } } }, titles_of(fresh))
  -- h2 edited in the working tree (one more line, lines below shifted): overlaps its old range
  local edited = vim.deepcopy(base_diff)
  edited[1].hunks[2] = { '@@ -10,2 +10,4 @@', ' ten', '+ten and a half', '+ten and three quarters', ' eleven' }
  local res = guide.resolve(rec, guide.hunks(diff.parse(difftext(edited))))
  h.eq({ { 'A', { 'h1', 'h2*' } }, { 'B', { 'h3', 'h4' } } }, titles_of(res), 'kept in its section, no "Not in guide"')
  h.eq('n', res.sections[1].items[2].note, 'the note stays with it')
  h.eq({ 0, false, 1 }, { res.sections[1].missing, res.sections[1].outdated, res.sections[1].edited })
  h.eq({ true, 0, 0, 1 }, { res.stale, res.outdated, res.new, res.edited })
  h.ok(res.sections[1].id ~= fresh.sections[1].id, 'its section identity changes with the hunk (marks reset)')
  h.eq(fresh.sections[2].id, res.sections[2].id)
  -- an edit that also shifts the new side of the hunks below it
  local shifted = vim.deepcopy(base_diff)
  shifted[1].hunks[1] = { '@@ -1,3 +1,5 @@ function a', ' one', '-two', '+TWO', '+two and a bit', '+more', ' three' }
  shifted[1].hunks[2] = { '@@ -10,2 +12,3 @@', ' ten', '+ten and a half', ' eleven' }
  local res2 = guide.resolve(rec, guide.hunks(diff.parse(difftext(shifted))))
  h.eq({ { 'A', { 'h1*', 'h2' } }, { 'B', { 'h3', 'h4' } } }, titles_of(res2))
  -- two hunks of one section merged by an edit between them: one edited hunk in that section
  local merged_rec = reanchor_rec({
    { path = 'src/a.ts', hunks = {
      { '@@ -1,3 +1,3 @@', ' one', '-two', '+TWO', ' three' },
      { '@@ -8,3 +8,3 @@', ' eight', '-nine', '+NINE', ' ten' },
    } },
  }, { { title = 'A', overview = 'o', hunks = { { id = 'h1' }, { id = 'h2' } } } })
  local merged = guide.resolve(merged_rec, guide.hunks(diff.parse(difftext({
    { path = 'src/a.ts', hunks = { {
      '@@ -1,10 +1,10 @@', ' one', '-two', '+TWO', ' three', '-four', '+FOUR', ' five', ' six', ' seven', ' eight', '-nine', '+NINE', ' ten',
    } } },
  }))))
  h.eq({ { 'A', { 'h1*' } } }, titles_of(merged))
  h.eq(0, merged.sections[1].missing)
end)

h.test('re-anchoring: the old side decides first; a grown hunk does not capture the next one', function()
  -- P and Q in one function, in two sections. P grows by 8 lines and Q is edited: P's new range
  -- now covers Q's old new-side range, but on the old side each overlaps only itself.
  local rec = reanchor_rec({
    { path = 'src/a.ts', hunks = {
      { '@@ -1,3 +1,3 @@ function f', ' a', '-b', '+B', ' c' },
      { '@@ -10,3 +10,3 @@ function f', ' j', '-k', '+K', ' l' },
    } },
  }, { { title = 'P', overview = 'o', hunks = { { id = 'h1' } } }, { title = 'Q', overview = 'o', hunks = { { id = 'h2' } } } })
  local grown = { '@@ -1,3 +1,11 @@ function f', ' a', '-b', '+B' }
  for i = 1, 8 do
    grown[#grown + 1] = '+more ' .. i
  end
  grown[#grown + 1] = ' c'
  local res = guide.resolve(rec, guide.hunks(diff.parse(difftext({
    { path = 'src/a.ts', hunks = { grown, { '@@ -10,3 +18,3 @@ function f', ' j', '-k', '+K!', ' l' } } },
  }))))
  h.eq({ { 'P', { 'h1*' } }, { 'Q', { 'h2*' } } }, titles_of(res))
  -- with nothing on the old side (a pure insertion moved), the new side still matches
  local rec2 = reanchor_rec({
    { path = 'src/b.ts', hunks = { { '@@ -4,0 +5,2 @@', '+x', '+y' } } },
  }, { { title = 'A', overview = 'o', hunks = { { id = 'h1' } } } })
  local res2 = guide.resolve(rec2, guide.hunks(diff.parse(difftext({
    { path = 'src/b.ts', hunks = { { '@@ -6,0 +6,2 @@', '+x', '+y!' } } },
  }))))
  h.eq({ { 'A', { 'h1*' } } }, titles_of(res2))
end)

h.test('re-anchoring: ambiguous matches and no match fall back to "Not in guide"', function()
  -- one guide hunk now overlapped by two current hunks (an edit split it): ambiguous
  local rec = reanchor_rec({
    { path = 'src/a.ts', hunks = { { '@@ -1,6 +1,6 @@', ' one', '-two', '+TWO', ' three', ' four', '-five', '+FIVE', ' six' } } },
    { path = 'src/b.ts', hunks = { { '@@ -1,1 +1,1 @@', '-x', '+y' } } },
  }, { { title = 'A', overview = 'o', hunks = { { id = 'h1' } } }, { title = 'B', overview = 'o', hunks = { { id = 'h2' } } } })
  local split = guide.resolve(rec, guide.hunks(diff.parse(difftext({
    { path = 'src/a.ts', hunks = {
      { '@@ -1,3 +1,3 @@', ' one', '-two', '+TWO!', ' three' },
      { '@@ -4,3 +4,3 @@', ' four', '-five', '+FIVE!', ' six' },
    } },
    { path = 'src/b.ts', hunks = { { '@@ -1,1 +1,1 @@', '-x', '+y' } } },
  }))))
  h.eq({ { 'A', {} }, { 'B', { 'h3' } }, { 'Not in guide', { 'h1', 'h2' } } }, titles_of(split))
  h.eq({ 1, true }, { split.sections[1].missing, split.sections[1].outdated })

  -- one current hunk overlapping guide hunks of two sections (an edit joined them): ambiguous
  local rec2 = reanchor_rec({
    { path = 'src/a.ts', hunks = {
      { '@@ -1,3 +1,3 @@', ' one', '-two', '+TWO', ' three' },
      { '@@ -8,3 +8,3 @@', ' eight', '-nine', '+NINE', ' ten' },
    } },
  }, { { title = 'A', overview = 'o', hunks = { { id = 'h1' } } }, { title = 'B', overview = 'o', hunks = { { id = 'h2' } } } })
  local joined = guide.resolve(rec2, guide.hunks(diff.parse(difftext({
    { path = 'src/a.ts', hunks = { {
      '@@ -1,10 +1,10 @@', ' one', '-two', '+TWO', ' three', '-four', '+FOUR', ' five', ' six', ' seven', ' eight', '-nine', '+NINE', ' ten',
    } } },
  }))))
  h.eq({ { 'A', {} }, { 'B', {} }, { 'Not in guide', { 'h1' } } }, titles_of(joined))

  -- no overlap (a change elsewhere in the file), another file, or a different function context
  local rec3 = reanchor_rec({
    { path = 'src/a.ts', hunks = { { '@@ -10,2 +10,3 @@ function ten', ' ten', '+ten and a half', ' eleven' } } },
  }, { { title = 'A', overview = 'o', hunks = { { id = 'h1' } } } })
  for _, spec in ipairs({
    { path = 'src/a.ts', hunks = { { '@@ -40,2 +40,3 @@ function ten', ' forty', '+forty and a half', ' forty-one' } } },
    { path = 'src/other.ts', hunks = { { '@@ -10,2 +10,3 @@ function ten', ' ten', '+ten and a bit', ' eleven' } } },
    { path = 'src/a.ts', hunks = { { '@@ -10,2 +10,3 @@ function nine', ' ten', '+ten and a bit', ' eleven' } } },
  }) do
    local res = guide.resolve(rec3, guide.hunks(diff.parse(difftext({ spec }))))
    h.eq({ { 'A', {} }, { 'Not in guide', { 'h1' } } }, titles_of(res), spec.path .. ' ' .. spec.hunks[1][1])
    h.eq(0, res.edited)
  end
end)

-- Line notes: anchored like AI review findings (hunk id + line numbers within the hunk), checked
-- against what the prompt showed; bad anchors dropped and counted, never guessed; caps.
local function notes_of(g)
  local out = {}
  for si, s in ipairs(g.sections) do
    for _, r in ipairs(s.hunks) do
      for _, n in ipairs(r.line_notes or {}) do
        out[#out + 1] = { si, r.id, n.line, n.end_line, n.side, n.text }
      end
    end
  end
  return out
end

h.test('line notes: valid anchors kept with their side; bad ones dropped and counted', function()
  local hs = guide.hunks(diff.parse(difftext(base_diff)))
  local g, w = guide.validate({
    title = 'T', summary = 'S',
    sections = {
      { title = 'A', overview = 'o', hunks = { { id = 'h1' }, { id = 'h2' } }, line_notes = {
        { hunk = 'h1', line = 3, text = 'The new spelling.' },
        { hunk = 'h1', line = 2, text = 'The old one goes.' }, -- a deleted line: the old side
        { hunk = 'h2', line = 1, end_line = 3, text = 'A short range.' },
        { hunk = 'h1', line = 3, text = 'The new spelling.' }, -- exact duplicate
        { hunk = 'h9', line = 1, text = 'Unknown hunk.' },
        { hunk = 'h1', line = 5, text = 'Past the end of the hunk.' },
        { hunk = 'h1', line = 0, text = 'Zero.' },
        { hunk = 'h1', line = 2, end_line = 1, text = 'End before start.' },
        { hunk = 'h1', line = 1.5, text = 'Not an integer.' },
        { hunk = 'h1', text = 'No line.' },
        { hunk = 'h4', line = 1, text = 'A binary file has no lines.' },
        { hunk = 'h1', line = 1, text = '  \n ' }, -- empty
        'junk',
        -- a note on a hunk another section shows stays with that hunk (and counts there)
        { hunk = 'h3', line = 1, text = 'Shown in B.' },
      } },
      { title = 'B', overview = 'o', hunks = { { id = 'h3' } }, line_notes = {
        { hunk = 'h2', line = 2, text = 'Section A already has 3 notes.' }, -- over the section cap
        { hunk = 'h3', line = 2, text = 'Line\nbreaks\0 become spaces.' },
      } },
    },
    unplaced = {},
  }, hs)
  assert(g, w)
  h.eq({
    { 1, 'h1', 2, 2, 'old', 'The old one goes.' },
    { 1, 'h1', 3, 3, 'new', 'The new spelling.' },
    { 1, 'h2', 1, 3, 'new', 'A short range.' },
    { 2, 'h3', 1, 1, 'old', 'Shown in B.' }, -- h3's first line is deleted
    { 2, 'h3', 2, 2, 'new', 'Line breaks become spaces.' },
    -- h4 went to "Other changes" without notes
  }, notes_of(g))
  h.eq({ kept = 5, dropped = 11, unknown_hunk = 1, bad_line = 6, empty = 2, duplicates = 1, extra = 1 }, w.notes)
  h.eq('11 dropped (1 unknown hunk, 6 lines outside their hunks, 2 empty, 1 duplicate, 1 over the limit)', guide.dropped_text(w.notes))
  -- no notes at all: no note warnings
  local _, w2 = guide.validate({ title = 'T', sections = { { title = 'A', hunks = { 'h1' } } } }, hs)
  h.eq(nil, w2.notes)
  h.eq(nil, guide.dropped_text(w2.notes))
end)

h.test('line notes: only lines the prompt numbered; long ranges clamped; long text cut', function()
  local hs = guide.hunks(diff.parse(difftext(base_diff)))
  local function one(n, shown)
    local g, w = guide.validate({ title = 'T', sections = { { title = 'A', hunks = { 'h1', 'h2', 'h3', 'h4' }, line_notes = { n } } } }, hs, shown)
    return notes_of(g)[1], w.notes
  end
  -- an abridged hunk numbered only its first PREVIEW_LINES lines (h1 has 4, so all of them)
  local big = { '@@ -1,0 +1,20 @@' }
  for i = 1, 20 do
    big[#big + 1] = '+l' .. i
  end
  local bhs = guide.hunks(diff.parse(difftext({ { path = 'big.ts', hunks = { big } } })))
  local function bnote(n, shown)
    local g, w = guide.validate({ title = 'T', sections = { { title = 'A', hunks = { 'h1' }, line_notes = { n } } } }, bhs, shown)
    return notes_of(g)[1], w.notes
  end
  local ab = { level = 'abridged', abridged = { h1 = true } }
  h.eq({ 1, 'h1', 6, 6, 'new', 'x' }, (bnote({ hunk = 'h1', line = gp.PREVIEW_LINES, text = 'x' }, ab)))
  local n, w = bnote({ hunk = 'h1', line = gp.PREVIEW_LINES + 1, text = 'x' }, ab)
  h.eq(nil, n)
  h.eq(1, w.bad_line, 'past the preview: never shown, so never anchored')
  h.eq({ 1, 'h1', 7, 7, 'new', 'x' }, (bnote({ hunk = 'h1', line = 7, text = 'x' }, { level = 'abridged', abridged = {} })))
  -- files level: no lines were shown, so no note can anchor
  n, w = one({ hunk = 'h1', line = 1, text = 'x' }, { level = 'files', abridged = {} })
  h.eq({ nil, 1 }, { n, w.bad_line })
  -- a range longer than NOTE_MAX_RANGE is clamped to its first lines
  h.eq({ 1, 'h1', 2, 1 + guide.NOTE_MAX_RANGE, 'new', 'x' }, (bnote({ hunk = 'h1', line = 2, end_line = 20, text = 'x' })))
  -- the text is one line of at most NOTE_MAX_CHARS characters
  n = one({ hunk = 'h1', line = 1, text = string.rep('ä', 300) })
  h.eq(guide.NOTE_MAX_CHARS, vim.fn.strchars(n[6]))
  h.ok(n[6]:find('…$'))
  -- `id` for `hunk`, numbers as ids, upper case: normalised like section hunk references
  h.eq({ 1, 'h1', 1, 1, 'new', 'x' }, (one({ id = 'H1', line = 1, text = 'x' })))
end)

h.test('line notes: caps per section and per guide, in the model\'s order', function()
  local d = {}
  for i = 1, 8 do
    d[i] = { path = 'f' .. i .. '.ts', hunks = { { '@@ -1,1 +1,5 @@', '-a', '+1', '+2', '+3', '+4', '+5' } } }
  end
  local hs = guide.hunks(diff.parse(difftext(d)))
  local sections = {}
  for i = 1, 8 do
    local notes = {}
    for l = 1, 5 do
      notes[l] = { hunk = 'h' .. i, line = l + 1, text = 's' .. i .. 'l' .. l }
    end
    sections[i] = { title = 'S' .. i, hunks = { 'h' .. i }, line_notes = notes }
  end
  local g, w = guide.validate({ title = 'T', sections = sections }, hs)
  local kept = notes_of(g)
  h.eq(guide.NOTE_MAX, #kept)
  h.eq(12, guide.NOTE_MAX)
  h.eq(3, guide.NOTE_MAX_SECTION)
  -- 3 per section for the first 4 sections; nothing after the overall cap
  h.eq({ 's1l1', 's1l2', 's1l3' }, { kept[1][6], kept[2][6], kept[3][6] })
  h.eq('s4l3', kept[12][6])
  h.eq({ 12, 28, 28 }, { w.notes.kept, w.notes.dropped, w.notes.extra })
  h.eq(gp.MAX_NOTES_PER_SECTION, gp.SCHEMA.properties.sections.items.properties.line_notes.maxItems)
end)

h.test('line notes: stored with their lines, follow an edited hunk, survive loading; old guides load', function()
  local rec, hs = reanchor_rec(base_diff, {
    { title = 'A', overview = 'o', hunks = { { id = 'h1' }, { id = 'h2' } }, line_notes = {
      { hunk = 'h1', line = 3, text = 'New spelling.' },
      { hunk = 'h2', line = 2, text = 'The half.' },
      { hunk = 'h2', line = 1, end_line = 3, text = 'All of it.' },
    } },
    { title = 'B', overview = 'o', hunks = { { id = 'h3' }, { id = 'h4' } } },
  })
  h.eq(2, rec.version)
  h.eq({
    { line = 3, end_line = 3, side = 'new', text = 'New spelling.', lines = { '+TWO' }, before = { ' one', '-two' }, after = { ' three' } },
  }, rec.sections[1].hunks[1].line_notes)
  -- sorted by line: the range (1-3) first
  h.eq({ ' ten', '+ten and a half', ' eleven' }, rec.sections[1].hunks[2].line_notes[1].lines)
  -- unchanged: as stored
  local fresh = guide.resolve(rec, hs)
  h.eq(3, fresh.notes)
  h.eq(0, fresh.notes_lost)
  h.eq({ { line = 3, end_line = 3, side = 'new', text = 'New spelling.' } }, fresh.sections[1].items[1].line_notes)
  -- h2 edited right next to its notes: their lines and context are no longer found unchanged,
  -- so both are lost (counted, not guessed)
  local edited = vim.deepcopy(base_diff)
  edited[1].hunks[2] = { '@@ -10,2 +10,4 @@', ' ten', '+ten and a quarter', '+ten and a half', ' eleven' }
  local res = guide.resolve(rec, guide.hunks(diff.parse(difftext(edited))))
  h.eq(true, res.sections[1].items[2].edited)
  h.eq(nil, res.sections[1].items[2].line_notes)
  h.eq({ 1, 2 }, { res.notes, res.notes_lost })
  -- saved and loaded (sanitised on the way in)
  local dir = h.tmpdir('guide-notes-store')
  rec.generator = { generated_at = 5 }
  guide.save(dir, rec)
  local back = guide.load(dir, rec.key, rec.anchors)
  h.eq(rec.sections[1].hunks, back.sections[1].hunks)
  -- a hand-edited record: bad notes dropped on load
  local bad = vim.deepcopy(rec)
  bad.anchors = 'bad'
  bad.sections[1].hunks[1].line_notes = {
    { line = 'x', text = 'not a number' },
    { line = 2, end_line = 1, text = 'end before start' },
    { line = 1, end_line = 40, text = 'too long a range' },
    { line = 1, text = '' },
    { line = 2, side = 'sideways', text = 'Kept\nwith a known side.', lines = { 5 } },
  }
  guide.save(dir, bad)
  local loaded = guide.load(dir, bad.key, 'bad')
  h.eq({ { line = 2, end_line = 2, side = 'new', text = 'Kept with a known side.' } }, loaded.sections[1].hunks[1].line_notes)
  -- a version 1 guide (written before line notes) loads and resolves without notes
  local old = vim.deepcopy(rec)
  old.version, old.anchors = 1, 'old'
  for _, s in ipairs(old.sections) do
    for _, a in ipairs(s.hunks) do
      a.line_notes = nil
    end
  end
  guide.save(dir, old)
  local ores = guide.resolve(guide.load(dir, old.key, 'old'), hs)
  h.eq({ 0, 0, false }, { ores.notes, ores.notes_lost, ores.stale })
  h.eq({ { 'A', { 'h1', 'h2' } }, { 'B', { 'h3', 'h4' } } }, titles_of(ores))
end)


-- An edited hunk: a note follows its line only when the line and the context stored around it
-- are found again, unchanged, at exactly one place; a copy of a short line never takes it.
local function notes_after(orig, notes, edited)
  local rec = reanchor_rec(orig, { { title = 'A', overview = 'o', hunks = { 'h1' }, line_notes = notes } })
  local hs = guide.hunks(diff.parse(difftext(edited)))
  local res = guide.resolve(rec, hs)
  local out = {}
  for _, n in ipairs(res.sections[1].items[1] and res.sections[1].items[1].line_notes or {}) do
    out[#out + 1] = { n.line, n.text, hs[1].text[n.line] }
  end
  return out, res, rec
end

local guard = { { path = 'a.lua', hunks = { {
  '@@ -1,3 +1,8 @@ local function f(x)', ' local function f(x)', '+  if x == nil then', '+    log("nil input")',
  '+    return nil', '+  end', '+  local y = g(x)', '   return y', ' end',
} } } }
local guarded = { { path = 'a.lua', hunks = { {
  '@@ -1,3 +1,11 @@ local function f(x)', ' local function f(x)', '+  if not ready then', '+    log("not ready")',
  '+    return nil', '+  end', '+  if x == nil then', '+    log("nil input")', '+    return nil', '+  end',
  '+  local y = g(x)', '   return y', ' end',
} } } }

h.test('line notes on an edited hunk: a copy of the line at the old place never takes the note', function()
  -- the note's `return nil` (line 4) now follows a new guard whose own `return nil` sits at 4:
  -- the note goes with its context to line 8, the guard it was written for
  local kept, res = notes_after(guard, { { hunk = 'h1', line = 4, text = 'Early return for nil input.' } }, guarded)
  h.eq({ { 8, 'Early return for nil input.', '+    return nil' } }, kept)
  h.eq({ 1, 0 }, { res.notes, res.notes_lost })
  -- a range note keeps its span
  kept = notes_after(guard, { { hunk = 'h1', line = 4, end_line = 5, text = 'The nil guard ends.' } }, guarded)
  h.eq({ { 8, 'The nil guard ends.', '+    return nil' } }, kept)
  -- the original guard deleted while the new one stays: not found, lost
  local only_new = { { path = 'a.lua', hunks = { {
    '@@ -1,3 +1,7 @@ local function f(x)', ' local function f(x)', '+  if not ready then', '+    log("not ready")',
    '+    return nil', '+  end', '+  local y = g(x)', '   return y', ' end',
  } } } }
  kept, res = notes_after(guard, { { hunk = 'h1', line = 4, text = 'Early return for nil input.' } }, only_new)
  h.eq({}, kept)
  h.eq({ 0, 1 }, { res.notes, res.notes_lost })
end)

h.test('line notes on an edited hunk: a deleted line\'s note never moves to another copy', function()
  local orig = { { path = 'b.lua', hunks = { {
    '@@ -1,2 +1,9 @@ function M.run(o)', ' function M.run(o)', '+  if not check(o) then', '+    return false', '+  end',
    '+  for _, x in ipairs(o) do', '+    if x.bad then', '+      return false', '+    end', '+  end', ' end',
  } } } }
  local edited = { { path = 'b.lua', hunks = { {
    '@@ -1,2 +1,8 @@ function M.run(o)', ' function M.run(o)', '+  assert(check(o))', '+  for _, x in ipairs(o) do',
    '+    if x.bad then', '+    return false', '+    end', '+  end', ' end',
  } } } }
  local kept, res = notes_after(orig, { { hunk = 'h1', line = 3, text = 'Bails out before the loop when the check fails.' } }, edited)
  h.eq({}, kept)
  h.eq({ 0, 1 }, { res.notes, res.notes_lost })
end)

h.test('line notes on an edited hunk: found again by context after lines added elsewhere; old records', function()
  local orig = { { path = 'c.lua', hunks = { {
    '@@ -1,2 +1,6 @@ function M.total(cart)', ' function M.total(cart)', '+  local sum = 0', '+  for _, item in ipairs(cart.items) do',
    '+    sum = sum + item.price * item.qty', '+  end', '+  return round(sum)', ' end',
  } } } }
  local edited = { { path = 'c.lua', hunks = { {
    '@@ -1,2 +1,8 @@ function M.total(cart)', ' function M.total(cart)', '+  assert(cart.items)', '+  log("total")',
    '+  local sum = 0', '+  for _, item in ipairs(cart.items) do', '+    sum = sum + item.price * item.qty', '+  end',
    '+  return round(sum)', ' end',
  } } } }
  local notes = { { hunk = 'h1', line = 4, text = 'Price times quantity, per item.' } }
  local kept, res, rec = notes_after(orig, notes, edited)
  h.eq({ { 6, 'Price times quantity, per item.', '+    sum = sum + item.price * item.qty' } }, kept)
  h.eq({ 1, 0 }, { res.notes, res.notes_lost })
  -- a record without stored context (written before it was stored): a unique, distinctive line
  -- is still found; a weak one (`return nil`, `end`) is lost even when it is unique
  local old = vim.deepcopy(rec)
  for _, n in ipairs(old.sections[1].hunks[1].line_notes) do
    n.before, n.after = nil, nil
  end
  res = guide.resolve(old, guide.hunks(diff.parse(difftext(edited))))
  h.eq(6, res.sections[1].items[1].line_notes[1].line)
  local _, _, grec = notes_after(guard, { { hunk = 'h1', line = 4, text = 'Early return.' } }, guard)
  for _, n in ipairs(grec.sections[1].hunks[1].line_notes) do
    n.before, n.after = nil, nil
  end
  local nilonly = { { path = 'a.lua', hunks = { {
    '@@ -1,3 +1,8 @@ local function f(x)', ' local function f(x)', '+  if x == false then', '+    log("false input")',
    '+    return nil', '+  end', '+  local y = g(x)', '   return y', ' end',
  } } } }
  res = guide.resolve(grec, guide.hunks(diff.parse(difftext(nilonly))))
  h.eq({ 0, 1 }, { res.notes, res.notes_lost }, 'a weak line alone is no anchor')
end)

h.test('line notes: merged hunks keep notes found again; notes of vanished hunks are counted', function()
  local orig = { { path = 'c.lua', hunks = {
    { '@@ -1,3 +1,3 @@', ' local alpha = 1', '-local beta = compute_beta()', '+local beta = compute_beta(alpha)', ' local gamma = 3' },
    { '@@ -20,3 +20,3 @@', ' local tau = 20', '-local upsilon = compute_upsilon()', '+local upsilon = compute_upsilon(tau)', ' local value = 22' },
  } } }
  local rec = reanchor_rec(orig, { { title = 'A', overview = 'o', hunks = { 'h1', 'h2' }, line_notes = {
    { hunk = 'h1', line = 3, text = 'Beta now depends on alpha.' },
    { hunk = 'h2', line = 3, text = 'Upsilon now depends on tau.' },
  } } })
  local body = { '@@ -1,22 +1,22 @@', ' local alpha = 1', '-local beta = compute_beta()', '+local beta = compute_beta(alpha)', ' local gamma = 3' }
  for i = 4, 10 do
    body[#body + 1] = ' local v' .. i .. ' = ' .. i
  end
  vim.list_extend(body, { '-local mid = 11', '+local mid = 12' })
  for i = 12, 19 do
    body[#body + 1] = ' local w' .. i .. ' = ' .. i
  end
  vim.list_extend(body, { ' local tau = 20', '-local upsilon = compute_upsilon()', '+local upsilon = compute_upsilon(tau)', ' local value = 22' })
  local hs = guide.hunks(diff.parse(difftext({ { path = 'c.lua', hunks = { body } } })))
  local res = guide.resolve(rec, hs)
  h.eq(1, #res.sections[1].items, 'one merged hunk')
  h.eq({ 'Beta now depends on alpha.', 'Upsilon now depends on tau.' }, vim.tbl_map(function(n)
    return n.text
  end, res.sections[1].items[1].line_notes))
  h.eq('+local upsilon = compute_upsilon(tau)', hs[1].text[res.sections[1].items[1].line_notes[2].line])
  h.eq({ 2, 0 }, { res.notes, res.notes_lost })
  -- the file gone from the review: its notes are counted as lost
  local other = guide.hunks(diff.parse(difftext({ { path = 'z.lua', hunks = { { '@@ -1,1 +1,1 @@', '-q', '+r' } } } })))
  local gone = guide.resolve(rec, other)
  h.eq({ 0, 2 }, { gone.notes, gone.notes_lost })
end)

h.test('line notes: an end past the hunk is dropped; the record keeps at most 12 notes on load', function()
  local hs = guide.hunks(diff.parse(difftext(base_diff)))
  local g, w = guide.validate({ title = 'T', sections = { { title = 'A', hunks = { 'h1', 'h2', 'h3', 'h4' }, line_notes = {
    { hunk = 'h1', line = 2, end_line = 5, text = 'One past the last line.' },
    { hunk = 'h1', line = 2, end_line = 4, text = 'Up to the last line.' },
  } } } }, hs)
  h.eq({ { 1, 'h1', 2, 4, 'old', 'Up to the last line.' } }, notes_of(g))
  h.eq(1, w.notes.bad_line)
  -- a hand-edited record with 5 notes on each of 4 hunks: the first 12 survive loading
  local dir = h.tmpdir('guide-notes-cap')
  local key = { repo = '/r', branch = 'b', base = 'main' }
  local hunks = {}
  for i = 1, 4 do
    local list = {}
    for l = 1, 5 do
      list[l] = { line = l, text = 'n' .. i .. '.' .. l }
    end
    hunks[i] = { hash = 'x' .. i, line_notes = list }
  end
  guide.save(dir, { kind = 'revuey-guide', version = 2, key = key, anchors = 'cap', title = 'T',
    sections = { { title = 'A', overview = 'o', hunks = hunks } }, generator = { generated_at = 1 } })
  local n = 0
  for _, a in ipairs(guide.load(dir, key, 'cap').sections[1].hunks) do
    n = n + #(a.line_notes or {})
  end
  h.eq(guide.NOTE_MAX, n)
end)

h.test('storage: exact diff first, else the newest guide for the key; only that one is decoded', function()
  local dir = h.tmpdir('guide-store')
  local key = { repo = '/r', branch = 'feat', base = 'main' }
  h.eq(nil, guide.load(dir, key, 'x'))
  local function rec(anchors, t, title)
    return { kind = 'revuey-guide', version = 1, key = key, anchors = anchors, title = title, sections = {}, generator = { generated_at = t } }
  end
  guide.save(dir, rec('aaa', 100, 'old'))
  guide.save(dir, rec('bbb', 200, 'new'))
  guide.save(dir, rec('aaa', 150, 'old, regenerated'))
  guide.save(dir, { kind = 'revuey-guide', version = 1, key = { repo = '/r', branch = 'other', base = 'main' }, anchors = 'ccc', title = 'other key', sections = {}, generator = { generated_at = 999 } })
  h.eq('old, regenerated', guide.load(dir, key, 'aaa').title, 'newest guide for the exact diff')
  local decode, n = vim.json.decode, 0
  vim.json.decode = function(...)
    n = n + 1
    return decode(...)
  end
  h.eq('new', guide.load(dir, key, 'zzz').title)
  vim.json.decode = decode
  h.eq(1, n, 'the newest is found from file names')
  h.eq('other key', guide.load(dir, { repo = '/r', branch = 'other', base = 'main' }, nil).title)
end)

h.test('storage: keeps the newest guides per review key', function()
  local dir = h.tmpdir('guide-prune')
  local key = { repo = '/r', branch = 'feat', base = 'main' }
  local other = { repo = '/r', branch = 'other', base = 'main' }
  guide.save(dir, { kind = 'revuey-guide', key = other, anchors = 'o', title = 'o', sections = {}, generator = { generated_at = 1 } }, 2)
  for t = 1, 7 do
    guide.save(dir, { kind = 'revuey-guide', key = key, anchors = 'a' .. t, title = 't' .. t, sections = {}, generator = { generated_at = 100 + t } }, 3)
  end
  local files = vim.fn.glob(dir .. '/*', true, true)
  h.eq(4, #files, table.concat(files, '\n'))
  h.eq(nil, guide.load(dir, key, 'a4') and guide.load(dir, key, 'a4').title == 't4' or nil, 'pruned')
  h.eq('t5', guide.load(dir, key, 'a5').title)
  h.eq('o', guide.load(dir, other, 'o').title, 'other keys are untouched')
end)

h.test('storage: write errors are reported', function()
  local dir = h.tmpdir('guide-ro')
  local key = { repo = '/r', branch = 'feat', base = 'main' }
  vim.fn.mkdir(dir .. '/guides', 'p')
  vim.uv.fs_chmod(dir .. '/guides', 365) -- r-x
  local ok, err = pcall(guide.save, dir .. '/guides', { kind = 'revuey-guide', key = key, anchors = 'a', title = 't', sections = {}, generator = { generated_at = 1 } })
  vim.uv.fs_chmod(dir .. '/guides', 493)
  h.eq(false, ok)
  h.ok(tostring(err):find('cannot write guide', 1, true), tostring(err))
end)

h.test('state: section reviewed marks persist next to file marks and merge', function()
  local dir = h.tmpdir('guide-state')
  local st = state.load(dir, '/r', 'feat', 'main')
  state.set_reviewed(st, 'a.ts', 'k1', true)
  state.save(st)
  h.eq(true, (state.toggle_section(st, 's1')))
  local other = state.load(dir, '/r', 'feat', 'main') -- a second instance
  h.eq(true, state.section_reviewed(other, 's1'))
  h.eq(true, state.is_reviewed(other, 'a.ts', 'k1'))
  state.toggle_section(other, 's2')
  h.eq(false, (state.toggle_section(st, 's1')))
  local again = state.load(dir, '/r', 'feat', 'main')
  h.eq(false, state.section_reviewed(again, 's1'))
  h.eq(true, state.section_reviewed(again, 's2'), "the other instance's mark survives")
  h.eq(true, state.is_reviewed(again, 'a.ts', 'k1'))
end)

h.test('prose: wrapping, inline styles, lists, callouts, code', function()
  local out = prose.render(table.concat({
    'The cart applies **discount rules** before tax, via `applyDiscount` per item.',
    '',
    '> [!WARNING] Totals round half-even now.',
    '',
    '- first item that is long enough to wrap onto a second line',
    '- second',
    '',
    '```',
    'const x = 1;',
    '```',
  }, '\n'), 30)
  local text = vim.tbl_map(function(l)
    return l.text
  end, out)
  h.eq({
    'The cart applies discount',
    'rules before tax, via',
    'applyDiscount per item.',
    '',
    '▎ Warning: Totals round',
    '▎ half-even now.',
    '',
    '• first item that is long',
    '  enough to wrap onto a second',
    '  line',
    '• second',
    '',
    '  const x = 1;',
  }, text)
  for _, l in ipairs(out) do
    h.ok(vim.api.nvim_strwidth(l.text) <= 30, l.text)
  end
  local function has(line, group, s)
    for _, sp in ipairs(out[line].hls) do
      if sp[3] == group and out[line].text:sub(sp[1] + 1, sp[2]) == s then
        return true
      end
    end
    return false
  end
  -- each line knows its paragraph and its offset in it (cursor restore across re-wraps)
  h.eq({ 1, 1, 1, 2, 2 }, { out[1].para, out[2].para, out[3].para, out[5].para, out[6].para })
  h.eq({ 0, 26, 48 }, { out[1].off, out[2].off, out[3].off })
  h.ok(out[8].para ~= out[11].para, 'list items are separate paragraphs')
  h.ok(has(1, 'RevueyGuideBold', 'discount'))
  h.ok(has(2, 'RevueyGuideBold', 'rules'))
  h.ok(has(3, 'RevueyGuideCode', 'applyDiscount'))
  h.ok(has(5, 'RevueyGuideWarning', '▎'))
  h.ok(has(5, 'RevueyGuideBold', 'Warning'))
  h.ok(has(8, 'RevueyGuideListMarker', '•'))
  h.ok(has(13, 'RevueyGuideCode', '  const x = 1;'))
  -- snake_case is not emphasis; multibyte text wraps by display width
  h.eq('a snake_case_name', prose.render('a snake_case_name', 40)[1].text)
  local wide = prose.render('漢字漢字 漢字漢字 漢字漢字', 20)
  h.eq({ '漢字漢字 漢字漢字', '漢字漢字' }, vim.tbl_map(function(l)
    return l.text
  end, wide))
end)

h.test('guide layout: prose rows, hunks as in the diff, sections and side table', function()
  local files = diff.parse(difftext(base_diff))
  local doc = {
    { kind = 'prose', text = 'Title', role = 'title' },
    { kind = 'section', text = '1. A', section_idx = 1 },
    { kind = 'prose', text = 'overview', role = 'overview', section_idx = 1 },
    { kind = 'hunk', file_idx = 1, hunk_idx = 2, header = 'src/a.ts  @@ -10,2 +10,3 @@', path_len = 8, guide_id = 'h2', section_idx = 1,
      note = { { kind = 'prose', text = '  a note', role = 'note', section_idx = 1 } } },
    { kind = 'section', text = '2. B', section_idx = 2 },
    { kind = 'hunk', file_idx = 1, hunk_idx = 1, header = 'src/a.ts  @@ -1,3 +1,3 @@', path_len = 8, section_idx = 2 },
    { kind = 'hunk', file_idx = 3, header = 'logo.png', path_len = 8, section_idx = 2 },
  }
  local l = layout.compose_guide(files, doc)
  h.eq({
    'Title', '1. A', 'overview',
    'src/a.ts  @@ -10,2 +10,3 @@', '  a note', 'ten', 'ten and a half', 'eleven',
    '2. B',
    'src/a.ts  @@ -1,3 +1,3 @@', 'one', 'two', 'TWO', 'three',
    'logo.png', 'Binary file not shown',
  }, l.lines)
  h.eq('guide', l.kind)
  h.eq({ 'prose', 'meta', 'prose' }, { l.map[1].kind, l.map[2].kind, l.map[3].kind })
  h.eq('section', l.map[2].meta)
  h.eq({ 'meta', 'hunk', 'h2', 8 }, { l.map[4].kind, l.map[4].meta, l.map[4].guide_id, l.map[4].path_len })
  h.eq({ 'prose', true, 1, 'src/a.ts' }, { l.map[5].kind, l.map[5].note, l.map[5].file_idx, l.map[5].path })
  h.eq({ 'ctx', 10, 10, 2, 1 }, { l.map[6].kind, l.map[6].old_lnum, l.map[6].new_lnum, l.map[6].hunk_idx, l.map[6].line_idx })
  h.eq({ 'add', 11, 1 }, { l.map[7].kind, l.map[7].new_lnum, l.map[7].section_idx })
  h.eq(5, l.hunk_base[1][2], 'line k of a hunk is at hunk_base + k, notes included')
  h.eq(10, l.hunk_base[1][1])
  h.eq({ { row = 4, file_idx = 1, first_change = 7 }, { row = 10, file_idx = 1, first_change = 12 } }, l.hunks)
  h.eq({ { start_row = 2, end_row = 8, section_idx = 1 }, { start_row = 9, end_row = 16, section_idx = 2 } }, l.sections)
  h.eq({ [1] = 4, [3] = 15 }, l.file_rows)
  h.eq(13, layout.find_new_row(l, files, 'src/a.ts', 2))
  h.eq(7, layout.find_new_row(l, files, 'src/a.ts', 11))
  local folds = layout.fold_levels(l, 12, 3)
  h.eq({ '>1', '1' }, { folds[2], folds[3] })
  h.eq(nil, folds[1], 'the title is outside every fold')
  h.eq('>1', folds[9])
  -- each hunk block (header, notes, lines; or header + note for a file without a text diff) is a
  -- level-2 fold inside its section
  h.eq({ { start_row = 4, end_row = 8 }, { start_row = 10, end_row = 14 }, { start_row = 15, end_row = 16 } }, l.blocks)
  h.eq({ '>2', '2', '2', '>2', '2', '>2', '2' }, { folds[4], folds[5], folds[8], folds[10], folds[14], folds[15], folds[16] })
end)

h.run()
