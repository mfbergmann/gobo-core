// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The only way the engine touches calendars. EventKit is untestable in CI
/// (TCC approval, a real calendar database, a logged-in user), so every
/// EventKit call lives behind this protocol and `SyncEngine` is exercised
/// exhaustively against an in-memory fake. GoboCore itself never imports
/// EventKit.
public protocol CalendarStore {
    func calendars() throws -> [CalendarRef]

    /// All event occurrences in the given calendars intersecting
    /// [from, to). Recurring series arrive expanded, one element per
    /// occurrence, with `occurrenceDate` set.
    func events(in calendars: [CalendarRef], from: Date, to: Date) throws -> [SourceEvent]

    /// Creates a mirror event and returns its store identifier. The store
    /// must set availability to Busy (where supported) and must not attach
    /// alarms.
    func create(_ mirror: MirrorSpec, in calendar: CalendarRef) throws -> String

    /// Rewrites an existing mirror to match the spec, re-asserting Busy
    /// availability and stripping any alarms.
    func update(id: String, to mirror: MirrorSpec) throws

    func delete(id: String) throws

    /// Deletes an entire recurring series by its shared identifier. Only the
    /// explicit purge path uses this; regular sync never touches recurring
    /// events on the target. Defaults to `delete(id:)` for stores without
    /// recurrence.
    func deleteSeries(id: String) throws

    /// Flushes pending writes as one batch, so a failure part-way does not
    /// leave the target calendar half-updated. Stores without batch
    /// semantics may treat every write as immediate.
    func commit() throws

    /// Discards pending (uncommitted) writes after a failure.
    func rollback()
}

public extension CalendarStore {
    func deleteSeries(id: String) throws {
        try delete(id: id)
    }

    func commit() throws {}
    func rollback() {}
}
