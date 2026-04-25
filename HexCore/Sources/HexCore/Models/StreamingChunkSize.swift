import Foundation

/// Hex-side mirror of FluidAudio's `StreamingChunkSize`.
///
/// Stored in `HexSettings` so the user's preference can be encoded without importing FluidAudio.
/// Map to `FluidAudio.StreamingChunkSize` at the client boundary when constructing the ASR manager.
public enum LiveTranscriptionChunkSize: String, Codable, CaseIterable, Sendable, Equatable {
	/// 160 ms output shift — lowest latency, higher word-error rate.
	case ms160
	/// 320 ms output shift — balanced latency/accuracy; the recommended default.
	case ms320

	/// Approximate perceived latency in milliseconds (equals the output shift).
	public var perceivedLatencyMs: Int {
		switch self {
		case .ms160: return 160
		case .ms320: return 320
		}
	}
}
