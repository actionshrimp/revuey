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
- Mark hunks, files and guide sections as reviewed, in either view; marks are kept per review unit and keyed by
  content hashes, so they invalidate exactly where code changes.
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
   (TypeScript returns the import alias until the project has loaded): initialized, at least `lsp_settle_ms`
   old, and, during warm-up only (before the client's first finished `$/progress` report or first
   answered request), no report begun in the last `progress_max_ms` (10s) and not ended: a cold server
   loading its project on a busy machine. Later reports (a check on save) and reports that never end
   don't delay requests; a client's progress state is dropped when it detaches from its last buffer.
   The whole wait is capped at 15s. Proven in a spike; see report notes.
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
   (`detect`): `for-each-ref` (heads, `refs/branch-metadata` and `refs/remotes`), `config --get-regexp` for
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
   related branches outside the stack get suggest-only notes (see **Notes** below).
   **Explicit parents that aren't ancestors** use an old tip of the parent if there is one, or else trunk
   (`stale`), with a note. Every layer target carries `floor = trunk`, so `review.merge_base_for` never diffs
   below `merge-base(trunk, tip)`.
   **Landed layers:** bottom-up, a layer whose own changed files are identical in trunk
   (`git diff --quiet trunk tip -- files`) is marked landed and dimmed. The check stops at the first unlanded
   layer.
   **Squash-merged commits:** before that, the bottom layer (when diffed from trunk) drops its oldest
   commits that trunk already has (`stack.landed_runs`). A run of consecutive commits matches a trunk
   commit that changes the same paths and has the same patch id (one line of context, whitespace kept,
   no path prefixes), and each trunk commit accounts for one run. A revert's reversed patch cancels
   the commit it reverts. The longest run wins. The layer starts after the last run, except that when
   every commit matched the last run stays as the layer's own diff. The full scope starts there too
   (`stack.base_rev`). With no stack, `detect` returns the same start for the plain review, which
   diffs from it while keeping the trunk as its base (labels and marks). Caps: runs of 20 commits,
   branches of 200 commits or 500 paths, the latest 2000 trunk commits touching those paths.
   **Marks:** layers above another layer add the old blob to the content key (`key_old`), so a parent change to
   the same file resets the mark. The bottom layer, full scope and plain reviews keep chunk 1's new-blob keys,
   so they still share marks. Unit marks (decision 10) are per scope too, since they live in the scope's state
   file; their keys carry no scope, so an identical hunk in a layer and in the full scope has the same key but
   separate marks. Layer rows count fully reviewed files: other layers' stats come from `git diff --raw`
   content keys without parsing patches, so only the file-level mark (stored whenever all of a file's units
   are reviewed) is visible there, and "files" matches the row's `3f` column.
   Ambiguity (duplicate tips, forks, unknown or cyclic parents) becomes notes; nothing inferred is
   persisted (the child-branch trap is undetectable from the graph, so the user's explicit choice is the
   fix). Layer diffs use `merge-base(parent tip, layer tip)`, which also covers a trunk that moved on and a
   stack that was never rebased. Only the HEAD layer (and the full scope when HEAD is the top) can include the
   working tree; other scopes are `mode_locked` committed-only. Reviewed state is per layer (layer + normalised
   parent), so the bottom layer and full scope share files with the plain single-branch review of the same
   diff. Per-layer stats come from `git diff --raw` content keys (no patch parsing), loaded in the background.
   `:Revuey <base>` without `--stack` skips detection entirely and behaves exactly like the single-branch review.
   **Remote-tracking layers** (`stack.remote_layers`, pure). The fingerprint's one `for-each-ref` also lists
   `refs/remotes` (and each local branch's `%(upstream)`). **Gate:** remote layers are only considered with HEAD detached:
   on a local branch, refs of the user's own work under other names (backups, PR-ref mirrors, a
   colleague's start, a fork's upstream) would split it, and flip with each push; there only explicit
   parents (revuey settings, Graphite) can name a remote ref. After the first graph load, HEAD's first-parent line
   above trunk is a set, minus commits any remote's default branch has (one `rev-list --stdin` with each
   `<remote>/HEAD`, else `main`/`master`/`develop`, excluded; only run when a remote ref is on the line); a remote ref is a candidate only when its tip is in that set and is not HEAD (no
   per-branch merge-base, so 3000 remote branches add no measurable time). Never `<remote>/HEAD`, trunk (full
   or remote-stripped name), PR-head mirrors (`*/pr/*`, `*/pull/*`), aliases of the checked-out branch (its
   upstream, `@{push}`, refs at their commits, refs named `*/<branch>`), ignore-list matches, or refs whose local copy (a branch tracking it, or of the same
   name) is on the line; a local branch at the same commit wins and the ref goes to the layer's `also`. Several
   refs at one commit: named by an explicit parent, then the name stored for that commit (a per-repo
   `stack-remote-names-*.json` in the state dir, so a new `origin/aaa-backup` doesn't rename a layer, across
   sessions too), then `origin`, then alphabetical. Chosen refs are
   added to `branches` (flagged `remote`) and the resolver treats them like local tips; nothing above HEAD is
   added, so they only ever extend the stack downwards. Explicit parents naming a branch present only as a
   remote copy map to it. **Detached HEAD:** a branch at HEAD (local first, else a remote candidate) becomes
   `current`, its layer `detached`; with none there is no stack and a `detached` note. **Keys:** a remote layer's
   `state_branch` drops the remote (`origin/x` -> `x`) and children use the same key as `state_base`, so a
   local `x` created later inherits marks, comments and guides; local keys are unchanged. The full name is
   kept when an unrelated local `x` exists (one not tracking this ref), or when two remotes' refs with the
   same branch name are both layers (for the less preferred). The CLI (`here()`) resolves a detached HEAD
   to the newest live session's branch for the worktree, else to the current layer `detect` would pick. Remote layers are
   dimmed with `ro` in the panel, committed-only, and `:RevueyStackParent` refuses them; `rescope` falls back
   to the state key, so the review stays on a layer that just gained a local branch. An `upstream` note reports
   when the checked-out branch is ahead of or behind its fetched copy, unless that copy is trunk. revuey never
   fetches.
   **Switching layers** (`switch.lua`: pure `plan`, `collisions`, `parent_setting`, status/worktree
   parsing and message texts, plus `prepare`/`check`/`run`/`set_parent` over git; `view.switch_layer`
   asks and refreshes). `gS`, `:RevueySwitch` and, with `stack.switch_on_navigate`, `]s`/`[s` check
   a layer out in the current worktree with plain `git switch` (no stack tools, no stash, no
   restack). `plan`: a local layer -> `switch` (`noop` when it is the current branch; detached at it
   attaches); a remote layer -> a local branch whose upstream is the ref (same name first) is
   switched to (`noop` when current), else a local branch of the short name (tracking something
   else or nothing) is a `conflict` the user resolves (switch to it untouched, or cancel), else
   `git switch --track <ref>`. Refusals, checked before the question for a connected agent and
   again after it: modified listed buffers of files in the worktree (a later `:w` would write the
   old branch's text onto the new one); a branch in another worktree (`worktree list --porcelain`,
   path named; git's own "already used by worktree" is mapped too); tracked changes (`status
   --porcelain=v1 -z --untracked-files=all --ignore-submodules=all`: submodule pointers and
   contents are left out, since `git switch` without `--recurse-submodules` leaves submodule
   checkouts alone and a pointer left behind by a bump would otherwise block every later switch);
   and `collisions`: every path `git diff --name-status HEAD <target>` adds that already exists on
   disk (untracked or ignored, since tracked files are clean: git refuses for the first and
   silently overwrites the second), or has a non-directory in place of one of its directories;
   a directory at an added path counts unless the switch removes tracked files under it. Other
   untracked files are carried over as git does. One switch per review at a time
   (`s.switching`): a request while one runs is dropped with a message (with `]s`/`[s` the view
   still moves). A connected agent (`agent_link.poll`) gets a `vim.ui.select` confirmation, asked
   once per review for `]s`/`[s` (`s.switch_agent_ok`) and every time for `gS`; questions run
   inside the `git.async` coroutine (resumed from the select callback). A non-zero `git switch`
   after which HEAD is on the branch (a failing `post-checkout` hook) is a warning and the switch
   goes on. **Parent setting:** on a local branch remote refs are layers only when a parent setting
   names them, so when the layer below is a remote-tracking layer and the layer's parent was
   inferred (`parent_setting`: never the bottom layer, whose parent is trunk; never for the
   "switch anyway" to an unrelated branch; never naming the branch itself), the switch writes
   `branch.<b>.revueyParent = <that ref>` (`git branch -d` drops it with the branch, so a reused
   name starts clean). `record_parent` never overwrites an existing setting (`git config --get`
   first; a different one gets a one-line note instead), and records nothing unless the parent is an
   ancestor of the branch (`merge-base --is-ancestor`), so a local copy behind a restack keeps its
   layout. With no stack, `detect` still reports an `unknown_parent` note for the checked-out
   branch's setting naming a branch that is gone (a pruned remote ref), so the stack never vanishes
   silently. The layers above a remote layer's new local branch are not kept: the gate
   stays closed for everything but explicit parents, so stray refs (backups, pushes under other
   names, a colleague's start) never become layers; a detached worktree shows the whole remote
   stack. After a switch: `lsp.checktime()` (hidden buffers reloaded, or wiped when the file is
   gone), then `:checktime` for the user's buffers (their autoread decides; modified buffers are
   never forced), then `refresh{scope = {head = true}}`: `rescope` maps it to the new HEAD layer,
   which keeps the scope on the switched layer (same scope key: per-scope cursor and folds) and
   gives it the working tree. The registry entry gains `checked_out` (the HEAD layer's branch, nil
   when detached) next to the viewed `branch`; `bin/revuey sessions` shows it when they differ.
   Remote layers record a `local_copy` (a local branch tracking them off the line) for the panel
   hint. The panel draws a `virt_lines` hint (`panel.switch_hint`) under the layer row the cursor
   is on while the panel has focus, and a `gS check out layer` help line.
   **Notes** (`stack_notes.lua`, pure) are tables `{kind, branch, layer?, parent?, source?, at?, branches?,
   text}`, one per branch they are about. Kinds that change the diff shown are `warn` (`not_restacked`,
   `squashed`: commits at the bottom left out because trunk has them as squash merges (`squash_skip`; folded
   into the layer's `landed` note when the layer landed entirely), `stale_parent`, `unknown_parent`, `cycle`, `newer_copy`: the stack may be built on an old version of
   another branch, and `outside`: a branch sharing commits, perhaps a parent that moved on, whose commits
   are then in the layer's diff); all others are `info`. `resolve` makes the
   structural ones (also `fork`, `same_commit`, `parent_landed`), `mark_landed` adds `landed`, `detect` adds
   `detached` and `upstream`, and
   `foreign_notes` the related-branch ones from one `git log --branches --not trunk` (same author, author
   date and changed paths, different commit = another copy; commits marked `(cherry picked from commit`
   are skipped). Committer dates give a direction: older elsewhere = `outdated_copy` (that branch is built
   on an outdated copy of the stack). Newer elsewhere is `newer_copy` only when shaped like a parent amended
   under the stack: the matched commits are a contiguous run of the bottom layer below commits of its own;
   under the run the branch holds exactly the stack's commits (a parent amended only at its top); and
   the branch tip is the newer copy of the run's top or a descendant of it (amended, then extended). A
   non-`-x` cherry-pick onto a fresh branch whose tip is the copy looks the same and also warns ("may"). Anything else (backports,
   whole-stack rebases with a backup branch, clock skew) is `other_copy`, informational. Copies are grouped
   by the branch `--source` names, and one `for-each-ref --contains` per group (capped at 30 groups) finds
   every branch holding them. "Set as parent" is offered only when `merge-base --is-ancestor` says the
   branch tip is an ancestor of the layer (`parent_ok`), so it never leads to a stale setting. Remaining branches containing the stack's root
   commit are `side` (they contain a layer tip below HEAD) or `outside`. The panel renders
   `summary()`: at most three lines grouped by kind (the related kinds share one count), wrapped, never
   cut; `notes_float.lua` renders `details()` (every note, grouped, with meaning, impact and branch rows
   carrying actions: set as parent through `view.set_stack_parent`, clear a revuey parent setting, ignore
   a branch or a suggested glob, un-ignore) and re-renders from `panel.render` after each refresh.
   **Ignore list** (`stack_ignore.lua`): globs from `config.stack.ignore_branches` plus a per-repo JSON file
   in the state dir, keyed by the git common dir (worktrees share it; nothing goes into git config). Saves
   re-read and apply only the change, then rename a temp file; an unreadable file is moved to
   `.corrupt-*`. `detect` filters the informational related kinds (`outdated_copy`, `other_copy`, `side`,
   `same_commit`; warnings are never hidden) into `stack.ignored`
   (`review.notes_ignored` without a stack) after detection, so ignoring never changes the layers; the
   patterns are part of the fingerprint, so a change re-runs detection and other instances notice it.
8. **State** lives as JSON under `stdpath('data')/revuey/`, keyed by repo + review target; a pure-Lua data layer with
   no UI calls so it can be tested headless. Format version 2: `files` (file marks by content key), `units` (unit
   and parent hunk marks by key) and, read only, version 1's `sections` (guide section marks by identity). Saves
   re-read the file and apply only this instance's changes (file marks per path and key, unit marks per key), then
   write a temp file and rename it. Read, merge and rename hold a cross-process lock (`lock.lua`), so two
   processes saving at once cannot both start from the old file. The lock is `<file>.lock`
   created with O_EXCL and holding "pid host time token"; release removes it only when it still
   holds this holder's token. A lock whose pid is dead on this host is broken at once, and any
   lock of this host older than 60s (its pid may have been reused; holders keep it for
   milliseconds); one from another host (or without a readable record) when older than 15s. Breakers serialise on
   `<file>.lock.break` and remove the lock only if it is still the one they judged stale, so two
   breakers never both end up holding it. The CLI waits up to 10s (`$REVUEY_LOCK_TIMEOUT_MS`).
   The UI waits at most 100ms: on a busy lock the change stays pending in memory (`_changes`,
   the comments store's dirty ids, queued event lines) and `lock.defer` retries the save from a
   timer with backoff (50ms doubling to 2s), with one quiet message if it still fails after 30s
   and a last 2s try on `VimLeavePre`. A save still blocked then is written to a recovery file
   next to its file (`<name>.pending-<pid>.json`, `.jsonl` for events) that the next load merges
   (comments by last writer wins, marks as pending changes; events are appended first), saves and
   removes. The stack ignore
   list, the comments file and the comment event feed use the same lock.

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
   - **Section reviewed state** is derived: a section is reviewed when all units of the hunks it shows
     are (decision 10), so marks are shared with the diff view and survive regeneration per hunk. The
     section identity (hash of the sorted hashes of the hunks it shows) still keys the guide's
     remembered section folds, and version 1 state files stored section marks under it: when a guide
     resolves, a stored `sections[id]` matching a section marks that section's units and is dropped.
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

10. **Review units and nested marks** (`units.lua`, pure). A unit is the atomic reviewable piece;
   today one diff hunk, later several per large hunk (the planned split at tree-sitter or blank-line
   boundaries, `h7a`/`h7b`). Nothing outside `units.lua` assumes one unit = one hunk: marks, progress,
   folding and the guide's hunk references go through it.
   - **Keys.** `units.derive(files, {key_old, split})` reuses `guide.hunks`: a unit's key is the
     guide hunk hash (path, `+`/`-`/space prefixes, text, CR and no-EOL flags; not line numbers;
     identical hunks get `@old_start,new_start`), so guide hunk ids map 1:1 to unit keys. A piece of
     a split hunk is keyed the same way by its own lines (`@` plus its first line numbers when
     identical). Each unit records its parent hunk key, file index, path, line range and the file's
     content key (`state.content_key`, with the old side for `key_old` layers).
   - **Files without hunks** (binary, placeholders, pure renames, mode-only changes) get one
     whole-file unit whose mark *is* the file mark, keyed by content key as before.
   - **Coverage.** A unit is reviewed when its key, its parent hunk's key, or a file mark with the
     file's current content key is set. When all pieces of a hunk are marked the hunk key is stored
     too, so a different split later still counts the hunk as reviewed; when all units of a file
     are, the file mark is (for layer stats). These derived marks are computed by `state.save`
     (a `_finalize` hook from `units.lua`) on the merged tables, after re-reading the file and
     applying this instance's changes, so two Neovims marking parts of one file still produce its
     file mark, and a stale instance never stores a file mark over another's unmark. An unmark
     always records removal of the unit key, its parent hunk key and the file mark at the current
     content key, even when this instance never saw them (another instance may have stored them);
     siblings covered only by those marks are spelled out as unit marks first. A matching file mark
     with no unit marks behind it at all is a legacy mark and is converted in the same step.
     Toggling a group (hunk, file, section, selection) marks all when any unit is unreviewed, else
     unmarks all. On a code line of a split hunk `mr` toggles just the unit holding the line; the
     header toggles the whole hunk (`review.split` is a test hook for the cut until the engine
     splits hunks itself).
   - **Pruning.** On each save, unit marks whose key the current review does not show and has not
     shown for 30 days are dropped. Rendering a review refreshes `seen_at` on the marks of every unit
     it shows (`units.touch`, at most one save per scope per day), and the save that prunes keeps
     every key of the review it belongs to, so a mark of a unit on screen is never pruned.
     The grace period matters because working-tree and committed mode share a state file, so a
     review never sees all of its keys at once. Within it, reverting an edit brings the mark back,
     which is right: the content is the reviewed content again.
   - **Derived state.** A file is reviewed when all its units are; a section when all units of its
     hunks are. Partial progress is shown as `◐ done/total` (units) on diff file headers, hunk
     headers once split, the winbar, the panel's file rows and section list, and guide section
     headings; complete ones show `✓ reviewed` / `☑`.
   - **Migration.** Version 1 file marks keep counting for all units (the file-mark coverage rule);
     when a review is rendered, a matching file mark without unit marks behind it is converted to
     unit marks and saved, so a later edit of one hunk resets only that hunk. Version 1 section
     marks are converted when the guide resolves (above). Nothing is lost if a conversion fails:
     the old marks still count until the next successful save.
   - **View (`view.lua`).** `mr` resolves a target from the cursor row: inside a hunk block (header,
     note or line) its hunk's units; elsewhere a diff file or a guide section; visual `mr` collects
     the units at the selected rows. After toggling, file and hunk headers, section headings and the
     panel are updated in place; folds change in this view (files or sections that became complete
     close, ones that stopped being complete open; hunks marked on their own collapse, unmarked ones
     expand), the other view's remembered folds follow, and the cursor moves to the next unreviewed
     hunk (skipping hunks inside a collapsed file, section or hunk), file or section, or stays on
     the last one without reopening it. Visual `mr` first widens the selection to whole collapsed
     folds at either end. In the guide the in-buffer meta line ("1/2 reviewed") is rewritten in
     place, and with a UI attached the winbar is redrawn. A hunk appears in at most one guide section (resolution and validation place each hunk
     once), so hunk fold keys need no section scope. Hunk fold state is kept
     per view by hunk key: `true` (the user's `<Tab>`), `'reviewed'` (collapsed because reviewed),
     `false` (the user expanded it), nil (no choice: a reviewed hunk in a file or section that is not
     complete starts collapsed). Unmarking a whole file or section only re-expands `'reviewed'`
     hunks, so the user's own collapses stay. A refresh that makes a complete file incomplete (an
     edit) re-opens its fold, with its still-reviewed hunks collapsed.

11. **Comments** (`comments.lua` pure model, storage and events; `comments_export.lua` Markdown/JSON;
   `comments_view.lua` UI glue; `comment_editor.lua` the float; `cli.lua` the shell side).
   - **Model.** `{id, anchor, body (md), author {kind = user|ai|agent, name?}, status (draft|saved|resolved,
     room for dismissed|accepted), in_review, thread [{id, author, body, created_at, updated_at}],
     created_at, updated_at (ms), file_level, outdated (derived)}`, plus `draft`/`reply_draft` for unsaved
     edits of a saved comment, and the delivery fields of a comment sent to an agent (decision 12):
     `sent_at`, `sent_reply` (the follow-up reply sent, else the body), `acked_at`, `answered_at`. Ids are 11 hex digits of milliseconds and 5 random ones: sortable and
     unique. The UI makes `user` comments; `bin/revuey comment` makes `agent` ones (saved, `in_review =
     false`); agent replies are `agent` too; AI review findings (`ai`, `dismissed`/`accepted`) and the
     forge's "add to review" (`in_review`) fill the rest. Agent and AI authors are labelled
     (`claude (agent)` when named) and highlighted `RevueyCommentAgent` in threads, `by …` in the
     list and the Markdown export.
   - **Anchor.** `{path, side = new|old, start_line, end_line, unit_key, unit_line, hunk_key, hunk_line,
     context_hash, text_hash, context_lines, snippet, sort_line}`. `sort_line` is the anchor's place in new-side order (a deleted line sits just before the next new-side line of its hunk, `n - 0.5`), kept up to date by placement and used to order lists and exports. A range is on the new side when any selected row has a new-side line
     (deleted rows inside it stay in the snippet), else on the old side. `context_hash` is a sha256 of
     the side's lines `start-2 .. end+2` (from the full side text: the reviewed snapshot or new blob, the
     old blob; positions outside the file hash as a marker). `snippet` is the selected rows with
     `+`/`-`/space markers when made.
     **Anchors from the shell** (`comments.anchor_for_lines`, for `bin/revuey comment`): path, side
     and lines as given (an old-side range stays old even over context lines), the snippet of the
     rows from the first line to the last (other-side rows included, as a selection), `sort_line`,
     and the same `context_hash`/`text_hash`/`context_lines` over the same side text
     (`review.side_text`, shared with the UI: the working-tree file or loading snapshot for `new` in
     working-tree mode, the new blob when committed, the old blob for `old`). `unit_key`,
     `hunk_key` and the offsets are left out: the UI's placement finds them by hash.
   - **Placement** (every render, against the review's files and units, view-independent): the anchor's
     unit still exists (same content, so only shifted) -> the same offset in it; else its parent hunk;
     else the nearest window of rows shown on that side whose hash matches (ties: nearest to the last known
     line, so identical code at two places stays put); else, within 100 lines, the nearest window whose
     lines alone match `text_hash` (only stored when the lines hold three or more word characters, so a
     lone `}` never wanders; this covers an edit next to the comment, or lines inserted at the top of a
     file, where the context changed but the commented code did not); else outdated. Renders after a review change write
     the "last known" lines, unit and outdated flag back (no `updated_at` bump: derived, every instance
     derives the same); renders caused by a live reload never write, so two instances in different modes
     cannot ping-pong, with one exception: a line comment with no unit and hunk yet
     (`comments.unresolved`, made by the CLI) that placement put in a unit is written at once, with
     `hunk_line` and `unit_line` (when its last line is in the same unit), exactly as a selection of
     those rows would have stored them. That happens once per comment, so it cannot ping-pong
     either; with no UI running the first render of the opened review (which persists) does it. Rows come from the layout (`comment_index`), so the guide shows the same comments
     where it shows the lines; an outdated comment sits at its last known row, else in an "Outdated
     comments" group on the file's last row; a file-level comment under the file header (guide: the
     file's first hunk header). Threads are `virt_lines` in their own namespace and the gutter bar is
     drawn by `view.statuscolumn` in the first cell of the sign area (same width), so buffer text, the
     side table, folds, marks and LSP are untouched.
   - **Storage.** `<state file>.comments.json` next to the marks file of the scope (a separate file, so
     an older revuey rewriting the marks file cannot drop comments). Saves re-read the file and merge per
     id: last writer wins by `updated_at` (ties: this instance for its changed ids), deletes are tombstones
     (`{id, deleted, updated_at}`), replies are merged by reply id (an agent reply survives a concurrent
     edit of the body). Read, merge and rename hold `lock.lua`'s lock (see decision 8): without it 20
     parallel `bin/revuey reply` calls kept only 14 replies. Atomic write (temp + rename); an
     undecodable file is moved to `.corrupt-*`. Comments and their tombstones are never pruned, so a
     long-idle instance can never resurrect a deleted comment. The UI watches the state directory (`uv.fs_event`; renames replace the file) and reloads
     with an 80ms debounce.
   - **Event feed.** Each change appends one JSON line to `<state file>.events.jsonl`: `{id (sortable),
     kind = created|updated|deleted|resolved|replied|sent|acked, at, comment_id, review {repo,
     branch, base, state_branch, scope, layers?, head, merge_base, mode}, location, anchor, snippet, body,
     author, status, file_level, outdated, reply?}`. Past 1 MB the file is renamed to `.1` before the next
     append. `cli.lua watch` polls every events file of the state dir (new ones too) every 250ms: files
     present at start are followed from their end (`--since` replays from the start, `.1` included); a
     changed inode means rotation: the old descriptor is drained, `.1` is read whole if it is not the
     file being followed (two rotations between polls), and the new file is followed from 0. Events are
     filtered by repo and branch (`branch`, `state_branch` or full-stack `layers`) and printed with a
     flush per line. Neovim turns SIGTERM into a deadly-signal exit, so `bin/revuey` runs `watch` as a
     child and turns TERM/INT/HUP into SIGUSR1, which the script handles with a `Signal` autocmd; it also
     exits when its parent goes away. `reply` merges and saves like the UI, then appends a `replied`
     event; `comment` saves a new comment and appends `created`; the running UI picks the file
     change up (and notifies "the agent commented on …"). Without `--all`, `watch` skips the
     agent's own events: `replied` by an agent, `created` with an agent author, and `acked`.
   - **Send hook.** The editor's `<C-a>` calls `comments_view.actions.send({session, kind, anchor,
     comment?, text, store})`. The default is `send_to_agent` (decision 12); the later chat panel
     plugs in here.

12. **Agent link** (`sessions.lua` pure registry and presence; `agent_link.lua` UI glue;
   `comments_view.send_to_agent`; `cli.lua` the agent side; `skill/revuey` the Claude Code skill).
   A coding agent receives comments sent from a running review and answers in their threads,
   whether it launched revuey or connects to a review the user started.
   - **Registry.** A base is a directory with `sessions/` and `watchers/`: first the worktree's own
     git dir (`git rev-parse --absolute-git-dir`, so linked worktrees are separate and nothing
     shows in `git status`) + `/revuey`, then the state dir when that is not writable. Each review
     writes `sessions/<nvim pid>.json` (`{id, pid, host, worktree, git_dir, branch, checked_out, base, mode,
     scope {kind, branch, layers}, scope_key (state file name), comments, events, state_dir,
     server (v:servername), common_dir, started_at, updated_at, load {base, from (the merge
     base), target, mode, context_lines, max_file_bytes}, review (review_info)}`) atomically after its first
     render, rewrites it at the end of any render that changed it (scope, layer, branch) and on
     every 2 s poll (`updated_at`), and removes it on cleanup and `VimLeavePre`. An entry is dead
     when its pid is dead or its `server` (a path) is gone. Staleness alone does not kill it (a
     review suspended with Ctrl-Z or blocked stops refreshing): an entry older than 30 s is
     dead only when its socket does not accept a connection (`sockconnect`; the kernel accepts
     for a stopped process), which is how a crashed review whose pid was reused looks. Listing removes the others and
     unreadable files. `--all` scans the common dir's base and each `worktrees/*` base, and
     keeps entries of this repo's `common_dir` only (the state dir fallback is shared).
   - **Presence.** `watch` writes `watchers/<pid>.json` `{pid, session|null, worktree,
     heartbeat_at, mode}` at start, on (re)attach and every 5 s, and removes it on exit. The UI
     polls every 2 s: connected when a watcher attached to its id (or attached to no session, in
     its worktree) has a heartbeat under 30 s and a live pid. A change redraws the panel's winbar
     (`agent_link.winbar`, kept by the winbar guard) and the comment markers.
   - **Delivery** is separate from `status` (draft/saved/resolved, AI review dismissed/accepted)
     and `in_review`, so sending never interferes with triage or the forge. `comments.delivery`
     derives `sent` (queued: no watch printed it), `delivered` (delivered_at >= sent_at),
     `seen` (acked_at >= sent_at), `answered` (answered_at, or an agent reply created after
     sent_at). The timestamps merge by maximum (an ack from the CLI survives a concurrent edit
     in the UI; the newest send carries its `sent_reply` and `sent_session`). A re-send sets
     `sent_at` past every earlier delivery, ack, answer and agent reply. Markers follow this
     state: only an undelivered message depends on presence ("queued" or "sending").
   - **Sending.** `<C-a>` (new comment, edit, or a reply as a follow-up), `cs` (existing comment)
     and `ga` (the editor titled "Ask agent" on a line or selection) save the comment, set
     `sent_at` and `sent_session` (this review's id), and append the usual event plus a `sent`
     event: the comment event fields (full anchor, snippet, body, review {repo, branch, base,
     scope, layers...}) and `message`, `message_kind` (comment|reply), `sent_at`, `session`. The
     sent event is appended through `lock.after`, so when a busy lock deferred the comments
     save it waits until the comment is on disk (`show`, `reply` and catch-up read the file).
     Without a connected agent the send is recorded all the same and marked "queued".
   - **watch.** Attaches to the worktree's single live session (`--session` when several; with
     none it waits, and it re-attaches when its session's entry disappears and one new session
     appears). It follows the event files of the default state dir and the session's; files in a
     directory seen for the first time are followed from their end. Then a catch-up: every
     undelivered sent comment in the repo's comments files (`comments.undelivered`, rebuilt as
     `sent` events; `--replay`: every unacknowledged one), after the feeds were opened, so a
     message sent in between appears in both and is printed once (dedupe by `<comment
     id>:<sent_at>`). In `--messages` mode each printed message is stamped `delivered_at` in its
     comments file, so the next watch (Monitor re-armed, new pid) does not print it again; no
     per-watcher cursor. Routing: a message whose `session` is another live review is left to
     that review's watchers; one from a review that is gone (or with no session) goes to any
     watcher, and a change in the live set triggers another catch-up. `inbox` picks its review
     the same way (`--session`, else the only one, else exit 2) and filters with the same rule
     (`cli.routed`). When the attached review ends, `watch` re-attaches to the one live review
     with the same `scope_key` (the review restarted), else prints that it waits. Sent events match by repo
     (any branch or scope of the worktree); other events keep the `--scope` filter.
     `--messages` prints only sent events as `revuey message <id> <loc> (<side>) [<branch or full
     stack>][ follow-up]: <first line>  (<bin> show <id> for full context)`; `<bin>` is
     `$REVUEY_BIN`, which `bin/revuey` sets to its own absolute path.
   - **Agent commands.** `show` renders one message (`comments_export.message`); `reply` also
     sets `acked_at`/`answered_at` on a sent comment; `comment --path p (--line N [--end M]
     [--side new|old] | --file) <text|->` leaves a new agent comment. It picks the review like
     `watch`/`inbox` (`--session`, else the only live one, else exit 2) and loads its diff
     headlessly with `review.load` from the session's `load` (exact: same base, merge base, stack
     target, mode and hunk options; one `git diff` plus the working-tree snapshot, well under a
     second), writing to the session's comments and events files. With no live review it loads
     what `revuey` opens there: `stack.detect` and the HEAD layer's target (a detached HEAD
     resolves to the layer of the branch at HEAD), else the plain review against the trunk; the
     comment shows when that review is opened. The CLI runs with `--clean`, so it cannot read the
     user's config, and a wrong trunk, mode or state dir would put the comment into a scope file
     the next review never opens (or validate it against the wrong diff, so it opens outdated).
     So every review also writes `<base>/last-review-<hash of worktree>.json` (`sessions.write_last`,
     same bases as the registry: the worktree's git dir first, so it is found whatever
     `state_dir` says; kept after the review closes): the trunk (the stack's, else the plain
     review's base), an explicit base, whether stacks are detected, `full` scope, the mode it was
     opened in, the state dir, `context_lines` and `max_file_bytes`. The CLI uses it, re-detecting
     the stack with that trunk; without one (revuey never opened in this worktree) it falls back
     to the default branch, working-tree mode and the default state dir. It prints the scope, the
     base and the mode (`in feat vs develop, working tree`). Validation
     uses that diff: the path must be a changed file (else the first changed paths are listed;
     the old path of a renamed file names the new one), every line must be shown on that side
     (else the nearest hunk ranges and `--file` are suggested), `--end >= --line`, at most
     `comments.MAX_RANGE` (200) lines. `ack` sets `acked_at` and appends an `acked`
     event (hidden from `watch` unless `--all`; refused for a comment never sent); `inbox`
     prints every unacknowledged message, delivered ones marked "(delivered, not handled)", and
     exits. A short id matching several comments is refused with the candidates. All of
     them search the default state dir plus the live sessions' state dirs, so a review whose
     config sets another `state_dir` is still found while it runs.
   - **Skill.** `skill/revuey/SKILL.md` (connect, Monitor with the 30-minute maximum and re-arm,
     `show`/`reply`/`ack`, `inbox` without Monitor, no edits unless asked), `revuey` (finds
     `bin/revuey` via `.revuey-bin`, the skill's real path, or PATH) and `launch.sh --in
     tmux|herdr|none <dir>`: an explicit target, verified (`tmux display-message -t
     $TMUX_PANE`, `herdr pane get $HERDR_PANE_ID`) or refused, never guessed; the pane runs
     `bash <temp script>`, so no quoting reaches the pane's shell (bash, zsh or fish). The skill
     runs `inbox` once on connect (messages a crashed agent was shown), puts `cd <worktree> &&`
     before every command (Monitor has its own cwd), treats only the Comment and the user's
     thread entries as requests, and answers instead of editing when the message's branch is
     not checked out. `bin/revuey install-skill` links it into `$HOME/.claude/skills/revuey`
     (`--copy` copies and writes `.revuey-bin`); an existing install is replaced only with
     `--force` or a yes on a terminal, a directory being moved to `~/.claude/revuey-skill-backups/<time>/` (outside `skills/`); a link to
     the same checkout by another path counts as installed; installing from a worktree or temp
     path warns.
   - **Tests never reach the user's multiplexer.** `tests/helpers.lua` drops `TMUX*`, `HERDR_*`,
     `ZELLIJ*` and `CMUX_*`, sets a private `TMUX_TMPDIR` and puts failing `herdr`/`zellij`/`cmux`
     blockers first on PATH; `guard_spec.lua` (first in `make test`) checks this from a
     subprocess, requires `-L` on every tmux call in the specs, and drives `launch.sh` against
     fake multiplexers only.
   - **Later: the chat panel** sends through the same hook and can reuse the delivery fields and
     the thread as its transcript.
13. **Pull request status** (`forge.lua` pure lookup, cache and display models; `forge_view.lua`
    panel glue; `log.lua` quiet log). Read-only, GitHub only, through the user's own `gh` (assumed
    logged in; no auth checks or setup flow).
    - **Targets.** `forge.remote_info` reads `git remote`, `git remote get-url <name>` per remote,
      one `git for-each-ref` with each branch's `%(upstream:remotename/remoteref)` and
      `%(push:remotename/remoteref)`, and `git config --get-regexp` for
      `remote.<name>.gh-resolved`. `parse_remote_url` handles
      scp-like, `ssh://`, `https://` and `git://` URLs; a host is GitHub when it is github.com (or
      an ssh alias such as `github.com-work`, or `ssh.github.com`), contains "github", or is in
      `forge.hosts`; local paths and other forges give nil, so such repos make no call. The base
      remote is resolved like gh: `gh-resolved = base`, else `upstream`, else the trunk's
      (`origin/main` -> origin, a local trunk's upstream), else `origin`, else the only GitHub
      remote. Each layer (key: layer name; a plain review: `''`) gets a target `{candidates,
      tip}`. Candidates, tried in order: a remote layer's name without its remote
      (`split_remote`); for a local branch its own name, then its push target's name, then its
      upstream's name when different and not the trunk's (`git switch -c feat origin/main`
      tracks main). Each candidate has `{branch, remote, head_owner, repos}`: `repos` is the base
      repo, plus the branch's own remote's repo when that differs (a fork: its PR usually lives
      in the base repo with `headRepositoryOwner` = the fork's owner).
    - **One call.** `build_query` aliases one `repository(owner,name) { pullRequests(headRefName,
      first: 30, orderBy: UPDATED_AT desc) parent { nameWithOwner pullRequests(...) } }` per
      distinct (repo, branch), so a fork's parent is searched in the same request (null for a
      non-fork; left out when the base came from `gh-resolved` or `upstream`, so an internal fork
      doesn't match its public parent's PRs), with a shared fragment: number, title, url, state, isDraft, updatedAt,
      headRefOid, author, reviewDecision, latestReviews,
      reviewRequests, mergeable, base/head ref names, headRepositoryOwner and the head commit's
      `statusCheckRollup.contexts` `checkRunCountsByState`/`statusContextCountsByState` (counts
      only, no per-check nodes). One `gh api graphql -f query=…` per host per fetch (in practice
      one per refresh), `vim.system` with `forge.timeout` (15s; code 124 -> "timed out"), its
      handle given to the caller to kill. `pick` sorts by `updatedAt` across repos and prefers
      an OPEN PR, then MERGED/CLOSED ones whose `headRefOid` is on the branch's line
      (`check_heads`: `git merge-base --is-ancestor` oid -> tip, else tip -> oid for a branch
      behind commits made on GitHub; concurrent, memoised in `forge.ancestry`; an unknown commit
      counts as unrelated), among PRs whose head owner is the candidate's
      (null for a deleted fork: never ours). The first candidate with a PR wins.
    - **Cache.** `forge.cache[host/owner/name] = {at, branches = {branch -> PRs}, failed?}` (a
      repo's entry also holds its parent's PRs); a target is fresh when every repo it searches
      was fetched (or failed) within `forge.ttl`. A failure keeps the last good `branches`, so
      what was shown stays, marked stale (`?`, `(stale)`). `forge_view.update` runs from view's
      `render` (open, scope switches, refreshes that re-render), resolves targets and fetches
      only when something is stale, then redraws the panel only if the PRs it shows changed
      (`forge_view.signature` against what `panel.render` last drew), with
      `panel.render(s, {keep_view = true})`: background redraws (this one and the stack stats)
      keep the panel cursor on the item it was on (file, layer, section, PR heading; the view
      scrolls by the rows added above) instead of jumping to the diff's current file. `R`
      (`refresh{forge = true}` -> `s.forge_force`) fetches whatever the cache holds. One lookup
      per review at a time: requests while one runs become one follow-up. Each lookup has a
      generation; `forge_view.detach` (review cleanup) bumps it and kills `gh`, and `fetch`
      writes nothing when `alive()` is false after the call, so a late result or failure never
      reaches the cache or a newer panel. No polling: `panel.render` calls `forge_view.lazy`,
      which schedules an update once the TTL has passed. A failure is cached like a result, so
      a broken `gh` is retried once per TTL (or on `R`), not on every redraw.
    - **Failures** (spawn error for a missing `gh`, non-zero exit, unparsable JSON, GraphQL
      errors, rate limits, network) show nothing: the reason goes to `log.lua`, which appends to
      `log_file` (default `stdpath('log')/revuey.log`, moved to `.1` at 256KB) and keeps the last
      200 entries in memory.
      Partial data with errors (one repo not found) is used and the errors logged.
    - **Display.** `forge.row` (`#N` plus `✓`/`✗`/`●`/`○` by review decision; draft, merged and
      closed dim with a marker) and `forge.detail` (title, author/state/draft, decision, latest
      review per reviewer, requested reviewers, check counts, mergeable for open PRs, base, and a
      `base_mismatch` warning when an open PR's base differs from the layer's parent as GitHub
      would name it) are pure models. The panel prepends the row chips to a layer's virtual
      text (a plain review: its `branch → base` line); when the name has less than 8 cells left
      the commit count goes. `forge_view.render_detail` draws the viewed layer's section below
      the stack section (none in full scope), wrapped to the panel (`panel.wrap` breaks words
      wider than a line by display width); `<Tab>` on its heading toggles
      `s.forge.collapsed`; `gx` (`keymaps.forge_open`) opens a row's PR (layer rows, detail rows,
      else the viewed layer) with `vim.ui.open`. Highlights `RevueyForge*`.
    - **Later** (roadmap 5, 6): forge review threads and posting reviews reuse `remote_info`,
      `targets`, `parse_remote_url` and `run_graphql`; the PR found here gives the number and
      repo.
    - **Tests** use `tests/bin/gh` (fake, records argv, answers queries from canned PR nodes per
      `owner/name:branch`); `tests/helpers.lua` blocks the real `gh` on PATH for every spec.

## Code layout conventions
- `lua/revuey/` modules; `plugin/revuey.lua` defines user commands only (lazy-require modules).
- Keep git/data logic (`git.lua`, `diff.lua`, `state.lua`, `units.lua`, `stack.lua`, `stack_notes.lua`, `stack_ignore.lua`, `switch.lua`, `forge.lua`, `log.lua`, `guide.lua`, `guide_prompt.lua`,
  `prose.lua`, `diagram.lua`, `attribution.lua`, `comments.lua`, `comments_export.lua`, `sessions.lua`, `cli.lua`) free of window/buffer UI so it is testable with
  `nvim --headless -l`.
- Tests in `tests/`, run with `make test`. Testing strategy and rules are in `docs/TESTING.md`.
- Shell out to `git`/`gh` with `vim.system`; never block the UI for long-running work.
