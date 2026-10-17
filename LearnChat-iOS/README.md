# LearnChat for iOS

LearnChat is the SwiftUI iOS port of the Android app in `../LearnChat`. It talks directly to the local
Muse Glimmer service through its HTTP API, keeps chats on the device, streams replies
token by token, compacts older conversation history, and processes PDF, photo, and video
attachments on the phone.

## Requirements

- Xcode 27
- iOS 17 or newer
- The Muse Glimmer service reachable from the phone or Simulator

## Build and run

See the shared [mobile setup guide](../docs/setup-mobile.md) for prerequisites, signing, server
settings, installation, and physical-device verification.

Open `LearnChat.xcodeproj` in Xcode, choose an iPhone Simulator, and press Run.

For a connected iPhone, choose the phone as the run destination and press Run. The checked-in
project uses Kedar's Apple development team for automatic signing; Developer Mode must be enabled
on the phone.

The equivalent command-line build is:

```bash
cd LearnChat-iOS
xcodebuild build \
  -project LearnChat.xcodeproj \
  -scheme LearnChat \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO
```

To install and launch the command-line build in an already booted Simulator:

```bash
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/LearnChat.app
xcrun simctl launch booted com.learnchat.app
```

The default server is `http://192.168.86.32:11434`. Select `muse-glimmer:latest` in Settings for
the current single-model runtime. A physical iPhone must be on the same Wi-Fi as the Mac. The iOS
Simulator can use the Mac's LAN address or `http://127.0.0.1:11434`. Change either value and test
the connection from **Settings**.

## Tests

Run the native tests, including the context compactor and real attachment preprocessing pipeline:

```bash
xcodebuild test \
  -project LearnChat.xcodeproj \
  -scheme LearnChat \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:LearnChatTests
```

`LearnChatUITests/LearnChatSmokeTests.swift` also covers a live streamed chat, reopening saved history,
Settings connection testing, and a photo attachment. The live tests expect the configured model
server to be reachable. The photo test expects at least one image in the Simulator's photo library.

## Feature parity

- Chat list ordered by recent activity, new chat, rename, and delete
- Per-chat SwiftData persistence, including partial stopped replies
- Stable per-chat runtime sessions, migrated in place for existing chats without replacing history
- Rolling summary plus recent-message window for resuming long chats
- Muse Glimmer `/api/chat` newline-delimited JSON streaming, reasoning, typing indicator, Stop, and
  follow-latest scrolling
- Foreground cache-lease renewal for established chats, automatic full-context recovery after
  expiry, serialized sends per chat, and explicit stalled-stream socket cancellation
- Server address, model, reasoning visibility, context window, and **Server model can see images**
  settings stored in `UserDefaults`
- PDFKit text extraction with Vision OCR fallback for scans
- Vision OCR and image labels for photos
- AVFoundation video frame sampling with a timestamped on-device description
- Unbranded platform placeholder icon and matching Material 3 colors/layout

Picked files are processed locally. Their derived text is always included; when the image setting
is enabled, stored photo pixels and a sampled preview frame from each video are also included in
the compatible API's `images` field. The current `muse-glimmer:latest` service has its vision
projector loaded, so no alternate model selection is needed.

## Architecture

The source mirrors the Android clean-layer layout:

```text
LearnChat/
├── App/                 dependency container and app entry point
├── UI/                  chat list, chat, settings, reusable components, theme
├── Domain/              models, repository protocols, use case, context compaction
└── Data/                SwiftData, UserDefaults, Muse Glimmer client, preprocessing
```

The app uses only Apple frameworks: SwiftUI, SwiftData, PDFKit, Vision, PhotosUI, and
AVFoundation. There are no third-party package dependencies.

## Runtime session behavior

Each local chat owns a persisted UUID sent as `X-Muse-Session-ID` on its full-context chat calls.
While an established chat is visible and the app is active, LearnChat renews its runtime lease every
two minutes through `POST /api/sessions/{id}/heartbeat`. Leaving the chat or backgrounding the app
stops renewal. A missing or expired lease does not delete or rotate the local chat: the next send
includes the retained local context and recreates the server session. Background summaries remain
standalone requests and do not borrow the conversation session.

The app prevents overlapping sends for the same session and briefly retries a server `409` only
when no stream output was received. Stop cancels the underlying HTTP task even when the server is
silent between chunks, then stores any partial reply with its existing Stopped status.
