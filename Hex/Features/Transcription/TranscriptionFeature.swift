//
//  TranscriptionFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import ComposableArchitecture
import CoreGraphics
import Foundation
import HexCore
import Inject
import SwiftUI
import WhisperKit

private let transcriptionFeatureLogger = HexLog.transcription

@Reducer
struct TranscriptionFeature {
  @ObservableState
  struct State {
    var isRecording: Bool = false
    var isTranscribing: Bool = false
    var isPrewarming: Bool = false
    var error: String?
    var recordingStartTime: Date?
    var meter: Meter = .init(averagePower: 0, peakPower: 0)
    var sourceAppBundleID: String?
    var sourceAppName: String?
    /// Tracks whether the active batch recording session was promoted to locked
    /// (i.e. entered via batchDoubleTap). Task 5.1 will bind this to the
    /// InvisibleWindow indicator; it is set here but not yet used in the UI.
    var isBatchLocked: Bool = false
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
    @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
  }

  enum Action {
    case task
    case audioLevelUpdated(Meter)

    // Hotkey actions (legacy press/release — kept for backward compatibility with direct sends)
    case hotKeyPressed
    case hotKeyReleased

    // Dispatcher-routed batch slot outcomes (wired in Task 3.2 via AppFeature hub)
    case dispatcherFired(slot: HotkeyDispatcher.Slot, action: HotkeyDispatcher.SlotAction)

    // Recording flow
    case startRecording
    case stopRecording

    // Cancel/discard flow
    case cancel   // Explicit cancellation with sound
    case discard  // Silent discard (too short/accidental)

    // Transcription result flow
    case transcriptionResult(String, URL)
    case transcriptionError(Error, URL?)

    // Model availability
    case modelMissing
  }

  enum CancelID {
    case metering
    case recordingCleanup
    case transcription
  }

  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.sleepManagement) var sleepManagement
  @Dependency(\.date.now) var now
  @Dependency(\.transcriptPersistence) var transcriptPersistence

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      // MARK: - Lifecycle / Setup

      case .task:
        // Starts two concurrent effects:
        // 1) Observing audio meter
        // 2) Monitoring hot key events
        // 3) Priming the recorder for instant startup
        return .merge(
          startMeteringEffect(),
          startHotKeyMonitoringEffect(),
          warmUpRecorderEffect()
        )

      // MARK: - Metering

      case let .audioLevelUpdated(meter):
        state.meter = meter
        return .none

      // MARK: - HotKey Flow

      case .hotKeyPressed:
        // If we're transcribing, send a cancel first. Otherwise start recording immediately.
        // We'll decide later (on release) whether to keep or discard the recording.
        return handleHotKeyPressed(isTranscribing: state.isTranscribing)

      case .hotKeyReleased:
        // If we're currently recording, then stop. Otherwise, just cancel
        // the delayed "startRecording" effect if we never actually started.
        return handleHotKeyReleased(isRecording: state.isRecording)

      // MARK: - Dispatcher-Routed Batch Slot Outcomes

      case let .dispatcherFired(slot, slotAction):
        return handleDispatcherFired(&state, slot: slot, action: slotAction)

      // MARK: - Recording Flow

      case .startRecording:
        return handleStartRecording(&state)

      case .stopRecording:
        return handleStopRecording(&state)

      // MARK: - Transcription Results

      case let .transcriptionResult(result, audioURL):
        return handleTranscriptionResult(&state, result: result, audioURL: audioURL)

      case let .transcriptionError(error, audioURL):
        return handleTranscriptionError(&state, error: error, audioURL: audioURL)

      case .modelMissing:
        return .none

      // MARK: - Cancel/Discard Flow

      case .cancel:
        // Only cancel if we're in the middle of recording, transcribing, or post-processing
        guard state.isRecording || state.isTranscribing else {
          return .none
        }
        return handleCancel(&state)

      case .discard:
        // Silent discard for quick/accidental recordings
        guard state.isRecording else {
          return .none
        }
        return handleDiscard(&state)
      }
    }
  }
}

// MARK: - Effects: Metering & HotKey

private extension TranscriptionFeature {
  /// Effect to begin observing the audio meter.
  func startMeteringEffect() -> Effect<Action> {
    .run { send in
      for await meter in await recording.observeAudioLevel() {
        await send(.audioLevelUpdated(meter))
      }
    }
    .cancellable(id: CancelID.metering, cancelInFlight: true)
  }

  /// Effect to start monitoring hotkey events through the `keyEventMonitor`.
  ///
  /// As of Task 3.2, hotkey dispatch is handled by AppFeature's `startHotkeyDispatchEffect()`,
  /// which owns a local `HotkeyDispatcher` copy and routes batch-slot outcomes here via
  /// `.dispatcherFired(slot:action:)`. This function retains only the lightweight per-session
  /// escape-key listener (ESC-while-idle → cancel) that does not belong in the central hub.
  func startHotKeyMonitoringEffect() -> Effect<Action> {
    .run { send in
      // ESC with no modifiers cancels any active session regardless of how it was started.
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

  func warmUpRecorderEffect() -> Effect<Action> {
    .run { _ in
      await recording.warmUpRecorder()
    }
  }
}

// MARK: - HotKey Press/Release Handlers

private extension TranscriptionFeature {
  func handleHotKeyPressed(isTranscribing: Bool) -> Effect<Action> {
    // If already transcribing, cancel first. Otherwise start recording immediately.
    let maybeCancel = isTranscribing ? Effect.send(Action.cancel) : .none
    let startRecording = Effect.send(Action.startRecording)
    return .merge(maybeCancel, startRecording)
  }

  func handleHotKeyReleased(isRecording: Bool) -> Effect<Action> {
    // Always stop recording when hotkey is released
    return isRecording ? .send(.stopRecording) : .none
  }
}

// MARK: - Dispatcher-Routed Batch Slot Handler

private extension TranscriptionFeature {
  /// Handles outcomes routed from AppFeature's HotkeyDispatcher hub for batch slots.
  ///
  /// Idempotency rules (see four-hotkey-rebuild-plan.md):
  /// - `.batchHold.startRecording` → normal press-and-hold start. No-op if already recording.
  /// - `.batchDoubleTap.startRecording` → promote to locked mode. No-op mic start if already
  ///   recording (the session was started under batchHold and is now being promoted).
  /// - `.batchHold.stopRecording` / `.batchDoubleTap.stopRecording` → stop the active session.
  /// - `.batchHold.cancel` / `.batchDoubleTap.cancel` → cancel with sound.
  /// - `.discard` (mapped from SlotAction.cancel when coming from discard path) → silent discard.
  /// - Live slots are handled by LiveTranscriptionFeature (Task 3.3); ignored here.
  func handleDispatcherFired(
    _ state: inout State,
    slot: HotkeyDispatcher.Slot,
    action: HotkeyDispatcher.SlotAction
  ) -> Effect<Action> {
    switch (slot, action) {

    // ── Batch hold: normal press-and-hold start ──────────────────────────────
    case (.batchHold, .startRecording):
      // If a session is already running (e.g. mid-promotion from hold → doubleTap), do nothing.
      guard !state.isRecording else { return .none }
      state.isBatchLocked = false
      return handleStartRecording(&state)

    // ── Batch double-tap: promote session to locked mode ─────────────────────
    case (.batchDoubleTap, .startRecording):
      state.isBatchLocked = true
      // If no session is running yet, start one now.
      if !state.isRecording {
        return handleStartRecording(&state)
      }
      // Session already running (was started as batchHold) — just mark it locked.
      return .none

    // ── Stop: either slot stops the active session ────────────────────────────
    case (.batchHold, .stopRecording), (.batchDoubleTap, .stopRecording):
      guard state.isRecording else { return .none }
      state.isBatchLocked = false
      return handleStopRecording(&state)

    // ── Cancel: either slot cancels with sound ────────────────────────────────
    case (.batchHold, .cancel), (.batchDoubleTap, .cancel):
      state.isBatchLocked = false
      guard state.isRecording || state.isTranscribing else { return .none }
      return handleCancel(&state)

    // ── Live slots: not handled here (Task 3.3 wires LiveTranscriptionFeature) ─
    case (.liveHold, _), (.liveDoubleTap, _):
      return .none
    }
  }
}

// MARK: - Recording Handlers

private extension TranscriptionFeature {
  func handleStartRecording(_ state: inout State) -> Effect<Action> {
    guard state.modelBootstrapState.isModelReady else {
      return .merge(
        .send(.modelMissing),
        .run { _ in soundEffect.play(.cancel) }
      )
    }
    state.isRecording = true
    let startTime = now
    state.recordingStartTime = startTime
    
    // Capture the active application
    if let activeApp = NSWorkspace.shared.frontmostApplication {
      state.sourceAppBundleID = activeApp.bundleIdentifier
      state.sourceAppName = activeApp.localizedName
    }
    transcriptionFeatureLogger.notice("Recording started at \(startTime.ISO8601Format())")

    // Prevent system sleep during recording
    return .merge(
      .cancel(id: CancelID.recordingCleanup),
      .run { [sleepManagement, preventSleep = state.hexSettings.preventSystemSleep] _ in
        // Play sound immediately for instant feedback
        soundEffect.play(.startRecording)

        if preventSleep {
          await sleepManagement.preventSleep(reason: "Hex Voice Recording")
        }
        await recording.startRecording()
      }
    )
  }

  func handleStopRecording(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    state.isBatchLocked = false

    let stopTime = now
    let startTime = state.recordingStartTime
    let duration = startTime.map { stopTime.timeIntervalSince($0) } ?? 0

    let decision = RecordingDecisionEngine.decide(
      .init(
        hotkey: state.hexSettings.hotkey,
        minimumKeyTime: state.hexSettings.minimumKeyTime,
        recordingStartTime: state.recordingStartTime,
        currentTime: stopTime
      )
    )

    let startStamp = startTime?.ISO8601Format() ?? "nil"
    let stopStamp = stopTime.ISO8601Format()
    let minimumKeyTime = state.hexSettings.minimumKeyTime
    let hotkeyHasKey = state.hexSettings.hotkey.key != nil
    transcriptionFeatureLogger.notice(
      "Recording stopped duration=\(String(format: "%.3f", duration))s start=\(startStamp) stop=\(stopStamp) decision=\(String(describing: decision)) minimumKeyTime=\(String(format: "%.2f", minimumKeyTime)) hotkeyHasKey=\(hotkeyHasKey)"
    )

    guard decision == .proceedToTranscription else {
      // If the user recorded for less than minimumKeyTime and the hotkey is modifier-only,
      // discard the audio to avoid accidental triggers.
      transcriptionFeatureLogger.notice("Discarding short recording per decision \(String(describing: decision))")
      return .run { _ in
        let url = await recording.stopRecording()
        guard !Task.isCancelled else { return }
        try? FileManager.default.removeItem(at: url)
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    }

    // Otherwise, proceed to transcription
    state.isTranscribing = true
    state.error = nil
    let model = state.hexSettings.selectedModel
    let language = state.hexSettings.outputLanguage

    state.isPrewarming = true

    return .run { [sleepManagement] send in
      // Allow system to sleep again
      await sleepManagement.allowSleep()

      var audioURL: URL?
      do {
        let capturedURL = await recording.stopRecording()
        guard !Task.isCancelled else { return }
        soundEffect.play(.stopRecording)
        audioURL = capturedURL

        // Create transcription options with the selected language
        // Note: cap concurrency to avoid audio I/O overloads on some Macs
        let decodeOptions = DecodingOptions(
          language: language,
          detectLanguage: language == nil, // Only auto-detect if no language specified
          chunkingStrategy: .vad,
        )
        
        let result = try await transcription.transcribe(capturedURL, model, decodeOptions) { _ in }
        
        transcriptionFeatureLogger.notice("Transcribed audio from \(capturedURL.lastPathComponent) to text length \(result.count)")
        await send(.transcriptionResult(result, capturedURL))
      } catch {
        transcriptionFeatureLogger.error("Transcription failed: \(error.localizedDescription)")
        await send(.transcriptionError(error, audioURL))
      }
    }
    .cancellable(id: CancelID.transcription)
  }
}

// MARK: - Transcription Handlers

private extension TranscriptionFeature {
  func handleTranscriptionResult(
    _ state: inout State,
    result: String,
    audioURL: URL
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false

    // Check for force quit command (emergency escape hatch)
    if ForceQuitCommandDetector.matches(result) {
      transcriptionFeatureLogger.fault("Force quit voice command recognized; terminating Hex.")
      return .run { _ in
        try? FileManager.default.removeItem(at: audioURL)
        await MainActor.run {
          NSApp.terminate(nil)
        }
      }
    }

    // If empty text, nothing else to do
    guard !result.isEmpty else {
      return .none
    }

    let duration = state.recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0

    transcriptionFeatureLogger.info("Raw transcription: '\(result)'")
    let remappings = state.hexSettings.wordRemappings
    let removalsEnabled = state.hexSettings.wordRemovalsEnabled
    let removals = state.hexSettings.wordRemovals
    let modifiedResult: String
    if state.isRemappingScratchpadFocused {
      modifiedResult = result
      transcriptionFeatureLogger.info("Scratchpad focused; skipping word modifications")
    } else {
      var output = result
      if removalsEnabled {
        let removedResult = WordRemovalApplier.apply(output, removals: removals)
        if removedResult != output {
          let enabledRemovalCount = removals.filter(\.isEnabled).count
          transcriptionFeatureLogger.info("Applied \(enabledRemovalCount) word removal(s)")
        }
        output = removedResult
      }
      let remappedResult = WordRemappingApplier.apply(output, remappings: remappings)
      if remappedResult != output {
        transcriptionFeatureLogger.info("Applied \(remappings.count) word remapping(s)")
      }
      modifiedResult = remappedResult
    }

    guard !modifiedResult.isEmpty else {
      return .none
    }

    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory

    return .run { send in
      do {
        try await finalizeRecordingAndStoreTranscript(
          result: modifiedResult,
          duration: duration,
          sourceAppBundleID: sourceAppBundleID,
          sourceAppName: sourceAppName,
          audioURL: audioURL,
          transcriptionHistory: transcriptionHistory
        )
      } catch {
        await send(.transcriptionError(error, audioURL))
      }
    }
    .cancellable(id: CancelID.transcription)
  }

  func handleTranscriptionError(
    _ state: inout State,
    error: Error,
    audioURL: URL?
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false
    state.error = error.localizedDescription
    
    if let audioURL {
      try? FileManager.default.removeItem(at: audioURL)
    }

    return .none
  }

  /// Move file to permanent location, create a transcript record, paste text, and play sound.
  func finalizeRecordingAndStoreTranscript(
    result: String,
    duration: TimeInterval,
    sourceAppBundleID: String?,
    sourceAppName: String?,
    audioURL: URL,
    transcriptionHistory: Shared<TranscriptionHistory>
  ) async throws {
    @Shared(.hexSettings) var hexSettings: HexSettings

    if hexSettings.saveTranscriptionHistory {
      let transcript = try await transcriptPersistence.save(
        result,
        audioURL,
        duration,
        sourceAppBundleID,
        sourceAppName
      )

      transcriptionHistory.withLock { history in
        history.history.insert(transcript, at: 0)

        if let maxEntries = hexSettings.maxHistoryEntries, maxEntries > 0 {
          while history.history.count > maxEntries {
            if let removedTranscript = history.history.popLast() {
              Task {
                 try? await transcriptPersistence.deleteAudio(removedTranscript)
              }
            }
          }
        }
      }
    } else {
      try? FileManager.default.removeItem(at: audioURL)
    }

    await pasteboard.paste(result)
    soundEffect.play(.pasteTranscript)
  }
}

// MARK: - Cancel/Discard Handlers

private extension TranscriptionFeature {
  func handleCancel(_ state: inout State) -> Effect<Action> {
    state.isTranscribing = false
    state.isRecording = false
    state.isPrewarming = false
    state.isBatchLocked = false

    return .merge(
      .cancel(id: CancelID.transcription),
      .run { [sleepManagement] _ in
        // Allow system to sleep again
        await sleepManagement.allowSleep()
        // Stop the recording to release microphone access
        let url = await recording.stopRecording()
        guard !Task.isCancelled else { return }
        try? FileManager.default.removeItem(at: url)
        soundEffect.play(.cancel)
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    )
  }

  func handleDiscard(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    state.isPrewarming = false
    state.isBatchLocked = false

    // Silently discard - no sound effect
    return .run { [sleepManagement] _ in
      // Allow system to sleep again
      await sleepManagement.allowSleep()
      let url = await recording.stopRecording()
      guard !Task.isCancelled else { return }
      try? FileManager.default.removeItem(at: url)
    }
    .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
  }
}

// MARK: - View

struct TranscriptionView: View {
  @Bindable var store: StoreOf<TranscriptionFeature>
  @ObserveInjection var inject

  var status: TranscriptionIndicatorView.Status {
    if store.isTranscribing {
      return .transcribing
    } else if store.isRecording {
      return .recording
    } else if store.isPrewarming {
      return .prewarming
    } else {
      return .hidden
    }
  }

  var body: some View {
    TranscriptionIndicatorView(
      status: status,
      meter: store.meter
    )
    .task {
      await store.send(.task).finish()
    }
    .enableInjection()
  }
}

// MARK: - Force Quit Command

private enum ForceQuitCommandDetector {
  static func matches(_ text: String) -> Bool {
    let normalized = normalize(text)
    return normalized == "force quit hex now" || normalized == "force quit hex"
  }

  private static func normalize(_ text: String) -> String {
    text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}
