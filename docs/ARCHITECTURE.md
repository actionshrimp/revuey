# revuey architecture

revuey is a code review surface implemented as a **pure Neovim Lua plugin** (Neovim >= 0.12, no plenary, no
nvim-treesitter dependency at runtime beyond installed parsers). Background research and the reasons for this choice
are in `reports/Terminal code review tool landscape.md`.

## Product goals
- Review local branches and full local PR stacks before pushing (base = merge-base with a configurable default
  branch such as `main` or `develop`; stack = chain of branches each based on the previous).
- Review GitHub PRs (and their stacks) by fetching `refs/pull/N/head` into a detached temporary `git worktree`
  (or a `gh repo clone` temp clone when not in the repo), so the whole codebase is navigable.
- AI guided review: Claude produces a JSON guide (title, summary, ordered sections of prose referencing
  engine-assigned hunk IDs). Rendered with the same diff renderer as the main view (decision 9).
- Ask AI inline (visual selection in diff or guide view) and a chat side panel with diff + guide context.
  AI calls spawn the user's own `claude -p` CLI asynchronously (never read credentials ourselves).
  Useful flags for later: `--include-partial-messages --resume <id> --fork-session`; the guide's
  session id is stored with it for that.
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
4. **One renderer, two hosts.** The guide view reuses the composed-buffer renderer with prose blocks between
   hunks (`layout.compose_guide`, sharing `push_hunk` with `layout.compose`); see decision 9.
5. **Side-by-side** is a secondary mode using Neovim's native diff mode (later chunk).
6. **Review target for local branches** defaults to the working tree: `merge-base(base, HEAD)` diffed against
   the working tree, plus untracked non-ignored files as additions; the new side is read from disk and keyed by
   `git hash-object`. Committed-only (`merge-base..HEAD`) is a toggle. Working-tree reviews auto-refresh
   (BufWritePost debounced, FocusGained, re-entry when file stats changed), coalesce concurrent refreshes, skip
   re-rendering when the diff is unchanged, and preserve cursor/scroll/folds.
7. **Local stacks** (`stack.lua`). A `revuey.Stack` is an ordered list of layers (bottom first), each with a
   tip commit, a parent rev and a reviewed-state key (`state_branch`, `state_base`); a scope is a layer or the
   full stack, turned into a `revuey.Target` (`from`, `to` or nil for HEAD/working tree, labels, state key) that
   `review.load` diffs. Nothing in the model assumes layers are local branches, so a later PR-stack source only
   has to build a `revuey.Stack`.
   Detection is split into a pure resolver (`resolve`: branch tips + a first-parent graph of commits not
   reachable from trunk + explicit parents -> layers, forks, notes, or a request for more history) and a gatherer
   (`detect`): `for-each-ref` (heads and `refs/branch-metadata`), `config --get-regexp` for
   `branch.*.revueyParent`, one `cat-file --batch` for Graphite blobs, `for-each-ref --contains HEAD` for
   candidates above, and `rev-list --parents --stdin ^trunk` for the graph; all async, and skipped when a
   fingerprint of refs/overrides/HEAD/trunk is unchanged. Heuristic parent = nearest other branch tip on the
   first-parent line (merged side branches are never parents). Explicit parents (revuey config, then Graphite)
   override it; a parent already in trunk becomes trunk. Upward we follow a single child and stop at forks.
   **Moved parents:** reflogs of unmerged branches (creation and `reset:` entries excluded) map old tips to
   their branch. If the first-parent walk hits an old tip of a branch that has since moved (amend, new commit,
   rebase) before any current tip, that branch is the parent (`diverged`). The layer is diffed from the old tip,
   which shows only the child's own commits, with a "not restacked" note. A parent whose tip *is* an ancestor
   (merged into the child rather than rebased) is a normal parent; ancestry follows merge parents inside the
   loaded graph. Upward candidates include branches containing old tips of stack branches. Without reflogs,
   branches sharing the stack's root commit but not in the stack get a suggest-only note.
   **Explicit parents that aren't ancestors** use an old tip of the parent if there is one, or else trunk
   (`stale`), with a note. Every layer target carries `floor = trunk`, so `review.merge_base_for` never diffs
   below `merge-base(trunk, tip)`.
   **Landed layers:** bottom-up, a layer whose own changed files are identical in trunk
   (`git diff --quiet trunk tip -- files`) is marked landed and dimmed. The check stops at the first unlanded
   layer.
   **Marks:** layers above another layer add the old blob to the content key (`key_old`), so a parent change to
   the same file resets the mark. The bottom layer, full scope and plain reviews keep chunk 1's new-blob keys,
   so they still share marks.
   Ambiguity (duplicate tips, forks, unknown or cyclic parents) becomes panel notes; nothing inferred is
   persisted (the child-branch trap is undetectable from the graph, so the user's explicit choice is the
   fix). Layer diffs use `merge-base(parent tip, layer tip)`, which also covers a trunk that moved on and a
   stack that was never rebased. Only the HEAD layer (and the full scope when HEAD is the top) can include the
   working tree; other scopes are `mode_locked` committed-only. Reviewed state is per layer (layer + normalised
   parent), so the bottom layer and full scope share files with the plain single-branch review of the same
   diff. Per-layer stats come from `git diff --raw` content keys (no patch parsing), loaded in the background.
   `:Revuey <base>` without `--stack` skips detection entirely and behaves exactly like the single-branch review.
8. **State** lives as JSON under `stdpath('data')/revuey/`, keyed by repo + review target; a pure-Lua data layer with
   no UI calls so it can be tested headless.

9. **AI guide** (`guide.lua` pure model, `guide_prompt.lua` prompt + schema, `ai.lua` provider, `prose.lua`
   markdown, `guide_view.lua` glue). Adapted from plannotator's Guided Review (research notes, Part A),
   but hunk-level.
   - **Hunk ids and anchors.** `guide.hunks(files)` numbers every hunk `h1..hn` in diff order (files
     without a text diff, such as binaries and pure renames, get one entry). Each has an anchor
     `{path, old_start, new_start, header, hash}`; the hash covers the path and the hunk's +/-/context
     lines (CR and no-EOL flags included), not line numbers, so a hunk shifted by edits above it keeps
     its hash. Identical hunks in one file get `~2`, `~3` suffixes. The model only sees and returns ids.
   - **Prompt.** Methodology on stdin before the user message: identity (organiser, not bug hunter),
     voice (25-word sentences, no dashes or emoji), a small lookup budget (Read/Grep/Glob), ordering
     (heart, consequences, glue last), hunk-level chunking (a file's hunks may be split), coverage
     (every id exactly once in a section or `unplaced`), 2-6 sections (max 10), optional
     `> [!IMPORTANT]`/`> [!WARNING]` callouts. The user message has the repo, scope, commit subjects,
     a file list with `+/-` counts and ids, then each hunk as `@@ h7 path @@` + the git hunk. Over
     `ai.max_prompt_chars` the largest hunks become index entries (header, counts, first 6 lines,
     `[abridged]`) and the model is told the files are in its cwd.
   - **Schema** (`--json-schema`, `additionalProperties: false` everywhere):
     `{title, summary (md), sections: [{title, overview (md), hunks: [{id, note?}]}], unplaced: [id]}`.
   - **Invocation.** `ai.run` spawns `claude -p --output-format stream-json --verbose --permission-mode
     dontAsk --tools Read,Grep,Glob,Bash --allowedTools Read,Grep,Glob,Bash(git diff:*),Bash(git log:*),Bash(git show:*)
     --disallowedTools Bash(git * --out*) --restricted --safe-mode --strict-mcp-config
     --append-system-prompt <shell rules> --json-schema … [--model] [--effort] --name "revuey guide: …"`
     in the repo root (prompt on stdin), with `vim.system` (`detach = true`, so the CLI leads its own
     process group). The NDJSON stream gives the session id and model (`system/init`), progress lines from
     `tool_use` ("reading src/cart.ts"), and the answer from the `result` event's `structured_output`
     (fallback: the `StructuredOutput` tool input, then the result text). Cancel and timeout send SIGTERM to
     the process group, then SIGKILL after 2s; `VimLeavePre` (and the test harness before `os.exit`) kills
     every live run synchronously, since detached processes would otherwise outlive Neovim. A provider is
     `{build(opts) -> argv, stdin; stream() -> parser}`, so codex can be added. The session is kept
     (no `--no-session-persistence`) and its id stored, for the later Ask AI chunk.
   - **Read-only, whatever the settings say** (verified on Claude Code 2.1.302 with three `haiku` runs in
     a scratch repo whose `.claude/settings.local.json` allowed `Bash(make:*)`, `Bash(touch:*)` and `Write`
     and had a `SessionStart` hook; the model was asked to Write a file, run `make`, `git diff > f`,
     `git diff --output=f` and `touch`, then `git diff --stat` and `git log`):
     - With the earlier flags (`--setting-sources` loading those files), `make` and `touch` ran and the
       hook fired: settings-file allow rules and hooks apply under dontAsk. `--setting-sources user` alone
       is therefore not enough, because the user's own allow rules and hooks would apply the same way.
     - `--restricted` ignores user, project and local settings files (even when `--setting-sources`
       asks for them), confines the file tools to the working directory and keeps login working.
       `--safe-mode` also turns off hooks from plugins and other customisations. With both, every
       write was refused, no hook ran (not even the user's own `SessionStart`), nothing was written,
       and the two read commands worked.
     - Redirects and compound commands are refused by dontAsk without any deny rule. `Bash(git diff:*)`
       keeps its space through `--allowedTools`. A mid-pattern wildcard deny (`Bash(git * --out*)`)
       blocks `git diff --output=f` although the allow rule matches it. `Write`/`Edit`/`WebFetch` are
       not in `--tools`, so they do not exist. The allow and deny lists are exactly these proven rules.
     - Caveat: settings-based login (`env`, `apiKeyHelper`) and a settings default model are ignored too.
       `ai.restricted = false` swaps the two flags for `--setting-sources user` (documented risk: the
       user's allow rules and hooks apply). Runs stay in `ai.live` until their process group has exited
       and been sent its follow-up SIGKILL, so cancelling and quitting at once still kills everything.
   - **Validation** against the launch-time hunks (model instructed, not trusted): mechanical JSON
     repair (strip fences, slice `{`..`}`), unknown ids and duplicates dropped (first wins), empty
     sections dropped, unplaced and missed hunks put in a final "Other changes" section, zero valid
     sections is a failure. Warnings are stored with the guide.
   - **Persistence.** `<state_dir>/guides/<slug>-<hash(repo, branch, base)>-<generated_at>-<hash(anchor set)>.json`
     (the name carries time and anchors, so lookups decode one file; the newest `ai.keep_guides` (5)
     per review key are kept),
     keyed like reviewed state (so each layer and the full scope have their own), holding sections
     with anchors (not ids) plus `generator = {provider, model, session_id, generated_at, head,
     merge_base, mode, duration_ms, cost_usd, abridged, warnings}`. Opening a review loads the guide for
     the exact anchor set, else the newest one for the key.
   - **Staleness** (`guide.resolve`): hunks are matched by hash. Sections render the hunks that still
     exist; sections that lost any are `outdated`; hunks the guide doesn't know go to "Not in guide";
     a banner offers regeneration. Nothing re-runs automatically.
   - **Section reviewed state:** identity = hash of the sorted hashes of the hunks the section shows,
     stored as `sections[id]` in the review's state JSON (merged per id on save, beside file marks).
     Unchanged hunks keep the mark across regeneration; a changed hunk gives a new id (un-reviewed).
   - **Identical hunks** (the same edit twice in one review) get `@old_start,new_start` appended to their
     hash, so an identity never moves from one copy to another; the cost is that such hunks count as
     changed when lines above them shift. Unique hunks stay shift-invariant.
   - **Model strings** are sanitised on validation and again when a stored guide is loaded: titles and
     notes become one line without control characters; summaries and overviews keep newlines only.
   - **Prompt budget.** The whole stdin prompt stays within `ai.max_prompt_chars`: full hunks, else the
     largest hunks abridged, else no hunk bodies (the file list with each file's ids, and a
     `git diff <base> -- <path>` hint), else the run is refused with advice to review one layer.
   - **View.** The diff window, buffer and panel are shared; `s.view_mode` picks `layout.compose` or
     `layout.compose_guide`. Prose lines are side-table entries of kind `prose` (styled by extmarks,
     skipped by syntax, word diff, LSP and EOL notes); section headings are `meta = 'section'` rows and
     fold level 1 (files in the diff view); every hunk block (`layout.blocks`: header, notes, lines)
     is fold level 2 and long context runs level 3, with `foldlevel=2`. `<Tab>` is an expr mapping:
     `za` on a title row, else `<C-i>`, so the jumplist is untouched; hunk rows are identical to the diff's (plus `section_idx`). `hunk_base[fi][hi]`
     replaces "header row + k" so note rows can sit between a hunk header and its lines. Each mode
     keeps its own cursor/scroll/folds. Jobs live in `guide_view.jobs` by review key, so they outlive
     scope switches and even closing the review; a 100ms timer redraws the spinner via extmarks only.

## Code layout conventions
- `lua/revuey/` modules; `plugin/revuey.lua` defines user commands only (lazy-require modules).
- Keep git/data logic (`git.lua`, `diff.lua`, `state.lua`, `stack.lua`, `guide.lua`, `guide_prompt.lua`,
  `prose.lua`) free of window/buffer UI so it is testable with `nvim --headless -l`.
- Tests in `tests/`, run with `make test`. Testing strategy and rules are in `docs/TESTING.md`.
- Shell out to `git`/`gh` with `vim.system`; never block the UI for long-running work.
