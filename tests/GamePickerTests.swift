// Harness for the game picker row builder (GamePicker.swift): stored-target
// synthesis when absent, dedupe by bundle id, case-insensitive sort, the
// missing-bundle-id and self exclusions, duplicate-name labeling, and the
// target-quit transition keeping the selection's bundle id.
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

let storedID = "com.riotgames.LeagueofLegends.GameClient"
let storedName = "League of Legends"
let selfID = "io.github.heyitaki.cataclysm"

func build(_ running: [GamePickerCandidate]) -> [GamePickerRow] {
    buildGamePickerRows(storedBundleID: storedID, storedName: storedName,
                        running: running, ownBundleID: selfID)
}

@main
struct GamePickerTests {
    static func main() {
        storedRowTests()
        filterTests()
        orderingTests()
        labelTests()
        quitTransitionTests()
        pinnedTests()
        noTargetTests()
        knownAppTests()
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    static func storedRowTests() {
        // No running apps at all: the synthesized stored row is the list.
        let alone = build([])
        checkEq(alone.count, 1, "stored: synthesized row is the whole empty list")
        checkEq(alone[0], GamePickerRow(bundleID: storedID, name: storedName,
                                        label: storedName, isRunning: false),
                "stored: synthesized from persisted id and name")

        // Stored target running: its row comes from the running app, still
        // first, and does not repeat in the running section.
        let rows = build([
            GamePickerCandidate(bundleID: "com.apple.finder", name: "Finder"),
            GamePickerCandidate(bundleID: storedID, name: "League Of Legends"),
        ])
        checkEq(rows.count, 2, "stored: running target not duplicated")
        checkEq(rows[0].bundleID, storedID, "stored: target stays first while running")
        checkEq(rows[0].name, "League Of Legends", "stored: running name wins over persisted")
        check(rows[0].isRunning, "stored: running target marked running")
    }

    static func filterTests() {
        let rows = build([
            GamePickerCandidate(bundleID: nil, name: "No Bundle"),
            GamePickerCandidate(bundleID: "", name: "Empty Bundle"),
            GamePickerCandidate(bundleID: selfID, name: "Cataclysm"),
            GamePickerCandidate(bundleID: "com.apple.finder", name: "Finder"),
            GamePickerCandidate(bundleID: "com.apple.finder", name: "Finder Again"),
            GamePickerCandidate(bundleID: "com.example.nameless", name: nil),
        ])
        // The nameless app's display name is its bundle id, which sorts
        // before "Finder" case-insensitively.
        checkEq(rows.map(\.bundleID),
                [storedID, "com.example.nameless", "com.apple.finder"],
                "filter: no-id and self excluded, dedupe keeps first")
        checkEq(rows[2].name, "Finder", "filter: dedupe keeps the first occurrence's name")
        // A nameless app shows its bundle id rather than vanishing.
        checkEq(rows[1].name, "com.example.nameless", "filter: nil name falls back to bundle id")
    }

    static func orderingTests() {
        let rows = build([
            GamePickerCandidate(bundleID: "com.example.zulu", name: "zulu"),
            GamePickerCandidate(bundleID: "com.example.alpha", name: "Alpha"),
            GamePickerCandidate(bundleID: "com.example.bravo", name: "bravo"),
        ])
        checkEq(rows.map(\.name), [storedName, "Alpha", "bravo", "zulu"],
                "order: stored first, then case-insensitive by name")
    }

    static func labelTests() {
        let rows = build([
            GamePickerCandidate(bundleID: "com.example.one", name: "Twin"),
            GamePickerCandidate(bundleID: "com.example.two", name: "twin"),
            GamePickerCandidate(bundleID: "com.example.solo", name: "Solo"),
        ])
        checkEq(rows.first { $0.bundleID == "com.example.one" }?.label,
                "Twin (com.example.one)", "label: first twin carries its id")
        checkEq(rows.first { $0.bundleID == "com.example.two" }?.label,
                "twin (com.example.two)", "label: second twin carries its id")
        checkEq(rows.first { $0.bundleID == "com.example.solo" }?.label,
                "Solo", "label: unique name stays bare")

        // The stored row participates in collision detection too.
        let collide = build([
            GamePickerCandidate(bundleID: "com.example.fake", name: storedName),
        ])
        checkEq(collide[0].label, "\(storedName) (\(storedID))",
                "label: stored row disambiguates against a running twin")
        checkEq(collide[1].label, "\(storedName) (com.example.fake)",
                "label: running twin of the stored row disambiguates")
    }

    static func quitTransitionTests() {
        // The target quitting is just a rebuild without it: the first row
        // keeps the same bundle id (so the selection is unchanged) and drops
        // to the synthesized form.
        let before = build([GamePickerCandidate(bundleID: storedID, name: storedName)])
        let after = build([])
        check(before[0].isRunning, "quit: target was running before")
        check(!after[0].isRunning, "quit: synthesized after the target quits")
    }

    static func pinnedTests() {
        let pinnedID = "com.example.pinned"
        let pinned = [GamePickerCandidate(bundleID: pinnedID, name: "Pinned")]

        // Closed pinned app: synthesized, right after the stored row, ahead of
        // the running section.
        let closed = buildGamePickerRows(
            storedBundleID: storedID, storedName: storedName, pinned: pinned,
            running: [GamePickerCandidate(bundleID: "com.apple.finder", name: "Finder")],
            ownBundleID: selfID)
        checkEq(closed.map(\.bundleID), [storedID, pinnedID, "com.apple.finder"],
                "pinned: stored, then pinned, then running")
        check(!closed[1].isRunning, "pinned: closed pinned app synthesized")

        // Running pinned app: takes the running row, no repeat below.
        let open = buildGamePickerRows(
            storedBundleID: storedID, storedName: storedName, pinned: pinned,
            running: [GamePickerCandidate(bundleID: pinnedID, name: "Pinned Live")],
            ownBundleID: selfID)
        checkEq(open.count, 2, "pinned: running pinned app not duplicated")
        checkEq(open[1].name, "Pinned Live", "pinned: running name wins")
        check(open[1].isRunning, "pinned: running pinned app marked running")

        // Stored target is the pinned app: one row, stored position.
        let same = buildGamePickerRows(
            storedBundleID: pinnedID, storedName: "Pinned", pinned: pinned,
            running: [], ownBundleID: selfID)
        checkEq(same.count, 1, "pinned: stored pinned app listed once")

        // Cataclysm itself cannot be pinned any more than it can be picked.
        let own = buildGamePickerRows(
            storedBundleID: storedID, storedName: storedName,
            pinned: [GamePickerCandidate(bundleID: selfID, name: "Cataclysm")],
            running: [], ownBundleID: selfID)
        checkEq(own.count, 1, "pinned: own bundle excluded")
    }

    static func noTargetTests() {
        // No stored target: nothing synthesized, pinned and running rows only.
        let rows = buildGamePickerRows(
            storedBundleID: nil, storedName: "",
            pinned: [GamePickerCandidate(bundleID: "com.example.pinned", name: "Pinned")],
            running: [GamePickerCandidate(bundleID: "com.apple.finder", name: "Finder")],
            ownBundleID: selfID)
        checkEq(rows.map(\.bundleID), ["com.example.pinned", "com.apple.finder"],
                "none: no synthesized stored row")
    }

    static func knownAppTests() {
        checkEq(knownAppName(for: "com.riotgames.LeagueofLegends.GameClient"),
                "League of Legends", "known: in-game client keeps the plain name")
        checkEq(knownAppName(for: "com.riotgames.LeagueofLegends.LeagueClientUx"),
                "League of Legends Launcher", "known: launcher named apart")
        checkEq(knownAppName(for: "com.apple.finder"), nil, "known: unknown app unnamed")
        checkEq(pinnedApps.map { $0.bundleID },
                ["com.riotgames.LeagueofLegends.GameClient"],
                "known: only the in-game client is pinned")
    }
}
