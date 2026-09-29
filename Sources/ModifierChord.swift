import AppKit

// Push-to-talk: begin as soon as both modifiers are held, finish when either
// is released, and discard if another key makes this an ordinary shortcut.
struct ModifierChord {
    enum Signal: Equatable { case none, begin, end, cancel }
    private var active = false
    private var blocked = false

    mutating func flagsChanged(_ flags: NSEvent.ModifierFlags) -> Signal {
        let relevant = flags.intersection([.option, .command, .control, .shift, .function])
        if relevant.isEmpty {
            let signal: Signal = active ? .end : .none
            active = false
            blocked = false
            return signal
        }
        if !relevant.intersection([.control, .shift, .function]).isEmpty {
            let signal: Signal = active ? .cancel : .none
            active = false
            blocked = true
            return signal
        }
        if active, relevant != [.option, .command] {
            active = false
            blocked = true // A new hold requires fully releasing the previous one.
            return .end
        }
        if relevant == [.option, .command], !active, !blocked {
            active = true
            return .begin
        }
        return .none
    }

    mutating func keyDown(_ flags: NSEvent.ModifierFlags) -> Signal {
        let signal: Signal = active ? .cancel : .none
        if active || !flags.intersection([.option, .command]).isEmpty { blocked = true }
        active = false
        return signal
    }
}
