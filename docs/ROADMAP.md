# Roadmap

Work lands chunk by chunk as pull requests gated on CI (see [TESTING.md](TESTING.md)). Order below is the planned
sequence; later items build on earlier ones.

## Done
- Local branch review: composed diff buffer, file panel, projected syntax and word diff, `gd`/`K`, reviewed marks.
- Working-tree mode with auto-refresh.
- Local PR stacks: layer and full-stack scopes, restack/override/squash-merge notes.
- Stacks without local branches (git half): remote-tracking branches as layers below HEAD, detached HEAD at a
  branch tip, remote-stripped state keys, read-only remote layers in the panel.
- AI guided review: hunk-level sections, staleness, section reviewed marks, read-only restricted `claude -p`.
- CI on GitHub Actions.
- Local comments and export: comments on lines, ranges (either side) and files in the diff and guide views,
  inline threads, drafts, re-anchoring and outdated comments, per-review storage with merge-on-save, Markdown/JSON
  export, `bin/revuey comments|watch|reply` and the comment event feed for agents.
- Ask AI, part 1: send to an agent session. `<C-a>` in the comment editor, `cs` on a comment and `ga` on a
  line or selection send it to a coding-agent session (Claude Code via the `revuey` skill, launched by the agent
  in a tmux or herdr pane, or connected to a review the user started); a per-worktree session registry,
  `bin/revuey sessions|watch --messages|show|reply|ack|inbox|install-skill`, catch-up of unacknowledged
  messages, presence in the panel header, sent/queued/seen/answered markers on threads.
- Pull request status: one batched `gh api graphql` lookup per refresh (cached per repo, TTL) finds each
  layer's PR by head branch (remote layers without the remote, fork PRs by head owner); `#N` with
  review state on stack rows (or a plain review's title), a foldable detail section for the viewed
  layer (reviewers, checks, mergeable, base, a warning when GitHub's base differs from the stack
  parent), `gx` opens it in the browser. Failures are silent and logged to `revuey.log`.
- Edit from the review, part 1: `gS` (and `:RevueySwitch`) checks a stack layer out in the current worktree
  with plain `git switch` (`--track` for a remote-only layer), refusing on a dirty worktree or a branch checked
  out elsewhere, files it would write over (untracked or ignored) or unsaved buffers, asking before touching
  an unrelated local branch of the same name or switching under a connected agent; `@` moves, the layer gets
  the working tree, hidden LSP buffers reload. Opt-in `stack.switch_on_navigate` for `]s`/`[s`. A branch
  created for a remote layer keeps the remote layer below it through `branch.<b>.revueyParent`.
- Edit from the review, part 2: `ge` on a hunk line (diff or guide) opens the real working-tree file in
  a float near the cursor, folded (window-local, manual) to the hunk plus context, titled with the path
  and line range. It is the file's one buffer (an open one, else revuey's hidden LSP buffer handed over
  as a normal listed buffer), so undo, LSP, completion, formatters, autocmds and `:checktime`/W12 work
  as usual; `:w`/`<C-s>` save and the auto-refresh keeps the review cursor on the edited hunk; `q`
  asks save/discard/cancel with unsaved changes. Only the checked-out layer (`@`) in working-tree mode
  edits (full stack: hunks attributed to the checked-out top layer only); other layers, remote `ro`
  layers and committed mode refuse with "press gS to switch" / "switch to working-tree mode (gu)".
  Deleted lines open at the nearest new-side line. Guide hunks re-anchor by overlap (old or new range,
  same file, same function context, conservative), so an edited hunk stays in its section marked
  "✎ edited since guide" with its reviewed mark reset; comments re-anchor by their usual rules.
  Fixup commits for lower layers are left (see Next).
- `<Tab>` to collapse files, hunks and guide sections; fix for `mr` on the last file.
- Proxy LSP client (`revuey`) so the user's own LSP mappings and pickers work in revuey buffers; clearer guide scope wording.
- Guide overview diagram (structured graph rendered as box-drawing text, Mermaid export) and branch labels on hunks
  in full-stack guides.
- Nested reviewed marks: review units (one per hunk for now), `mr` on hunks, files, sections and selections in both
  views, shared state and partial progress (`◐ 2/5`).
- Agents can create new comments: `bin/revuey comment --path --line [--end] [--side] | --file`, validated against
  the review's diff, shown live and labelled as agent comments.
- Calmer stack notes: summary lines, a details float with actions, a per-repo ignore list; squash-merged bottom
  commits skipped (also for single-branch reviews).


## Next
1. **AI reviews (local-first).** Schema-driven, like the guide: `:RevueyAIReview [skill]` runs the user's
   `claude` CLI in the background (read-only, restricted, `--json-schema`) and returns one JSON document: a short
   summary, a suggested verdict (approve / comment / request changes) and findings (severity, title, body, optional
   suggested change). Findings anchor to engine-assigned hunk IDs plus an offset within the hunk, not raw line
   numbers. revuey validates, drops bad anchors and imports each finding as an AI-authored local comment to triage:
   accept (becomes the user's own comment), dismiss, or follow up via the agent link. Nothing is posted anywhere.
   The same schema is accepted from outside via `bin/revuey import-review <file|->`, so an external agent or tool can
   produce a review in the same format. An optional skill's `SKILL.md` is read by revuey and passed as guidance.
   Single conversational comments from a connected agent use `bin/revuey comment --path --line` instead.
2. **Remote PR review via worktrunk.** `:Revuey pr <N|url>` from inside an existing clone runs
   `wt switch pr:<N> --no-cd` so the user's worktrunk hooks bootstrap the worktree, walks the PR stack via `gh`
   (base branch chain), and opens the review there with LSP working. No fresh-clone mode. Cleanup via `wt remove`.
   **Stacks without local branches.** Reviewing someone else's stack from a worktree at its top shouldn't need
   local branches for the intermediate PRs. **Git half: done** (see Done): with HEAD detached, remote-tracking branches on HEAD's
   own line between trunk and HEAD are layers below HEAD (remote branches above HEAD are not used), a local
   branch wins over its remote copy, a detached HEAD at a branch tip uses that branch, state keys strip the
   remote prefix, and remote-only layers are dimmer and read-only. **Left: the GitHub half.** When the stack
   has PRs, layers come from the GitHub base chain, with tips at `origin/<head>` (or `refs/pull/<N>/head` for
   forks), fetched as needed (revuey itself doesn't fetch today). Editing a remote-only layer needs `gS`, which
   creates a local tracking branch with `git switch --track`. Also read GitHub's native stacks (public preview):
   the PR `stack`/`stackEntry` GraphQL fields (joined to the existing PR-status query) and the `gh stack`
   extension's local `.git/gh-stack` file, as explicit stack sources like Graphite metadata; confirm both formats
   against a real stacked repo first.
   **Up-to-date builds for the LSP.** In TypeScript monorepos, workspace packages often point `types`/`exports` at
   `dist/`, so tsserver is wrong or empty until the tree is built. New PR worktrees: document a worktrunk
   `pre-start` pipeline (install, then build; `pre-start` because it blocks, so `wt switch` returns with the tree
   built, which a background `post-start` would not), and have revuey wait for `wt switch` before starting LSP.
   `gS` uses plain `git switch`, so no `wt` hook fires: add an opt-in `stack.after_switch` command (e.g.
   `{ "wt", "hook", "post-switch", "build", "--foreground" }`, keeping the build in the user's worktrunk config),
   run in the background after a successful switch with "building…" in the panel header and failures in
   `revuey.log`, then restart the worktree's LSP clients so tsserver picks up the new `.d.ts` files. Incremental
   builds (`tsc -b`, turbo) keep this cheap. Document the build-free alternative for repos that can change:
   a `source` export condition plus `customConditions`, or project references with `declarationMap`.
3. **Show existing forge comments.** For a review backed by an open PR, fetch its review threads (`gh api graphql`)
   and render them inline alongside local comments, including resolved and outdated state.
4. **Post reviews to the forge.** Each local comment has an "add to review" toggle (Graphite style). Submitting
   posts all included comments together as one GitHub review with a verdict: approve, comment or request changes.
   Uses GitHub's pending-review flow so nothing is visible until submit. In full-stack scope each comment is routed
   to the PR of the layer that introduced the line. Optional sync of GitHub's per-file "viewed" state.
5. **Finer-grained guide sections.** Guides already reference individual hunks, so one file can be split across
   sections. Go further by splitting large hunks before the model sees them, at tree-sitter top-level boundaries
   (functions, classes, exports) or blank-line gaps, each piece getting its own ID (`h7a`, `h7b`). The model still
   only picks IDs, so validation stays simple; adjacent pieces in the same section render as one block.
   Reviewed marks already go through review units with parent hunk keys (`units.lua`), so this only changes how
   units are cut.
6. **Edit from the review: what is left.** (The `gS` layer switch and the edit float are done; see Done.)
   Fixup commits for lower layers (an edit made while viewing a lower layer becoming a `fixup!` commit
   on it) are not done. After committing on a lower layer the existing "not restacked" warning flags
   the layers above; revuey never restacks and never asks for a restack automatically: a later "send
   restack request" action in the warning's details float, triggered by the user, would message the
   launching agent session (mentioning Graphite when the repo uses it, so the agent can pick the right
   tool). revuey itself uses plain git throughout (e.g. `git switch`, also fine for Graphite
   branches). Direct typing into the composed review buffer is not planned (no per-line read-only).
   Alternative considered: one worktree per layer via worktrunk.

## Later / ideas
- Built-in chat panel (descoped: the external agent session covers it). A lighter option: when no agent is
  connected, `<C-a>` offers a one-shot answer from revuey's own read-only `claude -p` (resuming the guide's session),
  landing as a reply in the comment's thread, with no panel.
- Optional image rendering of the guide diagram via snacks.nvim when available.
- Codex as a second AI provider.
- Side-by-side diff mode.
- Standalone non-Neovim frontend reusing the JSON state, if there is demand.
