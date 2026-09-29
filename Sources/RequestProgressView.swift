import SwiftUI

/// A visible status for real work, including the quiet wait before a first token.
/// The clock advances elapsed time only; it never invents completion progress.
struct RequestProgressView: View {
    let progress: RequestProgress
    let assistantState: AgentState
    let speechState: SpeechOutputState
    let detail: String
    let onStop: () -> Void
    var isFullControl = false
    private let accent = Color(red: 0.15, green: 0.66, blue: 0.49)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let waiting = progress.isWaitingForData(at: context.date)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    if assistantState == .reviewing {
                        Image(systemName: "hand.raised").foregroundStyle(accent)
                    } else if assistantState == .idle && speechState == .speaking {
                        Image(systemName: "speaker.wave.2.fill").foregroundStyle(accent)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(title).font(.system(size: 12, weight: .semibold))
                        .lineLimit(1).layoutPriority(1)
                    Spacer(minLength: 4)
                    Text("\(Int(progress.elapsed(at: context.date)))s elapsed")
                        .font(.system(size: 10, design: .monospaced)).monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("Stop", action: onStop).controlSize(.small)
                        .accessibilityLabel(assistantState == .idle ? "Stop speaking" : "Stop request")
                }
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true).help(message)
                if speechState != .idle && assistantState != .idle {
                    Label(speechState == .speaking ? "Voice reply is playing" : "Preparing the voice reply", systemImage: "speaker.wave.2")
                        .font(.system(size: 10)).foregroundStyle(accent)
                }
                if waiting {
                    Label("No new data for \(Int(progress.secondsSinceActivity(at: context.date)))s. You can stop and try again.", systemImage: "clock")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background((waiting ? Color.orange : accent).opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke((waiting ? Color.orange : accent).opacity(0.18)))
        }
    }

    private var title: String {
        switch assistantState {
        case .thinking: return isFullControl ? "Codex is working" : "Preparing your answer"
        case .searching: return "Searching the web"
        case .replying: return isFullControl ? "Codex update" : "Receiving your answer"
        case .reviewing: return "Waiting for your approval"
        case .running: return isFullControl ? "Codex is taking action" : "Running your action"
        case .idle: return progress.kind.title
        }
    }

    private var message: String {
        switch assistantState {
        case .thinking:
            if isFullControl { return detail.isEmpty ? "Waiting for Codex Astra…" : detail }
            let model = detail.components(separatedBy: " · ").first ?? detail
            return model.isEmpty ? "Waiting for the assistant to respond…" : "Waiting for \(model)…"
        case .searching: return detail.isEmpty ? "Waiting for search results…" : "Looking up: \(detail)"
        case .replying: return isFullControl ? "Codex's progress is shown below." : "The answer is arriving below."
        case .reviewing: return "Check the proposed action below, then choose Run."
        case .running: return isFullControl ? (detail.isEmpty ? "Working on your request. Activity appears below." : detail) : "The approved action is running. Its output appears below."
        case .idle:
            return speechState == .speaking ? "Playing your answer. Start another recording to interrupt." : "Waiting for Qwen to generate your voice reply…"
        }
    }
}
