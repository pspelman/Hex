import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct GeneralSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		Section {
			Label {
				Toggle("Open on Login",
				       isOn: Binding(
				       	get: { store.hexSettings.openOnLogin },
				       	set: { store.send(.toggleOpenOnLogin($0)) }
				       ))
			} icon: {
				Image(systemName: "arrow.right.circle")
			}

			Label {
				Toggle(
					"Show Dock Icon",
					isOn: Binding(
						get: { store.hexSettings.showDockIcon },
						set: { store.send(.toggleShowDockIcon($0)) }
					)
				)
			} icon: {
				Image(systemName: "dock.rectangle")
			}

			Label {
				Toggle(
					"Use clipboard to insert",
					isOn: Binding(
						get: { store.hexSettings.useClipboardPaste },
						set: { store.send(.setUseClipboardPaste($0)) }
					)
				)
				Text("Use clipboard to insert text. Fast but may not restore all clipboard content.\nTurn off to use simulated keypresses. Slower, but doesn't need to restore clipboard")
			} icon: {
				Image(systemName: "doc.on.doc.fill")
			}

			Label {
				Toggle(
					"Copy to clipboard",
					isOn: Binding(
						get: { store.hexSettings.copyToClipboard },
						set: { store.send(.setCopyToClipboard($0)) }
					)
				)
				Text("Copy transcription text to clipboard in addition to pasting it")
			} icon: {
				Image(systemName: "doc.on.clipboard")
			}

			Label {
				Toggle(
					"Prevent System Sleep while Recording",
					isOn: Binding(
						get: { store.hexSettings.preventSystemSleep },
						set: { store.send(.togglePreventSystemSleep($0)) }
					)
				)
			} icon: {
				Image(systemName: "zzz")
			}

			Label {
				Toggle(
					"Super Fast Mode",
					isOn: Binding(
						get: { store.hexSettings.superFastModeEnabled },
						set: { store.send(.toggleSuperFastMode($0)) }
					)
				)
				Text("Keep the microphone warm and prepend a short in-memory buffer for near-instant capture. macOS will keep showing the microphone indicator while this mode is armed.")
			} icon: {
				Image(systemName: "bolt.circle")
			}

			Label {
				HStack(alignment: .center) {
					Text("Audio Behavior while Recording")
				Spacer()
					Picker("", selection: Binding(
						get: { store.hexSettings.recordingAudioBehavior },
						set: { store.send(.setRecordingAudioBehavior($0)) }
					)) {
						Label("Pause Media", systemImage: "pause")
							.tag(RecordingAudioBehavior.pauseMedia)
						Label("Mute Volume", systemImage: "speaker.slash")
							.tag(RecordingAudioBehavior.mute)
						Label("Do Nothing", systemImage: "hand.raised.slash")
							.tag(RecordingAudioBehavior.doNothing)
					}
					.pickerStyle(.menu)
				}
			} icon: {
				Image(systemName: "speaker.wave.2")
			}

			Label {
				VStack(alignment: .leading, spacing: 6) {
					Toggle(
						"Live Transcription (experimental)",
						isOn: Binding(
							get: { store.hexSettings.liveTranscriptionEnabled },
							set: { store.send(.setLiveTranscriptionEnabled($0)) }
						)
					)
					Text("Stream text into the focused field as you speak. Requires a separate ~250 MB model download and Accessibility permission.")
						.settingsCaption()

					if store.hexSettings.liveTranscriptionEnabled {
						HStack {
							Text("Chunk Size")
							Spacer()
							Picker("", selection: Binding(
								get: { store.hexSettings.liveTranscriptionChunkSize },
								set: { store.send(.setLiveTranscriptionChunkSize($0)) }
							)) {
								Text("160 ms (lowest latency)").tag(LiveTranscriptionChunkSize.ms160)
								Text("320 ms (more accurate)").tag(LiveTranscriptionChunkSize.ms320)
							}
							.pickerStyle(.menu)
							.fixedSize()
						}

						Divider()

						liveModelStatusView
					}
				}
			} icon: {
				Image(systemName: "waveform.badge.mic")
			}
		} header: {
			Text("General")
		}
		.enableInjection()
	}

	@ViewBuilder
	private var liveModelStatusView: some View {
		VStack(alignment: .leading, spacing: 6) {
			if store.isLiveModelDownloading {
				HStack(spacing: 8) {
					ProgressView(value: store.liveModelDownloadProgress)
						.progressViewStyle(.linear)
					Text(progressText)
						.font(.caption.monospacedDigit())
						.foregroundStyle(.secondary)
						.frame(width: 56, alignment: .trailing)
				}
				Text("Downloading the streaming EOU model. This is a one-time \(humanModelSize) download.")
					.settingsCaption()
			} else if store.isLiveModelReady {
				HStack(spacing: 8) {
					Image(systemName: "checkmark.circle.fill")
						.foregroundStyle(.green)
					Text("Streaming model installed")
						.font(.body)
					Spacer()
				}
			} else {
				HStack(spacing: 8) {
					Image(systemName: "arrow.down.circle")
						.foregroundStyle(.secondary)
					Text("Streaming model not yet downloaded")
						.font(.body)
					Spacer()
					Button {
						store.send(.downloadLiveModel)
					} label: {
						Text("Download Model")
					}
					.buttonStyle(.borderedProminent)
					.controlSize(.small)
				}
				Text("About \(humanModelSize). Required for live transcription. The standard Hex transcription model is unaffected.")
					.settingsCaption()
			}

			if let errorMessage = store.liveModelError {
				Label {
					Text(errorMessage)
						.font(.caption)
						.foregroundStyle(.red)
				} icon: {
					Image(systemName: "exclamationmark.triangle.fill")
						.foregroundStyle(.red)
				}
			}
		}
	}

	private var progressText: String {
		let pct = Int((store.liveModelDownloadProgress * 100).rounded())
		return "\(pct)%"
	}

	private var humanModelSize: String { "~250 MB" }
}
