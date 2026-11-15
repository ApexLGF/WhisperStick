import Combine
import CryptoKit
import Foundation

enum TaskLifecycleProvider: String, Sendable {
    case codex
    case claude
    case workbuddy
}

enum TaskLifecycleOutcome: Sendable {
    case started
    case completed
    case cancelled
    case failed
    /// Local observation lease expired without a provider terminal event.
    /// Clear dedupe state silently so the next real Prompt can start normally.
    case expired
}

struct TaskLifecycleSignal: Sendable {
    let provider: TaskLifecycleProvider
    let sessionID: String
    let turnID: String
    let outcome: TaskLifecycleOutcome
}

/// WorkBuddy does not expose a prompt/turn event stream. Its local database
/// does expose durable session status edges, so convert only real transitions
/// observed after the initial snapshot into lifecycle signals. Repeated polls
/// of the same status intentionally produce no event.
enum WorkBuddyLifecycleMapper {
    static func outcome(previousStatus: String, currentStatus: String) -> TaskLifecycleOutcome? {
        let previous = state(for: previousStatus)
        let current = state(for: currentStatus)
        guard previous != current else { return nil }

        if current == .processing,
           previous != .processing,
           previous != .waitingForInput {
            return .started
        }
        guard previous == .processing else { return nil }
        switch current {
        case .completed: return .completed
        case .cancelled: return .cancelled
        case .failed: return .failed
        case .idle, .processing, .waitingForInput: return nil
        }
    }

    private enum State: Equatable {
        case idle
        case processing
        case waitingForInput
        case completed
        case cancelled
        case failed
    }

    private static func state(for status: String) -> State {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "working", "running", "processing": return .processing
        case "waiting", "waiting_for_input", "awaiting_input", "needs_input":
            return .waitingForInput
        case "completed", "done", "success": return .completed
        case "terminated", "cancelled", "canceled": return .cancelled
        case "failed", "error": return .failed
        default: return .idle
        }
    }
}

/// Converts provider-specific events into one start and one terminal sound per
/// user prompt. Status frames remain independent and continue to drive LEDs.
@MainActor
final class TaskLifecycleCoordinator: ObservableObject {
    weak var bleManager: BLEManager?

    private var activeTurns: [String: String] = [:]

    func handle(_ signal: TaskLifecycleSignal) {
        let sessionKey = Self.normalizedSessionKey(signal.sessionID)
        switch signal.outcome {
        case .started:
            // A hook and the rollout can both report the same start. A session
            // has only one outer user turn at a time, so suppress the duplicate.
            guard activeTurns[sessionKey] == nil else { return }
            guard bleManager?.sendTaskLifecycleEvent(
                .started,
                eventID: Self.eventID(provider: signal.provider, session: sessionKey,
                                      turn: signal.turnID, terminal: "start")
            ) == true else { return }
            activeTurns[sessionKey] = signal.turnID

        case .expired:
            activeTurns.removeValue(forKey: sessionKey)

        case .completed, .cancelled, .failed:
            // Never replay an orphan terminal event after App launch/reconnect.
            guard let activeTurn = activeTurns.removeValue(forKey: sessionKey) else { return }
            let kind: BLEManager.TaskLifecycleWireKind = signal.outcome == .failed ? .failed : .completed
            bleManager?.sendTaskLifecycleEvent(
                kind,
                eventID: Self.eventID(provider: signal.provider, session: sessionKey,
                                      turn: activeTurn, terminal: kind == .failed ? "failed" : "complete")
            )
        }
    }

    private static func normalizedSessionKey(_ value: String) -> String {
        value.split(separator: ":", maxSplits: 1).last.map(String.init) ?? value
    }

    private static func eventID(provider: TaskLifecycleProvider, session: String,
                                turn: String, terminal: String) -> Data {
        let source = Data("\(provider.rawValue)|\(session)|\(turn)|\(terminal)".utf8)
        return Data(SHA256.hash(data: source).prefix(16))
    }
}
