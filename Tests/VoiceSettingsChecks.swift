import Foundation

extension CoreTests {
    @MainActor static func voiceSettingsChecks() async throws {
        let suite = "quick-dictate-voice-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func store(_ value: [String: Any]) throws {
            defaults.set(try JSONSerialization.data(withJSONObject: value, options: .sortedKeys), forKey: FeatureSettings.storageKey)
        }
        func serialized(_ options: FeatureOptions) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as! [String: Any]
        }

        let fresh = FeatureSettings(defaults: defaults)
        check(fresh.options.schemaVersion == 3, "New voice settings use schema version 3")
        check(fresh.options.model == AgentModel.defaultID, "GPT-6 Luna is the new default assistant")
        check(fresh.options.workRoot == FileManager.default.homeDirectoryForCurrentUser.path,
              "A fresh Mac starts optional actions in its own existing home folder")
        check(fresh.options.speakReplies && fresh.options.webSearchEnabled, "Voice replies and as-needed web search default on")
        check(!fresh.options.polishEnabled && !fresh.options.askEnabled && !fresh.options.actEnabled && !fresh.options.fullControlEnabled && !fresh.options.terminalEnabled && !fresh.options.computerEnabled,
              "The voice upgrade does not enable assistant modes or local action capabilities")
        check(fresh.options.fullControlScreenEnabled, "Screen control is available by default only after Full Control is enabled")
        check(fresh.options.enabledModes == [.dictation], "Fresh install does not activate Full Control or its shortcut")
        check(!fresh.options.useSelectedText, "The voice upgrade leaves selected-text sharing opt-in")
        check(defaults.data(forKey: FeatureSettings.storageKey) == nil, "Loading fresh defaults does not write preference data")

        let preferredDictation = KeyboardShortcutBinding.presets[3]
        let preferredAsk = KeyboardShortcutBinding.presets[4]
        let preferredAct = KeyboardShortcutBinding.presets[5]
        var legacy = FeatureOptions()
        legacy.askEnabled = true
        legacy.actEnabled = true
        legacy.terminalEnabled = true
        legacy.computerEnabled = false
        legacy.speakReplies = false
        legacy.useSelectedText = true
        legacy.model = "anthropic/claude-opus-5"
        legacy.workRoot = "/tmp/quick-dictate-user-chosen-folder"
        legacy.shortcuts = [VoiceMode.dictation.rawValue: preferredDictation,
                            VoiceMode.ask.rawValue: preferredAsk, VoiceMode.act.rawValue: preferredAct]
        var legacyJSON = try serialized(legacy)
        legacyJSON.removeValue(forKey: "schemaVersion")
        legacyJSON.removeValue(forKey: "webSearchEnabled")
        legacyJSON.removeValue(forKey: "fullControlEnabled")
        legacyJSON.removeValue(forKey: "fullControlScreenEnabled")
        legacyJSON.removeValue(forKey: "polishEnabled")
        try store(legacyJSON)
        let upgraded = FeatureSettings(defaults: defaults)
        check(upgraded.options.schemaVersion == 3 && upgraded.options.model == FeatureOptions.defaultAssistantModel,
              "Unversioned old preferences migrate once to the requested Luna model")
        check(upgraded.options.speakReplies && upgraded.options.webSearchEnabled,
              "Migration enables spoken voice answers and as-needed search")
        check(upgraded.options.askEnabled && upgraded.options.actEnabled && upgraded.options.terminalEnabled && !upgraded.options.computerEnabled,
              "Migration preserves all existing capability choices")
        check(upgraded.options.useSelectedText && upgraded.options.workRoot == legacy.workRoot,
              "Migration preserves selected-text preference and chosen work folder")
        check(upgraded.options.shortcuts == legacy.shortcuts, "Migration preserves every chosen shortcut")
        check(!upgraded.options.fullControlEnabled && !upgraded.options.enabledModes.contains(.fullControl),
              "Old saved settings never implicitly enable Full Control")
        check(upgraded.options.binding(for: .fullControl).displayLabel == "⌥⌘F",
              "An older shortcut dictionary supplies Full Control's distinct default without rewriting existing bindings")
        check(!upgraded.options.polishEnabled && !upgraded.options.enabledModes.contains(.polish),
              "Missing Polish preference never enables rewriting for an existing installation")
        check(upgraded.options.binding(for: .polish).displayLabel == "⌥⌘P",
              "An older shortcut dictionary supplies the Polish hold without rewriting the user's shortcuts")
        let migrationData = defaults.data(forKey: FeatureSettings.storageKey)!
        let savedMigration = try JSONSerialization.jsonObject(with: migrationData) as! [String: Any]
        check(savedMigration["schemaVersion"] as? Int == 3, "Migration persists its schema marker under the original storage key")
        check(FeatureSettings(defaults: defaults).options == upgraded.options, "Reloading upgraded settings is idempotent")
        check(defaults.data(forKey: FeatureSettings.storageKey) == migrationData, "Reload does not rewrite already-migrated settings")

        let alternativeModel = AgentModel.presets.first(where: { $0.id != FeatureOptions.defaultAssistantModel })!.id
        var changes = 0
        upgraded.onChange = { changes += 1 }
        try upgraded.update { $0.speakReplies = false; $0.webSearchEnabled = false; $0.model = alternativeModel }
        let chosen = FeatureSettings(defaults: defaults)
        check(!chosen.options.speakReplies && !chosen.options.webSearchEnabled && chosen.options.model == alternativeModel,
              "A user's new-schema voice/search/model choices survive reload without remigration")
        check(changes == 1, "One preference change sends one change callback")
        try upgraded.update { _ in }
        check(changes == 1, "A no-op update neither writes nor sends a callback")

        try store(["schemaVersion": 2, "model": "google/gemini-3.5-flash-lite", "askEnabled": true,
                   "actEnabled": true, "speakReplies": false, "webSearchEnabled": false,
                   "workRoot": legacy.workRoot])
        let formerDefault = FeatureSettings(defaults: defaults)
        check(formerDefault.options.schemaVersion == 3 && formerDefault.options.model == AgentModel.defaultID,
              "Saved Gemini default upgrades to Luna")
        check(formerDefault.options.askEnabled && formerDefault.options.actEnabled && !formerDefault.options.speakReplies &&
              !formerDefault.options.webSearchEnabled && formerDefault.options.workRoot == legacy.workRoot,
              "Model migration preserves unrelated mode, voice, search and folder choices")
        try store(["schemaVersion": 2, "model": alternativeModel, "askEnabled": true])
        let chosenPreset = FeatureSettings(defaults: defaults)
        check(chosenPreset.options.schemaVersion == 3 && chosenPreset.options.model == alternativeModel,
              "Model migration keeps a chosen non-Gemini preset")

        try store(["schemaVersion": 2, "askEnabled": true, "speakReplies": false, "workRoot": legacy.workRoot])
        let partial = FeatureSettings(defaults: defaults)
        check(partial.options.askEnabled && !partial.options.speakReplies && partial.options.workRoot == legacy.workRoot,
              "Partial schema 2 data preserves all provided choices")
        check(partial.options.webSearchEnabled && partial.options.model == FeatureOptions.defaultAssistantModel,
              "Missing newly-added keys independently receive current defaults")
        check(partial.options.binding(for: .ask) == KeyboardShortcutBinding.defaultBinding(for: .ask),
              "Missing shortcut data falls back to valid defaults")
        check(!partial.options.fullControlEnabled, "Schema 2 saved before Full Control leaves that mode off")

        let beforeFullControl = partial.options
        try partial.update { $0.fullControlEnabled = true }
        let fullControl = FeatureSettings(defaults: defaults)
        check(fullControl.options.fullControlEnabled && fullControl.options.enabledModes == [.dictation, .ask, .fullControl],
              "Enabling Full Control persists and activates only its separate mode")
        check(!fullControl.options.actEnabled && !fullControl.options.terminalEnabled && !fullControl.options.computerEnabled,
              "Full Control does not turn on or depend on reviewed Do capabilities")
        check(fullControl.options.askEnabled == beforeFullControl.askEnabled && fullControl.options.model == beforeFullControl.model &&
              fullControl.options.workRoot == beforeFullControl.workRoot && fullControl.options.speakReplies == beforeFullControl.speakReplies,
              "Full Control leaves the selected Ask model, voice preference and work folder intact")
        check(fullControl.options.fullControlScreenEnabled, "Enabling Full Control preserves its default screen capability")
        try fullControl.update { $0.fullControlScreenEnabled = false }
        check(!FeatureSettings(defaults: defaults).options.fullControlScreenEnabled,
              "An explicit screen-control choice persists independently of Full Control mode")
        let beforeFullCollision = defaults.data(forKey: FeatureSettings.storageKey)
        await expectError("different shortcuts") {
            try fullControl.update { $0.shortcuts[VoiceMode.fullControl.rawValue] = $0.binding(for: .ask) }
        }
        check(defaults.data(forKey: FeatureSettings.storageKey) == beforeFullCollision,
              "Full Control shortcut collision does not overwrite saved preferences")
        try fullControl.update { $0.fullControlEnabled = false; $0.shortcuts[VoiceMode.fullControl.rawValue] = $0.binding(for: .ask) }
        await expectError("different shortcuts") { try fullControl.update { $0.fullControlEnabled = true } }
        check(!fullControl.options.fullControlEnabled && fullControl.options.askEnabled,
              "Enabling a colliding Full Control shortcut leaves other active modes usable")
        try fullControl.update { $0.shortcuts[VoiceMode.fullControl.rawValue] = .defaultBinding(for: .fullControl); $0.fullControlEnabled = true }
        try fullControl.update { $0.fullControlEnabled = false }
        check(!FeatureSettings(defaults: defaults).options.fullControlEnabled && !fullControl.options.fullControlScreenEnabled,
              "Disabling Full Control persists without re-enabling screen access")

        let beforePolish = fullControl.options
        let beforePolishBytes = defaults.data(forKey: FeatureSettings.storageKey)
        check(!FeatureSettings(defaults: defaults).options.polishEnabled && defaults.data(forKey: FeatureSettings.storageKey) == beforePolishBytes,
              "Loading schema 2 without Polish does not migrate or rewrite any preferences")
        try fullControl.update { $0.polishEnabled = true }
        let polish = FeatureSettings(defaults: defaults)
        var expectedPolish = beforePolish
        expectedPolish.polishEnabled = true
        check(polish.options == expectedPolish, "Enabling Polish persists its switch and preserves every other setting exactly")
        check(polish.options.enabledModes == beforePolish.enabledModes.union([.polish]),
              "Polish enables only its own mode and shortcut")
        check(!VoiceMode.polish.isAssistant && !VoiceMode.dictation.isAssistant && [VoiceMode.ask, .act, .fullControl].allSatisfy(\.isAssistant),
              "Polish remains separate from assistant capabilities and conversation routing")
        let beforePolishCollision = defaults.data(forKey: FeatureSettings.storageKey)
        await expectError("different shortcuts") {
            try polish.update { $0.shortcuts[VoiceMode.polish.rawValue] = $0.binding(for: .ask) }
        }
        check(defaults.data(forKey: FeatureSettings.storageKey) == beforePolishCollision,
              "A colliding Polish hold cannot overwrite an existing working shortcut")
        try polish.update { $0.polishEnabled = false; $0.shortcuts[VoiceMode.polish.rawValue] = $0.binding(for: .ask) }
        await expectError("different shortcuts") { try polish.update { $0.polishEnabled = true } }
        check(!polish.options.polishEnabled && polish.options.askEnabled,
              "Enabling a conflicting saved Polish shortcut leaves Ask available")
        try polish.update { $0.shortcuts[VoiceMode.polish.rawValue] = .defaultBinding(for: .polish); $0.polishEnabled = true }
        try polish.update { $0.polishEnabled = false }
        check(!FeatureSettings(defaults: defaults).options.polishEnabled, "Disabling Polish persists independently")

        try store(["schemaVersion": 2, "askEnabled": true, "actEnabled": true, "terminalEnabled": "invalid", "fullControlEnabled": "invalid", "polishEnabled": "invalid",
                   "speakReplies": false, "webSearchEnabled": false, "model": "unknown/removed-model", "workRoot": legacy.workRoot])
        let damaged = FeatureSettings(defaults: defaults)
        check(damaged.options.askEnabled && damaged.options.actEnabled && !damaged.options.speakReplies && !damaged.options.webSearchEnabled,
              "A damaged individual field does not reset unrelated mode or voice settings")
        check(!damaged.options.terminalEnabled && damaged.options.model == FeatureOptions.defaultAssistantModel,
              "An invalid capability stays off and an unsupported model falls back safely")
        check(damaged.options.workRoot == legacy.workRoot, "Model recovery preserves the selected folder")
        check(!damaged.options.fullControlEnabled, "A damaged Full Control preference never silently enables full access")
        check(!damaged.options.polishEnabled, "A damaged Polish preference never silently enables rewriting")

        var conflict = FeatureOptions()
        conflict.askEnabled = true
        conflict.useSelectedText = true
        conflict.workRoot = legacy.workRoot
        conflict.shortcuts[VoiceMode.ask.rawValue] = conflict.binding(for: .dictation)
        defaults.set(try JSONEncoder().encode(conflict), forKey: FeatureSettings.storageKey)
        let repaired = FeatureSettings(defaults: defaults)
        check(repaired.options.askEnabled && repaired.options.useSelectedText && repaired.options.workRoot == legacy.workRoot,
              "Repairing invalid shortcuts preserves all other preferences")
        check(repaired.options.shortcuts == FeatureOptions().shortcuts, "Invalid shortcut collisions recover to distinct defaults")
        let beforeInvalid = defaults.data(forKey: FeatureSettings.storageKey)
        await expectError("different shortcuts") { try repaired.update { $0.shortcuts[VoiceMode.ask.rawValue] = $0.binding(for: .dictation) } }
        check(defaults.data(forKey: FeatureSettings.storageKey) == beforeInvalid, "Rejected changes leave persisted data untouched")
        await expectError("Choose a folder") { try repaired.update { $0.workRoot = "relative/path" } }
        await expectError("Choose a folder") { try repaired.update { $0.workRoot = "/tmp/invalid\0folder" } }
        check(repaired.options.workRoot == legacy.workRoot, "Invalid folder changes leave the previous folder active")

        try store(["schemaVersion": 9, "askEnabled": true, "unknownFutureField": "preserve-me"])
        let futureData = defaults.data(forKey: FeatureSettings.storageKey)
        let future = FeatureSettings(defaults: defaults)
        check(!future.options.askEnabled, "Unsupported future settings do not enable capabilities in an older binary")
        check(defaults.data(forKey: FeatureSettings.storageKey) == futureData, "Reading a future schema preserves its original data")
        await expectError("newer app version") { try future.update { $0.askEnabled = true } }
        check(defaults.data(forKey: FeatureSettings.storageKey) == futureData, "An older binary cannot overwrite future settings")

        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: FeatureSettings.storageKey)
        let recovered = FeatureSettings(defaults: defaults)
        check(recovered.options == FeatureOptions(), "Unreadable settings load conservative capability defaults")
        check(defaults.data(forKey: FeatureSettings.storageKey) == corrupt, "Loading unreadable data does not overwrite it")
    }
}
