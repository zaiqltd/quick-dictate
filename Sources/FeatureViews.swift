import AppKit
import SwiftUI

private let featureAccent = Color(red: 0.30, green: 0.80, blue: 0.65)

private struct ConversationScrollMetrics: Equatable {
    let originY: CGFloat
    let bottomY: CGFloat
    let viewportHeight: CGFloat
}

private struct ConversationScrollPreference: PreferenceKey {
    static var defaultValue: ConversationScrollMetrics? = nil
    static func reduce(value: inout ConversationScrollMetrics?, nextValue: () -> ConversationScrollMetrics?) {
        value = nextValue() ?? value
    }
}

struct FeatureSettingsView: View {
    @ObservedObject var settings: FeatureSettings
    @State private var validationError = ""
    @State private var codexAvailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Make it yours").font(.system(size: 17, weight: .semibold))
                Text("Dictation is always ready. Turn on the extras you want.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            featureCard {
                HStack(spacing: 10) {
                    featureIcon("waveform")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Dictate").font(.system(size: 13, weight: .semibold))
                        Text("Speak into any text field.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Always on").font(.system(size: 10, weight: .medium)).foregroundStyle(featureAccent)
                }
                shortcutPicker(for: .dictation)
            }
            featureCard {
                featureToggle("Polish", subtitle: "Clearer messages. Less filler. Still you.", symbol: "sparkles",
                              value: boolean(\.polishEnabled))
                if settings.options.polishEnabled {
                    shortcutPicker(for: .polish)
                    Text("Speak or paste rough text. GPT-6 Luna through OpenRouter cuts filler and repetition while keeping your meaning and tone. Your original stays available to copy.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Voice results paste into your text field without pressing Send. Typed results stay here to copy. Nothing is saved to history.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            featureCard {
                featureToggle("Ask", subtitle: "Talk through a question. Get an answer.", symbol: "bubble.left.and.bubble.right",
                              value: boolean(\.askEnabled))
                if settings.options.askEnabled { shortcutPicker(for: .ask) }
            }
            featureCard {
                featureToggle("Do", subtitle: "Ask for an action. Review it before it runs.", symbol: "command",
                              value: boolean(\.actEnabled))
                if settings.options.actEnabled {
                    shortcutPicker(for: .act)
                    Divider().padding(.vertical, 2)
                    VStack(alignment: .leading, spacing: 10) {
                        capabilityToggle("Terminal commands", detail: "Run a command after you approve its exact text.", value: boolean(\.terminalEnabled))
                        capabilityToggle("Open apps, files & websites", detail: "Open an item after you approve it.", value: boolean(\.computerEnabled))
                    }
                    if !settings.options.terminalEnabled && !settings.options.computerEnabled {
                        Text("Enable an action above to let Do carry out requests.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            featureCard {
                featureToggle("Full Control", subtitle: "Hand the whole task to Codex.", symbol: "bolt.fill",
                              value: boolean(\.fullControlEnabled))
                if settings.options.fullControlEnabled {
                    shortcutPicker(for: .fullControl)
                    Divider().padding(.vertical, 2)
                    Label("Codex Astra · Medium", systemImage: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Full access · no command approvals")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(featureAccent)
                    Text("Build projects, run commands, and open apps and websites. Codex runs with your Mac user's access; macOS permissions still apply.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Uses the installed Codex CLI and your primary Codex login. Requests go to Codex. Conversations clear when switching between Codex and Ask or Do.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Label(codexAvailable ? "Codex CLI found" : "Codex CLI not found. Install it and sign in to your primary account.",
                          systemImage: codexAvailable ? "checkmark.circle" : "exclamationmark.circle")
                        .font(.system(size: 10)).foregroundStyle(codexAvailable ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider().padding(.vertical, 2)
                    capabilityToggle("Use Codex screen control when needed", detail: "Let Codex use its available screen-control tools for your task. Codex manages the required macOS permissions.", value: boolean(\.fullControlScreenEnabled))
                    if settings.options.fullControlScreenEnabled {
                        Text("Screenshots are taken only when Codex needs one for your task and are sent to Codex.")
                            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if settings.options.fullControlEnabled || (settings.options.actEnabled && (settings.options.terminalEnabled || settings.options.computerEnabled)) {
                featureCard { workFolder }
            }
            if settings.options.askEnabled || settings.options.actEnabled || settings.options.fullControlEnabled {
                featureCard {
                    VStack(alignment: .leading, spacing: 8) {
                        if settings.options.askEnabled || settings.options.actEnabled {
                            Text("Ask & Do model").font(.system(size: 12, weight: .semibold))
                            Picker("Model", selection: Binding(get: { settings.options.model }, set: { value in update { $0.model = value } })) {
                                ForEach(AgentModel.presets) { model in Text(model.title).tag(model.id) }
                            }.pickerStyle(.segmented).labelsHidden()
                            if let model = AgentModel.presets.first(where: { $0.id == settings.options.model }) {
                                Text(model.detail).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Divider().padding(.vertical, 2)
                        }
                        capabilityToggle("Speak voice replies", detail: "Voice questions are answered aloud automatically. Typed replies stay quiet; choose Speak to hear one.", value: boolean(\.speakReplies))
                        Text("Qwen Audio 3.0 Plus · natural cloud voice")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        if settings.options.askEnabled || settings.options.actEnabled {
                            capabilityToggle("Search when needed", detail: "Ask and Do can look up fresh facts and include sources. Search queries go to Parallel through OpenRouter.", value: boolean(\.webSearchEnabled))
                        }
                        capabilityToggle("Include selected text", detail: "Send text you select as context when using an assistant shortcut.", value: boolean(\.useSelectedText))
                    }
                }
                Text("Ask and Do use OpenRouter; Full Control uses Codex. Spoken reply text goes to the cloud voice model. Quick Dictate keeps conversations in memory until you start a new chat or quit.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
            if !validationError.isEmpty {
                Label(validationError, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityLabel("Settings error: \(validationError)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: refreshCodexAvailability)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshCodexAvailability() }
    }

    private var workFolder: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Working folder").font(.system(size: 11, weight: .medium))
                    Text(settings.options.workRoot).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(settings.options.workRoot)
                }
                Spacer(minLength: 0)
                Button("Choose…", action: chooseFolder).controlSize(.small)
            }
            Text(settings.options.fullControlEnabled
                 ? "Codex starts here. This folder is not a sandbox: Full Control can access other locations available to your Mac user."
                 : settings.options.terminalEnabled
                   ? "Terminal commands run with your Mac user privileges. This folder is a starting location, not a sandbox. Reviewed action output goes to your selected model through OpenRouter."
                   : "File actions stay inside this folder. Each action needs your approval; its result goes to your selected model through OpenRouter.")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 4)
    }

    private func shortcutPicker(for mode: VoiceMode) -> some View {
        HStack {
            Text("Hold to talk").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Picker("\(mode.title) shortcut", selection: Binding(
                get: { settings.options.binding(for: mode) },
                set: { value in update { $0.shortcuts[mode.rawValue] = value } }
            )) {
                ForEach(KeyboardShortcutBinding.presets) { binding in
                    Text(binding.displayLabel).tag(binding)
                }
            }
            .labelsHidden().pickerStyle(.menu).frame(width: 115)
            .accessibilityLabel("\(mode.title) keyboard shortcut")
        }.padding(.top, 4)
    }

    private func featureToggle(_ title: String, subtitle: String, symbol: String, value: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            featureIcon(symbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .accessibilityLabel("Enable \(title)")
        }
    }

    private func capabilityToggle(_ title: String, detail: String, value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 11, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.toggleStyle(.switch).controlSize(.small)
            .accessibilityLabel(title).help(detail)
    }

    private func featureIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 15, weight: .medium)).foregroundStyle(featureAccent)
            .frame(width: 34, height: 34).background(featureAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    private func featureCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }

    private func boolean(_ keyPath: WritableKeyPath<FeatureOptions, Bool>) -> Binding<Bool> {
        Binding(get: { settings.options[keyPath: keyPath] }, set: { value in update { $0[keyPath: keyPath] = value } })
    }

    private func update(_ mutation: (inout FeatureOptions) -> Void) {
        do { try settings.update(mutation); validationError = "" }
        catch { validationError = error.localizedDescription }
    }

    private func refreshCodexAvailability() {
        codexAvailable = CodexCLI.locateExecutable() != nil
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the assistant's working folder"
        panel.message = "Commands and Codex tasks start here. This folder does not limit Full Control's access."
        panel.prompt = "Choose folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: settings.options.workRoot)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            update { $0.workRoot = url.resolvingSymlinksInPath().path }
        }
    }
}

struct AgentPanelView: View {
    @ObservedObject var session: AgentSession
    let mode: VoiceMode
    var voiceBusy = false
    @State private var copied = false
    @State private var showsActivity = false
    @State private var followsLatest = true
    @State private var lastScrollMetrics: ConversationScrollMetrics?

    private var lastAnswer: String? { session.turns.last(where: { $0.role == .assistant })?.text }
    private var canSend: Bool { !voiceBusy && !session.isBusy && !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var voiceActive: Bool { session.speechState != .idle }
    private var canReplay: Bool { !voiceBusy && !session.isBusy && !voiceActive && lastAnswer != nil }

    var body: some View {
        VStack(spacing: 10) {
            if mode == .fullControl {
                Label("Full access · Codex Astra · Medium", systemImage: "bolt.fill")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(featureAccent)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(featureAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Full Control: full access, Codex Astra, medium reasoning. Commands run without individual approvals.")
            }
            HStack(spacing: 9) {
                Text(stateLabel)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1).layoutPriority(1)
                if let progress = session.progress, !progress.isActive {
                    Text("\(Int(progress.elapsed(at: Date())))s total")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                } else if !session.isBusy && !voiceActive && !session.elapsed.isEmpty {
                    Text(session.elapsed).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Speak", action: session.replayLast)
                    .buttonStyle(.plain).font(.system(size: 10)).disabled(!canReplay)
                    .accessibilityLabel("Speak last answer").help("Read the last answer aloud")
                Button(action: copyAnswer) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(.plain).disabled(lastAnswer == nil)
                .accessibilityLabel(copied ? "Answer copied" : "Copy answer").help(copied ? "Copied" : "Copy answer")
                Button("New chat") { followsLatest = true; lastScrollMetrics = nil; session.newChat(); copied = false }
                    .buttonStyle(.plain).font(.system(size: 10))
                    .disabled(voiceBusy || (session.turns.isEmpty && !session.isBusy && !voiceActive))
                if (session.isBusy || voiceActive) && session.progress == nil {
                    Button("Stop", action: session.cancel).controlSize(.small)
                        .accessibilityLabel(session.isBusy ? "Stop request" : "Stop speaking")
                }
            }
            if let progress = session.progress, progress.isActive, !voiceBusy {
                RequestProgressView(progress: progress, assistantState: session.state,
                                    speechState: session.speechState, detail: session.activityDetail,
                                    onStop: session.cancel, isFullControl: mode == .fullControl)
            }
            if !session.activityLog.isEmpty { activityDisclosure }
            ScrollViewReader { proxy in
                GeometryReader { viewport in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if session.turns.isEmpty { welcome }
                            ForEach(session.turns) { turn in turnView(turn).id(turn.id) }
                            if !session.streamingText.isEmpty && (session.state == .thinking || session.state == .replying || mode == .fullControl) {
                                streamingReply.id("streaming-answer")
                            }
                            if session.state == .reviewing, let proposal = session.pending.first {
                                reviewCard(proposal).id("review-\(proposal.id)")
                            }
                            if session.state == .running || (mode == .fullControl && session.isBusy && !session.liveOutput.isEmpty) { runningOutput }
                            if !session.error.isEmpty {
                                Label(session.error, systemImage: "exclamationmark.circle")
                                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                                    .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            }
                            Color.clear.frame(height: 1).id("conversation-bottom")
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background {
                                GeometryReader { content in
                                    let frame = content.frame(in: .named("agent-conversation-scroll"))
                                    Color.clear.preference(key: ConversationScrollPreference.self, value: ConversationScrollMetrics(
                                        originY: frame.minY, bottomY: frame.maxY, viewportHeight: viewport.size.height))
                                }
                            }
                    }
                    .coordinateSpace(name: "agent-conversation-scroll")
                    .onPreferenceChange(ConversationScrollPreference.self) { metrics in
                        guard let metrics else { return }
                        // Content growth changes the bottom edge, not the user's
                        // scroll offset. Keep following until the user moves away;
                        // otherwise a large streamed chunk would disable itself.
                        if let previous = lastScrollMetrics,
                           abs(previous.viewportHeight - metrics.viewportHeight) < 0.5,
                           abs(previous.originY - metrics.originY) > 0.5 {
                            followsLatest = metrics.bottomY <= metrics.viewportHeight + 48
                        }
                        lastScrollMetrics = metrics
                    }
                    .onChange(of: viewport.size.height) { _, _ in scrollToEnd(proxy) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
                .onChange(of: session.turns.last?.id) { _, _ in
                    if session.turns.last?.role == .user || session.turns.isEmpty { followsLatest = true }
                    scrollToEnd(proxy)
                }
                .onChange(of: session.state) { _, _ in scrollToEnd(proxy) }
                .onChange(of: session.error) { _, _ in scrollToEnd(proxy) }
                .onChange(of: session.streamingText) { _, _ in scrollToEnd(proxy) }
            }
            HStack(spacing: 8) {
                WordTextField(placeholder: composePlaceholder, text: $session.draft, onSubmit: send)
                    .frame(height: 27)
                Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)).frame(width: 25, height: 23) }
                    .buttonStyle(.borderedProminent).tint(featureAccent).disabled(!canSend)
                    .accessibilityLabel("Send request").help("Send request")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: session.turns.count) { _, _ in copied = false }
            .onAppear { if mode == .fullControl { showsActivity = true } }
            .onChange(of: mode) { _, newMode in showsActivity = newMode == .fullControl }
    }

    private var stateLabel: String {
        guard panelActivity == .idle else { return panelActivity.title }
        if session.progress?.kind == .failed { return "Request interrupted" }
        if session.progress?.kind == .stopped { return "Stopped" }
        return "Conversation"
    }

    private var panelActivity: VoiceActivity {
        let assistant: VoiceActivity.Assistant
        switch session.state {
        case .idle: assistant = .idle
        case .thinking: assistant = .thinking
        case .searching: assistant = .searching
        case .replying: assistant = .replying
        case .reviewing: assistant = .reviewing
        case .running: assistant = .running
        }
        let speech: VoiceActivity.Speech
        switch session.speechState {
        case .idle: speech = .idle
        case .preparing: speech = .preparing
        case .speaking: speech = .speaking
        }
        return VoiceActivity.resolve(capture: .idle, assistant: assistant, speech: speech)
    }

    private var activityDisclosure: some View {
        DisclosureGroup(isExpanded: $showsActivity) {
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(session.activityLog.enumerated()), id: \.offset) { _, entry in
                        Text(entry).font(.system(size: 10)).foregroundStyle(.secondary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.top, 5)
            }.frame(maxHeight: mode == .fullControl ? 90 : 72)
        } label: {
            HStack(spacing: 7) {
                Text("Activity").font(.system(size: 10, weight: .medium))
                if !session.activityDetail.isEmpty {
                    Text(session.activityDetail).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
        }
        .foregroundStyle(.secondary)
    }

    private var streamingReply: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(mode == .fullControl ? "CODEX" : "ASSISTANT").font(.system(size: 9, weight: .semibold)).tracking(0.7)
                .foregroundStyle(featureAccent)
            Text(session.streamingText).font(.system(size: 12)).lineSpacing(3)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: mode.symbol)
                .font(.system(size: 24, weight: .light)).foregroundStyle(featureAccent)
            Text(welcomeTitle)
                .font(.system(size: 17, weight: .semibold))
            Text(welcomeDetail)
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            Text(welcomeExample)
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 3).fixedSize(horizontal: false, vertical: true)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composePlaceholder: String {
        switch mode {
        case .fullControl: return "Give Codex a task…"
        case .act: return "Ask me to do something…"
        default: return "Ask me anything…"
        }
    }

    private var welcomeTitle: String {
        switch mode {
        case .fullControl: return "From request to done."
        case .act: return "Say what you want done."
        default: return "A thought partner, one hold away."
        }
    }

    private var welcomeDetail: String {
        switch mode {
        case .fullControl: return "Speak or type the task. Codex can work through it, run commands, build projects, and open apps or websites. Follow its updates here; Stop ends the current run."
        case .act: return "Describe the task by voice or type below. You'll see each proposed action before choosing Run."
        default: return "Ask a question, work through an idea, or get help with text you've selected."
        }
    }

    private var welcomeExample: String {
        switch mode {
        case .fullControl: return "Try: “Build a simple timer app in a new folder and open it.”"
        case .act: return "Try: “Show me the files in my working folder.”"
        default: return "Try: “Help me turn this idea into a clear plan.”"
        }
    }

    private func turnView(_ turn: AgentTurn) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(turnLabel(turn.role))
                .font(.system(size: 9, weight: .semibold)).tracking(0.7)
                .foregroundStyle(turn.role == .user ? Color.secondary : featureAccent)
            Text(turn.text).font(.system(size: turn.role == .action ? 11 : 12, design: turn.role == .action ? .monospaced : .default))
                .lineSpacing(3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !turn.sources.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(turn.sources) { source in
                        Link(destination: source.url) {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "globe").font(.system(size: 9)).padding(.top, 2)
                                Text(source.title.isEmpty ? source.url.host ?? "Source" : source.title)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                                Image(systemName: "arrow.up.right").font(.system(size: 8)).padding(.top, 2)
                            }.font(.system(size: 10))
                        }.foregroundStyle(featureAccent).help(source.url.absoluteString)
                    }
                }.padding(.top, 5)
            }
        }
        .padding(11).frame(maxWidth: .infinity, alignment: .leading)
        .background(turn.role == .user ? Color.primary.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
    }

    private func turnLabel(_ role: AgentTurn.Role) -> String {
        switch role {
        case .user: return "YOU"
        case .assistant: return mode == .fullControl ? "CODEX" : "ASSISTANT"
        case .action: return "ACTION RESULT"
        case .search: return "SEARCH"
        case .activity: return "CODEX UPDATE"
        }
    }

    private func reviewCard(_ proposal: PendingAgentAction) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label("Review action", systemImage: "hand.raised").font(.system(size: 11, weight: .semibold)).foregroundStyle(featureAccent)
                Spacer()
                if session.pending.count > 1 { Text("\(session.pending.count) waiting").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            Text(proposal.action.title).font(.system(size: 14, weight: .semibold))
            Text(proposal.action.detail).font(.system(size: 11, design: .monospaced)).lineSpacing(3)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text("Chosen folder: \(proposal.workRoot.path)").font(.system(size: 10)).textSelection(.enabled)
                if case .shell = proposal.action {
                    Text("Runs with your Mac user privileges. The chosen folder is not a sandbox.")
                        .font(.system(size: 10))
                }
                Text("The result is sent to your selected model through OpenRouter.").font(.system(size: 10))
            }.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", action: session.cancel).controlSize(.small)
                Spacer()
                Button("Run", action: session.approveNext).buttonStyle(.borderedProminent).tint(featureAccent).controlSize(.small)
                    .accessibilityLabel("Run reviewed action")
            }
        }
        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
        .background(featureAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(featureAccent.opacity(0.25), lineWidth: 1))
    }

    private var runningOutput: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                ProgressView().controlSize(.mini)
                Text("Live output").font(.system(size: 11, weight: .medium))
                Spacer()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(session.liveOutput.isEmpty ? "Waiting for output…" : session.liveOutput)
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("output-bottom")
                }.frame(height: 120)
                    .onChange(of: session.liveOutput) { _, _ in proxy.scrollTo("output-bottom", anchor: .bottom) }
            }
        }.padding(11).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func send() {
        guard canSend else { return }
        followsLatest = true
        session.send(session.draft, mode: mode)
    }

    private func copyAnswer() {
        guard let answer = lastAnswer else { return }
        Paste.copy(answer)
        copied = true
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            guard followsLatest else { return }
            if session.state == .reviewing, let proposal = session.pending.first {
                proxy.scrollTo("review-\(proposal.id)", anchor: .top)
            } else {
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }
        }
    }
}
