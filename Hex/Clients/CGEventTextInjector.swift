//
//  CGEventTextInjector.swift
//  Hex
//

import AppKit
import CoreGraphics
import Foundation
import HexCore

private let injectionLog = HexLog.injection

/// Fallback injection strategy using synthetic keyboard events.
///
/// Computes a character-level LCP diff against its last-rendered string and emits
/// backspace events for the diverged suffix, then Unicode `keyboardSetUnicodeString`
/// events for the replacement text.
///
/// Thread-safety: all mutable state is contained in `StateActor`.
final class CGEventTextInjector: Sendable {

  enum CGEventTextInjectorError: Error, Sendable {
    /// Could not create a `CGEventSource` — unexpected on any macOS version we target.
    case eventSourceUnavailable
  }

  private let state = StateActor()

  init() {}

  /// Begin a session: snapshots `lastRendered` as empty.
  func beginSession(generation: UInt64) async throws {
    await state.begin(generation: generation)
  }

  /// Apply a declarative intent via backspace + Unicode injection.
  func apply(_ intent: InjectionIntent) async throws {
    try await state.apply(intent)
  }

  /// End the session cleanly.
  func endSession(generation: UInt64) async {
    await state.end(generation: generation)
  }

  /// Abort — clears `lastRendered` without attempting retraction.
  ///
  /// Retracting after a focus change would corrupt the newly-focused element.
  func abort(reason: AbortReason) async {
    await state.abort(reason: reason)
  }
}

// MARK: - StateActor

private actor StateActor {

  private var lastRendered: String = ""
  private var currentGeneration: UInt64?

  // Virtual key code for the Delete (Backspace) key
  private static let backspaceKeyCode: CGKeyCode = 51

  // Threshold for "burst mode" — suffixes at or below this length skip inter-event sleep
  private static let burstThreshold = 3

  // MARK: Session lifecycle

  func begin(generation: UInt64) {
    lastRendered = ""
    currentGeneration = generation
    injectionLog.debug("CGEventTextInjector: session \(generation) started")
  }

  func apply(_ intent: InjectionIntent) async throws {
    guard let generation = currentGeneration, intent.generation == generation else {
      injectionLog.debug(
        "CGEventTextInjector: dropping stale intent generation=\(intent.generation, privacy: .public)"
      )
      return
    }

    let newFullText = intent.fullText

    // Idempotency: nothing to do
    guard newFullText != lastRendered else { return }

    // Use `.privateState` so the source does NOT inherit the user's currently-held modifier
    // keys. Live transcription is always invoked while the user is holding their hotkey
    // (commonly modifier-only chords like Option+Ctrl+Shift). With `.combinedSessionState`,
    // every synthesized character carries those modifier flags and the focused app
    // interprets each keystroke as an unbound shortcut and silently drops it.
    guard let source = CGEventSource(stateID: .privateState) else {
      throw CGEventTextInjector.CGEventTextInjectorError.eventSourceUnavailable
    }

    // Compute common prefix length (character-level, not scalar-level — matches Swift's
    // Character granularity so emoji and combined graphemes don't split mid-retract)
    let commonPrefixLen = zip(lastRendered, newFullText)
      .prefix(while: { $0.0 == $0.1 })
      .count

    let backspaceCount = lastRendered.count - commonPrefixLen
    let suffixStartIndex = newFullText.index(newFullText.startIndex, offsetBy: commonPrefixLen)
    let suffix = String(newFullText[suffixStartIndex...])

    injectionLog.debug(
      "CGEventTextInjector: backspaces=\(backspaceCount, privacy: .public) suffix=\(suffix.count, privacy: .public) chars"
    )

    // Emit backspaces
    for _ in 0 ..< backspaceCount {
      postBackspace(source: source)
    }

    // Emit Unicode events for the new suffix
    let useBurst = suffix.count <= Self.burstThreshold
    await postUnicodeString(suffix, source: source, burst: useBurst)

    lastRendered = newFullText
  }

  func end(generation: UInt64) {
    guard currentGeneration == generation else { return }
    injectionLog.debug("CGEventTextInjector: session \(generation) ended")
    resetState()
  }

  func abort(reason: AbortReason) {
    injectionLog.info(
      "CGEventTextInjector: session aborted, reason=\(String(describing: reason), privacy: .public)"
    )
    // Do NOT retract: the focus may have changed and retracting would corrupt the wrong field.
    resetState()
  }

  // MARK: CGEvent helpers

  /// Post a single backspace key-down + key-up pair.
  ///
  /// `flags` is explicitly cleared on each event so the user's physically-held hotkey
  /// modifiers don't combine with the synthetic backspace (which would turn it into
  /// Option+Backspace = "delete word", etc.).
  private func postBackspace(source: CGEventSource) {
    let down = CGEvent(keyboardEventSource: source, virtualKey: Self.backspaceKeyCode, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: Self.backspaceKeyCode, keyDown: false)
    down?.flags = []
    up?.flags = []
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
  }

  /// Post the entire suffix as a *single* multi-character Unicode key event.
  ///
  /// `keyboardSetUnicodeString` accepts a UTF-16 buffer of any length, and posting one
  /// event with the whole suffix avoids per-character autocomplete pop-ups (VS Code
  /// IntelliSense, Slack `@` mentions, Xcode completion, etc.) that intercept a few
  /// characters mid-typing. With per-char posting, IntelliSense triggers on the first
  /// matching prefix and eats the rest of the suffix; one combined event lands as a
  /// single text-input transaction so any popup only triggers after all chars are in.
  ///
  /// The `burst` parameter is retained for API stability but is now a no-op — there's
  /// only one event to post regardless of suffix length.
  private func postUnicodeString(_ text: String, source: CGEventSource, burst: Bool) async {
    guard !text.isEmpty else { return }

    let utf16 = Array(text.utf16)
    let length = utf16.count

    let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
    // Clear modifier flags — see `postBackspace` for the full reasoning. Without this,
    // synthesized text becomes <held-modifiers>+<chars> and is dropped as a shortcut.
    down?.flags = []
    up?.flags = []

    utf16.withUnsafeBufferPointer { buffer in
      down?.keyboardSetUnicodeString(stringLength: length, unicodeString: buffer.baseAddress)
      up?.keyboardSetUnicodeString(stringLength: length, unicodeString: buffer.baseAddress)
    }

    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
  }

  // MARK: State reset

  private func resetState() {
    lastRendered = ""
    currentGeneration = nil
  }
}
