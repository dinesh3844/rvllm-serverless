# rvLLM Serverless for RunPod

RunPod Serverless wrapper for [`rvLLM`](https://github.com/m0at/rvllm), keeping the Rust inference server intact and adding only the minimal serverless layer needed for deployment.

This repository is intentionally shaped like the official RunPod worker repositories:

- one generic image that lets users choose a `MODEL_ID` at deploy time
- one baked-image path that downloads a specific model into the image at build time
- a small Python handler that starts `rvllm serve`, waits for `/health`, and proxies RunPod jobs to the local OpenAI-compatible API

## Why This Shape

`rvLLM` already has the hard part:

- OpenAI-compatible HTTP routes
- Hugging Face model-id support
- fast startup and much smaller runtime footprint than Python `vLLM`

So this serverless layer does **not** re-implement inference. It does three things only:

1. Launch `rvllm serve` with env-driven configuration.
2. Translate RunPod job inputs into local HTTP requests.
3. Rewrite model names when the public model name differs from the local baked path.

That keeps the serverless repo easy to reason about and keeps `rvLLM` front-and-center.

## Deployment Modes

### 1. Generic Image + `MODEL_ID` at Deploy Time

Build a reusable image once, then choose the model from RunPod endpoint environment variables.

Use this when:

- you want one image for many models
- you are okay with first-boot Hugging Face download time
- you want a RunPod Hub style workflow

Required env:

- `MODEL_ID=Qwen/Qwen2.5-7B-Instruct`

### 2. Baked Image

Bake a model snapshot into the image and serve from a local path like `/models/default`.

Use this when:

- cold-start predictability matters
- your model is gated/private and you want controlled image contents
- you want to avoid endpoint-time download latency

The wrapper automatically keeps the **public** model name as the original Hugging Face repo id while `rvLLM` serves from the baked local directory.

## Repository Layout

```text
rvLLM-serverless/
├── .runpod/hub.json
├── builder/
│   ├── download_model.py
│   └── requirements.txt
├── scripts/
│   ├── build.sh
│   └── smoke_test.sh
├── src/
│   ├── config.py
│   ├── handler.py
│   ├── proxy.py
│   ├── request_mapping.py
│   └── server_launcher.py
└── tests/
    ├── test_config.py
    └── test_request_mapping.py
```

## Configuration

### Core Runtime Variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `MODEL_ID` | unset | Public model id. Also used as the runtime model target when `MODEL_TARGET` is not set. |
| `MODEL_TARGET` | unset | Actual value passed to `rvllm serve --model`. Use this when serving a baked local directory. |
| `SERVED_MODEL_NAME` | `MODEL_ID` or `MODEL_TARGET` | Public model name exposed through `/v1/models` and accepted in request bodies. |
| `TOKENIZER_ID` | unset | Optional tokenizer override passed to `rvllm serve --tokenizer`. |
| `HF_TOKEN` | unset | Hugging Face token for gated/private models. |
| `HF_HOME` | `/runpod-volume/huggingface` | Hugging Face cache root. |
| `HUGGINGFACE_HUB_CACHE` | `${HF_HOME}/hub` | Explicit HF hub cache path. |
| `RVLLM_PORT` | `8000` | Local port used by `rvllm serve`. |
| `MAX_CONCURRENCY` | `30` | RunPod worker concurrency hint. |
| `SERVER_READY_TIMEOUT` | `900` | Seconds to wait for `rvLLM` health before failing startup. |
| `REQUEST_TIMEOUT` | `600` | Seconds to wait for proxied HTTP requests. |

### `rvLLM` Launch Variables

These are translated into `rvllm serve` flags:

| Variable | Default |
| --- | --- |
| `DTYPE` | `auto` |
| `MAX_MODEL_LEN` | `2048` |
| `GPU_MEMORY_UTILIZATION` | `0.9` |
| `TENSOR_PARALLEL_SIZE` | `1` |
| `MAX_NUM_SEQS` | `256` |
| `RUST_LOG` | `info` |
| `DISABLE_TELEMETRY` | `false` |

## Job Input Contract

The worker supports two clean input styles.

### A. Direct OpenAI-style Input

If `input` already looks like a chat/completions payload, the route is inferred automatically.

Chat example:

```json
{
  "input": {
    "messages": [
      { "role": "system", "content": "Answer briefly." },
      { "role": "user", "content": "What is rvLLM?" }
    ],
    "temperature": 0.2,
    "max_tokens": 128,
    "stream": false
  }
}
```

Completion example:

```json
{
  "input": {
    "prompt": "Write a one-line summary of RunPod Serverless.",
    "max_tokens": 64
  }
}
```

If `model` is omitted, the worker injects `SERVED_MODEL_NAME` automatically.

### B. Explicit Proxy Input

Use this when you want full control over the local OpenAI-compatible endpoint:

```json
{
  "input": {
    "path": "/v1/models",
    "method": "GET"
  }
}
```

Or:

```json
{
  "input": {
    "path": "/v1/chat/completions",
    "method": "POST",
    "body": {
      "model": "Qwen/Qwen2.5-7B-Instruct",
      "messages": [
        { "role": "user", "content": "Return JSON only." }
      ],
      "stream": true
    }
  }
}
```

## Local Build on macOS

This workspace already contains sibling folders:

- `rvllm/`
- `rvLLM-serverless/`

The included build script stages only those folders into a temporary Docker context, so you can build on macOS without copying the entire workspace into Docker.

### Prerequisites

- Docker Desktop
- BuildKit enabled
- enough disk for Rust + CUDA build artifacts
- optional: registry login if you plan to push the image

### Build a Generic Image

```bash
cd rvLLM-serverless
./scripts/build.sh --tag your-registry/rvllm-serverless:latest
```

To validate the staged Docker command without starting a build:

```bash
cd rvLLM-serverless
./scripts/build.sh --tag your-registry/rvllm-serverless:latest --dry-run
```

### Build a Baked Image

```bash
cd rvLLM-serverless
HF_TOKEN=hf_xxx ./scripts/build.sh \
  --tag your-registry/rvllm-serverless:qwen25-7b \
  --bake-model \
  --model-id Qwen/Qwen2.5-7B-Instruct
```

### Push After Build

```bash
cd rvLLM-serverless
./scripts/build.sh --tag your-registry/rvllm-serverless:latest --push
```

## RunPod Deployment

### Option 1. Deploy the Generic Image

Endpoint environment example:

```env
MODEL_ID=Qwen/Qwen2.5-7B-Instruct
DTYPE=half
MAX_MODEL_LEN=8192
GPU_MEMORY_UTILIZATION=0.92
MAX_NUM_SEQS=128
HF_TOKEN=hf_xxx
```

### Option 2. Deploy a Baked Image

Endpoint environment example:

```env
MODEL_TARGET=/models/default
SERVED_MODEL_NAME=Qwen/Qwen2.5-7B-Instruct
DTYPE=half
MAX_MODEL_LEN=8192
GPU_MEMORY_UTILIZATION=0.92
MAX_NUM_SEQS=128
```

For baked images, requests can still use:

```json
{ "model": "Qwen/Qwen2.5-7B-Instruct" }
```

The proxy rewrites that to the local baked path before forwarding to `rvLLM`.

## How Streaming Works

`rvLLM` emits OpenAI-style SSE on the local HTTP port. The RunPod worker parses those events and yields JSON chunks through the RunPod streaming interface.

Implications:

- use RunPod `/stream` when you want incremental output
- use RunPod `/run` or `/runsync` for non-streaming requests
- streamed chunks preserve the OpenAI response shape, but transport is RunPod streaming, not raw SSE passthrough

## What Was Verified on macOS

This repo is set up so the following checks can be run without H100 access:

- Python import and syntax validation for the serverless wrapper
- request-shape and config resolution tests in `tests/`
- Docker build command generation and staging workflow

Run:

```bash
cd rvLLM-serverless
./scripts/smoke_test.sh
```

## What Still Needs H100 Validation

These should be done once GPU access is available:

1. First cold boot with a real Hugging Face model on RunPod Serverless.
2. End-to-end `/v1/chat/completions` latency and startup timings.
3. `DTYPE`, `MAX_MODEL_LEN`, and `MAX_NUM_SEQS` tuning on H100.
4. Behavior under concurrent traffic and large prompt loads.
5. Model compatibility checks for the exact model families you plan to serve.

## Recommended Next H100 Session

When H100 access is available, the fastest validation order is:

1. Deploy the generic image with a small known-good model.
2. Confirm `/v1/models`, non-stream chat, and streaming chat.
3. Move to the target production model.
4. Decide whether baked image is worth the larger image size versus first-boot download.

## Notes

- The wrapper currently targets the existing `rvllm serve` CLI surface and does not add a new inference API.
- This repository intentionally prefers a thin wrapper over deep `rvLLM` modifications.
- If later needed, the next reasonable improvement is a serverless-native Rust entrypoint inside `rvLLM` itself, but that is not required to get the image built and deployed.
