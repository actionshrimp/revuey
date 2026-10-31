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
(`context_lines`, `fold_context_threshold`, `collapse_large_files`, `panel_width`, `panel_folders`, `lsp_warmup`,
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
| `:RevueySubmit [approve\|comment\|request-changes\|pending]` | [Post the review to GitHub](#posting-a-review-to-github): the comments added with `ci`, as one review with that verdict (asked when left out), after a confirmation. `pending` adds them to your pending review on GitHub without submitting it. `:RevueySubmit forget` drops revuey's record of an unconfirmed comment on this line. |
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
`main ← feat/api ← feat/ui ← feat/docs`. `:Revuey` (or `bin/revuey`) with no base detects it
from git as below; once the branches have pull requests on GitHub, their base branches give the
stack instead, and stacks that branch become a tree to pick a path from (see
[Stack trees from GitHub](#stack-trees-from-github)):

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
- **An agent connected to the review** (`● agent connected`): revuey switches without asking,
  then tells the agent (its `bin/revuey watch --messages` prints a `revuey switched` line with the
  branch before and after, the layer and its pull request when revuey already knows it), so it
  re-reads the files and works on the new layer. The message says so: `revuey: switched to
  stack/math; told the connected agent`. If the note cannot be written, the switch stands and the
  message says the agent was not told (details in `revuey.log`). With no agent connected nothing
  is sent.
- **One at a time:** a `gS` (or `]s`) while a switch runs is dropped with a message.

Afterwards the review refreshes: the layer gets `@`, the working tree and the `●` markers, and the
view moves to it (cursor and folds as you left them there), whichever layer you were viewing:
`gS` on a layer row in the full-stack scope views that layer, and the guide view shows its guide
(or offers one). A refused switch leaves the view as it was. The session registry records the new branch
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

`stack = { switch_on_navigate = true }` makes `]s`/`[s` switch too, with the same checks; when a
switch is refused the view still moves, and a message says the branch did not. A connected agent
is told once you stop: switches less than 1.5 s apart become one message, from the branch the
agent last heard of to the one you stopped on (nothing when that is where it was), sent after the
pause, with your next `gS`, or when the review closes or Neovim quits.

### Someone else's stack (no local branches)

To review a colleague's stacked PRs you don't need a local branch for every PR. Fetch first
(revuey never fetches on its own; it uses the remote-tracking branches you have, and when the
stack has pull requests [`gF`](#stack-trees-from-github) fetches the ones it lacks), then review from a
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

### Stack trees from GitHub

Stacked pull requests can branch: a branch with two child PRs (one continuing the stack, one
abandoned), a closed chain hanging off the middle, a branch moved onto a new base with its old
PR closed. When the checked-out branch has a pull request on GitHub, revuey builds the stack from
the PRs' base branches instead of guessing from git history:

- **The stack is a path through the tree:** from the trunk down through each PR's base, then up
  through open PRs, taking the longest run of open PRs where a branch has several (a tie goes
  to the lower PR number, the one opened first). A branch with one open child just continues.
  The commits come from your branches: a local branch of the PR's head when it is the PR's (at
  its head, or containing it with your commits on top), else `origin/<head>` (read-only,
  `ro`), else the head commit when the clone has it. Your checked-out branch is always its PR's
  layer, whatever the PR's state (closed, merged) and whatever it holds. A lower branch you
  amended and restacked your branch onto (not pushed yet) is shown from your copy, so each layer
  shows its own change. A local copy that is just behind the PR or was rebased off it is not
  shown: the PR is, with a `⚠ local stack/a differs from PR #11` note. An old closed PR of a
  branch that moved on is shown from its own commit, never from the branch.
- **`gb` shows the tree** over the diff as a graph, like `git log --graph`: the top of the
  stack at the top, the trunk at the bottom, every branch in a column of its own, joined to
  the PR it comes off right above that PR:

  ```
   Stack tree · 9 PRs on main
  ● #15 stack/d  Discounts for members                  not fetched  draft
  ● #13 stack/c  Coupon codes                 origin behind · fetch  ✗
  │ ○ #19 bob:fix-d  Fix the discount rounding       not fetched  fork  ●
  ├─╯
  │ ○ #14 stack/x  Experiment: free shipping                     closed
  ├─╯
  ● #12 stack/b  Tax on the cart total                            ● @ ▶
  │ ○ #17 stack/old2  Legacy price rules, part 2     not fetched  closed
  │ ○ #16 stack/old1  Legacy price rules                          closed
  ├─╯
  ● #11 stack/a  Prices per item                                  ✓
  ● main

   path: main › #11 › #12 › #13 › #15
   j/k up/down  h/l other branch  <CR> review  C closed (4)  gF fetch  q close
  ```

  The path you are reviewing is the left column, its PRs `●`; other PRs are `○`. The cursor
  sits on a PR, and the path you would get from it, from the trunk through that PR and on
  along its open PRs above, is lit along its whole length, lines included (the rest of the
  graph is dim); the footer spells it out (`main › #100 › … 16 more … › #13 › #15` when long; `⇣` after a PR whose commits are
  not in your clone yet, where the stack would stop: `gF` fetches them).

  - `k` goes up the column (the next PR built on this one, or the next branch in that
    column), `j` down to the PR this one is based on (from a side branch's lowest PR, the fork
    point it comes off), so `j`/`k` follow a branch.
  - `h`/`l` go to the nearest PR in the column to the left / right: that is how to swap to
    another branch. `l` on a fork point goes into its own branches; at a fork, `l` from the
    PR above it reaches the branch beside it, and `h` comes back. Every PR can be reached this
    way.
  - `<CR>` reviews the lit path: the panel's stack becomes it, viewing that PR's layer, and it
    becomes the left column. `q`/`<Esc>` close without a change.
  - Closed PRs are hidden (a PR says `+3 closed` for the ones above it); `C` shows them.
    Closed and merged PRs show their state, and can be chosen too. Columns are reused once a
    branch has joined, so a tree with many forks stays narrow; a long one scrolls with the
    cursor.

  Each row has the PR number, branch, title, the review state (as in the panel), `@` on
  HEAD's PR, `▶` on the layer you are viewing, and what your clone lacks: `not fetched`
  (no `origin/<head>`, no commit) or `origin behind · fetch` (`origin/<head>` is not GitHub's
  head). In a narrow window the details on the right go first, then the title.
- **Nothing is stored:** the chosen path lasts while the review is open (refreshes and `R`
  keep it). Reopening starts from the path through your branch again.
- **When you switch branches** (in the review with `gS`, or elsewhere): on a branch of the tree
  the path stays and `@` moves with you; on any other branch the stack is that branch's own,
  its tree fetched once (git detection until it arrives, or when it has no PR). A tree that
  finished loading is kept for when you come back (to any branch in it); `R` drops the kept
  ones. If you pick a path in the tree that doesn't have your branch, a note says so.
- **The panel** shows the chosen path as before. `⑂2` on a layer means the tree has two other
  PRs on that branch (`gb` shows them); `⇣` means its branch is not fetched or behind GitHub.
  With the panel focused, the layer under the cursor says which (`gb tree: 2 other paths
  here`, `gF fetch: origin is behind GitHub`). A PR whose commits are not in your clone is
  left out (the layer above then shows its changes too) with a `⚠ PR #15 not fetched` note.
  `]s`/`[s`, the full-stack scope and `gS` work along the chosen path; `gS` on a remote layer
  creates a tracking branch as before. The PR section, threads, the description, posting
  (`gP`) and the news check use the layer's own PR: a closed PR's layer never shows or posts to
  the open PR its branch has now. Other notes: a layer not based on its parent PR's head
  (`⚠ … not based on …'s head`: like on GitHub it shows the parent's old commits), and a parent
  you set (`:RevueyStackParent`, Graphite) that GitHub's base disagrees with (the stack follows
  GitHub). The [ignore list](#stack-notes) does not remove PRs from the path.
- **`gF` fetches** the stack's branches from the PRs' remote with `git fetch` (into
  `origin/<head>`; for PRs from forks and closed PRs `refs/pull/N/head`, which brings the
  commits without writing a ref), then refreshes. It only writes to your clone, never to
  GitHub. In the tree it fetches the path under the cursor. If part of it fails (a branch
  deleted on GitHub since), the rest is still fetched, a gone branch by its pull ref, and the
  message says which (a remote that doesn't answer is tried once, not once per branch). It
  never prompts: no git credential prompt, and ssh runs in batch mode (no host-key or
  passphrase question) unless you configured ssh for git yourself (`GIT_SSH_COMMAND`,
  `GIT_SSH`, `core.sshCommand`). Closing the review stops it. revuey does not fetch on open: a
  fetch moves your remote-tracking branches, can ask for credentials and costs a network round
  trip on every review, and the marks say when one is worth it.
- **PRs from forks** are shown (`bob:fix-d`, `fork`); `gF` brings their commits through
  `refs/pull/N/head`, and they are read-only layers (`gh pr checkout N` checks one out).
- **When it is read:** with the PR lookup, when the review opens and on `R` (never on its own,
  not after posting a review).
  The first round shares the lookup's call: the base chain seven PRs at a time, then one call
  per level of children for every branch of the tree at once. What the stack needs comes
  first; closed subtrees follow (`loading closed PRs…` in the tree's heading meanwhile). At
  most 25 calls, 300 PRs and 30 child PRs per branch: past that the tree is cut where it got
  to (`cut:` in its heading, `… ` on PRs not expanded, `+N more on GitHub`, and a
  `stack tree incomplete: R retries` note in the panel).
- **Without GitHub** (no `gh`, no GitHub remote, offline, no PR for your branch) the stack comes
  from git as above, and `gb` says why there is no tree. A lone PR stays a plain review until
  you pick a path in the tree. Branches without a PR yet above the top PR (local work not
  pushed) stay on top of the stack; one that has a PR based elsewhere on GitHub is not stacked
  there (a note says so). `stack = { github = false }` turns the tree off.

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
  merged and closed PRs are dim with `draft`, `merged` or `closed`. A `↻` (and `(new on GitHub ·
  R)` on the detail heading) means the PR changed on GitHub since it was fetched: press `R` to
  see it. A dim `?` (and `(stale)` on the detail heading) means the last lookup failed and this is
  the previous result. In a narrow panel the branch name is cut first, then the
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
- **When.** What you see from GitHub changes only when you ask: the PRs are looked up when the
  review opens (one call for every layer, in the background), and again only on `R`. Switching
  layers (`]s`/`[s`, `gs`, `gS`), refreshes after a save or a git change, focus, resizes and
  redraws never fetch. A branch looked up under a new name is looked up once at the next
  refresh: a layer that appears in the stack later, or a branch whose push or upstream config
  changed (`git push -u` to another name). One lookup
  runs at a time per review; `gh` is stopped after `forge.timeout` seconds (15) and when the
  review closes, and a lookup that ends after that is ignored.
- **News on GitHub.** While the review is shown and Neovim has focus, every `forge.ttl` seconds
  (180) one small query asks GitHub whether the scope's PRs changed: a push, merge or close,
  draft, the title or description edited, a new review or reply, requested reviewers, the review
  decision, CI state, threads added or resolved. A PR that changed is marked (`↻` on its row,
  `(new on GitHub · R)` on the detail heading, `(new)` on the threads line, `new on GitHub · R to
  refresh` on the description) and nothing shown is replaced until you press `R`, which fetches
  everything and clears the marks (other layers' too). Back from another window or tab
  (`FocusGained`), it checks at once if one is due; none runs while a review is being submitted. Not detected: an edited review comment, a PR opened for a branch that had
  none (`R` finds it), changes to other layers' PRs while one layer is viewed. A failed check is
  only logged. `forge.check = false` turns it off. Each check costs one GraphQL rate-limit point
  (of 5,000 an hour). **`forge.ttl` changed meaning:** it used to be how long PR data was cached
  before a redraw refetched it (60); it is now the interval between checks, and at least 60
  seconds (an old `ttl = 0` meaning "always fresh" checks every minute, not nonstop).
- **Failures are quiet.** No `gh`, not logged in, offline, timed out, rate limited or unexpected
  output: nothing new is shown (PRs already shown stay, marked stale), and the reason is written
  to the log file (`log_file`, default `stdpath('log')/revuey.log`, moved to `revuey.log.1` at
  256KB). Repos without a GitHub remote make no call at all.

```lua
require('revuey').setup({
  -- ttl: seconds between checks for news on GitHub, at least 60 (nothing is refetched until `R`)
  forge = { enabled = true, ttl = 180, check = true, timeout = 15, cmd = 'gh', hosts = { 'git.example.com' } },
  keymaps = { forge_open = 'gx' },
})
```

### The PR description

When the review is backed by an open pull request with a description, the description is shown
above the first file of the diff view (not in the guide view), as text:

```
          PR #42 · Cart totals with discounts
            Why

            Totals ignored discounts; fixes #7.

            What
            • Cart.total() sums each line with multiply
            … 8 more lines (<Tab> expands)

  A     ▾ src/cart.ts   +20 −0  added
```

- **Which PR.** The viewed layer's (a plain review's branch's), open or draft. In full-stack scope,
  every layer's open PR, bottom first, each collapsed. Merged and closed PRs, an empty
  description, or one that is only a PR template's `<!-- -->` comments show nothing.
- **Rendered as text.** Headings, lists, code, quotes, tables and rules like comments are rendered;
  HTML comments are removed; images (`![alt](…)`, `<img alt>`) show as `(image: alt)` and links as
  their text; `<details>` shows its summary as `▸ …` with the content below; other HTML GitHub
  allows becomes its text. Nothing is fetched.
- **Collapsed** to `max_lines` body lines (6) with `… N more lines`. `<Tab>` on the description
  expands or collapses it; it is a normal fold, so `zo`/`zc`/`za` work too. Your choice is kept
  across refreshes and scope switches.
- **It never moves the view.** It comes with the PR lookup, in the background, so it usually
  arrives after the review is drawn: it is inserted above the first file and the view scrolls
  with it, so the line you are on stays where it is on the screen (when part of the description is
  on screen above it, a longer description pushes the code down). With the first file at the
  top, the winbar says `↑ PR description`: `gg` (or `k`) shows it. It waits while you are in
  Visual or Insert mode or writing a comment.
- **When.** It is part of the PR lookup: the same call and cache; `R` fetches it again and an
  edited description is updated in place. When the title or description changed on GitHub
  since, its title line ends `· new on GitHub · R to refresh`. Failures show nothing (a
  description already shown stays, its title line ending `· stale`) and are logged like the
  lookup's.

```lua
require('revuey').setup({
  forge = { description = { enabled = true, expanded = false, max_lines = 6 } }, -- or false
})
```

### Review threads from GitHub

The review threads of an open PR are drawn inline next to your own [comments](#comments), in the
diff and the guide: the PR of the layer you are viewing (or of a plain review's branch), and in
full-stack scope every layer's open PR. Each thread is marked `GitHub #42`; GitHub logins stand in
for authors.

```
     18▍+     return sum(this.items.map((i) => multiply(i.price, i.quantity)));
          ╭─ carol · 2026-01-03 · GitHub #42 ─────────────────────────────────
          │ Should the total be rounded to cents?
          │ ↳ alice · 2026-01-03
          │   Good point, will do.
          ╰─
```

- **Where.** A thread goes on the lines GitHub gives it (`line`/`startLine` on the new side, or
  the old side for comments on deleted lines; file threads under the file header), but only when
  the text there is what the thread's diff hunk shows, and either your copy of the file is the
  PR's head commit's (no local edits; revuey asks git for the blob), or the lines just above it
  match the hunk's too (at least one of them; all of them for lines with little text, such as
  `end`, `}` or `return err`), or the line is distinctive and has no copy within 100 lines (a
  later push may have edited the lines above). The review is often not exactly the PR's diff (uncommitted edits, local commits not
  pushed yet, commits pushed since, or the full-stack scope, where a lower PR's lines have
  moved): then the same lines with the same context are looked for within 100 lines of the
  file, and used only when there is exactly one such copy and the diff shows it (the header
  then says `GitHub line 18`). A thread GitHub marks outdated is looked for the same way by the
  text it was made on, so it stays on its code while that code is still there. A thread that
  can't be placed (its code changed locally or on GitHub, outside this diff's hunks, or the
  match is ambiguous) is listed under "GitHub threads on lines not shown here" at the end of its
  file, never on a guessed line; one on a file not in the view goes to the end of the review.
- **State.** Resolved threads (`resolved by alice`) and threads GitHub marks `outdated` are
  collapsed to their first line, like resolved comments; `cz` expands one. The viewer's own
  unsubmitted review comments are marked `pending`. `gH` cycles what is drawn: all threads, open
  ones only, none. `]m`/`[m` and the comments list (`cl`, a "GitHub threads" part) include them.
  The PR section in the panel counts them (`threads: 2 open, 1 resolved`, plus `more on GitHub`
  when the list was cut, `(new)` when threads were added, answered or resolved on GitHub since
  (`R` shows them), and `(stale)` when the last fetch failed and these are the threads from
  before).
- **Read-only.** Threads are never changed from revuey (posting a review, below, only adds to
  them). `gx` on a thread opens it in the browser (elsewhere
  in the diff the key does what it does outside revuey: Neovim's `gx`, or your own mapping when
  `keymaps.forge_open` is another key). `ce`, `cx`, `cd` and `cs` say the thread is read-only.
  `cr` writes a **local reply**: a comment of yours on the thread's lines, labelled `local reply to
  GitHub #42 thread` and linked to the thread; [posting a review](#posting-a-review-to-github)
  sends it as a reply in that thread. It lives in your comments file like any comment; the
  threads themselves are never stored.
- **When.** After the PR lookup, in the background (opening a review never waits for GitHub): one
  `gh api graphql` call for the scope's open PRs, more only for long lists (50 threads per page,
  each thread's first 20 comments, then 100 at a time; at most 10 rounds, after which a thread
  says `… N more on GitHub`). Fetched the first time a scope shows the PR, then kept: scope
  switches and refreshes reuse them, `R` fetches again (as does submitting a review). Failures are quiet as above: threads already
  shown stay, nothing else changes, and the reason is in the log file.

```lua
require('revuey').setup({
  forge = { threads = { enabled = true, show = 'all' } }, -- show: 'all' | 'open' | 'none'
  keymaps = { forge_threads = 'gH' },
})
```

### Posting a review to GitHub

Your comments stay local until you post them. `ci` on a comment adds it to the review ("add to
review", marked `in review`; again takes it out); `gP` or `:RevueySubmit [approve|comment|request-changes]`
posts every comment added in the scope you are viewing as **one GitHub review** with a verdict,
through your `gh`. Nothing is added unless you pick it. Only your own saved comments can be
added: an AI review finding or an [agent's comment](#connect-an-agent) once you accept it
(`ca`), and the local replies `cr` makes on GitHub threads (posted as replies in their threads);
not untriaged agent comments or findings, drafts or resolved comments. The panel shows
`gP submit review` whenever the scope has an open PR (a verdict needs no comment), with
`(2 in review)` once comments are added.

**Add to pending review** (no verdict, nothing submitted): pick it as the last choice of the
verdict prompt, run `:RevueySubmit pending`, or press `Add to pending review` in a verdict's
confirmation (offered when it would add something; its text says how many `+` comments go to
which PR). The comments go into your pending review on GitHub (the one you started in GitHub's
UI or in Graphite, reused, never a second one; else a new one) and stop there: only you can see
them, and you edit and submit the review on github.com or in Graphite, or with a later `gP`.
Everything below applies as for a submit (the same reading first, the same confirmation of
exactly what is added, the same records), except that nothing is submitted and the PR's other
pending comments stay as they are. A review you then submit on GitHub, or with `gP`, is found by
the next `gP`, which marks the comments `posted` and sends nothing twice; a pending comment you
edit on GitHub is still recognised by its id (the confirmation says `edited on GitHub since`
and shows GitHub's text; your local copy is never overwritten).

A typical flow with a coding agent: ask it to review the PR into revuey; it leaves its points as
local comments ([`bin/revuey comment`](#connect-an-agent)), which are drafts for you. `ca` makes
one yours (`accepted from agent`), `ce` edits it, `cn` dismisses one, `ci` adds yours to the
review, and `gP` → `Add to pending review` puts them in your pending review, where you finish
the review in GitHub's or Graphite's UI. Nothing reaches GitHub until you confirm a `gP`.

What happens, in order:

1. **Reading (nothing is sent).** revuey reads the PR's files as GitHub has them, the PR itself
   (its head commit, your pending review, its latest reviews) and every review it sent comments
   to before, and settles what became of those (below). Each comment is checked against GitHub's
   diff (below); what can't be posted is left out with the reason.
2. **Confirmation.** The verdict (or "Add to your pending review"), and per PR exactly what will happen: the comments and replies
   revuey will add (`+`), those already in your pending review (`=`, with GitHub's text when you
   edited one since, here or on GitHub), the comments your pending review has from elsewhere (submitted too), the
   commit it is bound to when that is not the one you reviewed, PRs that are blocked and why,
   and everything left out with the reason; in the full-stack scope every PR of the stack
   (`PR #13: nothing to post, no review`). `Write body` adds a review body (a Comment review
   with nothing in it needs one). `Add to pending review` adds the `+` comments without
   submitting (not offered when a PR is refused only for the verdict, such as approving your
   own PR: use `:RevueySubmit pending`). Cancel leaves GitHub untouched.
3. **Sending.** On a PR where you have no pending review and everything is a line comment, one
   request creates and submits the review with all its comments: it exists whole, or not at all.
   Otherwise (your pending review there, started in GitHub's UI or another tool such as
   Graphite, which is reused and never replaced or emptied; or replies to threads and file
   comments, which need it; or `Add to pending review`, which always works this way) the comments
   go into the pending review, then it is submitted, only when every comment went in (with `Add
   to pending review`, never). Before each request revuey saves what it sends, so a request that
   gets no answer (a timeout) or a Neovim that dies meanwhile leaves a record.
4. **Posted.** Posted comments are marked `posted to GitHub #42` and the threads are fetched
   again: from then on the GitHub thread stands for the comment (your local copy is not drawn
   twice; with GitHub threads hidden, `gH`, it shows with the `posted` mark; one with local
   replies, which are not posted, stays shown, collapsed).

**When GitHub does not answer.** The next `gP` first looks for what was sent, exactly as it was
sent (not your comment as it is now): found once, it is recorded (`in your pending review on
GitHub #42`, or posted); proven absent (the review read whole without it), it is forgotten and
sent again if it is still in the review. Anything else (GitHub unreadable, a pending review too
long to read whole, two comments it cannot tell apart, a comment of yours from elsewhere with
the same text, or any comment of yours on its lines or in its thread, which may be it edited on
GitHub) marks it `maybe on GitHub #42 (unconfirmed)` and blocks that PR: nothing more
goes to it until a later `gP` can tell. Check the PR on GitHub; then `Forget unconfirmed` in the
confirmation drops revuey's records of what it sent to the blocked PRs (comments and reviews),
and `:RevueySubmit forget` on a comment drops its record; either may make a later submit post
it twice, so both warn first. A submit with no answer is found the same way and never sent
twice. Just before your pending review is submitted, revuey reads it again: if another tool
added comments to it while the confirmation was open, nothing is submitted (the next `gP`
shows them). Comments you take out, edit or delete while the confirmation is open are not sent. A
comment in your pending review that you take out with `ci` stays there until you delete it on
GitHub; then revuey forgets it. One that was in your pending review and is gone from it (you
deleted it on GitHub, or discarded the review) is taken out of the review, listed with that
reason, and not added again unless you `ci` it again. A failed or cancelled submit leaves your pending review as it
is. One submit runs at a time per Neovim; two Neovims on the same review do not see each
other's submit, so do not submit from both at once. In the full-stack scope only PRs with
comments from revuey get the verdict; a pending review of yours on another PR of the stack is
mentioned, not submitted.

**Which line on GitHub.** GitHub numbers a comment's lines in the file at the PR's head (the old
side: in its base), and only takes lines inside the PR diff's hunks. A comment is posted on the
line you wrote it on, or not at all:

- New-side lines: your copy of the file must be exactly the file at the PR head (so a file with
  uncommitted or unpushed changes is refused, whichever lines you commented), and the lines must
  be inside one hunk of the PR's diff. A range goes as GitHub's `startLine`..`line`.
- Old-side lines (deleted code): inside one hunk, and that hunk's old lines read the same as
  yours.
- The PR head must be the commit the review shows for that layer: when it moved on GitHub, or you
  have unpushed commits, nothing goes to that PR (fetch or push, then `R`).
- In the full-stack scope each comment goes to the open PR whose diff adds (or deletes) the
  lines: a line added by `stack/cart` but in a file `stack/ui` changed again is refused, with a
  hint to post it from `stack/cart`'s scope. Each PR gets its own review with the verdict;
  PRs without comments get none.
- File comments go to the PR that has the file as you see it.
- GitHub does not let a PR's author approve it or request changes; that is refused before
  anything is sent.

```lua
require('revuey').setup({
  keymaps = { comment_include = 'ci', forge_submit = 'gP' },
})
```

GitHub's per-file "viewed" checkboxes are not synced.

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
3. A URL must name the repo worktrunk uses (it looks the number up there whatever the URL
   says, so revuey refuses another repo's URL instead of opening a different PR). That is gh's
   default repo (`gh repo set-default`), else the first remote with a GitHub URL in
   `.git/config` order (not necessarily `origin`). In a fork clone, `gh repo set-default`
   picks which of the two `:Revuey pr` opens PRs of. worktrunk's own errors are shown as it words them: `gh` missing, no GitHub
   remote, an unknown PR, a failed hook.

**Approvals.** worktrunk asks before running a repo's *project* hooks (`.config/wt.toml`) the first
time, and again when they change; in the background it cannot ask and refuses. revuey never
passes `--yes`: it shows the commands and offers to run the same `wt switch` in a terminal split,
where you answer worktrunk's own prompt (or decline: worktrunk then skips the project hooks); the
review opens when it succeeds. Closing the terminal (`:q` on its window, `:bd!`) while
worktrunk waits stops it; switching to another buffer there (to read `.config/wt.toml` first,
say) does not, and `:Revuey pr` shows the terminal again. You can also approve beforehand with `wt config approvals add` in
the clone. Hooks in your user config (`~/.config/worktrunk/config.toml`) need no approval.

**A failed hook** leaves the worktree behind (worktrunk does not remove it); the message names it
and shows the last lines the hook printed (the end of worktrunk's output goes to the log file,
`stdpath('log')/revuey.log` by default, which the message names).
`:Revuey pr` again opens it as it is, since `pre-start` only runs when the worktree is created:
re-run the hooks with `wt -C <path> hook pre-start`, or remove the worktree.

**Cleanup** is yours; revuey never removes worktrees. Close the review first (its language
servers run in the worktree), then `wt remove <branch>` (or the worktree's path) removes the
worktree, and the branch too when it is merged (`--no-delete-branch` keeps it, `-D` deletes an
unmerged one). `wt list` shows them all.

`pr` is always this subcommand: to review against a base branch named `pr`, use
`:Revuey refs/heads/pr` (or `revuey refs/heads/pr`).

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

**Line notes.** Claude can also pin a short note to a line, or a few lines, it wants you to
look at: "The cache key is built here.", "Note the early return for empty carts." A note is
drawn right above its lines, as a violet band labelled `▼ guide` (`▼ guide · 3 lines` for a
range), so it reads differently from comment boxes, AI review findings and GitHub threads, which
sit below their lines. Notes are rare by design: at most 3 per section and 12 per guide, and
never a bug report (those belong in an [AI review](#ai-review)).

- `]n` / `[n`: next / previous line note (takes a count).
- `gN`: collapse every note to a `◆ guide` marker at the end of its line, and back.

Notes belong to the guide, not to your comments: they are not in the comment list, `]m`,
exports, the agent link or anything posted, and they are not shown in the diff view, where the
code stays yours. Claude points at a line by its hunk id and the line's number within the hunk,
as AI review findings do; a note on a line the prompt did not show (or an unknown hunk) is
dropped, never moved, and the "guide ready" message counts the drops. Guides made before line
notes existed load as they are, without notes. After an edit, a note on an edited hunk stays
only where its lines and the two lines around them are found again unchanged, in one place (a
note is never handed to a copy of a short line like `return nil`); the banner counts the ones
that were lost.

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
commit subjects, a file list and the diff, with each hunk marked by an id (`@@ h7 path @@`) and
its lines numbered within the hunk (`3|+text`, for line notes); Claude only refers to hunks by
id, and revuey checks the answer (unknown ids are dropped, missed hunks go to an "Other changes"
section, line notes on lines that were not shown are dropped). The line numbers cost about 5-7%
of the diff's share of the budget, so a diff just under the limit may now be sent abridged. The whole prompt stays under `ai.max_prompt_chars`
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
(ai)`, on the lines it is about, for you to triage (only once you accept one can you add it to a
[review you post](#posting-a-review-to-github)):

```
╭─ claude (ai) · just now · major · ca accept · cn dismiss ─────────
│ Import both helpers from one place
│
│ Two imports of the same module drift apart.
╰─
```

- `ca` **accepts** it: it becomes your own comment ("accepted from AI review"), to edit, resolve
  or later post like any other. The same keys triage an agent's comments
  ([`bin/revuey comment`](#connect-an-agent)): accepted, one is marked "accepted from agent".
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
- When the branch has an open pull request, its GitHub review threads are drawn next to your
  comments, read-only (see [Review threads from GitHub](#review-threads-from-github)). They are
  not in your comments file, the export or the agent feed; a local reply (`cr` on a thread) is.

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
4. Ask Claude to leave you a comment ("point out in revuey where the retry logic lives", or
   "review this PR and leave comments") and it adds a new thread with `bin/revuey comment`; it
   shows up at once, labelled with the agent's name (`agent`, or `$REVUEY_AGENT_NAME`) and
   highlighted as the agent's. It is a **draft for you**: `ca` accepts it (it becomes your
   comment, "accepted from agent", to edit with `ce` and add to a review with `ci`), `cn`
   dismisses it (collapsed, kept; again restores it). Until you accept it, it cannot be posted;
   [`gP`](#posting-a-review-to-github) can then add it to your pending review on GitHub, to
   finish there, or submit it. The agent never posts anything itself.

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
local only: nothing is posted to GitHub. Your `ca`/`cn` on it append `accepted`/`dismissed`
events (`watch` prints `accept …`, `dismiss …`, `restore …`); exports mark it `a draft for the
user, not accepted yet`, or once accepted `accepted from a comment by claude (agent)`, and
leave dismissed ones out unless `--all`. Replies an agent makes in your threads (`reply`) are
answers to you, not drafts: they are not triaged or posted (`ca` there says there is nothing
to accept; copy what you want into your own comment).

A `watch --messages` line looks like this (`--json` prints the full event instead, with the
anchor, the code, the message and the review: repo, branch, scope, base):

```
revuey message 19a3f0c2d4e1a8b7f src/cart.ts:12-14 (new) [stack/cart]: Why multiply here?  (/home/me/dev/revuey/main/bin/revuey show 19a3f0c2d4e1a8b7f for full context)
```

When you [check out another layer](#checking-out-a-layer) (`gS`, `:RevueySwitch`, `]s`/`[s`
with `switch_on_navigate`), the watch of that review prints a line saying so (a `switched` event
in the feed; live only: neither a later watch nor `--since` prints it again):

```
revuey switched stack/cart -> stack/math (layer 1 of 3, PR #12 https://github.com/me/shop/pull/12): the worktree has stack/math checked out now and the review shows that layer; files on disk changed, so re-read them, and focus on this layer from now on
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
  `2/5` hunks when partly reviewed). Files are listed under a header per folder, so you can see
  which services, layers or test folders a change touches:
  ```
   ./
       M  README.md            +1 −1
   packages/api/src/routes:
     ✓ M  billing.ts           +3 −1
       A  refunds.ts          +40 −0
   packages/api/test:
       A  billing.test.ts     +12 −0
  ```
  Folders come in tree order (files at the repository root under `./` first, a folder before its
  subfolders), files by name within each, and the diff and `]f`/`[f` follow the same order. A
  header that does not fit is shortened fish-style (`packages/a/s/routes`, then
  `packages/…/routes`, then `…/routes`); when every folder shares leading folders (everything
  under `src/`), they are left out of the headers and named once above them (` in src/`). A
  folder whose files are all reviewed is dimmed. `panel_folders = false` gives the flat list (git's
  path order, each file's folder after its name). The comment list, the AI findings and
  `bin/revuey hunks` follow the same order.

  Upgrading to the folder order: hunk ids follow the file order, so an AI review document made
  with `bin/revuey hunks` before the upgrade is refused once ("the code changed": run `hunks`
  again), and a saved guide is not found once (generate it again). Reviewed marks and comments
  are kept.
- **Diff (right):** one continuous buffer for all files.

Every diff line is a real buffer line, and its text is exactly the source text. The `+`/`-` markers,
old/new line numbers and file status are drawn in the `statuscolumn`. The winbar shows the file at
the top of the window, and the keys that work on a comment or note under the cursor ([Finding the
keys](#finding-the-keys)). Reviewed files and very large files start folded.

## Keymaps

### Finding the keys

- **`g?`** opens every revuey key in a float (`q`, `<Esc>` or `g?` closes it), grouped as below
  and read from your `keymaps` config, so a rebound key shows its new key and a disabled one
  (`false`) is left out. It works in the diff view, the guide view and the file panel, whose last
  help line says ` g? all keys`.
- **The winbar** names the keys that work on the line under the cursor while it is on a comment,
  an AI finding, an agent's comment, a GitHub thread or a guide line note, for what it is now:
  `ce edit · cr reply · ci add to review · cx resolve · cd delete` on your comment (`ci remove from
  review` once added, no `ci` once posted, `cx reopen` when resolved), `ca accept · cn dismiss · cs
  ask agent` on an untriaged finding or agent comment, `cr reply · gx open` on a GitHub thread
  (`cz expand` when a thread or comment is cut), `]n/[n next/prev · gN hide notes` on a guide
  note. Only keys that would work are named, most useful first. While the hint shows it takes the
  winbar's right side (the file count, `↑ PR description`, the guide's `§`/`✓` counters: the panel
  has them too; a `new on GitHub · R` mark stays). In a narrow window the last keys are left out
  first, keeping 20 cells for the file or section on the left; a longer name is then cut from its
  start. The hint shows while the diff window has focus.

Diff and guide buffer (the tables are generated from `lua/revuey/keys.lua`, the list `g?` shows:
`nvim --headless --clean -l scripts/readme-keys.lua`):

<!-- keys:begin -->
**Comments**

| Key | Action |
|---|---|
| `gc` | [Comment](#comments) on this line (visual: the selected lines; a file or hunk header: the whole file) |
| `ce` | Edit the comment on this line |
| `cr` | Reply to the comment (on a GitHub thread: a local reply) |
| `cx` | Resolve the comment, or reopen a resolved one |
| `cd` | Delete the comment (asks first) |
| `cz` | Expand / collapse a long or resolved comment |
| `ca` | [AI review](#ai-review) finding or [agent comment](#connect-an-agent) on this line: accept it as your comment |
| `cn` | Dismiss the AI finding or agent comment (again: restore) |
| `ga` | [Ask the agent](#connect-an-agent) about this line or the selection |
| `cs` | Send the comment on this line to the agent |
| `<C-a>` | In the comment editor: save and send to the agent |
| `]m` / `[m` | Next / previous comment (takes a count) |
| `gC` | Hide / show the comment threads |
| `cl` | List all comments (`<CR>` jumps) |

**Review and posting**

| Key | Action |
|---|---|
| `mr` | Toggle reviewed. On a hunk header or any line of a hunk: that hunk (it collapses, and the cursor moves to the next unreviewed hunk you can see, skipping collapsed files). On a file header: the whole file (marks every hunk when any is unreviewed, else unmarks them all; collapses the file and moves to the next unreviewed one). In visual mode: every hunk the selection touches (a collapsed file in the selection counts whole). A file whose hunks are all reviewed collapses; its header shows `✓ reviewed`, or `◐ 2/5` while partly reviewed. Unmarking a file re-expands the hunks that were collapsed because they were reviewed, not the ones you collapsed with `<Tab>` |
| `ci` | Add the comment on this line to the [review to post on GitHub](#posting-a-review-to-github) / take it out |
| `gP` | Submit the review to GitHub (`:RevueySubmit`): pick a verdict (or add to your pending review, not submitted), then a confirmation |

**Navigation**

| Key | Action |
|---|---|
| `]c` / `[c` | Next / previous hunk (skips collapsed files and hunks; takes a count) |
| `]f` / `[f` | Next / previous file |
| `]]` / `[[` | Guide view: next / previous section. Diff view: next / previous file |
| `gd` | LSP definition (added/context lines). Jumps within the diff when the target is shown there, otherwise opens the file below |
| `K` | LSP hover |
| `gp` | Focus the file panel |

**Layers and switching**

| Key | Action |
|---|---|
| `]s` / `[s` | Next / previous stack layer (takes a count). These shadow spell navigation, which is off in review buffers. |
| `gs` | Toggle full-stack scope and back to the last layer |
| `gS` | [Check out](#checking-out-a-layer) the layer being viewed in this worktree (`git switch`) |
| `gb` | The [stack tree](#stack-trees-from-github): every PR of the stack on GitHub, to pick the path to review |
| `gF` | `git fetch` the stack's PR branches from their remote (layers marked `⇣`, "not fetched" or "origin behind") |
| `j k` in the stack tree | Down to the PR this one is based on (toward the trunk) / up the column; the path from the trunk to the PR under the cursor lights up, and the footer shows it |
| `h l` in the stack tree | The nearest PR in the column to the left / right: how to swap to another branch at a fork (`l` on a fork point goes into its own branches) |
| `<CR>` in the stack tree | Review the path through the PR under the cursor; `q`/`<Esc>` close without a change |
| `C` | In the stack tree: show / hide closed PRs |
| `!` | [Stack notes](#stack-notes) in full, with actions (also in the file panel) |
| `gu` | Toggle working tree (default) / committed only |

**GitHub**

| Key | Action |
|---|---|
| `gx` | On a GitHub thread: open it in the browser (elsewhere: Neovim's `gx`) |
| `gH` | [GitHub review threads](#review-threads-from-github): all / open only / hidden |

**Guide**

| Key | Action |
|---|---|
| `gG` | Toggle the AI guide view (offers to generate a guide when there is none) |
| `gR` | Generate a new AI guide (asks first when one exists) |
| `]n` / `[n` | Guide view: next / previous [line note](#ai-guide) (takes a count) |
| `gN` | Guide view: collapse the line notes to markers, or show them in full |
| `<CR>` on the guide's diagram | On a box: jump to its section. On the "Overview" heading: fold / unfold the diagram (like `<Tab>`) |

**Files and folds**

| Key | Action |
|---|---|
| `<CR>` / `go` | Open the working-tree file at this line (in a split below) |
| `ge` | [Edit](#editing-from-the-review) the real file at this line in a float (checked-out layer, working-tree mode) |
| `<Tab>` | On a file header or hunk header: collapse / expand that file or hunk (does not mark it reviewed). On a long [PR description](#the-pr-description): expand / collapse it. On any other line it is `<C-i>` (jump forward, takes a count), since most terminals send the same key for both |
| `<S-Tab>` | Collapse every file, or expand them all when all are collapsed |
| `za` etc. | Normal fold commands: each file is a fold, each hunk a fold inside it, and long unchanged runs are folded |

**Other**

| Key | Action |
|---|---|
| `R` | Refresh (re-runs git; also automatic in working-tree mode) |
| `g?` | All keys in a float, as configured (`q` closes) |
| `q` | Close the review (quits Neovim when started via `bin/revuey`) |
<!-- keys:end -->

`<Tab>` and `<S-Tab>` are buffer-local, so in revuey's diff/guide buffer they override your own
`<Tab>`/`<C-i>`/`<S-Tab>` mappings (only there). A count (`3<Tab>`) always means jump forward. Set
`keymaps = { toggle_fold = false, toggle_all_folds = false }` to leave those keys alone.

File panel:
- `<CR>`/`o`: show the file and focus the diff. On a folder header, its first file. On a stack row, switch to that layer (or the full stack).
- Moving the cursor previews files in the diff. Folder headers are labels: the cursor stops on
  them (nothing is previewed, `mr` does nothing there), and while it is on one the diff's winbar
  shows `<CR> first file in` and the folder's full path (the header may be shortened).
- `mr`, `gu`, `R`, `]s`, `[s`, `gs`, `!`, `gG`, `gR`, `cl`, `gP`, `g?`, `gp` (back to the diff) and `q` work as in the diff buffer.
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
`RevueyGuideWarning`, `RevueyGuideHunkNote`, `RevueyGuideOutdated`, the line notes'
`RevueyGuideLineNote` (the band), `RevueyGuideLineNoteLabel` and `RevueyGuideLineNoteMarker`, the diagram's `RevueyDiagramNew`,
`RevueyDiagramChanged`, `RevueyDiagramContext`, `RevueyDiagramEdge`, `RevueyDiagramLabel`, the
stack's `RevueyLayerLabel`, the stack notes' `RevueyStackNote` (dim) and `RevueyStackWarn`, the comments'
`RevueyCommentSign`, `RevueyCommentBorder`, `RevueyCommentAuthor`, `RevueyCommentDraft`,
`RevueyCommentResolved` and `RevueyCommentOutdated`, AI reviews' `RevueyAiCritical`, `RevueyAiMajor`,
`RevueyAiMinor`, `RevueyAiNit` (severities), `RevueyAiApprove`, `RevueyAiComment`, `RevueyAiChanges`
(verdicts) and `RevueyAiTriage`, the pull requests' `RevueyForgeApproved`,
`RevueyForgeChanges`, `RevueyForgePending`, `RevueyForgeNone`, `RevueyForgeDraft`, `RevueyForgeMerged`,
`RevueyForgeClosed`, `RevueyForgeNumber`, `RevueyForgeDim` and `RevueyForgeWarn`, GitHub review threads'
`RevueyForgeBorder`, `RevueyForgeAuthor` and `RevueyForgeSign`, the PR description's
`RevueyForgeDescriptionTitle`, `RevueyForgeDescriptionMore` and `RevueyForgeDescriptionRule`, the winbar's
key hint `RevueyKeyHint` and `RevueyKeyHintKey` (also the keys in the `g?` float, with `RevueyKeyHelpGroup`), and others (see
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
- If Claude added line notes (a violet `▼ guide` band above a line), `]n` / `[n` move between
  them and `gN` collapses them to `◆ guide` markers. `gG`: the diff view shows none.

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
  Line notes: anchors checked against the numbered lines the prompt showed (bad ones dropped and
  counted by reason), caps, storage, following an edited hunk, sanitising on load, old guides.
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
  and replays canned stream-json (good, diagram, line notes with bad anchors, invalid, missing hunks, unknown ids, errors, slow, hang),
  so the tests never need the network or a subscription.
- **Checking out a layer** (`switch_spec.lua`): the `gS` decision (local, remote with a tracking
  branch, a conflicting local name, a fresh `--track`, detached, already on it), collisions, the
  parent setting, status and worktree parsing and the message texts (unit); then real git, each
  test on its own fixture: local and remote-only layers (marks and comments carried over, the
  parent setting keeping the layer below after commits and reopening), stray remote refs never
  becoming layers, no self-parent, a deleted and reused branch name, a conflicting name, dirty,
  untracked, ignored and file-for-directory refusals, unsaved buffers, a branch in another
  worktree, a failing hook, a submodule bump, telling a connected agent (no question; the
  `switched` event's fields and a real `watch --messages` printing it; nothing without an agent; a
  failed write logged while the switch stands; refusals and the conflicting-name question
  unchanged; `]s`/`[s` switches coalesced), `switch_on_navigate`, one switch at a time, the
  registry and `sessions`, hidden LSP buffers and `:RevueySwitch`.
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
