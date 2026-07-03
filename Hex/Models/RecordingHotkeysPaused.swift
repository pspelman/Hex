import ComposableArchitecture

/// Whether the recording hotkeys (all four dispatcher slots) are currently paused.
///
/// In-memory by design: every launch starts unpaused so Hex can never be left
/// silently ignoring its hotkeys across restarts. The pause toggle hotkey and the
/// paste-last-transcript hotkey are unaffected by this flag.
extension SharedReaderKey where Self == InMemoryKey<Bool>.Default {
  static var recordingHotkeysPaused: Self {
    Self[.inMemory("recordingHotkeysPaused"), default: false]
  }
}
