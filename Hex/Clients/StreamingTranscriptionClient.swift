import AVFoundation
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

#if canImport(FluidAudio)
import CoreML
import FluidAudio

// MARK: - Public client interface

/// TCA dependency client for streaming ASR via FluidAudio's `StreamingEouAsrManager`.
///
/// Callers start a session, push audio buffers from the capture tap, and consume
/// an `AsyncStream<TranscriptionEvent>` that emits `.provisional` on every partial
/// callback and `.finalize` on every EOU callback.  The stream terminates when
/// `finishSession()` or `cancelSession()` is called.
@DependencyClient
struct StreamingTranscriptionClient {
  /// Returns true if the EOU model required for `chunkSize` is already on disk.
  var isModelAvailable: @Sendable (_ chunkSize: LiveTranscriptionChunkSize) async -> Bool = { _ in false }

  /// Download (if needed) and load the EOU model for the given chunk size.
  /// Reports byte-level progress via the Progress callback. Throws on download or load failure.
  var ensureLoaded: @Sendable (
    _ chunkSize: LiveTranscriptionChunkSize,
    _ progress: @escaping @Sendable (Progress) -> Void
  ) async throws -> Void = { _, _ in }

  /// Begin a streaming session. Audio buffers must be pushed via `pushAudioBuffer`.
  /// Returns an `AsyncStream<TranscriptionEvent>` that emits `.provisional` on every partial
  /// callback and `.finalize` on every EOU callback.  Stream terminates on `finishSession`
  /// or `cancelSession`.
  var startSession: @Sendable (
    _ chunkSize: LiveTranscriptionChunkSize,
    _ eouDebounceMs: Int
  ) async throws -> AsyncStream<TranscriptionEvent> = { _, _ in AsyncStream { _ in } }

  /// Push an audio buffer (any format — auto-resampled by FluidAudio to 16 kHz mono Float32).
  /// No-op if no session is active.
  var pushAudioBuffer: @Sendable (AVAudioPCMBuffer) async -> Void = { _ in }

  /// Drain any in-flight partial as a final `.finalize` event, then close the stream.
  /// Returns the final transcript (also emitted in the stream as `.finalize`).
  var finishSession: @Sendable () async throws -> String = { "" }

  /// Cancel without draining (e.g. user pressed ESC). Closes the stream silently.
  var cancelSession: @Sendable () async -> Void = {}
}

// MARK: - DependencyKey + DependencyValues

extension StreamingTranscriptionClient: DependencyKey {
  static var liveValue: Self {
    let live = StreamingTranscriptionClientLive()
    return Self(
      isModelAvailable: { await live.isModelAvailable(chunkSize: $0) },
      ensureLoaded: { try await live.ensureLoaded(chunkSize: $0, progress: $1) },
      startSession: { try await live.startSession(chunkSize: $0, eouDebounceMs: $1) },
      pushAudioBuffer: { await live.pushAudioBuffer($0) },
      finishSession: { try await live.finishSession() },
      cancelSession: { await live.cancelSession() }
    )
  }
}

extension DependencyValues {
  var streamingTranscription: StreamingTranscriptionClient {
    get { self[StreamingTranscriptionClient.self] }
    set { self[StreamingTranscriptionClient.self] = newValue }
  }
}

// MARK: - Live implementation

/// Actor-isolated implementation of `StreamingTranscriptionClient`.
///
/// Lifecycle per session:
///   `startSession` → construct + `loadModels` → push buffers → `finishSession` or `cancelSession`
///
/// Between sessions: call `startSession` again.  A fresh `StreamingEouAsrManager` is constructed
/// each time because model files differ per chunk size.  Reusing a loaded manager across
/// sessions of the same chunk size is a v1.1 optimization — safe to revisit once the API surface
/// is stable.
actor StreamingTranscriptionClientLive {
  private let logger = HexLog.streamingASR

  // Active session state.  All mutated only on the actor's executor.
  private var manager: StreamingEouAsrManager?
  private var loadedChunkSize: LiveTranscriptionChunkSize?
  private var streamContinuation: AsyncStream<TranscriptionEvent>.Continuation?
  private var revisionCounter: UInt64 = 0
  private var lastEmittedPartial: String = ""

  // MARK: - isModelAvailable

  func isModelAvailable(chunkSize: LiveTranscriptionChunkSize) async -> Bool {
    guard let modelDir = eouModelDir(for: chunkSize) else { return false }
    return hasRequiredModelFiles(at: modelDir)
  }

  // MARK: - ensureLoaded

  func ensureLoaded(
    chunkSize: LiveTranscriptionChunkSize,
    progress: @escaping @Sendable (Progress) -> Void
  ) async throws {
    let modelsRoot = try eouModelsRoot()
    let modelDir = modelsRoot.appendingPathComponent("parakeet-eou-streaming/\(chunkSize.subfolderName)", isDirectory: true)

    let p = Progress(totalUnitCount: 100)
    p.completedUnitCount = 1
    progress(p)

    if hasRequiredModelFiles(at: modelDir) {
      logger.notice("EOU model already present chunkSize=\(chunkSize.rawValue, privacy: .public)")
      p.completedUnitCount = 100
      progress(p)
      return
    }

    logger.notice("Downloading EOU model chunkSize=\(chunkSize.rawValue, privacy: .public) to=\(modelsRoot.path, privacy: .private)")

    // Poll directory size while the download runs.
    let pollTask = Task<Void, Never> {
      let targetBytes: Double = 300 * 1024 * 1024  // ~300MB estimate; actual varies per FluidInference build
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 250_000_000)
        if let size = directorySize(modelsRoot) {
          let frac = max(0.0, min(1.0, Double(size) / targetBytes))
          p.completedUnitCount = Int64(5 + frac * 90)
          progress(p)
        }
      }
    }
    defer { pollTask.cancel() }

    try await DownloadUtils.downloadRepo(chunkSize.repo, to: modelsRoot)

    pollTask.cancel()

    guard hasRequiredModelFiles(at: modelDir) else {
      throw NSError(
        domain: "StreamingTranscriptionClient",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "EOU model download completed but expected files are missing at \(modelDir.path)"]
      )
    }

    p.completedUnitCount = 100
    progress(p)
    logger.notice("EOU model download finished chunkSize=\(chunkSize.rawValue, privacy: .public)")
  }

  // MARK: - startSession

  func startSession(
    chunkSize: LiveTranscriptionChunkSize,
    eouDebounceMs: Int
  ) async throws -> AsyncStream<TranscriptionEvent> {
    // Tear down any existing session cleanly before starting a new one.
    if manager != nil {
      logger.notice("startSession called with an active session — cancelling previous session")
      await cancelSession()
    }

    let modelsRoot = try eouModelsRoot()
    let modelDir = modelsRoot.appendingPathComponent("parakeet-eou-streaming/\(chunkSize.subfolderName)", isDirectory: true)

    guard hasRequiredModelFiles(at: modelDir) else {
      throw NSError(
        domain: "StreamingTranscriptionClient",
        code: -2,
        userInfo: [NSLocalizedDescriptionKey: "EOU model not available for chunkSize=\(chunkSize.rawValue). Call ensureLoaded first."]
      )
    }

    logger.notice("Starting streaming ASR session chunkSize=\(chunkSize.rawValue, privacy: .public) eouDebounceMs=\(eouDebounceMs)")

    let newManager = StreamingEouAsrManager(
      configuration: MLModelConfiguration(),
      chunkSize: chunkSize.fluidAudioChunkSize,
      eouDebounceMs: eouDebounceMs,
      debugFeatures: false
    )

    // Wire callbacks before loadModels so no events are dropped if the first
    // chunk arrives extremely quickly after load completes.
    await newManager.setPartialCallback { [weak self] partial in
      Task { await self?.emitPartial(partial) }
    }
    await newManager.setEouCallback { [weak self] final in
      Task { await self?.emitFinalize(final) }
    }

    try await newManager.loadModels(modelDir: modelDir)

    let (stream, continuation) = AsyncStream<TranscriptionEvent>.makeStream()

    self.manager = newManager
    self.loadedChunkSize = chunkSize
    self.streamContinuation = continuation
    self.revisionCounter = 0
    self.lastEmittedPartial = ""

    logger.notice("Streaming ASR session started chunkSize=\(chunkSize.rawValue, privacy: .public)")
    return stream
  }

  // MARK: - pushAudioBuffer

  func pushAudioBuffer(_ buffer: AVAudioPCMBuffer) async {
    guard let m = manager else { return }
    do {
      _ = try await m.process(audioBuffer: buffer)
    } catch {
      // Log and route as a synthetic finalize so the caller gets partial state,
      // then terminate the stream.  A dead manager cannot recover.
      logger.error("StreamingEouAsrManager.process failed — terminating session: \(error.localizedDescription, privacy: .public)")
      emitFinalize(lastEmittedPartial)
      terminateStream()
      manager = nil
      loadedChunkSize = nil
    }
  }

  // MARK: - finishSession

  func finishSession() async throws -> String {
    guard let m = manager else { return "" }

    // Capture and clear state before the await so re-entrant calls see nil.
    let continuation = streamContinuation
    manager = nil
    loadedChunkSize = nil
    streamContinuation = nil

    logger.notice("Finishing streaming ASR session")

    let finalText = try await m.finish()

    // Emit trailing text as a finalize event if non-empty.
    if !finalText.isEmpty {
      revisionCounter &+= 1
      lastEmittedPartial = ""
      continuation?.yield(.finalize(CommittedText(revisionId: revisionCounter, text: finalText)))
    }

    continuation?.finish()

    // reset() wipes accumulatedTokenIds so a recycled manager is clean;
    // we already threw away the reference above, so this is belt-and-suspenders.
    await m.reset()

    logger.notice("Streaming ASR session finished finalText.count=\(finalText.count)")
    return finalText
  }

  // MARK: - cancelSession

  func cancelSession() async {
    guard manager != nil else { return }

    let continuation = streamContinuation
    manager = nil
    loadedChunkSize = nil
    streamContinuation = nil
    lastEmittedPartial = ""

    logger.notice("Cancelling streaming ASR session (no finalize emitted)")
    // Intentionally NOT calling `m.reset()`. When cancelSession is invoked because a
    // new session is being started (`startSession` -> auto-cleanup path), the previous
    // session's buffer drain task may still have an in-flight `m.process(buffer)`
    // suspended at FluidAudio's internal `await processChunkAndDecode` point. Calling
    // `m.reset()` here clears `m.audioBuffer` while that suspended `process()` resumes
    // into a `removeFirst(shiftSamples)` on an empty buffer — Swift precondition crash
    // (`RangeReplaceableCollection.swift:596: Can't remove more items...`).
    //
    // Since we drop the only strong reference to `m` above, it deinits naturally once
    // its in-flight work completes. No reset needed.
    continuation?.finish()
  }

  // MARK: - Private event helpers

  private func emitPartial(_ text: String) {
    // Skip if unchanged — FluidAudio only calls the partial callback when new tokens
    // are produced, but defensive de-dup is cheap insurance against any future change.
    guard let cont = streamContinuation, text != lastEmittedPartial else { return }
    revisionCounter &+= 1
    lastEmittedPartial = text
    cont.yield(.provisional(Hypothesis(revisionId: revisionCounter, text: text)))
    logger.debug("Partial emit revisionId=\(self.revisionCounter) text.count=\(text.count)")
  }

  private func emitFinalize(_ text: String) {
    guard let cont = streamContinuation else { return }
    revisionCounter &+= 1
    lastEmittedPartial = ""
    cont.yield(.finalize(CommittedText(revisionId: revisionCounter, text: text)))
    logger.debug("EOU finalize revisionId=\(self.revisionCounter) text.count=\(text.count)")
  }

  /// Close the stream without emitting a finalize event.  Used on error paths.
  private func terminateStream() {
    streamContinuation?.finish()
    streamContinuation = nil
  }

  // MARK: - Private path helpers

  /// Canonical Application Support root for the FluidAudio EOU models.
  ///
  /// Mirror of the path convention in `ParakeetEouCommand.getModelsDirectory()`:
  ///   `<appSupport>/FluidAudio/Models`
  /// `DownloadUtils.downloadRepo(.parakeetEouXXX, to:)` writes into
  ///   `<modelsRoot>/parakeet-eou-streaming/{160ms,320ms}/`
  private func eouModelsRoot() throws -> URL {
    let fm = FileManager.default
    let appSupport = try fm.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let root = appSupport.appendingPathComponent("FluidAudio/Models", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func eouModelDir(for chunkSize: LiveTranscriptionChunkSize) -> URL? {
    guard let root = try? eouModelsRoot() else { return nil }
    return root.appendingPathComponent("parakeet-eou-streaming/\(chunkSize.subfolderName)", isDirectory: true)
  }

  private func hasRequiredModelFiles(at dir: URL) -> Bool {
    let fm = FileManager.default
    guard fm.fileExists(atPath: dir.path) else { return false }
    let required = [
      "streaming_encoder.mlmodelc",
      "decoder.mlmodelc",
      "joint_decision.mlmodelc",
      "vocab.json",
    ]
    return required.allSatisfy { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
  }

  private func directorySize(_ dir: URL) -> UInt64? {
    let fm = FileManager.default
    guard let en = fm.enumerator(
      at: dir,
      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
      options: .skipsHiddenFiles
    ) else { return nil }
    var total: UInt64 = 0
    for case let url as URL in en {
      if let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
        vals.isRegularFile == true
      {
        total &+= UInt64(vals.fileSize ?? 0)
      }
    }
    return total
  }
}

// MARK: - LiveTranscriptionChunkSize → FluidAudio mapping

private extension LiveTranscriptionChunkSize {
  /// Maps Hex's chunk-size enum to the FluidAudio `StreamingChunkSize` enum.
  var fluidAudioChunkSize: StreamingChunkSize {
    switch self {
    case .ms160: return .ms160
    case .ms320: return .ms320
    case .ms1600: return .ms1600
    }
  }

  /// Subfolder name produced by `DownloadUtils.downloadRepo` for this chunk size.
  ///
  /// `ms1600` reuses the `320ms` model bundle (same weights, different streaming config) —
  /// FluidAudio's own CLI does the same redirect (`ParakeetEouCommand.swift:184`).
  var subfolderName: String {
    switch self {
    case .ms160: return "160ms"
    case .ms320, .ms1600: return "320ms"
    }
  }

  /// FluidAudio `Repo` identifier used to download the EOU model for this chunk size.
  /// `ms1600` reuses the 320ms repo — see `subfolderName` for context.
  var repo: Repo {
    switch self {
    case .ms160: return .parakeetEou160
    case .ms320, .ms1600: return .parakeetEou320
    }
  }
}

// MARK: - #else shim (FluidAudio not linked)

#else

struct StreamingTranscriptionClient {
  var isModelAvailable: @Sendable (_ chunkSize: LiveTranscriptionChunkSize) async -> Bool = { _ in false }
  var ensureLoaded: @Sendable (
    _ chunkSize: LiveTranscriptionChunkSize,
    _ progress: @escaping @Sendable (Progress) -> Void
  ) async throws -> Void = { _, _ in
    throw NSError(
      domain: "StreamingTranscriptionClient",
      code: -99,
      userInfo: [NSLocalizedDescriptionKey: "FluidAudio not linked. Add Swift Package: https://github.com/FluidInference/FluidAudio.git and link FluidAudio to the Hex target."]
    )
  }
  var startSession: @Sendable (
    _ chunkSize: LiveTranscriptionChunkSize,
    _ eouDebounceMs: Int
  ) async throws -> AsyncStream<TranscriptionEvent> = { _, _ in
    throw NSError(
      domain: "StreamingTranscriptionClient",
      code: -99,
      userInfo: [NSLocalizedDescriptionKey: "FluidAudio not linked."]
    )
  }
  var pushAudioBuffer: @Sendable (AVAudioPCMBuffer) async -> Void = { _ in }
  var finishSession: @Sendable () async throws -> String = { "" }
  var cancelSession: @Sendable () async -> Void = {}
}

extension StreamingTranscriptionClient: DependencyKey {
  static var liveValue: Self { Self() }
}

extension DependencyValues {
  var streamingTranscription: StreamingTranscriptionClient {
    get { self[StreamingTranscriptionClient.self] }
    set { self[StreamingTranscriptionClient.self] = newValue }
  }
}

#endif
