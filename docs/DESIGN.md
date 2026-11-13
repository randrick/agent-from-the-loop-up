# Design notes

These notes describe the code at tag `article-02`: stage 0, the bare loop.

They grow with the series. Each article's tag carries the design as it stands at that stage. A section is added when the code it describes arrives.

## Design goals

The series builds toward four goals, set out in [Article 1](https://www.linkedin.com/pulse/ai-agent-from-loop-up-why-i-built-my-own-ray-andrick-s9ife). Stage 0 meets the first.

| Goal | Meaning | At stage 0 |
|---|---|---|
| 1. OS first | Use what the operating system already provides before writing anything in a general-purpose language. | Met. The loop is bash. The work is done by `curl`, `jq` and `bash`, connected by pipes and exit codes. |
| 2. State you can read | The system's state is files and text. | Not yet. The conversation lives in a shell variable and is gone when the loop exits. |
| 3. Policy lives in the loop | A rule in the prompt is a request. A rule in the loop is a fact. | Not yet. The loop has no rules. |
| 4. Multi-tenant from day one | Each user's or team's files, memory and sessions are kept apart from everyone else's. | Not yet. There is one user and no stored state to keep apart. |

## The loop

An AI agent is a model inside a loop. At stage 0 the loop has four steps:

1. **Send.** Send the conversation to the model.
2. **Check.** Look at the reply. Plain text means the model is finished: print it and stop.
3. **Run.** A tool call means there is work: run the command.
4. **Append.** Add the command's output to the conversation. Go to step 1.

On one line:

```
model -> run -> results -> repeat
```

## Parts

| File | Role |
|---|---|
| `loop.sh` | The loop. |
| `Dockerfile` | The container image the loop and its tests run in. |
| `tests/run.sh` | Mechanics tests. They run the loop against a scripted stand-in for the LLM. |
| `tests/fake_llm.py` | The scripted stand-in. |
| `tests/live.sh` | A one-request check against a real LLM. |

## Interfaces

### Starting the loop

`loop.sh "your request"`. One argument. Four settings come from the environment:

| Setting | Meaning | Default |
|---|---|---|
| `LLM_BASE_URL` | The API's base URL | `http://localhost:11434/v1` in the script. The container image sets `http://host.docker.internal:11434/v1`. |
| `LLM_MODEL` | Model name | `qwen3.6:27b` |
| `LLM_API_KEY` | API key | none |
| `LLM_REASONING_EFFORT` | How much the model thinks before it answers | `none`. An empty value leaves the field out of the request. |

### To the LLM

- One `POST` to `$LLM_BASE_URL/chat/completions` per turn of the loop.
- The body carries `model`, `messages` (the whole conversation) and `tools`. It carries `reasoning_effort` when that setting is not empty.
- An `Authorization: Bearer` header is sent when `LLM_API_KEY` is set.
- From the response the loop reads `.choices[0].message`. Everything else is ignored.
- The reply is read whole. There is no streaming.

### The tool

One tool is offered to the model: `bash`, with one string argument, `command`.

### The tool result

The result of a command goes back to the model as one message:

- `role` is `tool`.
- `tool_call_id` is the id of the call it answers.
- `content` is `exit N` on the first line, where N is the command's exit code, followed by the command's standard output and standard error together.

### Out of the loop

- The model's final answer goes to standard output.
- Each command goes to standard error before it runs, with a leading `+ `.
- Exit code 0: the model gave a final answer.
- Exit code 1: the request to the LLM failed. The service's response is printed.
- Exit code 2: no request was given.
- Any other exit code: a failure inside the script itself. See the known limits.

## Decisions

| Decision | Reason |
|---|---|
| The loop is bash at this stage. | Everything stage 0 does is glue: start a program, pass it text, check its exit code. |
| The loop speaks the OpenAI-style chat completions API. | Local servers and paid services both speak it, so a reader changes settings to change LLM. |
| The loop runs in a container. | Readers can try it without a Linux machine. The container is also the only protection this stage has, because the loop runs whatever command the model asks for. |
| The LLM runs outside the loop's container. | Readers bring their own LLM. The loop needs only its URL. |
| The loop's working directory is a Docker named volume. | It behaves the same on every platform, and nothing on the reader's own disk is mounted into the container. |
| Thinking is off by default. | Ollama is much faster that way with the model I use, and the examples do not need it. |
| One command per reply. | The loop handles one tool call at a time. The API expects an answer to every call left in the conversation, so the extra calls are dropped before the reply is stored. |
| A failed command does not stop the loop. | The exit code and the error text are information the model needs. |
| Commands get no input. | A command that reads input gets end-of-file at once and the loop carries on. |
| Every request carries the whole conversation. | The API keeps no state between calls. |
| A failed request stops the loop and shows the service's response. | The reader needs the service's reason to fix their setup. |
| Two kinds of test. | The mechanics tests use a scripted stand-in, so they give the same result every time. The live check uses a real model, so it checks only that a run completed. |

## Known limits

Stage 0 exists to show how the loop works. Real work needs the stages that follow. Each limit below was confirmed against the code at this tag.

| Limit | What happens | Addressed in |
|---|---|---|
| Every action is a free-form shell string. | The loop cannot tell reading a file from deleting a directory. | Tools |
| The tool's name is not checked. | A call to any tool name runs as a shell command if it has a `command` argument. | Tools |
| Only the first tool call in a reply is kept. | The others are dropped without notice. | Tools |
| An unreadable tool call looks like a final answer. | If a call's arguments are not valid JSON or hold no `command`, the loop prints whatever text came with the call, often only a blank line, and exits 0. A reply with no text and no call does the same. | Tools |
| No approval. | The loop runs whatever command the model asks for. | Policy |
| No step limit. | A model that never gives a final answer keeps the loop running until someone stops it. | Policy |
| Nothing is written down. | The conversation exists only while the loop runs. | The record |
| The conversation grows with every step. | Every reply and every command's full output is added. Nothing shortens it, so a long run stops fitting in the model's context. | The context view |
| Nothing carries over between runs. | The next run starts with no knowledge of this one. | Memory |
| Commands share the loop's container. | They run as root inside it. They can read the loop's settings, API key included, and a key they print goes into the conversation. They share the container's network. With the Linux run command that is the host's network, so they can reach any service listening on the machine. Nothing limits their CPU, memory or disk use. | The sandbox |
| The volume keeps its files. | Files from earlier runs stay in the working directory until the volume is deleted. | The sandbox |
| The answer is not checked. | Whatever the model says last is printed. | Monitors |
| Nothing judges the model. | The live check confirms that a model can call the tool. Nothing tells a good model from a poor one. | Choosing the model |
| No time limit on a command. | A command that never finishes hangs the loop. Ctrl-C cannot interrupt it. | Not assigned yet |
| Command output is held in memory. | A command that never stops printing grows the loop's memory without bound. | Not assigned yet |
| A background process blocks the loop. | If a command starts a process in the background, the loop waits until that process exits or closes its output. | Not assigned yet |
| Each command runs in a fresh shell. | A `cd` or a variable set by one command is gone in the next. The tool's description does not tell the model. | Not assigned yet |
| Text sent with a tool call is not shown. | It goes into the conversation. The reader sees only the command. | Not assigned yet |
| Output that is not text is altered. | NUL bytes are dropped and bytes that are not valid UTF-8 are replaced before the output reaches the model. | Not assigned yet |
| No time limit or retry on the LLM request. | A request that hangs, hangs the loop. One failed request ends the run. | Not assigned yet |
| A size limit on the conversation. | The script passes the conversation to `jq` as a command-line argument, and Linux limits one argument to about 128 KB. Past that the loop stops with `jq: Argument list too long`. One command with large output is enough. | Not assigned yet |
| Tested on Linux only. | The macOS and Windows run command has not been tested. | Not assigned yet |
