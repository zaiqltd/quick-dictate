import Cocoa
import Carbon

protocol ShortcutRegistering: AnyObject {
    var registeredModes: Set<VoiceMode> { get }
    func update(bindings: [VoiceMode: KeyboardShortcutBinding], enabled: Set<VoiceMode>,
                onKey: @escaping (VoiceMode, Bool) -> Void) -> [String]
    func teardown()
}
extension CarbonShortcutRegistration: ShortcutRegistering {}

final class GlobalHotkey {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var chord = ModifierChord() // Compatibility seam for existing controller tests.
    private var router = ShortcutRouter(doubleTapControl: true)
    private let registration: ShortcutRegistering
    private let currentModifiers: () -> NSEvent.ModifierFlags
    private let isKeyDown: (UInt16) -> Bool
    private let pollKeyReleases: Bool
    private var releaseTimer: Timer?
    private var watchedKeys: Set<UInt16> = []
    private var consumedKeys: Set<UInt16> = []
    private var configuredBindings: [VoiceMode: KeyboardShortcutBinding]?
    private var configuredModes: Set<VoiceMode> = []
    private var configurationErrors: [String] = []
    var onHandsFreeChange: ((Bool) -> Void)?
    func clearHandsFree() {
        guard router.isHandsFree else { return }
        _ = router.reset()
        onHandsFreeChange?(false)
    }
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?
    var onModeSignal: ((ShortcutRouter.Signal) -> Void)?

    init(registration: ShortcutRegistering = CarbonShortcutRegistration(),
         currentModifiers: @escaping () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags },
         isKeyDown: @escaping (UInt16) -> Bool = { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) },
         pollKeyReleases: Bool = true) {
        self.registration = registration
        self.currentModifiers = currentModifiers
        self.isKeyDown = isKeyDown
        self.pollKeyReleases = pollKeyReleases
    }

    func register() -> Bool {
        if globalMonitor != nil && localMonitor != nil { return true }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        let events: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in _ = self?.handle(event) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
        return globalMonitor != nil && localMonitor != nil
    }

    @discardableResult
    func configure(bindings: [VoiceMode: KeyboardShortcutBinding], enabledModes: Set<VoiceMode>) -> [String] {
        do { try KeyboardShortcutBinding.validate(bindings: bindings, enabledModes: enabledModes) }
        catch { return [error.localizedDescription] }
        if configuredBindings == bindings, configuredModes == enabledModes, configurationErrors.isEmpty { return [] }
        let errors = registration.update(bindings: bindings, enabled: enabledModes) { [weak self] mode, down in
            self?.registeredKey(mode, down: down)
        }
        let available = enabledModes.filter { bindings[$0]?.keyCode == nil || registration.registeredModes.contains($0) }
        do { deliver(try router.configure(bindings: bindings, enabledModes: available)) }
        catch { return errors + [error.localizedDescription] }
        configuredBindings = bindings
        configuredModes = enabledModes
        configurationErrors = errors
        return errors
    }

    private func handle(_ event: NSEvent) -> Bool {
        process(eventType: event.type, keyCode: event.keyCode, flags: event.modifierFlags,
                isRepeat: event.type == .keyDown && event.isARepeat,
                sourceTag: event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0)
    }

    // Returns whether the local monitor should consume this event. Globally,
    // Carbon owns enabled letter chords before another app can receive them.
    @discardableResult
    func process(eventType: NSEvent.EventType, keyCode: UInt16 = 0, flags: NSEvent.ModifierFlags,
                 isRepeat: Bool = false, sourceTag: Int64 = 0) -> Bool {
        guard sourceTag != Paste.eventTag else { return false }
        switch eventType {
        case .flagsChanged:
            deliver(router.flagsChanged(flags, sourceTag: sourceTag))
            return false
        case .keyDown:
            // Once this physical key belongs to a shortcut, consume its whole
            // hold, including unmodified repeats after releasing a modifier.
            let reserved = consumedKeys.contains(keyCode) || isReserved(keyCode, flags: flags)
            if reserved { consumedKeys.insert(keyCode) }
            deliver(router.keyDown(keyCode, flags: flags, isRepeat: isRepeat, sourceTag: sourceTag))
            return reserved
        case .keyUp:
            let reserved = consumedKeys.remove(keyCode) != nil || isReserved(keyCode, flags: flags)
            watchedKeys.remove(keyCode)
            stopReleaseTimerIfIdle()
            deliver(router.keyUp(keyCode, flags: flags, sourceTag: sourceTag))
            return reserved
        default: return false
        }
    }

    // Legacy tests supply only whether a nonmodifier key was pressed. Preserve
    // their exact cancellation behavior without guessing that key's identity.
    func process(flags: NSEvent.ModifierFlags, keyDown: Bool, sourceTag: Int64 = 0) {
        guard sourceTag != Paste.eventTag else { return }
        let signal = keyDown ? chord.keyDown(flags) : chord.flagsChanged(flags)
        switch signal {
        case .begin: deliver([.begin(.dictation)])
        case .end: deliver([.end(.dictation)])
        case .cancel: deliver([.cancel(.dictation)])
        case .none: break
        }
    }

    private func registeredKey(_ mode: VoiceMode, down: Bool) {
        guard router.enabledModes.contains(mode), let binding = router.bindings[mode], let key = binding.keyCode else { return }
        if down {
            // Read the actual modifier state: an extra Shift or Control must
            // cancel even if Carbon matched a broader native registration.
            _ = process(eventType: .keyDown, keyCode: key, flags: currentModifiers())
            watchRelease(of: key)
        } else {
            // Some native releases arrive when a modifier is released, while
            // the letter remains physically down. Keep tracking that letter.
            pollHeldKeys()
        }
    }

    // Callable in tests with injected physical state; production invokes this
    // only for keys belonging to the application's registered shortcuts.
    func pollHeldKeys() {
        let flags = currentModifiers()
        deliver(router.flagsChanged(flags))
        for key in watchedKeys.sorted() where !isKeyDown(key) {
            _ = process(eventType: .keyUp, keyCode: key, flags: flags)
        }
        stopReleaseTimerIfIdle()
    }

    private func isReserved(_ key: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let relevant = flags.intersection([.option, .command, .shift, .control, .function])
        return registration.registeredModes.contains { mode in
            router.enabledModes.contains(mode) && router.bindings[mode]?.keyCode == key && router.bindings[mode]?.modifiers == relevant
        }
    }

    private func deliver(_ signals: [ShortcutRouter.Signal]) {
        onHandsFreeChange?(router.isHandsFree)
        for signal in signals {
            if case .begin(let mode) = signal, let key = router.bindings[mode]?.keyCode { watchRelease(of: key) }
            if let onModeSignal { onModeSignal(signal); continue }
            switch signal {
            case .begin(.dictation): onPress?()
            case .end(.dictation): onRelease?()
            case .cancel(.dictation): onCancel?()
            default: break
            }
        }
    }

    private func watchRelease(of key: UInt16) {
        watchedKeys.insert(key)
        guard pollKeyReleases, releaseTimer == nil else { return }
        let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in self?.pollHeldKeys() }
        RunLoop.main.add(timer, forMode: .common)
        releaseTimer = timer
    }
    private func stopReleaseTimerIfIdle() {
        if watchedKeys.isEmpty { releaseTimer?.invalidate(); releaseTimer = nil }
    }
    deinit {
        releaseTimer?.invalidate()
        registration.teardown()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}

enum Paste {
    static let eventTag: Int64 = 0x5144494354 // Identifies only our own injected paste events.
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    static func focusedElement() -> AXUIElement? {
        var element: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &element) == .success,
              let element, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        return (element as! AXUIElement)
    }
    static func isSecureField() -> Bool {
        guard let element = focusedElement() else { return false }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &role)
        return (role as? String) == (kAXSecureTextFieldSubrole as String)
    }
    @MainActor static func insert(_ text: String, targetPID: pid_t?, targetElement: AXUIElement?) async -> Bool {
        copy(text)
        guard AXIsProcessTrusted(), let targetPID else { return false }
        // Wait for the dictation shortcut's modifiers to be released before Cmd+V.
        for _ in 0..<40 {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]).isEmpty { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled { return false }
        }
        guard !Task.isCancelled,
              CGEventSource.flagsState(.combinedSessionState).intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]).isEmpty,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID,
              !isSecureField() else { return false }
        if let targetElement {
            guard let current = focusedElement(), CFEqual(current, targetElement) else { return false }
        }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: eventTag)
        up.setIntegerValueField(.eventSourceUserData, value: eventTag)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
