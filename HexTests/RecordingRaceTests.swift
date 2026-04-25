import AppKit
import AVFoundation
import ComposableArchitecture
import Foundation
import Testing

@testable import Hex

@Suite(.serialized)
@MainActor
struct RecordingRaceTests {
  @Test
  func newRecordingCancelsPendingDiscardCleanup() async throws {
    let now = Date(timeIntervalSince1970: 1_234)
    let activeApp = NSWorkspace.shared.frontmostApplication
    let stopURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("discard-cleanup-\(UUID().uuidString).wav")
    let created = FileManager.default.createFile(
      atPath: stopURL.path,
      contents: Data("test".utf8)
    )
    #expect(created)
    defer { try? FileManager.default.removeItem(at: stopURL) }

    let probe = RecordingProbe(stopURL: stopURL)
    let store = TestStore(initialState: Self.makeState()) {
      TranscriptionFeature()
    } withDependencies: {
      $0.date.now = now
      $0.recording.startRecording = {
        await probe.recordStart()
      }
      $0.recording.stopRecording = {
        await probe.beginStop()
      }
      $0.sleepManagement.preventSleep = { _ in }
      $0.sleepManagement.allowSleep = {}
      $0.soundEffects.play = { _ in }
    }

    await store.send(.startRecording) {
      $0.isRecording = true
      $0.recordingStartTime = now
      $0.sourceAppBundleID = activeApp?.bundleIdentifier
      $0.sourceAppName = activeApp?.localizedName
    }
    await store.send(.discard) {
      $0.isRecording = false
      $0.isPrewarming = false
    }

    await probe.waitForPendingStop()

    await store.send(.startRecording) {
      $0.isRecording = true
      $0.recordingStartTime = now
      $0.sourceAppBundleID = activeApp?.bundleIdentifier
      $0.sourceAppName = activeApp?.localizedName
    }

    await probe.resumePendingStop()
    await store.finish()

    let counts = await probe.counts()
    #expect(counts.startCalls == 2)
    #expect(counts.stopCalls == 1)
    #expect(FileManager.default.fileExists(atPath: stopURL.path))
  }

  // MARK: - Live capture hook

  /// Verifies that `beginLiveCapture`/`endLiveCapture` toggle `isLiveCaptureActive`
  /// correctly, and that `endLiveCapture` is idempotent.
  ///
  /// This test exercises only the queue-protected callback property — it does not start
  /// an `AVAudioEngine`, so no microphone permission is required.
  @Test
  func liveCaptureActiveTogglesWithCallback() async throws {
    let (meterStream, meterContinuation) = AsyncStream<Meter>.makeStream()
    _ = meterStream
    let controller = SuperFastCaptureController(meterContinuation: meterContinuation)

    #expect(controller.isLiveCaptureActive == false)

    controller.beginLiveCapture(onBuffer: { _ in })
    // `beginLiveCapture` dispatches async onto processingQueue; yield to let it land.
    try await Task.sleep(for: .milliseconds(50))
    #expect(controller.isLiveCaptureActive == true)

    controller.endLiveCapture()
    try await Task.sleep(for: .milliseconds(50))
    #expect(controller.isLiveCaptureActive == false)

    // Idempotent: second `endLiveCapture` must not crash or set state incorrectly.
    controller.endLiveCapture()
    try await Task.sleep(for: .milliseconds(50))
    #expect(controller.isLiveCaptureActive == false)
  }

  @Test
  func stopGuardIgnoresOnlyStaleSessions() {
    let currentSessionID = UUID()

    #expect(
      RecordingClientLive.shouldIgnoreStopRequest(
        snapshotSessionID: currentSessionID,
        currentSessionID: currentSessionID
      ) == false
    )
    #expect(
      RecordingClientLive.shouldIgnoreStopRequest(
        snapshotSessionID: nil,
        currentSessionID: currentSessionID
      ) == false
    )
    #expect(
      RecordingClientLive.shouldIgnoreStopRequest(
        snapshotSessionID: currentSessionID,
        currentSessionID: UUID()
      )
    )
  }

  private static func makeState() -> TranscriptionFeature.State {
    TranscriptionFeature.State(
      hexSettings: Shared(.init()),
      isRemappingScratchpadFocused: Shared(false),
      modelBootstrapState: Shared(.init(isModelReady: true)),
      transcriptionHistory: Shared(.init())
    )
  }
}

private actor RecordingProbe {
  private let stopURL: URL
  private var startCalls = 0
  private var stopCalls = 0
  private var stopContinuation: CheckedContinuation<URL, Never>?

  init(stopURL: URL) {
    self.stopURL = stopURL
  }

  func recordStart() {
    startCalls += 1
  }

  func beginStop() async -> URL {
    stopCalls += 1
    return await withCheckedContinuation { continuation in
      stopContinuation = continuation
    }
  }

  func waitForPendingStop() async {
    while stopContinuation == nil {
      await Task.yield()
    }
  }

  func resumePendingStop() {
    stopContinuation?.resume(returning: stopURL)
    stopContinuation = nil
  }

  func counts() -> (startCalls: Int, stopCalls: Int) {
    (startCalls, stopCalls)
  }
}
