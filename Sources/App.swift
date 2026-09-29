import Cocoa
import SwiftUI
import AVFoundation
import ServiceManagement
import Combine

enum Phase: Equatable { case idle, requestingMic, recording, transcribing, polishing }
enum HoldSource { case shortcut, button, accessibility }
enum DictionarySheet: String, Identifiable { case correction, words; var id: String { rawValue } }

@MainActor final class DictationApp: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var phase: Phase = .idle {
        didSet { if phase != oldValue { phaseStartedAt = Date() } }
    }
    @Published private(set) var phaseStartedAt = Date()
    @Published var status = "Ready when you are."
    @Published var lastText = ""
    @Published var error = ""
    @Published var seconds = 0
    @Published var level = 0.0
    @Published var micAllowed = false
    @Published var pasteAllowed = false
    @Published var keyPresent = false
    @Published var settingsVisible = false
    @Published var retryAvailable = false
    @Published var launchAtLogin = false
    @Published var autoPaste = UserDefaults.standard.object(forKey: "autoPaste") as? Bool ?? true
    @Published var latency = ""
    @Published var selectedText = ""
    @Published var polishDraft = ""
    @Published private(set) var polishOriginal = ""
    @Published private(set) var polishedText = ""
    @Published var dictionarySheet: DictionarySheet?
    var correctionSeed = ""
    private var correctionText = ""
    let dictionary: PersonalDictionary
    let features: FeatureSettings
    let agent: AgentSession
    @Published var activeMode: VoiceMode = .dictation
    @Published private(set) var shortcutError = ""
    private var captureMode: VoiceMode = .dictation
    private var capturedSelection: String?
    private var didLaunch = false
    private var feedbackSubscription: AnyCancellable?
    private let recorder: any AudioRecording
    private let client: any SpeechTranscribing
    private let polisher: any TextPolishing
    private var polishShouldCopy = false
    private let services: DictationServices
    private let hotkey = GlobalHotkey()
    @Published var handsFree = false
    private var window: NSWindow!
    private var hud: NSPanel!
    private var statusItem: NSStatusItem!
    private var recordMenuItem: NSMenuItem!
    private var retryMenuItem: NSMenuItem!
    private var copyMenuItem: NSMenuItem!
    private var timer: Timer?
    private var permissionTimer: Timer?
    private var task: Task<Void, Never>?
    private var audio: Data?
    private var targetPID: pid_t?
    private var targetElement: AXUIElement?
    private var runID = UUID()
    private var hideHUDWork: DispatchWorkItem?
    private var sleepObserver: NSObjectProtocol?
    private var activeHold: HoldSource?
    var mainHeight: CGFloat { (activeMode == .dictation ? 320 : activeMode == .polish ? 600 : 654) + (features.options.enabledModes.count > 1 ? 38 : 0) + (error.isEmpty ? 0 : 88) + ((!micAllowed || !pasteAllowed) ? 40 : 0) }
    var contentWidth: CGFloat { settingsVisible || activeMode == .polish ? 480 : activeMode == .dictation ? 400 : 520 }
    var contentHeight: CGFloat {
        let screenHeight = window?.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 1000
        return min(settingsVisible ? 650 : mainHeight, screenHeight - 40)
    }
    var shortcutLabel: String { features.options.binding(for: activeMode).displayLabel }

    var voiceActivity: VoiceActivity {
        let capture: VoiceActivity.Capture
        switch phase { case .idle: capture = .idle; case .requestingMic: capture = .requestingMicrophone; case .recording: capture = .listening; case .transcribing: capture = .transcribing; case .polishing: capture = .polishing }
        let assistant: VoiceActivity.Assistant
        switch agent.state { case .idle: assistant = .idle; case .thinking: assistant = .thinking; case .searching: assistant = .searching; case .replying: assistant = .replying; case .reviewing: assistant = .reviewing; case .running: assistant = .running }
        let speech: VoiceActivity.Speech
        switch agent.speechState { case .idle: speech = .idle; case .preparing: speech = .preparing; case .speaking: speech = .speaking }
        return VoiceActivity.resolve(capture: capture, assistant: assistant, speech: speech)
    }
    var feedbackDetail: String {
        if activeMode == .polish, phase == .idle { return "" }
        switch voiceActivity {
        case .listening: return handsFree ? "Hands-free · tap Control to finish" : "Release to finish"
        case .transcribing: return "MAI-Transcribe-2"
        case .polishing: return "Keeping your meaning and tone"
        case .preparingVoice, .speaking: return "Qwen Audio 3.0 TTS Plus"
        case .requestingMicrophone: return "Allow access in the macOS prompt"
        default: return agent.activityDetail
        }
    }
    var activityStopLabel: String { agent.isBusy ? "Stop request" : voiceActivity.stopLabel }
    var statusLine: String {
        if activeMode.isAssistant, phase == .idle, error.isEmpty, !retryAvailable {
            return voiceActivity.isActive ? voiceActivity.title + "…" : "Hold the keys, speak, then release."
        }
        if handsFree && phase == .recording { return "Hands-free · tap Control to finish." }
        return status == "Ready when you are." ? "Hold the keys, speak, then release." : status
    }
    func stopActivity() {
        if phase != .idle { cancel() }
        agent.cancel()
        syncActivityFeedback()
    }
    private func syncActivityFeedback() {
        updateMenu()
        if voiceActivity.isActive { showHUD() } else { hideHUD() }
    }

    init(recorder: (any AudioRecording)? = nil, client: (any SpeechTranscribing)? = nil,
         polisher: (any TextPolishing)? = nil,
         services: DictationServices? = nil, dictionary: PersonalDictionary? = nil,
         features: FeatureSettings? = nil, agent: AgentSession? = nil) {
        self.recorder = recorder ?? Recorder()
        self.client = client ?? TranscriptionClient()
        self.polisher = polisher ?? PolishClient()
        self.services = services ?? .live
        self.dictionary = dictionary ?? PersonalDictionary()
        let settings = features ?? FeatureSettings()
        self.features = settings
        self.agent = agent ?? AgentSession(settings: settings, loadKey: (services ?? .live).loadKey)
        super.init()
        self.feedbackSubscription = self.agent.$state.combineLatest(self.agent.$speechState, self.agent.$activityDetail, self.agent.$progress)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send(); self.syncActivityFeedback()
            }
        self.features.onChange = { [weak self] in self?.featuresChanged() }
        self.agent.onPresent = { [weak self] in
            guard let self else { return }
            self.settingsVisible = false; self.fitWindow(); self.showWindow()
        }
        self.recorder.onFailure = { [weak self] message in
            Task { @MainActor in self?.cancel(); self?.error = message; self?.showWindow() }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didLaunch = true
        NSApp.setActivationPolicy(.regular)
        makeMainMenu()
        makeWindows()
        makeMenu()
        refreshPermissions()
        hotkey.onHandsFreeChange = { [weak self] locked in if self?.handsFree != locked { self?.handsFree = locked } }
        hotkey.onModeSignal = { [weak self] signal in
            MainActor.assumeIsolated {
                switch signal {
                case .begin(let mode):
                    self?.beginHold(.shortcut, mode: mode)
                    if self?.activeHold != .shortcut { self?.hotkey.clearHandsFree() }
                case .end: self?.endHold(.shortcut)
                case .cancel: self?.cancelHold(.shortcut)
                }
            }
        }
        configureShortcuts()
        if !hotkey.register() { error = "Couldn't listen for the shortcut. Use the Record button for now." }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.phase == .recording { self?.stop() } }
        }
        showWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        task?.cancel(); agent.cancel(); recorder.discard(); timer?.invalidate(); permissionTimer?.invalidate()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    }

    private func makeWindows() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: mainHeight), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Quick Dictate"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainView(app: self))
        window.center()
        hud = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 156, height: 32), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud.isFloatingPanel = true
        hud.level = .floating
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.hasShadow = true
        hud.hidesOnDeactivate = false
        hud.contentView = NSHostingView(rootView: RecordingHUD(app: self))
    }

    private func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Quick Dictate")
        statusItem.button?.toolTip = "Quick Dictate · Hold Option + Command to talk"
        let menu = NSMenu()
        recordMenuItem = menu.addItem(withTitle: "Hold ⌥⌘ to talk", action: #selector(stop), keyEquivalent: "")
        recordMenuItem.target = self
        copyMenuItem = menu.addItem(withTitle: "Copy latest text", action: #selector(copyLatest), keyEquivalent: "")
        copyMenuItem.target = self
        retryMenuItem = menu.addItem(withTitle: "Retry last recording", action: #selector(retry), keyEquivalent: "")
        retryMenuItem.target = self
        menu.addItem(.separator())
        let open = menu.addItem(withTitle: "Open Quick Dictate", action: #selector(showWindow), keyEquivalent: "")
        open.target = self
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        let words = menu.addItem(withTitle: "Remembered words…", action: #selector(showDictionary), keyEquivalent: "")
        words.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Quick Dictate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateMenu()
    }

    private func makeMainMenu() {
        let main = NSMenu()
        let application = NSMenu(title: "Quick Dictate")
        let applicationItem = NSMenuItem(title: "Quick Dictate", action: nil, keyEquivalent: "")
        applicationItem.submenu = application
        main.addItem(applicationItem)
        let settings = application.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        application.addItem(.separator())
        application.addItem(withTitle: "Hide Quick Dictate", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        application.addItem(withTitle: "Quit Quick Dictate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = main
    }

    private func updateMenu() {
        recordMenuItem?.title = phase == .recording ? "Finish recording" : "Hold \(features.options.binding(for: .dictation).displayLabel) to dictate"
        recordMenuItem?.isEnabled = phase == .recording
        retryMenuItem?.isHidden = !retryAvailable
        retryMenuItem?.isEnabled = phase == .idle
        copyMenuItem?.isEnabled = !lastText.isEmpty
        statusItem?.button?.image = NSImage(systemSymbolName: phase == .recording ? "record.circle.fill" : phase == .transcribing ? "ellipsis.circle" : "waveform", accessibilityDescription: "Quick Dictate")
        statusItem?.button?.image = NSImage(systemSymbolName: voiceActivity.symbol, accessibilityDescription: voiceActivity.title)
        statusItem?.button?.title = voiceActivity.isActive ? " " + voiceActivity.title : ""
        statusItem?.button?.toolTip = voiceActivity.title + (feedbackDetail.isEmpty ? "" : " · " + feedbackDetail)
        statusItem?.button?.contentTintColor = phase == .recording ? .systemRed : nil
    }

    func refreshPermissions() {
        let mic = services.microphoneStatus() == .authorized
        let paste = AXIsProcessTrusted()
        let key = services.loadKey() != nil
        let login = SMAppService.mainApp.status == .enabled
        if micAllowed != mic { micAllowed = mic }
        if pasteAllowed != paste { pasteAllowed = paste }
        if keyPresent != key { keyPresent = key }
        if launchAtLogin != login { launchAtLogin = login }
    }

    @objc func showWindow() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); refreshPermissions()
    }
    @objc func showSettings() { settingsVisible = true; showWindow() }
    @objc func showDictionary() { guard phase == .idle else { return }; showWindow(); dictionarySheet = .words }
    func showCorrection() {
        guard phase == .idle, !lastText.isEmpty else { return }
        correctionSeed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        correctionText = lastText
        dictionarySheet = .correction
    }
    func rememberCorrection(heard: String, preferred: String) throws {
        guard phase == .idle else { throw DictationError(message: "Finish this recording before correcting the text.") }
        // A new dictation may arrive while this sheet is open. Correct the text
        // the user opened, rather than applying an old correction to new speech.
        let corrected = try CorrectionEditing.replacing(heard, with: preferred, in: correctionText)
        try dictionary.remember(heard: heard, preferred: preferred)
        lastText = corrected
        selectedText = ""
        services.copy(corrected)
        status = "Corrected & copied. Spelling remembered."
        dictionarySheet = nil
        correctionText = ""
        updateMenu()
    }
    func fitWindow() {
        guard let window else { return }
        let height = contentHeight
        let oldFrame = window.frame
        let newFrame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: contentWidth, height: height))
        guard abs(newFrame.height - oldFrame.height) > 1 || abs(newFrame.width - oldFrame.width) > 1 else { return }
        var frame = NSRect(x: oldFrame.minX, y: oldFrame.maxY - newFrame.height, width: newFrame.width, height: newFrame.height)
        if let screen = window.screen?.visibleFrame {
            frame.origin.x = max(screen.minX, min(frame.minX, screen.maxX - frame.width))
            frame.origin.y = max(screen.minY, min(frame.minY, screen.maxY - frame.height))
        }
        // Keep the native window in step with SwiftUI's fixed content size.
        // Animated resizing leaves the newly laid-out tabs moving/clipped while
        // the window is still between the Dictate and assistant dimensions.
        window.setFrame(frame, display: true, animate: false)
    }

    func enableMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in Task { @MainActor in self?.refreshPermissions() } }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }
    func enablePaste() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refreshPermissions()
        } catch { self.error = "Couldn't change launch at login. Try again from System Settings → Login Items." }
    }
    func saveKey(_ key: String) {
        do { try Credentials.save(key); error = ""; refreshPermissions(); status = "OpenRouter key saved." }
        catch { self.error = error.localizedDescription }
    }
    func setAutoPaste(_ value: Bool) { autoPaste = value; UserDefaults.standard.set(value, forKey: "autoPaste") }

    func selectMode(_ mode: VoiceMode) {
        guard phase == .idle, features.options.enabledModes.contains(mode) else { return }
        if mode != activeMode && agent.isBusy { agent.cancel() }
        agent.prepareForMode(mode)
        activeMode = mode; error = ""
    }
    private func configureShortcuts() {
        shortcutError = hotkey.configure(bindings: features.options.bindings, enabledModes: features.options.enabledModes).joined(separator: "\n")
    }
    private func featuresChanged() {
        if phase != .idle || (audio != nil && !features.options.enabledModes.contains(captureMode)) { cancel() }
        agent.settingsChanged()
        if !features.options.enabledModes.contains(activeMode) { activeMode = .dictation }
        if didLaunch { configureShortcuts() }
        objectWillChange.send(); updateMenu(); fitWindow()
    }

    func beginHold(_ source: HoldSource, mode: VoiceMode? = nil) {
        // Dictionary/settings windows must not disable dictation in other apps.
        let requested = mode ?? activeMode
        guard phase == .idle, activeHold == nil, features.options.enabledModes.contains(requested) else { return }
        if requested != .dictation, agent.isBusy { agent.cancel() }
        agent.prepareForMode(requested)
        activeMode = requested; captureMode = requested
        agent.stopSpeaking()
        activeHold = source
        start()
        if phase == .idle { activeHold = nil; hotkey.clearHandsFree() }
    }
    func endHold(_ source: HoldSource) {
        guard activeHold == source else { return }
        activeHold = nil
        if phase == .recording { stop() }
        else if phase == .requestingMic { cancel() }
    }
    func cancelHold(_ source: HoldSource) {
        guard activeHold == source else { return }
        cancel()
        status = "Ready when you are."
    }

    private func start() {
        guard services.loadKey() != nil else { error = "Add your OpenRouter API key to get started."; showSettings(); return }
        let target = services.captureTarget()
        targetPID = target.pid
        targetElement = target.element
        capturedSelection = captureMode.isAssistant && features.options.useSelectedText && !target.isSecure ? services.selectedContext() : nil
        if target.isSecure {
            error = "Choose a normal text field before dictating."; showWindow(); return
        }
        error = ""
        runID = UUID()
        let current = runID
        switch services.microphoneStatus() {
        case .authorized: beginRecording()
        case .notDetermined:
            phase = .requestingMic; status = "Allow microphone access to start."; updateMenu()
            services.requestMicrophone { [weak self] allowed in
                Task { @MainActor in
                    guard let self, self.runID == current else { return }
                    self.refreshPermissions()
                    self.phase = .idle
                    if allowed, self.activeHold != nil { self.beginRecording() }
                    else { self.hotkey.clearHandsFree(); self.error = "Microphone access is off. Enable it below, then try again."; self.showWindow(); self.syncActivityFeedback() }
                }
            }
        default:
            error = "Microphone access is off. Enable it below, then try again."; showWindow()
        }
    }

    private func beginRecording() {
        do {
            try recorder.start()
            audio = nil; retryAvailable = false; seconds = 0; level = 0
            phase = .recording
            status = "Listening… release to transcribe."
            showHUD()
            updateMenu()
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateRecording() }
            }
        } catch {
            hotkey.clearHandsFree(); phase = .idle; self.error = "Couldn't start recording. Check your microphone in System Settings → Sound."
            showWindow(); syncActivityFeedback()
        }
    }

    func updateRecording() {
        guard phase == .recording else { return }
        seconds = Int(recorder.elapsed)
        level = recorder.level
        if seconds >= 300 { stop() }
    }

    @objc func stop() {
        hotkey.clearHandsFree()
        guard phase == .recording else { return }
        activeHold = nil
        timer?.invalidate(); timer = nil
        let duration = recorder.elapsed
        do {
            let data = try recorder.finish()
            guard duration >= 0.3 else { cancel(); status = "Too short — try speaking for a little longer."; return }
            audio = data
            transcribe()
        } catch {
            phase = .idle; self.error = "Couldn't read that recording. Please try again."; syncActivityFeedback(); showWindow()
        }
    }

    private func transcribe() {
        guard let audio, let key = services.loadKey() else {
            phase = .idle; retryAvailable = self.audio != nil; syncActivityFeedback()
            error = "Add an OpenRouter key in Settings, then Retry."; showSettings(); return
        }
        phase = .transcribing; status = "Turning speech into text…"; error = ""; retryAvailable = false
        showHUD(); updateMenu()
        let current = runID
        let destination = targetPID
        let destinationElement = targetElement
        let vocabulary = dictionary.hints
        let mode = captureMode
        let selection = capturedSelection
        let began = Date()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.client.transcribe(audio: audio, format: "wav", key: key, vocabulary: vocabulary)
                guard !Task.isCancelled, self.runID == current else { return }
                if mode == .polish {
                    self.audio = nil; self.capturedSelection = nil
                    self.startPolish(result.text, key: key, destination: DictationTarget(pid: destination, element: destinationElement), copyOnCompletion: true)
                    return
                }
                if mode.isAssistant {
                    self.phase = .idle
                    if self.agent.send(result.text, mode: mode, selection: selection, spoken: true) {
                        self.audio = nil; self.capturedSelection = nil; self.retryAvailable = false
                        self.status = "Ready when you are."
                    } else {
                        self.retryAvailable = true; self.status = "Recording kept for Retry."
                        self.error = self.agent.isBusy ? "Your assistant is busy. Retry this recording when it finishes." : "Could not send to the assistant. Check its settings, then Retry."
                    }
                    self.syncActivityFeedback(); self.showWindow()
                    return
                }
                self.lastText = result.text
                self.selectedText = ""
                self.latency = String(format: "%.1fs", Date().timeIntervalSince(began))
                self.audio = nil
                let pasted: Bool
                if self.autoPaste { pasted = await self.services.insert(result.text, DictationTarget(pid: destination, element: destinationElement)) }
                else { self.services.copy(result.text); pasted = false }
                guard !Task.isCancelled, self.runID == current else { return }
                self.status = pasted ? "Paste sent · also copied" : "Copied — press ⌘V to paste."
                self.phase = .idle; self.retryAvailable = false; self.updateMenu()
                self.hideHUD(after: 0.8)
            } catch {
                guard !Task.isCancelled, self.runID == current else { return }
                self.phase = .idle
                self.error = error is CancellationError ? "Transcription was interrupted. Your audio is ready to retry." : error.localizedDescription
                self.retryAvailable = self.audio != nil
                self.status = "Recording kept for Retry."
                self.syncActivityFeedback(); self.showWindow()
            }
        }
    }

    @objc func retry() {
        guard phase == .idle, audio != nil else { return }
        guard features.options.enabledModes.contains(captureMode) else { cancel(); return }
        if captureMode.isAssistant && agent.isBusy { error = "Your assistant is busy. Retry when it finishes."; return }
        runID = UUID()
        // Retrying from this window must never unexpectedly switch apps and paste.
        targetPID = nil
        targetElement = nil
        if captureMode == .polish { activeMode = .polish }
        transcribe()
    }
    func cancel() {
        hotkey.clearHandsFree()
        activeHold = nil
        runID = UUID(); task?.cancel(); task = nil
        timer?.invalidate(); timer = nil; recorder.discard()
        audio = nil; capturedSelection = nil; retryAvailable = false; phase = .idle; status = "Cancelled. Ready when you are."; error = ""
        syncActivityFeedback()
    }
    @objc func copyLatest() { guard !lastText.isEmpty else { return }; services.copy(lastText); status = "Copied — press ⌘V to paste." }

    func polishTypedText() {
        guard phase == .idle, features.options.polishEnabled else { return }
        let text = polishDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let key = services.loadKey() else { error = "Add your OpenRouter key in Settings to polish text."; return }
        agent.cancel()
        activeMode = .polish
        startPolish(text, key: key, destination: nil, copyOnCompletion: false)
    }

    func retryPolish() {
        guard phase == .idle, features.options.polishEnabled, !polishOriginal.isEmpty else { return }
        guard let key = services.loadKey() else { error = "Add your OpenRouter key in Settings to retry."; return }
        agent.cancel()
        activeMode = .polish
        // A retry from this window must never paste into an old target.
        startPolish(polishOriginal, key: key, destination: nil, copyOnCompletion: polishShouldCopy)
    }

    private func startPolish(_ original: String, key: String, destination: DictationTarget?, copyOnCompletion: Bool) {
        runID = UUID()
        let current = runID
        audio = nil; capturedSelection = nil
        polishOriginal = original; polishDraft = original; polishedText = ""
        polishShouldCopy = copyOnCompletion
        phase = .polishing; status = "Polishing your message…"; error = ""; retryAvailable = false
        syncActivityFeedback()
        let began = Date()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.polisher.polish(original, key: key)
                guard !Task.isCancelled, self.runID == current, self.features.options.polishEnabled else { return }
                self.polishedText = text
                let pasted: Bool
                if copyOnCompletion, self.autoPaste, let destination {
                    pasted = await self.services.insert(text, destination)
                } else {
                    if copyOnCompletion { self.services.copy(text) }
                    pasted = false
                }
                guard !Task.isCancelled, self.runID == current else { return }
                self.latency = String(format: "%.1fs", Date().timeIntervalSince(began))
                self.status = pasted ? "Paste sent · original kept in Polish" : copyOnCompletion ? "Polished & copied — press ⌘V to paste." : "Polished. Copy your message below."
                self.phase = .idle; self.updateMenu(); self.hideHUD(after: 0.8)
            } catch {
                guard !Task.isCancelled, self.runID == current else { return }
                self.phase = .idle
                self.error = error is CancellationError ? "Polishing was interrupted. Your original is kept below." : error.localizedDescription
                self.status = "Original kept. Retry or copy it below."
                self.syncActivityFeedback(); self.showWindow()
            }
        }
    }

    func copyPolishedText() {
        guard phase == .idle, !polishedText.isEmpty else { return }
        services.copy(polishedText); status = "Polished message copied."
    }

    func restorePolishOriginal() {
        guard phase == .idle, !polishOriginal.isEmpty else { return }
        services.copy(polishOriginal); status = "Original copied — paste it wherever you need."
    }

    private func showHUD() {
        hideHUDWork?.cancel()
        guard let hud else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        if let frame = screen?.visibleFrame { hud.setFrameOrigin(NSPoint(x: frame.midX - 78, y: frame.minY + 12)) }
        hud.orderFrontRegardless()
    }
    private func hideHUD(after delay: TimeInterval = 0) {
        hideHUDWork?.cancel()
        if delay == 0 { hud?.orderOut(nil); return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.voiceActivity.isActive else { return }; self.hud?.orderOut(nil)
        }
        hideHUDWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

private let mint = Color(red: 0.15, green: 0.66, blue: 0.49)

struct MainView: View {
    @ObservedObject var app: DictationApp
    @ObservedObject var features: FeatureSettings
    init(app: DictationApp) { self.app = app; self.features = app.features }
    var body: some View {
        Group {
            if app.settingsVisible { SettingsView(app: app) }
            else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(mint).frame(width: 30, height: 30)
                            .background(mint.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                        Text("Quick Dictate").font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Button(action: app.showSettings) { Image(systemName: "gearshape").font(.system(size: 14)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Settings")
                    }
                    if features.options.enabledModes.count > 1 { ModeTabsView(app: app, features: features) }
                    if app.activeMode != .dictation {
                        PipelineTimelineView(activity: app.voiceActivity, detail: app.feedbackDetail,
                                             assistantLabel: app.activeMode == .polish ? "Polish" : app.activeMode == .fullControl ? "Codex" : AgentModel.presets.first(where: { $0.id == app.features.options.model })?.title ?? "Assistant",
                                             includesVoice: app.activeMode != .polish,
                                             captureStartedAt: app.phase == .idle ? nil : app.phaseStartedAt,
                                             progress: app.activeMode == .polish ? nil : app.agent.progress, stopLabel: app.activityStopLabel,
                                             onStop: app.stopActivity)
                    }
                    HoldToTalkView(app: app)
                    HStack(spacing: 6) {
                        Circle().fill(app.phase == .recording ? Color.red : mint).frame(width: 5, height: 5)
                        Text(app.statusLine)
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        if app.phase != .idle {
                            Button("Cancel", action: app.cancel).buttonStyle(.link).font(.system(size: 11))
                        }
                    }.frame(height: 16)
                    if !app.error.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                            Text(app.error).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                            if app.retryAvailable { Button("Retry", action: app.retry).controlSize(.small) }
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                    }
                    if app.activeMode == .polish {
                        PolishView(app: app)
                    } else if app.activeMode.isAssistant {
                        AgentPanelView(session: app.agent, mode: app.activeMode, voiceBusy: app.phase != .idle)
                    } else {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Last dictation").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            if !app.latency.isEmpty { Text(app.latency).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary) }
                            Spacer()
                            Button("Correct & remember", action: app.showCorrection)
                                .buttonStyle(.link).font(.system(size: 10))
                                .disabled(app.lastText.isEmpty || app.phase != .idle)
                            Button(action: app.copyLatest) { Image(systemName: "doc.on.doc").font(.system(size: 11)) }
                                .buttonStyle(.plain).foregroundStyle(.secondary).disabled(app.lastText.isEmpty).help("Copy text")
                        }
                        if app.lastText.isEmpty {
                            Text("Your words will appear here.").font(.system(size: 13)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        } else {
                            SelectableTranscript(text: app.lastText) { app.selectedText = $0 }.frame(maxHeight: .infinity)
                        }
                    }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if !app.micAllowed || !app.pasteAllowed {
                        HStack(spacing: 8) {
                            Text("Finish setup").font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            if !app.micAllowed { Button("Microphone", action: app.enableMicrophone).controlSize(.small) }
                            if !app.pasteAllowed { Button("Shortcut & paste", action: app.enablePaste).controlSize(.small) }
                        }.frame(height: 26)
                    }
                }.padding(20)
            }
        }.frame(width: app.contentWidth, height: app.contentHeight)
            .background(Color(nsColor: .windowBackgroundColor))
            .onChange(of: CGSize(width: app.contentWidth, height: app.contentHeight)) { app.fitWindow() }
            .sheet(item: $app.dictionarySheet) { sheet in
                if sheet == .correction { RememberCorrectionView(app: app, seed: app.correctionSeed) }
                else { RememberedWordsView(dictionary: app.dictionary) { app.dictionarySheet = nil } }
            }
    }
}

struct ModeTabsView: View {
    @ObservedObject var app: DictationApp
    @ObservedObject var features: FeatureSettings
    var body: some View {
        HStack(spacing: 4) {
            ForEach(VoiceMode.allCases.filter { features.options.enabledModes.contains($0) }) { mode in
                Button { app.selectMode(mode) } label: {
                    Group {
                        if features.options.enabledModes.count > 4 { Text(mode.title) }
                        else { Label(mode.title, systemImage: mode.symbol) }
                    }
                        .font(.system(size: features.options.enabledModes.count > 3 ? 11 : 12, weight: .medium))
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(app.activeMode == mode ? mint.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(app.phase != .idle)
                    .accessibilityAddTraits(app.activeMode == mode ? .isSelected : [])
            }
        }.padding(3).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct HoldToTalkView: View {
    @ObservedObject var app: DictationApp
    @GestureState private var held = false
    private var busy: Bool { app.phase == .transcribing || app.phase == .requestingMic || app.phase == .polishing }
    var body: some View {
        HStack(spacing: 12) {
            if busy { ProgressView().controlSize(.small).frame(width: 22) }
            else { Image(systemName: "mic.fill").font(.system(size: 19)).foregroundStyle(mint).frame(width: 22) }
            VStack(alignment: .leading, spacing: 3) {
                Text(app.phase == .recording ? "Listening…" : app.phase == .transcribing ? "Transcribing…" : app.phase == .polishing ? "Polishing…" : app.phase == .requestingMic ? "Allow microphone access" : "Hold to talk")
                    .font(.system(size: 14, weight: .semibold))
                Text(app.phase == .recording ? (app.handsFree ? "Tap Control to finish" : "Release to finish") : app.activeMode == .polish ? "Release to polish & paste" : app.activeMode == .dictation ? "Release to transcribe & paste" : "Release to send to \(app.activeMode.title)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(app.shortcutLabel).font(.system(size: 17, weight: .medium, design: .rounded))
                .padding(.horizontal, 9).frame(height: 30)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.07)))
        }.padding(.horizontal, 14).frame(height: 64)
            .background(mint.opacity(app.phase == .recording ? 0.17 : 0.08), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(mint.opacity(app.phase == .recording ? 0.4 : 0.16)))
            .contentShape(RoundedRectangle(cornerRadius: 11))
            .gesture(DragGesture(minimumDistance: 0).updating($held) { _, state, _ in state = true })
            .onChange(of: held) { _, down in
                if down { app.beginHold(.button) } else { app.endHold(.button) }
            }
            .onDisappear { app.endHold(.button) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(app.phase == .recording ? (app.handsFree ? "Hands-free recording. Tap Control to finish." : "Recording. Release to transcribe.") : "Hold to talk. \(app.shortcutLabel). \(app.activeMode.title).")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text("Start recording")) { app.beginHold(.accessibility) }
            .accessibilityAction(named: Text("Finish recording")) { app.endHold(.accessibility) }
            .accessibilityAction(named: Text("Cancel recording")) { app.cancelHold(.accessibility) }
    }
}

struct SettingsView: View {
    @ObservedObject var app: DictationApp
    @State private var key = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                HStack {
                    Text("Settings").font(.system(size: 20, weight: .semibold))
                    Spacer()
                    Button("Done") { app.settingsVisible = false }.keyboardShortcut(.escape, modifiers: [])
                }
                VStack(alignment: .leading, spacing: 9) {
                    Label(app.keyPresent ? "OpenRouter connected" : "Connect OpenRouter", systemImage: app.keyPresent ? "checkmark.circle.fill" : "key.fill")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(app.keyPresent ? mint : Color.primary)
                    Text(app.keyPresent ? "Your saved key is ready. Add a key only to replace it." : "Paste your OpenRouter API key to get started.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    SecureField("sk-or-…", text: $key).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Save key") { app.saveKey(key); if app.error.isEmpty { key = "" } }.disabled(key.isEmpty).controlSize(.small)
                        Link("Get a key ↗", destination: URL(string: "https://openrouter.ai/settings/keys")!).font(.system(size: 11))
                    }
                }
                Divider()
                FeatureSettingsView(settings: app.features)
                if !app.shortcutError.isEmpty { Text(app.shortcutError).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                Divider()
                DictionarySettingsRow(app: app, dictionary: app.dictionary)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Paste automatically", isOn: Binding(get: { app.autoPaste }, set: app.setAutoPaste))
                    Toggle("Open when I log in", isOn: Binding(get: { app.launchAtLogin }, set: app.setLogin))
                    Text("Hold your chosen shortcut while talking. Release to finish. With Control for Dictate, double-tap to record hands-free; tap Control again to finish. Escape cancels.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.toggleStyle(.checkbox).font(.system(size: 12))
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Label(app.micAllowed ? "Microphone enabled" : "Microphone needed", systemImage: "mic"); Spacer(); if !app.micAllowed { Button("Enable", action: app.enableMicrophone).controlSize(.small) } }
                    HStack { Label(app.pasteAllowed ? "Shortcut & paste enabled" : "Enable shortcut & paste", systemImage: "keyboard"); Spacer(); if !app.pasteAllowed { Button("Enable", action: app.enablePaste).controlSize(.small) } }
                }.font(.system(size: 12))
                if !app.error.isEmpty { Text(app.error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                Text("MAI-Transcribe-2 via OpenRouter. Saved words stay on your Mac and are sent as spelling hints. Polish uses GPT-6 Luna to clean up a message. Ask and Do use OpenRouter; Full Control uses your primary Codex login. Spoken replies use Qwen. Messages stay in memory, not a saved history.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }.padding(20)
        }
    }
}

struct RecordingHUD: View {
    @ObservedObject var app: DictationApp
    var body: some View {
        HStack(spacing: 9) {
            if app.phase == .recording {
                HStack(spacing: 2) {
                    ForEach(0..<4) { i in
                        Capsule().fill(mint).frame(width: 2, height: 4 + app.level * Double([9, 17, 13, 7][i]))
                    }
                }.frame(width: 16).animation(.easeOut(duration: 0.1), value: app.level)
            } else if app.voiceActivity.showsSpinner { ProgressView().controlSize(.mini).frame(width: 16) }
            else if app.voiceActivity.isActive { Image(systemName: app.voiceActivity.symbol).font(.system(size: 11)).foregroundStyle(mint).frame(width: 16) }
            else { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(mint).frame(width: 16) }
            Text(app.phase == .recording ? String(format: "%d:%02d", app.seconds / 60, app.seconds % 60) : app.voiceActivity.isActive ? app.voiceActivity.title : app.status.hasPrefix("Paste sent") ? "Paste sent" : app.status.hasPrefix("Polished.") ? "Polished" : "Copied")
                .font(.system(size: 11, weight: .medium)).monospacedDigit().lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if app.voiceActivity.isActive {
                Button(action: app.stopActivity) { Image(systemName: "xmark").font(.system(size: 9, weight: .medium)).frame(width: 16, height: 24) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(app.activityStopLabel).help(app.activityStopLabel)
            }
        }.padding(.horizontal, 12).frame(width: 156, height: 32)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.10)))
            .preferredColorScheme(.dark)
    }
}
