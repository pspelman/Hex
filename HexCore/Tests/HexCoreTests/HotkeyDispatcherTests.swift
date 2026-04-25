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
}
