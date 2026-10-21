# Standalone terminal code-review app: feasibility and building blocks (Rust first; Go and TypeScript/Bun as alternatives) — as of 2026-10-21

Scope note: this covers the "standalone TUI" route only. Versions below were read from crates.io / npm / go.mod / GitHub on 2026-10-21 unless stated otherwise.

## Key Question 1: Rust TUI stack (ratatui, backends, text input, markdown, highlighting, diffing, git, worktrees) and how existing Rust tools solve it

### Takeaway
The Rust stack is mature and every piece needed exists off-the-shelf: ratatui 0.30.x (split into ratatui-core / ratatui-widgets / backend crates), crossterm 0.29 as the default backend, edtui (actively maintained) or ratatui-textarea for comment input, tui-markdown 0.3.12 for prose, syntect 5.3 + two-face for zero-runtime-cost highlighting (what tuicr and gitui use) or tree-sitter-highlight 0.27 (what gitu uses), imara-diff 0.2 / similar 3.2 for diffing, and git2 0.21 as the pragmatic git choice (every surveyed Rust git TUI uses git2; gitui additionally uses gix for read paths). tuicr is the closest existing prior art and proves the exact feature set (unified + side-by-side diffs, comments, GitHub export via `gh`, `$EDITOR` integration) is buildable with this stack.

### Cited Findings

**ratatui and backends**
- Latest ratatui release is v0.30.2 (19 Jun [2026]) alongside ratatui-core 0.1.2, ratatui-crossterm 0.1.2, ratatui-termion 0.1.2, ratatui-termwiz 0.1.2, ratatui-widgets 0.3.2, ratatui-macros 0.7.2; that release also added a Termina backend (`ratatui-termina`) behind a `termina` feature, and fixed a Scrollbar regression from 0.30.0 — [ratatui releases](https://github.com/ratatui/ratatui/releases)
- v0.30.0 was "the biggest version of Ratatui yet" and made Ratatui `no_std`; released as 2025 wrapped up — [orhun's 2025 wrapped](https://blog.orhun.dev/2025-wrapped/)
- v0.30 highlights: workspace split (`ratatui-core` for foundational types that "change more slowly" so widget authors can depend on it; `ratatui-widgets`; crossterm/termion/termwiz backend crates; `ratatui-macros`); MSRV 1.86, Rust 2024 edition; `ratatui::run()` helper for init/restore; `Block::title` replaced by `Line`-based titles; `Alignment` renamed `HorizontalAlignment`; `WidgetRef` no longer gets blanket `Widget` impl; `ScrollbarState::get_position()`; automatic border merging; crossterm version selection via feature flags — [ratatui v0.30 highlights](https://ratatui.rs/highlights/v030/)
- Ratatui supports Crossterm, Termion, Termwiz, and Termina backends; each supports raw mode, alternate screen, and mouse capture; "The most commonly-used backend is Crossterm... If you have no particular reason to use Termion or Termwiz, you will find it easiest to learn Crossterm simply due to its popularity." — [ratatui.rs backends](https://www.ratatui.rs/concepts/backends/)
- Each backend "handles mouse capture differently, with variations in the types of events that can be captured and how they are represented" — [ratatui.rs mouse capture](https://ratatui.rs/concepts/backends/mouse-capture/)
- The ratatui backend comparison frames Termwiz as the choice when "the TUI [is] only for Wezterm users" — [ratatui backend comparison](https://www.ratatui.rs/concepts/backends/comparison/)
- Ratatui renders immediately each frame; "after the drawing closure returns, a diff is performed and only the changes are drawn to the terminal" — [ratatui.rs backends](https://www.ratatui.rs/concepts/backends/)
- crossterm latest on crates.io is 0.29.0, last updated 2025-04-05, 214M downloads — [crates.io crossterm](https://crates.io/api/v1/crates/crossterm)
- Mixing crossterm major versions keeps separate event queues and can cause lost events / races — [ratatui.rs](https://ratatui.rs/installation/) (via search summary)

**Text input widgets for comments**
- tui-textarea: latest 0.7.0, last updated 2024-10-22 ("simple yet powerful text editor widget for ratatui and tui-rs") — effectively stale — [crates.io tui-textarea](https://crates.io/api/v1/crates/tui-textarea)
- gitui 0.28.1 depends on `ratatui-textarea` 0.8 (a maintained successor/fork of tui-textarea), not tui-textarea — [gitui Cargo.toml](https://raw.githubusercontent.com/gitui-org/gitui/master/Cargo.toml)
- edtui: latest 0.11.7, updated 2026-08-16, "A TUI based vim inspired editor" — [crates.io edtui](https://crates.io/api/v1/crates/edtui)
- tuicr uses edtui 0.11 (default features off) for its comment editor and has an opt-in `comment_vim = true` setting for modal editing in the comment box — [tuicr Cargo.toml](https://raw.githubusercontent.com/agavra/tuicr/main/Cargo.toml); [tuicr README](https://raw.githubusercontent.com/agavra/tuicr/main/README.md)

**Markdown / prose rendering**
- tui-markdown: latest 0.3.12, updated 2026-10-19, "A simple library for converting markdown to a Ratatui Text value", repo joshka/tui-markdown, 561k downloads — [crates.io tui-markdown](https://crates.io/api/v1/crates/tui-markdown)
- tui-markdown parses with pulldown-cmark and returns a ratatui `Text`; `highlight-code` feature (default on) uses syntect + ansi-to-tui for code blocks; supports headings, lists, block quotes, emphasis, code blocks, footnotes; does NOT support tables, task lists, links, images — [docs.rs tui-markdown](https://docs.rs/tui-markdown)
- Alternatives seen: `ratatui-markdown` 0.2.x (tables + `MarkdownPreview` widget), `ratkit` 0.2.2 (`MarkdownRenderer`) — [docs.rs ratatui-markdown](https://docs.rs/ratatui-markdown); [docs.rs ratkit](https://docs.rs/crate/ratkit/0.2.2)
- tuicr uses pulldown-cmark 0.13.4 directly (default features off) rather than tui-markdown — [tuicr Cargo.toml](https://raw.githubusercontent.com/agavra/tuicr/main/Cargo.toml)

**Syntax highlighting: syntect vs tree-sitter**
- syntect latest 5.3.0, updated 2025-09-27, "high quality syntax highlighting and code intelligence using Sublime Text's grammars", 34M downloads — [crates.io syntect](https://crates.io/api/v1/crates/syntect)
- tree-sitter-highlight latest 0.27.1, updated 2026-10-08 — [crates.io tree-sitter-highlight](https://crates.io/api/v1/crates/tree-sitter-highlight)
- tuicr (syntect route): syntect 5.2 + two-face 0.5 (`syntect-default-fancy`, default features off); themes can point at a `.tmTheme` file via `syntax_theme` — [tuicr Cargo.toml](https://raw.githubusercontent.com/agavra/tuicr/main/Cargo.toml); [tuicr README](https://raw.githubusercontent.com/agavra/tuicr/main/README.md)
- gitui (syntect route): syntect 5.3 (default syntaxes/themes, parsing, plist-load, regex-fancy) + two-face 0.4.4 — [gitui Cargo.toml](https://raw.githubusercontent.com/gitui-org/gitui/master/Cargo.toml)
- gitu 0.43.0 (tree-sitter route): tree-sitter and tree-sitter-highlight pinned `=0.25.6`, with ~19 grammar crates vendored as dependencies (rust, toml-ng, javascript 0.23.1, typescript 0.23.2, c, cpp, json, ruby, haskell, go, c-sharp, python, bash, php, java, scala, ocaml, html, elixir); diffs with imara-diff 0.2.0; git via git2 0.20.2 — [gitu Cargo.toml](https://raw.githubusercontent.com/altsem/gitu/master/Cargo.toml)
- Trade-off summary from ecosystem discussion: tree-sitter highlights are "much more accurate" and TextMate themes are easy to port, but custom syntaxes are harder; syntect uses Sublime syntax definitions which are "much more widespread and are easier to convert from the ubiquitous TextMate syntax definition format"; "many tree-sitter parsers do not get published to crates.io, and those that are, are usually very outdated" — [zola issue 1787](https://github-redirect.dependabot.com/getzola/zola/issues/1787); [syntastica](https://github.com/RubixDev/syntastica)
- `tree-painter` crate: tree-sitter based highlighter using Helix themes, explicitly positioned against syntect's regex parser — [docs.rs tree-painter](https://docs.rs/tree-painter)

**Diff crates**
- similar: 3.2.0, updated 2026-08-17, 225M downloads — [crates.io similar](https://crates.io/api/v1/crates/similar)
- imara-diff: 0.2.0, updated 2025-06-14, 35M downloads; its docs claim "up to 30 times" faster than `similar` on Linux kernel diffs (self-reported benchmark); Histogram algorithm "outperforms Myers diff by 10% - 100%"; designed for pathological inputs — [crates.io imara-diff](https://crates.io/api/v1/crates/imara-diff); [docs.rs imara-diff](https://docs.rs/imara-diff)
- imara-diff is now maintained under gitoxide as `gix-imara-diff` (0.2.4) — [docs.rs gix-imara-diff](https://docs.rs/gix-imara-diff/0.2.4)
- diffy: 0.5.2, updated 2026-08-31, "Tools for finding and manipulating differences between files" (patch/merge oriented), 18M downloads — [crates.io diffy](https://crates.io/api/v1/crates/diffy)
- tuicr lists no diff crate at all (it parses git-produced diffs); it uses git2 0.20 (default features off, zlib-ng-compat on musl) — [tuicr Cargo.toml](https://raw.githubusercontent.com/agavra/tuicr/main/Cargo.toml)

**git2 vs gix vs shelling out**
- git2: 0.21.0 (published 2026-05-18), 121M downloads — [crates.io git2](https://crates.io/api/v1/crates/git2)
- gix: 0.89.0, updated 2026-10-08, "Interact with git repositories just like git would", 52.7M downloads — [crates.io gix](https://crates.io/api/v1/crates/gix)
- gitoxide crate-status: worktree *add* supported; worktree list partly; checkout orchestration (switch/restore/reset) MISSING (only low-level index checkout); worktree move/remove/repair missing; shallow clone supported; partial/blobless clone NOT supported; fetch with custom refspecs supported over HTTPS (curl/reqwest), SSH only via external `ssh` binary; writing FETCH_HEAD missing; persisting remotes to config missing; merge-base (incl. octopus) supported; tree/tree and tree/worktree diffs with rename tracking supported; push, merge, rebase, stash, hooks all missing — [gitoxide crate-status.md](https://raw.githubusercontent.com/GitoxideLabs/gitoxide/main/crate-status.md)
- gitui's asyncgit 0.28.1 uses git2 0.21 (https, ssh, unstable-sha256) AND gix 0.84.0 (mailmap, max-performance, revision, sha1, sha256, status) — i.e. gix for selected read paths, git2 for everything else — [asyncgit Cargo.toml](https://raw.githubusercontent.com/gitui-org/gitui/master/asyncgit/Cargo.toml)
- Radicle's migration plan (2024) was to replace git2 with gix in stages, noting the fetch protocol was the hardest part — [gitoxide issue 1319](https://github.com/byron/gitoxide/issues/1319)
- Cargo's `cargo_use_gitoxide_instead_of_git2` flag is still documented as for testing/developing only — [cargo docs](https://doc.rust-lang.org/stable/nightly-rustc/cargo/core/features/fn.cargo_use_gitoxide_instead_of_git2.html)

**Reference Rust apps**
- tuicr 0.27.0: ratatui 0.30 (`unstable-rendered-line-info`), crossterm 0.29, edtui 0.11, syntect 5.2 + two-face 0.5, git2 0.20, ureq 3 (no tokio/reqwest), pulldown-cmark 0.13.4, arboard 3.4 (clipboard), terminal-colorsaurus 1 (bg detection), self-replace/tempfile 3.24 (self-update) — [tuicr Cargo.toml](https://raw.githubusercontent.com/agavra/tuicr/main/Cargo.toml)
- tuicr features: "single continuous diff across all changed files", `diff_view = "side-by-side" | "unified"`, line/range/file/review-level comments, per-file/hunk review tracking persisted across sessions, export to GitHub/GitLab/Gitea/Bitbucket/Azure DevOps/Gerrit/clipboard/stdout, works with git/jj/Mercurial, `tuicr pr 125`, `tuicr -r main..HEAD`, `tuicr -w`; exposes a Rust `ReviewStore` library API for its persisted sessions — [tuicr README](https://raw.githubusercontent.com/agavra/tuicr/main/README.md)
- gitui 0.28.1: ratatui 0.30 (crossterm backend), crossterm 0.29, ratatui-textarea 0.8, syntect 5.3, two-face 0.4.4, notify 8, MSRV 1.88, internal `asyncgit` crate for off-thread git — [gitui Cargo.toml](https://raw.githubusercontent.com/gitui-org/gitui/master/Cargo.toml)
- yazi 26.9.1 (rust-version 1.99): depends directly on `ratatui-core` 0.1.2 (patched git branch `fix_buffer_diff_wide_cells`) and `ratatui-widgets` 0.3.2 rather than the umbrella crate; tokio 1.54, mlua 0.12.2; ~24 workspace crates (yazi-core, yazi-tui, yazi-term, yazi-scheduler, yazi-plugin, ...) — [yazi Cargo.toml](https://raw.githubusercontent.com/sxyazi/yazi/main/Cargo.toml); [yazi-fm Cargo.toml](https://raw.githubusercontent.com/sxyazi/yazi/main/yazi-fm/Cargo.toml)

### Inferences
- The three Rust git TUIs surveyed (tuicr, gitui, gitu) all use git2 for write-side/orchestration work; gix is used only for read-side acceleration (gitui). Given gix's crate-status (no checkout orchestration, no partial clone, SSH via external binary, no FETCH_HEAD), a new tool wanting worktrees + PR fetches should either use git2 or shell out to `git` for `worktree add`, `fetch`, and partial clone, and reserve gix for fast read-only paths (revwalk, merge-base, tree diffs) if at all.
- Shelling out to `git` for clone/fetch/worktree is the lowest-risk path: partial (`--filter=blob:none`) clones and `git worktree add --detach` are unsupported or only partially supported in gix, and git2/libgit2 also lacks partial-clone support (libgit2's gap is well known; not re-verified in this pass — see Gaps).
- For comment input, edtui is the live option in 2026 (updated Aug 2026, used by tuicr); tui-textarea is stale since Oct 2024, with `ratatui-textarea` as the fork that gitui moved to.
- Large-diff virtualization is not a ratatui feature; apps must compute the visible window themselves and build only those `Line`s each frame (ratatui's own buffer diff handles terminal I/O cost, not widget construction cost). tuicr enabling `unstable-rendered-line-info` suggests it relies on ratatui's rendered-line metadata for scroll bookkeeping.
- syntect is the lower-friction choice for a review tool: no grammar crate bundling, `.tmTheme` support, binary-serialized syntax sets via two-face, and both tuicr and gitui prove it is fine for diff views. tree-sitter gives better accuracy and is the route gitu chose (pinning ~19 grammar crates), at the cost of binary size and grammar versioning churn.

### Gaps
- No published benchmark on startup cost of syntect (loading two-face syntax sets) versus tree-sitter grammar init in a TUI; not found in this pass.
- No source found documenting ratatui 0.30 mouse-event changes specifically; mouse support is via backend crates and was not itemized in release notes read.
- libgit2/git2 partial-clone support status was not re-verified from a primary source.

## Key Question 2: LSP client from Rust (crates; what helix/zed use; minimal client; rootUri for temp worktrees; TypeScript server options and tsgo/TypeScript 7 status)

### Takeaway
There is no widely shared Rust "LSP client" crate: helix and zed both hand-roll a JSON-RPC transport over the server's stdio using `lsp-types` (helix maintains a fork) plus tokio/smol; `async-lsp` 0.2.4 (tower-based, explicitly supports building clients) is the only general-purpose option. The big 2026 change is that TypeScript 7.0 (GA July 8, 2026) ships a native LSP server (`tsc --lsp --stdio`) and dropped `tsserver.js`, so typescript-language-server no longer works with TS 7; a new tool should target TS7's built-in LSP first and vtsls/typescript-language-server only for TS ≤6 workspaces.

### Cited Findings

**Rust LSP crates**
- `lsp-types` (gluon-lang): latest 0.97.0, last updated 2024-06-04, 41M downloads — [crates.io lsp-types](https://crates.io/api/v1/crates/lsp-types)
- `async-lsp` 0.2.4 (released 2026-04-24): "A framework for Language Server Protocol (LSP) applications, built on tower"; depends on lsp-types ^0.95.0; "can build both a language server and a language client"; optional deps: async-io 2, tokio ≥1.27, rustix 1, tracing, waitpid-any — [docs.rs async-lsp](https://docs.rs/crate/async-lsp/latest); [github oxalica/async-lsp](https://github.com/oxalica/async-lsp)
- helix-lsp ("LSP client implementation for Helix project") depends on a local `helix-lsp-types` crate (not crates.io), tokio 1.50 with `process`, `io-util`, `io-std`, `sync`, etc., `sonic-rs` for JSON, `futures-util`, `arc-swap`, `slotmap`; no async-lsp, no tower — [helix-lsp Cargo.toml](https://raw.githubusercontent.com/helix-editor/helix/master/helix-lsp/Cargo.toml)
- Helix's `helix-lsp-types` is a fork of lsp-types taken at v0.95.1 with usability tweaks — [helix-lsp-types README](https://git.bendn.org/helix/tree/helix-lsp-types/README.md)
- Zed's `lsp` crate (0.1.0, GPL-3.0-or-later) depends on `lsp-types`, `futures`, `futures-lite`, `async-channel`, `postage`, `parking_lot`, `serde_json`, and gpui; no async-lsp/tower — [zed crates/lsp/Cargo.toml](https://raw.githubusercontent.com/zed-industries/zed/main/crates/lsp/Cargo.toml)

**TypeScript server landscape (Oct 2026)**
- TypeScript 7.0 GA: July 8, 2026. "The new foundation is built on the Language Server Protocol (LSP) and is able to leverage multiple threads to serve simultaneous requests." Added since beta: auto-imports, expandable hovers, inlay hints, code lenses, go-to-source-definition, JSX linked editing; also semantic highlighting, sort imports, remove unused imports. npm: `typescript` (provides `tsc` for TS7), `@typescript/typescript6` (`tsc6` + TS 6.0 API), `@typescript/native-preview` nightlies retired in favor of `typescript@next`. TS 7.0 ships WITHOUT a programmatic API; a new API is expected in 7.1. "Any editor with LSP support should work with TypeScript 7." Editor perf: VS Code codebase time-to-first-error ~17.5s → <1.3s; Canva ~58s → ~4.8s — [Announcing TypeScript 7.0](https://devblogs.microsoft.com/typescript/announcing-typescript-7-0/)
- microsoft/typescript-go staging repo was archived Sep 1, 2026; development moved back to microsoft/TypeScript; for 7.0 RC and later the command is `tsc` (preview name was `tsgo`); LSP status was listed as "in progress — nearly all features implemented" — [github microsoft/typescript-go](https://github.com/microsoft/typescript-go)
- Launch form in practice: `tsc --lsp --stdio`; running `tsc --lsp` alone reports that only stdio is supported; an `initialize` to it advertised completion, hover, go-to-definition, references, code actions, rename; the author switched because typescript-language-server failed with "Could not find a valid TypeScript installation" since "TypeScript 7 dropped the `tsserver.js` that the adapter depended on" — [arunmozhi.in, 2026-07-10](https://arunmozhi.in/2026/07/10/using-typescript-v7-with-emacs-eglot/)
- Serena (Apr 2026, 7.0 dev build) describes tsgo as implementing LSP natively via `tsgo --lsp` over stdio "without Node.js or the traditional typescript-language-server wrapper"; a related PR notes typescript-language-server is not compatible with TS 7 — [serena issue 1402](https://github.com/oraios/serena/issues/1402); [serena PR 1406](https://github.com/oraios/serena/pull/1406)
- VS Code's TS7 extension starts `<tsdk>/tsgo --lsp --stdio` when `js/ts.tsdk.path` points at a directory containing a `tsgo` or `tsc` executable — [vercel-labs/tsc-ts wiki](https://github.com/vercel-labs/tsc-ts/wiki)
- typescript-language-server README: run as `typescript-language-server --stdio`; install example is `npm install -g typescript-language-server typescript@6`; TypeScript resolution sources reported via `$/typescriptVersion` are `workspace`, `user-setting` (`initializationOptions.tsserver.path`), and `bundled`; project states TS 7's LSP "will hopefully supersede this project" — [typescript-language-server README](https://github.com/typescript-language-server/typescript-language-server)
- vtsls: LSP wrapper around VS Code's bundled TypeScript extension, "features and performance are nearly the same" as VS Code; ships with bundled TypeScript and uses it by default; `vtsls.autoUseWorkspaceTsdk` / `vtsls.typescript.globalTsdk` to override; run `vtsls --stdio`; Node ≥16; no TS7 statement on the README — [github yioneko/vtsls](https://github.com/yioneko/vtsls)
- Claude Code bug report: sending `rootUri: null` on initialize made typescript-language-server unable to locate tsconfig.json or `node_modules/typescript` and it crashed; cross-file definition/references returned empty — [claudeissues 31365](https://claudeissues.com/issue/31365-bug-lsp-tool-passes-rooturi-null-during-initialization-breaking-typescript-langu)
- coc-tsserver resolves `tsserver.tsdk` global config first and falls back to its bundled module — [coc-tsserver README](https://app.unpkg.com/coc-tsserver@2.3.1/files/Readme.md)

### Inferences
- A minimal client for this tool: spawn server with stdio, send `initialize` with `rootUri`/`workspaceFolders` pointing at the worktree (never null), `initialized`, `textDocument/didOpen` for each file the user opens in the viewer (content from the worktree or from the diff's post-image), then `textDocument/definition` and `textDocument/hover`; `shutdown`/`exit` on close. Helix's and Zed's crates show this is ~a transport + request-id map + `lsp-types` serde; `async-lsp` wraps the same thing in tower middleware if you want concurrency/cancellation handled for you. Note the lsp-types version skew: async-lsp pins 0.95, crates.io latest is 0.97 (stale since 2024), helix forked 0.95.1.
- Whether `node_modules` must be installed in the worktree: for typescript-language-server/vtsls (TS ≤6), the server itself can run from a bundled TypeScript, but type resolution for third-party imports requires the packages (or `@types`) on disk; without them hover/definition into dependencies degrade to `any`/missing while intra-project navigation still works via tsconfig paths. TS 7's `tsc --lsp` is a native binary and similarly needs the project's dependencies present to resolve them. Sharing `node_modules` into the worktree (symlink) is therefore worth doing (see KQ5).
- TS7 startup numbers (VS Code codebase <1.3s to first error vs 17.5s on TS6) indicate that for a medium project the native server should be sub-second to a few seconds to initialize, versus multi-second to tens of seconds for tsserver-based servers; that makes "spawn an LSP per review worktree" viable in a TUI in a way it was not before.
- Because TS 7.0 has no programmatic API, the "just use the TypeScript compiler API from a TS app" shortcut (KQ3) only works against TS 6 (`@typescript/typescript6`) until 7.1 ships an API; for TS7 projects the LSP route is the only supported integration from any language.

### Gaps
- No primary-source measurement of `tsc --lsp` or `typescript-language-server` initialize-to-ready latency on a "medium" project; only the TS team's VS Code/Canva editor numbers above.
- No official TypeScript docs page found enumerating `tsc --lsp` flags; the `--lsp --stdio` form is from community posts and the VS Code extension source.
- Did not verify from a primary source how TS7's LSP behaves when `node_modules` is absent.

## Key Question 3: Alternatives — Go (bubbletea v2 + lipgloss + chroma + go-git) and TypeScript/Bun (Ink, OpenTUI); dev velocity vs distribution vs performance

### Takeaway
Go's Charm stack hit v2 on 2026-02-23 (bubbletea v2.1.0 / lipgloss v2.0.6 / bubbles v2.2.1 / glamour v2 in crush; chroma v2.27 and go-git v5.19 for highlighting/git) and is proven by lazygit, gh-dash, and crush. The TS/Bun route has OpenTUI 0.6.6 (Zig core, flexbox, built-in tree-sitter `CodeRenderable` and `MarkdownRenderable`, used by OpenCode "for millions of users") and Ink 8.0; `bun build --compile` gives single binaries but at 60–150 MB. The TS compiler-API advantage is blunted by TS 7.0 shipping without a programmatic API.

### Cited Findings

**Go**
- Bubble Tea, Lip Gloss, and Bubbles v2 announced out of beta on 23 February 2026; new "Cursed Renderer" modeled on ncurses; `tea.Model.View()` now returns a `tea.View` struct; import paths moved to `charm.land/bubbletea/v2`, `charm.land/lipgloss/v2` — [charm.land blog v2](https://charm.land/blog/v2/)
- crush go.mod (go 1.27.0): `charm.land/bubbletea/v2` v2.1.0, `charm.land/lipgloss/v2` v2.0.6, `charm.land/bubbles/v2` v2.2.1, `charm.land/glamour/v2` v2.0.1, `github.com/alecthomas/chroma/v2` v2.27.0, `github.com/go-git/go-git/v5` v5.19.2, `github.com/sourcegraph/jsonrpc2` v0.2.2 (JSON-RPC transport; crush has its own LSP client on top), no tree-sitter — [crush go.mod](https://raw.githubusercontent.com/charmbracelet/crush/main/go.mod)
- gh-dash go.mod (go 1.27.1): bubbletea v2.0.2, lipgloss v2.0.1, bubbles v2.0.0, glamour v2.0.0, `github.com/cli/go-gh/v2` v2.13.0, `github.com/shurcooL/githubv4`, git via `aymanbagabas/git-module` (shells out to git; no go-git), chroma only indirect (via glamour) — [gh-dash go.mod](https://raw.githubusercontent.com/dlvhdr/gh-dash/main/go.mod)
- go-gh reads `GITHUB_TOKEN`/`GH_TOKEN` (and `GH_ENTERPRISE_TOKEN`), with CVE-2024-53859 fixed in v2.11.1 limiting `GITHUB_TOKEN` to github.com/ghe.com hosts — [NVD CVE-2024-53859](https://nvd.nist.gov/vuln/detail/cve-2024-53859)
- lazygit's editor integration is template-driven (`os.edit`, `editAtLine`, `editAtLineAndWait`, `openDirInEditor`, `editInTerminal`) with presets for vim, nvim, nvim-remote (experimental), vscode, zed, helix, etc. — [lazygit Config.md](https://raw.githubusercontent.com/jesseduffield/lazygit/master/docs/Config.md)

**TypeScript / Bun**
- `@opentui/core` 0.6.6 on npm: "TypeScript library on a native Zig core"; deps `diff` 9.0.0, `marked` 17.0.1, `string-width`, `bun-ffi-structs`; platform `optionalDependencies` for darwin/linux/win32 × x64/arm64 (+musl); engines bun ≥1.3.14, node ≥26.4.0; peer dep `web-tree-sitter` 0.25.10 — [npm @opentui/core](https://registry.npmjs.org/@opentui/core/latest)
- OpenTUI README: Zig core; packages core/react/solid/keymap/qrcode/three/ssh; flexbox layout; selects, inputs, scroll boxes with keyboard+mouse; "OpenCode uses OpenTUI in production for millions of users"; dev requires Bun ≥1.4.1 and Zig 0.16.0 — [OpenTUI README](https://cdn.jsdelivr.net/gh/anomalyco/opentui@main/README.md)
- OpenTUI `CodeRenderable` highlights via Tree-sitter (`filetype` + `syntaxStyle`), built-in TypeScript/JavaScript, Markdown, Zig grammars, any WASM grammar + highlights query can be registered, `highlightOnce()` for ANSI output, `streaming: true` for LLM output; `MarkdownRenderable` highlights fenced code blocks via Tree-sitter — [opentui.com code component](https://opentui.com/docs/components/code); [opentui.com markdown](https://opentui.com/docs/components/markdown)
- Ink 8.0.0 ("React for CLI"): deps yoga-layout ~3.2.1, react-reconciler ^0.34; peer react ≥19.3.0; Node ≥22 — [npm ink](https://registry.npmjs.org/ink/latest)
- `bun build ./cli.ts --compile --outfile mycli` produces a standalone binary; cross-targets like `bun-linux-x64`; binaries embed the runtime and a small tool grows to 60–150 MB — [bun docs executables](https://bun.com/docs/bundler/executables.md); [flaviocopes 2026-10-07](https://flaviocopes.com/javascript-single-executable/)
- Plannotator (`plannotator review`) is browser-based: starts a temporary local server and opens the diff in the browser; docs verified against v0.23.1 (July 2026); no OpenTUI connection found — [docs.plannotator.ai](https://docs.plannotator.ai/open-source.md)
- TS 7.0 "ships without a programmatic API"; tools needing it should use TS 6.0 via `@typescript/typescript6` until 7.1 — [Announcing TypeScript 7.0](https://devblogs.microsoft.com/typescript/announcing-typescript-7-0/)

### Inferences
- Velocity: TS/OpenTUI has the most "batteries included" for exactly this app (flexbox, scroll boxes, tree-sitter code + markdown renderables, streaming LLM text), and GitHub/Claude/OpenAI SDKs are native to the ecosystem. Go is in the middle (glamour for markdown, chroma for highlighting, mature Elm-style framework) and is where the two best-known review-adjacent TUIs (lazygit, gh-dash) live. Rust requires the most assembly (markdown + highlighting + diff coloring glue is hand-rolled) but has tuicr as a working template.
- Distribution: Rust and Go both produce small static binaries with mature release tooling (cargo-dist; goreleaser); Bun `--compile` binaries are 60–150 MB and OpenTUI additionally carries native Zig platform packages, which is acceptable for an npm-installed dev tool (OpenCode ships this way) but heavier for Homebrew/curl installs.
- Performance: Rust/Go are comfortably fast for a diff viewer; OpenTUI's Zig core offloads rendering so TS is viable too (OpenCode proves it at scale). The LSP client is cheap in all three; the expensive part (TS7 server) is external regardless.
- The "trivially call tsserver via the TypeScript API from TS" argument is weaker in 2026: TS 7 has no API until 7.1, so even a TS app would talk LSP to `tsc --lsp` for TS7 projects.

### Gaps
- No source found confirming Ink + JSX + yoga bundles cleanly under `bun build --compile`; needs a direct test.
- go-git vs shelling out: gh-dash shells out (git-module), crush uses go-git; no 2026 comparison of go-git's worktree/partial-clone support was gathered.

## Key Question 4: Rendering mixed "guided review" documents (markdown prose + embedded, syntax-highlighted, diff-colored code hunks)

### Takeaway
No Rust crate renders "markdown with embedded diff hunks" out of the box; the practical design is to render prose blocks with tui-markdown (or pulldown-cmark directly) into ratatui `Text`, render each code hunk yourself as `Line`s of `Span`s where syntect/tree-sitter supplies foreground styles and the diff status supplies background/gutter styles, then concatenate into one virtualized line list. OpenTUI is the only surveyed framework with built-in markdown + tree-sitter code renderables, though it too lacks a diff-aware code block.

### Cited Findings
- tui-markdown converts markdown to a ratatui `Text` value with syntect highlighting of fenced code via `ansi-to-tui`; tables/links/images unsupported — [docs.rs tui-markdown](https://docs.rs/tui-markdown); [crates.io](https://crates.io/api/v1/crates/tui-markdown)
- Ratatui `Text`/`Line`/`Span` carry per-span `Style` (fg, bg, modifiers); styling gained conversions from anstyle, tuples, and primitives in 0.30 — [ratatui v0.30 highlights](https://ratatui.rs/highlights/v030/)
- tuicr renders one continuous diff across files with syntect+two-face highlighting and `.tmTheme` themes, and uses pulldown-cmark for markdown (comments/export), proving the per-span approach for diff+syntax in ratatui — [tuicr Cargo.toml](https://raw.githubusercontent.com/agavra/tuicr/main/Cargo.toml); [tuicr README](https://raw.githubusercontent.com/agavra/tuicr/main/README.md)
- Go: glamour v2 (markdown renderer used by gh-dash and crush) with chroma v2.27 for code; crush imports both — [crush go.mod](https://raw.githubusercontent.com/charmbracelet/crush/main/go.mod)
- OpenTUI: `MarkdownRenderable` (tree-sitter highlighted fenced blocks, normalizes `tsx` → `typescriptreact`) and `CodeRenderable` with `onHighlight` callback "for changing highlights before render", `conceal` option, selection support — [opentui.com markdown](https://opentui.com/docs/components/markdown); [opentui.com code](https://opentui.com/docs/components/code)

### Inferences
- In Rust, the cleanest architecture is a document model of blocks (`Prose(markdown)`, `Hunk{file, old_range, new_range, lines}`), rendered to a flat `Vec<Line>` with a side index mapping document lines back to (file, line) for jump-to-definition/open-in-editor. Highlight each hunk's file once (syntect `HighlightLines` over the post-image, or tree-sitter over the full file so context is correct), then slice the hunk's lines and overlay diff bg colors; this is the same two-layer styling tuicr/gitui do.
- OpenTUI's `onHighlight` hook is the closest to a built-in "overlay diff colors on syntax highlights" primitive among surveyed frameworks.
- Side-by-side rendering in a prose document is awkward at narrow widths; unified hunks embedded in prose with a toggle to a full side-by-side pane is the more realistic default.

### Gaps
- No crate found that specifically renders unified diff hunks with syntax highlighting into ratatui `Text` (tuicr's rendering is app code, not a published widget); `tui-markdown` has no hook to inject pre-styled code blocks — would require forking or post-processing.
- `termimad`, `mdcat`, `bat` were not re-surveyed in this pass (they target ANSI output, not ratatui buffers).

## Key Question 5: Git stack handling (computing branch stacks, Graphite/jj metadata, fetching PR refs, worktrees vs partial clones, sharing node_modules)

### Takeaway
Fetch PRs with `git fetch origin pull/N/head:<branch>` (read-only `refs/pull/` namespace); compute stacks by walking merge-bases from branch tips back to trunk, optionally reading Graphite's `refs/branch-metadata/*` JSON blobs or jj's parent graph; create review checkouts with `git worktree add` on top of one blobless clone, and symlink `node_modules` since worktrees share objects but not ignored files.

### Cited Findings
- GitHub docs: `git fetch origin pull/ID/head:BRANCH_NAME`, then `git switch BRANCH_NAME`; the remote `refs/pull/` namespace is read-only — [GitHub docs: checking out PRs locally](https://docs.github.com/en/pull-requests/how-tos/review-pull-requests/checking-out-pull-requests-locally)
- Graphite stores stack metadata as JSON blobs in the object DB pointed to by `refs/branch-metadata/*`; a plain `git rebase` that removes a recorded base commit can untrack a branch and its children; `gt track` repairs it — [Graphite blog: git key value](https://graphite.dev/blog/git-key-value); [Graphite docs: track branches](https://graphite.com/docs/track-branches.md)
- `git-workon-lib` reads Graphite stacks from `refs/branch-metadata/*` without needing `gt`, and only calls `gt track` when registering new branches — [docs.rs git-workon-lib stack.rs](https://docs.rs/git-workon-lib/0.11.1/src/workon/stack.rs.html)
- jj: `trunk()` resolves to main/master/trunk bookmark or the default remote branch; `jj log -r 'trunk()..@'` shows the stack; `ancestors(x, depth)` limits depth; jj-stack derives stacks from parent relationships walking from a head back to trunk, bookmarks not required per change; change IDs are stable across rebases while commit IDs change — [jj revsets.md](https://git.joshthomas.dev/mirrors/jj/src/branch/patch-1/docs/revsets.md); [jj-stack reference](https://www.serpentine.com/software/jj-stack/reference/bookmarks-and-selection/)
- gix supports merge-base (incl. octopus), revwalk with include/exclude tips, and worktree add, but not partial/blobless clone or checkout orchestration — [gitoxide crate-status](https://raw.githubusercontent.com/GitoxideLabs/gitoxide/main/crate-status.md)
- Worktrees share the object store so adding one is nearly instant, but `.gitignore`d artefacts such as `node_modules` are not shared; `git-worktree-share` symlinks untracked dirs (incl. `node_modules`) from `.git/shared/` into each worktree — [git-worktree-share](https://github.com/keithamus/git-worktree-share); [notes.dsebastien.net](https://notes.dsebastien.net/30+Areas/33+Permanent+notes/33.02+Content/Git+Worktree)
- In a blobless clone, `git fetch` sends only new commits and trees; blobs are fetched lazily at checkout — [GDK issue 1902](https://gitlab.com/gitlab-org/gitlab-development-kit/-/issues/1902)
- A CI discussion of a large repo used a blobless clone and proposed sharing one git dir across fresh worktrees to avoid slow `git clean` — [actions/checkout issue 1718 mirror](https://git.tdem.in/actions/checkout/issues/1718)
- tuicr already supports `tuicr pr 125` and, in PR review, opens "the PR's revision, as a read-only copy if your checkout differs" — [tuicr README](https://raw.githubusercontent.com/agavra/tuicr/main/README.md)

### Inferences
- Stack computation without tool metadata: for each local branch with upstream tracking, compute `merge-base` against every other candidate branch and trunk; a branch B is "stacked on" A if `merge-base(A,B) == A` and A is the nearest such tip. Prefer Graphite's `refs/branch-metadata/*` or `jj log -r 'trunk()..@'` when present because they encode intent, then fall back to the merge-base heuristic. git2 and gix both expose merge-base; `git log --graph` parsing is unnecessary.
- Since neither gix nor libgit2 does partial clones, the tool should shell out to `git clone --filter=blob:none` (or reuse the user's existing clone) and `git worktree add --detach <path> <sha>` for review checkouts; then symlink `node_modules` (and other heavy ignored dirs) from the main checkout so TS7's LSP can resolve dependencies.
- Fetching `refs/pull/N/head` into the *user's* repo is harmless (it does not touch their branches) and lets a worktree be created from the fetched SHA without a temp clone.

### Gaps
- No sources found on git-spr's metadata format (commit-id trailers) in this pass.
- No timing data comparing worktree-add on a blobless clone vs. a fresh partial clone for large repos.

## Key Question 6: Editor integration from a standalone TUI

### Takeaway
Follow lazygit's template model: per-editor command templates with `{{filename}}` / `{{line}}`, a suspend flag, and an `nvim-remote` mode that, when `$NVIM` is set, uses `nvim --server $NVIM --remote-send` / `--remote-tab` to open the file in the parent Neovim instead of nesting; VS Code is `code --reuse-window --goto file:line[:col]` (add `--wait` to block); tuicr simply runs `$EDITOR` (overridable with `editor = "nvim"`).

### Cited Findings
- Neovim: `--server <addr>` connects to a running server; `--remote file.txt` edits a file there; `--remote-send` sends keys (e.g. `nvim --server ~/.cache/nvim/server.pipe --remote-send '<C-\><C-N>:wqa<CR>'`); the `+{cmd}` init command "is not yet supported by Nvim" for remote invocations, so line jumps are done by sending an Ex command after opening — [neovim remote docs](https://neovim.io/doc/user/remote.html)
- `nvr` (neovim-remote) supports `+10`-style line arguments and starts a new `nvim` if the target socket does not exist — [github mhinz/neovim-remote](https://github.com/mhinz/neovim-remote)
- lazygit presets (editor_presets.go): nvim: `nvim +{{line}} -- {{filename}}` with suspend true; nvim-remote: if `$NVIM` unset run `nvim`, else `--remote-send "q"` then `--remote-tab` the file, and for editAtLine additionally send `:{{line}}<CR>`; suspend false when `$NVIM` is set; vscode: `code --reuse-window --goto -- {{filename}}:{{line}}` (`--wait` for the blocking variant); helix: `helix -- {{filename}}:{{line}}`; zed: `zed -- {{filename}}:{{line}}` / `zed --wait` — [lazygit editor_presets.go](https://raw.githubusercontent.com/jesseduffield/lazygit/master/pkg/config/editor_presets.go)
- lazygit config: `os.editPreset` (vim, nvim, nvim-remote, lvim, emacs, nano, micro, vscode, sublime, bbedit, kakoune, helix, xcode, zed, acme), inference from `git config core.editor`, `$VISUAL`, `$EDITOR`; `os.editInTerminal` is really "suspend"; alt/shift-click opens a line in the editor — [lazygit Config.md](https://raw.githubusercontent.com/jesseduffield/lazygit/master/docs/Config.md)
- VS Code CLI: `-g`/`--goto file:line[:character]`, `-r`/`--reuse-window`, `-w`/`--wait` — [VS Code command line docs](https://code.visualstudio.com/docs/configure/command-line)
- lazygit discussion shows a shell script that takes file/line/column and sends a Lua call via `nvr --remote-send` to open at that position in the running Neovim — [lazygit discussion 1956](https://fr.github.com/jesseduffield/lazygit/discussions/1956)
- tuicr: `e` / `:edit` opens the focused file in `$EDITOR`; `editor` config overrides; in PR review opens the PR revision (read-only copy if checkout differs) — [tuicr README](https://raw.githubusercontent.com/agavra/tuicr/main/README.md)

### Inferences
- For a terminal editor (nvim/helix/vim) the TUI must leave raw mode/alternate screen, spawn, and restore (ratatui 0.30's `ratatui::run()` wraps init/restore; manual suspend is needed around the child). For GUI editors (code/zed) no suspend is needed.
- When the review tool is launched from inside Neovim's `:terminal`, `$NVIM` is set and `nvim --server $NVIM --remote-send '<C-\><C-N>:e +{{line}} {{filename}}<CR>'` (or `--remote-tab` + `:{{line}}<CR>` as lazygit does) avoids nested editors; the review tool can also expose an RPC-friendly `--stdout`/JSON mode so a Neovim plugin can drive it, as tuicr's review CLI does.

### Gaps
- Exact `nvim --remote` line-jump syntax not verified beyond lazygit's `:{{line}}<CR>` approach.

## Key Question 7: Distribution (cargo-dist, Homebrew taps, npm wrappers)

### Takeaway
cargo-dist (now "dist", axodotdev) is actively maintained — 0.33.0 on 2026-09-10 — and generates shell/PowerShell installers, a Homebrew tap formula, and an npm package from one config; the npm-wrapper pattern (thin launcher + per-platform `optionalDependencies`) is standard and is also what OpenTUI and Codex use.

### Cited Findings
- cargo-dist releases: 0.33.0 (2026-09-10) added Azure Artifact Signing for Windows; 0.32.0 (2026-05-21) npm installer dropped axios/rimraf, requires Node ≥14.14; 0.31.0 (2026-02-23) "simple" static-mirror hosting; installers listed: shell script, PowerShell, Homebrew, npm — [cargo-dist releases](https://github.com/axodotdev/cargo-dist/releases)
- Repo README: "`dist` (formerly known as `cargo-dist`)"; 3,515 commits, 304 open issues, 50 open PRs, not archived — [github axodotdev/cargo-dist](https://github.com/axodotdev/cargo-dist)
- tuicr ships via install script (curl), Homebrew (`brew install agavra/tap/tuicr`), pacman, Cargo, Mise, Nix, GitHub Release binaries, and a `tuicr update [version]` self-updater (self-replace crate) — [tuicr README](https://raw.githubusercontent.com/agavra/tuicr/main/README.md); [tuicr Cargo.toml](https://raw.githubusercontent.com/agavra/tuicr/main/Cargo.toml)
- npm wrapper pattern: main package with a JS launcher and `optionalDependencies` on `@scope/tool-darwin-arm64`, `@scope/tool-linux-x64`, etc. (as used by SWC/Turbopack/Biome); publish platform packages before the main package; npm versions are immutable so partial-release recovery means publishing only missing platform packages — [skills.sh rust-npm-publish](https://skills.sh/codervisor/forge/rust-npm-publish); [weyaw release docs](https://cdn.jsdelivr.net/npm/weyaw@0.3.8/docs/release.md); [lekoarts.de](https://www.lekoarts.de/publishing-a-rust-cli-on-npm/)
- Codex CLI versions each platform tarball as `<version>-<platform-tag>` and points optionalDependencies at dist-tags via npm alias syntax — [Codex CLI scripts](https://upd.dev/layers/codex/src/branch/main/codex-cli/scripts)
- `@opentui/core` itself uses the same optionalDependencies platform-package layout (8 platform packages) — [npm @opentui/core](https://registry.npmjs.org/@opentui/core/latest)
- `gh auth token` prints the active account's token (`--hostname`, `--user` flags) — [gh manual](https://cli.github.com/manual/gh_auth_token)

### Inferences
- Relative effort (Rust): cargo-dist config + GitHub Actions ≈ a day; Homebrew tap is generated by dist; npm wrapper is also generated by dist's npm installer, so all three channels come essentially free once dist is set up. Go gets the same from goreleaser. TS/Bun: `bun build --compile` per platform + npm optionalDependencies, with much larger artifacts.
- GitHub auth: shelling out to `gh auth token` (or honoring `GH_TOKEN`/`GITHUB_TOKEN` like go-gh) is how tuicr-style tools reuse the user's login; tuicr requires an authenticated `gh` for GitHub submission.

### Gaps
- No source found quantifying cargo-dist npm-installer adoption or pitfalls specific to TUI binaries.

## Key Question 8: Review-state persistence and LLM API access (brief)

### Takeaway
tuicr demonstrates the persistence model (session files created when a review target becomes active, listed via `tuicr review list`, readable through a `ReviewStore` Rust API); LLM calls need only an HTTP client (tuicr uses blocking `ureq` 3, avoiding tokio entirely), though a TUI that streams model output will want an async runtime or a worker thread.

### Cited Findings
- tuicr persists reviews as session files, removed on exit if empty; `tuicr review list`; `ReviewStore` API for reading/writing — [tuicr README](https://raw.githubusercontent.com/agavra/tuicr/main/README.md); [lib.rs tuicr](https://lib.rs/crates/tuicr)
- tuicr dependencies include `ureq` 3 (json), `serde_json`, `toml` 0.8, `directories` 6.0, `uuid` 1 (v4), `sha1` — i.e. no tokio/reqwest — [tuicr Cargo.toml](https://raw.githubusercontent.com/agavra/tuicr/main/Cargo.toml)
- yazi uses tokio 1.54 with a scheduler crate for background work; gitui uses an `asyncgit` crate with crossbeam channels and rayon-core for off-thread git — [yazi Cargo.toml](https://raw.githubusercontent.com/sxyazi/yazi/main/Cargo.toml); [gitui Cargo.toml](https://raw.githubusercontent.com/gitui-org/gitui/master/Cargo.toml)

### Inferences
- A review-state file per (repo, target) keyed by content hash (tuicr uses sha1) in a `directories`-resolved data dir, serialized with serde (TOML/JSON), is the proven pattern; adding guide-document state (which hunks were read, comments anchored to file+line+hash) is a straightforward extension.
- The LSP client needs an event loop reading the server's stdout; the LLM streaming client and git/LSP work should live on a tokio runtime or dedicated threads feeding the ratatui event loop via channels (gitui's asyncgit and yazi's scheduler are the reference designs).

### Gaps
- No primary source examined tuicr's on-disk session format or location.
