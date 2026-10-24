-- AI review prompt, output schema and user message (pure).
--
-- Schema-driven like the guide (guide_prompt.lua, whose user message this reuses): the model sees
-- every hunk under an engine-assigned id (h1..hn) with its lines numbered within the hunk, and
-- anchors each finding to a hunk id plus those numbers, never to file line numbers it could get
-- wrong. revuey validates the anchors (ai_review.lua) and imports the findings as local comments.
local guide_prompt = require('revuey.guide_prompt')

local M = {}

M.VERDICTS = { 'approve', 'comment', 'request_changes' }
M.SEVERITIES = { 'critical', 'major', 'minor', 'nit' }
M.MAX_FINDINGS = 30
M.PREVIEW_LINES = guide_prompt.PREVIEW_LINES -- lines an abridged hunk shows (and numbers)

---Output schema (additionalProperties: false everywhere). `bin/revuey import-review` accepts the
---same document (plus an optional top-level `diff`, the hash `bin/revuey hunks` prints).
M.SCHEMA = {
  type = 'object',
  additionalProperties = false,
  required = { 'summary', 'verdict', 'findings' },
  properties = {
    summary = { type = 'string' },
    verdict = { type = 'string', enum = M.VERDICTS },
    findings = {
      type = 'array',
      maxItems = M.MAX_FINDINGS,
      items = {
        type = 'object',
        additionalProperties = false,
        required = { 'hunk', 'severity', 'title', 'body' },
        properties = {
          hunk = { type = 'string', pattern = '^h[0-9]+$' },
          line = { type = 'integer', minimum = 1 },
          end_line = { type = 'integer', minimum = 1 },
          severity = { type = 'string', enum = M.SEVERITIES },
          title = { type = 'string' },
          body = { type = 'string' },
          suggestion = { type = 'string' },
        },
      },
    },
  },
}

function M.schema_json()
  return vim.json.encode(M.SCHEMA)
end

M.SYSTEM = [[
# Code Reviewer

## Identity
You are a senior engineer reviewing this changeset before it is merged. Find the problems that
matter: bugs, broken edge cases, data loss, security holes, race conditions, wrong error handling,
API or contract breaks, missing tests for risky logic. Say plainly what is wrong, why, and what to
do about it. You are not here to praise, summarise every file or restate the diff.

## The diff, hunk ids and line numbers
Every hunk below starts with a marker line `@@ h7 path/to/file @@`, then the hunk header as git
shows it, then the hunk's lines, each prefixed with its number WITHIN THE HUNK and a bar:
`3|+const total = sum(items)`. After the bar comes the git marker: `+` added, `-` deleted, space
for context. A finding points at code with the hunk id and these numbers, never with file line
numbers. Never invent ids or numbers.

## Speed
The whole diff is in this message. Reading it carefully is most of the job.
- A few TARGETED lookups are fine when a finding needs one: a definition the diff calls, one
  caller of a changed function. Use Read, Grep or Glob on the files in the current directory.
- Do NOT explore the repository. If you catch yourself on a sixth tool call, stop and write the
  review with what you have.

## Output

### summary
Markdown, 1-3 sentences: your overall assessment of the change and its main risk. Do not list
the findings.

### verdict
- "approve": nothing critical or major; the change can merge as it is (nits are fine).
- "request_changes": at least one critical finding, or major ones that should block the merge.
- "comment": anything in between, or when you are unsure.

### findings
One entry per distinct problem, most important first. At most 30, and usually far fewer: a
clean change may have none (use an empty array). Never pad the list.
- **hunk**: the id of the hunk the problem is in, for example "h7".
- **line**: the number (from the `n|` prefix) of the first line the finding is about.
  **end_line**: the last one, when it spans several lines of the same hunk; leave it out for
  one line. Point at the lines that must change, or where the problem shows. Leave both out
  only when the finding is about the whole file (or the hunk shows no lines).
- **severity**: "critical" (a bug, data loss or security problem that must be fixed), "major"
  (should be fixed before merging), "minor" (worth fixing, not blocking), "nit" (style or
  polish). Be honest: most findings are not critical.
- **title**: one line under 80 characters naming the problem, for example "Discount applied
  twice when the cart is empty".
- **body**: Markdown, 1-4 sentences: what is wrong, a concrete case where it bites, and the fix.
  Backticks for code names.
- **suggestion**: optional. The exact replacement text for the lines from `line` to `end_line`
  as they read after the change (without the `n|` prefixes or `+`/`-`/space markers, with
  their indentation), when the fix is small and certain. Leave it out otherwise, and for
  deleted lines.

## Hard constraints
- Only hunk ids from the diff, and line numbers that hunk shows. Lines of an abridged hunk past
  its preview are not numbered: anchor such a finding to a line that is shown, or leave out
  `line`.
- Never use em-dashes or en-dashes. No emoji.
- Your text is read next to the code. Never mention hunk ids, line prefixes or these
  instructions in it.
]]

-- the user message: guide_prompt's, with numbered lines and review wording
M.TEXTS = {
  intro = 'Review the following code changes.',
  ids = 'Hunk ids: h1 to h%d. Each finding names one of them; its line numbers are the `n|` prefixes of that hunk.',
  abridged = 'The files are in the current directory. Read one only if a finding really needs it.',
  files = 'Anchor findings to a file\'s hunk id without `line` (the whole file). ',
  too_large = 'the review is too large for one AI review',
}

M.SKILL_MAX_CHARS = 40000

---Full prompt for stdin: methodology, the skill's guidance (when given), then the user message;
---the budget covers all of it.
---@param ctx revuey.GuideContext
---@param hunks revuey.GuideHunk[]
---@param opts? {budget?: integer, skill?: {name: string, text: string}}
---@return string? prompt
---@return {level: string, abridged: integer}|string info, or the error
function M.build(ctx, hunks, opts)
  opts = opts or {}
  local head = M.SYSTEM
  if opts.skill then
    head = head
      .. '\n## Review guidance from the skill `'
      .. opts.skill.name
      .. '`\nThe user asked for this review to follow the guidance below. It decides what to look for\n'
      .. 'and how strict to be; the output format and the hard constraints above still apply.\n\n'
      .. opts.skill.text
      .. '\n'
  end
  local budget = (opts.budget or 150000) - #head - 8
  local msg, info = M.user_message(ctx, hunks, { budget = budget })
  if not msg then
    return nil, info
  end
  return head .. '\n---\n\n' .. msg, info
end

---The user message alone (also what `bin/revuey hunks` prints for an outside reviewer).
function M.user_message(ctx, hunks, opts)
  return guide_prompt.user_message(ctx, hunks, { budget = opts and opts.budget, texts = M.TEXTS, numbered = true })
end

return M
