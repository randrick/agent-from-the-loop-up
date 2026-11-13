#!/usr/bin/env bash
# Pragmatic AI: An AI Agent From the Loop Up
# https://github.com/randrick/agent-from-the-loop-up
# Copyright (c) 2026 Ray Andrick
# SPDX-License-Identifier: MIT
# Provided as is, in the hope that it is useful, with no warranty. See LICENSE.
#
# Live check for loop.sh: one trivial request through your real LLM. It
# confirms that the API can be reached, the model exists, and the model can
# call a tool. It checks only that the loop completed. It never judges what
# the model said, because a real model words its answer differently every run.
#
# Usage:  tests/live.sh
# Config: LLM_BASE_URL, LLM_MODEL, LLM_API_KEY and LLM_REASONING_EFFORT, the same
#         as loop.sh
# Exit:   0 if every check passed, 1 otherwise
set -uo pipefail    # no -e: a failed check is counted, it does not stop the run

here=$(cd "$(dirname "$0")" && pwd)
# Check the loop.sh beside this directory if there is one, else the installed one.
if [[ -x $here/../loop.sh ]]; then loop=$here/../loop.sh; else loop=$(command -v loop.sh); fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/work"

echo "# Asking the model to run one command. Without a GPU this can take minutes."
(cd "$tmp/work" &&
    "$loop" "Run this shell command: echo loop-ok. Then tell me what it printed." \
        >"$tmp/out" 2>"$tmp/err")
rc=$?

# Show the run, so a failure can be read.
sed 's/^/    /' "$tmp/err" "$tmp/out"

fail=0
check() {
    local desc=$1
    shift
    if "$@" >/dev/null 2>&1; then
        echo "ok   - $desc"
    else
        echo "FAIL - $desc"
        fail=$((fail + 1))
    fi
}

check "the loop reached the LLM and exited 0" test "$rc" -eq 0
check "the model called the tool (a command was run)" grep -q '^+ ' "$tmp/err"
check "the model gave a final answer" test -s "$tmp/out"

echo
if [[ $fail -eq 0 ]]; then
    echo "Live check passed."
else
    echo "Live check failed. See \"If something goes wrong\" in the README."
    exit 1
fi
