#!/usr/bin/env bash
# Pragmatic AI: An AI Agent From the Loop Up
# https://github.com/randrick/agent-from-the-loop-up
# Copyright (c) 2026 Ray Andrick
# SPDX-License-Identifier: MIT
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

# Stop on the first failed command, unset variable or failed pipeline stage.
set -euo pipefail

LLM_BASE_URL=${LLM_BASE_URL:-http://localhost:11434/v1}
LLM_MODEL=${LLM_MODEL:-qwen3.6:27b}
# "-" and not ":-" here, so that an empty value stays empty.
LLM_REASONING_EFFORT=${LLM_REASONING_EFFORT-none}

if [[ $# -ne 1 ]]; then
    echo "usage: $0 \"your request\"" >&2
    exit 2
fi

# Send the API key only if one is set. A local server such as Ollama needs none.
auth=()
if [[ -n ${LLM_API_KEY:-} ]]; then
    auth=(-H "Authorization: Bearer $LLM_API_KEY")
fi

# The one capability the model is offered: run a shell command.
tools='[{"type":"function","function":{"name":"bash",
  "description":"Run a shell command and return its output.",
  "parameters":{"type":"object","required":["command"],
    "properties":{"command":{"type":"string"}}}}}]'

# The conversation is a JSON array of messages. It starts with the request.
# jq builds and edits all the JSON in this script: -n starts from nothing,
# --arg passes a shell string in safely, --argjson passes JSON in as JSON.
messages=$(jq -n --arg p "$1" '[{role:"user", content:$p}]')

while true; do
    # Send the whole conversation and the tool list. The server keeps no state
    # between calls, so every call carries everything. reasoning_effort is
    # added only when it is set.
    request=$(jq -n --arg m "$LLM_MODEL" --argjson msgs "$messages" --argjson t "$tools" \
                 --arg e "$LLM_REASONING_EFFORT" \
                 '{model:$m, messages:$msgs, tools:$t}
                  + (if $e == "" then {} else {reasoning_effort:$e} end)')

    # The model's message is at .choices[0].message in the response. If the
    # call fails or the response has no message, show what the service said.
    if ! response=$(curl -sS --fail-with-body "${auth[@]}" -H "Content-Type: application/json" \
                         "$LLM_BASE_URL/chat/completions" -d @- <<<"$request") ||
       ! reply=$(jq -e '.choices[0].message' <<<"$response"); then
        echo "loop.sh: request failed: $response" >&2
        exit 1
    fi

    # This loop handles one tool call per reply, so keep only the first. The
    # API expects an answer to every call left in the conversation.
    reply=$(jq '.tool_calls |= (if . then .[:1] else . end)' <<<"$reply")
    messages=$(jq --argjson r "$reply" '. + [$r]' <<<"$messages")

    # A reply with no tool call is the final answer. The call's arguments
    # arrive as a JSON string, so they are parsed before reading the command.
    cmd=$(jq -r '.tool_calls[0].function.arguments // empty | fromjson? | .command // empty' <<<"$reply")
    if [[ -z "$cmd" ]]; then
        jq -r '.content // ""' <<<"$reply"
        exit 0
    fi
    id=$(jq -r '.tool_calls[0].id' <<<"$reply")

    # Run the command, after printing it to stderr so you can watch. Its exit
    # code and output go back to the model as the tool result, tagged with the
    # id of the call it answers.
    # - Stdin is /dev/null so a command that waits for input fails instead of
    #   hanging.
    # - "&& rc=0 || rc=$?" records the exit code. Without it, set -e would end
    #   this script whenever the model's command failed. A failed command is
    #   information for the model, so the loop carries on.
    echo "+ $cmd" >&2
    out=$(sh -c "$cmd" </dev/null 2>&1) && rc=0 || rc=$?
    messages=$(jq --arg id "$id" --arg o "exit $rc"$'\n'"$out" \
                  '. + [{role:"tool", tool_call_id:$id, content:$o}]' <<<"$messages")
done
