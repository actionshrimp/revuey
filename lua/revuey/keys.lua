-- Every key revuey maps, described once: the `g?` cheat sheet (key_help) and the README's
-- Keymaps tables (scripts/readme-keys.lua writes them; a test checks they match) are built from
-- this list, with the keys read from `config.keymaps`, so rebinds show and disabled keys
-- (false) are left out. `names` are keymap options (a pair: next / previous); `fixed` is a key
-- that is not configurable. `desc` is the cheat sheet's one line, `readme` the README's longer
-- text (default: `desc`); `readme = false` keeps an entry out of the README table.
local config = require('revuey.config')

local M = {}

M.GROUPS = {
  {
    name = 'Comments',
    { names = { 'comment_add' }, desc = 'comment on this line (visual: the selection; a file header: the file)',
      readme = '[Comment](#comments) on this line (visual: the selected lines; a file or hunk header: the whole file)' },
    { names = { 'comment_edit' }, desc = 'edit the comment on this line' },
    { names = { 'comment_reply' }, desc = 'reply to the comment (on a GitHub thread: a local reply)' },
    { names = { 'comment_resolve' }, desc = 'resolve the comment, or reopen a resolved one' },
    { names = { 'comment_delete' }, desc = 'delete the comment (asks first)' },
    { names = { 'comment_expand' }, desc = 'expand / collapse a long or resolved comment' },
    { names = { 'comment_accept' }, desc = 'accept the AI finding or agent comment: it becomes yours',
      readme = '[AI review](#ai-review) finding or [agent comment](#connect-an-agent) on this line: accept it as your comment' },
    { names = { 'comment_dismiss' }, desc = 'dismiss the AI finding or agent comment (again: restore)' },
    { names = { 'ask_agent' }, desc = 'ask the agent about this line or the selection',
      readme = '[Ask the agent](#connect-an-agent) about this line or the selection' },
    { names = { 'send_comment' }, desc = 'send the comment on this line to the agent' },
    { names = { 'comment_send' }, desc = 'in the comment editor: save and send to the agent' },
    { names = { 'comment_next', 'comment_prev' }, desc = 'next / previous comment (takes a count)' },
    { names = { 'comment_toggle' }, desc = 'hide / show the comment threads' },
    { names = { 'comment_list' }, desc = 'all comments in a float (<CR> jumps)', readme = 'List all comments (`<CR>` jumps)' },
  },
  {
    name = 'Review and posting',
    { names = { 'toggle_reviewed' }, desc = 'mark reviewed: the hunk, the file on its header, the selection',
      readme = 'Toggle reviewed. On a hunk header or any line of a hunk: that hunk (it collapses, and the cursor moves to the next unreviewed hunk you can see, skipping collapsed files). On a file header: the whole file (marks every hunk when any is unreviewed, else unmarks them all; collapses the file and moves to the next unreviewed one). In visual mode: every hunk the selection touches (a collapsed file in the selection counts whole). A file whose hunks are all reviewed collapses; its header shows `✓ reviewed`, or `◐ 2/5` while partly reviewed. Unmarking a file re-expands the hunks that were collapsed because they were reviewed, not the ones you collapsed with `<Tab>`' },
    { names = { 'comment_include' }, desc = 'add the comment on this line to the GitHub review / take it out',
      readme = 'Add the comment on this line to the [review to post on GitHub](#posting-a-review-to-github) / take it out' },
    { names = { 'forge_submit' }, desc = 'submit the review to GitHub: a verdict, then a confirmation',
      readme = 'Submit the review to GitHub (`:RevueySubmit`): pick a verdict (or add to your pending review, not submitted), then a confirmation' },
  },
  {
    name = 'Navigation',
    { names = { 'next_hunk', 'prev_hunk' }, desc = 'next / previous hunk (takes a count)',
      readme = 'Next / previous hunk (skips collapsed files and hunks; takes a count)' },
    { names = { 'next_file', 'prev_file' }, desc = 'next / previous file' },
    { names = { 'next_section', 'prev_section' }, desc = 'guide: next / previous section (diff: file)',
      readme = 'Guide view: next / previous section. Diff view: next / previous file' },
    { names = { 'definition' }, desc = 'LSP definition (in the diff when shown there)',
      readme = 'LSP definition (added/context lines). Jumps within the diff when the target is shown there, otherwise opens the file below' },
    { names = { 'hover' }, desc = 'LSP hover' },
    { names = { 'focus_panel' }, desc = 'focus the file panel (from the panel: the diff)', readme = 'Focus the file panel' },
  },
  {
    name = 'Layers and switching',
    { names = { 'next_layer', 'prev_layer' }, desc = 'next / previous stack layer (takes a count)',
      readme = 'Next / previous stack layer (takes a count). These shadow spell navigation, which is off in review buffers.' },
    { names = { 'toggle_stack' }, desc = 'full stack / back to the last layer', readme = 'Toggle full-stack scope and back to the last layer' },
    { names = { 'switch_layer' }, desc = 'check the layer out in this worktree (git switch)',
      readme = '[Check out](#checking-out-a-layer) the layer being viewed in this worktree (`git switch`)' },
    { names = { 'stack_tree' }, desc = 'the stack tree from GitHub: pick the path of PRs to review',
      readme = 'The [stack tree](#stack-trees-from-github): every PR of the stack on GitHub, to pick the path to review' },
    { names = { 'stack_fetch' }, desc = "git fetch the stack's PR branches (marked not fetched / behind)",
      readme = "`git fetch` the stack's PR branches from their remote (layers marked `⇣`, \"not fetched\" or \"origin behind\")" },
    { fixed = '<CR>', where = 'in the stack tree', desc = 'stack tree: review the path through this PR (j k move, q closes)',
      readme = 'Review the path through the PR under the cursor (`j`/`k` move between PRs and light the path up; `q`/`<Esc>` close without a change)' },
    { names = { 'tree_closed' }, desc = 'stack tree: show / hide closed PRs', readme = 'In the stack tree: show / hide closed PRs' },
    { names = { 'stack_notes' }, desc = 'stack notes in full, with actions',
      readme = '[Stack notes](#stack-notes) in full, with actions (also in the file panel)' },
    { names = { 'toggle_mode' }, desc = 'working tree / committed only', readme = 'Toggle working tree (default) / committed only' },
  },
  {
    name = 'GitHub',
    { names = { 'forge_open' }, desc = 'on a GitHub thread: open it (panel: the PR) in the browser',
      readme = 'On a GitHub thread: open it in the browser (elsewhere: Neovim\'s `gx`)' },
    { names = { 'forge_threads' }, desc = 'GitHub review threads: all / open only / hidden',
      readme = '[GitHub review threads](#review-threads-from-github): all / open only / hidden' },
  },
  {
    name = 'Guide',
    { names = { 'toggle_guide' }, desc = 'diff view / AI guide view (offers to generate one)',
      readme = 'Toggle the AI guide view (offers to generate a guide when there is none)' },
    { names = { 'regenerate_guide' }, desc = 'generate a new AI guide', readme = 'Generate a new AI guide (asks first when one exists)' },
    { names = { 'next_note', 'prev_note' }, desc = 'next / previous guide line note',
      readme = 'Guide view: next / previous [line note](#ai-guide) (takes a count)' },
    { names = { 'toggle_notes' }, desc = 'collapse the line notes to markers / show them',
      readme = 'Guide view: collapse the line notes to markers, or show them in full' },
    { fixed = '<CR>', where = 'on the guide\'s diagram', desc = 'on the guide\'s diagram: a box jumps to its section',
      readme = 'On a box: jump to its section. On the "Overview" heading: fold / unfold the diagram (like `<Tab>`)' },
  },
  {
    name = 'Files and folds',
    { names = { 'open_file' }, desc = 'open the file at this line (split below)',
      readme = 'Open the working-tree file at this line (in a split below)' },
    { names = { 'edit' }, desc = 'edit the real file at this line in a float',
      readme = '[Edit](#editing-from-the-review) the real file at this line in a float (checked-out layer, working-tree mode)' },
    { names = { 'toggle_fold' }, desc = 'collapse / expand the file, hunk or section (else <C-i>)',
      readme = 'On a file header or hunk header: collapse / expand that file or hunk (does not mark it reviewed). On a long [PR description](#the-pr-description): expand / collapse it. On any other line it is `<C-i>` (jump forward, takes a count), since most terminals send the same key for both' },
    { names = { 'toggle_all_folds' }, desc = 'collapse every file (guide: section) / expand all',
      readme = 'Collapse every file, or expand them all when all are collapsed' },
    { fixed = 'za', where = 'etc.', desc = 'and the other fold commands: files, hunks, long unchanged runs',
      readme = 'Normal fold commands: each file is a fold, each hunk a fold inside it, and long unchanged runs are folded' },
  },
  {
    name = 'Other',
    { names = { 'refresh' }, desc = 'refresh (re-runs git; fetches from GitHub)',
      readme = 'Refresh (re-runs git; also automatic in working-tree mode)' },
    { names = { 'help' }, desc = 'this list of keys', readme = 'All keys in a float, as configured (`q` closes)' },
    { names = { 'close' }, desc = 'close the review', readme = 'Close the review (quits Neovim when started via `bin/revuey`)' },
  },
}

---The keys of keymap option `name` (a string or a list), {} when it is disabled.
---@param defaults? boolean read config.defaults (the README) instead of the options
---@return string[]
function M.list(name, defaults)
  local k = (defaults and config.defaults or config.options).keymaps[name]
  if type(k) == 'table' then
    return vim.tbl_filter(function(x)
      return type(x) == 'string' and x ~= ''
    end, k)
  end
  return (type(k) == 'string' and k ~= '') and { k } or {}
end

---The first key of keymap option `name`, or nil when it is disabled.
function M.first(name)
  return M.list(name)[1]
end

---Keys of an entry as shown (`]c [c`), or nil when every one of them is disabled.
---@param sep? string between keys (default ' ')
function M.text(entry, defaults, sep)
  if entry.fixed then
    return entry.fixed
  end
  local all = {}
  for _, n in ipairs(entry.names) do
    vim.list_extend(all, M.list(n, defaults))
  end
  return #all > 0 and table.concat(all, sep or ' ') or nil
end

---The README's Keymaps tables (scripts/readme-keys.lua), from the defaults: one per group.
function M.markdown()
  local out = {}
  for _, g in ipairs(M.GROUPS) do
    local rows = {}
    for _, e in ipairs(g) do
      local keys = M.text(e, true, '` / `')
      if keys and e.readme ~= false then
        local cell = '`' .. keys .. '`' .. (e.where and (' ' .. e.where) or '')
        local text = e.readme or (e.desc:gsub('^%l', string.upper))
        -- a `|` would end the table cell
        text = text:gsub('|', '\\|')
        rows[#rows + 1] = '| ' .. cell .. ' | ' .. text .. ' |'
      end
    end
    if #rows > 0 then
      vim.list_extend(out, { '**' .. g.name .. '**', '', '| Key | Action |', '|---|---|' })
      vim.list_extend(out, rows)
      out[#out + 1] = ''
    end
  end
  out[#out] = nil
  return table.concat(out, '\n')
end

---Expand `{name}` in a panel help line to the option's first key (`{name#2}`: its second key,
---else the first). Segments (split on two spaces) with a disabled key are left out; nil when
---nothing is left.
function M.line(template)
  local kept = {}
  for seg in (template .. '  '):gmatch('(.-)  ') do
    local ok = true
    local text = seg:gsub('{([%w_]+)#?(%d*)}', function(name, nth)
      local l = M.list(name)
      local k = l[tonumber(nth) or 1] or l[1]
      if not k then
        ok = false
        return ''
      end
      return k
    end)
    if ok and text:find('%S') then
      kept[#kept + 1] = text
    end
  end
  if #kept == 0 then
    return nil
  end
  local line = table.concat(kept, '  ')
  return line:sub(1, 1) == ' ' and line or (' ' .. line)
end

return M
