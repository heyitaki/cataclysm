// Settings: the UserDefaults-backed store behind every panel control.
// Validation happens on every read, not only in the UI, per the spec's
// persistence rules: out-of-bounds numbers are clamped (multiplier 0.001-100
// stored as thousandths, lines per notch 1-1000, corner radius 0-200), a
// value of the wrong type or non-finite falls back to its default, and keys
// this version does not know are left untouched so a downgrade keeps a newer
// version's settings. Reads never rewrite storage: a stored multiplier
// outside the slider's 0.25x-4.0x range is legal and stays exactly as
// stored, with only the slider parked at the nearer end.
//
// recovery.-prefixed keys are recovery metadata, not preferences. They are
// deliberately absent from Key.all, so resetToDefaults() can never erase the
// only record of the user's real acceleration value while the live property
// is held at -1.

import Foundation

final class Settings {
    enum Key {
        static let enabled = "app.enabled"
        static let jailEnabled = "jail.enabled"
        static let targetBundleID = "jail.targetBundleID"
        static let targetDisplayName = "jail.targetDisplayName"
        static let cornerRadius = "jail.cornerRadius"
        static let accelerationOff = "accel.disabled"
        static let invertVertical = "scroll.invertVertical"
        static let invertHorizontal = "scroll.invertHorizontal"
        static let flattenNotches = "scroll.flatten"
        static let linesPerNotch = "scroll.linesPerNotch"
        static let mulThousandths = "scroll.mulThousandths"
        static let altTrackpadDetection = "scroll.altTrackpadDetection"
        static let hotkeyKeyCode = "hotkey.keyCode"
        static let hotkeyModifiers = "hotkey.modifiers"
        static let launchAtLogin = "app.launchAtLogin"
        static let lastRegisteredVersion = "app.lastRegisteredVersion"

        // Everything resetToDefaults() erases. recovery.-prefixed keys and
        // lastRegisteredVersion are bookkeeping, not preferences: erasing
        // the version would force a needless watcher re-register cycle with
        // its 10s uncovered probe window on the next launch.
        static let all = [
            enabled, jailEnabled, targetBundleID, targetDisplayName, cornerRadius,
            accelerationOff, invertVertical, invertHorizontal, flattenNotches,
            linesPerNotch, mulThousandths, altTrackpadDetection,
            hotkeyKeyCode, hotkeyModifiers, launchAtLogin,
        ]
    }

    // Stored as the target bundle id when no application is chosen. Bundle
    // ids allow only alphanumerics, hyphens, and periods, so this can never
    // collide with a real one, and it is non-empty so the store keeps it
    // instead of falling back to the default target.
    static let noTarget = "(none)"

    enum Default {
        static let targetBundleID = "com.riotgames.LeagueofLegends.GameClient"
        static let targetDisplayName = "League of Legends"
        // Measured off the League client window; 0 disables corner clamping.
        static let cornerRadius = 18.0
        static let linesPerNotch = 1
        static let mulThousandths = 1_000
        // cmd+alt+L, the chord the retired Hammerspoon helper shipped. Raw
        // Carbon values
        // (kVK_ANSI_L, cmdKey | optionKey) so this file needs no Carbon
        // import; the hotkey code that consumes them does.
        static let hotkeyKeyCode = 37
        static let hotkeyModifiers = 0x0100 | 0x0800
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Typed reads with default fallback

    // object(forKey:) plus a conditional cast, never the coercing bool/
    // integer(forKey:) accessors: a hand-edited plist with a string where a
    // number belongs must fall back to the default, not coerce to 0. NSNumber
    // bridges CFBoolean to Int (true becomes 1) and any number to Bool, so
    // the boolean/number distinction is checked explicitly too.
    private func bool(_ key: String, or fallback: Bool) -> Bool {
        guard let number = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return fallback }
        return number.boolValue
    }

    private func int(_ key: String, or fallback: Int) -> Int {
        guard let number = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = number as? Int else { return fallback }
        return value
    }

    private func finiteDouble(_ key: String, or fallback: Double) -> Double {
        guard let number = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = number as? Double, value.isFinite else { return fallback }
        return value
    }

    private func nonEmptyString(_ key: String, or fallback: String) -> String {
        guard let value = defaults.string(forKey: key), !value.isEmpty else {
            return fallback
        }
        return value
    }

    // MARK: - Preferences

    // The master switch: off stops every feature (jail, scroll filter,
    // acceleration) while the app keeps running and keeps its settings.
    var enabled: Bool {
        get { bool(Key.enabled, or: true) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    var jailEnabled: Bool {
        get { bool(Key.jailEnabled, or: true) }
        set { defaults.set(newValue, forKey: Key.jailEnabled) }
    }

    var targetBundleID: String {
        get { nonEmptyString(Key.targetBundleID, or: Default.targetBundleID) }
        set { defaults.set(newValue, forKey: Key.targetBundleID) }
    }

    var targetDisplayName: String {
        get { nonEmptyString(Key.targetDisplayName, or: Default.targetDisplayName) }
        set { defaults.set(newValue, forKey: Key.targetDisplayName) }
    }

    var cornerRadius: Double {
        get { clampedCornerRadius(finiteDouble(Key.cornerRadius, or: Default.cornerRadius)) }
        set { defaults.set(clampedCornerRadius(newValue), forKey: Key.cornerRadius) }
    }

    var accelerationOff: Bool {
        get { bool(Key.accelerationOff, or: true) }
        set { defaults.set(newValue, forKey: Key.accelerationOff) }
    }

    var invertVertical: Bool {
        get { bool(Key.invertVertical, or: true) }
        set { defaults.set(newValue, forKey: Key.invertVertical) }
    }

    var invertHorizontal: Bool {
        get { bool(Key.invertHorizontal, or: false) }
        set { defaults.set(newValue, forKey: Key.invertHorizontal) }
    }

    var flattenNotches: Bool {
        get { bool(Key.flattenNotches, or: true) }
        set { defaults.set(newValue, forKey: Key.flattenNotches) }
    }

    var linesPerNotch: Int {
        get { clampedLinesPerNotch(int(Key.linesPerNotch, or: Default.linesPerNotch)) }
        set { defaults.set(clampedLinesPerNotch(newValue), forKey: Key.linesPerNotch) }
    }

    var mulThousandths: Int {
        get { clampedMulThousandths(int(Key.mulThousandths, or: Default.mulThousandths)) }
        set { defaults.set(clampedMulThousandths(newValue), forKey: Key.mulThousandths) }
    }

    var altTrackpadDetection: Bool {
        get { bool(Key.altTrackpadDetection, or: false) }
        set { defaults.set(newValue, forKey: Key.altTrackpadDetection) }
    }

    // The chord validates as a pair (Hotkey.swift's isValidStoredHotkey): a
    // value RegisterEventHotKey could not take without trapping, or a chord
    // the recorder could never produce, falls back to the default chord
    // wholesale so key code and modifiers always describe the same chord.
    private var storedHotkey: (keyCode: Int, modifiers: Int) {
        let keyCode = int(Key.hotkeyKeyCode, or: Default.hotkeyKeyCode)
        let modifiers = int(Key.hotkeyModifiers, or: Default.hotkeyModifiers)
        guard isValidStoredHotkey(keyCode: keyCode, modifiers: modifiers) else {
            return (Default.hotkeyKeyCode, Default.hotkeyModifiers)
        }
        return (keyCode, modifiers)
    }

    var hotkeyKeyCode: Int {
        get { storedHotkey.keyCode }
        set { defaults.set(newValue, forKey: Key.hotkeyKeyCode) }
    }

    var hotkeyModifiers: Int {
        get { storedHotkey.modifiers }
        set { defaults.set(newValue, forKey: Key.hotkeyModifiers) }
    }

    // The sketch in the spec's dropdown section ships this checked: the app
    // fixes acceleration and scroll with defaults, which only holds across
    // reboots if it comes back at login. The stored flag is the preference;
    // SMAppService.mainApp registration is the consumer's job.
    var launchAtLogin: Bool {
        get { bool(Key.launchAtLogin, or: true) }
        set { defaults.set(newValue, forKey: Key.launchAtLogin) }
    }

    // nil until the first successful watcher registration records a version;
    // a mismatch with the running build triggers unregister-then-re-register.
    var lastRegisteredVersion: String? {
        get { defaults.string(forKey: Key.lastRegisteredVersion) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.lastRegisteredVersion)
            } else {
                defaults.removeObject(forKey: Key.lastRegisteredVersion)
            }
        }
    }

    // Per-axis snapshots for the scroll tap; flatten, lines, and multiplier
    // are shared across axes, inversion is per axis (the flatten pairing rule
    // applyAxisDeltas depends on).
    var verticalScrollConfig: ScrollAxisConfig {
        ScrollAxisConfig(invert: invertVertical, flatten: flattenNotches,
                         linesPerNotch: linesPerNotch, mulThousandths: mulThousandths)
    }

    var horizontalScrollConfig: ScrollAxisConfig {
        ScrollAxisConfig(invert: invertHorizontal, flatten: flattenNotches,
                         linesPerNotch: linesPerNotch, mulThousandths: mulThousandths)
    }

    // MARK: - Reset

    // "Reset to defaults" per the spec: erase the settings a person chose,
    // never anything recovery.-prefixed, and leave unknown keys (a newer
    // version's settings) alone. Reapplying the live defaults immediately
    // (writing -1 to the acceleration property again, not restoring) is the
    // caller's job; this store only owns persistence.
    func resetToDefaults() {
        for key in Key.all {
            defaults.removeObject(forKey: key)
        }
    }
}

func clampedCornerRadius(_ raw: Double) -> Double {
    min(max(raw, 0), 200)
}
