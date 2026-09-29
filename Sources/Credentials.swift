import Foundation
import Security

enum Credentials {
    static let service = "local.chad.quick-dictate.openrouter"
    static let account = "api-key"
    static func parseEnv(_ contents: String) -> String? {
        for rawLine in contents.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equal = line.firstIndex(of: "="), line[..<equal].trimmingCharacters(in: .whitespaces) == "OPENROUTER_API_KEY" else { continue }
            var value = String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
            if let first = value.first, first == "\"" || first == "'" {
                value.removeFirst()
                if let end = value.firstIndex(of: first) { value = String(value[..<end]) }
                else { return nil }
            } else { value = String(value.split(whereSeparator: { $0.isWhitespace || $0 == "#" }).first ?? "") }
            return value.hasPrefix("sk-or-") ? value : nil
        }
        return nil
    }
    static func load() -> String? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty { return key }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".credentials/openrouter.env")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseEnv(contents)
    }
    static func save(_ key: String) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("sk-or-"), !value.contains(where: { $0.isWhitespace }) else {
            throw DictationError(message: "Paste a valid OpenRouter API key starting with sk-or-.")
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var create = query.merging(attributes, uniquingKeysWith: { _, new in new })
            create[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(create as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw DictationError(message: "Couldn't save the key to your Mac's Keychain.") }
    }
}
