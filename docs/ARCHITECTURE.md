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
   **Proxy client** (`lsp_proxy.lua`), so the user's own `vim.lsp.buf.*` mappings, `<C-]>` and
   pickers work in review buffers, which otherwise have no client ("not supported by any server").
   On `FileType revuey` (autocmd in `lsp.lua`, so `view.lua` needs no hook) an in-process client
   named `revuey` is started with `vim.lsp.start({cmd = function(dispatchers) ... end})`: `cmd`
   returns a `vim.lsp.rpc.PublicClient` (`request`, `notify`, `is_closing`, `terminate`) whose
   replies are always scheduled, like a real server's. It advertises only definition, type
   definition, declaration, implementation, references and hover, `positionEncoding = utf-16` and
   no document sync, so `LspAttach` handlers enable nothing that would misbehave (diagnostics,
   semantic tokens, inlay hints, formatting, completion, code actions have no provider). Each
   request maps the row through the side table (`del`/meta/prose rows: a warning plus an error
   reply, never a hang), and `lsp.request` forwards it with any extra params (`context`) to the
   real server of *that row's* file through its hidden buffer, with the same readiness wait
   (no LSP for the filetype: the warning after 1.5s). Results are returned as the server sent
   them, with locations in real files; only positions are converted when the real server's
   encoding differs, `originSelectionRange` (hidden-buffer coordinates) is dropped, and a hover
   range on the requested line is moved to the review row.
   Core jump handlers put the target in the *current* window, which is the diff window, and the
   diff buffer used to be `bufhidden=wipe` (wiping it ends the session). With the proxy the diff
   buffer is `bufhidden=hide`; on `BufWinLeave` the view and closed folds are saved, and when the
   diff window shows another buffer that buffer is first shown in the code window below (a new
   split made while the diff window still shows it, with cleared jumplist and tagstack; a new
   tab on E36; a `winfixbuf` code window is skipped), so `bufhidden=wipe/delete/unload` buffers
   (fugitive objects, dashboards) are never hidden, and only then is the review put back (any
   jump, picker selection, quickfix entry or `:edit` in the diff window). `BufWinEnter` of the
   review in the code window (`<C-o>` there) puts the code window's file back and focuses the
   review at that position. `vim.b.snacks_main` makes snacks.picker target the review window, and
   the panel window is `winfixbuf`. Revuey's buffer keymaps are re-applied (twice scheduled)
   after `LspAttach` of the proxy, since user handlers map `gd`/`K`/`]]` on every client.
   `$/cancelRequest` drops the reply and cancels the readiness wait and the forwarded request
   (`lsp.request` returns a cancel handle). Rows without LSP reply with an empty result, and core's
   "No locations found"/"No information available" are suppressed while that reply's handler
   runs, so the user sees one revuey message. On wipe every `revuey` client attached to the
   buffer is stopped, and clients left with no buffer (`:lsp restart` racing a close) are swept
   after each initialize. If the
   diff window is gone the buffer is wiped as before; `TabClosed` (nested, so the session's
   `BufWipeout` cleanup runs) wipes it at once for `:tabclose`. The client is stopped on the
   buffer's `BufWipeout`, so open/close/reopen leaves no clients. Revuey's own `gd`/`K` keep
   their direct `lsp.request` path (`gd` jumps inside the diff when the target is shown there);
   routing them through the proxy would need the same in-diff mapping as an `on_list` and saves
   nothing.
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
   markdown, `diagram.lua` overview diagram, `attribution.lua` branch labels, `guide_view.lua` glue).
   Adapted from plannotator's Guided Review (research notes, Part A),
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
   - **Scope wording** (a guide covers one review scope, `ctx.stack` from `guide_view`). Layer
     scope: "This review covers only the branch X: its own changes on top of its parent branch
     Y", the layer's position in the chain (`main <- a <- b <- c`), and an instruction to call it
     "this branch" or "this change", never "this stack", mentioning the stack only when needed.
     Full scope: the branches listed bottom first with their parents, "this stack", and commit
     subjects grouped per branch (`git log parent_rev..tip` per layer) so the model can say which
     branch introduced what. Plain branch reviews keep `Changes: X compared with Y` and no stack
     wording. The guide's winbar shows the scope (`Guide · layer stack/cart`, `Guide · full stack`).
   - **Schema** (`--json-schema`, `additionalProperties: false` everywhere):
     `{title, summary (md), sections: [{title, overview (md), hunks: [{id, note?}]}], unplaced: [id],
     diagram?: {nodes: [{id, label, kind: new|changed|context, section? (1-based)}] (max 12),
     edges: [{from, to, label?}] (max 20)}}`.
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
   - **Overview diagram** (`diagram.lua`, pure). The model never draws: it returns nodes and edges
     (prompt: only when the structure is worth seeing, few nodes, short labels; skip trivial
     changes). `guide.validate_diagram` keeps unique ids (first wins, max 12), one-line labels
     truncated to 28 cells (edges 20), unknown kinds as `changed`, sections mapped from the
     model's numbering to the surviving sections (a dropped section shifts the rest) or by
     title; edges only between known nodes, no self loops, deduplicated, max 20; fewer than two
     nodes means no diagram. Stored on the record, re-validated on load.
     `diagram.render(d, width)` -> `{lines, hls, nodes, mode}` is a small Sugiyama layout, top to
     bottom: a DFS (sources first, then node order) reverses back edges; ranks by longest path,
     with sources pulled down next to their successors; dummy points split long edges; order
     within ranks by barycenter sweeps (down, then two up/down pairs; the order with the fewest
     crossings wins); x by isotonic regression (pool adjacent violators) of each item towards the
     mean centre of its neighbours, keeping order, a 2-4 column gap and the width. Boxes get one
     port per line (`┬` out, `▼` in; back edges `▲` at the top, `┴` below). Between ranks every
     line that changes column gets its own horizontal track, ordered so a line arriving at a
     column turns after the line leaving it (arrival, else departure, ports are first moved off
     columns another line leaves from, so two lines swapping columns never need each other to
     turn first and merge); lines are drawn as direction masks turned into
     box-drawing characters (crossings become `┼`). Labels go beside the arrow, else beside where
     the line leaves the box, else in a list under the drawing. If any rank is wider than the
     width the list form is used (`A ──label──▶ B`, nodes without edges as `• C`). A legend of
     the kinds used ends both forms. Everything is deterministic (ties by node order), so specs
     compare exact output. `diagram.mermaid(d)` gives Mermaid flowchart text with kind classes
     (`:RevueyGuideDiagram mermaid [reg]`; groundwork for image rendering).
     In the guide the heading and drawing are side-table rows of kind `diagram` (skipped by every
     diff feature, like prose) carrying highlight spans and node spans `{start, end, id,
     section}`; `layout.diagram` is their row range and a level-1 fold. `<CR>` on a node jumps
     to its section, on the heading toggles the fold, as does `<Tab>` (the heading is a fold
     title like section headings, and `<S-Tab>` collapses it with the sections); the drawing is redone at the prose width on
     every render at the full text width (not the prose cap), so `WinResized` re-lays it out; its
     fold state and the cursor's row within it (column clamped) are kept. A fixed-seed fuzz test
     (`tests/diagram_check.lua`) traces every edge from its port to its arrow. Assumes
     `ambiwidth=single`.
   - **Branch labels** (`attribution.lua`). Full scope only: for each hunk, the layers whose
     commits changed its lines. Each layer is diffed on its own with no context (`parent...tip`,
     `-U0`, plus `git diff -U0 <top>` and the untracked files when the top layer is HEAD in
     working-tree mode, as an `uncommitted` layer). A layer's change positions (added lines, and
     `p + 0.5` for a deletion after new-side line p) are carried forward to the top through the
     `-U0` hunks of every later layer (`linemap.from_hunks`, renames followed by path); a line a
     later layer rewrites stops mapping, so it belongs to that layer. A full-scope hunk is
     labelled with every layer that has a position inside its changed span (context lines don't
     count). Chosen over `git blame` because it costs one diff per layer rather than a blame per
     file, attributes pure deletions, and treats the working tree as one more layer; the cost is
     that the stack's history must connect: a layer whose child was not restacked (`diverged`,
     or `stale` with an old tip) is diffed only up to the old tip the child forked from, since
     its later commits are not in the top; a child diffed from trunk gives no labels at all and a
     note in the guide (wrong labels are worse than none). Matching runs on the main thread (about
     80ms for 6,000 hunks).
     Computed in `view` after loading a full-scope review (`review.layer_labels`, cached by
     review signature and layer tips), shown right-aligned on hunk headers in the guide and in
     the full-scope diff (`RevueyLayerLabel`), and appended to the prompt's hunk markers
     (`@@ h7 src/cart.ts @@ [stack/cart, stack/ui]`) with one line explaining the tags.
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
  `prose.lua`, `diagram.lua`, `attribution.lua`) free of window/buffer UI so it is testable with
  `nvim --headless -l`.
- Tests in `tests/`, run with `make test`. Testing strategy and rules are in `docs/TESTING.md`.
- Shell out to `git`/`gh` with `vim.system`; never block the UI for long-running work.
