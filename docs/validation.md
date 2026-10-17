# Validation record

## Imported source baseline

This repository began as a clean snapshot of private QChat `main` revision
`3ba550dff14e99e3fa3047778136fc4601895485`. The snapshot contains no source repository Git
history. Local Orcha/configuration state, credentials, environments, model weights, caches,
builds, logs and chat data were excluded from the publication inventory.

The source still carries its pre-rebranding `QChat` names. LearnChat must remain private until
the rebranding work, an independent publication audit and human approval are complete.

Checked on 2026-10-17 on the existing Apple silicon Mac. Runtime and app folders stayed in
place, and the live inference service was not restarted.

| Check | Result |
| --- | --- |
| Runtime unit tests | 47 passed |
| Dashboard JavaScript and syntax checks | Passed |
| Android debug build and unit tests | Build succeeded; 14 tests passed (JDK 22) |
| iOS Simulator build and unit tests | Xcode 27, iPhone 17 / iOS 26.5: 19 tests passed |
| Runtime shell scripts | zsh syntax checks passed |
| Portable launchd generator | Generated/validated a plist in a temporary path containing spaces; no live registration changed |
| Publication file inventory | Source/build inputs only; generated APKs, iOS build trees, weights, signing files and local Orcha state excluded |
| Credential-pattern scan | No private keys or recognized token patterns in the reviewed candidate files |

Android checks used the existing local SDK and build cache. iOS compiled into the ignored
`build/` directory and ran only `QChatTests`; no live UI/device signing test was
performed for this migration. Downloads and a clean-host model startup were documented and
checked against upstream guidance, but not repeated: the 18 GB installed model and running
service were preserved. API-key and post-reboot installation paths were not exercised.

The source project's earlier QA review covered its publication inventory, runtime, Android and
iOS results, launchd generation and shell syntax. The current private-repository setup repeated
47 runtime tests, the dashboard JavaScript and syntax checks, Android's debug build and 14 unit
tests, all 19 iOS unit tests, the staged inventory review and a credential-pattern scan. These
checks establish the imported baseline; they do not replace the independent LearnChat
rebranding/publication audit or Kedar's repository and setup-guide verification.

## Reproduce the checks

```sh
(cd muse-runtime && PYTHONPATH=. python3 -m unittest discover -s tests -v)
(cd QChat && ./gradlew testDebugUnitTest assembleDebug)
(cd QChat-iOS && xcodebuild build -project QChat.xcodeproj -scheme QChat \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build CODE_SIGNING_ALLOWED=NO)
```

See [mobile setup](setup-mobile.md) for prerequisites and Simulator unit-test commands.
Run `for script in muse-runtime/scripts/*.sh; do zsh -n "$script" || break; done` for shell parsing.
Generate a launchd plist only in a
throwaway copy to validate path generation without touching the registered live service.
Read-only `/healthz`, `/api/status` and `/api/tags` checks preserve active conversations.
Record the model PID before/after migration to show that repository work did not restart it.

## Human verification

Kedar confirmed the earlier external-device streamed-chat request as successful on 2026-10-17.
The Android heartbeat/lifecycle task has its own review and acceptance record. Repository and
setup-guide acceptance remains a separate Kedar checkpoint after publication. No build or
health check substitutes for those human decisions.
