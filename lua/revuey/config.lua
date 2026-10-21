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
  -- Intra-line word highlights for paired -/+ lines.
  word_diff = true,
  -- Directory for persisted review state (nil = stdpath('data')/revuey).
  state_dir = nil,
  keymaps = {
    next_hunk = ']c',
    prev_hunk = '[c',
    next_file = ']f',
    prev_file = '[f',
    open_file = { '<CR>', 'go' },
    definition = 'gd',
    hover = 'K',
    toggle_reviewed = 'mr',
    focus_panel = 'gp', -- not <Tab>: that is <C-i> (jumplist forward)
    refresh = 'R',
    toggle_mode = 'gu', -- working tree <-> committed only
    -- stacks (only active when a stack is detected). ]s/[s shadow spell navigation, which is
    -- off in review buffers.
    next_layer = ']s',
    prev_layer = '[s',
    toggle_stack = 'gs', -- full stack <-> layer scope
    close = 'q',
  },
}

M.options = vim.deepcopy(M.defaults)

function M.set(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
end

return M
