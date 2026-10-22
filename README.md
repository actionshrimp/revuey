# revuey

[![test](https://github.com/actionshrimp/revuey/actions/workflows/test.yml/badge.svg)](https://github.com/actionshrimp/revuey/actions/workflows/test.yml)

Code review inside Neovim (>= 0.12). It shows a composed unified diff of the current branch
against its base, or of one layer of a local branch stack (or the whole stack) before you push. Tree-sitter syntax is projected onto the diff lines, LSP go-to-definition and hover
work from inside the diff, and "reviewed" marks persist. An [AI guide](#ai-guide) (your own `claude`
CLI) can reorganise the review into ordered, explained sections. Design notes:
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Install (lazy.nvim, local checkout)

```lua
{
  dir = '~/dev/revuey/main',
  cmd = { 'Revuey', 'RevueyClose', 'RevueyStackParent', 'RevueyGuide' },
  opts = {
    -- default_branch = 'develop', -- default: origin/HEAD, else main, master, develop
    -- ai = { model = 'sonnet' }, -- AI guide; default: Claude Code's default model
  },
}
```

`setup()` is optional. All options and their defaults are in `lua/revuey/config.lua`
(`context_lines`, `fold_context_threshold`, `collapse_large_files`, `panel_width`, `lsp_warmup`,
`lsp_settle_ms`, `word_diff`, `state_dir`, `keymaps`, `ai`).

Requirements:
- `git`.
- Tree-sitter parsers *and highlight queries* for the languages you review (for example
  typescript/tsx via nvim-treesitter). Without them the diff still works but has no syntax colours.
- An LSP configured for the filetype (for example `ts_ls`) for `gd` and `K`.
- For the AI guide only: [Claude Code](https://claude.com/claude-code) (`claude`) on `PATH`, logged in.

## Commands

| Command | |
|---|---|
| `:Revuey` | Review the current branch, uncommitted work included. If the branch is part of a local stack, the review opens at its layer with the stack shown (see [Stacks](#stacks)); otherwise it diffs `merge-base(default branch, HEAD)` against the working tree. |
| `:Revuey --stack` | The whole stack: trunk merge-base to the top of the stack. |
| `:Revuey <base>` | Single-branch review against `base`, exactly as before (no stack detection). `:Revuey <base> --stack` uses `base` as the stack's trunk. |
| `:Revuey ... --committed` | Committed changes only (`merge-base..HEAD`). |
| `:RevueyStackParent [branch]` | Set the stack parent of the layer being reviewed (or of the current branch). `--clear` removes the override. No argument: pick from a list, which also offers "clear override". |
| `:RevueyGuide` | Switch between the diff and the [AI guide](#ai-guide) view. With no guide yet, offers to generate one. |
| `:RevueyGuide!` | Generate a new guide (in the background) and show the guide view. |
| `:RevueyGuide cancel` | Stop a running generation. |
| `:RevueyClose` | Close the review tab. |
| `bin/revuey [args]` | Shell wrapper taking the same arguments as `:Revuey`: starts `nvim` with your config and the review; `q` quits. It finds the plugin relative to the script (or via `$REVUEY_PLUGIN_DIR`), so nothing needs installing. `$REVUEY_NVIM` picks the nvim binary (`$NVIM` is ignored because inside `:terminal` it is a socket). |

**Uncommitted work is included by default** (working-tree mode): committed, staged and unstaged
changes to tracked files, files deleted on disk, and untracked (non-ignored) files as additions.
Files with uncommitted changes get a `●` in the panel, whose header shows the mode. `gu` switches
to committed-only mode (`merge-base..HEAD`) and back. In working-tree mode the review refreshes
itself when you write a file in the repo (debounced), when Neovim regains focus, and when you
re-enter the diff window after files changed; cursor, scroll, folds and reviewed marks are kept.
Reviewed marks are keyed by file content, so a mark made in either mode counts in the other when
the content is the same (and survives `git add`), and editing a file clears its mark. Untracked
symlinks show their link text like git; nested repositories and files or diffs over
`max_file_bytes` (default 1 MB) are listed with a "not shown" placeholder and never read. Refreshes
only re-read files whose size/mtime changed.

LSP requests go through the working-tree buffer. Lines are mapped between the review and the
buffer by position (through a diff when the buffer has unsaved edits, or in committed mode when the
file has uncommitted changes); when a definition isn't shown in the diff, the real file opens.

Line-ending-only changes (LF/CRLF) and a missing final newline are marked with a `⏎` note at the end
of the line.

## Stacks

A stack is a chain of local branches, each based on the one below, for example
`main ← feat/api ← feat/ui ← feat/docs`. `:Revuey` (or `bin/revuey`) with no base detects it:

- **Layers below HEAD:** local branches whose tips are on HEAD's first-parent line above
  `merge-base(trunk, HEAD)`. The trunk is `default_branch` or the auto-detected default branch.
- **Layers above HEAD:** branches containing HEAD, followed while there is exactly one child. At
  a fork the stack stops and the panel says so.
- **Explicit parents win** over the guess: `branch.<name>.revueyParent` in git config (set with
  `:RevueyStackParent`), then Graphite's `refs/branch-metadata/<name>` (`parentBranchName`).
  Unreadable metadata is ignored. A parent that is already merged into trunk counts as trunk.
- **Several branches on one commit:** one is picked deterministically (the current branch, else
  one with an explicit parent, else alphabetical) and the others are mentioned in the panel.

- **Parent moved, child not restacked** (you amended, added to or rebased a lower branch): the
  branch's reflog shows where it used to point, so the child stays in the stack. Its layer diff
  starts from that old tip, which shows only the child's own commits. A note says to restack.
  Without reflogs, branches that share the stack's commits but aren't in it get a note instead.
- **Explicit parent that isn't an ancestor** (a stale override, say after the parent was
  squash-merged and the child rebased onto trunk): the layer is shown against trunk, with a note
  suggesting you fix the override or run `:RevueyStackParent --clear`. A layer diff never reaches
  below the trunk merge-base.
- **Landed bottom layers:** a bottom layer whose changed files are identical in trunk
  (squash-merged) is dimmed with "looks landed in main". The layers above still diff against it.

The guess cannot tell a parent from a child branch cut part-way through it, so it is only a
suggestion and nothing guessed is ever saved. If a stack looks wrong, fix it with
`:RevueyStackParent`. Long lists of branch names in notes are shortened ("a, b, c and 40 more").

The file panel gets a stack section at the top: the layers from trunk up, each with commits,
files changed and reviewed files (`2c 3f ✓1/3`), `@` on HEAD's branch and `▶` on the reviewed
scope, then a **full stack** row. Notes about duplicate tips, forks and ignored metadata follow.

- **Layer scope** (default): parent tip to layer tip. Uncommitted work belongs to the HEAD layer
  only. Other layers are committed-only, and `gu` says so.
- **Full stack scope:** trunk merge-base to the top. It includes the working tree only when HEAD
  is the top layer.
- Reviewed marks are kept per layer: keyed by layer branch and parent (normalised, so
  `origin/main` and `main` match), plus content hashes as before. For layers above another
  layer the old side's hash is part of the key too, so a mark resets when the parent layer
  changes that file. The bottom layer and a plain
  `:Revuey main` share marks, because they review the same diff, and so do the full scope and
  `:Revuey main` on the top branch.
- Switching layers remembers the cursor, scroll and folds for each scope. If the layer you are
  viewing disappears (branch deleted), you get a warning and the HEAD layer is shown.
- Detection runs asynchronously (a few `for-each-ref`, `rev-list` and `config` calls, plus a read
  of the reflogs of up to 300 unmerged branches). It is skipped on refresh when refs and
  overrides are unchanged, and entering the diff window checks for branches moved elsewhere.
  Layer stats load in the background from `git diff --raw`.

With a single branch and no stack, everything behaves exactly as before.

## AI guide

The guide is Claude's walk through the review. It splits the changes into a few ordered
sections: the heart of the change first, then its consequences, then glue. Each section has a
short explanation and the hunks it covers. A file's hunks can be spread over several sections.
It is a reading order, not a bug hunt, but a section may carry an Important or Warning callout.

`gG` (or `:RevueyGuide`) switches the diff window to the guide view; the panel and keys stay.
With no guide for this review yet, it asks before generating one. Generation runs in the
background: the panel shows a spinner, the elapsed time and what Claude is doing ("reading
src/cart.ts"), and you can keep reviewing the diff with `gG`. A small stack layer takes about
10 seconds; a 3,500-line branch about 35 seconds (Opus, $0.10 to $0.70 per guide in our runs).

The guide view uses the same renderer as the diff: syntax, word diff, `gd`, `K`, `go`/`<CR>`,
`]c`/`[c` and folds all work inside it. Each section is a fold with a heading, a reviewed
checkbox and its hunk count, followed by the explanation and its hunks. Each hunk has a
`path  @@ … @@` header and sometimes a one-line note from Claude. The prose is real buffer text
(so you can search and yank it), wrapped to the window and re-wrapped when it is resized,
with light markdown styling.

- `]]` / `[[`: next / previous section.
- `<Tab>` on a section heading collapses / expands the section; on a hunk's `path  @@ … @@`
  header it collapses / expands that hunk. `<S-Tab>` collapses every section (or expands them all).
  Elsewhere `<Tab>` is `<C-i>` as in the diff.
- `mr`: mark the section under the cursor reviewed. It folds, and the cursor moves to the next
  section. The panel shows `✓` per section and "n/m reviewed".
- Section marks are separate from file marks (both are shown: file marks appear on each hunk
  header as "✓ file reviewed"). A section's identity is the set of its hunks' contents, so the
  mark survives regenerating the guide when those hunks are unchanged, and resets when any of
  them changes.

**When the code changes** after the guide was generated, sections whose hunks are unchanged
render as before. A section with changed or missing hunks gets an "outdated" chip and shows only
the hunks that still exist. New hunks go to a final "Not in guide" section, and a banner offers
`gR` to regenerate. The guide never re-runs by itself.

**Per scope:** each review (branch and base, or a stack layer, or the full stack) has its own
guide. Switching layers keeps a generation running for the layer it was started on.

**What runs:** your own `claude` CLI, in the repository root, with the prompt on stdin:
`claude -p --output-format stream-json --verbose --permission-mode dontAsk --tools Read,Grep,Glob,Bash
--allowedTools Read,Grep,Glob,Bash(git diff:*),Bash(git log:*),Bash(git show:*)
--disallowedTools 'Bash(git * --out*)' --restricted --safe-mode --strict-mcp-config …`. Claude can
read files in the repo and run `git diff`/`log`/`show`, nothing else: `--restricted` and
`--safe-mode` make it ignore settings files (yours and the repo's, so no extra allow rules or
hooks), plugins and MCP servers. revuey never reads your credentials. The prompt contains the
commit subjects, a file list and the diff, with each hunk marked by an id (`@@ h7 path @@`);
Claude only refers to hunks by id, and revuey checks the answer (unknown ids are dropped, missed
hunks go to an "Other changes" section). The whole prompt stays under `ai.max_prompt_chars`
(150k characters): the largest hunks are sent as a short index entry, and if that is not
enough, only the file list; a review too big even for that is refused (review one layer). The
Claude session is kept (named "revuey guide: <branch>" in `claude --resume`) and its id is
stored with the guide. Cancelling, a timeout or quitting Neovim stops the CLI and everything it
started.

Guides are saved as JSON under `stdpath('data')/revuey/guides/` (or `state_dir/guides`), with
the model, time and commit they were made from; the newest `ai.keep_guides` (5) per review are
kept. Errors (no `claude`, not logged in, timeout)
are reported and shown in the guide view.

```lua
require('revuey').setup({
  ai = {
    model = nil,        -- e.g. 'sonnet', 'opus', a full model id; nil = Claude Code's default
    effort = nil,       -- 'low' … 'max'; nil = default
    timeout_ms = 600000,
    max_prompt_chars = 150000,
    cmd = nil,          -- path to the claude executable (default: `claude` on PATH)
    keep_guides = 5,    -- saved guides kept per review
    restricted = true,  -- see below before turning this off
  },
})
```

**`ai.restricted`** (default `true`) runs `claude` with `--restricted --safe-mode`, so it ignores
every settings file, yours included. If you log in through settings (`env` or `apiKeyHelper`
in `~/.claude/settings.json`, as with Bedrock, Vertex or a proxy), the run fails as "not logged
in", and a default model set in your settings is not used (set `ai.model` instead). Setting
`restricted = false` loads your user settings (`--setting-sources user`; the repo's settings
still never load). **Warning:** your settings' permission allow rules and hooks then apply to a
run that reads the repo's content, so a rule such as `Bash(make:*)` plus a prompt injection in
the code could run commands. Only turn it off if your settings have no such allow rules or hooks.

## Layout

The review opens in a new tab:
- **File panel (left):** status letter, `+/-` counts, and `✓` for reviewed files.
- **Diff (right):** one continuous buffer for all files.

Every diff line is a real buffer line, and its text is exactly the source text. The `+`/`-` markers,
old/new line numbers and file status are drawn in the `statuscolumn`. The winbar shows the file at
the top of the window. Reviewed files and very large files start folded.

## Keymaps

Diff buffer:

| Key | Action |
|---|---|
| `]c` / `[c` | Next / previous hunk (skips collapsed files and hunks; takes a count) |
| `]f` / `[f` | Next / previous file |
| `<CR>` / `go` | Open the working-tree file at this line (in a split below) |
| `gd` | LSP definition (added/context lines). Jumps within the diff when the target is shown there, otherwise opens the file below |
| `K` | LSP hover |
| `mr` | Toggle file reviewed (collapses the file and moves to the next one) |
| `<Tab>` | On a file header or hunk header: collapse / expand that file or hunk (does not mark it reviewed). On any other line it is `<C-i>` (jump forward, takes a count), since most terminals send the same key for both |
| `<S-Tab>` | Collapse every file, or expand them all when all are collapsed |

`<Tab>` and `<S-Tab>` are buffer-local, so in revuey's diff/guide buffer they override your own
`<Tab>`/`<C-i>`/`<S-Tab>` mappings (only there). A count (`3<Tab>`) always means jump forward. Set
`keymaps = { toggle_fold = false, toggle_all_folds = false }` to leave those keys alone.
| `za` etc. | Normal fold commands: each file is a fold, each hunk a fold inside it, and long unchanged runs are folded |
| `gp` | Focus the file panel |
| `gu` | Toggle working tree (default) / committed only |
| `R` | Refresh (re-runs git; also automatic in working-tree mode) |
| `]s` / `[s` | Next / previous stack layer (takes a count). These shadow spell navigation, which is off in review buffers. |
| `gs` | Toggle full-stack scope and back to the last layer |
| `gG` | Toggle the AI guide view (offers to generate a guide when there is none) |
| `gR` | Generate a new AI guide (asks first when one exists) |
| `]]` / `[[` | Guide view: next / previous section. Diff view: next / previous file |
| `q` | Close the review (quits Neovim when started via `bin/revuey`) |

File panel:
- `<CR>`/`o`: show the file and focus the diff. On a stack row, switch to that layer (or the full stack).
- Moving the cursor previews files in the diff.
- `mr`, `gu`, `R`, `]s`, `[s`, `gs`, `gG`, `gR`, `gp` (back to the diff) and `q` work as in the diff buffer.
- In the guide view the panel also lists the guide's sections: `<CR>` jumps to one, `mr` marks it reviewed.

Reviewed marks are stored in `stdpath('data')/revuey/*.json`. Each review is keyed by repo root,
branch (or stack layer) and base (or parent layer), and each file by its new blob hash, so a mark
disappears when the branch changes that file.

All highlight groups can be overridden: `RevueyAdd`, `RevueyDelete`, `RevueyAddText` and
`RevueyDeleteText` (word diff), `RevueyFileHeader`, `RevueyHunkHeader`, `RevueyAddSign`,
`RevueyDeleteSign`, `RevueyLineNr`, `RevueyAddLineNr`, `RevueyDeleteLineNr`, `RevueyReviewed`,
the guide's `RevueyGuideTitle`, `RevueyGuideSection`, `RevueyGuideCode`, `RevueyGuideImportant`,
`RevueyGuideWarning`, `RevueyGuideHunkNote`, `RevueyGuideOutdated`, and others (see
`lua/revuey/highlights.lua`).

## Try it

```sh
cd ~/dev/revuey/main
scripts/make-fixture.sh /tmp/revuey-fixture   # throwaway TS repo: branch feature/cart vs main
cd /tmp/revuey-fixture
~/dev/revuey/main/bin/revuey                  # or: bin/revuey main
```

Things to try:
- `]f` / `]c` to move around.
- `gd` on `sum(` in `src/cart.ts`: jumps to the new `sum` in the math.ts diff.
- `gd` on `formatCurrency(`: opens `src/format.ts` below.
- `K` on a call.
- `mr` to mark a file reviewed.
- `<Tab>` on a file header or an `@@` hunk header to collapse it, `<Tab>` again to expand it;
  `<S-Tab>` collapses every file.
- `q` to quit.

Uncommitted work: in another terminal (or Neovim split) edit `/tmp/revuey-fixture/src/math.ts`
and save, or create a new file under `src/`; the review updates with a `●` on those files. Press
`gu` to compare with the committed-only view.

In a real repo, run `bin/revuey` (or `:Revuey`) on your feature branch.

### A local stack

```sh
scripts/make-fixture.sh --stack /tmp/revuey-stack  # main ← stack/math ← stack/cart ← stack/ui
cd /tmp/revuey-stack                               # stack/cart (the middle layer) is checked out
~/dev/revuey/main/bin/revuey                       # opens at layer 2/3; or: bin/revuey --stack
```

Things to try:
- `]s` to go to `stack/ui` (committed-only, since it is above HEAD) and `[s` to go back down to `stack/math`.
- `gs` for the full stack, then `gs` again to return to the last layer.
- In the panel, `gp` then `<CR>` on a layer row.
- `mr` a file in `stack/cart`, then `]s`: the mark stays with `stack/cart`, and its row shows `✓1/2`.
- Edit `src/math.ts` and save: the change shows up in `stack/cart` (HEAD) only.
- `:RevueyStackParent main` while on `stack/cart` drops `stack/math` from the stack; `:RevueyStackParent`
  and "clear override" restores it.

### The AI guide

Needs `claude` on `PATH` and logged in (each guide is one `claude -p` run).

```sh
scripts/make-fixture.sh --stack /tmp/revuey-guide
cd /tmp/revuey-guide
~/dev/revuey/main/bin/revuey --stack          # the full stack: 4 files
```

- `gG`, then pick "Generate a guide". Watch the spinner in the panel; `gG` goes back to the diff
  while it runs. The guide appears after about 10 seconds.
- `]]` / `[[` between sections, `]c` within them, `gd` on `sum(` or `K` on a call.
- `mr` on a section: it folds with `☑`, the cursor moves on, and the panel's "reviewed" count goes up.
- `<Tab>` on a section heading or a hunk header collapses it; `<Tab>` again expands it.
- Edit `src/cart.ts` and save: the section with that hunk turns "outdated", the edited hunk
  appears under "Not in guide", and a banner offers `gR`.
- `gs` for a layer: it has no guide of its own yet. `gs` again: the full-stack guide is back.

## Tests

`make test` runs every spec in a fresh `nvim --headless --clean`, offline and without your config
(see [docs/TESTING.md](docs/TESTING.md)):
- **Unit:** diff parsing (renames, binary, type changes, CRLF, missing EOF newline), line layout,
  state persistence/merging/invalidation, async syntax projection (bundled Lua parser), stack
  resolution (ordering, forks, duplicate tips, Graphite metadata, overrides, trunk ahead, merged
  layers) plus `detect()` on real repos.
- **Unit (guide):** hunk ids and anchors, prompt building and the size budget, the stream-json
  parser, validation and JSON repair, section identity, staleness, guide storage, markdown prose.
- **Integration:** real fixture repos opened headlessly (buffer text, extmarks, folds, keymaps,
  lifecycle cleanup, empty reviews, stack layer switching/full scope/per-layer marks/working tree
  on the HEAD layer only), plus LSP definition/hover when `typescript-language-server`
  is on PATH (skipped otherwise). TypeScript highlight checks skip without the TS parser/queries.
  The AI guide runs against a fake `claude` (`tests/bin/claude`) that records its argv and stdin
  and replays canned stream-json (good, invalid, missing hunks, unknown ids, errors, slow, hang),
  so the tests never need the network or a subscription.
- **Screen:** a child Neovim (vendored `mini.test`, `tests/vendor/mini`) renders the review and its
  screen grid, highlight attributes included, is compared to `tests/screenshots/*`. After an
  intended UI change, regenerate them with `REVUEY_UPDATE_SCREENSHOTS=1 make test` and review the
  text diff. `tests/bin_spec.lua` launches `bin/revuey` in tmux (skipped without tmux).
