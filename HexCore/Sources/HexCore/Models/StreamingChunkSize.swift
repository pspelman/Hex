import Foundation

/// Hex-side mirror of FluidAudio's `StreamingChunkSize`.
///
/// Stored in `HexSettings` so the user's preference can be encoded without importing FluidAudio.
/// Map to `FluidAudio.StreamingChunkSize` at the client boundary when constructing the ASR manager.
public enum LiveTranscriptionChunkSize: String, Codable, CaseIterable, Sendable, Equatable {
	/// 160 ms output shift — lowest latency, higher word-error rate.
	case ms160
	/// 320 ms output shift — balanced latency/accuracy.
	case ms320
	/// 1600 ms output shift — highest accuracy (20 valid encoder frames per chunk),
	/// noticeable conversational lag. Recommended for users who prefer accuracy over realtime feel.
	case ms1600

	/// Approximate perceived latency in milliseconds (equals the output shift).
	public var perceivedLatencyMs: Int {
		switch self {
		case .ms160: return 160
		case .ms320: return 320
		case .ms1600: return 1600
		}
	}
}
