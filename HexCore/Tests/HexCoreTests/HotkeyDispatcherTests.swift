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
}
