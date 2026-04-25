import Foundation

/// The pure middle stage of the live-transcription pipeline.
///
/// Sits between the upstream `AsyncStream<TranscriptionEvent>` from the ASR client and the
/// downstream `TextInjectionClient`. Owns the commit/coalesce/backpressure policy so that
/// the TCA feature and the injector remain oblivious to those concerns.
///
/// The actor serializes all access — callers must use `await` on every method.
public actor ReconciliationEngine {

	// MARK: - Configuration

	/// Tuning knobs for the engine's backpressure and coalescing policy.
	public struct Configuration: Sendable, Equatable {
		/// Maximum number of pending provisional events in the internal queue.
		/// Older provisionals are dropped when this limit is exceeded after coalescing.
		public var maxPendingProvisionals: Int
		/// When true, a newer provisional collapses all queued provisionals into itself.
		public var coalesceProvisionals: Bool

		public init(
			maxPendingProvisionals: Int = 3,
			coalesceProvisionals: Bool = true
		) {
			self.maxPendingProvisionals = maxPendingProvisionals
			self.coalesceProvisionals = coalesceProvisionals
		}
	}

	// MARK: - Private State

	private let configuration: Configuration
	private var generation: UInt64 = 0
	private var lastCommitted: String = ""
	/// Pending provisionals — bounded by `configuration.maxPendingProvisionals` after coalescing.
	private var pendingProvisionals: [Hypothesis] = []
	/// Tracks whether the session is active; false after endSession/abort until next startSession.
	private var isSessionActive: Bool = false

	// MARK: - Init

	/// Creates a new engine with the given configuration.
	public init(configuration: Configuration = .init()) {
		self.configuration = configuration
	}

	// MARK: - Public API

	/// The current session generation counter.
	public var currentGeneration: UInt64 { generation }

	/// Opens a fresh session, bumps the monotonic generation counter, and clears in-flight state.
	///
	/// Returns a single `.beginSession` command. Call this before pushing any events.
	public func startSession() -> [InjectionCommand] {
		generation &+= 1
		lastCommitted = ""
		pendingProvisionals = []
		isSessionActive = true
		return [.beginSession(generation: generation)]
	}

	/// Consumes one upstream event and returns zero or more downstream commands.
	///
	/// - Returns: An empty array when the session is not active (after `endSession` or `abort`).
	/// - Note: Revision IDs from upstream are informational. The engine's *generation* counter is the
	///   session boundary and is only bumped by `startSession()`. Stale revision IDs from a racing
	///   upstream are accepted here; the injector uses the generation to discard truly stale intents.
	public func ingest(_ event: TranscriptionEvent) -> [InjectionCommand] {
		guard isSessionActive else { return [] }

		switch event {
		case .provisional(let hypothesis):
			return ingestProvisional(hypothesis)

		case .finalize(let committed):
			return ingestFinalize(committed)

		case .retract(let tokenRange):
			return ingestRetract(tokenRange: tokenRange)
		}
	}

	/// Ends the session cleanly. Clears in-flight state and returns an `.endSession` command.
	public func endSession() -> [InjectionCommand] {
		guard isSessionActive else { return [] }
		isSessionActive = false
		pendingProvisionals = []
		let g = generation
		return [.endSession(generation: g)]
	}

	/// Aborts the session immediately. Returns an `.abort` command.
	public func abort(reason: AbortReason) -> [InjectionCommand] {
		guard isSessionActive else { return [] }
		isSessionActive = false
		pendingProvisionals = []
		return [.abort(reason: reason)]
	}

	// MARK: - Private Helpers

	private func ingestProvisional(_ hypothesis: Hypothesis) -> [InjectionCommand] {
		if configuration.coalesceProvisionals {
			// Collapse all queued provisionals into this latest one.
			pendingProvisionals = [hypothesis]
		} else {
			pendingProvisionals.append(hypothesis)
			// Drop oldest when over the bounded limit (finalize is never in this queue).
			while pendingProvisionals.count > configuration.maxPendingProvisionals {
				pendingProvisionals.removeFirst()
			}
		}

		let intent = InjectionIntent(
			generation: generation,
			committed: lastCommitted,
			tentative: hypothesis.text
		)
		return [.apply(intent)]
	}

	private func ingestFinalize(_ committed: CommittedText) -> [InjectionCommand] {
		// Finalize is never dropped — evict pending provisionals to make room conceptually.
		pendingProvisionals = []
		lastCommitted += committed.text

		let intent = InjectionIntent(
			generation: generation,
			committed: lastCommitted,
			tentative: ""
		)
		return [.apply(intent)]
	}

	private func ingestRetract(tokenRange: Range<Int>) -> [InjectionCommand] {
		// Heuristic: tokenize lastCommitted by whitespace splitting.
		// This is an approximation — a more sophisticated tokenizer can replace this in v2.
		let tokenCount = tokenRange.count
		var tokens = lastCommitted.split(
			separator: " ",
			maxSplits: .max,
			omittingEmptySubsequences: false
		).map(String.init)

		if tokenCount > 0 && tokenCount <= tokens.count {
			tokens.removeLast(tokenCount)
		}
		lastCommitted = tokens.joined(separator: " ")

		let intent = InjectionIntent(
			generation: generation,
			committed: lastCommitted,
			tentative: ""
		)
		return [.apply(intent)]
	}
}
