# Roadmap

Work lands chunk by chunk as pull requests gated on CI (see [TESTING.md](TESTING.md)). Order below is the planned
sequence; later items build on earlier ones.

## Done
- Local branch review: composed diff buffer, file panel, projected syntax and word diff, `gd`/`K`, reviewed marks.
- Working-tree mode with auto-refresh.
- Local PR stacks: layer and full-stack scopes, restack/override/squash-merge notes.
- AI guided review: hunk-level sections, staleness, section reviewed marks, read-only restricted `claude -p`.
- CI on GitHub Actions.

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
2. **AI reviews (local-first).** `:RevueyAIReview [skill]` asks the user's `claude` CLI (read-only, restricted, as
   for the guide) to review the current scope. Findings come back structured (severity, title, body, optional
   suggested change), anchored to review units plus a line range, and land as AI-authored local comment threads.
   The user triages each: accept (becomes their own comment, editable, eligible for a later forge review), dismiss,
   or ask a follow-up that resumes the agent's session. Nothing is posted anywhere. An optional skill's `SKILL.md`
   (from `~/.claude/skills`, the repo's `.claude/skills`, or a path) is read by revuey and passed as review
   guidance; skills that need to run scripts are treated as guidance only.
3. **Ask AI and chat panel.** Built on local comments: from the comment editor (or a visual selection), a key
   sends the draft as a question instead of saving it, carrying its anchor (file, lines, code, guide section). The
   answer streams into a chat side panel that resumes the guide's Claude session, so it has the review context, and
   can be pinned back as a reply in that comment's thread, then kept as a review comment or discarded. Follow-ups on
   AI review findings use the same path. Read-only, restricted `claude -p` as for the guide.
   **Send to the launching agent session.** When a coding agent launched revuey (via a small revuey skill, in a
   tmux or herdr pane), comments and questions can be sent straight back to that session without closing revuey.
   revuey appends events (file, lines, code, text) to a feed that `revuey watch` streams; the agent watches it with
   Claude Code's Monitor tool (re-armed every 30 minutes) and can answer with `revuey reply <id> "…"`, shown in the
   comment's thread. Fallback for other agent CLIs: type the message into the launching pane. The local comments
   chunk should write this event feed from the start.
4. **Remote PR review via worktrunk.** `:Revuey pr <N|url>` from inside an existing clone runs
   `wt switch pr:<N> --no-cd` so the user's worktrunk hooks bootstrap the worktree, walks the PR stack via `gh`
   (base branch chain), and opens the review there with LSP working. No fresh-clone mode. Cleanup via `wt remove`.
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

## Later / ideas
- Optional image rendering of the guide diagram via snacks.nvim when available.
- Codex as a second AI provider.
- Side-by-side diff mode.
- Standalone non-Neovim frontend reusing the JSON state, if there is demand.
