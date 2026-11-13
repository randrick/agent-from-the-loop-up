# Pragmatic AI: An AI Agent From the Loop Up
# https://github.com/randrick/agent-from-the-loop-up
# Copyright (c) 2026 Ray Andrick
# SPDX-License-Identifier: MIT
#
# A throwaway place to run loop.sh. The model's commands run inside this
# container, so they can only touch the container and the one volume
# mounted at /work. The model runs outside, behind an OpenAI-style API.
#
# On a Linux machine, loop.sh could run directly on the host. It runs in a
# container here for two reasons:
# - Readers can try the examples without a Linux machine.
# - The container is the only protection this stage has. The loop runs
#   whatever command the model asks for, with the rights of whoever started
#   it. Asked to "clean up my home directory", a model could run rm -rf ~
#   by mistake. On the host, that deletes your files. In here, it deletes
#   the container's.

FROM debian:13-slim

# What loop.sh needs (bash, curl, jq), plus python3 for the example task.
RUN apt-get update \
 && apt-get install -y --no-install-recommends bash ca-certificates curl jq python3 \
 && rm -rf /var/lib/apt/lists/*

COPY --chmod=755 loop.sh /usr/local/bin/loop.sh

# The tests, so they can run in the same container as the loop (see the README).
COPY --chmod=755 tests /tests

# Docker Desktop (macOS, Windows) maps this name to the host. On Linux the
# README overrides LLM_BASE_URL instead.
ENV LLM_BASE_URL=http://host.docker.internal:11434/v1

WORKDIR /work
ENTRYPOINT ["loop.sh"]
