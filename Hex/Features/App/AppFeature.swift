//
//  AppFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/26/25.
//

import AppKit
import ComposableArchitecture
import Dependencies
import HexCore
import SwiftUI

@Reducer
struct AppFeature {
  enum ActiveTab: Equatable {
    case settings
    case remappings
    case history
    case about
  }

	@ObservableState
	struct State {
		var transcription: TranscriptionFeature.State = .init()
		var liveTranscription: LiveTranscriptionFeature.State = .init()
		var settings: SettingsFeature.State = .init()
		var history: HistoryFeature.State = .init()
		var activeTab: ActiveTab = .settings
		@Shared(.hexSettings) var hexSettings: HexSettings
		@Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState

    // Shared dispatcher — owns one HotKeyProcessor per unique chord across all four slots.
    // Equatable conformance on HotkeyDispatcher compares only Configuration, which is
    // sufficient for TCA's state-diffing. Per-chord runtime state is excluded deliberately.
    // Wired to TranscriptionFeature (batch slots) in Task 3.2 and to
    // LiveTranscriptionFeature (live slots) in Task 3.3.
    var hotkeyDispatcher: HotkeyDispatcher = .init()

    // Permission state
    var microphonePermission: PermissionStatus = .notDetermined
    var accessibilityPermission: PermissionStatus = .notDetermined
    var inputMonitoringPermission: PermissionStatus = .notDetermined
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case transcription(TranscriptionFeature.Action)
    case liveTranscription(LiveTranscriptionFeature.Action)
    case settings(SettingsFeature.Action)
    case history(HistoryFeature.Action)
    case setActiveTab(ActiveTab)
    case task
    case pasteLastTranscript

    // Builds a Configuration from current hexSettings and applies it to hotkeyDispatcher.
    // Called at app launch and will be called after settings mutations in Phase 4.
    case syncHotkeyDispatcher

    // Permission actions
    case checkPermissions
    case permissionsUpdated(mic: PermissionStatus, acc: PermissionStatus, input: PermissionStatus)
    case appActivated
    case requestMicrophone
    case requestAccessibility
    case requestInputMonitoring
    case modelStatusEvaluated(Bool)
  }

  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.transcription) var transcription
  @Dependency(\.permissions) var permissions

  var body: some ReducerOf<Self> {
    BindingReducer()

    Scope(state: \.transcription, action: \.transcription) {
      TranscriptionFeature()
    }

    Scope(state: \.liveTranscription, action: \.liveTranscription) {
      LiveTranscriptionFeature()
    }

    Scope(state: \.settings, action: \.settings) {
      SettingsFeature()
    }

    Scope(state: \.history, action: \.history) {
      HistoryFeature()
    }

    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .syncHotkeyDispatcher:
        state.hotkeyDispatcher.configure(.init(
          liveHoldHotkey: state.hexSettings.liveHoldHotkey,
          liveDoubleTapHotkey: state.hexSettings.liveDoubleTapHotkey,
          batchHoldHotkey: state.hexSettings.batchHoldHotkey,
          batchDoubleTapHotkey: state.hexSettings.batchDoubleTapHotkey,
          minimumKeyTime: state.hexSettings.minimumKeyTime
        ))
        return .none

      case .task:
        return .merge(
          .send(.syncHotkeyDispatcher),
          startPasteLastTranscriptMonitoring(),
          startHotkeyDispatchEffect(),
          ensureSelectedModelReadiness(),
          startPermissionMonitoring(),
          .send(.liveTranscription(.task))
        )
        
      case .pasteLastTranscript:
        @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
        guard let lastTranscript = transcriptionHistory.history.first?.text else {
          return .none
        }
        return .run { _ in
          await pasteboard.paste(lastTranscript)
        }
        
      case .transcription(.modelMissing):
        HexLog.app.notice("Model missing - activating app and switching to settings")
        state.activeTab = .settings
        state.settings.shouldFlashModelSection = true
        return .run { send in
          await MainActor.run {
            HexLog.app.notice("Activating app for model missing")
            NSApplication.shared.activate(ignoringOtherApps: true)
          }
          try? await Task.sleep(for: .seconds(2))
          await send(.settings(.set(\.shouldFlashModelSection, false)))
        }

      case .transcription:
        return .none

      case .liveTranscription:
        return .none

      case .settings:
        return .none

      case .history(.navigateToSettings):
        state.activeTab = .settings
        return .none
      case .history:
        return .none
		case let .setActiveTab(tab):
			state.activeTab = tab
			return .none

      // Permission handling
      case .checkPermissions:
        return .run { send in
          async let mic = permissions.microphoneStatus()
          async let acc = permissions.accessibilityStatus()
          async let input = permissions.inputMonitoringStatus()
          await send(.permissionsUpdated(mic: mic, acc: acc, input: input))
        }

      case let .permissionsUpdated(mic, acc, input):
        state.microphonePermission = mic
        state.accessibilityPermission = acc
        state.inputMonitoringPermission = input
        return .none

      case .appActivated:
        // App became active - re-check permissions
        return .send(.checkPermissions)

      case .requestMicrophone:
        return .run { send in
          _ = await permissions.requestMicrophone()
          await send(.checkPermissions)
        }

      case .requestAccessibility:
        return .run { send in
          await permissions.requestAccessibility()
          // Poll for status change (macOS doesn't provide callback)
          for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(1))
            await send(.checkPermissions)
          }
        }

      case .requestInputMonitoring:
        return .run { send in
          _ = await permissions.requestInputMonitoring()
          for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(1))
            await send(.checkPermissions)
          }
        }

      case .modelStatusEvaluated:
        return .none
      }
    }
  }
  
  private func startPasteLastTranscriptMonitoring() -> Effect<Action> {
    .run { send in
      @Shared(.isSettingPasteLastTranscriptHotkey) var isSettingPasteLastTranscriptHotkey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings

      let token = keyEventMonitor.handleKeyEvent { keyEvent in
        // Skip if user is setting a hotkey
        if isSettingPasteLastTranscriptHotkey {
          return false
        }

        // Check if this matches the paste last transcript hotkey
        guard let pasteHotkey = hexSettings.pasteLastTranscriptHotkey,
              let key = keyEvent.key,
              key == pasteHotkey.key,
              keyEvent.modifiers.matchesExactly(pasteHotkey.modifiers) else {
          return false
        }

        // Trigger paste action - use MainActor to avoid escaping send
        MainActor.assumeIsolated {
          send(.pasteLastTranscript)
        }
        return true // Intercept the key event
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

  /// Central hotkey dispatch hub (Option A from the four-hotkey rebuild plan).
  ///
  /// Owns a local `HotkeyDispatcher` copy that is kept in sync with `hexSettings`
  /// on every event — the same pattern the old per-feature `HotKeyProcessor` used.
  /// `AppFeature.State.hotkeyDispatcher` stores the configuration; per-chord runtime
  /// state (activeSlot, processor timings) lives in the local copy so it can be
  /// mutated synchronously inside the CGEvent-tap callback.
  ///
  /// Batch-slot outcomes are forwarded to `TranscriptionFeature` via
  /// `.transcription(.dispatcherFired(slot:action:))`.
  /// Live-slot outcomes are no-ops until Task 3.3 wires `LiveTranscriptionFeature`.
  private func startHotkeyDispatchEffect() -> Effect<Action> {
    .run { send in
      @Shared(.isSettingHotKey) var isSettingHotKey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings

      // Local dispatcher copy — mutated synchronously inside the callback.
      // Re-configured on every event from the latest hexSettings.
      var dispatcher = HotkeyDispatcher()

      let token = keyEventMonitor.handleInputEvent { inputEvent in
        // Skip when the user is actively capturing a new hotkey chord.
        if isSettingHotKey { return false }

        // Keep the local dispatcher in sync with current settings.
        dispatcher.configure(.init(
          liveHoldHotkey: hexSettings.liveHoldHotkey,
          liveDoubleTapHotkey: hexSettings.liveDoubleTapHotkey,
          batchHoldHotkey: hexSettings.batchHoldHotkey,
          batchDoubleTapHotkey: hexSettings.batchDoubleTapHotkey,
          minimumKeyTime: hexSettings.minimumKeyTime
        ))

        switch inputEvent {
        case .keyboard(let keyEvent):
          let now = Date()
          let outcome = dispatcher.process(keyEvent: keyEvent, now: now)
          return Self.routeDispatchOutcome(outcome, send: send)

        case .mouseClick:
          let now = Date()
          let outcome = dispatcher.processMouseClick(now: now)
          _ = Self.routeDispatchOutcome(outcome, send: send)
          // Never intercept a mouse click — the user needs it to reach the target app.
          return false
        }
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

  /// Routes a `DispatchOutcome` to the appropriate child feature and returns the
  /// CGEvent-intercept flag (true = swallow the event, false = pass through).
  ///
  /// - Batch slots → `TranscriptionFeature.dispatcherFired`
  /// - Live slots → no-op until Task 3.3
  /// - Conflicts → no-op until Task 3.4 adds the UX log + cancel sound
  @discardableResult
  private static func routeDispatchOutcome(
    _ outcome: HotkeyDispatcher.DispatchOutcome,
    send: Send<Action>
  ) -> Bool {
    switch outcome {
    case let .fire(slot, slotAction):
      switch slot {
      case .batchHold, .batchDoubleTap:
        MainActor.assumeIsolated {
          send(.transcription(.dispatcherFired(slot: slot, action: slotAction)))
        }
        // Intercept only for stopRecording/cancel on a chord that has a key component —
        // for modifier-only chords the key-up events should pass through.
        return slotAction == .cancel
      case .liveHold, .liveDoubleTap:
        // Task 3.3 will wire these to LiveTranscriptionFeature.
        return false
      }

    case let .discard(slot):
      switch slot {
      case .batchHold, .batchDoubleTap:
        MainActor.assumeIsolated {
          send(.transcription(.dispatcherFired(slot: slot, action: .cancel)))
        }
        return false
      case .liveHold, .liveDoubleTap:
        return false
      }

    case .conflict:
      // Task 3.4 will add conflict UX (log + cancel sound).
      return false

    case .none:
      return false
    }
  }

  private func ensureSelectedModelReadiness() -> Effect<Action> {
    .run { send in
      @Shared(.hexSettings) var hexSettings: HexSettings
      @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
      let selectedModel = hexSettings.selectedModel
      guard !selectedModel.isEmpty else {
        await send(.modelStatusEvaluated(false))
        return
      }
      let isReady = await transcription.isModelDownloaded(selectedModel)
      $modelBootstrapState.withLock { state in
        state.modelIdentifier = selectedModel
        if state.modelDisplayName?.isEmpty ?? true {
          state.modelDisplayName = selectedModel
        }
        state.isModelReady = isReady
        if isReady {
          state.lastError = nil
          state.progress = 1
        } else {
          state.progress = 0
        }
      }
      await send(.modelStatusEvaluated(isReady))
    }
  }

  private func startPermissionMonitoring() -> Effect<Action> {
    .run { send in
      // Initial check on app launch
      await send(.checkPermissions)

      // Monitor app activation events
      for await activation in permissions.observeAppActivation() {
        if case .didBecomeActive = activation {
          await send(.appActivated)
        }
      }

    }
  }

}

struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>
  @State private var columnVisibility = NavigationSplitViewVisibility.automatic

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      List(selection: $store.activeTab) {
        Button {
          store.send(.setActiveTab(.settings))
        } label: {
          Label("Settings", systemImage: "gearshape")
        }
        .buttonStyle(.plain)
        .tag(AppFeature.ActiveTab.settings)

        Button {
          store.send(.setActiveTab(.remappings))
        } label: {
          Label("Transforms", systemImage: "text.badge.plus")
        }
        .buttonStyle(.plain)
        .tag(AppFeature.ActiveTab.remappings)

        Button {
          store.send(.setActiveTab(.history))
        } label: {
          Label("History", systemImage: "clock")
        }
        .buttonStyle(.plain)
        .tag(AppFeature.ActiveTab.history)

        Button {
          store.send(.setActiveTab(.about))
        } label: {
          Label("About", systemImage: "info.circle")
        }
        .buttonStyle(.plain)
        .tag(AppFeature.ActiveTab.about)
      }
    } detail: {
      switch store.state.activeTab {
      case .settings:
        SettingsView(
          store: store.scope(state: \.settings, action: \.settings),
          microphonePermission: store.microphonePermission,
          accessibilityPermission: store.accessibilityPermission,
          inputMonitoringPermission: store.inputMonitoringPermission
        )
        .navigationTitle("Settings")
      case .remappings:
        WordRemappingsView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("Transforms")
      case .history:
        HistoryView(store: store.scope(state: \.history, action: \.history))
          .navigationTitle("History")
      case .about:
        AboutView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("About")
      }
    }
    .enableInjection()
  }
}
