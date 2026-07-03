import AppKit
import ComposableArchitecture
import SwiftUI

/// Menu bar status-item icon that dims while the recording hotkeys are paused —
/// the at-a-glance indicator that Hex is deliberately not listening.
struct MenuBarIconView: View {
  @Shared(.recordingHotkeysPaused) var recordingHotkeysPaused: Bool

  private static let normalIcon: NSImage = makeIcon(alpha: 1.0)
  private static let pausedIcon: NSImage = makeIcon(alpha: 0.35)

  var body: some View {
    Image(nsImage: recordingHotkeysPaused ? Self.pausedIcon : Self.normalIcon)
  }

  private static func makeIcon(alpha: CGFloat) -> NSImage {
    let base = NSImage(named: "HexIcon")!
    let ratio = base.size.height / base.size.width
    let size = NSSize(width: 18 / ratio, height: 18)
    return NSImage(size: size, flipped: false) { rect in
      base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
      return true
    }
  }
}

/// Checkable menu item mirroring the pause-hotkeys toggle hotkey — the mouse path
/// to the same state. Routes through the AppFeature reducer so both paths share
/// one mutation point (and its logging).
struct MenuBarPauseHotkeysToggle: View {
  @Shared(.recordingHotkeysPaused) var recordingHotkeysPaused: Bool

  var body: some View {
    Toggle("Pause Recording Hotkeys", isOn: Binding(
      get: { recordingHotkeysPaused },
      set: { _ in HexApp.appStore.send(.toggleRecordingHotkeysPaused) }
    ))
  }
}
