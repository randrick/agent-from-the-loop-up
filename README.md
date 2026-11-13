# Pragmatic AI: An AI Agent From the Loop Up

Example code for my LinkedIn series "An AI Agent From the Loop Up." The series builds an LLM agent harness one stage at a time on Linux, Python and plain OS primitives.

## How this repo is organized

Each article has a matching tag. `article-02` holds the code as Article 2 leaves it, `article-03` holds it as Article 3 leaves it, and so on. `main` matches the latest published article.

To get the code for one article:

```
git clone https://github.com/randrick/agent-from-the-loop-up.git
cd agent-from-the-loop-up
git checkout article-02
```

The README at each tag has step-by-step instructions for that article.

## Prerequisites

To run the examples you need two things:

1. **Docker, working.** Every example runs inside a container.
   - [Get Docker](https://docs.docker.com/get-started/get-docker/). On macOS or Windows that means Docker Desktop. On Windows, run the commands in a WSL2 terminal.
2. **Access to an LLM through an OpenAI-style chat completions API that supports tool calls.** The model can run on your own machine or at a paid service. Some options:
   - Local: [Ollama](https://ollama.com) (also as a [Docker image](https://hub.docker.com/r/ollama/ollama)), [llama.cpp](https://github.com/ggml-org/llama.cpp) (its server needs `--jinja` for tool calls), [LM Studio](https://lmstudio.ai)
   - Paid: [OpenAI](https://platform.openai.com), [OpenRouter](https://openrouter.ai) (many providers' models through one API key)

If either of those is new to you, start there. The examples assume both already work.

I use Ollama, running in a Docker container. The steps below assume the same. My machine is a Dell 5820 with 128 GB of RAM, 16 CPU cores and an NVIDIA RTX 3090 with 24 GB of memory. Ollama does not require a GPU. Without one, expect each example to take minutes. To use something else, see [Using another LLM](#using-another-llm).

The script reads four settings from the environment:

| Variable | Meaning | Default |
|---|---|---|
| `LLM_BASE_URL` | The API's base URL | Ollama on the host |
| `LLM_MODEL` | Model name, as the service spells it | `qwen3.6:27b` |
| `LLM_API_KEY` | API key, if the service needs one | none |
| `LLM_REASONING_EFFORT` | How much the model "thinks" before it answers | `none` (thinking off) |

Thinking is off by default because Ollama is much faster that way with the model I use, and these examples do not need it. The script sends `reasoning_effort: "none"` with every request. Some services reject that field for some models. If yours does, set `LLM_REASONING_EFFORT` to an empty string and the script leaves the field out.

## Articles

1. [An AI Agent From the Loop Up: Why I Built My Own](https://www.linkedin.com/pulse/ai-agent-from-loop-up-why-i-built-my-own-ray-andrick-s9ife) (no code)
2. The bare loop (tag `article-02`)

## Article 2: the bare loop

`loop.sh` is the whole agent at this stage: a model inside a loop, in a few dozen lines of bash.

The files:

```
loop.sh              the loop
Dockerfile           the container image the loop runs in
tests/run.sh         mechanics tests, no LLM needed
tests/fake_llm.py    the scripted stand-in for the LLM that those tests use
tests/live.sh        one-request check against your real LLM
```

**Warning:** the script runs whatever command the model asks for. Nothing in the script checks or limits it. The steps below run it inside a throwaway container, so the model's commands can only touch the container and one Docker volume. Don't skip the container.

### Steps

1. Start Ollama in a container and pull the model. With an NVIDIA GPU and the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html):

   ```
   docker run -d --gpus=all -v ollama:/root/.ollama -p 127.0.0.1:11434:11434 --name ollama ollama/ollama
   docker exec ollama ollama pull qwen3.6:27b
   ```

   `-p 127.0.0.1:11434:11434` publishes Ollama to your own machine only. The rest of your network cannot reach it.

   Without a GPU, leave out `--gpus=all`. Ollama then runs on the CPU, slowly. `qwen3.6:27b` needs a GPU with about 24 GB of memory, so on a smaller machine pull a smaller model that supports tool calls and pass its name as `LLM_MODEL` in step 3.

2. Get the code for this article and build the container image:

   ```
   cd ~
   git clone https://github.com/randrick/agent-from-the-loop-up.git
   cd agent-from-the-loop-up
   git checkout article-02
   docker build -t loop-up .
   ```

3. Run the loop.

   On macOS or Windows (Docker Desktop):

   ```
   docker run --rm --init -v stage0:/work loop-up "Create fib.py that prints the first 10 Fibonacci numbers, run it, report the output."
   ```

   On Linux:

   ```
   docker run --rm --init --network host -e LLM_BASE_URL=http://localhost:11434/v1 -v stage0:/work loop-up "Create fib.py that prints the first 10 Fibonacci numbers, run it, report the output."
   ```

What the flags do:

- `--rm` deletes the container when the loop ends.
- `--init` lets Ctrl-C stop the loop.
- `-v stage0:/work` gives the loop a Docker volume named `stage0` as its working directory. The model's files land there and outlive the container. Nothing on your own machine is reachable from inside.
- On Linux, `--network host` lets the container reach Ollama on `localhost`.

### What you should see

Each command the model runs is printed with a leading `+`. The model's final answer is printed last. This is a run on my machine, which took about 5 seconds:

````
+ cat > fib.py << 'EOF'
# Print the first 10 Fibonacci numbers

def fibonacci(n):
    fib_numbers = []
    a, b = 0, 1
    for _ in range(n):
        fib_numbers.append(a)
        a, b = b, a + b
    return fib_numbers

fib_10 = fibonacci(10)
for num in fib_10:
    print(num)
EOF
+ python fib.py
+ python3 fib.py
The `fib.py` script has been created and executed successfully.

**Output:**
```
0
1
1
2
3
5
8
13
21
34
```

The first 10 Fibonacci numbers (starting from 0) are: 0, 1, 1, 2, 3, 5, 8, 13, 21, 34.
````

Your run will differ, because the model chooses its own commands each time. In this one the model tried `python`, which the container does not have. The loop sent the failure back, and the model switched to `python3` by itself.

### Looking at what the model made

List the files in the volume:

```
docker run --rm -v stage0:/work --entrypoint ls loop-up -l
```

Show one of them:

```
docker run --rm -v stage0:/work --entrypoint cat loop-up fib.py
```

The volume keeps its files between runs. To start clean, delete it:

```
docker volume rm stage0
```

### Using another LLM

Add the settings to the `docker run` command in step 3. For example, with OpenRouter:

```
docker run --rm --init -e LLM_BASE_URL=https://openrouter.ai/api/v1 -e LLM_MODEL=<model name> -e LLM_API_KEY=<your key> -v stage0:/work loop-up "Create fib.py that prints the first 10 Fibonacci numbers, run it, report the output."
```

### Tests

There are two kinds. Both run in the same container image as the loop.

**Mechanics tests.** These run `loop.sh` against a scripted stand-in for the LLM (`tests/fake_llm.py`). They need no LLM and no GPU, and they give the same result every time:

```
docker run --rm --entrypoint /tests/run.sh loop-up
```

The last line should read `27 passed, 0 failed`.

**Live check.** This sends one trivial request through your real LLM. It confirms your setup meets the prerequisites: the API can be reached, the model exists and the model can call a tool. It checks only that the loop completed, because a real model words its answer differently every run.

On macOS or Windows (Docker Desktop):

```
docker run --rm --init --entrypoint /tests/live.sh loop-up
```

On Linux:

```
docker run --rm --init --network host -e LLM_BASE_URL=http://localhost:11434/v1 --entrypoint /tests/live.sh loop-up
```

The last line should read `Live check passed.`

### If something goes wrong

- **`curl: (7) Failed to connect`**: the loop cannot reach the LLM. Check that Ollama answers with `curl http://localhost:11434/v1/models`. On Linux, check that you used the Linux command in step 3.
- **`loop.sh: request failed:` followed by a message**: the LLM service refused the request, and the message is its reason. The common ones are a model name it does not know (pull the model, or check `LLM_MODEL`), a model that does not support tool calls (choose one that does) and a complaint about `reasoning_effort` (add `-e LLM_REASONING_EFFORT=` to the `docker run` command).
- **The loop ends and prints nothing**: the model sent back neither text nor a command the loop could read. Run it again. If it keeps happening, try another model.
- **The loop never ends**: nothing in this stage limits how long the model keeps going. Press Ctrl-C.

### What has been tested

I ran these steps on Linux with rootless Docker, Ollama in a container, an RTX 3090 and `qwen3.6:27b`. The macOS and Windows command in step 3 has not been tested yet.

## Subscribe

Pragmatic AI on LinkedIn: https://www.linkedin.com/build-relation/newsletter-follow?entityUrn=7334276735670128642

## License

The code is under the MIT License; see [LICENSE](LICENSE). The license covers the code only. The article text is Copyright 2026 Ray Andrick, all rights reserved.
