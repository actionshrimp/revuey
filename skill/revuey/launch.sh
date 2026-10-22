#!/usr/bin/env bash
# Open revuey in a new pane next to the agent (tmux or herdr) and return at once; revuey keeps
# running while the agent watches it.
#   launch.sh [directory] [-- revuey args...]      e.g. launch.sh . -- --stack
# Prints the pane and the review session id once revuey has registered (up to 20s).
# Exit 3: no tmux or herdr here (the user has to start revuey); exit 4: a review is already
# running in that worktree (attach to it instead).
# REVUEY_PANE_SIZE: width of the new pane in percent (tmux, default 60).
set -euo pipefail

skill_dir=$(cd "$(dirname "$0")" && pwd -P)
revuey=$skill_dir/revuey

dir=.
if [ -n "${1:-}" ] && [ "$1" != "--" ]; then
  dir=$1
  shift
fi
if [ "${1:-}" = "--" ]; then
  shift
fi
dir=$(cd "$dir" && pwd)

sessions() {
  (cd "$dir" && "$revuey" sessions) | grep -v '^no revuey sessions' || true
}

before=$(sessions)
if [ -n "$before" ]; then
  echo "revuey is already running in $dir:"
  echo "$before"
  echo "Attach to it: $revuey watch --messages [--session <id>]"
  exit 4
fi

cmd=$(printf '%q' "$revuey")
for a in "$@"; do
  cmd="$cmd $(printf '%q' "$a")"
done

if [ -n "${TMUX:-}" ]; then
  pane=$(tmux split-window -h -P -F '#{pane_id}' -l "${REVUEY_PANE_SIZE:-60}%" -c "$dir" "$cmd")
  where="tmux pane $pane"
elif [ "${HERDR_ENV:-}" = "1" ]; then
  command -v jq >/dev/null 2>&1 || { echo "launch.sh: herdr needs jq to read pane ids" >&2; exit 1; }
  pane=$(herdr pane split --current --direction right --cwd "$dir" --focus | jq -er '.result.pane.pane_id')
  # the pane's shell may not be bash: hand it one single-quoted bash -c argument
  inner=${cmd//\'/\'\\\'\'}
  herdr pane run "$pane" "bash -c '$inner'; exit" >/dev/null
  where="herdr pane $pane"
else
  echo "No tmux or herdr here, so revuey cannot be opened in a pane."
  echo "Ask the user to run this in another terminal (or :Revuey in their Neovim), in $dir:"
  echo "  $cmd"
  echo "Then attach with: $revuey watch --messages"
  exit 3
fi

for _ in $(seq 1 80); do
  now=$(sessions)
  if [ -n "$now" ]; then
    echo "revuey is open in $where; review session:"
    echo "$now"
    exit 0
  fi
  sleep 0.25
done
echo "revuey was started in $where but has not registered a review yet (it may be asking something, or failed); check the pane."
