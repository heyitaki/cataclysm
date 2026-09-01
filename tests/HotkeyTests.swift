// Harness for the pure hotkey chord math (Hotkey.swift): NSEvent-flag to
// Carbon-modifier conversion, chord validity, and the display label the
// Advanced row renders.
//
// Build and run: make test

import Foundation

var passed = 0
var failed = 0

func check(_ cond: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if cond { passed += 1 } else {
        failed += 1
        let text = detail()
        print("FAIL: \(name)\(text.isEmpty ? "" : ": " + text)")
    }
}

func checkEq<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    check(got == want, name, "got \(got), want \(want)")
}

// NSEvent.ModifierFlags raw bits, restated here so a drift in Hotkey.swift's
// private constants fails a test instead of silently agreeing with itself.
let nsShiftFlag: UInt = 1 << 17
let nsControlFlag: UInt = 1 << 18
let nsOptionFlag: UInt = 1 << 19
let nsCommandFlag: UInt = 1 << 20

@main
struct HotkeyTests {
    static func main() {
        conversionTests()
        validityTests()
        storedValidityTests()
        labelTests()
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    static func conversionTests() {
        checkEq(carbonModifiers(fromNSFlags: 0), 0, "convert: no flags")
        checkEq(carbonModifiers(fromNSFlags: nsCommandFlag),
                CarbonModifiers.cmd, "convert: command alone")
        checkEq(carbonModifiers(fromNSFlags: nsCommandFlag | nsOptionFlag),
                CarbonModifiers.cmd | CarbonModifiers.option,
                "convert: cmd+option is the shipped default's mask")
        checkEq(carbonModifiers(fromNSFlags: nsShiftFlag | nsControlFlag),
                CarbonModifiers.shift | CarbonModifiers.control,
                "convert: shift+control")
        // Device-dependent bits (left/right variants, caps lock, function)
        // must not leak into the Carbon mask.
        let deviceBits: UInt = 0xFFFF | (1 << 16) | (1 << 23)
        checkEq(carbonModifiers(fromNSFlags: deviceBits), 0,
                "convert: device-dependent bits ignored")
        // The shipped default in Settings is these exact Carbon values.
        checkEq(CarbonModifiers.cmd | CarbonModifiers.option, 0x0100 | 0x0800,
                "convert: masks match Settings.Default.hotkeyModifiers")
    }

    static func validityTests() {
        check(isValidHotkeyChord(modifiers: CarbonModifiers.cmd), "valid: cmd")
        check(isValidHotkeyChord(modifiers: CarbonModifiers.option), "valid: option")
        check(isValidHotkeyChord(modifiers: CarbonModifiers.control), "valid: control")
        check(isValidHotkeyChord(
            modifiers: CarbonModifiers.cmd | CarbonModifiers.shift),
            "valid: cmd+shift")
        // A bare key or a shift-only chord would swallow typing system-wide.
        check(!isValidHotkeyChord(modifiers: 0), "invalid: no modifiers")
        check(!isValidHotkeyChord(modifiers: CarbonModifiers.shift),
              "invalid: shift alone")
    }

    // Stored values reach RegisterEventHotKey through UInt32 conversions, so
    // anything unrepresentable (or a chord the recorder could never produce)
    // must be rejected before Settings hands it over.
    static func storedValidityTests() {
        check(isValidStoredHotkey(keyCode: 37,
                                  modifiers: CarbonModifiers.cmd
                                      | CarbonModifiers.option),
              "stored: the shipped default chord is valid")
        check(isValidStoredHotkey(keyCode: 0, modifiers: CarbonModifiers.cmd),
              "stored: key code 0 (A) is valid")
        check(isValidStoredHotkey(keyCode: 0xFFFF, modifiers: CarbonModifiers.cmd),
              "stored: the top hardware key code is valid")
        check(!isValidStoredHotkey(keyCode: -1, modifiers: CarbonModifiers.cmd),
              "stored: negative key code is invalid")
        check(!isValidStoredHotkey(keyCode: 0x10000, modifiers: CarbonModifiers.cmd),
              "stored: key code beyond hardware range is invalid")
        check(!isValidStoredHotkey(keyCode: 37, modifiers: -CarbonModifiers.cmd),
              "stored: negative modifiers are invalid")
        check(!isValidStoredHotkey(keyCode: 37, modifiers: 0),
              "stored: bare key is invalid")
        check(!isValidStoredHotkey(keyCode: 37, modifiers: CarbonModifiers.shift),
              "stored: shift-only chord is invalid")
        check(!isValidStoredHotkey(keyCode: 37,
                                   modifiers: CarbonModifiers.cmd | 0x40000),
              "stored: unknown modifier bits are invalid")
    }

    static func labelTests() {
        // The shipped default chord: kVK_ANSI_L with cmd+option.
        checkEq(hotkeyChordLabel(keyCode: 37, modifiers: 0x0100 | 0x0800),
                "⌥⌘L", "label: default chord")
        // Standard macOS symbol order: control, option, shift, command.
        checkEq(hotkeyChordLabel(
                    keyCode: 0,
                    modifiers: CarbonModifiers.cmd | CarbonModifiers.shift
                        | CarbonModifiers.option | CarbonModifiers.control),
                "⌃⌥⇧⌘A", "label: all modifiers in display order")
        checkEq(hotkeyChordLabel(keyCode: 49, modifiers: CarbonModifiers.control),
                "⌃Space", "label: named non-letter key")
        checkEq(hotkeyKeyName(122), "F1", "label: function key")
        checkEq(hotkeyKeyName(126), "↑", "label: arrow key")
        checkEq(hotkeyKeyName(200), "key 200", "label: unknown code fallback")
        checkEq(escapeKeyCode, 53, "label: escape keycode constant")
    }
}
