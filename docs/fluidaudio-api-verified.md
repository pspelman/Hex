# FluidAudio Streaming ASR — Verified API Reference

**Status:** Ground truth. Verified against the exact commit Hex pins. Supersedes the API claims in `docs/live-transcription-plan.md` §1.1.

**Verification date:** 2026-04-24

---

## Resolved version & source paths

- **Pin (from `Hex.xcodeproj/.../Package.resolved`):** `https://github.com/FluidInference/FluidAudio` — branch `main`, revision **`47552dde26f79b880efff2f23ad4dab55aa914ca`**.
- **Most recent commit at that pin:** `feat: add partial callback for real-time ghost text (#230)` — i.e. the per-chunk partial callback the design doc lists as "future API" is **already shipping** at this pin.
- **Local checkout used for verification:** `/tmp/fluidaudio-check` (`git clone` of the FluidInference/FluidAudio repo, checked out at the pinned SHA).
- **Primary file:** `Sources/FluidAudio/ASR/Streaming/StreamingEouAsrManager.swift` (lines 1–506).
- **Supporting files:**
  - `Sources/FluidAudio/ModelNames.swift` — repo identifiers and folder layout.
  - `Sources/FluidAudio/DownloadUtils.swift` — `DownloadUtils.downloadRepo(_:to:)`.
  - `Sources/FluidAudio/Shared/AudioConverter.swift` — confirms `AVAudioPCMBuffer` is auto-resampled to 16 kHz mono Float32.
  - `Sources/FluidAudioCLI/Commands/Parakeet/ParakeetEouCommand.swift` — reference integration in the FluidAudio CLI; shows the exact download + load wiring.

There is also a sibling `StreamingAsrManager` (`Sources/FluidAudio/ASR/Streaming/StreamingAsrManager.swift`) which uses the **TDT v3 0.6B** weights Hex already downloads. That class is *different* from `StreamingEouAsrManager` and is discussed at the end of "Discrepancies" — it is the "no-extra-download" alternative if rollout cost is unacceptable.

---

## Verified API

### 1. Class name

**Verified:** `public actor StreamingEouAsrManager` in module `FluidAudio`.
The doc's name is correct verbatim.

```swift
// StreamingEouAsrManager.swift:158
public actor StreamingEouAsrManager {
    public let chunkSize: StreamingChunkSize
    public var eouDebounceMs: Int
    public private(set) var eouDetected: Bool
    public private(set) var configuration: MLModelConfiguration
    public let debugFeatures: Bool
    // ...
}
```

A second public type `public actor StreamingAsrManager` exists in the same package — same module, different class, different model. Distinct from `StreamingEouAsrManager`. Do not confuse them at import time.

### 2. Initializer signature

**Verified.** The doc's parameter names are correct, but the chunk-size type is a **dedicated `StreamingChunkSize` enum** (not `Duration`/`TimeInterval`/sample count), and there are **two extra parameters** (`configuration` first; `debugFeatures` last).

```swift
// StreamingEouAsrManager.swift:219–230
public init(
    configuration: MLModelConfiguration = MLModelConfiguration(),
    chunkSize: StreamingChunkSize = .ms160,
    eouDebounceMs: Int = 1280,
    debugFeatures: Bool = false
)
```

Where `StreamingChunkSize` is:

```swift
// StreamingEouAsrManager.swift:16–46
public enum StreamingChunkSize: Sendable {
    case ms160   // 160ms latency — default; ~8–9% WER on LibriSpeech test-clean
    case ms320   // 320ms latency — ~5.73% WER, 14× RTFx; **larger 64-mel-frame audio chunks (~630ms)**
    case ms1600  // 1600ms latency — uses 320ms-trained weights internally
}
```

`eouDebounceMs` is a plain `Int` (milliseconds of sustained predicted-silence required before EOU fires). Default 1280 ms. It is also `public var` on the actor, so it can be tuned post-init by `await manager.eouDebounceMs = 800`. The init is **synchronous** (`init`, not `async init`) — but because the type is an actor, callers will see the standard `await` requirement at the use sites, not at construction.

**Important nuance about `.ms320`:** the per-chunk latency is 320 ms, but `chunkSize.chunkSamples == 10080`, i.e. each `process(audioBuffer:)` window is **~630 ms of audio** with 320 ms shift between outputs. The internal sliding-window math handles this; the caller can push smaller buffers (the manager accumulates).

### 3. Model loading

**Verified.** `loadModels(modelDir: URL)` takes a plain `URL` to an **already-downloaded** model directory. **It does not download.** Caller is responsible for fetching the model bundle first (FluidAudio ships `DownloadUtils.downloadRepo` for this).

```swift
// StreamingEouAsrManager.swift:244–268
public func loadModels(modelDir: URL) async throws {
    self.streamingEncoder = try await MLModel.load(
        contentsOf: modelDir.appendingPathComponent("streaming_encoder.mlmodelc"),
        configuration: self.configuration)
    self.decoder = try await MLModel.load(
        contentsOf: modelDir.appendingPathComponent("decoder.mlmodelc"),
        configuration: self.configuration)
    self.joint = try await MLModel.load(
        contentsOf: modelDir.appendingPathComponent("joint_decision.mlmodelc"),
        configuration: self.configuration)
    let vocabUrl = modelDir.appendingPathComponent("vocab.json")
    self.tokenizer = try Tokenizer(vocabPath: vocabUrl)
    // ...
}
```

`modelDir` must contain:

| File / dir                  | Required by                                     |
|-----------------------------|-------------------------------------------------|
| `streaming_encoder.mlmodelc` | `loadModels`                                    |
| `decoder.mlmodelc`           | `loadModels`                                    |
| `joint_decision.mlmodelc`    | `loadModels`                                    |
| `vocab.json`                 | `loadModels` (Tokenizer)                        |
| `tokenizer.model`            | listed in `ModelNames.ParakeetEOU.requiredModels` (downloaded by `downloadRepo`) |
| `parakeet_eou_preprocessor.mlmodelc` | listed in required set, but **not actually loaded** by `StreamingEouAsrManager` (it uses native Swift mel via `NeMoMelSpectrogram`) — pulled down anyway by `downloadRepo` |

The repo identifiers and folder layout that `downloadRepo` produces are:

```swift
// ModelNames.swift:8–9, 22–25, 60–63
case parakeetEou160 = "FluidInference/parakeet-realtime-eou-120m-coreml/160ms"
case parakeetEou320 = "FluidInference/parakeet-realtime-eou-120m-coreml/320ms"
// remotePath: "FluidInference/parakeet-realtime-eou-120m-coreml"
// folderName: "parakeet-eou-streaming/160ms" or "parakeet-eou-streaming/320ms"
```

So if you call `DownloadUtils.downloadRepo(.parakeetEou320, to: appSupport)`, files end up at:
`<appSupport>/parakeet-eou-streaming/320ms/{streaming_encoder,decoder,joint_decision,parakeet_eou_preprocessor}.mlmodelc + vocab.json + tokenizer.model`,
and that exact path is what you pass to `loadModels(modelDir:)`.

**Convenience reference (from FluidAudio's own CLI, `ParakeetEouCommand.swift:166–205`):**

```swift
static func getModelsDirectory() -> URL {
    let asURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("FluidAudio", isDirectory: true)
    return asURL.appendingPathComponent("Models/parakeet-eou-streaming", isDirectory: true)
}
// Then: modelsUrl = getModelsDirectory().appendingPathComponent(chunkSize.modelSubdirectory) // "160ms" or "320ms"
// Download:
let modelsDir = modelsUrl.deletingLastPathComponent().deletingLastPathComponent()
try await DownloadUtils.downloadRepo(.parakeetEou320, to: modelsDir)
```

### 4. `process(audioBuffer:)`

**Verified.** Signature is `public func process(audioBuffer: AVAudioPCMBuffer) async throws -> String`. It is `async`, it `throws`, it accepts **any** `AVAudioPCMBuffer` format (the internal `AudioConverter` resamples to 16 kHz mono Float32 transparently — `AudioConverter.resampleBuffer` uses `AVAudioConverter` for arbitrary rate/channel/format conversion), and **always returns `""`** in the current implementation (line 316: `// Return empty - actual transcription happens in finish()`). Transcript text reaches the caller via the EOU/partial callbacks or `finish()`.

```swift
// StreamingEouAsrManager.swift:297–317
public func process(audioBuffer: AVAudioPCMBuffer) async throws -> String {
    let samples = try audioConverter.resampleBuffer(audioBuffer)   // any format → 16 kHz mono Float32
    self.audioBuffer.append(contentsOf: samples)
    while self.audioBuffer.count >= chunkSamples {
        let chunk = Array(self.audioBuffer.prefix(chunkSamples))
        try await processChunkAndDecode(chunk)
        self.audioBuffer.removeFirst(shiftSamples)
    }
    return ""   // <— intentional; see finish()/callbacks
}
```

There is also an `appendAudio(_:)` variant that accumulates samples without running inference (used for VAD-driven simulated streaming).

### 5. EOU callback

**Verified.** The closure type is named, public, and expects a single `String` (the accumulated transcript up to the EOU point). `eouDetected` exists as a `public private(set) var Bool` you can poll on the actor.

```swift
// StreamingEouAsrManager.swift:148–193
public typealias EouCallback = @Sendable (String) -> Void
public typealias PartialCallback = @Sendable (String) -> Void  // see Q10

public actor StreamingEouAsrManager {
    public private(set) var eouDetected: Bool = false   // pollable
    public func setEouCallback(_ callback: @escaping EouCallback)
    public func setPartialCallback(_ callback: @escaping PartialCallback)
}
```

The callback fires from inside `processChunkAndDecode` (line 467), **on whatever task is doing the await on `process(audioBuffer:)`** — i.e. it runs on the actor's executor, not on a hardcoded queue. Both callbacks are `@Sendable (String) -> Void`. Neither is `async`.

### 6. `finish()`

**Verified.** Signature is `public func finish() async throws -> String`. It pads any partial in-flight audio out to a full chunk, runs one final inference pass, and returns the full accumulated transcript decoded from `accumulatedTokenIds`. **It also clears `accumulatedTokenIds` as a side effect** (line 345). Calling `finish()` mid-stream therefore returns whatever has been decoded so far including the trailing partial — there is no separate "drain without commit" hook.

```swift
// StreamingEouAsrManager.swift:319–348
public func finish() async throws -> String {
    if !audioBuffer.isEmpty {
        let paddingNeeded = chunkSamples - audioBuffer.count
        if paddingNeeded > 0 { audioBuffer.append(contentsOf: Array(repeating: 0.0, count: paddingNeeded)) }
        let chunk = Array(audioBuffer.prefix(chunkSamples))
        try await processChunkAndDecode(chunk)
        audioBuffer.removeAll()
    }
    let transcript = tokenizer?.decode(ids: accumulatedTokenIds) ?? ""
    accumulatedTokenIds.removeAll()  // <-- side effect: token state is wiped on finish
    return transcript
}
```

Practical consequence: if you want a "snapshot" mid-stream, the partial callback (Q10) is the correct mechanism — `finish()` is destructive to running state. To start a fresh utterance after `finish()`, you also need `reset()` (Q7).

### 7. `reset()` / lifecycle

**Verified.** `public func reset() async` (no throws, no return). Wipes audio buffer, debug buffer, accumulated tokens, EOU flags, sample counters, and resets all CoreML loopback state plus the RNN-T decoder hidden state. After `reset()` the manager is ready to consume a new utterance with the **already-loaded models** — you do *not* need to call `loadModels` again.

```swift
// StreamingEouAsrManager.swift:350–360
public func reset() async {
    audioBuffer.removeAll()
    debugFeatureBuffer.removeAll()
    accumulatedTokenIds.removeAll()
    eouDetected = false
    eouFirstDetectedAt = nil
    totalSamplesProcessed = 0
    try? resetStates()       // re-zeros pre_cache, cache_last_channel/time/len
    rnntDecoder?.resetState()
    processedChunks = 0
}
```

Recommended session lifecycle:

```
init → loadModels → (process×N → optional finish/EOU callback) → reset → (process×N …) → reset → …
```

There is also `injectSilence(_ seconds: Double)` (line 362) for testing — appends N×16000 zero samples to the buffer.

### 8. EOU model identity — **separate model from the existing Parakeet TDT v3**

**Verified — and this is the single most consequential finding.** `StreamingEouAsrManager` does **not** reuse the Parakeet TDT v3 weights Hex already downloads. It requires the dedicated **NVIDIA `parakeet_realtime_eou_120m-v1`** model, redistributed by FluidInference at:

```
HuggingFace repo: FluidInference/parakeet-realtime-eou-120m-coreml
Subfolder:        160ms/ or 320ms/ (separate CoreML compilations per chunk size)
On-disk layout:   <root>/parakeet-eou-streaming/{160ms,320ms}/
Required files:   streaming_encoder.mlmodelc, decoder.mlmodelc, joint_decision.mlmodelc,
                  parakeet_eou_preprocessor.mlmodelc, vocab.json, tokenizer.model
```

(Source: `ModelNames.swift:8–67`, `ModelNames.ParakeetEOU` at `ModelNames.swift:152–173`, `ParakeetEouCommand.swift:166–205`.)

This is a **120M-parameter** model. The existing batch model Hex downloads is the **600M-parameter** `parakeet-tdt-0.6b-v3-coreml` — physically different weights, different architecture (loopback streaming encoder vs full encoder), different vocab file (`vocab.json` vs `parakeet_vocab.json`).

**Implications for Hex's `ModelDownloadFeature` and `Resources/Data/models.json`:**

- A new entry must be added pointing at the EOU repo. It cannot reuse the existing Parakeet TDT v3 entry.
- Each chunk size (`160ms`, `320ms`) is a separately exported CoreML bundle. If we ship a chunk-size selector, we must download the bundle that matches the user's selection (or pre-download both).
- Disk footprint estimate: a 120M-param Float32 CoreML bundle is on the order of **~480 MB**, but FluidInference ships compiled `.mlmodelc` (often quantized) so real footprint is closer to **~200–400 MB per chunk-size variant** depending on precision. We will only know exactly by running the download once.
- `ParakeetClient` in Hex currently uses `AsrModels.downloadAndLoad(version:)` which does **not** know about the EOU repo. The streaming path needs to call `DownloadUtils.downloadRepo(.parakeetEou320, to:)` directly, then construct `StreamingEouAsrManager` and call `loadModels(modelDir:)` on the resulting subfolder.

**There is a no-extra-download alternative — see "Discrepancies" §A below.**

### 9. Concurrency / Sendable

**Verified.** `public actor StreamingEouAsrManager` — it is an actor. All public methods are isolated to the actor's executor. Calling `process(audioBuffer:)` from a background queue requires `await` and is automatically serialized by the actor.

`StreamingChunkSize: Sendable` (line 16). `EouCallback` and `PartialCallback` are `@Sendable (String) -> Void` (lines 150, 154). `MLModelConfiguration` and `AVAudioPCMBuffer` are not `Sendable` per Apple's annotation, so capture-list rules apply when crossing actor boundaries — Hex's existing `RecordingClient`/`SuperFastCaptureController` already deal with this for the batch path.

**Practical consequence:** the design doc's plan to call `process()` from the audio capture callback on a background queue is correct; it just requires a `Task { await manager.process(audioBuffer: buf) }` hop. The actor will serialize.

### 10. Per-chunk partial hypothesis

**Verified — and this is the second highest-impact finding, in the *positive* direction.** The pinned commit (`#230 — feat: add partial callback for real-time ghost text`) **already exposes a per-chunk partial transcript callback**. The design doc treats this as future API; it is shipping today.

```swift
// StreamingEouAsrManager.swift:152–154, 240–242
public typealias PartialCallback = @Sendable (String) -> Void
public func setPartialCallback(_ callback: @escaping PartialCallback)
```

It fires inside `processChunkAndDecode`, **only when the chunk produced new tokens** (line 437: `!decodeResult.tokenIds.isEmpty`), with the full accumulated transcript to date:

```swift
// StreamingEouAsrManager.swift:436–440
if let callback = partialCallback, let tokenizer = tokenizer, !decodeResult.tokenIds.isEmpty {
    let partial = tokenizer.decode(ids: accumulatedTokenIds)
    callback(partial)
}
```

So the v1 design's "EOU-only, no per-chunk partials" assumption is overly conservative. **We can ship word-by-word ghost text from day one** by wiring `setPartialCallback` into `StreamingTranscriptionClient` and emitting `.provisional` events on every fire, with `.finalize` reserved for the EOU callback.

There is **no `currentHypothesis` property** to poll — partials only arrive via the callback. There is also no public token/timestamp-level partial; the callback gives a `String` only. (Token-level data exists internally as `accumulatedTokenIds` + `RnntDecoder` outputs, but is not exposed.)

---

## Compiling sample integration

```swift
import AVFoundation
import FluidAudio
import Foundation

@main
struct LiveTranscribeProbe {
    static func main() async throws {
        // 1. Resolve a writable directory and download the 320ms EOU model.
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let modelsRoot = appSupport.appendingPathComponent("FluidAudio/Models", isDirectory: true)
        try await DownloadUtils.downloadRepo(.parakeetEou320, to: modelsRoot)
        let modelDir = modelsRoot.appendingPathComponent("parakeet-eou-streaming/320ms",
                                                         isDirectory: true)

        // 2. Construct the streaming manager and wire callbacks.
        let manager = StreamingEouAsrManager(
            configuration: MLModelConfiguration(),
            chunkSize: .ms320,
            eouDebounceMs: 800,
            debugFeatures: false)
        await manager.setPartialCallback { partial in print("PARTIAL: \(partial)") }
        await manager.setEouCallback { final in print("EOU: \(final)") }
        try await manager.loadModels(modelDir: modelDir)

        // 3. Push a single AVAudioPCMBuffer chunk (any format — auto-resampled to 16 kHz mono Float32).
        //    For demo purposes we synthesize 1 second of silence in the engine's input format.
        let engine = AVAudioEngine()
        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        let frameCount = AVAudioFrameCount(inputFormat.sampleRate)  // 1 second
        let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        _ = try await manager.process(audioBuffer: buffer)  // returns "" by contract

        // 4. Drain any in-flight partial and reset for next utterance.
        let trailing = try await manager.finish()
        if !trailing.isEmpty { print("TRAILING: \(trailing)") }
        await manager.reset()
    }
}
```

This compiles against `import FluidAudio` at the pinned revision. (`DownloadUtils.downloadRepo` is `public static`; `Repo.parakeetEou320` is public; all `StreamingEouAsrManager` methods used are public.)

---

## Discrepancies vs. the design doc

The design doc is in `/Users/pspelman/coding/Hex/docs/live-transcription-plan.md`. Each item below cites the exact location to edit.

### A. (Highest impact) "No per-chunk partial hypothesis" is wrong — partials are shipping

- **Where it's wrong:** §1.1 claims "There is **no per-chunk partial hypothesis string exposed in the current API**. This is the most important constraint for v1 design." Repeated in §3 ("This section assumes a future FluidAudio API update exposes a per-chunk partial hypothesis") and §5.2 ("On an EOU-only basis (v1), the user sees nothing during speech and then sees the full utterance appear at EOU") and Open Question #2.
- **Reality:** `setPartialCallback(_:)` (Q10 above) is public on the pinned revision and fires on every chunk that produces new tokens.
- **What to change:** v1 scope can include word-by-word ghost text. The two-track model (`.provisional` from partials, `.finalize` from EOU) the doc reserves for v2 in §6.1 should be the v1 shape. Open Question #2 is answered: yes.

### B. Initializer signature is missing two parameters

- **Where it's wrong:** §1.1 sample shows `StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: 1280)`.
- **Reality:** the real init also takes `configuration: MLModelConfiguration = .init()` first and `debugFeatures: Bool = false` last. Defaults match, but if Hex wants to control compute units (CPU vs ANE — important for power use on battery), it must pass a `MLModelConfiguration` explicitly.
- **What to change:** update the §1.1 snippet; add `MLModelConfiguration` plumbing to `StreamingTranscriptionClient`.

### C. EOU model identity — confirmed separate, design doc was right to flag this

- **Where the doc is correct but uncertain:** §1.1 ("**The EOU model is a separate model bundle from the Parakeet TDT v3** … must be managed by `ModelDownloadFeature`. … Estimate: ~300–400MB additional model size") and Open Question #1.
- **Reality:** Confirmed separate. Repo is `FluidInference/parakeet-realtime-eou-120m-coreml`. 120M params. Each of the 160ms / 320ms chunk sizes is its own subfolder in the repo, downloaded independently. The 1600ms variant **reuses the 320ms weights** internally (see `ParakeetEouCommand.swift:184–185`), so we only need to download two bundles, not three, even if we expose all three chunk sizes.
- **What to change:** Open Question #1 is answered. Add a `models.json` entry for `parakeet-eou-streaming-320ms` (+ `-160ms` if both chunk sizes are user-facing). The download code must call `DownloadUtils.downloadRepo(.parakeetEou320, to:)` rather than `AsrModels.downloadAndLoad(...)`.

### D. (Minor) "TDT-CTC batch variant" is a misnomer

- **Where:** §1.1 footnote says EOU is "a Parakeet EOU variant, not the TDT-CTC batch variant."
- **Reality:** the existing batch model is **Parakeet TDT v3** (RNN-T / TDT, not CTC). The text should say "TDT batch variant" or just "the existing v3 batch weights."

### E. (Minor) `process()` chunk size

- **Where:** §1.1 says "320ms chunks" and §5.2 budgets a 320ms chunk fill time.
- **Reality:** with `.ms320` the **shift between outputs** is 320 ms, but each `process()` chunk is `chunkSamples = 10080 = 630 ms` of audio. The manager handles its own buffering, so the caller can hand it any size; the apparent latency-per-output is still 320 ms. This is purely a naming-clarity nit, not a behavior change.
- **What to change:** §5.2's latency table is still right end-to-end (320 ms shift → 320 ms perceived latency). Just clarify that "320 ms chunk" refers to shift, not buffer size.

### F. (Alternative — not strictly a discrepancy) `StreamingAsrManager` reuses TDT v3

- **Context:** The doc only considers `StreamingEouAsrManager`. The pinned FluidAudio also exposes `StreamingAsrManager` (`Sources/FluidAudio/ASR/Streaming/StreamingAsrManager.swift`), which:
  - Takes a `StreamingAsrConfig` (sliding-window + confidence-threshold parameters, default 11 s chunks / 2 s context — much higher latency than EOU mode).
  - **Reuses the existing `AsrModels` (TDT v3) Hex already downloads** (line 69 / 465: `try await AsrModels.downloadAndLoad()`).
  - Emits `AsyncStream<StreamingTranscriptionUpdate>` with two-tier `confirmedTranscript` / `volatileTranscript` state — a closer match to the doc's "Apple Speech-style" model.
- **Tradeoff:** zero extra download, but **multi-second latency between updates** (the windows are 10–15 s by design). EOU mode has hundreds-of-ms latency but requires the new ~200–400 MB bundle.
- **What to do:** keep `StreamingEouAsrManager` as the v1 target (the doc's choice is right for the latency budget), but document `StreamingAsrManager` as the fallback path if EOU model download is judged unacceptable for rollout. Mention it in §5.4 staged rollout.

---

## Blockers

None of the API claims in the design doc are blocking — but the rollout assumptions are. Surfacing them explicitly:

1. **Disk + bandwidth for the 120M EOU model.** A new 200–400 MB download per user. The release flow already supports model downloads via `ModelDownloadFeature`, but `models.json` must gain entries and the UI must surface "Live mode requires a one-time download." Without this, enabling live mode in Settings will hang on first invocation. **Action:** before any Hex code is written, run `DownloadUtils.downloadRepo(.parakeetEou320, to:)` once on a clean machine and record actual byte count for the changeset note.
2. **`process()`/`finish()` token state is stateful and mid-stream `finish()` is destructive.** §3.2's "VAD silence gate (Approach B)" plan to use `finish()` between EOUs would clobber `accumulatedTokenIds`. The correct primitive is the EOU callback (which does **not** reset state — only `reset()` does). Adjust the v1 reconciliation engine accordingly: `.finalize` is emitted from the EOU callback; `reset()` is called between utterances; `finish()` is reserved for end-of-session.
3. **No public token-/timestamp-level partial.** The partial callback returns a `String` only. The §6.1 typed `Hypothesis` struct's `tokens: [Token]` and `stability: Double` fields cannot be populated from FluidAudio data alone for v1 — they would have to be heuristic (whitespace tokenization + LCP-stability count over consecutive partials). This does not block v1; it just means the `tokens` and `stability` fields stay nil/heuristic until a future FluidAudio surface area expands.
4. **Compute-unit selection is at init time only.** `MLModelConfiguration.computeUnits` is captured in the actor's `configuration` property at init and cannot be changed without re-loading the model. If we want a user-facing "low-power CPU only" toggle, it requires re-instantiating the manager. Not a v1 blocker, but worth noting for the Settings story.
5. **Actor reentrancy and back-pressure.** `process(audioBuffer:)` can take ~25–30 ms per chunk; if the audio tap fires faster than that, awaits will queue on the actor. The §6.2 `ReconciliationEngine` bounded queue is upstream of the FluidAudio actor and does **not** prevent FluidAudio's internal queue from growing. If we drop chunks under load, we must drop them at the capture/recording side **before** the `Task { await manager.process(...) }` hop, not inside the engine.
