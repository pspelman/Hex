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

    guard let source = CGEventSource(stateID: .combinedSessionState) else {
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
  private func postBackspace(source: CGEventSource) {
    let down = CGEvent(keyboardEventSource: source, virtualKey: Self.backspaceKeyCode, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: Self.backspaceKeyCode, keyDown: false)
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
  }

  /// Post Unicode key events for the entire suffix string.
  ///
  /// Each Swift `Character` is posted as a keyDown+keyUp pair using
  /// `keyboardSetUnicodeString`, which handles multi-scalar grapheme clusters correctly.
  /// Burst mode skips the inter-event sleep for short suffixes to reduce latency.
  private func postUnicodeString(_ text: String, source: CGEventSource, burst: Bool) async {
    for character in text {
      // Encode the character as UTF-16 code units (required by keyboardSetUnicodeString)
      let utf16 = Array(character.utf16)
      let length = utf16.count

      let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)

      utf16.withUnsafeBufferPointer { buffer in
        down?.keyboardSetUnicodeString(stringLength: length, unicodeString: buffer.baseAddress)
        up?.keyboardSetUnicodeString(stringLength: length, unicodeString: buffer.baseAddress)
      }

      down?.post(tap: .cghidEventTap)
      up?.post(tap: .cghidEventTap)

      // Pace non-burst events to avoid coalescing in apps with fast-typing guards.
      // The actor suspends here which is safe: the Task that called apply() suspends,
      // and no other actor caller can interleave during this wait because actor reentrancy
      // only occurs at suspension points with no competing callers to the same actor.
      //
      // NOTE: If an apply() is called while we are sleeping here, it will queue behind
      // the current invocation. The CompositeTextInjector's generation check prevents
      // stale intents from executing after a session ends, but within a session, rapid
      // concurrent applies may still queue. The upstream ReconciliationEngine's coalesce
      // policy should prevent this in practice.
      if !burst {
        // 1ms sleep keeps inter-event pacing without visible latency
        try? await Task.sleep(nanoseconds: 1_000_000)
      }
    }
  }

  // MARK: State reset

  private func resetState() {
    lastRendered = ""
    currentGeneration = nil
  }
}
