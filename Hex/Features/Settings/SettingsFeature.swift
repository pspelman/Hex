import AVFoundation
import AppKit
import ComposableArchitecture
import CoreAudio
import Dependencies
import HexCore
import IdentifiedCollections
import Sauce
import ServiceManagement
import SwiftUI

private let settingsLogger = HexLog.settings
private typealias SettingsAudioPropertyListenerBlock = @convention(block) (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void

private enum HotKeyCaptureTarget: CaseIterable {
  case recording
  case pasteLastTranscript
  case liveHold
  case liveDoubleTap
  case batchHold
  case batchDoubleTap
  case pauseHotkeys
}

extension SharedReaderKey
  where Self == InMemoryKey<Bool>.Default
{
  static var isSettingHotKey: Self {
    Self[.inMemory("isSettingHotKey"), default: false]
  }

  static var isSettingPasteLastTranscriptHotkey: Self {
    Self[.inMemory("isSettingPasteLastTranscriptHotkey"), default: false]
  }

  static var isRemappingScratchpadFocused: Self {
    Self[.inMemory("isRemappingScratchpadFocused"), default: false]
  }

  static var isSettingLiveHoldHotkey: Self {
    Self[.inMemory("isSettingLiveHoldHotkey"), default: false]
  }

  static var isSettingLiveDoubleTapHotkey: Self {
    Self[.inMemory("isSettingLiveDoubleTapHotkey"), default: false]
  }

  static var isSettingBatchHoldHotkey: Self {
    Self[.inMemory("isSettingBatchHoldHotkey"), default: false]
  }

  static var isSettingBatchDoubleTapHotkey: Self {
    Self[.inMemory("isSettingBatchDoubleTapHotkey"), default: false]
  }

  static var isSettingPauseHotkeysHotkey: Self {
    Self[.inMemory("isSettingPauseHotkeysHotkey"), default: false]
  }
}

// MARK: - Settings Feature

@Reducer
struct SettingsFeature {
  @ObservableState
  struct State {
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isSettingHotKey) var isSettingHotKey: Bool = false
    @Shared(.isSettingPasteLastTranscriptHotkey) var isSettingPasteLastTranscriptHotkey: Bool = false
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
    @Shared(.isSettingLiveHoldHotkey) var isSettingLiveHoldHotkey: Bool = false
    @Shared(.isSettingLiveDoubleTapHotkey) var isSettingLiveDoubleTapHotkey: Bool = false
    @Shared(.isSettingBatchHoldHotkey) var isSettingBatchHoldHotkey: Bool = false
    @Shared(.isSettingBatchDoubleTapHotkey) var isSettingBatchDoubleTapHotkey: Bool = false
    @Shared(.isSettingPauseHotkeysHotkey) var isSettingPauseHotkeysHotkey: Bool = false
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
    @Shared(.hotkeyPermissionState) var hotkeyPermissionState: HotkeyPermissionState

    var languages: IdentifiedArrayOf<Language> = []
    var currentModifiers: Modifiers = .init(modifiers: [])
    var currentPasteLastModifiers: Modifiers = .init(modifiers: [])
    var currentLiveHoldModifiers: Modifiers = .init(modifiers: [])
    var currentLiveDoubleTapModifiers: Modifiers = .init(modifiers: [])
    var currentBatchHoldModifiers: Modifiers = .init(modifiers: [])
    var currentBatchDoubleTapModifiers: Modifiers = .init(modifiers: [])
    var currentPauseHotkeysModifiers: Modifiers = .init(modifiers: [])
    var remappingScratchpadText: String = ""
    
    // Available microphones
    var availableInputDevices: [AudioInputDevice] = []
    var defaultInputDeviceName: String?

    // Model Management
    var modelDownload = ModelDownloadFeature.State()
    var shouldFlashModelSection = false

    // Live transcription model
    var isLiveModelReady: Bool = false
    var isLiveModelDownloading: Bool = false
    var liveModelDownloadProgress: Double = 0
    var liveModelError: String?

  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)

    // Existing
    case task
    case startSettingHotKey
    case startSettingPasteLastTranscriptHotkey
    case clearPasteLastTranscriptHotkey
    case keyEvent(KeyEvent)

    // Four-slot hotkey capture
    case startSettingLiveHoldHotkey
    case startSettingLiveDoubleTapHotkey
    case startSettingBatchHoldHotkey
    case startSettingBatchDoubleTapHotkey
    case clearLiveHoldHotkey
    case clearLiveDoubleTapHotkey
    case clearBatchHoldHotkey
    case clearBatchDoubleTapHotkey
    case startSettingPauseHotkeysHotkey
    case clearPauseHotkeysHotkey
    case toggleOpenOnLogin(Bool)
    case toggleShowDockIcon(Bool)
    case togglePreventSystemSleep(Bool)
    case setRecordingAudioBehavior(RecordingAudioBehavior)
    case toggleSuperFastMode(Bool)
    case setUseClipboardPaste(Bool)
    case setCopyToClipboard(Bool)
    case setMinimumKeyTime(Double)
    case setOutputLanguage(String?)
    case setSelectedMicrophoneID(String?)
    case setSoundEffectsEnabled(Bool)
    case setSoundEffectsVolume(Double)

    // Live transcription
    case setLiveTranscriptionChunkSize(LiveTranscriptionChunkSize)
    case checkLiveModelReady
    case liveModelReadyEvaluated(Bool)
    case downloadLiveModel
    case liveModelDownloadProgressUpdated(Double)
    case liveModelDownloadFinished(Bool, String?)

    // Permission delegation (forwarded to AppFeature)
    case requestMicrophone
    case requestAccessibility
    case requestInputMonitoring

    // Microphone selection
    case loadAvailableInputDevices
    case availableInputDevicesLoaded([AudioInputDevice], String?)

    // Model Management
    case modelDownload(ModelDownloadFeature.Action)
    
    // History Management
    case toggleSaveTranscriptionHistory(Bool)
    case setMaxHistoryEntries(Int?)

    // Modifier configuration
    case setModifierSide(Modifier.Kind, Modifier.Side)

    // Word remappings
    case setWordRemovalsEnabled(Bool)
    case addWordRemoval
    case updateWordRemoval(WordRemoval)
    case removeWordRemoval(UUID)
    case addWordRemapping
    case updateWordRemapping(WordRemapping)
    case removeWordRemapping(UUID)
    case setRemappingScratchpadFocused(Bool)
  }

  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.continuousClock) var clock
  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.permissions) var permissions
  @Dependency(\.soundEffects) var soundEffects
  @Dependency(\.transcriptPersistence) var transcriptPersistence
  @Dependency(\.streamingTranscription) var streamingTranscription

  private func deleteAudioEffect(for transcripts: [Transcript]) -> Effect<Action> {
    .run { [transcriptPersistence] _ in
      for transcript in transcripts {
        try? await transcriptPersistence.deleteAudio(transcript)
      }
    }
  }

  private func isCapturing(_ target: HotKeyCaptureTarget, state: State) -> Bool {
    switch target {
    case .recording: state.isSettingHotKey
    case .pasteLastTranscript: state.isSettingPasteLastTranscriptHotkey
    case .liveHold: state.isSettingLiveHoldHotkey
    case .liveDoubleTap: state.isSettingLiveDoubleTapHotkey
    case .batchHold: state.isSettingBatchHoldHotkey
    case .batchDoubleTap: state.isSettingBatchDoubleTapHotkey
    case .pauseHotkeys: state.isSettingPauseHotkeysHotkey
    }
  }

  private func beginCapture(_ target: HotKeyCaptureTarget, state: inout State) {
    // Mutual exclusion: cancel any in-progress capture before starting a new one.
    // Without this guard two rapid taps could set two flags simultaneously, leaving
    // the second row visually stuck in "capturing" state until Settings closes.
    for prior in HotKeyCaptureTarget.allCases where prior != target {
      if isCapturing(prior, state: state) {
        settingsLogger.notice("HotKey capture cancelling prior=\(String(describing: prior), privacy: .public) for new target=\(String(describing: target), privacy: .public)")
        endCapture(prior, state: &state)
      }
    }
    settingsLogger.notice("HotKey capture begin target=\(String(describing: target), privacy: .public)")
    switch target {
    case .recording:
      state.$isSettingHotKey.withLock { $0 = true }
      state.currentModifiers = .init(modifiers: [])
    case .pasteLastTranscript:
      state.$isSettingPasteLastTranscriptHotkey.withLock { $0 = true }
      state.currentPasteLastModifiers = .init(modifiers: [])
    case .liveHold:
      state.$isSettingLiveHoldHotkey.withLock { $0 = true }
      state.currentLiveHoldModifiers = .init(modifiers: [])
    case .liveDoubleTap:
      state.$isSettingLiveDoubleTapHotkey.withLock { $0 = true }
      state.currentLiveDoubleTapModifiers = .init(modifiers: [])
    case .batchHold:
      state.$isSettingBatchHoldHotkey.withLock { $0 = true }
      state.currentBatchHoldModifiers = .init(modifiers: [])
    case .batchDoubleTap:
      state.$isSettingBatchDoubleTapHotkey.withLock { $0 = true }
      state.currentBatchDoubleTapModifiers = .init(modifiers: [])
    case .pauseHotkeys:
      state.$isSettingPauseHotkeysHotkey.withLock { $0 = true }
      state.currentPauseHotkeysModifiers = .init(modifiers: [])
    }
  }

  private func endCapture(_ target: HotKeyCaptureTarget, state: inout State) {
    settingsLogger.notice("HotKey capture end target=\(String(describing: target), privacy: .public)")
    switch target {
    case .recording:
      state.$isSettingHotKey.withLock { $0 = false }
      state.currentModifiers = .init(modifiers: [])
    case .pasteLastTranscript:
      state.$isSettingPasteLastTranscriptHotkey.withLock { $0 = false }
      state.currentPasteLastModifiers = .init(modifiers: [])
    case .liveHold:
      state.$isSettingLiveHoldHotkey.withLock { $0 = false }
      state.currentLiveHoldModifiers = .init(modifiers: [])
    case .liveDoubleTap:
      state.$isSettingLiveDoubleTapHotkey.withLock { $0 = false }
      state.currentLiveDoubleTapModifiers = .init(modifiers: [])
    case .batchHold:
      state.$isSettingBatchHoldHotkey.withLock { $0 = false }
      state.currentBatchHoldModifiers = .init(modifiers: [])
    case .batchDoubleTap:
      state.$isSettingBatchDoubleTapHotkey.withLock { $0 = false }
      state.currentBatchDoubleTapModifiers = .init(modifiers: [])
    case .pauseHotkeys:
      state.$isSettingPauseHotkeysHotkey.withLock { $0 = false }
      state.currentPauseHotkeysModifiers = .init(modifiers: [])
    }
  }

  private func captureModifiers(for target: HotKeyCaptureTarget, state: State) -> Modifiers {
    switch target {
    case .recording:
      state.currentModifiers
    case .pasteLastTranscript:
      state.currentPasteLastModifiers
    case .liveHold:
      state.currentLiveHoldModifiers
    case .liveDoubleTap:
      state.currentLiveDoubleTapModifiers
    case .batchHold:
      state.currentBatchHoldModifiers
    case .batchDoubleTap:
      state.currentBatchDoubleTapModifiers
    case .pauseHotkeys:
      state.currentPauseHotkeysModifiers
    }
  }

  private func updateCaptureModifiers(_ modifiers: Modifiers, for target: HotKeyCaptureTarget, state: inout State) {
    switch target {
    case .recording:
      state.currentModifiers = modifiers
    case .pasteLastTranscript:
      state.currentPasteLastModifiers = modifiers
    case .liveHold:
      state.currentLiveHoldModifiers = modifiers
    case .liveDoubleTap:
      state.currentLiveDoubleTapModifiers = modifiers
    case .batchHold:
      state.currentBatchHoldModifiers = modifiers
    case .batchDoubleTap:
      state.currentBatchDoubleTapModifiers = modifiers
    case .pauseHotkeys:
      state.currentPauseHotkeysModifiers = modifiers
    }
  }

  private func applyCapturedHotKey(key: Key?, modifiers: Modifiers, for target: HotKeyCaptureTarget, state: inout State) {
    switch target {
    case .recording:
      state.$hexSettings.withLock {
        $0.hotkey.key = key
        $0.hotkey.modifiers = modifiers.erasingSides()
      }
    case .pasteLastTranscript:
      guard let key else { return }
      state.$hexSettings.withLock {
        $0.pasteLastTranscriptHotkey = HotKey(key: key, modifiers: modifiers.erasingSides())
      }
    case .liveHold:
      state.$hexSettings.withLock {
        $0.liveHoldHotkey = HotKey(key: key, modifiers: modifiers.erasingSides())
      }
    case .liveDoubleTap:
      state.$hexSettings.withLock {
        $0.liveDoubleTapHotkey = HotKey(key: key, modifiers: modifiers.erasingSides())
      }
    case .batchHold:
      state.$hexSettings.withLock {
        $0.batchHoldHotkey = HotKey(key: key, modifiers: modifiers.erasingSides())
      }
    case .batchDoubleTap:
      state.$hexSettings.withLock {
        $0.batchDoubleTapHotkey = HotKey(key: key, modifiers: modifiers.erasingSides())
      }
    case .pauseHotkeys:
      guard let key else { return }
      state.$hexSettings.withLock {
        $0.pauseHotkeysHotkey = HotKey(key: key, modifiers: modifiers.erasingSides())
      }
    }
  }

  private func handleCapture(_ keyEvent: KeyEvent, for target: HotKeyCaptureTarget, state: inout State) -> Effect<Action> {
    settingsLogger.notice("HotKey capture event target=\(String(describing: target), privacy: .public) key=\(String(describing: keyEvent.key), privacy: .public) modifiers=\(String(describing: keyEvent.modifiers), privacy: .public)")

    if keyEvent.key == .escape {
      endCapture(target, state: &state)
      return .none
    }

    let updatedModifiers = keyEvent.modifiers.union(captureModifiers(for: target, state: state))
    updateCaptureModifiers(updatedModifiers, for: target, state: &state)

    if target == .pasteLastTranscript || target == .pauseHotkeys, keyEvent.key != nil, updatedModifiers.isEmpty {
      return .none
    }

    if let key = keyEvent.key {
      applyCapturedHotKey(key: key, modifiers: updatedModifiers, for: target, state: &state)
      endCapture(target, state: &state)
      return .none
    }

    // Only finalize a modifier-only capture once the user has actually pressed at least one
    // modifier. Without this guard, a stray flagsChanged event arriving with empty modifiers
    // (e.g. caps lock toggling, or releasing a key that was already held when capture started)
    // would immediately end the session and persist an empty hotkey.
    //
    // This guard covers all targets that support modifier-only hotkeys (recording + all four slots).
    let supportsModifierOnly: Bool
    switch target {
    case .recording, .liveHold, .liveDoubleTap, .batchHold, .batchDoubleTap:
      supportsModifierOnly = true
    case .pasteLastTranscript, .pauseHotkeys:
      supportsModifierOnly = false
    }
    if supportsModifierOnly, keyEvent.modifiers.isEmpty, !updatedModifiers.isEmpty {
      applyCapturedHotKey(key: nil, modifiers: updatedModifiers, for: target, state: &state)
      endCapture(target, state: &state)
    }

    return .none
  }

  var body: some ReducerOf<Self> {
    BindingReducer()

    Scope(state: \.modelDownload, action: \.modelDownload) {
      ModelDownloadFeature()
    }

    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .task:
        if let url = Bundle.main.url(forResource: "languages", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let languages = try? JSONDecoder().decode([Language].self, from: data)
        {
          state.languages = IdentifiedArray(uniqueElements: languages)
        } else {
          settingsLogger.error("Failed to load languages JSON from bundle")
        }

        // Listen for key events and load microphones (existing + new)
        return .run { [keyEventMonitor] send in
          func audioPropertyAddress(
            _ selector: AudioObjectPropertySelector,
            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
            element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
          ) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(
              mSelector: selector,
              mScope: scope,
              mElement: element
            )
          }

          // Subscribe to key events FIRST, before any other setup, so a user who
          // immediately taps the HotKey capture area never races the audio-device
          // configuration below.
          let keyEventListenerTask = Task { [keyEventMonitor] in
            settingsLogger.notice("HotKey capture listener subscribing")
            do {
              for try await keyEvent in await keyEventMonitor.listenForKeyPress() {
                await send(.keyEvent(keyEvent))
              }
              settingsLogger.notice("HotKey capture listener stream closed")
            } catch {
              settingsLogger.error("HotKey capture listener errored: \(error.localizedDescription, privacy: .public)")
            }
          }

          await send(.modelDownload(.fetchModels))
          await send(.loadAvailableInputDevices)
          await send(.checkLiveModelReady)

          // Set up periodic refresh of available devices (every 120 seconds)
          // Using a longer interval to reduce resource usage
          let deviceRefreshTask = Task { @MainActor in
            for await _ in clock.timer(interval: .seconds(120)) {
              // Only refresh when the app is active to save resources
              if NSApplication.shared.isActive {
                await send(.loadAvailableInputDevices)
              }
            }
          }

          // Listen for device connection/disconnection notifications
          // Using a simpler debounced approach with a single task
          var deviceUpdateTask: Task<Void, Never>?
          var audioHardwareObservers: [(AudioObjectPropertySelector, SettingsAudioPropertyListenerBlock)] = []

          // Helper function to debounce device updates
          func debounceDeviceUpdate() {
            deviceUpdateTask?.cancel()
            deviceUpdateTask = Task {
              try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
              if !Task.isCancelled {
                await send(.loadAvailableInputDevices)
              }
            }
          }

          func installAudioHardwareObserver(_ selector: AudioObjectPropertySelector) {
            let listener: SettingsAudioPropertyListenerBlock = { _, _ in
              debounceDeviceUpdate()
            }
            var address = audioPropertyAddress(selector)
            let status = AudioObjectAddPropertyListenerBlock(
              AudioObjectID(kAudioObjectSystemObject),
              &address,
              DispatchQueue.main,
              listener
            )

            if status == noErr {
              audioHardwareObservers.append((selector, listener))
            } else {
              settingsLogger.error("Failed to observe audio hardware selector \(selector): \(status)")
            }
          }

          let deviceConnectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "AVCaptureDeviceWasConnected"),
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }
          
          let deviceDisconnectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "AVCaptureDeviceWasDisconnected"),
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }

          let appDidBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }

          let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }

          installAudioHardwareObserver(kAudioHardwarePropertyDefaultInputDevice)
          installAudioHardwareObserver(kAudioHardwarePropertyDevices)

          // Be sure to clean up resources when the task is finished
          defer {
            keyEventListenerTask.cancel()
            deviceRefreshTask.cancel()
            deviceUpdateTask?.cancel()
            NotificationCenter.default.removeObserver(deviceConnectionObserver)
            NotificationCenter.default.removeObserver(deviceDisconnectionObserver)
            NotificationCenter.default.removeObserver(appDidBecomeActiveObserver)
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)

            for (selector, listener) in audioHardwareObservers {
              var address = audioPropertyAddress(selector)
              let status = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                listener
              )
              if status != noErr {
                settingsLogger.error("Failed to remove audio hardware observer for selector \(selector): \(status)")
              }
            }
          }

          // Park the effect: outer cleanup runs when this Task is cancelled by SwiftUI's
          // .task lifecycle. The key event listener runs concurrently in its own Task.
          await withTaskCancellationHandler {
            while !Task.isCancelled {
              try? await Task.sleep(for: .seconds(60))
            }
          } onCancel: {
            keyEventListenerTask.cancel()
          }
        }

      case .startSettingHotKey:
        beginCapture(.recording, state: &state)
        return .none

      case .addWordRemoval:
        state.$hexSettings.withLock {
          $0.wordRemovals.append(.init(pattern: ""))
        }
        return .none

      case let .updateWordRemoval(removal):
        state.$hexSettings.withLock {
          guard let index = $0.wordRemovals.firstIndex(where: { $0.id == removal.id }) else { return }
          $0.wordRemovals[index] = removal
        }
        return .none

      case let .removeWordRemoval(id):
        state.$hexSettings.withLock {
          $0.wordRemovals.removeAll { $0.id == id }
        }
        return .none

      case .addWordRemapping:
        state.$hexSettings.withLock {
          $0.wordRemappings.append(.init(match: "", replacement: ""))
        }
        return .none

      case let .updateWordRemapping(remapping):
        state.$hexSettings.withLock {
          guard let index = $0.wordRemappings.firstIndex(where: { $0.id == remapping.id }) else { return }
          $0.wordRemappings[index] = remapping
        }
        return .none

      case let .removeWordRemapping(id):
        state.$hexSettings.withLock {
          $0.wordRemappings.removeAll { $0.id == id }
        }
        return .none

      case let .setRemappingScratchpadFocused(isFocused):
        state.$isRemappingScratchpadFocused.withLock { $0 = isFocused }
        return .none

      case .startSettingPasteLastTranscriptHotkey:
        beginCapture(.pasteLastTranscript, state: &state)
        return .none

      case .clearPasteLastTranscriptHotkey:
        state.$hexSettings.withLock { $0.pasteLastTranscriptHotkey = nil }
        return .none

      case .startSettingLiveHoldHotkey:
        beginCapture(.liveHold, state: &state)
        return .none

      case .startSettingLiveDoubleTapHotkey:
        beginCapture(.liveDoubleTap, state: &state)
        return .none

      case .startSettingBatchHoldHotkey:
        beginCapture(.batchHold, state: &state)
        return .none

      case .startSettingBatchDoubleTapHotkey:
        beginCapture(.batchDoubleTap, state: &state)
        return .none

      case .clearLiveHoldHotkey:
        state.$hexSettings.withLock { $0.liveHoldHotkey = nil }
        return .none

      case .clearLiveDoubleTapHotkey:
        state.$hexSettings.withLock { $0.liveDoubleTapHotkey = nil }
        return .none

      case .clearBatchHoldHotkey:
        state.$hexSettings.withLock { $0.batchHoldHotkey = nil }
        return .none

      case .clearBatchDoubleTapHotkey:
        state.$hexSettings.withLock { $0.batchDoubleTapHotkey = nil }
        return .none

      case .startSettingPauseHotkeysHotkey:
        beginCapture(.pauseHotkeys, state: &state)
        return .none

      case .clearPauseHotkeysHotkey:
        state.$hexSettings.withLock { $0.pauseHotkeysHotkey = nil }
        return .none

      case let .keyEvent(keyEvent):
        if state.isSettingLiveHoldHotkey {
          return handleCapture(keyEvent, for: .liveHold, state: &state)
        }
        if state.isSettingLiveDoubleTapHotkey {
          return handleCapture(keyEvent, for: .liveDoubleTap, state: &state)
        }
        if state.isSettingBatchHoldHotkey {
          return handleCapture(keyEvent, for: .batchHold, state: &state)
        }
        if state.isSettingBatchDoubleTapHotkey {
          return handleCapture(keyEvent, for: .batchDoubleTap, state: &state)
        }
        if state.isSettingPasteLastTranscriptHotkey {
          return handleCapture(keyEvent, for: .pasteLastTranscript, state: &state)
        }
        if state.isSettingPauseHotkeysHotkey {
          return handleCapture(keyEvent, for: .pauseHotkeys, state: &state)
        }

        guard state.isSettingHotKey else { return .none }
        return handleCapture(keyEvent, for: .recording, state: &state)

      case let .toggleOpenOnLogin(enabled):
        state.$hexSettings.withLock { $0.openOnLogin = enabled }
        return .run { _ in
          if enabled {
            try? SMAppService.mainApp.register()
          } else {
            try? SMAppService.mainApp.unregister()
          }
        }

      case let .toggleShowDockIcon(enabled):
        state.$hexSettings.withLock { $0.showDockIcon = enabled }
        return .run { _ in
          await MainActor.run {
            NotificationCenter.default.post(name: .updateAppMode, object: nil)
          }
        }

      case let .togglePreventSystemSleep(enabled):
        state.$hexSettings.withLock { $0.preventSystemSleep = enabled }
        return .none

      case let .setUseClipboardPaste(enabled):
        state.$hexSettings.withLock { $0.useClipboardPaste = enabled }
        return .none

      case let .setCopyToClipboard(enabled):
        state.$hexSettings.withLock { $0.copyToClipboard = enabled }
        return .none

      case let .setRecordingAudioBehavior(behavior):
        state.$hexSettings.withLock { $0.recordingAudioBehavior = behavior }
        return .none

      case let .toggleSuperFastMode(enabled):
        state.$hexSettings.withLock { $0.superFastModeEnabled = enabled }
        return .run { _ in
          await recording.warmUpRecorder()
        }

      case let .setMinimumKeyTime(value):
        state.$hexSettings.withLock { $0.minimumKeyTime = value }
        return .none

      case let .setOutputLanguage(language):
        state.$hexSettings.withLock { $0.outputLanguage = language }
        return .none

      case let .setSelectedMicrophoneID(deviceID):
        state.$hexSettings.withLock { $0.selectedMicrophoneID = deviceID }
        return .none

      case let .setSoundEffectsEnabled(enabled):
        state.$hexSettings.withLock { $0.soundEffectsEnabled = enabled }
        return .run { _ in
          await soundEffects.setEnabled(enabled)
        }

      case let .setSoundEffectsVolume(volume):
        state.$hexSettings.withLock { $0.soundEffectsVolume = volume }
        return .none

      case let .setLiveTranscriptionChunkSize(chunkSize):
        state.$hexSettings.withLock { $0.liveTranscriptionChunkSize = chunkSize }
        return .send(.checkLiveModelReady)

      case .checkLiveModelReady:
        let chunkSize = state.hexSettings.liveTranscriptionChunkSize
        return .run { [streamingTranscription] send in
          let ready = await streamingTranscription.isModelAvailable(chunkSize)
          await send(.liveModelReadyEvaluated(ready))
        }

      case let .liveModelReadyEvaluated(ready):
        state.isLiveModelReady = ready
        if ready { state.liveModelError = nil }
        return .none

      case .downloadLiveModel:
        guard !state.isLiveModelDownloading else { return .none }
        state.isLiveModelDownloading = true
        state.liveModelDownloadProgress = 0
        state.liveModelError = nil
        let chunkSize = state.hexSettings.liveTranscriptionChunkSize
        return .run { [streamingTranscription] send in
          do {
            try await streamingTranscription.ensureLoaded(chunkSize) { progress in
              Task { await send(.liveModelDownloadProgressUpdated(progress.fractionCompleted)) }
            }
            await send(.liveModelDownloadFinished(true, nil))
          } catch {
            await send(.liveModelDownloadFinished(false, error.localizedDescription))
          }
        }

      case let .liveModelDownloadProgressUpdated(progress):
        state.liveModelDownloadProgress = progress
        return .none

      case let .liveModelDownloadFinished(success, errorMessage):
        state.isLiveModelDownloading = false
        state.isLiveModelReady = success
        state.liveModelError = errorMessage
        if success { state.liveModelDownloadProgress = 1 }
        return .none

      // Permission requests
      case .requestMicrophone:
        settingsLogger.info("User requested microphone permission from settings")
        return .run { _ in
          _ = await permissions.requestMicrophone()
        }

      case .requestAccessibility:
        settingsLogger.info("User requested accessibility permission from settings")
        return .run { _ in
          await permissions.requestAccessibility()
        }

      case .requestInputMonitoring:
        settingsLogger.info("User requested input monitoring permission from settings")
        return .run { _ in
          _ = await permissions.requestInputMonitoring()
        }

      // Model Management
      case let .modelDownload(.selectModel(newModel)):
        // Also store it in hexSettings:
        state.$hexSettings.withLock {
          $0.selectedModel = newModel
        }
        // Then continue with the child's normal logic:
        return .none

      case .modelDownload:
        return .none
      
      // Microphone device selection
      case .loadAvailableInputDevices:
        return .run { send in
          let devices = await recording.getAvailableInputDevices()
          let defaultName = await recording.getDefaultInputDeviceName()
          await send(.availableInputDevicesLoaded(devices, defaultName))
        }
        
      case let .availableInputDevicesLoaded(devices, defaultName):
        state.availableInputDevices = devices
        state.defaultInputDeviceName = defaultName
        return .none
        
      case let .toggleSaveTranscriptionHistory(enabled):
        state.$hexSettings.withLock { $0.saveTranscriptionHistory = enabled }
        
        // If disabling history, delete all existing entries
        if !enabled {
          let transcripts = state.transcriptionHistory.history
          
          // Clear the history
          state.$transcriptionHistory.withLock { history in
            history.history.removeAll()
          }

          return deleteAudioEffect(for: transcripts)
        }
        
        return .none

      case let .setMaxHistoryEntries(maxHistoryEntries):
        state.$hexSettings.withLock { $0.maxHistoryEntries = maxHistoryEntries }
        return .none

      case let .setModifierSide(kind, side):
        guard state.hexSettings.hotkey.key == nil else { return .none }
        state.$hexSettings.withLock {
          $0.hotkey.modifiers = $0.hotkey.modifiers.setting(kind: kind, to: side)
        }
        return .none

      case let .setWordRemovalsEnabled(enabled):
        state.$hexSettings.withLock { $0.wordRemovalsEnabled = enabled }
        return .none

      }
    }
  }
}
