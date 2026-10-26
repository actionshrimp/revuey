-- Build the forge-thread placement corpus (tests/data/forge_threads/) from real GitHub review
-- threads: a cases file of RIGHT-side threads with a snapshot of each file at the PR head.
--
--   nvim --headless --clean -l scripts/trim-forge-corpus.lua <cases.json> [out dir]
--
-- <cases.json>: a list of { repo, pr, path, line, start_line, original_line,
-- original_start_line, side, start_side, hunk (the first comment's diffHunk), file (the PR-head
-- snapshot, relative to the cases file) }, as collected with `gh api graphql` (reviewThreads
-- with path, line, startLine, originalLine, originalStartLine, diffSide, startDiffSide and the
-- first comment's diffHunk) plus the file at the PR's headRefOid. No authors, logins or bodies.
--
-- Each file is cut to the lines placement can look at (the thread's lines and ±MARGIN, which
-- covers forge_threads.RADIUS plus the hunk's context above), renumbered: line numbers and the
-- hunk header move by the slice offset. The expected placement (head trust on and off) is
-- computed on the slice, and the script refuses to write unless it equals the placement on the
-- whole file shifted by the offset. Nothing here runs during the tests.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path
local ft = require('revuey.forge_threads')

local src = assert(arg[1], 'usage: trim-forge-corpus.lua <cases.json> [out dir]')
local out = arg[2] or (root .. '/tests/data/forge_threads')
local srcdir = vim.fs.dirname(vim.fn.fnamemodify(src, ':p'))
local MARGIN = ft.RADIUS + 10

-- the repos the reviewers sampled (the cases file names the repo only)
local OWNERS = {
  TypeScript = 'microsoft/TypeScript',
  ruff = 'astral-sh/ruff',
  vscode = 'microsoft/vscode',
  deno = 'denoland/deno',
  neovim = 'neovim/neovim',
}

local function read(path)
  local fd = assert(io.open(path, 'rb'))
  local s = fd:read('*a')
  fd:close()
  return s
end

---Lines of a file (bytes kept, CR included), without the empty piece after a final newline.
local function split(text)
  local lines = vim.split(text, '\n', { plain = true })
  if lines[#lines] == '' then
    lines[#lines] = nil
  end
  return lines
end

local function nz(v)
  return v ~= vim.NIL and v or nil
end

---Placement of a case's thread on `lines` (every line shown, as in a new file), head trust on or off.
local function place(c, lines, at_head)
  local by, sorted = {}, {}
  for k = 1, #lines do
    by[k] = true
    sorted[k] = k
  end
  local ctx = {
    files = { { path = c.path, status = 'A', new_blob = 'HEAD' } },
    U = { by_path = { [c.path] = 1 } },
    rows = function()
      return { by_lnum = by, sorted = sorted }
    end,
    get_line = function(_, _, l)
      return lines[l]
    end,
  }
  local t = {
    path = c.path, line = c.line, start_line = c.start_line, original_line = c.original_line,
    original_start_line = c.original_start_line, side = c.side or 'RIGHT', start_side = c.start_side,
    subject = 'LINE', comments = { { diff_hunk = c.hunk } },
  }
  local p = ft.place(t, ctx, at_head and { head_blob = 'HEAD' } or nil)
  return { how = p.how, start_line = p.start_line, end_line = p.end_line }
end

local function shift_hunk(h, off)
  return (h:gsub('^@@ %-(%d+)(,?%d*) %+(%d+)(,?%d*) @@', function(a, ac, b, bc)
    return ('@@ -%d%s +%d%s @@'):format(math.max(1, tonumber(a) - off), ac, math.max(1, tonumber(b) - off), bc)
  end, 1))
end

local cases = vim.json.decode(read(src))
vim.fn.mkdir(out .. '/files', 'p')
local result, bytes, bad = {}, 0, {}
for i, raw in ipairs(cases) do
  local c = {
    repo = raw.repo, pr = raw.pr, path = raw.path, line = nz(raw.line), start_line = nz(raw.start_line),
    original_line = nz(raw.original_line), original_start_line = nz(raw.original_start_line),
    side = nz(raw.side) or 'RIGHT', start_side = nz(raw.start_side), hunk = raw.hunk,
  }
  local full = split(read(srcdir .. '/' .. raw.file))
  local nums = vim.tbl_filter(function(x)
    return x ~= nil
  end, { c.line, c.start_line })
  local lo = math.max(1, math.min(unpack(nums)) - MARGIN)
  local hi = math.min(#full, math.max(unpack(nums)) + MARGIN)
  local off = lo - 1
  local slice = vim.list_slice(full, lo, hi)
  local trimmed = vim.deepcopy(c)
  for _, k in ipairs({ 'line', 'start_line', 'original_line', 'original_start_line' }) do
    if trimmed[k] then
      trimmed[k] = trimmed[k] - off
    end
  end
  trimmed.hunk = shift_hunk(c.hunk, off)
  local expected = {}
  for mode, at_head in pairs({ at_head = true, no_head = false }) do
    local whole = place(c, full, at_head)
    local cut = place(trimmed, slice, at_head)
    expected[mode] = cut
    local same = whole.how == cut.how
      and (whole.start_line and whole.start_line - off) == cut.start_line
      and (whole.end_line and whole.end_line - off) == cut.end_line
    if not same then
      bad[#bad + 1] = ('%d %s#%d %s %s: whole %s, slice %s (offset %d)'):format(i, c.repo, c.pr, c.path, mode,
        vim.inspect(whole), vim.inspect(cut), off)
    end
  end
  local name = ('files/%02d-%s'):format(i, vim.fs.basename(c.path))
  local text = table.concat(slice, '\n') .. '\n'
  bytes = bytes + #text
  local fd = assert(io.open(out .. '/' .. name, 'wb'))
  fd:write(text)
  fd:close()
  result[i] = {
    source = { repo = OWNERS[c.repo] or c.repo, pr = c.pr, path = c.path, head_commit = vim.NIL, offset = off,
      lines = #full },
    slice = name,
    thread = {
      line = trimmed.line, start_line = trimmed.start_line or vim.NIL, original_line = trimmed.original_line or vim.NIL,
      original_start_line = trimmed.original_start_line or vim.NIL, side = trimmed.side,
      start_side = trimmed.start_side or vim.NIL, diff_hunk = trimmed.hunk,
    },
    expected = expected,
  }
end
if #bad > 0 then
  io.stderr:write('slices place differently from the whole files:\n' .. table.concat(bad, '\n') .. '\n')
  os.exit(1)
end
local fd = assert(io.open(out .. '/cases.json', 'w'))
-- one case per line: diffs of the corpus stay readable
local parts = {}
for _, r in ipairs(result) do
  parts[#parts + 1] = vim.json.encode(r)
end
fd:write('[\n' .. table.concat(parts, ',\n') .. '\n]\n')
fd:close()
print(('%d cases, %d bytes of slices; every slice places as its whole file (both modes)'):format(#result, bytes))
