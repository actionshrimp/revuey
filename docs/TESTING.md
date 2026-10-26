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
  tests can assert on flags such as `--resume`, `--allowedTools` and `--json-schema`. A run whose
  schema has `findings` (an AI review) answers with a canned review, or with
  `$REVUEY_FAKE_CLAUDE_OUTPUT` when a test sets it. A guide run answers with a canned guide;
  `REVUEY_FAKE_CLAUDE=notes` adds line notes, three of them with bad anchors (an unknown hunk,
  a line the hunk lacks, a file without numbered lines), picked from the numbered lines of the
  prompt it was given.
- **GitHub:** a fake `gh` (`tests/bin/gh`, `h.use_fake_gh`) records its argv and returns canned JSON for
  GraphQL PR lookups (PR nodes per `owner/name:branch`, forks' parents, repos that resolve to null), or a
  failure scenario (exit 1, garbage, rate limit, GraphQL errors, a hang that dies on SIGTERM). It also
  answers review-thread queries (thread nodes per `owner/name#N`, cut into pages by the query's
  `first`/`after`, PRs that resolve to null) with a failure scenario of their own
  (`REVUEY_FAKE_GH_THREADS_SCENARIO`), so a working PR lookup can be combined with failing threads.
  For posting reviews it reads a post file (`REVUEY_FAKE_GH_POST`, the fifth argument of
  `h.use_fake_gh`: the viewer, PRs with node ids, heads and pending reviews, the PRs' files for
  the REST `pulls/N/files` pages, review states, and failures: refused threads by body, a
  failing review creation, submit, files read or preflight) that is also its state: review
  mutations rewrite it, and threads they add go into the threads file (pending until
  submitted), so a refetch shows them. Every mutation is recorded as `{op, alias, input}` (the
  input object parsed) in `REVUEY_FAKE_GH_MUTATIONS`, which tests read to assert exactly what
  would be posted; REST calls with `-f`/`-F`/`-X` are refused. It keeps submitted reviews
  (`history`) for the PR's latest reviews and `node` reads, answers a review created and
  submitted at once with its threads, pages reviews' comments by the query's `first`/`after`,
  can apply a mutation and then answer nothing (`fail.lost`, `fail.lost_create`: a timeout after
  GitHub did the work), answer nothing without applying it (`fail.lost_unapplied`), stay down
  afterwards (`fail.down_after_lost`), refuse threads on one side (`fail.add_side`), fail later
  comment pages (`fail.pages`), and answer a review `node` or a PR with a null that is not
  NOT_FOUND (`fail.review_null`, `fail.pr_null`). Posting is only ever tested
  against this fake: no spec or manual check sends a mutation to GitHub.
- **Real review threads:** `tests/data/forge_threads/` is a frozen corpus of 37 RIGHT-side
  threads from public PRs (TypeScript, ruff, vscode, deno, neovim): for each, an excerpt of the
  file at the PR head (the thread's lines ±110, enough for placement's ±100-line search and the
  hunk context, renumbered), the thread's GitHub positions and diff hunk, its source and the
  expected placement with head trust on and off (`NOTICE` lists the licences).
  `forge_corpus_spec.lua` places every case in both modes; `forge_corpus_e2e_spec.lua` builds a
  repository from the excerpts, serves the threads through the fake `gh` and checks where the
  review draws each one. `scripts/trim-forge-corpus.lua` rebuilds the corpus from a cases file
  and file snapshots (collected once with `gh`, never during tests) and refuses to write unless
  every excerpt places exactly as its whole file. Add a case there when a real thread is
  misplaced, and fix the code, not the expectation, unless the new placement is the safer one. `tests/helpers.lua` puts a blocker for the real `gh` first on PATH, so no spec
  can reach GitHub. A fake `wt` (`tests/bin/wt`, `h.use_fake_wt`) stands in for worktrunk's
  `wt switch pr:<N>`: it records argv, cwd and whether stdin is a terminal, creates real
  worktrees, and plays wt's progress, hook, approval and error output; the real `wt` is
  blocked on PATH too (it would run the developer's hooks and approvals). PR fetching is tested against a local bare
  repository acting as `origin`, with `refs/pull/N/head` refs created by the test.

**Headless specs never grow the screen.** In headless Neovim 0.12.4 (no UI attached) the screen
grid stays at its startup size (80x24) when `'columns'` or `'lines'` is set larger, so the next
redraw (the tab line first) writes past it: a heap overrun that crashes intermittently and far
from the cause (seen as SIGSEGV in augroup or autocmd code once LSP traffic redraws windows), and
that happens without revuey too. Setting the size with `--cmd` before startup does not help.
`tests/helpers.lua` therefore undoes any increase of either option in a headless spec and fails
the spec; shrinking is allowed. Specs work at 80x24 (narrow the file panel when a test needs a
wider diff window), and anything that needs a bigger screen runs in a mini.test child with a UI
attached (`screen_spec.lua`), which may be resized freely.

## Running
- `make test` runs everything; each spec runs in a fresh `nvim --headless --clean` so specs cannot leak state.
- Specs must not depend on the developer's own Neovim config, parsers excepted: tests that need a tree-sitter parser
  or query skip clearly when it is unavailable rather than failing obscurely.
- Specs never reach the developer's terminal multiplexer. `tests/helpers.lua` unsets `TMUX*`,
  `HERDR_*`, `ZELLIJ*` and `CMUX_*`, points tmux at a private `TMUX_TMPDIR` and blocks
  `herdr`/`zellij`/`cmux` on PATH; every tmux call in a spec uses its own `-L` socket, and
  `skill/revuey/launch.sh` is only run against fake multiplexers. `guard_spec.lua` (run first)
  enforces this. Manual runs follow the same rule: a private `tmux -L` server, never the live one.
- No process a spec starts may outlive it. Tests only run inside `h.run()`, so cleanup written
  after the test definitions would run before them: register it with `h.teardown(fn)` (run after
  the tests, whatever they did), and get mini.test children from `h.child()`, which stops them
  there. `make test` gives every spec `REVUEY_TEST_RUN=<run dir>`, which everything it starts
  inherits, and `scripts/check-leaks.sh` fails the run (and kills them) when any such process is
  still alive at the end.
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
