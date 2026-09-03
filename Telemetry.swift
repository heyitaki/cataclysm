// Telemetry: the daily heartbeat, gated by the telemetry.enabled default
// (Settings.swift). This module owns the install identity, the cadence and
// the request; the transport that sends it is injected, so the harness
// never touches the network and the app supplies the URLSession one
// (CataclysmApp.swift).
//
// Cadence: eligible when the default is on and the last *attempt* is absent
// or at least 20 hours old. The attempt timestamp is written before the
// transport runs, so a failed send is dropped rather than retried by the
// hourly recheck; the next heartbeat waits the full interval either way.
// The payload is exactly the seven fields the Worker validates: anything
// missing, extra or malformed is a 400 and no row, so the version strings
// are trimmed to the dotted-integer shape it accepts.

import Foundation

final class Telemetry {
    static let endpoint = URL(string: "https://akshath.me/cataclysm/ping")!
    static let minimumInterval: TimeInterval = 20 * 60 * 60
    // How often the app re-checks eligibility after the launch-time tick.
    static let tickInterval: TimeInterval = 60 * 60
    static let requestTimeout: TimeInterval = 10

    #if arch(arm64)
    static let arch = "arm64"
    #else
    static let arch = "x86_64"
    #endif

    // The running macOS in the Worker's shape.
    static var hostMacOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private let settings: Settings
    private let version: String
    private let macOSVersion: String

    init(settings: Settings, appVersion: String) {
        self.settings = settings
        self.version = dottedInteger(appVersion)
        self.macOSVersion = dottedInteger(Telemetry.hostMacOSVersion)
    }

    // MARK: - Identity

    // Minted once and kept for the life of the install. The created date
    // rides along on every heartbeat so cohort retention survives Analytics
    // Engine's 90-day window: without it an install whose first ping aged
    // out is indistinguishable from a new one. Both are bookkeeping, spared
    // by resetToDefaults(). Each value missing on its own is re-minted
    // without touching the other: a lost created date keeps the id, so the
    // Mac still counts as one install; a lost id keeps the date, so the new
    // id lands in the cohort the install actually belongs to.
    func identity(now: Date) -> (installID: String, created: String) {
        let installID = settings.telemetryInstallID ?? UUID().uuidString.lowercased()
        let created = settings.telemetryInstallCreated ?? Telemetry.dayString(now)
        settings.telemetryInstallID = installID
        settings.telemetryInstallCreated = created
        return (installID, created)
    }

    // MARK: - Cadence

    // An attempt slightly in the future (clock set backwards) reads as recent,
    // so the heartbeat waits instead of doubling up. One further ahead than a
    // whole interval was stamped by a wrong clock; waiting it out could mean
    // months of silence, so it is treated as stale instead.
    func isEligible(now: Date) -> Bool {
        guard settings.telemetryEnabled else { return false }
        guard let last = settings.telemetryLastAttempt else { return true }
        let elapsed = now.timeIntervalSince1970 - last
        return elapsed >= Telemetry.minimumInterval || elapsed <= -Telemetry.minimumInterval
    }

    // MARK: - Request

    func payload(now: Date) -> [String: Any] {
        let identity = identity(now: now)
        return [
            "install": identity.installID,
            "created": identity.created,
            "version": version,
            "macos": macOSVersion,
            "arch": Telemetry.arch,
            "enabled": settings.enabled,
            "jailEnabled": settings.jailEnabled,
        ]
    }

    func request(now: Date) -> URLRequest {
        var request = URLRequest(url: Telemetry.endpoint,
                                 timeoutInterval: Telemetry.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Every value is a String or a Bool, so serialization cannot throw.
        request.httpBody = try! JSONSerialization.data(withJSONObject: payload(now: now),
                                                       options: [.sortedKeys])
        return request
    }

    // One heartbeat if due. Returns whether the transport was invoked.
    @discardableResult
    func tick(now: Date = Date(), transport: (URLRequest) -> Void) -> Bool {
        guard isEligible(now: now) else { return false }
        settings.telemetryLastAttempt = now.timeIntervalSince1970
        transport(request(now: now))
        return true
    }

    // YYYY-MM-DD in UTC, the zone Analytics Engine stamps pings in, so the
    // cohort week stats.sh derives from it lines up with the ping weeks.
    static func dayString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}

// The Worker accepts one to four dot-separated integers and nothing else. A
// build tagged "1.2.3-beta" keeps its numeric prefix and a string with no
// leading digits becomes "0", so an odd version costs the suffix, not every
// heartbeat that install would ever send.
func dottedInteger(_ raw: String) -> String {
    var parts: [String] = []
    for part in raw.split(separator: ".", omittingEmptySubsequences: false) {
        let digits = part.prefix { $0.isASCII && $0.isNumber }
        if digits.isEmpty { break }
        parts.append(String(digits))
        if digits.count != part.count || parts.count == 4 { break }
    }
    return parts.isEmpty ? "0" : parts.joined(separator: ".")
}
