import AppKit
import Carbon

enum VoiceMode: String, Codable, CaseIterable, Identifiable {
    case dictation, polish, ask, act, fullControl
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dictation: return "Dictate"
        case .polish: return "Polish"
        case .ask: return "Ask"
        case .act: return "Do"
        case .fullControl: return "Full Control"
        }
    }
    var isAssistant: Bool { self == .ask || self == .act || self == .fullControl }
}

struct KeyboardShortcutBinding: Codable, Equatable, Hashable, Identifiable {
    private var modifierBits: UInt
    let keyCode: UInt16?

    init(modifiers: NSEvent.ModifierFlags = [.option, .command], keyCode: UInt16? = nil) {
        modifierBits = modifiers.rawValue
        self.keyCode = keyCode
    }

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierBits) }
    var id: String { "\(modifierBits):\(keyCode.map(String.init) ?? "hold")" }
    var displayLabel: String {
        var label = ""
        for (flag, symbol): (NSEvent.ModifierFlags, String) in [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")] {
            if modifiers.contains(flag) { label += symbol }
        }
        if let keyCode { label += Self.keyNames[keyCode] ?? "?" }
        return label
    }

    static let defaults: [VoiceMode: KeyboardShortcutBinding] = [
        .dictation: KeyboardShortcutBinding(),
        .polish: KeyboardShortcutBinding(keyCode: UInt16(kVK_ANSI_P)),
        .ask: KeyboardShortcutBinding(keyCode: UInt16(kVK_ANSI_A)),
        .act: KeyboardShortcutBinding(keyCode: UInt16(kVK_ANSI_R)),
        .fullControl: KeyboardShortcutBinding(keyCode: UInt16(kVK_ANSI_F))
    ]
    static func defaultBinding(for mode: VoiceMode) -> KeyboardShortcutBinding { defaults[mode]! }

    // Presets use physical key positions. Keep the modifier-only shortcut and
    // letter shortcuts on the same modifiers so a hold can safely upgrade.
    private static let presetKeys: [UInt16?] = [nil, UInt16(kVK_ANSI_A), UInt16(kVK_ANSI_R),
        UInt16(kVK_ANSI_D), UInt16(kVK_ANSI_S), UInt16(kVK_ANSI_G), UInt16(kVK_ANSI_K), UInt16(kVK_Space), UInt16(kVK_ANSI_F), UInt16(kVK_ANSI_P)]
    static let presets = presetKeys.map { KeyboardShortcutBinding(keyCode: $0) }
        + presetKeys.map { KeyboardShortcutBinding(modifiers: .control, keyCode: $0) }

    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M", 49: "Space"
    ]
    private static let allowedModifiers: NSEvent.ModifierFlags = [.command, .option, .shift, .control]

    static func validate(bindings: [VoiceMode: KeyboardShortcutBinding], enabledModes: Set<VoiceMode>) throws {
        for binding in bindings.values {
            let modifierCount = [NSEvent.ModifierFlags.command, .option, .shift, .control].filter { binding.modifiers.contains($0) }.count
            guard binding.modifiers.subtracting(allowedModifiers).isEmpty, (modifierCount >= 2 || binding.modifiers == .control) else {
                throw ShortcutError.invalidModifiers
            }
            if let key = binding.keyCode, keyNames[key] == nil { throw ShortcutError.invalidKey }
        }
        let enabled = VoiceMode.allCases.filter { enabledModes.contains($0) }
        for mode in enabled where bindings[mode] == nil { throw ShortcutError.missingBinding(mode) }
        for (index, mode) in enabled.enumerated() {
            guard let binding = bindings[mode] else { continue }
            for otherMode in enabled.dropFirst(index + 1) {
                guard let other = bindings[otherMode] else { continue }
                if binding == other { throw ShortcutError.collision(mode, otherMode) }
                // Different modifier-only prefixes would cancel one another
                // before the longer shortcut could become active.
                if (binding.keyCode == nil && binding.modifiers != other.modifiers &&
                    other.modifiers.isSuperset(of: binding.modifiers)) ||
                    (other.keyCode == nil && binding.modifiers != other.modifiers &&
                     binding.modifiers.isSuperset(of: other.modifiers)) {
                    throw ShortcutError.overlappingModifiers(mode, otherMode)
                }
            }
        }
    }
}

enum ShortcutError: LocalizedError {
    case invalidModifiers, invalidKey, missingBinding(VoiceMode)
    case collision(VoiceMode, VoiceMode), overlappingModifiers(VoiceMode, VoiceMode)
    var errorDescription: String? {
        switch self {
        case .invalidModifiers: return "Choose Control alone, or at least two of Option, Command, Shift or Control."
        case .invalidKey: return "Choose a letter key, Space, or a modifiers-only hold."
        case .missingBinding(let mode): return "Choose a shortcut for \(mode.title)."
        case .collision(let first, let second): return "\(first.title) and \(second.title) need different shortcuts."
        case .overlappingModifiers(let first, let second):
            return "Use the same modifiers with different keys for \(first.title) and \(second.title)."
        }
    }
}

// Pure event state: no timers, permission prompts, audio or typed characters.
// An extended shortcut upgrades a modifier-only hold by cancelling its audio
// before emitting the new begin. Only an end signal may submit that mode.
struct ShortcutRouter {
    enum Signal: Equatable {
        case begin(VoiceMode), end(VoiceMode), cancel(VoiceMode)
    }
    private(set) var bindings: [VoiceMode: KeyboardShortcutBinding]
    private(set) var enabledModes: Set<VoiceMode>
    private(set) var activeMode: VoiceMode?
    private var pressedKeys: Set<UInt16> = []
    private var currentModifiers: NSEvent.ModifierFlags = []
    private var blocked = false
    private(set) var isHandsFree = false
    private var controlDownAt: TimeInterval?
    private var lastControlTap: TimeInterval?
    private let doubleTapControl: Bool
    private let clock: () -> TimeInterval
    private let ignoredSourceTag: Int64
    private static let relevantModifiers: NSEvent.ModifierFlags = [.option, .command, .control, .shift, .function]

    init(bindings: [VoiceMode: KeyboardShortcutBinding] = KeyboardShortcutBinding.defaults,
         enabledModes: Set<VoiceMode> = [.dictation], ignoredSourceTag: Int64 = 0x5144494354,
         doubleTapControl: Bool = false, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.doubleTapControl = doubleTapControl
        self.clock = clock
        self.bindings = bindings
        // Invalid configuration fails closed; validate before saving settings
        // so the caller can explain a conflict without disabling a good config.
        self.enabledModes = (try? KeyboardShortcutBinding.validate(bindings: bindings, enabledModes: enabledModes)) != nil
            ? enabledModes : []
        self.ignoredSourceTag = ignoredSourceTag
    }

    @discardableResult
    mutating func configure(bindings: [VoiceMode: KeyboardShortcutBinding], enabledModes: Set<VoiceMode>) throws -> [Signal] {
        try KeyboardShortcutBinding.validate(bindings: bindings, enabledModes: enabledModes)
        guard bindings != self.bindings || enabledModes != self.enabledModes else { return [] }
        isHandsFree = false; lastControlTap = nil; controlDownAt = nil
        let signals = cancelActive()
        self.bindings = bindings
        self.enabledModes = enabledModes
        blocked = !currentModifiers.isEmpty || !pressedKeys.isEmpty
        return signals
    }

    mutating func flagsChanged(_ flags: NSEvent.ModifierFlags, sourceTag: Int64 = 0) -> [Signal] {
        guard sourceTag != ignoredSourceTag else { return [] }
        let previousModifiers = currentModifiers
        currentModifiers = flags.intersection(Self.relevantModifiers)
        if isHandsFree {
            if currentModifiers == .control && previousModifiers != .control {
                isHandsFree = false; activeMode = nil; blocked = true
                lastControlTap = nil; controlDownAt = nil
                return [.end(.dictation)]
            }
            return []
        }
        if doubleTapControl, enabledModes.contains(.dictation),
           bindings[.dictation] == KeyboardShortcutBinding(modifiers: .control) {
            if currentModifiers == .control, previousModifiers.isEmpty, pressedKeys.isEmpty, !blocked {
                let now = clock()
                if let last = lastControlTap, now - last <= 0.35 {
                    lastControlTap = nil; controlDownAt = nil
                    isHandsFree = true; activeMode = .dictation
                    return [.begin(.dictation)]
                }
                controlDownAt = now; lastControlTap = nil
            } else if currentModifiers.isEmpty, previousModifiers == .control,
                      activeMode == .dictation, let down = controlDownAt, clock() - down <= 0.22 {
                lastControlTap = clock(); controlDownAt = nil; activeMode = nil
                return [.cancel(.dictation)]
            } else if currentModifiers != .control && !currentModifiers.isEmpty {
                controlDownAt = nil; lastControlTap = nil
            }
        }
        if let mode = activeMode, let binding = bindings[mode] {
            if currentModifiers == binding.modifiers { return [] }
            activeMode = nil
            blocked = true
            releaseBlockIfNeutral()
            // Removing any required modifier finishes; adding an unrelated
            // modifier cancels. Caps Lock never enters currentModifiers.
            return currentModifiers.isSubset(of: binding.modifiers) ? [.end(mode)] : [.cancel(mode)]
        }
        releaseBlockIfNeutral()
        guard !blocked, !currentModifiers.isEmpty else { return [] }
        guard pressedKeys.isEmpty else { blocked = true; return [] }
        if let mode = matchingMode(keyCode: nil) {
            activeMode = mode
            return [.begin(mode)]
        }
        if !enabledModes.contains(where: { bindings[$0]?.modifiers.isSuperset(of: currentModifiers) == true }) {
            blocked = true
        }
        return []
    }

    mutating func keyDown(_ keyCode: UInt16, flags: NSEvent.ModifierFlags, isRepeat: Bool = false, sourceTag: Int64 = 0) -> [Signal] {
        guard sourceTag != ignoredSourceTag else { return [] }
        currentModifiers = flags.intersection(Self.relevantModifiers)
        lastControlTap = nil; controlDownAt = nil
        if isHandsFree {
            if keyCode == 53 {
                isHandsFree = false; activeMode = nil; blocked = true
                return [.cancel(.dictation)]
            }
            return []
        }
        let wasPressed = !pressedKeys.insert(keyCode).inserted
        if isRepeat || wasPressed { return [] }
        if let activeMode, let activeBinding = bindings[activeMode] {
            if activeBinding.keyCode == nil, activeBinding.modifiers == currentModifiers,
               pressedKeys.count == 1, let nextMode = matchingMode(keyCode: keyCode) {
                self.activeMode = nextMode
                return [.cancel(activeMode), .begin(nextMode)]
            }
            blocked = true
            return cancelActive()
        }
        guard !blocked, pressedKeys.count == 1 else { return [] }
        if let mode = matchingMode(keyCode: keyCode) {
            activeMode = mode
            return [.begin(mode)]
        }
        if !currentModifiers.isEmpty { blocked = true }
        return []
    }

    mutating func keyUp(_ keyCode: UInt16, flags: NSEvent.ModifierFlags, sourceTag: Int64 = 0) -> [Signal] {
        guard sourceTag != ignoredSourceTag else { return [] }
        currentModifiers = flags.intersection(Self.relevantModifiers)
        pressedKeys.remove(keyCode)
        if let mode = activeMode, bindings[mode]?.keyCode == keyCode {
            activeMode = nil
            blocked = true
            releaseBlockIfNeutral()
            return [.end(mode)]
        }
        releaseBlockIfNeutral()
        return []
    }

    // For lost monitors / application shutdown, discard rather than submit.
    mutating func reset() -> [Signal] {
        isHandsFree = false; lastControlTap = nil; controlDownAt = nil
        let signals = cancelActive()
        pressedKeys.removeAll()
        currentModifiers = []
        blocked = false
        return signals
    }

    private func matchingMode(keyCode: UInt16?) -> VoiceMode? {
        VoiceMode.allCases.first { mode in
            enabledModes.contains(mode) && bindings[mode]?.keyCode == keyCode && bindings[mode]?.modifiers == currentModifiers
        }
    }
    private mutating func cancelActive() -> [Signal] {
        guard let mode = activeMode else { return [] }
        activeMode = nil
        return [.cancel(mode)]
    }
    private mutating func releaseBlockIfNeutral() {
        if currentModifiers.isEmpty && pressedKeys.isEmpty { blocked = false }
    }
}
