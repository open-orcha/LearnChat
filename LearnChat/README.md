# LearnChat

An Android chat app that talks to the local **Muse Glimmer** inference server running on
the Mac. Chats are stored on the phone, replies stream in token-by-token, and older history is
compacted on-device so long conversations stay coherent and fast.

## Building

See the shared [mobile setup guide](../docs/setup-mobile.md) for prerequisites, phone setup,
server settings, installation, and physical-device verification. The short local build is:

```bash
cd LearnChat
export JAVA_HOME=$(/usr/libexec/java_home -v 22)   # any JDK 17–23 works; the shell's JAVA_HOME is stale
./gradlew assembleDebug                             # → app/build/outputs/apk/debug/app-debug.apk
./gradlew testDebugUnitTest                         # context, transport, retry and lease tests
```

Or open the `LearnChat` folder in Android Studio (set *Gradle JDK* to a 17–23 JDK under
Settings → Build Tools → Gradle) and press Run.

`local.properties` points at `~/Library/Android/sdk`; adjust if your SDK lives elsewhere.

## Installing on a phone / emulator

```bash
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

The phone must be on the same Wi-Fi as the Mac. The default server address is
`http://192.168.86.32:11434` (the Mac's LAN address); change it in **Settings** if the Mac's IP
changes. On an emulator use `http://10.0.2.2:11434` (the emulator's alias for the host machine).
"Test connection" in Settings tells you whether the server is reachable.

## What the app does

- **Chat list** — past chats newest first; long-press to rename or delete. "New chat" starts one.
- **Chat screen** — bubbles, typing indicator while the model thinks, token-by-token streaming
  with a blinking caret, auto-scroll (pauses if you scroll up; tap the arrow to resume), Stop button.
  The model's reasoning trace is shown under each reply (collapsible; default is in Settings).
- **Persistence** — every chat and message is written to a Room database, including partial
  replies (persisted every ~400 ms while streaming, and on Stop).
- **Conversation cache** — every local chat has a persisted opaque session ID. While an established
  chat is visible and the app is foregrounded, LearnChat renews its five-minute server cache lease every
  two minutes. Navigation or backgrounding stops renewal and lets the lease expire naturally.
- **Continuing an old chat** — see *Context compaction* below.
- **Attachments** — the paperclip picks a PDF, photo or video. It is processed **on the phone** (see
  *On-device file preprocessing* below) and shows as a chip with a short summary ("12 pages ·
  4,210 words") while you type; the model then answers about its contents.
- **Settings** — server address, model name, "show reasoning by default", size of the verbatim
  window, and "send photos as pixels" for the current Muse vision projector.

## Architecture

```
com.learnchat.app
├── domain/                     pure Kotlin, no Android deps
│   ├── model/                  Chat, Message, MessagePart (Text | Image | File | Audio), ChatTurn, StreamEvent
│   ├── repository/             ChatRepository, SettingsRepository, ChatServerClient (interfaces)
│   ├── context/                ContextCompactor + WindowedSummaryCompactor, Summarizer (model / extractive)
│   ├── preprocess/             AttachmentPreprocessor interface (file → MessagePart with derived text)
│   └── usecase/                SendMessageUseCase — the send/stream/persist orchestration
├── data/
│   ├── local/                  Room: entities, DAOs, LearnChatDatabase, mappers
│   ├── preprocess/             AndroidAttachmentPreprocessor: PdfTextExtractor, ImageAnalyzer, VideoFrameSampler
│   ├── remote/museglimmer/     MuseGlimmerChatClient — NDJSON streaming over OkHttp
│   ├── repository/             RoomChatRepository
│   └── settings/               DataStoreSettingsRepository
├── di/AppContainer.kt          hand-rolled DI (no Hilt); wires the above
└── ui/                         Jetpack Compose, MVVM
    ├── chatlist/  chat/  settings/   screens + ViewModels
    ├── components/             MessageBubble, Composer, TypingIndicator
    └── navigation/             NavHost routes
```

Layers only talk downward: UI → ViewModel → use case / repository interfaces → data. The UI never
sees OkHttp or Room types.

### On-device file preprocessing (PDF / photo / video)

The phone extracts useful text and visual descriptions before sending an attachment, so chats keep
working even when image pixels are disabled. The current Muse Glimmer service also has its vision
projector loaded: enable *Settings → Server model can see images* to send a downscaled photo or
sampled video frame alongside that on-device description. The app is fully native
(Kotlin/Compose) and talks directly to the Muse Glimmer HTTP API; it does not require a separate
model-server app or a server-side upload endpoint.

| File  | What the phone does | Library |
|-------|---------------------|---------|
| PDF   | Copies it into app storage, pulls the text layer page by page. A page with no text layer (a scan) is rendered and OCR'd instead. Capped at 24k chars with a "cut here" marker. | PDFBox-Android (text), `PdfRenderer` + ML Kit OCR (scans) |
| Photo | Downscales to ≤1280 px JPEG, then OCR (any text in the picture) + image labels ("dog, beach, sunset" with confidences). | ML Kit text recognition + image labelling — bundled models, works offline, no Play Services |
| Video | Samples up to 8 evenly spaced frames (~1 per 5 s) with the hardware decoder, analyses each like a photo, and sends a timestamped timeline plus overall labels. The clip itself is never copied. | `MediaMetadataRetriever` + the photo path |

The derived text is wrapped in a clearly delimited block (`[Attached PDF: "x.pdf", 3 pages — text
extracted on the user's phone] … [End of "x.pdf"]`, see `MessagePart.promptText()`) so the model
can distinguish it from the user's prompt. Requests with attachments ask for a 16k context window,
but the current runtime keeps its 8192-token slot limit, including reserved answer space. Long
inputs may be compacted with information loss; see the [runtime limits](../docs/runtime-api.md).

Preprocessing starts the moment a file is picked (progress shows on the chip: "Reading page 3/12",
"Frame 2/6"), so it is usually finished by the time the user has typed their question. Send is
disabled until every chip is ready. The original file / thumbnail is kept under
`filesDir/attachments/` so bubbles can show it later.

With `muse-glimmer:latest` and *Server model can see images* enabled, photos and a sampled preview
frame from each video are also sent as base64 `images` on the compatible chat message
(`MuseGlimmerChatClient.toWireRequest()`), alongside the on-device description and video timeline. No app
rebuild or alternate model selection is needed.

Alternatives considered and rejected: doing it in the web page's JavaScript (heavy, and pdf.js /
Tesseract.js downloads are slow on a phone browser); a server-side upload endpoint on the Mac (moves
the heavy lifting off-device, which is the opposite of the goal, and adds an upload path to secure).

### Extending further (audio, other backends)

- **Message model**: a `Message` is a list of `MessagePart`s. `Image`, `File` and `Audio` parts are
  defined and persisted (`message_parts` table, one row per part with a `type` column). Add a new
  part type = add a sealed-class case, a mapper branch in `data/local/Mappers.kt`, a branch in
  `AndroidAttachmentPreprocessor`, and a renderer branch in `MessageBubble` / `AttachmentParts`.
- **Transport**: `ChatServerClient` is the only thing that knows the wire format. A different
  backend (OpenAI-style SSE, a websocket for live audio) is a new `ChatServerClient` implementation
  swapped in `AppContainer`.
- **Streaming events**: `StreamEvent` is a sealed interface; audio chunks or tool calls become new
  event types handled in `SendMessageUseCase`.

### Context compaction (how old chats stay coherent)

`WindowedSummaryCompactor` builds the context sent with every new prompt:

1. The last **N** messages (default 12, i.e. 6 exchanges; editable in Settings) are sent verbatim.
2. Everything older is replaced by one short **rolling summary** stored on the chat row.
3. After a reply completes, if ≥ 4 messages have fallen outside the window since the last summary,
   the app asks the model (in the background, non-streaming, no thinking) to fold them into an
   updated ≤120-word summary. If the server is unreachable it falls back to an extractive clip
   (first ~160 chars of each message).
4. Until the model summary catches up, any uncovered older messages are clipped extractively so the
   prompt is always complete.
5. A rough token budget (~6k tokens, chars/4) shrinks the verbatim window for very long messages.

The strategy is behind the `ContextCompactor` interface so it can be replaced (e.g. embeddings +
retrieval) without touching the UI.

### Server protocol (from InfraAgent)

`POST {base}/api/chat` with `{"model": "muse-glimmer:latest", "messages": [...], "stream": true}` and
the conversation's stable ID in `X-Muse-Session-ID`.
The response is newline-delimited JSON; each line carries `message.thinking` or `message.content`
deltas and the last line has `done: true`. `POST /api/sessions/{id}/heartbeat` renews a live lease;
404 means it expired and the next full-history chat request safely rebuilds it. No authentication
is currently configured (trusted LAN only).
