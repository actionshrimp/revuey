#!/usr/bin/env bash
# Fail when processes started by the test suite outlive it (child Neovims, watchers, sleeps...).
#   scripts/check-leaks.sh <marker>
# `make test` runs every spec with REVUEY_TEST_RUN=<marker> in its environment, which every
# process it starts inherits. Anything still alive with that variable after a short grace period
# is listed, killed, and makes this exit 1.
set -uo pipefail
marker="REVUEY_TEST_RUN=${1:?usage: check-leaks.sh <marker>}"

# this script's ancestors (make, the shell running the recipe) are not leaks, even when their
# command line spells the marker
ancestors=" $$ "
p=$PPID
while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
  ancestors="$ancestors$p "
  p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
done

find_pids() {
  if [ -r /proc/self/environ ]; then
    for d in /proc/[0-9]*; do
      # (the redirect's own error, e.g. another user's process, is silenced too)
      if { tr '\0' '\n' <"$d/environ"; } 2>/dev/null | grep -qxF "$marker"; then
        echo "${d#/proc/}"
      fi
    done
  else
    # macOS: -E appends the environment of the user's own processes to the command. The marker
    # reaches awk through its environment as M=..., so awk never matches itself.
    ps -E -ww -x -o pid= -o command= 2>/dev/null | M="$marker" awk 'index($0 " ", " " ENVIRON["M"] " ") { print $1 }'
  fi
}

leaks() {
  for pid in $(find_pids); do
    case "$ancestors" in
      *" $pid "*) ;;
      *) kill -0 "$pid" 2>/dev/null && echo "$pid" ;;
    esac
  done
}

pids=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pids=$(leaks)
  [ -z "$pids" ] && exit 0
  sleep 0.5
done
echo "LEAKED test processes (still running after the suite):" >&2
for pid in $pids; do
  ps -o pid= -o command= -p "$pid" >&2 || echo "$pid (gone)" >&2
done
# shellcheck disable=SC2086
kill $pids 2>/dev/null
exit 1
