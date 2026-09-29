import Foundation
import Combine
import Darwin

struct RememberedWord: Codable, Equatable, Identifiable {
    let id: UUID
    var heard: String
    var preferred: String
    var updatedAt: Date
}

final class PersonalDictionary: ObservableObject {
    static let maximumWords = 100
    static let maximumCharacters = 80
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Quick Dictate/dictionary.json")
    }
    private struct Document: Codable { let version: Int; let words: [RememberedWord] }
    @Published private(set) var words: [RememberedWord] = []
    @Published private(set) var canUndo = false
    private(set) var loadError: String?
    private let url: URL
    private var undoSnapshot: [RememberedWord]?
    var hints: [String] { (try? Self.validatedHints(words.map(\.preferred))) ?? [] }

    init(url: URL = PersonalDictionary.defaultURL) {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size <= 1_000_000 else { throw DictationError(message: "Dictionary file is too large.") }
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
            guard document.version == 1, document.words.count <= Self.maximumWords,
                  Set(document.words.map(\.id)).count == document.words.count else {
                throw DictationError(message: "Unrecognized dictionary format.")
            }
            _ = try Self.validatedHints(document.words.map(\.preferred))
            for word in document.words where !word.heard.isEmpty { _ = try Self.validatedPhrase(word.heard) }
            words = document.words
        } catch {
            // Do not overwrite a file we could not read, and do not prevent normal dictation.
            loadError = "Couldn't read your saved words. The original dictionary file has been left untouched."
        }
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").precomposedStringWithCanonicalMapping
    }
    private static func key(_ text: String) -> String { normalized(text).lowercased() }
    static func validatedPhrase(_ text: String) throws -> String {
        let value = normalized(text)
        guard !value.isEmpty else { throw DictationError(message: "Enter the word or name you want remembered.") }
        guard value.count <= maximumCharacters, value.split(separator: " ").count <= 8 else {
            throw DictationError(message: "Save a word, name or short phrase (up to 8 words / 80 characters).")
        }
        guard value.rangeOfCharacter(from: .alphanumerics) != nil,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DictationError(message: "Enter a word or name, rather than punctuation alone.")
        }
        return value
    }
    static func validatedHints(_ phrases: [String]) throws -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for phrase in phrases {
            let value = try validatedPhrase(phrase)
            if seen.insert(key(value)).inserted { result.append(value) }
        }
        guard result.count <= maximumWords else { throw DictationError(message: "Your dictionary can remember up to 100 words or names.") }
        return result
    }

    func remember(heard: String = "", preferred: String) throws {
        let preferred = try Self.validatedPhrase(preferred)
        let heard = Self.normalized(heard).isEmpty ? "" : try Self.validatedPhrase(heard)
        if !heard.isEmpty, heard == preferred { throw DictationError(message: "Those spellings already match. Enter the corrected spelling.") }
        var updated = words
        let match = updated.firstIndex { !heard.isEmpty && Self.key($0.heard) == Self.key(heard) }
            ?? updated.firstIndex { Self.key($0.preferred) == Self.key(preferred) }
        let id = match.map { updated[$0].id } ?? UUID()
        updated.removeAll { (!heard.isEmpty && Self.key($0.heard) == Self.key(heard)) || Self.key($0.preferred) == Self.key(preferred) }
        guard updated.count < Self.maximumWords else { throw DictationError(message: "Your dictionary is full. Forget a word before adding another.") }
        updated.insert(RememberedWord(id: id, heard: heard, preferred: preferred, updatedAt: Date()), at: 0)
        try commit(updated)
    }
    func forget(_ id: UUID) throws {
        guard words.contains(where: { $0.id == id }) else { return }
        try commit(words.filter { $0.id != id })
    }
    func undo() throws {
        guard let previous = undoSnapshot else { return }
        try persist(previous)
        words = previous
        undoSnapshot = nil
        canUndo = false
    }
    private func commit(_ updated: [RememberedWord]) throws {
        try persist(updated)
        undoSnapshot = words
        words = updated
        canUndo = true
    }
    private func persist(_ updated: [RememberedWord]) throws {
        if let loadError { throw DictationError(message: loadError) }
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let temporary = directory.appendingPathComponent(".dictionary-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: temporary) }
            let data = try encoder.encode(Document(version: 1, words: updated))
            guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]),
                  rename(temporary.path, url.path) == 0 else {
                throw DictationError(message: "Couldn't write the dictionary file.")
            }
        } catch { throw DictationError(message: "Couldn't save your words on this Mac. Your existing dictionary has not been changed in the app.") }
    }
}

enum CorrectionEditing {
    static func replacing(_ heard: String, with preferred: String, in text: String) throws -> String {
        let heard = try PersonalDictionary.validatedPhrase(heard)
        let preferred = try PersonalDictionary.validatedPhrase(preferred)
        let phrase = heard.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
        let regex = try NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_])" + phrase + "(?![\\p{L}\\p{N}_])", options: .caseInsensitive)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard regex.firstMatch(in: text, range: range) != nil else {
            throw DictationError(message: "That word wasn't found in this dictation. Select the mistake or enter it exactly as shown.")
        }
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: preferred))
    }
}
