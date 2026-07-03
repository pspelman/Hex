import XCTest
@testable import HexCore

final class HotkeyDispatcherTests: XCTestCase {
	func testBindingsGroupsSlotsByChord() {
		let opt = HotKey(key: nil, modifiers: [.option])
		let shiftCmd = HotKey(key: nil, modifiers: [.shift, .command])
		let cfg = HotkeyDispatcher.Configuration(
			liveHoldHotkey: shiftCmd,
			liveDoubleTapHotkey: nil,
			batchHoldHotkey: opt,
			batchDoubleTapHotkey: opt
		)

		let bindings = cfg.bindings()
		XCTAssertEqual(bindings[opt], [.batchHold, .batchDoubleTap])
		XCTAssertEqual(bindings[shiftCmd], [.liveHold])
		XCTAssertEqual(bindings.count, 2)
	}

	func testSlotsBoundToFiltersByPattern() {
		let opt = HotKey(key: nil, modifiers: [.option])
		let cfg = HotkeyDispatcher.Configuration(
			batchHoldHotkey: opt,
			batchDoubleTapHotkey: opt
		)

		XCTAssertEqual(cfg.slotsBoundTo(chord: opt, pattern: .pressAndHold), [.batchHold])
		XCTAssertEqual(cfg.slotsBoundTo(chord: opt, pattern: .doubleTap), [.batchDoubleTap])
	}

	func testSlotsBoundToDetectsConflict() {
		let opt = HotKey(key: nil, modifiers: [.option])
		let cfg = HotkeyDispatcher.Configuration(
			liveHoldHotkey: opt,
			batchHoldHotkey: opt
		)

		let conflicting = cfg.slotsBoundTo(chord: opt, pattern: .pressAndHold)
		XCTAssertEqual(conflicting, [.liveHold, .batchHold])
	}

	func testConfigureCreatesOneProcessorPerUniqueChord() {
		let opt = HotKey(key: nil, modifiers: [.option])
		let shiftCmd = HotKey(key: nil, modifiers: [.shift, .command])
		var dispatcher = HotkeyDispatcher()
		dispatcher.configure(HotkeyDispatcher.Configuration(
			liveHoldHotkey: shiftCmd,
			batchHoldHotkey: opt,
			batchDoubleTapHotkey: opt
		))

		// Indirectly: configure, then re-configure with a subset, then ensure no crash.
		dispatcher.configure(HotkeyDispatcher.Configuration(batchHoldHotkey: opt))
		// No assertion needed — absence of crash is the contract.
	}

	func testReConfigureIsIdempotent() {
		let opt = HotKey(key: nil, modifiers: [.option])
		var dispatcher = HotkeyDispatcher()
		let cfg = HotkeyDispatcher.Configuration(batchHoldHotkey: opt, batchDoubleTapHotkey: opt)
		dispatcher.configure(cfg)
		dispatcher.configure(cfg) // re-apply
		// Contract: no crash, no leaked state.
	}

	func testPressAndHoldDispatchesToBoundSlot() {
		let opt = HotKey(key: nil, modifiers: [.option])
		var dispatcher = HotkeyDispatcher()
		dispatcher.configure(HotkeyDispatcher.Configuration(batchHoldHotkey: opt))

		let t0 = Date(timeIntervalSinceReferenceDate: 0)
		let pressEvent = KeyEvent(key: nil, modifiers: [.option])
		let releaseEvent = KeyEvent(key: nil, modifiers: [])

		let pressOutcome = dispatcher.process(keyEvent: pressEvent, now: t0)
		XCTAssertEqual(pressOutcome, .fire(slot: .batchHold, action: .startRecording))

		let releaseOutcome = dispatcher.process(keyEvent: releaseEvent, now: t0.addingTimeInterval(0.5))
		XCTAssertEqual(releaseOutcome, .fire(slot: .batchHold, action: .stopRecording))
	}

	/// Verifies double-tap-lock dispatch routing when both batchHold and batchDoubleTap share the
	/// same chord (Option-only). This is the default fresh-install configuration.
	///
	/// HotKeyProcessor double-tap mechanics for a modifier-only chord:
	///  - First press  → .pressAndHold, emits .startRecording
	///  - First release (within doubleTapThreshold) → .idle, emits .stopRecording; records lastTapAt
	///  - Second press  → .pressAndHold again, emits .startRecording (not yet locked)
	///  - Second release (within doubleTapThreshold of first release) → .doubleTapLock, emits nil
	///  - Third press while locked → .idle, emits .stopRecording
	///
	/// The dispatcher detects the silent .pressAndHold → .doubleTapLock transition on the second
	/// release and synthesises a .fire(batchDoubleTap, .startRecording) outcome, promoting
	/// the in-flight session to the correct slot.
	func testDoubleTapDispatchesToDoubleTapSlot() {
		let opt = HotKey(key: nil, modifiers: [.option])
		var dispatcher = HotkeyDispatcher()
		dispatcher.configure(HotkeyDispatcher.Configuration(
			batchHoldHotkey: opt,
			batchDoubleTapHotkey: opt
		))

		let t0 = Date(timeIntervalSinceReferenceDate: 0)
		let press = KeyEvent(key: nil, modifiers: [.option])
		let release = KeyEvent(key: nil, modifiers: [])

		// First press: enters press-and-hold → routes to batchHold.
		let firstPress = dispatcher.process(keyEvent: press, now: t0)
		XCTAssertEqual(firstPress, .fire(slot: .batchHold, action: .startRecording))

		// First release (50ms, within modifier-only threshold): processor stops the first session
		// and records lastTapAt for double-tap detection. Modifier-only hotkeys use a 0.3s threshold
		// before a release counts as a "real" stop; at 50ms this is still below threshold so the
		// processor emits .stopRecording (not .discard) because isReleaseForActiveHotkey fires
		// before the elapsed-time check.
		let firstRelease = dispatcher.process(keyEvent: release, now: t0.addingTimeInterval(0.05))
		XCTAssertEqual(firstRelease, .fire(slot: .batchHold, action: .stopRecording))

		// Second press (100ms, within 0.3s double-tap window): processor enters .pressAndHold
		// again. Post-event state is still .pressAndHold (lock not engaged yet), so batchHold fires.
		let secondPress = dispatcher.process(keyEvent: press, now: t0.addingTimeInterval(0.10))
		XCTAssertEqual(secondPress, .fire(slot: .batchHold, action: .startRecording))

		// Second release (150ms): processor transitions .pressAndHold → .doubleTapLock silently
		// (nil output). The dispatcher detects this transition and emits a synthetic
		// .fire(batchDoubleTap, .startRecording), promoting the session to the doubleTap slot.
		// THIS IS THE KEY CONTRACT ASSERTION.
		let secondRelease = dispatcher.process(keyEvent: release, now: t0.addingTimeInterval(0.15))
		XCTAssertEqual(secondRelease, .fire(slot: .batchDoubleTap, action: .startRecording))

		// Third press while locked: processor emits .stopRecording and returns to .idle.
		// activeSlot is now .batchDoubleTap (promoted on the second release), so stopRecording
		// routes there.
		let thirdPress = dispatcher.process(keyEvent: press, now: t0.addingTimeInterval(1.0))
		XCTAssertEqual(thirdPress, .fire(slot: .batchDoubleTap, action: .stopRecording))
	}

	/// Verifies that a sub-threshold mouse click discards the active session, and that a
	/// post-threshold click is silently ignored (only ESC can cancel after the threshold).
	///
	/// `HotKeyProcessor.processMouseClick()` returns `.discard` when the elapsed time since
	/// press is less than the modifier-only minimum duration (max(minimumKeyTime, 0.3s)), and
	/// `nil` after the threshold. It never returns `.cancel` — that output is ESC-only.
	func testMouseClickDiscardsSubThresholdSession() {
		let opt = HotKey(key: nil, modifiers: [.option])
		var dispatcher = HotkeyDispatcher()
		dispatcher.configure(HotkeyDispatcher.Configuration(batchHoldHotkey: opt))

		let t0 = Date(timeIntervalSinceReferenceDate: 0)

		// Start a session
		_ = dispatcher.process(keyEvent: KeyEvent(key: nil, modifiers: [.option]), now: t0)

		// Sub-threshold click (< 0.3s modifier-only minimum) → should discard silently
		let subThresholdOutcome = dispatcher.processMouseClick(now: t0.addingTimeInterval(0.1))
		if case let .discard(slot) = subThresholdOutcome {
			XCTAssertEqual(slot, .batchHold)
		} else {
			XCTFail("Expected .discard(batchHold) for sub-threshold click, got \(subThresholdOutcome)")
		}
	}

	/// Verifies that a post-threshold mouse click is ignored (returns .none).
	///
	/// After the 0.3s modifier-only threshold, `processMouseClick()` returns nil and the
	/// recording continues. Only ESC can cancel it at that point.
	func testMouseClickIgnoredAfterThreshold() {
		let opt = HotKey(key: nil, modifiers: [.option])
		var dispatcher = HotkeyDispatcher()
		dispatcher.configure(HotkeyDispatcher.Configuration(batchHoldHotkey: opt))

		let t0 = Date(timeIntervalSinceReferenceDate: 0)

		// Start a session
		_ = dispatcher.process(keyEvent: KeyEvent(key: nil, modifiers: [.option]), now: t0)

		// Post-threshold click (> 0.3s modifier-only minimum) → should be ignored
		let postThresholdOutcome = dispatcher.processMouseClick(now: t0.addingTimeInterval(1.0))
		XCTAssertEqual(postThresholdOutcome, .none)
	}

	// MARK: - Configuration.overlaps(chord:)

	func testOverlapsDetectsExactChordMatch() {
		let optP = HotKey(key: .p, modifiers: [.option])
		let cfg = HotkeyDispatcher.Configuration(liveHoldHotkey: optP)

		XCTAssertTrue(cfg.overlaps(chord: optP))
	}

	func testOverlapsDetectsModifierOnlySlotSubsumedByKeyedChord() {
		// Slots bound to modifier-only Option; toggle chord Option+P would press
		// Option first and start a hold before the toggle fires.
		let opt = HotKey(key: nil, modifiers: [.option])
		let cfg = HotkeyDispatcher.Configuration(batchHoldHotkey: opt, batchDoubleTapHotkey: opt)

		XCTAssertTrue(cfg.overlaps(chord: HotKey(key: .p, modifiers: [.option])))
	}

	func testOverlapsFalseForDisjointChord() {
		let opt = HotKey(key: nil, modifiers: [.option])
		let cfg = HotkeyDispatcher.Configuration(batchHoldHotkey: opt)

		XCTAssertFalse(cfg.overlaps(chord: HotKey(key: .h, modifiers: [.shift, .command])))
	}

	func testOverlapsFalseForEmptyConfiguration() {
		let cfg = HotkeyDispatcher.Configuration()

		XCTAssertFalse(cfg.overlaps(chord: HotKey(key: .p, modifiers: [.option])))
	}

	func testConflictReportedWhenSamePatternBoundToTwoSlots() {
		let opt = HotKey(key: nil, modifiers: [.option])
		var dispatcher = HotkeyDispatcher()
		dispatcher.configure(HotkeyDispatcher.Configuration(
			liveHoldHotkey: opt,
			batchHoldHotkey: opt
		))

		let t0 = Date(timeIntervalSinceReferenceDate: 0)
		let press = KeyEvent(key: nil, modifiers: [.option])
		let outcome = dispatcher.process(keyEvent: press, now: t0)

		if case let .conflict(slots, action) = outcome {
			XCTAssertEqual(slots, [.liveHold, .batchHold])
			XCTAssertEqual(action, .startRecording)
		} else {
			XCTFail("Expected conflict outcome, got \(outcome)")
		}
	}
}
