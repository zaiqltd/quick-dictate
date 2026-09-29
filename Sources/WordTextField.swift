import AppKit
import SwiftUI

// Keep word editing in AppKit's field editor. The SwiftUI wrapper only mirrors
// complete values; it never inserts characters or forwards keyboard events.
struct WordTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var initialFocus = false
    var onSubmit: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.placeholderString = placeholder
        field.stringValue = text
        field.font = .systemFont(ofSize: 13)
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.focusOnAttach = initialFocus
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel(placeholder)
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        if field.stringValue != text { field.stringValue = text }
    }
    final class Field: NSTextField {
        var focusOnAttach = false
        private var didRequestFocus = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard focusOnAttach, !didRequestFocus, window != nil else { return }
            didRequestFocus = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: WordTextField
        init(_ parent: WordTextField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard command == #selector(NSResponder.insertNewline(_:)) else { return false }
            if let submit = parent.onSubmit { submit() }
            else { control.window?.selectNextKeyView(control) }
            return true
        }
    }
}
