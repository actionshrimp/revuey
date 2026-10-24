# revuey

[![test](https://github.com/actionshrimp/revuey/actions/workflows/test.yml/badge.svg)](https://github.com/actionshrimp/revuey/actions/workflows/test.yml)

Code review inside Neovim (>= 0.12). It shows a composed unified diff of the current branch
against its base, or of one layer of a local branch stack (or the whole stack) before you push. Tree-sitter syntax is projected onto the diff lines, LSP go-to-definition and hover
work from inside the diff (your own LSP mappings and pickers too), and "reviewed" marks persist. An [AI guide](#ai-guide) (your own `claude`
CLI) can reorganise the review into ordered, explained sections. [Comments](#comments) on lines,
ranges or files show inline as threads and export as Markdown for an AI session; coding agents
read them, follow them live and reply from the shell. You can also [send a comment or question to
a coding agent](#connect-an-agent) (Claude Code) without leaving the review, and its answer lands
in the comment's thread. Design notes:
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Install (lazy.nvim, local checkout)

```lua
{
  dir = '~/dev/revuey/main',
  cmd = { 'Revuey', 'RevueyClose', 'RevueyStackParent', 'RevueyStackIgnore', 'RevueyGuide', 'RevueyGuideDiagram', 'RevueyComments', 'RevueyCommentsExport' },
  opts = {
    -- default_branch = 'develop', -- default: origin/HEAD, else main, master, develop
    -- ai = { model = 'sonnet' }, -- AI guide; default: Claude Code's default model
    -- stack = { ignore_branches = { 'dave/old-*' } }, -- hide notes about these branches
  },
}
```

`setup()` is optional. All options and their defaults are in `lua/revuey/config.lua`
(`context_lines`, `fold_context_threshold`, `collapse_large_files`, `panel_width`, `lsp_warmup`,
`lsp_settle_ms`, `lsp_proxy`, `word_diff`, `state_dir`, `stack`, `keymaps`, `comments`, `ai`, `forge`,
`log_file`).

Requirements:
- `git`.
- Tree-sitter parsers *and highlight queries* for the languages you review (for example
  typescript/tsx via nvim-treesitter). Without them the diff still works but has no syntax colours.
- An LSP configured for the filetype (for example `ts_ls`) for `gd`, `K` and your own LSP mappings.
- For the AI guide only: [Claude Code](https://claude.com/claude-code) (`claude`) on `PATH`, logged in.
- For [pull request status](#pull-requests) only: [`gh`](https://cli.github.com) on `PATH`, logged in.
- For [`:Revuey pr`](#reviewing-a-pull-request-worktrunk) only: [worktrunk](https://worktrunk.dev) (`wt`) and `gh`.

## Commands

| Command | |
|---|---|
| `:Revuey` | Review the current branch, uncommitted work included. If the branch is part of a local stack, the review opens at its layer with the stack shown (see [Stacks](#stacks)); otherwise it diffs `merge-base(default branch, HEAD)` against the working tree, skipping commits at the bottom that the default branch already has as squash merges. |
| `:Revuey --stack` | The whole stack: trunk merge-base to the top of the stack. |
| `:Revuey <base>` | Single-branch review against `base`, exactly as before (no stack detection). `:Revuey <base> --stack` uses `base` as the stack's trunk. |
| `:Revuey ... --committed` | Committed changes only (`merge-base..HEAD`). |
| `:Revuey pr <N\|url>` | [Review a pull request](#reviewing-a-pull-request-worktrunk) in its own worktree: worktrunk's `wt switch pr:<N>` sets it up (your hooks install and build it), then the review opens there in a new tab. `:Revuey pr cancel` stops the setup. |
| `:RevueyStackParent [branch]` | Set the stack parent of the layer being reviewed (or of the current branch). `--clear` removes the override. No argument: pick from a list, which also offers "clear override". |
| `:RevueySwitch [layer]` | Check out a stack layer in this worktree (`git switch`), like `gS`: the named layer (its branch name, or a remote layer's name without the remote), or the one being viewed. See [Checking out a layer](#checking-out-a-layer). |
| `:RevueyStackIgnore [pattern]` | Hide [stack notes](#stack-notes) about branches matching a glob (`*` matches anything, `/` included), in this repo. No argument: list the ignore list. `:RevueyStackIgnore! pattern` removes a pattern. |
| `:RevueyGuide` | Switch between the diff and the [AI guide](#ai-guide) view. With no guide yet, offers to generate one. |
| `:RevueyGuide!` | Generate a new guide (in the background) and show the guide view. |
| `:RevueyGuide cancel` | Stop a running generation. |
| `:RevueyGuideDiagram mermaid [reg]` | Copy the guide's [overview diagram](#ai-guide) as Mermaid flowchart text to a register (default `+` when Neovim has a clipboard, else `"`). |
| `:RevueyAIReview [skill]` | Run an [AI review](#ai-review) of the review (in the background): its findings become AI comments to accept or dismiss. `skill`: a skill name or path whose `SKILL.md` guides it. Asks first when untriaged findings of the last one would be replaced; `:RevueyAIReview!` does not. |
| `:RevueyAIReview cancel` | Stop a running AI review. |
| `:RevueyComments` | All [comments](#comments) of the review in a float; `<CR>` jumps to one. |
| `:RevueyCommentsExport [markdown\|json] [--all] [reg\|file]` | Export the comments (default: Markdown to the `+` register when Neovim has a clipboard, else `"`). A one-character argument is a register, anything else a file. `--all` includes resolved comments and drafts. |
| `:RevueyClose` | Close the review tab. |
| `bin/revuey [args]` | Shell wrapper taking the same arguments as `:Revuey`: starts `nvim` with your config and the review; `q` quits. It finds the plugin relative to the script (or via `$REVUEY_PLUGIN_DIR`), so nothing needs installing. `$REVUEY_NVIM` picks the nvim binary (`$NVIM` is ignored because inside `:terminal` it is a socket). |
| `bin/revuey pr <N\|url>` | The same from the shell: `wt switch` runs in your terminal (its output, its approval prompt), then Neovim opens with the review in the worktree. |
| `bin/revuey comments\|watch\|reply` | [Comments for coding agents](#comments-for-coding-agents), from the shell, without the UI. |
| `bin/revuey sessions\|watch --messages\|show\|ack\|inbox\|comment\|install-skill` | [Connect an agent](#connect-an-agent) to a running review. `bin/revuey --help` describes every command. |
| `bin/revuey hunks\|import-review` | [AI reviews from outside](#ai-reviews-from-another-agent-or-tool): the hunks with their ids, and importing a review in revuey's format. |

**Uncommitted work is included by default** (working-tree mode): committed, staged and unstaged
changes to tracked files, files deleted on disk, and untracked (non-ignored) files as additions.
Files with uncommitted changes get a `●` in the panel, whose header shows the mode. `gu` switches
to committed-only mode (`merge-base..HEAD`) and back. In working-tree mode the review refreshes
itself when you write a file in the repo (debounced), when Neovim regains focus, and when you
re-enter the diff window after files changed; cursor, scroll, folds and reviewed marks are kept.
Reviewed marks are keyed by content (each hunk by its lines), so a mark made in either mode counts
in the other when the content is the same (and survives `git add`), and editing a hunk clears only
that hunk's mark. Untracked
symlinks show their link text like git; nested repositories and files or diffs over
`max_file_bytes` (default 1 MB) are listed with a "not shown" placeholder and never read. Refreshes
only re-read files whose size/mtime changed.

LSP requests go through the working-tree buffer. Lines are mapped between the review and the
buffer by position (through a diff when the buffer has unsaved edits, or in committed mode when the
file has uncommitted changes); when a definition isn't shown in the diff, the real file opens.

**Your own LSP mappings work in the diff and the guide.** Review buffers get an LSP client named
`revuey` (you will see it in `:checkhealth vim.lsp` and in statuslines). It supports definition,
type definition, declaration, implementation, references and hover, and nothing else (no
diagnostics, completion, formatting, inlay hints or code actions). Each request is sent to the
real language server of the file under the cursor, so `vim.lsp.buf.definition()`,
`vim.lsp.buf.references()`, `<C-]>` and pickers built on LSP requests work unchanged, and a
review with several languages routes each line to its own server. Results point at the real files.
A jump that would replace the diff (any jump in the current window, a quickfix entry, a picker
selection) opens in the code window below instead (or a new tab when there is no room for a
split), and the review stays where it was. Tested with snacks.picker, which is pointed at the
review window (`vim.b.snacks_main`); pickers that open selections in the window they were started
from (Telescope, fzf-lua) should behave the same when started from the diff. The file panel window
is `winfixbuf`, so a picker never replaces it. `<C-o>` in the code window that would show the
review there takes you back to the review window instead. Deleted lines and filetypes without an
LSP give one message and an empty result. Revuey's own keys (`gd`, `K`, `]]`...) are put back
after your `LspAttach` handlers run, so `gd` still jumps inside the diff when the definition is
shown there. `lsp_proxy = false` turns the client off.

Line-ending-only changes (LF/CRLF) and a missing final newline are marked with a `⏎` note at the end
of the line.

## Editing from the review

`ge` on a hunk line (an added or context line, or the `@@` header) in the diff or the guide opens
the real working-tree file in a float near the cursor, on that line, folded to the hunk plus 3
lines of context (`zo`/`zR` show the rest; the folds are manual and belong to the float only).
The title names the file and the hunk's line range. It is the file's own buffer, the one `:edit`
gives you (if the file is already open, that same buffer, unsaved edits included; never a second
one), so undo, completion, LSP, formatters and your autocmds work as usual.

- `:w` or `<C-s>` (normal mode; insert-mode `<C-s>` stays signature help) saves. The review
  refreshes as for any write, and its cursor moves to the line you were editing, or the nearest
  hunk when that line is no longer in the diff.
- `q` closes the float. With unsaved changes it asks: save, discard (only the changes made in the
  float are undone) or cancel. `:q` closes it like any window, keeping unsaved changes in the
  buffer. Closing the review closes the float the same way. `<Esc>` is left alone.
- The float's `q` and `<C-s>` are buffer mappings that only act in the float; mappings of yours
  they shadow come back when it closes, and so do the window options the buffer had.
- If another Neovim is editing the file (it has a swap file), the float does not open and says
  so.
- On a deleted (`-`) line the float opens at the nearest new-side line and says deleted lines
  can't be edited. Prose, the diagram, file headers and notes say there is nothing to edit.
- If the file changes on disk while the float is open, Neovim's usual `:checktime` warning (W12
  when you also changed it) applies.

Only the checked-out layer (`@`) in working-tree mode can be edited; everything else refuses with
how to get there: "`stack/math` isn't checked out; press gS to switch" on another layer (remote
`ro` layers included), "switch to working-tree mode (gu)" in committed-only mode. A remote `ro`
layer stays read-only even with HEAD detached at its tip (there is no branch to commit to): `gS`
checks out a local branch for it first. In the full
stack, a hunk can be edited when the top layer is checked out and the hunk's [branch
label](#ai-guide) names only that layer (or uncommitted work); hunks from lower layers name the
layer to switch to. Edits always land in the working tree: revuey makes no fixup commits for
lower layers and never restacks.

In the guide, an edited hunk stays in its section with an "✎ edited since guide" marker instead
of moving to "Not in guide" (see [When the code changes](#ai-guide)); its reviewed mark resets, as
for any change. Comments on edited lines move or become outdated by the usual rules.

`keymaps = { edit = false }` turns the key off.

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
- **Squash-merged commits under the bottom layer** (lower PRs merged, the branch not restacked
  onto trunk): commits at its bottom that trunk already has, one squash per run of commits and
  not reverted since, are left out of its diff and the full scope, with a note, so it shows what
  its PR shows (a `⚠ … skips N commits already in main` note). A layer that landed entirely keeps
  its own squash-merged commits, and its "looks landed" note mentions the skipped ones. The same
  applies to a lone branch once the lower branches are deleted and no stack is left. Squashes
  that needed conflict resolution, or that a later trunk change touches within a line, don't
  match, and the diff is unchanged.

The guess cannot tell a parent from a child branch cut part-way through it, so it is only a
suggestion and nothing guessed is ever saved. If a stack looks wrong, fix it with
`:RevueyStackParent`.

The file panel gets a stack section at the top: the layers from trunk up, each with commits,
files changed and fully reviewed files (`2c 3f ✓1/3`; a file counts once every hunk of it is
reviewed), `@` on HEAD's branch and `▶` on the reviewed
scope, then a **full stack** row, then a few short [stack notes](#stack-notes).

- **Layer scope** (default): parent tip to layer tip. Uncommitted work belongs to the HEAD layer
  only. Other layers are committed-only, and `gu` says so.
- **Full stack scope:** trunk merge-base (after any skipped squash-merged commits) to the top. It includes the working tree only when HEAD
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

With a single branch and no stack, everything behaves exactly as before (apart from the
related-branch notes below).

### Checking out a layer

Layers are views: `]s`/`[s`, `gs` and `<CR>` on a layer row never touch your worktree. To work on a
lower layer, `gS` (on a layer row in the panel, or in the diff for the layer being viewed) or
`:RevueySwitch [layer]` checks it out in the current worktree with plain git:

- **A local branch:** `git switch <branch>`. Detached at a layer's tip, this attaches HEAD to it.
- **A remote-only layer** (`origin/x`, `ro`): a local branch tracking `origin/x` is switched to;
  otherwise `git switch --track origin/x` creates `x`. Marks, comments and guides made on
  `origin/x` belong to `x` (state keys drop the remote). If a local `x` exists that tracks
  something else or nothing, revuey never changes it: it says so and offers to switch to that
  `x` anyway, or cancel.
- **Already on it:** nothing happens (a message says so).
- **Refused, with the reason:** uncommitted changes to tracked files (staged or not; a few are
  named, revuey never stashes); unsaved buffers of files in the worktree (a later `:w` would write
  the old branch's text onto the new one); untracked or ignored files where the switch writes a
  file (git would refuse the first and silently overwrite the second; they are named); a branch
  checked out in another worktree (its path is named). Other untracked files are carried over, as
  git does, and show up in the new layer's working-tree review. Submodules are left out of the
  check: `git switch` leaves submodule checkouts as they are, so run `git submodule update` when a
  layer bumps one.
- **An agent connected to the review** (`● agent connected`): revuey asks first, since switching
  branches changes the files under an agent that may be working.
- **One at a time:** a `gS` (or `]s`) while a switch runs is dropped with a message.

Afterwards the review refreshes: the layer gets `@`, the working tree and the `●` markers, and the
view stays on it (cursor and folds as you left them). The session registry records the new branch
(`checked_out`, shown by `bin/revuey sessions`) for agents. revuey's hidden LSP buffers reload (or
are dropped when the file is gone), then `:checktime` runs, so your own buffers follow your
`autoread` setting. A failing `post-checkout` hook gives a warning, but the switch happened and
the review follows it. revuey never restacks: after committing on a lower layer, the layers above
show the usual "not restacked" note.

On a local branch, remote-tracking branches are layers only when a parent setting names them.
So checking out a layer whose layer below is remote-only (`gS` on `origin/stack/cart` above
`origin/stack/math`) records `branch.stack/cart.revueyParent = origin/stack/math`, which keeps
that layer below (deleting the branch removes the setting). A parent setting that already exists
(yours, or an earlier switch's) is never changed: when it differs, a message says what the stack
has instead. Nothing is recorded when that layer is not an ancestor of the branch (a local copy
behind a restack of the remote stack). If the remote branch a parent setting names is deleted or
pruned, a note says so (`:RevueyStackParent --clear` removes the setting). The remote layers *above* it are not
shown while you are on the branch: review from a detached worktree to see the whole remote stack.

`stack = { switch_on_navigate = true }` makes `]s`/`[s` switch too, with the same checks (an
agent confirmation is asked once per review); when a switch is refused the view still moves, and a
message says the branch did not.

### Someone else's stack (no local branches)

To review a colleague's stacked PRs you don't need a local branch for every PR. Fetch first
(revuey never fetches; it uses the remote-tracking branches you have), then review from a
worktree detached at the top PR:

```sh
git fetch origin
git worktree add --detach ../review-their-stack origin/their-top-branch
cd ../review-their-stack && revuey
```

- **Only with a detached HEAD:** on a local branch, remote-tracking branches are never layers, so
  your own branch is never split by copies of it on a remote (a backup or older push under another
  name, a PR ref, a colleague's branch started from yours, a fork's upstream). The one exception is
  a parent you set explicitly (`:RevueyStackParent origin/<name>`, or Graphite metadata naming a
  branch you only have as `origin/<name>`): that remote branch becomes the layer below. So to
  review a colleague's stack from a local branch tracking its top, detach instead, or set its
  parent. [`gS`](#checking-out-a-layer) sets that parent for you when it creates a branch for a
  remote layer.
- **Remote-tracking layers below HEAD:** a branch under `refs/remotes/<remote>/` counts when its
  tip is on HEAD's first-parent line between `merge-base(trunk, HEAD)` and HEAD, and no remote's
  default branch (`origin/main`, `upstream/main`, ...) contains it. Remote branches above HEAD or
  on other lines are never used, nor are `<remote>/HEAD`, the trunk, PR-head mirrors (`*/pr/*`,
  `*/pull/*`), copies of the checked-out branch (its upstream and push ref, refs at their
  commits, refs named `*/<branch>`, when detached at a branch) and branches on the [ignore list](#stack-notes) (for remote
  branches it does keep them out of the stack). This is one ref listing plus set lookups, so
  thousands of remote branches cost next to nothing.
- **Local wins:** a local branch at the same commit, or a local copy of the branch (tracking it,
  or with the same name) on that line, is the layer instead. Several remote branches at one commit: the
  branch a parent setting names, then the one shown there before (kept per repo in the state dir,
  so reopening with a new `origin/aaa-backup` at that commit keeps the name and its marks), then
  `origin`, then alphabetical; the rest are listed as at the same
  commit. Explicit parents (`:RevueyStackParent`, Graphite) may name a branch you only have as
  `origin/<name>`.
- **Detached HEAD** at a branch tip (local first, else remote-tracking) uses that branch as the
  current layer, marked with a dim `@` and a `detached HEAD at …` note listing any other branches
  there. Detached at no branch: no stack, and a note says why.
- **Shown dimmer, with `ro`:** remote-only layers keep their `origin/` prefix and are read-only
  (`committed only (remote, read-only)`; `:RevueyStackParent` refuses them).
- **Marks carry over:** state keys drop the remote, so reviewed marks, comments and guides made on
  `origin/feat-x` belong to a local `feat-x` created later (or one tracking it). If you already
  have an unrelated local `feat-x`, or two remotes' branches with the same name are both layers,
  the remote layer keeps its full name as its key. A detached HEAD with no branch at it is still
  keyed `HEAD`; reviews made detached at a branch tip before this feature were keyed `HEAD` too,
  and now key by that branch's layer (their old marks and comments are not migrated).
- When your checked-out branch differs from its fetched remote copy, a note says how far it is
  ahead or behind (not for a branch that tracks the trunk).
- `bin/revuey comments`/`watch` in a detached worktree use the live review's scope, or else the
  branch the review would pick.

### Stack notes

Detection reports what it noticed as notes. The panel shows at most three short lines, one per
kind, for example:

```
 ⚠ stack/b not restacked on stack/a
 ○ 3 related branches outside this stack (2 ignored)
 ● stack/a looks landed in main
```

Notes that change the diff you see use the warning colour (`RevueyStackWarn`). The rest are
dim (`RevueyStackNote`) and don't affect the review.

| Note | Affects the diff? |
|---|---|
| Not restacked (a layer is still on its parent's old tip) | yes: the layer shows only its own commits |
| Commits already in trunk are skipped (squash-merged lower branches; a layer that landed entirely says so in its "looks landed" note instead) | yes: the diff leaves them out, wrongly if the match is wrong |
| Parent setting out of date (explicit parent that isn't an ancestor) | yes: compared with trunk instead |
| Parent setting names a missing branch | yes: the parent is guessed instead |
| Parent settings form a loop | yes: compared with trunk instead |
| Built on an old version of another branch (that branch has newer copies of commits at the bottom of your stack, like a parent amended without restacking) | maybe: old commits of that branch can show up |
| Shares commits with your stack (no reflog links it; perhaps a parent that moved on) | maybe: its commits can be part of the layer's diff |
| Related branches outside the stack (`○`): an outdated copy of your stack, another version of a stack commit (backports, backups, clock skew), side branch | no |
| Looks landed, the stack stops at a fork, detached HEAD, ahead of or behind its fetched remote copy, same commit as a layer, parent already merged | no |

`!` in the panel or the diff opens a float with every note in full: what it means, why it
matters (or that it doesn't affect this review), and the branches involved, grouped by kind.
On a branch row:

- `p` sets that branch as the parent of the layer it relates to (`:RevueyStackParent` for that
  layer). It is offered only when the branch tip is an ancestor of the layer, so the setting
  holds; otherwise the fix is to rebase, as the note says.
- `c` clears an out-of-date parent setting made with `:RevueyStackParent`.
- `x` ignores the branch; `X` ignores a pattern, prefilled from the branch: up to a ticket
  number (`dave/abc-1058-apply-price-check` suggests `dave/abc-1058-*`), else up to the last
  `-`, never just `dave/*`. The prompt says how many branches the suggestion matches when it is
  more than three.
- `u` on an ignored pattern stops ignoring it. `<CR>` lists the row's actions; `q` closes.

The panel and the float refresh after each action.

**Ignore list.** Patterns are globs: `*` matches any characters (including `/`), `?` one
character, and `**/x` also matches `x`. Each repo has its own list, kept in the state dir (`stack-ignore-*.json` next to the
reviewed marks; an unreadable file is kept as `.corrupt-*`), so nothing is written to your repo. All worktrees of a repo share it. Patterns in
`setup({ stack = { ignore_branches = { 'dave/old-*' } } })` apply everywhere and can only be
removed in your config. Ignoring hides informational notes about branches outside the stack
(related branches and other branches at a layer's commit); warnings that can change the diff are
never hidden. It never changes which local branches are layers (it does keep matching
remote-tracking branches out of the stack): an ignored local branch that is a layer stays one, and notes about layers (not restacked, parent settings, forks,
landed) are always shown. The summary line counts what is hidden, e.g. `(2 ignored)`.

## Pull requests

When a layer (or a plain review's branch) has a pull request on GitHub, the panel shows its number
and review state on the layer's row, and a section with the details of the layer you are viewing:

```
 Stack: 3 layers on main
    stack/math     #41 merged 1c 1f ✓0/1
 ▶@ stack/cart          #42 ✗ 2c 2f ✓0/2
    stack/ui        #43 draft 1c 2f ✓0/2
    full stack                4c 4f ✓0/4

 ▾ PR #42                              ✗
   Cart totals with discounts
   by alice · open
   ✗ changes requested
     ✗ carol changes requested
     ✓ dan approved
     ○ bob requested
   checks: 12 passed, 1 failed, 2
   pending
   mergeable
   base: stack/math
```

- Row chips: `✓` approved (`RevueyForgeApproved`), `✗` changes requested (`RevueyForgeChanges`),
  `●` review required (`RevueyForgePending`), `○` no review decision (`RevueyForgeNone`); drafts,
  merged and closed PRs are dim with `draft`, `merged` or `closed`. A dim `?` (and `(stale)` on
  the detail heading) means the last lookup failed and this is the previous result. In a narrow panel the branch name is cut first, then the
  commit count. A review without a stack shows the chip on its `branch → base` line.
- The detail section has the title, author, state, the review decision, each reviewer's latest
  review and the reviewers still requested, check counts, mergeability and the base branch. When
  an open PR's base is not the layer's parent in revuey's stack (GitHub and the local stack
  disagree), it says so: `⚠ GitHub base main, stack parent stack/cart`. `<Tab>` on its heading
  folds it. There is none in full-stack scope.
- `gx` in the panel opens the PR in your browser (`vim.ui.open`): on a layer row, that layer's PR,
  anywhere else the viewed layer's. (`go` already opens files in the diff.)
- **Lookup.** One `gh api graphql` call per refresh covers every layer, by head branch name: a
  remote layer `origin/x` is looked up as `x`; a local branch by its own name, then its push
  target's name, then its upstream's name when that differs (never the trunk: a branch made with
  `git switch -c feat origin/main` is still looked up as `feat`). The base repo is found like gh
  does: the remote `gh repo set-default` marked (`remote.<name>.gh-resolved`), else `upstream`,
  else the trunk's remote, else `origin` (`git remote get-url`, SSH or HTTPS). Unless the base came
  from `gh-resolved` or `upstream`, each lookup also asks the repo's parent, so a fork cloned as
  `origin` with no `upstream` remote still finds PRs in the parent. PRs from other people's forks with the same branch name are skipped (head
  owner). An open PR wins, then the most recently updated merged or closed one, but only when
  its head commit and the branch tip are on one line (either is an ancestor of the other, so a
  branch behind commits made on GitHub still shows its PR), so a new branch reusing an old name
  doesn't show the old PR. Hosts other than github.com need `forge.hosts` (hosts with
  "github" in their name are recognised).
- **When.** On open and on scope switches, in the background, with results cached per repo for
  `forge.ttl` seconds (60). `R` always looks again. There is no polling: a panel redraw after the
  TTL looks again. One lookup runs at a time per review; `gh` is stopped after `forge.timeout`
  seconds (15) and when the review closes, and a lookup that ends after that is ignored.
- **Failures are quiet.** No `gh`, not logged in, offline, timed out, rate limited or unexpected
  output: nothing new is shown (PRs already shown stay, marked stale), and the reason is written
  to the log file (`log_file`, default `stdpath('log')/revuey.log`, moved to `revuey.log.1` at
  256KB). Repos without a GitHub remote make no call at all.

```lua
require('revuey').setup({
  forge = { enabled = true, ttl = 60, timeout = 15, cmd = 'gh', hosts = { 'git.example.com' } },
  keymaps = { forge_open = 'gx' },
})
```

## Reviewing a pull request (worktrunk)

`:Revuey pr 123` (or a PR URL) from inside a clone of the repo reviews that pull request in its
own worktree, set up by [worktrunk](https://worktrunk.dev) exactly as `wt switch pr:123` would in
your shell, so your worktrunk hooks install dependencies and build it first:

1. revuey runs `wt switch pr:123 --no-cd --format json` in the background, in the clone's root.
   worktrunk asks GitHub (through `gh`) for the PR's branch, fetches it (fork PRs too), creates
   the worktree (at your `worktree-path`, by default `../<repo>.<branch>`) or finds the one it
   made before, and runs the `pre-start` hooks. Progress shows as a progress message (wt's latest
   line and the time so far); `:Revuey pr cancel` (or cancelling the message in a UI that offers
   it) stops wt and the hooks it started.
2. When `wt switch` returns, the review opens in a new tab whose working directory is the
   worktree (`:tcd`, so pickers, `:edit` and terminals there work in the PR's tree; other tabs
   keep theirs, and `:RevueyClose` closes the tab). Only then do revuey's LSP buffers load, so
   tsserver starts on a tree the hooks already built. The review is the usual one for the PR's
   branch: the stack is detected as for any branch (local branches below it are layers), and the
   [PR status](#pull-requests) section warns when GitHub's base differs from the stack parent.
   Building the layers from the PR's base chain on GitHub is not done yet.
3. A URL must name this clone's GitHub repo (worktrunk looks the number up in the clone's repo
   whatever the URL says, so revuey refuses a URL from another repo instead of opening a
   different PR). worktrunk's own errors are shown as it words them: `gh` missing, no GitHub
   remote, an unknown PR, a failed hook.

**Approvals.** worktrunk asks before running a repo's *project* hooks (`.config/wt.toml`) the first
time, and again when they change; in the background it cannot ask and refuses. revuey never
passes `--yes`: it shows the commands and offers to run the same `wt switch` in a terminal split,
where you answer worktrunk's own prompt (or decline: worktrunk then skips the project hooks); the
review opens when it succeeds. You can also approve beforehand with `wt config approvals add` in
the clone. Hooks in your user config (`~/.config/worktrunk/config.toml`) need no approval.

**A failed hook** leaves the worktree behind (worktrunk does not remove it); the message names it.
`:Revuey pr` again opens it as it is, since `pre-start` only runs when the worktree is created:
re-run the hooks with `wt -C <path> hook pre-start`, or remove the worktree.

**Cleanup** is yours; revuey never removes worktrees. Close the review first (its language
servers run in the worktree), then `wt remove <branch>` (or the worktree's path) removes the
worktree, and the branch too when it is merged (`--no-delete-branch` keeps it, `-D` deletes an
unmerged one). `wt list` shows them all.

From the shell, `bin/revuey pr 123` does the same, with `wt switch` running in your terminal
(its output as it happens, its approval prompt, `^C` to stop), then starts Neovim with the review
in the worktree.

### Up-to-date builds for the LSP (TypeScript)

In TypeScript monorepos, workspace packages often point `types`/`exports` at `dist/`, so tsserver
is wrong or empty until the tree is built. Build in a worktrunk **`pre-start`** pipeline:
`pre-start` hooks block, so `wt switch` (and so `:Revuey pr`) returns with the tree installed and
built, and the review's LSP starts on it. `post-start` hooks run in the background after `wt
switch` has returned, so tsserver would start (and cache its view of `dist/`) while the build is
still running.

```toml
# .config/wt.toml (project hooks: shared with the repo, approved once per change)
# or ~/.config/worktrunk/config.toml (user hooks: no approval)
[[pre-start]]
install = "pnpm install --frozen-lockfile"

[[pre-start]]
build = "pnpm -r build"   # or: npx tsc -b, npx turbo run build

[post-start]
copy = "wt step copy-ignored"   # anything that may finish later (caches, dev servers)
```

Each `[[pre-start]]` block is one step and a failing step stops the rest; keys within a block
run concurrently. Incremental builds (`tsc -b`, turbo) keep later runs cheap.

**Build-free alternative,** for repos that can change: let tsserver read the packages' sources
instead of `dist/`.

- A `source` export condition in each workspace package, plus `customConditions` in the
  tsconfig the editor uses (TypeScript 5.0+, `moduleResolution` `bundler`, `node16` or
  `nodenext`); builds and consumers outside the repo keep resolving `dist/`:

  ```jsonc
  // packages/ui/package.json
  "exports": {
    ".": { "source": "./src/index.ts", "types": "./dist/index.d.ts", "default": "./dist/index.js" }
  }
  // tsconfig.json (or a tsconfig.base.json the packages extend)
  "compilerOptions": { "customConditions": ["source"] }
  ```

- Or TypeScript project references (`composite: true`, `references` between packages) with
  `declarationMap: true`: tsserver then maps a reference's `.d.ts` back to its source for
  go-to-definition, and loads referenced projects from source while editing (unless
  `disableSourceOfProjectReferenceRedirect` is set).

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
- `<Tab>` on a section heading (or the diagram's "Overview" heading) collapses / expands it; on a
  hunk's `path  @@ … @@` header it collapses / expands that hunk. `<S-Tab>` collapses the diagram
  and every section (or expands them all). A collapsed diagram stays collapsed across refreshes.
  Elsewhere `<Tab>` is `<C-i>` as in the diff.
- `mr` on a section heading (or its prose): mark every hunk of the section reviewed (or unmark
  them all when they all are). It folds, and the cursor moves to the next section that is not
  reviewed. On a hunk header or inside a hunk: that hunk only; it folds and the cursor moves to
  the next unreviewed hunk. Visual `mr` marks every hunk the selection touches.
- Marks are shared with the diff view: a hunk marked in the guide counts in the diff, and a file
  marked in the diff ticks off its hunks in every section that shows them. A section is reviewed
  when all of its hunks are: the heading shows `☑ … ✓ reviewed`, or `◐ 1/3` while partly reviewed,
  and so does the panel's section list (`✓`, `◐`); the guide header counts fully reviewed
  sections. Marks follow the hunks' content, so they survive regenerating the guide.

**Overview diagram.** When the structure is worth seeing (several modules calling each other, a
data flow, a new component wired into existing ones), the guide starts with a small diagram
below the summary. Claude only names the nodes (modules or concepts, each new, changed or
context) and edges; revuey lays them out and draws them with box-drawing characters, because
models align box art badly:

```
╭─────────────────╮    ╭─────────────────╮
│ main (index.ts) │    │ Total component │
╰────────┬────────╯    ╰────────┬────────╯
         │                      │
         ╰────────╮  ╭──────────╯
          total() │  │ total()
                  ▼  ▼
                ╭──────╮
                │ Cart │
                ╰───┬──╯
                    │ sum, multiply
                    ▼
               ╭─────────╮
               │ math.ts │
               ╰─────────╯
```

Boxes are coloured by kind (`RevueyDiagramNew`, `RevueyDiagramChanged`, `RevueyDiagramContext`).
The drawing is redone when the window is resized; when it can't fit, it becomes a list
(`index.ts ──new Cart──▶ cart.ts`). `<CR>` on a box jumps to the section that covers it, and
`<Tab>` (or `<CR>`, `za`) on the "Overview" heading folds the diagram. `:RevueyGuideDiagram mermaid`
copies it as Mermaid text. Small changes get no diagram. The diagram uses the full window
width (prose is capped at 100 columns). It assumes `ambiwidth=single`: box-drawing characters
are ambiguous-width, so with `ambiwidth=double` the boxes misalign (the list form still reads).

**Branch labels (full stack).** In the full-stack scope each hunk header shows, right-aligned,
the branch that introduced it, for example `[stack/cart]`, or several (`[stack/cart, stack/ui]`)
when more than one branch changed those lines; working-tree changes show `[uncommitted]`. The
labels appear in the guide and in the full-stack diff view, and Claude gets the same tags in the
prompt, so the prose can say which branch introduced what. Layer scopes have no labels.

**When the code changes** after the guide was generated, sections whose hunks are unchanged
render as before. A hunk edited in place (with [`ge`](#editing-from-the-review) or anywhere
else) stays in its section with an "✎ edited since guide" marker on its header: it is matched to
the guide's hunk when it overlaps that hunk's old or new line range in the same file and its
function context (after `@@ … @@`) agrees. Matching is conservative: when an edit splits a guide
hunk in two, or joins hunks of different sections, nothing is matched. Two hunks of one section
joined by an edit show as one edited hunk. A section with missing hunks gets an "outdated" chip
and shows only the hunks that still exist. New hunks go to a final "Not in guide" section, and a
banner (counting outdated sections, new and edited hunks) offers `gR` to regenerate. The guide
never re-runs by itself.

**Per scope:** each review (branch and base, or a stack layer, or the full stack) has its own
guide. Switching layers keeps a generation running for the layer it was started on. The guide's
winbar names its scope ("Guide · layer stack/cart", "Guide · full stack"). For a layer, Claude is
told the review covers only that branch's changes on top of its parent, so it says "this branch"
and mentions the rest of the stack only when needed. For the full stack it gets the branches in
order with each branch's commits, and notes which branch introduced what when that helps.

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

## AI review

`:RevueyAIReview` asks Claude to review the changes, the way a colleague would before a merge:
bugs, broken edge cases, security and contract problems, missing tests for risky logic. It runs
in the background, like the [guide](#ai-guide), with the same read-only `claude` invocation
(the schema differs; the session is named "revuey review: <branch>"). The answer is one JSON
document: a short summary, a suggested verdict (approve, comment or request changes) and a
list of findings, each with a severity (critical, major, minor, nit), a title, an explanation
and optionally a suggested change.

**Nothing is posted anywhere.** Each finding becomes a local [comment](#comments) by `claude
(ai)`, on the lines it is about, for you to triage:

```
╭─ claude (ai) · just now · major · ca accept · cn dismiss ─────────
│ Import both helpers from one place
│
│ Two imports of the same module drift apart.
╰─
```

- `ca` **accepts** it: it becomes your own comment ("accepted from AI review"), to edit, resolve
  or later post like any other.
- `cn` **dismisses** it: it stays, collapsed to one line and marked "dismissed", and no longer
  counts; `cn` again restores it.
- `cs` sends it to the [connected agent](#connect-an-agent) to **follow up** ("is this real?
  fix it"), and `cr` replies in its thread, as with any comment.

The panel shows the latest review of the scope under the stack and guide blocks: the verdict
(`✓ approve`, `● comment`, `✗ request changes`), how many findings are left to triage, how many
were dropped, and the summary. `cl` lists the verdict and summary above the comments; findings
there are tagged with their severity and `to triage`. A spinner with the elapsed time and what
Claude is doing ("reading src/cart.ts") shows while it runs, and you keep reviewing.

**Anchors.** Claude never gives file line numbers. The prompt shows every hunk under its id with
its lines numbered within the hunk (`3|+const total = sum(items)`), and a finding names a hunk id
and those numbers (or no line: the whole file). revuey checks them against the diff the review
was started on: findings on unknown hunks or lines a hunk does not have are dropped, and the
"AI review ready" message and the panel say how many. A finding is anchored exactly as a
selection of the same rows would be, so it follows the code like any comment when you edit
(and becomes outdated when its lines change).

**Running it again** replaces the previous review's findings you have not touched (no triage,
reply, send or unsaved edit), after asking (`!` skips the question). Accepted, dismissed,
answered and sent findings stay, and a finding you already accepted, dismissed or deleted is
not added again. Output that is not a review (no summary, verdict or findings list) is an
error and changes nothing. Each scope (branch, stack layer, full stack) has its own review,
like the guide: a layer's review covers only that branch's changes on top of its parent, the full stack all of them, with
the same branch tags in the prompt.

**Skills.** `:RevueyAIReview <skill>` reads that skill's `SKILL.md` (from
`~/.claude/skills/<skill>/`, else the repo's `.claude/skills/<skill>/`; or give a path to a skill
directory or any Markdown file) and passes it to Claude as review guidance: what to look for,
how strict to be. revuey reads the file itself (front matter dropped, at most 40,000
characters), because the restricted run loads no skills, settings or plugins. Tab completes skill
names. The output format stays the same.

Reviews are stored per scope next to its comments (`*.ai-review.json`: summary, verdict, counts,
model, cost, the skill used). Failures (no `claude`, not logged in, invalid output) are reported
and shown in the panel, and leave the last review and its findings alone.

### AI reviews from another agent or tool

An outside agent or tool can produce a review in the same format and import it, so its findings
show up the same way:

```sh
bin/revuey hunks                 # the diff with hunk ids and numbered lines, and the diff hash
bin/revuey hunks --prompt        # the whole prompt revuey's own review sends (instructions too)
bin/revuey hunks --json          # {diff, review, hunks: [{id, path, header, lines}]}
bin/revuey import-review --schema            # the JSON schema
bin/revuey import-review review.json         # import (- reads stdin); --name names the reviewer
```

```json
{
  "summary": "Moves cart totals into cart.ts; rounding is the main risk.",
  "verdict": "request_changes",
  "diff": "4c1f…",
  "findings": [
    { "hunk": "h3", "line": 5, "end_line": 6, "severity": "major",
      "title": "Discount applied twice", "body": "…", "suggestion": "…" }
  ]
}
```

`import-review` picks the review like `bin/revuey comment` (the running one, `--session <id>`
when several, else the review `revuey` would open there) and prints what it imported and
dropped. The optional `diff` is the hash `hunks` printed: when the code has changed since, the
ids may mean other hunks, so the import is refused. The reviewer is `--name` (else
`$REVUEY_AGENT_NAME`); importing again under the same name replaces that reviewer's untouched
findings, as above. A running review shows the findings at once.

## Comments

Comment while you review, in the diff or the guide view:

- `gc` on a line comments on it: added and context lines on the new side, deleted lines on the
  old side. In visual mode `gc` comments on the selected lines (one file; the range is on the new
  side when it holds any added or context line, and the deleted lines inside it are kept with the
  code). On a file header, or a hunk header, it is a comment on the whole file.
- The editor is a small markdown float under the line, titled with the anchor
  (`src/cart.ts:12-14 (new)`). `<C-s>` or `:w` saves; `q` or `<Esc><Esc>` cancels (asking first
  when there is text). Closing it any other way (`:q`, another window) keeps the text as a
  **draft**, shown inline; `ce` continues it. `<C-a>` saves it and sends it to the
  [connected agent](#connect-an-agent) (in a reply editor: the reply, as a follow-up).
- Comments show **inline under their last line** as a thread box (author, time, body with light
  markdown, replies), wrapped to the window, with a `▍` bar in the gutter on the commented lines.
  They are virtual lines: the buffer text, folds, `mr`, LSP and selections are unaffected. Long
  comments (and resolved ones) are cut with `… N more lines`; `cz` expands them. `gC` hides or
  shows every thread (the gutter bars stay). The panel shows `✎2` on files with open comments.
- On a commented line (or its range): `ce` edit, `cr` reply, `cx` resolve / reopen, `cd` delete
  (asks first), `cz` expand. `]m` / `[m` move to the next / previous comment. `cl` (also in the
  panel) or `:RevueyComments` lists them all.
- **Moving code.** Each comment remembers the hunk it was made in and a hash of its lines plus two
  lines of context either side. When the hunk is unchanged (edits elsewhere just shift it) the
  comment moves with it; otherwise it goes to the nearest place with the same lines and context,
  or failing that (only the lines around it changed) the nearest place within 100 lines with the
  same lines, unless they are trivial (a lone `}`). When its lines changed it is **outdated**: it stays at its last known line (or, when that line
  is no longer in the diff, in an "Outdated comments" group at the end of the file) and keeps the
  code it was made on.
- Comments are kept per review (branch or stack layer, like reviewed marks) in
  `stdpath('data')/revuey/*.comments.json`, and never pruned. Several Neovims can comment on the
  same review: saves merge per comment (the latest change wins; a delete wins over older edits;
  replies are merged), and each instance picks up the others' changes live.

`gc` shadows Neovim's built-in commenting operator (`gc{motion}`, `gcc`) in review buffers only,
where there is nothing to comment out; likewise `ce`/`cd`/`cr`/`cx`/`cz`/`cl`/`ca`/`cn` shadow `c{motion}` and
`]m`/`[m` the method motions, which do nothing in a read-only diff. Remap them under `keymaps`
(`comment_add`, `comment_edit`, ...; `false` disables one).

**Export** with `:RevueyCommentsExport`: Markdown meant for pasting into an AI session. A short
header names the review (repo, branch, scope, base and merge-base), then each comment in file
order and, within a file, in the order the diff shows them (comments on deleted lines where their
hunk puts them): `path:start-end (new|old)`, the diff lines it is about in a fenced `diff` block, the
comment, and its replies. Outdated comments say so; resolved comments and drafts are left out
unless you pass `--all`. `json` gives the full data for tools. For example:

````markdown
# Review comments: stack/cart → stack/math

- Repo: revuey-stack (/tmp/revuey-stack)
- Branch: stack/cart
- Scope: stack layer stack/cart
- Base: stack/math (merge-base 41f287d7)

2 comments, ordered by file and line. Each gives the file, the line range and side (new: the code after the change, old: the code before it), the diff lines it is about, and the reviewer's note.

## 1. src/cart.ts:4 (new)

```diff
+import { multiply, sum } from "./math";
```

Is `multiply` still needed here?

Replies:
- **agent**: Yes: `total()` uses it.

## 2. src/index.ts:7 (old)

```diff
-  const total = oldTotal([1, 2, 3]);
```

Keep a test for oldTotal before removing this.
````

### Comments for coding agents

`bin/revuey` gives agents the comments of the current repo and branch without opening the UI
(it runs `nvim --clean --headless`, so it ignores your config). Both the UI and the CLI use
`$REVUEY_STATE_DIR` when it is set, so set it rather than `state_dir` in your config if you move
the state; a `state_dir` in `setup()` only applies to the UI:

```sh
bin/revuey comments              # the Markdown export (--json: JSON; --all: resolved and drafts too)
bin/revuey watch                 # follow comment events, one line each
bin/revuey reply <id> "Fixed."   # reply in the comment's thread (- reads the text from stdin)
```

`--scope current` (default) covers the checked-out branch's reviews (its branch review, its stack
layer and full-stack reviews that include it); `--scope all` every review of the repo; `--scope
<branch>` another branch.

Every change to a comment (created, updated, deleted, resolved, replied, sent, acked) is appended as one JSON line to `*.events.jsonl` next to the comments
(rotated at 1 MB; a snippet longer than 200 lines is cut in events). Writes to the comments
file and the feed hold a lock, so any number of Neovims and `reply` calls can write at once. `watch` prints one line per event and flushes it at once, so it works under
Claude Code's Monitor tool (each stdout line is an event), and it exits cleanly on SIGTERM:

```
comment src/cart.ts:1 (new): Is `multiply` still needed here?  #1a163fedcc13a6b5
comment src/index.ts:7 (old): Keep a test for oldTotal before removing this.  #1a163fee6381dbb5
resolve src/index.ts:7 (old): Keep a test for oldTotal before removing this.  #1a163fee6381dbb5
```

`--json` prints the full event instead (kind, review, anchor with line range and side, the code,
the body, author, and the reply for `replied`). `--since <event id>` (or `all`) first replays
earlier events. The agent's own replies and comments are not echoed back unless `--all` is given. A reply
made with `bin/revuey reply` (author `agent`, or `$REVUEY_AGENT_NAME`) shows up in a running
revuey's thread within a moment. The comment id may be shortened to any unique part of it.

## Connect an agent

Send a comment or a question about the code to a coding-agent session (Claude Code first) while
you keep reviewing; the agent's answer shows up in that comment's thread.

- `<C-a>` in the comment editor saves the comment and sends it. In a reply editor (`cr`) it
  sends the reply as a follow-up.
- `cs` on a commented line sends that comment (again, if it was sent before).
- `ga` on a line or a visual selection opens the editor titled "Ask agent"; type the question and
  `<C-a>` sends it (`<C-s>` only saves it). `ga` rather than `<leader>a`: leader mappings are
  global and often taken, while `ga` (show the character code) means nothing in a review, and it
  follows revuey's `g` keys (`gc`, `gC`).
- The thread shows where the message is: `queued: no agent connected` (it is delivered when an
  agent connects), `sent → agent` (an agent was shown it), `seen by agent` (acknowledged),
  `answered`. With two reviews of one worktree open, each review's messages go to the agent
  watching that review.
- The file panel's header shows `● agent connected` or `○ no agent`.

The keys are `comment_send`, `send_comment` and `ask_agent` under `keymaps`.

**With Claude Code.** Install the skill once (it links `skill/revuey` from this checkout into
`~/.claude/skills/revuey`; `--copy` copies it instead, `--force` replaces an existing one,
moving a directory aside to `~/.claude/revuey-skill-backups/<time>/`). Install it from your main checkout: a link
into a worktree or temp dir breaks when that is removed (it warns):

```sh
~/dev/revuey/main/bin/revuey install-skill
```

Then, in a Claude Code session running in your repo:

1. **Claude launches revuey**: ask it to "open revuey" (in tmux or herdr it opens revuey in a
   pane to the right; elsewhere it tells you the command to run). Or **you launch revuey**
   yourself (`bin/revuey`, or `:Revuey` in your Neovim) and ask Claude to "connect to my revuey
   review".
2. Claude finds the review with `bin/revuey sessions` and watches it with its Monitor tool
   (`bin/revuey watch --messages`, re-armed every 30 minutes). The header turns to
   `● agent connected`.
3. Send comments and questions from revuey. Claude reads each one with `bin/revuey show <id>`,
   answers with `bin/revuey reply <id> "…"`, or acknowledges it with `bin/revuey ack <id>` when
   it just acts on it. It only edits files when a message asks for a change.
4. Ask Claude to leave you a comment ("point out in revuey where the retry logic lives") and it
   adds a new thread with `bin/revuey comment`; it shows up at once, labelled with the agent's
   name (`agent`, or `$REVUEY_AGENT_NAME`) and highlighted as the agent's.

**From the shell** (any agent; run inside the reviewed worktree):

```sh
bin/revuey sessions              # live reviews of this worktree (--all: every worktree), --json
bin/revuey watch --messages      # one line per message; ones no watch printed yet come first
                                 # (catch-up; --replay: every one not handled yet)
bin/revuey show <id>             # the message in Markdown: file, lines, code, comment, thread
bin/revuey reply <id> "Because…" # answer in the thread (- reads stdin); marks it answered
bin/revuey ack <id>              # handled without a reply: not delivered again
bin/revuey inbox                 # messages not handled yet, then exit (no Monitor needed);
                                 # --json; --session <id> like watch
bin/revuey comment --path src/cart.ts --line 12 --end 14 "Is this rounding intended?"
bin/revuey comment --path src/cart.ts --line 7 --side old -   # a deleted line; text on stdin
bin/revuey comment --path src/cart.ts --file "Needs a test."  # the whole file
```

`comment` leaves a new comment (author `agent`, saved, not added to any forge review) and
prints its id and where it went:

```
1a1b2c3d4e5f6a7b
commented on src/cart.ts:12-14 (new) in stack/cart vs stack/base, working tree, session 48213
```

It goes into the same review as `watch` (the worktree's only live review, else `--session
<id>`). With no review running it goes into the review `bin/revuey` would open there (the stack
layer of HEAD, a detached HEAD too, else the branch against the default branch) and shows when
you open it. Since the CLI does not read your Neovim config, it takes your `default_branch`,
`uncommitted`, `state_dir` and `context_lines` from the last review opened in that worktree
(recorded in `$(git rev-parse --git-dir)/revuey/`); before revuey has ever opened there it uses
the defaults. The CLI loads that review's diff itself (one `git diff` plus the working-tree
snapshot, the same loader as the UI, so the check is exact): the path must be one of its changed
files and every line inside a hunk on that side (`new`, the default: added and context lines;
`old`: deleted and context lines), else it fails with the nearest hunks and suggests `--file`.
Ranges are at most 200 lines. It records the path, side, lines, code snippet and the context
hash (from the working tree in working-tree mode, the old blob for `old`); the running review
finds the comment's hunk on its next render and stores it, as for its own comments. Its
`created` event and the comment itself are never delivered back to the agent: `watch` (without
`--all`) skips the agent's own comments, and only comments the user sends are messages. It is
local only: nothing is posted to GitHub.

A `watch --messages` line looks like this (`--json` prints the full event instead, with the
anchor, the code, the message and the review: repo, branch, scope, base):

```
revuey message 19a3f0c2d4e1a8b7f src/cart.ts:12-14 (new) [stack/cart]: Why multiply here?  (/home/me/dev/revuey/main/bin/revuey show 19a3f0c2d4e1a8b7f for full context)
```

How it works: each running review registers itself in
`$(git rev-parse --git-dir)/revuey/sessions/<nvim pid>.json` (worktree, branch, scope, the
comments and event feed paths, Neovim's PID and RPC socket); it falls back to revuey's state dir
when the git dir is not writable, rewrites the entry when you switch layers or scopes, and
refreshes it every 2 s and removes it on exit (an entry is dead when its process or its Neovim
socket is gone, or when it was not refreshed for 30 s and its socket does not answer: a crashed
review whose pid was reused; a suspended review stays alive). Sending marks the comment with
`sent_at` and the sending review, and appends a `sent` event to the comment feed once the
comment is saved; its `status` stays as it was. `watch` attaches to the worktree's single live
review (several: pick one with `--session <id>`; none yet: it waits for one, and it re-attaches
when the review restarts), registers a watcher with a heartbeat in the same place (the review
counts an agent as connected while a heartbeat is under 30 s old and its process lives), prints
the messages no watch has printed yet, then new ones, and records each one it prints as
delivered, so a restarted watch (Monitor re-armed) never repeats one. It prints only its own
review's messages, and those of a review that is gone (one that is only suspended keeps its
own), and when its review restarts it follows the new one of the same scope; `inbox` takes
`--session` and routes the same way. A message counts as handled once the
agent acknowledges it or replies; `inbox` lists the rest, delivered or not.

`skill/revuey/launch.sh --in tmux|herdr|none <dir>` opens the review pane for the agent. It
only splits a pane it can verify (`$TMUX_PANE` known to the tmux server, `$HERDR_PANE_ID` found
by `herdr pane get`) and refuses otherwise; `none` prints the command for you to run.

## Layout

The review opens in a new tab:
- **File panel (left):** status letter, `+/-` counts, and `✓` for reviewed files (`◐` and
  `2/5` hunks when partly reviewed).
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
| `mr` | Toggle reviewed. On a hunk header or any line of a hunk: that hunk (it collapses, and the cursor moves to the next unreviewed hunk you can see, skipping collapsed files). On a file header: the whole file (marks every hunk when any is unreviewed, else unmarks them all; collapses the file and moves to the next unreviewed one). In visual mode: every hunk the selection touches (a collapsed file in the selection counts whole). A file whose hunks are all reviewed collapses; its header shows `✓ reviewed`, or `◐ 2/5` while partly reviewed. Unmarking a file re-expands the hunks that were collapsed because they were reviewed, not the ones you collapsed with `<Tab>` |
| `<Tab>` | On a file header or hunk header: collapse / expand that file or hunk (does not mark it reviewed). On any other line it is `<C-i>` (jump forward, takes a count), since most terminals send the same key for both |
| `<S-Tab>` | Collapse every file, or expand them all when all are collapsed |

`<Tab>` and `<S-Tab>` are buffer-local, so in revuey's diff/guide buffer they override your own
`<Tab>`/`<C-i>`/`<S-Tab>` mappings (only there). A count (`3<Tab>`) always means jump forward. Set
`keymaps = { toggle_fold = false, toggle_all_folds = false }` to leave those keys alone.
| `za` etc. | Normal fold commands: each file is a fold, each hunk a fold inside it, and long unchanged runs are folded |
| `gp` | Focus the file panel |
| `gu` | Toggle working tree (default) / committed only |
| `ge` | [Edit](#editing-from-the-review) the real file at this line in a float (checked-out layer, working-tree mode) |
| `R` | Refresh (re-runs git; also automatic in working-tree mode) |
| `]s` / `[s` | Next / previous stack layer (takes a count). These shadow spell navigation, which is off in review buffers. |
| `gs` | Toggle full-stack scope and back to the last layer |
| `gS` | [Check out](#checking-out-a-layer) the layer being viewed in this worktree (`git switch`) |
| `!` | [Stack notes](#stack-notes) in full, with actions (also in the file panel) |
| `gG` | Toggle the AI guide view (offers to generate a guide when there is none) |
| `gR` | Generate a new AI guide (asks first when one exists) |
| `]]` / `[[` | Guide view: next / previous section. Diff view: next / previous file |
| `gc` | [Comment](#comments) on this line (visual: the selected lines; a file or hunk header: the whole file) |
| `ce` / `cr` / `cx` / `cd` | Edit / reply to / resolve or reopen / delete the comment on this line |
| `cz` | Expand / collapse a long or resolved comment |
| `ga` / `cs` | [Ask the agent](#connect-an-agent) about this line or the selection / send the comment on this line to it |
| `]m` / `[m` | Next / previous comment (takes a count) |
| `gC` | Hide / show comment threads |
| `cl` | List all comments (`<CR>` jumps) |
| `ca` / `cn` | [AI review](#ai-review) finding on this line: accept it as your comment / dismiss it (again: restore) |
| `<CR>` on the guide's diagram | On a box: jump to its section. On the "Overview" heading: fold / unfold the diagram (like `<Tab>`) |
| `q` | Close the review (quits Neovim when started via `bin/revuey`) |

File panel:
- `<CR>`/`o`: show the file and focus the diff. On a stack row, switch to that layer (or the full stack).
- Moving the cursor previews files in the diff.
- `mr`, `gu`, `R`, `]s`, `[s`, `gs`, `!`, `gG`, `gR`, `cl`, `gp` (back to the diff) and `q` work as in the diff buffer.
- `gS` on a layer row checks that layer out (elsewhere: the viewed layer). While the panel has focus, a dim
  line under the layer row the cursor is on says what `gS` would do there (`gS creates local branch
  stack/cart` on a remote-only layer).
- `gx`: open the [pull request](#pull-requests) of the layer row under the cursor (elsewhere: of
  the viewed layer) in the browser. `<Tab>` on the PR heading folds its details; elsewhere it is
  `<C-i>`.
- In the guide view the panel also lists the guide's sections: `<CR>` jumps to one, `mr` marks it reviewed.
- `mr` on a file row marks the whole file, in either view.

Reviewed marks are stored in `stdpath('data')/revuey/*.json`. Each review is keyed by repo root,
branch (or stack layer) and base (or parent layer). Each hunk is marked by a hash of its path and
lines (not line numbers), so editing one hunk resets only that hunk, and a hunk moved by edits
above it keeps its mark. A file whose hunks are all reviewed is also stored by its new blob hash.
Files without hunks (binary files, "not shown" placeholders, pure renames, mode changes) are
marked as a whole, by blob hash. State files from earlier versions keep working: a file mark
still counts for all of the file's hunks (and is converted to hunk marks when the review opens),
and a guide section mark becomes marks on that section's hunks. Marks of content a review has not
shown for 30 days are dropped from the file the next time you mark something.

**Upgrading:** restart every Neovim running revuey after updating. An instance still running the
previous version keeps only file marks when it next saves, so it would drop the hunk marks.

All highlight groups can be overridden: `RevueyAdd`, `RevueyDelete`, `RevueyAddText` and
`RevueyDeleteText` (word diff), `RevueyFileHeader`, `RevueyHunkHeader`, `RevueyAddSign`,
`RevueyDeleteSign`, `RevueyLineNr`, `RevueyAddLineNr`, `RevueyDeleteLineNr`, `RevueyReviewed`,
`RevueyPartial` (partly reviewed, `◐`),
the guide's `RevueyGuideTitle`, `RevueyGuideSection`, `RevueyGuideCode`, `RevueyGuideImportant`,
`RevueyGuideWarning`, `RevueyGuideHunkNote`, `RevueyGuideOutdated`, the diagram's `RevueyDiagramNew`,
`RevueyDiagramChanged`, `RevueyDiagramContext`, `RevueyDiagramEdge`, `RevueyDiagramLabel`, the
stack's `RevueyLayerLabel`, the stack notes' `RevueyStackNote` (dim) and `RevueyStackWarn`, the comments'
`RevueyCommentSign`, `RevueyCommentBorder`, `RevueyCommentAuthor`, `RevueyCommentDraft`,
`RevueyCommentResolved` and `RevueyCommentOutdated`, AI reviews' `RevueyAiCritical`, `RevueyAiMajor`,
`RevueyAiMinor`, `RevueyAiNit` (severities), `RevueyAiApprove`, `RevueyAiComment`, `RevueyAiChanges`
(verdicts) and `RevueyAiTriage`, the pull requests' `RevueyForgeApproved`,
`RevueyForgeChanges`, `RevueyForgePending`, `RevueyForgeNone`, `RevueyForgeDraft`, `RevueyForgeMerged`,
`RevueyForgeClosed`, `RevueyForgeNumber`, `RevueyForgeDim` and `RevueyForgeWarn`, and others (see
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
- Your own mappings: `:lua vim.lsp.buf.definition()` (or whatever you map it to) on `sum(`
  opens `src/math.ts` in the split below; `vim.lsp.buf.type_definition()` on `cart` in
  `src/index.ts` opens the `Cart` class; `vim.lsp.buf.references()` or a picker on `sum(`
  lists the real locations. On a `-` line you get "no LSP on a deleted line".
- `mr` inside a hunk of `src/math.ts`: the hunk folds, the file header shows `◐ 1/2`, and the
  cursor moves to the next hunk. `mr` on a file header marks the whole file.
- `<Tab>` on a file header or an `@@` hunk header to collapse it, `<Tab>` again to expand it;
  `<S-Tab>` collapses every file.
- `q` to quit.

Comments:
- `gc` on `+ import { multiply, sum } ...` in `src/cart.ts`, type a note, `<C-s>`. `Vjgc` on two
  lines, `gc` on a `-` line (old side), `gc` on a file header (whole file).
- `cr` to reply, `cx` to resolve, `]m` / `[m` between comments, `cl` for the list.
- `:RevueyCommentsExport` and paste the clipboard into an AI chat.
- In a second terminal in the fixture: `~/dev/revuey/main/bin/revuey watch`, then comment again:
  each comment prints one line. `~/dev/revuey/main/bin/revuey reply <id from that line> "On it"`
  shows the reply in the thread.
- Add three lines at the top of `src/cart.ts` and save: the comments move with their lines.

Uncommitted work: in another terminal (or Neovim split) edit `/tmp/revuey-fixture/src/math.ts`
and save, or create a new file under `src/`; the review updates with a `●` on those files. Press
`gu` to compare with the committed-only view.

Editing: `ge` on `+ export function sum` in `src/math.ts` opens the file in a float, folded to the
hunk. Change a line, `:w`: the diff updates under it and the review cursor follows the line. `q`
closes it (it asks when there are unsaved changes). `ge` on a `-` line opens at the nearest new
line; `gu` then `ge` says to switch back to working-tree mode first.

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
- `[s` to `stack/math`, then `gS`: the worktree is on `stack/math` now (`@` moved), and edits show
  up in that layer. `:RevueySwitch stack/cart` goes back.

### Someone else's stack

```sh
scripts/make-fixture.sh --remote-stack /tmp/revuey-remote  # pushed to /tmp/revuey-remote/upstream.git
cd /tmp/revuey-remote/review                               # fresh clone, detached at origin/stack/ui
~/dev/revuey/main/bin/revuey
```

Things to try:
- The panel shows `origin/stack/math`, `origin/stack/cart` and `@ origin/stack/ui`, dimmed with
  `ro`, and a `detached HEAD at origin/stack/ui` note.
- `[s`, `mr` a file in `origin/stack/cart`, then quit, run
  `git branch --track stack/cart origin/stack/cart` and reopen: the layer is now the local
  `stack/cart` and keeps its mark.
- `:RevueyStackParent` names parents explicitly; on a local branch that's the only way a
  remote-tracking branch becomes a layer.
- `gp`, cursor on `origin/stack/cart`: the hint says `gS creates local branch stack/cart`. `gS`:
  `stack/cart` is created tracking it and checked out, `@` moves there, and `origin/stack/math`
  stays below it (`origin/stack/ui` shows again once you go back to the detached worktree:
  `git switch --detach origin/stack/ui`). Edit a file first and `gS` refuses, naming it.

### Stack notes

Old branches left on an earlier version of a layer:

```sh
scripts/make-fixture.sh --stack /tmp/revuey-notes
cd /tmp/revuey-notes
git branch old/try-1 stack/math && git branch old/try-2 stack/math
git checkout -q stack/math && echo '// tweak' >> src/math.ts && git commit -qa --amend --no-edit
git rebase -q --onto stack/math stack/math@{1} stack/cart && git rebase -q --onto stack/cart stack/cart@{1} stack/ui
git checkout -q stack/cart
~/dev/revuey/main/bin/revuey
```

- The panel shows one dim line, `⚠ 2 related branches outside this stack`.
- `!` opens the details. `x` on `old/try-1` hides it (the line now says `(1 ignored)`); `X` on
  `old/try-2` offers `old/try-*`. `u` on a pattern brings the notes back. `:RevueyStackIgnore` lists
  the patterns.

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
  `mr` on one hunk instead: the section shows `◐ 1/2`, and `gG` shows that file's progress in the diff.
- `<Tab>` on a section heading or a hunk header collapses it; `<Tab>` again expands it.
- `ge` on a line of `src/cart.ts` in the guide, change it and `:w`: the hunk stays in its section
  with "✎ edited since guide" (and loses its reviewed mark), and a banner offers `gR`. Add a
  change somewhere new instead and it appears under "Not in guide".
- The full-stack guide starts with an overview diagram: `<CR>` on a box jumps to its section,
  `:RevueyGuideDiagram mermaid` copies it as Mermaid. Hunk headers show the branch that
  introduced each hunk (`[stack/cart, stack/ui]` on `src/cart.ts`).
- `gs` for a layer: it has no guide of its own yet, and no branch labels. `gs` again: the
  full-stack guide is back.

### An AI review

In the same review (needs `claude` too):

- `:RevueyAIReview`. The panel shows "AI review" with a spinner; after a few seconds the verdict,
  the findings to triage and the summary appear, and each finding is a `claude (ai)` thread on
  its lines. `]m` moves between them.
- `ca` on one: it becomes your comment. `cn` on another: it collapses as "dismissed" (`cn` again
  restores it). `cl` lists them all under the verdict.
- `:RevueyAIReview` again asks before replacing the findings you have not touched; the ones you
  accepted or dismissed stay.
- `bin/revuey hunks` in the repo prints what Claude saw; `bin/revuey import-review --schema` the
  format an outside tool would write.

## Tests

`make test` runs every spec in a fresh `nvim --headless --clean`, offline and without your config
(see [docs/TESTING.md](docs/TESTING.md)):
- **Unit:** diff parsing (renames, binary, type changes, CRLF, missing EOF newline), line layout,
  state persistence/merging/invalidation, review units (keys, identical hunks, files without
  hunks, derived file and section state, nested hunk/piece marks via a synthetic split, old state
  files), async syntax projection (bundled Lua parser), stack
  resolution (ordering, forks, duplicate tips, Graphite metadata, overrides, trunk ahead, merged
  layers) plus `detect()` on real repos. Remote-tracking layers: candidate selection, dedupe
  precedence and state keys (with the same-name-on-two-remotes case), and someone else's stack
  in a bare upstream reviewed from a fresh clone (detached and tracking, marks and comments kept
  when a local branch appears, unrelated remote branches, squash merges, 3000 remote branches).
  Stack notes: classification, grouping, summary lines,
  the details listing and actions, and the ignore list (glob matching, suggestions, persistence
  and merging).
- **Unit (guide):** hunk ids and anchors, prompt building (layer and full-stack scope wording) and the size budget, the stream-json
  parser, validation and JSON repair, section identity, staleness, guide storage, markdown prose.
  The overview diagram: schema validation, golden layouts (chain, fan-out, fan-in, cycle,
  multibyte labels, the list fallback) and Mermaid text. Branch attribution on a 3-layer git
  stack (a hunk two layers touched, a pure deletion, a rename, uncommitted and untracked work).
- **Integration:** real fixture repos opened headlessly (buffer text, extmarks, folds, keymaps,
  lifecycle cleanup, empty reviews, `mr` on hunks, files, sections and selections in both views
  with folding and cursor moves, an edit resetting one hunk, stack layer switching/full scope/per-layer marks/working tree
  on the HEAD layer only; stack notes: the summary line for old branches on a pre-amend
  layer, the details float, ignoring a branch or pattern (persisted across reviews), set as parent
  and clearing it from the float, config ignore patterns), plus LSP definition/hover when `typescript-language-server`
  is on PATH (skipped otherwise). The `revuey` proxy client: capabilities, a user-style
  `LspAttach` handler (keymaps, inlay hints), lifecycle (no leaked clients), deleted lines,
  filetypes without an LSP, encoding conversion and keeping the review in its window run without
  a server; `vim.lsp.buf.definition`/`type_definition`/`references`/`hover` from context and
  added lines, in the diff and the guide, run against `typescript-language-server`. TypeScript highlight checks skip without the TS parser/queries.
  The AI guide runs against a fake `claude` (`tests/bin/claude`) that records its argv and stdin
  and replays canned stream-json (good, diagram, invalid, missing hunks, unknown ids, errors, slow, hang),
  so the tests never need the network or a subscription.
- **Checking out a layer** (`switch_spec.lua`): the `gS` decision (local, remote with a tracking
  branch, a conflicting local name, a fresh `--track`, detached, already on it), collisions, the
  parent setting, status and worktree parsing and the message texts (unit); then real git, each
  test on its own fixture: local and remote-only layers (marks and comments carried over, the
  parent setting keeping the layer below after commits and reopening), stray remote refs never
  becoming layers, no self-parent, a deleted and reused branch name, a conflicting name, dirty,
  untracked, ignored and file-for-directory refusals, unsaved buffers, a branch in another
  worktree, a failing hook, a submodule bump, the agent confirmation (re-checked after, once per
  review for `]s`), `switch_on_navigate`, one switch at a time, the registry and `sessions`,
  hidden LSP buffers and `:RevueySwitch`.
- **Editing from the review** (`edit_spec.lua`, `edit_float_spec.lua`): which rows can be edited
  for each row kind, layer, mode and full-stack attribution, and the row-to-line mapping after
  earlier edits (unit); guide re-anchoring by overlap (a confident match, ambiguous splits and
  joins, no match) in `guide_spec.lua`; then the float on real repos: from the diff and the
  guide, folds, `:w`/`<C-s>` with the refresh and the review cursor, LSP in the float (real
  `typescript-language-server`, skipped without it), refusals on another layer, committed mode,
  a remote `ro` layer and a lower layer's hunk in the full stack, deleted lines, the unsaved-close
  question, an already open and modified buffer, nothing leaking into other windows, the guide's
  "edited since guide" marker with the reviewed mark reset, and comments re-anchoring.
- **Comments:** the model, re-anchoring (shifted, moved, outdated, deleted lines on the old side,
  identical code at two places), merging with tombstones, the export formats (golden) and event
  lines (unit); `gc` in normal and visual mode on added, deleted and context lines and file
  headers in both views, the editor, edit/reply/resolve/delete, drafts, a working-tree edit
  moving and then outdating comments, export to a register, live reload, two Neovim instances
  merging, and `bin/revuey comments`/`watch`/`reply` round trips with `watch` as a subprocess
  (integration).
- **Agent link:** the session registry, watcher heartbeats, delivery state and catch-up selection
  (unit, `sessions_spec.lua`); `<C-a>`, `cs` and `ga` sends, `watch --messages` catch-up and live
  lines, presence, `reply`/`ack`/`show`/`inbox`, `sessions` with zero, one and several reviews,
  scope switches and `install-skill` into a temporary `HOME` (integration, `agent_link_spec.lua`).
- **Screen:** a child Neovim (vendored `mini.test`, `tests/vendor/mini`) renders the review and its
  screen grid, highlight attributes included, is compared to `tests/screenshots/*`. After an
  intended UI change, regenerate them with `REVUEY_UPDATE_SCREENSHOTS=1 make test` and review the
  text diff. `tests/bin_spec.lua` launches `bin/revuey` in tmux (skipped without tmux).
