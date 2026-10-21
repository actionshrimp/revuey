# Testing

revuey is driven by automated tests wherever possible. Every chunk of work adds tests at the levels it touches, and a
bug fix starts with a test that reproduces the bug. `make test` must pass before a chunk is considered done, and it
must never need the network, a GitHub account or an AI subscription.

## Levels

### Unit
Pure-Lua modules with no window or buffer UI: diff parsing, line layout and side-table mapping, review state and hash
invalidation, stack resolution, guide schema validation, prompt building. Run in `nvim --headless --clean -l`.
Fast, and exhaustive on edge cases (renames, binary files, no newline at EOF, CRLF, multibyte text, tabs, empty and
deleted files).

### Integration
Real git repositories built in a temp dir by test helpers (see `tests/helpers.lua` and `scripts/make-fixture.sh`).
Open a review headlessly and assert on buffer lines, the line side-table, extmarks and highlight groups, folds, and
the effect of keymaps driven with `normal`/`feedkeys`. LSP tests run the real `typescript-language-server` against
fixture TypeScript files; they skip with a clear message when the server is not installed.

### End-to-end (screen)
Drive a child Neovim over RPC with a UI attached and assert on what the user actually sees: the rendered screen grid
including the file panel, gutter and folds. Prefer reference screenshots checked into `tests/screenshots/` and
regenerated deliberately (for example `REVUEY_UPDATE_SCREENSHOTS=1 make test`), so layout regressions show up as
readable text diffs. `bin/revuey` launch behaviour can be covered with a tmux `capture-pane` smoke test where tmux
is available.

## Fakes for external tools
- **AI:** tests never call the real `claude`. A fake `claude` executable placed first on `PATH` replays recorded
  `stream-json` fixtures, can simulate slow streams, errors and cancellation, and records the argv it was given so
  tests can assert on flags such as `--resume`, `--allowedTools` and `--json-schema`.
- **GitHub:** a fake `gh` returns canned JSON for API/GraphQL calls. PR fetching is tested against a local bare
  repository acting as `origin`, with `refs/pull/N/head` refs created by the test.

## Running
- `make test` runs everything; each spec runs in a fresh `nvim --headless --clean` so specs cannot leak state.
- Specs must not depend on the developer's own Neovim config, parsers excepted: tests that need a tree-sitter parser
  or query skip clearly when it is unavailable rather than failing obscurely.
