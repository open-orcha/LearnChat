# LearnChat

LearnChat is a local AI chat system: native Android and iOS apps talk over Wi-Fi to
Muse Glimmer running on a Mac through standalone llama.cpp and a Python HTTP service.
Chats are saved on the phone; the Mac manages short-lived conversation caches.
Ollama is not required to run the current service.

This private repository contains the LearnChat runtime, dashboard and mobile clients. Project,
package and bundle names use LearnChat consistently. Keep the repository private until independent
QA and human approval are complete.

## Repository layout

| Folder | Contents |
| --- | --- |
| [`muse-runtime/`](muse-runtime/) | Python control service, cache management, macOS startup scripts and tests |
| [`LearnChat/`](LearnChat/) | Kotlin / Jetpack Compose Android app, Gradle wrapper and Room schemas |
| [`LearnChat-iOS/`](LearnChat-iOS/) | SwiftUI iOS app, Xcode project, XcodeGen specification and tests |
| [`docs/`](docs/) | Setup, HTTP contract, troubleshooting, validation and GitHub workflow |

There are no submodules or nested repositories. Future runtime/model work belongs in this same
repository, with component-specific changes reviewed together when necessary.

## Start here

1. Clone the private repository using an account with access:
   `git clone git@github.com:open-orcha/LearnChat.git`, then `cd LearnChat`.
2. Follow [Mac runtime setup](docs/setup-runtime.md) to obtain llama.cpp and the model,
   configure and start the service, and check a streamed response.
3. Start the optional local [runtime dashboard](docs/runtime-dashboard.md) to inspect host
   resources, leases and cache activity without sending chats or renewing leases.
4. Follow [Android and iOS setup](docs/setup-mobile.md) for each platform's SDK, build,
   installation and signing prerequisites.
5. Complete the [phone verification steps](docs/setup-mobile.md#phone-verification).
   A successful connection check alone does not verify a streamed chat.

For the already-configured workspace, use `muse-runtime/scripts/status.sh` before starting
anything. Its service is already running; repository setup does not require a restart.

## Architecture and supported behavior

```text
Android (Room) / iOS (SwiftData)
             | HTTP /api/chat, newline-delimited JSON
             v
Python control service :11434
  session leases, bounded caches, compaction, /api/status, /metrics
             | loopback only
             v
llama-server 127.0.0.1:18080
  Muse Glimmer GGUF + vision projector, four 8K slots
```

Current scope includes streaming text/reasoning, cancellation, saved chat history,
PDF/photo/video preprocessing, and optional image pixels sent to the vision-capable server.
Android and iOS maintain stable session IDs and renew a visible, active conversation's
five-minute cache lease about every two minutes. Leaving the chat or backgrounding the app
allows the runtime cache to expire; that does not delete the phone's saved history.

This deployment serves **one configured model**, `muse-glimmer:latest`. Selecting a different
name in an app does not load another model. Multi-model routing, other runtimes and iOS
heartbeat integration are future work. This migration does not add or replace any model.

The service uses plain HTTP on a trusted local network. It is not an internet-facing service
and has no TLS or per-user authorization. Keep it off router port forwarding. Optional API-key
protection requires client header support; the current phone settings do not provide it.

## Development and verification

- [Runtime HTTP contract and operations](docs/runtime-api.md)
- [Build and verification record](docs/validation.md)
- [Troubleshooting](docs/troubleshooting.md)
- [GitHub sync and review workflow](docs/github-workflow.md)
- [Agent working agreement](AGENTS.md)

Only source, build definitions and setup examples belong in Git. Model weights, local `.env`,
signing keys, builds, chats, logs and Orcha state are excluded. LearnChat source is available
under the [MIT License](LICENSE); third-party components and models retain their own terms.
