import Foundation

/// Outcome filter implementing "pause recording hotkeys".
///
/// Sits between `HotkeyDispatcher.process(...)` and outcome routing. Events keep
/// flowing through the dispatcher while paused — freezing the event stream instead
/// would leave `HotKeyProcessor` per-chord state stale mid-chord and make an
/// in-flight recording unstoppable by hotkey.
///
/// While paused, new sessions (`.startRecording` fires) and `.conflict`s are
/// suppressed; stop/cancel/discard for a session that started before the pause pass
/// through so the user can finish or cancel it normally. The `suppressedSlots`
/// ledger drops the phantom stop/cancel/discard that eventually pairs with a
/// suppressed start — without it, a phantom `.cancel` fire would swallow the user's
/// ESC keypress (routing returns the intercept flag for cancels).
public struct HotkeyPauseGate: Sendable, Equatable {
    private var suppressedSlots: Set<HotkeyDispatcher.Slot> = []

    public init() {}

    /// Filters one dispatch outcome given the current paused state.
    /// Returns `.none` when the outcome must be dropped.
    public mutating func filter(
        _ outcome: HotkeyDispatcher.DispatchOutcome, paused: Bool
    ) -> HotkeyDispatcher.DispatchOutcome {
        switch outcome {
        case let .fire(slot, .startRecording):
            if paused {
                suppressedSlots.insert(slot)
                return .none
            }
            // A suppressed double-tap promotion can orphan the hold slot's ledger
            // entry; a real start on the slot supersedes any stale suppression.
            suppressedSlots.remove(slot)
            return outcome

        case let .fire(slot, .stopRecording), let .fire(slot, .cancel):
            if suppressedSlots.remove(slot) != nil {
                return .none
            }
            return outcome

        case let .discard(slot):
            if suppressedSlots.remove(slot) != nil {
                return .none
            }
            return outcome

        case .conflict:
            return paused ? .none : outcome

        case .none:
            return outcome
        }
    }
}
