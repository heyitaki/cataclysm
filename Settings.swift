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

        // Everything resetToDefaults() erases. recovery.-prefixed keys are
        // not preferences and must never appear here.
        static let all = [
            jailEnabled, targetBundleID, targetDisplayName, cornerRadius,
            accelerationOff, invertVertical, invertHorizontal, flattenNotches,
            linesPerNotch, mulThousandths, altTrackpadDetection,
            hotkeyKeyCode, hotkeyModifiers, launchAtLogin, lastRegisteredVersion,
        ]
    }

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

    // The unbundled CLI's UserDefaults domain, keyed by process name.
    static let legacyDomainName = "mousejail"
    // Must match PointerAccel.storeKey, which owns reads and writes of the
    // live value; Settings only migrates it across the domain switch.
    private static let recoveryOriginalKey = "recovery.originalMouseAcceleration"
    // recovery.-prefixed on purpose: "Reset to defaults" spares it, so a
    // reset can never re-trigger a stale re-import from the old domain.
    private static let migrationMarkerKey = "recovery.migratedFromLegacyDomain"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard,
         legacy: UserDefaults? = UserDefaults(suiteName: Settings.legacyDomainName)) {
        self.defaults = defaults
        migrateLegacyRecovery(from: legacy)
    }

    // MARK: - Typed reads with default fallback

    // object(forKey:) plus a conditional cast, never the coercing bool/
    // integer(forKey:) accessors: a hand-edited plist with a string where a
    // number belongs must fall back to the default, not coerce to 0.
    private func bool(_ key: String, or fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    private func int(_ key: String, or fallback: Int) -> Int {
        defaults.object(forKey: key) as? Int ?? fallback
    }

    private func finiteDouble(_ key: String, or fallback: Double) -> Double {
        guard let value = defaults.object(forKey: key) as? Double,
              value.isFinite else { return fallback }
        return value
    }

    private func nonEmptyString(_ key: String, or fallback: String) -> String {
        guard let value = defaults.string(forKey: key), !value.isEmpty else {
            return fallback
        }
        return value
    }

    // MARK: - Preferences

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

    var hotkeyKeyCode: Int {
        get { int(Key.hotkeyKeyCode, or: Default.hotkeyKeyCode) }
        set { defaults.set(newValue, forKey: Key.hotkeyKeyCode) }
    }

    var hotkeyModifiers: Int {
        get { int(Key.hotkeyModifiers, or: Default.hotkeyModifiers) }
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

    // MARK: - Migration

    // One-time read: the unbundled CLI persisted the original acceleration
    // under its process-name domain (legacyDomainName), and the bundled
    // app's .standard is a different domain. The first bundled run copies
    // the value over so crash recovery still knows the real acceleration.
    // The validity rule mirrors PointerAccel's: an Int32-representable value
    // that is not -1; junk and the one destructive value never migrate.
    private func migrateLegacyRecovery(from legacy: UserDefaults?) {
        guard !defaults.bool(forKey: Self.migrationMarkerKey) else { return }
        defer { defaults.set(true, forKey: Self.migrationMarkerKey) }
        guard defaults.object(forKey: Self.recoveryOriginalKey) == nil,
              let stored = legacy?.object(forKey: Self.recoveryOriginalKey) as? Int,
              let value = Int32(exactly: stored), value != -1 else { return }
        defaults.set(stored, forKey: Self.recoveryOriginalKey)
    }
}

func clampedCornerRadius(_ raw: Double) -> Double {
    min(max(raw, 0), 200)
}
