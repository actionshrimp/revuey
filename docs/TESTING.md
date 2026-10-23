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
- **GitHub:** a fake `gh` (`tests/bin/gh`, `h.use_fake_gh`) records its argv and returns canned JSON for
  GraphQL PR lookups (PR nodes per `owner/name:branch`, forks' parents, repos that resolve to null), or a
  failure scenario (exit 1, garbage, rate limit, GraphQL errors, a hang that dies on SIGTERM). `tests/helpers.lua` puts a blocker for the real `gh` first on PATH, so no spec
  can reach GitHub. PR fetching is tested against a local bare
  repository acting as `origin`, with `refs/pull/N/head` refs created by the test.

## Running
- `make test` runs everything; each spec runs in a fresh `nvim --headless --clean` so specs cannot leak state.
- Specs must not depend on the developer's own Neovim config, parsers excepted: tests that need a tree-sitter parser
  or query skip clearly when it is unavailable rather than failing obscurely.
- Specs never reach the developer's terminal multiplexer. `tests/helpers.lua` unsets `TMUX*`,
  `HERDR_*`, `ZELLIJ*` and `CMUX_*`, points tmux at a private `TMUX_TMPDIR` and blocks
  `herdr`/`zellij`/`cmux` on PATH; every tmux call in a spec uses its own `-L` socket, and
  `skill/revuey/launch.sh` is only run against fake multiplexers. `guard_spec.lua` (run first)
  enforces this. Manual runs follow the same rule: a private `tmux -L` server, never the live one.
- Skip with `h.skip(reason)` inside a test, or `h.skip_spec(reason)` at the top of a spec to skip all of it. Both print
  `  skip <spec> :: <test> — <reason>` (`<test>` is `(all tests)` for a whole spec).

## CI
`.github/workflows/test.yml` runs `make test` on `ubuntu-latest` for every push to `main` and every pull request
(superseded PR runs on the same ref are cancelled; runs on `main` are not). It pins Neovim to the official v0.12.4
release tarball (sha256-checked), because the screenshots depend on its rendering, and installs git, tmux,
`typescript-language-server` and `typescript` (pinned npm versions), with a `C.UTF-8` locale and
`TERM=xterm-256color`. The job summary lists the `  skip …` lines printed by the test harness, so skips must go
through `h.skip`/`h.skip_spec` to appear there.
- The TypeScript highlight check in `e2e_spec.lua` skips in CI, as it does locally: Neovim bundles no TypeScript
  highlights query, so providing the parser alone would not enable it.
- CI sets `REVUEY_TEST_MAX_GAP_MS=100` for the main-loop responsiveness check in `screen_spec.lua` (default 50ms),
  because shared runners are slower and noisier than a laptop.
