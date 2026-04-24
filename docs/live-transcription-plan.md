# Live Transcription Mode — Design Plan

**Status:** Pre-implementation design. Not approved for work.  
**Author:** Guru-Dev research pass, April 2026  
**Target release scope:** v1 Parakeet-only append-only streaming; v2 backtracking; v3 WhisperKit

---

## Table of Contents

1. [ASR Backend Streaming Capability](#1-asr-backend-streaming-capability)
2. [Text Injection Strategy](#2-text-injection-strategy)
3. [Partial Hypothesis Reconciliation](#3-partial-hypothesis-reconciliation)
4. [TCA Architecture Integration](#4-tca-architecture-integration)
5. [Risks, Unknowns, and Rollout](#5-risks-unknowns-and-rollout)
6. [Architecture Revisions (Post-Library Review)](#6-architecture-revisions-post-library-review) — **read this; it supersedes parts of §4**
7. [Recommended v1 Scope](#recommended-v1-scope)
8. [Open Questions](#open-questions)
9. [Proposed First Spike](#proposed-first-spike)

---

## 1. ASR Backend Streaming Capability

### 1.1 FluidAudio / Parakeet EOU — Streaming-Native

FluidAudio ships a dedicated streaming API in `StreamingEouAsrManager`. This is a **separate class from `AsrManager`** (the batch manager Hex currently uses). The streaming class is purpose-built for real-time use:

```swift
// From FluidAudio Documentation/API.md
let manager = StreamingEouAsrManager(
    chunkSize: .ms160,       // 160ms = lowest latency, ~8% WER
    eouDebounceMs: 1280      // Minimum silence before EOU fires
)
try await manager.loadModels(modelDir: modelsURL)

manager.setEouCallback { transcript in
    // Called when silence threshold is met — "utterance done"
    print("EOU: \(transcript)")
}

// Hot path — called for every audio chunk
_ = try await manager.process(audioBuffer: audioChunk)

// After hotkey release — finalize whatever partial was in flight
let finalTranscript = try await manager.finish()
await manager.reset()
```

Key facts:

- `process(audioBuffer:)` is the per-chunk entry point. It currently **returns an empty string** — the accumulated transcript comes from `finish()` or from the `setEouCallback`. There is **no per-chunk partial hypothesis string exposed in the current API**. This is the most important constraint for v1 design (see Section 3).
- `eouDetected: Bool` property can be polled after each `process()` call to know if the model declared an utterance boundary.
- Chunk sizes: `.ms160` (~8% WER on LibriSpeech), `.ms320` (~5% WER), `.ms1600` (batch-like throughput). For live transcription, `.ms320` is the right tradeoff — it yields acceptable WER without the latency of a full-utterance boundary wait.
- **The EOU model is a separate model bundle from the Parakeet TDT v3** already shipped by Hex. It requires its own `loadModels(modelDir:)` call pointing at a different model directory (a Parakeet EOU variant, not the TDT-CTC batch variant). Model download is a non-trivial addition: this is a separate model the user does not yet have, and it must be managed by `ModelDownloadFeature`.
- Performance on Apple Silicon: roughly 5x real-time factor (RTF) at 160ms, 12x RTF at 320ms. With 320ms chunks on M-series hardware, inference completes in approximately 25–27ms, which is well inside the chunk period and leaves headroom for text injection.

**Verdict:** FluidAudio is the right first target. The streaming API is real and documented. The main friction is that partials are not exposed per-chunk in the current API — only on EOU fire. This means v1 live streaming will work at the utterance level (append-on-EOU) rather than sub-word streaming. True word-by-word streaming requires either: (a) FluidAudio exposing a per-chunk hypothesis in a future API update; or (b) polling `finish()` speculatively after each chunk, which is untested.

### 1.2 WhisperKit — Streaming via AudioStreamTranscriber

WhisperKit exposes a streaming path via `AudioStreamTranscriber`:

```swift
// From WhisperKit / argmax-oss-swift documentation
let audioStreamTranscriber = AudioStreamTranscriber(
    audioEncoder: whisperKit.audioEncoder,
    featureExtractor: whisperKit.featureExtractor,
    segmentSeeker: whisperKit.segmentSeeker,
    textDecoder: whisperKit.textDecoder,
    tokenizer: tokenizer,
    audioProcessor: whisperKit.audioProcessor,
    decodingOptions: DecodingOptions(task: .transcribe)
) { oldState, newState, error in
    // State change callback
    for segment in newState.confirmedSegments {
        // These will not change again
    }
    for segment in newState.unconfirmedSegments {
        // These are tentative and may be revised
    }
    // newState.currentText — the full live hypothesis
}

try await audioStreamTranscriber.startStreamTranscription()
```

This API is meaningful: it distinguishes `confirmedSegments` (stable) from `unconfirmedSegments` (tentative). This maps directly onto the "backtracking" problem in Section 3.

However, WhisperKit streaming has significant caveats:

- **Encoder-decoder architecture overhead.** Whisper's encoder runs over a 30-second mel spectrogram window. `AudioStreamTranscriber` slides this window forward in chunks (typically 5–15 seconds of overlap), running a full encoder+decoder pass each time. On Apple Silicon, encoder inference for Whisper Small is ~200–400ms; for Large v3, ~1–2s. This means the streaming latency is measured in hundreds of milliseconds to seconds per update, not tens of milliseconds.
- **`startStreamTranscription()` opens its own `AVAudioEngine` tap.** This conflicts with Hex's `SuperFastCaptureController`, which already owns the input node tap. Running two taps on the same input node will crash. The integration requires routing audio manually to WhisperKit or restructuring the capture path — significant engineering work.
- **WER is lower than Parakeet EOU** (~3–5% for Whisper Small, ~2% for Large v3 on English) but the streaming latency is worse. Users would see text appear in bursts rather than continuously.
- The existing `WhisperKit` instance in `TranscriptionClientLive` exposes `audioEncoder`, `featureExtractor`, etc. as properties, so constructing `AudioStreamTranscriber` is feasible without a new download.

**Verdict:** WhisperKit streaming is real but architecturally harder and significantly higher latency for this use case. Treat as v3 — valuable for multilingual accuracy, lower priority for initial live mode.

### 1.3 Backend Recommendation

Build v1 on **FluidAudio's `StreamingEouAsrManager`** with `.ms320` chunks. Parakeet's RNN-T/TDT architecture is purpose-built for streaming; the API is stable and documented; the latency budget is comfortable on Apple Silicon. WhisperKit streaming is deferred to v3.

The **main caveat** is that `StreamingEouAsrManager` requires downloading a **new EOU model** that is separate from the Parakeet TDT v3 already in Hex. This model must be integrated into `ModelDownloadFeature` and added to `models.json`. Estimate: ~300–400MB additional model size.

---

## 2. Text Injection Strategy

Today's output path is `pasteboard.paste(result)` — a single atomic write at the end of the recording. Streaming requires a fundamentally different approach: the text appears character by character in the focused element and may be partially retracted.

The app sandbox already has:
- `com.apple.security.automation.apple-events = true` — for AppleScript/System Events (used by current `simulateTypingWithAppleScript` and `pasteToFrontmostApp`)
- `com.apple.security.network.client = true` — for HF model downloads
- `com.apple.security.app-sandbox = true`

The current `PasteboardClientLive` already implements three strategies: Cmd+V (CGEvent), AppleScript menu click, and `AXUIElementSetAttributeValue(focusedElement, kAXSelectedTextAttribute)`.

### 2.1 Option A: Synthetic Key Events via CGEvent

Inject one character at a time using `CGEvent(keyboardEventSource:virtualKey:keyDown:)`, and retract by posting backspace key events (`CGKeyCode 51`). This is how Apple's own Dictation injects text under the hood.

**Hot path sketch:**

```swift
// Injecting a single Unicode scalar
func injectCharacter(_ scalar: Unicode.Scalar) {
    let source = CGEventSource(stateID: .combinedSessionState)
    var keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)!
    var keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)!
    keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: [scalar.value])
    keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: [scalar.value])
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
}

// Retracting N characters
func retract(count: Int) {
    let source = CGEventSource(stateID: .combinedSessionState)
    for _ in 0..<count {
        CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true)!.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false)!.post(tap: .cghidEventTap)
    }
}
```

**Reliability by app type:**

| App | Works? | Notes |
|-----|--------|-------|
| Native Cocoa (TextEdit, Notes, Mail) | Excellent | Full Unicode support, autocorrect fires naturally |
| Electron (VS Code, Slack desktop) | Good | CGEvent Unicode injection is respected; autocorrect disabled by default |
| Chrome/Firefox (web inputs) | Good | Web apps receive key events; some rich editors (ProseMirror, CodeMirror) may swallow events |
| Terminal.app | Good for standard input; poor in vim/emacs | Vim normal mode will misinterpret character injection |
| Password fields | Blocked | macOS blocks Unicode event injection into password fields as a security measure |
| Sandboxed apps | Good | CGEvent at `.cghidEventTap` works cross-process; no special entitlement needed beyond what Hex already has |

**Entitlement requirements:** None beyond what is already present. CGEvent posting at `.cghidEventTap` works from a sandboxed app. However, creating the event source with `.combinedSessionState` may require the app to be a foreground process or have Accessibility permission — this is a spike item (see Section 5).

**Backtracking:** Post N backspace events before injecting new suffix. This is the universal approach and works everywhere CGEvent injection works.

**Failure modes:**
- If the user clicks away mid-stream, focus changes and backspaces land in the wrong field. The injection loop must monitor the frontmost application and abort if it changes.
- Autocorrect in the host app (TextEdit, iOS-style apps on macOS 14+) may silently rewrite injected text, making the character count for backtracking wrong. Mitigation: disable autocorrect detection is hard; the safer approach is to use AX as primary (see Option B) and fall back to CGEvent.
- Typing speed: injecting a long burst of characters (e.g., a full 300ms-chunk worth of text) will appear as a rapid burst. This is visually fine but may trigger rate-limiting in some apps. The fix is to batch the diff and inject as a single AX attribute set, not character by character.

### 2.2 Option B: Accessibility API (AXUIElement) — Primary Recommendation

Set `kAXSelectedTextAttribute` on the focused UI element with the new text, or use `kAXSelectedTextRangeAttribute` + `kAXInsertionPointLineNumberAttribute` to manipulate the selection range. The `PasteboardClientLive.insertTextAtCursor` method already does a simpler version of this — it sets `kAXSelectedTextAttribute` to replace the current selection with new text.

For live streaming with backtracking, the approach is:

1. Before emitting the first partial, record the cursor position (character offset) using `kAXSelectedTextRangeAttribute`. Store this as `liveAnchorRange`.
2. On each new partial hypothesis, compute the diff. Then:
   a. Set `kAXSelectedTextRangeAttribute` to `(anchor, anchor + len(previous_partial))` — this selects the tentative text.
   b. Set `kAXSelectedTextAttribute` to the new partial string — this replaces the selection atomically.
3. On finalize (EOU or hotkey release): the text is already in the field. Update `liveAnchorRange` and clear state.

**Hot path sketch:**

```swift
func replaceRange(element: AXUIElement, anchorOffset: Int, previousLength: Int, newText: String) {
    // Select the tentative text (from anchor to anchor + previousLength)
    let newRange = CFRange(location: anchorOffset, length: previousLength)
    let rangeValue = AXValueCreate(.cfRange, &newRange)!
    AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
    // Replace selection with new partial
    AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, newText as CFTypeRef)
}
```

**Reliability by app type:**

| App | Works? | Notes |
|-----|--------|-------|
| Native Cocoa | Excellent | Full AX support; the current `insertTextAtCursor` already uses this path |
| Electron (VS Code, Slack) | Poor | Electron apps expose a minimal AX tree. `kAXSelectedTextAttribute` write often fails with `.apiDisabled` |
| Chrome (web inputs) | Moderate | AX writes work for native-like inputs, fail for many rich-text editors |
| Terminal | Poor | Terminal.app exposes very little via AX |
| Password fields | Blocked | AX is blocked for password fields |
| SwiftUI apps | Varies | SwiftUI text fields expose AX, but the behavior depends on macOS version |

**Entitlement requirements:** Reading `kAXFocusedUIElementAttribute` from the system-wide element requires Accessibility permission (TCC prompt, `com.apple.security.accessibility.inspect` or user grant via System Settings > Privacy > Accessibility). Hex does not currently request this. Writing attributes requires the same permission. This is the primary blocker: adding AX write capability will trigger a TCC prompt on first use.

**Sandbox compatibility:** AX reads/writes from a sandboxed app require the user to grant Accessibility permission in System Settings. This is compatible with the sandbox — it does not require dropping the sandbox. The prompt is a one-time UX gate.

### 2.3 Option C: Input Method Kit (IMKInputController / TSM)

Implementing a proper Input Method (IM) would let Hex inject marked/uncommitted text the same way CJK input methods do — with full OS-level support for revision, no Accessibility permission, and native compatibility everywhere. The IM would hold uncommitted text in the "composition buffer" until EOU, then commit.

**Why this is attractive in theory:** Perfect compatibility, no TCC prompts, no backspace hackery. The OS handles replacing tentative text.

**Why it is a poor choice for v1:**
- Implementing an IMKInputController requires registering a separate bundle (`.component` extension) recognized by the Input Method System. This is a distinct process from the main app, requires separate code signing, and must be installed into `/Library/Input Methods/` or the user's Library equivalent — which is incompatible with the App Sandbox without special dispensation.
- The integration with menu-bar apps is non-standard. Hex would need to spawn a helper process.
- Testing across the full app matrix is very expensive.
- This is 3–4x the engineering work of AX or CGEvent.

**Verdict:** Defer IMK permanently. The complexity-to-benefit ratio does not support it.

### 2.4 Recommended Strategy

**Primary: AXUIElement selection-replace.** Fast, supports atomic replacement without backspace churn, works across native Cocoa apps (the highest-value target). Requires a one-time Accessibility TCC prompt.

**Fallback: CGEvent backspace + Unicode injection.** Covers Electron apps and web browsers where AX writes fail. Works without additional TCC but has the autocorrect interference risk.

**Determine fallback at runtime:** After obtaining the focused element, attempt `AXUIElementSetAttributeValue(..., kAXSelectedTextAttribute)` with a zero-length probe. If it returns `.success`, use AX. If it returns `.apiDisabled` or `.failure`, fall back to CGEvent.

**Text injection client interface:**

```swift
// New dependency in HexCore (for unit testability)
protocol TextInjectionClient: Sendable {
    // Begin a live session; records anchor position
    func beginSession(in element: AXUIElement) async throws -> LiveSession

    // Atomically replace previous partial with new partial
    func updatePartial(session: LiveSession, newText: String) async throws

    // Commit the final text (no more changes)
    func commit(session: LiveSession) async throws

    // Abort — leave whatever is in the field as-is, or retract if possible
    func abort(session: LiveSession) async throws
}
```

**Focus-change guard:** At the start of each injection loop iteration, compare `NSWorkspace.shared.frontmostApplication?.bundleIdentifier` against the value captured at session start. If they differ, call `abort()` immediately. The same check applies on the TCA side — the `LiveTranscriptionFeature` should store `sourceAppBundleID` (already tracked in `TranscriptionFeature`) and abort if focus leaves.

**Password field guard:** Before starting injection, check `kAXRoleAttribute == "AXSecureTextField"` on the focused element. If true, fall back to clipboard paste at end-of-utterance (same as current batch mode), never inject live.

---

## 3. Partial Hypothesis Reconciliation

This section assumes a future FluidAudio API update exposes a per-chunk partial hypothesis string (or that we poll `finish()` speculatively). The design should be built to receive a stream of partial strings even if v1 uses only EOU-level granularity.

### 3.1 The Diff Algorithm

Given previous partial `P` and new partial `Q`, compute the minimal edit to apply to what's already typed:

```
P = "the quick brown"
Q = "the quick brown fox"
→ commonPrefixLen = 15 ("the quick brown")
→ retract(len(P) - 15) = retract(0)
→ inject("fox")
```

A more complex revision:

```
P = "the quick brawn"    // ASR initially heard "brawn"
Q = "the quick brown"    // Model revised after more audio
→ commonPrefixLen = 10 ("the quick ")
→ retract(5)              // delete "brawn"
→ inject("brown")         // type "brown"
```

**Algorithm (character-level LCP):**

```swift
struct PartialDiff {
    let retractCount: Int    // Number of chars to erase
    let appendText: String   // New text to inject after erasing
}

func diff(previous: String, next: String) -> PartialDiff {
    let commonLen = zip(previous, next).prefix(while: { $0.0 == $0.1 }).count
    let retract = previous.count - commonLen
    let append = String(next.dropFirst(commonLen))
    return PartialDiff(retractCount: retract, appendText: append)
}
```

This is O(min(|P|, |Q|)) and runs in microseconds — well within the 320ms chunk budget.

### 3.2 Stability-Based Commit Threshold

The most important UX principle here is: **don't retract text the user is already reading**. Churn on the last 1–2 words is acceptable (the model is still deciding); churn on the opening of a sentence is jarring.

Two approaches from the industry:

**Approach A — Persistence count (Deepgram-style "is_final"):**  
A token (or word) is "committed" once it has appeared in the same form across K consecutive partial hypotheses without change. K=3 at 320ms/chunk = committed after ~1 second of stability. Committed text is never retracted; only the uncommitted suffix can be revised.

**Approach B — VAD silence gate (Apple Dictation-style):**  
Text is tentative until a ≥300ms VAD silence is detected, at which point the current partial is committed. This maps naturally onto the EOU callback in `StreamingEouAsrManager` — EOU fires after `eouDebounceMs` of silence and the EOU transcript is considered final.

**Recommendation for v1:** Use VAD silence gate (Approach B) because `StreamingEouAsrManager` already provides the EOU callback and the EOU transcript is FluidAudio's finalized result. Committed text = text from last EOU event. Uncommitted suffix = text in flight since last EOU.

**Recommendation for v2 (if per-chunk partials become available):** Add persistence count on top of the VAD gate. Tokens stable for ≥3 chunks are promoted to committed even before EOU. This enables smooth word-by-word injection.

### 3.3 UX Hazard Matrix

| Hazard | Impact | Mitigation |
|--------|--------|-----------|
| User types manually while live-dictation is injecting | Characters interleaved; anchor position invalid | On any user-originated key event detected during live session, abort injection immediately and transition to "capture and paste at end" fallback |
| Focus changes mid-stream (Command+Tab, click away) | Backspaces and new text land in wrong app | Monitor `NSWorkspace.frontmostApplicationDidChangeNotification`; abort session on any change |
| User presses Backspace | Our anchor offset is wrong; next backtrack will erase user's character | Treat any key event from the user as a session abort signal (see above) |
| Host app autocorrect rewrites injected text | Character count for backtracking is wrong | Prefer AX `kAXSelectedTextRangeAttribute` approach (reads actual selection range from the field, not a locally maintained count); for CGEvent fallback, disable autocorrect detection is infeasible — best bet is conservative commit and minimal backtracking |
| Multi-line text fields | Line breaks affect character counting if using AX range | AX ranges are character-offset based in most implementations, line breaks are just `\n` in the text — should work. Test explicitly. |
| Password fields | Security risk | Detect `AXSecureTextField` role before session start; fall through to batch-paste mode |
| Very fast speech, model can't keep up | Process queue backs up | `process(audioBuffer:)` is async; if it can't keep up, chunks must be dropped (not queued unboundedly). Add a bounded channel between the audio tap and the ASR loop. |
| Model not loaded yet | Crash or hang | Gate on `modelBootstrapState.isModelReady` exactly as the current batch path does; the EOU model will need its own ready state |
| Hotkey released before EOU fires | Partial text in field, no finalization | On hotkey release, always call `finish()` and inject the remaining partial before returning |

### 3.4 Word Remappings and Removals

Today's `WordRemappingApplier` and `WordRemovalApplier` run on the final batch transcript. In streaming mode, applying them per-partial would cause bizarre visible rewrites as words scroll by. 

**Recommendation:** In v1, disable word remappings and removals during live injection. Apply them only on the final `finish()` result, then do one last diff-and-replace to swap the live text with the remapped version. This is a known limitation to document in the Settings UI when live mode is active.

---

## 4. TCA Architecture Integration

### 4.1 Where Does the New State Machine Live?

**Option A: Extend `TranscriptionFeature` with a mode enum.**  
Add `enum TranscriptionMode { case batch, live }` to `TranscriptionFeature.State`. The existing reducer grows a live-specific branch. Simple, no new reducer.

**Option B: New `LiveTranscriptionFeature` reducer.**  
A sibling to `TranscriptionFeature`, composed at the `AppFeature` level. Completely separate state and action types. Cleaner isolation; allows the batch path to remain untouched.

**Recommendation: Option B — new `LiveTranscriptionFeature`.**

The live path has fundamentally different state (anchor position, partial buffer, injection session, EOU model state) and a different action graph (chunk-level, not file-level). Mixing it into `TranscriptionFeature` would make that reducer load-bearing for two very different problems. A separate feature composes cleanly and lets us test them in isolation.

`AppFeature` would hold `TranscriptionFeature.State` and `LiveTranscriptionFeature.State` side-by-side and route hotkey events to the appropriate feature based on `hexSettings.transcriptionMode`.

> **Note:** §4.2–4.4 describe the original draft shape. After a library-architecture review (see §6), the adapter interface flips to declarative desired-state, fallbacks move into a composite adapter, and a dedicated `ReconciliationEngine` sits between the streaming client and the injector. Treat §6 as the final v1 shape.

### 4.2 New Dependency: `TextInjectionClient`

```swift
// Lives in Hex/Clients/ (not HexCore — it depends on AppKit/AX frameworks)
@DependencyClient
struct TextInjectionClient {
    var beginSession: @Sendable () async throws -> LiveInjectionSession
    var updatePartial: @Sendable (LiveInjectionSession, String) async throws -> Void
    var commit: @Sendable (LiveInjectionSession) async throws -> Void
    var abort: @Sendable (LiveInjectionSession) async throws -> Void
}
```

`LiveInjectionSession` is a value type carrying:
- `anchorOffset: Int` — character position in the focused element when the session started
- `previousPartial: String` — last partial injected (for diff computation)
- `focusedElement: AXUIElement` — captured at session start
- `strategy: InjectionStrategy` — `.ax` or `.cgEvent`

### 4.3 New Dependency: `StreamingTranscriptionClient`

```swift
// Lives in Hex/Clients/
@DependencyClient
struct StreamingTranscriptionClient {
    // Returns an AsyncStream of events
    var startSession: @Sendable (StreamingConfig) async throws -> AsyncStream<StreamingEvent>
    var pushAudioBuffer: @Sendable (AVAudioPCMBuffer) async throws -> Void
    var finish: @Sendable () async throws -> String
    var cancel: @Sendable () async -> Void
}

enum StreamingEvent: Sendable {
    case partial(String)       // New partial hypothesis
    case eou(String)           // End-of-utterance with finalized transcript
    case error(Error)
}
```

The live implementation wraps `StreamingEouAsrManager`. The test/preview implementation yields canned events at configurable intervals.

### 4.4 Reconciliation Logic in HexCore

The diff algorithm (Section 3.1) and the stability logic (Section 3.2) are pure functions with no AppKit dependencies. They belong in `HexCore/Sources/HexCore/Logic/`:

```
HexCore/Sources/HexCore/Logic/
  HotKeyProcessor.swift          (existing)
  RecordingDecision.swift        (existing)
  PartialHypothesisDiffer.swift  (new)
  LiveTranscriptionState.swift   (new — pure state machine)
```

`PartialHypothesisDiffer.swift` exports:
```swift
public struct PartialDiff: Equatable, Sendable {
    public let retractCount: Int
    public let appendText: String
    public static func compute(previous: String, next: String) -> PartialDiff
}
```

This is unit-testable without any AppKit or FluidAudio dependency. Tests go in `HexCoreTests`.

### 4.5 HexSettings Changes

Add to `HexSettings`:

```swift
public var liveTranscriptionEnabled: Bool   // toggle in Settings > General
public var liveTranscriptionChunkSize: LiveChunkSize  // .ms160 / .ms320
```

And a new `HexSettingKey` case for each. The existing `normalizeDoubleTapSettings()` pattern can be followed for any derived normalization. The `LiveChunkSize` type lives in `HexCore`.

### 4.6 Hotkey Routing

Live mode does not necessarily need a different hotkey. The simplest UX is:

- If `liveTranscriptionEnabled` is `true`, the existing hotkey triggers `LiveTranscriptionFeature` instead of `TranscriptionFeature`.
- Double-tap lock is especially useful here: activate live mode hands-free.

The routing decision happens in `AppFeature`, which routes `hotKeyPressed`/`hotKeyReleased` to the appropriate child feature based on `hexSettings.liveTranscriptionEnabled`.

No changes to `HotKeyProcessor` are needed for v1. The existing press-and-hold and double-tap-lock semantics are retained.

### 4.7 Audio Capture Path

`SuperFastCaptureController` already delivers `AVAudioPCMBuffer` to a `processingQueue` in the `enqueue()` → `process()` pipeline. Today, `process()` writes samples to a file. In live mode, we need to also (or instead) push buffers to the streaming ASR loop.

The cleanest approach: add a second observer hook to `SuperFastCaptureController`:

```swift
// New property on SuperFastCaptureController
var onBuffer: ((AVAudioPCMBuffer) -> Void)?
```

When `onBuffer` is set (i.e., live mode is active), `process()` calls it in addition to (or instead of) writing to file. The `RecordingClient` plumbs this through as a new `startLiveCapture(onBuffer:)` method, which starts the engine and sets the hook without opening an output file.

Importantly, `StreamingEouAsrManager.process(audioBuffer:)` expects audio at its native sample rate (typically 16kHz, same as Hex's `targetFormat`). The existing `convert()` pipeline in `SuperFastCaptureController` already resamples to 16kHz — the buffer format is directly compatible.

### 4.8 Architecture Diagram (Simplified)

```
Hotkey event
    │
    ▼
AppFeature
    │ (liveTranscriptionEnabled?)
    ├─ YES ──► LiveTranscriptionFeature
    │               │
    │               ├─ RecordingClient (existing, extended with onBuffer hook)
    │               │       │ AVAudioPCMBuffer @ 16kHz
    │               │       ▼
    │               ├─ StreamingTranscriptionClient
    │               │       │ StreamingEvent (.partial, .eou)
    │               │       ▼
    │               ├─ PartialHypothesisDiffer (HexCore, pure)
    │               │       │ PartialDiff
    │               │       ▼
    │               └─ TextInjectionClient
    │                       │ AXUIElement writes / CGEvent backspace+inject
    │                       ▼
    │                 [Focused text field]
    │
    └─ NO ───► TranscriptionFeature (unchanged)
```

---

## 5. Risks, Unknowns, and Rollout

### 5.1 Sandbox and Entitlement Implications

**CGEvent posting:** `CGEvent.post(tap: .cghidEventTap)` from a sandboxed app requires no additional entitlement for posting synthetic events. However, creating an event source with `.combinedSessionState` may require Input Monitoring permission (`com.apple.security.input-monitoring`) on macOS 12+. This needs verification: the current `PasteboardClientLive.postCmdV()` already uses this pattern successfully, which suggests Input Monitoring is either already granted or not required for event posting (only for monitoring). The distinction is important: **event posting** (what we need) is different from **event monitoring** (what Sauce/KeyEventMonitorClient does). This is a spike item.

**AX writes:** Writing to `kAXSelectedTextAttribute` requires Accessibility permission granted by the user in System Settings > Privacy & Security > Accessibility. This is a TCC prompt. The prompt fires once; subsequent launches use the cached grant. Hex must call `AXIsProcessTrustedWithOptions` and handle the "not trusted" case gracefully — either by degrading to CGEvent injection or by surfacing a permission prompt in Settings. The existing `PermissionsSectionView.swift` is the right place to add an Accessibility permission row.

**New entitlement needed:** No new entitlements are required beyond what is already declared. AX permission is a TCC grant, not an entitlement. CGEvent posting does not require a sandbox exception.

**App Sandbox compatibility summary:** Both AX and CGEvent injection are compatible with the App Sandbox as it stands. No entitlement changes to `Hex.entitlements` are required.

### 5.2 Latency Budget

End-to-end latency from speech to visible text on Apple Silicon M-series:

| Stage | Budget |
|-------|--------|
| Audio buffer fill time (320ms chunk) | 320ms |
| SuperFastCaptureController → onBuffer callback | ~1–5ms |
| `StreamingEouAsrManager.process()` inference | ~25–30ms (12x RTF at 320ms) |
| `PartialHypothesisDiffer.compute()` | <1ms |
| `TextInjectionClient.updatePartial()` AX write | ~2–5ms |
| **Total from end of chunk to text appearing** | **~30–40ms** |
| **Total latency from speech to text (best case)** | **350–360ms** |

This is comparable to Apple Dictation (~300–400ms) and better than most streaming cloud ASR services (~500–800ms round-trip). It is fast enough to feel live.

**Note:** The 320ms chunk granularity means text appears in bursts aligned to chunk boundaries, not truly word-by-word. On an EOU-only basis (v1), the user sees nothing during speech and then sees the full utterance appear at EOU. This is the primary UX tradeoff of v1 vs. v2.

### 5.3 What We Cannot Know Without a Spike

1. **Whether `StreamingEouAsrManager` exposes useful partials before EOU.** The documented API returns an empty string from `process()`. We need to experimentally verify: does `finish()` return a partial mid-utterance? If called between chunks, what does it return? If it returns a stable running partial, v2 backtracking becomes simpler.

2. **Whether `StreamingEouAsrManager` uses a separate model from the current Parakeet TDT v3.** The docs reference a "Parakeet EOU" variant with its own `loadModels(modelDir:)` call pointing at a different directory. We need to confirm: can `StreamingEouAsrManager` reuse the already-downloaded TDT v3 assets, or does it require a completely new model download? This directly impacts the rollout story (does enabling live mode require a 300–400MB additional download?).

3. **Whether CGEvent Unicode injection requires Input Monitoring TCC on macOS 15.** The current `postCmdV()` uses `.cghidEventTap` without a TCC prompt. Does injecting arbitrary Unicode scalars via `keyboardSetUnicodeString` trigger the same gate?

4. **Actual EOU debounce UX feel.** With `eouDebounceMs: 1280`, a 1.28-second pause is required before the utterance is committed. For natural speech with pauses, this may be too long (user says "um..." and waits — does the EOU fire mid-thought?). Need to experiment with values like 800ms and 600ms.

5. **AX write compatibility with Electron apps.** The existing `insertTextAtCursor` already attempts AX writes and falls back. We need to measure the failure rate across Slack, VS Code, and Notion specifically.

### 5.4 Staged Rollout

**v1 — Parakeet EOU, append-only, no mid-stream backtracking:**
- Trigger: existing hotkey, gated by `liveTranscriptionEnabled = true` (off by default)
- EOU model download required (flag this prominently in Settings)
- Streaming session: audio accumulates per-chunk, EOU fires after silence, full utterance text injected at once via AX or CGEvent
- No backtracking: the text is injected as a single string per EOU event, exactly like batch mode but without waiting for hotkey release
- Word remappings applied on commit (same as batch)
- Password field guard: fall through to batch paste
- Focus-change guard: abort and fall through to batch paste
- History logging: each EOU-committed utterance is a history entry, exactly as today

**v2 — Per-chunk partials and backtracking (requires FluidAudio per-chunk hypothesis API or speculative `finish()` polling):**
- Text appears word-by-word during speech, not just at EOU
- Committed prefix (stable across 3+ partials) is never retracted
- Uncommitted suffix may be revised up to one EOU boundary
- Word remappings disabled during live injection; applied at commit
- Requires spike findings from Section 5.3, item 1

**v3 — WhisperKit streaming:**
- `AudioStreamTranscriber` integration
- Must resolve audio engine tap conflict with `SuperFastCaptureController`
- `confirmedSegments` maps to committed text; `unconfirmedSegments` maps to revisable suffix
- Higher accuracy for multilingual input; higher latency
- Separate model selection (only available for downloaded Whisper models)

---

## 6. Architecture Revisions (Post-Library Review)

After drafting §1–§5, we ran the proposed architecture against the project's reference library (Clean Architecture; Fundamentals of Software Architecture; Software Architecture: The Hard Parts; Architecture for Flow; Designing Data-Intensive Applications; Enterprise Integration Patterns; 97 Things Every Data Engineer Should Know; Fundamentals of Data Engineering; LLM Engineer's Handbook; Designing Machine Learning Systems). Three concrete revisions came out of that pass and supersede the corresponding parts of §4. The streaming-ASR theory question (token stability in TDT) was not resolvable from the library; that confirms Spike #1 (§Proposed First Spike) is load-bearing rather than belt-and-suspenders.

### 6.1 Pipeline as a typed event stream, not method calls

**Source:** DDIA on event streams ("an event is generated once by a producer… potentially processed by multiple consumers" [p.459]); 97 Things on tardy data ("some data is born late, some achieves lateness" [p.150]).

**Why it changes:** the original draft has the streaming client invoke methods on the differ which invokes methods on the injector. That collapses two distinct semantics — *new tentative hypothesis* and *finalized commit* — into the same call. Modeling the pipeline as a typed event log makes the semantics first-class, makes the differ trivially unit-testable from canned event arrays, and gives us a place to tag a monotonic `revisionId` for idempotency.

**Final shape (HexCore):**

```swift
public enum TranscriptionEvent: Sendable, Equatable {
    case provisional(Hypothesis)          // may be revised
    case finalize(CommittedText)          // immutable from this revisionId forward
    case retract(tokenRange: Range<Int>)  // only on recovery / explicit user-driven abort
}

public struct Hypothesis: Sendable, Equatable {
    public let revisionId: UInt64         // monotonic per session
    public let text: String
    public let tokens: [Token]            // optional; v2 will use these for stability scoring
    public let stability: Double          // 0..1 — from the model where available, else heuristic
}
```

`StreamingTranscriptionClient.startSession` now returns `AsyncStream<TranscriptionEvent>` instead of a free-form callback. The v1 EOU-only mode emits exactly one `.finalize` per EOU callback and zero `.provisional` events; v2 enables `.provisional` between EOUs without changing the consumer.

### 6.2 `ReconciliationEngine` as an explicit middle stage in HexCore

**Source:** Fundamentals of Data Engineering ("streaming transformations aim to prepare data for downstream consumption" [p.353]); 97 Things on long-running streaming services and bounded queues [p.150].

**Why it changes:** the original draft puts the diff and the stability heuristic in HexCore but leaves the *commit/coalesce/backpressure policy* implicit, scattered across the streaming client and the injector. The library is unanimous: that policy is its own stream-processing stage and should be named, isolated, and unit-tested.

**Final shape (HexCore, pure):**

```swift
public actor ReconciliationEngine {
    public struct Configuration: Sendable {
        public var maxPendingProvisionals: Int = 3   // bounded queue depth
        public var coalesceProvisionals: Bool = true // collapse superseded provisionals
        public var commitMode: CommitMode = .endOfUtterance  // v1: EOU-only
    }

    public init(configuration: Configuration) { /* … */ }

    /// Consume one upstream event, return zero or more downstream commands.
    /// Pure: no AppKit, no AX, no audio. Easily unit-tested.
    public func ingest(_ event: TranscriptionEvent) -> [InjectionCommand]
}

public enum InjectionCommand: Sendable, Equatable {
    case apply(InjectionIntent)  // see §6.3 — declarative desired-state
    case beginSession(generation: UInt64)
    case endSession(generation: UInt64)
    case abort(reason: AbortReason)
}
```

Backpressure rules (encoded inside the engine, testable in isolation):
- **Bounded queue, depth 3, drop-oldest** for `.provisional` only.
- **Coalesce-revisions:** when a newer `.provisional` lands and the queue is non-empty, collapse the queue into the latest revision.
- **Never drop `.finalize`** — it is the commit boundary. If the queue is full and a finalize arrives, evict provisionals to make room.
- **Generation counter** (`UInt64`) is bumped on every session start so stale events from a cancelled session can be rejected by the injector.

This is also where the v2 stability heuristic (K-consecutive-stable-partials) will live when we enable mid-stream commits — adding it later is a config flag and a few new pure functions, not a structural change.

### 6.3 Declarative desired-state injector + composite fallback

**Source:** Clean Architecture ("nothing in an inner circle can know anything at all about something in an outer circle" [p.231]); EIP Document Message ("pass a document to any interested recipient, who is free to decide how to process the document" [p.75]); Architecture for Flow on ports & adapters [p.124].

**Why it changes:** the original draft has the feature (inner core) own the AX-primary / CGEvent-fallback selection logic and emit imperative `typeCharacter` / `backspace` calls. Both leak outer-circle concerns inward. Two consequences: the core needs to know which OS APIs exist, and the diff math is duplicated between core and adapter (we compute the diff in HexCore, then the adapter still has to compute its *own* diff because AX ranges and CGEvent character counts behave differently after host-app autocorrect).

**Final shape:**

The core never says "type these chars." It says: "the on-screen state should now be this." The adapter owns the keystroke math because only the adapter can observe what is actually rendered.

```swift
// Port: lives in Hex/Clients (depends on AppKit/AX, so not in HexCore)
public protocol TextInjectionClient: Sendable {
    func apply(_ intent: InjectionIntent) async throws
    func beginSession(generation: UInt64) async throws
    func endSession(generation: UInt64) async throws
}

public struct InjectionIntent: Sendable, Equatable {
    public let committed: String   // immutable history; never retracted
    public let tentative: String   // currently rendered but revisable suffix
    public let generation: UInt64  // session id; older intents are no-ops
}
```

**Composite adapter pattern:** `CompositeTextInjector` is the single concrete `TextInjectionClient` the feature depends on. Internally it owns:

- `AXTextInjector` — primary, uses `kAXSelectedTextRangeAttribute` + `kAXSelectedTextAttribute` for atomic replacement of the tentative span.
- `CGEventTextInjector` — fallback, computes a character-level LCP diff against its last-rendered string and emits backspaces + Unicode key events.

Selection is **runtime, internal to the composite, and per-session**: on `beginSession`, the composite probes AX with a zero-length write; if `.success`, it locks the session to AX; otherwise to CGEvent. The feature never sees which path ran. This satisfies the dependency rule and makes the v3 IMK option (deferred per §2.3) a drop-in third strategy without any feature-level change.

**Idempotency contract:** adapters MUST be idempotent on `apply` — re-sending the same `InjectionIntent` (same `generation`, same `committed`, same `tentative`) is a no-op. This is what makes the "never observe what's actually rendered" gap from §2 manageable: when in doubt, the engine can re-emit the latest intent and trust the adapter to no-op.

### 6.4 Revised pipeline diagram

```
Hotkey event
    │
    ▼
AppFeature
    │ (liveTranscriptionEnabled?)
    ├─ YES ──► LiveTranscriptionFeature (TCA reducer)
    │               │
    │               ├─ RecordingClient (existing, extended with onBuffer hook)
    │               │       │ AVAudioPCMBuffer @ 16kHz
    │               │       ▼
    │               ├─ StreamingTranscriptionClient
    │               │       │ AsyncStream<TranscriptionEvent>
    │               │       │   .provisional(Hypothesis) | .finalize(...) | .retract(...)
    │               │       ▼
    │               ├─ ReconciliationEngine  (HexCore actor — pure, testable)
    │               │       • bounded queue, coalesce, never-drop-finalize
    │               │       • generation counter
    │               │       │ [InjectionCommand]
    │               │       │   .apply(InjectionIntent) | .beginSession | .endSession | .abort
    │               │       ▼
    │               └─ CompositeTextInjector   (single port; runtime AX→CGEvent selection)
    │                       │ idempotent declarative apply
    │                       ▼
    │                 [Focused text field]
    │
    └─ NO ───► TranscriptionFeature (unchanged)
```

### 6.5 What this changes in §4

- **§4.2 `TextInjectionClient`** — becomes the protocol shown in §6.3. The `LiveInjectionSession` value type is gone (state is now the `(generation, committed, tentative)` triple inside `InjectionIntent`).
- **§4.3 `StreamingTranscriptionClient`** — `StreamingEvent` is replaced by `TranscriptionEvent` with the typed cases above. `startSession` returns `AsyncStream<TranscriptionEvent>` directly.
- **§4.4 Reconciliation in HexCore** — `PartialHypothesisDiffer` stays as a private helper used by the CGEvent injector; the public HexCore surface becomes `ReconciliationEngine` + `TranscriptionEvent` + `InjectionIntent`. Tests target the engine, not the differ.
- **§4.8 diagram** — superseded by §6.4 above.

No change required to §1 (backend choice), §2 (injection mechanics still apply, just relocated behind the composite), §3 (the diff math and stability heuristics still apply, just live inside the injector and the engine respectively), or §5 (risk inventory unchanged).

---

## Recommended v1 Scope

Build live transcription using FluidAudio's `StreamingEouAsrManager` with `.ms320` chunks. Audio flows from the existing `SuperFastCaptureController` (extended with an `onBuffer` callback hook) through a new `StreamingTranscriptionClient` that emits `AsyncStream<TranscriptionEvent>` (typed `.provisional` / `.finalize` / `.retract` events with monotonic revision IDs — see §6.1). Events feed a `ReconciliationEngine` actor in HexCore (§6.2) which owns the commit policy, bounded queue, and coalesce-revisions backpressure rules. The engine emits `InjectionCommand`s carrying declarative `InjectionIntent` values (committed text + tentative suffix + generation). A single `CompositeTextInjector` port (§6.3) consumes those intents and internally chooses between an `AXTextInjector` (primary, atomic `kAXSelectedTextAttribute` replacement) and a `CGEventTextInjector` (fallback, character-level diff with synthetic backspaces); the feature never sees which path ran. v1 commits at EOU only — text appears once per utterance, not word-by-word — but the typed-event + declarative-intent shape makes v2 mid-stream backtracking a config change rather than a refactor. A new `LiveTranscriptionFeature` TCA reducer manages the lifecycle, gated by a `liveTranscriptionEnabled` setting that defaults to `false`. All pure logic (engine, differ, intent computation) lives in `HexCore` for unit testability. A one-time Accessibility TCC prompt is required. The EOU model download must be managed by `ModelDownloadFeature`.

---

## Open Questions

1. Does `StreamingEouAsrManager` require a separate model download, or can it reuse the existing Parakeet TDT v3 assets? How large is the EOU model?
2. Is there any way to get a per-chunk running transcript from `StreamingEouAsrManager` today, enabling v1 to show text as it's spoken rather than at EOU boundaries?
3. What is the right `eouDebounceMs` value for natural conversational speech? Is it user-configurable?
4. Does injecting Unicode characters via `keyboardSetUnicodeString` on a `CGEvent` trigger Input Monitoring TCC on macOS 15, or does the existing Sauce entitlement/grant cover it?
5. Should live mode use the same hotkey with a mode toggle in Settings, or a separate dedicated hotkey? (A dedicated hotkey is simpler to route but adds Settings UI complexity.)
6. How does live mode interact with the word remapping scratchpad (`isRemappingScratchpadFocused`)? Live mode should probably disable itself when the scratchpad is focused.
7. Should EOU-committed utterances be saved to transcription history? If the user speaks in multiple short utterances without releasing the hotkey, each EOU event produces a separate entry — is that the right behavior?
8. How do we handle the case where the user stops speaking but does not release the hotkey? EOU fires; text is committed; but the recording session is still open. Does the next utterance append to the same history entry?
9. Does `StreamingEouAsrManager` support multilingual input the same way the TDT v3 batch model does?
10. What is the App Store review posture on Accessibility permission? Apple's own apps use it freely, but some reviewers flag it. (Not relevant if distributing direct only.)

---

## Proposed First Spike

**Goal:** Answer the two highest-value unknowns before any production code is written.

**Duration:** 1 day (one engineer)

**What to build:** A standalone Swift command-line tool (not modifying Hex) that:
1. Instantiates `StreamingEouAsrManager` with `.ms320` chunks.
2. Calls `loadModels(modelDir:)` — **first, verify whether it can point at the existing Parakeet TDT v3 model directory, or whether it fails and demands a different model**. Log the exact path it resolves and the size of any download triggered.
3. Captures live microphone audio via `AVAudioEngine` at 16kHz.
4. Pushes 320ms buffers to `process(audioBuffer:)` in a loop.
5. After each `process()` call, immediately calls `finish()` speculatively and logs the return value.
6. Logs `eouDetected` after each chunk.
7. When `setEouCallback` fires, logs the transcript.
8. Also posts a `CGEvent` with `keyboardSetUnicodeString` and verifies whether a TCC prompt fires on macOS 15.

**Success criteria — what the spike must prove:**

| Question | Success signal |
|----------|---------------|
| Does `StreamingEouAsrManager` need a new model download? | Tool runs to first EOU without an unexpected download, OR logs the exact download URL and byte count |
| Does speculative `finish()` return a running partial? | Log shows non-empty strings from `finish()` before EOU fires |
| What is the EOU cadence for natural speech? | Log timestamps of EOU events during a 30-second spoken paragraph — compute mean inter-EOU interval |
| Does Unicode CGEvent injection require TCC? | `keyboardSetUnicodeString` injection reaches a test TextEdit window without a TCC dialog on a freshly-consented macOS 15 machine |
| What is the actual inference latency per chunk? | Log `process()` call duration; confirm it is below 320ms (the chunk period) |

**Output:** A written log of spike findings (5–10 lines) that directly answers each question, shared before v1 implementation begins. If any answer is a blocker (e.g., EOU model is 800MB, or `finish()` always returns empty string), the v1 scope is revised accordingly.
