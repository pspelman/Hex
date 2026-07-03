import ComposableArchitecture
import Foundation
import Testing

@testable import Hex

@MainActor
struct PauseHotkeysTests {
  /// `.toggleRecordingHotkeysPaused` flips the shared in-memory flag both ways —
  /// the single mutation point used by the toggle hotkey and the menu bar item.
  ///
  /// Uses a plain `Store` rather than `TestStore` because `AppFeature.State` is not
  /// `Equatable` (TestStore requires it). The action runs no effects, so direct
  /// state inspection is sufficient.
  @Test
  func toggleFlipsSharedPausedFlag() {
    let store = Store(initialState: AppFeature.State()) {
      AppFeature()
    }

    #expect(store.withState(\.recordingHotkeysPaused) == false)

    store.send(.toggleRecordingHotkeysPaused)
    #expect(store.withState(\.recordingHotkeysPaused) == true)

    store.send(.toggleRecordingHotkeysPaused)
    #expect(store.withState(\.recordingHotkeysPaused) == false)
  }
}
