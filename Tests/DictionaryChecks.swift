import Foundation

extension CoreTests {
    static func dictionaryChecks(client: TranscriptionClient, audio: Data) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quick-dictate-dictionary-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("words/dictionary.json")
        let store = PersonalDictionary(url: file)
        check(store.words.isEmpty && store.loadError == nil, "Fresh dictionary is empty")
        check(!FileManager.default.fileExists(atPath: file.path), "No file before explicit remembering")
        try store.remember(heard: "QLume", preferred: "CueLoom")
        check(store.words.count == 1 && store.hints == ["CueLoom"], "Only preferred spelling becomes a hint")
        let id = store.words[0].id
        let reloaded = PersonalDictionary(url: file)
        check(reloaded.words == store.words, "Words survive restart")
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber).intValue
        check(mode == 0o600, "Dictionary file is private")
        let parentMode = (try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as! NSNumber).intValue
        check(parentMode == 0o700, "Dictionary folder is private")
        try store.remember(heard: "qlume", preferred: "CueLoom")
        check(store.words.count == 1 && store.words[0].id == id, "Remembering twice updates the same word")
        try store.remember(heard: "QLume", preferred: "CueLoomPro")
        check(store.hints == ["CueLoomPro"], "Changing a correction removes the outdated hint")
        try store.undo()
        check(store.hints == ["CueLoom"] && !store.canUndo, "Undo restores prior spelling")
        try store.forget(id)
        check(store.hints.isEmpty && PersonalDictionary(url: file).words.isEmpty, "Forget is persisted")
        try store.undo()
        check(store.hints == ["CueLoom"] && PersonalDictionary(url: file).hints == ["CueLoom"], "Forget can be undone and restored on disk")
        try store.remember(preferred: "  Cape   Town  ")
        check(store.hints == ["Cape Town", "CueLoom"], "Whitespace is normalized")
        let hints = try PersonalDictionary.validatedHints(["CueLoom", "cueloom", " Cape   Town "])
        check(hints == ["CueLoom", "Cape Town"], "Request hints are deduplicated")
        let previous = try Data(contentsOf: file)
        await expectError("Enter the word") { try store.remember(preferred: " \n ") }
        await expectError("80 characters") { try store.remember(preferred: String(repeating: "a", count: 81)) }
        await expectError("8 words") { try store.remember(preferred: "one two three four five six seven eight nine") }
        await expectError("punctuation") { try store.remember(preferred: "!!!") }
        await expectError("already match") { try store.remember(heard: "Same", preferred: "Same") }
        let after = try Data(contentsOf: file)
        check(after == previous, "Invalid corrections leave disk untouched")

        try store.remember(heard: "Brand One", preferred: "BrandOne")
        try store.remember(heard: "Brand Two", preferred: "BrandTwo")
        try store.remember(heard: "Brand One", preferred: "BrandTwo")
        check(store.words.filter { $0.preferred == "BrandTwo" }.count == 1 && !store.hints.contains("BrandOne"), "Updating merges a conflicting preferred spelling")

        let corrupt = directory.appendingPathComponent("corrupt.json")
        let badData = Data("{broken dictionary".utf8)
        try badData.write(to: corrupt)
        let broken = PersonalDictionary(url: corrupt)
        check(broken.loadError != nil && broken.hints.isEmpty, "Corrupt file is reported without breaking transcription")
        await expectError("left untouched") { try broken.remember(preferred: "Test") }
        let stillBad = try Data(contentsOf: corrupt)
        check(stillBad == badData, "Corrupt dictionary is not overwritten")

        let blockedPath = directory.appendingPathComponent("not-a-directory")
        try Data("keep".utf8).write(to: blockedPath)
        let blocked = PersonalDictionary(url: blockedPath.appendingPathComponent("dictionary.json"))
        await expectError("Couldn't save") { try blocked.remember(preferred: "Unsaved") }
        check(blocked.words.isEmpty && !blocked.canUndo, "Failed writes cannot claim to remember a word")

        let fullFile = directory.appendingPathComponent("full/dictionary.json")
        try FileManager.default.createDirectory(at: fullFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let words: [[String: Any]] = (0..<100).map { ["id": UUID().uuidString, "heard": "", "preferred": "Word\($0)", "updatedAt": 0] }
        try JSONSerialization.data(withJSONObject: ["version": 1, "words": words]).write(to: fullFile)
        let full = PersonalDictionary(url: fullFile)
        check(full.words.count == 100 && full.loadError == nil, "100-word dictionary loads")
        await expectError("full") { try full.remember(preferred: "OneMore") }
        try full.remember(preferred: "WORD1")
        check(full.words.count == 100 && full.hints.contains("WORD1"), "Updating a word remains possible at capacity")
        await expectError("100 words") { _ = try PersonalDictionary.validatedHints((0..<101).map { "Word\($0)" }) }

        func correction(_ heard: String, _ preferred: String, _ input: String, _ expected: String) throws {
            let result = try CorrectionEditing.replacing(heard, with: preferred, in: input)
            check(result == expected, "Explicit latest-text correction: \(heard)")
        }
        try correction("QLume", "CueLoom", "QLume, then qlume. Not QLumely.", "CueLoom, then CueLoom. Not QLumely.")
        try correction("Jose", "José", "Call Jose, not Josef.", "Call José, not Josef.")
        try correction("C++", "CPP", "Use C++.", "Use CPP.")
        try correction("Queue Loom", "CueLoom", "Open Queue\nLoom now.", "Open CueLoom now.")
        try correction("brand", "Brand$1", "Use brand.", "Use Brand$1.")
        try correction("openrouter", "OpenRouter", "openrouter works", "OpenRouter works")
        await expectError("wasn't found") { _ = try CorrectionEditing.replacing("cat", with: "dog", in: "catalogue") }
        await expectError("Enter the word") { _ = try CorrectionEditing.replacing("", with: "Name", in: "text") }

        MockProtocol.handler = { request in
            var body = request.httpBody
            if body == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096); var data = Data()
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
                body = data
            }
            let json = try JSONSerialization.jsonObject(with: body!) as! [String: Any]
            let provider = json["provider"] as! [String: Any]
            let options = provider["options"] as! [String: Any]
            let azure = options["azure"] as! [String: Any]
            let list = azure["phraseList"] as! [String: [String]]
            check(list["phrases"] == ["CueLoom", "Cape Town"], "Exact live-verified Azure phrase-list shape")
            check(json["model"] as? String == TranscriptionClient.model, "Dictionary retains MAI-Transcribe-2")
            check(azure.count == 1 && json["prompt"] == nil, "No ignored prompt or unrelated provider settings")
            return (200, Data("{\"text\":\"QLume\"}".utf8))
        }
        let hinted = try await client.transcribe(audio: audio, format: "wav", key: "test", vocabulary: ["CueLoom", "Cape Town"])
        check(hinted.text == "QLume", "Future transcripts are hints, never blind text replacement")
    }
}
