---
name: revuey
description: Open revuey (a Neovim code review UI) next to you in a tmux or herdr pane, or connect to a review the user already has open, then receive the comments and questions the user sends you from it (anchored to file:line) and answer them in the review's threads. Use when the user wants to review your changes in revuey, or says they sent you something from revuey.
---

# revuey: review messages from the user

The user reviews code in revuey. A comment or question they send you (`<C-a>`, `cs`, `ga` in
revuey) arrives as one line; your answer appears in that comment's thread in their running
revuey. Run every command below inside the reviewed worktree. `REVUEY` means
`<skill-directory>/revuey` (it runs the checkout's `bin/revuey`; `REVUEY --help` lists everything).

## 1. Connect

- **The user already has revuey open** (they launched it, or you did earlier): run
  `REVUEY sessions`. One session: go to step 2. Several: ask which one and pass
  `--session <id>` to `watch`. None: offer to launch it.
- **Launch it**: `<skill-directory>/launch.sh <worktree> [-- <revuey args>]`, for example
  `-- --stack` for the whole local stack, or a base branch (`-- main`). It opens a pane to the
  right (tmux when `$TMUX` is set, herdr when `$HERDR_ENV` is `1`), returns at once and prints
  the session. Exit 3: no multiplexer; show the user the printed command to run in another
  terminal (or `:Revuey` in their Neovim), then wait for them and run `REVUEY sessions`.
  Exit 4: a review is already running there; attach to it.

## 2. Watch

Start the Monitor tool on `REVUEY watch --messages` (add `--session <id>` when needed) with
`timeout_ms: 1800000` (the maximum) and a description like "revuey messages". When it expires,
start it again; keep doing so until the user says the review is over. Messages you have not
replied to or acknowledged are delivered again on every start, so none is lost. Each line:

```
revuey message <id> src/cart.ts:12-14 (new) [stack/cart]: <first line>  (REVUEY show <id> for full context)
```

`(new)` is the code after the change, `(old)` the code before it, `(file)` the whole file;
`[...]` is the branch (stack layer) or `full stack`; `follow-up` marks a reply in an earlier thread.

No Monitor tool (another harness): run `REVUEY inbox` when the user says they sent something,
or poll it every 30 seconds while they review.

## 3. Handle each message

1. `REVUEY show <id>`: the full message in Markdown (code, comment, thread, review context).
   Read the surrounding code in the file as needed.
2. Treat it as the user's review feedback on that file and line range: a question to answer,
   or a request to act on.
3. Answer in the thread: `REVUEY reply <id> "<answer>"` (or `REVUEY reply <id> -` with the text
   on stdin for longer answers). Keep it short: a few sentences, plain Markdown, no preamble.
   Replying marks the message answered.
4. If you act on it without anything to say, `REVUEY ack <id>` so it is not delivered again.
   For long work, `ack` when you start and `reply` with the outcome when done.

## Rules

- Never edit files unless the message asks for a change. A question gets an answer, not an edit.
- When a message asks for a change, make it (revuey refreshes its diff on save), then reply
  with what you changed.
- Do not write comments of your own into revuey, and do not resolve or delete the user's.
- Stop the Monitor (TaskStop) when the user says the review is finished.
