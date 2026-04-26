import Dependencies
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

    // MARK: - Per-chord runtime state

    /// Per-chord runtime state.
    private struct PerChordState: @unchecked Sendable {
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
}

// MARK: - Event Processing

extension HotkeyDispatcher {
    /// Routes one keyboard event through the dispatcher.
    ///
    /// `now` is propagated to `HotKeyProcessor` via `withDependencies` so the dispatcher
    /// (and its tests) can supply a deterministic clock without exposing an internal API.
    public mutating func process(keyEvent: KeyEvent, now: Date) -> DispatchOutcome {
        guard !perChord.isEmpty else { return .none }

        var outcome: DispatchOutcome = .none

        // Each KeyEvent is expected to match at most one chord, so this loop
        // produces at most one non-.none outcome — there is no "last writer wins"
        // race in practice.
        for chord in perChord.keys {
            // Snapshot the processor, mutate it under a controlled clock, write back.
            guard var state = perChord[chord] else { continue }

            let preState = state.processor.state

            let output: HotKeyProcessor.Output? = withDependencies {
                $0.date.now = now
            } operation: {
                state.processor.process(keyEvent: keyEvent)
            }

            let postState = state.processor.state

            // The processor's `state` field reflects the post-event state machine state.
            // Only `.doubleTapLock` maps to the double-tap pattern; everything else is press-and-hold.
            let pattern: Pattern
            switch postState {
            case .doubleTapLock:
                pattern = .doubleTap
            default:
                pattern = .pressAndHold
            }

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

            // Lock-engagement transition: state moved from .pressAndHold to .doubleTapLock
            // with no output (the lock engages silently on the second release).
            //
            // Promote the in-flight session from the pressHold slot to the doubleTap slot
            // for this chord and emit a synthetic .startRecording so consumers can mark the
            // session as locked. Without this, a chord bound to both batchHold and
            // batchDoubleTap (the default) could only ever fire batchHold — Mode D
            // (locked batch recording) would be unreachable.
            if output == nil,
               case .pressAndHold = preState,
               postState == .doubleTapLock
            {
                let doubleTapSlots = configuration.slotsBoundTo(chord: chord, pattern: .doubleTap)
                switch doubleTapSlots.count {
                case 0:
                    // No doubleTap slot bound — should not occur because configure() sets
                    // doubleTapLockEnabled = false when no doubleTap slot is bound to the chord.
                    break
                case 1:
                    if let slot = doubleTapSlots.first {
                        state.activeSlot = slot
                        outcome = .fire(slot: slot, action: .startRecording)
                    }
                default:
                    outcome = .conflict(slots: doubleTapSlots, action: .startRecording)
                }
            }

            perChord[chord] = state
        }

        return outcome
    }
}

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
