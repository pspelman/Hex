import ComposableArchitecture
import HexCore
import Inject
import Sauce
import SwiftUI

// MARK: - Four-Slot Hot Key Section

/// Replaces the legacy single-hotkey section with four labeled rows — one per
/// `HotkeyDispatcher.Slot`.  Conflict detection is computed directly from the
/// four `HexSettings` fields and shown as an inline banner above the rows.
struct FourSlotHotKeySectionView: View {
    @ObserveInjection var inject
    @Bindable var store: StoreOf<SettingsFeature>

    var body: some View {
        Section("Hot Keys") {
            // Conflict banner — shown only when two or more slots share a chord+pattern.
            let conflicting = conflictingSlots(in: hotkeyConfiguration)
            if !conflicting.isEmpty {
                Label {
                    Text(conflictBannerText(for: conflicting))
                        .font(.callout)
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
                .padding(.vertical, 2)
            }

            // Live · Hold
            HotKeySlotRow(
                title: "Live · Hold",
                subtitle: "Start live transcription by pressing and holding",
                hotKey: store.hexSettings.liveHoldHotkey,
                isCapturing: store.isSettingLiveHoldHotkey,
                currentModifiers: store.currentLiveHoldModifiers,
                isConflicting: conflicting.contains(.liveHold),
                onTap: { store.send(.startSettingLiveHoldHotkey) },
                onClear: { store.send(.clearLiveHoldHotkey) }
            )

            // Live · Double-tap
            HotKeySlotRow(
                title: "Live · Double-tap",
                subtitle: "Lock live transcription on with a double-tap",
                hotKey: store.hexSettings.liveDoubleTapHotkey,
                isCapturing: store.isSettingLiveDoubleTapHotkey,
                currentModifiers: store.currentLiveDoubleTapModifiers,
                isConflicting: conflicting.contains(.liveDoubleTap),
                onTap: { store.send(.startSettingLiveDoubleTapHotkey) },
                onClear: { store.send(.clearLiveDoubleTapHotkey) }
            )

            // Batch · Hold
            HotKeySlotRow(
                title: "Batch · Hold",
                subtitle: "Record a batch clip by pressing and holding",
                hotKey: store.hexSettings.batchHoldHotkey,
                isCapturing: store.isSettingBatchHoldHotkey,
                currentModifiers: store.currentBatchHoldModifiers,
                isConflicting: conflicting.contains(.batchHold),
                onTap: { store.send(.startSettingBatchHoldHotkey) },
                onClear: { store.send(.clearBatchHoldHotkey) }
            )

            // Batch · Double-tap
            HotKeySlotRow(
                title: "Batch · Double-tap",
                subtitle: "Lock batch recording on with a double-tap",
                hotKey: store.hexSettings.batchDoubleTapHotkey,
                isCapturing: store.isSettingBatchDoubleTapHotkey,
                currentModifiers: store.currentBatchDoubleTapModifiers,
                isConflicting: conflicting.contains(.batchDoubleTap),
                onTap: { store.send(.startSettingBatchDoubleTapHotkey) },
                onClear: { store.send(.clearBatchDoubleTapHotkey) }
            )

            // Pause toggle — a standalone global hotkey, NOT a dispatcher slot.
            // It flips whether the four recording slots above respond at all.
            HotKeySlotRow(
                title: "Pause Hotkeys",
                subtitle: "Toggle the recording hotkeys above on or off (resets on relaunch)",
                hotKey: store.hexSettings.pauseHotkeysHotkey,
                isCapturing: store.isSettingPauseHotkeysHotkey,
                currentModifiers: store.currentPauseHotkeysModifiers,
                isConflicting: pauseToggleOverlapsOtherHotkeys,
                onTap: { store.send(.startSettingPauseHotkeysHotkey) },
                onClear: { store.send(.clearPauseHotkeysHotkey) }
            )

            if store.isSettingPauseHotkeysHotkey {
                Text("Use at least one modifier (⌘, ⌥, ⇧, ⌃) plus a key.")
                    .settingsCaption()
            } else if pauseToggleOverlapsOtherHotkeys {
                Label {
                    Text("This shortcut overlaps a recording hotkey or the paste shortcut; pressing it may trigger that action first.")
                        .settingsCaption()
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
            }

            // Minimum key time — only relevant when at least one active slot is modifier-only.
            if hasModifierOnlySlot {
                Label {
                    Slider(
                        value: Binding(
                            get: { store.hexSettings.minimumKeyTime },
                            set: { store.send(.setMinimumKeyTime($0)) }
                        ),
                        in: 0.0 ... 2.0,
                        step: 0.1
                    ) {
                        Text("Ignore below \(store.hexSettings.minimumKeyTime, specifier: "%.1f")s")
                    }
                } icon: {
                    Image(systemName: "clock")
                }
            }
        }
        .enableInjection()
    }

    // MARK: - Helpers

    private var hotkeyConfiguration: HotkeyDispatcher.Configuration {
        HotkeyDispatcher.Configuration(
            liveHoldHotkey: store.hexSettings.liveHoldHotkey,
            liveDoubleTapHotkey: store.hexSettings.liveDoubleTapHotkey,
            batchHoldHotkey: store.hexSettings.batchHoldHotkey,
            batchDoubleTapHotkey: store.hexSettings.batchDoubleTapHotkey,
            minimumKeyTime: store.hexSettings.minimumKeyTime
        )
    }

    /// Returns the set of conflicting slots: two or more slots sharing the same
    /// chord AND the same activation pattern.
    private func conflictingSlots(in cfg: HotkeyDispatcher.Configuration) -> Set<HotkeyDispatcher.Slot> {
        var result: Set<HotkeyDispatcher.Slot> = []
        for (_, slots) in cfg.bindings() {
            for pattern in [HotkeyDispatcher.Pattern.pressAndHold, .doubleTap] {
                let same = slots.filter { $0.pattern == pattern }
                if same.count >= 2 {
                    result.formUnion(same)
                }
            }
        }
        return result
    }

    private func conflictBannerText(for slots: Set<HotkeyDispatcher.Slot>) -> String {
        let names = slots.sorted { $0.displayName < $1.displayName }.map(\.displayName)
        let listed: String
        if names.count == 2 {
            listed = "\(names[0]) and \(names[1])"
        } else {
            let all = names.dropLast().joined(separator: ", ")
            listed = "\(all), and \(names.last!)"
        }
        return "\(listed) are bound to the same chord with the same activation; only one will fire."
    }

    /// True when the pause-toggle chord collides with a recording slot or the
    /// paste-last-transcript shortcut. Not part of the slot-conflict banner —
    /// the toggle is not a dispatcher slot, so it gets its own warning.
    private var pauseToggleOverlapsOtherHotkeys: Bool {
        guard let chord = store.hexSettings.pauseHotkeysHotkey else { return false }
        return hotkeyConfiguration.overlaps(chord: chord)
            || chord == store.hexSettings.pasteLastTranscriptHotkey
    }

    /// True when any bound slot uses a modifier-only hotkey (key == nil).
    private var hasModifierOnlySlot: Bool {
        let hotkeys: [HotKey?] = [
            store.hexSettings.liveHoldHotkey,
            store.hexSettings.liveDoubleTapHotkey,
            store.hexSettings.batchHoldHotkey,
            store.hexSettings.batchDoubleTapHotkey,
        ]
        return hotkeys.compactMap { $0 }.contains { $0.key == nil && !$0.modifiers.isEmpty }
    }
}

// MARK: - Single-slot row

private struct HotKeySlotRow: View {
    @ObserveInjection var inject

    let title: String
    let subtitle: String
    let hotKey: HotKey?
    let isCapturing: Bool
    let currentModifiers: Modifiers
    let isConflicting: Bool
    let onTap: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Label column
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(subtitle)
                    .settingsCaption()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Chord display
            let displayModifiers = isCapturing ? currentModifiers : (hotKey?.modifiers ?? .init(modifiers: []))
            let displayKey: Key? = isCapturing ? nil : hotKey?.key

            HotKeyView(modifiers: displayModifiers, key: displayKey, isActive: isCapturing)
                .frame(minWidth: 100)
                .contentShape(Rectangle())
                .onTapGesture { onTap() }
                .overlay(alignment: .topTrailing) {
                    if isConflicting {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .offset(x: 4, y: -4)
                    }
                }

            // Clear button — only visible when a hotkey is bound
            if hotKey != nil, !isCapturing {
                Button("Clear") { onClear() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.15))
                    )
            }
        }
        .padding(.vertical, 4)
        .enableInjection()
    }
}

// MARK: - Slot display names

private extension HotkeyDispatcher.Slot {
    var displayName: String {
        switch self {
        case .liveHold:       return "Live · Hold"
        case .liveDoubleTap:  return "Live · Double-tap"
        case .batchHold:      return "Batch · Hold"
        case .batchDoubleTap: return "Batch · Double-tap"
        }
    }
}
