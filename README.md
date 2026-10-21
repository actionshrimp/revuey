# revuey

[![test](https://github.com/actionshrimp/revuey/actions/workflows/test.yml/badge.svg)](https://github.com/actionshrimp/revuey/actions/workflows/test.yml)

Code review inside Neovim (>= 0.12). Chunk 1 shows a composed unified diff of the current branch
against its base. Tree-sitter syntax is projected onto the diff lines, LSP go-to-definition and hover
work from inside the diff, and "reviewed" marks persist. Design notes: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Install (lazy.nvim, local checkout)

```lua
{
  dir = '~/dev/revuey/main',
  cmd = { 'Revuey', 'RevueyClose' },
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
| `:Revuey [base]` | Review the current branch, uncommitted work included: diff `merge-base(base, HEAD)` against the working tree. |
| `:Revuey [base] --committed` | Committed changes only (`merge-base..HEAD`). |
| `:RevueyClose` | Close the review tab. |
| `bin/revuey [base]` | Shell wrapper: starts `nvim` with your config and the review; `q` quits. It finds the plugin relative to the script (or via `$REVUEY_PLUGIN_DIR`), so nothing needs installing. `$REVUEY_NVIM` picks the nvim binary (`$NVIM` is ignored because inside `:terminal` it is a socket). |

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
| `q` | Close the review (quits Neovim when started via `bin/revuey`) |

File panel:
- `<CR>`/`o`: show the file and focus the diff.
- Moving the cursor previews files in the diff.
- `mr`, `gu`, `R`, `gp` (back to the diff) and `q` work as in the diff buffer.

Reviewed marks are stored in `stdpath('data')/revuey/*.json`. Each review is keyed by repo root,
branch and base, and each file by its new blob hash, so a mark disappears when the branch changes
that file.

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

## Tests

`make test` runs every spec in a fresh `nvim --headless --clean`, offline and without your config
(see [docs/TESTING.md](docs/TESTING.md)):
- **Unit:** diff parsing (renames, binary, type changes, CRLF, missing EOF newline), line layout,
  state persistence/merging/invalidation, async syntax projection (bundled Lua parser).
- **Integration:** real fixture repos opened headlessly (buffer text, extmarks, folds, keymaps,
  lifecycle cleanup, empty reviews), plus LSP definition/hover when `typescript-language-server`
  is on PATH (skipped otherwise). TypeScript highlight checks skip without the TS parser/queries.
- **Screen:** a child Neovim (vendored `mini.test`, `tests/vendor/mini`) renders the review and its
  screen grid, highlight attributes included, is compared to `tests/screenshots/*`. After an
  intended UI change, regenerate them with `REVUEY_UPDATE_SCREENSHOTS=1 make test` and review the
  text diff. `tests/bin_spec.lua` launches `bin/revuey` in tmux (skipped without tmux).
