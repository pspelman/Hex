import Foundation

/// A typed event emitted by the upstream streaming ASR client.
///
/// The event stream is the contract between the ASR layer and the reconciliation engine.
/// v1 emits `.finalize` from EOU callbacks and `.provisional` from per-chunk partials.
/// `.retract` is reserved for recovery paths and explicit abort scenarios.
public enum TranscriptionEvent: Sendable, Equatable {
	/// A partial hypothesis that may still be revised.
	case provisional(Hypothesis)
	/// A finalized transcript segment — immutable from this revision forward.
	case finalize(CommittedText)
	/// A retraction of a token range from the committed buffer.
	case retract(tokenRange: Range<Int>)
}

/// A partial hypothesis from the streaming ASR model.
public struct Hypothesis: Sendable, Equatable {
	/// Monotonic revision counter, scoped to the current session.
	public let revisionId: UInt64
	/// The full accumulated transcript text at this revision.
	public let text: String
	/// Model-reported confidence in stability. 0 if unavailable.
	public let stability: Double

	public init(revisionId: UInt64, text: String, stability: Double = 0) {
		self.revisionId = revisionId
		self.text = text
		self.stability = stability
	}
}

/// A finalized transcript segment that will not be revised.
public struct CommittedText: Sendable, Equatable {
	/// Monotonic revision counter, scoped to the current session.
	public let revisionId: UInt64
	/// The finalized transcript text.
	public let text: String

	public init(revisionId: UInt64, text: String) {
		self.revisionId = revisionId
		self.text = text
	}
}
