#!/usr/bin/env bash
# Pragmatic AI: An AI Agent From the Loop Up
# https://github.com/randrick/agent-from-the-loop-up
# Copyright (c) 2026 Ray Andrick
# SPDX-License-Identifier: MIT
# Provided as is, in the hope that it is useful, with no warranty. See LICENSE.
#
# Mechanics tests for loop.sh. They run the loop against fake_llm.py, a
# scripted stand-in for the LLM service, so they need no model and no GPU.
# They check the loop's own mechanics. They say nothing about how a real
# model behaves. For that, see live.sh.
#
# Usage: tests/run.sh
# Needs: bash, curl, jq, python3
# Exit:  0 if every check passed, 1 otherwise
set -uo pipefail    # no -e: a failed check is counted, it does not stop the run

here=$(cd "$(dirname "$0")" && pwd)
# Test the loop.sh beside this directory if there is one, else the installed one.
if [[ -x $here/../loop.sh ]]; then loop=$here/../loop.sh; else loop=$(command -v loop.sh); fi

tmp=$(mktemp -d)

# The loop is run with its stdin attached to this pipe, which stays open and
# never delivers anything. A command that reads the loop's stdin would wait
# forever, so case 10 fails if the loop stops giving commands an empty stdin.
mkfifo "$tmp/stdin"
exec 9<>"$tmp/stdin"
fake_pid=
cleanup() {
    [[ -n $fake_pid ]] && kill "$fake_pid" 2>/dev/null
    rm -rf "$tmp"
}
trap cleanup EXIT

pass=0
fail=0

# check DESCRIPTION COMMAND...: run the command, count it as a pass if it succeeds.
check() {
    local desc=$1
    shift
    if "$@" >/dev/null 2>&1; then
        echo "ok   - $desc"
        pass=$((pass + 1))
    else
        echo "FAIL - $desc"
        fail=$((fail + 1))
    fi
}

# run_case SCENARIO [REQUEST]: start the fake with that scenario, run the loop
# against it in an empty directory, stop the fake. Afterwards:
#   $rc         the loop's exit code
#   $tmp/out    what the loop printed (the final answer)
#   $tmp/err    its stderr (the "+ command" lines and any error)
#   $tmp/log    every request the fake received, one JSON object per line
#   $work       the directory the model's commands ran in
# Set $key first to run the loop with LLM_API_KEY. Set $effort_off=1 to run it
# with LLM_REASONING_EFFORT empty.
key=
effort_off=
run_case() {
    local scenario=$1
    shift
    work=$tmp/work
    rm -rf "$work" "$tmp/port"
    mkdir "$work"
    : >"$tmp/log"

    python3 "$here/fake_llm.py" "$scenario" "$tmp/port" "$tmp/log" &
    fake_pid=$!
    for _ in $(seq 50); do    # wait up to 5 seconds for the fake to be listening
        [[ -s $tmp/port ]] && break
        sleep 0.1
    done

    # timeout: a loop that hangs fails the test with exit code 124.
    (cd "$work" && env -u LLM_API_KEY -u LLM_REASONING_EFFORT \
        ${key:+LLM_API_KEY="$key"} ${effort_off:+LLM_REASONING_EFFORT=} LLM_MODEL=fake \
        LLM_BASE_URL="http://127.0.0.1:$(cat "$tmp/port")/v1" \
        timeout 20 "$loop" "$@" <&9 >"$tmp/out" 2>"$tmp/err")
    rc=$?

    kill "$fake_pid" 2>/dev/null
    wait "$fake_pid" 2>/dev/null
    fake_pid=
}

# requests JQ_FILTER: true if the filter holds for the array of logged requests.
requests() { jq -e -s "$1" "$tmp/log"; }

echo "# 1. A normal run: two commands, then a final answer"
run_case normal "Create fib.py"
check "the loop exits 0" test "$rc" -eq 0
check "the final answer is printed" grep -qx "fib.py prints: 0 1 1 2 3 5 8 13 21 34" "$tmp/out"
check "the model's first command ran (fib.py exists)" test -f "$work/fib.py"
check "both commands were shown" test "$(grep -c '^+ ' "$tmp/err")" -eq 2
check "the model was called three times" requests 'length == 3'
check "requests go to /chat/completions" requests 'all(.[]; .path == "/v1/chat/completions")'
check "each request carries the whole conversation so far" \
    requests '[.[].body.messages | length] == [1, 3, 5]'

echo "# 2. A failing command is reported to the model, and the loop carries on"
run_case failing "Do something"
check "the loop exits 0" test "$rc" -eq 0
check "the tool result carries the exit code and the output" \
    requests '.[1].body.messages[-1] | .role == "tool" and (.content | startswith("exit 3\nbefore"))'
check "the tool result names the call it answers" \
    requests '.[1].body.messages[-1].tool_call_id == "call_1"'
check "the model's answer after the failure is printed" grep -q "exit code 3" "$tmp/out"

echo "# 3. A reply with two tool calls is cut down to the first"
run_case two_calls "Do two things"
check "the first command ran" test -f "$work/first"
check "the second command did not run" test ! -e "$work/second"
check "the conversation keeps only the first call" \
    requests '.[1].body.messages[1].tool_calls | length == 1'

echo "# 4. The API key"
key=sk-test
run_case answer "Hello"
check "is sent when LLM_API_KEY is set" requests '.[0].authorization == "Bearer sk-test"'
key=
run_case answer "Hello"
check "is not sent when LLM_API_KEY is unset" requests '.[0].authorization == null'

echo "# 5. Thinking"
run_case answer "Hello"
check "is turned off by default (reasoning_effort is \"none\")" \
    requests '.[0].body.reasoning_effort == "none"'
effort_off=1
run_case answer "Hello"
check "is left to the service when LLM_REASONING_EFFORT is empty" \
    requests '.[0].body | has("reasoning_effort") | not'
effort_off=

echo "# 6. A rejected request"
run_case rejected "Hello"
check "the loop exits non-zero" test "$rc" -ne 0
check "the service's reason is shown" grep -q "does not support tools" "$tmp/err"

echo "# 7. A response with no message"
run_case no_message "Hello"
check "the loop exits non-zero" test "$rc" -ne 0
check "the service's response is shown" grep -q "quota exceeded" "$tmp/err"

echo "# 8. An unreachable server"
LLM_BASE_URL=http://127.0.0.1:1/v1 "$loop" "Hello" >"$tmp/out" 2>"$tmp/err"
rc=$?
check "the loop exits non-zero" test "$rc" -ne 0
check "the failure is reported" grep -q "request failed" "$tmp/err"

echo "# 9. No request given"
"$loop" >"$tmp/out" 2>"$tmp/err"
rc=$?
check "the loop exits 2" test "$rc" -eq 2
check "the usage line is shown" grep -q "usage:" "$tmp/err"

echo "# 10. A command that waits for input does not hang the loop"
run_case waits_for_input "Read something"
check "the loop finishes and exits 0" test "$rc" -eq 0

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
