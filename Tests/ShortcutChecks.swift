import AppKit
import Carbon

private final class FakeShortcutRegistration: ShortcutRegistering {
    var registeredModes: Set<VoiceMode> = []
    var failedModes: Set<VoiceMode> = []
    var callback: ((VoiceMode, Bool) -> Void)?
    var updateCount = 0
    var tornDown = false
    func update(bindings: [VoiceMode: KeyboardShortcutBinding], enabled: Set<VoiceMode>, onKey: @escaping (VoiceMode, Bool) -> Void) -> [String] {
        updateCount += 1
        callback = onKey
        registeredModes = enabled.filter { bindings[$0]?.keyCode != nil && !failedModes.contains($0) }
        return enabled.intersection(failedModes).map { "\($0.title) shortcut is already used." }
    }
    func teardown() { tornDown = true; callback = nil; registeredModes = [] }
}

extension CoreTests {
    @MainActor static func shortcutChecks() async throws {
        let base: NSEvent.ModifierFlags = [.option, .command]
        let a = UInt16(kVK_ANSI_A), r = UInt16(kVK_ANSI_R), f = UInt16(kVK_ANSI_F), p = UInt16(kVK_ANSI_P), x = UInt16(kVK_ANSI_X)
        let tag: Int64 = 0x5144494354
        let defaults = KeyboardShortcutBinding.defaults
        let controlBindings = defaults.mapValues { KeyboardShortcutBinding(modifiers: .control, keyCode: $0.keyCode) }
        try KeyboardShortcutBinding.validate(bindings: controlBindings, enabledModes: Set(VoiceMode.allCases))
        check(CarbonShortcutRegistration.carbonModifiers(for: .control) == UInt32(controlKey), "Control native registration has no extra modifiers")
        for mode in VoiceMode.allCases {
            var controlRouter = ShortcutRouter(bindings: controlBindings, enabledModes: Set(VoiceMode.allCases))
            check(controlRouter.flagsChanged(.control) == [.begin(.dictation)], "Control starts hold for \(mode.title)")
            if let key = controlBindings[mode]?.keyCode {
                check(controlRouter.keyDown(key, flags: .control) == [.cancel(.dictation), .begin(mode)], "Control letter upgrades to \(mode.title)")
                check(controlRouter.keyDown(key, flags: .control, isRepeat: true).isEmpty, "Control repeat does not duplicate \(mode.title)")
                check(controlRouter.keyUp(key, flags: .control) == [.end(mode)], "Letter release submits \(mode.title) once")
                check(controlRouter.flagsChanged([]).isEmpty, "Control release cannot resubmit \(mode.title)")
            } else {
                check(controlRouter.flagsChanged([]) == [.end(.dictation)], "Control release ends dictation")
            }
        }
        var now: TimeInterval = 10
        var latch = ShortcutRouter(bindings: controlBindings, enabledModes: Set(VoiceMode.allCases), doubleTapControl: true, clock: { now })
        check(latch.flagsChanged(.control) == [.begin(.dictation)], "First tap starts capture immediately")
        now += 0.08
        check(latch.flagsChanged([]) == [.cancel(.dictation)], "Short first tap never uploads audio")
        check(latch.flagsChanged([]).isEmpty, "Duplicate neutral event preserves pending tap")
        now += 0.12
        check(latch.flagsChanged(.control) == [.begin(.dictation)] && latch.isHandsFree, "Second tap locks capture")
        check(latch.flagsChanged([]).isEmpty && latch.isHandsFree, "Second tap release keeps recording")
        check(latch.keyDown(x, flags: []).isEmpty, "Typing during locked recording does not submit")
        check(latch.keyUp(x, flags: []).isEmpty, "Typing release does not submit")
        check(latch.flagsChanged(.control) == [.end(.dictation)] && !latch.isHandsFree, "Next Control press finishes once")
        check(latch.flagsChanged([]).isEmpty, "Stop tap release cannot restart")
        now += 1
        check(latch.flagsChanged(.control) == [.begin(.dictation)], "Normal hold starts after lock")
        now += 0.5
        check(latch.flagsChanged([]) == [.end(.dictation)], "Normal hold still submits on release")
        now += 1
        _ = latch.flagsChanged(.control); now += 0.05; _ = latch.flagsChanged([])
        now += 0.1; _ = latch.flagsChanged(.control); _ = latch.flagsChanged([])
        check(latch.keyDown(53, flags: []) == [.cancel(.dictation)] && !latch.isHandsFree, "Escape cancels hands-free")
        _ = latch.reset()
        now += 1; _ = latch.flagsChanged(.control); now += 0.05; _ = latch.flagsChanged([])
        now += 0.5; _ = latch.flagsChanged(.control)
        check(!latch.isHandsFree, "Late second tap does not lock")
        _ = latch.reset()
        now += 1; _ = latch.flagsChanged(.control); now += 0.05; _ = latch.flagsChanged([])
        _ = latch.keyDown(x, flags: []); _ = latch.keyUp(x, flags: [])
        now += 0.1; _ = latch.flagsChanged(.control)
        check(!latch.isHandsFree, "Intervening typing invalidates double tap")
        _ = latch.reset()
        now += 1; _ = latch.flagsChanged(.control); now += 0.05; _ = latch.flagsChanged([])
        now += 0.1; _ = latch.flagsChanged(.control); _ = latch.flagsChanged([])
        check(latch.reset() == [.cancel(.dictation)] && !latch.isHandsFree, "External cancellation clears latch")
        let controlRegistration = FakeShortcutRegistration()
        let controlHotkey = GlobalHotkey(registration: controlRegistration, pollKeyReleases: false)
        var controlSignals: [ShortcutRouter.Signal] = []
        controlHotkey.onModeSignal = { controlSignals.append($0) }
        check(controlHotkey.configure(bindings: controlBindings, enabledModes: Set(VoiceMode.allCases)).isEmpty, "Control family configures")
        controlHotkey.process(eventType: .flagsChanged, flags: .control)
        check(!controlHotkey.process(eventType: .keyDown, keyCode: UInt16(kVK_ANSI_C), flags: .control), "Control C passes through")
        check(controlSignals == [.begin(.dictation), .cancel(.dictation)], "Unrelated Control chord discards recording")
        controlHotkey.process(eventType: .keyUp, keyCode: UInt16(kVK_ANSI_C), flags: [])
        controlHotkey.process(eventType: .flagsChanged, flags: .control)
        check(controlHotkey.process(eventType: .keyDown, keyCode: p, flags: .control), "Control P is consumed")
        check(controlHotkey.process(eventType: .keyUp, keyCode: p, flags: .control), "Control P release is consumed")
        check(Array(controlSignals.suffix(3)) == [.cancel(.dictation), .begin(.polish), .end(.polish)], "Control P follows one Polish lifecycle")
        var router = ShortcutRouter()
        check(router.flagsChanged(.option).isEmpty, "One modifier does not record")
        check(router.flagsChanged(base) == [.begin(.dictation)], "Default hold starts dictation")
        check(router.flagsChanged(base).isEmpty, "Repeated flags cannot restart recording")
        check(router.flagsChanged(.command) == [.end(.dictation)], "Release either modifier ends default hold")
        check(router.flagsChanged(base).isEmpty, "Partial release cannot restart a hold")
        _ = router.flagsChanged([])
        check(router.flagsChanged(base.union(.capsLock)) == [.begin(.dictation)], "Caps Lock does not change the shortcut")
        check(router.flagsChanged(.capsLock) == [.end(.dictation)], "Caps Lock does not prevent release")

        router = ShortcutRouter(enabledModes: Set(VoiceMode.allCases))
        check(router.flagsChanged(base) == [.begin(.dictation)], "Base dictation begins before a possible agent key")
        check(router.keyDown(a, flags: base) == [.cancel(.dictation), .begin(.ask)], "Ask upgrade discards dictation before starting Ask")
        check(router.keyDown(a, flags: base, isRepeat: true).isEmpty, "Held Ask key does not repeat")
        check(router.keyDown(a, flags: base).isEmpty, "Duplicate monitor event does not repeat")
        check(router.keyUp(a, flags: base) == [.end(.ask)], "Release letter finishes Ask")
        check(router.flagsChanged(base).isEmpty, "Letter release does not fall back to dictation")
        _ = router.keyDown(a, flags: base)
        check(router.activeMode == nil, "Repressing letter needs all shortcut keys released")
        _ = router.keyUp(a, flags: [])
        check(router.flagsChanged(base) == [.begin(.dictation)], "Fully released shortcut can start again")
        check(router.keyDown(r, flags: base) == [.cancel(.dictation), .begin(.act)], "Act upgrade never sends interim dictation")
        check(router.flagsChanged(.option) == [.end(.act)], "Release modifier finishes Act while letter is held")
        _ = router.flagsChanged([])
        check(router.flagsChanged(base).isEmpty, "Still-held letter blocks another recording")
        _ = router.flagsChanged([])
        _ = router.keyUp(r, flags: [])
        check(router.flagsChanged(base) == [.begin(.dictation)], "Act release leaves the next full hold ready")
        check(router.keyDown(f, flags: base) == [.cancel(.dictation), .begin(.fullControl)], "Full Control hold discards preliminary dictation before recording its task")
        check(router.keyDown(f, flags: base, isRepeat: true).isEmpty, "Held Full Control key never starts duplicate tasks")
        check(router.keyUp(f, flags: base) == [.end(.fullControl)], "Releasing F finishes Full Control exactly once")
        check(router.keyUp(f, flags: base).isEmpty, "Duplicate F release never sends a second Full Control task")
        check(router.flagsChanged(base).isEmpty, "Full Control release cannot fall back to dictation")
        _ = router.flagsChanged([])
        _ = router.flagsChanged(base)
        check(router.keyDown(f, flags: base) == [.cancel(.dictation), .begin(.fullControl)], "Full Control is ready again after a full release")
        check(router.flagsChanged(.option) == [.end(.fullControl)], "Releasing a required modifier also finishes Full Control")

        router = ShortcutRouter(enabledModes: [.dictation, .polish])
        check(router.flagsChanged(base) == [.begin(.dictation)], "Polish shares the existing modifier prefix")
        check(router.keyDown(p, flags: base) == [.cancel(.dictation), .begin(.polish)], "Polish hold discards preliminary dictation before rewriting")
        check(router.keyDown(p, flags: base, isRepeat: true).isEmpty, "Held Polish key cannot submit repeated rewrites")
        check(router.keyUp(p, flags: base) == [.end(.polish)], "Releasing P finishes Polish once")
        check(router.keyUp(p, flags: base).isEmpty && router.flagsChanged(base).isEmpty,
              "Duplicate Polish release cannot paste twice or fall back to dictation")
        _ = router.flagsChanged([])
        _ = router.flagsChanged(base)
        check(router.keyDown(p, flags: base) == [.cancel(.dictation), .begin(.polish)], "Polish works again after a full release")
        check(router.flagsChanged(.command) == [.end(.polish)], "Releasing either required modifier completes Polish")

        router = ShortcutRouter()
        _ = router.flagsChanged(base)
        check(router.keyDown(p, flags: base) == [.cancel(.dictation)], "Disabled Polish cancels preliminary dictation without rewriting")
        check(router.keyUp(p, flags: []).isEmpty, "Disabled Polish never submits audio")

        router = ShortcutRouter()
        _ = router.flagsChanged(base)
        check(router.keyDown(f, flags: base) == [.cancel(.dictation)], "Disabled Full Control does not intercept the task as another mode")
        check(router.keyUp(f, flags: []).isEmpty, "Disabled Full Control never submits audio")

        router = ShortcutRouter(enabledModes: [.fullControl])
        check(router.flagsChanged(base).isEmpty, "Full Control can run with no modifier-only dictation binding active")
        check(router.keyDown(f, flags: base) == [.begin(.fullControl)], "Full Control can start independently of Ask and Do")
        check(router.reset() == [.cancel(.fullControl)], "Lost monitors cancel rather than dispatching a Full Control request")

        router = ShortcutRouter()
        _ = router.flagsChanged(base)
        check(router.keyDown(a, flags: base) == [.cancel(.dictation)], "Disabled Ask is an ordinary chord that cancels")
        check(router.keyUp(a, flags: base).isEmpty, "Disabled agent release cannot submit")
        _ = router.flagsChanged([])
        check(router.flagsChanged(base) == [.begin(.dictation)], "Disabled mode cancellation recovers after release")
        check(router.flagsChanged(base.union(.shift)) == [.cancel(.dictation)], "Additional modifier cancels instead of sending")
        check(router.flagsChanged(base).isEmpty, "Removing extra modifier does not resume cancelled audio")
        _ = router.flagsChanged([])
        _ = router.flagsChanged(.option)
        _ = router.keyDown(x, flags: .option)
        check(router.flagsChanged(base).isEmpty, "Earlier modified key blocks accidental start")
        _ = router.keyUp(x, flags: [])
        check(router.flagsChanged(base) == [.begin(.dictation)], "Unrelated shortcut can fully recover")

        router = ShortcutRouter(enabledModes: [.ask, .act])
        check(router.flagsChanged(base).isEmpty, "Disabled dictation stays off while agent modifiers are held")
        check(router.keyDown(a, flags: base) == [.begin(.ask)], "Ask works independently of dictation")
        check(router.keyDown(r, flags: base) == [.cancel(.ask)], "A second letter cancels an agent hold")
        check(router.keyUp(a, flags: base).isEmpty, "Cancelled agent never submits on letter release")
        _ = router.keyUp(r, flags: [])
        check(router.keyDown(r, flags: base) == [.begin(.act)], "Keyed shortcut works when modifier event was missed")
        check(router.keyUp(r, flags: []) == [.end(.act)], "Key release with all modifiers up ends exactly once")
        check(router.keyUp(r, flags: []).isEmpty, "Duplicate release cannot submit twice")

        router = ShortcutRouter()
        check(router.keyDown(UInt16(kVK_ANSI_V), flags: .command, sourceTag: tag).isEmpty, "App paste key-down is ignored")
        check(router.keyUp(UInt16(kVK_ANSI_V), flags: .command, sourceTag: tag).isEmpty, "App paste key-up is ignored")
        check(router.flagsChanged(.command, sourceTag: tag).isEmpty, "App paste modifiers are ignored")
        check(router.flagsChanged(base) == [.begin(.dictation)], "Automatic paste never blocks the next hold")
        check(router.keyDown(x, flags: base, sourceTag: tag).isEmpty, "Injected app event cannot cancel physical recording")
        check(router.flagsChanged([]) == [.end(.dictation)], "Physical release still submits after ignored event")

        router = ShortcutRouter()
        _ = router.keyDown(x, flags: [])
        check(router.flagsChanged(base).isEmpty, "Holding a normal key before modifiers cannot trigger recording")
        _ = router.keyUp(x, flags: [])
        check(router.flagsChanged(base) == [.begin(.dictation)], "Normal typing release leaves shortcut usable")
        check(router.reset() == [.cancel(.dictation)], "Reset discards active audio rather than submitting")
        check(router.reset().isEmpty, "Reset is idempotent")
        check(router.flagsChanged(base) == [.begin(.dictation)], "Reset removes stuck monitor state")
        let changedSignals = try router.configure(bindings: defaults, enabledModes: Set(VoiceMode.allCases))
        check(changedSignals == [.cancel(.dictation)], "Changing modes cancels a hold")
        check(router.flagsChanged(base).isEmpty, "Config change cannot restart held modifiers")
        _ = router.flagsChanged([])
        _ = router.flagsChanged(base)
        let unchangedSignals = try router.configure(bindings: defaults, enabledModes: Set(VoiceMode.allCases))
        check(unchangedSignals.isEmpty, "Unchanged config preserves active hold")
        check(router.activeMode == .dictation, "No-op settings refresh does not lose recording")

        var colliding = defaults
        colliding[.ask] = defaults[.dictation]
        do { try KeyboardShortcutBinding.validate(bindings: colliding, enabledModes: [.dictation, .ask]); check(false, "Active collisions must fail") }
        catch { check(error.localizedDescription.contains("different shortcuts"), "Collision error names the needed fix") }
        var fullCollision = defaults
        fullCollision[.fullControl] = defaults[.ask]
        await expectError("Full Control") {
            try KeyboardShortcutBinding.validate(bindings: fullCollision, enabledModes: [.ask, .fullControl])
        }
        try KeyboardShortcutBinding.validate(bindings: fullCollision, enabledModes: [.ask])
        check(true, "Disabled Full Control may retain an inactive conflicting preference")
        try KeyboardShortcutBinding.validate(bindings: colliding, enabledModes: [.dictation])
        check(true, "Disabled shortcut may share an active binding")
        do { _ = try router.configure(bindings: colliding, enabledModes: [.dictation, .ask]); check(false, "Bad reconfiguration must fail") }
        catch { check(router.activeMode == .dictation && router.bindings == defaults, "Failed settings preserve current valid state") }
        check(ShortcutRouter(bindings: colliding, enabledModes: [.dictation, .ask]).enabledModes.isEmpty, "Invalid startup shortcuts fail closed")
        await expectError("Choose a shortcut") { try KeyboardShortcutBinding.validate(bindings: [:], enabledModes: [.ask]) }
        await expectError("at least two") { try KeyboardShortcutBinding.validate(bindings: [.dictation: .init(modifiers: .command)], enabledModes: [.dictation]) }
        await expectError("at least two") { try KeyboardShortcutBinding.validate(bindings: [.dictation: .init(modifiers: base.union(.function))], enabledModes: [.dictation]) }
        await expectError("letter key") { try KeyboardShortcutBinding.validate(bindings: [.ask: .init(keyCode: 999)], enabledModes: [.ask]) }
        await expectError("same modifiers") {
            try KeyboardShortcutBinding.validate(bindings: [.dictation: .init(), .ask: .init(modifiers: base.union(.shift), keyCode: a)], enabledModes: [.dictation, .ask])
        }
        let custom: [VoiceMode: KeyboardShortcutBinding] = [.dictation: .init(keyCode: UInt16(kVK_ANSI_D)), .ask: .init(keyCode: UInt16(kVK_ANSI_G))]
        router = ShortcutRouter(bindings: custom, enabledModes: [.dictation, .ask])
        check(router.flagsChanged(base).isEmpty, "A keyed dictation preset does not record on modifiers alone")
        check(router.keyDown(UInt16(kVK_ANSI_D), flags: base) == [.begin(.dictation)], "Custom dictation key starts")
        check(router.keyUp(UInt16(kVK_ANSI_D), flags: base) == [.end(.dictation)], "Custom dictation key releases")

        let encoded = try JSONEncoder().encode(defaults)
        let decoded = try JSONDecoder().decode([VoiceMode: KeyboardShortcutBinding].self, from: encoded)
        check(decoded == defaults, "Shortcut preferences persist without losing modifiers or key codes")
        check(KeyboardShortcutBinding.defaultBinding(for: .dictation).displayLabel == "⌥⌘", "Dictation label keeps chosen shortcut")
        check(KeyboardShortcutBinding.defaultBinding(for: .ask).displayLabel == "⌥⌘A", "Ask label shows its extra letter")
        check(KeyboardShortcutBinding.defaultBinding(for: .act).displayLabel == "⌥⌘R", "Act label shows its extra letter")
        check(KeyboardShortcutBinding.defaultBinding(for: .fullControl).displayLabel == "⌥⌘F", "Full Control label shows its distinct F hold")
        check(KeyboardShortcutBinding.defaultBinding(for: .polish).displayLabel == "⌥⌘P", "Polish has its distinct Option Command P hold")
        check(KeyboardShortcutBinding.presets.contains(.defaultBinding(for: .polish)), "Polish default is available in the shortcut picker")
        check(KeyboardShortcutBinding.presets.contains(.defaultBinding(for: .fullControl)), "Full Control's default appears in the shortcut picker")
        check(KeyboardShortcutBinding.presets.contains(.init(modifiers: .control)), "Picker offers Control hold")
        check(Set(KeyboardShortcutBinding.presets).count == KeyboardShortcutBinding.presets.count, "Shortcut picker has no duplicates")
        check(CarbonShortcutRegistration.carbonModifiers(for: base) == UInt32(optionKey | cmdKey), "Native registration reserves exactly Option+Command")
        check(CarbonShortcutRegistration.carbonModifiers(for: base.union([.shift, .control])) == UInt32(optionKey | cmdKey | shiftKey | controlKey), "Native modifier conversion preserves configurable modifiers")

        // Exercise production monitor/registration wiring without reserving a
        // real OS shortcut or reading the user's keyboard/clipboard state.
        let registration = FakeShortcutRegistration()
        var physicalFlags = NSEvent.ModifierFlags()
        var physicalKeys: Set<UInt16> = []
        var hotkey: GlobalHotkey? = GlobalHotkey(registration: registration, currentModifiers: { physicalFlags },
            isKeyDown: { physicalKeys.contains($0) }, pollKeyReleases: false)
        var emitted: [ShortcutRouter.Signal] = []
        var legacyPresses = 0
        hotkey!.onPress = { legacyPresses += 1 }
        hotkey!.onModeSignal = { emitted.append($0) }
        check(hotkey!.configure(bindings: defaults, enabledModes: Set(VoiceMode.allCases)).isEmpty, "Controller registers enabled keyed modes")
        check(registration.registeredModes == [.polish, .ask, .act, .fullControl], "All enabled keyed modes register; modifier-only dictation does not")
        physicalFlags = base
        check(!hotkey!.process(eventType: .flagsChanged, flags: base), "Modifier flags continue to the focused application")
        check(emitted == [.begin(.dictation)] && legacyPresses == 0, "Mode callback does not also fire legacy recording callbacks")
        physicalKeys = [a]
        registration.callback?(.ask, true)
        check(emitted == [.begin(.dictation), .cancel(.dictation), .begin(.ask)], "Native hotkey callback upgrades through the production router")
        check(hotkey!.process(eventType: .keyDown, keyCode: a, flags: base), "Enabled local letter shortcut is consumed")
        check(emitted.count == 3, "Native and NSEvent duplicate key-down do not start twice")
        registration.callback?(.ask, false)
        check(emitted.count == 3, "Premature native release cannot stop a physically held chord")
        physicalFlags = .option
        registration.callback?(.ask, false)
        check(emitted.last == .end(.ask), "Native release ends after a required modifier physically releases")
        let afterEnd = emitted.count
        check(hotkey!.process(eventType: .keyDown, keyCode: a, flags: [], isRepeat: true), "Held shortcut key's unmodified repeats never type into the app")
        check(emitted.count == afterEnd, "Unmodified shortcut repeat never starts or submits a second recording")
        physicalFlags = base
        hotkey!.process(eventType: .flagsChanged, flags: base)
        check(emitted.count == afterEnd, "Still-held agent letter prevents a fresh modifier recording")
        physicalFlags = []
        physicalKeys = []
        hotkey!.pollHeldKeys()
        check(!hotkey!.process(eventType: .keyDown, keyCode: a, flags: []), "Fresh ordinary letter after full shortcut release still types normally")
        hotkey!.process(eventType: .keyUp, keyCode: a, flags: [])
        physicalFlags = base
        hotkey!.process(eventType: .flagsChanged, flags: base)
        check(emitted.last == .begin(.dictation), "Physical polling recovers even if native key-up is swallowed")
        physicalKeys = [r]
        registration.callback?(.act, true)
        physicalKeys = []
        registration.callback?(.act, false)
        check(emitted.last == .end(.act), "Physical letter release completes agent while modifiers remain held")
        let beforeDuplicateUp = emitted.count
        check(hotkey!.process(eventType: .keyUp, keyCode: r, flags: base), "Reserved local key-up is also consumed")
        check(emitted.count == beforeDuplicateUp, "Duplicate native and monitor key-up cannot submit twice")
        physicalFlags = []
        hotkey!.process(eventType: .flagsChanged, flags: [])
        physicalFlags = base
        hotkey!.process(eventType: .flagsChanged, flags: base)
        physicalKeys = [f]
        registration.callback?(.fullControl, true)
        check(emitted.suffix(2) == [.cancel(.dictation), .begin(.fullControl)], "Native Full Control registration upgrades the modifier hold through the real router")
        check(hotkey!.process(eventType: .keyDown, keyCode: f, flags: base), "Reserved Full Control key does not type into the focused field")
        let beforeFullRelease = emitted.count
        registration.callback?(.fullControl, false)
        check(emitted.count == beforeFullRelease, "Native Full Control callback cannot end a still-held physical key")
        physicalKeys = []
        hotkey!.pollHeldKeys()
        check(emitted.last == .end(.fullControl), "Physical polling completes Full Control even if native key-up is lost")
        let afterFullRelease = emitted.count
        check(hotkey!.process(eventType: .keyUp, keyCode: f, flags: base), "Full Control's matching key-up is consumed")
        check(emitted.count == afterFullRelease, "Duplicate Full Control monitor release cannot submit again")
        physicalFlags = []
        hotkey!.process(eventType: .flagsChanged, flags: [])
        physicalFlags = base
        hotkey!.process(eventType: .flagsChanged, flags: base)
        physicalKeys = [p]
        registration.callback?(.polish, true)
        check(emitted.suffix(2) == [.cancel(.dictation), .begin(.polish)],
              "Native Polish registration upgrades through the production monitor without submitting dictation")
        check(hotkey!.process(eventType: .keyDown, keyCode: p, flags: base), "Polish shortcut does not type P into the focused field")
        let beforePolishRelease = emitted.count
        registration.callback?(.polish, false)
        check(emitted.count == beforePolishRelease, "Native callback cannot finish Polish while its physical key remains held")
        physicalKeys = []
        hotkey!.pollHeldKeys()
        check(emitted.last == .end(.polish), "Physical release polling finishes Polish if native key-up is missed")
        let afterPolishRelease = emitted.count
        check(hotkey!.process(eventType: .keyUp, keyCode: p, flags: base), "Polish consumes its matching shortcut key-up")
        check(emitted.count == afterPolishRelease, "Duplicate native and monitor Polish release submits exactly once")
        physicalFlags = []
        hotkey!.process(eventType: .flagsChanged, flags: [])
        check(!hotkey!.process(eventType: .keyDown, keyCode: p, flags: []), "Normal P typing still works after Polish releases")
        hotkey!.process(eventType: .keyUp, keyCode: p, flags: [])
        physicalFlags = base
        hotkey!.process(eventType: .flagsChanged, flags: base)
        let updates = registration.updateCount
        let beforeRefresh = emitted.count
        check(hotkey!.configure(bindings: defaults, enabledModes: Set(VoiceMode.allCases)).isEmpty, "Unchanged native configuration succeeds")
        check(registration.updateCount == updates && emitted.count == beforeRefresh, "Settings refresh never unregisters or cancels an unchanged hold")
        check(!hotkey!.process(eventType: .keyDown, keyCode: x, flags: base), "Ordinary app shortcut is left untouched")
        check(emitted.last == .cancel(.dictation), "Ordinary app shortcut discards interim audio")
        hotkey!.process(eventType: .keyUp, keyCode: x, flags: [])
        check(!hotkey!.process(eventType: .keyDown, keyCode: UInt16(kVK_ANSI_V), flags: .command, sourceTag: tag), "Generated paste is never swallowed by local monitor")
        hotkey!.process(eventType: .flagsChanged, flags: base)
        check(emitted.last == .begin(.dictation), "Injected paste leaves integrated monitor ready for next hold")
        hotkey!.process(eventType: .flagsChanged, flags: [])
        registration.failedModes = [.act]
        var changed = defaults
        changed[.act] = .init(keyCode: UInt16(kVK_ANSI_G))
        check(!hotkey!.configure(bindings: changed, enabledModes: Set(VoiceMode.allCases)).isEmpty, "OS reservation conflicts are returned to Settings")
        hotkey!.process(eventType: .flagsChanged, flags: base)
        let beforeConflict = emitted.count
        check(!hotkey!.process(eventType: .keyDown, keyCode: UInt16(kVK_ANSI_G), flags: base), "Failed reservation is never consumed as an app shortcut")
        check(Array(emitted.dropFirst(beforeConflict)) == [.cancel(.dictation)], "Unreserved mode cannot activate through observer fallback")
        check(!hotkey!.configure(bindings: colliding, enabledModes: [.dictation, .ask]).isEmpty, "Invalid monitor configuration reports collision")
        check(registration.registeredModes == [.polish, .ask, .fullControl], "Invalid settings preserve existing native reservations, including Polish")
        hotkey = nil
        check(registration.tornDown, "Monitor teardown unregisters native shortcuts")
    }
}
