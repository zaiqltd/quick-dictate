import SwiftUI

// A clock readout, not a progress simulation. Capture uses its own start time
// because the assistant request does not exist until transcription completes.
struct PipelineTimelineView: View {
    let activity: VoiceActivity
    var detail: String = ""
    var assistantLabel: String = "Luna"
    var includesVoice = true
    var captureStartedAt: Date?
    var progress: RequestProgress?
    var stopLabel: String?
    let onStop: () -> Void
    @State private var timelineAnchor = Date()

    var body: some View {
        TimelineView(.periodic(from: timelineAnchor, by: 1)) { context in
            let duration = stageElapsed(at: context.date)
            PipelineNavigationView(activity: activity, detail: detail(at: context.date, elapsed: duration),
                                   assistantLabel: assistantLabel,
                                   includesVoice: includesVoice,
                                   elapsedLabel: duration.map(Self.elapsedLabel) ?? "",
                                   statusTitle: finishedTitle,
                                   stopLabel: stopLabel, onStop: onStop)
        }
    }

    private func stageElapsed(at date: Date) -> TimeInterval? {
        guard activity.isActive else { return nil }
        if let captureStartedAt { return max(0, date.timeIntervalSince(captureStartedAt)) }
        guard let progress, progress.isActive else { return nil }
        return progress.stageElapsed(at: date)
    }

    private func detail(at date: Date, elapsed: TimeInterval?) -> String {
        if !activity.isActive, progress?.kind == .failed { return "See the error below and try again" }
        if !activity.isActive, progress?.kind == .stopped { return "Ready for another request" }
        if activity == .transcribing, let elapsed, elapsed >= 12 {
            return "Still waiting for transcription"
        }
        if activity == .polishing, let elapsed, elapsed >= 12 {
            return "Still waiting for polished text"
        }
        if captureStartedAt == nil, activity.isActive, let progress, progress.isWaitingForData(at: date) {
            return "No new data for \(Self.elapsedLabel(progress.secondsSinceActivity(at: date)))"
        }
        return detail
    }

    private var finishedTitle: String? {
        guard !activity.isActive else { return nil }
        if progress?.kind == .failed { return "Interrupted" }
        if progress?.kind == .stopped { return "Stopped" }
        return nil
    }

    static func elapsedLabel(_ duration: TimeInterval) -> String {
        let seconds = duration.isFinite ? max(0, Int(duration)) : 0
        if seconds < 60 { return "\(seconds)s" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// Shows the current stage only; inactive stages are neither marked completed
// nor assigned invented percentage progress. Suitable above the hold card.
struct PipelineNavigationView: View {
    let activity: VoiceActivity
    var detail: String = ""
    var assistantLabel: String = "Luna"
    var includesVoice = true
    var elapsedLabel: String = ""
    var statusTitle: String?
    var stopLabel: String?
    let onStop: () -> Void
    private let accent = Color(red: 0.15, green: 0.66, blue: 0.49)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                ForEach(VoiceActivity.PipelineStage.allCases.filter { includesVoice || $0 != .voice }) { stage in
                    stageLabel(stage)
                    if stage != (includesVoice ? .voice : .assistant) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .semibold)).foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Voice pipeline. \(statusTitle ?? activity.title).")
            HStack(spacing: 7) {
                if activity.showsSpinner {
                    ProgressView().controlSize(.mini).frame(width: 13, height: 13)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: activity.symbol).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(activity.isActive ? accent : Color.secondary)
                        .frame(width: 13, height: 13).accessibilityHidden(true)
                }
                Text(statusTitle ?? activity.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    .layoutPriority(1)
                if !elapsedLabel.isEmpty {
                    Text(elapsedLabel).font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary).fixedSize()
                        .accessibilityLabel("Current stage elapsed \(elapsedLabel)")
                }
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail).help(detail)
                }
                Spacer(minLength: 3)
                if activity.isActive {
                    Button(action: onStop) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(stopLabel ?? activity.stopLabel).help(stopLabel ?? activity.stopLabel)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.05)))
    }

    private func stageLabel(_ stage: VoiceActivity.PipelineStage) -> some View {
        let selected = activity.pipelineStage == stage
        return HStack(spacing: 4) {
            Image(systemName: stage == .assistant && activity == .searching ? "globe" : stage.symbol)
                .font(.system(size: 9, weight: .medium))
            Text(stage == .assistant ? assistantLabel : stage.title).font(.system(size: 10, weight: selected ? .semibold : .regular))
                .lineLimit(1)
        }
        .foregroundStyle(selected ? accent : Color.secondary)
        .padding(.horizontal, 5).padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(selected ? accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
    }
}
