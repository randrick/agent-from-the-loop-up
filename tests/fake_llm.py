#!/usr/bin/env python3
# Pragmatic AI: An AI Agent From the Loop Up
# https://github.com/randrick/agent-from-the-loop-up
# Copyright (c) 2026 Ray Andrick
# SPDX-License-Identifier: MIT
"""A scripted stand-in for an LLM service, for testing loop.sh.

It speaks just enough of the OpenAI-style chat completions API for the loop:
each POST gets the next response from a fixed script. A real model answers
differently every run, so a test built on one cannot pass or fail reliably.
This fake answers the same way every time, and needs no model and no GPU.

Usage: fake_llm.py SCENARIO PORT_FILE LOG_FILE

  SCENARIO   which script to play (a key of SCENARIOS below)
  PORT_FILE  the server picks a free port and writes its number here
  LOG_FILE   every request received is appended here, one JSON object per line,
             so a test can check what the loop actually sent
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


def call(call_id, command):
    """One tool call, as the API returns it. The arguments are a JSON string."""
    return {"id": call_id, "type": "function",
            "function": {"name": "bash", "arguments": json.dumps({"command": command})}}


def asks_for(*calls):
    """A response in which the model asks for one or more commands to be run."""
    return 200, {"choices": [{"index": 0, "finish_reason": "tool_calls",
                              "message": {"role": "assistant", "content": None,
                                          "tool_calls": list(calls)}}]}


def answers(text):
    """A response in which the model gives its final answer in plain text."""
    return 200, {"choices": [{"index": 0, "finish_reason": "stop",
                              "message": {"role": "assistant", "content": text}}]}


# Each scenario is the list of responses the fake gives, in order.
SCENARIOS = {
    # Write a file, run it, report. The ordinary path through the loop.
    "normal": [
        asks_for(call("call_1", "printf 'print(*[0, 1, 1, 2, 3, 5, 8, 13, 21, 34])\\n' > fib.py")),
        asks_for(call("call_2", "python3 fib.py")),
        answers("fib.py prints: 0 1 1 2 3 5 8 13 21 34"),
    ],
    # A command that fails. The loop should report the failure and carry on.
    "failing": [
        asks_for(call("call_1", "echo before; exit 3")),
        answers("The command failed with exit code 3."),
    ],
    # Two commands in one reply. The loop handles one, so it keeps the first.
    "two_calls": [
        asks_for(call("call_1", "touch first"), call("call_2", "touch second")),
        answers("Done."),
    ],
    # A command that waits for input. The loop should not hang.
    "waits_for_input": [
        asks_for(call("call_1", "read line")),
        answers("Done."),
    ],
    # A final answer straight away.
    "answer": [
        answers("Hello."),
    ],
    # The service refuses the request.
    "rejected": [
        (400, {"error": {"message": "model does not support tools"}}),
    ],
    # The service says OK but sends no message.
    "no_message": [
        (200, {"error": {"message": "quota exceeded"}}),
    ],
}


def main():
    scenario, port_file, log_file = sys.argv[1:4]
    script = list(SCENARIOS[scenario])

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            pass  # keep the test output clean

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            with open(log_file, "a") as log:
                log.write(json.dumps({"path": self.path,
                                      "authorization": self.headers.get("Authorization"),
                                      "body": body}) + "\n")
            if script:
                status, payload = script.pop(0)
            else:
                status, payload = 500, {"error": {"message": "fake_llm: script exhausted"}}
            data = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    server = HTTPServer(("127.0.0.1", 0), Handler)  # port 0: any free port
    with open(port_file, "w") as f:
        f.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()
