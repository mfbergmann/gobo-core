// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// EventKit's `predicateForEvents(withStart:end:calendars:)` matches events
/// in at most a four-year span and *silently* truncates anything longer to
/// the first four years. Store implementations split wide reads into chunks
/// below that limit so a purge over many years actually sees everything.
public enum DateRangeChunker {
    /// Conservatively below EventKit's four-year cap.
    public static let maxChunkSeconds: TimeInterval = 1200 * 86_400

    public static func chunks(from: Date, to: Date) -> [Range<Date>] {
        guard from < to else { return [] }
        var result: [Range<Date>] = []
        var cursor = from
        while cursor < to {
            let end = min(cursor.addingTimeInterval(maxChunkSeconds), to)
            result.append(cursor..<end)
            cursor = end
        }
        return result
    }
}
