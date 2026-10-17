# Build and connect the mobile apps

First make the [Mac runtime](setup-runtime.md) ready. Both apps use the public Muse Glimmer HTTP
service, not the private llama.cpp backend. Use `muse-glimmer:latest` as the model. Historical
`llava-llama3` instructions refer to the former deployment and do not select a different model on
the current single-model runtime.

## Android

Requirements: Android Studio or command-line SDK tools, an installed JDK 17–23, Android SDK
platform 35, platform tools (`adb`) and accepted Android SDK licenses. This source uses Gradle
8.13, Android Gradle Plugin 8.13.1 and Kotlin 2.2.10. The app requires Android 8 / API 26 or newer
and currently packages only **arm64-v8a** native libraries; use an arm64 phone/emulator.

From the repository root (the Android folder is the inner `LearnChat/`):

```sh
cd LearnChat
# macOS example: use an actually installed supported JDK. This host has JDK 22.
export JAVA_HOME=$(/usr/libexec/java_home -v 22)
# On another host choose your installed JDK 17-23 instead.
export ANDROID_HOME="$HOME/Library/Android/sdk"
printf 'sdk.dir=%s\n' "$ANDROID_HOME" > local.properties
./gradlew assembleDebug testDebugUnitTest
```

`local.properties` is ignored and machine-specific; keep an existing correct file. Android
Studio can create it. SDK licenses must be accepted interactively if prompted; this repository
does not auto-accept license agreements. Debug signing uses the developer's local debug key.
Release/store signing and distribution are not configured.
The repository intentionally contains no custom launcher artwork, so Android uses its unbranded
platform placeholder icon.

Enable Developer options and USB debugging on the phone, connect it, and approve its USB trust
prompt. Then:

```sh
adb devices
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

If multiple devices are listed, use `adb -s <device-serial> install -r ...` for the intended one.
The debug application ID is `com.learnchat.app.debug`. The APK is generated locally and excluded
from Git. Installation with `-r` preserves application data when the signing key is compatible;
a different developer's debug key can cause a signature conflict. Do not uninstall to fix it
without considering saved chat history.

Open **Settings**, enter `http://<Mac-Wi-Fi-IP>:11434`, set model `muse-glimmer:latest`, and test
the connection. Android Emulator can use `http://10.0.2.2:11434`; a physical phone cannot.
Set **Server model can see images** when sending image pixels to the configured Muse projector.
PDF extraction, photo OCR/labels and video frame sampling run on the device. Full video/audio
understanding and audio recording are not implemented.

## iOS

Requirements: macOS, Xcode with an installed iOS Simulator runtime (validated here with Xcode
27 and iOS 26.5 Simulator), and iOS 17 or newer on a device. The app uses Apple frameworks only.
The generated Xcode project is included; `project.yml` is its XcodeGen source. Install XcodeGen
only if regenerating the project (`brew install xcodegen`, then `xcodegen generate` in
`LearnChat-iOS`). Keep the specification and generated project consistent.
The app icon catalog is intentionally absent, so simulator and development builds use Xcode's
unbranded placeholder.

Open `LearnChat-iOS/LearnChat.xcodeproj`, choose an available iPhone Simulator and Run. For a terminal
build, first list destinations so you can substitute one installed on your Mac:

```sh
cd LearnChat-iOS
xcodebuild -showdestinations -project LearnChat.xcodeproj -scheme LearnChat
xcodebuild build -project LearnChat.xcodeproj -scheme LearnChat \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO
```

After booting a Simulator through Xcode:

```sh
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/LearnChat.app
xcrun simctl launch booted com.learnchat.app
```

Run the existing unit tests on an installed Simulator (the example is available on this host):

```sh
xcodebuild test -project LearnChat.xcodeproj -scheme LearnChat \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO -only-testing:LearnChatTests
```

Live UI tests in `LearnChatUITests` need a reachable runtime; the photo case also needs a picture in
the Simulator library. Running build/unit tests does not establish a real phone chat.

For an iPhone, connect and trust the device, enable Developer Mode, select your development
team in **Signing & Capabilities**, choose a bundle ID your team can sign, select the phone and
Run in Xcode. The existing project records Kedar's development team ID (an identifier, not a
signing key). Other developers must use their own team. Certificates/profiles and private keys
are not included. Apple account, signing and license prompts require the developer's action;
an unsigned Simulator build cannot be installed as a signed iPhone app.

In app Settings, select the Mac Wi-Fi address and `muse-glimmer:latest`. The Simulator may use
`http://127.0.0.1:11434`; a phone must use the Mac's network address. Allow iOS Local Network
permission. The app allows plain local HTTP. Like Android, iOS renews an established visible
chat's runtime lease while the app is active and lets it expire after the chat leaves the
foreground; the next send rebuilds a missing runtime session from the phone's saved history.

## Upgrade compatibility

The mobile transport implementation is named for the Muse Glimmer service, but its established
HTTP contract is unchanged: `/api/chat`, `/api/tags`, session headers, newline-delimited chunks,
and JSON keys such as `messages`, `images`, and `options.num_ctx` keep their existing wire names.
The local storage names, SwiftData models and settings keys match the LearnChat identifiers.
Installing over a compatible LearnChat build preserves its settings and on-device chat history.
A package with a different bundle or application identifier installs separately and its data is
not migrated automatically.

## Phone verification

Kedar confirmed the earlier external-device streamed-chat request as successful on 2026-10-17.
For a new installation and the separate Android heartbeat acceptance, use these steps on the
physical phone and record the result in the relevant Orcha task:

1. Connect Mac and phone to the same trusted Wi-Fi; ensure the Mac stays awake.
2. Test the configured server connection, then send a short message in LearnChat.
3. Confirm visible text streams, finishes without an error, and remains after reopening the chat.
4. On Android, leave that established chat open for over five minutes and send again. Background
   or leave the chat for over five minutes, return, and send again; local history should survive.
5. Stop a reply and resend, and try a photo if image input is required. A temporary busy response
   after Stop may outlast Android's bounded retries; wait and try once more.

Report the platform, app build, server address, steps and result without posting private chat
content. Physical-phone verification and repository/setup review remain human checkpoints.
