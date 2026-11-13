#!/usr/bin/env bash
# Pragmatic AI: An AI Agent From the Loop Up
# https://github.com/randrick/agent-from-the-loop-up
# Copyright (c) 2026 Ray Andrick
# SPDX-License-Identifier: MIT
# Provided as is, in the hope that it is useful, with no warranty. See LICENSE.
#
# Stage 0: the bare agent loop. Show the model the conversation. If it asks for a
# command, run it and show it the output. Repeat until it answers in plain text.
#
# WARNING: this runs whatever command the model asks for. There is no approval,
# sandbox, record or limit. Run it only inside a throwaway container (see the
# README).
#
# Usage:   loop.sh "your request"
# Needs:   bash, curl, jq, and an LLM with an OpenAI-style chat completions API
#          that supports tool calls.
# Config:  LLM_BASE_URL  API base URL (default http://localhost:11434/v1, Ollama)
#          LLM_MODEL     model name   (default qwen3.6:27b)
#          LLM_API_KEY   API key, if the service needs one (default none)
#          LLM_REASONING_EFFORT  how much the model "thinks" before it answers
#                        (default none, which turns thinking off; set it to
#                        an empty string to leave the choice to the service)

# Reading the bash
#
# If bash is new to you, these are the pieces this script uses:
#
#   name=$(command)     run the command and keep what it prints in "name"
#   "$name"             the value kept in "name"
#   $1                  the first argument given to this script (your request)
#   command <<<"$name"  run the command with that value as its input
#   a | b               run a, and give what it prints to b as input
#   >&2                 print to the error stream, so it stays apart from
#                       the answer
#   $?                  the exit code of the last command. 0 means it worked.
#
# Two other programs do the real work:
#
#   curl   sends a request to a web address and prints the response
#   jq     reads, builds and edits JSON, the text format the LLM API speaks

# Stop on the first failed command, unset variable or failed pipeline stage.
set -euo pipefail

# The settings. ${NAME:-value} means: use NAME from the environment if it is
# set, otherwise use value.
LLM_BASE_URL=${LLM_BASE_URL:-http://localhost:11434/v1}
LLM_MODEL=${LLM_MODEL:-qwen3.6:27b}
# "-" and not ":-" here, so that an empty value stays empty.
LLM_REASONING_EFFORT=${LLM_REASONING_EFFORT-none}

# $# is the number of arguments. The script takes exactly one: the request.
if [[ $# -ne 1 ]]; then
    echo "usage: $0 \"your request\"" >&2
    exit 2
fi

# Send the API key only if one is set. A local server such as Ollama needs none.
# "auth" is a list of extra options for curl. It stays empty when there is no
# key, and "${auth[@]}" further down puts the list on curl's command line.
auth=()
if [[ -n ${LLM_API_KEY:-} ]]; then
    auth=(-H "Authorization: Bearer $LLM_API_KEY")
fi

# The one capability the model is offered: run a shell command. This JSON is
# sent with every request. It tells the model that a tool named "bash" exists
# and that it takes one piece of text, called "command".
tools='[{"type":"function","function":{"name":"bash",
  "description":"Run a shell command and return its output.",
  "parameters":{"type":"object","required":["command"],
    "properties":{"command":{"type":"string"}}}}}]'

# The conversation is a JSON array of messages. It starts with one message:
# your request, with the role "user".
# jq builds and edits all the JSON in this script: -n starts from nothing,
# --arg passes a shell string in safely, --argjson passes JSON in as JSON.
messages=$(jq -n --arg p "$1" '[{role:"user", content:$p}]')

# What a tool call looks like
#
# The model's only output is a reply. Because the request lists a tool (above),
# the model may reply with a request to use that tool in place of plain text.
# That request is a "tool call". It is data in a reply. Nothing has run.
#
# A reply that asks for a command:
#
#   {"role": "assistant", "content": "",
#    "tool_calls": [{"id": "call_1", "type": "function",
#      "function": {"name": "bash",
#                   "arguments": "{\"command\": \"python3 fib.py\"}"}}]}
#
# The loop runs the command and adds the result to the conversation as a new
# message, tagged with the id of the call it answers:
#
#   {"role": "tool", "tool_call_id": "call_1",
#    "content": "exit 0\n0\n1\n1\n2\n3\n5\n8\n13\n21\n34"}
#
# A reply with no "tool_calls" is the model's final answer:
#
#   {"role": "assistant", "content": "fib.py printed the first 10 numbers."}
#
# The loop below is those three shapes in order: send the conversation, check
# the reply for a tool call, run the command, append the result, repeat.
while true; do
    # STEP 1: SEND
    # Build the request: the model's name, the whole conversation and the tool
    # list. The server keeps no state between calls, so every call carries
    # everything. reasoning_effort is added only when it is set.
    request=$(jq -n --arg m "$LLM_MODEL" --argjson msgs "$messages" --argjson t "$tools" \
                 --arg e "$LLM_REASONING_EFFORT" \
                 '{model:$m, messages:$msgs, tools:$t}
                  + (if $e == "" then {} else {reasoning_effort:$e} end)')

    # Send it with curl and keep the response. The model's reply is the part
    # of the response at .choices[0].message, which jq picks out.
    #   -sS                  no progress display, but do show errors
    #   --fail-with-body     treat an error status from the service as a failure
    #   -d @-                send what arrives on input (the request) as the body
    #   jq -e                fail if the part asked for is missing
    # "if ! a || ! b" reads: if the request failed, or the response has no
    # message. In either case show what the service said and stop.
    if ! response=$(curl -sS --fail-with-body "${auth[@]}" -H "Content-Type: application/json" \
                         "$LLM_BASE_URL/chat/completions" -d @- <<<"$request") ||
       ! reply=$(jq -e '.choices[0].message' <<<"$response"); then
        echo "loop.sh: request failed: $response" >&2
        exit 1
    fi

    # This loop handles one tool call per reply, so keep only the first. The
    # API expects an answer to every call left in the conversation.
    # The jq reads: if the reply has tool_calls, cut the list down to its first
    # item. Then add the reply to the end of the conversation.
    reply=$(jq '.tool_calls |= (if . then .[:1] else . end)' <<<"$reply")
    messages=$(jq --argjson r "$reply" '. + [$r]' <<<"$messages")

    # STEP 2: CHECK
    # Look in the reply for a command to run. The call's arguments arrive as
    # JSON written inside a string, so "fromjson" unpacks them before
    # ".command" is read. "// empty" means: if that part is missing, give
    # nothing. So "cmd" ends up as the command, or as nothing.
    #
    # Nothing ([[ -z "$cmd" ]]) means the reply is the final answer: print its
    # text and stop. Otherwise note the call's id, which the result must carry.
    cmd=$(jq -r '.tool_calls[0].function.arguments // empty | fromjson? | .command // empty' <<<"$reply")
    if [[ -z "$cmd" ]]; then
        jq -r '.content // ""' <<<"$reply"
        exit 0
    fi
    id=$(jq -r '.tool_calls[0].id' <<<"$reply")

    # STEP 3: RUN
    # Show the command on the error stream so you can watch, then run it and
    # keep everything it prints in "out".
    # - bash -c "$cmd" runs the text of the command in a new shell.
    # - </dev/null gives the command no input, so one that waits for input
    #   fails instead of hanging.
    # - 2>&1 keeps the command's error messages together with its output.
    # - "&& rc=0 || rc=$?" records the exit code in "rc". Without it, set -e
    #   would end this script whenever the model's command failed. A failed
    #   command is information for the model, so the loop carries on.
    echo "+ $cmd" >&2
    out=$(bash -c "$cmd" </dev/null 2>&1) && rc=0 || rc=$?

    # STEP 4: APPEND
    # Add the result to the end of the conversation as a "tool" message: the
    # call's id, then "exit" with the exit code, a new line ($'\n'), and the
    # output. Then go round again, so the model sees what happened.
    messages=$(jq --arg id "$id" --arg o "exit $rc"$'\n'"$out" \
                  '. + [{role:"tool", tool_call_id:$id, content:$o}]' <<<"$messages")
done
