# Roadmap

Work lands chunk by chunk as pull requests gated on CI (see [TESTING.md](TESTING.md)). Order below is the planned
sequence; later items build on earlier ones.

## Done
- Local branch review: composed diff buffer, file panel, projected syntax and word diff, `gd`/`K`, reviewed marks.
- Working-tree mode with auto-refresh.
- Local PR stacks: layer and full-stack scopes, restack/override/squash-merge notes.
- AI guided review: hunk-level sections, staleness, section reviewed marks, read-only restricted `claude -p`.
- CI on GitHub Actions.
- Local comments and export: comments on lines, ranges (either side) and files in the diff and guide views,
  inline threads, drafts, re-anchoring and outdated comments, per-review storage with merge-on-save, Markdown/JSON
  export, `bin/revuey comments|watch|reply` and the comment event feed for agents.

## In flight
- `<Tab>` to collapse files, hunks and guide sections; fix for `mr` on the last file.
- Proxy LSP client so the user's own LSP mappings and pickers work in revuey buffers; clearer guide scope wording.
- Guide overview diagram (structured graph rendered as box-drawing text, Mermaid export) and branch labels on hunks
  in full-stack guides.
- Nested reviewed marks: review units (one per hunk for now), `mr` on hunks, files, sections and selections in both
  views, shared state and partial progress (`◐ 2/5`).

## Next
1. **Local comments and export.** Comments on a line or range in the diff or guide view, on either side,
   rendered inline as threads. Anchored by path, side, line range and content hash so they re-anchor or show as
   outdated when code moves. Stored locally per review. Export to a paste-friendly text format (file, line range,
   the commented code, the comment body) via a command, the clipboard and `bin/revuey comments`, for handing to an
   AI session. This is the foundation for the forge items below.
2. **AI reviews (local-first).** Schema-driven, like the guide: `:RevueyAIReview [skill]` runs the user's
   `claude` CLI in the background (read-only, restricted, `--json-schema`) and returns one JSON document: a short
   summary, a suggested verdict (approve / comment / request changes) and findings (severity, title, body, optional
   suggested change). Findings anchor to engine-assigned hunk IDs plus an offset within the hunk, not raw line
   numbers. revuey validates, drops bad anchors and imports each finding as an AI-authored local comment to triage:
   accept (becomes the user's own comment), dismiss, or follow up via the agent link. Nothing is posted anywhere.
   The same schema is accepted from outside via `bin/revuey import-review <file|->`, so an external agent or tool can
   produce a review in the same format. An optional skill's `SKILL.md` is read by revuey and passed as guidance.
   Single conversational comments from a connected agent use `bin/revuey comment --path --line` instead.
3. **Ask AI via the agent session.** From the comment editor or a selection, a key sends the comment (with file,
   lines, code and guide section) to a connected coding-agent session, and replies land in the comment's thread.
   This is the primary Ask AI path; a built-in chat panel is descoped (see Later).
   **Send to the launching agent session.** When a coding agent launched revuey (via a small revuey skill, in a
   tmux or herdr pane), comments and questions can be sent straight back to that session without closing revuey.
   revuey appends events (file, lines, code, text) to a feed that `revuey watch` streams; the agent watches it with
   Claude Code's Monitor tool (re-armed every 30 minutes) and can answer with `revuey reply <id> "…"`, shown in the
   comment's thread. Fallback for other agent CLIs: type the message into the launching pane. The local comments
   chunk should write this event feed from the start.
4. **Remote PR review via worktrunk.** `:Revuey pr <N|url>` from inside an existing clone runs
   `wt switch pr:<N> --no-cd` so the user's worktrunk hooks bootstrap the worktree, walks the PR stack via `gh`
   (base branch chain), and opens the review there with LSP working. No fresh-clone mode. Cleanup via `wt remove`.
   **Stacks without local branches.** Reviewing someone else's stack from a worktree at its top shouldn't need
   local branches for the intermediate PRs. When the stack has PRs, layers come from the GitHub base chain, with
   tips at `origin/<head>` (or `refs/pull/<N>/head` for forks), fetched as needed. Without a forge, remote-tracking
   branches are a fallback for layers *below* HEAD only: an `origin/*` branch counts when its tip is on HEAD's own
   line between trunk and HEAD (cheap and bounded even with thousands of remote branches); remote branches above
   HEAD are not used. A local branch wins over its remote copy. State keys strip the remote prefix, so marks and
   comments carry over if a local branch is created later. Remote-only layers are shown dimmer and are read-only;
   editing one needs `gS`, which creates a local tracking branch with `git switch --track`.
5. **Show existing forge comments.** For a review backed by an open PR, fetch its review threads (`gh api graphql`)
   and render them inline alongside local comments, including resolved and outdated state.
6. **Post reviews to the forge.** Each local comment has an "add to review" toggle (Graphite style). Submitting
   posts all included comments together as one GitHub review with a verdict: approve, comment or request changes.
   Uses GitHub's pending-review flow so nothing is visible until submit. In full-stack scope each comment is routed
   to the PR of the layer that introduced the line. Optional sync of GitHub's per-file "viewed" state.
7. **Finer-grained guide sections.** Guides already reference individual hunks, so one file can be split across
   sections. Go further by splitting large hunks before the model sees them, at tree-sitter top-level boundaries
   (functions, classes, exports) or blank-line gaps, each piece getting its own ID (`h7a`, `h7b`). The model still
   only picks IDs, so validation stays simple; adjacent pieces in the same section render as one block.
   Reviewed marks already go through review units with parent hunk keys (`units.lua`), so this only changes how
   units are cut.
8. **Edit from the review.** A key on a hunk (diff or guide view) opens an editable float of the real
   working-tree file, folded to that hunk plus context, so undo, LSP and formatters work as normal; saving lets
   working-tree auto-refresh redraw the diff and guide. Guide hunks re-anchor by overlap (as comments do) so an
   edited hunk stays in its section with an "edited since guide" marker instead of moving to "Not in guide"; its
   reviewed mark resets. Direct typing into the composed review buffer is not planned (no per-line read-only).
   Editing lower stack layers: a key on a layer (e.g. `gS`) checks out that branch in the current worktree (the
   worktree is treated as fair game), making it the working-tree layer so the edit float works there; plain
   `]s`/`[s` stay view-only unless opted in via config. Refuses on a dirty worktree (no auto-stash) and handles
   branches checked out elsewhere; confirms first when launched by an agent session working in the same worktree.
   After committing, the existing "not restacked" warning flags the layers above. revuey never restacks and never
   asks for a restack automatically: the warning's details float offers a "send restack request" action the user
   triggers when ready, which messages the launching agent session (mentioning Graphite when the repo uses it, so
   the agent can pick the right tool). revuey itself uses plain git throughout (e.g. `git switch`, also fine for
   Graphite branches). Layers other than the checked-out one (`@`) stay
   viewable but refuse edits with a "press gS to switch" message. Local branches only. Alternative considered:
   one worktree per layer via worktrunk.

## Known bugs
- **Comment thread borders in herdr.** The bottom and right borders of inline comment threads (virtual lines)
  render incorrectly in herdr. Not yet investigated; likely candidates are the width calculation (sign, number
  and fold columns) or how herdr renders box-drawing characters in virtual lines. Check in plain Ghostty and
  tmux first to tell revuey bugs from terminal ones.

## Later / ideas
- Built-in chat panel (descoped: the external agent session covers it). A lighter option: when no agent is
  connected, `<C-a>` offers a one-shot answer from revuey's own read-only `claude -p` (resuming the guide's session),
  landing as a reply in the comment's thread, with no panel.
- Optional image rendering of the guide diagram via snacks.nvim when available.
- Codex as a second AI provider.
- Side-by-side diff mode.
- Standalone non-Neovim frontend reusing the JSON state, if there is demand.
