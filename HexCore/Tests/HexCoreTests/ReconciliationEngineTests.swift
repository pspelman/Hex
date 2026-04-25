import XCTest
@testable import HexCore

final class ReconciliationEngineTests: XCTestCase {

	// MARK: - startSession

	func testStartSession_bumpsGenerationAndReturnsBeginSession() async {
		// Given
		let engine = ReconciliationEngine()

		// When
		let commands = await engine.startSession()

		// Then
		let generation = await engine.currentGeneration
		XCTAssertEqual(generation, 1)
		XCTAssertEqual(commands, [.beginSession(generation: 1)])
	}

	func testStartSession_calledTwice_incrementsGenerationEachTime() async {
		// Given
		let engine = ReconciliationEngine()

		// When
		_ = await engine.startSession()
		let commands = await engine.startSession()

		// Then
		let generation = await engine.currentGeneration
		XCTAssertEqual(generation, 2)
		XCTAssertEqual(commands, [.beginSession(generation: 2)])
	}

	// MARK: - ingest(.provisional)

	func testIngestProvisional_emitsApplyWithEmptyCommittedAndHypothesisAsTentative() async {
		// Given
		let engine = ReconciliationEngine()
		_ = await engine.startSession()
		let hypothesis = Hypothesis(revisionId: 1, text: "hello world")

		// When
		let commands = await engine.ingest(.provisional(hypothesis))

		// Then
		let expected = InjectionIntent(generation: 1, committed: "", tentative: "hello world")
		XCTAssertEqual(commands, [.apply(expected)])
	}

	func testIngestProvisional_secondProvisional_whenCoalesceEnabled_keepOnlyLatest() async {
		// Given — coalesceProvisionals is true by default
		let engine = ReconciliationEngine()
		_ = await engine.startSession()

		// When
		let first = Hypothesis(revisionId: 1, text: "the quick")
		let second = Hypothesis(revisionId: 2, text: "the quick brown")
		_ = await engine.ingest(.provisional(first))
		let commands = await engine.ingest(.provisional(second))

		// Then — only the latest tentative text is reflected; no finalize occurred
		let expected = InjectionIntent(generation: 1, committed: "", tentative: "the quick brown")
		XCTAssertEqual(commands, [.apply(expected)])
	}

	// MARK: - ingest(.finalize)

	func testIngestFinalize_promotesTextToCommitted_clearsTentative() async {
		// Given
		let engine = ReconciliationEngine()
		_ = await engine.startSession()

		let provisional = Hypothesis(revisionId: 1, text: "hello")
		_ = await engine.ingest(.provisional(provisional))

		// When
		let committed = CommittedText(revisionId: 2, text: "hello")
		let commands = await engine.ingest(.finalize(committed))

		// Then
		let expected = InjectionIntent(generation: 1, committed: "hello", tentative: "")
		XCTAssertEqual(commands, [.apply(expected)])
	}

	func testIngestFinalize_appendsToExistingCommitted() async {
		// Given
		let engine = ReconciliationEngine()
		_ = await engine.startSession()

		_ = await engine.ingest(.finalize(CommittedText(revisionId: 1, text: "first ")))

		// When
		let commands = await engine.ingest(.finalize(CommittedText(revisionId: 2, text: "second")))

		// Then
		let expected = InjectionIntent(generation: 1, committed: "first second", tentative: "")
		XCTAssertEqual(commands, [.apply(expected)])
	}

	// MARK: - Bounded queue + finalize-never-dropped

	func testBoundedQueue_burstOfProvisionals_finalizeIsNeverDropped() async {
		// Given — maxPendingProvisionals = 3; we push N=10 provisionals then one finalize
		let config = ReconciliationEngine.Configuration(maxPendingProvisionals: 3, coalesceProvisionals: true)
		let engine = ReconciliationEngine(configuration: config)
		_ = await engine.startSession()

		// Push 10 provisionals
		for i in 0..<10 {
			_ = await engine.ingest(.provisional(Hypothesis(revisionId: UInt64(i), text: "word\(i)")))
		}

		// When — finalize arrives after the burst
		let committed = CommittedText(revisionId: 10, text: "finalized")
		let commands = await engine.ingest(.finalize(committed))

		// Then — the finalize must not be dropped; committed reflects the finalized text
		let expected = InjectionIntent(generation: 1, committed: "finalized", tentative: "")
		XCTAssertEqual(commands, [.apply(expected)])
	}

	// MARK: - ingest(.retract)

	func testIngestRetract_dropsTrailingNTokensFromCommitted() async {
		// Given — committed is a 4-token string; we retract the last 2
		let engine = ReconciliationEngine()
		_ = await engine.startSession()
		_ = await engine.ingest(.finalize(CommittedText(revisionId: 1, text: "one two three four")))

		// When
		let commands = await engine.ingest(.retract(tokenRange: 0..<2))

		// Then — trailing 2 whitespace-split tokens ("three four") are removed
		let expected = InjectionIntent(generation: 1, committed: "one two", tentative: "")
		XCTAssertEqual(commands, [.apply(expected)])
	}

	// MARK: - Re-emitting the same InjectionIntent

	func testReEmittingSameInput_doesNotCrash_exactlyOneApplyPerIngest() async {
		// Given — the engine does not deduplicate; re-sending the same event returns one .apply
		let engine = ReconciliationEngine()
		_ = await engine.startSession()
		let hypothesis = Hypothesis(revisionId: 1, text: "hello")

		// When
		let first = await engine.ingest(.provisional(hypothesis))
		let second = await engine.ingest(.provisional(hypothesis))

		// Then — each ingest produces exactly one command; behavior is sane (no crash, no explosion)
		XCTAssertEqual(first.count, 1)
		XCTAssertEqual(second.count, 1)
		XCTAssertEqual(first, second)
	}

	// MARK: - endSession

	func testEndSession_emitsEndSessionWithCurrentGeneration() async {
		// Given
		let engine = ReconciliationEngine()
		_ = await engine.startSession()

		// When
		let commands = await engine.endSession()

		// Then
		XCTAssertEqual(commands, [.endSession(generation: 1)])
	}

	func testEndSession_subsequentIngest_isNoOp() async {
		// Given
		let engine = ReconciliationEngine()
		_ = await engine.startSession()
		_ = await engine.endSession()

		// When — ingest after endSession, before next startSession
		let commands = await engine.ingest(.provisional(Hypothesis(revisionId: 1, text: "ignored")))

		// Then
		XCTAssertTrue(commands.isEmpty)
	}

	// MARK: - abort

	func testAbort_emitsAbortCommand() async {
		// Given
		let engine = ReconciliationEngine()
		_ = await engine.startSession()

		// When
		let commands = await engine.abort(reason: .focusChanged)

		// Then
		XCTAssertEqual(commands, [.abort(reason: .focusChanged)])
	}

	func testAbort_subsequentIngest_isNoOpUntilNextStartSession() async {
		// Given
		let engine = ReconciliationEngine()
		_ = await engine.startSession()
		_ = await engine.abort(reason: .sessionCancelled)

		// When — ingesting after abort should be a no-op
		let commands = await engine.ingest(.provisional(Hypothesis(revisionId: 1, text: "ignored")))

		// Then
		XCTAssertTrue(commands.isEmpty)

		// But a new session should restore normal operation
		_ = await engine.startSession()
		let afterRestart = await engine.ingest(.provisional(Hypothesis(revisionId: 1, text: "active")))
		XCTAssertEqual(afterRestart.count, 1)
	}

	// MARK: - Session restart clears state

	func testStartSession_clearsPreviousCommittedText() async {
		// Given — accumulate some committed text in the first session
		let engine = ReconciliationEngine()
		_ = await engine.startSession()
		_ = await engine.ingest(.finalize(CommittedText(revisionId: 1, text: "session one text")))

		// When — start a new session
		_ = await engine.startSession()
		let commands = await engine.ingest(.provisional(Hypothesis(revisionId: 1, text: "fresh")))

		// Then — committed is cleared; tentative reflects only the new hypothesis
		let expected = InjectionIntent(generation: 2, committed: "", tentative: "fresh")
		XCTAssertEqual(commands, [.apply(expected)])
	}
}
