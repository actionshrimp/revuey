-- Guided review prompt, output schema and user message (pure).
--
-- The methodology is adapted from plannotator's "Guided Review Organizer"
-- (packages/core/guide-prompt.ts, Apache-2.0/MIT), made hunk-level: the model groups engine-assigned
-- hunk ids (h1..hn) into ordered sections instead of whole files, and never sees or returns line
-- numbers it could get wrong.
local M = {}

---Output schema (additionalProperties: false everywhere).
M.SCHEMA = {
  type = 'object',
  additionalProperties = false,
  required = { 'title', 'summary', 'sections', 'unplaced' },
  properties = {
    title = { type = 'string' },
    summary = { type = 'string' },
    sections = {
      type = 'array',
      items = {
        type = 'object',
        additionalProperties = false,
        required = { 'title', 'overview', 'hunks' },
        properties = {
          title = { type = 'string' },
          overview = { type = 'string' },
          hunks = {
            type = 'array',
            items = {
              type = 'object',
              additionalProperties = false,
              required = { 'id' },
              properties = {
                id = { type = 'string', pattern = '^h[0-9]+$' },
                note = { type = 'string' },
              },
            },
          },
        },
      },
    },
    unplaced = { type = 'array', items = { type = 'string', pattern = '^h[0-9]+$' } },
  },
}

function M.schema_json()
  return vim.json.encode(M.SCHEMA)
end

M.SYSTEM = [[
# Guided Review Organizer

## Identity
You are a senior engineer who deeply understands this changeset. You are organizing it into a
guided review: an ordered sequence of sections that lets a reviewer understand the change in one
sitting. Order the sections the way the work is best understood, not by file path or diff size.

You are NOT hunting for bugs. You are NOT writing a findings report. For each section, tell the
reviewer what changed, why it exists, and what it implies. Give them the "this is a big diff, but
here is the key part" orientation they cannot get from reading files in path order.

## The diff and hunk ids
Every hunk in the diff below starts with a marker line `@@ h7 path/to/file @@`, followed by the
hunk exactly as git shows it. `h7` is the hunk's id. Sections reference hunks ONLY by these ids.
Never cite line numbers, and never invent ids.

## Voice
Write like a colleague explaining the change out loud to another capable engineer who has never
seen this codebase. The diff renders right under your words, so your words carry the why and the
shape of the change, not the code.
- Short sentences. Twenty-five words is the ceiling, and most sentences are shorter. One idea per
  sentence. If you reach for a dash or a semicolon, end the sentence instead.
- Plain words. Say file, function, module, request, the server. Not artifact, surface, primitive,
  backbone. Say what a thing does the first time you name it, then keep using the same name.
- Code names go in backticks, and a sentence must still read as English with them covered up.
  Two per sentence at most.
- No verdicts and no selling: not "elegant", "robust", "seamless", "critically", "simply".
  State the fact.

## Speed
The whole diff is in this message. Reading it once, carefully, is 90% of the job.
- The diff and the file list are your primary and usually your only source.
- A few TARGETED lookups are fine when a section's story needs one: a definition the diff uses,
  one call site. Use Read, Grep or Glob on the files in the current directory. Every lookup must
  answer a question you can name. "Understanding the codebase" is not a question.
- Do NOT explore the repository or read unchanged files "for context". If you catch yourself on
  a fourth tool call, stop and write the guide with what you have.
A slow, exhaustive guide is a failed guide: the reviewer is waiting for it.

## Output

### title
One line naming what the changeset does. Not a placeholder like "Code changes".

### summary
Markdown, 1-3 sentences: why this changeset exists and its overall shape. Use the commit
messages and the branch name. Do not list the sections.

### sections
Each section is a chapter of the review: a title, an overview, and the hunks it covers.

#### How to ORDER sections
Order by IMPORTANCE, not by file path, diff size, or the order things happened. The reviewer
should be able to stop after any section and have already seen what matters most.
1. The heart comes first: the part that, once understood, unlocks everything else. Entry point
   first, definitions before their users, cause before effect.
2. Then the consequences, in decreasing signal: call sites, downstream logic, tests for the new
   behavior. Tests go with the code they exercise unless they are trivial.
3. Glue and low-signal changes come LAST, grouped in one section: wiring, imports, renames,
   config, generated files. Give it a plain title ("Wiring and config") and a one or two
   sentence overview.

#### How to CHUNK sections
A section is a logical unit of change, not a file and not a folder.
- If hunks in three files changed for one reason, that is ONE section.
- A file's hunks may be split across sections. If one file has two unrelated changes, put each
  hunk in the section it belongs to. Never default to one section per file.
- Unrelated pieces of work (two features, a feature plus a refactor) never share a section.
- Within a section, list hunks in reading order: definitions before their users.
- Typically 2-6 sections. Never more than 10. A small change may need only one section.

#### Section fields
- **title**: concept level, for example "Discount rules for cart totals". NEVER a file name
  paraphrase like "Changes to cart.ts".
- **overview**: Markdown, 2-5 sentences, in this order:
  1. What changed here, concretely.
  2. Why it exists, including non-obvious decisions ("X instead of Y because Z").
  3. The key implications: behavior, API or data contracts, performance, operations.
  Where one section carries most of the risk or deserves the closest read, say so plainly.
  For a genuinely high-risk behavior or contract change, add a callout on its own line:
  `> [!IMPORTANT] ...` or `> [!WARNING] ...`. Most sections have none.
  Markdown only where it sharpens the prose: backticks for code names, **bold** for at most one
  clause a skimming reviewer must not miss, a short bullet list for 3+ parallel changes. Never
  paste code from the diff; it renders under your overview already.
- **hunks**: the hunk ids in this section, each as `{"id": "h7"}`, optionally with a `note`: one
  short line (under 15 words) saying what THIS hunk contributes, when that is not obvious from
  the overview. Most hunks need no note. Do not repeat the overview.

### unplaced
Hunk ids that belong in no section: pure noise. This should be rare. Use an empty array when
every hunk is placed. Glue usually belongs in the trailing glue section instead.

## Coverage rule (hard constraint)
Every hunk id must appear EXACTLY ONCE: in one section's `hunks`, or in `unplaced`. Never twice.
Never omitted.

## Calibration: guide, not review
Explain and orient. Pointing out where risk concentrates IS orientation. Hunting for bugs is not.
If you notice what looks like a real bug while reading, mention it briefly in that section's
overview, in a `> [!WARNING]` callout. Do not go looking for problems.

## Hard constraints
- Never use em-dashes or en-dashes anywhere, and never "--" standing in for one. Use commas,
  colons or separate sentences.
- No emoji.
- title: one line. summary: at most 3 sentences. overview: at most 5 sentences.
- Only ids from the diff. Every id exactly once.
- Your text is read next to the rendered diff. Never mention hunk ids, markers, abridged
  hunks or these instructions in it.

## Pipeline
1. Read the whole diff and the file list.
2. Identify the logical groupings of change, across files and within files. This is thinking,
   not tool calls.
3. Order the sections: the heart first, then consequences, then glue.
4. Write the title, summary and each overview.
5. Verify coverage: every hunk id appears exactly once. Fix any that is missing or duplicated.
6. Return the structured output.
]]

local function counts(h)
  return ('+%d -%d'):format(h.added, h.removed)
end

M.PREVIEW_LINES = 6

---Lines of one hunk in the diff section: full, or an index entry ("abridged").
local function hunk_lines(h, abridged)
  local out = { '', ('@@ %s %s @@'):format(h.id, h.path) }
  if not h.hunk_idx then
    out[#out + 1] = h.text[1]
  elseif abridged then
    out[#out + 1] = h.header .. '  [abridged: ' .. counts(h) .. ', ' .. #h.text .. ' lines]'
    for i = 1, math.min(M.PREVIEW_LINES, #h.text) do
      out[#out + 1] = h.text[i]
    end
    out[#out + 1] = '[... ' .. math.max(#h.text - M.PREVIEW_LINES, 0) .. ' more lines]'
  else
    out[#out + 1] = h.header
    vim.list_extend(out, h.text)
  end
  return out
end

local function size(lines)
  local n = 0
  for _, l in ipairs(lines) do
    n = n + #l + 1
  end
  return n
end

---@class revuey.GuideStackContext
---@field kind 'layer'|'full' one branch (layer scope) or the whole stack (full scope)
---@field index? integer      layer scope: which layer (1 = bottom)
---@field trunk string
---@field layers {name: string, parent: string, commits?: string[]}[] bottom first; commits newest first

---@class revuey.GuideContext
---@field repo string        repo name
---@field branch string      new side label (branch or layer)
---@field base string        old side label
---@field stack? revuey.GuideStackContext the review's scope when it is part of a stack
---@field uncommitted? boolean some changes are uncommitted (working tree)
---@field commits? string[]  commit subjects, newest first
---@field diff_cmd? string   command that shows this diff, e.g. "git diff <merge-base>"

---User message: context, file list with counts and ids, then the diff with id markers. The whole
---message is kept within `opts.budget` characters, in three steps:
---  full      every hunk in full;
---  abridged  the largest hunks become index entries (header, counts, first lines);
---  files     no hunk bodies at all: the file list (with each file's ids) is the diff, and the
---            model reads what it needs with `git diff`;
---and when even the file list does not fit, nothing is sent (nil + a message).
---@param ctx revuey.GuideContext
---@param hunks revuey.GuideHunk[]
---@param opts? {budget?: integer}
---@return string? message
---@return {level: 'full'|'abridged'|'files', abridged: integer}|string info, or the error
function M.user_message(ctx, hunks, opts)
  local budget = (opts and opts.budget) or 150000
  local head = {}
  local function add(s)
    head[#head + 1] = s
  end
  add('Organize the following code changes into a guided review.')
  add('')
  add(('Repository: %s'):format(ctx.repo))
  local st = ctx.stack
  local by_branch = false
  if st and st.kind == 'full' then
    local top = st.layers[#st.layers]
    add(('Changes: the whole stack from %s up to %s'):format(st.trunk, top and top.name or ctx.branch))
    add('')
    add(('This review covers a whole stack of %d branches, each built on the one before it, bottom first:'):format(#st.layers))
    for i, l in ipairs(st.layers) do
      add(('%d. %s (on %s)'):format(i, l.name, l.parent))
    end
    add('Call it "this stack". When it helps the reader, say which branch introduced a change.')
    by_branch = vim.iter(st.layers):any(function(l)
      return l.commits ~= nil
    end)
  elseif st and st.kind == 'layer' then
    add(('Changes: branch %s compared with its parent branch %s'):format(ctx.branch, ctx.base))
    add('')
    local chain = { st.trunk }
    for _, l in ipairs(st.layers) do
      chain[#chain + 1] = l.name
    end
    add(('This review covers only the branch `%s`: its own changes on top of its parent branch `%s`.'):format(ctx.branch, ctx.base))
    add(('The branch is layer %d of a stack of %d branches (%s), but the other branches are not part of this review.'):format(
      st.index,
      #st.layers,
      table.concat(chain, ' <- ')
    ))
    add('Call it "this branch" or "this change", never "this stack". Mention the surrounding stack only when it is needed to explain something.')
  else
    add(('Changes: %s compared with %s'):format(ctx.branch, ctx.base))
  end
  if ctx.uncommitted then
    add('Some of these changes are uncommitted work in the working tree.')
  end
  if by_branch then
    add('')
    add('Commits by branch (bottom first, newest first within each):')
    for _, l in ipairs(st.layers) do
      add('- ' .. l.name .. ':')
      local cs = l.commits or {}
      for i, c in ipairs(cs) do
        if i > 15 then
          add(('  - ... and %d more'):format(#cs - 15))
          break
        end
        add('  - ' .. c)
      end
      if #cs == 0 then
        add('  - (no commits)')
      end
    end
  elseif ctx.commits and #ctx.commits > 0 then
    add('')
    add('Commits (newest first):')
    for i, c in ipairs(ctx.commits) do
      if i > 30 then
        add(('... and %d more'):format(#ctx.commits - 30))
        break
      end
      add('- ' .. c)
    end
  end
  -- files in diff order, with their hunk ids
  add('')
  add('Changed files (+added -removed: hunk ids):')
  local order, per_file = {}, {}
  for _, h in ipairs(hunks) do
    local f = per_file[h.file_idx]
    if not f then
      f = { path = h.path, old_path = h.old_path, status = h.status, added = 0, removed = 0, ids = {} }
      per_file[h.file_idx] = f
      order[#order + 1] = f
    end
    f.added, f.removed = f.added + h.added, f.removed + h.removed
    f.ids[#f.ids + 1] = h.id
  end
  for _, f in ipairs(order) do
    local name = (f.old_path ~= f.path) and (f.old_path .. ' -> ' .. f.path) or f.path
    local status = ({ A = ' [added]', D = ' [deleted]', R = ' [renamed]' })[f.status] or ''
    add(('%s%s (+%d -%d): %s'):format(name, status, f.added, f.removed, table.concat(f.ids, ' ')))
  end
  add('')
  add(('Hunk ids: h1 to h%d. Every id must appear exactly once in a section or in `unplaced`.'):format(#hunks))

  local bodies, total = {}, size(head) + 8 -- + 'Diff:' heading
  for i, h in ipairs(hunks) do
    bodies[i] = hunk_lines(h, false)
    total = total + size(bodies[i])
  end
  local NOTE = 400 -- room for the explanation added when abridging
  local level, n_abridged = 'full', 0
  if total > budget then
    -- abridge the largest hunks first until it fits
    level = 'abridged'
    local order_i = {}
    for i in ipairs(hunks) do
      order_i[i] = i
    end
    local sizes = {}
    for i, b in ipairs(bodies) do
      sizes[i] = size(b)
    end
    table.sort(order_i, function(a, b)
      if sizes[a] ~= sizes[b] then
        return sizes[a] > sizes[b]
      end
      return a < b
    end)
    total = total + NOTE
    for _, i in ipairs(order_i) do
      if total <= budget then
        break
      end
      local short = hunk_lines(hunks[i], true)
      local saved = sizes[i] - size(short)
      if saved > 0 then
        bodies[i] = short
        total = total - saved
        n_abridged = n_abridged + 1
      end
    end
  end
  local out = vim.deepcopy(head)
  if total <= budget then
    if n_abridged > 0 then
      out[#out + 1] = ''
      out[#out + 1] = ('The diff is large, so %d hunk%s marked [abridged] show only an index entry: header, counts and the first lines. '):format(
        n_abridged,
        n_abridged == 1 and ' is' or 's are'
      ) .. 'The files are in the current directory. Read one only if a section really needs it.'
    end
    out[#out + 1] = ''
    out[#out + 1] = 'Diff:'
    for _, b in ipairs(bodies) do
      vim.list_extend(out, b)
    end
    local msg = table.concat(out, '\n') .. '\n'
    if #msg <= budget then
      return msg, { level = level, abridged = n_abridged }
    end
  end
  -- per-file only: the list above already carries every id
  out = vim.deepcopy(head)
  out[#out + 1] = ''
  out[#out + 1] = 'The diff is too large to include. Use the file list above: each file lists its hunk ids in order. '
    .. 'Group whole files, or a file\'s hunks in order, by what the file names and commits suggest. '
    .. ('To see one file\'s changes, run `%s -- <path>` (one file at a time, only where a section needs it).'):format(ctx.diff_cmd or 'git diff')
  local msg = table.concat(out, '\n') .. '\n'
  if #msg <= budget then
    return msg, { level = 'files', abridged = #hunks }
  end
  return nil, ('the review is too large for one guide (%d files, %d hunks; even the file list is %d characters, over ai.max_prompt_chars = %d). '
    .. 'Review one stack layer at a time, or raise ai.max_prompt_chars.'):format(#order, #hunks, #msg, budget)
end

---Full prompt for stdin: methodology, then the user message; the budget covers both.
---@return string? prompt
---@return {level: string, abridged: integer}|string info, or the error
function M.build(ctx, hunks, opts)
  local budget = ((opts and opts.budget) or 150000) - #M.SYSTEM - 8
  local msg, info = M.user_message(ctx, hunks, { budget = budget })
  if not msg then
    return nil, info
  end
  return M.SYSTEM .. '\n---\n\n' .. msg, info
end

return M
