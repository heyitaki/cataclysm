// Pure hotkey chord math behind the Advanced hotkey row: Carbon modifier
// masks, the NSEvent-flag conversion, chord validity, and the display label.
// Foundation-only so the test harness links it without AppKit or Carbon; the
// masks are the Carbon constants by value (cmdKey, shiftKey, optionKey,
// controlKey), which is also why Settings.Default stores raw ints.

import Foundation

enum CarbonModifiers {
    static let cmd = 0x0100
    static let shift = 0x0200
    static let option = 0x0800
    static let control = 0x1000
}

// NSEvent.ModifierFlags device-independent raw bits, by value for the same
// AppKit-free reason.
private let nsShift: UInt = 1 << 17
private let nsControl: UInt = 1 << 18
private let nsOption: UInt = 1 << 19
private let nsCommand: UInt = 1 << 20

let escapeKeyCode = 53

func carbonModifiers(fromNSFlags raw: UInt) -> Int {
    var mods = 0
    if raw & nsCommand != 0 { mods |= CarbonModifiers.cmd }
    if raw & nsShift != 0 { mods |= CarbonModifiers.shift }
    if raw & nsOption != 0 { mods |= CarbonModifiers.option }
    if raw & nsControl != 0 { mods |= CarbonModifiers.control }
    return mods
}

// A chord needs at least one command-class modifier; a bare key or a
// shift-only chord registered globally would swallow ordinary typing
// system-wide. The recorder keeps listening past an invalid press.
func isValidHotkeyChord(modifiers: Int) -> Bool {
    modifiers & (CarbonModifiers.cmd | CarbonModifiers.option | CarbonModifiers.control) != 0
}

// Stored chord values come from UserDefaults, which a hand-edited plist can
// make negative or huge — and RegisterEventHotKey takes both through UInt32
// conversions, so an unvalidated read would crash on every launch until a
// manual `defaults delete`. A stored pair is usable only when the key code
// is a hardware key code and the modifiers are a chord the recorder could
// have produced (the four Carbon bits, with a command-class one set).
func isValidStoredHotkey(keyCode: Int, modifiers: Int) -> Bool {
    let knownBits = CarbonModifiers.cmd | CarbonModifiers.shift
        | CarbonModifiers.option | CarbonModifiers.control
    return (0...0xFFFF).contains(keyCode)
        && modifiers & ~knownBits == 0
        && isValidHotkeyChord(modifiers: modifiers)
}

// Modifier symbols in the standard macOS display order: control, option,
// shift, command.
func hotkeyChordLabel(keyCode: Int, modifiers: Int) -> String {
    var out = ""
    if modifiers & CarbonModifiers.control != 0 { out += "⌃" }
    if modifiers & CarbonModifiers.option != 0 { out += "⌥" }
    if modifiers & CarbonModifiers.shift != 0 { out += "⇧" }
    if modifiers & CarbonModifiers.cmd != 0 { out += "⌘" }
    return out + hotkeyKeyName(keyCode)
}

// kVK_ANSI_* layout-independent hardware codes to display names. A static
// table rather than UCKeyTranslate: deterministic, layout-stable, and free of
// Carbon input-source calls. Unknown codes still render something usable.
func hotkeyKeyName(_ keyCode: Int) -> String {
    let names: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 50: "`",
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
        114: "Help", 115: "Home", 116: "Page Up", 117: "Fwd Delete",
        119: "End", 121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
    return names[keyCode] ?? "key \(keyCode)"
}
