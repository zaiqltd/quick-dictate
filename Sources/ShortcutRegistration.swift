import AppKit
import Carbon

// Carbon reserves letter chords at the OS level, so an agent shortcut cannot
// also reload a browser or activate another application's menu command.
final class CarbonShortcutRegistration {
    private static let signature: OSType = 0x5144484B // QDHK
    private var handler: EventHandlerRef?
    private var registrations: [EventHotKeyRef] = []
    private var modesByID: [UInt32: VoiceMode] = [:]
    private var nextID: UInt32 = 1
    private var onKey: ((VoiceMode, Bool) -> Void)?
    private(set) var registeredModes: Set<VoiceMode> = []

    @discardableResult
    func update(bindings: [VoiceMode: KeyboardShortcutBinding], enabled: Set<VoiceMode>,
                onKey: @escaping (VoiceMode, Bool) -> Void) -> [String] {
        do { try KeyboardShortcutBinding.validate(bindings: bindings, enabledModes: enabled) }
        catch { return [error.localizedDescription] }
        unregisterKeys()
        self.onKey = onKey
        let keyedModes = VoiceMode.allCases.filter { enabled.contains($0) && bindings[$0]?.keyCode != nil }
        guard !keyedModes.isEmpty else { return [] }
        if handler == nil {
            var eventTypes = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                              EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                return Unmanaged<CarbonShortcutRegistration>.fromOpaque(context).takeUnretainedValue().handle(event)
            }, eventTypes.count, &eventTypes, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else {
                return ["macOS could not listen for agent shortcuts (\(status)). Dictation is still available."]
            }
        }
        var errors: [String] = []
        for mode in keyedModes {
            guard let binding = bindings[mode], let keyCode = binding.keyCode else { continue }
            let id = nextID
            nextID &+= 1
            if nextID == 0 { nextID = 1 }
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(keyCode), Self.carbonModifiers(for: binding.modifiers),
                EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference {
                registrations.append(reference)
                modesByID[id] = mode
                registeredModes.insert(mode)
            } else {
                errors.append("\(mode.title) shortcut \(binding.displayLabel) is unavailable (macOS \(status)). Choose another shortcut in Settings.")
            }
        }
        return errors
    }

    func teardown() {
        unregisterKeys()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        onKey = nil
    }

    static func carbonModifiers(for flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var id = EventHotKeyID()
        guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
              id.signature == Self.signature, let mode = modesByID[id.id] else { return OSStatus(eventNotHandledErr) }
        switch GetEventKind(event) {
        case UInt32(kEventHotKeyPressed): onKey?(mode, true)
        case UInt32(kEventHotKeyReleased): onKey?(mode, false)
        default: return OSStatus(eventNotHandledErr)
        }
        return noErr
    }

    private func unregisterKeys() {
        for reference in registrations { UnregisterEventHotKey(reference) }
        registrations.removeAll()
        modesByID.removeAll()
        registeredModes.removeAll()
    }

    deinit { teardown() }
}
