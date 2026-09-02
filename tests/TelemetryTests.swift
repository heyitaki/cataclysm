// Harness for the heartbeat (Telemetry.swift): the install identity minted
// once, the 20-hour cadence gate, the attempt timestamp written before
// dispatch, and the request's URL, method, header, timeout and seven-field
// payload. The transport is a stub closure, so nothing here touches the
// network, and every store is a pid-scoped scratch UserDefaults(suiteName:).
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

var scratchSuites: [String] = []

func scratchSuiteName(_ name: String) -> String {
    "io.github.heyitaki.cataclysm.telemetry-tests."
        + "\(ProcessInfo.processInfo.processIdentifier).\(name)"
}

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

let hour: TimeInterval = 3_600

// A fixed instant in UTC, built through a calendar so the test never hand-
// computes epoch seconds.
func utc(_ year: Int, _ month: Int, _ day: Int, _ hourOfDay: Int, _ minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                              hour: hourOfDay, minute: minute))!
}

func matches(_ value: String, _ pattern: String) -> Bool {
    value.range(of: pattern, options: .regularExpression) != nil
}

let uuidPattern = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
let dottedPattern = "^[0-9]+(\\.[0-9]+){0,3}$"

func makeTelemetry(_ name: String, appVersion: String = "0.1.0") -> (Telemetry, Settings) {
    let settings = Settings(defaults: scratch(name))
    return (Telemetry(settings: settings, appVersion: appVersion), settings)
}

func decodedBody(_ request: URLRequest) -> [String: Any]? {
    guard let body = request.httpBody else { return nil }
    return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
}

func isBoolean(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
}

@main
struct TelemetryTests {
    static func main() {
        identityTests()
        eligibilityTests()
        tickTests()
        payloadTests()
        requestTests()
        dottedIntegerTests()
        cleanup()
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    static func identityTests() {
        let (t, s) = makeTelemetry("identity")
        // 00:30 UTC on the 3rd is still the 2nd in every US time zone, so an
        // implementation that used local time would print the wrong day.
        let now = utc(2026, 9, 3, 0, 30)

        let first = t.identity(now: now)
        check(matches(first.installID, uuidPattern), "identity: lowercase uuid",
              first.installID)
        check(first.installID != "00000000-0000-0000-0000-000000000000",
              "identity: never the reserved probe id")
        checkEq(first.created, "2026-09-03", "identity: created is the UTC day")

        let second = t.identity(now: now.addingTimeInterval(400 * hour))
        checkEq(second.installID, first.installID, "identity: id stable across reads")
        checkEq(second.created, first.created, "identity: created stable across reads")

        checkEq(s.telemetryInstallID, first.installID, "identity: id persisted")
        checkEq(s.telemetryInstallCreated, first.created, "identity: created persisted")

        // A second Telemetry over the same store is the next launch.
        let relaunch = Telemetry(settings: s, appVersion: "0.1.0")
        checkEq(relaunch.identity(now: now).installID, first.installID,
                "identity: survives relaunch")

        // Two stores mint two ids.
        let (other, _) = makeTelemetry("identity-other")
        check(other.identity(now: now).installID != first.installID,
              "identity: distinct per store")

        // A created date lost on its own is re-minted without touching the id,
        // so the install keeps counting as the same Mac.
        s.telemetryInstallCreated = nil
        let repaired = t.identity(now: utc(2026, 10, 1, 12))
        checkEq(repaired.installID, first.installID, "identity: id kept when created missing")
        checkEq(repaired.created, "2026-10-01", "identity: created re-minted")

        // The mirror case: an id lost with its created date kept mints a
        // fresh id under that date, so the new id joins the cohort the
        // install actually belongs to instead of today's.
        s.telemetryInstallID = nil
        let reminted = t.identity(now: utc(2026, 11, 5, 12))
        check(matches(reminted.installID, uuidPattern), "identity: fresh id is a uuid",
              reminted.installID)
        check(reminted.installID != first.installID, "identity: fresh id when id missing")
        checkEq(reminted.created, "2026-10-01", "identity: created kept when id missing")
        checkEq(s.telemetryInstallID, reminted.installID, "identity: fresh id persisted")
    }

    static func eligibilityTests() {
        let (t, s) = makeTelemetry("eligibility")
        let now = utc(2026, 9, 2, 12)

        check(t.isEligible(now: now), "eligible: no attempt yet")

        s.telemetryEnabled = false
        check(!t.isEligible(now: now), "eligible: never when disabled")
        s.telemetryEnabled = true

        s.telemetryLastAttempt = now.addingTimeInterval(-(19 * hour + 59 * 60)).timeIntervalSince1970
        check(!t.isEligible(now: now), "eligible: not at 19h59m")
        s.telemetryLastAttempt = now.addingTimeInterval(-20 * hour).timeIntervalSince1970
        check(t.isEligible(now: now), "eligible: exactly 20h")
        s.telemetryLastAttempt = now.addingTimeInterval(-3 * 24 * hour).timeIntervalSince1970
        check(t.isEligible(now: now), "eligible: days later")

        // A clock set backwards reads as a recent attempt, not an eligible
        // one: the heartbeat waits rather than doubling up.
        s.telemetryLastAttempt = now.addingTimeInterval(5 * hour).timeIntervalSince1970
        check(!t.isEligible(now: now), "eligible: future attempt waits")
        // A stamp a whole interval or more ahead came from a wrong clock and
        // must not silence the heartbeat until real time catches up.
        s.telemetryLastAttempt = now.addingTimeInterval(20 * hour).timeIntervalSince1970
        check(t.isEligible(now: now), "eligible: attempt a full interval ahead")
        s.telemetryLastAttempt = now.addingTimeInterval(400 * 24 * hour).timeIntervalSince1970
        check(t.isEligible(now: now), "eligible: attempt a year ahead")

        s.telemetryLastAttempt = nil
        check(t.isEligible(now: now), "eligible: cleared attempt")
    }

    static func tickTests() {
        let (t, s) = makeTelemetry("tick")
        let now = utc(2026, 9, 2, 12)
        var sent: [URLRequest] = []
        var storedAtDispatch: Double?

        // The stub records the attempt timestamp as the transport sees it, and
        // then does nothing, which is exactly what a failed send looks like
        // from this module's side.
        let dispatched = t.tick(now: now) { request in
            storedAtDispatch = s.telemetryLastAttempt
            sent.append(request)
        }
        check(dispatched, "tick: dispatches when eligible")
        checkEq(sent.count, 1, "tick: one request")
        checkEq(storedAtDispatch, now.timeIntervalSince1970,
                "tick: attempt written before the transport runs")

        // The failed send is dropped, not retried by the hourly recheck.
        let retried = t.tick(now: now.addingTimeInterval(hour)) { sent.append($0) }
        check(!retried, "tick: no retry an hour after a failure")
        checkEq(sent.count, 1, "tick: transport not invoked within 20h")
        checkEq(s.telemetryLastAttempt, now.timeIntervalSince1970,
                "tick: attempt untouched by an ineligible tick")

        let later = now.addingTimeInterval(20 * hour)
        check(t.tick(now: later) { sent.append($0) }, "tick: due again at 20h")
        checkEq(sent.count, 2, "tick: second request at 20h")
        checkEq(s.telemetryLastAttempt, later.timeIntervalSince1970,
                "tick: attempt advanced")

        // Off means nothing is written and nothing is sent.
        s.telemetryEnabled = false
        let muchLater = later.addingTimeInterval(48 * hour)
        check(!t.tick(now: muchLater) { sent.append($0) }, "tick: disabled sends nothing")
        checkEq(sent.count, 2, "tick: disabled leaves the transport alone")
        checkEq(s.telemetryLastAttempt, later.timeIntervalSince1970,
                "tick: disabled does not touch the attempt")
    }

    static func payloadTests() {
        let (t, s) = makeTelemetry("payload", appVersion: "1.2.3")
        s.enabled = false
        s.jailEnabled = true
        let now = utc(2026, 9, 2, 12)

        guard let body = decodedBody(t.request(now: now)) else {
            check(false, "payload: body is a JSON object")
            return
        }
        checkEq(body.keys.sorted(),
                ["arch", "created", "enabled", "install", "jailEnabled", "macos", "version"],
                "payload: exactly the seven Worker fields")

        let install = body["install"] as? String ?? ""
        check(matches(install, uuidPattern), "payload: install is the uuid", install)
        checkEq(install, t.identity(now: now).installID, "payload: install matches identity")
        checkEq(body["created"] as? String, "2026-09-02", "payload: created")
        checkEq(body["version"] as? String, "1.2.3", "payload: version")
        let macos = body["macos"] as? String ?? ""
        check(matches(macos, dottedPattern), "payload: macos dotted integers", macos)
        #if arch(arm64)
        checkEq(body["arch"] as? String, "arm64", "payload: arch matches the build")
        #else
        checkEq(body["arch"] as? String, "x86_64", "payload: arch matches the build")
        #endif
        check(isBoolean(body["enabled"]), "payload: enabled is a JSON boolean")
        check(isBoolean(body["jailEnabled"]), "payload: jailEnabled is a JSON boolean")
        checkEq(body["enabled"] as? Bool, false, "payload: enabled mirrors settings")
        checkEq(body["jailEnabled"] as? Bool, true, "payload: jailEnabled mirrors settings")

        // The Worker reads at most 1024 bytes.
        check((t.request(now: now).httpBody?.count ?? 0) < 1_024, "payload: under the Worker's cap")

        // The host macOS as reported is already Worker-shaped.
        check(matches(Telemetry.hostMacOSVersion, dottedPattern),
              "payload: host macOS dotted integers", Telemetry.hostMacOSVersion)

        // A tagged build keeps its numeric prefix rather than 400ing forever.
        let (tagged, _) = makeTelemetry("payload-tagged", appVersion: "1.2.3-beta")
        checkEq(decodedBody(tagged.request(now: now))?["version"] as? String, "1.2.3",
                "payload: version sanitized")
    }

    static func requestTests() {
        let (t, _) = makeTelemetry("request")
        let request = t.request(now: utc(2026, 9, 2, 12))
        checkEq(request.url?.absoluteString, "https://akshath.me/cataclysm/ping", "request: url")
        checkEq(request.httpMethod, "POST", "request: method")
        checkEq(request.value(forHTTPHeaderField: "Content-Type"), "application/json",
                "request: json content type")
        checkEq(request.timeoutInterval, 10, "request: 10s timeout")
        check(request.httpBody != nil, "request: has a body")
    }

    static func dottedIntegerTests() {
        checkEq(dottedInteger("0.1.0"), "0.1.0", "dotted: plain")
        checkEq(dottedInteger("26"), "26", "dotted: single component")
        checkEq(dottedInteger("1.2.3-beta"), "1.2.3", "dotted: suffix dropped")
        checkEq(dottedInteger("1.2.3.4.5"), "1.2.3.4", "dotted: capped at four")
        checkEq(dottedInteger("1..2"), "1", "dotted: stops at an empty component")
        checkEq(dottedInteger("beta"), "0", "dotted: no digits falls back")
        checkEq(dottedInteger(""), "0", "dotted: empty falls back")
    }
}
