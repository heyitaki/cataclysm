// Game picker row building (spec "Game picker"): the stored target first,
// then every running .regular app deduped by bundle id and sorted
// case-insensitively by name. The jail matches frontmost by bundle id, so an
// app without one is left out, and Cataclysm excludes itself because
// selecting it would jail the cursor to the panel.
//
// The stored target must appear even when it is not running (League's game
// client only exists during a match), so its row is synthesized from the
// persisted bundle id and display name when absent. An uninstalled target
// looks identical to a closed one from outside, so the synthesized row simply
// stays selected and nothing reports an error.
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

func buildGamePickerRows(storedBundleID: String, storedName: String,
                         running: [GamePickerCandidate],
                         ownBundleID: String) -> [GamePickerRow] {
    var storedRow = GamePickerRow(bundleID: storedBundleID, name: storedName,
                                  label: storedName, isRunning: false)
    var seen = Set<String>()
    var runningRows: [GamePickerRow] = []
    for app in running {
        guard let id = app.bundleID, !id.isEmpty, id != ownBundleID,
              seen.insert(id).inserted else { continue }
        // A running app with no visible name still has to be pickable; the
        // bundle id is the only stable text left to show.
        let name = app.name.flatMap { $0.isEmpty ? nil : $0 } ?? id
        let row = GamePickerRow(bundleID: id, name: name, label: name, isRunning: true)
        if id == storedBundleID {
            storedRow = row
        } else {
            runningRows.append(row)
        }
    }
    runningRows.sort {
        $0.name.caseInsensitiveCompare($1.name) == .orderedAscending
    }

    var rows = [storedRow] + runningRows
    var nameCounts: [String: Int] = [:]
    for row in rows { nameCounts[row.name.lowercased(), default: 0] += 1 }
    for i in rows.indices where nameCounts[rows[i].name.lowercased()]! > 1 {
        rows[i].label = "\(rows[i].name) (\(rows[i].bundleID))"
    }
    return rows
}
