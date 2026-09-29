import Foundation

/// A snapshot of observed work. Reading elapsed/stall values never advances a
/// stage or changes a timestamp; the UI can render it with a TimelineView.
struct RequestProgress: Equatable {
    enum Kind: String, Equatable, CaseIterable {
        case thinking, searching, replying, preparingVoice, speaking, reviewing, running
        case complete, stopped, failed

        var title: String {
            switch self {
            case .thinking: return "Thinking"
            case .searching: return "Searching"
            case .replying: return "Replying"
            case .preparingVoice: return "Preparing voice"
            case .speaking: return "Speaking"
            case .reviewing: return "Waiting for your review"
            case .running: return "Running"
            case .complete: return "Complete"
            case .stopped: return "Stopped"
            case .failed: return "Interrupted"
            }
        }
        var isTerminal: Bool { self == .complete || self == .stopped || self == .failed }
        var awaitsRemoteData: Bool {
            self == .thinking || self == .searching || self == .replying || self == .preparingVoice
        }
    }

    let requestStartedAt: Date
    private(set) var stageStartedAt: Date
    private(set) var lastActivityAt: Date
    private(set) var finishedAt: Date?
    private(set) var kind: Kind
    var isActive: Bool { finishedAt == nil }

    init(kind: Kind = .thinking, at date: Date) {
        self.kind = kind
        requestStartedAt = date
        stageStartedAt = date
        lastActivityAt = date
        finishedAt = kind.isTerminal ? date : nil
    }

    /// Call only for a real stage change, model delta, returned result, command
    /// output or playback state event. Terminal snapshots ignore late updates.
    mutating func record(_ next: Kind, at date: Date) {
        guard isActive else { return }
        let time = max(date, lastActivityAt)
        if kind != next { kind = next; stageStartedAt = time }
        lastActivityAt = time
        if next.isTerminal { finishedAt = time }
    }

    func elapsed(at date: Date) -> TimeInterval {
        max(0, (finishedAt ?? date).timeIntervalSince(requestStartedAt))
    }
    func stageElapsed(at date: Date) -> TimeInterval {
        max(0, (finishedAt ?? date).timeIntervalSince(stageStartedAt))
    }
    func secondsSinceActivity(at date: Date) -> TimeInterval {
        max(0, (finishedAt ?? date).timeIntervalSince(lastActivityAt))
    }
    func isWaitingForData(at date: Date, threshold: TimeInterval = 12) -> Bool {
        isActive && kind.awaitsRemoteData && secondsSinceActivity(at: date) >= max(0, threshold)
    }
}
