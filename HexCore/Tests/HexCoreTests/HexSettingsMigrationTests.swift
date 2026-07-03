import XCTest
@testable import HexCore

final class HexSettingsMigrationTests: XCTestCase {
	func testV1FixtureMigratesToCurrentDefaults() throws {
		let data = try loadFixture(named: "v1")
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)

		XCTAssertEqual(decoded.recordingAudioBehavior, .pauseMedia, "Legacy pauseMediaOnRecord bool should map to pauseMedia behavior")
		XCTAssertEqual(decoded.soundEffectsEnabled, false)
		XCTAssertEqual(decoded.soundEffectsVolume, HexSettings.baseSoundEffectsVolume)
		XCTAssertEqual(decoded.openOnLogin, true)
		XCTAssertEqual(decoded.showDockIcon, false)
		XCTAssertEqual(decoded.selectedModel, "whisper-large-v3")
		XCTAssertEqual(decoded.useClipboardPaste, false)
		XCTAssertEqual(decoded.preventSystemSleep, true)
		XCTAssertEqual(decoded.minimumKeyTime, 0.25)
		XCTAssertEqual(decoded.copyToClipboard, true)
		XCTAssertFalse(decoded.superFastModeEnabled)
		XCTAssertEqual(decoded.useDoubleTapOnly, true)
		XCTAssertEqual(decoded.doubleTapLockEnabled, true)
		XCTAssertEqual(decoded.outputLanguage, "en")
		XCTAssertEqual(decoded.selectedMicrophoneID, "builtin:mic")
		XCTAssertEqual(decoded.saveTranscriptionHistory, false)
		XCTAssertEqual(decoded.maxHistoryEntries, 10)
		XCTAssertEqual(decoded.hasCompletedModelBootstrap, true)
		XCTAssertEqual(decoded.hasCompletedStorageMigration, true)
	}

	func testEncodeDecodeRoundTripPreservesDefaults() throws {
		let settings = HexSettings()
		let data = try JSONEncoder().encode(settings)
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)
		XCTAssertEqual(decoded, settings)
	}

	func testInitNormalizesDoubleTapOnlyWhenLockDisabled() {
		let settings = HexSettings(useDoubleTapOnly: true, doubleTapLockEnabled: false)

		XCTAssertFalse(settings.useDoubleTapOnly)
		XCTAssertFalse(settings.doubleTapLockEnabled)
	}

	func testDecodeNormalizesDoubleTapOnlyWhenLockDisabled() throws {
		let payload = "{\"useDoubleTapOnly\":true,\"doubleTapLockEnabled\":false}"
		guard let data = payload.data(using: .utf8) else {
			XCTFail("Failed to encode JSON payload")
			return
		}

		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)

		XCTAssertFalse(decoded.useDoubleTapOnly)
		XCTAssertFalse(decoded.doubleTapLockEnabled)
	}

	func testEncodeDecodeRoundTripPreservesNormalizedDoubleTapValues() throws {
		let settings = HexSettings(useDoubleTapOnly: true, doubleTapLockEnabled: false)
		let data = try JSONEncoder().encode(settings)
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)

		XCTAssertFalse(settings.useDoubleTapOnly)
		XCTAssertFalse(decoded.useDoubleTapOnly)
		XCTAssertEqual(decoded, settings)
	}

	// MARK: - Live transcription settings

	func testDefaultSettings_liveTranscriptionEnabledIsFalse() {
		let settings = HexSettings()
		XCTAssertFalse(settings.liveTranscriptionEnabled)
	}

	func testDefaultSettings_liveTranscriptionChunkSizeIsMs1600() {
		let settings = HexSettings()
		XCTAssertEqual(settings.liveTranscriptionChunkSize, .ms1600)
	}

	func testDecode_omittingNewKeys_returnsDefaults() throws {
		// Given — JSON without the new keys
		let payload = "{}"
		let data = try XCTUnwrap(payload.data(using: .utf8))

		// When
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)

		// Then — both fields default gracefully
		XCTAssertFalse(decoded.liveTranscriptionEnabled)
		XCTAssertEqual(decoded.liveTranscriptionChunkSize, .ms1600)
	}

	func testDecode_withNewKeysPresent_returnsThoseValues() throws {
		// Given — JSON that explicitly sets the new fields
		let payload = #"{"liveTranscriptionEnabled":true,"liveTranscriptionChunkSize":"ms160"}"#
		let data = try XCTUnwrap(payload.data(using: .utf8))

		// When
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)

		// Then
		XCTAssertTrue(decoded.liveTranscriptionEnabled)
		XCTAssertEqual(decoded.liveTranscriptionChunkSize, .ms160)
	}

	func testEncodeDecodeRoundTrip_preservesLiveTranscriptionValues() throws {
		// Given
		let original = HexSettings(liveTranscriptionEnabled: true, liveTranscriptionChunkSize: .ms160)

		// When
		let data = try JSONEncoder().encode(original)
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)

		// Then
		XCTAssertTrue(decoded.liveTranscriptionEnabled)
		XCTAssertEqual(decoded.liveTranscriptionChunkSize, .ms160)
		XCTAssertEqual(decoded, original)
	}

	func testFreshInstallProvidesFourSlotDefaults() {
		let settings = HexSettings()

		XCTAssertNil(settings.liveHoldHotkey)
		XCTAssertNil(settings.liveDoubleTapHotkey)
		XCTAssertEqual(settings.batchHoldHotkey, HotKey(key: nil, modifiers: [.option]))
		XCTAssertEqual(settings.batchDoubleTapHotkey, HotKey(key: nil, modifiers: [.option]))
	}

	func testV1FixtureFallsBackToFourSlotDefaultsForNewFields() throws {
		let data = try loadFixture(named: "v1")
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)

		XCTAssertNil(decoded.liveHoldHotkey)
		XCTAssertNil(decoded.liveDoubleTapHotkey)
		XCTAssertEqual(decoded.batchHoldHotkey, HotKey(key: nil, modifiers: [.option]))
		XCTAssertEqual(decoded.batchDoubleTapHotkey, HotKey(key: nil, modifiers: [.option]))
	}

	func testEncodeDecodeRoundTripPreservesFourSlotHotkeys() throws {
		var settings = HexSettings()
		settings.liveHoldHotkey = HotKey(key: nil, modifiers: [.shift, .control])
		settings.liveDoubleTapHotkey = HotKey(key: nil, modifiers: [.shift, .command])
		settings.batchHoldHotkey = HotKey(key: nil, modifiers: [.option])
		settings.batchDoubleTapHotkey = nil

		let data = try JSONEncoder().encode(settings)
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)

		XCTAssertEqual(decoded.liveHoldHotkey, settings.liveHoldHotkey)
		XCTAssertEqual(decoded.liveDoubleTapHotkey, settings.liveDoubleTapHotkey)
		XCTAssertEqual(decoded.batchHoldHotkey, settings.batchHoldHotkey)
		XCTAssertNil(decoded.batchDoubleTapHotkey)
	}

	// MARK: - Pause-hotkeys toggle hotkey

	func testFreshInstallHasNoPauseHotkeysHotkey() {
		let settings = HexSettings()
		XCTAssertNil(settings.pauseHotkeysHotkey)
	}

	func testDecode_omittingPauseHotkeysHotkey_returnsNil() throws {
		let data = try XCTUnwrap("{}".data(using: .utf8))
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)
		XCTAssertNil(decoded.pauseHotkeysHotkey)
	}

	func testDecode_withPauseHotkeysHotkeyPresent_returnsThatValue() throws {
		var settings = HexSettings()
		settings.pauseHotkeysHotkey = HotKey(key: .h, modifiers: [.option, .shift])
		let data = try JSONEncoder().encode(settings)

		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)

		XCTAssertEqual(decoded.pauseHotkeysHotkey, HotKey(key: .h, modifiers: [.option, .shift]))
		XCTAssertEqual(decoded, settings)
	}

	func testV1FixtureFallsBackToNilPauseHotkeysHotkey() throws {
		let data = try loadFixture(named: "v1")
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)
		XCTAssertNil(decoded.pauseHotkeysHotkey)
	}

	private func loadFixture(named name: String) throws -> Data {
		guard let url = Bundle.module.url(
			forResource: name,
			withExtension: "json",
			subdirectory: "Fixtures/HexSettings"
		) else {
			XCTFail("Missing fixture \(name).json")
			throw NSError(domain: "Fixture", code: 0)
		}
		return try Data(contentsOf: url)
	}
}
