#!/usr/bin/env bash
# Runs a command and, if it is still running after a time limit, prints a stack sample of it and every process it
# started before stopping them. Otherwise exits with the command's own status.
#
#   Scripts/run_with_hang_sampler.sh --minutes 15 -- swift test
set -uo pipefail

usage() { echo "usage: $0 --minutes N [--samples-dir DIR] -- command [args...]" >&2; exit 64; }

minutes=""
samples_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/hang-samples"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --minutes) [[ $# -ge 2 ]] || usage; minutes="$2"; shift 2 ;;
    --samples-dir) [[ $# -ge 2 && -n "$2" ]] || usage; samples_dir="$2"; shift 2 ;;
    --) shift; break ;;
    *) usage ;;
  esac
done
[[ "$minutes" =~ ^[0-9]+$ && "$minutes" -gt 0 && $# -gt 0 ]] || usage

descendants() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do
    echo "$child"
    descendants "$child"
  done
}

"$@" &
pid=$!
deadline=$((SECONDS + minutes * 60))
while kill -0 "$pid" 2>/dev/null; do
  if (( SECONDS >= deadline )); then
    echo "::error::'$*' was still running after $minutes minutes. Sampling its processes before stopping them."
    mkdir -p "$samples_dir"
    pids="$pid $(descendants "$pid" | tr '\n' ' ')"
    for target in $pids; do
      file="$samples_dir/sample-$target.txt"
      echo "::group::Stack sample of $target: $(ps -o command= -p "$target" 2>/dev/null | cut -c1-200)"
      if sample "$target" 3 -mayDie -file "$file" > /dev/null 2>&1 \
        || sudo -n sample "$target" 3 -mayDie -file "$file" > /dev/null 2>&1; then
        cat "$file"
      else
        echo "Couldn't sample process $target."
      fi
      echo "::endgroup::"
    done
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null
    sleep 5
    # shellcheck disable=SC2086
    kill -KILL $pids 2>/dev/null
    wait "$pid" 2>/dev/null
    exit 124
  fi
  sleep 5
done
wait "$pid"
