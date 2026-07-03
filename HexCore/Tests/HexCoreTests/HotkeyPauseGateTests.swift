import XCTest
@testable import HexCore

/// Contract tests for `HotkeyPauseGate` — the outcome filter that implements
/// "pause recording hotkeys" without freezing dispatcher state.
///
/// Semantics under test:
/// - Unpaused: every outcome passes through untouched.
/// - Paused: `.startRecording` fires and `.conflict`s are suppressed (no new sessions,
///   no conflict sound), but stop/cancel/discard for a session started BEFORE the pause
///   still pass through so an in-flight recording can be finished normally.
/// - A stop/cancel/discard whose start was suppressed must also be dropped — otherwise a
///   phantom `.cancel` would swallow the user's ESC keypress while paused.
final class HotkeyPauseGateTests: XCTestCase {
	func testUnpausedPassesEverythingThrough() {
		var gate = HotkeyPauseGate()

		let outcomes: [HotkeyDispatcher.DispatchOutcome] = [
			.fire(slot: .batchHold, action: .startRecording),
			.fire(slot: .batchHold, action: .stopRecording),
			.fire(slot: .liveDoubleTap, action: .cancel),
			.discard(slot: .liveHold),
			.conflict(slots: [.batchHold, .liveHold], action: .startRecording),
			.none,
		]

		for outcome in outcomes {
			XCTAssertEqual(gate.filter(outcome, paused: false), outcome)
		}
	}

	func testPausedSuppressesStartRecording() {
		var gate = HotkeyPauseGate()

		let outcome = gate.filter(.fire(slot: .batchHold, action: .startRecording), paused: true)

		XCTAssertEqual(outcome, HotkeyDispatcher.DispatchOutcome.none)
	}

	func testPausedSuppressesConflict() {
		var gate = HotkeyPauseGate()

		let outcome = gate.filter(
			.conflict(slots: [.batchHold, .liveHold], action: .startRecording), paused: true
		)

		XCTAssertEqual(outcome, HotkeyDispatcher.DispatchOutcome.none)
	}

	func testStopForSuppressedStartIsDroppedWhilePaused() {
		var gate = HotkeyPauseGate()

		_ = gate.filter(.fire(slot: .batchHold, action: .startRecording), paused: true)
		let stop = gate.filter(.fire(slot: .batchHold, action: .stopRecording), paused: true)

		XCTAssertEqual(stop, HotkeyDispatcher.DispatchOutcome.none)
	}

	func testCancelForSuppressedStartIsDroppedAfterUnpause() {
		var gate = HotkeyPauseGate()

		// Start suppressed while paused; the matching cancel arrives after unpausing
		// (e.g. user unpauses mid-chord, then hits ESC) and must still be dropped.
		_ = gate.filter(.fire(slot: .liveHold, action: .startRecording), paused: true)
		let cancel = gate.filter(.fire(slot: .liveHold, action: .cancel), paused: false)

		XCTAssertEqual(cancel, HotkeyDispatcher.DispatchOutcome.none)
	}

	func testDiscardForSuppressedStartIsDropped() {
		var gate = HotkeyPauseGate()

		_ = gate.filter(.fire(slot: .batchDoubleTap, action: .startRecording), paused: true)
		let discard = gate.filter(.discard(slot: .batchDoubleTap), paused: true)

		XCTAssertEqual(discard, HotkeyDispatcher.DispatchOutcome.none)
	}

	func testStopForPrePauseSessionPassesThroughWhilePaused() {
		var gate = HotkeyPauseGate()

		// Session started before the pause (start passed through unpaused).
		let start = gate.filter(.fire(slot: .batchDoubleTap, action: .startRecording), paused: false)
		XCTAssertEqual(start, .fire(slot: .batchDoubleTap, action: .startRecording))

		// User pauses mid-recording; the stop double-tap must still work.
		let stop = gate.filter(.fire(slot: .batchDoubleTap, action: .stopRecording), paused: true)
		XCTAssertEqual(stop, .fire(slot: .batchDoubleTap, action: .stopRecording))
	}

	func testCancelForPrePauseSessionPassesThroughWhilePaused() {
		var gate = HotkeyPauseGate()

		_ = gate.filter(.fire(slot: .liveHold, action: .startRecording), paused: false)
		let cancel = gate.filter(.fire(slot: .liveHold, action: .cancel), paused: true)

		XCTAssertEqual(cancel, .fire(slot: .liveHold, action: .cancel))
	}

	func testSuppressionIsClearedByMatchingStopSoLaterStopsPass() {
		var gate = HotkeyPauseGate()

		// Suppressed start + its matching stop consume the ledger entry.
		_ = gate.filter(.fire(slot: .batchHold, action: .startRecording), paused: true)
		_ = gate.filter(.fire(slot: .batchHold, action: .stopRecording), paused: true)

		// A later real session on the same slot behaves normally.
		let start = gate.filter(.fire(slot: .batchHold, action: .startRecording), paused: false)
		XCTAssertEqual(start, .fire(slot: .batchHold, action: .startRecording))
		let stop = gate.filter(.fire(slot: .batchHold, action: .stopRecording), paused: false)
		XCTAssertEqual(stop, .fire(slot: .batchHold, action: .stopRecording))
	}

	func testUnpausedStartClearsStaleSuppression() {
		var gate = HotkeyPauseGate()

		// A suppressed double-tap promotion can leave the hold slot's ledger entry
		// orphaned (its stop routes to the promoted slot instead). The next real
		// start on that slot must clear the stale entry so its stop isn't dropped.
		_ = gate.filter(.fire(slot: .batchHold, action: .startRecording), paused: true)

		let start = gate.filter(.fire(slot: .batchHold, action: .startRecording), paused: false)
		XCTAssertEqual(start, .fire(slot: .batchHold, action: .startRecording))
		let stop = gate.filter(.fire(slot: .batchHold, action: .stopRecording), paused: false)
		XCTAssertEqual(stop, .fire(slot: .batchHold, action: .stopRecording))
	}

	func testNonePassesThroughWhilePaused() {
		var gate = HotkeyPauseGate()

		XCTAssertEqual(gate.filter(.none, paused: true), HotkeyDispatcher.DispatchOutcome.none)
	}
}
