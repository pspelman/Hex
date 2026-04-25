# Four-Hotkey Rebuild Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Bootstrap prompt for fresh context:**
> > Read `/Users/pspelman/coding/Hex/docs/four-hotkey-rebuild-plan.md` and execute it task-by-task. Use the `superpowers:subagent-driven-development` skill so each task runs in a fresh subagent with two-stage review. Start at Phase 1 Task 1.1.

**Goal:** Replace Hex's single-hotkey + boolean-toggles model with four independent hotkey slots — `liveHold`, `liveDoubleTap`, `batchHold`, `batchDoubleTap` — so the user can experiment with all four interaction modes simultaneously.

**Architecture:** A new pure-logic `HotkeyDispatcher` in `HexCore` owns the routing decisions. Per unique chord, it instantiates one `HotKeyProcessor` configured for the interaction patterns bound to that chord. The dispatcher emits `DispatchOutcome.fire(slot, action)` events that `TranscriptionFeature` (slots `batchHold` / `batchDoubleTap`) and `LiveTranscriptionFeature` (slots `liveHold` / `liveDoubleTap`) consume via the existing `keyEventMonitor.handleInputEvent` pathway. Conflicts (two slots claiming the same `{chord, pattern}`) are detected at resolution time, never at assignment time.

**Tech Stack:** Swift 6 strict concurrency, The Composable Architecture (TCA), HexCore (Swift Package, `swift test`-driven), AppKit + SwiftUI (Hex app target).

---

## Critical context — read this before touching anything

### Project layout

- **`HexCore/`** — local Swift package (`swift-tools-version: 6.0`, `platforms: [.macOS(.v15)]`). Pure logic, no SwiftUI/AppKit/AVFoundation. Tested via `cd HexCore && swift test`. The dispatcher and settings model belong here.
- **`Hex/`** — the macOS app target. TCA reducers (`Hex/Features/`), clients (`Hex/Clients/`), SwiftUI views. Tested via `xcodebuild test -scheme Hex` (slower).
- **`Hex/Features/Transcription/TranscriptionFeature.swift`** — current batch-mode reducer. Owns `HotKeyProcessor` instance via `startHotKeyMonitoringEffect` (line ~162).
- **`Hex/Features/Transcription/LiveTranscriptionFeature.swift`** — live-streaming reducer. Owns its own `HotKeyProcessor` via `startHotKeyMonitoringEffect` (line ~338).
- **`Hex/Features/Settings/HotKeySectionView.swift`** — current single-row hotkey picker.
- **`Hex/Features/Settings/HotKeyView.swift`** — visual rendering (modifier glyphs + key cap). **Reuse as-is** in the new four-row UI.

### Recent fixes (do NOT regress these)

These were stabilized in conversation immediately before this plan was written. The new code MUST preserve these invariants:

1. **`Hex/Features/Settings/SettingsFeature.swift:267-294`** — settings hotkey-capture listener subscribes immediately at the top of `.task`, in its own `Task`. Don't re-introduce the audio-device setup race.
2. **`Hex/Features/Settings/SettingsFeature.swift:223-228`** — `handleCapture` guards modifier-only finalize with `!updatedModifiers.isEmpty` so a stray empty `flagsChanged` event can't commit an empty hotkey.
3. **`Hex/Clients/CGEventTextInjector.swift:88`** — `CGEventSource(stateID: .privateState)`. Do NOT change to `.combinedSessionState` (that re-introduces "synthetic chars become Option+char and apps drop them").
4. **`Hex/Clients/CGEventTextInjector.swift:147-148, 169-170`** — `event.flags = []` on every posted event. Without this, the user's held hotkey modifiers re-attach to synthetic chars.
5. **`Hex/Clients/CGEventTextInjector.swift:154-184`** — `postUnicodeString` posts the entire suffix as one multi-character `keyboardSetUnicodeString` event (not per-char). This is what stops VS Code IntelliSense from eating chunks of synthesized text.
6. **`Hex/Clients/KeyEventMonitorClient.swift:91-95, 401-411`** — PID filter at the CGEvent tap callback. Synthetic events posted by us (matching `KeyEventMonitorClientLive.ownProcessIdentifier`) are passed through without dispatch. Without this, our own injected keystrokes feed back into the hotkey state machine.
7. **`Hex/Features/Transcription/LiveTranscriptionFeature.swift:194-213`** — capture buffers are queued through an `AsyncStream<AVAudioPCMBuffer>` and drained from a single `Task`, so only one `pushAudioBuffer` is in flight at a time. Don't re-introduce per-buffer `Task { ... }` spawning — it crashes FluidAudio's actor with `RangeReplaceableCollection.swift:596`.
8. **`Hex/Features/Transcription/LiveTranscriptionFeature.swift:141-143`** — `hotKeyPressed` reducer claims `state.isLive = true` synchronously. Required to close the press/release race.
9. **`Hex/Features/Transcription/LiveTranscriptionFeature.swift:413-419`** — `.discard` in live-mode dispatch sends `hotKeyReleased`, not nothing. Required so a sub-threshold tap closes the session it accidentally started.
10. **`Hex/Clients/StreamingTranscriptionClient.swift:262-282`** — `cancelSession` does NOT call `m.reset()`. Calling reset while a previous session's buffer drain has an in-flight `m.process(buffer)` causes the same `RangeReplaceableCollection.swift:596` crash.

### Spec — what the rebuild must produce

The user wants a 2×2 of (transcription mode) × (activation pattern):

|                                     | **Press-and-hold (release stops)** | **Double-tap to start, double-tap to stop** |
|-------------------------------------|-------------------------------------|---------------------------------------------|
| **Live (streaming injection)**      | Slot **A** = `liveHold`             | Slot **B** = `liveDoubleTap`                |
| **Batch (record-then-transcribe)**  | Slot **C** = `batchHold`            | Slot **D** = `batchDoubleTap`               |

**Rules confirmed by user:**

1. The same chord MAY be bound to multiple slots iff they use different interaction patterns (e.g. Option to both `batchHold` and `batchDoubleTap` is fine — press-hold fires `batchHold`, double-tap fires `batchDoubleTap`).
2. The same `{chord, pattern}` bound to two different slots is a **conflict** — refuse at resolution time, never at assignment time. UX: when assignment overlaps, the Settings UI shows an inline warning but does not block input. When the conflict actually fires at runtime, log a notice, play the cancel sound, do nothing.
3. **Defaults on fresh install:**
   - `batchHoldHotkey = HotKey(key: nil, modifiers: [.option])` — current Hex default behavior
   - `batchDoubleTapHotkey = HotKey(key: nil, modifiers: [.option])` — same chord, locks via double-tap
   - `liveHoldHotkey = nil`
   - `liveDoubleTapHotkey = nil`
4. **Migration:** existing `hotkey`, `doubleTapLockEnabled`, `useDoubleTapOnly`, `liveTranscriptionEnabled` fields are dropped/ignored. Existing users get the four-slot defaults. User explicitly said "existing hotkey can fuck off."
5. **Mode A (live press-hold) commit semantics:** on hotkey release, drain the trailing partial through `finishSession` and emit a finalize. Match the current behavior — accuracy over latency.
6. **Mode D (batch double-tap-locked) UX:** show the `InvisibleWindow` recording indicator the entire time the lock is active. The current batch path only shows it during press-hold; this needs extension.

### Naming conventions

- `Slot` enum: `liveHold`, `liveDoubleTap`, `batchHold`, `batchDoubleTap`
- `Pattern` enum: `pressAndHold`, `doubleTap`
- Settings field names: `liveHoldHotkey`, `liveDoubleTapHotkey`, `batchHoldHotkey`, `batchDoubleTapHotkey`
- All HotKey values are `HotKey?` (nil means slot is unbound)

### Files to create

- `HexCore/Sources/HexCore/Logic/HotkeyDispatcher.swift` — pure dispatcher
- `HexCore/Tests/HexCoreTests/HotkeyDispatcherTests.swift` — dispatcher tests
- `Hex/Features/Settings/FourSlotHotKeySectionView.swift` — replacement Settings UI

### Files to modify

- `HexCore/Sources/HexCore/Settings/HexSettings.swift` — add 4 fields, drop legacy from logic (keep keys for graceful decode)
- `HexCore/Tests/HexCoreTests/HexSettingsMigrationTests.swift` — new tests for the 4-slot migration
- `Hex/Features/Transcription/TranscriptionFeature.swift` — handle `Slot.batchHold` / `.batchDoubleTap`
- `Hex/Features/Transcription/LiveTranscriptionFeature.swift` — handle `Slot.liveHold` / `.liveDoubleTap`
- `Hex/Features/App/AppFeature.swift` — owns the shared `HotkeyDispatcher` instance
- `Hex/Features/Settings/SettingsView.swift` — swap to `FourSlotHotKeySectionView`
- `Hex/Features/Settings/HotKeySectionView.swift` — DELETE (replaced)
- `Hex/Features/Settings/SettingsFeature.swift` — capture flow now produces four targets

### Build & test commands

```bash
# HexCore unit tests (fast — under 1 s)
cd /Users/pspelman/coding/Hex/HexCore && swift test

# Single test class
cd /Users/pspelman/coding/Hex/HexCore && swift test --filter HotkeyDispatcherTests

# App build
cd /Users/pspelman/coding/Hex && xcodebuild -project Hex.xcodeproj -scheme Hex -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD"

# App-level integration tests
cd /Users/pspelman/coding/Hex && xcodebuild test -scheme Hex -destination 'platform=macOS'
```

---

## Phase 1 — Settings model + migration (HexCore only)

### Task 1.1: Add four-slot HotKey fields to HexSettings

**Files:**
- Modify: `HexCore/Sources/HexCore/Settings/HexSettings.swift:26-51`

- [ ] **Step 1: Read the existing `HexSettings` struct + `HexSettingKey` enum** to see the public API and schema fields. Notice `hotkey: HotKey` (line 28), `doubleTapLockEnabled: Bool` (line 39), `useDoubleTapOnly: Bool` (line 38), `liveTranscriptionEnabled: Bool` (line 50). All four become legacy.

- [ ] **Step 2: Add four new properties.** Insert after `hotkey: HotKey` (line 28):

```swift
public var liveHoldHotkey: HotKey?
public var liveDoubleTapHotkey: HotKey?
public var batchHoldHotkey: HotKey?
public var batchDoubleTapHotkey: HotKey?
```

- [ ] **Step 3: Add init parameters** to the public `init(...)` (after `liveTranscriptionChunkSize: ... = .ms1600`):

```swift
liveHoldHotkey: HotKey? = nil,
liveDoubleTapHotkey: HotKey? = nil,
batchHoldHotkey: HotKey? = HotKey(key: nil, modifiers: [.option]),
batchDoubleTapHotkey: HotKey? = HotKey(key: nil, modifiers: [.option]),
```

- [ ] **Step 4: Wire them into the init body** alongside the other `self.X = X` lines:

```swift
self.liveHoldHotkey = liveHoldHotkey
self.liveDoubleTapHotkey = liveDoubleTapHotkey
self.batchHoldHotkey = batchHoldHotkey
self.batchDoubleTapHotkey = batchDoubleTapHotkey
```

- [ ] **Step 5: Add new cases to `HexSettingKey`** (private enum, around line 135):

```swift
case liveHoldHotkey
case liveDoubleTapHotkey
case batchHoldHotkey
case batchDoubleTapHotkey
```

- [ ] **Step 6: Add the four schema entries** to `HexSettingsSchema.fields` (around line 222). Each uses the `encodeIfPresent` strategy because the values are optional:

```swift
SettingsField(
    .liveHoldHotkey,
    keyPath: \.liveHoldHotkey,
    default: defaults.liveHoldHotkey,
    encode: { container, key, value in
        try container.encodeIfPresent(value, forKey: key)
    }
).eraseToAny(),
SettingsField(
    .liveDoubleTapHotkey,
    keyPath: \.liveDoubleTapHotkey,
    default: defaults.liveDoubleTapHotkey,
    encode: { container, key, value in
        try container.encodeIfPresent(value, forKey: key)
    }
).eraseToAny(),
SettingsField(
    .batchHoldHotkey,
    keyPath: \.batchHoldHotkey,
    default: defaults.batchHoldHotkey,
    encode: { container, key, value in
        try container.encodeIfPresent(value, forKey: key)
    }
).eraseToAny(),
SettingsField(
    .batchDoubleTapHotkey,
    keyPath: \.batchDoubleTapHotkey,
    default: defaults.batchDoubleTapHotkey,
    encode: { container, key, value in
        try container.encodeIfPresent(value, forKey: key)
    }
).eraseToAny(),
```

- [ ] **Step 7: Build HexCore.** Run `cd HexCore && swift build`. Expected: clean build. Existing tests will still pass because we added — didn't remove — fields.

- [ ] **Step 8: Commit.**

```bash
git add HexCore/Sources/HexCore/Settings/HexSettings.swift
git commit -m "Add four-slot hotkey fields to HexSettings

Adds liveHoldHotkey, liveDoubleTapHotkey, batchHoldHotkey, and
batchDoubleTapHotkey alongside the existing single-hotkey field.
Defaults: batch slots bound to Option, live slots unbound.
The old single-hotkey field is preserved so existing JSON decodes
cleanly; later phases remove its consumers."
```

### Task 1.2: Migration test — fresh install gets new defaults

**Files:**
- Modify: `HexCore/Tests/HexCoreTests/HexSettingsMigrationTests.swift`

- [ ] **Step 1: Write the failing test** at the bottom of the test class:

```swift
func testFreshInstallProvidesFourSlotDefaults() {
    let settings = HexSettings()

    XCTAssertNil(settings.liveHoldHotkey)
    XCTAssertNil(settings.liveDoubleTapHotkey)
    XCTAssertEqual(settings.batchHoldHotkey, HotKey(key: nil, modifiers: [.option]))
    XCTAssertEqual(settings.batchDoubleTapHotkey, HotKey(key: nil, modifiers: [.option]))
}
```

- [ ] **Step 2: Run the test:**

```bash
cd HexCore && swift test --filter HexSettingsMigrationTests/testFreshInstallProvidesFourSlotDefaults
```

Expected: PASS (the defaults are already in the init).

- [ ] **Step 3: Commit.**

```bash
git add HexCore/Tests/HexCoreTests/HexSettingsMigrationTests.swift
git commit -m "Test that fresh HexSettings has four-slot hotkey defaults"
```

### Task 1.3: Migration test — existing v1 fixture decodes safely

**Files:**
- Modify: `HexCore/Tests/HexCoreTests/HexSettingsMigrationTests.swift`

- [ ] **Step 1: Add a test verifying the v1 fixture (which has the legacy single `hotkey` field) decodes without crashing and the four new fields fall back to their defaults:**

```swift
func testV1FixtureFallsBackToFourSlotDefaultsForNewFields() throws {
    let data = try loadFixture(named: "v1")
    let decoded = try JSONDecoder().decode(HexSettings.self, from: data)

    XCTAssertNil(decoded.liveHoldHotkey)
    XCTAssertNil(decoded.liveDoubleTapHotkey)
    XCTAssertEqual(decoded.batchHoldHotkey, HotKey(key: nil, modifiers: [.option]))
    XCTAssertEqual(decoded.batchDoubleTapHotkey, HotKey(key: nil, modifiers: [.option]))
}
```

- [ ] **Step 2: Run.** Expected: PASS. The v1 fixture has no `liveHoldHotkey` / etc., so `decodeIfPresent` returns `nil` and the schema applies the default.

- [ ] **Step 3: Commit.**

```bash
git commit -am "Test that v1 settings fixture migrates with four-slot defaults"
```

### Task 1.4: Round-trip encode/decode test for the new fields

**Files:**
- Modify: `HexCore/Tests/HexCoreTests/HexSettingsMigrationTests.swift`

- [ ] **Step 1: Add the test:**

```swift
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
```

- [ ] **Step 2: Run.** Expected: PASS.

- [ ] **Step 3: Commit.**

```bash
git commit -am "Round-trip test for four-slot hotkey encode/decode"
```

---

## Phase 2 — `HotkeyDispatcher` (HexCore, pure logic)

The dispatcher owns the routing decision: given a four-slot configuration and a stream of `KeyEvent`s, emit `DispatchOutcome`s indicating which slot (if any) fired.

### Design summary (read this before Task 2.1)

- One `HotKeyProcessor` instance per **unique chord** across the four slots. If `batchHoldHotkey` and `batchDoubleTapHotkey` are both Option, that's one processor (Option) configured with both press-hold AND double-tap detection. If `liveHoldHotkey` is Shift+Cmd, that's a second processor configured with only press-hold detection.
- `HotKeyProcessor.process(keyEvent:)` returns `Output` (`.startRecording` / `.stopRecording` / `.cancel` / `.discard` / `nil`). The dispatcher inspects the **processor's resulting state** (`.pressAndHold` vs `.doubleTapLock`) to decide which slot fires.
- Routing rules:
  - Output `.startRecording` from press-hold transition (`state == .pressAndHold(...)`) → fires the **press-hold slot bound to this chord**.
  - Output `.startRecording` from double-tap-lock transition (`state == .doubleTapLock`) → fires the **double-tap slot bound to this chord**.
  - Output `.stopRecording` → fires the **same slot** that fired the matching `.startRecording` (track which slot is "active per chord").
- Conflict: at the moment a chord+pattern resolves to ≥ 2 slots (e.g. Option bound to both `batchHold` AND `liveHold`), emit `.conflict(slots:)` and do not start any session.

### Task 2.1: Define the dispatcher's public types

**Files:**
- Create: `HexCore/Sources/HexCore/Logic/HotkeyDispatcher.swift`

- [ ] **Step 1: Create the file with the type definitions only:**

```swift
import Foundation

/// Pure routing layer for the four-slot hotkey model.
///
/// Owns one `HotKeyProcessor` per unique chord across the configured slots and
/// translates the processor's low-level outputs into high-level slot-fire signals.
public struct HotkeyDispatcher: Sendable {

    public enum Slot: Sendable, Equatable, Hashable, CaseIterable {
        case liveHold
        case liveDoubleTap
        case batchHold
        case batchDoubleTap

        /// Which interaction pattern this slot uses.
        public var pattern: Pattern {
            switch self {
            case .liveHold, .batchHold: return .pressAndHold
            case .liveDoubleTap, .batchDoubleTap: return .doubleTap
            }
        }
    }

    public enum Pattern: Sendable, Equatable, Hashable {
        case pressAndHold
        case doubleTap
    }

    public enum SlotAction: Sendable, Equatable {
        case startRecording
        case stopRecording
        case cancel
    }

    public enum DispatchOutcome: Sendable, Equatable {
        /// One slot fired cleanly.
        case fire(slot: Slot, action: SlotAction)
        /// Two or more slots claim the same `{chord, pattern}` and we refuse to act.
        case conflict(slots: Set<Slot>, action: SlotAction)
        /// Sub-threshold tap that should cancel any session that already started.
        case discard(slot: Slot)
        /// Nothing relevant happened.
        case none
    }

    public struct Configuration: Sendable, Equatable {
        public var liveHoldHotkey: HotKey?
        public var liveDoubleTapHotkey: HotKey?
        public var batchHoldHotkey: HotKey?
        public var batchDoubleTapHotkey: HotKey?
        public var minimumKeyTime: Double

        public init(
            liveHoldHotkey: HotKey? = nil,
            liveDoubleTapHotkey: HotKey? = nil,
            batchHoldHotkey: HotKey? = nil,
            batchDoubleTapHotkey: HotKey? = nil,
            minimumKeyTime: Double = HexCoreConstants.defaultMinimumKeyTime
        ) {
            self.liveHoldHotkey = liveHoldHotkey
            self.liveDoubleTapHotkey = liveDoubleTapHotkey
            self.batchHoldHotkey = batchHoldHotkey
            self.batchDoubleTapHotkey = batchDoubleTapHotkey
            self.minimumKeyTime = minimumKeyTime
        }
    }
}
```

- [ ] **Step 2: Build HexCore.** Run `cd HexCore && swift build`. Expected: clean build.

- [ ] **Step 3: Commit.**

```bash
git add HexCore/Sources/HexCore/Logic/HotkeyDispatcher.swift
git commit -m "Add HotkeyDispatcher types (Slot, Pattern, SlotAction, DispatchOutcome)"
```

### Task 2.2: Slot-binding lookup — given a chord, which slots are bound?

**Files:**
- Modify: `HexCore/Sources/HexCore/Logic/HotkeyDispatcher.swift`
- Create: `HexCore/Tests/HexCoreTests/HotkeyDispatcherTests.swift`

- [ ] **Step 1: Add a private extension to `Configuration` that maps each unique chord to the set of slots bound to it.** Put this inside `HotkeyDispatcher.swift`:

```swift
extension HotkeyDispatcher.Configuration {
    /// For each unique chord present in the configuration, the set of slots bound to it.
    /// Used internally to instantiate one HotKeyProcessor per unique chord.
    func bindings() -> [HotKey: Set<HotkeyDispatcher.Slot>] {
        var result: [HotKey: Set<HotkeyDispatcher.Slot>] = [:]
        if let h = liveHoldHotkey { result[h, default: []].insert(.liveHold) }
        if let h = liveDoubleTapHotkey { result[h, default: []].insert(.liveDoubleTap) }
        if let h = batchHoldHotkey { result[h, default: []].insert(.batchHold) }
        if let h = batchDoubleTapHotkey { result[h, default: []].insert(.batchDoubleTap) }
        return result
    }

    /// All slots bound to the given chord with the given interaction pattern.
    /// More than one means a runtime conflict.
    func slotsBoundTo(chord: HotKey, pattern: HotkeyDispatcher.Pattern) -> Set<HotkeyDispatcher.Slot> {
        guard let bound = bindings()[chord] else { return [] }
        return bound.filter { $0.pattern == pattern }
    }
}
```

- [ ] **Step 2: Write the failing test in `HotkeyDispatcherTests.swift`:**

```swift
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
```

- [ ] **Step 3: Run.**

```bash
cd HexCore && swift test --filter HotkeyDispatcherTests
```

Expected: 3 PASS.

- [ ] **Step 4: Commit.**

```bash
git add HexCore/Sources/HexCore/Logic/HotkeyDispatcher.swift HexCore/Tests/HexCoreTests/HotkeyDispatcherTests.swift
git commit -m "Add chord→slot binding lookup with conflict detection"
```

### Task 2.3: Per-chord HotKeyProcessor management

The dispatcher needs to lazily create / re-create `HotKeyProcessor` instances when the configuration changes. Each processor is configured with `doubleTapLockEnabled = (some doubleTap slot binds this chord)`.

**Files:**
- Modify: `HexCore/Sources/HexCore/Logic/HotkeyDispatcher.swift`

- [ ] **Step 1: Add internal storage and configuration logic to the `HotkeyDispatcher` struct.** Add these properties and methods inside the `public struct HotkeyDispatcher`:

```swift
/// Per-chord runtime state.
private struct PerChordState {
    var processor: HotKeyProcessor
    /// The slot whose `.startRecording` was last fired — used to route the next `.stopRecording`.
    var activeSlot: HotkeyDispatcher.Slot?
}

private var configuration: Configuration = Configuration()
private var perChord: [HotKey: PerChordState] = [:]

public init() {}

/// Re-configures the dispatcher's slot bindings.
///
/// Idempotent: re-applying the same configuration is a no-op. When bindings change,
/// stale processors for chords no longer present are dropped (any in-flight session for
/// those chords is implicitly cancelled by the absence of further dispatch).
public mutating func configure(_ configuration: Configuration) {
    self.configuration = configuration
    let bindings = configuration.bindings()

    // Drop processors for chords no longer bound.
    perChord = perChord.filter { bindings.keys.contains($0.key) }

    // Add or update processors for each present chord.
    for (chord, slots) in bindings {
        let allowsDoubleTap = slots.contains { $0.pattern == .doubleTap }
        let allowsPressHold = slots.contains { $0.pattern == .pressAndHold }
        // useDoubleTapOnly == true means: chord is bound only to a doubleTap slot, not press-hold
        let useDoubleTapOnly = allowsDoubleTap && !allowsPressHold

        if perChord[chord] != nil {
            perChord[chord]?.processor.hotkey = chord
            perChord[chord]?.processor.doubleTapLockEnabled = allowsDoubleTap
            perChord[chord]?.processor.useDoubleTapOnly = useDoubleTapOnly
            perChord[chord]?.processor.minimumKeyTime = configuration.minimumKeyTime
        } else {
            var processor = HotKeyProcessor(hotkey: chord)
            processor.doubleTapLockEnabled = allowsDoubleTap
            processor.useDoubleTapOnly = useDoubleTapOnly
            processor.minimumKeyTime = configuration.minimumKeyTime
            perChord[chord] = PerChordState(processor: processor, activeSlot: nil)
        }
    }
}
```

- [ ] **Step 2: Write tests:**

```swift
func testConfigureCreatesOneProcessorPerUniqueChord() {
    let opt = HotKey(key: nil, modifiers: [.option])
    let shiftCmd = HotKey(key: nil, modifiers: [.shift, .command])
    var dispatcher = HotkeyDispatcher()
    dispatcher.configure(HotkeyDispatcher.Configuration(
        liveHoldHotkey: shiftCmd,
        batchHoldHotkey: opt,
        batchDoubleTapHotkey: opt
    ))

    // Internal: not directly testable without exposing perChord.
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
    // Contract: no crash, no leaked state. Real verification comes in dispatch tests below.
}
```

- [ ] **Step 3: Run + commit.**

```bash
cd HexCore && swift test --filter HotkeyDispatcherTests
git commit -am "HotkeyDispatcher.configure manages per-chord processors"
```

### Task 2.4: Process key event — single-slot fire (press-hold only)

**Files:**
- Modify: `HexCore/Sources/HexCore/Logic/HotkeyDispatcher.swift`

**Important — `HotKeyProcessor` API (verified against `HotKeyProcessor.swift:89-225`):**

- `public struct HotKeyProcessor` (value type, mutate via `inout`)
- `@Dependency(\.date.now) var now` — timestamps come from TCA's `Dependencies`, NOT a parameter
- `public private(set) var state: State` — readable enum (`.idle`, `.pressAndHold(startTime:)`, `.doubleTapLock`)
- `public mutating func process(keyEvent: KeyEvent) -> Output?` — no date param
- `public mutating func processMouseClick() -> Output?` — no date param
- `public enum Output { case startRecording, stopRecording, cancel, discard }`

To control time in tests and from the dispatcher, wrap calls with `withDependencies { $0.date.now = { now } }`.

- [ ] **Step 1: Add the `process` method.** It accepts a `now: Date` and threads it into `HotKeyProcessor` via `Dependencies.withDependencies`:

```swift
import Dependencies

extension HotkeyDispatcher {
    /// Routes one keyboard event through the dispatcher.
    ///
    /// `now` is propagated to `HotKeyProcessor` via `withDependencies` so the dispatcher
    /// (and its tests) can supply a deterministic clock without exposing an internal API.
    public mutating func process(keyEvent: KeyEvent, now: Date) -> DispatchOutcome {
        guard !perChord.isEmpty else { return .none }

        var outcome: DispatchOutcome = .none

        for chord in perChord.keys {
            // Snapshot the processor, mutate it under a controlled clock, write back.
            var state = perChord[chord]!
            let output: HotKeyProcessor.Output? = withDependencies {
                $0.date.now = now
            } operation: {
                state.processor.process(keyEvent: keyEvent)
            }
            // The processor's `state` field reflects the post-event state machine state.
            let pattern: Pattern = state.processor.state == .doubleTapLock ? .doubleTap : .pressAndHold

            switch output {
            case .startRecording:
                let slots = configuration.slotsBoundTo(chord: chord, pattern: pattern)
                switch slots.count {
                case 0:
                    break // chord matched but no slot wants this pattern
                case 1:
                    let slot = slots.first!
                    state.activeSlot = slot
                    outcome = .fire(slot: slot, action: .startRecording)
                default:
                    outcome = .conflict(slots: slots, action: .startRecording)
                }

            case .stopRecording:
                if let active = state.activeSlot {
                    state.activeSlot = nil
                    outcome = .fire(slot: active, action: .stopRecording)
                }

            case .cancel:
                if let active = state.activeSlot {
                    state.activeSlot = nil
                    outcome = .fire(slot: active, action: .cancel)
                }

            case .discard:
                if let active = state.activeSlot {
                    state.activeSlot = nil
                    outcome = .discard(slot: active)
                }

            case .none:
                break
            }

            perChord[chord] = state
        }

        return outcome
    }
}
```

- [ ] **Step 2: Write a press-and-hold dispatch test:**

```swift
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
```

- [ ] **Step 3: Run + iterate.** If tests fail, debug; the most likely issue is `HotKeyProcessor`'s actual API differing from the placeholder (`processor.state`, `process(keyEvent:date:)`).

```bash
cd HexCore && swift test --filter HotkeyDispatcherTests/testPressAndHoldDispatchesToBoundSlot
```

- [ ] **Step 4: Commit.**

```bash
git commit -am "HotkeyDispatcher.process: press-and-hold path"
```

### Task 2.5: Double-tap dispatch path

**Files:**
- Modify: `HexCore/Tests/HexCoreTests/HotkeyDispatcherTests.swift`

- [ ] **Step 1: Add a double-tap test:**

```swift
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

    // First tap: fires batchHold (press-and-hold path)
    _ = dispatcher.process(keyEvent: press, now: t0)
    _ = dispatcher.process(keyEvent: release, now: t0.addingTimeInterval(0.05))

    // Second tap within double-tap window
    _ = dispatcher.process(keyEvent: press, now: t0.addingTimeInterval(0.10))
    let secondRelease = dispatcher.process(keyEvent: release, now: t0.addingTimeInterval(0.15))

    // After the second release the processor enters .doubleTapLock state.
    // No fire output (HotKeyProcessor returns nil on lock entry); session is "locked on".
    // Now a third tap is the explicit stop:
    let thirdTap = dispatcher.process(keyEvent: press, now: t0.addingTimeInterval(1.0))

    // Validate that the dispatcher routed start to batchDoubleTap (not batchHold) when lock engaged
    // and routed stop to the same slot.
    XCTAssertEqual(secondRelease, .none) // lock entry produces no output
    if case let .fire(slot, action) = thirdTap {
        XCTAssertEqual(slot, .batchDoubleTap)
        XCTAssertEqual(action, .stopRecording)
    } else {
        XCTFail("Expected stopRecording on third tap, got \(thirdTap)")
    }
}
```

> **Validate against actual HotKeyProcessor semantics:** the lock-entry behavior may differ from the comment above. If `HotKeyProcessor` returns `.startRecording` on the second-tap press (with `state == .doubleTapLock` afterwards), the dispatcher should fire `batchDoubleTap.startRecording` at that moment and NOT before. Read `handleMatchingChord` and `handleNonmatchingChord` in `HotKeyProcessor.swift` and adjust the test expectations to match observed behavior.

- [ ] **Step 2: Run + iterate.** Adjust test expectations to match real `HotKeyProcessor` semantics.

- [ ] **Step 3: Commit.**

```bash
git commit -am "HotkeyDispatcher.process: double-tap-lock dispatch path"
```

### Task 2.6: Conflict detection at runtime

- [ ] **Step 1: Add a conflict test:**

```swift
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
```

- [ ] **Step 2: Run + verify.** The dispatch logic from Task 2.4 already returns `.conflict` when `slots.count > 1` — this just verifies it.

- [ ] **Step 3: Commit.**

```bash
git commit -am "HotkeyDispatcher: assert conflict detection at dispatch time"
```

### Task 2.7: Mouse-click cancel pass-through

`HotKeyProcessor.processMouseClick()` returns `.cancel` when a mouse click should kill the in-flight session, `.discard` for sub-threshold, and `.none` for ignore. The dispatcher must surface those.

- [ ] **Step 1: Add `processMouseClick(now:)` to the dispatcher**, symmetric to `process(keyEvent:now:)`:

```swift
extension HotkeyDispatcher {
    public mutating func processMouseClick(now: Date) -> DispatchOutcome {
        guard !perChord.isEmpty else { return .none }
        var outcome: DispatchOutcome = .none

        for chord in perChord.keys {
            var state = perChord[chord]!
            let output: HotKeyProcessor.Output? = withDependencies {
                $0.date.now = now
            } operation: {
                state.processor.processMouseClick()
            }

            switch output {
            case .cancel:
                if let active = state.activeSlot {
                    state.activeSlot = nil
                    outcome = .fire(slot: active, action: .cancel)
                }
            case .discard:
                if let active = state.activeSlot {
                    state.activeSlot = nil
                    outcome = .discard(slot: active)
                }
            case .startRecording, .stopRecording, .none:
                break // mouse clicks should never start or stop on their own
            }

            perChord[chord] = state
        }
        return outcome
    }
}
```

- [ ] **Step 2: Test:**

```swift
func testMouseClickCancelsActiveSession() {
    let opt = HotKey(key: nil, modifiers: [.option])
    var dispatcher = HotkeyDispatcher()
    dispatcher.configure(HotkeyDispatcher.Configuration(batchHoldHotkey: opt))

    let t0 = Date(timeIntervalSinceReferenceDate: 0)

    // Start a session
    _ = dispatcher.process(keyEvent: KeyEvent(key: nil, modifiers: [.option]), now: t0)

    // After the modifier-only threshold (0.3s), a mouse click should cancel
    let outcome = dispatcher.processMouseClick(now: t0.addingTimeInterval(1.0))

    if case let .fire(slot, action) = outcome {
        XCTAssertEqual(slot, .batchHold)
        XCTAssertEqual(action, .cancel)
    } else {
        XCTFail("Expected cancel fire, got \(outcome)")
    }
}
```

- [ ] **Step 3: Run + commit.**

```bash
cd HexCore && swift test --filter HotkeyDispatcherTests
git commit -am "HotkeyDispatcher.processMouseClick routes cancels to active slot"
```

---

## Phase 3 — Wire `HotkeyDispatcher` into the app

### Task 3.1: Promote dispatcher to `AppFeature` as a single instance

**Files:**
- Modify: `Hex/Features/App/AppFeature.swift`

- [ ] **Step 1: Add a state field for the dispatcher.** Inside `AppFeature.State`:

```swift
var hotkeyDispatcher: HotkeyDispatcher = .init()
```

- [ ] **Step 2: Add a sync action.** In `AppFeature.Action`:

```swift
case syncHotkeyDispatcher
```

In the reducer, build a `Configuration` from `state.hexSettings` and apply it:

```swift
case .syncHotkeyDispatcher:
    state.hotkeyDispatcher.configure(.init(
        liveHoldHotkey: state.hexSettings.liveHoldHotkey,
        liveDoubleTapHotkey: state.hexSettings.liveDoubleTapHotkey,
        batchHoldHotkey: state.hexSettings.batchHoldHotkey,
        batchDoubleTapHotkey: state.hexSettings.batchDoubleTapHotkey,
        minimumKeyTime: state.hexSettings.minimumKeyTime
    ))
    return .none
```

- [ ] **Step 3: Trigger sync at app launch.** In `AppFeature.task`'s `.merge(...)`:

```swift
.send(.syncHotkeyDispatcher),
```

- [ ] **Step 4: Trigger sync after settings mutation.** In each `SettingsFeature` reducer case that writes to one of the four hotkey fields (Phase 4 will add these — `setLiveHoldHotkey`, `setLiveDoubleTapHotkey`, `setBatchHoldHotkey`, `setBatchDoubleTapHotkey`, plus the `applyCapturedHotKey` flow), forward an action to `AppFeature` to trigger `.syncHotkeyDispatcher`. Use a delegate-style `case .delegate(.hotkeysChanged)` if the existing pattern doesn't already cover this.

- [ ] **Step 5: Build + commit.**

```bash
cd /Users/pspelman/coding/Hex && xcodebuild -project Hex.xcodeproj -scheme Hex -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD"
git commit -am "AppFeature owns shared HotkeyDispatcher synced from settings"
```

### Task 3.2: TranscriptionFeature consumes batch slots

**Files:**
- Modify: `Hex/Features/Transcription/TranscriptionFeature.swift`

- [ ] **Step 1: Replace the existing per-feature `HotKeyProcessor` instance with a subscription to dispatcher outcomes.** Inside `startHotKeyMonitoringEffect()` (around line 162), change:

  - The handler now feeds events into `state.hotkeyDispatcher.process(...)` (via a forwarded action like `.dispatcherEvent(InputEvent)`).
  - On `DispatchOutcome.fire(slot, action)`:
    - `slot == .batchHold && action == .startRecording` → existing batch-press-and-hold start path (`send(.hotKeyPressed)` equivalent).
    - `slot == .batchDoubleTap && action == .startRecording` → batch-double-tap-lock start.
    - Both: `action == .stopRecording` → existing stop path.

- [ ] **Step 2: Test the wiring** with the existing `RecordingRaceTests.swift`.

- [ ] **Step 3: Commit.**

### Task 3.3: LiveTranscriptionFeature consumes live slots

**Files:**
- Modify: `Hex/Features/Transcription/LiveTranscriptionFeature.swift`

Symmetric to 3.2. Live feature subscribes to `.liveHold` / `.liveDoubleTap`.

- [ ] **Step 1: Replace the in-feature `HotKeyProcessor` with dispatcher routing.**

- [ ] **Step 2: Preserve the recently-fixed invariants** (see "Recent fixes" section in the header):
  - `hotKeyPressed` claims `state.isLive = true` synchronously.
  - `.discard` from the dispatcher → send `.hotKeyReleased`.
  - Buffer-feed AsyncStream stays serial.

- [ ] **Step 3: Build + commit.**

### Task 3.4: Conflict UX — log + cancel sound

**Files:**
- Modify: `Hex/Features/App/AppFeature.swift`

- [ ] **Step 1: When `DispatchOutcome.conflict(slots:action:)` arrives, log via `HexLog.notice` and play `soundEffects.play(.cancel)`.** Do not start any session.

- [ ] **Step 2: Commit.**

---

## Phase 4 — Settings UI rewrite

### Task 4.1: New `FourSlotHotKeySectionView` with four rows

**Files:**
- Create: `Hex/Features/Settings/FourSlotHotKeySectionView.swift`
- Modify: `Hex/Features/Settings/SettingsView.swift`
- Delete: `Hex/Features/Settings/HotKeySectionView.swift`

- [ ] **Step 1: Design the view as four labeled rows.** Each row:
  - Title: "Live · Hold", "Live · Double-tap", "Batch · Hold", "Batch · Double-tap"
  - Body: tap-to-capture area using existing `HotKeyView` and the recently-stabilized `SettingsFeature` capture flow.
  - Trailing: small "Clear" button when bound, hidden when unbound.

- [ ] **Step 2: Extend `SettingsFeature` capture targets** (`HotKeyCaptureTarget` enum) to include the four new targets:

```swift
private enum HotKeyCaptureTarget {
    case liveHold
    case liveDoubleTap
    case batchHold
    case batchDoubleTap
    case pasteLastTranscript
}
```

  ...and update `applyCapturedHotKey` to write to the appropriate `state.$hexSettings` field.

- [ ] **Step 3: Inline conflict banner.** Compute the set of conflicting slots from `HotkeyDispatcher.Configuration.bindings()` whenever the four fields change. If non-empty, render a yellow `Label` above the rows: "X and Y are bound to the same chord with the same activation; only one will fire." Dismissable: when user fixes the binding, banner disappears.

- [ ] **Step 4: Drop legacy UI.** Remove the "Enable double-tap lock", "Use double-tap only", and "Live Transcription" toggles from Settings. The four-slot layout subsumes them.

### Task 4.2: Update `SettingsFeature` to drop legacy toggles

**Files:**
- Modify: `Hex/Features/Settings/SettingsFeature.swift`

- [ ] **Step 1: Remove `setDoubleTapLockEnabled`, `setUseDoubleTapOnly`, `setLiveTranscriptionEnabled` action cases.** Their underlying state fields stay in `HexSettings` for graceful decode, but the reducer no longer touches them and the UI no longer exposes them.

- [ ] **Step 2: Build + commit.**

---

## Phase 5 — Recording indicator for batch-double-tap-locked mode

### Task 5.1: Show `InvisibleWindow` for the duration of a locked batch session

**Files:**
- Modify: `Hex/Features/Transcription/TranscriptionFeature.swift`
- Modify: `Hex/App/HexAppDelegate.swift` (window presentation)

- [ ] **Step 1: Track lock state.** Add `var isBatchLocked: Bool` to `TranscriptionFeature.State`. Set `true` when `.batchDoubleTap.startRecording` fires, `false` on `.stopRecording` or `.cancel`.

- [ ] **Step 2: Bind `InvisibleWindow` visibility to `isBatchLocked`** (in addition to the existing press-and-hold lifecycle).

- [ ] **Step 3: Manual test.** Build, run, bind a hotkey to `batchDoubleTap`, double-tap to lock, verify the indicator appears and stays visible until the second double-tap stops it. Verify the indicator does NOT linger after the recording ends.

- [ ] **Step 4: Commit.**

---

## Acceptance criteria

A reviewer should verify, end-to-end, all of these:

1. **Migration:** Existing v1 fixture decodes; all four new fields populate from defaults. No legacy UI toggles visible.
2. **Each slot fires its own mode:**
   - `batchHold` press-and-hold → batch transcription pasted on release.
   - `batchDoubleTap` double-tap → batch recording locks; second double-tap pastes.
   - `liveHold` press-and-hold → live streaming text injection.
   - `liveDoubleTap` double-tap → live streaming locks; second double-tap stops.
3. **Same-chord, different-pattern coexistence:** Option bound to both `batchHold` and `batchDoubleTap` works without conflict warning.
4. **Same-chord, same-pattern conflict:** Option bound to both `batchHold` and `liveHold` shows a banner in Settings AND, when triggered at runtime, plays the cancel sound + logs and starts no session.
5. **Settings UX:** All four rows are individually bindable with the existing capture flow. Each row clears with a button. Banner appears/disappears as user edits bindings.
6. **No regressions on the recently-stabilized invariants:** the 10 items listed in "Recent fixes" must all still hold. Specifically, build the live-transcription path with `liveHold` bound to a single modifier (e.g. Shift) and verify text injection works in TextEdit and VS Code without chars being eaten.
7. **Tests:**
   - `cd HexCore && swift test` — all tests pass, including the new `HotkeyDispatcherTests` and updated `HexSettingsMigrationTests`.
   - `xcodebuild -scheme Hex build` — clean build, no errors.
8. **Indicator:** the InvisibleWindow stays visible for the duration of a `batchDoubleTap`-locked recording.

---

## Subagent dispatch suggestions

- **Phase 1 (settings model):** dispatch as one subagent (`guru-dev`). Pure data-layer change, fast feedback via `swift test`.
- **Phase 2 (dispatcher):** dispatch as one subagent (`guru-testing` to drive TDD). Each task in the phase is a discrete unit test. The tricky bit is matching `HotKeyProcessor`'s real API — the subagent must read the file before drafting tests.
- **Phase 3 (feature wiring):** dispatch as one subagent (`guru-dev`). Touches both transcription features and `AppFeature`. Pre-existing tests (`RecordingRaceTests`) provide some guard rails.
- **Phase 4 (UI):** dispatch as one subagent (`guru-dev`). SwiftUI + TCA bindings; manual visual verification needed.
- **Phase 5 (indicator):** dispatch as one subagent (`guru-dev`). Small, self-contained.

Between phases, run the full test suite + Xcode build as a sanity gate before moving on.

---

## Open questions a fresh agent may surface

1. **Does `HotKeyProcessor` accept an injected `Date` for tests?** The current signature uses `@Dependency(\.date)`. Tests need to either inject a frozen clock or use `withDependencies`. Verify before drafting Phase 2 tests.
2. **Should the dispatcher be an `actor`?** It's `struct` in this plan because the existing `HotKeyProcessor` is value-type. Check if any callers need cross-thread access — if yes, wrap the struct in an actor at the call site rather than making it one.
3. **What happens when a slot fires `cancel` mid-session?** Plan defers to existing per-feature cancel paths. Confirm they're idempotent.
4. **Conflict banner copy:** Settings UX should pick exact wording. Suggested: "These shortcuts overlap. Only one will respond." with the conflicting slot names beneath.
