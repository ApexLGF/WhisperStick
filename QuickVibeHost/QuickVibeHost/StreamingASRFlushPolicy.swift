import Foundation

/// Keeps the realtime ASR tail away from the native engine's unsafe bulk-feed path.
/// The values are centralized so the production pipeline and stress tests exercise
/// the same chunk and fallback policy.
struct StreamingASRFlushPolicy {
    enum Action: Equatable {
        case flushInChunks
        case fallbackToSegment
    }

    struct Plan: Equatable {
        let action: Action
        let backlogSamples: Int
        let backlogMilliseconds: Int
        let chunkSamples: Int
        let chunkCount: Int
    }

    static let sampleRate = 16_000
    static let chunkSamples = 3_200
    /// If the engine is more than five seconds behind when recording stops,
    /// chasing the tail is both slow and risky. The caller retains the complete
    /// WAV and falls back to segment recognition instead.
    static let maxBacklogSamples = 5 * sampleRate

    static func plan(backlogSamples: Int) -> Plan {
        let safeSamples = max(0, backlogSamples)
        let action: Action = safeSamples > maxBacklogSamples
            ? .fallbackToSegment
            : .flushInChunks
        return Plan(
            action: action,
            backlogSamples: safeSamples,
            backlogMilliseconds: safeSamples * 1_000 / sampleRate,
            chunkSamples: chunkSamples,
            chunkCount: safeSamples == 0 ? 0 : (safeSamples + chunkSamples - 1) / chunkSamples
        )
    }
}
