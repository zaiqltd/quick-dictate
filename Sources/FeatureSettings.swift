import AppKit
import Combine
import Foundation

extension VoiceMode {
    var symbol: String { switch self { case .dictation: return "waveform"; case .polish: return "sparkles"; case .ask: return "bubble.left.and.bubble.right"; case .act: return "command"; case .fullControl: return "bolt.fill" } }
    var subtitle: String { switch self { case .dictation: return "Your words, wherever you type."; case .polish: return "Less filler. Still your voice."; case .ask: return "Talk it through. Get an answer."; case .act: return "Turn a request into an action."; case .fullControl: return "Give Codex the task. Watch it get done." } }
}

struct FeatureOptions: Codable, Equatable {
    static let currentSchemaVersion = 3
    static let defaultAssistantModel = AgentModel.defaultID

    var schemaVersion = Self.currentSchemaVersion
    var polishEnabled = false
    var askEnabled = false
    var actEnabled = false
    var fullControlEnabled = false
    var fullControlScreenEnabled = true
    var terminalEnabled = false
    var computerEnabled = false
    // This preference applies to voice requests. Typed requests remain silent
    // unless the user explicitly chooses to play their answer.
    var speakReplies = true
    var webSearchEnabled = true
    var useSelectedText = false
    var model = Self.defaultAssistantModel
    var workRoot = FileManager.default.homeDirectoryForCurrentUser.path
    var shortcuts: [String: KeyboardShortcutBinding] = Dictionary(uniqueKeysWithValues: VoiceMode.allCases.map { ($0.rawValue, KeyboardShortcutBinding.defaultBinding(for: $0)) })

    init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, polishEnabled, askEnabled, actEnabled, fullControlEnabled, fullControlScreenEnabled, terminalEnabled, computerEnabled
        case speakReplies, webSearchEnabled, useSelectedText, model, workRoot, shortcuts
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // The previous release had no schema key. Missing or damaged individual
        // fields use their safe defaults without losing unrelated preferences.
        schemaVersion = (try? values.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? 1
        polishEnabled = (try? values.decodeIfPresent(Bool.self, forKey: .polishEnabled)) ?? polishEnabled
        askEnabled = (try? values.decodeIfPresent(Bool.self, forKey: .askEnabled)) ?? askEnabled
        actEnabled = (try? values.decodeIfPresent(Bool.self, forKey: .actEnabled)) ?? actEnabled
        fullControlEnabled = (try? values.decodeIfPresent(Bool.self, forKey: .fullControlEnabled)) ?? fullControlEnabled
        fullControlScreenEnabled = (try? values.decodeIfPresent(Bool.self, forKey: .fullControlScreenEnabled)) ?? fullControlScreenEnabled
        terminalEnabled = (try? values.decodeIfPresent(Bool.self, forKey: .terminalEnabled)) ?? terminalEnabled
        computerEnabled = (try? values.decodeIfPresent(Bool.self, forKey: .computerEnabled)) ?? computerEnabled
        speakReplies = (try? values.decodeIfPresent(Bool.self, forKey: .speakReplies)) ?? speakReplies
        webSearchEnabled = (try? values.decodeIfPresent(Bool.self, forKey: .webSearchEnabled)) ?? webSearchEnabled
        useSelectedText = (try? values.decodeIfPresent(Bool.self, forKey: .useSelectedText)) ?? useSelectedText
        model = (try? values.decodeIfPresent(String.self, forKey: .model)) ?? model
        workRoot = (try? values.decodeIfPresent(String.self, forKey: .workRoot)) ?? workRoot
        shortcuts = (try? values.decodeIfPresent([String: KeyboardShortcutBinding].self, forKey: .shortcuts)) ?? shortcuts
    }

    var enabledModes: Set<VoiceMode> {
        var result: Set<VoiceMode> = [.dictation]
        if polishEnabled { result.insert(.polish) }
        if askEnabled { result.insert(.ask) }
        if actEnabled { result.insert(.act) }
        if fullControlEnabled { result.insert(.fullControl) }
        return result
    }
    var bindings: [VoiceMode: KeyboardShortcutBinding] {
        Dictionary(uniqueKeysWithValues: VoiceMode.allCases.map { ($0, shortcuts[$0.rawValue] ?? KeyboardShortcutBinding.defaultBinding(for: $0)) })
    }
    func binding(for mode: VoiceMode) -> KeyboardShortcutBinding { bindings[mode]! }
}

@MainActor final class FeatureSettings: ObservableObject {
    @Published private(set) var options: FeatureOptions
    private let defaults: UserDefaults
    private var unsupportedSchema = false
    var onChange: (() -> Void)?
    // Keep the existing key so upgrading does not strand a user's choices.
    static let storageKey = "voiceFeatures.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode(FeatureOptions.self, from: data) else {
            options = FeatureOptions()
            return
        }
        guard decoded.schemaVersion <= FeatureOptions.currentSchemaVersion else {
            // An older binary must not rewrite settings from a newer schema.
            options = FeatureOptions()
            unsupportedSchema = true
            return
        }
        var restored = decoded
        if restored.schemaVersion < 2 {
            // User-requested voice upgrade: do this once, including when a
            // different assistant model had been selected in the old release.
            restored.model = FeatureOptions.defaultAssistantModel
            restored.speakReplies = true
            restored.webSearchEnabled = true
            restored.schemaVersion = 2
        }
        if restored.schemaVersion < 3 {
            // Replace the former default without changing an explicitly
            // selected Claude preset or any unrelated preference.
            if restored.model == "google/gemini-3.5-flash-lite" {
                restored.model = FeatureOptions.defaultAssistantModel
            }
            restored.schemaVersion = FeatureOptions.currentSchemaVersion
        }
        if (try? KeyboardShortcutBinding.validate(bindings: restored.bindings, enabledModes: restored.enabledModes)) == nil {
            restored.shortcuts = FeatureOptions().shortcuts
        }
        if !AgentModel.presets.contains(where: { $0.id == restored.model }) {
            restored.model = FeatureOptions.defaultAssistantModel
        }
        if !Self.isValidFolderPath(restored.workRoot) { restored.workRoot = FeatureOptions().workRoot }
        options = restored
        if restored != decoded, let encoded = try? JSONEncoder().encode(restored) {
            defaults.set(encoded, forKey: Self.storageKey)
        }
    }

    func update(_ change: (inout FeatureOptions) -> Void) throws {
        guard !unsupportedSchema else {
            throw DictationError(message: "These settings were saved by a newer app version. Update the app before changing them.")
        }
        var next = options
        change(&next)
        next.schemaVersion = FeatureOptions.currentSchemaVersion
        try KeyboardShortcutBinding.validate(bindings: next.bindings, enabledModes: next.enabledModes)
        guard Self.isValidFolderPath(next.workRoot) else { throw DictationError(message: "Choose a folder for terminal actions.") }
        guard AgentModel.presets.contains(where: { $0.id == next.model }) else { throw AgentClientError.unsupportedModel }
        guard next != options else { return }
        let encoded = try JSONEncoder().encode(next)
        options = next
        defaults.set(encoded, forKey: Self.storageKey)
        onChange?()
    }

    private static func isValidFolderPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\0")
    }
}
