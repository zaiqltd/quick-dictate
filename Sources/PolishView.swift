import SwiftUI

private let polishAccent = Color(red: 0.30, green: 0.80, blue: 0.65)

/// One input and one result, kept in the app controller's memory only.
struct PolishView: View {
    @ObservedObject var app: DictationApp
    @State private var showsOriginal = false
    @State private var copiedResult = false
    @State private var copiedOriginal = false

    private var isIdle: Bool { app.phase == .idle }
    private var canPolish: Bool { isIdle && !app.polishDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Say it your way. Send it clearly.")
                    .font(.system(size: 15, weight: .semibold))
                Text("Cuts filler and repetition. Keeps your meaning and tone.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("ROUGH TEXT").font(.system(size: 9, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary)
                ZStack(alignment: .topLeading) {
                    if app.polishDraft.isEmpty {
                        Text("Paste or type a rough message…")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 5).padding(.top, 7)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $app.polishDraft)
                        .font(.system(size: 12)).scrollContentBackground(.hidden)
                        .disabled(!isIdle)
                        .accessibilityLabel("Rough message")
                }
                .padding(5).frame(height: 88)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
            }

            HStack(spacing: 10) {
                Text("Or hold the shortcut and speak.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(action: app.polishTypedText) {
                    Label("Polish text", systemImage: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent).tint(polishAccent).disabled(!canPolish)
                .accessibilityLabel("Polish text")
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("POLISHED MESSAGE").font(.system(size: 9, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary)
                    Spacer()
                    if !app.polishedText.isEmpty {
                        Button {
                            app.copyPolishedText()
                            copiedResult = true
                        } label: {
                            Label(copiedResult ? "Copied" : "Copy", systemImage: copiedResult ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(!isIdle)
                        .accessibilityLabel(copiedResult ? "Polished message copied" : "Copy polished message")
                    }
                }
                ScrollView {
                    Text(app.polishedText.isEmpty ? "Your clearer message will appear here." : app.polishedText)
                        .font(.system(size: 12)).lineSpacing(3)
                        .foregroundStyle(app.polishedText.isEmpty ? Color.secondary : Color.primary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if isIdle && !app.polishOriginal.isEmpty && app.polishedText.isEmpty {
                    Button("Try again", action: app.retryPolish)
                        .controlSize(.small).accessibilityLabel("Retry polishing original message")
                }
            }
            .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(polishAccent.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(polishAccent.opacity(0.15), lineWidth: 1))

            if !app.polishOriginal.isEmpty {
                Button { showsOriginal = true } label: {
                    Label("Original message", systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Show original message")
                .popover(isPresented: $showsOriginal, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Original message").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Button { showsOriginal = false } label: {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                            }.buttonStyle(.plain).accessibilityLabel("Close original message")
                        }
                        ScrollView {
                            Text(app.polishOriginal).font(.system(size: 12)).lineSpacing(3)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 180)
                        Button {
                            app.restorePolishOriginal()
                            copiedOriginal = true
                        } label: {
                            Label(copiedOriginal ? "Original copied" : "Copy original", systemImage: copiedOriginal ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!isIdle)
                            .accessibilityLabel(copiedOriginal ? "Original message copied" : "Copy original")
                    }.padding(16).frame(width: 360)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: app.polishedText) { _, _ in copiedResult = false }
        .onChange(of: app.polishOriginal) { _, _ in copiedOriginal = false; showsOriginal = false }
    }
}
