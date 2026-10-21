# revuey architecture

revuey is a code review surface implemented as a **pure Neovim Lua plugin** (Neovim >= 0.12, no plenary, no
nvim-treesitter dependency at runtime beyond installed parsers). Background research and the reasons for this choice
are in `reports/Terminal code review tool landscape.md`.

## Product goals
- Review local branches and full local PR stacks before pushing (base = merge-base with a configurable default
  branch such as `main` or `develop`; stack = chain of branches each based on the previous).
- Review GitHub PRs (and their stacks) by fetching `refs/pull/N/head` into a detached temporary `git worktree`
  (or a `gh repo clone` temp clone when not in the repo), so the whole codebase is navigable.
- AI guided review: Claude produces a JSON guide (title, intent, ordered sections of prose referencing
  engine-assigned hunk IDs). Rendered with the same diff renderer as the main view.
- Ask AI inline (visual selection in diff or guide view) and a chat side panel with diff + guide context.
  AI calls spawn the user's own `claude -p` CLI asynchronously (never read credentials ourselves).
  Useful flags: `--output-format stream-json --include-partial-messages --resume <id> --fork-session
  --append-system-prompt-file --allowedTools Read,Grep,Glob --permission-mode plan --json-schema`.
- TypeScript LSP: jump to definition and hover from inside diff/guide buffers.
- Mark files and guide chunks as reviewed; state is keyed by content hashes so it invalidates when code changes.
- Coding agents can launch it in a tmux pane via a `bin/revuey` shell wrapper and read results back as JSON.

## Core design decisions
1. **Composed diff buffer.** The diff view is a scratch buffer laid out like a unified diff, where added,
   removed and context lines are all *real* buffer lines (so the cursor can land on deletions for comments,
   selection and Ask AI). Each buffer line has a side-table entry mapping it to
   `{ kind = "add"|"del"|"ctx"|"meta", old_lnum, new_lnum, path, hunk_id }`.
2. **Projected syntax highlighting.** Parse the full old and new file contents with tree-sitter
   (`vim.treesitter.get_string_parser`) and project captures onto composed lines (old side for `del`, new side for
   `add`/`ctx`). Apply lazily for visible lines via `nvim_set_decoration_provider`, like core highlighting does.
   Diff background colours are layered as extmarks (line_hl_group) beneath syntax.
3. **Projected LSP.** For `add`/`ctx` lines, load the real working-tree file into a hidden buffer (bufadd/bufload,
   set filetype so the user's LSP config attaches), translate cursor position (subtract any prefix columns), and
   send `textDocument/definition` / `hover` via that buffer. Wait for the client to be ready before first request
   (TypeScript returns the import alias until the project has loaded). Proven in a spike; see report notes.
   `del` lines get no LSP.
4. **One renderer, two hosts.** The guide view reuses the composed-buffer renderer with prose blocks between hunks.
5. **Side-by-side** is a secondary mode using Neovim's native diff mode (later chunk).
6. **Review target for local branches** defaults to the working tree: `merge-base(base, HEAD)` diffed against
   the working tree, plus untracked non-ignored files as additions; the new side is read from disk and keyed by
   `git hash-object`. Committed-only (`merge-base..HEAD`) is a toggle. Working-tree reviews auto-refresh
   (BufWritePost debounced, FocusGained, re-entry when file stats changed), coalesce concurrent refreshes, skip
   re-rendering when the diff is unchanged, and preserve cursor/scroll/folds.
7. **State** lives as JSON under `stdpath('data')/revuey/`, keyed by repo + review target; a pure-Lua data layer with
   no UI calls so it can be tested headless.

## Code layout conventions
- `lua/revuey/` modules; `plugin/revuey.lua` defines user commands only (lazy-require modules).
- Keep git/data logic (`git.lua`, `diff.lua`, `state.lua`) free of window/buffer UI so it is testable with
  `nvim --headless -l`.
- Tests in `tests/`, run with `make test`. Testing strategy and rules are in `docs/TESTING.md`.
- Shell out to `git`/`gh` with `vim.system`; never block the UI for long-running work.
