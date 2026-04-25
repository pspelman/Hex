//
//  TextInjectionClient.swift
//  Hex
//

import AppKit
import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

/// TCA dependency client for live text injection into the focused text field.
///
/// The client is strategy-agnostic: the live implementation uses a `CompositeTextInjector`
/// that selects AX-primary or CGEvent-fallback at session-start time without exposing the
/// choice to feature code.
@DependencyClient
struct TextInjectionClient {
  /// Begin a live injection session.
  ///
  /// Probes the focused element and locks the chosen strategy for the session.
  /// Throws if no focused element is reachable AND CGEvent path is also unavailable.
  var beginSession: @Sendable (_ generation: UInt64) async throws -> Void = { _ in }

  /// Apply the desired post-state declaratively.
  ///
  /// Idempotent: re-applying the same intent with identical fields is a no-op.
  /// Implementations compute their own diff against last-rendered state.
  var apply: @Sendable (_ intent: InjectionIntent) async throws -> Void = { _ in }

  /// Mark the session ended cleanly.
  ///
  /// Subsequent applies are no-ops until the next `beginSession`.
  var endSession: @Sendable (_ generation: UInt64) async -> Void = { _ in }

  /// Abort the current session immediately.
  ///
  /// Best-effort cleanup; never throws.
  var abort: @Sendable (_ reason: AbortReason) async -> Void = { _ in }

  /// Probe whether AX writing is currently available without prompting.
  ///
  /// Used by the Settings UI to surface the Accessibility permission row.
  var isAccessibilityWritable: @Sendable () async -> Bool = { false }
}

extension TextInjectionClient: DependencyKey {
  static var liveValue: Self {
    let live = CompositeTextInjector()
    return Self(
      beginSession: { try await live.beginSession(generation: $0) },
      apply: { try await live.apply($0) },
      endSession: { await live.endSession(generation: $0) },
      abort: { await live.abort(reason: $0) },
      isAccessibilityWritable: { await live.isAccessibilityWritable() }
    )
  }
}

extension DependencyValues {
  var textInjection: TextInjectionClient {
    get { self[TextInjectionClient.self] }
    set { self[TextInjectionClient.self] = newValue }
  }
}
