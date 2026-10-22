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
  -- alias until its project has loaded).
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
    stack_notes = '!', -- details of the stack notes (float with actions)
    -- AI guide
    toggle_guide = 'gG', -- diff view <-> guide view (offers to generate when there is none)
    regenerate_guide = 'gR', -- guide view: generate a new guide
    next_section = ']]', -- guide view (in the diff view: next file)
    prev_section = '[[',
    close = 'q',
  },
  -- AI guided review. Runs your own `claude` CLI (logged in); revuey never reads credentials.
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
