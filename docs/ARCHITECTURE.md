# revuey architecture

revuey is a code review surface implemented as a **pure Neovim Lua plugin** (Neovim >= 0.12, no plenary, no
nvim-treesitter dependency at runtime beyond installed parsers). Background research and the reasons for this choice
are in `reports/Terminal code review tool landscape.md`.

## Product goals
- Review local branches and full local PR stacks before pushing (base = merge-base with a configurable default
  branch such as `main` or `develop`; stack = chain of branches each based on the previous).
- Review GitHub PRs (and their stacks) in a worktree the user's worktrunk (`wt switch pr:N`) sets up and
  builds, so the whole codebase is navigable with LSP (decision 16; no fresh-clone mode).
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
   `git switch --track <ref>`. Refusals, checked after the conflict question: modified listed
   buffers of files in the worktree (a later `:w` would write the old branch's text onto the new
   one); a branch in another worktree (`worktree list --porcelain`,
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
   still moves). The conflict question runs inside the `git.async` coroutine (resumed from the
   select callback). A connected agent is not asked about: the switch goes ahead and the agent is
   told afterwards (`agent_link.tell_switch`, decided by a fresh `agent_link.poll`; no agent, nothing
   is written). It gets a `switched` event in the review's feed (`comments.switch_event`: `from`,
   the branch checked out before, absent when detached; `to`; `layer`, `layer_index`/`layer_count`;
   `pr` {number, url, title} from `forge_view.pr`, the cached lookup, never fetched for this;
   `session`, `worktree`, `review` for watch's routing), which `watch --messages` prints as `revuey
   switched <from> -> <to> (layer i of n[, <remote layer>][, PR #N <url>]): ...`, once per event
   id. Unlike a message it is never stamped or stored, and it is live only: `watch` drops one whose
   `at` is before the watch started (`--since`, a rotated feed read again), so a later watch never
   catches it up (the registry's `checked_out` is the lasting record). It goes only to watchers of
   the review that sent it (its `session` is the attached one, or the one that just ended),
   never through `routed`'s fallback for messages of a review that is gone: a review closing with
   a switch waiting writes the event and removes its entry in the same tick, and another
   review's agent must not get it. A `bin/revuey watch` older than this event prints it without
   `--messages` as a garbled `switched ? (new): #nil` line; nothing depends on that. A question used to guard this; telling
   instead keeps the agent informed without a prompt on every switch, and it is the agent's
   cue to re-read files. A write failure is logged (`log.write('agent', ...)`) and the done
   message says the agent was not told; it never fails or undoes the switch. `]s`/`[s` switches
   coalesce: each one waits `agent_link.SWITCH_COALESCE_MS` (1.5 s) in `link.switch_pending`, and a
   later switch takes its place keeping the first `from`, so walking the stack sends one message
   for where the user stopped rather than one per layer passed (each would tell the agent to drop
   its work and re-read files it is about to lose again). Any later switch (`gS` too, which sends at
   once) carries a waiting one along, and closing the review (`detach`) or quitting Neovim
   (`VimLeavePre`, over every linked review) sends it; a net move back to the branch the agent
   last heard of sends nothing, and says nothing about the agent. A review closed while `git
   switch` ran tells the agent all the same when the last poll saw it connected. A non-zero `git switch`
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
     a file list with `+/-` counts and ids, then each hunk as `@@ h7 path @@` + the git hunk, its
     lines numbered within the hunk (`3|+text`, as for AI reviews, so line notes can point at
     them; the numbers cost a few characters per line of the budget). Over
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
     `{title, summary (md), sections: [{title, overview (md), hunks: [{id, note?}], line_notes?:
     [{hunk, line, end_line?, text}] (max 3)}], unplaced: [id],
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
   - **Line notes** (the guide drawing the reviewer's eye to specific lines). A section's
     `line_notes` point at lines the way AI review findings do (decision 15): a hunk id plus the
     `n|` numbers of that hunk's lines, `end_line` for a short range. There is no side field:
     the numbered line's `+`/`-`/space marker decides it (`old` for a deleted line, else `new`),
     so the model cannot contradict itself. The prompt asks for notes sparingly (a key line, a
     subtle condition, the call that wires things together), never restating the overview and
     never reporting issues, which belong in an AI review (`:RevueyAIReview`) or a
     `> [!WARNING]` callout. `guide.validate(raw, hunks, shown)` checks each note with
     `guide.hunk_range`, the check AI review findings now share (unknown or unplaced hunk, a
     line that is not an integer inside the hunk or past what the prompt numbered: an
     abridged hunk's first 6 lines, nothing at the `files` level), and drops, never moves, a
     note with a bad anchor, no line, no text, an exact duplicate, or past the caps: 3 per
     section (also the schema's `maxItems`) and 12 per guide, in the model's order. Ranges are
     clamped to 8 lines and text to one line of 200 characters. A note stays with the hunk it
     points into, whichever section shows that hunk, and counts towards that section's cap
     (the prompt says so: usually a hunk of the section, else shown with that hunk).
     Drops are counted by reason (`warnings.notes`, the same reasons and wording as findings,
     `guide.dropped_text`) and named in the "guide ready" message.
     The record (version 2) stores each note on its hunk anchor with the lines it pointed at
     (`lines`) and up to 2 hunk lines either side (`before`, `after`); version 1 records have
     none and load unchanged (`sanitize_notes` also drops malformed notes of hand-edited files
     and keeps at most 12 per record). `guide.resolve` keeps notes of hash-matched hunks as
     they are. On a hunk re-anchored by overlap, or merged into one an earlier anchor of the
     section shows, a note stays only where its lines plus that context match at exactly one
     place in the whole hunk (its old line is just one candidate) and the matched text is not
     weak (`comments.distinctive_words`, as for comments and GitHub threads). Without stored
     context the lines alone must be unique and not weak. A short line (`return nil`) has
     copies, and a note on the wrong line is worse than a lost one. Everything else is lost
     and counted (`notes_lost`, in the stale banner), as are the notes of hunks that vanished.
     Not regenerated automatically.
     Rendering (`guide_view.draw_notes`, namespace `revuey.guide.notes`, after comments on every
     render): `virt_lines_above` on the note's first row, a band (`RevueyGuideLineNote`, a
     violet tint mixed into `Normal`'s background, per light/dark) with a `▼ guide` label
     (`· N lines` for a range) and inline markdown only (no code blocks or callouts, so a note
     can never render as a warning; the raw text when the markup leaves nothing), wrapped to
     the text width and cut to the window when it is narrower than a word. Choices: above
     the line (the reader meets the note before the code, and comments, AI findings and GitHub
     threads all hang below their last line, so they never collide); no box and no author
     line, so it never reads as a comment; shown by default (that is the point of a note);
     `gN` collapses all of them to a `◆ guide` end-of-line marker and back (per session, kept
     across re-renders; one toggle for all, since notes are one-liners and per-note collapse
     would need a key nobody remembers); `]n`/`[n` move between them, a pair of their own
     because `]m`/`[m` is the comment list's order and covers items with actions (`ce`, `ca`,
     `cn`), which notes have none of. `]n`/`[n` are unused by Neovim and `gN` (select the
     previous match) means nothing in a read-only buffer; the keys are configurable
     (`keymaps.next_note`, `prev_note`, `toggle_notes`) and only mapped in the review buffer.
     Notes are part of the guide document, not the comment store: no triage, export, agent
     delivery or posting, and they are not drawn in the diff view, which stays the plain diff
     plus your own comments; a note's wording is the guide's narrative and may be stale.
   - **Persistence.** `<state_dir>/guides/<slug>-<hash(repo, branch, base)>-<generated_at>-<hash(anchor set)>.json`
     (the name carries time and anchors, so lookups decode one file; the newest `ai.keep_guides` (5)
     per review key are kept),
     keyed like reviewed state (so each layer and the full scope have their own), holding sections
     with anchors (not ids) plus `generator = {provider, model, session_id, generated_at, head,
     merge_base, mode, duration_ms, cost_usd, abridged, warnings}`. Opening a review loads the guide for
     the exact anchor set, else the newest one for the key.
   - **Staleness** (`guide.resolve`): hunks are matched by hash first. Guide hunks left over are
     then **re-anchored by overlap**, like comments (position plus context, conservative): a
     candidate is a current hunk nobody matched by hash, in the same file, whose function
     context (text after `@@ … @@`) is empty on either side or equal, and whose old-side range
     (parsed from the `@@` header stored in the anchor, so older records work; an empty range is
     the point after its line) overlaps the guide hunk's. The old side comes first because
     working-tree edits leave it in place while new-side ranges shift with every line added
     above (a hunk that grew would otherwise overlap the next hunk's out-of-date range); the
     new side is used only when no old-side candidate exists. A guide hunk matches when it
     has exactly one candidate and every guide hunk claiming that candidate also has only it and
     sits in the same section (the first shows it, the others were joined into it and count as
     neither shown nor missing). Several candidates (an edit split the hunk) or claimants from
     different sections (an edit joined them) match nothing. A match renders in the guide
     hunk's place with its note and `edited = true` ("✎ edited since guide" on the header,
     `edited` counts per section and in total); its unit key is the new hash, so its reviewed
     mark resets, and the section identity changes with it. Unchanged guides resolve exactly as
     before (every hash matches, nothing is re-anchored). Sections that lost hunks are
     `outdated`; hunks the guide doesn't know go to "Not in guide"; a banner (outdated sections,
     new and edited hunks) offers regeneration. Nothing re-runs automatically.
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
     dismissed|accepted for AI review findings, decision 15), in_review, thread [{id, author, body, created_at, updated_at}],
     created_at, updated_at (ms), file_level, outdated (derived), ai? (an AI finding: decision 15),
     agent? (an agent's comment the user triaged: `{author, accepted_at?, dismissed_at?}`)}`, plus `draft`/`reply_draft` for unsaved
     edits of a saved comment, and the delivery fields of a comment sent to an agent (decision 12):
     `sent_at`, `sent_reply` (the follow-up reply sent, else the body), `acked_at`, `answered_at`. Ids are 11 hex digits of milliseconds and 5 random ones: sortable and
     unique. The UI makes `user` comments; `bin/revuey comment` makes `agent` ones (saved, `in_review =
     false`: drafts for the user, triaged with `ca`/`cn` like AI findings, decision 15); agent replies are `agent` too; AI review findings (`ai`, `dismissed`/`accepted`) and the
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
     `$REVUEY_BIN`, which `bin/revuey` sets to its own absolute path. It also prints `switched`
     events (a layer checked out, see "Switching layers"), routed and deduplicated (by event id)
     like messages, live only.
   - **Agent commands.** `show` renders one message (`comments_export.message`); `reply` also
     sets `acked_at`/`answered_at` on a sent comment; `comment --path p (--line N [--end M]
     [--side new|old] | --file) <text|->` leaves a new agent comment, a draft for the user: never
     postable until they accept it (`ca`, decision 15), and never posted by the agent. It picks the review like
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
     not checked out. It tells the agent that its comments are drafts the user accepts, edits
     and posts, and that it never posts to GitHub itself. `bin/revuey install-skill` links it into `$HOME/.claude/skills/revuey`
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
      headRefOid, body (the description, decision 19), author, reviewDecision, latestReviews,
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
    - **Cache.** `forge.cache[host/owner/name] = {at, branches = {branch -> PRs}, failed =
      {branch -> reason}}` (a repo's entry also holds its parent's PRs). Failures are per
      branch: a fetch covers only the targets a review has not fetched, so a first lookup of
      one new target must neither mark nor clear the other layers' stale. Nothing in it expires: when it is filled is
      decision 20 (the first time a review needs a target, `R`, after a submit; never a redraw,
      refresh or timer). A failure keeps the last good `branches`, so what was shown stays,
      marked stale (`?`, `(stale)`). `forge_view.update` runs from view's `render` (open, scope
      switches, refreshes that re-render), resolves targets and fetches only the targets this
      review never fetched (all of them with `R`), then redraws the panel only if the PRs it
      shows changed
      (`forge_view.signature` against what `panel.render` last drew), with
      `panel.render(s, {keep_view = true})`: background redraws (this one and the stack stats)
      keep the panel cursor on the item it was on (file, layer, section, PR heading; the view
      scrolls by the rows added above) instead of jumping to the diff's current file. `R`
      (`refresh{forge = true}` -> `s.forge_force`) fetches whatever the cache holds. One lookup
      per review at a time: requests while one runs become one follow-up. Each lookup has a
      generation; `forge_view.detach` (review cleanup) bumps it and kills `gh`, and `fetch`
      writes nothing when `alive()` is false after the call, so a late result or failure never
      reaches the cache or a newer panel. A failed first fetch counts as fetched: a broken `gh`
      is tried again on `R`, never on a redraw.
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
    - Review threads (decision 17) and posting reviews (decision 18) reuse `targets` and
      `run_graphql`; the PR found here gives the number, the repo and the layer tip a post is
      checked against.
    - **Tests** use `tests/bin/gh` (fake, records argv, answers queries from canned PR nodes per
      `owner/name:branch`); `tests/helpers.lua` blocks the real `gh` on PATH for every spec.

14. **Edit from the review** (`edit.lua` pure decision and mapping; `edit_float.lua` the float;
    `view.edit` glue). `ge` on a hunk row opens the real working-tree file in a float.
    - **Who may edit** (`edit.decide(review, entry)`): rows first (add/ctx lines and hunk
      headers; a `del` row opens at its `anchor_lnum` with a note; prose, diagram, file
      header, note, blank and section rows refuse). Then the layer: a layer scope must be the
      `is_head` layer (`@`; a remote `ro` layer below HEAD never is), the full scope needs the
      top layer to be HEAD, else "<layer> isn't checked out; press gS to switch"; a remote
      layer with HEAD detached at its tip refuses too (no branch to commit to; gS makes one). Then
      working-tree mode, else "switch to working-tree mode (gu)". In the full scope the hunk's
      attribution labels (decision 9, already computed per refresh) must name only the top
      layer or `uncommitted`; a lower layer is named in the refusal, and missing labels refuse
      (never guessed). Deleted, binary and placeholder files refuse.
    - **Mapping.** On the `@` layer in working-tree mode the new side is the working tree, so a
      row's `new_lnum` is a line of the review's snapshot (`f.new_text`). `edit.map_line` maps
      it through `linemap` from the snapshot to the buffer's current text (edits saved since the
      last refresh, or unsaved ones): unchanged lines exactly by diff (duplicated text is never
      picked), a changed line to the nearest unchanged line above plus the distance, clamped.
      The hunk's new range (`edit.hunk_range`) is mapped the same way for the folds and title.
    - **Buffer.** `lsp.buffer_for(abs)` first: an exact name or resolved-path match over the
      buffer list (never `vim.fn.bufnr(path)`, which takes a pattern and partial matches, so
      `config.js` found `config.json`; the LSP proxy and the diff buffer's renaming use it too),
      else `bufadd` (revuey's hidden LSP buffer when loaded has that name), so there is never a
      second buffer for the file. Loading is a `pcall(bufload)`: another Neovim's swap file
      raises E325 without a UI, so the buffer is unloaded again (wiped when new) and the float
      says "another Neovim is editing <file>" instead of opening (`lsp.file_buffer` does the
      same for hidden buffers). `lsp.adopt` drops it from the
      hidden-buffer set (no silent reloads or wipes by `lsp.checktime`/`cleanup` any more) and
      lists it: from then on it is an ordinary `:edit` buffer, so undo, swap files, LSP clients
      already attached, completion, formatters, the user's autocmds and `:checktime`/W12 behave
      as anywhere. Saving is a plain `:w`; the session's `BufWritePost` refresh does the rest.
    - **Float.** `relative = 'win'` on the diff window, below the cursor line when it fits,
      else above, at most 60% of its height. Folds are `foldmethod=manual` in the float only
      (`zE`, then a fold above and below the hunk plus `edit.CONTEXT` lines). Neovim copies a
      closing window's local options and folds into the buffer's window info, which the next
      window showing the buffer inherits, so before any close (`q`, `:q` via `WinClosed`,
      review cleanup) the float's options are put back to what the window had when it opened
      (the buffer's own, from its last window) and its folds removed. A new window also copies
      the current window's options when the buffer brings none, so options equal to the diff
      window's (statuscolumn, winbar, foldexpr...) are first reset to their global values.
      `q` and normal-mode `<C-s>` are buffer-local expr mappings (there are no window-local
      ones) that act only when the float is the current window and otherwise return the key
      itself; `<Esc>` and insert-mode `<C-s>` (signature help) are left alone. On close only
      mappings the float made (by their description) are deleted, so one an `LspAttach` handler
      set meanwhile stays, and those they shadowed (saved with `maparg`) come back with
      `mapset`. Closing with changes asks (`edit_float.ask`, a hook for tests): save,
      discard (`:undo` back to the `changenr()` taken at open, so edits the buffer already had
      stay; `:edit!` only when it was unmodified then) or cancel.
    - **Cursor after a save.** The float's `BufWritePost` stores `s.edit_focus` (path and the
      float's cursor line); the refresh that re-renders puts the review cursor on the row
      showing that line (`layout.find_new_row`, both views), else the header of the file's
      nearest hunk. A refresh that finds no change drops it.
    - **Guides and comments** follow from the refresh: guide hunks re-anchor by overlap
      (decision 9, staleness) and comments by their placement rules (decision 11).
    - Not done: fixup commits for lower layers, typing into the composed buffer, restacking.

15. **AI reviews** (`ai_review.lua` pure model, import and triage; `ai_review_prompt.lua` prompt +
    schema; `ai_review_view.lua` job and panel glue; `comments_view.lua` triage keys; `cli.lua`
    `hunks`/`import-review`). Schema-driven like the guide and built on its machinery: findings
    are a sibling of agent comments (decision 11), not a parallel system.
    - **Hunk ids and offsets.** The ids are the guide's (`guide.hunks`, via `guide_view.prepare`,
      so a full-stack review gets the branch tags too). The prompt reuses
      `guide_prompt.user_message` (context, scope wording, file list, budget steps) with review
      texts and `numbered = true`: every hunk line is prefixed with its 1-based index in the
      hunk (`3|+text`, abridged previews too). A finding anchors to `{hunk, line?, end_line?}`;
      no line means the whole file. The model never sees or returns file line numbers.
    - **Schema** (`--json-schema`, `additionalProperties: false`): `{summary (md), verdict:
      approve|comment|request_changes, findings (max 30): [{hunk, line?, end_line?, severity:
      critical|major|minor|nit, title, body (md), suggestion?}]}`. `import-review` also accepts
      an optional top-level `diff` (the anchors hash `bin/revuey hunks` prints).
    - **Invocation**: `ai.run` exactly as for the guide (read-only, `--restricted --safe-mode`,
      same tools and allow/deny rules, process-group kill), `--name "revuey review: <branch>"`.
      One job per scope, keyed by the scope's comments file (`ai_review_view.jobs`), outliving
      scope switches and the review; a 100ms ticker draws the panel spinner via an extmark.
      A job cancelled while its prompt is still gathered calls its `on_change` (guide jobs too),
      so the spinner goes at once. The job and spinner code mirrors the guide's rather than
      sharing a helper.
    - **Skills.** `:RevueyAIReview <skill>`: `ai_review.find_skill` looks for
      `~/.claude/skills/<name>/SKILL.md`, then the repo's `.claude/skills/<name>/SKILL.md` (the
      user's own first), or takes a path to a skill directory or a Markdown file;
      `read_skill` drops YAML front matter and refuses empty files and files over 40,000
      characters. The text goes into the prompt after the methodology ("Review guidance from
      the skill `x`"), inside the prompt budget. revuey reads it because the restricted run
      loads no skills.
    - **Validation** (`ai_review.validate`, against the launch-time hunks): JSON repair as for
      the guide; the document must be an object with a string `summary` and `verdict` and a
      `findings` list, else it is an error (prose around some other JSON object, a guide, `{}`,
      a findings map), so invalid output never replaces the last review; ids normalised (`H7`,
      `7`); a finding is dropped and counted by reason when its hunk is unknown, its lines are
      not integers inside the hunk or past what the prompt showed (`guide.hunk_range`, shared
      with the guide's line notes; an abridged hunk numbers only
      its first 6 lines; `guide_prompt.user_message` reports `abridged_ids`, and at its `files`
      level every finding is whole-file), or end before they start, or an end comes without a
      start, it has neither title nor body, it duplicates an
      earlier one (hunk, lines, title), or it is past 50. A line on a file without a text diff
      becomes a whole-file finding. Severities and verdicts are normalised (aliases such as
      `high`, `changes_requested`; unknown: `minor`, `comment`), titles one line (else the
      body's first line), bodies and the summary cleaned like guide prose, suggestions keep
      indentation and newlines. Zero findings is a valid review.
    - **Import** (`ai_review.import`, the same code for the UI and the CLI). Each finding's
      rows (`line..end_line` of its hunk) go through `comments.anchor_from_rows`, so the anchor
      (side, unit and hunk keys and offsets, `context_hash`, `text_hash`, snippet, `sort_line`)
      is exactly what a selection of those rows stores, made from the launch-time review's side
      texts; placement then re-anchors it like any comment when the code changed meanwhile.
      The comment: author `{kind = 'ai', name}` (`claude` for revuey's own runs, `--name` or
      `$REVUEY_AGENT_NAME` for imports), status `saved`, body `**title**`, the explanation and
      a fenced "Suggested change", and `ai = {review, severity, title, suggestion, hunk, line,
      end_line}`. **Re-runs:** the store is reloaded first (another instance or the CLI may have
      triaged meanwhile); the author's untouched findings (untriaged, no live reply, never sent,
      no draft) are then deleted with tombstones whose `updated_at` is one past the version
      seen, so any concurrent change elsewhere (accept, dismiss, reply) is newer and wins the
      merge (`deleted` events). Every other finding still in the store, and every one the user
      deleted (`comments.delete` keeps an AI finding's title and lines in its tombstone), blocks
      a new one with the same path, side, lines and title (counted as skipped), so a dismissed
      or deleted finding does not come back. Then one save (merge, lock) and a
      `created` event per finding. A `diff` hash that differs from the hunks' is refused before
      anything is written. The UI imports into the open review's store when it shows that scope
      (then refreshes), else into the file, which a running review reloads.
    - **Triage.** `ca` (`ai_review.accept`): author becomes `{kind = 'user'}`, status
      `accepted`, the AI author kept in `ai.author`: the user's own comment from then on (open
      like `saved`; edit, resolve, later "add to review"). `cn` (`toggle_dismiss`): `dismissed`
      (hidden from lists and counts like resolved, drawn collapsed) or back to `saved`; refused
      for an accepted finding. **Agent comments** (`bin/revuey comment`, author `agent`) are
      triaged by the same code (`ai_review.origin`): the agent kept in `agent = {author,
      accepted_at, dismissed_at}`, chip "accepted from agent"; untriaged ones show the `ca`/`cn`
      hint (`agent_untriaged`) but are never counted, listed or replaced with AI findings
      (`untriaged`, `pending` and re-runs stay AI-only, so an AI review named like the agent
      cannot delete them). A dismissed one keeps its agent author, so `ci` still refuses it.
      Agent replies (`bin/revuey reply`) are thread entries answering the user, not comments:
      nothing to accept (and local replies in a comment's thread are never posted, decision 18).
      Exports note "a draft for the user, not accepted yet" / "accepted from a comment by X
      (agent)", and `show` says the user accepted it as their own. Both act only on AI findings
      and agent comments covering the cursor row (a user comment on the same line is skipped) and append `accepted`/`dismissed` events (a
      `dismissed` event with status `saved` reads "restore"). Follow-up is the agent link:
      `cs`/`cr` work unchanged, and `show` labels the comment as an AI review finding the user
      sent. `cx` works as on any comment; reopening an accepted finding makes it `accepted`
      again, and `cn` on a resolved one says to reopen it first. Delivery stays separate from status (decision 12).
    - **Record.** `<state file>.ai-review.json` next to the comments file (the scope's latest
      review): `{kind, version, id, author, summary, verdict, findings, imported, dropped,
      skipped, replaced, warnings, anchors, review, generator {provider, model, session_id,
      generated_at, head, merge_base, mode, duration_ms, cost_usd, skill, prompt_level}}`,
      written atomically (temp + rename; last writer wins, it is a summary). The panel reads it
      on render (cached by mtime and size) and draws an "AI review" block after the guide's:
      the verdict right-aligned, a status row while a job runs, the last error, "N to triage"
      (untriaged AI findings in the store) with dropped and skipped counts, and the summary
      wrapped. The comments list starts with the verdict and summary. Errors are kept per scope
      until the next run and never touch the record or the findings.
    - **From outside.** `bin/revuey hunks [--json|--prompt]` loads the review headlessly like
      `comment` and prints the user message (or the whole prompt, plus how to import), with the
      anchors hash; a review loaded from a live session's `load` record gets its stack detected
      again (the record has none), and the full scope gets the branch tags (`attribution.load`); `import-review [--name] [--session] <file|->` (`--schema` prints the schema)
      imports into the session's comments file, printing imported, dropped, skipped and
      replaced counts.
    - Posting: an accepted finding or agent comment is the user's comment and can be added to a
      review posted to GitHub (decision 18); an untriaged or dismissed one cannot (`ci` says to
      accept it with `ca` first).

16. **Remote PR review via worktrunk** (`pr.lua` argument, command line, result and error
    parsing plus the background run; `pr_view.lua` progress, cancel, approval terminal and
    opening; `cli.lua` `pr-target`/`pr-path` for `bin/revuey pr`). `:Revuey pr <N|url>` runs
    `wt switch pr:<N> --no-cd --format json` (worktrunk 0.81) in the clone's root, so the user's
    worktrunk config decides where the worktree goes and its hooks (pre-switch, then the
    blocking pre-start: install, build) set it up; there is no fresh-clone mode and no `wt`
    config of revuey's own.
    - **Argument.** `N`, `#N`, `pr:N` or a pull request URL. wt ignores a URL's host, owner and
      name (it asks the clone's own repo for that number), so a URL is turned into `pr:N` only
      when host and repo are those wt asks (`pr.wt_repo`, as wt 0.81 picks it: gh's default
      repo from `gh repo set-default --view`, offline since gh reads `remote.<name>.gh-resolved`
      (`base` or an `owner/name`), else the first remote with a GitHub URL in git config order
      (`git config --get-regexp '^remote\..*\.url$'`; other forges and paths skipped, no
      preference for `origin`). Not `forge.base_remote`, which prefers `upstream` and the
      trunk's remote: after `gh repo fork` in an existing clone (origin renamed to upstream,
      the fork added as origin) wt asks the parent. Another URL is refused before wt runs; a
      bare number is left to wt.
      `pr` is always the subcommand: a base branch named `pr` is `:Revuey refs/heads/pr`.
    - **Run.** `vim.system` with stdin closed (wt sees no terminal), detached (its own process
      group: `:Revuey pr cancel`, or a progress UI cancelling the message, sends SIGTERM then
      SIGKILL to the group via `ai.terminate`, so hook processes such as `npm install` stop
      too, and reports it once wt has exited and its stderr is read to the end, so a
      `Running pre-start` line still in the pipe names the half-made worktree; after 3s
      regardless; `ai.live` kills it on `VimLeavePre`). One setup at a time (`pr_view.current`,
      claimed before the first yield); a second request is refused with a message. stdout is
      one JSON line `{action: created|existing, branch, path}`; stderr carries progress and
      hook output (kept as chunks, the latest 256KB; split at `\n` and `\r`, so a progress
      bar's updates are lines, and an unfinished line keeps only its last 4KB; the created
      worktree's path is noted as its `Running pre-start ... @ <path>` line arrives), shown
      line by line as a Neovim 0.12 progress message (`nvim_echo`
      `kind = 'progress'`, id `revuey.pr`, with elapsed seconds from a 1s timer), ending
      `success` or `failed`.
    - **Where the review opens.** In a new tab (as every review) with `:tcd <worktree>`
      (`opts.tcd` in `view.show`): reviews already carry their root (`review.root`, every git
      call uses it), so only the user's own tools (pickers, `:edit`, terminals, completion of
      `:Revuey` branches) need the directory, and a tab-local one moves them without changing
      other tabs or the global cwd; closing the review closes its tab and the directory with
      it. `bin/revuey pr` `cd`s in the shell instead (Neovim is the review there).
    - **LSP waits for wt.** The review is opened only from wt's exit callback, so revuey's
      hidden LSP buffers (warm-up) load after pre-start finished: tsserver starts on a built
      tree. post-start/post-switch hooks run in the background after wt returns; the docs
      recommend pre-start for builds for that reason.
    - **The stack** is the usual detection (decision 7) from the worktree's HEAD, which is the
      PR's local branch (wt creates one tracking `origin/<head>`, or the fork's ref): local
      branches below are layers; remote-tracking ones are not (HEAD is not detached) unless a
      parent setting names them. The PR status section's base-mismatch warning flags a stacked
      PR whose GitHub base is not the detected parent. Layers from the GitHub base chain are
      the roadmap's next part.
    - **Errors.** No `wt` on PATH (or `worktrunk.cmd`): checked before anything runs. wt's own
      failures are shown in wt's words (the `✗` line and what follows, glyphs and ANSI codes
      stripped; the last `✗` line, since a hook may print its own), plus the last 5 lines the
      failing step printed (after its `◎ Running` line and wt's indented echo of the command;
      `\r` updates reduced to the last); the last 4KB of stderr go to `revuey.log` one entry per
      line (a single entry would fill the log and rotate earlier diagnostics away), and the
      message names the log file: no `gh`, no GitHub remote, unknown PR, a failed hook. A pre-start failure
      leaves the worktree (wt does not remove it): its path comes from the last `Running
      pre-start ... @ <path>` line, and the message says `:Revuey pr` opens it as is (pre-start
      only runs on creation), how to re-run the hooks (`wt -C <path> hook pre-start`) and
      `wt remove`.
    - **Approval.** wt asks before running a repo's project hooks (first time, and after a
      change), reading the project config of the worktree it runs in (the clone, not the PR's
      branch); without a terminal it prints the commands and `Cannot prompt for approval in
      non-interactive environment` and exits 1 before creating anything. revuey never passes
      `--yes`. It lists the commands and offers to run the same `wt switch` in a terminal split
      (`jobstart` with `term = true` running `sh -c 'exec "$@" > "$0"' <file> wt switch ...`:
      wt's prompt and the hooks' output go to the terminal, its JSON to the file), where the
      user answers wt's own prompt; on exit 0 the terminal closes and the review opens, on a
      failure the terminal stays with wt's output. Closing the terminal while wt runs (its
      last window, `WinClosed`; or unloading it, `:bd!`) stops wt, since nobody can answer its
      prompt any more, and says so. Switching buffers in its window (to read `.config/wt.toml`
      first) only hides it: wt keeps waiting and `:Revuey pr` shows the terminal again; cancel closes the terminal; the output file is deleted
      on every path. Declining in revuey says how to approve
      (`wt config approvals add`, or one `wt switch` in a shell). Declining in wt's prompt
      makes wt skip the project hooks and go on, which is the user's choice.
    - **bin/revuey pr** runs `wt switch` in the user's terminal itself (stdin, stderr and the
      approval prompt are the terminal's; stdout captured), so the terminal is the progress UI
      and `^C` cancels; `cli.lua pr-target` validates the argument and `pr-path` reads the JSON,
      then the script `cd`s to the worktree and starts the review UI with no arguments.
    - **Cleanup** is the user's (`wt remove`), never automated.
    - **Tests** use `tests/bin/wt` (fake, records argv, cwd and whether stdin is a terminal;
      scenarios: created/existing worktrees from local or `origin/` branches, a slow or hanging
      pre-start with a child process, a failing hook, approval asked on a terminal or refused
      without one, and wt's error texts); unit tests parse stderr captured from the real wt
      0.81. `tests/helpers.lua` blocks the real `wt` on PATH.

17. **Review threads from the forge** (`forge.lua` query, pagination, mapping and cache;
    `forge_threads.lua` pure placement and display items; `forge_view.lua` scope and fetch;
    `comments_view.lua` drawing, keys and the list). The review threads of open PRs are drawn
    inline next to local comments, read-only. No second GitHub client: the same `gh api graphql`
    through `forge.run_graphql`, the same failure handling, log and kill-on-close.
    - **Which PRs.** `forge_view.scope_prs`: the viewed layer's PR (a plain review's), or every
      layer's in full-stack scope, OPEN only (draft included; merged and closed PRs show none),
      from the PR lookup of decision 13, so a review without a PR makes no thread call.
    - **When.** In `forge_view.update`, after the PR lookup has drawn the panel, inside the same
      `git.async` run and generation (so `R`, close and `alive()` cover it): opening and
      re-rendering never wait for GitHub; threads appear when they arrive (comments re-render,
      panel redraw with `keep_view`), only when their signature changed. Cached per PR
      (`forge.threads_cache[host/owner/name#N] = {at, threads, sig, failed?, truncated?}`) for
      the review (decision 20): a PR's threads are fetched the first time a scope shows it, then
      only on `R` (and after a submit); scope switches and refreshes reuse them. A failed fetch
      keeps the last threads, marked `(stale)` on the panel's threads line.
    - **Query** (`build_threads_query`, aliased requests in one call per host): `tN:
      repository(owner, name) { pullRequest(number) { reviewThreads(first: 50, after?) {
      pageInfo nodes { ...thread } } } }` and, for a thread with more comments, `cN: node(id) {
      ... on PullRequestReviewThread { comments(first: 100, after) { pageInfo nodes { ...comment
      } } } }`. Thread fields: `id isResolved isOutdated path line startLine originalLine
      originalStartLine diffSide startDiffSide subjectType resolvedBy{login}` and `comments(first:
      20) { totalCount pageInfo nodes }`; comment fields: `id databaseId url body createdAt
      lastEditedAt state diffHunk author{login} replyTo{id}`. Fragments are only included when
      used (GraphQL rejects unused ones). Each round asks every PR's next thread page and every
      long thread's next comment page together; at most `THREAD_ROUNDS` (10) rounds, then what
      was read is kept (`… N more on GitHub` from `totalCount`, `more on GitHub` on the panel's
      threads line for a cut thread list) and the cut logged. `run_graphql` passes partial
      data on: any null threads or comments page marks that PR failed (a null first page too:
      `scope_prs` only holds PRs the lookup just found open, so it is almost always transient),
      and it keeps its last cached threads, marked stale (`(stale)` on the panel's threads
      line); on a first-ever fetch the pages read so far are kept, marked cut and stale. A
      transport error in a later round fails only the PRs not yet complete: PRs whose thread
      pages are all read with no comment pages pending are cached as usual. A page call
      asks for at most 1,050 nodes (50 threads with 20 comments each), about one GraphQL
      rate-limit point.
    - **Placement** (`forge_threads.place`, every render, against `comments.context`). Side from
      `diffSide` (LEFT = old), lines from `line`/`startLine` (outdated threads:
      `originalLine`/`originalStartLine`; `forge_threads.range`: a range across sides is
      anchored on its last line, and a `startLine` past `line`, which GitHub returns once a range
      moved (TypeScript#64818: 44 and 41), starts at `line` minus the original span; the
      display item uses the same range),
      the expected text from the first comment's `diffHunk` (its last lines on that side end at
      the thread's line) and up to 3 hunk lines on that side above them as context. Checked
      against the real API (about 50 threads on neovim/neovim and microsoft/TypeScript): the
      last line of `diffHunk` on the thread's side is always the `originalLine` text, LEFT and
      multi-line threads included; file threads have `line = 1` and an empty hunk (so
      `subjectType` is checked first); outdated RIGHT threads have `line = null` while outdated
      LEFT threads keep a `line`; bodies and hunks may contain `\r\n` (stripped). Context:
      a match needs at least one context line with text to match too, and all of them when
      the commented lines are weak (fewer than two distinctive words, `comments.distinctive_words`:
      `end`, `}`, `return err`), like local comments' `context_matches` guard. Tiers: `line`
      (GitHub's lines are shown rows, their text matches, and one of: the review's new side of
      the file is the PR's head blob, the context matches, or the text is strong and the only
      copy within 100 lines; or there is no hunk text),
      `moved` (the text and context found at exactly one place of the side's full text within
      100 lines, copies on lines the diff does not show counted, that place shown; at least
      three word characters, or hunk context with text; weak text such as `}` needs all of its
      context to match, and is never searched for when it is still at GitHub's line: only its
      context changed, and another copy of the old block nearby, the same `}` or `return err`
      in the next function, would be a wrong place), else `outside` (file in the review:
      a group "GitHub threads on lines not shown here" at the file's last row), `missing` (file
      not shown: the end of the review), `file` (`subjectType FILE`: under the file header);
      renamed files (`status = 'R'`) are followed by `old_path`. The context is from the push
      the comment was made on: a later push that edits the lines above keeps the thread on its
      line (not outdated), so the context check alone wrongly moved 4 of 37 real current threads
      (TypeScript, ruff, deno, vscode, neovim) out of place. Hence the two other ways to accept
      GitHub's line: a strong unique line, and the **PR head**. The head is the one GitHub
      numbered the threads against: the threads query asks `pullRequest { headRefOid }` with
      each page and the cache entry stores it (pages from different heads, a push mid-fetch,
      store none). Not the PR lookup's `headRefOid`: the two caches are fetched and expire
      separately, and a failed threads refetch keeps older threads (with their old head)
      while the lookup already reports the new one, so old line numbers would be trusted
      against new text. `forge_view.load_head_blobs` asks `git cat-file --batch-check` for
      `<threads head>:<path>` of each thread's file; found blobs are kept for the review, a
      missing commit or path is asked again on the next update (the user may fetch it), and
      `place` gets the blob (a missing head is one `cat-file` call per update until found).
      Limitation: if GitHub recalculates thread lines some time after updating `headRefOid`, a
      fetch right after a push could pair the new head with old line numbers; a text match at
      the line is still required, so only weak or repeated lines are at risk; when it equals the review file's `new_blob` (the hashed working-tree file or the
      committed blob, so uncommitted edits and other commits never qualify), GitHub numbers the
      thread against exactly this text and a plain text match is trusted, weak or repeated
      lines included. Per PR, so in full-stack scope a lower PR qualifies for files the layers
      above left alone. New side only. The text check is what makes GitHub's numbers
      safe on a review that is not the PR's diff (working tree, unpushed commits, a full-stack
      scope where lower PRs' lines moved, a PR updated since the fetch): a thread is never put
      on other code, at worst listed apart. Placement is never stored.
    - **Items** (`forge_threads.item`): comment-like records `{id = 'gh:<thread id>', forge =
      {thread_id, pr, pr_url, repo, url, resolved, resolved_by, outdated, pending, hidden,
      comment_id, database_id}, anchor, author = {kind = 'forge', name = login}, body, thread
      (replies), status, created_at, updated_at, file_level}`, so `thread_lines` draws them with
      the comment code. They live in `s.cm.forge_items` only: never in the comments store, the
      export, the event feed, agent messages or the panel's `✎` counts. Ids and GitHub ids are
      kept for replies posted with a review (decision 18).
    - **Drawing.** Same virtual lines and gutter bar as comments (`RevueyForgeSign`; a local
      comment's bar wins on a shared row), border `RevueyForgeBorder`, a `GitHub #N` chip, then
      `pending` (the viewer's own unsubmitted review), `resolved by x`, `outdated`, `GitHub line
      N` when moved. Resolved and outdated threads are collapsed to their first line like
      resolved comments (`cz` expands); at a shared row local comments come first, threads in
      creation order. `gH` (`keymaps.forge_threads`) cycles `all` / `open` / `none` per review,
      starting from `forge.threads.show`. `]m`/`[m` and `cl` (a "GitHub threads" part) include
      them; `keymaps.forge_open` (`gx`) in the diff on a thread opens its URL; elsewhere that key's
      global mapping runs (an expr mapping's returned keys are fed; else the built-in command). Grouped threads cover the file's last row
      (the only way to reach them with `cz`/`gx`), so actions that only work on local comments
      (`ce`, `cx`, `cd`, `cs`) leave threads out when a local comment covers the row too. The
      panel's PR section counts them (`threads: 2 open, 1 resolved, 1 outdated`).
    - **Read-only; local replies.** `ce`/`cx`/`cd`/`cs` on a thread refuse with a message. `cr`
      makes a new local comment anchored on the thread's rows (`anchor_from_rows`, so it
      re-anchors like any comment) with `forge_reply = {thread_id, pr, repo, url, comment_id,
      database_id}`, labelled in the thread box, the list and the Markdown export. A review
      submit (decision 18) posts it as a reply in its thread. A thread not on shown lines
      refuses (nowhere to anchor).
    - **Failures.** As decision 13: no `gh`, non-zero exit, GraphQL errors, a PR that does not
      resolve (partial data: no threads for it) are logged, never shown; the review and the PR
      section are unaffected.
    - **Tests** extend the fake `gh` (`REVUEY_FAKE_GH_THREADS`: thread nodes per `owner/name#N`,
      paged by the query's `first`/`after`; `REVUEY_FAKE_GH_THREADS_SCENARIO` fail/errors for
      thread queries only). `forge_spec.lua` turns threads off so its call counts stay PR
      lookups.

18. **Posting reviews to the forge** (`forge.lua` queries and mutations; `forge_post.lua` pure
    anchor mapping, routing, plan and confirmation text; `forge_post_view.lua` the steps;
    `comments_view.lua` the toggle, chips and de-duplication). Local comments go to GitHub as one
    review per PR with a verdict, through the same `gh` (`run_graphql`, plus `rest_get` for the
    one REST read). Opt-in per comment, local until submit.
    - **Add to review.** `ci` (`keymaps.comment_include`) toggles the comment model's
      `in_review` (merged like any change, no event). `forge_post.includable`: the user's own
      comments only (`author.kind = 'user'`, so an AI finding or agent comment after `ca`, and
      `cr` replies), not drafts, resolved or dismissed ones, GitHub threads or posted comments;
      an agent's comment is refused with "accept it first with ca". Chips `in review`,
      `in your pending review on GitHub #N`, `posted to GitHub #N` (thread header and list); the
      panel's key help shows `gP submit review` whenever the scope has an open PR
      (`scope_targets`; a verdict alone needs no comment), with `(N in review)` when N > 0. The submit takes the store of the
      scope shown (comments of other scopes stay where they are).
    - **Where a comment goes** (`forge_post.locate`, against the PR's files from REST `GET
      repos/o/n/pulls/N/files`, paged by 100 up to GitHub's 3,000: `filename`, `status`,
      `sha` = the blob at the PR head, checked against a real PR, and `patch` = GitHub's own
      hunks). GitHub numbers RIGHT lines in the head's file and LEFT lines in the base's, and
      takes only lines inside the patch's hunks. New side: the review's file must be the head's
      blob (`new_blob == sha`: the same bytes, so every number is the same line; any
      uncommitted or unpushed change to the file refuses all its comments, not only changed
      lines, because mapping through a diff can pair a `}` with another `}`), every line inside
      one hunk (a range across hunks is refused: GitHub wants one), and its text equal to the
      patch's. Old side: inside one hunk, and every old-side line of that hunk equal to the
      review's old text at the same number (the base blob is not in the REST answer). A line the
      review shows as added (deleted) must be `+` (`-`) in the patch, else it was changed by an
      earlier layer: refused with a hint to post from that layer's scope. File comments
      (`subjectType: FILE`): the file in the patch list with the head's blob (a deleted file:
      `removed`). Payload: `path`, `line` = last line, `side` RIGHT|LEFT, `startLine`/`startSide`
      for ranges. Outdated, empty, over-long (60,000 bytes) comments and those on files not in
      the review are refused with the reason.
    - **Routing.** Targets are the scope's open PRs (`forge_view.current_key`/the stack layers,
      like `scope_prs`), each with the commit the review shows for it (`ForgeTarget.tip`: the
      layer tip, HEAD for a plain review). Layer scope: the one PR. Full stack: every target is
      tried and exactly one must accept the comment (none: the best reason, else "no open PR has
      this version of the file"; several: refused as ambiguous). No attribution labels are
      needed: blob identity plus the `+`/`-` rule pick the layer that introduced the lines, and
      a later layer that changed the file makes the earlier one's blob differ. Replies go to
      their `forge_reply.pr` when it is an open PR of the scope.
    - **Whole-PR refusals** (`target_refusal`): the PR did not resolve, is not OPEN, its
      `headRefOid` is not the reviewed tip (moved on GitHub, or unpushed commits), or the
      verdict is approve/request changes on the viewer's own PR (GitHub refuses those), or the
      viewer somehow has several pending reviews there.
    - **Preview first, then send.** `gP` reads only; nothing is sent before the user confirms,
      and Cancel leaves GitHub untouched (the coordinator's decision, within the user's "local
      until submit"). `prepare` (async): files per PR (concurrent), then one preflight query per
      host: `viewer { login }`, per PR `pullRequest { id number url state isDraft headRefOid
      author { login } reviews(states: [PENDING], first: 5) { nodes { ...review } } recent:
      reviews(last: 30) { totalCount nodes { ...review } } }` with `fragment review on
      PullRequestReview { id state viewerDidAuthor createdAt body commit { oid } comments(first:
      100) { totalCount pageInfo nodes { id fullDatabaseId url path line startLine originalLine
      originalStartLine subjectType body replyTo { id } } } }`, and `node(id) { ... on
      PullRequestReview {
      ...review } }` for every review revuey sent comments to. Every review read is paged to
      the end (`node(id) { ... on PullRequestReview { comments(first, after) } }`); one that
      cannot be is incomplete. A review is gone only on a NOT_FOUND error at its alias (checked
      read-only against GitHub); any other null is unknown. Then `reconcile` (below), then
      `forge_post.plan`, then the confirmation (`forge_post.summary`).
    - **Two ways to send.** After Confirm, per PR (`execute`):
      - *Atomic* (no pending review of the viewer's on the PR, and only line comments:
        `DraftPullRequestReviewThread` has path, line, side, startLine, startSide and body, no
        subject type and no thread to reply in; checked by read-only introspection): one
        `addPullRequestReview(input: {pullRequestId, commitOID: <reviewed tip>, event, body?,
        threads: [...]})`, which creates and submits; the review exists with all its threads or
        not at all. Its answer carries the review's comments, matched to the threads sent. A
        verdict alone is the same mutation with no threads.
      - *Pending flow* (the user's pending review, from GitHub's UI or Graphite, reused and
        never replaced; or replies and file comments, which need one): `addPullRequestReview(
        input: {pullRequestId, commitOID})` only when there is none (GitHub allows one per user
        and PR, so a lost answer here is found by the next prepare, never made twice);
        `addPullRequestReviewThread(input: {pullRequestReviewId, path, body, line, side,
        startLine?, startSide?} | {..., subjectType: FILE})` and
        `addPullRequestReviewThreadReply(input: {pullRequestReviewId,
        pullRequestReviewThreadId, body})` aliased `m1..` in batches of 10 (sized by the
        JSON-encoded bodies, under 60KB: the query is one argument); a refused alias carries
        `path: [alias]` (`forge.alias_error`). Then `submitPullRequestReview(input:
        {pullRequestReviewId, event, body?})`, only when every add of that PR was answered and
        accepted, and only when a re-read of the pending review (whole) holds nothing the
      confirmation did not show (another tool may have added comments meanwhile): else that PR
      is not submitted and the reason is reported. Only GitHub errors of a refusal type
      (`forge.REFUSALS`: UNPROCESSABLE, FORBIDDEN, NOT_FOUND...) count as refused; any other
      error at an alias may hide a change and is treated as a lost answer.
      All documents were validated offline against GitHub's published schema; the preflight
      was run read-only against a public PR.
    - **Write-ahead.** Before each mutation its records are saved and must be on disk (a save
      the comments lock defers aborts the send): per comment `forge_post = {state = 'sending',
      pr, repo, review_id (pending flow) | ledger (atomic), payload = {kind, path, line,
      start_line, side, start_side, subject, thread_id, body}, before = ids of same-text
      comments already in the pending review, sent_at}`; per atomic review an entry in
      `<state>.forge.json` (`{id, kind = 'atomic', pr, repo, commit, event, body, threads (the
      payloads), started_at}`), since a verdict alone has no comment to hold a record; and
      before every `submitPullRequestReview` an entry `{kind = 'submit', review_id, event,
      body}`. A write-ahead that cannot be saved sends nothing and is undone. The ledger is
      written to a temp file (write and close checked) and renamed; one that cannot be parsed
      stops every submit (its entries would be lost). An answer turns the records into `pending` (with
      GitHub's ids) or `posted`; a refusal drops them; a lost answer or a crash leaves them
      `sending`.
    - **Reconcile** (`forge_post_view.reconcile`, pure core `forge_post.reconcile` and
      `find_atomic`), at the start of every prepare. Recorded ids are checked first and claim
      their comments; then each `sending`/`unknown` record's stored payload (never the comment
      as it is now) is matched against the complete comments of the review it went to
      (`payload_matches`: same body and path, and the lines it was made on, `originalLine` and
      `originalStartLine`, since `line` follows the PR head and is null once outdated; or FILE;
      a reply to the thread's first comment, recorded at `cr` as `root_id`, or to any comment of
      it that is cached). A miss is never proof of absence while that review has a comment with
      the same body on that file. Found exactly once, unclaimed, not in `before`, and no other record matching it:
      recorded (pending, or posted if that review was submitted). Definitely absent (a complete
      read without it, or NOT_FOUND): forgotten, and planned again only while `in_review`.
      Anything else (a partial or failed read, several candidates, a candidate claimed or there
      before, one another record matches too): `unknown`, and its PR is blocked (listed with
      `?`, no Submit for it). GitHub's review comments do not say their side, so a LEFT and a
      RIGHT payload with the same text on the same line number are both unknown. A pending
      record is never forgotten without NOT_FOUND or a complete read showing it gone; a
      pending review that cannot be read whole blocks its PR. An atomic ledger entry is found
      among the PR's latest reviews, read whole (the viewer's, same commit, state and body,
      created after `started_at` minus 10 minutes of clock skew, and holding every thread sent:
      an empty Approve made elsewhere is not it): exactly one: posted; none while the reviews
      read reach back past that time: absent; else unknown and blocked. A submit entry is found
      when its review is no longer PENDING. Whenever a review of revuey's turns out submitted
      (a ledger entry, or a review its pending records went to), the PR gets no second review
      with the same verdict (`found_review`). `:RevueySubmit forget` on a comment
      drops its record (any state) with a warning that it may exist on GitHub; the blocked
      confirmation offers `Forget unconfirmed`, which (after a second warning) drops the
      blocked PRs' unanswered and stuck records and ledger entries, the only way out of an
      entry with no comment (a verdict alone); `ci` off on an unknown one means it is dropped if the next reconcile finds it
      absent. A pending comment edited here since is shown with GitHub's text.
    - **The user's pending review.** Its comments that revuey did not add are listed in the
      confirmation by `path:line` ("submitted too"), with the count. When it is bound to another
      commit than the reviewed tip (`commit.oid`; or no commit at all: line comments refused),
      GitHub numbers its threads in that commit:
      the confirmation says so, replies still go in, new-side line and file comments only when
      `git cat-file --batch-check <commit>:<path>` is the review's blob (same file, same
      numbers), old-side ones never (the base may differ).
    - **Partial failure, cancel, failed submit.** Nothing is ever deleted or rolled back on
      GitHub: a reused pending review holds the user's own comments, and deleting would need
      more mutations that can fail too. In the pending flow a refused add is reported and its
      record dropped, what went in stays pending, and the PR is not submitted; the next `gP`
      shows the pending ones (`=`) and adds the rest. An atomic review GitHub refuses makes
      nothing. A failed submit leaves the review pending.
    - **Add to pending review** (`pending`: no verdict, never submitted), for drafts the user
      finishes on github.com or in Graphite. Entry points: the verdict prompt's last choice,
      `:RevueySubmit pending` (`forge_post.is_pending`), and a button in a verdict's
      confirmation. A verdict is not asked for because there is none to give: the review's
      verdict is chosen where it is submitted. The prompt choice and the command avoid a
      meaningless verdict; the button lets a user who picked one change their mind after
      seeing the plan. The button is offered only when the same plan adds something
      (`pending_offer`: the result recomputed with `r.pending`) and no PR is refused only for
      the verdict (`verdict_refused`: approving one's own PR refuses its comments in that plan;
      `:RevueySubmit pending` plans without the verdict); its text names how many `+` comments
      go to which PR, and says a written body is not sent. The plan is the same (`target_refusal`
      without a verdict), the confirmation the same (`= / + / ?`, others' pending comments
      "stay as they are", `add_existing`/`add_new` instead of the submit modes). Execution is
      always the pending flow (`run_pending(..., add_only)`), never the atomic mutation, which
      submits: `addPullRequestReview(input: {pullRequestId, commitOID})` only when the user has no
      pending review, then the batched adds, written ahead as always; it stops there (no
      re-read, no submit ledger entry), and records end `pending`. Only PRs with `+` comments go;
      blocked PRs are blocked as for a submit (`Forget unconfirmed`). Write-ahead, reconcile,
      dedupe (`before`) and blocking are unchanged, so a later `gP` Submit finds the records by
      id in the pending review (`=`) and only submits, and a submit on GitHub or in Graphite is
      found by the next prepare (the recorded review no longer PENDING: posted, and that PR
      gets no second review with the same verdict). A pending comment edited on GitHub keeps
      its id, so it is matched by id (never re-added, never unknown); the confirmation compares
      the local body, the sent payload and GitHub's body to say `edited here since`, `edited on
      GitHub since` or both, and shows GitHub's text; the local comment is never overwritten.
    - **Commit binding.** A new review (atomic or pending) gets `commitOID` = the reviewed tip,
      after the preflight showed `headRefOid` equal to it. A push between the preflight and the
      send binds the review to the older commit, whose lines are the ones checked.
    - **Full stack.** Only PRs with revuey's comments get the verdict; the confirmation names
      every PR of the stack (`PR #13: nothing to post, no review`), and a PR with only a pending
      review of the user's from elsewhere is mentioned, not submitted.
    - **Posted.** After a successful submit (or atomic review), the PR's comments become `posted`
      (`in_review = false`, ids kept, `posted_at`), and `forge_view.update(s, true)` refetches
      the threads. **Not drawn twice:** a local comment with `forge_post` whose GitHub comment
      (`comment_id`; pending and posted records only) is among the threads drawn in the scope
      (`gH` mode respected) is not drawn, counted or listed (`comments_view.superseded`): the
      GitHub thread is the live one (replies from others, resolution), and a pending one
      already shows `pending (your unsubmitted review)`. A posted comment with local replies
      (never posted) stays drawn, collapsed to its first line (`cz` expands). With threads hidden, not fetched or
      failed, the local comment shows with its `posted`/`pending` chip; an unanswered one
      (`sending`/`unknown`) with `maybe on GitHub #N (unconfirmed)`.
    - **Concurrency.** One submit at a time per Neovim (`forge_post_view.job`, across its
      reviews); an error in the confirmation or the body editor releases it, and the body editor
      returns to the confirmation however it is closed. Back at the confirmation, each planned
      comment is checked again: one deleted, taken out of the review or edited meanwhile is
      dropped from this submit and listed. Two Neovims on one review do not share
      the lock (a limitation, in the README). Closing the review before the confirmation sends
      nothing; once sending, a submit runs to the end and records what it learns in the
      comments file (the store outlives the UI).
    - **Not done:** GitHub's per-file "viewed" state (roadmap); editing a pending or posted
      comment does not update GitHub (nor an edit on GitHub the local copy); local replies in a
      comment's own thread are not posted (only its body); a body for "add to pending review".
    - **Tests**: the fake `gh` takes a post file (`REVUEY_FAKE_GH_POST`: viewer, PRs with node
      ids, heads and pending reviews, REST files, review states, failures) that it also keeps as
      its state, records every mutation alias as `{op, alias, input}` (the input object parsed)
      and adds created threads to the threads file (PENDING, then SUBMITTED), so a refetch
      shows them. It keeps submitted reviews (`history`) for the latest-reviews and `node`
      reads, answers the atomic `addPullRequestReview` with threads, and can apply a mutation
      and then not answer (`lost`), not apply it and not answer (`lost_unapplied`), go down
      after that, refuse a side, fail later comment pages or return a PR null that is not
      NOT_FOUND. It refuses REST writes. The reviewer's repros (R1-R8), a crash between the
      write-ahead and the answer, lost atomic reviews found and not found, and a Graphite
      comment with the same text as a lost add are specs. "Add to pending review": an accepted,
      edited agent comment added to a new pending review then submitted by a later `gP`; the
      button in a verdict's confirmation reusing a Graphite review, then a submit made "on
      GitHub" (the fake's pending review moved to `history`) found and marked posted; an edit
      made on GitHub to a pending comment (and here, and both); the full stack; the own-PR,
      verdict-alone, body and blocked cases.

19. **The PR description** (`forge.lua` the field; `forge_description.lua` pure cleaning, rows and
    fold; `forge_view.lua` which PRs, signature and the redraw; `layout.lua` head rows and their
    fold; `view.lua` folds, `<Tab>`, winbar). The open PR's description is shown above the first
    file of the diff view (never the guide view), read-only.
    - **Which PRs.** `forge_view.scope_prs`, as threads (decision 17): the viewed layer's (a plain
      review's), OPEN only (drafts too, marked `draft`). Full-stack scope: every layer's, bottom
      first, each collapsed on its own: the scope reviews all of them, and the top layer's alone
      would describe only its own part. A layer switch shows that layer's alone.
    - **Data.** `body` in the PR lookup's fragment (decision 13): no second call, the same cache,
      `R`, change check (decision 20), failure handling and kill-on-close. `body` (the Markdown as written) rather than
      `bodyText` (GitHub's plain text: code fences, lists and headings flattened) or `bodyHTML`
      (sanitised HTML with camo image URLs, which would need an HTML-to-text pass and is bigger).
      Cost: the lookup now returns the body of every PR it reads (up to 30 per head branch name,
      usually one); GitHub caps a body at 65,536 characters.
    - **Cleaning** (`forge_description.clean`, outside fenced code and inline code spans): HTML
      comments removed (PR templates; across lines; an unclosed one hides the rest, as on GitHub;
      a line that held only a comment leaves no blank), Markdown and `<img>` images as
      `(image: alt)`, GitHub's allowed HTML (`details`/`summary` as a `▸` line, `br`, `p`, `b`,
      `code`, `a`, headings, lists, ...) turned into Markdown or dropped keeping its text, other
      `<...>` left as typed (`Vec<String>`), entities decoded, task boxes `☑`/`☐`, setext headings,
      `~~~` fences at any indent, blank runs collapsed, C0 and C1 control characters (ESC, CSI) and
      surrogate or NUL character references dropped. Comments are not started inside inline code
      spans or a tag's quoted attribute values; `<!-->` and `<!--->` are whole (empty) comments. Empty once cleaned (no body, whitespace, a template's
      comments only): nothing is shown. Nothing is fetched: links keep their text (prose drops the
      URL, as in comments), images are text.
    - **Rows** (`forge_description.render`): `PR #N · title`, the body through `prose.render`
      (the comments' Markdown renderer, `RevueyGuide*` groups) indented two cells and wrapped to
      the guide's prose width, table rows (with or without a leading `|`) and rules on rows of
      their own (prose would run them into a paragraph), a blank row. Longer than `max_lines` + 1 body rows (6 by default), the
      rest is a fold.
    - **Real rows, not virtual lines.** The rows are buffer lines at the top of the layout
      (`layout.compose(files, head)`), prose rows with `role = 'description'` (`kind = 'prose'`,
      which every diff feature already skips for the guide: comments, marks, `ge`, LSP and its
      proxy, syntax, word diff, `]c`, `]f`). Virtual lines above row 1 were tried and rejected:
      Neovim shows them only through `topfill` (`<C-y>`), not with `gg`, and not at all while
      row 1 is in a closed fold, so a review whose first file is reviewed (folded) would never
      show the description. Real rows are reachable with `gg`/`k`, searchable and yankable, and
      fold with the normal fold commands.
    - **Arriving later: only the head rows change.** Opening never waits: the first render has
      no description unless the cache already holds it. After the lookup, `forge_view.update`
      schedules `sync_description` out of its `git.async` task (nothing there can yield or
      interleave with a close or another render), which compares the descriptions' signature
      and wrap width with what was last drawn (`f.desc_drawn`) and, when they differ (arrived,
      edited, emptied, a resize re-wraps them), calls `view.replace_description`. That replaces
      only rows `1..old_n` of the buffer (`nvim_buf_set_lines(buf, 0, old_n, ...)`), so Neovim
      itself moves every window's cursor, marks, the jumplist, extmarks (comment threads,
      header chips) and folds (open or closed, context folds too) below by the delta, and the
      row-keyed Lua state is shifted by the same delta: `layout.replace_head` (pure, equal to
      composing with the new head), the fold levels, the hunk header marks' keys; word diff
      pairs and comment rows are rebuilt from the new layout. Each window's view is saved and
      put back shifted (Neovim's own topline correction depends on folds), so the code under each
      window's cursor stays on its window line, in a `:split` too. (When the description itself
      is partly on screen, above the cursor, it growing or shrinking moves the code below it
      down or up: the rows are on screen.) `forge_description_spec.lua` checks that the splice
      leaves exactly what a full render would (buffer, layout, folds, every extmark, marks,
      comment rows, word diff, cursor) in a dozen scenarios. No git call, no capture/restore by file and line, no `zx`.
      Chosen over the full re-render of the first version, which reran git inside the task,
      restored only the diff window, closed opened context folds and let `zx`'s `zv` open a fold
      at the cursor's old row number. (A full render, `R` or a scope switch, still renders
      everything; it uses `zX` now, for the same reason, and `capture_view` records the
      unchanged-line folds the user opened, by file and line, which render opens again.) The
      fold state of a description is read from every window on the buffer (a `zo` in a split
      counts). Not in Visual, Insert or any other
      mode but Normal (it waits for `ModeChanged`, re-armed each time), nor with the comment
      editor open (a float at a buffer row; retried every 500ms), nor in the guide view
      (switching back renders it); a resize goes through the same gate. When the cursor is on
      the first file with the description just above, the winbar says `↑ PR description`; on
      its rows it names the PR. Revealing a late description on first open (an open question)
      would be one more step in `replace_description`: setting the topline to 1 when the view is
      still where `show` put it. A hover or other LSP request in flight while rows shift answers
      for the row it was asked on (it may highlight the row above or below); left as is.
    - **Cost.** Every scan in the cleaning and in `prose.inline` is linear: images and tags are
      scanned by hand, link text stops at the next bracket, a link URL ends at the first `)` or
      space after it, found once for a run of links (URLs may hold `[`), a `_` closer is found
      once for all openers, tags are looked at for at most 512 bytes; a
      hostile 65,536-character body (`![![![...`, `[[[...`, ` _a _a ...`) cleans and renders in
      milliseconds (it took 13-26s each before, `prose.render` included, which thread comments
      share). `clean` is memoised per body (64 entries), since every signature check cleans the
      scope's bodies. The panel's signature leaves the body out.
    - **Folds.** The hidden part is a level-1 fold of its own (`fold_levels`), so `zo`/`zc`/`za`
      work; `<Tab>` (toggle_fold) anywhere on the description toggles it
      (`view.toggle_description`), foldtext `… N more lines (<Tab> expands)`. The state is per
      PR URL (`s.desc_expanded`, read back from the folds in `capture_view` and before the head
      rows are replaced, so `zo` counts),
      kept across refreshes and scopes; `forge.description.expanded` starts them open.
    - **Failures** as decision 13: no PR, a failed lookup, `gh` missing: nothing shown, logged. A
      failed refetch keeps the PR (stale) and so the description shown, its title row ending
      `· stale`; news found by the change check end it `· new on GitHub · R to refresh`
      (decision 20).
    - **Config** `forge.description = { enabled, expanded, max_lines }` (or `false`). Highlights
      `RevueyForgeDescriptionTitle`, `RevueyForgeDescriptionMore`, `RevueyForgeDescriptionRule`.
    - **Tests**: the fake `gh` answers a PR node's `body` only when the query's fragment asks for
      it. `forge_description_spec.lua` covers cleaning and rows, and through the fake `gh`: shown,
      absent (no PR, empty, template-only, merged, turned off), arriving late (`slow`) under a
      cursor, a comment and an opened context fold, a closed fold above the cursor, a `:split`,
      outside the lookup's task with no git call, Visual mode, a pending key and the editor (for
      lookups and resizes), `<Tab>`/`zo`/`zc`/`R`, edits, an unchanged lookup touching nothing,
      failures, scopes and the guide view, plus hostile bodies under a time bound;
      `layout_spec.lua` checks `replace_head` against `compose`; `screen_spec.lua` has it late
      (winbar hint), collapsed and expanded.

20. **When GitHub is read: first fetch, `R`, and the change check** (`forge.lua` the check query,
    signals, comparison and marks; `forge_view.lua` what is fetched when, the timer, focus and
    redraws). What revuey shows from GitHub (PR status, review threads, the description, and so
    the head blobs placement trusts) changes only when the user can expect it to.
    - **Fetches.** `forge_view.update` (from every render) fetches only what this review has never
      fetched: the PR lookup for targets not yet looked up (keyed by name and candidates, not the
      tip, so a commit does not refetch; on open that is every layer, so `]s`/`[s`, `gs` and `gS`
      fetch no PR), and the threads of the scope's open PRs never fetched here (a layer or the
      full stack shown for the first time). With `force` (`R`, `refresh{forge = true}`; and after
      a submit, `forge_post_view`) everything for the scope. Local refreshes (a file save, git
      changes, focus, a resize) re-render and so call `update`, which then fetches nothing,
      except a target that did not exist before (a new stack layer: a PR never looked up). Posting
      (`gP`) reads GitHub in its own preflight, untouched. `load_head_blobs` is local (`git
      cat-file`) and still runs on every update. The time-based expiry (`forge.ttl` as a TTL,
      `forge_view.lazy` from `panel.render`, `is_fresh`, `threads_fresh`) is gone: a redraw
      after the TTL used to replace what was shown without the user asking.
    - **The change check.** Every `forge.ttl` seconds (180 by default; the name is kept for old
      configs) while the review is shown, one `gh api graphql` call per host (in practice one)
      asks for the scope's PRs (every layer's in full-stack scope; any state) only change
      signals: `kN: repository(owner, name) { pM: pullRequest(number) { ...check } }` with
      `headRefOid state isDraft title lastEditedAt reviewDecision reviews { totalCount }
      reviewRequests { totalCount } commits(last: 1) { statusCheckRollup { state } }
      reviewThreads(first: 100) { totalCount nodes { isResolved comments { totalCount } } }`
      (threads only when shown). The baseline is what is shown: `forge.signals` of the PR node
      the lookup returned (the lookup's fragment asks the same fields: `lastEditedAt`, `reviews {
      totalCount }`, `reviewRequests { totalCount }`, the rollup's `state`) and the cached threads
      (count, resolved and comment counts of the first 100; none when the last threads fetch
      failed, a cut list has no count). A difference marks the PR in `forge.changed[repo#N] =
      {signal = true}`; nothing in the caches is touched, so nothing shown changes. A PR lookup
      that works clears the PR signals of the PRs it read (and the thread signals of a PR it
      reads merged or closed: its threads are neither shown nor fetched again, so nothing else
      would clear them), a complete threads fetch the thread signals. Threads are compared only
      for a PR shown open. `R` in a layer also refetches the threads of other layers' open PRs
      that have thread marks (left by a full-stack check), so `R` clears every mark.
    - **Why these signals, not `updatedAt`.** Measured read-only on 125 recently updated PRs of
      neovim, vscode, TypeScript, ruff and deno (October 2026): `updatedAt` equals the time of an
      issue comment, a comment or description edit, a review, a label, a milestone, an assignee,
      a review request or its removal, a title rename, ready-for-review, a close or merge, and
      follows each push within seconds; it does not move for cross-references, mentions or
      subscriptions. Many of those (labels, milestones, assignees, issue comments) are not
      shown by revuey and would nag; and no timeline event or timestamp exists for resolving a
      thread, so whether it bumps `updatedAt` could not be verified without a write. The
      signals cover what revuey shows: a push (`headRefOid`), merge/close/reopen (`state`),
      draft, a title or description edit (`title`, `lastEditedAt`), a review or a reply in a
      thread (`reviews.totalCount`: on GitHub every review comment belongs to a review),
      requested reviewers, the review decision, CI (`statusCheckRollup.state`: checks finishing
      do not bump `updatedAt`; on five deno PRs the last check run completed 40 minutes to 3
      hours after their `updatedAt`), and threads: a new thread (count), a reply (comment counts), resolving
      or unresolving (`isResolved`). **Not detected:** an edited review comment (no cheap
      signal; `lastEditedAt` per comment would mean reading comments), threads beyond the first
      100 being resolved, mergeability (left out on purpose: GitHub computes it lazily, so it
      flips from UNKNOWN on its own right after a fetch), a PR opened for a branch that had none
      (the check covers PRs shown; `R` looks), and changes to other layers' PRs while one layer
      is viewed (their chips are not checked).
    - **Uncertain, not verifiable read-only:** whether `lastEditedAt` moves on a title edit
      (`title` is its own signal, so either way a title edit is seen) and whether the viewer's
      own pending review counts in `reviews.totalCount` (checks are suppressed while a submit
      runs, and the refetch after it clears marks; a pending review started on github.com may
      show as news). The PR baselines come from the lookup and the thread baselines from the
      threads fetch that follows it: a reply posted between the two calls (a second or so)
      reads as a `reviews` change at the next check, a false mark that `R` clears.
    - **Cost.** Measured with `rateLimit { cost }`: the check costs 1 point for 1 to 20 PRs with
      their threads' flags and counts (a 20-PR answer is about 10KB; about 2s including `gh`
      start-up), so 20 points an hour at most of the 5,000. REST conditional requests (`gh api -i
      -H 'If-None-Match: <etag>' repos/o/r/pulls/N`) were measured too: ETags come back, a 304
      costs nothing (`X-Ratelimit-Used` unchanged) and a 200 one point, and the PR's
      `Last-Modified` is its `updatedAt`. Rejected: one `gh` process per PR per endpoint (plus
      `/reviews`, `/comments` and check runs for what the PR object lacks), the PR object has
      no review decision, thread resolution or check state, and its ETag moves with every field
      revuey does not show (labels, assignees, `mergeable_state`). Adding `lastEditedAt`,
      `reviews { totalCount }`, `reviewRequests { totalCount }` and the rollup's `state` to the
      PR lookup left its cost unchanged (6 points for 5 neovim branches, before and after).
    - **When it runs.** `forge_view.attach` (from `view.show`, once the session's augroup exists)
      starts a `vim.uv` timer ticking every quarter of the interval; a tick only compares
      clocks (`forge.now`, which tests replace). `maybe_check` runs the check when it is due (the
      interval since the last fetch or check), Neovim is focused (`FocusLost`/`FocusGained`),
      the diff buffer is in a window of the current tab page, and no lookup or check is in
      flight; `FocusGained`, `TabEnter` and `BufWinEnter` call it too, so a check that came due
      while away runs at once on coming back. One check at a time, its own generation,
      `forge.timeout`, its `gh` killed and the timer stopped and closed by `detach` (review
      cleanup). The interval is at least `forge.MIN_INTERVAL` (60s; tests lower it): `ttl`
      used to be a cache TTL, and an old `ttl = 0` would otherwise check back to back. No check
      runs while a submit (`gP`) is in progress (`forge_post_view.job`). A fetch that starts (`R`, a first fetch) drops a check in flight: compared
      against data the fetch replaces, its marks would announce news already shown. A failed check is logged and marks nothing (stale keeps its meaning: a failed
      fetch); the next one waits for the interval. `forge.check = false` starts no timer. When
      a check marks something new, the panel is redrawn (`keep_view`, only when its signature,
      which includes the marks, changed), the description rows go through `sync_description`
      (its signature includes the mark) and the winbar is redrawn; a check that finds nothing
      redraws nothing.
    - **Marks.** News (`RevueyForgeChanged`, linked to `DiagnosticInfo`: something to act on, not
      an error, and apart from the dim failure mark): the row chip `#12 ✓↻`, the detail heading
      `(new on GitHub · R)`, the threads line `(new)` when thread signals moved (short: the
      heading says the rest and the panel is 40 cells), the description's title row `· new on
      GitHub · R to refresh` when the title or description moved, and the winbar on the
      description `new on GitHub · R`. A failed fetch keeps the existing dim marks: `?` on the
      chip, `(stale)` on the heading and the threads line, and now `· stale` on the description
      title and `stale` in its winbar. Both can show at once (`#12 ✓↻?`, a failed `R` after
      news); `R` that works clears both. The detail heading's marks are right-aligned beside `PR
      #N` and must never cover it or the state: the longest form that fits the panel is used,
      `(new on GitHub · R) (stale)`, then `↻ R (stale)`, then `↻?`, then none. The threads
      line keeps its marks' colours when it wraps.
    - **Tests** (`forge_check_spec.lua`, fake `gh` answering the check from the same PRs and
      threads files, so a test changes a signal by rewriting them; `REVUEY_FAKE_GH_CHECK_SCENARIO
      = fail`): no fetch on redraws, refreshes, resizes, focus, fetched scopes or hours later;
      first fetches of a never-shown layer's threads; the quiet check (no redraw, no body);
      each signal marking only its PR in one full-stack query; the marks everywhere, the data
      unchanged until `R`, which clears them; a failed `R`; a failed check; focus and
      visibility; the real timer and its handle stopped and closed on close; `forge.check =
      false`; the interval's floor; a merged PR's thread marks cleared by `R`; `R` in a layer
      clearing other layers' thread marks; a slow check (`REVUEY_FAKE_GH_CHECK_DELAY`) dropped
      when `R` starts; the heading in 40-, 34- and 26-cell panels; stale per branch after a
      `git push -u`-like config change.
      `forge_post_spec.lua` checks the refetch after a submit clears the marks.

## Code layout conventions
- `lua/revuey/` modules; `plugin/revuey.lua` defines user commands only (lazy-require modules).
- Keep git/data logic (`git.lua`, `diff.lua`, `state.lua`, `units.lua`, `stack.lua`, `stack_notes.lua`, `stack_ignore.lua`, `switch.lua`, `edit.lua`, `forge.lua`, `forge_threads.lua`, `forge_post.lua`, `forge_description.lua`, `pr.lua`, `log.lua`, `guide.lua`, `guide_prompt.lua`, `ai_review.lua`, `ai_review_prompt.lua`,
  `prose.lua`, `diagram.lua`, `attribution.lua`, `comments.lua`, `comments_export.lua`, `sessions.lua`, `cli.lua`) free of window/buffer UI so it is testable with
  `nvim --headless -l`.
- Tests in `tests/`, run with `make test`. Testing strategy and rules are in `docs/TESTING.md`.
- Shell out to `git`/`gh`/`wt` with `vim.system`; never block the UI for long-running work.
