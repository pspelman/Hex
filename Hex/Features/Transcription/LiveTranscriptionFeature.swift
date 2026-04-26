//
//  LiveTranscriptionFeature.swift
//  Hex
//
//  TCA reducer that orchestrates live (streaming) transcription end-to-end.
//
//  Pipeline:
//    HotKey → startLiveSession
//           → RecordingClient.startLiveCapture (per-buffer tap)
//           → StreamingTranscriptionClient.pushAudioBuffer
//           → AsyncStream<TranscriptionEvent>
//           → ReconciliationEngine.ingest → [InjectionCommand]
//           → TextInjectionClient
//           → focused text field
//
//  On hotkey release: stopLiveSession drains the trailing partial via
//  StreamingTranscriptionClient.finishSession, then the stream's `for await` loop
//  exits naturally and emits .streamFinished.
//

import AppKit
import AVFoundation
import ComposableArchitecture
import Foundation
import HexCore

private let liveLogger = HexLog.streamingASR

@Reducer
struct LiveTranscriptionFeature {
  @ObservableState
  struct State {
    /// True while an active live session is open.
    var isLive: Bool = false
    /// True when the EOU model bundle is present on disk.
    var isModelReady: Bool = false
    /// True while the EOU model is downloading.
    var isDownloading: Bool = false
    /// Download progress 0..1.
    var downloadProgress: Double = 0
    /// Last error message surfaced to UI; cleared on next session start.
    var lastError: String?
    /// Bundle ID of the app that was frontmost when the session started.
    var sourceAppBundleID: String?
    /// Localized name of that app.
    var sourceAppName: String?
    /// When the current live session started.
    var liveStartedAt: Date?
    /// Tracks whether the active live session was entered via liveDoubleTap (locked mode).
    /// Task 5.1 will bind this to the InvisibleWindow indicator; not yet used in the UI.
    var isLiveLocked: Bool = false

    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
  }

  enum Action {
    /// Sent by the view's `.task` modifier — kicks off background effects.
    case task

    // MARK: - Hotkey routing

    /// The configured hotkey was pressed (gated on liveTranscriptionEnabled).
    case hotKeyPressed
    /// The configured hotkey was released.
    case hotKeyReleased
    /// User pressed ESC or another cancellation path.
    case cancel
    /// Sub-threshold tap — silently close any session that already started.
    case discard

    // Dispatcher-routed live slot outcomes (wired in Task 3.3 via AppFeature hub)
    case dispatcherFired(slot: HotkeyDispatcher.Slot, action: HotkeyDispatcher.SlotAction)

    // MARK: - Session lifecycle

    /// Begin a live streaming session.
    case startLiveSession
    /// User released the hotkey — drain trailing partial and finish gracefully.
    case stopLiveSession
    /// Abort immediately (focus changed, error, etc.).
    case abortSession(AbortReason)

    // MARK: - Model availability

    /// Probe whether the EOU model is available on disk.
    case checkModelReady
    /// Result of the availability probe.
    case modelReadyEvaluated(Bool)
    /// Initiate EOU model download.
    case downloadModel
    /// Incremental download progress.
    case modelDownloadProgress(Double)
    /// Download finished with success or failure.
    case modelDownloadFinished(Result<Void, EquatableError>)

    // MARK: - Stream plumbing (internal)

    /// A TranscriptionEvent arrived from the ASR stream.
    case streamEvent(TranscriptionEvent)
    /// The ASR stream closed normally (after finishSession drained it).
    case streamFinished
    /// The ASR stream terminated with an error.
    case streamError(EquatableError)
  }

  /// Wraps an arbitrary Error so Action stays Equatable.
  struct EquatableError: Error, Equatable {
    let underlying: String
    init(_ error: Error) { underlying = error.localizedDescription }
    init(_ message: String) { underlying = message }
  }

  enum CancelID {
    case liveSession
  }

  @Dependency(\.recording) var recording
  @Dependency(\.streamingTranscription) var streamingTranscription
  @Dependency(\.textInjection) var textInjection
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.sleepManagement) var sleepManagement
  @Dependency(\.date.now) var now

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {

      // MARK: - Lifecycle / Setup

      case .task:
        return .merge(
          startHotKeyMonitoringEffect(),
          .send(.checkModelReady)
        )

      // MARK: - HotKey Flow

      case .hotKeyPressed:
        guard !state.isLive else { return .none }
        guard !state.isRemappingScratchpadFocused else { return .none }
        guard state.hexSettings.liveTranscriptionEnabled else { return .none }
        guard state.isModelReady else {
          liveLogger.notice("Live hotkey pressed but EOU model not ready — initiating download")
          state.lastError = "Live transcription model is downloading…"
          return .send(.downloadModel)
        }
        // Claim isLive synchronously here, not in `.startLiveSession`. Without this,
        // a fast release races: hotKeyReleased's reducer is processed before
        // startLiveSession is, sees isLive==false, and bails — leaving an unkillable
        // session that gets fully set up by the still-running effect.
        state.isLive = true
        return .send(.startLiveSession)

      case .hotKeyReleased:
        guard state.isLive else { return .none }
        return .send(.stopLiveSession)

      // MARK: - Session Lifecycle

      case .startLiveSession:
        state.isLive = true
        state.lastError = nil
        state.liveStartedAt = now
        state.sourceAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        state.sourceAppName = NSWorkspace.shared.frontmostApplication?.localizedName

        let chunkSize = state.hexSettings.liveTranscriptionChunkSize
        let preventSleep = state.hexSettings.preventSystemSleep
        let appName = state.sourceAppName ?? "unknown"

        liveLogger.notice(
          "Live session starting chunkSize=\(chunkSize.rawValue, privacy: .public) app=\(appName, privacy: .public)"
        )

        return .run { [streamingTranscription, textInjection, recording, sleepManagement, soundEffect] send in
          if preventSleep {
            await sleepManagement.preventSleep(reason: "Hex Live Transcription")
          }
          soundEffect.play(.startRecording)

          // --- 1. Open the injection session via the engine ---
          let engine = ReconciliationEngine()
          let beginCommands = await engine.startSession()
          await applyCommands(beginCommands, via: textInjection)

          // --- 2. Start the streaming ASR session ---
          let stream: AsyncStream<TranscriptionEvent>
          do {
            stream = try await streamingTranscription.startSession(chunkSize, 1280)
          } catch {
            await send(.streamError(EquatableError(error)))
            return
          }

          // --- 3. Start the audio capture tap ---
          //
          // Buffers must be fed to FluidAudio's StreamingEouAsrManager strictly serially.
          // Its `process(audioBuffer:)` is an actor method that awaits an inner
          // `processChunkAndDecode`, which releases the actor lock; if a second `process()`
          // call interleaves there, both end up calling `audioBuffer.removeFirst(shiftSamples)`
          // back-to-back and the second pops past the buffer's end (Swift precondition failure
          // in RangeReplaceableCollection). We funnel the capture callback through an
          // AsyncStream and drain it from a single task to enforce that invariant.
          let (bufferStream, bufferContinuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .unbounded
          )

          do {
            try await recording.startLiveCapture { buffer in
              bufferContinuation.yield(buffer)
            }
          } catch {
            bufferContinuation.finish()
            await send(.streamError(EquatableError(error)))
            return
          }

          let bufferDrainTask = Task { [streamingTranscription] in
            for await buffer in bufferStream {
              await streamingTranscription.pushAudioBuffer(buffer)
            }
          }

          // --- 4. Drain the event stream through the engine into the injector ---
          for await event in stream {
            let commands = await engine.ingest(event)
            await applyCommands(commands, via: textInjection)
            await send(.streamEvent(event))
          }

          // --- 5. Stream closed — stop accepting buffers and finalize ---
          bufferContinuation.finish()
          _ = await bufferDrainTask.value
          let endCommands = await engine.endSession()
          await applyCommands(endCommands, via: textInjection)
          await send(.streamFinished)
        }
        .cancellable(id: CancelID.liveSession, cancelInFlight: true)

      case .stopLiveSession:
        // Mark session over immediately so UI updates; the cancellable stays alive
        // until finishSession drains the last partial through the stream, which exits
        // the `for await` loop and emits .streamFinished.
        state.isLive = false
        state.isLiveLocked = false
        state.liveStartedAt = nil
        state.sourceAppBundleID = nil
        state.sourceAppName = nil

        liveLogger.notice("Live session stop requested — draining trailing partial")

        return .run { [streamingTranscription, recording, sleepManagement, soundEffect] _ in
          await sleepManagement.allowSleep()
          await recording.stopLiveCapture()
          // finishSession pads + runs final inference, emits a .finalize into the stream,
          // then calls continuation.finish() — the `for await` loop in startLiveSession exits.
          _ = try? await streamingTranscription.finishSession()
          soundEffect.play(.stopRecording)
        }

      case let .abortSession(reason):
        state.isLive = false
        state.isLiveLocked = false
        state.liveStartedAt = nil
        state.sourceAppBundleID = nil
        state.sourceAppName = nil

        liveLogger.notice("Live session aborted reason=\(String(describing: reason), privacy: .public)")

        return .merge(
          .cancel(id: CancelID.liveSession),
          .run { [streamingTranscription, recording, textInjection, sleepManagement, soundEffect] _ in
            await sleepManagement.allowSleep()
            await recording.stopLiveCapture()
            await streamingTranscription.cancelSession()
            await textInjection.abort(reason)
            soundEffect.play(.cancel)
          }
        )

      case .cancel:
        guard state.isLive else { return .none }
        return .send(.abortSession(.sessionCancelled))

      // MARK: - Dispatcher-Routed Live Slot Outcomes

      case let .dispatcherFired(slot, slotAction):
        return handleDispatcherFired(&state, slot: slot, action: slotAction)

      case .discard:
        // Sub-threshold tap: a session may have been started on press.
        // Send hotKeyReleased to close it cleanly (invariant #9).
        // hotKeyReleased guards on isLive, so this is safe to send unconditionally.
        return .send(.hotKeyReleased)

      // MARK: - Model Availability

      case .checkModelReady:
        let chunkSize = state.hexSettings.liveTranscriptionChunkSize
        return .run { [streamingTranscription] send in
          let ready = await streamingTranscription.isModelAvailable(chunkSize)
          await send(.modelReadyEvaluated(ready))
        }

      case let .modelReadyEvaluated(ready):
        state.isModelReady = ready
        liveLogger.notice("EOU model ready=\(ready, privacy: .public)")
        return .none

      case .downloadModel:
        guard !state.isDownloading else { return .none }
        state.isDownloading = true
        state.downloadProgress = 0
        let chunkSize = state.hexSettings.liveTranscriptionChunkSize

        liveLogger.notice("Starting EOU model download chunkSize=\(chunkSize.rawValue, privacy: .public)")

        return .run { [streamingTranscription] send in
          do {
            try await streamingTranscription.ensureLoaded(chunkSize) { progress in
              Task { await send(.modelDownloadProgress(progress.fractionCompleted)) }
            }
            await send(.modelDownloadFinished(.success(())))
          } catch {
            await send(.modelDownloadFinished(.failure(EquatableError(error))))
          }
        }

      case let .modelDownloadProgress(p):
        state.downloadProgress = p
        return .none

      case let .modelDownloadFinished(result):
        state.isDownloading = false
        switch result {
        case .success:
          state.isModelReady = true
          state.lastError = nil
          liveLogger.notice("EOU model download succeeded")
        case let .failure(err):
          state.isModelReady = false
          state.lastError = err.underlying
          liveLogger.error("EOU model download failed: \(err.underlying, privacy: .public)")
        }
        return .none

      // MARK: - Stream Events

      case let .streamEvent(event):
        // Hook point for future debug/observability; no state mutation needed in v1.
        switch event {
        case let .provisional(h):
          liveLogger.debug("Stream provisional revisionId=\(h.revisionId) chars=\(h.text.count)")
        case let .finalize(c):
          liveLogger.notice("Stream finalize revisionId=\(c.revisionId) chars=\(c.text.count)")
        case let .retract(range):
          liveLogger.notice("Stream retract tokenRange=\(String(describing: range), privacy: .public)")
        }
        return .none

      case .streamFinished:
        state.isLive = false
        state.isLiveLocked = false
        liveLogger.notice("Stream finished cleanly")
        return .none

      case let .streamError(err):
        state.isLive = false
        state.lastError = err.underlying
        liveLogger.error("Stream error: \(err.underlying, privacy: .public)")
        return .send(.abortSession(.error(err.underlying)))
      }
    }
  }
}

// MARK: - Hotkey Monitoring Effect

private extension LiveTranscriptionFeature {
  /// As of Task 3.3, hotkey dispatch is handled by AppFeature's `startHotkeyDispatchEffect()`,
  /// which owns a local `HotkeyDispatcher` copy and routes live-slot outcomes here via
  /// `.dispatcherFired(slot:action:)`. This function retains only the lightweight per-session
  /// escape-key listener (ESC-while-active → cancel) that does not belong in the central hub.
  func startHotKeyMonitoringEffect() -> Effect<Action> {
    .run { send in
      // ESC with no modifiers cancels any active live session regardless of how it was started.
      let token = keyEventMonitor.handleInputEvent { inputEvent in
        guard case .keyboard(let keyEvent) = inputEvent,
              keyEvent.key == .escape,
              keyEvent.modifiers.isEmpty
        else {
          return false
        }
        Task { await send(.cancel) }
        return false
      }

      defer { token.cancel() }

      await withTaskCancellationHandler {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(60))
        }
      } onCancel: {
        token.cancel()
      }
    }
  }
}

// MARK: - Dispatcher-Routed Live Slot Handler

private extension LiveTranscriptionFeature {
  /// Handles outcomes routed from AppFeature's HotkeyDispatcher hub for live slots.
  ///
  /// Idempotency rules (symmetric to TranscriptionFeature.handleDispatcherFired):
  /// - `.liveHold.startRecording`      → normal press-and-hold start. No-op if already live.
  /// - `.liveDoubleTap.startRecording` → promote to locked mode. No-op session start if already
  ///   live (session was started under liveHold and is now being promoted — invariant lock-promotion).
  /// - `.liveHold.stopRecording` / `.liveDoubleTap.stopRecording` → drain and finish the session.
  /// - `.liveHold.cancel` / `.liveDoubleTap.cancel`               → abort immediately.
  /// - Batch slots are handled by TranscriptionFeature; ignored here.
  func handleDispatcherFired(
    _ state: inout State,
    slot: HotkeyDispatcher.Slot,
    action: HotkeyDispatcher.SlotAction
  ) -> Effect<Action> {
    switch (slot, action) {

    // ── Live hold: normal press-and-hold start ───────────────────────────────
    case (.liveHold, .startRecording):
      // Invariant #8: hotKeyPressed claims state.isLive = true synchronously.
      // Clear isLiveLocked only when we are actually starting a new session.
      if state.isLive { return .none }
      state.isLiveLocked = false
      return .send(.hotKeyPressed)

    // ── Live double-tap: promote session to locked mode ──────────────────────
    case (.liveDoubleTap, .startRecording):
      // Lock-promotion: set isLiveLocked whether or not a session is already running.
      state.isLiveLocked = true
      // If no session is running yet, start one now.
      if !state.isLive {
        return .send(.hotKeyPressed)
      }
      // Session already running (was started as liveHold) — just mark it locked.
      return .none

    // ── Stop: either slot drains and finishes the active session ─────────────
    case (.liveHold, .stopRecording), (.liveDoubleTap, .stopRecording):
      state.isLiveLocked = false
      // hotKeyReleased guards on isLive, so safe to send unconditionally.
      return .send(.hotKeyReleased)

    // ── Cancel: either slot aborts immediately ────────────────────────────────
    case (.liveHold, .cancel), (.liveDoubleTap, .cancel):
      state.isLiveLocked = false
      return .send(.cancel)

    // ── Batch slots: not handled here (TranscriptionFeature owns batch) ───────
    case (.batchHold, _), (.batchDoubleTap, _):
      return .none
    }
  }
}

// MARK: - Command Dispatch

/// Iterates `[InjectionCommand]` and dispatches each to the injector.
///
/// Private free function — no `self` needed; all state is in the commands and the client.
private func applyCommands(
  _ commands: [InjectionCommand],
  via textInjection: TextInjectionClient
) async {
  for command in commands {
    switch command {
    case let .beginSession(g):
      try? await textInjection.beginSession(g)
    case let .apply(intent):
      try? await textInjection.apply(intent)
    case let .endSession(g):
      await textInjection.endSession(g)
    case let .abort(reason):
      await textInjection.abort(reason)
    }
  }
}
