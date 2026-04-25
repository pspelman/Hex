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
