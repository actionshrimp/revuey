local M = {}

---@class revuey.Config
M.defaults = {
  -- Base branch to review against. nil = auto-detect (origin/HEAD, then main, master, develop).
  default_branch = nil,
  -- Include uncommitted work (staged, unstaged, untracked) by default; `gu` / `--committed` switch
  -- to committed-only (merge-base..HEAD).
  uncommitted = true,
  -- Files (or file diffs) larger than this are listed with a "not shown" placeholder and never
  -- read into memory.
  max_file_bytes = 1024 * 1024,
  -- Lines of context around each change (git diff -U).
  context_lines = 3,
  -- Runs of unchanged lines longer than this are folded (only matters with large context_lines).
  fold_context_threshold = 12,
  -- Files with more diff lines than this start collapsed (lockfiles, generated code).
  collapse_large_files = 1500,
  panel_width = 40,
  -- Start the TypeScript/other LSP for changed files when the review opens, so `gd` is ready.
  lsp_warmup = true,
  -- Minimum age (ms) of an LSP client before the first request (tsserver answers with the import
  -- alias until its project has loaded). While a client warms up, requests also wait for its
  -- $/progress reports (project loading) to end, up to 15s.
  lsp_settle_ms = 3000,
  -- Attach an in-process LSP client named "revuey" to review buffers. It forwards definition,
  -- type definition, declaration, implementation, references and hover to the real language
  -- server of the file under the cursor, so your own LSP mappings and pickers work in the diff.
  lsp_proxy = true,
  -- Intra-line word highlights for paired -/+ lines.
  word_diff = true,
  -- Directory for persisted review state (nil = stdpath('data')/revuey).
  state_dir = nil,
  stack = {
    -- Branch globs (`*` matches anything, including `/`) whose notes are hidden: related branches
    -- outside the stack, e.g. { 'dave/old-*' }. Added to the per-repo list kept by
    -- :RevueyStackIgnore. Never changes which branches are layers.
    ignore_branches = {},
    -- `]s`/`[s` also check the layer out in this worktree (as `gS` does, with the same checks).
    -- Off: they only move the view. A refused switch leaves the view moved and says why.
    switch_on_navigate = false,
  },
  keymaps = {
    next_hunk = ']c',
    prev_hunk = '[c',
    next_file = ']f',
    prev_file = '[f',
    open_file = { '<CR>', 'go' },
    definition = 'gd',
    hover = 'K',
    toggle_reviewed = 'mr',
    focus_panel = 'gp',
    -- <Tab> on a title line (file header, hunk header, guide section heading) collapses/expands that
    -- block; on any other line it is <C-i> (jumplist forward), since most terminals send the same key
    toggle_fold = '<Tab>',
    toggle_all_folds = '<S-Tab>', -- collapse every file (guide: section), or expand them all
    refresh = 'R',
    toggle_mode = 'gu', -- working tree <-> committed only
    -- stacks (only active when a stack is detected). ]s/[s shadow spell navigation, which is
    -- off in review buffers.
    next_layer = ']s',
    prev_layer = '[s',
    toggle_stack = 'gs', -- full stack <-> layer scope
    -- check the layer out in this worktree (`git switch`; panel: the layer row under the cursor)
    switch_layer = 'gS',
    stack_notes = '!', -- details of the stack notes (float with actions)
    -- AI guide
    toggle_guide = 'gG', -- diff view <-> guide view (offers to generate when there is none)
    regenerate_guide = 'gR', -- guide view: generate a new guide
    next_section = ']]', -- guide view (in the diff view: next file)
    prev_section = '[[',
    -- guide line notes (the guide's notes on specific lines; guide view only). ]n/[n are free in
    -- Neovim; `gN` (select the previous search match) means nothing in a read-only review buffer.
    next_note = ']n',
    prev_note = '[n',
    toggle_notes = 'gN', -- show the notes in full / collapse them to a marker
    close = 'q',
    -- comments (diff and guide views). `gc` shadows Neovim's commenting operator, which has
    -- nothing to do in a read-only review buffer; the c* keys shadow `c{motion}` likewise.
    comment_add = 'gc', -- on a line, a visual selection, or a file header (whole file)
    comment_edit = 'ce',
    comment_delete = 'cd',
    comment_reply = 'cr',
    comment_resolve = 'cx', -- resolve / reopen
    comment_expand = 'cz', -- expand / collapse a long or resolved comment
    comment_toggle = 'gC', -- show / hide the threads (gutter bars stay)
    comment_next = ']m', -- ]m/[m shadow the method motions, which mean nothing in a diff
    comment_prev = '[m',
    comment_list = 'cl', -- all comments in a float (also in the panel; :RevueyComments)
    -- AI review findings (:RevueyAIReview): accept one as your own comment, or dismiss it
    -- (again: restore). `cs` sends one to the agent session to follow up, as any comment.
    comment_accept = 'ca',
    comment_dismiss = 'cn',
    -- "add to review": include the comment on this line in the review posted to GitHub (or take
    -- it out); a local flag until you submit (forge_submit). `ci` shadows `ci{motion}` like the
    -- other c* keys.
    comment_include = 'ci',
    comment_send = '<C-a>', -- in the comment editor: save and send to the coding-agent session
    send_comment = 'cs', -- send the comment on this line to the agent session
    -- ask the agent about this line or the visual selection: the comment editor, where
    -- comment_send sends. `ga` (show the character code) means nothing in a review buffer, and
    -- unlike <leader>a it cannot collide with a user's global leader mappings.
    ask_agent = 'ga',
    -- panel: open the pull request of the layer under the cursor (else the one being viewed) in
    -- the browser. `go` already opens files in the diff, so this uses `gx` ("open URL").
    forge_open = 'gx',
    -- GitHub review threads in the diff: all (resolved and outdated collapsed), open only, hidden.
    -- `gH` (select-line mode) means nothing in a read-only review buffer. In the diff, `gx` on a
    -- thread opens it on GitHub.
    forge_threads = 'gH',
    -- submit the review to GitHub (:RevueySubmit): pick a verdict, the comments added with
    -- comment_include go into your pending review, then a confirmation before anything is
    -- published. `gP` (put before) means nothing in a read-only review buffer.
    forge_submit = 'gP',
    -- edit the real file at this line in a float (working-tree mode, checked-out layer only).
    -- `ge` (backward to the end of a word) means little in a read-only review buffer.
    edit = 'ge',
  },
  comments = {
    max_lines = 6, -- longer threads are cut ("… N more lines", comment_expand shows all)
    width = 100, -- max width of a thread box (else the window's text width)
  },
  -- Pull requests on GitHub: number and review status on stack rows (or a plain review's title)
  -- and a detail section for the layer being viewed. Runs your own `gh` (assumed logged in) when
  -- a review opens (one call for all layers) and on `R`; what is shown never changes on its own.
  -- Any failure (no gh, offline, rate limits) shows nothing new and is written to the log file.
  forge = {
    enabled = true,
    -- Every `ttl` seconds while the review is shown and Neovim focused, one small query asks
    -- GitHub whether the scope's PRs changed (head, state, reviews, threads, checks, description)
    -- and marks the ones that did ("↻", "new on GitHub · R"); nothing shown is replaced until `R`.
    -- `check = false` turns the check off.
    ttl = 180,
    check = true,
    timeout = 15, -- seconds before a gh call is stopped
    cmd = 'gh',
    -- GitHub Enterprise hosts (github.com and hosts with "github" in their name are known)
    hosts = {},
    -- Review threads of the open PR(s) of the scope shown, inline next to your comments
    -- (read-only; `cr` adds a local reply). Fetched in the background after the PR lookup, the
    -- first time a scope shows the PR; `R` fetches again. show: 'all' (resolved and outdated
    -- threads collapsed), 'open' (resolved ones hidden) or 'none'; the forge_threads key cycles it.
    threads = {
      enabled = true,
      show = 'all',
    },
    -- The description of the open PR(s) of the scope shown, at the top of the diff view (not the
    -- guide), rendered as text (HTML comments from PR templates removed, images and links as
    -- text, nothing fetched). It comes with the PR lookup (same call and cache; `R` fetches
    -- again) and is inserted above the first file without moving the view. Longer than
    -- `max_lines` it starts folded ("… N more lines"); <Tab> (toggle_fold) or `zo`/`zc` on it
    -- expands / collapses it; `expanded = true` starts it unfolded.
    description = {
      enabled = true,
      expanded = false,
      max_lines = 6,
    },
  },
  -- `:Revuey pr <N|url>` sets the PR's worktree up with worktrunk (`wt switch pr:<N>`), so your
  -- worktrunk hooks install and build it before the review (and its LSP) starts.
  worktrunk = {
    cmd = 'wt',
  },
  -- Quiet diagnostics (e.g. why the PR lookup failed). nil = stdpath('log')/revuey.log
  log_file = nil,
  -- AI guided review and AI reviews (:RevueyGuide, :RevueyAIReview). Runs your own `claude` CLI
  -- (logged in); revuey never reads credentials.
  ai = {
    provider = 'claude',
    cmd = nil, -- executable (default: the provider name, `claude`)
    model = nil, -- nil = Claude Code's default; or 'opus', 'sonnet', a full model id...
    effort = nil, -- nil = default; 'low'|'medium'|'high'|'xhigh'|'max'
    timeout_ms = 10 * 60 * 1000,
    -- diffs larger than this many characters send big hunks as a short index entry instead
    max_prompt_chars = 150000,
    -- true: claude ignores all settings files (yours and the repo's), so no permission allow
    -- rules or hooks can widen the read-only run. false: your user settings load (needed when you
    -- log in via settings `env`/apiKeyHelper, e.g. Bedrock, Vertex, a proxy), including YOUR allow
    -- rules and hooks, which then apply to a run that reads untrusted repo content. See README.
    restricted = true,
    -- saved guides kept per review (branch/layer + base); older ones are deleted
    keep_guides = 5,
  },
}

M.options = vim.deepcopy(M.defaults)

function M.set(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
end

return M
