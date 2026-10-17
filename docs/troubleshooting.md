# Troubleshooting and current limits

| Symptom | Check / action |
| --- | --- |
| Connection refused | Run `muse-runtime/scripts/status.sh`; check the service is on the configured port and Mac is awake. |
| Mac works but phone cannot connect | Use the Mac's Wi-Fi IP, same trusted network, `MUSE_HOST=0.0.0.0`, macOS firewall permission and iOS Local Network permission. Guest Wi-Fi/VPN isolation may block devices. |
| Port 11434 already used | Identify its owner with `lsof -nP -iTCP:11434 -sTCP:LISTEN`. Deliberately stop it or use the documented Ollama replacement option; do not kill unrelated processes. |
| Startup fails / model unavailable | Check absolute `.env` paths, GGUF sizes, Python/llama-server executable, and ignored `muse-runtime/state/service.log` / `llama-server.log`. Never upload raw logs containing private material. |
| launchd registration fails | Use a logged-in macOS GUI session; run `launchctl print gui/$(id -u)/local.muse-glimmer.runtime`. This setup is not a system daemon or automatic login installation. |
| 401 after enabling API key | Add a Bearer header to callers. Current apps lack an API-key setting; leave the established trusted-LAN configuration until header support exists. |
| Reply initially looks stalled | Hidden model reasoning may precede visible text. Showing reasoning can make progress visible. |
| 409 after Stop/resend | The server may still be generating. Android retries briefly before output begins; wait and resend after the error if needed. DELETE is not cancellation. |
| Old conversation resumes slowly | An expired/evicted cache rebuilds from submitted context. Phone history should remain intact. |
| Reply ends early | Check `done_reason: length`; the per-slot budget includes prompt and answer. Compaction is lossy, and image/context-heavy workloads need validation. |
| Model setting appears ineffective | The runtime serves one configured model. App names do not dynamically load another model. |
| Android JDK error | Check `java -version`, `JAVA_HOME` and Android Studio's Gradle JDK. Use an installed JDK 17–23 (22 tested). |
| Android SDK/license error | Set local SDK path, install platform 35 and accept SDK licenses in the SDK tools. |
| Android install storage/signature error | Free emulator/device space without deleting needed chats; use compatible signing or preserve data before reinstalling. arm64-v8a is the only packaged native ABI. |
| Xcode destination unavailable | Run `xcodebuild -showdestinations` and choose an installed runtime/device. Do not blindly reuse the documented example name. |
| iPhone signing or developer error | In Xcode choose an authorized team/bundle ID, trust the phone and enable Developer Mode. Resolve any Apple license/account prompts as the developer. |

Current limits: one model; plain trusted-LAN HTTP; no per-user access control, TLS or browser
frontend; no automatic post-reboot launch setup; macOS-only lifecycle scripts; no iOS lease
heartbeats; four bounded cache slots; lossy compaction and best-effort cache restoration;
Android arm64 only; no release-store signing, audio pipeline or full-video model ingestion.
No physical phone acceptance is implied by local or Simulator tests.
