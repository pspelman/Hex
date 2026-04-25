import Foundation

/// A declarative description of the on-screen text state the injector should achieve.
///
/// The injector owns the diff math; the core never issues imperative "type these chars" commands.
public struct InjectionIntent: Sendable, Equatable {
	/// Session generation. Intents from a stale generation are no-ops for the injector.
	public let generation: UInt64
	/// Text that is permanently committed — must never be retracted.
	public let committed: String
	/// Currently visible suffix that may still be revised.
	public let tentative: String

	public init(generation: UInt64, committed: String, tentative: String) {
		self.generation = generation
		self.committed = committed
		self.tentative = tentative
	}

	/// Full on-screen text: committed prefix + tentative suffix.
	public var fullText: String { committed + tentative }
}

/// The reason a live injection session is being aborted.
public enum AbortReason: Sendable, Equatable {
	case focusChanged
	case userInteraction
	case sessionCancelled
	case error(String)
}

/// A command emitted by the `ReconciliationEngine` for the text injector to execute.
public enum InjectionCommand: Sendable, Equatable {
	/// Open a new injection session with the given generation counter.
	case beginSession(generation: UInt64)
	/// Apply a declarative desired-state intent to the focused text field.
	case apply(InjectionIntent)
	/// Close the current injection session cleanly.
	case endSession(generation: UInt64)
	/// Abort the session immediately for the given reason.
	case abort(reason: AbortReason)
}
