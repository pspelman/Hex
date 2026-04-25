//
//  CompositeTextInjector.swift
//  Hex
//

import AppKit
import Foundation
import HexCore

private let injectionLog = HexLog.injection

/// Hides the AX-vs-CGEvent strategy choice from feature code.
///
/// On `beginSession`, probes AX writability with a zero-length write. If the probe
/// succeeds, the session is locked to `AXTextInjector`. Otherwise it falls back to
/// `CGEventTextInjector`. The choice is never exposed to callers and is never
/// switched mid-session (switching mid-session would double-write and corrupt the field).
final class CompositeTextInjector: Sendable {

  enum Strategy: String, Sendable {
    case ax
    case cgEvent
  }

  private let coordinator = Coordinator()

  init() {}

  /// Begin a session: probe AX and lock strategy for the session lifetime.
  func beginSession(generation: UInt64) async throws {
    try await coordinator.beginSession(generation: generation)
  }

  /// Apply a declarative intent to the focused element via the locked strategy.
  func apply(_ intent: InjectionIntent) async throws {
    try await coordinator.apply(intent)
  }

  /// End the session cleanly.
  func endSession(generation: UInt64) async {
    await coordinator.endSession(generation: generation)
  }

  /// Abort the session immediately.
  func abort(reason: AbortReason) async {
    await coordinator.abort(reason: reason)
  }

  /// Whether AX writing is available right now; used by Settings UI.
  func isAccessibilityWritable() async -> Bool {
    await coordinator.isAccessibilityWritable()
  }

  /// Current strategy, for diagnostics only.
  func currentStrategy() async -> Strategy? {
    await coordinator.currentStrategy
  }
}

// MARK: - Coordinator (actor)

private actor Coordinator {

  private let ax = AXTextInjector()
  private let cgEvent = CGEventTextInjector()

  private(set) var currentStrategy: CompositeTextInjector.Strategy?
  private var currentGeneration: UInt64?

  // MARK: Session lifecycle

  func beginSession(generation: UInt64) async throws {
    // Probe AX to decide strategy for this session
    let axWritable = await ax.probeWritable()
    let strategy: CompositeTextInjector.Strategy = axWritable ? .ax : .cgEvent
    currentStrategy = strategy
    currentGeneration = generation

    injectionLog.info(
      "CompositeTextInjector: session \(generation) using strategy=\(strategy.rawValue, privacy: .public)"
    )

    switch strategy {
    case .ax:
      try await ax.beginSession(generation: generation)
    case .cgEvent:
      try await cgEvent.beginSession(generation: generation)
    }
  }

  func apply(_ intent: InjectionIntent) async throws {
    guard let generation = currentGeneration, intent.generation == generation else {
      injectionLog.debug(
        "CompositeTextInjector: dropping intent for generation=\(intent.generation, privacy: .public), current=\(self.currentGeneration.map(String.init) ?? "nil", privacy: .public)"
      )
      return
    }

    switch currentStrategy {
    case .ax:
      do {
        try await ax.apply(intent)
      } catch AXTextInjector.AXTextInjectorError.passwordField {
        // Password field: propagate so the feature can abort cleanly.
        // We do NOT silently fall back to CGEvent — that would inject into a secure field.
        injectionLog.error(
          "CompositeTextInjector: AX apply hit password field — propagating to feature"
        )
        throw AXTextInjector.AXTextInjectorError.passwordField
      } catch AXTextInjector.AXTextInjectorError.unavailable(let msg) {
        // AX became unavailable mid-session. Switching to CGEvent here would double-write
        // any text the AX injector already placed. The safe choice is to abort.
        injectionLog.error(
          "CompositeTextInjector: AX apply unavailable mid-session (\(msg, privacy: .public)) — aborting"
        )
        await doAbort(reason: .error("AX unavailable mid-session: \(msg)"))
        throw AXTextInjector.AXTextInjectorError.unavailable(msg)
      }
    case .cgEvent:
      try await cgEvent.apply(intent)
    case .none:
      injectionLog.error("CompositeTextInjector: apply called with no active session")
    }
  }

  func endSession(generation: UInt64) async {
    guard currentGeneration == generation else { return }
    injectionLog.debug("CompositeTextInjector: ending session \(generation)")
    switch currentStrategy {
    case .ax:
      await ax.endSession(generation: generation)
    case .cgEvent:
      await cgEvent.endSession(generation: generation)
    case .none:
      break
    }
    resetState()
  }

  func abort(reason: AbortReason) async {
    await doAbort(reason: reason)
  }

  func isAccessibilityWritable() async -> Bool {
    await ax.probeWritable()
  }

  // MARK: Helpers

  /// Shared abort implementation used both by the public `abort` entry and by internal
  /// error handling that needs to abort without re-entering the actor lock.
  private func doAbort(reason: AbortReason) async {
    injectionLog.info(
      "CompositeTextInjector: aborting session, reason=\(String(describing: reason), privacy: .public)"
    )
    switch currentStrategy {
    case .ax:
      await ax.abort(reason: reason)
    case .cgEvent:
      await cgEvent.abort(reason: reason)
    case .none:
      break
    }
    resetState()
  }

  private func resetState() {
    currentStrategy = nil
    currentGeneration = nil
  }
}
