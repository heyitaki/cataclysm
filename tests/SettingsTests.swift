// Harness for the settings store (Settings.swift): defaults, every clamp
// bound, wrong-type fallback, and reset-to-defaults sparing recovery. keys.
// Every store points at a scratch UserDefaults(suiteName:), never .standard,
// so runs are hermetic.
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

let recoveryKey = "recovery.originalMouseAcceleration"

var scratchSuites: [String] = []

// Pid-scoped so two concurrent runs on one machine can never wipe each
// other's domains; checks that need the raw domain name derive it from here
// rather than restating the literal.
func scratchSuiteName(_ name: String) -> String {
    "io.github.heyitaki.cataclysm.settings-tests."
        + "\(ProcessInfo.processInfo.processIdentifier).\(name)"
}

// A fresh, empty defaults domain; wiped on creation in case a previous run
// died before cleanup, and again at exit.
func scratch(_ name: String) -> UserDefaults {
    let suite = scratchSuiteName(name)
    guard let d = UserDefaults(suiteName: suite) else {
        fatalError("could not create scratch suite \(suite)")
    }
    d.removePersistentDomain(forName: suite)
    scratchSuites.append(suite)
    return d
}

func cleanup() {
    for suite in scratchSuites {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}

@main
struct SettingsTests {
    static func main() {
        defaultsTests()
        clampTests()
        hotkeyTests()
        resetTests()
        cleanup()
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    static func defaultsTests() {
        let store = scratch("defaults")
        let s = Settings(defaults: store)
        checkEq(s.enabled, true, "default: master switch on")
        checkEq(s.jailEnabled, true, "default: jail enabled")
        checkEq(s.targetBundleID, "com.riotgames.LeagueofLegends.GameClient",
                "default: target bundle id")
        checkEq(s.targetDisplayName, "League of Legends", "default: target name")
        checkEq(s.cornerRadius, 18.0, "default: corner radius")
        checkEq(s.accelerationOff, true, "default: acceleration off")
        checkEq(s.invertVertical, true, "default: invert vertical")
        checkEq(s.invertHorizontal, false, "default: natural horizontal")
        checkEq(s.flattenNotches, true, "default: flatten on")
        checkEq(s.linesPerNotch, 1, "default: 1 line per notch")
        checkEq(s.mulThousandths, 1_000, "default: multiplier 1.0")
        checkEq(s.altTrackpadDetection, false, "default: alt detection off")
        checkEq(s.hotkeyKeyCode, 37, "default: hotkey key L")
        checkEq(s.hotkeyModifiers, 0x0100 | 0x0800, "default: hotkey cmd+alt")
        checkEq(s.launchAtLogin, true, "default: launch at login")
        check(s.lastRegisteredVersion == nil, "default: no registered version")

        check(Settings.Key.all.allSatisfy { !$0.hasPrefix("recovery.") },
              "no recovery. key is a preference")

        // Reads never write anything back into an untouched domain. A
        // missing domain is the expected state: the plist only comes into
        // existence on the first write.
        let residue = store.persistentDomain(forName: scratchSuiteName("defaults"))?
            .keys.map { $0 } ?? []
        check(residue.isEmpty, "defaults read leaves storage empty", "found \(residue)")
    }

    static func clampTests() {
        let store = scratch("clamps")
        let s = Settings(defaults: store)

        // Lines per notch: 1...1000, wrong type falls back to the default.
        store.set(0, forKey: Settings.Key.linesPerNotch)
        checkEq(s.linesPerNotch, 1, "lines: 0 clamps to lower bound")
        store.set(5_000, forKey: Settings.Key.linesPerNotch)
        checkEq(s.linesPerNotch, 1_000, "lines: 5000 clamps to upper bound")
        store.set("abc", forKey: Settings.Key.linesPerNotch)
        checkEq(s.linesPerNotch, 1, "lines: string falls back to default")
        store.set(3.5, forKey: Settings.Key.linesPerNotch)
        checkEq(s.linesPerNotch, 1, "lines: fractional falls back to default")

        // Multiplier thousandths: 1...100000.
        store.set(0, forKey: Settings.Key.mulThousandths)
        checkEq(s.mulThousandths, 1, "mul: 0 clamps to lower bound")
        store.set(-4, forKey: Settings.Key.mulThousandths)
        checkEq(s.mulThousandths, 1, "mul: negative clamps to lower bound")
        store.set(200_000, forKey: Settings.Key.mulThousandths)
        checkEq(s.mulThousandths, 100_000, "mul: 200000 clamps to upper bound")

        // Out-of-slider-range but in-bounds values are legal and are never
        // rewritten by a read.
        store.set(50_000, forKey: Settings.Key.mulThousandths)
        checkEq(s.mulThousandths, 50_000, "mul: 50x is legal beyond the slider")
        checkEq(store.object(forKey: Settings.Key.mulThousandths) as? Int, 50_000,
                "mul: read does not rewrite storage")

        // Corner radius: 0...200, non-finite falls back to the default.
        store.set(-5.0, forKey: Settings.Key.cornerRadius)
        checkEq(s.cornerRadius, 0.0, "radius: negative clamps to 0")
        store.set(500.0, forKey: Settings.Key.cornerRadius)
        checkEq(s.cornerRadius, 200.0, "radius: 500 clamps to upper bound")
        store.set(Double.nan, forKey: Settings.Key.cornerRadius)
        checkEq(s.cornerRadius, 18.0, "radius: NaN falls back to default")
        store.set(Double.infinity, forKey: Settings.Key.cornerRadius)
        checkEq(s.cornerRadius, 18.0, "radius: infinity falls back to default")
        store.set(25, forKey: Settings.Key.cornerRadius)
        checkEq(s.cornerRadius, 25.0, "radius: plist integer reads as points")

        // Wrong-type booleans and strings fall back rather than coerce.
        store.set("yes", forKey: Settings.Key.jailEnabled)
        checkEq(s.jailEnabled, true, "bool: string falls back to default")
        store.set("", forKey: Settings.Key.targetBundleID)
        checkEq(s.targetBundleID, "com.riotgames.LeagueofLegends.GameClient",
                "string: empty bundle id falls back to default")

        // NSNumber bridges booleans to Int (true is 1) and numbers to Bool,
        // so the boolean/number distinction has to be checked explicitly.
        // Keys are chosen so coercion and fallback differ: invertHorizontal
        // defaults false (coercing 1 would read true), cornerRadius defaults
        // 18 (coercing true would read 1.0).
        store.set(1, forKey: Settings.Key.invertHorizontal)
        checkEq(s.invertHorizontal, false, "bool: stored number falls back")
        store.set(true, forKey: Settings.Key.cornerRadius)
        checkEq(s.cornerRadius, 18.0, "double: stored boolean falls back")

        // Setters clamp before persisting.
        s.linesPerNotch = 0
        checkEq(store.object(forKey: Settings.Key.linesPerNotch) as? Int, 1,
                "lines: setter clamps into storage")
        s.cornerRadius = 999
        checkEq(store.object(forKey: Settings.Key.cornerRadius) as? Double, 200.0,
                "radius: setter clamps into storage")
        s.mulThousandths = 0
        checkEq(store.object(forKey: Settings.Key.mulThousandths) as? Int, 1,
                "mul: setter clamps into storage")

        // The per-axis snapshots pair each axis's inversion with the shared
        // flatten/lines/multiplier.
        s.invertVertical = true
        s.invertHorizontal = false
        s.flattenNotches = true
        s.linesPerNotch = 3
        s.mulThousandths = 600
        checkEq(s.verticalScrollConfig,
                ScrollAxisConfig(invert: true, flatten: true,
                                 linesPerNotch: 3, mulThousandths: 600),
                "vertical scroll config snapshot")
        checkEq(s.horizontalScrollConfig,
                ScrollAxisConfig(invert: false, flatten: true,
                                 linesPerNotch: 3, mulThousandths: 600),
                "horizontal scroll config snapshot")
    }

    // The stored chord validates as a pair: anything RegisterEventHotKey
    // could not take without trapping (negative, beyond UInt32), a chord the
    // recorder could never produce (unknown bits, no command-class modifier),
    // or a wrong type falls back to the default chord wholesale.
    static func hotkeyTests() {
        let store = scratch("hotkey")
        let s = Settings(defaults: store)

        store.set(40, forKey: Settings.Key.hotkeyKeyCode)
        store.set(0x0100, forKey: Settings.Key.hotkeyModifiers)
        checkEq(s.hotkeyKeyCode, 40, "hotkey: valid key code reads back")
        checkEq(s.hotkeyModifiers, 0x0100, "hotkey: valid modifiers read back")

        store.set(-1, forKey: Settings.Key.hotkeyKeyCode)
        checkEq(s.hotkeyKeyCode, 37, "hotkey: negative key code falls back")
        checkEq(s.hotkeyModifiers, 0x0100 | 0x0800,
                "hotkey: the pair falls back together")

        store.set(0x10000, forKey: Settings.Key.hotkeyKeyCode)
        checkEq(s.hotkeyKeyCode, 37, "hotkey: oversized key code falls back")

        store.set(40, forKey: Settings.Key.hotkeyKeyCode)
        store.set(-0x0100, forKey: Settings.Key.hotkeyModifiers)
        checkEq(s.hotkeyModifiers, 0x0100 | 0x0800,
                "hotkey: negative modifiers fall back")
        store.set(0x0200, forKey: Settings.Key.hotkeyModifiers)
        checkEq(s.hotkeyModifiers, 0x0100 | 0x0800,
                "hotkey: shift-only chord falls back")
        store.set(0x0100 | 0x40000, forKey: Settings.Key.hotkeyModifiers)
        checkEq(s.hotkeyModifiers, 0x0100 | 0x0800,
                "hotkey: unknown modifier bits fall back")

        // Wrong type goes through the shared int() fallback; true would
        // otherwise bridge to key code 1.
        store.set(0x0100, forKey: Settings.Key.hotkeyModifiers)
        store.set(true, forKey: Settings.Key.hotkeyKeyCode)
        checkEq(s.hotkeyKeyCode, 37, "hotkey: boolean key code falls back")
    }

    static func resetTests() {
        let store = scratch("reset")
        let s = Settings(defaults: store)
        s.jailEnabled = false
        s.linesPerNotch = 7
        s.targetBundleID = "com.example.game"
        s.lastRegisteredVersion = "0.9.0"
        store.set(196_608, forKey: recoveryKey)
        store.set("keep", forKey: "future.unknownKey")

        s.resetToDefaults()

        checkEq(s.jailEnabled, true, "reset: jail back to default")
        checkEq(s.enabled, true, "reset: master switch back on")
        checkEq(s.linesPerNotch, 1, "reset: lines back to default")
        checkEq(s.targetBundleID, "com.riotgames.LeagueofLegends.GameClient",
                "reset: target back to default")
        // Bookkeeping, not a preference: clearing it would force a watcher
        // re-register cycle (and its uncovered probe window) on next launch.
        check(s.lastRegisteredVersion != nil, "reset: spares registered version")
        check(store.object(forKey: Settings.Key.jailEnabled) == nil,
              "reset: removes keys rather than writing defaults")
        checkEq(store.object(forKey: recoveryKey) as? Int, 196_608,
                "reset: spares recovery original")
        checkEq(store.string(forKey: "future.unknownKey"), "keep",
                "reset: leaves unknown keys untouched")

        // The nil setter removes the key directly; resetToDefaults reaches
        // the same state through removeObject, bypassing the setter.
        s.lastRegisteredVersion = "1.0.0"
        s.lastRegisteredVersion = nil
        check(store.object(forKey: Settings.Key.lastRegisteredVersion) == nil,
              "version: nil setter removes the stored key")
    }
}
