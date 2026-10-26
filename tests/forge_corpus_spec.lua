-- Unit: forge_threads.place on real GitHub review threads (tests/data/forge_threads/, made by
-- scripts/trim-forge-corpus.lua from public PRs of TypeScript, ruff, vscode, deno and neovim).
-- Every case is placed with head trust on (the review shows the PR head's file) and off, and
-- must land where the corpus says: on GitHub's line, or listed apart ("outside"), never on a
-- guessed line. Each excerpt is a whole new file of the review (every line shown).
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
local ft = require('revuey.forge_threads')

local DIR = h.root .. '/tests/data/forge_threads'

local function read(path)
  local fd = assert(io.open(path, 'rb'))
  local s = fd:read('*a')
  fd:close()
  return s
end

local function nz(v)
  return v ~= vim.NIL and v or nil
end

local cases = vim.json.decode(read(DIR .. '/cases.json'))

---The case's thread and a placement context over its excerpt (all lines shown).
local function setup(c)
  local lines = vim.split(read(DIR .. '/' .. c.slice), '\n', { plain = true })
  if lines[#lines] == '' then
    lines[#lines] = nil
  end
  local by, sorted = {}, {}
  for k = 1, #lines do
    by[k] = true
    sorted[k] = k
  end
  local path = c.source.path
  local ctx = {
    files = { { path = path, status = 'A', new_blob = 'HEAD' } },
    U = { by_path = { [path] = 1 } },
    rows = function()
      return { by_lnum = by, sorted = sorted }
    end,
    get_line = function(_, _, l)
      return lines[l]
    end,
  }
  local th = c.thread
  local t = {
    path = path, line = nz(th.line), start_line = nz(th.start_line), original_line = nz(th.original_line),
    original_start_line = nz(th.original_start_line), side = th.side, start_side = nz(th.start_side),
    subject = 'LINE', comments = { { diff_hunk = th.diff_hunk } },
  }
  return t, ctx
end

h.test('the corpus: 37 cases from five public repos, excerpts only', function()
  h.eq(37, #cases)
  local repos = {}
  for _, c in ipairs(cases) do
    repos[c.source.repo] = true
    h.ok(c.source.pr and c.source.path and c.source.offset, vim.inspect(c.source))
    h.ok(c.thread.diff_hunk:match('^@@ '), c.slice)
  end
  h.eq({ 'astral-sh/ruff', 'denoland/deno', 'microsoft/TypeScript', 'microsoft/vscode', 'neovim/neovim' },
    vim.fn.sort(vim.tbl_keys(repos)))
end)

for i, c in ipairs(cases) do
  for _, mode in ipairs({ 'at_head', 'no_head' }) do
    local name = ('%02d %s#%d %s:%d (%s)'):format(i, c.source.repo, c.source.pr, c.source.path,
      c.thread.line + c.source.offset, mode == 'at_head' and 'at the PR head' or 'no head trust')
    h.test(name, function()
      local t, ctx = setup(c)
      local p = ft.place(t, ctx, mode == 'at_head' and { head_blob = 'HEAD' } or nil)
      local want = c.expected[mode]
      local got = { how = p.how, start_line = p.start_line, end_line = p.end_line }
      h.eq({ want.how, nz(want.start_line), nz(want.end_line) }, { got.how, got.start_line, got.end_line },
        ('%s#%d %s (excerpt lines; add %d for the file\'s)'):format(c.source.repo, c.source.pr, c.source.path, c.source.offset))
    end)
  end
end

h.run()
