//
//  AXTextInjector.swift
//  Hex
//

import AppKit
import Foundation
import HexCore

private let injectionLog = HexLog.injection

/// Primary injection strategy: atomically replaces the tentative span in the focused
/// text field using the Accessibility API.
///
/// Thread-safety: all mutable state lives in the `SessionActor`; the outer class is a
/// thin, sendable wrapper so `CompositeTextInjector` can hold it across actor boundaries.
final class AXTextInjector: Sendable {

  enum AXTextInjectorError: Error, Sendable {
    /// No focused text element is reachable via the system-wide AX element.
    case noFocusedElement
    /// The focused element is a password field; injection is blocked for security.
    case passwordField
    /// An AX call failed with the given error code description.
    case unavailable(String)
    /// A session operation was attempted before `beginSession` was called.
    case sessionNotStarted
  }

  private let session = SessionActor()

  init() {}

  /// Non-destructive probe: attempts a zero-length attribute write on the current focus.
  ///
  /// Returns `false` if the AX permission is denied or no focusable element exists.
  /// Restores the selection after the probe.
  func probeWritable() async -> Bool {
    await session.probeWritable()
  }

  /// Begin a session: captures the focused element and anchor offset.
  func beginSession(generation: UInt64) async throws {
    try await session.begin(generation: generation)
  }

  /// Apply a declarative intent by replacing the tentative span atomically.
  func apply(_ intent: InjectionIntent) async throws {
    try await session.apply(intent)
  }

  /// End the session cleanly.
  func endSession(generation: UInt64) async {
    await session.end(generation: generation)
  }

  /// Abort immediately; clears session state.
  func abort(reason: AbortReason) async {
    await session.abort(reason: reason)
  }
}

// MARK: - SessionActor

/// Owns all mutable state for a single AX injection session.
private actor SessionActor {

  private var focusedElement: AXUIElement?
  private var anchorOffset: Int = 0
  private var previousFullLength: Int = 0
  private var previousFullText: String = ""
  private var currentGeneration: UInt64?

  // MARK: Probe

  func probeWritable() -> Bool {
    let systemWide = AXUIElementCreateSystemWide()
    var focusedRef: CFTypeRef?
    let fetchError = AXUIElementCopyAttributeValue(
      systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
    )
    guard fetchError == .success, let ref = focusedRef else {
      return false
    }
    let element = ref as! AXUIElement  // swiftlint:disable:this force_cast

    // Guard: skip password fields
    if isPasswordField(element) { return false }

    // Capture current selection so we can restore it
    var selRef: CFTypeRef?
    let selError = AXUIElementCopyAttributeValue(
      element, kAXSelectedTextRangeAttribute as CFString, &selRef
    )

    // Attempt a zero-length write
    let probeResult = AXUIElementSetAttributeValue(
      element, kAXSelectedTextAttribute as CFString, "" as CFTypeRef
    )

    // Restore selection if we read it successfully
    if selError == .success, let selRef {
      AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, selRef)
    }

    return probeResult == .success
  }

  // MARK: Session lifecycle

  func begin(generation: UInt64) throws {
    let systemWide = AXUIElementCreateSystemWide()
    var focusedRef: CFTypeRef?
    let fetchError = AXUIElementCopyAttributeValue(
      systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
    )

    guard fetchError == .success, let ref = focusedRef else {
      injectionLog.error("AXTextInjector: no focused element at session start")
      throw AXTextInjector.AXTextInjectorError.noFocusedElement
    }

    let element = ref as! AXUIElement  // swiftlint:disable:this force_cast

    if isPasswordField(element) {
      injectionLog.info("AXTextInjector: focused element is a password field — refusing session")
      throw AXTextInjector.AXTextInjectorError.passwordField
    }

    // Capture anchor: the character offset of the current insertion point
    var rangeRef: CFTypeRef?
    let rangeError = AXUIElementCopyAttributeValue(
      element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
    )

    var anchor = 0
    if rangeError == .success, let rangeRef {
      var cfRange = CFRange()
      if AXValueGetValue(rangeRef as! AXValue, .cfRange, &cfRange) {  // swiftlint:disable:this force_cast
        anchor = cfRange.location
      }
    }

    self.focusedElement = element
    self.anchorOffset = anchor
    self.previousFullLength = 0
    self.previousFullText = ""
    self.currentGeneration = generation

    injectionLog.debug(
      "AXTextInjector: session \(generation) started, anchor=\(anchor, privacy: .public)"
    )
  }

  func apply(_ intent: InjectionIntent) throws {
    guard let generation = currentGeneration, intent.generation == generation else {
      // Stale intent from a previous or mismatched session — silently drop
      injectionLog.debug(
        "AXTextInjector: dropping stale intent generation=\(intent.generation, privacy: .public)"
      )
      return
    }

    guard let element = focusedElement else {
      throw AXTextInjector.AXTextInjectorError.sessionNotStarted
    }

    let newFullText = intent.fullText

    // Idempotency: skip if the desired state is already rendered
    if newFullText == previousFullText {
      return
    }

    // Select the tentative span: (anchor, anchor + previousFullLength)
    var selectRange = CFRange(location: anchorOffset, length: previousFullLength)
    guard let rangeValue = AXValueCreate(.cfRange, &selectRange) else {
      throw AXTextInjector.AXTextInjectorError.unavailable("AXValueCreate returned nil")
    }

    let selectError = AXUIElementSetAttributeValue(
      element, kAXSelectedTextRangeAttribute as CFString, rangeValue
    )
    if selectError != .success {
      injectionLog.error(
        "AXTextInjector: failed to set selection range: \(selectError.rawValue, privacy: .public)"
      )
      throw AXTextInjector.AXTextInjectorError.unavailable(
        "kAXSelectedTextRangeAttribute error \(selectError.rawValue)"
      )
    }

    // Replace selection with new full text
    let writeError = AXUIElementSetAttributeValue(
      element, kAXSelectedTextAttribute as CFString, newFullText as CFTypeRef
    )
    if writeError != .success {
      injectionLog.error(
        "AXTextInjector: failed to write text: \(writeError.rawValue, privacy: .public)"
      )
      throw AXTextInjector.AXTextInjectorError.unavailable(
        "kAXSelectedTextAttribute error \(writeError.rawValue)"
      )
    }

    previousFullLength = newFullText.count
    previousFullText = newFullText
    injectionLog.debug(
      "AXTextInjector: applied intent, fullLength=\(newFullText.count, privacy: .public)"
    )
  }

  func end(generation: UInt64) {
    guard currentGeneration == generation else { return }
    injectionLog.debug("AXTextInjector: session \(generation) ended")
    resetState()
  }

  func abort(reason: AbortReason) {
    injectionLog.info("AXTextInjector: session aborted, reason=\(String(describing: reason), privacy: .public)")
    resetState()
  }

  // MARK: Helpers

  private func resetState() {
    focusedElement = nil
    anchorOffset = 0
    previousFullLength = 0
    previousFullText = ""
    currentGeneration = nil
  }

  private func isPasswordField(_ element: AXUIElement) -> Bool {
    var roleRef: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
    guard err == .success, let roleRef else { return false }
    return (roleRef as? String) == "AXSecureTextField"
  }
}
