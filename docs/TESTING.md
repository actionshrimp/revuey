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
fixture TypeScript files. They go through `h.need_ts_ls()` (or `h.need_ts_ls_spec()` for a whole spec), which
starts the server once per `make test` run and checks that `initialize` succeeds (that is where it fails when it
finds no tsserver, e.g. with only TypeScript 7 installed; cached in `$REVUEY_TEST_RUN`): the tests skip with the
server's reason when it is missing or cannot start, instead of each waiting out its timeout, and fail instead of
skipping when `CI` is set.

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
  GraphQL PR lookups (PR nodes per `owner/name:branch`, forks' parents, repos that resolve to null; a
  node's `body` only when the query asks for it), or a
  failure scenario (exit 1, garbage, rate limit, GraphQL errors, a hang that dies on SIGTERM). It also
  answers review-thread queries (thread nodes per `owner/name#N`, cut into pages by the query's
  `first`/`after`, PRs that resolve to null) with a failure scenario of their own
  (`REVUEY_FAKE_GH_THREADS_SCENARIO`), so a working PR lookup can be combined with failing threads.
  It answers the change check's signal query (`fragment check`) from the same PRs and threads
  files, so a test changes a PR's signals by rewriting them between checks
  (`REVUEY_FAKE_GH_CHECK_SCENARIO=fail` fails checks only, `REVUEY_FAKE_GH_CHECK_DELAY` slows
  them). Code that depends on time takes `forge.now`, which specs replace with a clock they move.
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
  NOT_FOUND (`fail.review_null`, `fail.pr_null`). What the user does on github.com or in
  Graphite is simulated by rewriting the post file between submits: a pending review submitted
  there is moved to the PR's `history` with its new state (`submit_elsewhere` in
  `forge_post_spec.lua`), a pending comment edited there gets a new `body`. Posting is only ever
  tested against this fake: no spec or manual check sends a mutation to GitHub, and "add to
  pending review" is asserted to send no `submitPullRequestReview` and no `event`.
  For the stack tree it answers the tree's aliases (`sdN`: a head branch's PRs with their
  bases' PRs nested as deep as the query asks; `skN`: the PRs based on a branch) from a `_tree`
  list of PR nodes in the PRs file, newest first and cut at the query's `first` with the real
  `totalCount`; `REVUEY_FAKE_GH_TREE_SCENARIO=fail` fails the tree's own rounds while the first
  one (inside the PR lookup) still answers, `reject` rejects a lookup carrying the tree's aliases
  (GraphQL errors, no data) and answers the lookup alone. `h.tree_repo` builds the matching repositories: a
  bare "GitHub" with every branch and `refs/pull/N/head`, and a clone made before some of them
  moved, so some remote-tracking branches are missing or behind.
- **ssh for `git fetch`:** `tests/bin/fake-ssh` (`h.use_fake_ssh`, set as `GIT_SSH_COMMAND`)
  runs git's `git-upload-pack '<owner>/<name>.git'` against a local bare repository instead, so
  a clone whose origin is `git@github.com:acme/shop.git` (which the PR lookup needs) fetches
  without the network; it refuses when no repository is set, and logs each command with the
  `GIT_TERMINAL_PROMPT` git gave it. `REVUEY_FAKE_SSH_HANG=<seconds>` makes a remote that does
  not answer and then drops the connection (its pid logged, so a spec checks it was stopped).
- **Unexpected errors:** `h.capture_notify` passes error-level messages to `h.on_error` when a
  spec sets it; `stack_tree_view_spec.lua` fails a test on any error notification it did not
  expect, captured or not (an error inside a task would otherwise vanish in a capture).
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
  Specs run in parallel, `JOBS` at a time (default: one per CPU thread; `make test JOBS=1` runs them one by one),
  started slowest first in the order of `SPECS` in the `Makefile`; `screen_spec.lua` (`ALONE`) runs afterwards
  with nothing beside it, because it measures main-loop gaps. `scripts/run-tests.lua` prints each spec's output as
  one block when it ends, then a summary with every spec's time (re-sort `SPECS` from it when the order drifts)
  and the ok/FAIL/skip counts. `REVUEY_TEST_PROFILE=1` adds each test's time to its `ok` line.
- Specs share nothing on disk: each gets its own `<run dir>/<spec>/` as `REVUEY_TEST_TMP` (every `h.tmpdir`, the
  fixture) with its `TMPDIR` inside, and `tests/helpers.lua` points `XDG_CONFIG_HOME`, `XDG_DATA_HOME`,
  `XDG_STATE_HOME` and `XDG_CACHE_HOME` there too, so the default state dir, `revuey.log` and `lsp.log` are the
  spec's, never the developer's. Tmux servers are per process (`-L` with the pid, a private `TMUX_TMPDIR`, and
  `-f /dev/null` so the developer's `~/.tmux.conf` never loads); git never reads the developer's config.
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
- Nothing a run starts leaves files in the real temp dir. `make test` points `TMPDIR` at `<run dir>/tmp` (and unsets
  `XDG_RUNTIME_DIR`, so Neovim's server sockets go there too), removes the run dir when the run passes and keeps it,
  printing its path, when it fails. At the source: Lua's `os.exit` skips Neovim's own exit, which deletes the
  process's temp dir (`$TMPDIR/nvim.<user>/XXXXXX`, holding its server socket), so the harness ends specs with
  `h.exit(code)`, and `nvim -l` scripts (the fake `gh` and `claude`, `lua/revuey/cli.lua`) remove both before
  `os.exit`. A child Neovim must exit (`:qall`, `:cquit`) or be stopped with SIGTERM, never SIGKILL.
- The README's Keymaps tables are generated from `lua/revuey/keys.lua` (the list `g?` shows):
  after changing a key or its description run `nvim --headless --clean -l scripts/readme-keys.lua`;
  `key_help_spec.lua` fails while the README differs or a keymap option is missing from the list.
- Wait for a positive signal, never a fixed time. `h.settle(cond, ms)` waits until `cond()` holds with no revuey
  task (`git.async`, see `git.busy()`) left unfinished and nothing left scheduled (`h.flush()`): the end of a burst
  of background work (a refresh, a PR lookup, the layer stats, the tree's rounds), also after a review closed, to
  show that nothing more happens. A `gh` that must answer late uses `REVUEY_FAKE_GH=slow` with a gate file
  (`REVUEY_FAKE_GH_GATE`, answered when the test creates it) rather than a delay when the test can say when.
  Fixtures from `h.fixture()`/`h.make_fixture()` (`scripts/make-fixture.sh` without `--remote-stack`) are built once
  per run and copied, as is `h.tree_repo` once per spec (fixed dates: every copy has the same commits). The fake
  `gh` and `claude` run their Lua half with `nvim -u NONE -i NONE` (half the start-up of `--clean`).
- Skip with `h.skip(reason)` inside a test, or `h.skip_spec(reason)` at the top of a spec to skip all of it. Both print
  `  skip <spec> :: <test> — <reason>` (`<test>` is `(all tests)` for a whole spec).

## CI
`.github/workflows/test.yml` runs `make test` on `ubuntu-latest` for every push to `main` and every pull request
(superseded PR runs on the same ref are cancelled; runs on `main` are not). It pins Neovim to the official v0.12.4
release tarball (sha256-checked), because the screenshots depend on its rendering, and installs git, tmux,
`typescript-language-server` and `typescript` (pinned npm versions), with a `C.UTF-8` locale and
`TERM=xterm-256color`. GitHub sets `CI`, so the LSP tests fail there rather than skip if the server cannot start.
The job summary lists the `  skip …` lines printed by the test harness, so skips must go
through `h.skip`/`h.skip_spec` to appear there.
- The TypeScript highlight check in `e2e_spec.lua` skips in CI, as it does locally: Neovim bundles no TypeScript
  highlights query, so providing the parser alone would not enable it.
- The main-loop responsiveness check in `screen_spec.lua` allows a 100ms gap by default (`REVUEY_TEST_MAX_GAP_MS` overrides it; CI sets 100 explicitly):
  enough to catch real blocking (users notice 300ms and more) without flaking on a loaded machine.
