# Set up the Mac runtime

## Prerequisites

The supported deployment is macOS on Apple silicon, with Python 3.9 or newer, zsh,
`curl`, `lsof`, and standalone `llama-server`. Python uses only its standard library;
there is no pip dependency installation for the inference service. The optional localhost
[resource and lease dashboard](runtime-dashboard.md) uses psutil in a separate process. The current host uses Python 3.9.7,
llama.cpp 0.7.0 (build 11669) and a 128 GB Apple M5 Max Mac. Other platforms have not
been validated; the supplied start/stop scripts use macOS launchd.

Allow at least 20 GB for the model and projector plus room for downloads, tools and caches.
The existing model process measured about 18 GiB resident memory before workload-dependent
headroom. A 32 GB or larger Mac is a practical starting point, not a tested minimum.

Install command-line tools and Homebrew if they are missing, following their official setup
instructions. Then install the backend:

```sh
brew install llama.cpp
llama-server --version
```

The tested version is 0.7.0; Homebrew may now supply another version. Validate it with the
HTTP checks below before replacing a working installation. For source builds, see the
[official llama.cpp build guide](https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md).
Build outside this repository; on macOS Metal is enabled by default:

```sh
git clone https://github.com/ggml-org/llama.cpp.git "$HOME/llama.cpp"
cmake -S "$HOME/llama.cpp" -B "$HOME/llama.cpp/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$HOME/llama.cpp/build" --config Release -j 4 --target llama-server
```

Set `MUSE_LLAMA_SERVER` to the absolute path of the resulting executable. This service
requires `/v1/chat/completions/input_tokens`, explicit `id_slot`, the slot APIs and
`--kv-unified-per-slot`;
an arbitrary older llama.cpp build is not sufficient. Keep a known working backend when
upgrading rather than updating the live service during phone testing.

## Obtain the model and projector

Download the Q4_K_M text weights and matching perception encoder from
[Meta's Muse Glimmer GGUF repository](https://huggingface.co/meta-models/Muse-Glimmer-30B-GGUF).
The model card identifies the two files below and requires llama.cpp build 10353 or later.
Read its model terms before use; no weights are distributed in LearnChat.

```sh
mkdir -p "$HOME/Models/muse-glimmer"
curl --fail --location --retry 3 \
  'https://huggingface.co/meta-models/Muse-Glimmer-30B-GGUF/resolve/70bf1b61ac09f91b24d39038091b41c582bc5d7a/Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf' \
  --output "$HOME/Models/muse-glimmer/Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf"
curl --fail --location --retry 3 \
  'https://huggingface.co/meta-models/Muse-Glimmer-30B-GGUF/resolve/70bf1b61ac09f91b24d39038091b41c582bc5d7a/mmproj-Muse-Glimmer-30B-Q4_K_M.gguf' \
  --output "$HOME/Models/muse-glimmer/mmproj-Muse-Glimmer-30B-Q4_K_M.gguf"
```

These URLs pin the upstream revision inspected on 2026-10-17. Verify the downloaded files
with `shasum -a 256`; expected hashes from upstream file metadata are:

```text
4cc57c0f51040a226e5a72cc47b7613f7772950e460a665f7083de89f183f60e  Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf
f48b452316f9b213758e8659444029b961a24a07f99a1abb2a9f88b06f7c00c6  mmproj-Muse-Glimmer-30B-Q4_K_M.gguf
```

A login/error page is not a GGUF. The pinned model is 16756683904 bytes and differs from
the older installed model below; it has not been re-downloaded or live-tested in this migration.
The current host reuses already-downloaded Ollama blobs without copying or modifying them:

| File | Size (bytes) | SHA-256 from the existing content-addressed manifest |
| --- | ---: | --- |
| Q4_K_M model | 16756681056 | `71b5c9c9abbc2a9e7c13550b6f9fe1f062650117a24490b15a310cbd7de03f8b` |
| Vision projector | 1400328928 | `f48b452316f9b213758e8659444029b961a24a07f99a1abb2a9f88b06f7c00c6` |

Those files live under `~/.ollama/models/blobs/sha256-<hash>` on the existing host.
Reuse them by setting the two paths below; do not delete that directory while the service
uses it. New downloads may differ from this historical manifest. No Ollama process is needed.

## Configure

From the repository root:

```sh
cd muse-runtime
# First-time setup only; preserve an existing working .env.
cp -n config.example.env .env
```

Edit `.env`. It is a shell-sourced local file, so quote paths containing spaces.
Set `MUSE_MODEL_PATH` and `MUSE_MMPROJ_PATH` to the two real GGUF files, and
`MUSE_LLAMA_SERVER` to `command -v llama-server` (or your source-build path).
The example uses `$HOME/Models/muse-glimmer`. Set `MUSE_PYTHON` to an absolute interpreter
path if needed. Do not commit this file or paste API keys into task threads.

| Setting | Default / intended behavior |
| --- | --- |
| `MUSE_HOST` | `127.0.0.1` for this Mac only; `0.0.0.0` for a trusted Wi-Fi network |
| `MUSE_PORT` | `11434`, the phone-facing service |
| `MUSE_BACKEND_HOST`, `MUSE_BACKEND_PORT` | `127.0.0.1`, `18080`; keep backend private |
| `MUSE_MODEL_NAME` | `muse-glimmer:latest`, the advertised name |
| `MUSE_SLOTS`, `MUSE_CONTEXT_SIZE` | `4`, `32768`; 8192 tokens per slot |
| `MUSE_SESSION_TOKEN_LIMIT`, `MUSE_TOTAL_CACHE_TOKEN_LIMIT` | `8192`, `24576` |
| `MUSE_MAX_OUTPUT_TOKENS` | `2048`, reserved inside the slot limit |
| `MUSE_LEASE_SECONDS` | `300`; Android renews about every 120 seconds |
| `MUSE_SNAPSHOT_MODE` | `disabled`; hybrid-model slot restore is not fully reliable |
| `MUSE_MODEL_UNLOAD_POLICY` | `keep_loaded`; independent of session leases |
| `MUSE_MODEL_IDLE_SECONDS` | `900`, relevant only with `idle_timeout` |
| `MUSE_BACKEND_AUTOSTART` | `true`, service owns the model process |
| `MUSE_API_KEY` | empty for current phone clients; otherwise Bearer header required |

`idle_timeout` and `immediate` weight-unload modes also exist. Do not change the established
`keep_loaded` policy for the Android cache test. Default state is `muse-runtime/state/`;
`MUSE_STATE_DIR` can change backend/cache state, but launchd console logs remain in local `state/`.

Validate without starting a model (uses configured file paths but does not load weights):

```sh
set -a
source .env
set +a
python3 -c 'from muse_runtime.config import Config; Config.from_env(); print("Configuration valid")'
PYTHONPATH=. python3 -m unittest discover -s tests -v
```

## Start, check and stop

Use a logged-in macOS desktop session. `start.sh` registers a per-user launchd job, generates
its paths under ignored `state/`, waits for readiness and returns. An already healthy
registration is left running. Startup at login after a reboot is not installed: run the start
command again after logging in. The script needs a GUI launchd domain; headless service
installation is not yet provided.

```sh
./scripts/start.sh
./scripts/status.sh
curl --fail http://127.0.0.1:11434/healthz
curl --fail http://127.0.0.1:11434/api/tags
```

Expect `status: ok`, `ready: true` in status, and the configured model in `/api/tags`.
A health response establishes reachability; a chat check must also complete:

```sh
curl --fail --no-buffer http://127.0.0.1:11434/api/chat \
  -H 'Content-Type: application/json' \
  -H 'X-Muse-Session-ID: setup-check' \
  -d '{"model":"muse-glimmer:latest","messages":[{"role":"user","content":"Say hello in one sentence."}],"stream":true,"think":false}'
```

Expect JSON lines with reply text followed by `done: true` and no `error`. When an API key
is enabled, add `-H "Authorization: Bearer $MUSE_API_KEY"` to protected calls.
The service hides the reasoning field when `think:false`; the model can still spend time
thinking before visible text arrives.

If Ollama already owns port 11434, deliberately switch using `./scripts/start.sh --replace-ollama`.
This stops Ollama, disables its background login job and saves the old Ollama environment
registration under `state/`. It is unnecessary on this already-running host.

```sh
./scripts/stop.sh                 # stop the service and managed backend
./scripts/rollback-to-ollama.sh   # optional: restore a previously installed Ollama setup
```

Rollback requires the Ollama app already installed. It restores its saved login settings and
waits for `/api/tags`; it does not install Ollama or change models. For foreground debugging,
`./scripts/run.sh` runs until Ctrl-C; stop the background service first to avoid a port conflict.

For a phone, set `MUSE_HOST=0.0.0.0`, restart deliberately after any existing test finishes,
and use `http://<Mac-Wi-Fi-IP>:11434` in the app. Find the address in macOS Network settings.
Do not use `0.0.0.0` or `localhost` as the phone's server address. Keep both devices on the same
trusted network and avoid guest-network device isolation or router port forwarding.

## Local monitoring

Open **http://127.0.0.1:11436/** after starting the [runtime dashboard](runtime-dashboard.md).
It shows CPU/RAM, lease countdowns and renewal history without renewing leases or sending chats.
Use `python3 muse-runtime/scripts/dashboard.py start` from the repository root; the guide covers
the psutil dependency, one-time telemetry activation and independent stop/start commands.
