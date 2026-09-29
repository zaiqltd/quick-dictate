import AppKit
import SwiftUI

struct SelectableTranscript: NSViewRepresentable {
    let text: String
    var onSelection: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.font = .systemFont(ofSize: 13)
        view.textColor = .labelColor
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.setAccessibilityLabel("Last dictation")
        view.delegate = context.coordinator
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onSelection = onSelection
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        context.coordinator.updating = true
        view.string = text
        context.coordinator.updating = false
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSelection: (String) -> Void
        var updating = false
        init(onSelection: @escaping (String) -> Void) { self.onSelection = onSelection }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            let range = view.selectedRange()
            let value = view.string as NSString
            guard range.location != NSNotFound, NSMaxRange(range) <= value.length else { return }
            onSelection(range.length > 0 ? value.substring(with: range) : "")
        }
    }
}

struct DictionarySettingsRow: View {
    @ObservedObject var app: DictationApp
    @ObservedObject var dictionary: PersonalDictionary
    var body: some View {
        Button(action: app.showDictionary) {
            HStack {
                Label("Remembered words", systemImage: "character.book.closed")
                Spacer()
                Text("\(dictionary.words.count)").foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
            }.font(.system(size: 12))
        }.buttonStyle(.plain).disabled(app.phase != .idle)
    }
}

struct RememberCorrectionView: View {
    @ObservedObject var app: DictationApp
    @State private var heard: String
    @State private var preferred: String
    @State private var message = ""
    private let hasSelection: Bool

    init(app: DictationApp, seed: String) {
        self.app = app
        hasSelection = !seed.isEmpty
        _heard = State(initialValue: seed)
        _preferred = State(initialValue: seed)
    }
    private var canSave: Bool {
        !PersonalDictionary.normalized(heard).isEmpty && !PersonalDictionary.normalized(preferred).isEmpty
            && PersonalDictionary.normalized(heard) != PersonalDictionary.normalized(preferred)
            && app.dictionary.loadError == nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Correct & remember").font(.system(size: 18, weight: .semibold))
            Text("Fix a word here. I'll use your spelling as a hint next time.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("It heard").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                WordTextField(placeholder: "Word it got wrong", text: $heard, initialFocus: !hasSelection).frame(height: 24)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Use this spelling").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                WordTextField(placeholder: "Correct word or name", text: $preferred, initialFocus: hasSelection, onSubmit: save).frame(height: 24)
            }
            if !message.isEmpty { Text(message).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            Text("Updates this dictation and copies the corrected text. Saved spellings are sent with future audio to help recognition.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { app.dictionarySheet = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Remember", action: save).keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }.padding(22).frame(width: 400)
            .onAppear {
                message = app.dictionary.loadError ?? ""
            }
    }
    private func save() {
        guard canSave else { return }
        do { try app.rememberCorrection(heard: heard, preferred: preferred) }
        catch { message = error.localizedDescription }
    }
}

struct RememberedWordsView: View {
    @ObservedObject var dictionary: PersonalDictionary
    var close: () -> Void
    @State private var newWord = ""
    @State private var message = ""
    @State private var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Remembered words").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }
            Text("Your preferred spellings, sent as hints with each dictation. You decide what stays.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                WordTextField(placeholder: "Add a name or special word", text: $newWord, initialFocus: true, onSubmit: add).frame(height: 24)
                Button("Add", action: add).disabled(PersonalDictionary.normalized(newWord).isEmpty || dictionary.loadError != nil)
            }
            if let loadError = dictionary.loadError {
                Text(loadError).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if dictionary.words.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "character.book.closed").font(.system(size: 24)).foregroundStyle(.tertiary)
                    Text("No words remembered yet").font(.system(size: 12, weight: .medium))
                    Text("Select a mistake in your last dictation, then choose Correct & remember.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(dictionary.words) { word in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(word.preferred).font(.system(size: 13, weight: .medium)).textSelection(.enabled)
                                    if !word.heard.isEmpty { Text("Heard: \(word.heard)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                Spacer()
                                Button("Forget") { change { try dictionary.forget(word.id) }; if !isError { message = "Word forgotten. You can undo this." } }
                                    .buttonStyle(.link).font(.system(size: 11)).help("Forget \(word.preferred)")
                            }.padding(.vertical, 10)
                            Divider()
                        }
                    }
                }.frame(maxHeight: .infinity)
            }
            HStack {
                Text(message.isEmpty ? "\(dictionary.words.count) / 100 words · saved on this Mac" : message)
                    .font(.system(size: 10)).foregroundStyle(isError ? Color.orange : .secondary).lineLimit(2)
                Spacer()
                Button("Undo") { change { try dictionary.undo() }; if !isError { message = "Dictionary change undone." } }
                    .controlSize(.small).disabled(!dictionary.canUndo)
            }.frame(minHeight: 24)
        }.padding(22).frame(width: 400, height: 400)
    }
    private func change(_ action: () throws -> Void) {
        do { try action(); isError = false }
        catch { message = error.localizedDescription; isError = true }
    }
    private func add() {
        guard !PersonalDictionary.normalized(newWord).isEmpty else { return }
        change { try dictionary.remember(preferred: newWord) }
        if !isError { newWord = ""; message = "Spelling remembered." }
    }
}
