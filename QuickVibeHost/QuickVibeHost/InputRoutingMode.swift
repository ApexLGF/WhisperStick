import Foundation
import CoreGraphics

enum InputSource: String, Sendable {
    case bleButtonA
    case bleButtonB
    case hotkey
    case test
}

/// Control-key events routed alongside ASR text. Both carry a PTY byte
/// payload (for exclusive mode) and a keyboard fallback (for free mode /
/// PTY failure). Double-ESC matches Claude CLI's "cancel current input"
/// expectation — one ESC only clears a partial UI state.
enum ControlKey: Sendable {
    case enter
    case escapeOnce
    case escapeDouble
    case upArrow
    case downArrow
    case leftArrow
    case rightArrow
    case home
    case end
    case backspace
    case shiftTab

    var payload: Data {
        switch self {
        case .enter:        Data([0x0D])                    // \r
        case .escapeOnce:   Data([0x1B])                    // ESC
        case .escapeDouble: Data([0x1B, 0x1B])              // ESC ESC
        case .upArrow:      Data([0x1B, 0x5B, 0x41])        // ESC [ A
        case .downArrow:    Data([0x1B, 0x5B, 0x42])        // ESC [ B
        case .leftArrow:    Data([0x1B, 0x5B, 0x44])        // ESC [ D
        case .rightArrow:   Data([0x1B, 0x5B, 0x43])        // ESC [ C
        case .home:         Data([0x1B, 0x5B, 0x48])        // ESC [ H (xterm)
        case .end:          Data([0x1B, 0x5B, 0x46])        // ESC [ F (xterm)
        case .backspace:    Data([0x7F])                    // DEL
        case .shiftTab:     Data([0x1B, 0x5B, 0x5A])        // ESC [ Z (CSI back-tab)
        }
    }

    var logName: String {
        switch self {
        case .enter:        "enter"
        case .escapeOnce:   "esc×1"
        case .escapeDouble: "esc×2"
        case .upArrow:      "up"
        case .downArrow:    "down"
        case .leftArrow:    "left"
        case .rightArrow:   "right"
        case .home:         "home"
        case .end:          "end"
        case .backspace:    "backspace"
        case .shiftTab:     "shift+tab"
        }
    }

    func simulateKeyboard() {
        switch self {
        case .enter:
            KeyboardSimulator.pressEnter()
        case .escapeOnce:
            KeyboardSimulator.pressEscape()
        case .escapeDouble:
            KeyboardSimulator.pressEscape()
            KeyboardSimulator.pressEscape()
        case .upArrow:
            KeyboardSimulator.pressUpArrow()
        case .downArrow:
            KeyboardSimulator.pressDownArrow()
        case .leftArrow:
            KeyboardSimulator.pressKeyCombo(0x7B, modifiers: [])
        case .rightArrow:
            KeyboardSimulator.pressKeyCombo(0x7C, modifiers: [])
        case .home:
            KeyboardSimulator.pressKeyCombo(0x73, modifiers: [])
        case .end:
            KeyboardSimulator.pressKeyCombo(0x77, modifiers: [])
        case .backspace:
            KeyboardSimulator.pressKeyCombo(0x33, modifiers: [])
        case .shiftTab:
            KeyboardSimulator.pressKeyCombo(0x30, modifiers: .maskShift)
        }
    }
}

enum InputRoutingMode: Equatable, Sendable {
    case free
    case exclusive(sessionId: String)

    var isExclusive: Bool {
        if case .exclusive = self { return true }
        return false
    }

    var debugDescription: String {
        switch self {
        case .free: "free"
        case .exclusive(let sid): "exclusive(\(sid.prefix(8)))"
        }
    }
}
