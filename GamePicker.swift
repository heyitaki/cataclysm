// Game picker row building (spec "Game picker"): the stored target first,
// then the pinned apps, then every running .regular app deduped by bundle id
// and sorted case-insensitively by name. The jail matches frontmost by bundle
// id, so an app without one is left out, and Cataclysm excludes itself
// because selecting it would jail the cursor to the panel.
//
// The stored target and the pinned apps must appear even when not running
// (League's game client only exists during a match), so their rows are
// synthesized from a bundle id and display name when absent. An uninstalled
// app looks identical to a closed one from outside, so the synthesized row
// simply stays selectable and nothing reports an error. A nil stored id
// means no target is chosen, so nothing is synthesized for it.
//
// Foundation-only so the test harness links it without AppKit: the caller
// filters to .regular and supplies plain candidates, and icons are looked up
// by bundle id at render time.

import Foundation

// One running application as the picker sees it. bundleIdentifier and
// localizedName are both optional on NSRunningApplication.
struct GamePickerCandidate {
    let bundleID: String?
    let name: String?
}

struct GamePickerRow: Equatable {
    let bundleID: String
    let name: String
    // What the row displays: the name, with the bundle id appended when two
    // visible rows would otherwise carry the same name. Rows are tagged by
    // bundle id, never by name, so identity survives the collision either way.
    var label: String
    let isRunning: Bool
}

// Apps the picker knows by bundle id. Riot's launcher, client, and in-game
// client all call themselves "League of Legends" and share an icon, so the
// name says which one it is; the in-game client keeps the plain name because
// it is the one the jail exists for. It is also pinned: it only runs during
// a match, so it has to be selectable while closed.
struct KnownApp {
    let bundleID: String
    let name: String
    let pinned: Bool
}

let knownApps = [
    KnownApp(bundleID: "com.riotgames.LeagueofLegends.GameClient",
             name: "League of Legends", pinned: true),
    KnownApp(bundleID: "com.riotgames.LeagueofLegends.LeagueClientUx",
             name: "League of Legends Launcher", pinned: false),
    // The /Applications wrapper runs the launcher's backend process under
    // its own bundle id; LeagueClient is that same backend launched directly.
    KnownApp(bundleID: "com.riotgames.leagueoflegends",
             name: "League of Legends Launcher (backend)", pinned: false),
    KnownApp(bundleID: "com.riotgames.LeagueofLegends.LeagueClient",
             name: "League of Legends Launcher (backend)", pinned: false),
]

func knownAppName(for bundleID: String) -> String? {
    knownApps.first { $0.bundleID == bundleID }?.name
}

var pinnedApps: [GamePickerCandidate] {
    knownApps.filter(\.pinned).map { GamePickerCandidate(bundleID: $0.bundleID, name: $0.name) }
}

func buildGamePickerRows(storedBundleID: String?, storedName: String,
                         pinned: [GamePickerCandidate] = [],
                         running: [GamePickerCandidate],
                         ownBundleID: String) -> [GamePickerRow] {
    var runningByID: [String: GamePickerRow] = [:]
    for app in running {
        guard let id = app.bundleID, !id.isEmpty, id != ownBundleID,
              runningByID[id] == nil else { continue }
        // A running app with no visible name still has to be pickable; the
        // bundle id is the only stable text left to show.
        let name = app.name.flatMap { $0.isEmpty ? nil : $0 } ?? id
        runningByID[id] = GamePickerRow(bundleID: id, name: name, label: name, isRunning: true)
    }

    // Head rows keep their place whether or not the app is running; a
    // running one takes its row from the snapshot so it does not repeat below.
    var head: [GamePickerRow] = []
    var headIDs = Set<String>()
    func pin(_ id: String, _ name: String) {
        guard headIDs.insert(id).inserted else { return }
        head.append(runningByID.removeValue(forKey: id)
            ?? GamePickerRow(bundleID: id, name: name, label: name, isRunning: false))
    }
    // Same guards as the loops below: the settings accessors keep these
    // unreachable today, but the function's own contract should not rely on
    // that (an empty id would collide with the chooser row's tag).
    if let storedBundleID, !storedBundleID.isEmpty, storedBundleID != ownBundleID {
        pin(storedBundleID, storedName.isEmpty ? storedBundleID : storedName)
    }
    for app in pinned {
        guard let id = app.bundleID, !id.isEmpty, id != ownBundleID else { continue }
        pin(id, app.name.flatMap { $0.isEmpty ? nil : $0 } ?? id)
    }

    // Bundle id breaks name ties so a rebuild never reorders same-named rows.
    let rest = runningByID.values.sorted {
        switch $0.name.caseInsensitiveCompare($1.name) {
        case .orderedSame: return $0.bundleID < $1.bundleID
        case let order: return order == .orderedAscending
        }
    }

    var rows = head + rest
    var nameCounts: [String: Int] = [:]
    for row in rows { nameCounts[row.name.lowercased(), default: 0] += 1 }
    for i in rows.indices where nameCounts[rows[i].name.lowercased()]! > 1 {
        rows[i].label = "\(rows[i].name) (\(rows[i].bundleID))"
    }
    return rows
}
