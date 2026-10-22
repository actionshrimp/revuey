#!/usr/bin/env bash
# Open revuey in a new pane next to the agent and return at once; revuey keeps running while the
# agent watches it.
#   launch.sh --in tmux|herdr|none <directory> [-- revuey args...]    e.g. ... -- --stack
# The target is explicit and verified: tmux splits $TMUX_PANE after checking that the tmux
# server knows it; herdr splits $HERDR_PANE_ID after `herdr pane get` finds it. Anything else is
# refused, never guessed. `--in none` prints the command for the user to run.
# Prints the pane and the review session once revuey has registered.
# Exit: 0 started; 1 bad directory; 2 no or unverifiable target; 3 (--in none) the user has to
# start revuey; 4 a review is already running there (attach to it); 5 started, but no review
# registered within $REVUEY_LAUNCH_TIMEOUT seconds (default 20; check the pane).
# REVUEY_PANE_SIZE: width of the new tmux pane in percent (default 60).
set -euo pipefail

skill_dir=$(cd "$(dirname "$0")" && pwd -P)
revuey=$skill_dir/revuey

usage() {
  echo "usage: launch.sh --in tmux|herdr|none <directory> [-- revuey args...]" >&2
  echo "  --in tmux when \$TMUX is set, --in herdr when \$HERDR_ENV is 1, else --in none" >&2
  exit 2
}

target=
if [ "${1:-}" = "--in" ]; then
  target=${2:-}
  shift 2 || usage
fi
case "$target" in
  tmux|herdr|none) ;;
  *) usage ;;
esac
dir=${1:-}
[ -n "$dir" ] && [ "$dir" != "--" ] || usage
shift
if [ "${1:-}" = "--" ]; then
  shift
fi
if ! dir=$(cd "$dir" 2>/dev/null && pwd) || ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
  echo "launch.sh: not a git worktree: $dir" >&2
  exit 1
fi

# single quotes for any POSIX shell, fish and zsh: 'it'\''s'
q() {
  local s=${1//\'/\'\\\'\'}
  printf "'%s'" "$s"
}
cmd=$(q "$revuey")
for a in "$@"; do
  cmd="$cmd $(q "$a")"
done

sessions() {
  (cd "$dir" && "$revuey" sessions) | grep -v '^no revuey sessions' || true
}

if [ "$target" = none ]; then
  echo "revuey cannot be opened in a pane here. Ask the user to run this in another terminal"
  echo "(or :Revuey in their Neovim, in that directory):"
  echo "  cd $(q "$dir") && $cmd"
  echo "Then attach with: cd $(q "$dir") && $(q "$revuey") watch --messages"
  exit 3
fi

before=$(sessions)
if [ -n "$before" ]; then
  echo "revuey is already running in $dir:"
  echo "$before"
  echo "Attach to it: cd $(q "$dir") && $(q "$revuey") watch --messages [--session <id>]"
  exit 4
fi

# the pane runs `bash <script>`: a plain path, safe whatever the pane's shell (bash, zsh, fish)
script=$(mktemp /tmp/revuey-launch.XXXXXX)
{
  echo 'rm -f "$0"'
  echo "cd $(q "$dir") && exec $cmd"
} >"$script"

if [ "$target" = tmux ]; then
  pane=${TMUX_PANE:-}
  if [ -z "${TMUX:-}" ] || [ -z "$pane" ] || [ "$(tmux display-message -p -t "$pane" '#{pane_id}' 2>/dev/null)" != "$pane" ]; then
    rm -f "$script"
    echo "launch.sh: cannot verify the tmux pane to split (\$TMUX / \$TMUX_PANE); not launching" >&2
    exit 2
  fi
  new=$(tmux split-window -h -t "$pane" -P -F '#{pane_id}' -l "${REVUEY_PANE_SIZE:-60}%" -c "$dir" "bash $script")
  where="tmux pane $new"
else
  pane=${HERDR_PANE_ID:-}
  if [ "${HERDR_ENV:-}" != 1 ] || [ -z "$pane" ] || ! herdr pane get "$pane" >/dev/null 2>&1; then
    rm -f "$script"
    echo "launch.sh: cannot verify the herdr pane to split (\$HERDR_ENV / \$HERDR_PANE_ID); not launching" >&2
    exit 2
  fi
  command -v jq >/dev/null 2>&1 || { rm -f "$script"; echo "launch.sh: herdr needs jq to read pane ids" >&2; exit 2; }
  new=$(herdr pane split "$pane" --direction right --cwd "$dir" --focus | jq -er '.result.pane.pane_id')
  herdr pane run "$new" "bash $script; exit" >/dev/null
  where="herdr pane $new"
fi

timeout=${REVUEY_LAUNCH_TIMEOUT:-20}
for _ in $(seq 1 $((timeout * 4))); do
  now=$(sessions)
  if [ -n "$now" ]; then
    echo "revuey is open in $where; review session:"
    echo "$now"
    exit 0
  fi
  sleep 0.25
done
echo "revuey was started in $where but has not registered a review within ${timeout}s (it may be asking something, or failed); check the pane."
exit 5
