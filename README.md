# revuey

[![test](https://github.com/actionshrimp/revuey/actions/workflows/test.yml/badge.svg)](https://github.com/actionshrimp/revuey/actions/workflows/test.yml)

Code review inside Neovim (>= 0.12). It shows a composed unified diff of the current branch
against its base, or of one layer of a local branch stack (or the whole stack) before you push. Tree-sitter syntax is projected onto the diff lines, LSP go-to-definition and hover
work from inside the diff, and "reviewed" marks persist. Design notes: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Install (lazy.nvim, local checkout)

```lua
{
  dir = '~/dev/revuey/main',
  cmd = { 'Revuey', 'RevueyClose', 'RevueyStackParent' },
  opts = {
    -- default_branch = 'develop', -- default: origin/HEAD, else main, master, develop
  },
}
```

`setup()` is optional. All options and their defaults are in `lua/revuey/config.lua`
(`context_lines`, `fold_context_threshold`, `collapse_large_files`, `panel_width`, `lsp_warmup`,
`lsp_settle_ms`, `word_diff`, `state_dir`, `keymaps`).

Requirements:
- `git`.
- Tree-sitter parsers *and highlight queries* for the languages you review (for example
  typescript/tsx via nvim-treesitter). Without them the diff still works but has no syntax colours.
- An LSP configured for the filetype (for example `ts_ls`) for `gd` and `K`.

## Commands

| Command | |
|---|---|
| `:Revuey` | Review the current branch, uncommitted work included. If the branch is part of a local stack, the review opens at its layer with the stack shown (see [Stacks](#stacks)); otherwise it diffs `merge-base(default branch, HEAD)` against the working tree. |
| `:Revuey --stack` | The whole stack: trunk merge-base to the top of the stack. |
| `:Revuey <base>` | Single-branch review against `base`, exactly as before (no stack detection). `:Revuey <base> --stack` uses `base` as the stack's trunk. |
| `:Revuey ... --committed` | Committed changes only (`merge-base..HEAD`). |
| `:RevueyStackParent [branch]` | Set the stack parent of the layer being reviewed (or of the current branch). `--clear` removes the override. No argument: pick from a list, which also offers "clear override". |
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
| `]c` / `[c` | Next / previous hunk (skips collapsed files; takes a count) |
| `]f` / `[f` | Next / previous file |
| `<CR>` / `go` | Open the working-tree file at this line (in a split below) |
| `gd` | LSP definition (added/context lines). Jumps within the diff when the target is shown there, otherwise opens the file below |
| `K` | LSP hover |
| `mr` | Toggle file reviewed (collapses the file and moves to the next one) |
| `za` etc. | Normal fold commands: each file is a fold, and long unchanged runs are folded |
| `gp` | Focus the file panel (`<Tab>` is left alone: it is `<C-i>`, jump forward) |
| `gu` | Toggle working tree (default) / committed only |
| `R` | Refresh (re-runs git; also automatic in working-tree mode) |
| `]s` / `[s` | Next / previous stack layer (takes a count). These shadow spell navigation, which is off in review buffers. |
| `gs` | Toggle full-stack scope and back to the last layer |
| `q` | Close the review (quits Neovim when started via `bin/revuey`) |

File panel:
- `<CR>`/`o`: show the file and focus the diff. On a stack row, switch to that layer (or the full stack).
- Moving the cursor previews files in the diff.
- `mr`, `gu`, `R`, `]s`, `[s`, `gs`, `gp` (back to the diff) and `q` work as in the diff buffer.

Reviewed marks are stored in `stdpath('data')/revuey/*.json`. Each review is keyed by repo root,
branch (or stack layer) and base (or parent layer), and each file by its new blob hash, so a mark
disappears when the branch changes that file.

All highlight groups can be overridden: `RevueyAdd`, `RevueyDelete`, `RevueyAddText` and
`RevueyDeleteText` (word diff), `RevueyFileHeader`, `RevueyHunkHeader`, `RevueyAddSign`,
`RevueyDeleteSign`, `RevueyLineNr`, `RevueyAddLineNr`, `RevueyDeleteLineNr`, `RevueyReviewed`, and
others (see `lua/revuey/highlights.lua`).

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

## Tests

`make test` runs every spec in a fresh `nvim --headless --clean`, offline and without your config
(see [docs/TESTING.md](docs/TESTING.md)):
- **Unit:** diff parsing (renames, binary, type changes, CRLF, missing EOF newline), line layout,
  state persistence/merging/invalidation, async syntax projection (bundled Lua parser), stack
  resolution (ordering, forks, duplicate tips, Graphite metadata, overrides, trunk ahead, merged
  layers) plus `detect()` on real repos.
- **Integration:** real fixture repos opened headlessly (buffer text, extmarks, folds, keymaps,
  lifecycle cleanup, empty reviews, stack layer switching/full scope/per-layer marks/working tree
  on the HEAD layer only), plus LSP definition/hover when `typescript-language-server`
  is on PATH (skipped otherwise). TypeScript highlight checks skip without the TS parser/queries.
- **Screen:** a child Neovim (vendored `mini.test`, `tests/vendor/mini`) renders the review and its
  screen grid, highlight attributes included, is compared to `tests/screenshots/*`. After an
  intended UI change, regenerate them with `REVUEY_UPDATE_SCREENSHOTS=1 make test` and review the
  text diff. `tests/bin_spec.lua` launches `bin/revuey` in tmux (skipped without tmux).
